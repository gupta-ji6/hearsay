import AVFoundation
import Darwin
import FluidAudio
import Foundation

private struct HelperRequest: Codable {
    let id: Int
    let command: String
    let model: String?
    let audioPath: String?
}

private struct HelperResponse: Codable {
    let id: Int
    let ok: Bool
    let text: String?
    let error: String?
}

private enum HelperError: Error, LocalizedError {
    case invalidModel(String?)
    case missingAudioPath
    case notInitialized
    case unsupportedCommand(String)
    case warmupAudioAllocationFailed

    var errorDescription: String? {
        switch self {
        case .invalidModel(let model):
            return "Invalid Parakeet model: \(model ?? "nil")"
        case .missingAudioPath:
            return "Missing audio path"
        case .notInitialized:
            return "Parakeet model is not initialized"
        case .unsupportedCommand(let command):
            return "Unsupported command: \(command)"
        case .warmupAudioAllocationFailed:
            return "Unable to allocate Parakeet warmup audio"
        }
    }
}

private enum HelperParakeetModel: String {
    case englishV2 = "parakeet-tdt-0.6b-v2-coreml"
    case multilingualV3 = "parakeet-tdt-0.6b-v3-coreml"

    var asrVersion: AsrModelVersion {
        switch self {
        case .englishV2: return .v2
        case .multilingualV3: return .v3
        }
    }
}

private actor ParakeetRunner {
    private var asr: AsrManager?
    private var models: AsrModels?
    private var currentModel: HelperParakeetModel?
    private var warmedModels = Set<HelperParakeetModel>()

    func handle(_ request: HelperRequest) async throws -> HelperResponse {
        let model = try request.model.map { rawValue in
            guard let model = HelperParakeetModel(rawValue: rawValue) else {
                throw HelperError.invalidModel(request.model)
            }
            return model
        }

        switch request.command {
        case "load":
            guard let model else { throw HelperError.invalidModel(request.model) }
            try await ensureLoaded(model)
            return HelperResponse(id: request.id, ok: true, text: nil, error: nil)

        case "prewarm":
            guard let model else { throw HelperError.invalidModel(request.model) }
            try await prewarm(model)
            return HelperResponse(id: request.id, ok: true, text: nil, error: nil)

        case "transcribe":
            guard let model else { throw HelperError.invalidModel(request.model) }
            guard let audioPath = request.audioPath else { throw HelperError.missingAudioPath }
            try await ensureLoaded(model)
            let text = try await transcribe(URL(fileURLWithPath: audioPath))
            return HelperResponse(id: request.id, ok: true, text: text, error: nil)

        default:
            throw HelperError.unsupportedCommand(request.command)
        }
    }

    private func ensureLoaded(_ model: HelperParakeetModel) async throws {
        if currentModel == model, asr != nil {
            return
        }

        if currentModel != model {
            asr = nil
            models = nil
        }

        let downloadedModels = try await AsrModels.downloadAndLoad(version: model.asrVersion)
        models = downloadedModels

        let manager = AsrManager(config: .init())
        try await manager.loadModels(downloadedModels)
        asr = manager
        currentModel = model
    }

    private func prewarm(_ model: HelperParakeetModel) async throws {
        try await ensureLoaded(model)
        guard !warmedModels.contains(model), let asr else {
            return
        }

        let warmupURL = try Self.makeWarmupAudioFile()
        defer { try? FileManager.default.removeItem(at: warmupURL) }

        var decoderState = try TdtDecoderState(decoderLayers: await asr.decoderLayerCount)
        _ = try await asr.transcribe(warmupURL, decoderState: &decoderState)

        warmedModels.insert(model)
    }

    private func transcribe(_ url: URL) async throws -> String {
        guard let asr else {
            throw HelperError.notInitialized
        }

        var decoderState = try TdtDecoderState(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(url, decoderState: &decoderState)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
            throw HelperError.warmupAudioAllocationFailed
        }

        buffer.frameLength = 24_000
        if let samples = buffer.floatChannelData?[0] {
            let sampleRate = Float(format.sampleRate)
            let frequency: Float = 220
            let amplitude: Float = 0.003
            for index in 0..<Int(buffer.frameLength) {
                let phase = 2 * Float.pi * frequency * Float(index) / sampleRate
                samples[index] = sin(phase) * amplitude
            }
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}

@main
private enum HearsayParakeetHelper {
    static func main() async {
        let runner = ParakeetRunner()
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let protocolOutput = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        dup2(STDERR_FILENO, STDOUT_FILENO)

        while let line = readLine() {
            guard let data = line.data(using: .utf8) else {
                continue
            }

            do {
                let request = try decoder.decode(HelperRequest.self, from: data)
                let response: HelperResponse
                do {
                    response = try await runner.handle(request)
                } catch {
                    response = HelperResponse(
                        id: request.id,
                        ok: false,
                        text: nil,
                        error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    )
                }

                try write(response, to: protocolOutput, encoder: encoder)
            } catch {
                let response = HelperResponse(
                    id: -1,
                    ok: false,
                    text: nil,
                    error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
                try? write(response, to: protocolOutput, encoder: encoder)
            }
        }
    }

    private static func write(_ response: HelperResponse, to output: FileHandle, encoder: JSONEncoder) throws {
        let data = try encoder.encode(response)
        output.write(data)
        output.write(Data([0x0A]))
    }
}
