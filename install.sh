#!/usr/bin/env sh
# install.sh — download and install the dkod-signals release binary.
#
# What this does: detects OS/arch, downloads the matching release asset and
# SHA256SUMS from GitHub Releases, verifies the checksum, and installs the
# binary to /usr/local/bin (or $PREFIX/bin). Nothing is uploaded — this
# script only ever talks to GitHub's release API/CDN to fetch the binary
# itself; it never runs dkod-signals and never sends anything anywhere.
#
# WHAT VERIFIES WHAT, AND WHERE IT STOPS:
#
#   install.sh verifies the binary it downloads. Nothing verifies install.sh
#   itself when you fetch it from a branch. The MDM snippets pin it to a fixed
#   version and check it before running.
#
# THE SENTENCE ABOVE NAMES WHICH FETCH, and that is the whole of it. This file is
# piped to a root shell on every managed device, so a sentence saying "verified
# installer" without naming the fetch would be worse than the unverified fetch
# itself: it stops people looking.
#
# ADDING install.sh TO SHA256SUMS DOES NOT CHANGE THIS. That gives an admin one
# canonical number to compare out of band, and lets a re-install verify a script
# it already has - but the script and the checksums come from the same release,
# written by the same writer. It is not coverage of the fetch that runs as root.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/dkod-ai/dkod-signals-releases/main/install.sh | sh
#   curl -fsSL .../install.sh | VERSION=v0.1.0 PREFIX=/opt/dkod sh
#
# Env vars:
#   VERSION   Release tag to install, e.g. v0.1.0 [default: latest]
#   PREFIX    Install prefix; binary goes to $PREFIX/bin [default: /usr/local]
#   GH_TOKEN  GitHub token, sent as an Authorization header if set. NOT NEEDED:
#             the releases repo is public, so every request this script makes
#             succeeds without one. Kept for a mirror behind an access-controlled
#             proxy, set through DKOD_RELEASES_REPO.

set -eu

# THE PUBLIC RELEASES REPO BY DEFAULT, AND THIS FILE IS BYTE-IDENTICAL IN BOTH REPOS BECAUSE OF IT.
# The copy customers actually run is served from dkod-ai/dkod-signals-releases; if the two copies
# differed, the drift check would need a transform, and a transform is a thing to get subtly wrong
# on the one file that runs as root. So the two differences that used to exist - this line and the
# usage URL above - were removed rather than transformed, and the check is a plain `diff`.
REPO="${DKOD_RELEASES_REPO:-dkod-ai/dkod-signals-releases}"
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
# every asset's API id, which is what `asset_id_for` needs - the API asset
# endpoint takes an id, not a name.
#
# THE OLD WORDING IS NOT REPEATED HERE. It gave an access-control reason and
# named `fetch_asset` as its authority - while that function's own comment now
# refutes it. A correction that quotes the sentence it removes matches itself
# forever, so the grep that should prove the claim is gone can never reach zero.
if [ -n "${VERSION:-}" ]; then
  RELEASE_JSON="$(curl_auth "https://api.github.com/repos/${REPO}/releases/tags/${VERSION}")" \
    || die "could not find release ${VERSION}"
else
  log "resolving latest release..."
  RELEASE_JSON="$(curl_auth "https://api.github.com/repos/${REPO}/releases/latest")" \
    || die "could not reach the GitHub API for ${REPO}. Check network access to api.github.com; if you set DKOD_RELEASES_REPO to somewhere that needs credentials, export GH_TOKEN too"
  VERSION="$(printf '%s' "$RELEASE_JSON" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
  [ -n "$VERSION" ] || die "could not resolve the latest release tag"
fi

VERSION_NUM="${VERSION#v}"
ASSET="dkod-signals-${VERSION_NUM}-${TARGET}.tar.gz"

# --- downloading one asset ----------------------------------------------------
# THE API ASSET ENDPOINT, USED UNCONDITIONALLY - and the reason is no longer the
# one this comment used to give. That reason was about access control on the
# source repository, and it stopped being true when the releases repo became
# public. It is not restated here: a correction carrying the claim it removes
# is a claim that survives every grep written to find it.
#
# THE PATH STAYS ANYWAY, and the surviving reason is the better one: one code
# path exercised on every install beats two, one of which nobody runs. It also
# still works if DKOD_RELEASES_REPO ever points somewhere that needs a token.
#
# It needs the asset's numeric id rather than its name, which is what the
# lookup below is for.
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
