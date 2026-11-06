#!/usr/bin/env bash
# Universal k6 installer for Linux
# Supports: Debian/Ubuntu (+Mint, Pop, Kali...), Fedora/RHEL/Rocky/Alma/CentOS (dnf/yum),
#           Arch/Manjaro/EndeavourOS, Alpine, openSUSE, and a generic binary fallback.
# Usage:  chmod +x install-k6.sh && ./install-k6.sh
#         FORCE_BINARY=1 ./install-k6.sh   # skip package managers, install the release tarball

set -euo pipefail

log()  { printf '\033[1;34m[k6]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[k6]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[k6]\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---- privilege handling ------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif have sudo; then
  SUDO="sudo"
elif have doas; then
  SUDO="doas"
else
  die "Need root privileges: run as root or install sudo/doas."
fi

# ---- already installed? ------------------------------------------------------
if have k6 && [ "${FORCE:-0}" != "1" ]; then
  log "k6 is already installed: $(k6 version 2>/dev/null | head -n1)"
  log "Set FORCE=1 to reinstall."
  exit 0
fi

# ---- detect distro -----------------------------------------------------------
ID=""; ID_LIKE=""
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
fi
DISTRO="${ID:-unknown} ${ID_LIKE:-}"

is_like() {
  for d in "$@"; do
    case " $DISTRO " in *" $d "*) return 0 ;; esac
  done
  return 1
}

fetch() { # fetch URL -> stdout
  if have curl; then curl -fsSL "$1"
  elif have wget; then wget -qO- "$1"
  else die "curl or wget is required."
  fi
}

# ---- installers --------------------------------------------------------------
install_deb() {
  log "Using APT (Debian/Ubuntu family)"
  $SUDO apt-get update -y
  $SUDO apt-get install -y ca-certificates gnupg curl
  $SUDO mkdir -p /usr/share/keyrings
  fetch https://dl.k6.io/key.gpg | $SUDO gpg --batch --yes --dearmor \
    -o /usr/share/keyrings/k6-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
    | $SUDO tee /etc/apt/sources.list.d/k6.list >/dev/null
  $SUDO apt-get update -y
  $SUDO apt-get install -y k6
}

install_rpm() {
  log "Using DNF/YUM (RHEL/Fedora/Rocky/Alma/CentOS family)"
  local pm="dnf"
  have dnf || pm="yum"
  $SUDO "$pm" install -y https://dl.k6.io/rpm/repo.rpm
  $SUDO "$pm" install -y k6
}

install_arch() {
  log "Using pacman (Arch family)"
  $SUDO pacman -Sy --noconfirm k6
}

install_alpine() {
  log "Using apk (Alpine)"
  $SUDO apk add --no-cache k6
}

install_suse() {
  log "openSUSE: no official k6 repo, using the RPM repo via zypper"
  $SUDO zypper --non-interactive --gpg-auto-import-keys install https://dl.k6.io/rpm/repo.rpm || true
  $SUDO zypper --non-interactive install k6 || return 1
}

install_binary() {
  log "Installing from the official GitHub release tarball"
  have tar || die "tar is required."

  local arch
  case "$(uname -m)" in
    x86_64|amd64)  arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac

  local tag
  if have curl; then
    tag="$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/grafana/k6/releases/latest | sed 's#.*/##')"
  else
    tag="$(wget -qO- --max-redirect=0 https://github.com/grafana/k6/releases/latest 2>&1 | sed -n 's#.*/tag/\(v[0-9.]*\).*#\1#p' | head -n1)"
  fi
  [ -n "$tag" ] || die "Could not determine the latest k6 version."

  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  local url="https://github.com/grafana/k6/releases/download/${tag}/k6-${tag}-linux-${arch}.tar.gz"
  log "Downloading ${url}"
  fetch "$url" > "$tmp/k6.tar.gz"
  tar -xzf "$tmp/k6.tar.gz" -C "$tmp"
  $SUDO install -m 0755 "$tmp"/k6-*/k6 /usr/local/bin/k6
}

# ---- main --------------------------------------------------------------------
if [ "${FORCE_BINARY:-0}" = "1" ]; then
  install_binary
elif is_like debian ubuntu; then
  install_deb
elif is_like fedora rhel centos rocky almalinux ol amzn; then
  install_rpm
elif is_like arch archlinux manjaro endeavouros; then
  install_arch
elif is_like alpine; then
  install_alpine
elif is_like suse opensuse opensuse-leap opensuse-tumbleweed sles; then
  install_suse || { warn "zypper install failed, falling back to binary."; install_binary; }
else
  warn "Unknown distro (${DISTRO}), falling back to binary install."
  install_binary
fi

if have k6; then
  log "Success: $(k6 version | head -n1)"
else
  die "Installation finished but 'k6' is not in PATH."
fi
