#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_NAME="Runbar"
readonly PROJECT_FILE="${SCRIPT_DIR}/${PROJECT_NAME}.xcodeproj"
readonly DERIVED_DATA_DIR="${SCRIPT_DIR}/.build/DerivedData"

log() {
  printf '[runbar bootstrap] %s\n' "$*"
}

die() {
  printf '[runbar bootstrap] ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  local command_name="$1"
  local install_hint="$2"

  command -v "${command_name}" >/dev/null 2>&1 || die "Missing ${command_name}. ${install_hint}"
}

install_xcodegen_if_needed() {
  if command -v xcodegen >/dev/null 2>&1; then
    return
  fi

  if [[ "${RUNBAR_INSTALL_TOOLS:-1}" == "0" ]]; then
    die "XcodeGen is required. Install it with 'brew install xcodegen', or rerun without RUNBAR_INSTALL_TOOLS=0."
  fi

  require_command brew "Install Homebrew from https://brew.sh, then rerun this script."
  log "XcodeGen is missing; installing it with Homebrew."
  brew install xcodegen
}

main() {
  [[ "$(uname -s)" == "Darwin" ]] || die "Runbar is a native macOS app; bootstrap must run on macOS."
  [[ -f "${SCRIPT_DIR}/project.yml" ]] || die "project.yml is missing from ${SCRIPT_DIR}."

  require_command xcodebuild "Install Xcode, launch it once, and accept its license."
  require_command xcrun "Install the Xcode command-line tools with 'xcode-select --install'."
  require_command swift "Install Xcode and select it with 'sudo xcode-select -s /Applications/Xcode.app'."
  install_xcodegen_if_needed

  log "Using $(xcodebuild -version | tr '\n' ' ')"
  log "Generating ${PROJECT_NAME}.xcodeproj from project.yml."
  xcodegen generate --spec "${SCRIPT_DIR}/project.yml" --project "${SCRIPT_DIR}"

  log "Resolving Swift package dependencies."
  xcodebuild \
    -project "${PROJECT_FILE}" \
    -scheme "${PROJECT_NAME}" \
    -resolvePackageDependencies

  log "Building the Debug configuration without code signing."
  xcodebuild \
    -project "${PROJECT_FILE}" \
    -scheme "${PROJECT_NAME}" \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "${DERIVED_DATA_DIR}" \
    CODE_SIGNING_ALLOWED=NO \
    build

  log "Bootstrap complete. Open ${PROJECT_FILE} to get started."
}

main "$@"
