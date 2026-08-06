# Sotto — implementation plan

System-wide push-to-talk dictation for macOS. Hold a hotkey, speak, release; the text lands at
the cursor in whatever app has focus.

## Context

**What.** A background macOS menu bar app. While a configured hotkey is held it records the
microphone; on release it transcribes locally with whisper.cpp, cleans the transcript with an
LLM, and inserts the result at the cursor position in the frontmost application, restoring the
previous clipboard afterwards.

**Why this shape.** Every structural choice below was settled in a grilling session and, where it
was empirically decidable, measured on this machine rather than assumed. The measurements are in
"Measured facts" and they are the reason several obvious-looking designs were rejected.

**Destination.** Sotto runs on *this* Mac — Apple M5 Pro, 24 GB, macOS 26.5.1. Not distributed,
not notarized, no accounts, no telemetry. Done means: hold the hotkey in any app, speak, release,
and clean text appears.

## Spec references

No prior spec files exist — this is a new repository. The canonical inputs are:

- The originating brief (background app, global hold-to-talk hotkey, whisper.cpp local or
  Groq/OpenAI per a config flag, LLM cleanup pass, cursor insertion with clipboard restore,
  floating pill, menu bar toggle, launch at login, settings file, offline operation, README
  covering permissions).
- Six decisions settled by grilling, recorded under "Settled decisions".
- `~/Projects/roda/CLAUDE.md` house rules, which this project inherits: no fallback values, no
  default branches, no "if neither is provided" lookups. A missing required value throws with a
  specific message.

## Measured facts

Measured on this machine on 2026-08-05. These are load-bearing — several tasks below exist, or
don't, because of them.

| Measurement | Cold | Warm | Note |
|---|---|---|---|
| `whisper-cli` + `ggml-small.en` on a 9.33 s clip | 8.44 s | **0.40 s** | rendered `drizzle` lowercase |
| `whisper-cli` + `ggml-medium.en` on the same clip | — | **0.91 s** | rendered `Drizzle` correctly |
| Ollama `qwen3:8b`, `think:false`, cleanup prompt | 2.75 s | **0.75 s** | 633 ms generation, 32 tokens |
| End-to-end budget, `medium.en` + Ollama + paste | — | **~1.86 s** | `small.en` variant: ~1.35 s |

Three consequences:

1. **No streaming transcription.** 0.40–0.91 s for a 9.33 s clip is 10–23× realtime. Chunked
   streaming with partial-result merging — the single hardest piece of architecture in this
   project — buys nothing and is cut entirely. Transcribe on hotkey release.
2. **The model must be warmed at launch.** The 8.44 s cold figure is an empty page cache. Without
   a warm-up pass the first dictation after a reboot takes eight seconds.
3. **`medium.en` is the default.** It capitalised the proper noun `Drizzle` where `small.en` did
   not, and proper nouns are the bulk of technical dictation. It also preserved the filler `um`,
   which is *correct*: whisper should transcribe verbatim and the LLM should do the removing.
   Both models are already on disk, so this is a settings flip.

Environment, verified:

- macOS 26.5.1, Apple M5 Pro, 24 GB, arm64.
- Swift 6.3.2 via Command Line Tools. **No Xcode.** AppKit, SwiftUI, AVFoundation,
  ServiceManagement, ApplicationServices and the `CGEvent` tap APIs all compile and link.
- `whisper-cli` at `/opt/homebrew/bin/whisper-cli` (Homebrew `whisper-cpp`).
- Models at `~/Library/Application Support/Sotto/models/` — `ggml-small.en.bin` (465 MB),
  `ggml-medium.en.bin` (1.4 GB).
- Ollama 0.32.5 with `qwen3:8b` already pulled. **`think:false` is mandatory** — qwen3 is a
  reasoning model and its default `<think>` blocks add seconds for no benefit here.
- Code signing identity **`Sotto Dev`** (`A22EF0B5E30D5B9650C2B0DB015BADB15E924A7C`), self-signed,
  `codeSigning` EKU, trusted in the login keychain, valid 10 years. Private key exists only in the
  keychain. Public cert retained at the scratchpad path for reference; not needed to build.
- No competing hotkey grabbers installed (no Raycast, Alfred, Karabiner, BetterTouchTool).

