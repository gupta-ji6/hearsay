import Foundation

/// Metadata-only diagnostic log for support investigations.
///
/// Do not write raw transcripts, audio contents, clipboard text, screenshots,
/// cleanup prompts, or model output here. Event fields should be counts,
/// durations, coarse states, identifiers, and error categories only.
final class DiagnosticLog {
    enum Level: String {
        case info
        case warning
        case error
    }

    static let shared = DiagnosticLog()

    let logURL = Constants.diagnosticLogURL

    private let maxAge: TimeInterval = 24 * 60 * 60
    private let maxBytes = 1_000_000
    private let pruneInterval: TimeInterval = 10 * 60
    private let queue = DispatchQueue(label: "com.swair.hearsay.diagnostic-log")
    private let isoFormatter = ISO8601DateFormatter()
    private var lastPruneAt = Date.distantPast

    private init() {
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        queue.sync {
            try? FileManager.default.createDirectory(at: Constants.appSupportDirectory, withIntermediateDirectories: true)
            pruneLocked(force: true)
        }
    }

    func event(
        _ name: String,
        level: Level = .info,
        fields: [String: String] = [:],
        file: String = #fileID,
        line: Int = #line
    ) {
        let source = URL(fileURLWithPath: file).lastPathComponent
        let entry = makeEntry(
            name: name,
            level: level,
            fields: fields,
            source: "\(source):\(line)"
        )

        queue.async {
            self.pruneLocked(force: false)
            self.appendLocked(entry)

            if self.currentFileSizeLocked() > self.maxBytes {
                self.pruneLocked(force: true)
            }
        }
    }

    func snapshotText() -> String {
        let body = queue.sync { () -> String in
            pruneLocked(force: true)
            return (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        }

        let generatedAt = Self.makeFormatter().string(from: Date())
        let header = """
        # Hearsay diagnostic log
        # Generated: \(generatedAt)
        # Retention: last 24 hours, capped at 1000000 bytes
        # Privacy: metadata only; raw transcripts, audio, clipboard text, screenshots, and prompts are not recorded

        """

        return header + body
    }

    func writeSnapshotFile() throws -> URL {
        let timestamp = Self.makeFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Hearsay-Diagnostics-\(timestamp).log")

        try snapshotText().write(to: snapshotURL, atomically: true, encoding: .utf8)
        return snapshotURL
    }

    func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: logURL)
            lastPruneAt = Date.distantPast
        }
    }

    func errorFields(for error: Error) -> [String: String] {
        if let transcriptionError = error as? SpeechTranscriptionError {
            switch transcriptionError {
            case .noOutput:
                return ["error_type": "speech.no_output"]
            case .failed(let message):
                return [
                    "error_type": "speech.failed",
                    "message_length": "\(message.count)"
                ]
            }
        }

        let nsError = error as NSError
        return [
            "error_type": String(describing: type(of: error)),
            "error_domain": nsError.domain,
            "error_code": "\(nsError.code)"
        ]
    }

    private func makeEntry(
        name: String,
        level: Level,
        fields: [String: String],
        source: String
    ) -> String {
        var object: [String: Any] = [
            "timestamp": isoFormatter.string(from: Date()),
            "level": level.rawValue,
            "event": sanitizeEventName(name),
            "source": source,
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        ]

        if !fields.isEmpty {
            object["fields"] = fields.reduce(into: [String: String]()) { result, item in
                result[sanitizeFieldKey(item.key)] = sanitizeFieldValue(item.value, forKey: item.key)
            }
        }

        guard
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let line = String(data: data, encoding: .utf8)
        else {
            return "{\"event\":\"diagnostic_log.encode_failed\",\"level\":\"error\",\"timestamp\":\"\(isoFormatter.string(from: Date()))\"}"
        }

        return line
    }

    private func appendLocked(_ entry: String) {
        guard let data = (entry + "\n").data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    private func pruneLocked(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPruneAt) >= pruneInterval else { return }
        lastPruneAt = now

        guard let content = try? String(contentsOf: logURL, encoding: .utf8), !content.isEmpty else {
            return
        }

        let cutoff = now.addingTimeInterval(-maxAge)
        var keptLines: [String] = []

        for line in content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            guard let timestamp = timestamp(from: line), timestamp >= cutoff else {
                continue
            }
            keptLines.append(line)
        }

        while byteCount(for: keptLines) > maxBytes, !keptLines.isEmpty {
            keptLines.removeFirst()
        }

        if keptLines.isEmpty {
            try? FileManager.default.removeItem(at: logURL)
        } else {
            let pruned = keptLines.joined(separator: "\n") + "\n"
            try? pruned.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    private func timestamp(from line: String) -> Date? {
        guard
            let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let timestamp = object["timestamp"] as? String
        else {
            return nil
        }

        return isoFormatter.date(from: timestamp)
    }

    private func currentFileSizeLocked() -> Int {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
            let size = attributes[.size] as? NSNumber
        else {
            return 0
        }
        return size.intValue
    }

    private func byteCount(for lines: [String]) -> Int {
        lines.reduce(0) { total, line in
            total + line.utf8.count + 1
        }
    }

    private func sanitizeEventName(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.map(String.init).joined()
    }

    private func sanitizeFieldKey(_ key: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return key.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.map(String.init).joined()
    }

    private func sanitizeFieldValue(_ value: String, forKey key: String) -> String {
        if isSensitiveFieldKey(key) {
            return "[redacted]"
        }

        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        return String(normalized.prefix(240))
    }

    private func isSensitiveFieldKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        let exactSensitiveKeys: Set<String> = [
            "text",
            "transcript",
            "prompt",
            "clipboard",
            "output",
            "input",
            "raw"
        ]

        return exactSensitiveKeys.contains(normalized)
            || normalized.hasSuffix("_text")
            || normalized.hasSuffix("_transcript")
            || normalized.hasSuffix("_prompt")
            || normalized.hasSuffix("_clipboard")
            || normalized.hasSuffix("_output")
            || normalized.hasSuffix("_input")
            || normalized.contains("clipboard_content")
            || normalized.contains("audio_content")
            || normalized.contains("screenshot_content")
    }

    private static func makeFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}
