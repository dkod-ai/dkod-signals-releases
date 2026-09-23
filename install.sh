#!/usr/bin/env sh
# install.sh — download and install the dkod-signals release binary.
#
# What this does: detects OS/arch, downloads the matching release asset and
# SHA256SUMS from GitHub Releases by name, verifies the checksum, and installs the
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
# Only the TAG is read from the API, and only when VERSION is not given. The
# asset list is not trusted for a public download: on v0.1.74 GitHub served a
# by-tag view and a releases list that both showed ZERO assets for a release
# whose files were all there and downloadable (DKO-559), and every install that
# read the list failed. A public install therefore downloads by name from the
# release download URL and trusts SHA256SUMS, which it verifies below.
if [ -z "${VERSION:-}" ]; then
  log "resolving latest release..."
  LATEST_JSON="$(curl_auth "https://api.github.com/repos/${REPO}/releases/latest")" \
    || die "could not reach the GitHub API for ${REPO}. Check network access to api.github.com; if you set DKOD_RELEASES_REPO to somewhere that needs credentials, export GH_TOKEN too"
  VERSION="$(printf '%s' "$LATEST_JSON" | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
  [ -n "$VERSION" ] || die "could not resolve the latest release tag"
fi

# The tag goes into a URL path, so it is held to the shape of a tag.
case "$VERSION" in
  "" | .* | *[!A-Za-z0-9._-]*) die "unsupported release tag: ${VERSION}" ;;
esac

VERSION_NUM="${VERSION#v}"
ASSET="dkod-signals-${VERSION_NUM}-${TARGET}.tar.gz"

# --- downloading one asset ----------------------------------------------------
# WITHOUT GH_TOKEN (every customer install; the releases repo is public): the
# release download URL, by name. It needs no asset id, so it never reads the
# asset list that went stale on v0.1.74.
#
# WITH GH_TOKEN (a mirror behind an access-controlled proxy, set through
# DKOD_RELEASES_REPO): the API asset endpoint, which is the one that honours a
# token. It needs the asset's numeric id. The release's own `assets` array is
# read first, and when it lacks the asset the release's assets endpoint
# (`assets_url`, /releases/{id}/assets) is asked instead, because that endpoint
# stayed correct while the by-tag view did not.
RELEASE_JSON=""
ASSETS_JSON=""

load_release() {
  [ -n "$RELEASE_JSON" ] && return 0
  RELEASE_JSON="$(curl_auth "https://api.github.com/repos/${REPO}/releases/tags/${VERSION}")" \
    || die "could not find release ${VERSION}"
}

asset_id_in() { # json asset-name
  # Flattens the payload, normalises "key": "value" to "key":"value" so the
  # match does not depend on the API's pretty-printing, splits on "{" so each
  # asset object is one line, and reads the id out of that object's own API URL.
  # Matching the /releases/assets/<id> URL rather than a bare "id" field is what
  # stops this picking up the release id, the uploader id, or any other number.
  printf '%s' "$1" \
    | tr -d '\n' \
    | sed 's/"[[:space:]]*:[[:space:]]*"/":"/g' \
    | tr '{' '\n' \
    | grep -F "\"name\":\"$2\"" \
    | head -n 1 \
    | sed -E 's#.*/releases/assets/([0-9]+)".*#\1#'
}

asset_id_for() { # asset-name
  load_release
  _found="$(asset_id_in "$RELEASE_JSON" "$1")"
  if [ -z "$_found" ]; then
    if [ -z "$ASSETS_JSON" ]; then
      _assets_url="$(printf '%s' "$RELEASE_JSON" | tr -d '\n' \
        | sed 's/"[[:space:]]*:[[:space:]]*"/":"/g' \
        | grep -o '"assets_url":"https://api.github.com/[^"]*/releases/[0-9]*/assets"' \
        | head -n 1 | sed -E 's/^"assets_url":"(.*)"$/\1/')" || true
      [ -n "$_assets_url" ] || return 0
      ASSETS_JSON="$(curl_auth "${_assets_url}?per_page=100")" || return 0
    fi
    _found="$(asset_id_in "$ASSETS_JSON" "$1")"
  fi
  printf '%s' "$_found"
}

fetch_asset() { # asset-name dest
  _name="$1"; _dest="$2"
  if [ -z "${GH_TOKEN:-}" ]; then
    curl -fsSL -o "$_dest" "https://github.com/${REPO}/releases/download/${VERSION}/${_name}" \
      || die "could not download ${_name} from release ${VERSION} (does it build for ${TARGET}?)"
    return 0
  fi
  _id="$(asset_id_for "$_name")"
  [ -n "$_id" ] || die "release ${VERSION} has no asset named ${_name} (does it build for ${TARGET}?)"
  # --location is required: the API answers with a redirect to storage, and the
  # Authorization header is deliberately not resent to that host by curl.
  curl -fsSL -H "Authorization: Bearer ${GH_TOKEN}" -H "Accept: application/octet-stream" \
    -o "$_dest" "https://api.github.com/repos/${REPO}/releases/assets/${_id}"
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
