# Sotto

System-wide push-to-talk dictation for macOS. Hold a hotkey, speak, release; the cleaned-up text
lands at the cursor in whatever app has focus.

Runs on one machine (Apple M5 Pro, macOS 26.5.1). Not distributed, not notarized, no accounts, no
telemetry. Background menu bar app — no Dock icon.

## What's built

Hold-to-talk hotkey, microphone capture, local transcription (whisper.cpp), LLM cleanup (Ollama by
default, Groq/OpenAI optionally), cursor insertion with clipboard restore, a floating status pill,
menu bar controls, launch at login, custom vocabulary, per-app style profiles, and an in-memory
20-entry dictation history.

Voice editing (rewriting a selection by voice) is not built yet.

## Requirements

- macOS with Command Line Tools installed (`xcode-select --install`). No Xcode is required or
  used — this repo builds and tests entirely through `swiftc`/SwiftPM from the Command Line Tools.
- Swift 6 toolchain (ships with the Command Line Tools).
- `whisper-cli` from Homebrew's `whisper-cpp`, at `/opt/homebrew/bin/whisper-cli`:
  ```
  brew install whisper-cpp
  ```
- Ollama running locally with `qwen3:8b` pulled, for the default cleanup backend:
  ```
  brew install ollama
  ollama pull qwen3:8b
  ```
- A code signing identity named `Sotto Dev` in your login keychain (see "Signing" below).

## Build

```
./build.sh
```

