#!/usr/bin/env bash
# Detects the Linux distro, lists the 10 latest stable Go releases from go.dev,
# lets you pick one (or type any version), then installs it to /usr/local/go.
# Supported: Ubuntu, Debian, Fedora, Rocky/Alma/RHEL/CentOS, Arch (and derivatives)
#
# Usage:
#   sudo ./install-go.sh          # interactive: pick from the list or type a version
#   sudo ./install-go.sh 1.23.4   # non-interactive: install a specific version
#   ./install-go.sh --list        # just show the 10 latest stable versions
#
# Env:
#   INSTALL_DIR=/usr/local        # Go ends up in $INSTALL_DIR/go
set -euo pipefail

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

INSTALL_DIR="${INSTALL_DIR:-/usr/local}"
API_URL="https://go.dev/dl/?mode=json&include=all"
DL_BASE="https://go.dev/dl"
PROFILE_SCRIPT="/etc/profile.d/golang.sh"
REQUESTED=""
LIST_ONLY=0

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --list)    LIST_ONLY=1 ;;
    -*)        usage; die "Unknown option: $arg" ;;
    *)         REQUESTED="$arg" ;;
  esac
done

# ---------------------------------------------------------------- distro ----
PKG=""
detect_distro() {
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  local ids="${ID:-} ${ID_LIKE:-}"
  case " $ids " in
    *" ubuntu "*|*" debian "*)                         PKG="apt" ;;
    *" fedora "*)                                      PKG="dnf" ;;
    *" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*) PKG="dnf" ;;
    *" arch "*)                                        PKG="pacman" ;;
    *) die "Unsupported distro: ${PRETTY_NAME:-unknown}" ;;
  esac
  log "Detected distro: ${PRETTY_NAME:-$ID} (package manager: $PKG)"
}

SUDO=""
setup_root() {
  if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "Run as root (or install sudo)."
    SUDO="sudo"
  fi
}

install_deps() {
  local missing=()
  for c in curl tar jq sha256sum; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0

  log "Installing missing tools: ${missing[*]}"
  # sha256sum comes from coreutils
  local pkgs=()
  for c in "${missing[@]}"; do
    [[ "$c" == "sha256sum" ]] && pkgs+=("coreutils") || pkgs+=("$c")
  done
  case "$PKG" in
    apt)    $SUDO apt-get update -qq && $SUDO apt-get install -y -qq "${pkgs[@]}" ;;
    dnf)    $SUDO dnf install -y -q "${pkgs[@]}" ;;
    pacman) $SUDO pacman -Sy --noconfirm --needed "${pkgs[@]}" ;;
  esac
}

# ------------------------------------------------------------------ arch ----
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  GOARCH="amd64" ;;
    aarch64|arm64) GOARCH="arm64" ;;
    armv6l|armv7l) GOARCH="armv6l" ;;
    i386|i686)     GOARCH="386" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

# ------------------------------------------------------------------ main ----
detect_distro
[[ $LIST_ONLY -eq 1 ]] || setup_root
install_deps
detect_arch

log "Fetching the 10 latest stable Go releases from go.dev ..."
RELEASES_JSON="$(curl -fsSL "$API_URL")" || die "Could not fetch $API_URL"
echo "$RELEASES_JSON" | jq -e . >/dev/null 2>&1 || die "go.dev did not return valid JSON"

mapfile -t VERSIONS < <(echo "$RELEASES_JSON" \
  | jq -r '[.[] | select(.stable == true)] | .[0:10][] | .version')
[[ ${#VERSIONS[@]} -gt 0 ]] || die "No stable releases found"

echo
for i in "${!VERSIONS[@]}"; do
  printf '  %2d) %s\n' "$((i + 1))" "${VERSIONS[$i]}"
done
echo

if [[ $LIST_ONLY -eq 1 ]]; then
  exit 0
fi

# Pick the version
if [[ -z "$REQUESTED" ]]; then
  read -r -p "Pick a number (1-${#VERSIONS[@]}) or type a version [1]: " CHOICE
  CHOICE="${CHOICE:-1}"
else
  CHOICE="$REQUESTED"
fi

if [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= ${#VERSIONS[@]} )); then
  VERSION="${VERSIONS[$((CHOICE - 1))]}"
else
  VERSION="go${CHOICE#go}"
fi

FILENAME="${VERSION}.linux-${GOARCH}.tar.gz"
log "Selected: ${VERSION} (linux/${GOARCH})"

# Expected checksum comes from the JSON API (the .sha256 URL now returns HTML)
EXPECTED_SHA="$(echo "$RELEASES_JSON" | jq -r --arg v "$VERSION" --arg f "$FILENAME" \
  '.[] | select(.version == $v) | .files[] | select(.filename == $f) | .sha256' | head -n1)"
[[ "$EXPECTED_SHA" =~ ^[0-9a-f]{64}$ ]] \
  || die "Could not find a valid checksum for $FILENAME (does that version exist for linux/${GOARCH}?)"

# Download
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
log "Downloading $FILENAME"
curl -fL --progress-bar -o "$TMP_DIR/$FILENAME" "$DL_BASE/$FILENAME" \
  || die "Download failed: $DL_BASE/$FILENAME"

# Verify
log "Verifying SHA256 checksum"
ACTUAL_SHA="$(sha256sum "$TMP_DIR/$FILENAME" | awk '{print $1}')"
if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
  die "Checksum mismatch! expected=$EXPECTED_SHA actual=$ACTUAL_SHA"
fi
ok "Checksum OK"

# Install
log "Installing to $INSTALL_DIR/go"
$SUDO mkdir -p "$INSTALL_DIR"
$SUDO rm -rf "$INSTALL_DIR/go"
$SUDO tar -C "$INSTALL_DIR" -xzf "$TMP_DIR/$FILENAME"

# PATH setup for login shells
log "Writing $PROFILE_SCRIPT"
$SUDO tee "$PROFILE_SCRIPT" >/dev/null <<EOF
export PATH=\$PATH:$INSTALL_DIR/go/bin
EOF
$SUDO chmod 644 "$PROFILE_SCRIPT"

export PATH="$PATH:$INSTALL_DIR/go/bin"
ok "Installed: $("$INSTALL_DIR/go/bin/go" version)"
warn "Run 'source $PROFILE_SCRIPT' or open a new shell to get 'go' on your PATH."
