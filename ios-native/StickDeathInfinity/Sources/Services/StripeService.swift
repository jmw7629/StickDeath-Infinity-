// StripeService.swift
// Handles Pro & Creator subscription checkout via edge function + Stripe
// Tiers: Free (no payment), Pro ($4.99/mo), Creator ($7.99/mo)

import Foundation

enum SubscriptionTier: String, CaseIterable {
    case free     = "free"
    case pro      = "pro"
    case creator  = "creator"

    var displayName: String {
        switch self {
        case .free:    return "Free"
        case .pro:     return "Pro"
        case .creator: return "Creator"
        }
    }

    var priceDisplay: String {
        switch self {
        case .free:    return "Free"
        case .pro:     return "$4.99/mo"
        case .creator: return "$7.99/mo"
        }
    }

    var stripePriceId: String? {
        switch self {
        case .free:    return nil
        case .pro:     return "price_1TLD0iFLiSxiZ8KHhCCe3Lho"
        case .creator: return "price_1TMsryFLiSxiZ8KHMe3shnI1"
        }
    }

    var features: [String] {
        switch self {
        case .free:
            return [
                "Simple animation studio",
                "Up to 50 frames per project",
                "3 projects",
                "Watermark on exports",
                "Basic drawing tools",
            ]
        case .pro:
            return [
                "Simple animation studio",
                "Unlimited frames",
                "Unlimited projects",
                "No watermark",
                "HD export (1080p)",
                "All drawing tools",
            ]
        case .creator:
            return [
                "Advanced animation studio",
                "Stick figure rigging & IK posing",
                "AI-powered assistant (Spatter)",
                "Asset library (objects & sounds)",
                "Video import tool",
                "All Pro features included",
                "4K export",
                "Priority support",
            ]
        }
    }
}

class StripeService {
    static let shared = StripeService()

    /// Creates a checkout session for the given tier
    func createCheckoutSession(tier: SubscriptionTier = .pro) async throws -> URL {
        guard let priceId = tier.stripePriceId else {
            throw AppError.serverError("Free tier does not require checkout")
        }

        guard let accessToken = await AuthManager.shared.session?.accessToken else {
            throw AppError.notAuthenticated
        }

        var request = URLRequest(url: AppConfig.edgeFunction("create-checkout"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["price_id": priceId])

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw AppError.serverError("Failed to create checkout session")
        }

        struct CheckoutResponse: Decodable { let url: String }
        let result = try JSONDecoder().decode(CheckoutResponse.self, from: data)

        guard let url = URL(string: result.url) else {
            throw AppError.serverError("Invalid checkout URL")
        }
        return url
    }
}