This runs `swift build -c release`, assembles `Sotto.app`, and signs it with the `Sotto Dev`
identity. It ends by printing the designated requirement and failing if it doesn't match `Sotto
Dev`'s certificate root.

The first time `codesign` uses the `Sotto Dev` private key in a given context, macOS shows an
interactive keychain prompt ("codesign wants to use your confidential information..."). **`./build.sh`
will appear to hang at `Sotto.app: replacing existing signature` until that dialog is answered.**
Click **Always Allow** — plain "Allow" only grants that one invocation, and the next build hangs
again. If the script appears stuck at that line, check for the dialog rather than assuming the
build has failed; do not kill the process, and do not re-sign the bundle ad-hoc as a workaround —
an ad-hoc-signed build loses every permission grant on the next rebuild (see "Signing" below).

## Test

```
./test.sh
```

**Do not run bare `swift test`.** This machine has no Xcode, only the Command Line Tools, and the
`xctest` runner tool that `swift test` normally hands off to does not exist here
(`xcrun --find xctest` fails). Bare `swift test` builds the test bundle, finds no runner, and exits
**0 having run zero tests** — a clean-looking pass that proves nothing. `--disable-xctest` and
`--enable-swift-testing` do not fix this either. `test.sh` points `swiftc` at the Command Line
Tools' framework directory so SwiftPM uses the swift-testing entry point instead:

```sh
exec swift test -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks "$@"
```

95 tests currently pass. A handful of them drive the real `whisper-cli` and the real Ollama server
(not mocks), so both need to be installed and running for the suite to pass — see "Requirements"
above.

## Permissions

Sotto needs three grants before dictation works. All three are scoped to `Sotto.app` specifically —
running the test suite or `whisper-cli` from a terminal does **not** satisfy them, because the grant
attaches to whichever app made the request (Terminal, in that case), not to Sotto.

### 1. Input Monitoring

Sotto watches for the hold/release of the dictation hotkey with a `CGEventTap`, which macOS gates
behind Input Monitoring.

- **System Settings › Privacy & Security › Input Monitoring** → enable **Sotto**.
- Launch `Sotto.app` at least once first — it won't appear in the list until it has asked.
- A denied grant does **not** make `CGEvent.tapCreate` fail. It returns a non-nil tap port that
  the system then silently refuses to enable — the app launches looking fine and simply never
  reacts to the hotkey. Sotto checks for this itself (`CGEvent.tapIsEnabled` after
  `tapEnable`) and refuses to start dictation with a named error rather than watching nothing, but
  from the outside "Sotto launched" is not evidence the hotkey works — check the checkbox.

### 2. Accessibility

Sotto posts a synthetic Cmd-V to paste the transcript into the frontmost app, and (once voice
editing is built) will read the selected text via the Accessibility API. Posting synthetic
keyboard events system-wide requires this grant regardless of which app is frontmost.

- **System Settings › Privacy & Security › Accessibility** → enable **Sotto**.

### 3. Microphone

- **System Settings › Privacy & Security › Microphone**.
- Sotto cannot be added to this list in advance — macOS only lists an app under Microphone once it
  has actually requested access, and Sotto requests it at launch. Launch `Sotto.app` once, then
  find it in the list and enable it.

### Diagnosing "the hotkey stopped working"

If dictation was working and stops, the fastest check is whether the current `Sotto.app` is still
signed with the `Sotto Dev` identity:

```
codesign -dr - Sotto.app
```

Expect a line containing:

```
certificate root = H"a22ef0b5e30d5b9650c2b0db015badb15e924a7c"
```

If that line is missing — an ad-hoc signature shows a bare `cdhash` instead, with no `certificate
root` at all — the grants above no longer apply to this binary. macOS ties Input Monitoring and
Accessibility to an app's designated requirement, not its name or path; every ad-hoc-signed rebuild
gets a new identity, so a grant made against yesterday's build silently stops covering today's
even though System Settings still shows the checkbox ticked. The fix is `./build.sh`, which always
signs with `Sotto Dev`, whose requirement is stable across rebuilds — never patch this by re-signing
ad-hoc.

### Secure input

macOS has a separate, session-wide "secure input" mode (used by password fields and some terminal
apps) that silently drops synthetic keyboard events. Sotto checks for it before recording starts
and refuses with a red pill rather than transcribing something it can never paste. If dictation
refuses everywhere, including outside any password field, check whether the flag is stuck on:

```
ioreg -l -w 0 | grep kCGSSessionSecureInputPID
```

No output means secure input is off. A line naming a PID means something is holding it — on this
machine it was once `loginwindow`, a known stale state unrelated to Sotto — and the fix is a logout
or reboot, not a code change.

## What to expect

Measured on this machine (Apple M5 Pro, 24 GB) for a 9.33 s clip:

| Stage | Cold | Warm |
|---|---|---|
| Transcription, `medium.en` | 8.44 s | 0.91 s |
| Cleanup, Ollama `qwen3:8b` | 2.75 s | 0.75 s |
| End-to-end (transcribe + clean + paste) | — | ~1.86 s |

The cold numbers are what an empty page cache costs the first inference after a reboot. Sotto pays
that cost once at launch (and again if you re-enable dictation from the menu bar) by running a
silent throwaway transcription, so a real dictation is never the one that eats 8 seconds.

## Settings

Sotto reads `~/Library/Application Support/Sotto/settings.json`. There is no default: a missing
file, or a missing required key inside it, throws a named error at launch rather than falling back
to a guessed value — the error names the exact missing key.

`settings.example.json` in the repo root is a complete, valid example:

```json
{
  "hotkey": "fn",
  "whisperModelPath": "~/Library/Application Support/Sotto/models/ggml-medium.en.bin",
  "whisperBackend": "local",
  "cleanupBackend": "ollama",
  "cleanupModel": "qwen3:8b",
  "vocabulary": [
    "pnpm",
    "Drizzle"
  ],
  "appProfiles": {
    "default": "Fix punctuation and capitalisation using standard sentence case.",
    "com.apple.Terminal": "Lowercase, no trailing period.",
    "com.apple.mail": "Full prose with complete sentences.",
    "com.microsoft.VSCode": "Preserve identifiers verbatim, no sentence-casing."
  },
  "insertionMode": "paste"
}
```

Field by field:

- **`hotkey`** — `"fn"`, or a chord built from `cmd`/`ctrl`/`opt`/`shift` plus one of `space`,
  `escape`, `f13`–`f19`, e.g. `"ctrl+space"`. Anything else throws
  `DictationError.unparseableHotkey`.
- **`whisperModelPath`** — path to a `ggml` model file; `~` is expanded. Two models are installed
  on this machine, both under `~/Library/Application Support/Sotto/models/`:
  - `ggml-medium.en.bin` (1.4 GB) — the default. Slower, but capitalises proper nouns
    (`Drizzle`) that `small.en` gets wrong, and technical dictation is mostly proper nouns.
  - `ggml-small.en.bin` (465 MB) — faster (0.40 s warm vs. 0.91 s), lower accuracy on proper
    nouns. Switch to it by changing this one path.
  A path that doesn't resolve to a file throws `TranscriberError.modelMissing`.
- **`whisperBackend`** — must be `"local"`. `"groq"` and `"openai"` are recognised values but not
  yet implemented as transcription backends; setting either throws
  `DictationError.unsupportedWhisperBackend`. Any other string throws
  `SettingsError.unknownBackend`.
- **`cleanupBackend`** — one of:
  - `"ollama"` — default. Talks to `http://localhost:11434/api/generate`. An unreachable server
    throws `CleanupError.backendUnavailable` at cleanup time, which Sotto treats as a designed
    degradation: the raw transcript still gets pasted, and the pill turns amber instead of the
    dictation silently failing.
  - `"groq"` / `"openai"` — OpenAI-compatible chat completions. Require an API key (see below). A
    missing key throws `CleanupError.missingKey("GROQ_API_KEY")` or
    `CleanupError.missingKey("OPENAI_API_KEY")` at launch — before any recording, not mid-dictation.
  - `"none"` — no cleanup pass; the raw transcript is pasted verbatim and cleanup is never invoked.
  - Any other string throws `SettingsError.unknownBackend`.
