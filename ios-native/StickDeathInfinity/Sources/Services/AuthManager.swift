// AuthManager.swift
// Handles all authentication — sign up, login, logout, session management
// v6: + Apple Sign-In + Google Sign-In via GoogleSignIn SDK

import Foundation
import SwiftUI
import Supabase
import AuthenticationServices
import CryptoKit
import GoogleSignIn

@MainActor
class AuthManager: ObservableObject {
    static let shared = AuthManager()

    @Published var isLoggedIn = false
    @Published var isLoading = true
    @Published var currentUser: UserProfile?
    @Published var session: Session?

    private let profileCacheKey = "cached_user_profile"

    // Apple Sign-In state
    private var currentNonce: String?

    private init() {
        loadCachedProfile()
        Task { await checkSessionWithTimeout() }
    }

    // MARK: - Timeout wrapper — never stuck on splash
    private func checkSessionWithTimeout() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.checkSession() }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                if await self.isLoading {
                    await MainActor.run { self.isLoading = false }
                }
            }
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

    /// Generate a random nonce for Apple Sign-In
    func generateNonce() -> String {
        let nonce = randomNonceString()
        currentNonce = nonce
        return nonce
    }

    /// Get the SHA256 hash of the current nonce (for Apple's request)
    func sha256Nonce() -> String {
        guard let nonce = currentNonce else { return "" }
        let data = Data(nonce.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Return the raw nonce for Supabase verification
    var rawNonce: String? { currentNonce }

    // MARK: - Sign In with Google
    func signInWithGoogle() async throws {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = scene.windows.first?.rootViewController else {
            throw NSError(domain: "GoogleSignIn", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No root view controller found"])
        }

        // Configure Google Sign-In client ID
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: AppConfig.googleClientID)

        // Present Google Sign-In flow
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootVC)

        guard let idToken = result.user.idToken?.tokenString else {
            throw NSError(domain: "GoogleSignIn", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Missing Google ID token"])
        }

        // Use the Google ID token + access token to sign in with Supabase
        session = try await supabase.auth.signInWithIdToken(
            credentials: .init(
                provider: .google,
                idToken: idToken,
                accessToken: result.user.accessToken.tokenString
            )
        )
        isLoggedIn = true
        await fetchProfile()
    }

    private func randomNonceString(length: Int = 32) -> String {
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length
        while remainingLength > 0 {
            let randoms: [UInt8] = (0 ..< 16).map { _ in
                var random: UInt8 = 0
                let status = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
                if status != errSecSuccess { random = UInt8.random(in: 0...255) }
                return random
            }
            for random in randoms {
                if remainingLength == 0 { break }
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }
        return result
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

            // Auto-promote superusers
            await autoPromoteIfSuperuser()
        } catch {
            // Profile doesn't exist yet — create it (first login / signup)
            await createProfileIfNeeded()
        }
    }

    /// Creates a profile row in `users` table on first auth
    private func createProfileIfNeeded() async {
        guard let user = session?.user else { return }
        let email = user.email ?? ""
        let isSuperuser = AppConfig.superuserEmails.contains(email.lowercased())

        let newProfile: [String: String] = [
            "id": user.id.uuidString,
            "email": email,
            "username": user.userMetadata["username"]?.stringValue ?? email.components(separatedBy: "@").first ?? "user",
            "role": isSuperuser ? "superadmin" : "user",
            "subscription_tier": isSuperuser ? "pro" : "free",
            "avatar_url": ""
        ]

        do {
            try await supabase
                .from("users")
                .insert(newProfile)
                .execute()
            print("✅ Created profile for \(email)\(isSuperuser ? " [SUPERADMIN]" : "")")
            await fetchProfileOnly()
        } catch {
            print("⚠️ Failed to create profile: \(error)")
        }
    }

    /// Promotes matching emails to superadmin + pro (idempotent)
    private func autoPromoteIfSuperuser() async {
        guard let user = session?.user,
              let email = user.email,
              AppConfig.superuserEmails.contains(email.lowercased()),
              currentUser?.role != "superadmin" else { return }

        do {
            try await supabase
                .from("users")
                .update(["role": "superadmin", "subscription_tier": "pro"])
                .eq("id", value: user.id.uuidString)
                .execute()
            currentUser?.role = "superadmin"
            currentUser?.subscription_tier = "pro"
            if let profile = currentUser { cacheProfile(profile) }
            print("✅ Auto-promoted \(email) to superadmin")
        } catch {
            print("⚠️ Auto-promote failed: \(error)")
        }
    }

    /// Fetch-only (no create loop)
    private func fetchProfileOnly() async {
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

// MARK: - Apple Sign-In Coordinator (UIKit bridge)
class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    var onComplete: ((Result<(String, String), Error>) -> Void)?

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else {
            return ASPresentationAnchor()
        }
        return window
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            onComplete?(.failure(NSError(domain: "AppleSignIn", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing identity token"])))
            return
        }
        let nonce = AuthManager.shared.rawNonce ?? ""
        onComplete?(.success((idToken, nonce)))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        onComplete?(.failure(error))
    }
}
