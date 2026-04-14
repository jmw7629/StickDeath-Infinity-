// AuthManager.swift
// Handles all authentication — sign up, login, logout, session management
// v4: 3-second timeout on session check so app never gets stuck on splash

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

    private let profileCacheKey = "cached_user_profile"

    private init() {
        loadCachedProfile()
        Task { await checkSessionWithTimeout() }
    }

    // MARK: - Timeout wrapper — never stuck on splash
    private func checkSessionWithTimeout() async {
        // Race: session check vs 3-second timeout
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.checkSession() }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                if await self.isLoading {
                    await MainActor.run {
                        // Timeout hit — show WelcomeView (or cached profile)
                        self.isLoading = false
                    }
                }
            }
            // Wait for session check to finish (or timeout already flipped isLoading)
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Offline Profile Cache
    private func loadCachedProfile() {
        guard let data = UserDefaults.standard.data(forKey: profileCacheKey),
              let profile = try? JSONDecoder().decode(UserProfile.self, from: data) else { return }
        currentUser = profile
        isLoggedIn = true
    }

    private func cacheProfile(_ profile: UserProfile) {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: profileCacheKey)
        }
    }

    // MARK: - Session
    func checkSession() async {
        do {
            session = try await supabase.auth.session
            isLoggedIn = true
            await fetchProfile()
        } catch {
            if currentUser != nil && !OfflineManager.shared.isOnline {
                isLoggedIn = true
            } else {
                isLoggedIn = false
            }
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
        _ = try? await supabase.auth.signOut()
        session = nil
        currentUser = nil
        isLoggedIn = false
        UserDefaults.standard.removeObject(forKey: profileCacheKey)
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
            cacheProfile(profile)
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

        if OfflineManager.shared.isOnline {
            try await supabase
                .from("users")
                .update(updates)
                .eq("id", value: userId.uuidString)
                .execute()
            await fetchProfile()
        } else {
            if let payload = try? JSONEncoder().encode(updates) {
                OfflineManager.shared.enqueue(type: .updateProfile, payload: payload)
            }
            if let username { currentUser?.username = username }
            if let bio { currentUser?.bio = bio }
            if let avatarURL { currentUser?.avatar_url = avatarURL }
            if let profile = currentUser { cacheProfile(profile) }
        }
    }

    var isPro: Bool {
        currentUser?.subscription_tier == "pro" ||
        currentUser?.role == "pro" ||
        currentUser?.role == "admin" ||
        currentUser?.role == "superadmin"
    }

    var isAdmin: Bool {
        currentUser?.role == "admin" || currentUser?.role == "superadmin"
    }
}
