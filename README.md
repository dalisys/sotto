# Sotto

Sotto types what you say on your Mac. A small bar floats over your other apps. Speech can stay local with Parakeet, go to [OpenRouter](https://openrouter.ai), or go to a Whisper server you already run locally.

You need an Apple Silicon Mac on macOS 14 or later.

## Install

There is no App Store build. Install Sotto by building it on your Mac.

1. Install [Xcode](https://developer.apple.com/xcode/) and open it once so macOS finishes the setup. Sotto needs Swift 6.2 or newer.
2. In Terminal:

```sh
git clone https://github.com/dalisys/sotto.git
cd sotto
bash scripts/build-app.sh release
open dist/Sotto.app
```

This creates `dist/Sotto.app` and signs it for your Mac. It is not notarized. If macOS says it cannot be opened, right-click `dist/Sotto.app`, choose **Open**, then **Open** again.

Drag `dist/Sotto.app` into **Applications** if you want it in the Dock and in Launchpad.

## First launch

1. Open Sotto.
2. Click **Settings** in the sidebar.
3. Under **Transcription**, choose one engine:
   - **Local Parakeet** keeps the audio on your computer. Click **Prepare Parakeet** and wait for the download. You only do this once.
   - **OpenRouter** sends the audio to the model you pick. Paste a key from [openrouter.ai/keys](https://openrouter.ai/keys), click **Save key**, then **Verify key**.
   - **Local Whisper server** talks to a Whisper server that is already running locally. See [Local Whisper](#local-whisper) below.
4. Under **macOS permissions**, click **Enable Microphone** and allow the prompt.
5. Click **Enable Accessibility**, then turn Sotto on in **System Settings → Privacy & Security → Accessibility**. Sotto needs this to paste text into the app you are using.

Closing the Sotto window does not quit the app. The menu-bar icon and the floating bar stay available. Quit from the menu-bar icon when you want Sotto to stop listening for the shortcut.

## Dictate

1. Click a text field in another app, such as Notes, Mail, or a browser.
2. Press **Control + Option + Space** to start. Press it again to stop.
3. Or click the microphone on the floating bar, or **Start dictation** in the Sotto window.

Sotto transcribes after you stop. With Accessibility allowed, it pastes the text into the app that had focus. If it cannot paste, the transcript is copied to the clipboard.

The same text stays in Sotto. You can edit it, then click **Copy** or **Insert into app**.

## The floating bar

While Sotto is running, a small capsule sits at the bottom of the screen. Hover it to expand it. During recording it follows your voice level, then shows that it is working, then collapses.

Drag the dotted grip to move it. Sotto remembers that spot. In **Settings → Recording & insertion**, **Reset bar position** puts it back at the bottom of the screen. Turn off **Show floating dictation bar** if you only want the keyboard shortcut.

The bar does not take keyboard focus, so the other app keeps the cursor.

## Change the shortcut

Go to **Settings → Recording & insertion** and click **Record shortcut**. Press the keys you want, release them, then click **Save shortcut**.

Press the saved shortcut once to start and once to stop. If macOS says the shortcut is taken, choose another. If Sotto asks for keyboard access, allow it in Privacy & Security, then click **Retry shortcut**.

A shortcut that is only a letter or number replaces that key while Sotto is running. A function key, or a shortcut that includes Control, Option, Shift, or Command, leaves normal typing alone.

## History and spellings

**History** keeps your newest 500 transcripts locally. Open one to edit it again, or copy it.

**Dictionary** fixes spellings after transcription. Add the phrase you say and the spelling you want, such as a name or a product.

## Where your data stays

Settings, history, and the dictionary are stored in `~/Library/Application Support/Sotto`. The OpenRouter key is in the macOS Keychain, not in that folder. Audio is deleted after each dictation unless you turn on **Keep audio recordings** in Settings.

## Speech engines

### Local Parakeet

This is the default. **Prepare Parakeet** downloads the model into `~/Library/Application Support/Sotto/Models`. Later dictation does not download anything.

**V3 · multilingual** is the default and covers 25 European languages. Set **Language** to a locale such as `en-US` or `de-DE`. **V2 · English** is the other choice in Settings.

An 11-second English sample took 72–88 ms to transcribe after the model was already loaded. That measures the speech engine, not the time until text shows up in another app. The full notes are in [LOCAL_BENCHMARK.md](LOCAL_BENCHMARK.md).

### OpenRouter

You need your own key and account credit. The default speech model is `nvidia/parakeet-tdt-0.6b-v3`. Click **Refresh models** to load the current list, and pick an ID in `vendor/name` form.

**AI editing** is off. Turn it on only if you want a second step that cleans up the transcript. With Parakeet or Whisper, that step sends the finished text to OpenRouter and leaves the audio on your Mac. If editing is on and no key is saved, dictation still finishes and Sotto skips the cleanup.

**Test transcription** sends a short sample included with the app. It uses OpenRouter credits and does not open the microphone.

### Local Whisper

Sotto does not include Whisper. Install [whisper.cpp](https://github.com/ggml-org/whisper.cpp/tree/master/examples/server) yourself, start its server, then point Sotto at it:

```sh
whisper-server -m /absolute/path/model.bin --host 127.0.0.1 --port 8080
```

In Settings, choose **Local Whisper server**, enter `http://127.0.0.1:8080`, and click **Check status**. Only a local address is accepted. These recordings are not sent to a cloud service.

## What this version does not do

Sotto waits until you stop before it transcribes. It does not type along while you are still talking, and it does not record meetings. macOS does not tell Sotto whether the other app accepted the paste.

## For developers

```sh
bash scripts/test.sh
bash scripts/build-app.sh release
open dist/Sotto.app
```

Set `SOTTO_APP_OUTPUT=/absolute/path/Sotto.app` to choose where the app is written. The build is ad-hoc signed. Tests cover OpenRouter requests, local Whisper, permissions, dictionaries, and saved settings. They do not spend OpenRouter credits or record from the microphone.

Sotto’s own code is under the [MIT License](LICENSE). FluidAudio and the speech-model weights keep their own licenses. Those terms are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
