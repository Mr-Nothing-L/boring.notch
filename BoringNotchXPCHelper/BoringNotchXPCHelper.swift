//
//  BoringNotchXPCHelper.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation
import ApplicationServices
import IOKit
import CoreGraphics

class BoringNotchXPCHelper: NSObject, BoringNotchXPCHelperProtocol {
    
    @objc func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void) {
        reply(AXIsProcessTrusted())
    }

    @objc func requestAccessibilityAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @objc func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void) {
        if AXIsProcessTrusted() {
            reply(true)
            return
        }

        if promptIfNeeded {
            requestAccessibilityAuthorization()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            reply(AXIsProcessTrusted())
        }
    }

    // MARK: - Notification Relay (AX observation of system banners, event-driven)

    @objc func startNotificationRelay(hideSystemBanners: Bool, with reply: @escaping (Bool) -> Void) {
        guard AXIsProcessTrusted() else {
            NSLog("[NotificationRelay] start rejected: process not AX-trusted")
            reply(false)
            return
        }
        // AX observers deliver on the main runloop; hop there for all relay state changes.
        DispatchQueue.main.async {
            reply(NotificationRelayService.shared.start(hideSystemBanners: hideSystemBanners))
        }
    }

    @objc func stopNotificationRelay() {
        DispatchQueue.main.async {
            NotificationRelayService.shared.stop()
        }
    }

    @objc func pressNotificationBanner(_ id: String, with reply: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            reply(NotificationRelayService.shared.pressBanner(id: id))
        }
    }
    
    private class KeyboardBrightnessClient {
        private static let keyboardID: UInt64 = 1
        private var clientInstance: NSObject?
        private let getSelector = NSSelectorFromString("brightnessForKeyboard:")
        private let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")

        init() {
            var loaded = false
            let bundlePaths = [
                "/System/Library/PrivateFrameworks/CoreBrightness.framework",
                "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
            ]
            for path in bundlePaths where !loaded {
                if let bundle = Bundle(path: path) {
                    loaded = bundle.load()
                }
            }
            if loaded, let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
                clientInstance = cls.init()
            }
        }

        var isAvailable: Bool { clientInstance != nil }

        func currentBrightness() -> Float? {
            guard let clientInstance,
                  let fn: BrightnessGetter = methodIMP(on: clientInstance, selector: getSelector, as: BrightnessGetter.self)
            else { return nil }
            return fn(clientInstance, getSelector, Self.keyboardID)
        }

        func setBrightness(_ value: Float) -> Bool {
            guard let clientInstance,
                  let fn: BrightnessSetter = methodIMP(on: clientInstance, selector: setSelector, as: BrightnessSetter.self)
            else { return false }
            return fn(clientInstance, setSelector, value, Self.keyboardID).boolValue
        }

        private typealias BrightnessGetter = @convention(c) (NSObject, Selector, UInt64) -> Float
        private typealias BrightnessSetter = @convention(c) (NSObject, Selector, Float, UInt64) -> ObjCBool

        private func methodIMP<T>(on object: NSObject, selector: Selector, as type: T.Type) -> T? {
            guard let cls = object_getClass(object),
                  let method = class_getInstanceMethod(cls, selector)
            else { return nil }
            let imp = method_getImplementation(method)
            return unsafeBitCast(imp, to: type)
        }
    }

    private static let keyboardClient = KeyboardBrightnessClient()

    @objc func isKeyboardBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.isAvailable)
    }

    @objc func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void) {
        reply(Self.keyboardClient.currentBrightness().map { NSNumber(value: $0) })
    }

    @objc func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.setBrightness(value))
    }
    // MARK: - Screen Brightness (moved from client app into helper)

    @objc func isScreenBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        var b: Float = 0
        reply(displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) || ioServiceFor(displayID: CGMainDisplayID()) != nil)
    }

    @objc func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void) {
        var b: Float = 0
        if displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) {
            reply(NSNumber(value: b))
            return
        }
        if let io = ioServiceFor(displayID: CGMainDisplayID()) {
            var level: Float = 0
            if IODisplayGetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, &level) == kIOReturnSuccess {
                IOObjectRelease(io)
                reply(NSNumber(value: level))
                return
            }
            IOObjectRelease(io)
        }
        reply(nil)
    }

    @objc func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        let clamped = max(0, min(1, value))
        if displayServicesSetBrightness(displayID: CGMainDisplayID(), value: clamped) {
            reply(true)
            return
        }
        if let io = ioServiceFor(displayID: CGMainDisplayID()) {
            let ok = IODisplaySetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, clamped) == kIOReturnSuccess
            IOObjectRelease(io)
            reply(ok)
            return
        }
        reply(false)
    }

    // MARK: - Private helpers for DisplayServices / IOKit access
    private func displayServicesGetBrightness(displayID: CGDirectDisplayID, out: inout Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesGetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        var tmp: Float = 0
        let r = fn(displayID, &tmp)
        if r == 0 { out = tmp; return true }
        return false
    }

    private func displayServicesSetBrightness(displayID: CGDirectDisplayID, value: Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesSetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID, value) == 0
    }

    private func ioServiceFor(displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            let info = IODisplayCreateInfoDictionary(service, 0).takeRetainedValue() as NSDictionary
            if let vendorID = info[kDisplayVendorID] as? UInt32,
               let productID = info[kDisplayProductID] as? UInt32,
               vendorID == CGDisplayVendorNumber(displayID),
               productID == CGDisplayModelNumber(displayID) {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }

    // MARK: - Helper handle for private framework
    private enum DisplayServicesHandle {
        static let handle: UnsafeMutableRawPointer? = {
            let paths = [
                "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices"
            ]
            for p in paths {
                if let h = dlopen(p, RTLD_LAZY) { return h }
            }
            return nil
        }()
    }

    // MARK: - Kimi Code credential reader

    private func credentialsLog(_ message: String) {
        // 仅记录状态，绝不记录任何凭证内容或片段。
        NSLog("[CredentialReader] %@", message)
    }

    @objc func readKimiCodeCredentials(with reply: @escaping (NSDictionary) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = NSMutableDictionary()
            let home = FileManager.default.homeDirectoryForCurrentUser
            let configURL = home.appendingPathComponent(".kimi-code/config.toml")
            let credentialsURL = home.appendingPathComponent(".kimi-code/credentials/kimi-code.json")

            // 1. config.toml
            if FileManager.default.fileExists(atPath: configURL.path) {
                if let content = try? String(contentsOf: configURL, encoding: .utf8) {
                    self.parseKimiCodeConfigTOML(content, into: result)
                    self.credentialsLog("config.toml 读取成功")
                } else {
                    self.credentialsLog("config.toml 读取失败")
                }
            } else {
                self.credentialsLog("config.toml 文件不存在")
            }

            // 2. credentials/kimi-code.json
            if FileManager.default.fileExists(atPath: credentialsURL.path) {
                if let data = try? Data(contentsOf: credentialsURL),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let accessToken = json["access_token"] as? String, !accessToken.isEmpty {
                        result["kimiAccessToken"] = accessToken
                    }
                    if let refreshToken = json["refresh_token"] as? String, !refreshToken.isEmpty {
                        result["kimiRefreshToken"] = refreshToken
                    }
                    self.credentialsLog("credentials/kimi-code.json 读取成功")
                } else {
                    self.credentialsLog("credentials/kimi-code.json 读取失败")
                }
            } else {
                self.credentialsLog("credentials/kimi-code.json 文件不存在")
            }

            reply(result.copy() as! NSDictionary)
        }
    }

    private func parseKimiCodeConfigTOML(_ content: String, into result: NSMutableDictionary) {
        let sectionRegex = try! NSRegularExpression(
            pattern: #"^\s*\[providers\.(?:"([^"]+)"|([^"\]]+))\]\s*$"#,
            options: []
        )
        let apiKeyRegex = try! NSRegularExpression(
            pattern: #"^\s*api_key\s*=\s*"([^"]+)"\s*$"#,
            options: []
        )

        var currentSectionName: String?

        for line in content.components(separatedBy: .newlines) {
            let nsRange = NSRange(line.startIndex..., in: line)

            if let match = sectionRegex.firstMatch(in: line, options: [], range: nsRange) {
                let quoted = Range(match.range(at: 1), in: line).map { String(line[$0]) }
                let unquoted = Range(match.range(at: 2), in: line).map { String(line[$0]) }
                currentSectionName = quoted ?? unquoted
                continue
            }

            guard let sectionName = currentSectionName else { continue }

            if let match = apiKeyRegex.firstMatch(in: line, options: [], range: nsRange),
               let keyRange = Range(match.range(at: 1), in: line) {
                let apiKey = String(line[keyRange])
                guard !apiKey.isEmpty else { continue }

                let sectionLower = sectionName.lowercased()
                if sectionLower.contains("zhipu") || sectionLower.contains("glm") || sectionLower.contains("bigmodel") {
                    result["glmAPIKey"] = apiKey
                } else if sectionLower.contains("kimi"), apiKey.hasPrefix("sk-kimi-") {
                    result["kimiAPIKey"] = apiKey
                }
            }
        }
    }
}