**Measured during task 3, 2026-08-05 — a denied event tap does not fail the way you would expect.**
Without Input Monitoring, `CGEvent.tapCreate` returns a **non-nil** `CFMachPort` that the system then
refuses to enable:

```
CGPreflightListenEventAccess: false
tapCreate non-nil:            true      <- the obvious `guard let` passes
enabled after tapEnable:      false     <- and the app watches nothing, silently, forever
```

So `guard let port = tapCreate(...) else { throw }` is **not** a sufficient permission check. The
discriminator is enable-then-verify: `CGEvent.tapEnable(tap:enable:true)` followed by
`CGEvent.tapIsEnabled(tap:)`, throwing when it comes back false. Independently reproduced by the
coordinator. Also note the grant attaches to the **responsible** app, so running the suite from a
terminal creates an entry under Terminal — `Sotto.app` needs its own grant (task 14).

**Measured during task 7, 2026-08-05 — secure input is currently stuck on, and it will block Sotto.**

```
IsSecureEventInputEnabled():  true
kCGSSessionSecureInputPID:    413  ->  /System/Library/CoreServices/loginwindow.app
```

Nothing in this project caused it; `loginwindow` is holding the session-global flag, a known stale
state. Requirement 4 of task 7 says secure input must refuse dictation up front with a red pill, so a
correctly-built Sotto **will refuse every dictation on this machine until the flag clears** — almost
certainly at the next logout or reboot. Independently reproduced by the coordinator. This is a
machine state, not a defect: do not "fix" it in code, and do not weaken the guard to work around it.
Re-check with the two commands above before concluding that insertion is broken.

**Measured during post-review debugging, 2026-08-06 — Hardened Runtime silently kills the microphone.**

`build.sh` signs with `--options runtime`, and task 1 shipped an **empty** entitlements file. Under
Hardened Runtime the microphone is refused unless `com.apple.security.device.audio-input` is present,
and the refusal is instant and silent:

```
microphone status at launch = 0 (notDetermined)
microphone requestAccess returned granted=false     <- same second, no dialog ever shown
preflight -- mic=2 (denied)
```

No dialog appears, and the app never appears in System Settings > Microphone, because the request was
never legitimate. This is indistinguishable from a user having denied permission, and no amount of
clicking in System Settings fixes it. Fixed by adding the entitlement. Note that
`Resources/Sotto.entitlements` **must not contain XML comments** — `AMFIUnserializeXML` rejects them
with `syntax error`, unlike `plutil`.

**Also settled the same day: plan risk 3 is closed.** `fn` *is* capturable by a listen-only session tap
on macOS 26 with `AppleFnUsageType` unset — seven jobs fired from real `fn` holds. No chord fallback
and no preference change is needed.

## Settled decisions

| # | Decision | Rationale |
|---|---|---|
| 1 | Working app on this Mac, not a spec or a distributable | user choice |
| 2 | Native Swift, SwiftPM + `swiftc`, no Xcode | verified compiling; Xcode only buys signing/notarization, which the destination doesn't need |
| 3 | Cleanup backend defaults to **Ollama**, local | free, no key, no account, works offline end to end — strictly better than the originally-agreed "skip cleanup when offline" |
| 3a | When the configured backend is unreachable, raw text pastes and the pill turns amber | explicit designed degradation, surfaced in the UI — **not** a silent fallback |
| 4 | English only, `.en` whisper models | user dictates in English; `.en` models beat multilingual at equal size |
| 5 | In scope: custom vocabulary, per-app style profiles, dictation history, voice editing | user widened scope beyond the original brief |
| 6 | Named Sotto, `com.hakeem.sotto`, `~/Projects/sotto` | user choice |
| 7 | History is an **in-memory ring buffer of 20, cleared on quit** | covers the real use case (a paste went to the wrong window) while deleting the privacy question entirely — nothing on disk, nothing to encrypt, nothing contradicting "no telemetry" |
| 8 | Insertion is **pasteboard + synthetic Cmd-V**; unicode keystroke synthesis is opt-in only | keystroke synthesis is slow on long text and editors with auto-pairing mangle it |
| 9 | Signed with the `Sotto Dev` self-signed identity on every build | proven below to keep TCC grants across rebuilds |

