import Foundation

public struct LogMessage: Identifiable, Hashable {
    public enum Level: String, Codable {
        case verbose
        case info
        case warning
        case error
        case success

        public var prefix: String {
            switch self {
            case .verbose: return "DEBUG"
            case .info: return "INFO "
            case .warning: return "WARN "
            case .error: return "ERROR"
            case .success: return "OK   "
            }
        }
    }

    public let id: UUID
    public let timestamp: Date
    public let level: Level
    public let message: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), level: Level = .info, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
    }

    public var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }

    public static func parseLevel(from line: String) -> Level {
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("fail") || lower.contains("cannot") || lower.contains("unable to") {
            return .error
        } else if lower.contains("warn") || lower.contains("notice") {
            return .warning
        } else if lower.contains("success") || lower.contains("complete") || lower.contains("signed ok") || lower.contains("done") {
            return .success
        } else if lower.contains("debug") {
            return .verbose
        } else {
            return .info
        }
    }
}
