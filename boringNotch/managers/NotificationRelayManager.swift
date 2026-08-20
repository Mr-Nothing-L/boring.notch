//
//  NotificationRelayManager.swift
//  boringNotch
//
//  通知中继管理器（XPC 客户端）：AX 观察在非沙盒 XPC helper 内执行
//  （沙盒阻断跨进程 AXObserver，实测注册失败 -25204），本类只做聚合与展示状态。
//
//  【接口契约 — 并行开发约定，签名不可改】
//  - `NotificationRelayManager.shared` 单例，@MainActor
//  - `@Published groups: [NotificationGroup]`：按最新时间倒序，UI 直接观察
//  - `latest: NotificationGroup?`：展开态 header 紧凑视图使用
//  - `start() / stop()`：由 AppDelegate/设置开关驱动
//  - `activate(_:)`：点击通知 → 优先 XPC 让 helper AXPress 原横幅（深链接），失败则按 bundleID 激活 app
//  - `pauseAutoDismiss() / resumeAutoDismiss()`：UI 悬停时暂停自动收起
//
//  【数据流】
//  helper 经 XPC 反向通道（NotificationRelayClientProtocol）推送：
//  - didReceive(payload: id/appName/bundleID?/title/body) → 按 appName 合并进 groups
//  - didDismiss(id) → 移除对应分组
//

import AppKit
import Combine
import Defaults

/// 一条聚合后的通知分组（按 app 合并）
struct NotificationGroup: Identifiable, Equatable {
    let id: UUID
    let appName: String
    let bundleID: String?
    var title: String
    var body: String
    var count: Int
    var latestAt: Date
}

@MainActor
final class NotificationRelayManager: NSObject, ObservableObject {
    static let shared = NotificationRelayManager()

    /// 当前活跃通知分组，最新在前；UI 直接观察。
    /// 持久保留，直到：用户点击跳转、点清空按钮、或功能关闭。
    @Published private(set) var groups: [NotificationGroup] = []

    /// 闭合态刘海的预览行是否可见（新通知到达后显示，notificationPeekDuration 秒后自动隐藏；
    /// 不影响 groups 里通知的留存）
    @Published private(set) var peekVisible = false

    /// 鼠标是否正悬停在闭合态通知预览行上（悬停期间禁止 hover 展开刘海）
    @Published var isHoveringNotificationPeek = false

    /// 最新一条（刘海展开态 header 紧凑视图使用）
    var latest: NotificationGroup? { groups.first }

    // MARK: - Private State

    private var isRunning = false

    /// 每个分组对应的 helper 端最新横幅 id（合并时更新为最新一条，供 AXPress 深链接用）
    private var helperIDs: [UUID: String] = [:]

    // 预览行自动隐藏计时（支持悬停暂停/恢复，计数器语义）
    private var peekHideTask: Task<Void, Never>?
    private var peekDeadline: Date?
    private var peekRemaining: TimeInterval?
    private var pauseCounter = 0

    private override init() {
        super.init()
    }

    // MARK: - Public API

    /// 启动监听（调用方需已确认 Defaults[.notchNotificationsEnabled]）
    func start() {
        NSLog("📨 [NRM] start() called, isRunning=%@", "\(isRunning)")
        guard !isRunning else { return }
        isRunning = true

        Task { [weak self] in
            guard let self else { return }
            let granted = await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
            guard granted else {
                NSLog("⚠️ [NRM] 辅助功能未授权，停止通知监听")
                self.isRunning = false
                return
            }
            guard self.isRunning else { return }
            let hideSystemBanners = Defaults[.hideSystemNotificationBanners]
            let started = await XPCHelperClient.shared.startNotificationRelay(hideSystemBanners: hideSystemBanners)
            guard started else {
                NSLog("⚠️ [NRM] helper startNotificationRelay 失败，停止通知监听")
                self.isRunning = false
                return
            }
            NSLog("📨 [NRM] 通知中继已启动 (hideSystemBanners=%@)", "\(hideSystemBanners)")
        }
    }

    /// 停止监听并清空状态
    func stop() {
        NSLog("📨 [NRM] stop() called, isRunning=%@", "\(isRunning)")
        isRunning = false
        XPCHelperClient.shared.stopNotificationRelay()
        peekHideTask?.cancel()
        peekHideTask = nil
        peekDeadline = nil
        peekRemaining = nil
        pauseCounter = 0
        peekVisible = false
        helperIDs.removeAll()
        groups = []
    }

    /// 清空全部通知（通知页垃圾桶按钮）
    func clearAll() {
        peekHideTask?.cancel()
        peekHideTask = nil
        peekDeadline = nil
        peekRemaining = nil
        peekVisible = false
        helperIDs.removeAll()
        groups = []
    }

