import Foundation

public enum PipelineStep: Equatable {
    case idle
    case preparing
    case signing(progress: Double, detail: String)
    case signed(outputURL: URL)
    case installing(progress: Double, detail: String)
    case completed(outputURL: URL)
    case failed(error: String)

    public var isBusy: Bool {
        switch self {
        case .preparing, .signing, .installing:
            return true
        default:
            return false
        }
    }

    public var progress: Double {
        switch self {
        case .idle:
            return 0.0
        case .preparing:
            return 0.1
        case .signing(let p, _):
            return 0.1 + (p * 0.4) // 10% to 50%
        case .signed:
            return 0.5
        case .installing(let p, _):
            return 0.5 + (p * 0.5) // 50% to 100%
        case .completed:
            return 1.0
        case .failed:
            return 0.0
        }
    }

    public var statusTitle: String {
        switch self {
        case .idle:
            return "Ready"
        case .preparing:
            return "Preparing..."
        case .signing(_, let detail):
            return detail.isEmpty ? "Signing IPA..." : detail
        case .signed:
            return "Signing Complete"
        case .installing(_, let detail):
            return detail.isEmpty ? "Installing to Device..." : detail
        case .completed:
            return "Installed Successfully"
        case .failed(let err):
            return "Failed: \(err)"
        }
    }

    public var statusColorName: String {
        switch self {
        case .idle:
            return "secondary"
        case .preparing, .signing, .installing:
            return "accent"
        case .signed, .completed:
            return "green"
        case .failed:
            return "red"
        }
    }
}
