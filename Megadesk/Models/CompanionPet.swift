import Foundation
import Observation

/// One pet as loaded from a `<id>.json` file (bundled in `Megadesk/Pets/` or
/// dropped into the user's pets folder).
///
/// The definition covers everything that makes a pet distinct: its identity
/// (id, displayName), animation frames, default frame duration, and the voice
/// templates that drive what it "says" for each rule. Adding a new pet is a
/// single new JSON — no Swift changes required.
struct CompanionPetDefinition: Codable, Identifiable {
    let id: String
    let displayName: String
    let defaultDurationMs: Int?
    let voice: VoiceTemplates
    let frames: [Frame]

    struct VoiceTemplates: Codable {
        let waitingTooLong: String
        let multipleWaiting: String
        let stuckWorking: String
        let prCIFailing: String
        let prConflicts: String
        let userIdle: String
        let allForgotten: String
        let firstSessionOfDay: String
        let prMerged: String
    }

    struct Frame: Codable {
        let key: String
        let durationMs: Int?
        let lines: [String]
    }
}

/// Registry of pets, loaded from two sources:
///   1. The app bundle (`Megadesk/Pets/*.json`) — the built-in roster.
///   2. `~/.claude/megadesk/pets/*.json` — user-provided pets.
/// User pets with the same `id` as a bundled pet override the bundled one,
/// so users can tweak a built-in without editing the app.
///
/// Loading is on-demand: bundled + user JSONs are read at init, and the
/// user can call `reload()` from Settings after editing files.
@Observable
final class CompanionPetRegistry {
    static let shared = CompanionPetRegistry()

    /// All pets available for selection. Bundled appear in the order declared
    /// below; user-only pets follow, sorted by display name.
    private(set) var all: [CompanionPetDefinition] = []

    /// Default pet id used when no selection is saved yet (or the saved id is
    /// no longer available, e.g. a user deleted their custom pet).
    static let defaultId: String = "brume"

    /// Pets shipped with the app, in the order they should appear in the picker.
    private static let bundledIds: [String] = ["brume", "pixel", "mochi"]

