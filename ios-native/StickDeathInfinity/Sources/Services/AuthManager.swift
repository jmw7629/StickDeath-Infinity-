// AuthManager.swift
// Handles all authentication — sign up, login, logout, session management

import Foundation
import SwiftUI
import Supabase

@MainActor
class AuthManager: ObservableObject {
    static let shared = AuthManager()

    @Published var isLoggedIn = false
    @Published var isLoading = true
    @Published var currentUser: UserProfile?
    @Published var session: Session?

    private init() {
        Task { await checkSession() }
    }

    // MARK: - Session
    func checkSession() async {
        do {
            session = try await supabase.auth.session
            isLoggedIn = true
            await fetchProfile()
        } catch {
            isLoggedIn = false
        }
        isLoading = false
    }

    // MARK: - Sign Up
    func signUp(email: String, password: String, username: String) async throws {
        let response = try await supabase.auth.signUp(
            email: email,
            password: password,
            data: ["username": .string(username)]
        )
        session = response.session
        isLoggedIn = true
        await fetchProfile()
    }

    // MARK: - Login
    func login(email: String, password: String) async throws {
        session = try await supabase.auth.signIn(
            email: email,
            password: password
        )
        isLoggedIn = true
        await fetchProfile()
    }

    // MARK: - Sign In with Apple
    func signInWithApple(idToken: String, nonce: String) async throws {
        session = try await supabase.auth.signInWithIdToken(
            credentials: .init(
                provider: .apple,
                idToken: idToken,
                nonce: nonce
            )
        )
        isLoggedIn = true
        await fetchProfile()
    }

    // MARK: - Logout
    func logout() async {
        try? await supabase.auth.signOut()
        session = nil
        currentUser = nil
        isLoggedIn = false
    }

    // MARK: - Profile
    func fetchProfile() async {
        guard let userId = session?.user.id else { return }
        do {
            let profile: UserProfile = try await supabase
                .from("users")
                .select()
                .eq("id", value: userId.uuidString)
                .single()
                .execute()
                .value
            currentUser = profile
        } catch {
            print("⚠️ Failed to fetch profile: \(error)")
        }
    }

    func updateProfile(username: String? = nil, bio: String? = nil, avatarURL: String? = nil) async throws {
        guard let userId = session?.user.id else { return }
        var updates: [String: String] = [:]
        if let username { updates["username"] = username }
        if let bio { updates["bio"] = bio }
        if let avatarURL { updates["avatar_url"] = avatarURL }

        try await supabase
            .from("users")
            .update(updates)
            .eq("id", value: userId.uuidString)
            .execute()

        await fetchProfile()
    }

    var isPro: Bool {
        currentUser?.role == "pro" || currentUser?.role == "admin" || currentUser?.role == "superadmin"
    }

    var isAdmin: Bool {
        currentUser?.role == "admin" || currentUser?.role == "superadmin"
    }
}
