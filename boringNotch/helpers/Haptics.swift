//
//  Haptics.swift
//  boringNotch
//
//  刘海内点击触控板震动统一入口。
//  与 ContentView/BoringCalendar 现有的 .sensoryFeedback(.alignment) 同一震感，
//  由全局开关 Defaults[.enableHaptics] 控制（设置 → 通用 → Enable haptic feedback）。
//

import AppKit
import Defaults

enum Haptics {
    /// 在刘海内任意可点元素的点击处理里调用
    static func play() {
        guard Defaults[.enableHaptics] else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
