#!/usr/bin/env bash
# Detects the Linux distro and installs a C/C++ toolchain (gcc/g++, make, cmake, gdb)
# using the native package manager.
# Supported: Ubuntu, Debian (and Mint/Pop/etc.), Fedora, Rocky/Alma/RHEL/CentOS,
#            Arch (and derivatives such as Manjaro/EndeavourOS)
#
# Usage:
#   ./install-cpp.sh            # gcc, g++, make, cmake, gdb
#   ./install-cpp.sh --clang    # also install clang (and clang tools)
#   ./install-cpp.sh --minimal  # compiler + make only (no cmake/gdb)
#
# Run as a normal user (not with sudo). The script calls sudo only for the
# package manager. Running as root works too.
set -euo pipefail

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

CLANG=0
MINIMAL=0

# Echoes: apt | dnf | pacman
detect_pm() {
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release; unsupported system."
  # shellcheck disable=SC1091
  . /etc/os-release
  local ids=" ${ID:-} ${ID_LIKE:-} "
  case "$ids" in
    *" ubuntu "*|*" debian "*)                          echo apt ;;
    *" fedora "*|*" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*) echo dnf ;;
    *" arch "*)                                         echo pacman ;;
    *) die "Unsupported distro: ${PRETTY_NAME:-unknown}" ;;
  esac
}

# Sets SUDO to "" (root) or "sudo".
setup_sudo() {
  if [[ $EUID -eq 0 ]]; then
    SUDO=""
  else
    command -v sudo >/dev/null 2>&1 || die "Not root and sudo not found."
    SUDO="sudo"
  fi
}

install_cpp() {
  local pm pkgs=()
  pm="$(detect_pm)"
  setup_sudo

  case "$pm" in
    apt)
      pkgs=(build-essential)                       # gcc, g++, make, libc-dev
      (( MINIMAL )) || pkgs+=(cmake gdb)
      (( CLANG ))   && pkgs+=(clang)
      log "Package manager: apt | Installing: ${pkgs[*]}"
      # Minimal Debian/containers may lack this dir and break some post-installs.
      $SUDO mkdir -p /usr/share/man/man1
      $SUDO dpkg --configure -a || true
      $SUDO apt-get update -y
      if ! $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"; then
        warn "Install failed; attempting repair..."
        $SUDO dpkg --configure -a || true
        $SUDO env DEBIAN_FRONTEND=noninteractive apt-get -f install -y
        $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" \
          || die "Could not install ${pkgs[*]}. Run 'sudo dpkg --configure -a' and read the FIRST error."
      fi ;;
    dnf)
      pkgs=(gcc gcc-c++ make)
      (( MINIMAL )) || pkgs+=(cmake gdb)
      (( CLANG ))   && pkgs+=(clang)
      log "Package manager: dnf | Installing: ${pkgs[*]}"
      $SUDO dnf install -y "${pkgs[@]}" || die "dnf install failed." ;;
    pacman)
      pkgs=(gcc make)                              # gcc includes g++ on Arch
      (( MINIMAL )) || pkgs+=(cmake gdb)
      (( CLANG ))   && pkgs+=(clang)
      log "Package manager: pacman | Installing: ${pkgs[*]}"
      $SUDO pacman -Sy --needed --noconfirm "${pkgs[@]}" || die "pacman install failed." ;;
  esac

  ok "Installed: ${pkgs[*]}"
  local tool
  for tool in gcc g++ make cmake gdb clang; do
    if command -v "$tool" >/dev/null 2>&1; then
      printf '    %-6s %s\n' "$tool" "$("$tool" --version 2>&1 | head -n1)"
    fi
  done
}

for arg in "$@"; do
  case "$arg" in
    -h|--help)  usage; exit 0 ;;
    --clang)    CLANG=1 ;;
    --minimal)  MINIMAL=1 ;;
    *) die "Unknown argument: $arg (see --help)" ;;
  esac
done

install_cpp
