//
//  NotificationPeekView.swift
//  boringNotch
//
//  通知在刘海区域的展示视图。
//
//  - `NotificationPeekView()`：闭合态刘海向下延展的通知行（在 NotchShape 裁切
//    内部，与刘海黑块视觉统一、无分隔），由 ContentView 闭合态分支使用；
//    点击直接跳转来源 app（AXPress 原横幅，失败回退激活 app）
//  - `NotificationsView()`：展开态的「通知」tab 页面，卡片列表展示活跃通知，
//    点击卡片跳转来源 app（AXPress 原横幅，失败回退激活 app）
//

import AppKit
import Defaults
import SwiftUI

/// app 图标缓存：按 bundleID 取一次 NSWorkspace 图标后复用
private final class NotificationIconCache {
    static let shared = NotificationIconCache()

    private var cache: [String: NSImage] = [:]

    func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        cache[bundleID] = icon
        return icon
    }
}

/// 通知来源 app 图标；bundleID 缺失时回退 SF Symbol
private struct NotificationIconView: View {
    let bundleID: String?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Group {
            if let nsImage = NotificationIconCache.shared.icon(for: bundleID) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "bell.badge")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.white)
                    .padding(size * 0.15)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - 闭合态：刘海向下延展的通知行

/// 第一行是物理刘海占位（保持原闭合态位置），第二行是通知内容；
/// 整体在 mainLayout 的 .background(.black).clipShape(NotchShape) 内部，
/// 视觉上就是刘海黑块向下长大，无分隔、圆角连续。
struct NotificationPeekView: View {
    @ObservedObject private var relay = NotificationRelayManager.shared
    @EnvironmentObject var vm: BoringViewModel

    var body: some View {
        if relay.peekVisible, let latest = relay.latest, vm.effectiveClosedNotchHeight > 0 {
            VStack(spacing: 0) {
                // 物理刘海占位行（原闭合态空行）
                Rectangle()
                    .fill(.black)
                    .frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)

                // 通知内容行（向下延展部分）
                Button {
                    Haptics.play()
                    relay.activate(latest)
                } label: {
                    HStack(spacing: 10) {
                        NotificationIconView(bundleID: latest.bundleID, size: 22, cornerRadius: 6)

                        Text(latest.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if !latest.body.isEmpty {
                            Text(latest.body)
                                .font(.system(size: 12))
                                .foregroundStyle(.gray)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }

                        if latest.count > 1 {
                            Text("×\(latest.count)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background { Capsule().fill(.red) }
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .onHover { hovering in
                    relay.isHoveringNotificationPeek = hovering
                    if hovering {
                        relay.pauseAutoDismiss()
                    } else {
                        relay.resumeAutoDismiss()
                    }
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
        }
    }
}

// MARK: - 展开态：通知 tab 卡片页

/// 单条通知卡片
private struct NotificationCard: View {
    let group: NotificationGroup

    var body: some View {
        HStack(spacing: 10) {
            NotificationIconView(bundleID: group.bundleID, size: 28, cornerRadius: 7)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(group.appName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.gray)
                    if group.count > 1 {
                        Text("×\(group.count)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .background { Capsule().fill(.red) }
                    }
                }
                Text(group.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !group.body.isEmpty {
                    Text(group.body)
                        .font(.caption)
                        .foregroundStyle(.gray)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 0)

            Text(group.latestAt, format: .dateTime.hour().minute())
                .font(.system(size: 10))
                .foregroundStyle(.gray)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.08))
        }
    }
}

/// 「通知」tab 页面：活跃通知的卡片列表
struct NotificationsView: View {
    @ObservedObject private var relay = NotificationRelayManager.shared

    var body: some View {
        Group {
            if relay.groups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bell.slash")
                        .font(.title2)
                        .foregroundStyle(.gray)
                    Text("No notifications")
                        .font(.subheadline)
                        .foregroundStyle(.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(relay.groups) { group in
                                Button {
                                    Haptics.play()
                                    relay.activate(group)
                                } label: {
                                    NotificationCard(group: group)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .transition(.move(edge: .top).combined(with: .opacity))
                            }
                        }
                        .padding(.horizontal, 4)
                        // 底部留出垃圾桶按钮的空间
                        .padding(.bottom, 36)
                        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: relay.groups)
                    }

                    // 清空全部通知
                    Button {
                        Haptics.play()
                        withAnimation(.smooth) {
                            relay.clearAll()
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.gray)
                            .frame(width: 30, height: 30)
                            .background {
                                Circle().fill(.white.opacity(0.1))
                            }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(8)
                }
            }
        }
        // 用户正在查看页面时暂停自动收起
        .onAppear { relay.pauseAutoDismiss() }
        .onDisappear { relay.resumeAutoDismiss() }
    }
}

#Preview {
    NotificationsView()
        .padding()
        .background(Color.black)
}
