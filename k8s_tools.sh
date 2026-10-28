#!/usr/bin/env bash
# Detects the Linux distro and installs Kubernetes tooling:
#   kubectl, helm, kind, minikube, k3s            (clusters and core CLIs)
#   k9s, kubectx + kubens, stern                  (day-to-day helpers)
# Supported: Ubuntu, Debian, Fedora, Rocky/Alma/RHEL/CentOS, Arch (and derivatives)
#
# Usage:
#   sudo ./install-k8s-tools.sh                 # interactive menu
#   sudo ./install-k8s-tools.sh --all           # everything
#   sudo ./install-k8s-tools.sh --kubectl --helm --kind
#   sudo ./install-k8s-tools.sh --k3s
#   sudo ./install-k8s-tools.sh --k9s --kubectx --stern
#
# Pin versions with env vars (use sudo -E):
#   KUBECTL_VERSION=v1.31.2  HELM_VERSION=v3.16.2  KIND_VERSION=v0.24.0
#   MINIKUBE_VERSION=v1.34.0 K3S_VERSION=v1.31.2+k3s1
#   K9S_VERSION=v0.32.7      KUBECTX_VERSION=v0.9.5  STERN_VERSION=v1.31.0
#
# k3s on RHEL-family / Fedora:
#   - installs container-selinux before the k3s installer
#   - checks the *runtime* SELinux state (getenforce) vs /etc/selinux/config.
#     If SELinux is configured "enforcing" but is not actually enforcing right now
#     (e.g. Disabled on many VPS images), the installer's labeling step cannot work,
#     so the script passes INSTALL_K3S_SELINUX_WARN=true to let it continue.
#   - if the installer fails while SELinux is enforcing, it reloads the policy,
#     relabels the binary, retries once, then falls back to warn-only mode.
#   - opens firewalld ports/zones automatically when firewalld is running.
#   Set K3S_SKIP_FIREWALLD=1 to skip the firewalld changes.

set -euo pipefail

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: install-k8s-tools.sh [options]

  --all         install everything
  --kubectl     install kubectl
  --helm        install Helm
  --kind        install kind (Kubernetes in Docker)
  --minikube    install minikube
  --k3s         install k3s (lightweight Kubernetes server, needs systemd)
  --k9s         install k9s (terminal UI for clusters)
  --kubectx     install kubectx and kubens (switch contexts / namespaces fast)
  --stern       install stern (multi-pod log tailing)
  -h, --help    show this help

With no options, an interactive menu is shown.
EOF
}

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
  ubuntu|debian|linuxmint|pop|elementary|zorin|raspbian) family="debian" ;;
  fedora)                                                family="fedora" ;;
  rocky|almalinux|rhel|centos|ol)                        family="rhel"   ;;
  arch|manjaro|endeavouros)                              family="arch"   ;;
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

# ---- detect CPU architecture ------------------------------------------------
case "$(uname -m)" in
  x86_64|amd64)  ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) die "Unsupported CPU architecture: $(uname -m) (only amd64 and arm64 are handled)." ;;
esac

log "Detected: ${PRETTY_NAME:-$DISTRO} (family: $family, arch: $ARCH)"

# ---- temp dir ---------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- prerequisites ----------------------------------------------------------
install_prereqs() {
  local missing=()
  for c in curl tar sha256sum; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0

  log "Installing prerequisites: ${missing[*]}"
  case "$family" in
    debian) $SUDO apt-get update -y && $SUDO apt-get install -y curl tar coreutils ca-certificates ;;
    fedora|rhel) $SUDO dnf install -y curl tar coreutils ca-certificates ;;
    arch)   $SUDO pacman -Sy --noconfirm --needed curl tar coreutils ca-certificates ;;
  esac
}

has_container_runtime() {
  command -v docker >/dev/null 2>&1 || command -v podman >/dev/null 2>&1
}

# ---- component installers ---------------------------------------------------
install_kubectl() {
  log "Installing kubectl"
  local ver="${KUBECTL_VERSION:-}"
  [[ -n "$ver" ]] || ver="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  local base="https://dl.k8s.io/release/${ver}/bin/linux/${ARCH}"

  curl -fsSL -o "$TMP/kubectl"        "$base/kubectl"
  curl -fsSL -o "$TMP/kubectl.sha256" "$base/kubectl.sha256"
  ( cd "$TMP" && echo "$(cat kubectl.sha256)  kubectl" | sha256sum -c - ) \
    || die "kubectl checksum verification failed."

  $SUDO install -m 0755 "$TMP/kubectl" /usr/local/bin/kubectl
  ok "kubectl $ver installed"
}

