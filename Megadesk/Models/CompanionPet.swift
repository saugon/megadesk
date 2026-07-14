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

        // Below are optional and shared a single global cooldown so adding many
        // new rules at once doesn't turn the pet into a chatterbox. A pet that
        // omits any of these simply skips the corresponding rule.

        // Event-driven session signals
        let sessionNew: String?               // {name}
        let sessionFinishedAfterLong: String? // {name}, {duration}
        let sessionConfirmation: String?      // {name}

        // Event-driven PR signals (prMerged is the legacy field, kept above)
        let prOpened: String?              // {prTitle}
        let prClosedWithoutMerge: String?  // {prTitle}
        let prCIRecovered: String?         // {prTitle}
        let prCIRegressed: String?         // {prTitle}

        // Duration tiers (timer-driven)
        let sessionWorkingLong: String?         // {name}, {duration}  — > 30 min
        let sessionWorkingVeryLong: String?     // {name}, {duration}  — > 2 h
        let sessionConfirmationStuck: String?   // {name}, {duration}  — > 5 min

        // Ambient / time-of-day / stretch (timer-driven)
        let ambientFiller: [String]?
        let ambientBored: [String]?
        let ambientHumor: [String]?
        let ambientObservation: [String]?      // optional {count}
        let morningGreeting: String?
        let afternoonSlump: String?
        let endOfDay: String?
        let lateNight: String?
        let stretchReminder: String?           // {duration}
    }

    struct Frame: Codable {
        let key: String
        let durationMs: Int?
        let lines: [String]

        /// Lines with common leading whitespace stripped and right-padded to a
        /// rectangular bounding box, so the art stays centered when rendered
        /// in a monospace text view. Use this when displaying a frame from
        /// outside the animator.
        var normalizedLines: [String] {
            guard !lines.isEmpty else { return [] }

            let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let minLeading = nonEmpty.map { line in
                line.prefix(while: { $0 == " " }).count
            }.min() ?? 0

            let stripped = lines.map { line -> String in
                if line.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
                guard line.count >= minLeading else { return line }
                return String(line.dropFirst(minLeading))
            }

            let maxWidth = stripped.map { $0.count }.max() ?? 0
            return stripped.map { line -> String in
                let diff = maxWidth - line.count
                return diff > 0 ? line + String(repeating: " ", count: diff) : line
            }
        }

        var normalized: String { normalizedLines.joined(separator: "\n") }
    }

    /// First idle frame, used for static previews (e.g. the picker grid).
    /// Falls back to the very first frame if no `idle-*` frame exists.
    var previewFrame: Frame? {
        frames.first { $0.key.hasPrefix("idle-") } ?? frames.first
    }

    /// Description of one optional voice key — what triggers it and which
    /// placeholders are available — used by both the README/prompt docs and
    /// the in-app "update existing pet" flow.
    struct OptionalVoiceKey {
        let key: String
        let trigger: String
        let placeholders: String   // human-readable, e.g. "{name}, {duration}" or "(none)"
        let isArray: Bool
    }

    /// Catalogue of every optional voice key known to the engine. Stays in
    /// sync with `VoiceTemplates` and the rule implementations.
    static let optionalVoiceCatalog: [OptionalVoiceKey] = [
        .init(key: "sessionNew",               trigger: "a new session appears in the widget",                       placeholders: "{name}",            isArray: false),
        .init(key: "sessionFinishedAfterLong", trigger: "a session that was Working for a while moves out of working", placeholders: "{name}, {duration}", isArray: false),
        .init(key: "sessionConfirmation",      trigger: "a session enters \"Needs Confirmation\"",                    placeholders: "{name}",            isArray: false),
        .init(key: "prOpened",                 trigger: "a PR appears in the tracked list",                            placeholders: "{prTitle}",          isArray: false),
        .init(key: "prClosedWithoutMerge",     trigger: "a PR transitions to CLOSED (not merged)",                     placeholders: "{prTitle}",          isArray: false),
        .init(key: "prCIRecovered",            trigger: "CI flips from failing to passing",                            placeholders: "{prTitle}",          isArray: false),
        .init(key: "prCIRegressed",            trigger: "CI flips from passing to failing",                            placeholders: "{prTitle}",          isArray: false),
        .init(key: "sessionWorkingLong",       trigger: "a session has been working > 30 min",                         placeholders: "{name}, {duration}", isArray: false),
        .init(key: "sessionWorkingVeryLong",   trigger: "a session has been working > 2 h",                            placeholders: "{name}, {duration}", isArray: false),
        .init(key: "sessionConfirmationStuck", trigger: "a confirmation request has been waiting > 5 min",             placeholders: "{name}, {duration}", isArray: false),
        .init(key: "ambientFiller",            trigger: "quiet pad — generic chatter when nothing is happening",       placeholders: "(none)",             isArray: true),
        .init(key: "ambientBored",             trigger: "quiet pad — the pet complains about boredom",                 placeholders: "(none)",             isArray: true),
        .init(key: "ambientHumor",             trigger: "quiet pad — programming jokes / one-liners",                  placeholders: "(none)",             isArray: true),
        .init(key: "ambientObservation",       trigger: "quiet pad — comments on widget state",                        placeholders: "{count}",            isArray: true),
        .init(key: "morningGreeting",          trigger: "first idle tick after 8am",                                    placeholders: "(none)",             isArray: false),
        .init(key: "afternoonSlump",           trigger: "first idle tick after 14h",                                    placeholders: "(none)",             isArray: false),
        .init(key: "endOfDay",                 trigger: "first idle tick after 18h",                                    placeholders: "(none)",             isArray: false),
        .init(key: "lateNight",                trigger: "first idle tick after 22h",                                    placeholders: "(none)",             isArray: false),
        .init(key: "stretchReminder",          trigger: "user has been continuously idle > 90 min",                    placeholders: "{duration}",         isArray: false),
    ]

    /// Returns the optional voice keys that this pet is currently missing.
    /// Empty arrays for `[String]?` keys also count as missing so the user
    /// can opt-in by deleting the field instead of leaving an empty array.
    var missingOptionalVoiceKeys: [OptionalVoiceKey] {
        Self.optionalVoiceCatalog.filter { entry in
            switch entry.key {
            case "sessionNew":               return voice.sessionNew == nil
            case "sessionFinishedAfterLong": return voice.sessionFinishedAfterLong == nil
            case "sessionConfirmation":      return voice.sessionConfirmation == nil
            case "prOpened":                 return voice.prOpened == nil
            case "prClosedWithoutMerge":     return voice.prClosedWithoutMerge == nil
            case "prCIRecovered":            return voice.prCIRecovered == nil
            case "prCIRegressed":            return voice.prCIRegressed == nil
            case "sessionWorkingLong":       return voice.sessionWorkingLong == nil
            case "sessionWorkingVeryLong":   return voice.sessionWorkingVeryLong == nil
            case "sessionConfirmationStuck": return voice.sessionConfirmationStuck == nil
            case "ambientFiller":            return (voice.ambientFiller ?? []).isEmpty
            case "ambientBored":             return (voice.ambientBored ?? []).isEmpty
            case "ambientHumor":             return (voice.ambientHumor ?? []).isEmpty
            case "ambientObservation":       return (voice.ambientObservation ?? []).isEmpty
            case "morningGreeting":          return voice.morningGreeting == nil
            case "afternoonSlump":           return voice.afternoonSlump == nil
            case "endOfDay":                 return voice.endOfDay == nil
            case "lateNight":                return voice.lateNight == nil
            case "stretchReminder":          return voice.stretchReminder == nil
            default:                         return false
            }
        }
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
    private static let bundledIds: [String] = ["brume", "pixel", "mochi", "dwight"]

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

    /// Builds an LLM prompt that asks for ONLY the missing optional voice
    /// keys for the given pet, written in the same voice as its existing
    /// templates. Returns nil if the pet is already complete.
    static func voiceUpdatePrompt(for pet: CompanionPetDefinition) -> String? {
        let missing = pet.missingOptionalVoiceKeys
        guard !missing.isEmpty else { return nil }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let petJSON = (try? encoder.encode(pet))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "(failed to encode existing pet)"

        let table = missing.map { entry in
            let kind = entry.isArray ? " (array of strings)" : ""
            return "- \(entry.key)\(kind) — \(entry.trigger). Placeholders: \(entry.placeholders)."
        }.joined(separator: "\n")

        let exampleObject = missing.map { entry -> String in
            if entry.isArray {
                return "  \"\(entry.key)\": [\"…\", \"…\"]"
            }
            return "  \"\(entry.key)\": \"…\""
        }.joined(separator: ",\n")

        return """
        You are extending an existing Megadesk companion pet by adding new
        voice templates while preserving everything else exactly as it is.

        ## Output

        Return the COMPLETE updated pet JSON — a single JSON object that the
        user can drop in to replace the existing file. No prose, no
        commentary, no code fences. Escape backslashes as \\\\ and
        double-quotes as \\\" inside strings.

        Rules — strict:
        1. Copy the existing pet verbatim: keep `id`, `displayName`,
           `defaultDurationMs`, every existing `voice` template, and every
           entry in `frames` byte-for-byte (including whitespace inside
           lines).
        2. Inside the existing `voice` object, ADD the new keys listed
           below. Do not remove any existing voice key.
        3. Do not invent new keys outside the list below. Do not add fields
           outside the schema.

        Write the new templates in the same tone, cadence, language, and
        style as the existing voice. Short is better.

        ## Existing pet

        \(petJSON)

        ## Voice keys to add (currently missing)

        \(table)

        Each placeholder shown in braces (e.g. `{name}`, `{duration}`,
        `{prTitle}`, `{count}`) is substituted at runtime. Use only the
        placeholders listed for each key; do not invent new ones.

        Array-typed keys are pools — return 2-4 short variants per array.

        ## Skeleton of the new keys

        These will live INSIDE the `voice` object alongside the existing
        templates. Replace the `…` with text in the pet's voice; do not
        change key names.

        {
        \(exampleObject)
        }

        Output the full updated pet JSON now.
        """
    }

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
        // ── Required ──
        "waitingTooLong":    "…{name}… {duration}…",
        "multipleWaiting":   "…{count}… {oldest}…",
        "stuckWorking":      "…{name}… {duration}…",
        "prCIFailing":       "…{prTitle}…",
        "prConflicts":       "…{prTitle}…",
        "userIdle":          "…",
        "allForgotten":      "…",
        "firstSessionOfDay": "…",
        "prMerged":          "…{prTitle}…",

        // ── Optional (rule skipped if omitted; share a global cooldown) ──
        "sessionNew":               "…{name}…",
        "sessionFinishedAfterLong": "…{name}… {duration}…",
        "sessionConfirmation":      "…{name}…",
        "prOpened":                 "…{prTitle}…",
        "prClosedWithoutMerge":     "…{prTitle}…",
        "prCIRecovered":            "…{prTitle}…",
        "prCIRegressed":            "…{prTitle}…",
        "sessionWorkingLong":       "…{name}… {duration}…",
        "sessionWorkingVeryLong":   "…{name}… {duration}…",
        "sessionConfirmationStuck": "…{name}… {duration}…",
        "ambientFiller":     ["…", "…"],
        "ambientBored":      ["…", "…"],
        "ambientHumor":      ["…", "…"],
        "ambientObservation":["… {count} …"],
        "morningGreeting":   "…",
        "afternoonSlump":    "…",
        "endOfDay":          "…",
        "lateNight":         "…",
        "stretchReminder":   "…{duration}…"
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

    Each template is a string (or array of strings, for ambient categories)
    with placeholders in braces. Unknown placeholders are left as-is so
    typos stay visible. Available placeholders per rule:

      Required:
        waitingTooLong            {name}, {duration}
        multipleWaiting           {count}, {oldest}
        stuckWorking              {name}, {duration}
        prCIFailing               {prTitle}
        prConflicts               {prTitle}
        prMerged                  {prTitle}
        userIdle                  (none)
        allForgotten              (none)
        firstSessionOfDay         (none)

      Optional event-driven:
        sessionNew                {name}
        sessionFinishedAfterLong  {name}, {duration}
        sessionConfirmation       {name}
        prOpened                  {prTitle}
        prClosedWithoutMerge      {prTitle}
        prCIRecovered             {prTitle}
        prCIRegressed             {prTitle}

      Optional duration-tier:
        sessionWorkingLong        {name}, {duration}  (> 30 min)
        sessionWorkingVeryLong    {name}, {duration}  (> 2 h)
        sessionConfirmationStuck  {name}, {duration}  (> 5 min)

      Optional ambient / time-of-day / stretch:
        ambientFiller, ambientBored, ambientHumor, ambientObservation
                                  arrays of strings; observation can use {count}
        morningGreeting, afternoonSlump, endOfDay, lateNight   (none)
        stretchReminder           {duration}

    All optional rules share a single global cooldown so the pet stays calm
    even with many of them defined.

    ## Overriding built-in pets

    If you set `id` to one of the built-in ids (brume, pixel, mochi, dwight), your
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
        // ── Required ──
        "waitingTooLong":    "… {name} … {duration} …",
        "multipleWaiting":   "… {count} … {oldest} …",
        "stuckWorking":      "… {name} … {duration} …",
        "prCIFailing":       "… {prTitle} …",
        "prConflicts":       "… {prTitle} …",
        "userIdle":          "…",
        "allForgotten":      "…",
        "firstSessionOfDay": "…",
        "prMerged":          "… {prTitle} …",

        // ── Optional (omit a key to disable that rule for this pet) ──
        "sessionNew":               "… {name} …",
        "sessionFinishedAfterLong": "… {name} … {duration} …",
        "sessionConfirmation":      "… {name} …",
        "prOpened":                 "… {prTitle} …",
        "prClosedWithoutMerge":     "… {prTitle} …",
        "prCIRecovered":            "… {prTitle} …",
        "prCIRegressed":            "… {prTitle} …",
        "sessionWorkingLong":       "… {name} … {duration} …",
        "sessionWorkingVeryLong":   "… {name} … {duration} …",
        "sessionConfirmationStuck": "… {name} … {duration} …",
        "ambientFiller":            ["…", "…"],
        "ambientBored":             ["…", "…"],
        "ambientHumor":             ["…", "…"],
        "ambientObservation":       ["… {count} …"],
        "morningGreeting":          "…",
        "afternoonSlump":           "…",
        "endOfDay":                 "…",
        "lateNight":                "…",
        "stretchReminder":          "… {duration} …"
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

    Required:

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

    Optional (sharing one global cooldown — the pet won't fire more than
    one of these every ~minute):

    | Key                       | Trigger                                          | Placeholders       |
    |---------------------------|--------------------------------------------------|--------------------|
    | sessionNew                | a new session appears in the widget              | {name}             |
    | sessionFinishedAfterLong  | a long-Working session moves out of working      | {name} {duration}  |
    | sessionConfirmation       | a session enters "Needs Confirmation"            | {name}             |
    | prOpened                  | a PR appears in the tracked list                 | {prTitle}          |
    | prClosedWithoutMerge      | a PR moves to CLOSED (not MERGED)                | {prTitle}          |
    | prCIRecovered             | CI flips from failing → passing                  | {prTitle}          |
    | prCIRegressed             | CI flips from passing → failing                  | {prTitle}          |
    | sessionWorkingLong        | a session has been working > 30 min              | {name} {duration}  |
    | sessionWorkingVeryLong    | a session has been working > 2 h                 | {name} {duration}  |
    | sessionConfirmationStuck  | a confirmation request has waited > 5 min        | {name} {duration}  |
    | ambientFiller             | quiet pad (filler chatter when nothing happens)  | (none)             |
    | ambientBored              | quiet pad (the pet complains about boredom)      | (none)             |
    | ambientHumor              | quiet pad (programming jokes / one-liners)       | (none)             |
    | ambientObservation        | quiet pad (comments on widget state)             | optional {count}   |
    | morningGreeting           | first idle tick after 8am                        | (none)             |
    | afternoonSlump            | first idle tick after 14h                        | (none)             |
    | endOfDay                  | first idle tick after 18h                        | (none)             |
    | lateNight                 | first idle tick after 22h                        | (none)             |
    | stretchReminder           | user has been continuously idle > 90 min         | {duration}         |

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
        "prMerged":          "{prTitle} merged. Nice.",
        "sessionNew":               "New session: {name}.",
        "sessionFinishedAfterLong": "{name} finished after {duration}. Phew.",
        "sessionConfirmation":      "{name} is asking for your input.",
        "prOpened":                 "Tracking {prTitle}.",
        "prClosedWithoutMerge":     "{prTitle} closed without merging.",
        "prCIRecovered":            "CI is back to green on {prTitle}.",
        "prCIRegressed":            "CI just broke on {prTitle}.",
        "sessionWorkingLong":       "{name} has been working {duration} — going well?",
        "sessionWorkingVeryLong":   "{name} has been working {duration}. That's a lot.",
        "sessionConfirmationStuck": "{name} has been waiting on you for {duration}.",
        "ambientFiller":      ["Quiet day so far.", "Nice rhythm.", "All steady."],
        "ambientBored":       ["I'm bored.", "Anything happening?"],
        "ambientHumor":       ["Tabs vs spaces… still no winner.", "I dreamt I was a semicolon."],
        "ambientObservation": ["{count} sessions on the board.", "The board is empty."],
        "morningGreeting":    "Good morning. Coffee?",
        "afternoonSlump":     "3pm slump. Walk?",
        "endOfDay":           "Evening already. Wrapping up?",
        "lateNight":          "It's late. Take care of yourself.",
        "stretchReminder":    "You've been still for {duration}. Stretch?"
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
