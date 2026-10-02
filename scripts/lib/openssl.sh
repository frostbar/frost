# shellcheck shell=bash
# Sourced by scripts that need OpenSSL 3 or later: macOS's /usr/bin/openssl is LibreSSL, which lacks
# `pkcs12 -legacy` (scripts/create-signing-cert.sh) and Ed25519 `pkeyutl -rawin` (scripts/release/release.sh).

# Prints the path of an OpenSSL >= 3 binary and returns 0, or returns 1 if there is none. Tries, in order: $OPENSSL
# (an explicit override), Homebrew's openssl@3 (Apple silicon and Intel prefixes), Homebrew's default `openssl`, and
# the `openssl` on PATH.
find_openssl() {
  local candidate prefix
  local -a candidates=()
  if [[ -n ${OPENSSL:-} ]]; then candidates+=("$OPENSSL"); fi
  if command -v brew >/dev/null 2>&1 && prefix=$(brew --prefix openssl@3 2>/dev/null); then
    candidates+=("$prefix/bin/openssl")
  fi
  candidates+=(/opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl
               /opt/homebrew/bin/openssl /usr/local/bin/openssl)
  if candidate=$(command -v openssl 2>/dev/null); then candidates+=("$candidate"); fi
  for candidate in "${candidates[@]}"; do
    if [[ -x $candidate ]] && "$candidate" version 2>/dev/null | grep -Eq '^OpenSSL ([3-9]|[1-9][0-9])\.'; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}
