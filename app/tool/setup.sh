#!/usr/bin/env bash
# One-time project setup. Run from the app/ directory:
#   ./tool/setup.sh
# Needs: Flutter >= 3.22, Rust (rustup), Android NDK (via Android Studio),
#        cargo install flutter_rust_bridge_codegen@2.13.0
set -euo pipefail
cd "$(dirname "$0")/.."
APP_DIR=$(pwd)
FRB_VERSION=2.13.0

command -v flutter >/dev/null || { echo "flutter not found"; exit 1; }
command -v flutter_rust_bridge_codegen >/dev/null || cargo install "flutter_rust_bridge_codegen@${FRB_VERSION}"

# 1. Android/iOS platform folders (existing lib/ and pubspec.yaml are kept).
flutter create --no-pub --project-name tetra_terminal --org org.tetra.terminal --platforms=android,ios .

# 2. Borrow flutter_rust_bridge's cargokit plugin (rust_builder/) from a scratch
#    project, then point it at ../tetra_core instead of a bundled rust/ dir.
if [ ! -d rust_builder ]; then
  TMP=$(mktemp -d)
  (cd "$TMP" && flutter create --no-pub --project-name tetra_terminal --platforms=android,ios scratch >/dev/null \
     && cd scratch && flutter_rust_bridge_codegen integrate)
  cp -r "$TMP/scratch/rust_builder" .
  rm -rf "$TMP"
  # Cargokit paths are relative to rust_builder/{android,ios}.
  # Point cargokit at ../tetra_core and its library name (portable: GNU and BSD).
  python3 - <<'PY'
import os, sys
changed = 0
for root, _, files in os.walk("rust_builder"):
    if "/build_tool/.dart_tool" in root:
        continue
    for name in files:
        path = os.path.join(root, name)
        try:
            text = open(path, encoding="utf-8").read()
        except (UnicodeDecodeError, OSError):
            continue
        # Only the cargokit build files (they reference ../../rust); the package
        # name in pubspec.yaml and the plugin class names must stay unchanged.
        if "../../rust" not in text:
            continue
        new = text.replace("../../rust", "../../../tetra_core").replace("rust_lib_tetra_terminal", "tetra_core")
        if new != text:
            open(path, "w", encoding="utf-8").write(new)
            changed += 1
            print("patched", path)
if changed == 0:
    sys.exit("rust_builder: nothing to patch -- flutter_rust_bridge template changed?")
PY
  # Newer Android Gradle Plugin: namespace must come from build.gradle, not the manifest.
  sed -i.bak 's/ package="[^"]*"//' rust_builder/android/src/main/AndroidManifest.xml && rm -f rust_builder/android/src/main/AndroidManifest.xml.bak
  grep -q namespace rust_builder/android/build.gradle || \
    python3 -c 'import sys;p=sys.argv[1];s=open(p).read();open(p,"w").write(s.replace("android {","android {\n    namespace \"com.flutter_rust_bridge.tetra_core\"",1))' rust_builder/android/build.gradle
fi

# 3. Rustup targets.
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
if [[ "$(uname)" == "Darwin" ]]; then rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; fi

# 4. Permissions.
MANIFEST=android/app/src/main/AndroidManifest.xml
if ! grep -q RECORD_AUDIO "$MANIFEST"; then
  sed -i.bak 's#<application#<uses-permission android:name="android.permission.INTERNET"/>\
    <uses-permission android:name="android.permission.RECORD_AUDIO"/>\
    <uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS"/>\
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>\
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>\
    <uses-permission android:name="android.permission.WAKE_LOCK"/>\
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>\
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>\
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE"/>\
    <application#' "$MANIFEST" && rm -f "$MANIFEST.bak"
fi
GRADLE=$(ls android/app/build.gradle* | head -1)
sed -i.bak -E 's/minSdk(Version)? *=? *flutter\.minSdkVersion/minSdk = 23/' "$GRADLE" && rm -f "$GRADLE.bak"

PLIST=ios/Runner/Info.plist
# Edit the top-level dict only (a sed on "<dict>" would hit nested dicts too).
python3 - "$PLIST" <<'PY'
import plistlib, sys
p = sys.argv[1]
with open(p, 'rb') as f:
    d = plistlib.load(f)
d['NSMicrophoneUsageDescription'] = 'Needed to talk on TETRA calls.'
d['NSLocationWhenInUseUsageDescription'] = 'Sends your position (LIP) to dispatch.'
d['NSLocationAlwaysAndWhenInUseUsageDescription'] = 'Sends your position (LIP) to dispatch.'
d['UIBackgroundModes'] = sorted(set(d.get('UIBackgroundModes', [])) | {'audio', 'location'})
d['NSAppTransportSecurity'] = {'NSAllowsArbitraryLoads': True}  # plain http:// Brew servers
with open(p, 'wb') as f:
    plistlib.dump(d, f)
PY


# Allow plain http:// Brew servers (lab / LAN).
grep -q usesCleartextTraffic "$MANIFEST" || sed -i.bak 's#<application#<application android:usesCleartextTraffic="true"#' "$MANIFEST" && rm -f "$MANIFEST.bak"

# 4b. Plugins pinned to an old compileSdk (flutter_pcm_sound: 33) break newer AndroidX deps.
sdkmanager "platforms;android-36" >/dev/null 2>&1 || true
if ! grep -q "flutter_pcm_sound: 33" android/build.gradle* 2>/dev/null; then
  if [ -f android/build.gradle.kts ]; then cat >> android/build.gradle.kts <<'KTS'

// Plugins pinned to an old compileSdk (flutter_pcm_sound: 33) break newer AndroidX deps.
subprojects {
    val bump = { p: Project ->
        p.extensions.findByType(com.android.build.gradle.BaseExtension::class.java)?.compileSdkVersion(36)
    }
    if (state.executed) bump(this) else afterEvaluate { bump(this) }
}
KTS
  else cat >> android/build.gradle <<'GRV'

// Plugins pinned to an old compileSdk (flutter_pcm_sound: 33) break newer AndroidX deps.
subprojects {
    def bump = { p -> p.extensions.findByName("android")?.compileSdkVersion(36) }
    if (state.executed) bump(project) else afterEvaluate { bump(project) }
}
GRV
  fi
fi

# 5. Generate the Dart bindings (also adds `mod frb_generated;` to tetra_core).
flutter pub get
flutter_rust_bridge_codegen generate
dart run build_runner build --delete-conflicting-outputs

echo
echo "Done. Connect an Android phone and run:  flutter run"
