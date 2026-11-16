#!/usr/bin/env bash
#
# install-brew-linux.sh
# Install Homebrew on Linux (Linuxbrew) on most major distributions.
# Docs: https://docs.brew.sh/Homebrew-on-Linux
#
# Supported package managers for prerequisites:
#   apt     Debian, Ubuntu, Mint, Pop!_OS, Kali, Raspberry Pi OS ...
#   dnf/yum Fedora, RHEL, CentOS Stream, Rocky, AlmaLinux, Oracle Linux, Amazon Linux
#   pacman  Arch, Manjaro, EndeavourOS ...
#   zypper  openSUSE, SLES
#
# Usage:  ./install-brew-linux.sh        (run as a NORMAL user with sudo access)

set -euo pipefail

BREW_PREFIX="/home/linuxbrew/.linuxbrew"
BREW_BIN="${BREW_PREFIX}/bin/brew"
INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mWarning:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- sanity checks
[ "$(uname -s)" = "Linux" ] || die "This script is for Linux only."

if [ "$(id -u)" -eq 0 ]; then
  die "Homebrew refuses to install as root. Run this script as a normal user with sudo access."
fi

case "$(uname -m)" in
  x86_64|aarch64|arm64) ;;
  armv7*|armv6*) warn "ARM32 is Tier 3 (no bottles, you may need your own Ruby)." ;;
  i?86) die "32-bit x86 is not supported by Homebrew." ;;
  *) warn "Unrecognised architecture $(uname -m); continuing anyway." ;;
esac

if grep -qi microsoft /proc/version 2>/dev/null && [ -z "${WSL_INTEROP:-}" ] && [ -z "${WSL_DISTRO_NAME:-}" ]; then
  warn "Looks like WSL 1 (Tier 3 support). WSL 2 is recommended."
fi

SUDO=""
if command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  die "sudo is required to install prerequisites. Install sudo first (as root) and retry."
fi

# ---------------------------------------------------------------- already installed?
if [ -x "$BREW_BIN" ] || command -v brew >/dev/null 2>&1; then
  info "Homebrew is already installed: $(command -v brew || echo "$BREW_BIN")"
  ALREADY_INSTALLED=1
else
  ALREADY_INSTALLED=0
fi

# ---------------------------------------------------------------- detect distro
ID=""; ID_LIKE=""; PRETTY_NAME="Linux"
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
fi
DISTRO_STRING=" ${ID:-} ${ID_LIKE:-} "
info "Detected: ${PRETTY_NAME}"

has_word() { case "$DISTRO_STRING" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

PM=""
if   has_word alpine; then
  die "Alpine (musl libc) is not supported by Homebrew on Linux."
elif has_word debian || has_word ubuntu; then PM="apt"
elif has_word fedora; then PM="dnf-fedora"
elif has_word rhel || has_word centos || has_word rocky || has_word almalinux || has_word ol || has_word amzn; then PM="dnf-rhel"
elif has_word arch || has_word manjaro; then PM="pacman"
elif has_word suse || has_word opensuse || has_word sles; then PM="zypper"
else
  # Fallback: detect by available package manager
  if   command -v apt-get >/dev/null 2>&1; then PM="apt"
  elif command -v dnf     >/dev/null 2>&1; then PM="dnf-rhel"
  elif command -v yum     >/dev/null 2>&1; then PM="yum-rhel"
  elif command -v pacman  >/dev/null 2>&1; then PM="pacman"
  elif command -v zypper  >/dev/null 2>&1; then PM="zypper"
  else die "Could not determine your package manager. Install build tools, curl, file, git and procps manually, then run the Homebrew installer."
  fi
fi

# RHEL-likes with only yum (CentOS 7 era)
if [ "$PM" = "dnf-rhel" ] && ! command -v dnf >/dev/null 2>&1; then
  PM="yum-rhel"
fi

# ---------------------------------------------------------------- install prerequisites
if [ "$ALREADY_INSTALLED" -eq 0 ]; then
  info "Installing prerequisites using: ${PM}"
  case "$PM" in
    apt)
      $SUDO apt-get update
      $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        build-essential procps curl file git
      ;;
    dnf-fedora)
      $SUDO dnf group install -y development-tools
      $SUDO dnf install -y procps-ng curl file git
      ;;
    dnf-rhel)
      $SUDO dnf group install -y 'Development Tools'
      # curl may conflict with curl-minimal on some images, so don't force it
      $SUDO dnf install -y procps-ng file git
      command -v curl >/dev/null 2>&1 || $SUDO dnf install -y curl
      ;;
    yum-rhel)
      $SUDO yum groupinstall -y 'Development Tools'
      $SUDO yum install -y procps-ng curl file git
      ;;
    pacman)
      $SUDO pacman -Sy --needed --noconfirm base-devel procps-ng curl file git
      ;;
    zypper)
      $SUDO zypper --non-interactive install -t pattern devel_basis
      $SUDO zypper --non-interactive install procps curl file git
      ;;
  esac

  # ------------------------------------------------------------- install Homebrew
  info "Running the official Homebrew installer..."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL "$INSTALL_URL")"
fi

[ -x "$BREW_BIN" ] || die "Homebrew not found at ${BREW_BIN} after install."

# ---------------------------------------------------------------- shell configuration
SHELLENV_BASH="eval \"\$(${BREW_BIN} shellenv)\""
SHELLENV_FISH="eval (${BREW_BIN} shellenv)"

add_line() {  # add_line <file> <line>
  local file="$1" line="$2"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  if ! grep -qsF "$line" "$file"; then
    printf '\n# Homebrew\n%s\n' "$line" >> "$file"
    info "Added Homebrew to ${file}"
  fi
}

LOGIN_SHELL="$(basename "${SHELL:-/bin/bash}")"
case "$LOGIN_SHELL" in
  zsh)  add_line "$HOME/.zshrc" "$SHELLENV_BASH" ;;
  fish) add_line "$HOME/.config/fish/config.fish" "$SHELLENV_FISH" ;;
  *)    add_line "$HOME/.bashrc" "$SHELLENV_BASH" ;;
esac

# Make brew available to the rest of this script / current session
eval "$("$BREW_BIN" shellenv)"

# ---------------------------------------------------------------- verify
info "Installed: $(brew --version | head -n1)"
info "Verifying with 'brew doctor' (warnings are not necessarily fatal)..."
brew doctor || true

cat <<EOF

Done! Open a new terminal, or run:

    eval "\$(${BREW_BIN} shellenv)"

Then try:

    brew install hello

EOF
