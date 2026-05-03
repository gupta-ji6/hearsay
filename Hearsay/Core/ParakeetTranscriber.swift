import Foundation
import os.log

actor ParakeetTranscriber: SpeechTranscribing {
    private let model: ParakeetModel
    private let client: ParakeetClient
    private let logger = Logger(subsystem: "com.swair.hearsay", category: "parakeet")

    init(model: ParakeetModel, client: ParakeetClient = .shared) {
        self.model = model
        self.client = client
    }

    func prewarm() async throws {
        try await client.prewarm(model)
    }

    func transcribe(audioURL: URL) async throws -> String {
        try await client.ensureLoaded(model)

        let preparedClip = try ParakeetClipPreparer.ensureMinimumDuration(url: audioURL, logger: logger)
        defer { preparedClip.cleanup() }

        let text = try await client.transcribe(preparedClip.url)
        guard !text.isEmpty else {
            throw SpeechTranscriptionError.noOutput
        }

        return text
    }
}
