import Foundation

public struct AudioClip: Codable, Identifiable, Equatable {
    public let id: String
    public var soundName: String
    public var track: Int
    public var startTime: Double
    public var duration: Double
    public var volume: Double

    public init(id: String = UUID().uuidString, soundName: String = "", track: Int = 0, startTime: Double = 0, duration: Double = 0, volume: Double = 0.8) {
        self.id = id
        self.soundName = soundName
        self.track = track
        self.startTime = startTime
        self.duration = duration
        self.volume = volume
    }
}

public struct AudioTrack: Codable, Identifiable, Equatable {
    public let id: String
    public var name: String
    public var format: String
    public var audioData: Data?
    public var startTime: Double
    public var duration: Double

    public init(id: String = UUID().uuidString, name: String = "", format: String = "mp3", audioData: Data? = nil, startTime: Double = 0, duration: Double = 0) {
        self.id = id
        self.name = name
        self.format = format
        self.audioData = audioData
        self.startTime = startTime
        self.duration = duration
    }
}

public enum ProjectError: LocalizedError {
    case noProject
    case notFound

    public var errorDescription: String? {
        switch self {
        case .noProject: return "No project is currently open"
        case .notFound: return "Project not found"
        }
    }
}
