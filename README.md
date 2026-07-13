# Desk Notes 🗒️

Beautiful sticky notes that live directly on your Mac desktop — with built-in, fully local AI dictation.

Notes sit on your desktop like widgets (under your app windows), a menu-bar icon keeps the Dock clean, and double-clicking a note opens a full editor window that behaves like a real app (Stage Manager included).

## Features

- **Notes on the desktop** — frameless sticky notes floating right on your wallpaper; click-through everywhere else
- **Menu bar app** — 🗒️ in the menu bar; no Dock icon while idle
- **Three views per note** — rich-text Note, checkbox Tasks, and a mini Calendar with day/time reminders
- **Full editor on double-click** — opens as a real macOS window with a Google-Docs-style toolbar (fonts, sizes, colors, highlight, lists, alignment, spacing, links)
- **Local AI dictation** — [whisper.cpp](https://github.com/ggml-org/whisper.cpp) built in; press the mic and words appear at your cursor, transcribed on-device. Free, offline, private
- **Smart typing** — auto-capitalization, auto-apostrophes (dont → don't), smart lists (`1.` ⏎ → `2.`), link detection
- **Attachments** — images (auto-compressed) and files, via picker, drag-drop, or paste
- Colors, gradients, custom colors, per-view sizes, edge snapping, and more

## Install (download)

1. Grab **Desk-Notes.zip** from the [latest release](../../releases/latest) and unzip it.
2. Drag **Desk Notes.app** into **Applications**.
3. First launch only: **right-click the app → Open → Open**. (The app isn't Apple-notarized, so a plain double-click is blocked the first time.)
   - If macOS says the app is "damaged", run: `xattr -dr com.apple.quarantine "/Applications/Desk Notes.app"`
4. Look for 🗒️ in your menu bar → **New Note**. Allow microphone access when you first use dictation.

## Build from source

Requires macOS 14+, Xcode Command Line Tools, cmake (`brew install cmake`).

```sh
git clone https://github.com/Glazyman/DeskNotes.git && cd DeskNotes

# 1. build whisper.cpp (static)
git clone --depth 1 https://github.com/ggml-org/whisper.cpp.git
cmake -S whisper.cpp -B whisper.cpp/build -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF \
  -DCMAKE_OSX_SYSROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
  -DCMAKE_CXX_FLAGS="-nostdinc++ -isystem /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/usr/include/c++/v1"
cmake --build whisper.cpp/build -j 8

# 2. download the Whisper model (~148 MB)
curl -L -o ggml-base.en.bin \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"

# 3. build the app
./build.sh
open "Desk Notes.app"
```

## How it works

A single Objective-C AppKit shell (`main.m`) hosts the entire UI (`index.html`, one self-contained file) in a transparent, click-through, full-screen WKWebView pinned just above the desktop. JavaScript reports note rectangles to the shell, which toggles mouse pass-through so only the notes are interactive. The expanded editor re-parents the webview into a real titled window and temporarily promotes the app's activation policy — which is why macOS treats it like an app launch. Dictation streams 16 kHz PCM from AVAudioEngine into whisper.cpp with ~1 s live passes.

## License

MIT. Bundles [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (MIT) and the Public Sans typeface (SIL OFL 1.1) embedded in the UI.
