#!/usr/bin/env bash
# Build Snapi.app. Usage: ./build.sh [--release] [--run]
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=Debug
RUN=0
for arg in "$@"; do
  case "$arg" in
    --release) CONFIG=Release ;;
    --run) RUN=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found. Install: brew install xcodegen" >&2
  exit 1
fi

echo "==> Generating Xcode project"
xcodegen generate --quiet

APP="build/Build/Products/$CONFIG/Snapi.app"
LOG="build/xcodebuild-$CONFIG.log"
mkdir -p build
rm -rf "$APP"   # never report success from a stale bundle

SIGN_IDENTITY="Snapi Dev"

echo "==> Building ($CONFIG)"
# ENABLE_DEBUG_DYLIB=NO: the debug-dylib preview mode leaves the .app wrapper
# unsigned, which breaks the stable-identity signing TCC relies on.
if ! xcodebuild \
  -project Snapi.xcodeproj \
  -scheme Snapi \
  -configuration "$CONFIG" \
  -derivedDataPath build \
  ENABLE_DEBUG_DYLIB=NO \
  build >"$LOG" 2>&1; then
  echo "BUILD FAILED — errors:" >&2
  grep -E "error:" "$LOG" | grep -viE "CoreSimulator|iOSSimulator" \
    | sed 's|^.*/Sources/|Sources/|' | sort -u | head -30 >&2
  echo "Full log: $LOG" >&2
  exit 1
fi

# Surface real warnings, drop toolchain noise.
grep -E "warning:" "$LOG" \
  | grep -viE "CoreSimulator|iOSSimulator|AppIntents" \
  | sed 's|^.*/Sources/|Sources/|' | sort -u | head -10 || true

if [[ ! -d "$APP" ]]; then
  echo "BUILD FAILED: $APP not produced. Full log: $LOG" >&2
  exit 1
fi

# Re-sign the whole bundle with the stable self-signed identity so macOS TCC
# keeps Screen Recording permission across rebuilds. Falls back to ad-hoc if
# the identity is missing (run ./setup-signing.sh to create it).
if security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP" >>"$LOG" 2>&1 \
    && echo "==> Signed with \"$SIGN_IDENTITY\"" \
    || { echo "Signing failed. See $LOG" >&2; exit 1; }
else
  echo "==> WARNING: identity \"$SIGN_IDENTITY\" not found — run ./setup-signing.sh"
  echo "   (permission will be re-requested each rebuild until then)"
fi
echo "==> Built $APP"

if [[ $RUN -eq 1 ]]; then
  echo "==> Restarting Snapi"
  pkill -x Snapi 2>/dev/null || true
  sleep 1
  open "$APP"
fi
