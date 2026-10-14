import Foundation
import CryptoKit

/// Header-level inspection of `.sdiproject` backups before the full decode (#170).
///
/// `DeviceStorageManager.portableBundle(for:)` writes `SDIPROJECT000001\n`, an
/// 8-byte big-endian payload length, a SHA-256 of the payload and the payload.
/// The six digits are the bundle format version. Reading them first lets the
/// app say "made by a newer version" instead of "invalid document", and gives
/// one place to register a migration when a second format ships.
///
/// Version 1 is the first published format, so no older bundle exists and no
/// migration is registered. Nothing here decodes, writes or changes a project.
enum StudioPortableBundleFormat {
    static let currentVersion = 1
    static let magicPrefix = Data("SDIPROJECT".utf8)
    /// "SDIPROJECT" + six ASCII digits + "\n".
    static let headerLength = 17

    enum Header: Equatable, Sendable {
        case version(Int)
        case notABundle
    }

    enum Failure: LocalizedError, Equatable {
        case notABundle
        case newerVersion(Int)
        case noMigration(from: Int)

        var errorDescription: String? {
            switch self {
            case .notABundle:
                return "This file is not a StickDeath Infinity project backup. Nothing was imported."
            case .newerVersion:
                return "This backup was made by a newer version of StickDeath Infinity. Update the app to import it. Nothing was imported."
            case .noMigration:
                return "This backup uses a format this version cannot convert. Nothing was imported."
            }
        }
    }

    /// Upgrades the bytes of one format version to the next. Keys are the
    /// source version. Empty while version 1 is the only published format.
    static let migrations: [Int: (Data) throws -> Data] = [:]

    static func inspect(_ data: Data) -> Header {
        let bytes = Data(data.prefix(headerLength))
        guard bytes.count == headerLength, bytes.prefix(magicPrefix.count) == magicPrefix,
              bytes.last == UInt8(ascii: "\n") else { return .notABundle }
        let digits = bytes.dropFirst(magicPrefix.count).dropLast()
        guard digits.count == 6, digits.allSatisfy({ (48...57).contains($0) }),
              let text = String(data: Data(digits), encoding: .ascii), let version = Int(text), version > 0 else {
            return .notABundle
        }
        return .version(version)
    }

    /// Throws a fixed, path-free failure unless the bytes are a current-version
    /// bundle header. Integrity and content checks still happen in the full decode.
    static func requireSupported(_ data: Data) throws {
        _ = try migratedToCurrent(data)
    }

    /// Returns bytes in the current format, applying registered migrations in
    /// order. A newer version is never guessed at or partially read.
    static func migratedToCurrent(_ data: Data) throws -> Data {
        guard case .version(var version) = inspect(data) else { throw Failure.notABundle }
        guard version <= currentVersion else { throw Failure.newerVersion(version) }
        var bytes = data
        while version < currentVersion {
            guard let step = migrations[version] else { throw Failure.noMigration(from: version) }
            bytes = try step(bytes)
            guard case .version(let next) = inspect(bytes), next == version + 1 else { throw Failure.noMigration(from: version) }
            version = next
        }
        return bytes
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
