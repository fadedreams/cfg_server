#!/usr/bin/env bash
# Detects the Linux distro, lists the 10 latest Node.js releases from nodejs.org,
# lets you pick one (or type any version), then installs it. Can also install nvm.
# Supported: Ubuntu, Debian, Fedora, Rocky/Alma/RHEL/CentOS, Arch (and derivatives)
#
# Usage:
#   sudo ./install-node.sh              # interactive: pick from the list or type a version
#   sudo ./install-node.sh 22.11.0      # exact version
#   sudo ./install-node.sh 22           # newest 22.x
#   sudo ./install-node.sh lts          # newest LTS
#   sudo ./install-node.sh lts --nvm    # Node.js + latest nvm (for the invoking user)
#   sudo ./install-node.sh --nvm-only   # only nvm
#   ./install-node.sh --list            # just show the 10 latest releases
#
# Env:
#   INSTALL_DIR=/usr/local/lib/nodejs   # versions live in $INSTALL_DIR/node-vX-linux-ARCH
#   BIN_DIR=/usr/local/bin              # node/npm/npx/corepack get symlinked here

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/usr/local/lib/nodejs}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
DIST_URL="https://nodejs.org/dist"
NVM_FALLBACK_TAG="v0.40.3"

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: install-node.sh [VERSION | lts | latest | MAJOR] [--nvm] [--nvm-only] [--list] [-h]

  (no args)    interactive menu of the 10 latest releases
  22.11.0      install that exact version
  22           install the newest 22.x
  lts          install the newest LTS release
  latest       install the newest release
  --nvm        also install the latest nvm (for the invoking user, in ~/.nvm)
  --nvm-only   install only nvm, skip Node.js
  --list       show the 10 latest releases and exit

Env: INSTALL_DIR (default /usr/local/lib/nodejs), BIN_DIR (default /usr/local/bin)
EOF
}

# ---------------------------------------------------------------- distro ----

DISTRO_FAMILY=""

detect_distro() {
  [ -r /etc/os-release ] || die "Cannot read /etc/os-release; unsupported system"
  # shellcheck disable=SC1091
  . /etc/os-release
  local ids=" ${ID:-} ${ID_LIKE:-} "
  case "$ids" in
    *" ubuntu "*|*" debian "*)                        DISTRO_FAMILY="debian" ;;
    *" fedora "*)                                     DISTRO_FAMILY="fedora" ;;
    *" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*) DISTRO_FAMILY="rhel" ;;
    *" arch "*)                                       DISTRO_FAMILY="arch" ;;
    *) die "Unsupported distro: ${PRETTY_NAME:-unknown}" ;;
  esac
  log "Detected: ${PRETTY_NAME:-$ID} (family: $DISTRO_FAMILY)"
}

node_arch() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "x64" ;;
    aarch64|arm64)  echo "arm64" ;;
    armv7l)         echo "armv7l" ;;
    ppc64le)        echo "ppc64le" ;;
    s390x)          echo "s390x" ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
}

ensure_deps() {
  local missing=0 c
  for c in curl tar xz sha256sum; do
    command -v "$c" >/dev/null 2>&1 || missing=1
  done
  [ "$missing" -eq 0 ] && return 0

  [ "$(id -u)" -eq 0 ] || die "Missing dependencies (curl, tar, xz). Run with sudo to install them."
  log "Installing dependencies (curl, tar, xz)..."
  case "$DISTRO_FAMILY" in
    debian)
      apt-get update -y
      apt-get install -y curl xz-utils tar ca-certificates coreutils ;;
    fedora)
      dnf install -y xz tar ca-certificates coreutils
      command -v curl >/dev/null 2>&1 || dnf install -y curl ;;
    rhel)
      # Don't force-install curl: Rocky/Alma ship curl-minimal, which conflicts
      local pm=dnf
      command -v dnf >/dev/null 2>&1 || pm=yum
      "$pm" install -y xz tar ca-certificates coreutils
      command -v curl >/dev/null 2>&1 || "$pm" install -y curl ;;
    arch)
      pacman -S --noconfirm --needed curl xz tar ca-certificates coreutils ;;
  esac
}