### Why signing is task 1 and not an afterthought

macOS binds Accessibility and Input Monitoring grants to an app's **designated requirement**, not
its name or path. Demonstrated on this machine with two completely different programs:

```
SELF-SIGNED   binA → identifier "com.hakeem.sotto" and certificate root = H"a22ef0…"
              binB → identifier "com.hakeem.sotto" and certificate root = H"a22ef0…"   identical

AD-HOC        binA → cdhash H"cda30f7de08a5414…"
              binB → cdhash H"3f936e9c322ad3f2…"                                       differs
```

Ad-hoc signed, every rebuild is a new identity: the grant silently stops applying, System Settings
still shows a ticked checkbox, and that stale entry blocks a fresh prompt. You would re-grant after
every build. Signed with `Sotto Dev`, the requirement is stable and the grant persists. **Every
build script path must sign — an unsigned build is a broken build.**

## Gap analysis

| Exists | Needed | Delta | Risk |
|---|---|---|---|
| Swift 6.3.2 CLT, all frameworks | compiling `.app` bundle | SwiftPM manifest, `Info.plist`, bundle layout, signing script | Low — verified compiling |
| `Sotto Dev` identity, trusted | every build signed | one `codesign` line in `build.sh` | Low — proven stable |
| `whisper-cli`, both models | Swift → transcript | subprocess wrapper, output parsing, launch warm-up | Low — measured |
| Ollama + `qwen3:8b` | cleanup pass | HTTP client, prompt, `think:false`, error contract | Low — measured, adherence verified |
| — | hold-to-talk hotkey | `CGEventTap` on a dedicated thread, `flagsChanged` handling, listen-only | Medium — the usual failure (tap disabled under load) is designed out by construction, not recovered from; residual risk is the `fn`/Globe binding |
| — | mic capture | `AVAudioEngine` → 16 kHz mono PCM | Low |
| — | cursor insertion | pasteboard save/restore, synthetic Cmd-V, secure-input guard | **High** — clipboard restore has no completion callback; secure input silently drops events |
| — | floating pill | non-activating `NSPanel` at `.statusBar` level | Medium — must never steal focus, or the paste target changes |
| — | menu bar, launch at login | `NSStatusItem`, `SMAppService.mainApp` | Low |
| — | settings file | Codable schema, throwing loader | Low |
| — | per-app profiles | `NSWorkspace` frontmost bundle id → prompt map | Low |
| — | voice editing over a selection | `AXSelectedText` read, second hotkey, rewrite-and-replace | **High** — AX selection support varies per app; user reports it works, but per-app variance is real |
| — | README permissions walkthrough | prose + screenshots of the two TCC panes | Low |

## Tasks

Dependency order. Tasks 3 and 4 may run in parallel; 8–11 may run in parallel after 13.

---

### 1. Bootstrap the signed `.app` bundle
- [ ] **Goal:** `./build.sh` produces a signed `Sotto.app` that launches to a menu bar icon and whose designated requirement matches `Sotto Dev`.
- Agent: `executor` · `model:sonnet` · `exec:subagent`
- Files: `Package.swift`, `Sources/Sotto/main.swift`, `Sources/Sotto/AppDelegate.swift`, `Resources/Info.plist`, `build.sh`, `.gitignore`
- `Info.plist` must carry `LSUIElement=true` (no Dock icon), `CFBundleIdentifier=com.hakeem.sotto`, and `NSMicrophoneUsageDescription`.
- `build.sh` must end with `codesign -f -s "Sotto Dev" --options runtime --entitlements … Sotto.app` and then assert the DR.
- **Test must pass:** `swift build` succeeds; `./build.sh && codesign -dr - Sotto.app | grep 'certificate root = H"a22ef0b5e30d5b9650c2b0db015badb15e924a7c"'` matches.
- **Acceptance:** running `open Sotto.app` shows a menu bar item with a Quit entry, and no Dock icon appears.

