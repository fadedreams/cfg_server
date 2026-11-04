#!/usr/bin/env bash
# Detects the Linux distro and installs PHP (CLI + common extensions) from the
# right source for that distro, optionally with PHP-FPM and Composer.
# Supported: Ubuntu, Debian, Fedora, Rocky/Alma/RHEL/CentOS, Arch (and derivatives)
#
# Where versions come from:
#   Debian          -> sury.org repo (any 8.x), or the distro default
#   Ubuntu          -> ppa:ondrej/php (any 8.x), or the distro default
#   Rocky/Alma/RHEL -> Remi repo (any 8.x), or the distro default
#   Fedora, Arch    -> distro default only (they ship a recent PHP)
#
# Usage:
#   sudo ./install-php.sh             # interactive: pick a version
#   sudo ./install-php.sh 8.4         # non-interactive: a specific version
#   sudo ./install-php.sh default     # non-interactive: the distro's own PHP
#   sudo ./install-php.sh 8.4 --fpm --composer
#   ./install-php.sh --list           # show the versions this script offers
#
# Options:
#   --minimal    # CLI only, no extra extensions
#   --fpm        # also install PHP-FPM
#   --composer   # also install Composer to /usr/local/bin/composer

set -euo pipefail

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
}

SUPPORTED_VERSIONS=(8.5 8.4 8.3 8.2)
VERSION=""          # empty = distro default
REQUESTED=""
LIST_ONLY=0
MINIMAL=0
WITH_FPM=0
WITH_COMPOSER=0

for arg in "$@"; do
  case "$arg" in
    -h|--help)  usage; exit 0 ;;
    --list)     LIST_ONLY=1 ;;
    --minimal)  MINIMAL=1 ;;
    --fpm)      WITH_FPM=1 ;;
    --composer) WITH_COMPOSER=1 ;;
    -*)         usage; die "Unknown option: $arg" ;;
    *)          REQUESTED="$arg" ;;
  esac
done

# ---------------------------------------------------------------- distro ----
detect_distro() {
  [ -r /etc/os-release ] || die "Cannot detect distro: /etc/os-release not found"
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO_ID="${ID:-unknown}"
  DISTRO_LIKE="${ID_LIKE:-}"
  CODENAME="${VERSION_CODENAME:-}"
  VERSION_MAJOR="${VERSION_ID%%.*}"
  case "$DISTRO_ID $DISTRO_LIKE" in
    *ubuntu*)                             PKG="apt";    FAMILY="ubuntu" ;;
    *debian*)                             PKG="apt";    FAMILY="debian" ;;
    *fedora*)                             PKG="dnf";    FAMILY="fedora" ;;
    *rhel*|*centos*|*rocky*|*almalinux*)  PKG="dnf";    FAMILY="rhel" ;;
    *arch*)                               PKG="pacman"; FAMILY="arch" ;;
    *) die "Unsupported distro: $DISTRO_ID" ;;
  esac
  log "Detected distro: ${PRETTY_NAME:-$DISTRO_ID} (package manager: $PKG)"
}

pkg_install() {
  case "$PKG" in
    apt)    apt-get install -y -qq "$@" ;;
    dnf)    dnf install -y -q "$@" ;;
    pacman) pacman -S --noconfirm --needed "$@" ;;
  esac
}

install_deps() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v unzip >/dev/null 2>&1 || missing+=(unzip)
  [ "${#missing[@]}" -eq 0 ] && return 0
  log "Installing missing dependencies: ${missing[*]}"
  case "$PKG" in
    apt) apt-get update -qq ;;
    pacman) pacman -Sy --noconfirm >/dev/null ;;
  esac
  pkg_install "${missing[@]}"
}

# -------------------------------------------------------------- versions ----
list_versions() {
  echo
  echo "  1) distro default (no third-party repo)"
  local i=2
  for v in "${SUPPORTED_VERSIONS[@]}"; do
    printf '  %d) PHP %s\n' "$i" "$v"
    i=$((i + 1))
  done
  echo
}