install_helm() {
  log "Installing Helm"
  local ver="${HELM_VERSION:-}"
  [[ -n "$ver" ]] || ver="$(curl -fsSL https://get.helm.sh/helm-latest-version)"
  [[ "$ver" == v* ]] || ver="v${ver}"
  local tarball="helm-${ver}-linux-${ARCH}.tar.gz"

  curl -fsSL -o "$TMP/$tarball"           "https://get.helm.sh/${tarball}"
  curl -fsSL -o "$TMP/$tarball.sha256sum" "https://get.helm.sh/${tarball}.sha256sum"
  ( cd "$TMP" && sha256sum -c "$tarball.sha256sum" ) \
    || die "Helm checksum verification failed."

  tar -xzf "$TMP/$tarball" -C "$TMP"
  $SUDO install -m 0755 "$TMP/linux-${ARCH}/helm" /usr/local/bin/helm
  ok "Helm $ver installed"
}

install_kind() {
  log "Installing kind"
  local ver="${KIND_VERSION:-}"
  if [[ -z "$ver" ]]; then
    # Resolve the latest release tag from the GitHub redirect (no API rate limits).
    ver="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
      https://github.com/kubernetes-sigs/kind/releases/latest | sed 's|.*/||')"
  fi
  [[ "$ver" == v* ]] || ver="v${ver}"

  curl -fsSL -o "$TMP/kind" "https://kind.sigs.k8s.io/dl/${ver}/kind-linux-${ARCH}"
  $SUDO install -m 0755 "$TMP/kind" /usr/local/bin/kind
  ok "kind $ver installed"

  has_container_runtime || warn "kind needs Docker (or Podman). Install one before creating a cluster."
}

install_minikube() {
  log "Installing minikube"
  local ver="${MINIKUBE_VERSION:-latest}"
  local base="https://storage.googleapis.com/minikube/releases/${ver}"

  curl -fsSL -o "$TMP/minikube" "$base/minikube-linux-${ARCH}"

  # Verify checksum when the published .sha256 file is available.
  if curl -fsSL -o "$TMP/minikube.sha256" "$base/minikube-linux-${ARCH}.sha256" 2>/dev/null; then
    ( cd "$TMP" && echo "$(awk '{print $1}' minikube.sha256)  minikube" | sha256sum -c - ) \
      || die "minikube checksum verification failed."
  else
    warn "No checksum file found for minikube; skipping verification."
  fi

  $SUDO install -m 0755 "$TMP/minikube" /usr/local/bin/minikube
  ok "minikube installed"

  has_container_runtime || warn "minikube's default driver needs Docker (or Podman). Install one first."
  [[ $EUID -eq 0 ]] && warn "minikube's docker driver refuses to run as root; start it as a normal user."
}

# ---- k3s helpers (RHEL family / Fedora) -------------------------------------
# Runtime SELinux mode: Enforcing, Permissive or Disabled.
selinux_runtime() {
  if command -v getenforce >/dev/null 2>&1; then
    getenforce 2>/dev/null || echo "Disabled"
  else
    echo "Disabled"
  fi
}

# SELinux mode configured for the next boot (enforcing, permissive, disabled, or empty).
selinux_config() {
  [[ -r /etc/selinux/config ]] || return 0
  sed -n 's/^SELINUX=\([a-zA-Z]*\).*/\1/p' /etc/selinux/config | head -n1 | tr '[:upper:]' '[:lower:]'
}

selinux_enforcing() {
  [[ "$(selinux_runtime)" == "Enforcing" ]]
}

# container-selinux provides the container_runtime_exec_t type that k3s-selinux
# needs; without it the installer fails to label /usr/local/bin/k3s.
install_container_selinux() {
  if rpm -q container-selinux >/dev/null 2>&1; then
    log "container-selinux already installed"
    return 0
  fi

  log "Installing container-selinux"
  if $SUDO dnf install -y container-selinux; then
    return 0
  fi

  warn "container-selinux not found; enabling extra repos and retrying."
  $SUDO dnf install -y dnf-plugins-core || true
  $SUDO dnf config-manager --set-enabled crb appstream extras >/dev/null 2>&1 || true
  $SUDO dnf install -y container-selinux \
    || die "Could not install container-selinux. Enable the AppStream/extras repos and retry."

  # If k3s-selinux was installed earlier (without its dependency), reinstall it.
  if rpm -q k3s-selinux >/dev/null 2>&1; then
    $SUDO dnf reinstall -y k3s-selinux || true
  fi
}

