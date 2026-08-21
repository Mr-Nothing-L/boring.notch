//
//  UsageDetailView.swift
//  boringNotch
//
//  Token tab 页：AI 用量详情 + 历史曲线。
//
//  【接口契约 — 并行开发约定】
//  - `UsageDetailView()`：由 ContentView tab switch 的 .token 分支渲染
//  - 每模型一张卡片（5h/周窗口详情、总额度备注、updatedAt、手动刷新），Kimi/GLM 横向并排等宽
//  - 历史柱状图区：Swift Charts 按天聚合（固定最近 7 天，无采样补 0），Kimi/GLM 并排，蓝柱=周用量%，
//    X 轴「M-d」短标签 45° 斜放，悬停仅改透明度 + overlay tooltip（不影响柱子几何布局）
//  - 数据读 UsageManager.shared（kimi / glm / history）
//

import Charts
import Defaults
import SwiftUI

struct UsageDetailView: View {
    @ObservedObject private var usage = UsageManager.shared

    var body: some View {
        Group {
            if usage.hasAnyConfig {
                contentView
            } else {
                emptyStateView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 已配置状态

    private var contentView: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    UsageModelCard(model: usage.kimi, defaultName: "Kimi")
                    UsageModelCard(model: usage.glm, defaultName: "GLM")
                }

                historySection
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - 历史柱状图

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("usage.history.title")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                Spacer(minLength: 0)

                Text("usage.history.last7days")
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
            }

            if usage.history.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.title2)
                        .foregroundStyle(.gray)
                    Text("usage.history.collecting")
                        .font(.subheadline)
                        .foregroundStyle(.gray)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(0.06))
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    UsageHistoryChart(
                        title: "Kimi",
                        data: usage.history,
                        weeklyKey: \.kimiWeek
                    )

                    UsageHistoryChart(
                        title: "GLM",
                        data: usage.history,
                        weeklyKey: \.glmWeek
                    )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.06))
        }
    }

    // MARK: - 未配置引导

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 36))
                .foregroundStyle(.gray)

            Text("usage.empty.title")
                .font(.headline)
                .foregroundStyle(.white)

            Text("usage.empty.message")
                .font(.subheadline)
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            Button {
                Haptics.play()
                SettingsWindowController.shared.showWindow()
            } label: {
                Text("usage.empty.openSettings")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background {
                        Capsule()
                            .fill(.white.opacity(0.12))
                    }
            }
            .buttonStyle(PlainButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 单模型卡片

private struct UsageModelCard: View {
    let model: ModelUsage?
    let defaultName: String

    private var displayName: String { model?.name ?? defaultName }
    private var modelType: UsageModel { displayName.lowercased().contains("glm") ? .glm : .kimi }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 头部：icon + 名称 + 套餐
            HStack(spacing: 10) {
                ModelIconView(model: modelType, size: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)

                    if let note = model?.membershipNote, !note.isEmpty {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.gray)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                refreshButton
            }

            Divider()
                .background(.white.opacity(0.1))

            // 5h 窗口
            UsageWindowRow(
                title: String(localized: "usage.fiveHour.title"),
                valueText: fiveHourValueText,
                usedPct: model?.fiveHourUsedPct,
                resetDate: model?.fiveHourReset,
                color: .green,
                showDateForReset: false
            )

            // 周窗口
            UsageWindowRow(
                title: String(localized: "usage.weekly.title"),
                valueText: weeklyValueText,
                usedPct: model?.weeklyUsedPct,
                resetDate: model?.weeklyReset,
                color: .blue,
                showDateForReset: true
            )

            // 总额度备注
            if let total = model?.totalNote, !total.isEmpty {
                HStack(spacing: 4) {
                    Text("usage.total.label")
                        .font(.caption)
                        .foregroundStyle(.gray)
                    Text(total)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }

            // 更新时间 / 错误
            HStack(spacing: 4) {
                if let error = model?.lastError, !error.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                } else if let updated = model?.updatedAt {
                    Text("usage.updatedAt \(updated, format: .dateTime)")
                        .font(.caption2)
                        .foregroundStyle(.gray)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.08))
        }
    }

    private var refreshButton: some View {
        Button {
            Haptics.play()
            UsageManager.shared.refresh()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.gray)
                .frame(width: 26, height: 26)
                .background {
                    Circle()
                        .fill(.white.opacity(0.08))
                }
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var fiveHourValueText: String {
        if let pct = model?.fiveHourUsedPct {
            return String(format: "%@ %d%%", String(localized: "usage.used.label"), Int(pct))
        }
        return String(localized: "usage.noData")
    }

    private var weeklyValueText: String {
        if let used = model?.weeklyUsed, let limit = model?.weeklyLimit {
            return "\(used) / \(limit)"
        }
        if let pct = model?.weeklyUsedPct {
            return String(format: "%@ %d%%", String(localized: "usage.used.label"), Int(pct))
        }
        return String(localized: "usage.noData")
    }
}