### 2. Settings schema and throwing loader
- [ ] **Goal:** a typed settings file loads from disk, and any missing required value throws a named error rather than defaulting.
- Agent: `executor` · `model:sonnet` · `exec:subagent`
- Files: `Sources/Sotto/Settings.swift`, `Tests/SottoTests/SettingsTests.swift`, `settings.example.json`
- Location `~/Library/Application Support/Sotto/settings.json`. Covers: hotkey, whisper model path, whisper backend (`local` | `groq` | `openai`), cleanup backend (`ollama` | `groq` | `openai` | `none`), cleanup model, vocabulary array, per-app profile map, insertion mode.
- **House rule:** no `??`, no `.default`, no silent coercion. A missing key throws `SettingsError.missingKey(String)`. An unknown backend throws `SettingsError.unknownBackend(String)`.
- **Test must pass:** valid fixture parses; a fixture missing `whisperModelPath` throws `.missingKey("whisperModelPath")`; `"cleanupBackend": "banana"` throws `.unknownBackend("banana")`.
- **Acceptance:** no code path in this file can produce a value the user did not write.

### 3. Global hold-to-talk hotkey
- [ ] **Goal:** holding the configured key fires a start event and releasing it fires a stop event, reliably, without wedging system input.
- Agent: `deep-thinker` · `model:opus` · `exec:subagent`
- Files: `Sources/Sotto/HotkeyMonitor.swift`, `Tests/SottoTests/HotkeyMonitorTests.swift`
- `CGEvent.tapCreate` on `.cgSessionEventTap`, listening for `.flagsChanged` (the `fn` key is a modifier) plus `.keyDown`/`.keyUp` for chord alternatives.

**Design the timeout out of existence. Do not design around it.**

The tap callback is a hot path and gets treated like an audio render callback — the same discipline
a voice-interruption detector uses, and for the same reason: detection must never wait on work.
Four rules, all structural:

1. **Dedicated thread, dedicated runloop.** Create the tap on its own `Thread` running its own
   `CFRunLoop`, never the main runloop. The callback is invoked on the runloop that owns the
   source, so a tap on the main runloop competes with SwiftUI layout, menu tracking and the pill's
   animation. **This is the cause of essentially every reported `.tapDisabledByTimeout` in apps of
   this kind.** Off the main thread, the deadline is unreachable.
2. **The callback classifies and signals. Nothing else.** Read the event type and modifier flags,
   write to a preallocated slot, signal. No allocation, no `print`, no logging, no locks another
   thread can hold, no `DispatchQueue.sync`, no Swift ARC traffic on shared objects, no Foundation
   collections. It must be measurable in microseconds.
3. **`.listenOnly`, not an active tap.** An active tap holds the event stream while the system
   waits for the return value, so a slow callback degrades the user's typing. Listen-only removes
   that coupling. Sotto has no reason to *consume* the key: if `fn` must stop opening the emoji
   picker, that is fixed by setting `AppleFnUsageType` to 0 in the user's preferences — a
   one-line system setting — not by swallowing events in an active tap.
4. **All work happens elsewhere.** Starting `AVAudioEngine`, showing the pill, spawning
   `whisper-cli` — all of it is dispatched off the tap thread. The tap thread's only job is to
   observe.

Re-arming on `.tapDisabledByTimeout` stays in the code as a seatbelt, and it must log loudly when
it fires, because with rules 1–4 in place a firing means one of them has been violated. It is a
regression alarm, not the mitigation.

- Requires Input Monitoring; if the tap cannot be created, surface a specific error naming the permission, do not retry silently.
- **Test must pass:** a harness posting synthetic `flagsChanged` events asserts exactly one start and one stop per hold; the callback is instrumented and asserted to return in under 100 µs at the 99th percentile over 1000 events; a simulated `.tapDisabledByTimeout` asserts the tap is re-enabled **and** that the alarm was raised.
- **Test must pass:** with the main thread deliberately blocked for 3 s, 50 hold/release cycles still produce 50 start/stop pairs and zero timeouts. This is the test that proves rule 1.
- **Acceptance:** holding the key in any app produces start/stop with no dropped or doubled events across 50 presses, including while the pill is animating and a menu is open.
- Confidence: 85% — `fn` capture on macOS 26 is user-confirmed working but the system Globe binding may need `AppleFnUsageType` set to 0. Chord alternatives are the escape hatch. Verify during this task whether listen-only taps are exempt from the timeout deadline entirely or merely insulated from blocking the user; rules 1–2 make the answer moot either way, so do not block on it.