# Open the ports K3s needs and trust the pod/service CIDRs.
configure_firewalld_for_k3s() {
  [[ "${K3S_SKIP_FIREWALLD:-0}" == "1" ]] && return 0
  systemctl is-active --quiet firewalld 2>/dev/null || return 0
  command -v firewall-cmd >/dev/null 2>&1 || return 0

  log "firewalld is active; opening ports for k3s"
  $SUDO firewall-cmd --permanent --add-port=6443/tcp --add-port=10250/tcp
  $SUDO firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16   # pods
  $SUDO firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16   # services
  $SUDO firewall-cmd --reload
  ok "firewalld configured for k3s"
}

# Make sure the k3s binary carries the SELinux label k3s-selinux expects.
fix_k3s_selinux_label() {
  selinux_enforcing || return 0
  command -v restorecon >/dev/null 2>&1 || return 0
  [[ -e /usr/local/bin/k3s ]] || return 0

  $SUDO restorecon -v /usr/local/bin/k3s || true

  if ls -Z /usr/local/bin/k3s 2>/dev/null | grep -q container_runtime_exec_t; then
    ok "k3s binary has the container_runtime_exec_t label"
  else
    warn "k3s binary is not labeled container_runtime_exec_t. Check: ls -Z /usr/local/bin/k3s"
  fi
}

