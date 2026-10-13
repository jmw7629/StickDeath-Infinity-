import SwiftUI

/// Calendar shows only schedules the server returns for the current account
/// through `sdi_calendar_range`: challenge milestones and the member's own
/// War Room deadlines. Only the visible month is fetched; a protected
/// per-account cache backs the "Offline · last updated" state. No demo
/// events, invitations, notifications or contact access.
struct CalendarEventView: View {
    @ObservedObject private var auth = AuthService.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("sdi.calendar.selectedDate") private var savedDate = Date().timeIntervalSince1970
    @State private var month = Date()
    @State private var selectedDate = Date()
    @State private var placement: CalendarMonthPlacement?
    @State private var loading = false
    @State private var error: String?
    /// Set when the shown schedules came from the per-account cache, not the server.
    @State private var offlineUpdatedAt: Date?
    @State private var truncated = false
    @State private var detail: CalendarItem?
    @State private var request = UUID()
    @State private var refreshRevision = 0
    @State private var calendar = Calendar.current
    @State private var today = Date()

    private var accountKey: String {
        "\(auth.isAuthenticated):\(auth.userId ?? "guest"):\(refreshRevision):\(CalendarMonthPlacement.monthKey(monthStart, calendar: calendar))"
    }
    private var monthStart: Date { calendar.dateInterval(of: .month, for: month)?.start ?? month }
    private var dates: [Date] {
        guard let range = calendar.range(of: .day, in: .month, for: monthStart) else { return [] }
        return range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: monthStart) }
    }
    private var offset: Int { (calendar.component(.weekday, from: monthStart) - calendar.firstWeekday + 7) % 7 }
    private var weekdays: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7] }
    }
    private var selectedItems: [CalendarItem] { placement?.items(on: selectedDate, calendar: calendar) ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Button { moveMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                        .accessibilityLabel("Previous month").accessibilityIdentifier("calendar.prev-month")
                    Spacer()
                    Text(month.formatted(.dateTime.month(.wide).year())).font(.specialElite(19, relativeTo: .title3))
                    Spacer()
                    Button { moveMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                        .accessibilityLabel("Next month").accessibilityIdentifier("calendar.next-month")
                }
                HStack {
                    Text(calendar.timeZone.identifier).communityCaption()
                    Spacer()
                    Button("Today") { select(Date()); month = Date() }
                        .buttonStyle(CommunitySecondaryButtonStyle()).accessibilityIdentifier("calendar.today")
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
                    ForEach(0..<7, id: \.self) { index in
                        Text(weekdays[index]).communityCaption()
                    }
                    ForEach(0..<offset, id: \.self) { _ in Color.clear.frame(height: 44) }
                    ForEach(dates, id: \.self) { date in
                        Button { select(date) } label: {
                            VStack(spacing: 3) {
                                Text(String(calendar.component(.day, from: date))).font(.specialElite(15, relativeTo: .body))
                                Circle().fill(placement?.hasItems(on: date, calendar: calendar) == true ? StudioCraftTheme.accent : .clear)
                                    .frame(width: 4, height: 4)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(calendar.isDate(date, inSameDayAs: selectedDate) ? StudioCraftTheme.accentSoft : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: StudioCraftTheme.radius))
                            .overlay(RoundedRectangle(cornerRadius: StudioCraftTheme.radius).stroke(calendar.isDate(date, inSameDayAs: today) ? StudioCraftTheme.accent : .clear))
                        }
                        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
                        .accessibilityValue(placement?.hasItems(on: date, calendar: calendar) == true ? "Has scheduled items" : "")
                        .accessibilityAddTraits(calendar.isDate(date, inSameDayAs: selectedDate) ? .isSelected : [])
                    }
                }
                Text(selectedDate.formatted(date: .complete, time: .omitted)).font(.specialElite(17, relativeTo: .headline))
                if !CommunityServices.isConfigured { CommunityMessage(text: CommunityServices.notConfiguredText, kind: .info) }
                if !auth.isAuthenticated {
                    CommunitySignInPrompt(text: "Sign in to see your available schedules.", identifier: "calendar.sign-in")
                } else if loading {
                    ProgressView("Loading schedules…").tint(StudioCraftTheme.accent)
                } else if let error {
                    CommunityMessage(text: error, kind: .error).accessibilityIdentifier("calendar.error")
                    Button("Retry") { refreshRevision += 1 }
                        .buttonStyle(CommunitySecondaryButtonStyle()).accessibilityIdentifier("calendar.retry")
                }
                if let offlineUpdatedAt {
                    CommunityMessage(text: "Offline · last updated \(offlineUpdatedAt.formatted(date: .abbreviated, time: .shortened))", kind: .offline)
                        .accessibilityIdentifier("calendar.offline")
                }
                if truncated {
                    Text("More than 500 scheduled items exist this month; only the first 500 are shown.").communityCaption()
                }
                if auth.isAuthenticated && !loading && selectedItems.isEmpty && (error == nil || offlineUpdatedAt != nil) {
                    Text("No scheduled items on this day.").communityCaption().accessibilityIdentifier("calendar.day.empty")
                }
                ForEach(selectedItems) { item in
                    Button { detail = item } label: {
                        CommunityCard {
                            Text(item.title).font(.specialElite(18, relativeTo: .title3)).foregroundStyle(StudioCraftTheme.text)
                            Label(item.kindText, systemImage: item.kind == "war_match" ? "flag.checkered" : "trophy").communityCaption()
                            Text("\(item.milestoneText) at \(item.occurs_at.formatted(date: .omitted, time: .shortened))").font(.specialElite(14, relativeTo: .body)).foregroundStyle(StudioCraftTheme.text)
                            Text("Status: \(item.status)").communityCaption()
                        }
                    }.buttonStyle(.plain).accessibilityIdentifier("calendar.item")
                }
                Text("Calendar lists server schedules only. It does not create events, send invitations or notifications, or read device contacts.")
                    .communityCaption()
            }
            .padding(16).padding(.bottom, 60)
        }
        .communityScreen()
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear {
            refreshCalendarClock()
            let restored = Date(timeIntervalSince1970: savedDate)
            if savedDate.isFinite, (1900...2200).contains(calendar.component(.year, from: restored)) {
                selectedDate = restored; month = restored
            }
        }
        .task(id: accountKey) { await load() }
        .refreshable { await load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshCalendarClock(); refreshRevision += 1 }
            else { request = UUID(); placement = nil; detail = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in refreshCalendarClock() }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refreshCalendarClock() }
        .sheet(item: $detail) { CalendarItemDetailView(item: $0) }
        .accessibilityIdentifier("calendar.screen")
    }

    /// System clock changes invalidate day boundaries and markers. Keep the
    /// chosen civil date rather than shifting it when crossing time zones;
    /// server timestamps remain absolute instants.
    private func refreshCalendarClock() {
        let updated = Calendar.current
        if updated.identifier == calendar.identifier && updated.timeZone != calendar.timeZone {
            let chosenDay = calendar.dateComponents([.era, .year, .month, .day], from: selectedDate)
            let shownMonth = calendar.dateComponents([.era, .year, .month], from: month)
            if let value = updated.date(from: chosenDay) { selectedDate = value; savedDate = value.timeIntervalSince1970 }
            if let value = updated.date(from: shownMonth) { month = value }
        }
        calendar = updated
        today = Date()
    }
    private func select(_ date: Date) { selectedDate = date; savedDate = date.timeIntervalSince1970 }
    private func moveMonth(_ delta: Int) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: monthStart),
              (1900...2200).contains(calendar.component(.year, from: next)) else { return }
        month = next; select(next)
    }
    @MainActor private func load() async {
        let token = UUID(); request = token
        placement = nil; detail = nil; error = nil; loading = false; offlineUpdatedAt = nil; truncated = false
        guard auth.isAuthenticated, let account = auth.userId else { return }
        loading = true
        defer { if request == token { loading = false } }
        do {
            let result = try await CommunityServices.calendar.month(containing: monthStart, calendar: calendar, account: account)
            guard !Task.isCancelled, request == token, auth.isAuthenticated, auth.userId == account else { return }
            placement = result.placement; truncated = result.truncated
            if case .cache(let updatedAt) = result.source { offlineUpdatedAt = updatedAt }
        } catch {
            guard !Task.isCancelled, request == token, auth.userId == account else { return }
            self.error = CommunityGateway.normalize(error).errorDescription
        }
    }
}

