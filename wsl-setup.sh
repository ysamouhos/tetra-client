#!/usr/bin/env bash
# Installs Flutter, Android SDK/NDK, JDK 17 and Rust inside WSL (Ubuntu), then
# builds the TETRA terminal APK and copies it back to Windows.
#
# Run in WSL:
#   bash /mnt/f/tetra-client/wsl-setup.sh
#
# Safe to re-run: every step skips what is already installed.
set -euo pipefail

WIN_SRC=/mnt/f/tetra-client
WORK=$HOME/tetra-client                 # build in the Linux filesystem (much faster than /mnt/c)
FLUTTER_DIR=$HOME/flutter
ANDROID_SDK=$HOME/Android/Sdk
CMDLINE_TOOLS_ZIP=commandlinetools-linux-11076708_latest.zip
NDK_VERSION=27.0.12077973

step() { echo; echo "==> $*"; }

step "System packages (sudo password may be asked once)"
sudo apt-get update -y
sudo apt-get install -y curl git unzip xz-utils zip clang cmake ninja-build pkg-config \
  libglu1-mesa openjdk-17-jdk build-essential rsync

step "Rust"
if ! command -v cargo >/dev/null; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi
# shellcheck disable=SC1091
source "$HOME/.cargo/env"
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android

step "Flutter (stable)"
if [ ! -d "$FLUTTER_DIR" ]; then
  git clone --depth 1 -b stable https://github.com/flutter/flutter.git "$FLUTTER_DIR"
fi
export PATH="$FLUTTER_DIR/bin:$HOME/.pub-cache/bin:$PATH"
flutter config --no-analytics >/dev/null
flutter --version

step "Android SDK + NDK"
export ANDROID_HOME=$ANDROID_SDK ANDROID_SDK_ROOT=$ANDROID_SDK
if [ ! -x "$ANDROID_SDK/cmdline-tools/latest/bin/sdkmanager" ]; then
  mkdir -p "$ANDROID_SDK/cmdline-tools"
  tmp=$(mktemp -d)
  curl -sSL -o "$tmp/tools.zip" "https://dl.google.com/android/repository/$CMDLINE_TOOLS_ZIP"
  unzip -q "$tmp/tools.zip" -d "$tmp"
  mv "$tmp/cmdline-tools" "$ANDROID_SDK/cmdline-tools/latest"
  rm -rf "$tmp"
fi
export PATH="$ANDROID_SDK/cmdline-tools/latest/bin:$ANDROID_SDK/platform-tools:$PATH"
yes | sdkmanager --licenses >/dev/null || true
sdkmanager "platform-tools" "platforms;android-35" "build-tools;35.0.0" "ndk;$NDK_VERSION"
flutter config --android-sdk "$ANDROID_SDK" >/dev/null
yes | flutter doctor --android-licenses >/dev/null || true

step "flutter_rust_bridge codegen"
command -v flutter_rust_bridge_codegen >/dev/null || cargo install flutter_rust_bridge_codegen@2.13.0

step "Persist PATH in ~/.bashrc"
if ! grep -q "tetra-client env" "$HOME/.bashrc"; then
  cat >> "$HOME/.bashrc" <<EOF
# tetra-client env
export ANDROID_HOME=$ANDROID_SDK
export ANDROID_SDK_ROOT=$ANDROID_SDK
export PATH="$FLUTTER_DIR/bin:\$HOME/.pub-cache/bin:$ANDROID_SDK/cmdline-tools/latest/bin:$ANDROID_SDK/platform-tools:\$PATH"
source "\$HOME/.cargo/env"
EOF
fi

step "Copy project into WSL ($WORK)"
mkdir -p "$WORK"
rsync -a --exclude target --exclude build --exclude .dart_tool "$WIN_SRC/" "$WORK/"

step "Rust core tests"
(cd "$WORK/tetra_core" && cargo test -q)

step "App setup (platform folders, Rust bridge, bindings)"
cd "$WORK/app"
chmod +x tool/setup.sh
./tool/setup.sh

step "Analyze"
flutter analyze || echo "!! flutter analyze reported issues (see above)"

step "Build debug APK"
flutter build apk --debug
mkdir -p "$WIN_SRC/out"
cp build/app/outputs/flutter-apk/app-debug.apk "$WIN_SRC/out/tetra-terminal-debug.apk"

flutter doctor
echo
echo "APK copied to: F:\\tetra-client\\out\\tetra-terminal-debug.apk"
echo "Install it on a phone, or use adb over Wi-Fi from WSL:  adb pair <ip:port>; adb connect <ip:port>; flutter run"
