# AGENTS.md

Guide for coding agents working on Tidy Parrot. It's a macOS menu-bar app: tap fn, speak, tap fn again, and the
text is pasted into the focused field. Speech-to-text runs locally. The app is Swift (`app/`), and the model runs in a
Python + MLX helper process (`helper/`). [README.md](README.md) is the user-facing doc.

## Commands

Run everything through `make`; `make help` lists every target.

| Command | What it does |
|---|---|
| `make setup` | One time: creates the helper venv and downloads the pinned model (~806 MB) |
| `make build` / `make run` | Builds `build/TidyParrot.app` / also quits the running copy and opens the new one. Add `VERBATIM=1` to keep fillers |
| `make icon` | Regenerates the committed `app/Resources/AppIcon.icns` from `AppIcon.png`. Run it after changing the artwork |
| `make test` | Swift unit tests plus Python protocol tests. Fast, and needs no model |
| `make lint` / `make format` | swift-format with `.swift-format`. Lint is `--strict` |
| `make integration WAV=clip.wav` | Swift engine against the real helper and model |
| `make smoke WAV=clip.wav` | Python helper alone, over its stdin protocol |

Before you finish a change, run `make lint test`. If you touched the helper, the protocol or the engine, also run
`make integration`. You can make a test clip with
`say -o clip.wav --data-format=LEF32@48000 "Um, I I think so."`.

SwiftPM's own sandbox fails inside another sandbox with `sandbox_apply: Operation not permitted`. If you see that, run
the Swift commands outside your sandbox.

## Architecture

```
GlobalHotkeyMonitor ─toggle/cancel────────► DictationController ─► MicrophoneRecorder  (AVAudioEngine → 16 kHz clip)
                                                   │              ─► TranscriptionEngine (HelperProcessEngine ⇄ Python)
                                                   │              ─► PasteboardTextInserter (clipboard + ⌘V, then restore)
                                                   └─ AppStatus / messages ─► StatusMenu, RecordingIndicator
```

- **`app/Sources/TidyParrot/main.swift`**: starts `NSApplication`. Nothing else goes here.
- **`app/Sources/TidyParrotCore/`**: all app code, in one folder per concern:
  - `App/`: `AppDelegate` is the **composition root**, the only place that creates live implementations.
  - `Dictation/`: `DictationController` owns all state and runs the pipeline. `DictationSettings` holds its tunables.
    `AppStatus` is the derived status and its menu text.
  - `Audio/`: `AudioRecording` protocol, `MicrophoneRecorder`, `Resampler`, and `AudioClip` (mono float32 at 16 kHz).
    `AudioLevel` maps loudness to 0–1, and `LevelMeter` turns the tap's audio into one level per 50 ms for the
    on-screen meter.
  - `Transcription/`: `TranscriptionEngine` protocol and `HelperProcessEngine`, the Python subprocess. Also
    `HelperProtocol`, the wire format, and `UnavailableEngine`, a stand-in used when the Info.plist keys from
    `scripts/build.sh` are missing.
  - `Input/`: `HotkeySource` protocol, `GlobalHotkeyMonitor` (NSEvent), and `TapToToggleDetector`, the tap logic.
  - `Output/`: `TextInserting` protocol and `PasteboardTextInserter`. `FocusedInputChecking` protocol and
    `AccessibilityFocusedInput`, which refuses recording only for roles that never take text, and fails open
    otherwise. `SystemSounds` maps each `FeedbackSound` to a built-in macOS sound.
  - `Permissions/`: `PermissionsProviding` protocol and `SystemPermissions` (microphone and Accessibility).
  - `UI/`: `StatusMenu` and `RecordingIndicator`, which show what they're told. `RecordingIndicator` is the pill
    with level bars and a timer, shown while listening. It must never take focus, or the paste lands in the wrong
    app. `LevelBars` holds its animation as pure state.
  - `Support/`: `Log`.
- **`helper/`**:
  - `tidy_parrot_helper.py` loads the model once and serves clips.
  - `wire_protocol.py` holds the framing and serve loop, with no MLX, so it's testable.
  - `vendor/fluid_speech_mlx.py` is the upstream loader. **Unmodified; don't edit.**
- **`scripts/`**:
  - `build.sh` assembles the `.app` from `app/Resources/Info.plist`. It adds the helper paths with `plutil` and
    signs the bundle with the `Tidy Parrot Dev` certificate (or `SIGN_IDENTITY`), falling back to ad hoc.
  - `setup.sh` creates the venv and downloads the model.
- **`app/Resources/MenuBarIcon.pdf`**: the menu bar template image, the Fluent UI Emoji parrot (MIT, see
  `MenuBarIcon-LICENSE.txt`, which `build.sh` also copies into the bundle). Keep it one color so macOS can tint it.

### Helper protocol

