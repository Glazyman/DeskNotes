#!/bin/zsh
# Build Desk Notes.app — menu-bar sticky notes with local Whisper dictation.
set -e
cd "$(dirname "$0")"

APP="Desk Notes.app"
W="whisper.cpp"
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ compiling (Objective-C + whisper.cpp)…"
clang -fobjc-arc -O2 main.m \
  -isysroot "$SDK" \
  -I "$W/include" -I "$W/ggml/include" \
  "$W/build/src/libwhisper.a" \
  "$W/build/ggml/src/libggml.a" \
  "$W/build/ggml/src/libggml-base.a" \
  "$W/build/ggml/src/libggml-cpu.a" \
  "$W/build/ggml/src/ggml-blas/libggml-blas.a" \
  "$W/build/ggml/src/ggml-metal/libggml-metal.a" \
  -framework Cocoa -framework WebKit -framework AVFoundation \
  -framework Accelerate -framework Metal -framework MetalKit -framework Foundation \
  -lc++ \
  -o "$APP/Contents/MacOS/DeskNotes"

echo "→ bundling resources…"
cp Info.plist "$APP/Contents/Info.plist"
cp index.html "$APP/Contents/Resources/index.html"
cp ggml-base.en.bin "$APP/Contents/Resources/ggml-base.en.bin"

echo "→ signing (ad-hoc, local use)…"
codesign --force -s - "$APP"

echo "✓ built $APP"
