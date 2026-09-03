#!/usr/bin/env sh
# install.sh — download and install the dkod-signals release binary.
#
# What this does: detects OS/arch, downloads the matching release asset and
# SHA256SUMS from GitHub Releases, verifies the checksum, and installs the
# binary to /usr/local/bin (or $PREFIX/bin). Nothing is uploaded — this
# script only ever talks to GitHub's release API/CDN to fetch the binary
# itself; it never runs dkod-signals and never sends anything anywhere.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/dkod-ai/dkod-signals-releases/main/install.sh | sh
#   curl -fsSL .../install.sh | VERSION=v0.1.0 PREFIX=/opt/dkod sh
#
# Env vars:
#   VERSION   Release tag to install, e.g. v0.1.0 [default: latest]
#   PREFIX    Install prefix; binary goes to $PREFIX/bin [default: /usr/local]
#   GH_TOKEN  GitHub token, sent as an Authorization header — needed only if
#             dkod-ai/dkod-signals is (or becomes) a private repo.

set -eu

REPO="dkod-ai/dkod-signals-releases"
PREFIX="${PREFIX:-/usr/local}"
BIN_NAME="dkod-signals"

log() { printf 'install.sh: %s\n' "$*" >&2; }
die() {
  log "error: $*"
  exit 1
}

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not found"; }

need curl
need tar
need mktemp

# --- auth header, only if GH_TOKEN is set ---------------------------------
curl_auth() {
  if [ -n "${GH_TOKEN:-}" ]; then
    curl -fsSL -H "Authorization: Bearer ${GH_TOKEN}" "$@"
  else
    curl -fsSL "$@"
  fi
}

# --- OS/arch detection ------------------------------------------------------
os_name="$(uname -s)"
arch_name="$(uname -m)"

case "$os_name" in
  Darwin) os="apple-darwin" ;;
  Linux) os="unknown-linux-musl" ;;
  *) die "unsupported OS: $os_name (macOS and Linux only; Windows uses windows-intune.ps1)" ;;
esac

case "$arch_name" in
  x86_64 | amd64) arch="x86_64" ;;
  arm64 | aarch64) arch="aarch64" ;;
  *) die "unsupported architecture: $arch_name" ;;
esac

TARGET="${arch}-${os}"

# --- resolve the release ------------------------------------------------------
# The whole release payload is fetched once and reused: it carries the tag AND
# every asset's API id, and the ids are the only way to download from a private
# repository (see fetch_asset).
if [ -n "${VERSION:-}" ]; then
  RELEASE_JSON="$(curl_auth "https://api.github.com/repos/${REPO}/releases/tags/${VERSION}")" \
    || die "could not find release ${VERSION}"
else
  log "resolving latest release..."
  RELEASE_JSON="$(curl_auth "https://api.github.com/repos/${REPO}/releases/latest")" \
    || die "could not reach the GitHub API. For a private repository, export GH_TOKEN first"
  VERSION="$(printf '%s' "$RELEASE_JSON" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
  [ -n "$VERSION" ] || die "could not resolve the latest release tag"
fi

VERSION_NUM="${VERSION#v}"
ASSET="dkod-signals-${VERSION_NUM}-${TARGET}.tar.gz"

# --- downloading one asset ----------------------------------------------------
# A private repository's assets are NOT reachable at
# github.com/<repo>/releases/download/<tag>/<name>. That URL 404s with a valid
# token, because the token is dropped on the redirect to the storage host. The
# API asset endpoint with `Accept: application/octet-stream` is the only path
# that authenticates, and it needs the asset's numeric id rather than its name.
#
# Public repositories work either way, so this is used unconditionally: one code
# path that is exercised every time beats a private-only branch that is not.
asset_id_for() { # asset-name
  # Flattens the payload, normalises "key": "value" to "key":"value" so the
  # match does not depend on the API's pretty-printing, splits on "{" so each
  # asset object is one line, and reads the id out of that object's own API URL.
  # Matching the /releases/assets/<id> URL rather than a bare "id" field is what
  # stops this picking up the release id, the uploader id, or any other number.
  printf '%s' "$RELEASE_JSON" \
    | tr -d '\n' \
    | sed 's/"[[:space:]]*:[[:space:]]*"/":"/g' \
    | tr '{' '\n' \
    | grep -F "\"name\":\"$1\"" \
    | head -n 1 \
    | sed -E 's#.*/releases/assets/([0-9]+)".*#\1#'
}

fetch_asset() { # asset-name dest
  _name="$1"; _dest="$2"
  _id="$(asset_id_for "$_name")"
  [ -n "$_id" ] || die "release ${VERSION} has no asset named ${_name} (does it build for ${TARGET}?)"
  # --location is required: the API answers with a redirect to storage, and the
  # Authorization header is deliberately not resent to that host by curl.
  if [ -n "${GH_TOKEN:-}" ]; then
    curl -fsSL -H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/octet-stream" \
      -o "$_dest" "https://api.github.com/repos/${REPO}/releases/assets/${_id}"
  else
    curl -fsSL -H "Accept: application/octet-stream" \
      -o "$_dest" "https://api.github.com/repos/${REPO}/releases/assets/${_id}"
  fi
}

log "installing dkod-signals ${VERSION} for ${TARGET}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

fetch_asset "$ASSET" "${WORKDIR}/${ASSET}" \
  || die "could not download ${ASSET}"
fetch_asset "SHA256SUMS" "${WORKDIR}/SHA256SUMS" \
  || die "could not download SHA256SUMS"

# --- verify checksum ---------------------------------------------------------
cd "$WORKDIR"
EXPECTED="$(grep " ${ASSET}\$" SHA256SUMS | awk '{print $1}')"
[ -n "$EXPECTED" ] || die "no checksum entry for ${ASSET} in SHA256SUMS"

if command -v sha256sum >/dev/null 2>&1; then
  ACTUAL="$(sha256sum "$ASSET" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  ACTUAL="$(shasum -a 256 "$ASSET" | awk '{print $1}')"
else
  die "neither sha256sum nor shasum is available to verify the download"
fi

[ "$EXPECTED" = "$ACTUAL" ] || die "checksum mismatch for ${ASSET} (expected ${EXPECTED}, got ${ACTUAL})"
log "checksum verified"

# --- install -------------------------------------------------------------
tar -xzf "$ASSET"
EXTRACTED_DIR="dkod-signals-${VERSION_NUM}-${TARGET}"
[ -f "${EXTRACTED_DIR}/${BIN_NAME}" ] || die "expected binary not found in ${ASSET}"

BIN_DIR="${PREFIX}/bin"
mkdir -p "$BIN_DIR" 2>/dev/null || {
  log "cannot write to ${BIN_DIR}; retrying with sudo"
  need sudo
  sudo mkdir -p "$BIN_DIR"
}

if [ -w "$BIN_DIR" ]; then
  install -m 0755 "${EXTRACTED_DIR}/${BIN_NAME}" "${BIN_DIR}/${BIN_NAME}"
else
  need sudo
  sudo install -m 0755 "${EXTRACTED_DIR}/${BIN_NAME}" "${BIN_DIR}/${BIN_NAME}"
fi

log "installed ${BIN_DIR}/${BIN_NAME}"
