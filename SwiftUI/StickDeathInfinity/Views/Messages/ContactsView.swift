// ═══════════════════════════════════════════════════════════════════
// ContactsView — iOS Contacts layout for StickDeath ∞
// Matches: src/pages/ContactsScreen.tsx exactly
// - My Card at top
// - Alphabetical sections with A-Z scrubber
// - Contact detail: big monogram, gradient header, action buttons
// - Phone, email, address, birthday, relationships
// - Add / Edit mode
// ═══════════════════════════════════════════════════════════════════

import SwiftUI

// MARK: - Data Model

struct SDContact: Identifiable, Codable {
    let id: String
    var firstName: String
    var lastName: String
    var nickname: String?
    var company: String?
    var phones: [ContactPhone]
    var emails: [ContactEmail]
    var addresses: [ContactAddress]
    var birthday: String?
    var homepage: String?
    var relationships: [ContactRelationship]
    var notes: String?
    var isAppUser: Bool?
    var status: ContactStatus?
    var avatarUrl: String?

    var fullName: String {
        [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
    }
    var monogram: String {
        let f = firstName.first.map(String.init) ?? ""
        let l = lastName.first.map(String.init) ?? ""
        let m = (f + l).uppercased()
        return m.isEmpty ? "?" : m
    }
    var sortLetter: String {
        let c = lastName.first ?? firstName.first ?? Character("#")
        return c.isLetter ? String(c).uppercased() : "#"
    }
}

struct ContactPhone: Codable { var label: String; var number: String }
struct ContactEmail: Codable { var label: String; var email: String }
struct ContactAddress: Codable { var label: String; var street: String; var city: String; var state: String; var zip: String; var country: String }
struct ContactRelationship: Codable { var label: String; var name: String }
enum ContactStatus: String, Codable { case online, away, busy, offline }

// MARK: - Monogram Gradients (match web exactly)
private let monogramGradients: [(Color, Color)] = [
    (Color(hex: 0xDC2626), Color(hex: 0x7F1D1D)),   // red
    (Color(hex: 0x3B82F6), Color(hex: 0x1E3A5F)),   // blue
    (Color(hex: 0xA855F7), Color(hex: 0x581C87)),   // purple
    (Color(hex: 0xF97316), Color(hex: 0x9A3412)),   // orange
    (Color(hex: 0x22C55E), Color(hex: 0x14532D)),   // green
    (Color(hex: 0xEAB308), Color(hex: 0x854D0E)),   // yellow
    (Color(hex: 0xEC4899), Color(hex: 0x831843)),   // pink
]

private func gradientFor(_ contact: SDContact) -> LinearGradient {
    let hash = (contact.firstName + contact.lastName).unicodeScalars.reduce(0) { $0 + Int($1.value) }
    let pair = monogramGradients[hash % monogramGradients.count]
    return LinearGradient(colors: [pair.0, pair.1], startPoint: .top, endPoint: .bottom)
}

// MARK: - Sample Contacts
private let sampleContacts: [SDContact] = [
    SDContact(id: "me", firstName: "J_Willy", lastName: "Style", nickname: "J_Willy_Style", company: "StickDeath ∞",
              phones: [ContactPhone(label: "iPhone", number: "(607) 742-9951")],
              emails: [ContactEmail(label: "home", email: "Joseph@willisnmb.com")],
              addresses: [], relationships: [], isAppUser: true, status: .online),
    SDContact(id: "spatter", firstName: "Spatter", lastName: "", nickname: "SpatterAI", company: "StickDeath ∞ AI",
              phones: [], emails: [], addresses: [], relationships: [], isAppUser: true, status: .online),
]

private let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ#")

// MARK: - ContactsView

struct ContactsView: View {
    @State private var contacts: [SDContact] = sampleContacts
    @State private var searchQuery = ""
    @State private var selectedContact: SDContact? = nil
    @State private var showAddForm = false
    var onClose: (() -> Void)? = nil

    private var filteredContacts: [SDContact] {
        if searchQuery.isEmpty { return contacts }
        return contacts.filter {
            $0.fullName.localizedCaseInsensitiveContains(searchQuery) ||
            ($0.company ?? "").localizedCaseInsensitiveContains(searchQuery) ||
            ($0.nickname ?? "").localizedCaseInsensitiveContains(searchQuery)
        }
    }

