import Foundation
import SDCore

/// Bridges AuthService to SDCore's AuthTokenProvider protocol
@MainActor
final class AuthServiceAuthBridge: AuthTokenProvider {
    static let shared = AuthServiceAuthBridge()

    var currentAuthToken: String? {
        // Supabase session JWT is the auth token for backend calls
        guard let client = SupabaseManager.shared.client else { return nil }
        // The session token is managed internally by SupabaseClient
        // For backend auth, we use the user ID as a session identifier
        return AuthService.shared.userId
    }

    var isAuthenticated: Bool {
        AuthService.shared.isAuthenticated
    }
}