pick_version() {
  list_versions
  local choice
  read -r -p "Pick a number (1-$(( ${#SUPPORTED_VERSIONS[@]} + 1 ))) or type a version like 8.3 [1]: " choice </dev/tty
  choice="${choice:-1}"
  if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le $(( ${#SUPPORTED_VERSIONS[@]} + 1 )) ]; then
    if [ "$choice" -eq 1 ]; then
      VERSION=""
    else
      VERSION="${SUPPORTED_VERSIONS[$((choice - 2))]}"
    fi
  else
    VERSION="$choice"
  fi

  if [ "$WITH_COMPOSER" -eq 0 ]; then
    local yn
    read -r -p "Also install Composer? [y/N]: " yn </dev/tty
    [[ "$yn" =~ ^[Yy]$ ]] && WITH_COMPOSER=1
  fi
}

validate_version() {
  [ -z "$VERSION" ] && return 0
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || die "Invalid version: '$VERSION' (use e.g. 8.4, or 'default')"
  case "$FAMILY" in
    fedora|arch)
      warn "$FAMILY only ships its own PHP version; ignoring requested ${VERSION}."
      VERSION=""
      ;;
  esac
}

# ---------------------------------------------------------- repositories ----
setup_repo() {
  [ -z "$VERSION" ] && return 0
  case "$FAMILY" in
    debian)
      log "Adding sury.org PHP repository"
      pkg_install ca-certificates lsb-release apt-transport-https
      local tmp; tmp="$(mktemp -d)"
      curl -fsSL -o "${tmp}/keyring.deb" https://packages.sury.org/debsuryorg-archive-keyring.deb \
        || die "Could not download the sury keyring"
      dpkg -i "${tmp}/keyring.deb" >/dev/null
      rm -rf "$tmp"
      echo "deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ ${CODENAME} main" \
        > /etc/apt/sources.list.d/php.list
      apt-get update -qq
      ;;
    ubuntu)
      log "Adding ppa:ondrej/php"
      pkg_install software-properties-common ca-certificates
      add-apt-repository -y ppa:ondrej/php >/dev/null
      apt-get update -qq
      ;;
    rhel)
      log "Adding EPEL and Remi repositories"
      pkg_install epel-release
      dnf install -y -q "https://rpms.remirepo.net/enterprise/remi-release-${VERSION_MAJOR}.rpm"
      dnf module reset php -y -q
      dnf module enable "php:remi-${VERSION}" -y -q \
        || die "Remi does not offer PHP ${VERSION} for this system"
      ;;
  esac
}

# --------------------------------------------------------------- install ----
install_one() {
  # Install a package, but keep going if one optional extension is missing.
  pkg_install "$1" >/dev/null 2>&1 && ok "installed $1" || warn "skipped $1 (not available)"
}

install_php() {
  local p core exts=()

  case "$PKG" in
    apt)
      p="php${VERSION}"
      core="${p}-cli"
      exts=(mbstring xml curl zip gd mysql pgsql sqlite3 intl bcmath opcache)
      exts=("${exts[@]/#/${p}-}")
      [ "$WITH_FPM" -eq 1 ] && exts+=("${p}-fpm")
      apt-get update -qq
      ;;
    dnf)
      core="php-cli"
      exts=(php-mbstring php-xml php-pecl-zip php-gd php-mysqlnd php-pgsql php-intl php-bcmath php-opcache)
      [ "$WITH_FPM" -eq 1 ] && exts+=(php-fpm)
      ;;
    pacman)
      core="php"
      exts=(php-gd php-intl php-pgsql php-sqlite)
      [ "$WITH_FPM" -eq 1 ] && exts+=(php-fpm)
      ;;
  esac

  log "Installing PHP${VERSION:+ $VERSION} (${core})"
  pkg_install "$core" || die "Failed to install ${core}"

  if [ "$MINIMAL" -eq 0 ]; then
    log "Installing common extensions"
    for e in "${exts[@]}"; do install_one "$e"; done
  elif [ "$WITH_FPM" -eq 1 ]; then
    case "$PKG" in
      apt) install_one "${p}-fpm" ;;
      *)   install_one "php-fpm" ;;
    esac
  fi

  # With several PHP versions installed on Debian/Ubuntu, make this one the default.
  if [ "$PKG" = "apt" ] && [ -n "$VERSION" ] && command -v update-alternatives >/dev/null 2>&1; then
    update-alternatives --set php "/usr/bin/php${VERSION}" >/dev/null 2>&1 || true
  fi
}

install_composer() {
  local tmp; tmp="$(mktemp -d)"
  trap "rm -rf '$tmp'" RETURN

  log "Installing Composer"
  local expected actual
  expected="$(curl -fsSL https://composer.github.io/installer.sig)" \
    || die "Could not fetch Composer installer signature"
  curl -fsSL -o "${tmp}/composer-setup.php" https://getcomposer.org/installer \
    || die "Could not download the Composer installer"
  actual="$(php -r "echo hash_file('sha384', '${tmp}/composer-setup.php');")"
  [ "$expected" = "$actual" ] || die "Composer installer checksum mismatch!"
  ok "Checksum OK"
  php "${tmp}/composer-setup.php" --quiet --install-dir=/usr/local/bin --filename=composer
  ok "$(composer --version 2>/dev/null | head -n1)"
}

# ------------------------------------------------------------------ main ----
main() {
  if [ "$LIST_ONLY" -eq 1 ]; then
    echo "Versions offered by this script:"
    list_versions
    exit 0
  fi

  [ "$(id -u)" -eq 0 ] || die "Run as root: sudo $0 ${REQUESTED}"

  detect_distro
  install_deps

  case "$REQUESTED" in
    "")      pick_version ;;
    default) VERSION="" ;;
    *)       VERSION="${REQUESTED#php}" ;;
  esac
  validate_version

  log "Selected: PHP ${VERSION:-(distro default)}"
  setup_repo
  install_php

  echo
  ok "$(php -v | head -n1)"
  log "Binary: $(command -v php)"

  if [ "$WITH_COMPOSER" -eq 1 ]; then
    install_composer
  fi

  echo
  log "PHP is installed system-wide, so no PATH changes or 'source' are needed."
  [ "$WITH_FPM" -eq 1 ] && log "PHP-FPM installed; manage it with systemctl (service name varies by distro)."
  return 0
}

main
