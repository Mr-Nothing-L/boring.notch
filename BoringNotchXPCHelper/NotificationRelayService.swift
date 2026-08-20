//
//  NotificationRelayService.swift
//  BoringNotchXPCHelper
//
//  Event-driven AX relay for system notification banners.
//  Runs inside the non-sandboxed XPC helper because the sandboxed main app
//  cannot register a cross-process AXObserver (kAXErrorCannotComplete -25204).
//

import Foundation
import AppKit
import ApplicationServices

private let kLogPrefix = "[NotificationRelay]"
private let kNotificationCenterBundleID = "com.apple.notificationcenterui"
private let kBannerSubrole = "AXNotificationCenterBanner"
private let kHiddenBannerPosition = CGPoint(x: -5000, y: -5000)

/// AXObserver C callback — dispatches into the service singleton on the main runloop.
private func notificationRelayAXCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let service = Unmanaged<NotificationRelayService>.fromOpaque(refcon).takeUnretainedValue()
    service.handleAXNotification(element: element, notificationName: notification as String)
}

private let kRelayLogFile = "/tmp/bn_helper.log"
private func relayLog(_ message: String) {
    NSLog("%@", message)
    let line = "\(Date()): \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: kRelayLogFile),
           let h = FileHandle(forWritingAtPath: kRelayLogFile) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: kRelayLogFile))
        }
    }
}

final class NotificationRelayService {

    static let shared = NotificationRelayService()

    /// Current XPC connection from the main app; used to push events back.
    /// Set by ServiceDelegate in main.swift.
    /// 注意必须强引用：listener 侧不会保留已接受的连接，弱引用会导致连接提前释放、
    /// 反向推送静默丢失（曾因此出现通知时好时坏的问题）。
    var connection: NSXPCConnection?

    /// 专用 AX runloop 线程：XPC service 的主 runloop 不会被驱动（listener.resume() 只泵 dispatch main queue），
    /// AXObserver 的 runloop source 必须挂在真正运行的 runloop 上。
    private final class AXRunLoopThread: Thread {
        private(set) var runLoop: CFRunLoop?
        private let ready = DispatchSemaphore(value: 0)

        override func main() {
            runLoop = CFRunLoopGetCurrent()
            // 挂一个空 mach port 防止 runloop 因无 source 直接退出
            let port = CFMachPortCreate(kCFAllocatorDefault, nil, nil, nil)
            CFRunLoopAddSource(runLoop, CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0), .defaultMode)
            ready.signal()
            CFRunLoopRun()
        }