The protocol is defined twice: `helper/wire_protocol.py` (Python) and `HelperProtocol.swift` (Swift). **Change both
together** and update the tests on both sides.

1. At startup the helper sends one JSON line: either `{"ready", "load_ms", "clean_mode"}`, or `{"error"}` before it
   exits.
2. For each clip, the app sends a little-endian `UInt32` byte count followed by float32 PCM.
3. The helper answers each clip with one JSON line: `{"text", "ms"}` or `{"error"}`.

When stdin closes, the helper exits. The helper writes logs to stderr, which goes to `~/Library/Logs/TidyParrot.log`.

## Conventions

- **Swift 6 language mode, strict concurrency, zero warnings.**
  - UI, state and every protocol are `@MainActor`.
  - Blocking work goes off the main actor explicitly: the helper's pipe I/O runs on a serial `DispatchQueue`.
  - The audio tap closure is built in a `nonisolated` function. A closure formed on the main actor inherits that
    isolation, and it traps when Core Audio calls it on the audio thread.
  - Avoid `@unchecked Sendable`. If you can't, explain why it's safe in a `// Safety:` comment, as in
    `HelperConnection`.
- **Dependency injection by initializer.** Every system boundary reaches `DictationController` through
  `Dependencies`: hotkey, mic, engine, paste, permissions and focus as small protocols, and feedback sounds as a
  closure. Tests use the fakes in `Tests/.../Fakes.swift`. Don't reach for singletons or `shared` from inside the
  core. `Log` is the one deliberate exception: a file append, and tests may write to the real log.
- **Internal by default.** Only `AppDelegate` is `public`, because `main.swift` is in another module. Tests use
  `@testable import`.
- **Keep protocols small.** Add a method only when a caller needs it. Extend an existing type rather than adding a
  parallel one that does the same job.
- **Keep logic pure where you can.** `TapToToggleDetector`, `HelperProtocol`, `AppStatus.presentation` and
  `HelperProcessEngine.Configuration(infoDictionary:)` have no side effects and get table-style tests. Follow that
  pattern for new logic.
- **Testing:**
  - Use Swift Testing (`import Testing`, `@Test`, `#expect`), not XCTest.
  - Test failure and refusal paths as well as the happy path.
  - Wait for a condition with `waitUntil`. Use a fixed sleep only to show that something *doesn't* happen. Never touch the user's clipboard, keyboard or focused
    app from a test: `PasteboardTextInserterTests` uses a private pasteboard and a fake ⌘V.
  - Python tests use stdlib `unittest`, so no new dependencies.
- **Privacy:**
  - Never log or persist transcribed text; log timings and states only.
  - Nothing goes over the network at runtime, and the model loads from `helper/model`.
- **Pinned versions:** `helper/requirements.txt` is pinned because the vendored loader patches `parakeet-mlx`
  internals. If you bump the model revision in `scripts/setup.sh`, re-vendor the loader from the same revision.
- **Comments say why, not what.** Many existing comments record platform facts learned the hard way, for example
  global monitors skipping the app's own events, or password fields hiding key-ups. Keep them.

## Where to add things

| Feature | Where |
|---|---|
| New tunable (durations, trailing text) | Add a field to `DictationSettings` with a default. If users should change it, add persistence behind a protocol injected at `AppDelegate` |
| Another transcription engine (e.g. Core ML or FluidAudio) | Write a new type that conforms to `TranscriptionEngine` and pick it in `AppDelegate.makeEngine()`. Add tests like `HelperProcessEngineTests` |
| Configurable hotkey | `ModifierKey` is the value type and `TapToToggleDetector` holds the logic. A non-modifier key needs a new `HotkeySource` |
| New pipeline step (e.g. text post-processing) | A pure function or small protocol called from `DictationController.complete`, with tests in `DictationControllerTests` |
| Menu items or status text | `StatusMenu` for items (closures wired in `AppDelegate`), `AppStatus.presentation` for text |
| New helper message | Both protocol files, plus tests on both sides |
| Info.plist key | Static keys go in `app/Resources/Info.plist`. Machine-specific keys go in `scripts/build.sh` via `plutil` |

## Gotchas

- Without a trusted signing certificate the app is signed ad hoc, and every rebuild loses the Accessibility grant.
  README.md's "Signing" section sets one up. Until then, remove the app under Privacy & Security → Accessibility and
  add it again after each build.
- `build.sh` writes the helper's absolute paths into the app bundle. Rebuild after moving the folder.
- Paste uses key code 9, which is V on QWERTY only.
- NSEvent monitors only observe, so fn and Esc still reach macOS and the focused app. A plain fn tap also triggers
  System Settings → Keyboard → "Press 🌐 key to" unless that's set to "Do Nothing".
- Agents can't fully exercise the hotkey, mic and paste. To change them, a human has to run `make run` and dictate
  into a text field. Say so when you hand off a change that touches them.
