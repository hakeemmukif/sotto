# Sotto

System-wide push-to-talk dictation for macOS. Hold a key, speak, release — clean text lands at your
cursor in whatever app has focus.

Everything runs locally. No account, no API key, no telemetry, no network calls. Transcription is
whisper.cpp; the cleanup pass that strips "um" and fixes punctuation is a local LLM through Ollama.

```
hold ctrl ──▶ record ──▶ whisper.cpp ──▶ Ollama cleanup ──▶ paste at cursor
                          ~0.9 s           ~0.75 s            clipboard restored
```

> **Scope.** This was built to run on one machine — an Apple silicon Mac on macOS 26. It is signed with a
> self-signed certificate and is not notarized. You can build and run it, but expect to do the
> permissions dance below. It is not a product.

---

## What it does

- **Push-to-talk from anywhere.** A global event tap sees the key in any app.
- **Local transcription** via `whisper-cli`, defaulting to `ggml-medium.en`.
- **LLM cleanup** that removes filler and fixes punctuation without ever *answering* what you said.
- **Pastes at the cursor** and restores your previous clipboard — including images and files, not
  just text.
- **Refuses loudly** when it can't work: a red pill for secure input or a cleanup error — including
  a model that isn't installed — amber when the backend is merely unreachable and the raw transcript
  gets pasted anyway, and a specific error naming the exact System Settings pane when a permission is
  missing.
- **Custom vocabulary** so `pnpm` and `Drizzle` survive both whisper and the cleanup pass.
- **Per-app style profiles** — lowercase and unpunctuated in Terminal, full prose in Mail.
- **History** — the menu bar keeps the last 20 transcripts for a quick copy; every dictation is also
  logged to `history.jsonl` (90-day trim) and browsable in a window (⌘Y), with search, a per-app
  filter, and a raw/cleaned toggle.

## Measured performance

Against a 9.33 s clip. These numbers drove the design, not the other way round.

| Stage | Cold | Warm |
|---|---|---|
| `whisper-cli` + `ggml-medium.en` | 8.44 s | **0.91 s** |
| `whisper-cli` + `ggml-small.en` | 8.44 s | **0.40 s** |
| Ollama `qwen3:8b` cleanup | 2.75 s | **0.75 s** |
| End to end | — | **~1.86 s** |

The cleanup row and everything downstream of it are specific to `qwen3:8b` — a number without its
model is misleading, because not every model this size behaves the same. On Ollama 0.34.0,
`qwen3:4b` ignores `think: false` outright and returned 20,945 characters of reasoning in 63.9 s for
a nine-word transcript (measured 2026-09-15). Pick your cleanup model in Settings and press Test
before trusting any of these numbers for a model that isn't `qwen3:8b`.

Two consequences worth knowing:

**There is no streaming transcription.** At 10–23× realtime, chunked streaming with partial-result
merging — by far the hardest thing in this project — buys nothing. Transcription happens on release.

**The model is warmed at launch.** The 8.44 s cold figure is an empty page cache. Without a warm-up
pass, your first dictation after a reboot takes eight seconds. Sotto pays that cost at login instead.

---

## Requirements

