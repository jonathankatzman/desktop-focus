#!/bin/bash
set -e

APP_NAME="DesktopFocus"
APP_BUNDLE="${APP_NAME}.app"
SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:--}"

echo "==> Building ${APP_NAME}..."
swift build -c release 2>&1

echo "==> Creating app bundle..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp ".build/release/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/"
cp Info.plist "${APP_BUNDLE}/Contents/"
cp Assets/DesktopFocus.icns "${APP_BUNDLE}/Contents/Resources/"
xattr -cr "${APP_BUNDLE}" 2>/dev/null || true

echo "==> Signing..."
codesign --force --sign "${SIGNING_IDENTITY}" --entitlements entitlements.plist "${APP_BUNDLE}"

echo ""
echo "Done!  ${APP_BUNDLE} is ready."
echo ""
echo "To install: cp -r ${APP_BUNDLE} /Applications/"
echo "To run now: open ${APP_BUNDLE}"
echo ""
echo "NOTE: Grant Accessibility access when starting your first focus session"
echo "      (System Settings > Privacy & Security > Accessibility)"
