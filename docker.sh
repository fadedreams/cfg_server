#!/usr/bin/env bash
# Detects the Linux distro and installs Docker Engine + Docker Compose (v2 plugin) + Docker Buildx.
# Supported: Ubuntu, Debian, Fedora, Rocky (and RHEL-likes), Arch
#
# Usage:
#   sudo ./install-docker.sh
#   RUN_TEST=1 sudo -E ./install-docker.sh      # also runs the hello-world container
#   ADD_USER=alice sudo -E ./install-docker.sh  # add a specific user to the docker group
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
  ubuntu|debian)                       family="debian" ;;
  linuxmint|pop|elementary|zorin)      family="debian" ;;
  fedora)                              family="fedora" ;;
  rocky|rhel|centos|almalinux|ol)      family="rhel" ;;
  arch|manjaro|endeavouros|cachyos)    family="arch" ;;
  *)
    case " $LIKE " in
      *" ubuntu "*|*" debian "*) family="debian" ;;
      *" fedora "*)              family="fedora" ;;
      *" rhel "*|*" centos "*)   family="rhel" ;;
      *" arch "*)                family="arch" ;;
    esac
    ;;
esac
[[ -n "$family" ]] || die "Unsupported distro: $DISTRO (ID_LIKE=$LIKE)"
log "Detected: $DISTRO (family: $family)"

# ---- installers -------------------------------------------------------------
install_debian() {
  # Pick the right Docker repo (ubuntu vs debian) and codename.
  local repo_distro codename
  if [[ "$DISTRO" == "ubuntu" || " $LIKE " == *" ubuntu "* ]]; then
    repo_distro="ubuntu"
    codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  else
    repo_distro="debian"
    codename="${VERSION_CODENAME:-}"
  fi
  [[ -n "$codename" ]] || die "Could not determine distro codename."

  log "Removing conflicting packages (if any)..."
  for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    $SUDO apt-get remove -y "$pkg" >/dev/null 2>&1 || true
  done

  log "Setting up Docker apt repository ($repo_distro / $codename)..."
  $SUDO apt-get update -y
  $SUDO apt-get install -y ca-certificates curl
  $SUDO install -m 0755 -d /etc/apt/keyrings
  $SUDO curl -fsSL "https://download.docker.com/linux/${repo_distro}/gpg" \
    -o /etc/apt/keyrings/docker.asc
  $SUDO chmod a+r /etc/apt/keyrings/docker.asc

  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${repo_distro} ${codename} stable" \
    | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null

  log "Installing Docker Engine, Compose and Buildx..."
  $SUDO apt-get update -y
  $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
}

add_dnf_repo() {
  local url="$1"
  $SUDO dnf install -y dnf-plugins-core
  # dnf5 (newer Fedora) uses "addrepo"; dnf4 uses "--add-repo".
  if $SUDO dnf config-manager addrepo --from-repofile="$url" >/dev/null 2>&1; then
    return 0
  fi
  $SUDO dnf config-manager --add-repo "$url"
}

install_fedora() {
  log "Removing conflicting packages (if any)..."
  $SUDO dnf remove -y docker docker-client docker-client-latest docker-common \
    docker-latest docker-latest-logrotate docker-logrotate docker-selinux \
    docker-engine-selinux docker-engine >/dev/null 2>&1 || true

  log "Setting up Docker dnf repository..."
  add_dnf_repo "https://download.docker.com/linux/fedora/docker-ce.repo"

  log "Installing Docker Engine, Compose and Buildx..."
  $SUDO dnf install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
}

install_rhel() {
  # Docker publishes "rhel" and "centos" repos; Rocky/Alma use the centos one.
  local repo_distro="centos"
  [[ "$DISTRO" == "rhel" ]] && repo_distro="rhel"

  log "Removing conflicting packages (if any)..."
  $SUDO dnf remove -y docker docker-client docker-client-latest docker-common \
    docker-latest docker-latest-logrotate docker-logrotate docker-engine \
    podman runc >/dev/null 2>&1 || true

  log "Setting up Docker dnf repository ($repo_distro)..."
  add_dnf_repo "https://download.docker.com/linux/${repo_distro}/docker-ce.repo"

  log "Installing Docker Engine, Compose and Buildx..."
  $SUDO dnf install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
}

install_arch() {
  log "Installing Docker Engine, Compose and Buildx..."
  $SUDO pacman -Sy --noconfirm --needed docker docker-compose docker-buildx
}

case "$family" in
  debian) install_debian ;;
  fedora) install_fedora ;;
  rhel)   install_rhel ;;
  arch)   install_arch ;;
esac

# ---- enable service ---------------------------------------------------------
if command -v systemctl >/dev/null 2>&1; then
  log "Enabling and starting docker service..."
  $SUDO systemctl enable --now docker
else
  warn "systemctl not found; start the docker daemon manually."
fi

# ---- docker group -----------------------------------------------------------
TARGET_USER="${ADD_USER:-${SUDO_USER:-}}"
if [[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]]; then
  if id "$TARGET_USER" >/dev/null 2>&1; then
    getent group docker >/dev/null 2>&1 || $SUDO groupadd docker
    $SUDO usermod -aG docker "$TARGET_USER"
    ok "Added $TARGET_USER to the docker group (log out and back in to apply)."
  else
    warn "User '$TARGET_USER' does not exist; skipping docker group."
  fi
fi

# ---- verify -----------------------------------------------------------------
log "Verifying installation..."
$SUDO docker --version >/dev/null 2>&1 \
  && ok "Docker: $($SUDO docker --version)" \
  || die "docker not found on PATH after install."

$SUDO docker compose version >/dev/null 2>&1 \
  && ok "Compose: $($SUDO docker compose version)" \
  || warn "docker compose plugin not found."

$SUDO docker buildx version >/dev/null 2>&1 \
  && ok "Buildx: $($SUDO docker buildx version)" \
  || warn "docker buildx plugin not found."

if [[ "${RUN_TEST:-0}" == "1" ]]; then
  log "Running hello-world test container..."
  $SUDO docker run --rm hello-world && ok "hello-world ran successfully."
fi

ok "Done."