### 4. Microphone capture to 16 kHz mono PCM
- [ ] **Goal:** start/stop recording produces a valid 16 kHz mono 16-bit WAV that whisper.cpp accepts.
- Agent: `executor` · `model:sonnet` · `exec:subagent`
- Files: `Sources/Sotto/AudioRecorder.swift`, `Tests/SottoTests/AudioRecorderTests.swift`
- `AVAudioEngine` input tap → `AVAudioConverter` to 16 kHz mono → temp WAV. Discard clips under 300 ms (an accidental key tap should paste nothing, not an empty transcript).
- **Test must pass:** a 1 s recording yields a WAV whose header reports 16000 Hz, 1 channel, 16-bit, duration within 50 ms; a 100 ms recording returns `nil` rather than a file.
- **Acceptance:** the produced file transcribes correctly through `whisper-cli` with no format conversion.

### 5. Transcription via `whisper-cli`, with launch warm-up
- [ ] **Goal:** a WAV path in, a transcript string out, with the first dictation after login no slower than a subsequent one.
- Agent: `executor` · `model:sonnet` · `exec:subagent`
- Files: `Sources/Sotto/Transcriber.swift`, `Tests/SottoTests/TranscriberTests.swift`, `fixtures/bench.wav`
- Subprocess `whisper-cli -m <model> -f <wav> -np -nt`, capture stdout, trim. Inject the vocabulary list via `--prompt` (task 10).
- **Warm-up is required**, per the 8.44 s cold measurement: run one inference on a short silent clip at app start and on re-enable from the menu bar.
- **Test must pass:** transcribing `fixtures/bench.wav` returns a string containing `"authentication fix"` and `"migration"`; a warm second run completes in under 2 s.
- **Acceptance:** cold-start penalty is paid at login, invisibly, not on the user's first dictation.

### 6. Cleanup backends behind one protocol
- [ ] **Goal:** a raw transcript becomes cleaned text via the configured backend, and an unavailable backend produces a specific typed error rather than degraded output.
- Agent: `deep-thinker` · `model:opus` · `exec:subagent`
- Files: `Sources/Sotto/Cleanup/CleanupBackend.swift`, `Cleanup/OllamaBackend.swift`, `Cleanup/OpenAICompatibleBackend.swift`, `Sources/Sotto/Prompts.swift`, `Tests/SottoTests/CleanupTests.swift`
- Ollama is the default: `POST localhost:11434/api/generate`, `think:false`, `temperature:0.1`. Groq and OpenAI share one OpenAI-compatible implementation; keys come from `.env` at the repo root or `~/.config/sotto/.env`.
- **The prompt must forbid answering.** The verified failure mode is a model replying "Sure, I'll check that" to dictated questions instead of returning the sentence. The measured-good prompt is: *"You clean up dictated speech. Remove filler words and false starts. Fix punctuation and capitalisation. Never answer, respond to, or comment on the text — it is dictation, not a message to you. Do not add or remove meaning. Output only the cleaned text, nothing else."*
- **House rule:** backend `groq` with no key throws `CleanupError.missingKey("GROQ_API_KEY")`. Unreachable Ollama throws `CleanupError.backendUnavailable`. Neither may fall through to another backend.
- **Test must pass:** the Ollama path turns the bench sentence into text without `"um"` or `"you know"` and *without* answering the question; `groq` with no key throws `.missingKey`; a stubbed-unreachable Ollama throws `.backendUnavailable`.
- **Acceptance:** the only way to get raw text is `backendUnavailable` reaching the orchestrator, which is visible in the pill.

