//
//  UsageManager.swift
//  boringNotch
//
//  AI 用量数据层：GLM Coding Plan / Kimi Code 配额轮询、凭证解析、历史快照。
//
//  【接口契约 — 并行开发约定，签名不可改】
//  - `UsageManager.shared` 单例，@MainActor
//  - `@Published kimi / glm: ModelUsage?`：两模型最新用量
//  - `@Published history: [UsageSnapshot]`：7 天历史快照（详情页按天聚合画柱状图）
//  - `hasAnyConfig: Bool`：任一模型已配置凭证
//  - `start() / stop()`：由协调器按 Defaults[.usageDisplayEnabled] 驱动；每 5 分钟轮询
//  - `refresh()`：手动刷新（Token 页刷新按钮）
//
//  【已实测接口（2026-08-18）】
//  GLM: GET https://open.bigmodel.cn/api/monitor/usage/quota/limit
//       头 Authorization: <key>（裸 key）；limits[] 按 unit 区分（3=5h、6=周），
//       type 可能是 CREDIT_LIMIT 或 TOKENS_LIMIT，禁止按 type 硬编码
//  Kimi: GET https://api.kimi.com/coding/v1/usages
//       头 Authorization: Bearer <token>；usage=周额度、limits[].detail(window 300min)=5h 滚动窗
//

import Defaults
import Foundation

/// 单个模型的最新用量
struct ModelUsage: Equatable {
    var name: String
    var membershipNote: String?    // 套餐/会员等级
    var fiveHourUsedPct: Double?   // 5h 窗口已用百分比 0-100
    var fiveHourReset: Date?
    var weeklyUsedPct: Double?     // 周窗口已用百分比 0-100
    var weeklyUsed: String?
    var weeklyLimit: String?
    var weeklyReset: Date?
    var totalNote: String?         // 总额度备注（GLM 月度剩余 / Kimi 加油包状态）
    var lastError: String?
    var updatedAt: Date?
}

/// 历史快照点（详情页按天聚合画柱状图）
struct UsageSnapshot: Codable, Equatable, Identifiable {
    var id: Date { t }
    let t: Date
    let glm5h: Double?
    let glmWeek: Double?
    let kimi5h: Double?
    let kimiWeek: Double?
}

@MainActor
final class UsageManager: ObservableObject {
    static let shared = UsageManager()

    @Published private(set) var kimi: ModelUsage?
    @Published private(set) var glm: ModelUsage?
    @Published private(set) var history: [UsageSnapshot] = []
    @Published private(set) var credentialSources: [String: String] = [:]

    var hasAnyConfig: Bool {
        credentialSources.values.contains { $0 != "none" }
    }

    private var timer: Timer?
    private var isRefreshing = false

    private let pollInterval: TimeInterval = 5 * 60
    private let historyRetention: TimeInterval = 7 * 24 * 60 * 60

    private let glmEndpoint = URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!
    private let kimiEndpoint = URL(string: "https://api.kimi.com/coding/v1/usages")!
    private let kimiAuthEndpoint = URL(string: "https://auth.kimi.com/api/oauth/token")!

