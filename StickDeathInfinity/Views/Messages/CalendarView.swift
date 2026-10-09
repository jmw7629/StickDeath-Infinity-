import SwiftUI

/// Calendar contains only schedules returned for the current account. No demo
/// events, inferred room membership, invitations, or outbound notifications.
struct CalendarEventView: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("sdi.calendar.selectedDate") private var savedDate = Date().timeIntervalSince1970
    @State private var month = Date()
    @State private var selectedDate = Date()
    @State private var events: [ScheduledChallenge] = []
    @State private var loading = false
    @State private var error: String?
    @State private var invalidSchedules = 0
    @State private var detail: Challenge?
    @State private var request = UUID()
    @State private var refreshRevision = 0

    private var calendar: Calendar { Calendar.autoupdatingCurrent }
    private var accountKey: String { "\(auth.isAuthenticated):\(auth.userId ?? "guest"):\(refreshRevision)" }
    private var monthStart: Date {
        calendar.dateInterval(of: .month, for: month)?.start ?? month
    }
    private var dates: [Date] {
        guard let range = calendar.range(of: .day, in: .month, for: monthStart) else { return [] }
        return range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: monthStart) }
    }
    private var offset: Int {
        (calendar.component(.weekday, from: monthStart) - calendar.firstWeekday + 7) % 7
    }
    private var weekdays: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7] }
    }
    private var selectedEvents: [ScheduledChallenge] { events.filter { $0.overlaps(selectedDate, calendar: calendar) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Button { moveMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                        .accessibilityLabel("Previous month")
                    Spacer()
                    Text(month.formatted(.dateTime.month(.wide).year())).font(.specialElite(19))
                    Spacer()
                    Button { moveMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                        .accessibilityLabel("Next month")
                }
                HStack {
                    Text(TimeZone.autoupdatingCurrent.identifier).font(.caption).foregroundColor(.sdTextSecondary)
                    Spacer()
                    Button("Today") { select(Date()); month = Date() }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
                    ForEach(0..<7, id: \.self) { index in
                        Text(weekdays[index]).font(.caption).foregroundColor(.sdTextSecondary)
                    }
                    ForEach(0..<offset, id: \.self) { _ in Color.clear.frame(height: 44) }
                    ForEach(dates, id: \.self) { date in
                        Button { select(date) } label: {
                            VStack(spacing: 3) {
                                Text(String(calendar.component(.day, from: date)))
                                    .font(.specialElite(15))
                                Circle().fill(events.contains { $0.overlaps(date, calendar: calendar) } ? Color.sdRed : .clear)
                                    .frame(width: 4, height: 4)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(calendar.isDate(date, inSameDayAs: selectedDate) ? Color.sdRed.opacity(0.3) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(calendar.isDateInToday(date) ? Color.sdRed : .clear))
                        }
                        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
                        .accessibilityAddTraits(calendar.isDate(date, inSameDayAs: selectedDate) ? .isSelected : [])
                    }
                }
                Text(selectedDate.formatted(date: .complete, time: .omitted)).font(.specialElite(17))
                if !auth.isAuthenticated {
                    Label("Sign in to see your available schedules.", systemImage: "lock")
                } else if loading {
                    ProgressView("Loading schedules…")
                } else if let error {
                    Text(error).foregroundColor(.sdTextSecondary)
                    Button("Retry") { refreshRevision += 1 }
                } else if selectedEvents.isEmpty {
                    Text("No scheduled challenges on this day.").foregroundColor(.sdTextSecondary)
                }
                ForEach(selectedEvents) { event in
                    Button { detail = event.challenge } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(event.challenge.title).font(.specialElite(18))
                            Label("Challenge", systemImage: "flag.checkered").font(.caption)
                            Text("Starts \(event.start.formatted(date: .abbreviated, time: .shortened))")
                            if let end = event.end { Text("Ends \(end.formatted(date: .abbreviated, time: .shortened))") }
                        }
                        .foregroundColor(.sdTextPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        .background(Color.sdSurface).clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
                if invalidSchedules > 0 {
                    Text("\(invalidSchedules) challenge schedules have missing or invalid dates and cannot be placed on the calendar.")
                        .font(.caption).foregroundColor(.sdTextSecondary)
                }
                Text("Room and War Room schedules will appear when their scheduling services are connected. Calendar does not send invitations or notifications.")
                    .font(.caption).foregroundColor(.sdTextSecondary)
            }
            .padding(16).padding(.bottom, 60)
        }
        .foregroundColor(.sdTextPrimary)
        .background(Color.sdBackground.ignoresSafeArea())
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear {
            let restored = Date(timeIntervalSince1970: savedDate)
            if savedDate.isFinite, (1900...2200).contains(calendar.component(.year, from: restored)) {
                selectedDate = restored; month = restored
            }
        }
        .task(id: accountKey) { await load() }
        .refreshable { await load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshRevision += 1 }
            else { request = UUID(); events = []; detail = nil }
        }
        .sheet(item: $detail) { ChallengeDetailView(challenge: $0) }
        .accessibilityIdentifier("calendar.screen")
    }

    private func select(_ date: Date) {
        selectedDate = date; savedDate = date.timeIntervalSince1970
    }
    private func moveMonth(_ delta: Int) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: monthStart),
              (1900...2200).contains(calendar.component(.year, from: next)) else { return }
        month = next; select(next)
    }
    @MainActor private func load() async {
        let token = UUID(); request = token
        events = []; detail = nil; error = nil; invalidSchedules = 0; loading = false
        guard auth.isAuthenticated, let account = auth.userId else { return }
        loading = true
        defer { if request == token { loading = false } }
        do {
            let values = try await ChallengeService.shared.fetchChallenges()
            guard !Task.isCancelled, request == token, auth.isAuthenticated, auth.userId == account else { return }
            var unique: [Int: ScheduledChallenge] = [:]
            for challenge in values {
                if let event = ScheduledChallenge(challenge) { unique[event.id] = event }
                else { invalidSchedules += 1 }
            }
            events = unique.values.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        } catch {
            guard !Task.isCancelled, request == token, auth.userId == account else { return }
            self.error = "Schedules are unavailable. Check your connection and account configuration, then retry."
        }
    }
}

private struct ScheduledChallenge: Identifiable {
    var id: Int { challenge.id }
    let challenge: Challenge
    let start: Date
    let end: Date?

    init?(_ challenge: Challenge) {
        guard let start = Self.parse(challenge.startDate) else { return nil }
        let end = Self.parse(challenge.endDate)
        if challenge.endDate != nil && end == nil { return nil }
        if let end, end < start { return nil }
        self.challenge = challenge; self.start = start; self.end = end
    }
    func overlaps(_ date: Date, calendar: Calendar) -> Bool {
        guard let day = calendar.dateInterval(of: .day, for: date) else { return false }
        if let end, end > start { return start < day.end && end > day.start }
        return calendar.isDate(start, inSameDayAs: date)
    }
    private static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