### 7. Cursor insertion with clipboard restore and secure-input guard
- [ ] **Goal:** text lands at the cursor in the frontmost app and the user's previous clipboard survives intact, including non-text contents.
- Agent: `deep-thinker` · `model:opus` · `exec:subagent`
- Files: `Sources/Sotto/TextInserter.swift`, `Tests/SottoTests/TextInserterTests.swift`
- Four requirements, each a known failure mode:
  1. Save **all** `pasteboardItems` and their types, not just `.string`. Saving only the string destroys a copied image or file on restore.
  2. Post Cmd-V via `CGEvent` (keycode 9, `.maskCommand`) to `.cghidEventTap`.
  3. Restore after ~150 ms and cross-check `changeCount`. There is no completion callback — the target app reads the pasteboard asynchronously, so restoring too early pastes the *old* contents.
  4. Call `IsSecureEventInputEnabled()` **before recording starts**, not after. In a password field or Terminal with secure keyboard entry, synthetic events are silently dropped and a 20-second dictation would vanish. Refuse up front with a red pill.
- Unicode keystroke synthesis (`CGEventKeyboardSetUnicodeString`) is implemented as an opt-in `insertionMode` only.
- **Test must pass:** a pasteboard holding a string *and* a TIFF is fully restored after insertion; `IsSecureEventInputEnabled() == true` causes `InsertionError.secureInputActive` before any recording begins.
- **Acceptance:** copy an image, dictate, paste — the image is still on the clipboard.
- Confidence: 90% — the 150 ms restore delay is the empirical number used across this class of app but may need tuning against slow Electron targets.

### 8. The recording pill
- [ ] **Goal:** a small floating indicator shows recording, transcribing, and cleaning states without ever stealing focus.
- Agent: `claude` · `model:sonnet` · `exec:session`
- Files: `Sources/Sotto/PillWindow.swift`, `Sources/Sotto/PillView.swift`
- Non-activating `NSPanel`, `.nonactivatingPanel` style, `.statusBar` window level, `ignoresMouseEvents`. **If the pill takes focus the frontmost app changes and the paste goes to the wrong place** — this is the one hard constraint.
- States: recording (with a live input level), transcribing, cleaning, and amber "pasted raw — cleanup unavailable", red "secure input — cannot insert".
- `exec:session` because position, size and feel are judgment calls you will want to see.
- **Acceptance:** the pill is visible while holding the hotkey and `NSWorkspace.frontmostApplication` is unchanged throughout.

### 9. Menu bar controls and launch at login
- [ ] **Goal:** the menu bar item toggles dictation on/off, toggles launch at login, and lists recent transcripts.
- Agent: `executor` · `model:sonnet` · `exec:subagent`
- Files: `Sources/Sotto/MenuBarController.swift`, `Tests/SottoTests/MenuBarControllerTests.swift`
- `SMAppService.mainApp.register()` / `.unregister()`, with the menu item reflecting `.status`.
- Disabling must tear the event tap down, not merely ignore events — a disabled app should not be monitoring input.
- **Test must pass:** toggling off asserts the tap is invalidated; toggling login on asserts `SMAppService.mainApp.status == .enabled`.
- **Acceptance:** after a reboot with launch-at-login enabled, Sotto is running and the hotkey works with no re-granting.

### 10. Custom vocabulary and per-app style profiles
- [ ] **Goal:** recurring technical terms transcribe correctly, and the cleanup prompt adapts to the focused application.
- Agent: `executor` · `model:sonnet` · `exec:subagent`
- Files: `Sources/Sotto/Vocabulary.swift`, `Sources/Sotto/AppProfiles.swift`, `Tests/SottoTests/AppProfilesTests.swift`
- Vocabulary is injected into `whisper-cli --prompt` and appended to the cleanup prompt. **Whisper's prompt is capped at 224 tokens** — exceeding it silently truncates, so the loader must reject an over-long list with a specific error rather than trimming.
- Profiles map a bundle id to a prompt fragment (Terminal → lowercase, no trailing period; Mail → full prose; VS Code → preserve identifiers, no sentence-casing). An app with no profile uses the profile named `default`, which **must exist in the settings file** — its absence throws, so there is no implicit fallback.
- **Test must pass:** a 300-token vocabulary throws `VocabularyError.tooLong`; an unmapped bundle id resolves to the `default` profile; settings lacking a `default` profile throws.
- **Acceptance:** dictating "pnpm" and "Drizzle" into a terminal yields lowercase-correct, unpunctuated output.

