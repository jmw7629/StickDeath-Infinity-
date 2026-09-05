import Foundation

public enum LayerLockMode: String, Codable, CaseIterable, Sendable {
    case free, full, position, alpha
}
