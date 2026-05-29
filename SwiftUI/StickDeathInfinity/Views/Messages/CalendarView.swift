import SwiftUI

struct CalendarEventView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedDay: Int
    
    struct CalendarEvent: Identifiable {
        let id = UUID()
        let day: Int
        let title: String
        let time: String
        let color: Color
    }
    
    let events: [CalendarEvent]
    let today = Calendar.current.component(.day, from: Date())
    
    init() {
        let t = Calendar.current.component(.day, from: Date())
        _selectedDay = State(initialValue: t)
        events = [
            CalendarEvent(day: t, title: "War Room Battle", time: "3:00 PM", color: .red),
            CalendarEvent(day: t + 1, title: "Collab: Epic Duel", time: "11:00 AM", color: .purple),
            CalendarEvent(day: t + 2, title: "Speed Run Challenge", time: "5:00 PM", color: .orange),
            CalendarEvent(day: t + 5, title: "Creator Session", time: "2:00 PM", color: .green),
        ]
    }
    
    var daysInMonth: Int {
        let range = Calendar.current.range(of: .day, in: .month, for: Date())!
        return range.count
    }
    
    var firstDayOfWeek: Int {
        var components = Calendar.current.dateComponents([.year, .month], from: Date())
        components.day = 1
        let firstDay = Calendar.current.date(from: components)!
        return Calendar.current.component(.weekday, from: firstDay) - 1
    }
    
    var monthName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: Date())
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("📅 \(monthName)")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding()
            .background(Color(hex: "0A0A14"))
            
            // Calendar grid
            VStack(spacing: 2) {
                // Day headers
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7)) {
                    ForEach(["S","M","T","W","T","F","S"], id: \.self) { day in
                        Text(day)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                
                // Day cells
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 4) {
                    // Empty cells for offset
                    ForEach(0..<firstDayOfWeek, id: \.self) { _ in
                        Text("").frame(height: 36)
                    }
                    // Day cells
                    ForEach(1...daysInMonth, id: \.self) { day in
                        let hasEvent = events.contains { $0.day == day }
                        let isToday = day == today
                        let isSelected = day == selectedDay
                        
                        Button(action: { selectedDay = day }) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isSelected ? Color.red : (isToday ? Color.red.opacity(0.2) : Color.clear))
                                VStack(spacing: 1) {
                                    Text("\(day)")
                                        .font(.system(size: 12, weight: isToday ? .bold : .regular))
                                        .foregroundColor(isSelected ? .white : (isToday ? .red : .white))
                                    if hasEvent {
                                        Circle()
                                            .fill(isSelected ? .white : .red)
                                            .frame(width: 4, height: 4)
                                    }
                                }
                            }
                            .frame(height: 36)
                        }
                    }
                }
            }
            .padding()
            
            // Events for selected day
            VStack(alignment: .leading, spacing: 8) {
                Text("EVENTS")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                    .tracking(2)
                
                let dayEvents = events.filter { $0.day == selectedDay }
                if dayEvents.isEmpty {
                    Text("No events on this day")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                } else {
                    ForEach(dayEvents) { event in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(event.color)
                                .frame(width: 4, height: 36)
                            VStack(alignment: .leading) {
                                Text(event.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                                Text(event.time)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding()
            
            Spacer()
        }
        .background(Color(hex: "0A0A14"))
    }
}