### 11. In-memory dictation history
- [ ] **Goal:** the last 20 transcripts are re-copyable from the menu bar and never touch disk.
- Agent: `executor` · `model:haiku` · `exec:subagent`
- Files: `Sources/Sotto/History.swift`, `Tests/SottoTests/HistoryTests.swift`
- Fixed-capacity ring buffer, cleared on quit. No persistence, no file, no defaults database.
- **Test must pass:** inserting 25 entries retains exactly the last 20 in order; no file is created anywhere under `~/Library`.
- **Acceptance:** menu bar shows recent transcripts; quitting and relaunching shows an empty list.

### 12. Voice-editing mode
- [ ] **Goal:** holding a second hotkey over selected text replaces that selection with an LLM rewrite driven by the spoken instruction.
- Agent: `deep-thinker` · `model:opus` · `exec:session`
- Files: `Sources/Sotto/VoiceEdit.swift`, `Sources/Sotto/Prompts.swift`, `Tests/SottoTests/VoiceEditTests.swift`
- Read the selection via `AXUIElement` `kAXSelectedTextAttribute` on the focused element. If the app does not expose it, **refuse visibly** — do not silently fall back to sending Cmd-C, which would clobber the clipboard for a feature the app cannot support anyway.
- The spoken text is the *instruction*, the selection is the *payload*; they need separate prompt slots or the model will rewrite the instruction.
- `exec:session` because per-app AX variance needs you at the keyboard to find which apps work.
- **Test must pass:** a mock AX element exposing selected text yields a rewrite request containing both instruction and payload; an element without the attribute throws `VoiceEditError.selectionUnavailable`.
- **Acceptance:** select a sentence in TextEdit, hold the edit hotkey, say "make this shorter", and the selection is replaced.
- Confidence: 75% — the highest-uncertainty task on the list. AX selection support is genuinely inconsistent across apps, and the set that works can only be established empirically.

### 13. Pipeline orchestration and state machine
- [ ] **Goal:** hotkey, audio, transcription, cleanup, insertion and pill are wired into one state machine whose every error path is visible to the user.
- Agent: `deep-thinker` · `model:opus` · `exec:subagent`
- Files: `Sources/Sotto/DictationController.swift`, `Tests/SottoTests/DictationControllerTests.swift`
- States per job: `recording → transcribing → cleaning → inserting → done`, plus terminal error states for `secureInputActive`, `backendUnavailable` (proceeds to insert raw, amber pill), `permissionMissing`.

**The hotkey is always live.** This is the second half of the interruption discipline in task 3: the
tap never stalls, so the controller must never stall either. A press arriving while a previous job
is still transcribing or cleaning starts a **new recording immediately** — it is not ignored, not
queued behind the old job, and not rejected. The controller is therefore a job pipeline, not a
single state variable:

- Each dictation is a `Job` with a monotonically increasing sequence number.
- Jobs run concurrently through transcription and cleanup.
- **Insertion is serialised by sequence number**, so text always lands in the order you spoke it
  even if job 2 finishes cleanup before job 1. Out-of-order pasting is the one thing concurrency
  here could break, and the sequence gate is what prevents it.
- Nothing is discarded. A press during an in-flight job never costs you the in-flight transcript —
  the voice-interruption analogy stops at responsiveness, because unlike interrupted speech, an
  in-flight transcript is data the user wants.
- Releasing the key under the 300 ms floor (task 4) cancels that job outright and inserts nothing.

- **Test must pass:** with all collaborators stubbed, a full happy path reaches `inserting` with cleaned text; a `backendUnavailable` throw inserts the raw transcript and sets the amber state.
- **Test must pass:** two jobs started 200 ms apart, where job 2's cleanup is stubbed to finish *before* job 1's, insert in the order 1 then 2.
- **Test must pass:** a press during `transcribing` starts a second recording rather than being dropped, and both transcripts are inserted.
- **Acceptance:** no error anywhere in the pipeline results in nothing happening on screen, and rapid consecutive dictations never reorder or drop text.

