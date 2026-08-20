//
//  BoringNotchXPCHelperProtocol.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation

/// 主 app 侧导出对象实现的回调协议：helper 通过连接的 remoteObjectProxy 反向推送通知事件。
/// payload 为 property-list 字典：id(String, UUID)/appName/title/body，可选 bundleID。
@objc protocol NotificationRelayClientProtocol {
    /// 新横幅出现并已解析
    func notificationRelayDidReceive(_ payload: NSDictionary)
    /// 横幅在系统侧销毁
    func notificationRelayDidDismiss(_ id: String)
}

/// The protocol that this service will vend as its API. This protocol will also need to be visible to the process hosting the service.
@objc protocol BoringNotchXPCHelperProtocol {
    func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void)
    func requestAccessibilityAuthorization()
    func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void)
    // 通知横幅中继（AX 观察在非沙盒 helper 内执行；沙盒主 app 无法注册跨进程 AXObserver）
    /// 开始监听系统通知横幅。hideSystemBanners=true 时把系统横幅移出屏外。
    /// reply: true = 已挂接成功；false = AX 未授权或挂接失败
    func startNotificationRelay(hideSystemBanners: Bool, with reply: @escaping (Bool) -> Void)
    func stopNotificationRelay()
    /// 对指定通知的原横幅执行 AXPress（深链接跳转）；横幅已失效时 reply(false)
    func pressNotificationBanner(_ id: String, with reply: @escaping (Bool) -> Void)

    // 读取本机 Kimi Code 配置中的 AI 凭证（沙盒主 app 无法直读 ~/.kimi-code/，由非沙盒 helper 代读）。
    // 返回 NSDictionary，可能包含键：glmAPIKey / kimiAPIKey / kimiAccessToken / kimiRefreshToken（均为 String，缺则不含）。
    // 注意：凭证内容绝不进日志。
    func readKimiCodeCredentials(with reply: @escaping (NSDictionary) -> Void)
    // Keyboard backlight / CoreBrightness access (performed by the helper)
    func isKeyboardBrightnessAvailable(with reply: @escaping (Bool) -> Void)
    func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    // Screen brightness access (performed by the helper)
    func isScreenBrightnessAvailable(with reply: @escaping (Bool) -> Void)
    func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
}

/*
 To use the service from an application or other process, use NSXPCConnection to establish a connection to the service by doing something like this:

     connectionToService = NSXPCConnection(serviceName: "theboringteam.boringnotch.BoringNotchXPCHelper")
     connectionToService.remoteObjectInterface = NSXPCInterface(with: (any BoringNotchXPCHelperProtocol).self)
     connectionToService.resume()

 Once you have a connection to the service, you can use it like this:

     if let proxy = connectionToService.remoteObjectProxy as? BoringNotchXPCHelperProtocol {
         proxy.performCalculation(firstNumber: 23, secondNumber: 19) { result in
             NSLog("Result of calculation is: \(result)")
         }
     }

 And, when you are finished with the service, clean up the connection like this:

     connectionToService.invalidate()
*/