# Run the official installer from a saved copy so it can be retried.
#   $1 = "warn" to add INSTALL_K3S_SELINUX_WARN=true
run_k3s_installer() {
  local envs=()
  [[ -n "${K3S_VERSION:-}" ]] && envs+=("INSTALL_K3S_VERSION=$K3S_VERSION")
  [[ "${1:-}" == "warn" ]]    && envs+=("INSTALL_K3S_SELINUX_WARN=true")

  if [[ ${#envs[@]} -gt 0 ]]; then
    $SUDO env "${envs[@]}" sh "$TMP/k3s-install.sh"
  else
    $SUDO sh "$TMP/k3s-install.sh"
  fi
}

install_k3s() {
  log "Installing k3s"
  command -v systemctl >/dev/null 2>&1 || die "k3s installer expects systemd (systemctl not found)."

  local selinux_mode="warn-not-needed"   # "warn" => pass INSTALL_K3S_SELINUX_WARN=true
  local rpm_family=0
  [[ "$family" == "fedora" || "$family" == "rhel" ]] && rpm_family=1

  if [[ $rpm_family -eq 1 ]]; then
    # Must come before the k3s installer so the SELinux labeling can succeed.
    install_container_selinux
    configure_firewalld_for_k3s

    local rt cfg
    rt="$(selinux_runtime)"
    cfg="$(selinux_config)"
    log "SELinux runtime: $rt, configured: ${cfg:-unknown}"

    if [[ "$rt" != "Enforcing" && "$cfg" == "enforcing" ]]; then
      # The installer's chcon step cannot work when SELinux isn't active, but it
      # still insists on it because the config says "enforcing".
      warn "SELinux is configured 'enforcing' but is currently $rt, so labeling the k3s binary is impossible."
      warn "Continuing with INSTALL_K3S_SELINUX_WARN=true. To fix SELinux itself, set SELINUX=permissive"
      warn "in /etc/selinux/config, reboot (a relabel runs on boot), then rerun this script."
      selinux_mode="warn"
    fi
  fi

  # Save the official installer so it can be retried.
  curl -sfL https://get.k3s.io -o "$TMP/k3s-install.sh" || die "Could not download the k3s installer."

  if ! run_k3s_installer "$selinux_mode"; then
    [[ $rpm_family -eq 1 ]] || die "k3s installer failed."

    warn "k3s installer failed. Reloading SELinux policy, relabeling and retrying once."
    $SUDO dnf reinstall -y container-selinux k3s-selinux >/dev/null 2>&1 || true
    $SUDO semodule -B >/dev/null 2>&1 || true
    [[ -e /usr/local/bin/k3s ]] && $SUDO restorecon -v /usr/local/bin/k3s >/dev/null 2>&1 || true

    if ! run_k3s_installer "$selinux_mode"; then
      warn "Still failing. Retrying with INSTALL_K3S_SELINUX_WARN=true (k3s will run without its SELinux label)."
      run_k3s_installer warn || die "k3s installer failed. Check: journalctl -u k3s -e"
      selinux_mode="warn"
    fi
  fi

  if [[ $rpm_family -eq 1 ]]; then
    fix_k3s_selinux_label
    # Restart so the service starts with the corrected label.
    $SUDO systemctl restart k3s || warn "Could not restart k3s; check: sudo systemctl status k3s"
  fi

  # Give the invoking (non-root) user a kubeconfig, without overwriting an existing one.
  local user="${SUDO_USER:-}"
  if [[ -n "$user" && "$user" != "root" ]]; then
    local home
    home="$(getent passwd "$user" | cut -d: -f6)"
    if [[ -n "$home" && ! -e "$home/.kube/config" ]]; then
      log "Copying kubeconfig to $home/.kube/config"
      $SUDO install -d -m 0700 -o "$user" -g "$(id -gn "$user")" "$home/.kube"
      $SUDO install -m 0600 -o "$user" -g "$(id -gn "$user")" /etc/rancher/k3s/k3s.yaml "$home/.kube/config"
    elif [[ -e "$home/.kube/config" ]]; then
      warn "$home/.kube/config already exists; not overwritten."
      warn "K3s kubeconfig is at /etc/rancher/k3s/k3s.yaml (use KUBECONFIG=... to switch)."
    fi
  fi
  ok "k3s installed (check with: sudo k3s kubectl get nodes)"
}

# ---- helpers for GitHub-released tools ---------------------------------------
# Latest release tag of a GitHub repo, via the redirect (no API rate limits).
github_latest() {
  curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest" | sed 's|.*/||'
}

# Verify a downloaded file against a "<sha256>  <filename>" style checksums file.
#   $1 = file name inside $TMP, $2 = checksums file name inside $TMP
verify_sums() {
  awk -v f="$1" '$2 == f || $2 == "*" f' "$TMP/$2" | ( cd "$TMP" && sha256sum -c - >/dev/null ) \
    || die "Checksum verification failed for $1."
}

install_k9s() {
  log "Installing k9s"
  local ver="${K9S_VERSION:-}"
  [[ -n "$ver" ]] || ver="$(github_latest derailed/k9s)"
  [[ "$ver" == v* ]] || ver="v${ver}"
  local file="k9s_Linux_${ARCH}.tar.gz"
  local base="https://github.com/derailed/k9s/releases/download/${ver}"

  curl -fsSL -o "$TMP/$file" "$base/$file"
  # Newer releases ship checksums.sha256; older ones used checksums.txt.
  curl -fsSL -o "$TMP/k9s.sums" "$base/checksums.sha256" \
    || curl -fsSL -o "$TMP/k9s.sums" "$base/checksums.txt" \
    || die "Could not download the k9s checksums file."
  verify_sums "$file" k9s.sums

  mkdir -p "$TMP/k9s"
  tar -xzf "$TMP/$file" -C "$TMP/k9s"
  $SUDO install -m 0755 "$TMP/k9s/k9s" /usr/local/bin/k9s
  ok "k9s $ver installed"
}

install_kubectx() {
  log "Installing kubectx and kubens"
  local ver="${KUBECTX_VERSION:-}"
  [[ -n "$ver" ]] || ver="$(github_latest ahmetb/kubectx)"
  [[ "$ver" == v* ]] || ver="v${ver}"

  # kubectx names its x86 builds "x86_64" instead of "amd64".
  local karch
  case "$ARCH" in amd64) karch="x86_64" ;; *) karch="$ARCH" ;; esac
  local base="https://github.com/ahmetb/kubectx/releases/download/${ver}"

  curl -fsSL -o "$TMP/kubectx.sums" "$base/checksums.txt" \
    || die "Could not download the kubectx checksums file."

  local tool file
  for tool in kubectx kubens; do
    file="${tool}_${ver}_linux_${karch}.tar.gz"
    curl -fsSL -o "$TMP/$file" "$base/$file"
    verify_sums "$file" kubectx.sums
    mkdir -p "$TMP/$tool"
    tar -xzf "$TMP/$file" -C "$TMP/$tool"
    $SUDO install -m 0755 "$TMP/$tool/$tool" "/usr/local/bin/$tool"
  done
  ok "kubectx and kubens $ver installed"
}

install_stern() {
  log "Installing stern"
  local ver="${STERN_VERSION:-}"
  [[ -n "$ver" ]] || ver="$(github_latest stern/stern)"
  [[ "$ver" == v* ]] || ver="v${ver}"
  # Release files use the version without the leading "v".
  local file="stern_${ver#v}_linux_${ARCH}.tar.gz"
  local base="https://github.com/stern/stern/releases/download/${ver}"

  curl -fsSL -o "$TMP/$file" "$base/$file"
  curl -fsSL -o "$TMP/stern.sums" "$base/checksums.txt" \
    || die "Could not download the stern checksums file."
  verify_sums "$file" stern.sums

  mkdir -p "$TMP/stern"
  tar -xzf "$TMP/$file" -C "$TMP/stern"
  $SUDO install -m 0755 "$TMP/stern/stern" /usr/local/bin/stern
  ok "stern $ver installed"
}

# ---- choose components ------------------------------------------------------
WANT_KUBECTL=0; WANT_HELM=0; WANT_KIND=0; WANT_MINIKUBE=0; WANT_K3S=0
WANT_K9S=0; WANT_KUBECTX=0; WANT_STERN=0

if [[ $# -gt 0 ]]; then
  for arg in "$@"; do
    case "$arg" in
      --all)      WANT_KUBECTL=1; WANT_HELM=1; WANT_KIND=1; WANT_MINIKUBE=1; WANT_K3S=1
                  WANT_K9S=1; WANT_KUBECTX=1; WANT_STERN=1 ;;
      --kubectl)  WANT_KUBECTL=1 ;;
      --helm)     WANT_HELM=1 ;;
      --kind)     WANT_KIND=1 ;;
      --minikube) WANT_MINIKUBE=1 ;;
      --k3s)      WANT_K3S=1 ;;
      --k9s)      WANT_K9S=1 ;;
      --kubectx)  WANT_KUBECTX=1 ;;
      --stern)    WANT_STERN=1 ;;
      -h|--help)  usage; exit 0 ;;
      *)          usage; die "Unknown option: $arg" ;;
    esac
  done
