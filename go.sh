#!/usr/bin/env bash
# Detects the Linux distro, lists the 10 latest stable Go releases from go.dev,
# lets you pick one (or type any version), then installs it to /usr/local/go.
# Supported: Ubuntu, Debian, Fedora, Rocky/Alma/RHEL/CentOS, Arch (and derivatives)
#
# Usage:
#   sudo ./install-go.sh            # interactive: pick from the list or type a version
#   sudo ./install-go.sh 1.23.4     # non-interactive: install a specific version
#   ./install-go.sh --list          # just show the 10 latest stable versions
#
# Env:
#   INSTALL_DIR=/usr/local          # Go ends up in $INSTALL_DIR/go

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
detect_distro() {
  [ -r /etc/os-release ] || die "Cannot detect distro: /etc/os-release not found"
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO_ID="${ID:-unknown}"
  DISTRO_LIKE="${ID_LIKE:-}"
  case "$DISTRO_ID $DISTRO_LIKE" in
    *ubuntu*|*debian*)                    PKG="apt" ;;
    *fedora*)                             PKG="dnf" ;;
    *rhel*|*centos*|*rocky*|*almalinux*)  PKG="dnf" ;;
    *arch*)                               PKG="pacman" ;;
    *) die "Unsupported distro: $DISTRO_ID" ;;
  esac
  log "Detected distro: ${PRETTY_NAME:-$DISTRO_ID} (package manager: $PKG)"
}

install_deps() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v tar  >/dev/null 2>&1 || missing+=(tar)
  command -v sha256sum >/dev/null 2>&1 || missing+=(coreutils)
  [ "${#missing[@]}" -eq 0 ] && return 0

  log "Installing missing dependencies: ${missing[*]}"
  case "$PKG" in
    apt)    apt-get update -qq && apt-get install -y -qq "${missing[@]}" ;;
    dnf)    dnf install -y -q "${missing[@]}" ;;
    pacman) pacman -Sy --noconfirm --needed "${missing[@]}" ;;
  esac
}

# ------------------------------------------------------------------ arch ----
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)   GOARCH="amd64" ;;
    aarch64|arm64)  GOARCH="arm64" ;;
    armv6l|armv7l)  GOARCH="armv6l" ;;
    i386|i686)      GOARCH="386" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

# -------------------------------------------------------------- versions ----
# Prints the 10 latest stable versions (without the "go" prefix), newest first.
latest_versions() {
  curl -fsSL "$API_URL" \
    | grep -oE '"version": *"go[0-9]+\.[0-9]+(\.[0-9]+)?"' \
    | sed -E 's/.*"go([^"]+)"/\1/' \
    | awk '!seen[$0]++' \
    | head -n 10
}

pick_version() {
  log "Fetching the 10 latest stable Go releases from go.dev ..."
  mapfile -t VERSIONS < <(latest_versions)
  [ "${#VERSIONS[@]}" -gt 0 ] || die "Could not fetch version list from go.dev"

  echo
  local i=1
  for v in "${VERSIONS[@]}"; do
    printf '  %2d) go%s\n' "$i" "$v"
    i=$((i + 1))
  done
  echo

  if [ "$LIST_ONLY" -eq 1 ]; then
    exit 0
  fi

  local choice
  read -r -p "Pick a number (1-${#VERSIONS[@]}) or type a version [1]: " choice </dev/tty
  choice="${choice:-1}"

  if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#VERSIONS[@]}" ]; then
    VERSION="${VERSIONS[$((choice - 1))]}"
  else
    VERSION="${choice#go}"
  fi
}

# --------------------------------------------------------------- install ----
install_go() {
  local file="go${VERSION}.linux-${GOARCH}.tar.gz"
  local url="${DL_BASE}/${file}"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  log "Downloading ${file}"
  curl -fL --progress-bar -o "${tmp}/${file}" "$url" \
    || die "Download failed: $url (does version ${VERSION} exist?)"

  log "Verifying SHA256 checksum"
  local expected actual
  expected="$(curl -fsSL "${url}.sha256" | tr -d '[:space:]')" \
    || die "Could not fetch checksum for ${file}"
  actual="$(sha256sum "${tmp}/${file}" | awk '{print $1}')"
  [ "$expected" = "$actual" ] || die "Checksum mismatch! expected=$expected actual=$actual"
  ok "Checksum OK"

  log "Installing to ${INSTALL_DIR}/go"
  rm -rf "${INSTALL_DIR}/go"
  mkdir -p "$INSTALL_DIR"
  tar -C "$INSTALL_DIR" -xzf "${tmp}/${file}"

  # Persist PATH for all login shells
  cat > "$PROFILE_SCRIPT" <<EOF
# Added by install-go.sh
case ":\$PATH:" in
  *":${INSTALL_DIR}/go/bin:"*) ;;
  *) export PATH="\$PATH:${INSTALL_DIR}/go/bin" ;;
esac
EOF
  chmod 644 "$PROFILE_SCRIPT"

  # Apply PATH inside this script so the version check below works
  # shellcheck disable=SC1091
  source "$PROFILE_SCRIPT"

  ok "$(go version)"
  echo
  log "PATH is set via ${PROFILE_SCRIPT}."
  warn "Your current terminal is not updated (a script can't change its parent shell)."
  warn "Run now:  source ${PROFILE_SCRIPT}   (or open a new login shell)"
}

# ------------------------------------------------------------------ main ----
main() {
  if [ "$LIST_ONLY" -eq 1 ]; then
    command -v curl >/dev/null 2>&1 || die "curl is required"
    pick_version
    exit 0
  fi

  [ "$(id -u)" -eq 0 ] || die "Run as root: sudo $0 ${REQUESTED}"

  detect_distro
  install_deps
  detect_arch

  if [ -n "$REQUESTED" ]; then
    VERSION="${REQUESTED#go}"
  else
    pick_version
  fi

  log "Selected: go${VERSION} (linux/${GOARCH})"
  install_go
}

main