// MARK: - 单窗口行

private struct UsageWindowRow: View {
    let title: String
    let valueText: String
    let usedPct: Double?
    let resetDate: Date?
    let color: Color
    let showDateForReset: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.gray)

                Spacer(minLength: 0)

                Text(valueText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)

                if let reset = resetDate {
                    let resetFormat: Date.FormatStyle = showDateForReset
                        ? .dateTime.month(.abbreviated).day().hour().minute()
                        : .dateTime.hour().minute()
                    Text("usage.resets \(reset, format: resetFormat)")
                        .font(.system(size: 10))
                        .foregroundStyle(.gray)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.1))
                        .frame(height: 4)

                    if let pct = usedPct {
                        Capsule()
                            .fill(color)
                            .frame(width: max(0, geo.size.width * CGFloat(pct) / 100), height: 4)
                    }
                }
            }
            .frame(height: 4)
        }
    }
}

// MARK: - 历史柱状图

/// 按天聚合后的数据点（固定最近 7 天，无采样的天 value = 0）
private struct DailyUsagePoint: Identifiable {
    var id: Date { day }
    let day: Date
    var value: Double = 0
}

private struct UsageHistoryChart: View {
    let title: String
    let data: [UsageSnapshot]
    let weeklyKey: KeyPath<UsageSnapshot, Double?>

    @State private var selectedDay: Date?

    /// 固定最近 7 天日期桶；每天取当天最后一次非空 weekly 采样，无采样为 0
    private var dailyPoints: [DailyUsagePoint] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var points = (0 ... 6).map { offset -> DailyUsagePoint in
            let day = calendar.date(byAdding: .day, value: offset - 6, to: today) ?? today
            return DailyUsagePoint(day: day)
        }
        let indexByDay = Dictionary(uniqueKeysWithValues: points.enumerated().map { ($1.day, $0) })
        for snapshot in data where snapshot.t >= points[0].day {
            let day = calendar.startOfDay(for: snapshot.t)
            guard let index = indexByDay[day],
                  let value = snapshot[keyPath: weeklyKey] else { continue }
            points[index].value = value
        }
        return points
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)

            Chart(dailyPoints) { point in
                BarMark(
                    x: .value("usage.history.day", point.day, unit: .day),
                    y: .value("usage.history.weekly", point.value)
                )
                .foregroundStyle(.blue)
                .opacity(selectedDay == nil || selectedDay == point.day ? 1.0 : 0.35)
            }
            .chartYScale(domain: 0 ... 100)
            .chartXAxis {
                AxisMarks(values: dailyPoints.map(\.day)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            let parts = Calendar.current.dateComponents([.month, .day], from: date)
                            Text("\(parts.month ?? 0)-\(parts.day ?? 0)")
                                .font(.system(size: 8))
                                .foregroundStyle(.gray)
                                .fixedSize()
                                .rotationEffect(.degrees(-45), anchor: .topTrailing)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisValueLabel {
                        if let pct = value.as(Double.self) {
                            Text("\(Int(pct))%")
                                .font(.system(size: 8))
                                .foregroundStyle(.gray)
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let plotAnchor = proxy.plotFrame else { return }
                                let plotOrigin = geo[plotAnchor].origin
                                if let date: Date = proxy.value(atX: location.x - plotOrigin.x) {
                                    let calendar = Calendar.current
                                    selectedDay = calendar.startOfDay(for: date)
                                }
                            case .ended:
                                selectedDay = nil
                            }
                        }

                    // tooltip 用 overlay + .position 覆盖定位，不参与 chart 布局，柱子几何保持不动
                    if let selectedDay,
                       let point = dailyPoints.first(where: { $0.day == selectedDay }),
                       let plotAnchor = proxy.plotFrame,
                       let x = proxy.position(forX: selectedDay) {
                        let plotOrigin = geo[plotAnchor].origin
                        Text("\(selectedDay, format: .dateTime.month().day()) \(Int(point.value))%")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background {
                                Capsule()
                                    .fill(.black.opacity(0.85))
                            }
                            .fixedSize()
                            .position(x: plotOrigin.x + x, y: max(plotOrigin.y - 10, 8))
                    }
                }
            }
            .animation(.easeInOut(duration: 0.15), value: selectedDay)
            .frame(height: 90)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    UsageDetailView()
        .padding()
        .background(Color.black)
}