- **`cleanupModel`** — the model name passed to whichever cleanup backend is selected, e.g.
  `"qwen3:8b"` for Ollama.
- **`vocabulary`** — array of terms injected into whisper's `--prompt` and appended to the cleanup
  system prompt, so proper nouns and jargon transcribe and survive cleanup correctly. Whisper's
  prompt is capped at 224 tokens; an over-long list throws `VocabularyError.tooLong` up front
  rather than silently truncating.
- **`appProfiles`** — maps a frontmost app's bundle identifier to a style instruction appended to
  the cleanup prompt. **A `"default"` key is required** — it's used for any app not otherwise
  listed, and its absence throws `AppProfileError.missingDefaultProfile` rather than falling back
  to an implicit default.
- **`insertionMode`** — `"paste"` (default; pasteboard + synthetic Cmd-V) or `"unicodeKeystrokes"`
  (opt-in; synthesises the text as keystrokes instead, slower on long text and mangled by editors
  with auto-pairing, but usable where paste doesn't work). Any other string throws
  `SettingsError.unknownInsertionMode`.

Every key above is required; none has a default. Missing any of `hotkey`, `whisperModelPath`,
`whisperBackend`, `cleanupBackend`, `cleanupModel`, `vocabulary`, `appProfiles`, or `insertionMode`
throws `SettingsError.missingKey("<name>")` naming exactly the key that's missing.

To install your settings file:

```
mkdir -p ~/Library/Application\ Support/Sotto
cp settings.example.json ~/Library/Application\ Support/Sotto/settings.json
```

### API keys for Groq / OpenAI

Only needed if `cleanupBackend` is `"groq"` or `"openai"`. Sotto reads `GROQ_API_KEY` or
`OPENAI_API_KEY` from the first of these two files that contains it:

1. `.env` in the repo root (the working directory `Sotto.app` was launched from)
2. `~/.config/sotto/.env`

Each is a plain `KEY=value` line, e.g. `GROQ_API_KEY=gsk_...`. These files are read directly by
Sotto at startup, not exported into the shell environment.

## Run

```
open Sotto.app
```

Look for the microphone icon in the menu bar — no Dock icon appears (`LSUIElement` is set). Click
it for Turn Dictation On/Off, Launch at Login, and the last 20 transcripts (cleared on quit — never
written to disk). Hold the configured hotkey anywhere, speak, release.
