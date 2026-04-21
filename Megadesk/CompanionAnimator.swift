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
        }
    }

    private var timer: Timer?
    private var frameIndex: Int = 0

    init() {
        updateFrame()
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let frames = Self.frames(for: ghostState)
        frameIndex = (frameIndex + 1) % frames.count
        updateFrame()
    }

    private func updateFrame() {
        let frames = Self.frames(for: ghostState)
        currentFrame = frames[frameIndex % frames.count].joined(separator: "\n")
    }

    // MARK: - Frame data — 4 rows, 12 chars wide
    //
    //    .----.
    //   / ·  · \
    //   |      |
    //   ~`~``~`~

    private static func frames(for state: GhostState) -> [[String]] {
        switch state {
        case .idle:  return [idleA, idleB]
        case .alert: return [alertA, alertB]
        case .happy: return [happyA, happyB]
        }
    }

    // Idle — slow eye blink
    private static let idleA = [
        "   .----.   ",
        "  / \u{00B7}  \u{00B7} \\  ",
        "  |      |  ",
        "  ~`~``~`~  "
    ]
    private static let idleB = [
        "   .----.   ",
        "  / -  - \\  ",
        "  |      |  ",
        "  ~`~``~`~  "
    ]

    // Alert — eyes open, subtle horizontal tremble
    private static let alertA = [
        "   .----.   ",
        "  / o  o \\  ",
        "  |      |  ",
        "  ~`~``~`~  "
    ]
    private static let alertB = [
        "   .----.   ",
        "  /  o  o\\  ",
        "  |      |  ",
        "  ~`~``~`~  "
    ]

    // Happy — curved eyes, smile appears
    private static let happyA = [
        "   .----.   ",
        "  / ^  ^ \\  ",
        "  |      |  ",
        "  ~`~``~`~  "
    ]
    private static let happyB = [
        "   .----.   ",
        "  / ^  ^ \\  ",
        "  |  __  |  ",
        "  ~`~``~`~  "
    ]
}
