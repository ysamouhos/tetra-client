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
        # Only cargokit's build lines: the crate path, Gradle's libname and the
        # iOS -force_load of the static lib. Package/pod names stay unchanged.
        if "../../rust" not in text:
            continue
        out = []
        for line in text.splitlines(keepends=True):
            if "../../rust" in line or "libname" in line:
                line = line.replace("../../rust", "../../../tetra_core").replace("rust_lib_tetra_terminal", "tetra_core")
            line = line.replace("librust_lib_tetra_terminal", "libtetra_core")
            out.append(line)
        new = "".join(out)
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

# 6b. Release signing: use android/key.properties (written by CI from secrets,
#     or by you locally) when it exists; otherwise release builds use the debug key.
python3 - <<'PY'
import os, re, sys
p = "android/app/build.gradle.kts"
if not os.path.exists(p):
    sys.exit("expected android/app/build.gradle.kts (Kotlin DSL) for release signing")
s = open(p).read()
if "keystoreProperties" not in s:
    props = (
        "\nval keystoreProperties = java.util.Properties().apply {\n"
        "    val f = rootProject.file(\"key.properties\")\n"
        "    if (f.exists()) f.inputStream().use { load(it) }\n"
        "}\n"
    )
    m = re.search(r"^plugins \{.*?^\}\n", s, re.S | re.M)
    if not m:
        sys.exit("no plugins {} block in " + p)
    s = s[:m.end()] + props + s[m.end():]
    signing = (
        "    signingConfigs {\n"
        "        create(\"release\") {\n"
        "            if (!keystoreProperties.isEmpty) {\n"
        "                storeFile = file(keystoreProperties.getProperty(\"storeFile\"))\n"
        "                storePassword = keystoreProperties.getProperty(\"storePassword\")\n"
        "                keyAlias = keystoreProperties.getProperty(\"keyAlias\")\n"
        "                keyPassword = keystoreProperties.getProperty(\"keyPassword\")\n"
        "            }\n"
        "        }\n"
        "    }\n\n"
        "    buildTypes {"
    )
    if "    buildTypes {" not in s:
        sys.exit("no buildTypes block in " + p)
    s = s.replace("    buildTypes {", signing, 1)
    s, n = re.subn(r'signingConfig = signingConfigs\.getByName\("debug"\)',
                   'signingConfig = if (keystoreProperties.isEmpty) signingConfigs.getByName("debug") else signingConfigs.getByName("release")',
                   s, count=1)
    if n != 1:
        sys.exit("could not find the release signingConfig line in " + p)
    open(p, "w").write(s)
    print("release signing wired into", p)
PY

# 6. App icon and display name.
dart run flutter_launcher_icons
sed -i.bak -E 's/android:label="[^"]*"/android:label="TETRA Terminal"/' android/app/src/main/AndroidManifest.xml && rm -f android/app/src/main/AndroidManifest.xml.bak
python3 - ios/Runner/Info.plist <<'PY'
import plistlib, sys
p = sys.argv[1]
d = plistlib.load(open(p, 'rb'))
d['CFBundleDisplayName'] = 'TETRA Terminal'
d['CFBundleName'] = 'TETRA Terminal'
plistlib.dump(d, open(p, 'wb'))
PY

echo
echo "Done. Connect an Android phone and run:  flutter run"
