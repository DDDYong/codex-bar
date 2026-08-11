#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CodexBar"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/macos/CodexBar/CodexBar.xcodeproj"
SCHEME="CodexBar"
DERIVED_DATA="$ROOT_DIR/.build/CodexBar"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
INSTALLED_APP_BUNDLE="/Applications/$APP_NAME.app"
INSTALLED_APP_BINARY="$INSTALLED_APP_BUNDLE/Contents/MacOS/$APP_NAME"
LEGACY_APP_BUNDLE="/Applications/Codex Bar.app"
BUNDLE_ID="com.codexbar.app"
STALE_PROCESS_NAMES=("CodexBar" "Codex Bar")

if [[ ! -d "$PROJECT" ]]; then
  echo "Xcode project was not found: $PROJECT" >&2
  exit 1
fi

stop_running_apps() {
  local process_name
  local attempt

  for process_name in "${STALE_PROCESS_NAMES[@]}"; do
    pkill -x "$process_name" >/dev/null 2>&1 || true
  done

  for attempt in {1..20}; do
    local is_running=false

    for process_name in "${STALE_PROCESS_NAMES[@]}"; do
      if pgrep -x "$process_name" >/dev/null; then
        is_running=true
        break
      fi
    done

    if [[ "$is_running" == false ]]; then
      return
    fi

    sleep 0.1
  done
}

stop_running_apps

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  build

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Built app bundle was not found: $APP_BUNDLE" >&2
  exit 1
fi

install_app() {
  local staging_bundle="/Applications/.${APP_NAME}.install-$$.app"
  local signing_identity_hash

  rm -rf "$staging_bundle"
  /usr/bin/ditto "$APP_BUNDLE" "$staging_bundle"

  if [[ -n "${CODEXBAR_SIGNING_IDENTITY:-}" ]]; then
    signing_identity_hash="$(printf '%s' "$CODEXBAR_SIGNING_IDENTITY" | /usr/bin/tr '[:lower:]' '[:upper:]')"
    if [[ ! "$signing_identity_hash" =~ ^[[:xdigit:]]{40}$ ]]; then
      echo "CODEXBAR_SIGNING_IDENTITY must be a 40-character certificate hash" >&2
      exit 1
    fi
    if ! /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
      | /usr/bin/awk -v expected="$signing_identity_hash" '$2 == expected { found = 1 } END { exit(found ? 0 : 1) }'; then
      echo "CODEXBAR_SIGNING_IDENTITY does not match an available code-signing identity" >&2
      exit 1
    fi
    /usr/bin/codesign \
      --force \
      --deep \
      --sign "$signing_identity_hash" \
      --timestamp=none \
      --preserve-metadata=entitlements,flags \
      "$staging_bundle"
  else
    echo "warning: CODEXBAR_SIGNING_IDENTITY is unset; installed app will keep its build signature" >&2
  fi
  /usr/bin/codesign --verify --deep --strict "$staging_bundle"

  rm -rf "$INSTALLED_APP_BUNDLE"
  /bin/mv "$staging_bundle" "$INSTALLED_APP_BUNDLE"

  if [[ "$LEGACY_APP_BUNDLE" != "$INSTALLED_APP_BUNDLE" && -d "$LEGACY_APP_BUNDLE" ]]; then
    rm -rf "$LEGACY_APP_BUNDLE"
  fi
}

install_app

open_app() {
  /usr/bin/open "$INSTALLED_APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$INSTALLED_APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
