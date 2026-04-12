// StripeService.swift
// Handles Pro subscription checkout via your edge function + Stripe

import Foundation

class StripeService {
    static let shared = StripeService()

    // Creates a checkout session via your create-checkout edge function
    // Returns the Stripe checkout URL to open in a browser/webview
    func createCheckoutSession() async throws -> URL {
        guard let accessToken = await AuthManager.shared.session?.accessToken else {
            throw AppError.notAuthenticated
        }

        var request = URLRequest(url: AppConfig.edgeFunction("create-checkout"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["price_id": "price_1TLD0iFLiSxiZ8KHhCCe3Lho"])

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
