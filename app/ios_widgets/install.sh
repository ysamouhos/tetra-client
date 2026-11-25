#!/usr/bin/env bash
# Adds the Live Activity / home screen widget extension to the generated iOS
# project (ios/ is created by tool/setup.sh). Run from app/ on macOS after
# setup.sh; needs the xcodeproj gem (comes with CocoaPods). Idempotent.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=ios_widgets

APP_ID=$(grep -m1 'PRODUCT_BUNDLE_IDENTIFIER = ' ios/Runner.xcodeproj/project.pbxproj | sed -E 's/.*= ([^;]+);/\1/')
VERSION=$(grep -m1 '^version:' pubspec.yaml | sed -E 's/version: *//')
NAME=${VERSION%%+*}
BUILD=${VERSION#*+}
[ "$BUILD" = "$VERSION" ] && BUILD=1

mkdir -p ios/Shared ios/TetraWidgets
cp "$SRC/Shared/TetraShared.swift" ios/Shared/
cp "$SRC/Runner/TetraLivePlugin.swift" ios/Runner/
cp "$SRC"/TetraWidgets/*.swift "$SRC/TetraWidgets/Info.plist" ios/TetraWidgets/
sed "s/APP_BUNDLE_ID/$APP_ID/" "$SRC/Runner/Runner.entitlements" > ios/Runner/Runner.entitlements
sed "s/APP_BUNDLE_ID/$APP_ID/" "$SRC/TetraWidgets/TetraWidgets.entitlements" > ios/TetraWidgets/TetraWidgets.entitlements

# Register the channel plugin next to the generated plugins (works with the
# implicit-engine template and the older one that registers with self).
python3 - ios/Runner/AppDelegate.swift <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
if "TetraLivePlugin" not in s:
    s, n = re.subn(r"^(\s*)GeneratedPluginRegistrant\.register\(with: ([^)]+)\)\n",
                   lambda m: m.group(0) + f'{m.group(1)}if let r = {m.group(2)}.registrar(forPlugin: "TetraLivePlugin") {{ TetraLivePlugin.register(with: r) }}\n',
                   s, count=1, flags=re.M)
    if n != 1:
        sys.exit("AppDelegate.swift: GeneratedPluginRegistrant line not found")
    open(p, "w").write(s)
PY

python3 - ios/Runner/Info.plist <<'PY'
import plistlib, sys
p = sys.argv[1]
d = plistlib.load(open(p, 'rb'))
d['NSSupportsLiveActivities'] = True
d['NSSupportsLiveActivitiesFrequentUpdates'] = True
plistlib.dump(d, open(p, 'wb'))
PY

ruby "$SRC/add_targets.rb" ios "$NAME" "$BUILD"