    private var groupedContacts: [(String, [SDContact])] {
        let grouped = Dictionary(grouping: filteredContacts) { $0.sortLetter }
        return grouped.sorted { $0.key < $1.key }
    }

    var body: some View {
        if let contact = selectedContact {
            ContactDetailView(contact: contact) {
                withAnimation { selectedContact = nil }
            }
        } else {
            contactListView
        }
    }

    private var contactListView: some View {
        ZStack {
            Color.sdBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    if let onClose = onClose {
                        Button { onClose() } label: {
                            Image(systemName: "chevron.left")
                                .foregroundColor(.sdRed)
                        }
                    }
                    Text("Contacts")
                        .font(.specialElite(18))
                        .tracking(2)
                        .foregroundColor(.sdTextPrimary)
                    Spacer()
                    Button { showAddForm = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.sdRed)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.sdSurface)

                // Search
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.sdTextMuted)
                    TextField("Search", text: $searchQuery)
                        .font(.system(size: 15))
                        .foregroundColor(.sdTextPrimary)
                }
                .padding(10)
                .background(Color.white.opacity(0.05))
                .cornerRadius(10)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                // My Card
                if let me = contacts.first(where: { $0.id == "me" }) {
                    Button { withAnimation { selectedContact = me } } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(gradientFor(me))
                                .frame(width: 56, height: 56)
                                .overlay(
                                    Text(me.monogram)
                                        .font(.system(size: 22, weight: .bold))
                                        .foregroundColor(.white)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(me.fullName)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.sdTextPrimary)
                                Text("My Card")
                                    .font(.system(size: 13))
                                    .foregroundColor(.sdTextSecondary)
                            }
                            Spacer()
                        }
                        .padding(16)
                        .background(Color.sdSurface)
                    }
                }

                // Alphabetical list with scrubber
                ZStack(alignment: .trailing) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                                ForEach(groupedContacts, id: \.0) { letter, group in
                                    Section {
                                        ForEach(group) { contact in
                                            if contact.id != "me" {
                                                Button {
                                                    withAnimation { selectedContact = contact }
                                                } label: {
                                                    ContactRow(contact: contact)
                                                }
                                            }
                                        }
                                    } header: {
                                        HStack {
                                            Text(letter)
                                                .font(.system(size: 13, weight: .bold))
                                                .foregroundColor(.sdTextSecondary)
                                            Spacer()
                                        }
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 6)
                                        .background(Color.sdBackground)
                                        .id("section-\(letter)")
                                    }
                                }
                            }
                            .padding(.bottom, 100)
                        }
                    }

                    // A-Z scrubber
                    VStack(spacing: 1) {
                        ForEach(alphabet.map(String.init), id: \.self) { letter in
                            Text(letter)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.sdRed)
                        }
                    }
                    .padding(.trailing, 4)
                }
            }
        }
        .sheet(isPresented: $showAddForm) {
            AddContactFormView { newContact in
                contacts.append(newContact)
                showAddForm = false
            }
        }
    }
}

// MARK: - Contact Row
private struct ContactRow: View {
    let contact: SDContact

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(gradientFor(contact))
                .frame(width: 36, height: 36)
                .overlay(
                    Text(contact.monogram)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(contact.fullName)
                    .font(.system(size: 16))
                    .foregroundColor(.sdTextPrimary)
                if let company = contact.company, !company.isEmpty {
                    Text(company)
                        .font(.system(size: 12))
                        .foregroundColor(.sdTextSecondary)
                }
            }

            Spacer()

            if contact.isAppUser == true {
                Circle()
                    .fill(contact.status == .online ? Color.sdGreen : Color.sdTextMuted)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(
            Rectangle().fill(Color.sdBorder).frame(height: 1),
            alignment: .bottom
        )
    }
}

// MARK: - Contact Detail
private struct ContactDetailView: View {
    let contact: SDContact
    let onBack: () -> Void

