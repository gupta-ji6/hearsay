import AVFoundation
import Foundation
import os.log

#if canImport(FluidAudio) && arch(arm64)
import FluidAudio

actor ParakeetClient {
    static let shared = ParakeetClient()

    private var asr: AsrManager?
    private var models: AsrModels?
    private var currentModel: ParakeetModel?
    private var warmedModels = Set<ParakeetModel>()
    private let logger = Logger(subsystem: "com.swair.hearsay", category: "parakeet")

    func isModelAvailable(_ model: ParakeetModel) -> Bool {
        if currentModel == model, asr != nil {
            return true
        }

        for directory in model.cachedDirectories() where ParakeetModel.containsCompiledModel(in: directory) {
            logger.notice("Found Parakeet cache at \(directory.path)")
            return true
        }

        return false
    }

    func ensureLoaded(_ model: ParakeetModel, progress: @escaping (Progress) -> Void = { _ in }) async throws {
        if currentModel == model, asr != nil {
            return
        }

        if currentModel != model {
            asr = nil
            models = nil
        }

        let startedAt = Date()
        logger.notice("Starting Parakeet load variant=\(model.identifier)")

        let loadProgress = Progress(totalUnitCount: 100)
        loadProgress.completedUnitCount = 1
        progress(loadProgress)

        let pollTask = Task {
            while loadProgress.completedUnitCount < 95 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                for directory in model.cachedDirectories() {
                    guard let size = Self.directorySize(directory) else {
                        continue
                    }

                    let targetSize = Double(model.estimatedSize)
                    let fraction = max(0.0, min(1.0, Double(size) / targetSize))
                    loadProgress.completedUnitCount = Int64(5 + fraction * 90)
                    progress(loadProgress)
                    break
                }

                if Task.isCancelled {
                    break
                }
            }
        }
        defer { pollTask.cancel() }

        let downloadedModels = try await AsrModels.downloadAndLoad(version: model.asrVersion)
        self.models = downloadedModels

        let manager = AsrManager(config: .init())
        try await manager.loadModels(downloadedModels)
        self.asr = manager
        self.currentModel = model

        loadProgress.completedUnitCount = 100
        progress(loadProgress)
        logger.notice("Parakeet load completed in \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s")
    }

    func prewarm(_ model: ParakeetModel) async throws {
        try await ensureLoaded(model)
        guard !warmedModels.contains(model), let asr else {
            return
        }

        let startedAt = Date()
        logger.notice("Starting Parakeet inference prewarm variant=\(model.identifier)")

        do {
            let warmupURL = try Self.makeWarmupAudioFile()
            defer { try? FileManager.default.removeItem(at: warmupURL) }

            var decoderState = try TdtDecoderState(decoderLayers: await asr.decoderLayerCount)
            _ = try await asr.transcribe(warmupURL, decoderState: &decoderState)
        } catch {
            // Silence may legitimately produce no text; the important part is that Core ML
            // has had a chance to compile and run the graph before the user's first utterance.
            logger.debug("Parakeet prewarm completed with ignored error: \(error.localizedDescription)")
        }

        warmedModels.insert(model)
        logger.notice("Parakeet inference prewarm finished in \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s")
    }

    func transcribe(_ url: URL) async throws -> String {
        guard let asr else {
            throw SpeechTranscriptionError.failed("Parakeet not initialized")
        }

        let startedAt = Date()
        logger.notice("Transcribing with Parakeet file=\(url.lastPathComponent)")
        var decoderState = try TdtDecoderState(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(url, decoderState: &decoderState)
        logger.info("Parakeet transcription finished in \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s")
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func deleteCaches(_ model: ParakeetModel) async throws {
        var removedAny = false
        for directory in model.cachedDirectories() where FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.removeItem(at: directory)
            removedAny = true
        }

        if removedAny {
            asr = nil
            models = nil
            if currentModel == model {
                currentModel = nil
            }
        }
    }

    private static func directorySize(_ directory: URL) -> UInt64? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: .skipsHiddenFiles
        ) else {
            return nil
        }

        var total: UInt64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            total &+= UInt64(values.fileSize ?? 0)
        }

        return total
    }

    private static func makeWarmupAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hearsay-parakeet-warmup-\(UUID().uuidString).wav")

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000) else {
            throw SpeechTranscriptionError.failed("Unable to allocate Parakeet warmup audio")
        }

        buffer.frameLength = 24_000
        if let samples = buffer.floatChannelData?[0] {
            samples.initialize(repeating: 0, count: Int(buffer.frameLength))
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

private extension ParakeetModel {
    var asrVersion: AsrModelVersion {
        switch self {
        case .englishV2: return .v2
        case .multilingualV3: return .v3
        }
    }
}

#else

actor ParakeetClient {
    static let shared = ParakeetClient()

    func isModelAvailable(_ model: ParakeetModel) -> Bool {
        false
    }

    func ensureLoaded(_ model: ParakeetModel, progress: @escaping (Progress) -> Void = { _ in }) async throws {
        throw SpeechTranscriptionError.failed("Parakeet support is only available when FluidAudio is linked on Apple Silicon.")
    }

    func prewarm(_ model: ParakeetModel) async throws {
        throw SpeechTranscriptionError.failed("Parakeet support is only available when FluidAudio is linked on Apple Silicon.")
    }

    func transcribe(_ url: URL) async throws -> String {
        throw SpeechTranscriptionError.failed("Parakeet not available")
    }

    func deleteCaches(_ model: ParakeetModel) async throws {}
}

#endif
