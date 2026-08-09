#!/usr/bin/env bash
#
# Builds, signs, notarises and packages MotionCues.app for distribution.
#
# macOS refuses to run a downloaded app that is not signed with a Developer ID
# and notarised by Apple — the user gets "damaged and can't be opened", which
# is a lie the OS tells about unsigned software. So this is not optional if
# anyone other than the author is going to run it.
#
# Everything here needs credentials this script cannot invent. Set them in the
# environment or in a .env file beside this script (which .gitignore excludes):
#
#   DEVELOPER_ID   "Developer ID Application: Your Name (TEAMID)"
#                  → security find-identity -v -p codesigning
#   TEAM_ID        the 10-character team identifier
#   NOTARY_PROFILE the name of a stored notarytool keychain profile
#                  → xcrun notarytool store-credentials NOTARY_PROFILE \
#                      --apple-id you@example.com --team-id TEAMID \
#                      --password <app-specific-password>
#
# An app-specific password is created at appleid.apple.com, not your real one.
#
# Usage:  ./Scripts/release.sh 1.0.0
#         ./Scripts/release.sh 1.0.0 --skip-notarize   (local smoke test)

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
SKIP_NOTARIZE=false
[[ "${2:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=true

if [[ -z "$VERSION" ]]; then
  echo "usage: $0 <version> [--skip-notarize]" >&2
  exit 2
fi
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "version must be semver, e.g. 1.0.0 — got '$VERSION'" >&2
  exit 2
fi

# shellcheck disable=SC1091
[[ -f Scripts/.env ]] && source Scripts/.env

BUILD_DIR="build/release"
APP="$BUILD_DIR/MotionCues.app"
DMG="build/MotionCues-$VERSION.dmg"
ZIP="build/MotionCues-$VERSION.zip"

require() {
  if [[ -z "${!1:-}" ]]; then
    echo "error: \$$1 is not set — see the header of this script" >&2
    exit 1
  fi
}

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- preflight

step "Preflight"
require DEVELOPER_ID
require TEAM_ID
$SKIP_NOTARIZE || require NOTARY_PROFILE

if ! security find-identity -v -p codesigning | grep -qF "$DEVELOPER_ID"; then
  echo "error: no codesigning identity matching '$DEVELOPER_ID' in the keychain" >&2
  echo "       run: security find-identity -v -p codesigning" >&2
  exit 1
fi

command -v xcodegen >/dev/null || { echo "error: xcodegen not installed (brew install xcodegen)" >&2; exit 1; }

# The first use of a signing key pops a keychain dialog, and codesign blocks on
# it forever with no error. Fail fast and say so instead of appearing to hang.
if ! echo "probe" > "$TMPDIR/mc-sign-probe" \
   || ! timeout 20 codesign --force --sign "$DEVELOPER_ID" "$TMPDIR/mc-sign-probe" 2>/dev/null; then
  echo "error: could not use the signing key within 20s." >&2
  echo "       macOS is probably showing a keychain authorisation dialog." >&2
  echo "       Run this, click 'Always Allow', then try again:" >&2
  echo "         codesign --force --sign \"$DEVELOPER_ID\" /tmp/probe" >&2
  rm -f "$TMPDIR/mc-sign-probe"
  exit 1
fi
rm -f "$TMPDIR/mc-sign-probe"

# A dirty tree means the artefact does not correspond to any commit, which
# makes the release unreproducible and the version tag a lie.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree is dirty — commit or stash first" >&2
  git status --short >&2
  exit 1
fi

# ---------------------------------------------------------------- build

step "Generating the project"
xcodegen generate

step "Running the tests"
# Shipping a build whose tests were never run is how you ship the bug.
xcodebuild -project MotionCues.xcodeproj -scheme MotionCues \
           -configuration Debug -destination 'platform=macOS' test \
  | (command -v xcbeautify >/dev/null && xcbeautify || cat)

step "Building $VERSION"
rm -rf "$BUILD_DIR"
xcodebuild -project MotionCues.xcodeproj -scheme MotionCues \
           -configuration Release -destination 'platform=macOS' \
           MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)" \
           CONFIGURATION_BUILD_DIR="$PWD/$BUILD_DIR" \
           CODE_SIGN_IDENTITY="$DEVELOPER_ID" \
           CODE_SIGN_STYLE=Manual \
           DEVELOPMENT_TEAM="$TEAM_ID" \
           OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime" \
           build \
  | (command -v xcbeautify >/dev/null && xcbeautify || cat)

[[ -d "$APP" ]] || { echo "error: no app at $APP" >&2; exit 1; }

# ---------------------------------------------------------------- sign

step "Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP"
# Hardened runtime is a notarisation requirement, and easy to lose silently.
codesign -d --verbose=4 "$APP" 2>&1 | grep -q "flags=.*runtime" \
  || { echo "error: hardened runtime is not enabled" >&2; exit 1; }

# ---------------------------------------------------------------- notarise

if $SKIP_NOTARIZE; then
  step "Skipping notarisation (--skip-notarize)"
  echo "  The result will NOT run on another Mac."
else
  step "Notarising (this takes a few minutes)"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$ZIP"

  step "Stapling the ticket"
  # Without stapling the app needs the network on first launch to verify.
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"

  step "Checking Gatekeeper will accept it"
  spctl --assess --type execute --verbose=2 "$APP"
fi

# ---------------------------------------------------------------- package

step "Packaging"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "MotionCues" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

$SKIP_NOTARIZE || codesign --sign "$DEVELOPER_ID" --timestamp "$DMG"
$SKIP_NOTARIZE || xcrun stapler staple "$DMG"

ditto -c -k --keepParent "$APP" "$ZIP"

step "Done"
printf '  %s  (%s)\n' "$DMG" "$(du -h "$DMG" | cut -f1)"
printf '  %s  (%s)\n' "$ZIP" "$(du -h "$ZIP" | cut -f1)"
printf '  sha256 %s\n' "$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
printf '\nNext:\n'
printf '  git tag -a v%s -m "MotionCues %s" && git push origin v%s\n' "$VERSION" "$VERSION" "$VERSION"
printf '  gh release create v%s "%s" "%s" --title "MotionCues %s" --notes-file <(...)\n' \
       "$VERSION" "$DMG" "$ZIP" "$VERSION"
