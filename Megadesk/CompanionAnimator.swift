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
            if isVisible { stopTimer(); startTimer() }
        }
    }

    /// Which pet's frames to play. Changing it resets the animation and
    /// reloads the frame set.
    var petId: String = CompanionPetRegistry.defaultId {
        didSet {
            frameIndex = 0
            updateFrame()
            if isVisible { stopTimer(); startTimer() }
        }
    }

    private var timer: Timer?
    private var frameIndex: Int = 0

    /// Fallback duration when a frame doesn't declare its own in the JSON.
    private static let fallbackDurationMs: Int = 500

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

    /// Schedules a one-shot timer using the CURRENT frame's own duration so
    /// frame N stays visible for its declared ms before the swap to N+1.
    private func scheduleNext() {
        let frames = currentPetFrames(for: ghostState)
        guard !frames.isEmpty else { return }
        let current = frames[frameIndex % frames.count]
        let ms = current.durationMs ?? defaultDurationMs()
        let interval = TimeInterval(max(50, ms)) / 1000.0

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        let frames = currentPetFrames(for: ghostState)
        frameIndex = (frameIndex + 1) % frames.count
        updateFrame()
        scheduleNext()
    }

    private func updateFrame() {
        let frames = currentPetFrames(for: ghostState)
        guard !frames.isEmpty else { currentFrame = ""; return }
        currentFrame = frames[frameIndex % frames.count].normalized
    }

    // MARK: - Frame lookup

    private func currentPetFrames(for state: GhostState) -> [CompanionPetDefinition.Frame] {
        let registry = CompanionPetRegistry.shared
        let pet = registry.pet(id: petId) ?? registry.defaultPet
        let prefix: String
        switch state {
        case .idle:  prefix = "idle-"
        case .alert: prefix = "alert-"
        case .happy: prefix = "happy-"
        }
        let matching = pet.frames.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }
        return matching.isEmpty ? pet.frames : matching
    }

    private func defaultDurationMs() -> Int {
        let registry = CompanionPetRegistry.shared
        let pet = registry.pet(id: petId) ?? registry.defaultPet
        return pet.defaultDurationMs ?? Self.fallbackDurationMs
    }

}
