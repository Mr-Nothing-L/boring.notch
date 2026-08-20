//
//  UsageRingsView.swift
//  boringNotch
//
//  闭合态刘海的 AI 用量双模型圆环（常驻拉长显示）。
//
//  【接口契约 — 并行开发约定】
//  - `UsageRingsView()`：由 ContentView 闭合态用量分支渲染
//    布局：[Kimi icon][蓝环·周][绿环·5h]  ←物理刘海→  [蓝环·周][绿环·5h][GLM icon]
//  - 数据读 UsageManager.shared（kimi / glm: ModelUsage?）
//  - 圆环显示剩余比例（随消耗缩短）：蓝=周用量、绿=5h 用量
//

import AppKit
import Defaults
import SwiftUI

struct UsageRingsView: View {
    @ObservedObject private var usage = UsageManager.shared
    @EnvironmentObject var vm: BoringViewModel

    var body: some View {
        HStack(spacing: 0) {
            // 左侧：Kimi（标尺实测：外壳底部鼓包仅 ~8pt/侧，占位 +16 即可避开）
            HStack(spacing: 7) {
                ModelIconView(model: .kimi, size: 20)

                UsageRingView(
                    label: String(localized: "usage.weekly.short"),
                    usedPct: usage.kimi?.weeklyUsedPct,
                    color: .blue
                )

                UsageRingView(
                    label: String(localized: "usage.fiveHour.short"),
                    usedPct: usage.kimi?.fiveHourUsedPct,
                    color: .green
                )
            }
            .padding(.leading, 12)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width + 16)

            // 右侧：GLM
            HStack(spacing: 7) {
                UsageRingView(
                    label: String(localized: "usage.weekly.short"),
                    usedPct: usage.glm?.weeklyUsedPct,
                    color: .blue
                )

                UsageRingView(
                    label: String(localized: "usage.fiveHour.short"),
                    usedPct: usage.glm?.fiveHourUsedPct,
                    color: .green
                )

                ModelIconView(model: .glm, size: 20)
            }
            .padding(.trailing, 12)
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
    }
}

// MARK: - 子组件

/// 单用量圆环：描边进度环显示剩余比例
private struct UsageRingView: View {
    let label: String
    let usedPct: Double?
    let color: Color

    private let diameter: CGFloat = 14
    private let lineWidth: CGFloat = 2.5

    private var remainingPct: Double {
        guard let used = usedPct else { return 1 }
        return max(0, min(1, 1 - used / 100))
    }

    var body: some View {
        ZStack {
            // strokeBorder 向内描边：stroke 会溢出 frame 约 lineWidth/2，
            // 溢出部分会被 HStack 中后绘制的黑色占位块盖住（曾误判为「被刘海啃掉」）
            Circle()
                .strokeBorder(color.opacity(0.45), lineWidth: lineWidth)

            if usedPct != nil {
                ArcShape(fraction: remainingPct)
                    .strokeBorder(
                        color,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
            } else {
                Text("--")
                    .font(.system(size: 6, weight: .medium))
                    .foregroundStyle(.gray)
            }
        }
        .frame(width: diameter, height: diameter)
        .help(label)
    }
}

/// 从 12 点方向开始的进度弧；实现 InsettableShape 以便使用 strokeBorder（全部绘制在 frame 内）
private struct ArcShape: InsettableShape {
    var fraction: Double // 0-1
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let radius = max(0, min(rect.width, rect.height) / 2 - inset)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        p.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(-90 + 360 * max(0, min(1, fraction))),
            clockwise: false
        )
        return p
    }

    func inset(by amount: CGFloat) -> ArcShape {
        var copy = self
        copy.inset += amount
        return copy
    }

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }
}

enum UsageModel {
    case kimi
    case glm

    var assetName: String {
        switch self {
        case .kimi: return "kimi-logo"
        case .glm: return "glm-logo"
        }
    }

    var fallbackLetter: String {
        switch self {
        case .kimi: return "K"
        case .glm: return "G"
        }
    }

    var brandColor: Color {
        switch self {
        case .kimi: return Color(red: 0.18, green: 0.55, blue: 1.0)
        case .glm: return Color(red: 0.35, green: 0.35, blue: 0.35)
        }
    }
}

/// 模型图标：优先使用 xcassets logo，失败则自绘兜底
struct ModelIconView: View {
    let model: UsageModel
    let size: CGFloat

    var body: some View {
        Group {
            if let nsImage = NSImage(named: model.assetName) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                FallbackIconView(model: model, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
    }
}

/// 兜底图标：圆角方块 + 字母
struct FallbackIconView: View {
    let model: UsageModel
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .fill(model.brandColor.opacity(0.25))

            Text(model.fallbackLetter)
                .font(.system(size: size * 0.55, weight: .bold))
                .foregroundStyle(model.brandColor)
        }
        .frame(width: size, height: size)
    }
}

#Preview {
    UsageRingsView()
        .environmentObject(BoringViewModel())
        .frame(width: 640, height: 38)
        .background(Color.black)
}
