#!/usr/bin/env bash
# Detects the Linux distro, installs build prerequisites, then installs Rust
# via the official rustup installer (to ~/.cargo and ~/.rustup).
# Supported: Ubuntu, Debian, Fedora, Rocky/Alma/RHEL/CentOS, Arch (and derivatives)
#
# Usage:
#   ./install-rust.sh               # interactive: pick stable/beta/nightly or a version
#   ./install-rust.sh stable        # non-interactive: stable | beta | nightly
#   ./install-rust.sh 1.80.0        # non-interactive: a specific version
#   ./install-rust.sh --minimal     # use the minimal profile (rustc, cargo, rust-std only)
#
# Run as a normal user (not with sudo). The script calls sudo only to install
# system packages (curl, a C compiler/linker). Running as root installs Rust
# for root only.
#
# Env:
#   CARGO_HOME=$HOME/.cargo         # where cargo and binaries live
#   RUSTUP_HOME=$HOME/.rustup       # where toolchains live

set -euo pipefail

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

DIST_BASE="https://static.rust-lang.org/rustup/dist"
PROFILE="default"
TOOLCHAIN=""

for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --minimal) PROFILE="minimal" ;;
    -*)        usage; die "Unknown option: $arg" ;;
    *)         TOOLCHAIN="$arg" ;;
  esac
done

# ------------------------------------------------------------------ root ----
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  fi
else
  warn "Running as root: Rust will be installed for root only (${HOME})."
fi

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
  command -v cc   >/dev/null 2>&1 || {
    case "$PKG" in
      apt)    missing+=(build-essential) ;;
      dnf)    missing+=(gcc) ;;
      pacman) missing+=(base-devel) ;;
    esac
  }
  command -v sha256sum >/dev/null 2>&1 || missing+=(coreutils)
  [ "${#missing[@]}" -eq 0 ] && return 0

  if [ -z "$SUDO" ] && [ "$(id -u)" -ne 0 ]; then
    die "Missing packages (${missing[*]}) and sudo is not available. Install them as root and re-run."
  fi

  log "Installing missing dependencies: ${missing[*]}"
  case "$PKG" in
    apt)    $SUDO apt-get update -qq && $SUDO apt-get install -y -qq "${missing[@]}" ;;
    dnf)    $SUDO dnf install -y -q "${missing[@]}" ;;
    pacman) $SUDO pacman -Sy --noconfirm --needed "${missing[@]}" ;;
  esac
}

# ------------------------------------------------------------------ arch ----
detect_target() {
  case "$(uname -m)" in
    x86_64|amd64)   TARGET="x86_64-unknown-linux-gnu" ;;
    aarch64|arm64)  TARGET="aarch64-unknown-linux-gnu" ;;
    armv7l)         TARGET="armv7-unknown-linux-gnueabihf" ;;
    i386|i686)      TARGET="i686-unknown-linux-gnu" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

# ------------------------------------------------------------- toolchain ----
pick_toolchain() {
  echo
  echo "  1) stable   (recommended)"
  echo "  2) beta"
  echo "  3) nightly"
  echo
  local choice
  read -r -p "Pick a number (1-3) or type a version like 1.80.0 [1]: " choice </dev/tty
  choice="${choice:-1}"
  case "$choice" in
    1) TOOLCHAIN="stable" ;;
    2) TOOLCHAIN="beta" ;;
    3) TOOLCHAIN="nightly" ;;
    *) TOOLCHAIN="$choice" ;;
  esac
}

validate_toolchain() {
  case "$TOOLCHAIN" in
    stable|beta|nightly) ;;
    [0-9]*.[0-9]*|[0-9]*.[0-9]*.[0-9]*) ;;
    *) die "Invalid toolchain: '$TOOLCHAIN' (use stable, beta, nightly or e.g. 1.80.0)" ;;
  esac
}

# --------------------------------------------------------------- install ----
install_rust() {
  local url="${DIST_BASE}/${TARGET}/rustup-init"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  log "Downloading rustup-init (${TARGET})"
  curl -fL --progress-bar -o "${tmp}/rustup-init" "$url" \
    || die "Download failed: $url"

  log "Verifying SHA256 checksum"
  local expected actual
  expected="$(curl -fsSL "${url}.sha256" | awk '{print $1}')" \
    || die "Could not fetch checksum"
  actual="$(sha256sum "${tmp}/rustup-init" | awk '{print $1}')"
  [ "$expected" = "$actual" ] || die "Checksum mismatch! expected=$expected actual=$actual"
  ok "Checksum OK"
  chmod +x "${tmp}/rustup-init"

  log "Installing Rust (${TOOLCHAIN}, profile: ${PROFILE}) to ${CARGO_HOME:-$HOME/.cargo}"
  "${tmp}/rustup-init" -y --default-toolchain "$TOOLCHAIN" --profile "$PROFILE"

  # Apply PATH inside this script so the version checks below work
  # shellcheck disable=SC1091
  source "${CARGO_HOME:-$HOME/.cargo}/env"

  ok "$(rustc --version)"
  ok "$(cargo --version)"
  echo
  log "PATH is set via ${CARGO_HOME:-$HOME/.cargo}/env (rustup also edits your shell profile)."
  warn "Your current terminal is not updated (a script can't change its parent shell)."
  warn "Run now:  source \"${CARGO_HOME:-\$HOME/.cargo}/env\"   (or open a new shell)"
}

# ------------------------------------------------------------------ main ----
main() {
  detect_distro
  install_deps
  detect_target

  if [ -z "$TOOLCHAIN" ]; then
    pick_toolchain
  fi
  validate_toolchain

  if command -v rustup >/dev/null 2>&1; then
    warn "rustup is already installed. To update instead, run: rustup update"
    read -r -p "Reinstall anyway? [y/N]: " yn </dev/tty
    [[ "$yn" =~ ^[Yy]$ ]] || exit 0
  fi

  install_rust
}

main