    private let credentialsURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".kimi-code/credentials/kimi-code.json")

    private lazy var historyURL: URL = {
        let fm = FileManager.default
        let support = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = (support ?? fm.temporaryDirectory)
            .appendingPathComponent("boringNotch", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage_history.json")
    }()

    private let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        loadHistory()
        refreshCredentialSourcesFromKeychain()
    }

    private func refreshCredentialSourcesFromKeychain() {
        var sources: [String: String] = [:]
        sources["glm"] = (KeychainHelper.read(.glmAPIKey) != nil) ? "keychain" : "none"
        sources["kimi"] = (KeychainHelper.read(.kimiAPIKey) != nil) ? "keychain" : "none"
        credentialSources = sources
    }

    // MARK: - 生命周期

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRefreshing = false
        glm = nil
        kimi = nil
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { @MainActor in
            let credentials = await resolveCredentials()
            await fetchGLM(using: credentials.glmKey)
            await fetchKimi(using: credentials.kimiToken, refreshToken: credentials.kimiRefreshToken)
            isRefreshing = false
        }
    }

    // MARK: - 凭证解析

    /// 异步解析并缓存凭证来源。优先级：Keychain 手动覆盖 > helper 代读 Kimi Code 配置。
    /// 返回实际用于请求的 glmKey / kimiToken / kimiRefreshToken，同时更新 credentialSources。
    private func resolveCredentials() async -> (glmKey: String?, kimiToken: String?, kimiRefreshToken: String?) {
        var glmKey = KeychainHelper.read(.glmAPIKey)
        var kimiToken = KeychainHelper.read(.kimiAPIKey)
        var kimiRefreshToken: String?

        var sources: [String: String] = [:]
        if let glmKey, !glmKey.isEmpty {
            sources["glm"] = "keychain"
        }
        if let kimiToken, !kimiToken.isEmpty {
            sources["kimi"] = "keychain"
        }

        // 只有 Keychain 未覆盖时才请 helper 代读 ~/.kimi-code/。
        let needsHelper = glmKey == nil || glmKey?.isEmpty == true
            || kimiToken == nil || kimiToken?.isEmpty == true
        let helperCredentials = needsHelper ? await XPCHelperClient.shared.readKimiCodeCredentials() : [:]

        if glmKey == nil || glmKey?.isEmpty == true {
            glmKey = helperCredentials["glmAPIKey"]
            sources["glm"] = glmKey != nil ? "local" : (sources["glm"] ?? "none")
        }

        if kimiToken == nil || kimiToken?.isEmpty == true {
            kimiToken = helperCredentials["kimiAPIKey"] ?? helperCredentials["kimiAccessToken"]
            sources["kimi"] = kimiToken != nil ? "local" : (sources["kimi"] ?? "none")
            kimiRefreshToken = helperCredentials["kimiRefreshToken"]
        }

        if sources["glm"] == nil { sources["glm"] = "none" }
        if sources["kimi"] == nil { sources["kimi"] = "none" }

        credentialSources = sources
        return (glmKey, kimiToken, kimiRefreshToken)
    }

    /// 供设置页刷新凭证来源显示，不触发网络请求。
    func refreshCredentialSources() async {
        _ = await resolveCredentials()
    }

    @discardableResult
    private func updateCredentials(accessToken: String, refreshToken: String?) -> Bool {
        var dict: [String: Any] = [:]
        if let data = try? Data(contentsOf: credentialsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = json
        }
        dict["access_token"] = accessToken
        if let refreshToken {
            dict["refresh_token"] = refreshToken
        }
        guard let newData = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }
        do {
            try? FileManager.default.createDirectory(
                at: credentialsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try newData.write(to: credentialsURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - GLM

    private func fetchGLM(using key: String?) async {
        guard let key, !key.isEmpty else {
            self.glm = nil
            return
        }

        var request = URLRequest(url: glmEndpoint)
        request.setValue(key, forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                setGLMError("网络响应异常")
                return
            }

            print("[UsageManager] GLM status: \(http.statusCode)")

            switch http.statusCode {
            case 200..<300:
                parseGLMResponse(data)
            case 401, 403:
                setGLMError("未授权/凭证失效")
            default:
                setGLMError("服务器错误 (\(http.statusCode))")
            }
        } catch {
            setGLMError(error.localizedDescription)
        }
    }

    private func parseGLMResponse(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any] else {
            setGLMError("数据解析失败")
            return
        }

        let limits = dataObj["limits"] as? [[String: Any]] ?? []

        var fiveHourPct: Double?
        var fiveHourReset: Date?
        var weeklyPct: Double?
        var weeklyReset: Date?
        var totalNote: String?

        for limit in limits {
            let unit = (limit["unit"] as? NSNumber)?.intValue ?? limit["unit"] as? Int
            let pct = (limit["percentage"] as? NSNumber)?.doubleValue ?? limit["percentage"] as? Double
            let reset = dateFrom(milliseconds: limit["nextResetTime"])

            if unit == 3 {
                fiveHourPct = pct
                fiveHourReset = reset
            } else if unit == 6 {
                weeklyPct = pct
                weeklyReset = reset
            }

            if let type = limit["type"] as? String, type == "TIME_LIMIT" {
                if let remaining = limit["remaining"] {
                    totalNote = "剩余: \(remaining)"
                }
            }
        }

        let membership = dataObj["level"] as? String

        self.glm = ModelUsage(
            name: "GLM",
            membershipNote: membership,
            fiveHourUsedPct: fiveHourPct,
            fiveHourReset: fiveHourReset,
            weeklyUsedPct: weeklyPct,
            weeklyUsed: nil,
            weeklyLimit: nil,
            weeklyReset: weeklyReset,
            totalNote: totalNote,
            lastError: nil,
            updatedAt: Date()
        )
        recordSnapshot()
    }

    // MARK: - Kimi

    private func fetchKimi(using token: String?, refreshToken: String?) async {
        guard let token, !token.isEmpty else {
            self.kimi = nil
            return
        }

        await performKimiRequest(token: token, refreshToken: refreshToken, allowRefresh: true)
    }

    private func performKimiRequest(token: String, refreshToken: String?, allowRefresh: Bool) async {
        var request = URLRequest(url: kimiEndpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                setKimiError("网络响应异常")
                return
            }

            print("[UsageManager] Kimi status: \(http.statusCode)")

            switch http.statusCode {
            case 200..<300:
                parseKimiResponse(data)
            case 401:
                if allowRefresh, let refreshToken, !refreshToken.isEmpty {
                    if let newToken = await refreshKimiToken(refreshToken: refreshToken) {
                        await performKimiRequest(token: newToken, refreshToken: refreshToken, allowRefresh: false)
                        return
                    }
                }
                setKimiError("未授权/凭证失效")
            case 403:
                setKimiError("未授权/凭证失效")
            default:
                setKimiError("服务器错误 (\(http.statusCode))")
            }
        } catch {
            setKimiError(error.localizedDescription)
        }
    }

    private func parseKimiResponse(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            setKimiError("数据解析失败")
            return
        }

        // 周额度
        var weeklyUsed: String?
        var weeklyLimit: String?
        var weeklyPct: Double?
        var weeklyReset: Date?
        if let usage = json["usage"] as? [String: Any] {
            let used = usage["used"]
            let limit = usage["limit"]
            weeklyUsed = used != nil ? String(describing: used!) : nil
            weeklyLimit = limit != nil ? String(describing: limit!) : nil
            // 数值是字符串（如 "50"/"100"），兼容数字与字符串两种形态
            if let u = asDouble(used), let l = asDouble(limit), l > 0 {
                weeklyPct = (u / l) * 100
            }
            weeklyReset = dateFrom(iso8601: usage["resetTime"])
        }

        // 5h 滚动窗：window 与 detail 平级；duration=300（分钟，数字），detail 内数值是字符串
        var fiveHourPct: Double?
        var fiveHourReset: Date?
        if let limits = json["limits"] as? [[String: Any]],
           let fiveHour = limits.first(where: { limit -> Bool in
               guard let window = limit["window"] as? [String: Any] else { return false }
               let duration = (window["duration"] as? NSNumber)?.intValue ?? window["duration"] as? Int
               return duration == 300
           }),
           let detail = fiveHour["detail"] as? [String: Any] {
            // detail.limit/used 是字符串，如 "100"/"1"
            if let usedStr = detail["used"] as? String, let limitStr = detail["limit"] as? String,
               let used = Double(usedStr), let lim = Double(limitStr), lim > 0 {
                fiveHourPct = used / lim * 100
            }
            fiveHourReset = dateFrom(iso8601: detail["resetTime"])
        }

        // 会员等级
        var membership: String?
        if let user = json["user"] as? [String: Any],
           let member = user["membership"] as? [String: Any] {
            membership = member["level"] as? String
        }

        // 加油包状态
        var totalNote: String?
        if let booster = json["boosterWallet"] as? [String: Any] {
            totalNote = booster["status"] as? String
        }

        self.kimi = ModelUsage(
            name: "Kimi",
            membershipNote: membership,
            fiveHourUsedPct: fiveHourPct,
            fiveHourReset: fiveHourReset,
            weeklyUsedPct: weeklyPct,
            weeklyUsed: weeklyUsed,
            weeklyLimit: weeklyLimit,
            weeklyReset: weeklyReset,
            totalNote: totalNote,
            lastError: nil,
            updatedAt: Date()
        )
        recordSnapshot()
    }

    private func refreshKimiToken(refreshToken: String) async -> String? {
        var request = URLRequest(url: kimiAuthEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken)
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                print("[UsageManager] Kimi token refresh failed: status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = json["access_token"] as? String else {
                return nil
            }
            let newRefresh = json["refresh_token"] as? String
            _ = updateCredentials(accessToken: access, refreshToken: newRefresh ?? refreshToken)
            return access
        } catch {
            print("[UsageManager] Kimi token refresh error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 错误处理（保留上次成功数据）

    private func setGLMError(_ message: String) {
        if var current = glm {
            current.lastError = message
            current.updatedAt = Date()
            glm = current
        } else {
            glm = ModelUsage(
                name: "GLM",
                membershipNote: nil,
                fiveHourUsedPct: nil,
                fiveHourReset: nil,
                weeklyUsedPct: nil,
                weeklyUsed: nil,
                weeklyLimit: nil,
                weeklyReset: nil,
                totalNote: nil,
                lastError: message,
                updatedAt: Date()
            )
        }
    }

    private func setKimiError(_ message: String) {
        if var current = kimi {
            current.lastError = message
            current.updatedAt = Date()
            kimi = current
        } else {
            kimi = ModelUsage(
                name: "Kimi",
                membershipNote: nil,
                fiveHourUsedPct: nil,
                fiveHourReset: nil,
                weeklyUsedPct: nil,
                weeklyUsed: nil,
                weeklyLimit: nil,
                weeklyReset: nil,
                totalNote: nil,
                lastError: message,
                updatedAt: Date()
            )
        }
    }

    // MARK: - 历史快照

    private func recordSnapshot() {
        let snapshot = UsageSnapshot(
            t: Date(),
            glm5h: glm?.fiveHourUsedPct,
            glmWeek: glm?.weeklyUsedPct,
            kimi5h: kimi?.fiveHourUsedPct,
            kimiWeek: kimi?.weeklyUsedPct
        )
        history.append(snapshot)
        pruneHistory()
        saveHistory()
    }

    private func pruneHistory() {
        let cutoff = Date().addingTimeInterval(-historyRetention)
        history.removeAll { $0.t < cutoff }
        history.sort { $0.t < $1.t }
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL),
              let snaps = try? jsonDecoder.decode([UsageSnapshot].self, from: data) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-historyRetention)
        history = snaps.filter { $0.t >= cutoff }.sorted { $0.t < $1.t }
    }

    private func saveHistory() {
        do {
            try? FileManager.default.createDirectory(
                at: historyURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try jsonEncoder.encode(history)
            try data.write(to: historyURL, options: .atomic)
        } catch {
            print("[UsageManager] Failed to save history: \(error.localizedDescription)")
        }
    }

    // MARK: - 工具方法

    private func dateFrom(milliseconds value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue / 1000.0)
    }

    /// 兼容 JSON 里数字与字符串两种数值形态（Kimi 接口的数值是字符串）
    private func asDouble(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private func dateFrom(iso8601 value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