    /// helper 连接中断后调用（由 XPCHelperClient.interruptionHandler 触发）：
    /// helper 进程可能已重启，AX 监听状态丢失，需延迟重新挂接
    func restartAfterHelperReconnect() {
        guard isRunning else { return }
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(1))
            guard self.isRunning else { return }
            let started = await XPCHelperClient.shared.startNotificationRelay(
                hideSystemBanners: Defaults[.hideSystemNotificationBanners])
            NSLog("📨 [NRM] helper 重连后重新挂接: %@", "\(started)")
        }
    }

    /// 点击通知：优先 XPC 让 helper AXPress 原横幅（深链接），失败则按 bundleID 激活 app
    func activate(_ group: NotificationGroup) {
        Task { [weak self] in
            guard let self else { return }
            var handled = false

            if let helperID = self.helperIDs[group.id] {
                handled = await XPCHelperClient.shared.pressNotificationBanner(helperID)
                if !handled {
                    NSLog("⚠️ [NRM] AXPress 原横幅失败 (id=%@)，回退激活 app", helperID)
                }
            }

            if !handled, let bundleID = group.bundleID {
                let workspace = NSWorkspace.shared
                if let app = workspace.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
                    handled = app.activate(options: [.activateIgnoringOtherApps])
                } else if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
                    handled = true
                    workspace.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                        if let error {
                            NSLog("⚠️ [NRM] 激活失败: %@", error.localizedDescription)
                        }
                    }
                }
            }

            if handled {
                // AXPress/激活后系统会销毁横幅，这里同步移除，等不到销毁事件也不残留
                self.removeGroup(id: group.id)
            }
        }
    }

    /// 悬停预览行时暂停自动隐藏计时
    func pauseAutoDismiss() {
        pauseCounter += 1
        guard pauseCounter == 1 else { return }
        peekHideTask?.cancel()
        peekHideTask = nil
        if let deadline = peekDeadline {
            peekRemaining = max(0, deadline.timeIntervalSinceNow)
            peekDeadline = nil
        }
    }

    /// 结束悬停，恢复自动隐藏计时
    func resumeAutoDismiss() {
        guard pauseCounter > 0 else { return }
        pauseCounter -= 1
        guard pauseCounter == 0 else { return }
        if let remaining = peekRemaining {
            peekRemaining = nil
            schedulePeekHide(after: remaining)
        }
    }

    // MARK: - 合并 ingest

    /// 新横幅到达：按 appName 合并（同 app ×N），复用已有分组 id，helper 端 id 更新为最新一条
    private func ingest(payload: NSDictionary) {
        guard isRunning else {
            NSLog("⚠️ [NRM] ingest 被丢弃：isRunning=false")
            return
        }
        guard let idString = payload["id"] as? String,
              let uuid = UUID(uuidString: idString) else {
            NSLog("⚠️ [NRM] payload 缺少合法 id: %@", payload)
            return
        }
        let rawAppName = payload["appName"] as? String ?? ""
        let appName = rawAppName.isEmpty ? "未知来源" : rawAppName
        let bundleID = payload["bundleID"] as? String
        let title = payload["title"] as? String ?? ""
        let body = payload["body"] as? String ?? ""
        NSLog("📨 [NRM] didReceive: %@ - %@", appName, title)

        let now = Date()
        if let index = groups.firstIndex(where: { $0.appName == appName }) {
            groups[index].count += 1
            groups[index].title = title
            groups[index].body = body
            groups[index].latestAt = now
            helperIDs[groups[index].id] = idString
        } else {
            let group = NotificationGroup(
                id: uuid, appName: appName, bundleID: bundleID,
                title: title, body: body, count: 1, latestAt: now
            )
            groups.append(group)
            helperIDs[group.id] = idString
        }
        groups.sort { $0.latestAt > $1.latestAt }

        // 新通知到达：闭合态预览行显示，notificationPeekDuration 秒后自动隐藏
        // （通知本身在 groups 里持久保留，不受此计时影响）
        peekVisible = true
        if pauseCounter > 0 {
            peekRemaining = Defaults[.notificationPeekDuration]
            peekDeadline = nil
        } else {
            schedulePeekHide(after: Defaults[.notificationPeekDuration])
        }
    }

    /// 横幅在系统侧销毁：横幅引用失效，仅清理映射；通知分组持久保留
    private func handleDismiss(id helperID: String) {
        NSLog("📨 [NRM] didDismiss: %@", helperID)
        if let match = helperIDs.first(where: { $0.value == helperID }) {
            helperIDs[match.key] = nil
        }
    }

    // MARK: - 预览行自动隐藏

    private func schedulePeekHide(after delay: TimeInterval) {
        peekHideTask?.cancel()
        peekDeadline = Date().addingTimeInterval(delay)
        peekHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.peekVisible = false
            self?.peekDeadline = nil
        }
    }

    private func removeGroup(id: UUID) {
        helperIDs[id] = nil
        groups.removeAll { $0.id == id }
    }
}

// MARK: - NotificationRelayClientProtocol（helper 反向推送，回调在 XPC 后台队列）

extension NotificationRelayManager: NotificationRelayClientProtocol {
    nonisolated func notificationRelayDidReceive(_ payload: NSDictionary) {
        Task { @MainActor in
            self.ingest(payload: payload)
        }
    }

    nonisolated func notificationRelayDidDismiss(_ id: String) {
        Task { @MainActor in
            self.handleDismiss(id: id)
        }
    }
}
