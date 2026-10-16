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
LAUNCH_SERVICES_REGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"
USER_HOME="${HOME:-}"
QUARANTINE_DIR=""
QUARANTINE_RUN_ID=""
QUARANTINED_COUNT=0

if [[ ! -d "$PROJECT" ]]; then
  echo "Xcode project was not found: $PROJECT" >&2
  exit 1
fi

stop_running_apps() {
  local process_name
  local attempt
  local has_running_app=false

  for process_name in "${STALE_PROCESS_NAMES[@]}"; do
    if pgrep -x "$process_name" >/dev/null; then
      has_running_app=true
      break
    fi
  done

  if [[ "$has_running_app" == true ]]; then
    /usr/bin/osascript -e 'tell application id "com.codexbar.app" to quit' >/dev/null 2>&1 || true
  fi

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

  for process_name in "${STALE_PROCESS_NAMES[@]}"; do
    pkill -TERM -x "$process_name" >/dev/null 2>&1 || true
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

unregister_bundle_from_launch_services() {
  local bundle="$1"

  if [[ -x "$LAUNCH_SERVICES_REGISTER" && -d "$bundle" ]]; then
    "$LAUNCH_SERVICES_REGISTER" -u "$bundle" >/dev/null 2>&1 || true
  fi
}

create_quarantine_directory() {
  if [[ -n "$QUARANTINE_DIR" ]]; then
    return
  fi

  if [[ -z "$USER_HOME" ]]; then
    echo "Cannot quarantine stale app bundles because the user home directory is unavailable" >&2
    exit 1
  fi

  /bin/mkdir -p "$USER_HOME/Library/Caches"
  QUARANTINE_DIR="$USER_HOME/Library/Caches/CodexBar-launchpad-quarantine.noindex"
  /bin/mkdir -p "$QUARANTINE_DIR"
  QUARANTINE_RUN_ID="$(/bin/date +%Y%m%d%H%M%S)-$$"
}

quarantine_stale_bundle() {
  local bundle="$1"

  if [[ ! -d "$bundle" || "$bundle" == "$INSTALLED_APP_BUNDLE" ]]; then
    return
  fi

  create_quarantine_directory
  unregister_bundle_from_launch_services "$bundle"

  local destination="$QUARANTINE_DIR/${QUARANTINE_RUN_ID}-${QUARANTINED_COUNT}-$(basename "$bundle").quarantined"
  /bin/mv "$bundle" "$destination"
  unregister_bundle_from_launch_services "$destination"
  QUARANTINED_COUNT=$((QUARANTINED_COUNT + 1))
  echo "info: quarantined stale app bundle: $bundle"
}

unregister_stale_bundles_under() {
  local root="$1"
  local bundle

  if [[ ! -d "$root" ]]; then
    return
  fi

  while IFS= read -r -d '' bundle; do
    quarantine_stale_bundle "$bundle"
  done < <(
    find "$root" -type d \( -name "$APP_NAME.app" -o -name "Codex Bar.app" \) -prune -print0
  )
}

unregister_stale_local_bundles() {
  unregister_stale_bundles_under "$ROOT_DIR/.build"
  unregister_stale_bundles_under "$ROOT_DIR/output"
  unregister_stale_bundles_under "$ROOT_DIR/src-tauri/target"

  local xcode_derived_data="$USER_HOME/Library/Developer/Xcode/DerivedData"
  if [[ -n "$USER_HOME" && -d "$xcode_derived_data" ]]; then
    unregister_stale_bundles_under "$xcode_derived_data"
  fi

  unregister_bundle_from_launch_services "$LEGACY_APP_BUNDLE"

  if [[ "$QUARANTINED_COUNT" -gt 0 && -x "$LAUNCH_SERVICES_REGISTER" ]]; then
    "$LAUNCH_SERVICES_REGISTER" -gc >/dev/null 2>&1 || true
  fi
}

register_installed_bundle() {
  if [[ -x "$LAUNCH_SERVICES_REGISTER" && -d "$INSTALLED_APP_BUNDLE" ]]; then
    "$LAUNCH_SERVICES_REGISTER" -f "$INSTALLED_APP_BUNDLE" >/dev/null 2>&1 || true
  fi
}

install_app() {
  local staging_bundle="/Applications/.${APP_NAME}.install-$$.app"
  local signing_identity_hash
  local detected_signing_identities
  local detected_identity_count

  rm -rf "$staging_bundle"
  /usr/bin/ditto "$APP_BUNDLE" "$staging_bundle"

  if [[ -z "${CODEXBAR_SIGNING_IDENTITY:-}" ]]; then
    detected_signing_identities="$(
      /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
        | /usr/bin/awk '/Apple Development:/ { print $2 }' \
        || true
    )"
    detected_identity_count="$(printf '%s\n' "$detected_signing_identities" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
    if [[ "$detected_identity_count" == "1" ]]; then
      CODEXBAR_SIGNING_IDENTITY="$detected_signing_identities"
      echo "info: using the only available Apple Development signing identity"
    fi
  fi

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
    unregister_bundle_from_launch_services "$LEGACY_APP_BUNDLE"
    rm -rf "$LEGACY_APP_BUNDLE"
  fi
}

install_app
unregister_stale_local_bundles
register_installed_bundle

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
