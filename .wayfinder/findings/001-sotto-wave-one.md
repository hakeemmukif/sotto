# 001 — Sotto wave one

**Base commit:** none. This repository was created by the wave; the fixed point is the empty tree
(`4b825dc642cb6eb9a060e54bf8d69288fbee4904`).
**Wave:** 16 commits, 43 files, 4,941 insertions. All 14 planned tasks built.
**Suite at review time:** 105 tests, 18 suites, green via `./test.sh`.
**Review:** `/code-review`, both axes, parallel sub-agents.

Every finding is marked **verified** (reproduced by the coordinator) or **reported** (a review agent
said so and the coordinator did not independently confirm).

---

## Tier 1 — correctness, fixed in this wave

### 1. `Transcriber.warmUp()` had no production caller — **verified, FIXED**

Both review axes found this independently. `grep -rn warmUp Sources/` returned only the error case and
the throw site: nothing ever called it. Task 5 states *"**Warm-up is required** … run one inference on
a short silent clip at app start and on re-enable from the menu bar"*, and the plan's Measured facts
give the reason — 8.44 s cold against 0.91 s warm. The feature was implemented, tested, and never
wired, so every first dictation after a reboot would have taken eight seconds.

Fixed in `AppDelegate`: a background warm-up at launch and on menu-bar re-enable. Failure is logged,
not swallowed. **Verified empirically** — `whisper-cli` now spawns ~1 s after `open Sotto.app`.

### 2. `hotkeyLabel: ""` invented a value the user never wrote — **verified, FIXED**

`AppDelegate.swift:81` passed an empty string when settings failed to load, so `hotkeyLabel` was
unknowable. Directly against the house rule: *"Never default to `0`, `''`, or `'unknown'`."* Masked at
the time because `MenuBarController` short-circuits on `dictationError`, but the invented value was
real. Now `String?`, and the menu says "Listening" rather than "Listening — hold ".

### 3. `.DS_Store` committed — **verified, FIXED**

Tracked since the root commit, owned by no task's file list. `git rm --cached` plus a `.gitignore`
entry.

---

## Tier 2 — real gaps, deliberately not fixed

### 4. Task 12's second hotkey is not wired — **verified, DEFERRED**

`VoiceEdit.swift` is 102 lines referenced nowhere outside itself and its tests. `Settings` has no
`editHotkey` key. The task's Goal — *"holding a **second hotkey** over selected text replaces that
selection"* — is therefore unmet; the two "Test must pass" clauses are met.

**Why deferred:** task 12 is `exec:session` in the plan precisely because *"per-app AX variance needs
you at the keyboard to find which apps work"*. Accessibility is still ungranted, so wiring it now would
produce a trigger that refuses on first use, with no way to test the thing the task exists to
discover. The implementing agent left a precise wiring plan in its report — settings key, second
monitor, and three named traps (`ProfiledCleaner` would append the per-app profile to the rewrite
prompt; `cleaner(for:)` returns nil when `cleanupBackend` is `"none"`; the edit must join the existing
sequence gate).

### 5. The pill's input level is always zero — **verified, DEFERRED**

Task 8 asks for *"recording (with a live input level)"*. `PillState(.recording) = .recording(level: 0)`
is the only construction path in the app, and `AudioRecorder` exposes no level, so the meter always
draws its floor. The meter renders correctly when given a level — the tests pass 0.0 and 1.0 — but
nothing supplies one.

**Why deferred:** the fix needs `AudioRecorder` to publish a running RMS from its tap callback and
`DictationController` to forward it, touching two files the wave has already stabilised. It is cosmetic
and the pill is otherwise honest about state.

### 6. Several "Test must pass" clauses are proven against stubs, not the named API — **reported**

- **Task 9:** *"toggling login on asserts `SMAppService.mainApp.status == .enabled`"* — the test asserts
  a `LoginItemStub`. No test touches `SMAppService.mainApp`. Its agent could not measure real
  registration at all and said so.
- **Task 3:** *"a simulated `.tapDisabledByTimeout` asserts the tap is re-enabled **and** that the alarm
  was raised"* — only the alarm half is asserted. `start()` never succeeds without Input Monitoring, so
  the `CGEvent.tapEnable` re-arm never executes.
- **Task 4:** the acceptance criterion (a produced file transcribing through `whisper-cli`) — the
  coordinator verified this by hand outside the suite; the live-mic test is skipped.

These are honest consequences of ungranted TCC, not sloppiness — every agent flagged its own. They are
recorded so the next session does not mistake a green suite for proven behaviour.

### 7. `README.md` is stale — **reported**

Says 95 tests (now 105) and *"Voice editing … is not built yet"* (it is built, just unwired).

---

## Tier 3 — judgement calls, left alone

- **Temp WAVs are discarded with `try?`** in two places. Best-effort cleanup; the only unlogged discard
  in the codebase. **reported**
- **`AppProfiles`** collapses "no frontmost app" into the same branch as "unmapped app". The plan
  sanctions only the latter. The implementing agent flagged and justified it. **reported**
- **`History` hardcodes `20` four times** where the sibling ring in `HotkeyMonitor` names its constants.
  **reported**
- **The "empty detail → separate error case" shape recurs three times.** The house rule — *"three
  similar lines beat a premature abstraction"* — argues against extracting it. Left as is. **verified**

---

## What the whole wave never proved

**Nothing has been dictated end to end.** No real key event, no real paste, no microphone recording, no
selection read from any app. Zero applications have been tested for `kAXSelectedTextAttribute` — the
per-app variance behind task 12's 75% confidence is entirely unmeasured.

Three machine-state findings, all reproduced by the coordinator, are recorded in the plan's Measured
facts because each one cost real time:

1. **A denied event tap returns a non-nil port.** `CGEvent.tapCreate` succeeds with Input Monitoring
   denied; only `CGEvent.tapIsEnabled` reveals it. The obvious `guard let` ships an app that watches
   nothing, silently, forever.
2. **Secure input was stuck on**, held by `loginwindow`, and a correct Sotto refuses every dictation in
   that state. Cleared by the reboot.
3. **Bare `swift test` ran zero tests and exited 0.** No Xcode means no `xctest` runner. All 105 tests
   exist only because `./test.sh` was introduced in task 1.

A fourth, learned the hard way twice: **`codesign` blocks on an interactive keychain prompt**, and an
agent that kills it leaves the bundle ad-hoc signed with a cdhash designated requirement — the exact
state that silently breaks TCC grants. Two agents hit this. Never kill a hung `codesign`; answer the
dialog.