        func waitUntilReady() -> CFRunLoop {
            ready.wait()
            return runLoop!
        }
    }

    private lazy var axThread: AXRunLoopThread = {
        let t = AXRunLoopThread()
        t.name = "notificationRelay.ax"
        t.start()
        return t
    }()

    private struct BannerRef {
        let id: String
        let window: AXUIElement
        let banner: AXUIElement
    }

    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var hideSystemBanners = false
    private var banners: [String: BannerRef] = [:]
    private var workspaceObserversRegistered = false
    private var running = false

    private init() {}

    // MARK: - Public API (called on main queue)

    func start(hideSystemBanners: Bool) -> Bool {
        self.hideSystemBanners = hideSystemBanners
        running = true
        registerWorkspaceObservers()
        guard attach() else {
            relayLog("\(kLogPrefix) attach failed")
            return false
        }
        return true
    }

    func stop() {
        running = false
        detach()
        banners.removeAll()
        relayLog("\(kLogPrefix) stopped")
    }

    /// Press the original banner (deep-link into the source app). Returns false if stale/missing.
    func pressBanner(id: String) -> Bool {
        guard let ref = banners[id] else {
            relayLog("\(kLogPrefix) press failed: unknown id \(id)")
            return false
        }
        guard isElementValid(ref.banner) else {
            relayLog("\(kLogPrefix) press failed: banner element invalid for id \(id)")
            banners.removeValue(forKey: id)
            return false
        }
        let err = AXUIElementPerformAction(ref.banner, kAXPressAction as CFString)
        relayLog("\(kLogPrefix) AXPress on banner \(id): \(err.rawValue)")
        return err == .success
    }

    // MARK: - Attach / detach to NotificationCenter

    @discardableResult
    private func attach() -> Bool {
        detach()

        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == kNotificationCenterBundleID
        }) else {
            relayLog("\(kLogPrefix) \(kNotificationCenterBundleID) not running")
            return false
        }

        let pid = app.processIdentifier
        var newObserver: AXObserver?
        let createErr = AXObserverCreate(pid, notificationRelayAXCallback, &newObserver)
        guard createErr == .success, let newObserver else {
            relayLog("\(kLogPrefix) AXObserverCreate failed: \(createErr.rawValue)")
            return false
        }

        let appElement = AXUIElementCreateApplication(pid)
        // Required, otherwise kAXWindowCreatedNotification is never delivered.
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let addErr = AXObserverAddNotification(
            newObserver, appElement, kAXWindowCreatedNotification as CFString, refcon)
        guard addErr == .success else {
            relayLog("\(kLogPrefix) AXObserverAddNotification(AXWindowCreated) failed: \(addErr.rawValue)")
            return false
        }

        CFRunLoopAddSource(
            axThread.waitUntilReady(), AXObserverGetRunLoopSource(newObserver), .defaultMode)

        observer = newObserver
        observedPID = pid
        relayLog("\(kLogPrefix) attached to \(kNotificationCenterBundleID) (pid \(pid))")
        return true
    }

    private func detach() {
        if let observer, axThread.runLoop != nil {
            CFRunLoopRemoveSource(
                axThread.waitUntilReady(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPID = 0
    }

    // MARK: - Workspace notifications (process restart re-attach)

    private func registerWorkspaceObservers() {
        guard !workspaceObserversRegistered else { return }
        workspaceObserversRegistered = true
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == kNotificationCenterBundleID else { return }
            relayLog("\(kLogPrefix) NotificationCenter terminated; detaching")
            self?.detach()
        }
        nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self, self.running,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == kNotificationCenterBundleID else { return }
            relayLog("\(kLogPrefix) NotificationCenter launched; re-attaching")
            // AX server may need a moment before accepting an observer for the new process.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if !self.attach() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { _ = self.attach() }
                }
            }
        }
    }

    // MARK: - AX notification handling (main runloop)

    func handleAXNotification(element: AXUIElement, notificationName: String) {
        // 回调来自专用 AX runloop 线程；状态都在主队列，统一切换过去
        DispatchQueue.main.async {
            relayLog("\(kLogPrefix) AX event: \(notificationName)")
            switch notificationName {
            case kAXWindowCreatedNotification:
                self.handleWindowCreated(element)
            case kAXUIElementDestroyedNotification:
                self.handleElementDestroyed(element)
            default:
                break
            }
        }
    }

    private func handleWindowCreated(_ window: AXUIElement) {
        // 判别瞬时横幅 vs 通知中心面板（实测 macOS 26）：
        // 两者的窗口都是全屏 AXSystemDialog 覆盖层，无法靠 subrole/尺寸区分；
        // 但瞬时横幅窗口内只含 1 个 AXNotificationCenterBanner，
        // 通知中心面板的窗口内包含多个（已送达通知列表）。因此只处理横幅数==1 的窗口。
        let windowSubrole = copyStringAttribute(window, kAXSubroleAttribute) ?? ""
        guard windowSubrole == "AXSystemDialog" else {
            relayLog("\(kLogPrefix) window rejected: subrole=\(windowSubrole.isEmpty ? "<none>" : windowSubrole)")
            return
        }
        let bannerCount = countBanners(in: window)
        if bannerCount == 0 {
            // Content may not be populated yet; retry once shortly after.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, self.running, self.isElementValid(window) else { return }
                let retryCount = self.countBanners(in: window)
                guard retryCount == 1, let banner = self.findBanner(in: window) else {
                    if retryCount > 1 {
                        relayLog("\(kLogPrefix) window rejected on retry: \(retryCount) banners (通知中心面板)")
                    }
                    return
                }
                self.processBanner(window: window, banner: banner)
            }
            return
        }
        guard bannerCount == 1 else {
            relayLog("\(kLogPrefix) window rejected: \(bannerCount) banners (通知中心面板)")
            return
        }
        guard let banner = findBanner(in: window) else { return }
        processBanner(window: window, banner: banner)
    }

    private func processBanner(window: AXUIElement, banner: AXUIElement) {
        // Skip duplicates (retry path can race with a fully populated first pass).
        for (_, ref) in banners where CFEqual(ref.window, window) { return }

        let description = copyStringAttribute(banner, kAXDescriptionAttribute) ?? ""
        let extracted = extractBannerTexts(from: banner)
        let (appName, bundleID) = resolveApp(from: description, subtitle: extracted.subtitle)

        let title = extracted.title
        let body = extracted.body

        let id = UUID().uuidString
        banners[id] = BannerRef(id: id, window: window, banner: banner)

        relayLog("\(kLogPrefix) banner received: app=\(appName) title=\(title) subtitle=\(extracted.subtitle ?? "<none>")")

        // Observe destruction of this banner's window for dismiss events.
        if let observer {
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            let err = AXObserverAddNotification(
                observer, window, kAXUIElementDestroyedNotification as CFString, refcon)
            if err != .success {
                relayLog("\(kLogPrefix) register AXUIElementDestroyed failed: \(err.rawValue)")
            }
        }

        if hideSystemBanners {
            moveOffScreen(window)
        }

        let payload: NSMutableDictionary = [
            "id": id,
            "appName": appName,
            "title": title,
            "body": body
        ]
        if let bundleID { payload["bundleID"] = bundleID }
        push { $0.notificationRelayDidReceive(payload) }
    }

    private func handleElementDestroyed(_ element: AXUIElement) {
        guard let (id, _) = banners.first(where: { CFEqual($0.value.window, element) || CFEqual($0.value.banner, element) })
        else { return }
        banners.removeValue(forKey: id)
        relayLog("\(kLogPrefix) banner destroyed: id=\(id)")
        push { $0.notificationRelayDidDismiss(id) }
    }

    // MARK: - Banner tree parsing

    private func findBanner(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth <= 8 else { return nil }
        if copyStringAttribute(element, kAXSubroleAttribute) == kBannerSubrole {
            return element
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return nil }
        for child in children {

            if let found = findBanner(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    /// 统计子树内 AXNotificationCenterBanner 数量（区分瞬时横幅窗口与通知中心面板）
    private func countBanners(in element: AXUIElement, depth: Int = 0) -> Int {
        guard depth <= 10 else { return 0 }
        var count = copyStringAttribute(element, kAXSubroleAttribute) == kBannerSubrole ? 1 : 0
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return count }
        for child in children {
            count += countBanners(in: child, depth: depth + 1)
        }
        return count
    }

    /// 提取标题/副标题/正文：优先按子级 AXStaticText 的 AXIdentifier
    /// （"title"/"subtitle"/"body"，网页推送横幅实测带标识）匹配；
    /// 取不到再退回按位置收集（首个为标题，其余拼接为正文）。
    private func extractBannerTexts(from banner: AXUIElement) -> (title: String, subtitle: String?, body: String) {
        var identified: [String: String] = [:]
        collectIdentifiedTexts(banner, into: &identified)
        if let title = identified["title"], !title.isEmpty {
            let subtitle = identified["subtitle"]
            let body = identified["body"] ?? ""
            return (title, (subtitle?.isEmpty == false) ? subtitle : nil, body)
        }
        let texts = collectStaticTexts(banner)
        return (texts.first ?? "", nil, texts.dropFirst().joined(separator: "\n"))
    }

    private func collectIdentifiedTexts(_ element: AXUIElement, into result: inout [String: String], depth: Int = 0) {
        guard depth <= 8 else { return }
        if copyStringAttribute(element, kAXRoleAttribute) == kAXStaticTextRole,
           let identifier = copyStringAttribute(element, kAXIdentifierAttribute),
           let value = copyStringAttribute(element, kAXValueAttribute), !value.isEmpty {
            result[identifier] = value
        }
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                collectIdentifiedTexts(child, into: &result, depth: depth + 1)
            }
        }
    }

    private func collectStaticTexts(_ element: AXUIElement, depth: Int = 0) -> [String] {
        guard depth <= 8 else { return [] }
        var result: [String] = []
        if copyStringAttribute(element, kAXRoleAttribute) == kAXStaticTextRole,
           let value = copyStringAttribute(element, kAXValueAttribute), !value.isEmpty {
            result.append(value)
        }
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                result.append(contentsOf: collectStaticTexts(child, depth: depth + 1))
            }
        }
        return result
    }

    /// AXDescription of the banner group starts with the app's display name;
    /// match it against running apps (longest localizedName prefix wins).
    /// 匹配失败时按域名特征识别网页推送（Safari Web Push）：appName 取域名，
    /// bundleID 取默认浏览器，保证点击可跳转。
    private func resolveApp(from description: String, subtitle: String? = nil) -> (name: String, bundleID: String?) {
        var best: NSRunningApplication?
        for app in NSWorkspace.shared.runningApplications {
            guard let name = app.localizedName,
                  !name.isEmpty,
                  description.hasPrefix(name) else { continue }
            if name.count > (best?.localizedName?.count ?? 0) { best = app }
        }
        if let best {
            return (best.localizedName ?? description, best.bundleIdentifier)
        }
        if let domain = webPushDomain(from: description, subtitle: subtitle) {
            return (domain, defaultBrowserBundleID())
        }
        return (description, nil)
    }

    /// 网页推送的域名：subtitle 即域名（实测），否则取描述首段（第一个逗号前）的首个 token。
    private func webPushDomain(from description: String, subtitle: String?) -> String? {
        if let subtitle, isDomainLike(subtitle) { return subtitle }
        let firstSegment = description.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
        let firstToken = firstSegment.split(separator: " ").first.map(String.init) ?? ""
        return isDomainLike(firstToken) ? firstToken : nil
    }

    /// 域名特征：不含空格且包含 "."
    private func isDomainLike(_ text: String) -> Bool {
        !text.isEmpty && !text.contains(" ") && text.contains(".")
    }

    private func defaultBrowserBundleID() -> String {
        if let appURL = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://www.apple.com")!),
           let bundleID = Bundle(url: appURL)?.bundleIdentifier {
            return bundleID
        }
        return "com.apple.Safari"
    }

    // MARK: - Hiding banners

    private func moveOffScreen(_ window: AXUIElement) {
        var point = kHiddenBannerPosition
        guard let positionValue = AXValueCreate(.cgPoint, &point) else { return }
        let setErr = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        guard setErr == .success else {
            relayLog("\(kLogPrefix) hide failed (set position): \(setErr.rawValue)")
            return
        }
        // Read back to confirm the banner actually moved off screen.
        var readBackRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &readBackRef) == .success,
              let axValue = readBackRef,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            relayLog("\(kLogPrefix) hide unconfirmed (read-back failed); giving up")
            return
        }
        var readBack = CGPoint.zero
        AXValueGetValue(unsafeDowncast(axValue, to: AXValue.self), .cgPoint, &readBack)
        if abs(readBack.x - kHiddenBannerPosition.x) < 1 && abs(readBack.y - kHiddenBannerPosition.y) < 1 {
            relayLog("\(kLogPrefix) banner hidden off screen")
        } else {
            relayLog("\(kLogPrefix) hide unconfirmed (position \(readBack.x),\(readBack.y)); giving up")
        }
    }

    // MARK: - Helpers

    private func isElementValid(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success
    }

    private func copyStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func push(_ block: (NotificationRelayClientProtocol) -> Void) {
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ error in
            relayLog("\(kLogPrefix) push error: \(error.localizedDescription)")
        }) as? NotificationRelayClientProtocol else {
            relayLog("\(kLogPrefix) no client connection; dropping event")
            return
        }
        block(proxy)
    }
}