/// Milestone details plus a truthful route to the challenge when it is still listed.
private struct CalendarItemDetailView: View {
    let item: CalendarItem
    @Environment(\.dismiss) private var dismiss
    @State private var found: ChallengeSummary?
    @State private var presented: ChallengeSummary?
    @State private var clock: ChallengeClock?
    @State private var lookup: String?
    @State private var busy = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(item.title).communityHeading()
                    Text("\(item.kindText) · \(item.milestoneText)").font(.specialElite(15, relativeTo: .body))
                    Text(item.occurs_at.formatted(date: .complete, time: .shortened)).font(.specialElite(14, relativeTo: .body))
                    Text("Status: \(item.status)").communityCaption()
                    if item.kind == "challenge" {
                        if busy { ProgressView().tint(StudioCraftTheme.accent) }
                        if let lookup { CommunityMessage(text: lookup, kind: .info) }
                        if let found {
                            Button("Open challenge") { presented = found }
                                .buttonStyle(CommunityPrimaryButtonStyle())
                                .accessibilityIdentifier("calendar.item.open-challenge")
                        }
                    } else {
                        Text("Open War Room from Rooms to see this matchup.").communityCaption()
                    }
                    Text("Calendar cannot edit or cancel schedules: challenges are scheduled by moderators and matchups close on the server.").communityCaption()
                }.padding(16)
            }
            .communityScreen()
            .navigationTitle("Schedule item").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $presented) { ChallengeDetailView(challenge: $0, clock: clock) }
            .task {
                guard item.kind == "challenge" else { return }
                busy = true; defer { busy = false }
                do {
                    let listing = try await CommunityServices.challenges.list()
                    if let match = listing.challenges.first(where: { $0.id == item.recordID }) { clock = listing.clock; found = match }
                    else { lookup = "This challenge is no longer listed (cancelled or older than 30 days)." }
                } catch { lookup = CommunityGateway.normalize(error).errorDescription }
            }
        }.preferredColorScheme(.dark)
    }
}

/// Internal (not private) so the native unit tests can exercise day-overlap
/// arithmetic across daylight-saving transitions with the production code.
/// Retained for legacy `challenges`-table schedules; the Calendar screen now
/// places `CalendarItem` milestones through `CalendarMonthPlacement`.
struct ScheduledChallenge: Identifiable {
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
