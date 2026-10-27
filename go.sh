#!/usr/bin/env bash
# Detects the Linux distro, lists the 10 latest stable Go releases from go.dev,
# lets you pick one (or type any version), then installs it to /usr/local/go.
# Supported: Ubuntu, Debian, Fedora, Rocky/Alma/RHEL/CentOS, Arch (and derivatives)
#
# Usage:
#   sudo ./install-go.sh              # interactive: pick from the list or type a version
#   sudo ./install-go.sh 1.23.4       # non-interactive: install a specific version
#   ./install-go.sh --list            # just show the 10 latest stable versions
#
# Env:
#   INSTALL_DIR=/usr/local            # Go ends up in $INSTALL_DIR/go

set -euo pipefail

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

INSTALL_DIR="${INSTALL_DIR:-/usr/local}"
API_URL="https://go.dev/dl/?mode=json&include=all"
DL_BASE="https://go.dev/dl"

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

# ---- detect CPU architecture (Go's naming) ----------------------------------
case "$(uname -m)" in
  x86_64|amd64)   ARCH="amd64"   ;;
  aarch64|arm64)  ARCH="arm64"   ;;
  armv6l|armv7l)  ARCH="armv6l"  ;;
  i386|i686)      ARCH="386"     ;;
  ppc64le)        ARCH="ppc64le" ;;
  s390x)          ARCH="s390x"   ;;
  riscv64)        ARCH="riscv64" ;;
  *) die "Unsupported CPU architecture: $(uname -m)" ;;
esac

log "Detected: ${PRETTY_NAME:-$DISTRO} (family: $family, arch: $ARCH)"

# ---- prerequisites ----------------------------------------------------------
install_prereqs() {
  local missing=()
  for c in curl tar jq sha256sum; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0

  [[ -n "$SUDO" || $EUID -eq 0 ]] || die "Missing tools (${missing[*]}) and no sudo available to install them."
  log "Installing prerequisites: ${missing[*]}"
  case "$family" in
    debian)      $SUDO apt-get update -y && $SUDO apt-get install -y curl tar jq coreutils ca-certificates ;;
    fedora|rhel) $SUDO dnf install -y curl tar jq coreutils ca-certificates ;;
    arch)        $SUDO pacman -Sy --noconfirm --needed curl tar jq coreutils ca-certificates ;;
  esac
}
install_prereqs

# ---- fetch release list -----------------------------------------------------
log "Fetching Go releases from go.dev"
JSON="$(curl -fsSL "$API_URL")" || die "Could not fetch $API_URL"

mapfile -t VERSIONS < <(jq -r '[.[] | select(.stable == true)] | .[0:10] | .[].version' <<<"$JSON")
[[ ${#VERSIONS[@]} -gt 0 ]] || die "Could not parse the release list."

# Currently installed version (if any)
CURRENT=""
if [[ -x "$INSTALL_DIR/go/bin/go" ]]; then
  CURRENT="$("$INSTALL_DIR/go/bin/go" version 2>/dev/null | awk '{print $3}')" || true
elif command -v go >/dev/null 2>&1; then
  CURRENT="$(go version 2>/dev/null | awk '{print $3}')" || true
fi

print_list() {
  echo
  echo "10 latest stable Go versions:"
  local i=1 v tag
  for v in "${VERSIONS[@]}"; do
    tag=""
    [[ "$v" == "${VERSIONS[0]}" ]] && tag=" (latest)"
    [[ -n "$CURRENT" && "$v" == "$CURRENT" ]] && tag="$tag (installed)"
    printf '  %2d) %s%s\n' "$i" "${v#go}" "$tag"
    i=$((i + 1))
  done
  echo
  if [[ -n "$CURRENT" ]]; then
    echo "Currently installed: ${CURRENT#go}"
    echo
  fi
  return 0
}

if [[ $LIST_ONLY -eq 1 ]]; then
  print_list
  exit 0
fi

# ---- choose version ---------------------------------------------------------
normalize() {
  # accepts 1.23.4, go1.23.4, v1.23.4 -> go1.23.4
  local v="$1"
  v="${v#v}"; v="${v#go}"
  echo "go${v}"
}

CHOSEN=""
if [[ -n "$REQUESTED" ]]; then
  CHOSEN="$(normalize "$REQUESTED")"
else
  [[ -t 0 ]] || die "No version given and no terminal for the menu. Pass a version: ./install-go.sh 1.23.4"
  print_list
  while [[ -z "$CHOSEN" ]]; do
    read -rp "Pick 1-${#VERSIONS[@]}, type a version (e.g. 1.22.8), or q to quit [1]: " answer
    answer="${answer:-1}"
    case "$answer" in
      q|Q) log "Cancelled."; exit 0 ;;
      *[!0-9]*|"")
        CHOSEN="$(normalize "$answer")"
        ;;
      *)
        if (( answer >= 1 && answer <= ${#VERSIONS[@]} )); then
          CHOSEN="${VERSIONS[$((answer - 1))]}"
        else
          warn "Number out of range."
        fi
        ;;
    esac
  done
fi

# ---- look up the file + checksum for this version/arch ----------------------
FILENAME="${CHOSEN}.linux-${ARCH}.tar.gz"
SHA256="$(jq -r --arg v "$CHOSEN" --arg f "$FILENAME" \
  '.[] | select(.version == $v) | .files[] | select(.filename == $f) | .sha256' <<<"$JSON" | head -n1)"

if [[ -z "$SHA256" ]]; then
  die "No official linux/${ARCH} build found for '${CHOSEN#go}'. Check the version (note: Go 1.20 and older use e.g. 1.20, not 1.20.0)."
fi

if [[ "$CHOSEN" == "$CURRENT" ]]; then
  warn "${CHOSEN#go} is already installed; reinstalling."
fi

# ---- download, verify, install ----------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log "Downloading $FILENAME"
curl -fSL --progress-bar -o "$TMP/$FILENAME" "$DL_BASE/$FILENAME"

log "Verifying SHA256 checksum"
echo "$SHA256  $TMP/$FILENAME" | sha256sum -c - >/dev/null || die "Checksum verification failed."
ok "Checksum OK"

[[ -n "$INSTALL_DIR" && "$INSTALL_DIR" != "/" ]] || die "Refusing to use INSTALL_DIR='$INSTALL_DIR'."
log "Installing to $INSTALL_DIR/go"
$SUDO mkdir -p "$INSTALL_DIR"
$SUDO rm -rf "$INSTALL_DIR/go"
$SUDO tar -C "$INSTALL_DIR" -xzf "$TMP/$FILENAME"

# ---- PATH setup -------------------------------------------------------------
PROFILE_FILE="/etc/profile.d/golang.sh"
# $INSTALL_DIR/go/bin is not on PATH by default
$SUDO tee "$PROFILE_FILE" >/dev/null <<EOF
# Added by install-go.sh
export PATH="\$PATH:$INSTALL_DIR/go/bin:\$HOME/go/bin"
EOF
$SUDO chmod 0644 "$PROFILE_FILE"

# ---- verify -----------------------------------------------------------------
"$INSTALL_DIR/go/bin/go" version >/dev/null 2>&1 || die "Install finished but the go binary doesn't run."
ok "$("$INSTALL_DIR/go/bin/go" version)"
echo
log "PATH is set via $PROFILE_FILE. Apply it now with:"
echo "    source $PROFILE_FILE"
echo "or open a new login shell. Then check with: go version"
