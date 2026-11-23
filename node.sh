#!/usr/bin/env bash
# Detects the Linux distro, lists the 10 latest Node.js releases from nodejs.org,
# lets you pick one (or type any version), then installs it. Can also install nvm.
# Supported: Ubuntu, Debian, Fedora, Rocky/Alma/RHEL/CentOS, Arch (and derivatives)
#
# Run it as your NORMAL user: it only uses sudo for the steps that need root
# (package install, writing to /usr/local). This also works when piped through
# process substitution, which `sudo bash <(curl ...)` does not:
#
#   bash <(curl -fsSL "https://raw.githubusercontent.com/fadedreams/cfg_server/main/node.sh")
#
# Usage:
#   ./node.sh                 # interactive: pick from the list or type a version
#   ./node.sh 22.11.0         # exact version
#   ./node.sh 22              # newest 22.x
#   ./node.sh lts             # newest LTS
#   ./node.sh lts --nvm       # Node.js + latest nvm (for the invoking user)
#   ./node.sh --nvm-only      # only nvm
#   ./node.sh --list          # just show the 10 latest releases
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
Usage: node.sh [VERSION | lts | latest | MAJOR] [--nvm] [--nvm-only] [--list] [-h]
  (no args)   interactive menu of the 10 latest releases
  22.11.0     install that exact version
  22          newest 22.x
  22.11       newest 22.11.x
  lts         newest LTS release
  latest      newest release
  --nvm       also install the latest nvm (for the invoking user)
  --nvm-only  only install nvm
  --list      show the 10 latest releases and exit
  -h, --help  show this help
EOF
}

TMP_DIR=""
cleanup() {
  if [ -n "$TMP_DIR" ]; then rm -rf "$TMP_DIR"; fi
}
trap cleanup EXIT

# ---------------------------------------------------------------- privileges
SUDO=""
need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "Root privileges are required and sudo is not installed. Run as root."
    SUDO="sudo"
    log "Root is needed for this step; using sudo."
    sudo -v || die "sudo authentication failed."
  fi
}

# ------------------------------------------------------------- interactivity
TTY_IN=""
if [ -t 0 ]; then
  TTY_IN="/dev/stdin"
elif { : </dev/tty; } 2>/dev/null; then
  TTY_IN="/dev/tty"
fi

ask() {
  local a=""
  if [ -n "$TTY_IN" ]; then
    printf '%s' "$1" >&2
    read -r a <"$TTY_IN" || true
  fi
  printf '%s' "$a"
}

# ------------------------------------------------------------------- distro
FAMILY="unknown"
detect_distro() {
  [ -r /etc/os-release ] || die "Cannot detect distro (/etc/os-release missing)."
  local id id_like pretty
  id="$(. /etc/os-release; printf '%s' "${ID:-}")"
  id_like="$(. /etc/os-release; printf '%s' "${ID_LIKE:-}")"
  pretty="$(. /etc/os-release; printf '%s' "${PRETTY_NAME:-${NAME:-unknown}}")"
  case " $id $id_like " in
    *" debian "*|*" ubuntu "*)                 FAMILY="debian" ;;
    *" fedora "*|*" rhel "*|*" centos "*)      FAMILY="redhat" ;;
    *" arch "*)                                FAMILY="arch" ;;
    *)                                         FAMILY="unknown" ;;
  esac
  log "Detected: $pretty (family: $FAMILY)"
}

ARCH=""
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)   ARCH="x64" ;;
    aarch64|arm64)  ARCH="arm64" ;;
    armv7l)         ARCH="armv7l" ;;
    ppc64le)        ARCH="ppc64le" ;;
    s390x)          ARCH="s390x" ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
}

ensure_deps() {
  local missing=() pkgs=() c
  for c in curl tar xz sha256sum; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if [ "${#missing[@]}" -eq 0 ]; then return 0; fi

  warn "Missing tools: ${missing[*]}"
  for c in "${missing[@]}"; do
    case "$c" in
      curl)      pkgs+=("curl") ;;
      tar)       pkgs+=("tar") ;;
      sha256sum) pkgs+=("coreutils") ;;
      xz)        if [ "$FAMILY" = "debian" ]; then pkgs+=("xz-utils"); else pkgs+=("xz"); fi ;;
    esac
  done

  need_root
  case "$FAMILY" in
    debian)
      pkgs+=("ca-certificates")
      $SUDO apt-get update -y
      $SUDO apt-get install -y "${pkgs[@]}"
      ;;
    redhat)
      if command -v dnf >/dev/null 2>&1; then
        $SUDO dnf install -y "${pkgs[@]}"
      else
        $SUDO yum install -y "${pkgs[@]}"
      fi
      ;;
    arch)
      $SUDO pacman -S --noconfirm --needed "${pkgs[@]}"
      ;;
    *)
      die "Unknown distro family. Please install manually: ${missing[*]}"
      ;;
  esac
}

