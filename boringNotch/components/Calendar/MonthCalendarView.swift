//
//  MonthCalendarView.swift
//  boringNotch
//
//  月历视图（日历样式设置可切换：周视图 Wheel / 月历 Month）。
//
//  【接口契约 — 并行开发约定】
//  - `MonthCalendarView(selectedDate: Binding<Date>)`：月历格子视图，
//    由 BoringCalendar.swift 的 CalendarView 在 Defaults[.calendarViewStyle] == .month 时渲染
//  - 顶部 M月｜农历 + 年份；星期行随系统 locale；6×7 月格子；
//    今天用 Color.effectiveAccent 圆形高亮；非本月日期淡化
//  - 点某天更新 selectedDate，由调用方触发 calendarManager.updateCurrentDate
//

import Defaults
import SwiftUI

struct MonthCalendarView: View {
    @Binding var selectedDate: Date
    @State private var hasAppeared = false

    private var calendar: Calendar { Calendar.current }

    /// 被选中日期所在的月份（格子展示跟随 selectedDate）
    private var displayedMonth: Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: selectedDate))
            ?? selectedDate
    }

    /// 星期行：shortWeekdaySymbols 固定从周日开始，按 firstWeekday 旋转对齐
    private var weekdaySymbols: [String] {
        let symbols = calendar.shortWeekdaySymbols
        let offset = calendar.firstWeekday - 1
        return Array(symbols[offset...] + symbols[..<offset])
    }

    /// 42 个格子（6 行×7 列）对应的日期；nil 仅兜底，正常不会为空
    private var gridDates: [Date?] {
        let monthStart = displayedMonth
        let firstWeekday = calendar.component(.weekday, from: monthStart)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        return (0..<42).map { index in
            calendar.date(byAdding: .day, value: index - leading, to: monthStart)
        }
    }

    private var lunarText: String {
        let chinese = Calendar(identifier: .chinese)
        let components = chinese.dateComponents([.month, .day], from: selectedDate)
        guard let month = components.month, let day = components.day else { return "" }
        let months = ["正月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "冬月", "腊月"]
        let days = [
            "初一", "初二", "初三", "初四", "初五", "初六", "初七", "初八", "初九", "初十",
            "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九", "二十",
            "廿一", "廿二", "廿三", "廿四", "廿五", "廿六", "廿七", "廿八", "廿九", "三十",
        ]
        let monthName = months[min(max(month - 1, 0), months.count - 1)]
        let dayName = days[min(max(day - 1, 0), days.count - 1)]
        // 初一显示月份名，与系统日历习惯一致
        return day == 1 ? monthName : dayName
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(displayedMonth.formatted(.dateTime.month(.wide)))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                Text("｜")
                    .font(.caption2)
                    .foregroundColor(Color(white: 0.65))
                Text(lunarText)
                    .font(.caption2)
                    .foregroundColor(Color(white: 0.65))
                Spacer()
                Text(displayedMonth.formatted(.dateTime.year()))
                    .font(.caption)
                    .fontWeight(.light)
                    .foregroundColor(Color(white: 0.65))
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 1) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 8))
                        .foregroundColor(Color(white: 0.65))
                        .frame(height: 10)
                }

                ForEach(0..<42, id: \.self) { index in
                    if let date = gridDates[index] {
                        dayCell(date: date)
                    } else {
                        Color.clear.frame(height: 14)
                    }
                }
            }
        }
        // 整体在其可用区域内垂直居中，避免贴顶被物理刘海/摄像头遮挡
        .frame(maxHeight: .infinity, alignment: .center)
        // 登场动画：与音乐播放器一致，从上方滑入并淡入
        .offset(y: hasAppeared ? 0 : -12)
        .opacity(hasAppeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.35)) {
                hasAppeared = true
            }
        }
    }

    private func dayCell(date: Date) -> some View {
        let isToday = calendar.isDateInToday(date)
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isInMonth = calendar.isDate(date, equalTo: displayedMonth, toGranularity: .month)

        return Button {
            Haptics.play()
            selectedDate = date
        } label: {
            ZStack {
                Circle()
                    .fill(isToday ? Color.effectiveAccent : (isSelected ? Color.effectiveAccentBackground : .clear))
                    .frame(width: 13, height: 13)
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 8, weight: isToday || isSelected ? .semibold : .regular))
                    .foregroundColor(
                        isToday || isSelected
                            ? .white
                            : Color(white: 0.65).opacity(isInMonth ? 1.0 : 0.35)
                    )
            }
            .frame(maxWidth: .infinity)
            .frame(height: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

#Preview {
    MonthCalendarView(selectedDate: .constant(Date()))
        .frame(width: 215)
        .background(.black)
}
