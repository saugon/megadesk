import Foundation

/// Watches a Claude Code JSONL transcript for a given session and extracts
/// the currently active tool, calling `onUpdate` whenever it changes.
final class JSONLWatcher {

    /// Called on the main queue with the new detail string, or nil when the tool finishes.
    var onUpdate: ((String?) -> Void)?

    private let sessionId: String
    private var jsonlURL: URL?
    private var fileOffset: UInt64 = 0
    private var lineBuffer = ""
    private var watchSource: DispatchSourceFileSystemObject?
    private var fileFD: Int32 = -1
    private var retryCount = 0
    private static let maxRetries = 6  // ~12s total retry window

    init(sessionId: String) {
        self.sessionId = sessionId
        start()
    }

    deinit { stop() }

    // MARK: - Lifecycle

    private func start() {
        guard let url = findJSONLFile() else {
            guard retryCount < Self.maxRetries else { return }
            retryCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.start()
            }
            return
        }
        jsonlURL = url
        // Start from the end — we only care about future tool events
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        fileOffset = (attrs?[.size] as? UInt64) ?? 0
        openWatch(url: url)
    }

    private func stop() {
        watchSource?.cancel()
        watchSource = nil
        if fileFD >= 0 { close(fileFD); fileFD = -1 }
    }

    // MARK: - File discovery

    private func findJSONLFile() -> URL? {
        let projectsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: projectsURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return nil }
        for dir in dirs {
            let candidate = dir.appendingPathComponent("\(sessionId).jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Watching

    private func openWatch(url: URL) {
        fileFD = open(url.path, O_EVTONLY)
        guard fileFD >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileFD,
            eventMask: [.write, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.readNewLines() }
        source.resume()
        watchSource = source
    }

    private func readNewLines() {
        guard let url = jsonlURL,
              let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        do {
            try fh.seek(toOffset: fileOffset)
            guard let data = try fh.readToEnd(), !data.isEmpty else { return }
            fileOffset += UInt64(data.count)
            let text = lineBuffer + (String(data: data, encoding: .utf8) ?? "")
            let lines = text.components(separatedBy: "\n")
            for i in 0..<lines.count - 1 {
                processLine(lines[i])
            }
            lineBuffer = lines.last ?? ""
        } catch {}
    }

    // MARK: - Parsing

    private func processLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        let type = json["type"] as? String ?? ""

        // Turn complete — clear detail
        if type == "system", (json["subtype"] as? String) == "turn_duration" {
            onUpdate?(nil)
            return
        }

        // Tool result received — tool is done
        if type == "user",
           let msg = json["message"] as? [String: Any],
           let content = msg["content"] as? [[String: Any]],
           content.contains(where: { ($0["type"] as? String) == "tool_result" }) {
            onUpdate?(nil)
            return
        }

        // Tool use starting
        if type == "assistant",
           let msg = json["message"] as? [String: Any],
           let content = msg["content"] as? [[String: Any]] {
            for block in content where (block["type"] as? String) == "tool_use" {
                let name = block["name"] as? String ?? ""
                let input = block["input"] as? [String: Any] ?? [:]
                onUpdate?(format(name: name, input: input))
                return
            }
        }
    }

    // MARK: - Formatting

    private func format(name: String, input: [String: Any]) -> String {
        switch name {
        case "Read":
            if let p = input["file_path"] as? String { return "Reading \(filename(p))" }
        case "Edit":
            if let p = input["file_path"] as? String { return "Editing \(filename(p))" }
        case "Write":
            if let p = input["file_path"] as? String { return "Writing \(filename(p))" }
        case "Bash":
            if let cmd = input["command"] as? String {
                let short = String(cmd.prefix(40)).replacingOccurrences(of: "\n", with: "; ")
                return "$ \(short)"
            }
        case "Glob":
            if let p = input["pattern"] as? String { return "Glob \(p)" }
        case "Grep":
            if let p = input["pattern"] as? String { return "Grep \(String(p.prefix(30)))" }
        case "Agent":
            if let d = input["description"] as? String { return "Task: \(String(d.prefix(35)))" }
        case "Task":
            if let d = input["description"] as? String { return "Task: \(String(d.prefix(35)))" }
        case "WebSearch":
            if let q = input["query"] as? String { return "Search: \(String(q.prefix(30)))" }
        case "WebFetch":
            if let u = input["url"] as? String, let host = URL(string: u)?.host {
                return "Fetching \(host)"
            }
        case "TodoWrite":
            return "Updating todos"
        default:
            break
        }
        return name
    }

    private func filename(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}
