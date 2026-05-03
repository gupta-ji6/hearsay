import Foundation
import os.log

actor ParakeetClient {
    static let shared = ParakeetClient()

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

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var nextRequestID = 1
    private var currentModel: ParakeetModel?
    private let logger = Logger(subsystem: "com.swair.hearsay", category: "parakeet")

    func isModelAvailable(_ model: ParakeetModel) -> Bool {
        if currentModel == model, process?.isRunning == true {
            return true
        }

        for directory in model.cachedDirectories() where ParakeetModel.containsCompiledModel(in: directory) {
            logger.notice("Found Parakeet cache at \(directory.path)")
            return true
        }

        return false
    }

    func ensureLoaded(_ model: ParakeetModel, progress: @escaping (Progress) -> Void = { _ in }) async throws {
        if currentModel == model, process?.isRunning == true {
            return
        }

        let startedAt = Date()
        logger.notice("Starting Parakeet helper load variant=\(model.identifier)")

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

        _ = try await send(command: "load", model: model)
        currentModel = model

        loadProgress.completedUnitCount = 100
        progress(loadProgress)
        logger.notice("Parakeet helper load completed in \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s")
    }

    func prewarm(_ model: ParakeetModel) async throws {
        try await ensureLoaded(model)
        let startedAt = Date()
        logger.notice("Starting Parakeet helper prewarm variant=\(model.identifier)")
        _ = try await send(command: "prewarm", model: model)
        logger.notice("Parakeet helper prewarm finished in \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s")
    }

    func transcribe(_ url: URL) async throws -> String {
        guard let currentModel else {
            throw SpeechTranscriptionError.failed("Parakeet not initialized")
        }

        let startedAt = Date()
        logger.notice("Transcribing with Parakeet helper file=\(url.lastPathComponent)")
        let response = try await send(command: "transcribe", model: currentModel, audioURL: url)
        logger.info("Parakeet helper transcription finished in \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s")
        return (response.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func deleteCaches(_ model: ParakeetModel) async throws {
        var removedAny = false
        for directory in model.cachedDirectories() where FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.removeItem(at: directory)
            removedAny = true
        }

        if removedAny, currentModel == model {
            stopHelper()
            currentModel = nil
        }
    }

    private func send(command: String, model: ParakeetModel, audioURL: URL? = nil) async throws -> HelperResponse {
        try ensureHelperRunning()
        guard let input, let output else {
            throw SpeechTranscriptionError.failed("Parakeet helper pipes are unavailable")
        }

        let requestID = nextRequestID
        nextRequestID += 1

        let request = HelperRequest(
            id: requestID,
            command: command,
            model: model.rawValue,
            audioPath: audioURL?.path
        )

        let requestData = try JSONEncoder().encode(request) + Data([0x0A])
        let responseData = try await Task.detached {
            try input.write(contentsOf: requestData)
            return try Self.readLine(from: output)
        }.value

        let response = try JSONDecoder().decode(HelperResponse.self, from: responseData)
        guard response.id == requestID else {
            throw SpeechTranscriptionError.failed("Parakeet helper returned an out-of-order response")
        }

        guard response.ok else {
            throw SpeechTranscriptionError.failed(response.error ?? "Parakeet helper failed")
        }

        return response
    }

    private func ensureHelperRunning() throws {
        if process?.isRunning == true {
            return
        }

        stopHelper()

        guard let helperURL = Self.helperExecutableURL() else {
            throw SpeechTranscriptionError.failed("Parakeet helper is not bundled for this architecture.")
        }

        let standardInput = Pipe()
        let standardOutput = Pipe()
        let helperProcess = Process()
        helperProcess.executableURL = helperURL
        helperProcess.standardInput = standardInput
        helperProcess.standardOutput = standardOutput
        helperProcess.standardError = FileHandle.standardError

        do {
            try helperProcess.run()
        } catch {
            throw SpeechTranscriptionError.failed("Unable to launch Parakeet helper: \(error.localizedDescription)")
        }

        process = helperProcess
        input = standardInput.fileHandleForWriting
        output = standardOutput.fileHandleForReading
        currentModel = nil
    }

    private func stopHelper() {
        try? input?.close()
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        input = nil
        output = nil
    }

    private static func helperExecutableURL() -> URL? {
        #if arch(arm64)
        if let url = Bundle.main.url(forAuxiliaryExecutable: "HearsayParakeetHelper") {
            return url
        }

        let fallback = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/HearsayParakeetHelper")
        if FileManager.default.isExecutableFile(atPath: fallback.path) {
            return fallback
        }
        #endif

        return nil
    }

    private static func readLine(from handle: FileHandle) throws -> Data {
        var data = Data()
        while true {
            let byte = handle.readData(ofLength: 1)
            guard let value = byte.first else {
                throw SpeechTranscriptionError.failed("Parakeet helper exited unexpectedly")
            }

            if value == 0x0A {
                return data
            }

            data.append(value)
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
}
