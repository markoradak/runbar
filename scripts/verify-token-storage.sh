#!/usr/bin/env bash

set -Eeuo pipefail
set +x

readonly BUNDLE_ID="app.runbar.Runbar"
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly LOG_EXPORT="$(mktemp -t runbar-logs.XXXXXX)"

cleanup() {
  unset token_marker
  rm -f "${LOG_EXPORT}"
}
trap cleanup EXIT

read -r -s -p "Paste the exact token to search for (input is hidden): " token_marker
printf '\n'
[[ -n "${token_marker}" ]] || { printf 'ERROR: token was empty.\n' >&2; exit 2; }

search_path() {
  local label="$1"
  local path="$2"

  if [[ ! -e "${path}" ]]; then
    printf 'PASS %-24s not present: %s\n' "${label}" "${path}"
    return
  fi

  if grep -R -q -F -f <(printf '%s\n' "${token_marker}") -- "${path}" 2>/dev/null; then
    printf 'FAIL %-24s token marker found (value suppressed): %s\n' "${label}" "${path}" >&2
    return 1
  fi
  printf 'PASS %-24s no token marker: %s\n' "${label}" "${path}"
}

failure=0
search_path "app container" "${HOME}/Library/Containers/${BUNDLE_ID}" || failure=1
search_path "preferences plist" "${HOME}/Library/Preferences/${BUNDLE_ID}.plist" || failure=1
search_path "application support" "${HOME}/Library/Application Support/Runbar" || failure=1
search_path "application cache" "${HOME}/Library/Caches/${BUNDLE_ID}" || failure=1
search_path "saved app state" "${HOME}/Library/Saved Application State/${BUNDLE_ID}.savedState" || failure=1
search_path "local build products" "${REPO_ROOT}/.build" || failure=1

/usr/bin/log show --style compact --last 1h --predicate 'process == "Runbar"' >"${LOG_EXPORT}" 2>/dev/null || true
if grep -q -F -f <(printf '%s\n' "${token_marker}") -- "${LOG_EXPORT}"; then
  printf 'FAIL %-24s token marker found (value suppressed)\n' "unified logs" >&2
  failure=1
else
  printf 'PASS %-24s no token marker in last hour\n' "unified logs"
fi

if [[ "${failure}" -ne 0 ]]; then
  printf 'M0 token-storage verification FAILED.\n' >&2
  exit 1
fi
printf 'M0 token-storage verification PASSED. Keychain was intentionally not searched.\n'
