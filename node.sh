#!/usr/bin/env bash
# Detects the Linux distro, lists the 10 latest Node.js releases from nodejs.org,
# lets you pick one (or type any version), then installs it.
# Supported: Ubuntu, Debian, Fedora, Rocky/Alma/RHEL/CentOS, Arch (and derivatives)
#
# Usage:
#   sudo ./install-node.sh              # interactive: pick from the list or type a version
#   sudo ./install-node.sh 22.11.0      # exact version
#   sudo ./install-node.sh 22           # newest 22.x
#   sudo ./install-node.sh lts          # newest LTS
#   ./install-node.sh --list            # just show the 10 latest releases
#
# Env:
#   INSTALL_DIR=/usr/local/lib/nodejs   # versions live in $INSTALL_DIR/node-vX-linux-ARCH
#   BIN_DIR=/usr/local/bin              # node/npm/npx/corepack get symlinked here

set -euo pipefail

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: install-node.sh [VERSION | lts | latest | MAJOR] [--list] [-h]

  (no args)    interactive menu of the 10 latest releases
  22.11.0      install that exact version
  22           install the newest 22.x
  lts          install the newest LTS release
  latest       install the newest release
  --list       show the 10 latest releases and exit

Env: INSTALL_DIR (default /usr/local/lib/nodejs), BIN_DIR (default /usr/local/bin)
EOF
}

INSTALL_DIR="${INSTALL_DIR:-/usr/local/lib/nodejs}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
DIST_URL="${NODE_DIST_URL:-https://nodejs.org/dist}"

REQUESTED=""
LIST_ONLY=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --list)    LIST_ONLY=1 ;;
    -*)        usage; die "Unknown option: $arg" ;;
    *)         REQUESTED="$arg" ;;
  esac
done

# ---- root / sudo ------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; else SUDO=""; fi
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

# ---- detect CPU architecture (Node's naming) --------------------------------
case "$(uname -m)" in
  x86_64|amd64)   ARCH="x64"     ;;
  aarch64|arm64)  ARCH="arm64"   ;;
  armv7l)         ARCH="armv7l"  ;;
  ppc64le)        ARCH="ppc64le" ;;
  s390x)          ARCH="s390x"   ;;
  *) die "Unsupported CPU architecture for official Node.js builds: $(uname -m)" ;;
esac

log "Detected: ${PRETTY_NAME:-$DISTRO} (family: $family, arch: $ARCH)"

# ---- prerequisites ----------------------------------------------------------
install_prereqs() {
  local missing=()
  for c in curl tar xz jq sha256sum; do
    if ! command -v "$c" >/dev/null 2>&1; then missing+=("$c"); fi
  done
  if [[ ${#missing[@]} -eq 0 ]]; then return 0; fi

  if [[ -z "$SUDO" && $EUID -ne 0 ]]; then
    die "Missing tools (${missing[*]}) and no sudo available to install them."
  fi
  log "Installing prerequisites: ${missing[*]}"
  case "$family" in
    debian)      $SUDO apt-get update -y && $SUDO apt-get install -y curl tar xz-utils jq coreutils ca-certificates ;;
    fedora|rhel) $SUDO dnf install -y curl tar xz jq coreutils ca-certificates ;;
    arch)        $SUDO pacman -Sy --noconfirm --needed curl tar xz jq coreutils ca-certificates ;;
  esac
}
install_prereqs

# Official Node.js binaries link against libatomic, which minimal server images often lack.
has_libatomic() {
  local out
  out="$(ldconfig -p 2>/dev/null || /sbin/ldconfig -p 2>/dev/null || true)"
  [[ "$out" == *"libatomic.so.1"* ]]
}
install_runtime_libs() {
  if has_libatomic; then return 0; fi
  log "Installing libatomic (required by Node.js)"
  case "$family" in
    debian) $SUDO apt-get update -y && $SUDO apt-get install -y libatomic1 ;;
    fedora|rhel) $SUDO dnf install -y libatomic ;;
    arch)   $SUDO pacman -Sy --noconfirm --needed gcc-libs ;;
  esac
}
install_runtime_libs

