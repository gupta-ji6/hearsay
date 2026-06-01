import Foundation

enum DictationMode: Equatable {
    case pasteAtCursor
    case returnToCaller(requestId: UUID)
}

enum DictationState: String, Codable {
    case idle
    case recording
    case transcribing
    case unavailable
}

struct DictationRequest {
    let id: UUID
    let caller: String
    let mode: DictationMode
    let createdAt: Date
    let autoStop: Bool
    let metadata: [String: String]
}

struct DictationResult: Codable {
    let requestId: String
    let status: String
    let text: String?
    let error: String?
    let durationSeconds: Double?

    static func completed(requestId: UUID, text: String, durationSeconds: Double) -> DictationResult {
        DictationResult(
            requestId: requestId.uuidString,
            status: "completed",
            text: text,
            error: nil,
            durationSeconds: durationSeconds
        )
    }

    static func cancelled(requestId: UUID) -> DictationResult {
        DictationResult(
            requestId: requestId.uuidString,
            status: "cancelled",
            text: nil,
            error: nil,
            durationSeconds: nil
        )
    }

    static func failed(requestId: UUID, error: String) -> DictationResult {
        DictationResult(
            requestId: requestId.uuidString,
            status: "failed",
            text: nil,
            error: error,
            durationSeconds: nil
        )
    }
}

enum CallerDictationError: LocalizedError {
    case busy(state: DictationState)
    case invalidRequest(String)
    case notFound
    case microphonePermissionMissing
    case transcriberUnavailable
    case recordingFailed(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .busy(let state):
            return "Hearsay is already \(state.rawValue)"
        case .invalidRequest(let message):
            return message
        case .notFound:
            return "Dictation request not found"
        case .microphonePermissionMissing:
            return "Microphone permission is not granted"
        case .transcriberUnavailable:
            return "No transcription model is available"
        case .recordingFailed(let message):
            return message
        case .transcriptionFailed(let message):
            return message
        }
    }

    var apiCode: String {
        switch self {
        case .busy:
            return "busy"
        case .invalidRequest:
            return "invalid_request"
        case .notFound:
            return "not_found"
        case .microphonePermissionMissing:
            return "microphone_permission_missing"
        case .transcriberUnavailable:
            return "transcriber_unavailable"
        case .recordingFailed:
            return "recording_failed"
        case .transcriptionFailed:
            return "transcription_failed"
        }
    }

    var httpStatus: Int {
        switch self {
        case .invalidRequest:
            return 400
        case .notFound:
            return 404
        case .busy:
            return 409
        case .microphonePermissionMissing, .transcriberUnavailable:
            return 503
        case .recordingFailed, .transcriptionFailed:
            return 500
        }
    }
}