    /// Directory where users can drop their own pet JSONs.
    let userPetsURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/megadesk/pets")
    }()

    private init() {
        ensureUserDirectory()
        reload()
    }

    func pet(id: String) -> CompanionPetDefinition? {
        all.first { $0.id == id }
    }

    var defaultPet: CompanionPetDefinition {
        pet(id: Self.defaultId) ?? all.first!
    }

    /// Reloads bundled + user pets. Called once at startup and on-demand
    /// from Settings (the "Reload" button) after the user adds or edits
    /// a JSON in the user pets folder.
    func reload() {
        var byId: [String: CompanionPetDefinition] = [:]

        // Bundled first.
        for id in Self.bundledIds {
            if let pet = loadFromBundle(id: id) {
                byId[pet.id] = pet
            }
        }

        // User pets override bundled by id.
        for pet in loadFromUserDirectory() {
            byId[pet.id] = pet
        }

        let bundled = Self.bundledIds.compactMap { byId[$0] }
        let userOnly = byId.values
            .filter { !Self.bundledIds.contains($0.id) }
            .sorted { $0.displayName < $1.displayName }

        all = bundled + Array(userOnly)
    }

    // MARK: - Loading

    private func loadFromBundle(id: String) -> CompanionPetDefinition? {
        guard let url = Bundle.main.url(forResource: id, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CompanionPetDefinition.self, from: data)
    }

    private func loadFromUserDirectory() -> [CompanionPetDefinition] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: userPetsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url -> CompanionPetDefinition? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(CompanionPetDefinition.self, from: data)
            }
    }

    // MARK: - User directory setup

    private func ensureUserDirectory() {
        let fm = FileManager.default
        try? fm.createDirectory(at: userPetsURL, withIntermediateDirectories: true)

        // Drop a README on first run so users know the format.
        let readmeURL = userPetsURL.appendingPathComponent("README.txt")
        if !fm.fileExists(atPath: readmeURL.path) {
            try? Self.readmeContents.write(to: readmeURL, atomically: true, encoding: .utf8)
        }

        // Drop the LLM prompt so users can open it directly and paste it
        // into Claude / ChatGPT / etc.
        let promptURL = userPetsURL.appendingPathComponent("LLM_PROMPT.md")
        if !fm.fileExists(atPath: promptURL.path) {
            try? Self.llmPromptContents.write(to: promptURL, atomically: true, encoding: .utf8)
        }
    }

    /// The full prompt users can paste into an LLM (Claude, ChatGPT, …) to
    /// have it generate a pet JSON that fits Megadesk's schema. Exposed as a
    /// public computed property so the Settings UI can copy it to the
    /// clipboard with one click.
    static var llmPrompt: String { llmPromptContents }

    // MARK: - README template

    private static let readmeContents: String = """
    # Megadesk Custom Pets

    Drop any `<id>.json` file in this folder to add or override a companion pet.
    After editing, click "Reload" in Settings → Companion to pick up changes.

    ## JSON schema

    {
      "id": "myPet",                 // must be unique; also the file stem
      "displayName": "My Pet",       // shown in Settings → Companion → Pet
      "defaultDurationMs": 500,      // optional; falls back to 500ms per frame
      "voice": {
        "waitingTooLong":    "…{name}… {duration}…",
        "multipleWaiting":   "…{count}… {oldest}…",
        "stuckWorking":      "…{name}… {duration}…",
        "prCIFailing":       "…{prTitle}…",
        "prConflicts":       "…{prTitle}…",
        "userIdle":          "…",
        "allForgotten":      "…",
        "firstSessionOfDay": "…",
        "prMerged":          "…{prTitle}…"
      },
      "frames": [
        { "key": "idle-a",  "durationMs": 500, "lines": ["…", "…"] },
        { "key": "idle-b",  "durationMs": 500, "lines": ["…", "…"] },
        { "key": "alert-a", "durationMs": 500, "lines": ["…", "…"] },
        { "key": "alert-b", "durationMs": 500, "lines": ["…", "…"] },
        { "key": "happy-a", "durationMs": 500, "lines": ["…", "…"] },
        { "key": "happy-b", "durationMs": 500, "lines": ["…", "…"] }
      ]
    }

    ## Frames

    The animator cycles through every frame whose key starts with the current
    state's prefix (`idle-*`, `alert-*`, `happy-*`) in alphabetical order.
    Add as many variants as you want (e.g. `idle-c`, `idle-d`). Each frame's
    `durationMs` controls how long it stays on screen.

    Lines are strings of ASCII characters. Leading whitespace common to all
    lines is stripped and everything is right-padded so the art stays centered.

    ## Voice

    Each template is a string with placeholders in braces. Available
    placeholders per rule:

      waitingTooLong    {name}, {duration}
      multipleWaiting   {count}, {oldest}
      stuckWorking      {name}, {duration}
      prCIFailing       {prTitle}
      prConflicts       {prTitle}
      prMerged          {prTitle}
      userIdle          (none)
      allForgotten      (none)
      firstSessionOfDay (none)

    Unknown placeholders are left as-is so typos stay visible.

    ## Overriding built-in pets

    If you set `id` to one of the built-in ids (brume, pixel, mochi), your
    file takes precedence over the bundled version.

    ## Generating a pet with an LLM

    See `LLM_PROMPT.md` in this folder. Paste it into Claude, ChatGPT, or
    any other LLM, append a short brief describing the pet you want, and
    the model returns a ready-to-save JSON.
    """

    // MARK: - LLM Prompt

    private static let llmPromptContents: String = #"""
    # Megadesk Companion Pet — LLM Prompt

    Paste this entire prompt into Claude, ChatGPT, or another LLM, then
    append your creative brief at the bottom. The LLM will output a JSON
    you can save as `<yourPetId>.json` in the Megadesk pets folder.

    ---

    You are generating a Megadesk companion pet definition.

    Megadesk is a macOS widget that tracks coding sessions, pull requests,
    and alerts. A companion is a small ASCII-art pet that lives in the
    widget and comments on what's happening (sessions waiting for input,
    PRs merging, long working sessions, etc.). Each pet has its own
    animation frames and its own "voice" — the phrases it uses when events
    fire.

    ## Output

    Return ONLY a valid JSON object. No prose, no explanation, no code
    fences. The JSON must parse with `JSONDecoder` and match the schema
    below. Escape backslashes as `\\` and double-quotes as `\"` inside
    strings.

    ## Schema

    {
      "id": "<lowercase, file-safe identifier>",
      "displayName": "<name shown in the Pet picker>",
      "defaultDurationMs": 500,
      "voice": {
        "waitingTooLong":    "… {name} … {duration} …",
        "multipleWaiting":   "… {count} … {oldest} …",
        "stuckWorking":      "… {name} … {duration} …",
        "prCIFailing":       "… {prTitle} …",
        "prConflicts":       "… {prTitle} …",
        "userIdle":          "…",
        "allForgotten":      "…",
        "firstSessionOfDay": "…",
        "prMerged":          "… {prTitle} …"
      },
      "frames": [
        { "key": "idle-a",  "durationMs": 2000, "lines": ["…", "…"] },
        { "key": "idle-b",  "durationMs": 150,  "lines": ["…", "…"] },
        { "key": "alert-a", "durationMs": 500,  "lines": ["…", "…"] },
        { "key": "alert-b", "durationMs": 500,  "lines": ["…", "…"] },
        { "key": "happy-a", "durationMs": 500,  "lines": ["…", "…"] },
        { "key": "happy-b", "durationMs": 500,  "lines": ["…", "…"] }
      ]
    }

    ## Voice — when each template fires

    | Key                | Trigger                                 | Placeholders       |
    |--------------------|-----------------------------------------|--------------------|
    | waitingTooLong     | a session has waited for input > 15min  | {name} {duration}  |
    | multipleWaiting    | 3+ sessions waiting simultaneously      | {count} {oldest}   |
    | stuckWorking       | a session has been working > 30min      | {name} {duration}  |
    | prCIFailing        | a tracked PR's CI turned failing        | {prTitle}          |
    | prConflicts        | a tracked PR has merge conflicts        | {prTitle}          |
    | userIdle           | no session activity for > 45min         | (none)             |
    | allForgotten       | all sessions marked forgotten           | (none)             |
    | firstSessionOfDay  | first session of the calendar day       | (none)             |
    | prMerged           | a tracked PR was merged                 | {prTitle}          |

    Write every line in the pet's voice — consistent personality, tone,
    and language. Short is better.

    ## Frames

    Three states: `idle`, `alert`, `happy`. Each state needs at least 2
    frames with keys matching the state prefix plus a letter (`idle-a`,
    `idle-b`, …). Frames cycle in alphabetical key order; you can add
    more (`idle-c`, `idle-d`, …) to make the loop richer.

    `durationMs` controls how long each frame stays on screen. Mix short
    and long durations to create life — e.g. eyes-open at 2000ms plus a
    blink at 150ms gives a subtle pulse every 2 seconds.

    Keep art at most ~14 chars wide and ~8 lines tall. Use only
    monospace-safe ASCII / common Unicode symbols (·, ♥, ★, etc.).
    Common leading whitespace is auto-stripped and lines are right-padded
    to a rectangle, so you can center art visually without worrying about
    trailing spaces.

    ## Reference: Brume (built-in friendly ghost)

    {
      "id": "brume",
      "displayName": "Brume",
      "defaultDurationMs": 500,
      "voice": {
        "waitingTooLong":    "Hey — {name} has been waiting for you for {duration}.",
        "multipleWaiting":   "You have {count} sessions waiting. Oldest is {oldest}.",
        "stuckWorking":      "{name} has been working for {duration}. Might be stuck.",
        "prCIFailing":       "CI is failing on {prTitle}.",
        "prConflicts":       "{prTitle} has merge conflicts.",
        "userIdle":          "Still there?",
        "allForgotten":      "All quiet. Good time for a break.",
        "firstSessionOfDay": "Hey! Let's get to work.",
        "prMerged":          "{prTitle} merged. Nice."
      },
      "frames": [
        { "key": "idle-a",  "durationMs": 2500, "lines": ["", "", "   .----.", "  / ·  · \\", "  |      |", "  ~`~``~`~"] },
        { "key": "idle-b",  "durationMs": 1000, "lines": ["", "    ~  ~", "   .----.", "  / ·  · \\", "  |      |", "  ~~`~~`~~"] },
        { "key": "alert-a", "durationMs": 500,  "lines": ["", "", "   .----.", "  / o  o \\", "  |      |", "  ~`~``~`~"] },
        { "key": "alert-b", "durationMs": 500,  "lines": ["", "", "   .----.", "  /  o  o\\", "  |      |", "  ~`~``~`~"] },
        { "key": "happy-a", "durationMs": 500,  "lines": ["", "", "   .----.", "  / ^  ^ \\", "  |      |", "  ~`~``~`~"] },
        { "key": "happy-b", "durationMs": 500,  "lines": ["", "    ~  ~", "   .----.", "  / ^  ^ \\", "  |      |", "  ~~`~~`~~"] }
      ]
    }

    ---

    ## Your brief

    Generate a pet matching the following description. Pay attention to
    personality, language, tone, and visual style. The tone should be
    consistent across every voice line and the art should feel like the
    character the brief describes.

    <PASTE YOUR BRIEF HERE — e.g. "a grumpy dragon that complains in
     medieval English", "a sleepy capybara who speaks in Spanish", "a
     paranoid robot that treats every event as an emergency", etc.>

    Output the JSON now.
    """#
}

/// Light-weight interpolation that replaces `{key}` placeholders with the
/// matching value from the dictionary. Keys not present are left as-is so
/// missing substitutions stay visible and debuggable.
extension String {
    func filling(_ values: [String: String]) -> String {
        var result = self
        for (key, value) in values {
            result = result.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return result
    }
}