# ---- fetch release list -----------------------------------------------------
log "Fetching Node.js releases from nodejs.org"
JSON="$(curl -fsSL "$DIST_URL/index.json")" || die "Could not fetch $DIST_URL/index.json"

# Only releases that have a build for this architecture. Newest first.
# Each line: version|lts-codename-or-empty
mapfile -t LINES < <(jq -r --arg a "$ARCH" '
  [.[] | select(.files | index("linux-" + $a))] | .[0:10] | .[]
  | .version + "|" + (if .lts == false then "" else .lts end)' <<<"$JSON")
[[ ${#LINES[@]} -gt 0 ]] || die "Could not parse the release list."

VERSIONS=(); LTS_NAMES=()
for line in "${LINES[@]}"; do
  VERSIONS+=("${line%%|*}")
  LTS_NAMES+=("${line#*|}")
done

# Resolve user input to a full version present in the release list.
# Accepts: lts | latest | 22 | 22.11 | 22.11.0 | v22.11.0
resolve_version() {
  local input="${1#v}" lower
  lower="${input,,}"
  case "$lower" in
    lts)
      jq -r --arg a "$ARCH" '[.[] | select(.lts != false) | select(.files | index("linux-" + $a))] | .[0].version // empty' <<<"$JSON" ;;
    latest|current)
      jq -r --arg a "$ARCH" '[.[] | select(.files | index("linux-" + $a))] | .[0].version // empty' <<<"$JSON" ;;
    *)
      if [[ "$input" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        jq -r --arg a "$ARCH" --arg p "v${input}." \
          '[.[] | select(.version | startswith($p)) | select(.files | index("linux-" + $a))] | .[0].version // empty' <<<"$JSON"
      else
        jq -r --arg a "$ARCH" --arg v "v${input}" \
          '[.[] | select(.version == $v) | select(.files | index("linux-" + $a))] | .[0].version // empty' <<<"$JSON"
      fi ;;
  esac
}

LTS_VERSION="$(resolve_version lts)"

# Currently installed version (if any)
CURRENT=""
if command -v node >/dev/null 2>&1; then
  CURRENT="$(node --version 2>/dev/null)" || true
fi

print_list() {
  echo
  echo "10 latest Node.js releases:"
  local i=1 v tag
  for v in "${VERSIONS[@]}"; do
    tag=""
    if [[ -n "${LTS_NAMES[$((i - 1))]}" ]]; then tag=" (LTS: ${LTS_NAMES[$((i - 1))]})"; fi
    if [[ -n "$CURRENT" && "$v" == "$CURRENT" ]]; then tag="$tag (installed)"; fi
    printf '  %2d) %s%s\n' "$i" "${v#v}" "$tag"
    i=$((i + 1))
  done
  echo
  if [[ -n "$LTS_VERSION" ]]; then echo "Newest LTS: ${LTS_VERSION#v}"; fi
  if [[ -n "$CURRENT" ]]; then echo "Currently installed: ${CURRENT#v}"; fi
  echo
  return 0
}

if [[ $LIST_ONLY -eq 1 ]]; then
  print_list
  exit 0
fi

# ---- choose version ---------------------------------------------------------
CHOSEN=""
if [[ -n "$REQUESTED" ]]; then
  CHOSEN="$(resolve_version "$REQUESTED")"
  [[ -n "$CHOSEN" ]] || die "No Node.js build found for '$REQUESTED' on linux-$ARCH."
else
  [[ -t 0 ]] || die "No version given and no terminal for the menu. Pass one: ./install-node.sh lts"
  print_list
  while [[ -z "$CHOSEN" ]]; do
    read -rp "Pick 1-${#VERSIONS[@]}, 'lts', 'latest', a major (e.g. v22) or a version (e.g. 22.11.0), q to quit [lts]: " answer
    answer="${answer:-lts}"
    if [[ "$answer" == "q" || "$answer" == "Q" ]]; then
      log "Cancelled."; exit 0
    elif [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#VERSIONS[@]} )); then
      CHOSEN="${VERSIONS[$((answer - 1))]}"
    else
      CHOSEN="$(resolve_version "$answer")"
      if [[ -z "$CHOSEN" ]]; then warn "No Node.js build found for '$answer'. Try again."; fi
    fi
  done
fi

if [[ "$CHOSEN" == "$CURRENT" ]]; then
  warn "${CHOSEN#v} is already the active version; reinstalling."
fi
log "Selected: ${CHOSEN#v}"

# ---- download + verify ------------------------------------------------------
NAME="node-${CHOSEN}-linux-${ARCH}"
TARBALL="${NAME}.tar.xz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log "Downloading $TARBALL"
curl -fSL --progress-bar -o "$TMP/$TARBALL" "$DIST_URL/$CHOSEN/$TARBALL"
curl -fsSL -o "$TMP/SHASUMS256.txt" "$DIST_URL/$CHOSEN/SHASUMS256.txt"

log "Verifying SHA256 checksum"
( cd "$TMP" && grep " ${TARBALL}\$" SHASUMS256.txt | sha256sum -c - >/dev/null ) \
  || die "Checksum verification failed."
ok "Checksum OK"

# ---- install ----------------------------------------------------------------
[[ -n "$INSTALL_DIR" && "$INSTALL_DIR" != "/" ]] || die "Refusing to use INSTALL_DIR='$INSTALL_DIR'."
log "Installing to $INSTALL_DIR/$NAME"
$SUDO mkdir -p "$INSTALL_DIR" "$BIN_DIR"
$SUDO rm -rf "${INSTALL_DIR:?}/$NAME"
$SUDO tar -xJf "$TMP/$TARBALL" -C "$INSTALL_DIR"

# 'current' points at the active version, so switching or rolling back is one symlink.
$SUDO ln -sfn "$INSTALL_DIR/$NAME" "$INSTALL_DIR/current"
for bin in node npm npx corepack; do
  if [[ -e "$INSTALL_DIR/current/bin/$bin" ]]; then
    $SUDO ln -sfn "$INSTALL_DIR/current/bin/$bin" "$BIN_DIR/$bin"
  fi
done

# PATH for login shells (also covers globally installed npm binaries)
PROFILE_FILE="/etc/profile.d/nodejs.sh"
if [[ -d /etc/profile.d ]]; then
  $SUDO tee "$PROFILE_FILE" >/dev/null <<EOF
# Added by install-node.sh
export PATH="\$PATH:$INSTALL_DIR/current/bin"
EOF
  $SUDO chmod 0644 "$PROFILE_FILE"
fi

# ---- verify -----------------------------------------------------------------
if ! NODE_OUT="$("$INSTALL_DIR/current/bin/node" --version 2>&1)"; then
  die "Install finished but the node binary doesn't run: $NODE_OUT"
fi
ok "node $NODE_OUT"
if [[ -e "$INSTALL_DIR/current/bin/npm" ]]; then
  ok "npm  $("$INSTALL_DIR/current/bin/node" "$INSTALL_DIR/current/lib/node_modules/npm/bin/npm-cli.js" --version)"
fi

if [[ -x /usr/bin/node && "$BIN_DIR" != "/usr/bin" ]]; then
  warn "A distro-packaged node exists at /usr/bin/node; $BIN_DIR comes first in PATH, so the new one wins."
fi

echo
log "Other installed versions (if any) stay in $INSTALL_DIR and can be deleted safely."
log "Open a new shell or run 'source $PROFILE_FILE', then check: node -v && npm -v"
