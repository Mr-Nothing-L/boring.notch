//
//  UsageDetailView.swift
//  boringNotch
//
//  Token tab 页：AI 用量详情 + 历史曲线。
//
//  【接口契约 — 并行开发约定】
//  - `UsageDetailView()`：由 ContentView tab switch 的 .token 分支渲染
//  - 每模型一张卡片（5h/周窗口详情、总额度备注、updatedAt、手动刷新）
//  - 历史曲线区：Swift Charts，蓝线=周用量%、绿线=5h 用量%
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
                UsageModelCard(model: usage.kimi, defaultName: "Kimi")
                UsageModelCard(model: usage.glm, defaultName: "GLM")

                historySection
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - 历史曲线

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("usage.history.title")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            if usage.history.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
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
                VStack(spacing: 12) {
                    UsageHistoryChart(
                        title: "Kimi",
                        data: usage.history,
                        fiveHourKey: \.kimi5h,
                        weeklyKey: \.kimiWeek
                    )

                    UsageHistoryChart(
                        title: "GLM",
                        data: usage.history,
                        fiveHourKey: \.glm5h,
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

// MARK: - 历史曲线

private struct UsageHistoryChart: View {
    let title: String
    let data: [UsageSnapshot]
    let fiveHourKey: KeyPath<UsageSnapshot, Double?>
    let weeklyKey: KeyPath<UsageSnapshot, Double?>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)

            Chart(data) { snapshot in
                if let week = snapshot[keyPath: weeklyKey] {
                    LineMark(
                        x: .value("usage.history.time", snapshot.t),
                        y: .value("usage.history.weekly", week)
                    )
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }

                if let five = snapshot[keyPath: fiveHourKey] {
                    LineMark(
                        x: .value("usage.history.time", snapshot.t),
                        y: .value("usage.history.fiveHour", five)
                    )
                    .foregroundStyle(.green)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            .chartYScale(domain: 0...100)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date, format: .dateTime.hour().minute())
                                .font(.system(size: 8))
                                .foregroundStyle(.gray)
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
            .frame(height: 90)
        }
    }
}

#Preview {
    UsageDetailView()
        .padding()
        .background(Color.black)
}