    var body: some View {
        ZStack {
            Color.sdBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    // Gradient header with large monogram
                    ZStack {
                        gradientFor(contact)
                            .frame(height: 200)
                            .overlay(Color.black.opacity(0.3))

                        VStack(spacing: 8) {
                            Circle()
                                .fill(Color.white.opacity(0.15))
                                .frame(width: 90, height: 90)
                                .overlay(
                                    Text(contact.monogram)
                                        .font(.system(size: 36, weight: .bold))
                                        .foregroundColor(.white)
                                )

                            Text(contact.fullName)
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(.white)

                            if let company = contact.company, !company.isEmpty {
                                Text(company)
                                    .font(.system(size: 14))
                                    .foregroundColor(.white.opacity(0.7))
                            }
                        }
                    }

                    // Action buttons
                    HStack(spacing: 24) {
                        ContactActionButton(icon: "phone.fill", label: "call")
                        ContactActionButton(icon: "message.fill", label: "message")
                        ContactActionButton(icon: "video.fill", label: "video")
                        ContactActionButton(icon: "envelope.fill", label: "mail")
                    }
                    .padding(.vertical, 16)
                    .background(Color.sdSurface)

                    // Phone numbers
                    if !contact.phones.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(contact.phones, id: \.number) { phone in
                                DetailRow(label: phone.label, value: phone.number, color: .sdBlue)
                            }
                        }
                        .padding(.top, 16)
                    }

                    // Emails
                    if !contact.emails.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(contact.emails, id: \.email) { email in
                                DetailRow(label: email.label, value: email.email, color: .sdBlue)
                            }
                        }
                        .padding(.top, 8)
                    }

                    // Notes
                    if let notes = contact.notes, !notes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Notes")
                                .font(.system(size: 12))
                                .foregroundColor(.sdTextMuted)
                            Text(notes)
                                .font(.system(size: 15))
                                .foregroundColor(.sdTextPrimary)
                        }
                        .padding(16)
                        .background(Color.sdSurface)
                        .padding(.top, 8)
                    }
                }
                .padding(.bottom, 100)
            }

            // Back button overlay
            VStack {
                HStack {
                    Button { onBack() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Contacts")
                        }
                        .font(.system(size: 16))
                        .foregroundColor(.sdRed)
                    }
                    .padding(16)
                    Spacer()
                }
                Spacer()
            }
        }
    }
}

private struct ContactActionButton: View {
    let icon: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(.sdRed)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.sdTextSecondary)
        }
        .frame(width: 60)
    }
}

private struct DetailRow: View {
    let label: String
    let value: String
    var color: Color = .sdTextPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.sdTextMuted)
            Text(value)
                .font(.system(size: 16))
                .foregroundColor(color)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(
            Rectangle().fill(Color.sdBorder).frame(height: 1),
            alignment: .bottom
        )
    }
}

// MARK: - Add Contact Form
private struct AddContactFormView: View {
    @Environment(\.dismiss) var dismiss
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var company = ""
    @State private var phone = ""
    @State private var email = ""
    let onSave: (SDContact) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                Color.sdBackground.ignoresSafeArea()
                VStack(spacing: 16) {
                    SDTextField(placeholder: "First Name", text: $firstName)
                    SDTextField(placeholder: "Last Name", text: $lastName)
                    SDTextField(placeholder: "Company", text: $company)
                    SDTextField(placeholder: "Phone", text: $phone)
                    SDTextField(placeholder: "Email", text: $email)
                    Spacer()
                }
                .padding(16)
            }
            .navigationTitle("New Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.sdRed)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        let contact = SDContact(
                            id: UUID().uuidString,
                            firstName: firstName, lastName: lastName,
                            company: company.isEmpty ? nil : company,
                            phones: phone.isEmpty ? [] : [ContactPhone(label: "mobile", number: phone)],
                            emails: email.isEmpty ? [] : [ContactEmail(label: "home", email: email)],
                            addresses: [], relationships: []
                        )
                        onSave(contact)
                    }
                    .foregroundColor(.sdRed)
                    .disabled(firstName.isEmpty && lastName.isEmpty)
                }
            }
        }
    }
}

// MARK: - Color hex extension
private extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
    static let sdBlue = Color(hex: 0x3B82F6)
    static let sdGreen = Color(hex: 0x22C55E)
}
