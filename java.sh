#!/usr/bin/env bash
# Detects the Linux distro and installs OpenJDK using the native package manager.
# Supported: Ubuntu, Debian (and Mint/Pop/etc.), Fedora, Rocky/Alma/RHEL/CentOS,
#            Arch (and derivatives such as Manjaro/EndeavourOS)
#
# Usage:
#   ./install-java.sh            # interactive: pick a version from a menu
#   ./install-java.sh 21         # non-interactive: 8 | 11 | 17 | 21 | 25 | latest
#   ./install-java.sh 17 --jre   # runtime only (headless JRE, no javac)
#
# Run as a normal user (not with sudo). The script calls sudo only for the
# package manager. Running as root works too.
#
# Env:
#   JAVA_DEFAULT=21     # version used when the menu is skipped / Enter is pressed
set -euo pipefail

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

JAVA_DEFAULT="${JAVA_DEFAULT:-21}"
VERSION=""
KIND="jdk"   # jdk | jre

# ---------- helpers ----------

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

# Echoes the package name for a given pm / version / kind.
pkg_name() {
  local pm="$1" v="$2" kind="$3"
  case "$pm" in
    apt)
      [[ "$v" == latest ]] && v=25
      if [[ $kind == jdk ]]; then echo "openjdk-${v}-jdk"
      else echo "openjdk-${v}-jre-headless"; fi ;;
    dnf)
      [[ "$v" == latest ]] && v=25
      [[ "$v" == 8 ]] && v="1.8.0"
      if [[ $kind == jdk ]]; then echo "java-${v}-openjdk-devel"
      else echo "java-${v}-openjdk-headless"; fi ;;
    pacman)
      local n="$v"; [[ "$v" == latest ]] && n=""
      if [[ $kind == jdk ]]; then echo "jdk${n}-openjdk"
      else echo "jre${n}-openjdk-headless"; fi ;;
  esac
}

# apt install that heals half-configured packages (e.g. openjdk-*-jre-headless
# failing in its post-install step) and retries once before giving up.
apt_install_with_repair() {
  local pkg="$1"
  local APT="$SUDO env DEBIAN_FRONTEND=noninteractive apt-get"

  # Fix leftovers from any earlier interrupted/failed install first.
  $SUDO dpkg --configure -a || true

  # ca-certificates is needed by ca-certificates-java, which the JRE's
  # post-install step runs; installing it first avoids a common failure.
  if $APT install -y ca-certificates "$pkg"; then
    return 0
  fi

  warn "Install failed; attempting repair (dpkg --configure -a, apt-get -f install)..."
  $SUDO dpkg --configure -a || true
  if $APT -f install -y && $APT install -y "$pkg"; then
    ok "Recovered after repair."
    return 0
  fi

  warn "Still failing. Diagnostics:"
  $SUDO dpkg --audit >&2 || true
  [[ -r /var/log/apt/term.log ]] && tail -n 40 /var/log/apt/term.log >&2 || true
  if [[ -f /proc/1/environ ]] && grep -qaE 'container=|WSL' /proc/1/environ 2>/dev/null; then
    warn "Looks like a container/WSL environment; check the first error printed by 'dpkg --configure -a'."
  fi
  die "Could not install $pkg. Run 'sudo dpkg --configure -a' and read the FIRST error."
}

# ---------- main function ----------

install_java() {
  local version="${1:-$JAVA_DEFAULT}" kind="${2:-jdk}"
  local pm pkg
  pm="$(detect_pm)"
  setup_sudo
  pkg="$(pkg_name "$pm" "$version" "$kind")"
  log "Package manager: $pm | Installing: $pkg"

  case "$pm" in
    apt)
      $SUDO apt-get update -y
      if ! apt-cache show "$pkg" >/dev/null 2>&1; then
        warn "'$pkg' is not available on this release. Available OpenJDK packages:"
        apt-cache search --names-only '^openjdk-[0-9]+-jdk$' | sort -V >&2 || true
        die "Pick one of the versions above."
      fi
      apt_install_with_repair "$pkg" ;;
    dnf)
      $SUDO dnf install -y "$pkg" \
        || die "'$pkg' not found. Try: dnf search openjdk" ;;
    pacman)
      $SUDO pacman -Sy --needed --noconfirm "$pkg" \
        || die "'$pkg' not found. Try: pacman -Ss openjdk" ;;
  esac

  ok "Installed $pkg"
  command -v java >/dev/null 2>&1 && java -version 2>&1 | sed 's/^/    /'
  [[ $kind == jdk ]] && command -v javac >/dev/null 2>&1 && printf '    %s\n' "$(javac -version 2>&1)"

  # Hints for multiple installed versions / JAVA_HOME
  case "$pm" in
    apt)    log "Switch versions with:  sudo update-alternatives --config java" ;;
    dnf)    log "Switch versions with:  sudo alternatives --config java" ;;
    pacman) log "Switch versions with:  sudo archlinux-java set <java-N-openjdk>  (list: archlinux-java status)" ;;
  esac
  if command -v java >/dev/null 2>&1; then
    local jh
    jh="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
    log "JAVA_HOME is likely:  $jh"
  fi
}

# ---------- arg parsing ----------

for arg in "$@"; do
  case "$arg" in
    -h|--help)  usage; exit 0 ;;
    --jre)      KIND="jre" ;;
    --jdk)      KIND="jdk" ;;
    8|11|17|21|25|latest) VERSION="$arg" ;;
    *) die "Unknown argument: $arg (see --help)" ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  if [[ -t 0 ]]; then
    echo "Select Java (OpenJDK) version:"
    echo "  1) 8"
    echo "  2) 11"
    echo "  3) 17  (LTS)"
    echo "  4) 21  (LTS)"
    echo "  5) 25  (LTS)"
    echo "  6) latest"
    read -rp "Choice [default: $JAVA_DEFAULT]: " choice
    case "${choice:-}" in
      1) VERSION=8 ;; 2) VERSION=11 ;; 3) VERSION=17 ;;
      4) VERSION=21 ;; 5) VERSION=25 ;; 6) VERSION=latest ;;
      "") VERSION="$JAVA_DEFAULT" ;;
      *) die "Invalid choice." ;;
    esac
  else
    VERSION="$JAVA_DEFAULT"
  fi
fi

install_java "$VERSION" "$KIND"
