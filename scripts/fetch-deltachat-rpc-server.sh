#!/usr/bin/env bash
# Downloads a standalone deltachat-rpc-server binary for the current
# platform from https://github.com/chatmail/core/releases and stores
# it under .deps/. The URL is fully predictable from
# RPC_VERSION + asset name, so no GitHub API call is needed.
#
# Usage:
#   scripts/fetch-deltachat-rpc-server.sh            # fetch if missing
#   scripts/fetch-deltachat-rpc-server.sh --print-path   # echo path
#
# Override via env: RPC_VERSION (default v2.57.0), RPC_REPO (default chatmail/core)
set -euo pipefail

RPC_VERSION="${RPC_VERSION:-v2.57.0}"
RPC_REPO="${RPC_REPO:-chatmail/core}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/.deps"

# platform -> GitHub release asset name
declare -A ASSET=(
  [linux-x64]="deltachat-rpc-server-x86_64-linux"
  [linux-arm64]="deltachat-rpc-server-aarch64-linux"
  [darwin-x64]="deltachat-rpc-server-x86_64-macos"
  [darwin-arm64]="deltachat-rpc-server-aarch64-macos"
  [windows-x64]="deltachat-rpc-server-win64.exe"
)

detect_platform() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$os/$arch" in
    linux/x86_64)   echo linux-x64 ;;
    linux/aarch64)  echo linux-arm64 ;;
    darwin/x86_64)  echo darwin-x64 ;;
    darwin/arm64)   echo darwin-arm64 ;;
    mingw64_nt*/x86_64|msys_nt*/x86_64|cygwin_nt*/x86_64) echo windows-x64 ;;
    *) echo "unsupported: ${os}/${arch}" >&2; return 1 ;;
  esac
}

main() {
  local platform; platform="$(detect_platform)"
  local asset="${ASSET[$platform]}"
  local out="${DEPS_DIR}/${asset}"
  local url="https://github.com/${RPC_REPO}/releases/download/${RPC_VERSION}/${asset}"

  if [[ "${1:-}" == "--print-path" ]]; then
    if [[ ! -f "$out" ]]; then
      echo "Run 'make deps' first to download $asset" >&2
      exit 1
    fi
    echo "$out"
    return
  fi

  mkdir -p "$DEPS_DIR"
  if [[ -f "$out" ]]; then
    echo "$out (cached)"
    return
  fi

  echo "Fetching $url ..."
  if ! curl --fail --silent --show-error --location --output "$out.tmp" "$url"; then
    rm -f "$out.tmp"
    echo "Failed to download $asset for $platform from $url" >&2
    exit 1
  fi

  mv "$out.tmp" "$out"
  if [[ "$platform" != windows-* ]]; then
    chmod +x "$out"
  fi
  echo "Saved to $out ($(wc -c < "$out" | tr -d ' ') bytes)"
}

main "$@"