# --------------------------------------------------------------- releases ---

RELEASES=""   # lines of: "vX.Y.Z <LTS-codename|false>", newest first

fetch_releases() {
  local raw
  raw="$(curl -fsSL "$DIST_URL/index.json")" || die "Could not fetch $DIST_URL/index.json"
  RELEASES="$(printf '%s' "$raw" \
    | grep -o '"version":"v[0-9.]*"[^}]*' \
    | sed -n 's/^"version":"\(v[0-9.]*\)".*"lts":\(false\|"[A-Za-z]*"\).*/\1 \2/p' \
    | tr -d '"')" || true
  [ -n "$RELEASES" ] || die "Could not parse the release list"
}

print_latest() {
  local i=1 ver lts tag
  printf '\nLatest 10 Node.js releases:\n'
  while read -r ver lts; do
    tag=""
    [ "$lts" != "false" ] && tag="  (LTS: $lts)"
    printf '  %2d) %s%s\n' "$i" "$ver" "$tag"
    i=$((i + 1))
  done < <(printf '%s\n' "$RELEASES" | head -n 10)
  printf '\n'
}

# Turns lts | latest | MAJOR | MAJOR.MINOR | X.Y.Z | vX.Y.Z into an exact vX.Y.Z
resolve_version() {
  local spec="${1#v}" out=""
  case "$spec" in
    lts)
      out="$(printf '%s\n' "$RELEASES" | awk '$2!="false"{print $1; exit}')" ;;
    latest)
      out="$(printf '%s\n' "$RELEASES" | awk 'NR==1{print $1}')" ;;
    *)
      if [[ "$spec" =~ ^[0-9]+$ ]] || [[ "$spec" =~ ^[0-9]+\.[0-9]+$ ]]; then
        out="$(printf '%s\n' "$RELEASES" | awk -v p="v$spec." 'index($1,p)==1{print $1; exit}')"
      elif [[ "$spec" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        out="$(printf '%s\n' "$RELEASES" | awk -v v="v$spec" '$1==v{print $1; exit}')"
      else
        die "Invalid version spec: '$1'"
      fi ;;
  esac
  [ -n "$out" ] || die "No Node.js release matches '$1'"
  printf '%s' "$out"
}

choose_version_interactive() {
  local ans lts_default
  print_latest >&2
  lts_default="$(resolve_version lts)"
  read -r -p "Pick 1-10, type a version (22, 22.11.0, lts, latest), or Enter for LTS [$lts_default]: " ans
  ans="${ans//[[:space:]]/}"
  if [ -z "$ans" ]; then
    printf '%s' "$lts_default"
  elif [[ "$ans" =~ ^([1-9]|10)$ ]]; then
    printf '%s\n' "$RELEASES" | awk -v n="$ans" 'NR==n{print $1}'
  else
    resolve_version "$ans"
  fi
}

# ---------------------------------------------------------------- install ---

install_node() {
  local ver="$1" arch name tarball tmp dest
  arch="$(node_arch)"
  name="node-${ver}-linux-${arch}"
  tarball="${name}.tar.xz"
  dest="$INSTALL_DIR/$name"

  [ "$(id -u)" -eq 0 ] || die "Installing Node.js needs root. Re-run with sudo."

  if [ -x "$dest/bin/node" ]; then
    warn "$name already present in $INSTALL_DIR; skipping download"
  else
    tmp="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT

    log "Downloading $tarball ..."
    curl -fSL --progress-bar -o "$tmp/$tarball" "$DIST_URL/$ver/$tarball"
    curl -fsSL -o "$tmp/SHASUMS256.txt" "$DIST_URL/$ver/SHASUMS256.txt"

    log "Verifying checksum..."
    ( cd "$tmp" && grep " $tarball\$" SHASUMS256.txt | sha256sum -c - >/dev/null ) \
      || die "Checksum verification failed for $tarball"
    ok "Checksum OK"

    mkdir -p "$INSTALL_DIR"
    log "Extracting to $INSTALL_DIR ..."
    tar -xJf "$tmp/$tarball" -C "$INSTALL_DIR"
  fi

  mkdir -p "$BIN_DIR"
  local b
  for b in node npm npx corepack; do
    if [ -e "$dest/bin/$b" ]; then
      ln -sfn "$dest/bin/$b" "$BIN_DIR/$b"
    fi
  done

  ok "Node.js $ver installed -> $dest"
  "$BIN_DIR/node" --version | sed 's/^/    node /'
  "$BIN_DIR/npm"  --version | sed 's/^/    npm  /'
}

# -------------------------------------------------------------------- nvm ---

# Installs the latest nvm for the real user (not root) into ~/.nvm
install_nvm() {
  local target_user target_home tag
  target_user="${SUDO_USER:-$(id -un)}"
  target_home="$(getent passwd "$target_user" | cut -d: -f6)"
  [ -n "$target_home" ] || die "Cannot find home directory for $target_user"

  command -v curl >/dev/null 2>&1 || die "curl is required to install nvm"
  command -v git  >/dev/null 2>&1 || warn "git not found; nvm's installer will fall back to curl/wget"

  # Resolve the latest release tag by following GitHub's /releases/latest redirect
  tag="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
        https://github.com/nvm-sh/nvm/releases/latest | sed 's|.*/||')" || tag=""
  if ! [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    tag="$NVM_FALLBACK_TAG"
    warn "Could not resolve latest nvm tag, falling back to $tag"
  fi
  log "Installing nvm $tag for user '$target_user' in $target_home/.nvm"

  local run=(bash)
  if [ "$(id -u)" -eq 0 ] && [ "$target_user" != "root" ]; then
    run=(sudo -u "$target_user" -H bash)
  fi

  # PROFILE is set explicitly so the installer edits the right rc file under sudo
  curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${tag}/install.sh" \
    | PROFILE="$target_home/.bashrc" NVM_DIR="$target_home/.nvm" "${run[@]}"

  ok "nvm $tag installed. Open a new shell or run: source ~/.bashrc"
}

# ------------------------------------------------------------------- main ---

main() {
  local WITH_NVM=0 NVM_ONLY=0 LIST_ONLY=0 SPEC="" a
  for a in "$@"; do
    case "$a" in
      --nvm)      WITH_NVM=1 ;;
      --nvm-only) NVM_ONLY=1 ;;
      --list)     LIST_ONLY=1 ;;
      -h|--help)  usage; exit 0 ;;
      -*)         usage >&2; die "Unknown option: $a" ;;
      *)          [ -z "$SPEC" ] || die "Only one version argument is allowed"
                  SPEC="$a" ;;
    esac
  done

  detect_distro

  if [ "$NVM_ONLY" -eq 1 ]; then
    ensure_deps
    install_nvm
    exit 0
  fi

  ensure_deps
  fetch_releases

  if [ "$LIST_ONLY" -eq 1 ]; then
    print_latest
    exit 0
  fi

  local ver
  if [ -n "$SPEC" ]; then
    ver="$(resolve_version "$SPEC")"
  else
    [ -t 0 ] || die "No version given and stdin is not a terminal. Pass a version, e.g. 'lts'."
    ver="$(choose_version_interactive)"

    if [ "$WITH_NVM" -eq 0 ]; then
      local yn
      read -r -p "Also install nvm? [y/N]: " yn
      case "$yn" in [yY]*) WITH_NVM=1 ;; esac
    fi
  fi

  log "Selected Node.js $ver"
  install_node "$ver"

  if [ "$WITH_NVM" -eq 1 ]; then
    install_nvm
  fi
}

main "$@"
