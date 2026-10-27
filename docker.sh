#!/usr/bin/env bash
# Detects the Linux distro and installs Docker Engine + Docker Compose (v2 plugin).
# Supported: Ubuntu, Debian, Fedora, Rocky (and RHEL-likes), Arch
#
# Usage:
#   sudo ./install-docker.sh
#   RUN_TEST=1 sudo -E ./install-docker.sh     # also runs the hello-world container
#   ADD_USER=alice sudo -E ./install-docker.sh # add a specific user to the docker group

set -euo pipefail

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---- root / sudo ------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "Run as root or install sudo."
  SUDO="sudo"
else
  SUDO=""
fi

# ---- detect distro ----------------------------------------------------------
[[ -r /etc/os-release ]] || die "/etc/os-release not found; can't detect distro."
# shellcheck disable=SC1091
. /etc/os-release
DISTRO="${ID:-unknown}"
LIKE="${ID_LIKE:-}"

family=""
case "$DISTRO" in
  ubuntu|debian)                         family="debian" ;;
  linuxmint|pop|elementary|zorin)        family="debian" ;;
  fedora)                                family="fedora" ;;
  rocky|almalinux|rhel|centos|ol)        family="rhel"   ;;
  arch|manjaro|endeavouros)              family="arch"   ;;
  *)
    case " $LIKE " in
      *" ubuntu "*|*" debian "*) family="debian" ;;
      *" fedora "*)              family="fedora" ;;
      *" rhel "*|*" centos "*)   family="rhel"   ;;
      *" arch "*)                family="arch"   ;;
      *) die "Unsupported distro: $DISTRO (ID_LIKE='$LIKE')" ;;
    esac
    ;;
esac
log "Detected: ${PRETTY_NAME:-$DISTRO} (family: $family)"

# ---- already installed? -----------------------------------------------------
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  ok "Docker and Compose already installed:"
  docker --version
  docker compose version
  exit 0
fi

# ---- installers -------------------------------------------------------------
install_debian() {
  # Pick the upstream repo (ubuntu or debian) and codename, handling derivatives like Mint/Pop.
  local repo_os codename
  if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
    repo_os="$DISTRO"
    codename="${VERSION_CODENAME:-}"
  elif [[ " $LIKE " == *" ubuntu "* ]]; then
    repo_os="ubuntu"
    codename="${UBUNTU_CODENAME:-}"
  else
    repo_os="debian"
    codename="${DEBIAN_CODENAME:-${VERSION_CODENAME:-}}"
  fi
  [[ -n "$codename" ]] || die "Could not determine release codename."
  log "Using Docker repo for $repo_os ($codename)"

  log "Removing conflicting packages (if any)"
  for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    $SUDO apt-get remove -y "$pkg" >/dev/null 2>&1 || true
  done

  $SUDO apt-get update -y
  $SUDO apt-get install -y ca-certificates curl
  $SUDO install -m 0755 -d /etc/apt/keyrings
  $SUDO curl -fsSL "https://download.docker.com/linux/${repo_os}/gpg" -o /etc/apt/keyrings/docker.asc
  $SUDO chmod a+r /etc/apt/keyrings/docker.asc

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${repo_os} ${codename} stable" \
    | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null

  $SUDO apt-get update -y
  $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_rpm_repo() {
  # $1 = fedora | centos | rhel  (path component on download.docker.com)
  local repo_os="$1"
  log "Using Docker repo for $repo_os"

  $SUDO dnf install -y dnf-plugins-core curl ca-certificates

  # Writing the .repo file directly works on both dnf4 and dnf5.
  $SUDO curl -fsSL "https://download.docker.com/linux/${repo_os}/docker-ce.repo" \
    -o /etc/yum.repos.d/docker-ce.repo

  $SUDO dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_arch() {
  log "Installing Docker via pacman"
  $SUDO pacman -Sy --noconfirm --needed docker docker-compose docker-buildx
}

case "$family" in
  debian) install_debian ;;
  fedora) install_rpm_repo fedora ;;
  rhel)
    # Rocky, Alma, CentOS use the centos repo; real RHEL has its own.
    if [[ "$DISTRO" == "rhel" ]]; then install_rpm_repo rhel; else install_rpm_repo centos; fi
    ;;
  arch)   install_arch ;;
esac

# ---- enable service ---------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
  log "Enabling and starting docker service"
  $SUDO systemctl enable --now docker
else
  warn "systemctl not found; start the Docker daemon manually."
fi

# ---- docker group -----------------------------------------------------------
TARGET_USER="${ADD_USER:-${SUDO_USER:-}}"
if [[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]]; then
  log "Adding '$TARGET_USER' to the docker group"
  $SUDO usermod -aG docker "$TARGET_USER"
  warn "Log out and back in (or run 'newgrp docker') for the group change to apply."
  warn "Note: docker group membership is effectively root access on this machine."
fi

# ---- verify -----------------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "Install finished but 'docker' is not on PATH."
ok "$(docker --version)"
if docker compose version >/dev/null 2>&1; then
  ok "$(docker compose version)"
else
  warn "'docker compose' plugin not found."
fi

if [[ -n "${RUN_TEST:-}" ]]; then
  log "Running hello-world test"
  $SUDO docker run --rm hello-world
fi

ok "Done."