else
  [[ -t 0 ]] || { usage; die "No options given and no terminal for the menu."; }
  cat <<'EOF'

Select components to install:
  1) kubectl
  2) helm
  3) kind
  4) minikube
  5) k3s
  6) k9s
  7) kubectx + kubens
  8) stern
  a) all

EOF
  read -rp "Enter choices (e.g. '1 2 3' or 'a'): " choices
  for c in $choices; do
    case "$c" in
      1) WANT_KUBECTL=1 ;;
      2) WANT_HELM=1 ;;
      3) WANT_KIND=1 ;;
      4) WANT_MINIKUBE=1 ;;
      5) WANT_K3S=1 ;;
      6) WANT_K9S=1 ;;
      7) WANT_KUBECTX=1 ;;
      8) WANT_STERN=1 ;;
      a|A) WANT_KUBECTL=1; WANT_HELM=1; WANT_KIND=1; WANT_MINIKUBE=1; WANT_K3S=1
           WANT_K9S=1; WANT_KUBECTX=1; WANT_STERN=1 ;;
      *) die "Invalid choice: $c" ;;
    esac
  done
fi

TOTAL=$((WANT_KUBECTL + WANT_HELM + WANT_KIND + WANT_MINIKUBE + WANT_K3S + WANT_K9S + WANT_KUBECTX + WANT_STERN))
[[ $TOTAL -gt 0 ]] || die "Nothing selected."

# ---- run --------------------------------------------------------------------
install_prereqs

[[ $WANT_KUBECTL  -eq 1 ]] && install_kubectl
[[ $WANT_HELM     -eq 1 ]] && install_helm
[[ $WANT_KIND     -eq 1 ]] && install_kind
[[ $WANT_MINIKUBE -eq 1 ]] && install_minikube
[[ $WANT_K9S      -eq 1 ]] && install_k9s
[[ $WANT_KUBECTX  -eq 1 ]] && install_kubectx
[[ $WANT_STERN    -eq 1 ]] && install_stern
[[ $WANT_K3S      -eq 1 ]] && install_k3s   # last, so it doesn't clobber an existing kubectl

# ---- summary ----------------------------------------------------------------
echo
log "Summary"
command -v kubectl  >/dev/null 2>&1 && echo "  kubectl : $(kubectl version --client 2>/dev/null | head -n1)"
command -v helm     >/dev/null 2>&1 && echo "  helm    : $(helm version --short)"
command -v kind     >/dev/null 2>&1 && echo "  kind    : $(kind version)"
command -v minikube >/dev/null 2>&1 && echo "  minikube: $(minikube version --short 2>/dev/null)"
command -v k9s      >/dev/null 2>&1 && echo "  k9s     : $(k9s version --short 2>/dev/null | awk '/^Version/ {print $2; exit}')"
command -v kubectx  >/dev/null 2>&1 && echo "  kubectx : $(kubectx --version 2>/dev/null | head -n1) (kubens: $(kubens --version 2>/dev/null | head -n1))"
command -v stern    >/dev/null 2>&1 && echo "  stern   : $(stern --version 2>/dev/null | awk '/^version:/ {print $2; exit}')"
command -v k3s      >/dev/null 2>&1 && echo "  k3s     : $(k3s --version | head -n1)"
echo
ok "Done."