# ----------------------------------------------------------------- releases
RELEASES=""   # lines of: "vX.Y.Z <LTS-codename|false>", newest first

fetch_releases() {
  local raw
  raw="$(curl -fsSL "$DIST_URL/index.json")" || die "Could not download $DIST_URL/index.json"
  RELEASES="$(sed -n 's/.*"version":"\(v[0-9][0-9.]*\)".*"lts":\(false\|"[^"]*"\).*/\1 \2/p' <<<"$raw" | tr -d '"')"
  [ -n "$RELEASES" ] || die "Could not parse the Node.js release list."
}

show_list() {
  local i=0 v l
  echo
  echo "Latest 10 Node.js releases:"
  while read -r v l; do
    i=$((i + 1))
    if [ "$l" != "false" ]; then
      printf '  %2d) %s  (LTS: %s)\n' "$i" "$v" "$l"
    else
      printf '  %2d) %s\n' "$i" "$v"
    fi
    if [ "$i" -ge 10 ]; then break; fi
  done <<<"$RELEASES"
  echo
}

# resolve_version <spec> -> prints vX.Y.Z
resolve_version() {
  local spec v
  spec="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  if [ "$spec" = "lts" ]; then
    v="$(awk '$2!="false"{print $1; exit}' <<<"$RELEASES")"
  elif [ "$spec" = "latest" ] || [ "$spec" = "current" ]; then
    v="$(awk 'NR==1{print $1; exit}' <<<"$RELEASES")"
  elif [[ "$spec" =~ ^v?[0-9]+$ ]] || [[ "$spec" =~ ^v?[0-9]+\.[0-9]+$ ]]; then
    v="$(awk -v p="v${spec#v}." 'index($1,p)==1{print $1; exit}' <<<"$RELEASES")"
  elif [[ "$spec" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    v="v${spec#v}"
    grep -q "^$v " <<<"$RELEASES" || die "Version $v does not exist on nodejs.org."
  else
    die "Unrecognised version '$1'. Use e.g. 22, 22.11.0, lts or latest."
  fi
  [ -n "$v" ] || die "No release found matching '$1'."
  printf '%s' "$v"
}

# ------------------------------------------------------------------ install
install_node() {
  local ver="$1" name tarball base expected actual b
  name="node-$ver-linux-$ARCH"
  tarball="$name.tar.xz"
  base="$DIST_URL/$ver"
  TMP_DIR="$(mktemp -d)"

  log "Downloading $tarball ..."
  curl -fL --progress-bar -o "$TMP_DIR/$tarball" "$base/$tarball" \
    || die "Download failed: $base/$tarball (no build for $ARCH?)"

  log "Verifying SHA-256 checksum ..."
  curl -fsSL -o "$TMP_DIR/SHASUMS256.txt" "$base/SHASUMS256.txt" \
    || die "Could not download SHASUMS256.txt"
  expected="$(awk -v f="$tarball" '$2==f{print $1}' "$TMP_DIR/SHASUMS256.txt")"
  [ -n "$expected" ] || die "No checksum entry found for $tarball"
  actual="$(sha256sum "$TMP_DIR/$tarball" | awk '{print $1}')"
  [ "$expected" = "$actual" ] || die "Checksum mismatch! expected $expected, got $actual"

  need_root
  log "Installing to $INSTALL_DIR/$name ..."
  $SUDO mkdir -p "$INSTALL_DIR" "$BIN_DIR"
  $SUDO rm -rf "${INSTALL_DIR:?}/$name"
  $SUDO tar -xJf "$TMP_DIR/$tarball" -C "$INSTALL_DIR" --no-same-owner

  for b in node npm npx corepack; do
    if [ -e "$INSTALL_DIR/$name/bin/$b" ]; then
      $SUDO ln -sfn "$INSTALL_DIR/$name/bin/$b" "$BIN_DIR/$b"
    fi
  done
  hash -r 2>/dev/null || true

  ok "Installed Node.js $("$BIN_DIR/node" -v) and npm $("$BIN_DIR/npm" -v)"

  local active
  active="$(command -v node 2>/dev/null || true)"
  if [ -n "$active" ] && [ "$active" != "$BIN_DIR/node" ]; then
    warn "'node' on your PATH is $active, which shadows $BIN_DIR/node."
    warn "Remove the distro package or put $BIN_DIR first in PATH."
  fi
}

install_nvm() {
  local tag cmd
  tag="$(curl -fsSL https://api.github.com/repos/nvm-sh/nvm/releases/latest 2>/dev/null \
        | sed -n 's/.*"tag_name": *"\(v[0-9.]*\)".*/\1/p' | head -n1 || true)"
  if [ -z "$tag" ]; then
    warn "Could not query the latest nvm release; using $NVM_FALLBACK_TAG"
    tag="$NVM_FALLBACK_TAG"
  fi
  # nvm's installer aborts if $NVM_DIR is set but missing, so create it inside
  # the same shell/user that runs the installer (works with and without sudo).
  cmd='if [ -n "${NVM_DIR:-}" ]; then mkdir -p "$NVM_DIR" || { echo "Cannot create NVM_DIR: $NVM_DIR" >&2; exit 1; }; fi; '
  cmd+="set -o pipefail; curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/$tag/install.sh | bash"

  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    log "Installing nvm $tag for user $SUDO_USER ..."
    sudo -u "$SUDO_USER" -H bash -c "$cmd"
  else
    if [ "$(id -u)" -eq 0 ]; then warn "Installing nvm for root (no invoking user detected)."; fi
    log "Installing nvm $tag ..."
    bash -c "$cmd"
  fi
  ok "nvm $tag installed. Open a new shell or run: source ~/.nvm/nvm.sh"
}

# --------------------------------------------------------------------- main
main() {
  local spec="" do_nvm=0 nvm_only=0 list_only=0 arg ver ans default_lts

  for arg in "$@"; do
    case "$arg" in
      -h|--help)  usage; exit 0 ;;
      --nvm)      do_nvm=1 ;;
      --nvm-only) nvm_only=1 ;;
      --list)     list_only=1 ;;
      -*)         die "Unknown option: $arg (try --help)" ;;
      *)
        [ -z "$spec" ] || die "Only one version argument is allowed."
        spec="$arg"
        ;;
    esac
  done

  detect_distro

  if [ "$nvm_only" -eq 1 ]; then
    command -v curl >/dev/null 2>&1 || ensure_deps
    install_nvm
    exit 0
  fi

  if [ "$list_only" -eq 1 ]; then
    command -v curl >/dev/null 2>&1 || die "curl is required."
    fetch_releases
    show_list
    exit 0
  fi

  ensure_deps
  detect_arch
  fetch_releases

  if [ -z "$spec" ]; then
    if [ -z "$TTY_IN" ]; then
      spec="lts"
      log "Non-interactive shell: defaulting to the newest LTS."
    else
      show_list
      default_lts="$(awk '$2!="false"{print $1; exit}' <<<"$RELEASES")"
      ans="$(ask "Pick 1-10, type a version (22, 22.11.0, lts, latest), or Enter for LTS [$default_lts]: ")"
      ans="${ans//[[:space:]]/}"
      if [ -z "$ans" ]; then
        spec="lts"
      elif [[ "$ans" =~ ^([1-9]|10)$ ]]; then
        spec="$(awk -v n="$ans" 'NR==n{print $1; exit}' <<<"$RELEASES")"
      else
        spec="$ans"
      fi
      if [ "$do_nvm" -eq 0 ]; then
        ans="$(ask "Also install nvm? [y/N]: ")"
        if [[ "$ans" =~ ^[Yy] ]]; then do_nvm=1; fi
      fi
    fi
  fi

  ver="$(resolve_version "$spec")"
  log "Selected Node.js $ver"

  install_node "$ver"

  if [ "$do_nvm" -eq 1 ]; then
    install_nvm
  fi

  ok "Done."
}

main "$@"