- macOS 14+ (developed on 26.5)
- Swift 6.3+ via Command Line Tools — **Xcode is not required**
- A code signing identity (see [Signing](#signing), and read it before you skip it)

```sh
brew install whisper-cpp ollama
ollama serve &
ollama pull qwen3:8b

mkdir -p ~/Library/Application\ Support/Sotto/models
curl -L -o ~/Library/Application\ Support/Sotto/models/ggml-medium.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.en.bin
```

## Install

```sh
git clone https://github.com/hakeemmukif/sotto.git
cd sotto

cp settings.example.json ~/Library/Application\ Support/Sotto/settings.json

./build.sh
open Sotto.app
```

`build.sh` will pause on a keychain dialog the first time. Click **Always Allow** — plain "Allow"
means it asks again on every build.

Then grant permissions (next section), quit and relaunch, and hold your hotkey.

---

## Permissions

Sotto needs three grants. **It will not work until all three are in place**, and each fails in its
own way.

| Permission | System Settings ▸ Privacy & Security ▸ | Why | Without it |
|---|---|---|---|
| **Input Monitoring** | Input Monitoring | the `CGEventTap` that sees your hotkey | the hotkey does nothing at all |
| **Accessibility** | Accessibility | posting the synthetic ⌘V, and reading selections | it transcribes but never inserts |
| **Microphone** | Microphone | recording you | every dictation refuses immediately |

For Input Monitoring and Accessibility: click **+**, press `⌘⇧G`, and paste the full path to
`Sotto.app`. Microphone cannot be added by hand — macOS only lists an app once it has *asked*, and
Sotto asks at launch.

**Quit and relaunch after granting.** A new Input Monitoring grant is only picked up at process
start.

### Check what Sotto actually sees

Sotto writes its startup state to a log. This is the fastest way to find out which grant is missing:

```sh
cat ~/Library/Logs/Sotto.log
```

```
microphone status at launch = 3 (0=notDetermined 2=denied 3=authorized)
preflight — listenEvent=true axTrusted=true mic=3
startListening succeeded — hotkey ctrl is live
```

All three `true`/`3` and a `startListening succeeded` means Sotto is armed. Anything else names the
problem.

> **Never diagnose by running the binary directly.** `./Sotto.app/Contents/MacOS/Sotto` makes your
> *terminal* the responsible process for TCC, so macOS reports the terminal's permissions and every
> value reads false — even when Sotto's own grants are fine. Always `open Sotto.app` and read the
> log.

---

## Settings

`~/Library/Application Support/Sotto/settings.json`. Every key is required. **A missing key throws a
named error rather than defaulting to anything** — that is deliberate, and it is the rule the whole
codebase is built on.

```json
{
  "hotkey": "ctrl",
  "whisperModelPath": "~/Library/Application Support/Sotto/models/ggml-medium.en.bin",
  "whisperBackend": "local",
  "cleanupBackend": "ollama",
  "cleanupModel": "qwen3:8b",
  "vocabulary": ["pnpm", "Drizzle"],
  "appProfiles": {
    "default": "Fix punctuation and capitalisation using standard sentence case.",
    "com.apple.Terminal": "Lowercase, no trailing period.",
    "com.microsoft.VSCode": "Preserve identifiers verbatim, no sentence-casing."
  },
  "insertionMode": "paste"
}
```

| Key | Values |
|---|---|
| `hotkey` | `"fn"`, a bare modifier (`"ctrl"`, `"cmd"`, `"opt"`, `"shift"`), a modifier combination (`"ctrl+opt+cmd"`), or a chord (`"ctrl+space"`, `"cmd+shift+f13"`) |
| `whisperModelPath` | path to a `ggml-*.bin`; `~` is expanded |
| `whisperBackend` | `local` |
| `cleanupBackend` | `ollama`, `groq`, `openai`, or `none` |
| `cleanupModel` | e.g. `qwen3:8b` |
| `vocabulary` | terms fed to whisper *and* the cleanup prompt. Capped at whisper's 224-token prompt limit — an over-long list throws rather than silently truncating |
| `appProfiles` | bundle id → prompt fragment. A profile named `default` **must exist** |
| `insertionMode` | `paste` (⌘V) or `unicodeKeystrokes` (slower, mangled by editors with auto-pairing) |

A bare modifier is held exactly like `fn`. Convenient on a keyboard with no `fn` key — but note that
`"ctrl"` means every `ctrl`-based shortcut also starts a recording. The 300 ms floor discards
anything shorter than a deliberate hold, so quick chords are usually harmless. Use `"ctrl+space"` if
it bothers you.

`groq` and `openai` read their keys from `.env` at the repo root or `~/.config/sotto/.env`. A
missing key throws `missingKey("GROQ_API_KEY")` — it never silently falls back to another backend.

### Changing the cleanup model without editing JSON

`cleanupModel` no longer requires a hand edit and a relaunch. The Settings tab — `⌘,`, or the third
tab of the `⌘Y` window — lists whatever models Ollama actually has installed, lets you Test one
against a fixed fixture sentence before switching to it, and Apply writes `settings.json` and swaps
the running cleaner in the same call. (Test works against any backend; the installed-models dropdown
and Apply are Ollama-only — a remote backend has nothing local to swap to.)

Its Health panel always shows the verdict of the model's last Test, a "Last dictation" line naming
the most recent failure with its stage, its cleanup latency, and why (or "none this session"), a
failure count, and a button to open the log; for an Ollama backend it also shows whether the daemon
answers, whether the selected model is installed, and whether it's loaded or cold. Every row reads
"— not checked" until it has actually run once, and **installed is deliberately not health**:
`qwen3:4b` was installed and reachable and still returned 20,945 characters of reasoning in 63.9 s
for a nine-word transcript (Ollama 0.34.0, measured 2026-09-15) — a tick on installed alone would
have passed it.

---

## Signing

**An unsigned build is a broken build.** macOS binds Accessibility and Input Monitoring grants to an
app's *designated requirement*, not its name or path. Ad-hoc signed, every rebuild is a new
identity: the grant silently stops applying, System Settings still shows a ticked checkbox, and that
stale entry blocks a fresh prompt. You would re-grant after every build.

`build.sh` signs with a self-signed identity and then asserts the result, exiting non-zero if it
doesn't match. To use your own, create a self-signed `codeSigning` certificate in Keychain Access,
trust it, then update `IDENTITY` and the expected certificate hash in `build.sh`.

Diagnostic when the hotkey suddenly stops working:

```sh
codesign -dr - Sotto.app
```

You want `identifier "com.hakeem.sotto" and certificate root = H"..."`. If you see a bare `cdhash`,
the bundle is ad-hoc signed and its grants are dead.

### Hardened Runtime and the microphone

`build.sh` signs with `--options runtime`. Under Hardened Runtime the microphone is refused **unless
`com.apple.security.device.audio-input` is in the entitlements** — and the refusal is instant,
silent, and produces no dialog:

```
microphone status at launch = 0 (notDetermined)
microphone requestAccess returned granted=false     ← same second, no prompt ever shown
```

The app then never appears under System Settings ▸ Microphone at all, because the request was never
legitimate. This is indistinguishable from a user having denied permission, and no amount of
clicking fixes it. If you fork this and strip the entitlements file, this is what you'll hit.

`Resources/Sotto.entitlements` must also contain **no XML comments** — `AMFIUnserializeXML` rejects
them with a syntax error, unlike `plutil`.

---

## Development

```sh
./test.sh          # 223 tests in 34 suites
./build.sh         # signed Sotto.app
```

> **Use `./test.sh`, never bare `swift test`.** Without Xcode there is no `xctest` runner, so
> `swift test` builds the test bundle, runs **zero tests**, and exits 0. It is a green result that
> proves nothing. `--disable-xctest` and `--enable-swift-testing` don't help; `test.sh` adds the one
> flag that does.

`./test.sh` currently finishes with five failures, and they are permanent rather than regressions:
`HistoryStoreTests` round-trips a `Date` through ISO-8601 and loses sub-second precision on the way
back, and `CleanupTests` and `VoiceEditTests` between them hardcode the model name `qwen3:8b` in four
places to drive the real Ollama daemon, which 404s because this machine doesn't have it installed.
`TranscriberTests`' warm-transcription-under-2s budget also fails occasionally alongside them and
passes on a re-run — real but tight, not a sixth permanent failure.

### Architecture

| File | Responsibility |
|---|---|
| `HotkeyMonitor` | `CGEventTap` on a dedicated thread with its own runloop |
| `AudioRecorder` | `AVAudioEngine` → 16 kHz mono PCM, 300 ms floor |
| `Transcriber` | `whisper-cli` subprocess, launch warm-up |
| `Cleanup/` | one `Cleaner` protocol; Ollama and OpenAI-compatible backends |
| `TextInserter` | pasteboard save/restore, synthetic ⌘V, secure-input guard |
| `DictationController` | the job pipeline and its sequence gate |
| `PillWindow` / `PillView` | non-activating status indicator |

Two design choices worth calling out:

**The event tap never stalls.** It runs on its own thread with its own runloop, is listen-only, and
its callback does nothing but classify and signal — measured p99 of 1.5–4.7 µs against a 100 µs
budget. Almost every reported `tapDisabledByTimeout` in apps of this kind comes from putting the tap
on the main runloop. The re-arm handler is kept as an alarm that something regressed, not as the
mitigation.

**Insertion is serialised by sequence number.** Press the hotkey while a previous dictation is still
transcribing and it starts a *new* recording immediately — nothing is queued, ignored, or dropped.
Jobs run concurrently, but text always lands in the order you spoke it.

---

## Known limitations

Stated plainly rather than buried.

- **Voice editing is built but not wired.** `VoiceEdit.swift` rewrites a selection from a spoken
  instruction and is tested, but no second hotkey triggers it. It needs an `editHotkey` setting and
  a second monitor.
- **Launch at login is unverified.** The menu toggle calls `SMAppService`, but registration has
  never succeeded from a non-`/Applications`, unnotarized bundle.
- **Secure input blocks everything, correctly.** In a password field — or when a stale
  `loginwindow` state leaves the flag stuck on — Sotto refuses with a red pill. Diagnose with
  `ioreg -l -w 0 | grep kCGSSessionSecureInputPID`; a logout or reboot clears a stuck one.
- **English only.** The `.en` models are chosen deliberately: they beat multilingual models at equal
  size.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Hotkey does nothing | Input Monitoring missing | grant it, then **relaunch** |
| Transcribes but never pastes | Accessibility missing | grant it, then relaunch |
| Every dictation refuses instantly | mic denied, or entitlement missing | `tccutil reset Microphone com.hakeem.sotto`, relaunch |
| Red pill, nothing inserts | secure input active | leave the password field; reboot if stuck |
| Red pill, "Cleanup failed — nothing pasted" | the cleanup backend returned an error that isn't a plain connection failure — e.g. a 404 for a model that isn't installed | click the pill while it's showing, or open Settings (⌘,); pick an installed model, Test it, Apply |
| Settings ▸ Test says a model "leaked reasoning" | the model ignored `think: false` and returned its reasoning instead of cleaned text | pick another model — not every model honours `think: false` |
| Amber pill, raw text pasted | Ollama unreachable | `ollama serve` |
| Amber pill, raw text pasted, ~20 s after you spoke | cleanup ran past the 20 s request timeout | pick a faster model in Settings |
| Worked, then stopped | ad-hoc signature | `codesign -dr - Sotto.app`, rebuild |
| `build.sh` seems to hang | keychain dialog waiting | click **Always Allow** |
| Tests "pass" but nothing ran | used `swift test` | use `./test.sh` |

## License

MIT
