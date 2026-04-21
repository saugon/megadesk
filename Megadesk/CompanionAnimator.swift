import Foundation
import Observation

@Observable
final class CompanionAnimator {
    var currentFrame: String = ""
    var isVisible: Bool = false {
        didSet {
            if isVisible { startTimer() } else { stopTimer() }
        }
    }

    var ghostState: GhostState = .idle {
        didSet {
            frameIndex = 0
            updateFrame()
            // New state → restart timing at the first frame's own duration.
            if isVisible { stopTimer(); startTimer() }
        }
    }

    private var timer: Timer?
    private var frameIndex: Int = 0

    /// Default duration (ms) used when a frame doesn't specify one via the
    /// `---key:ms---` delimiter.
    private static let defaultDurationMs: Int = 500

    init() {
        updateFrame()
    }

    // MARK: - Timing

    private func startTimer() {
        stopTimer()
        scheduleNext()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Schedules a one-shot timer to advance to the next frame, using the
    /// CURRENT frame's duration. This makes the per-frame duration honored:
    /// frame N stays visible for its own declared ms before tick() swaps it.
    private func scheduleNext() {
        let frames = Self.frames(for: ghostState)
        guard !frames.isEmpty else { return }
        let current = frames[frameIndex % frames.count]
        let ms = current.durationMs ?? Self.defaultDurationMs
        let interval = TimeInterval(max(50, ms)) / 1000.0

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        let frames = Self.frames(for: ghostState)
        frameIndex = (frameIndex + 1) % frames.count
        updateFrame()
        scheduleNext()
    }

    private func updateFrame() {
        let frames = Self.frames(for: ghostState)
        guard !frames.isEmpty else { return }
        currentFrame = frames[frameIndex % frames.count].lines.joined(separator: "\n")
    }

    // MARK: - Frame data

    struct FrameData {
        var lines: [String]
        var durationMs: Int?
    }

    /// Frames are loaded from `companion-frames.txt` in the app bundle.
    /// Edit that file with any monospaced editor to change the animation.
    /// If the file is missing or malformed, the hardcoded defaults below are used.
    private static let loadedFrames: [String: FrameData] = loadFrames()

    private static func frames(for state: GhostState) -> [FrameData] {
        let prefix: String
        switch state {
        case .idle:  prefix = "idle-"
        case .alert: prefix = "alert-"
        case .happy: prefix = "happy-"
        }

        // Pick up every key for this state (e.g. `idle-a`, `idle-b`, `idle-c`...)
        // and return them sorted so the cycle order is stable.
        let matching = loadedFrames.keys.filter { $0.hasPrefix(prefix) }.sorted()
        if !matching.isEmpty {
            return matching.compactMap { loadedFrames[$0] }
        }

        // Fallback to hardcoded defaults.
        let fallback = defaultFrames.keys.filter { $0.hasPrefix(prefix) }.sorted()
        return fallback.compactMap { defaultFrames[$0] }
    }

    // MARK: - Loader

    private static func loadFrames() -> [String: FrameData] {
        guard let url = Bundle.main.url(forResource: "companion-frames", withExtension: "txt"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return defaultFrames
        }
        let parsed = parseFrames(content)
        return parsed.isEmpty ? defaultFrames : parsed
    }

    /// Parses `---<key>[:<ms>]---` delimited frames.
    ///
    /// Example delimiters:
    ///   `---idle-a---`        → key=`idle-a`, duration=nil (uses default)
    ///   `---idle-a:750---`    → key=`idle-a`, duration=750 ms
    private static func parseFrames(_ content: String) -> [String: FrameData] {
        var framesByKey: [String: [String]] = [:]
        var durationsByKey: [String: Int] = [:]
        var currentKey: String?
        var currentLines: [String] = []

        func commitCurrent() {
            if let key = currentKey {
                framesByKey[key] = currentLines
            }
        }

        for line in content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("---") && line.hasSuffix("---") && line.count > 6 {
                commitCurrent()
                let inner = String(line.dropFirst(3).dropLast(3))
                // Split into key and optional duration.
                if let colonIdx = inner.firstIndex(of: ":") {
                    let key = String(inner[..<colonIdx])
                    let durStr = String(inner[inner.index(after: colonIdx)...])
                    if let ms = Int(durStr.trimmingCharacters(in: .whitespaces)) {
                        durationsByKey[key] = ms
                    }
                    currentKey = key
                } else {
                    currentKey = inner
                }
                currentLines = []
            } else if line.hasPrefix("#") {
                continue
            } else if currentKey != nil {
                currentLines.append(line)
            }
        }
        commitCurrent()

        // Strip trailing empty lines, then rebalance each frame so the visible
        // content is centered horizontally in a rectangular bounding box:
        //   1. Strip the common leading whitespace across all non-empty lines.
        //   2. Right-pad all lines to the max width (editors strip trailing
        //      whitespace, so we restore it programmatically).
        var result: [String: FrameData] = [:]
        for (k, lines) in framesByKey {
            var trimmed = lines
            while let last = trimmed.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                trimmed.removeLast()
            }

            let nonEmpty = trimmed.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let minLeading = nonEmpty.map { line in
                line.prefix(while: { $0 == " " }).count
            }.min() ?? 0

            let stripped = trimmed.map { line -> String in
                if line.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
                guard line.count >= minLeading else { return line }
                return String(line.dropFirst(minLeading))
            }

            let maxWidth = stripped.map { $0.count }.max() ?? 0
            let padded = stripped.map { line -> String in
                let diff = maxWidth - line.count
                return diff > 0 ? line + String(repeating: " ", count: diff) : line
            }
            result[k] = FrameData(lines: padded, durationMs: durationsByKey[k])
        }
        return result
    }

    // MARK: - Hardcoded defaults (fallback)

    private static let defaultFrames: [String: FrameData] = [
        "idle-a":  FrameData(lines: ["   .----.   ", "  / \u{00B7}  \u{00B7} \\  ", "  |      |  ", "  ~`~``~`~  "], durationMs: nil),
        "idle-b":  FrameData(lines: ["   .----.   ", "  / -  - \\  ",              "  |      |  ", "  ~`~``~`~  "], durationMs: nil),
        "alert-a": FrameData(lines: ["   .----.   ", "  / o  o \\  ",              "  |      |  ", "  ~`~``~`~  "], durationMs: nil),
        "alert-b": FrameData(lines: ["   .----.   ", "  /  o  o\\  ",              "  |      |  ", "  ~`~``~`~  "], durationMs: nil),
        "happy-a": FrameData(lines: ["   .----.   ", "  / ^  ^ \\  ",              "  |      |  ", "  ~`~``~`~  "], durationMs: nil),
        "happy-b": FrameData(lines: ["   .----.   ", "  / ^  ^ \\  ",              "  |  __  |  ", "  ~`~``~`~  "], durationMs: nil),
    ]
}
