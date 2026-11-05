# Testing Sotto before it is notarized

Sotto is not signed with an Apple Developer ID and is not notarized. This guide is for a small group
of testers who get a prebuilt app directly from the maintainer. macOS will warn about it once; after
that it runs like any other app.

---

## For the maintainer: making a test build

```sh
./build.sh
ditto -c -k --keepParent Sotto.app Sotto-<version>.zip
```

- Zip with `ditto`, not Finder's Compress. `ditto` keeps the code signature intact.
- Send the zip privately (AirDrop, a shared drive, a chat). Attaching it to a GitHub release makes it
  public, because this repository is public.
- Always sign with the same "Sotto Dev" certificate. Testers' permission grants are tied to it; a
  regenerated certificate forces every tester to grant all three permissions again.
- The build is arm64 only. Intel Macs cannot run it.

---

## For testers: installing

You need an Apple silicon Mac (M1 or later) on macOS 14 or newer, and about 7 GB of free disk for
the models. Setup takes 20–30 minutes, most of it downloads.

### 1. Install the speech and cleanup engines

```sh
brew install whisper-cpp ollama
brew services start ollama
ollama pull qwen3:8b
```

`qwen3:8b` is about 5 GB and is the model Sotto's timings were measured with. Larger models work if
your Mac has the memory, but start with this one.

### 2. Download the speech model

```sh
mkdir -p ~/Library/Application\ Support/Sotto/models
curl -L -o ~/Library/Application\ Support/Sotto/models/ggml-medium.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.en.bin
```

### 3. Create the settings file

Every key is required; Sotto refuses to start with a named error if one is missing.

```sh
cat > ~/Library/Application\ Support/Sotto/settings.json <<'EOF'
{
  "hotkey": "fn",
  "whisperModelPath": "~/Library/Application Support/Sotto/models/ggml-medium.en.bin",
  "whisperBackend": "local",
  "cleanupBackend": "ollama",
  "cleanupModel": "qwen3:8b",
  "vocabulary": [],
  "appProfiles": {
    "default": "Fix punctuation and capitalisation using standard sentence case."
  },
  "insertionMode": "paste"
}
EOF
```

If your keyboard has no `fn` key, use `"ctrl+space"` as the hotkey.

### 4. Install and open the app

1. Unzip `Sotto-<version>.zip` and drag `Sotto.app` into `/Applications`.
2. Open it. macOS will say it cannot verify the developer. Click **Done**.
3. Open **System Settings ▸ Privacy & Security**, scroll down, and click **Open Anyway** next to the
   Sotto message. Confirm with your password.

On recent macOS versions, right-click ▸ Open no longer bypasses this warning; use **Open Anyway**.

### 5. Grant three permissions

In **System Settings ▸ Privacy & Security**:

| Permission | Without it |
|---|---|
| **Microphone** | every dictation refuses immediately. Sotto asks at launch; click Allow. |
| **Accessibility** | it transcribes but never pastes. Add `Sotto.app` with **+**. |
| **Input Monitoring** | the hotkey does nothing. Add `Sotto.app` with **+**. |

**Quit Sotto from the menu bar and open it again** after granting. Input Monitoring is only picked up
at launch.

### 6. Try it

- Click into any text field, hold the hotkey, speak a sentence, release. Clean text appears at the
  cursor in about two seconds.
- Open the Prompt tab from the menu bar icon, type a rough request, and press **Enhance**. It comes
  back rewritten as a clearer, structured prompt.

The first dictation after launch can be slower while the models warm up.

---

## When something goes wrong

Check the log first; it names the missing permission or failing stage:

```sh
cat ~/Library/Logs/Sotto.log
```

A healthy start ends with `startListening succeeded`. Do not diagnose by running the binary from
Terminal: macOS then checks Terminal's permissions instead of Sotto's, and every value reads false.

When you report a problem, send:

1. What you did and what you expected.
2. The last 30 lines of `~/Library/Logs/Sotto.log`.
3. Your macOS version and Mac model.

## Removing Sotto

```sh
rm -rf /Applications/Sotto.app ~/Library/Application\ Support/Sotto ~/Library/Logs/Sotto.log
```

Then remove Sotto from the three Privacy & Security lists. `brew uninstall whisper-cpp ollama` removes
the engines; `ollama rm qwen3:8b` removes the cleanup model.
