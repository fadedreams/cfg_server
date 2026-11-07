#!/usr/bin/env bash
# replace-nano.sh - make `nano` launch vi on any Linux distro
set -euo pipefail

# --- root handling ---
if [[ $EUID -ne 0 ]]; then
  SUDO="sudo"
else
  SUDO=""
fi

# --- detect distro family ---
. /etc/os-release
ID_ALL="${ID:-} ${ID_LIKE:-}"

case " $ID_ALL " in
  *" arch "*|*" manjaro "*)
    FAMILY=arch;   INSTALL_VI="$SUDO pacman -S --needed --noconfirm vi";   REMOVE_NANO="$SUDO pacman -Rns --noconfirm nano" ;;
  *" debian "*|*" ubuntu "*)
    FAMILY=debian; INSTALL_VI="$SUDO apt-get install -y vim-tiny";         REMOVE_NANO="$SUDO apt-get remove -y nano" ;;
  *" fedora "*|*" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*)
    if command -v dnf >/dev/null; then PM=dnf; else PM=yum; fi
    FAMILY=rhel;   INSTALL_VI="$SUDO $PM install -y vim-minimal";          REMOVE_NANO="$SUDO $PM remove -y nano" ;;
  *" suse "*|*" opensuse "*|*" sles "*)
    FAMILY=suse;   INSTALL_VI="$SUDO zypper install -y vim";               REMOVE_NANO="$SUDO zypper remove -y nano" ;;
  *" alpine "*)
    FAMILY=alpine; INSTALL_VI="$SUDO apk add vim";                         REMOVE_NANO="$SUDO apk del nano" ;;
  *" void "*)
    FAMILY=void;   INSTALL_VI="$SUDO xbps-install -y vim";                 REMOVE_NANO="$SUDO xbps-remove -y nano" ;;
  *)
    echo "Unknown distro ($ID_ALL) - skipping package steps."
    FAMILY=unknown; INSTALL_VI=""; REMOVE_NANO="" ;;
esac
echo "Detected family: $FAMILY"

# --- make sure vi exists ---
if ! command -v vi >/dev/null 2>&1 && [[ -n "$INSTALL_VI" ]]; then
  echo "vi not found, installing..."
  eval "$INSTALL_VI"
fi

# --- install the wrapper (same on every distro) ---
$SUDO mkdir -p /usr/local/bin
printf '#!/bin/sh\nexec vi "$@"\n' | $SUDO tee /usr/local/bin/nano >/dev/null
$SUDO chmod +x /usr/local/bin/nano
echo "Installed /usr/local/bin/nano -> vi"

# --- optional: remove real nano package ---
if [[ "${1:-}" == "--remove" && -n "$REMOVE_NANO" ]]; then
  echo "Removing nano package..."
  eval "$REMOVE_NANO" || true
fi

hash -r
echo "Done. Test with: which nano"