### 14. README with the permissions walkthrough
- [ ] **Goal:** a first-time reader can grant every permission Sotto needs without guessing.
- Agent: `executor` · `model:sonnet` · `exec:subagent`
- Files: `README.md`
- Must cover: **Input Monitoring** (for the `CGEventTap` that sees the hotkey), **Accessibility** (for posting the synthetic Cmd-V and for reading selections in voice-edit mode), and **Microphone**. Name the exact System Settings pane for each.
- Must explain the signing requirement in one short section — that unsigned builds lose their grants — and include the `codesign -dr -` check as the diagnostic when the hotkey stops working.
- Must document the settings file with a complete annotated example, the model paths, and how to switch backends.
- **Test must pass:** every command in the README runs as written on a clean checkout.
- **Acceptance:** following the README from scratch produces a working install.

## Risks & uncertainties

Ranked by likelihood × cost.

1. **AX selection support varies per app** (task 12). Confidence 75%. The user reports it works;
   what cannot be known without trying is *which* apps. Worst case this feature lands supporting a
   subset, which is why it is `exec:session` and last.
2. **Clipboard restore timing** (task 7). 150 ms is empirical, not specified by Apple. A slow
   Electron target could read the pasteboard after the restore, pasting stale content. The
   `changeCount` cross-check bounds the damage but does not eliminate it.
3. **`fn` key vs the system Globe binding** (task 3). `AppleFnUsageType` is currently unset on this
   machine, meaning system default. If macOS 26 intercepts `fn` before the tap sees it, the user
   sets that preference to 0 or picks a chord. Not fatal, but it is the one assumption taken on
   the user's word rather than measured.
4. **Out-of-order insertion** (task 13). Running jobs concurrently so the hotkey never stalls
   introduces a hazard single-threading did not have: job 2 finishing cleanup before job 1 would
   paste your sentences in the wrong order. The sequence-gated insertion queue exists solely to
   prevent this, and it has its own test.
5. **Pill stealing focus** (task 8). If the panel activates, the frontmost app changes between
   recording and pasting and the text goes to the wrong window. Constrained by
   `.nonactivatingPanel` and asserted in the acceptance criterion.

**No longer a risk: event tap disabled by timeout.** Previously ranked first here. It is now a
design constraint rather than a hazard — a dedicated tap thread with its own runloop, a callback
that only classifies and signals, and a listen-only tap remove the conditions that produce it.
The re-arm handler remains as an alarm that something regressed, not as the mitigation.

Deliberately accepted, not mitigated: one machine, no notarization, no crash reporting (which
would be telemetry), and no automated test of the actual TCC grant surviving a rebuild — that is
verified by hand once, using the `codesign -dr -` comparison already proven above.

## Out of scope

- Malay, Manglish and every non-English language — `.en` models are chosen precisely because they
  trade multilingual capability for English accuracy.
- Notarization, Developer ID, and running on any Mac other than this one.
- Accounts, sync, cloud history, telemetry, crash reporting, usage stats.
- Full Xcode, `.xcodeproj`, and anything requiring the GUI in a build.
- iOS, iPadOS, Windows, Linux.
- Streaming partial transcripts into the target app as you speak — cut by the latency measurement,
  not by preference.
- Persisting dictation history to disk (decision 7).

## Models & execution

| Tag | Meaning |
|---|---|
| `model:haiku` | mechanical, fully specified — task 11 |
| `model:sonnet` | default implementation — tasks 1, 2, 4, 5, 8, 9, 10, 14 |
| `model:opus` | fuzzy judgment or a known silent-failure mode — tasks 3, 6, 7, 12, 13 |
| `exec:subagent` | autonomous, test-gated |
| `exec:session` | needs you at the keyboard — tasks 8 and 12 |

**Test command:** `./test.sh`

> Not `swift test`. Measured 2026-08-05 during task 1: on this Command-Line-Tools-only machine the
> `xctest` runner tool does not exist (`xcrun --find xctest` fails), so bare `swift test` builds the
> test bundle, runs **zero** tests, and exits 0 — a green result that proves nothing. `--disable-xctest`
> and `--enable-swift-testing` do not help. `test.sh` adds the one flag that does.

**Build command:** `./build.sh` (must emit a signed bundle; an unsigned bundle is a failed build)

**Suggested order:** 1 → 2 → (3 ∥ 4) → 5 → 6 → 7 → 13 → (8 ∥ 9 ∥ 10 ∥ 11) → 12 → 14

Tasks 1–7 and 13 constitute a working dictation tool. Tasks 8–12 are the widened scope, and 14
closes it out.
