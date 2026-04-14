// AuthManager.swift
// Handles all authentication — sign up, login, logout, session management
// v5: Proper 5-second timeout using unstructured Task (not withTaskGroup)

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
        Task { await checkSession() }
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

    // MARK: - Session (with bulletproof timeout)
    func checkSession() async {
        // Fire off session check as a SEPARATE unstructured task
        // so we can timeout independently even if Supabase SDK hangs
        let sessionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let sess = try await supabase.auth.session
                // Only update if we haven't been cancelled/timed out
                guard !Task.isCancelled else { return }
                self.session = sess
                self.isLoggedIn = true
                await self.fetchProfile()
            } catch {
                guard !Task.isCancelled else { return }
                if self.currentUser != nil {
                    self.isLoggedIn = true
                } else {
                    self.isLoggedIn = false
                }
            }
            // Mark loading done if still loading
            if self.isLoading {
                self.isLoading = false
            }
        }

        // Wait 5 seconds — if session check hasn't finished, force-unblock
        try? await Task.sleep(nanoseconds: 5_000_000_000)

        if isLoading {
            print("⏱️ AuthManager: Session check timed out after 5s — moving to Welcome screen")
            sessionTask.cancel()
            isLoading = false
            if currentUser == nil {
                isLoggedIn = false
            }
        }
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
