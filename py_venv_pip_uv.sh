#!/usr/bin/env bash
# Detects the Linux distro, then sets up Python the modern way:
#   1. system Python + venv + pip from your distro   (so `python3 -m venv` works)
#   2. uv (fast Python package/project/venv manager), verified binary from GitHub
#   3. a Python version of your choice, installed with uv
#      (lists the newest release of each Python line; pick one or type any version)
# Supported: Ubuntu, Debian, Fedora, Rocky/Alma/RHEL/CentOS, Arch (and derivatives)
#
# Usage:
#   sudo ./install-python-uv.sh                  # interactive
#   sudo ./install-python-uv.sh 3.12             # newest 3.12.x
#   sudo ./install-python-uv.sh 3.12.4           # exact version
#   sudo ./install-python-uv.sh latest
#   ./install-python-uv.sh --list                # just show the versions
#
# Options:
#   --no-system-python    don't install distro python3/venv/pip packages
#   --no-python           install uv only, skip the managed Python
#
# Env: UV_VERSION=0.9.0  PY_DIR=/opt/uv/python  BIN_DIR=/usr/local/bin

set -euo pipefail

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: install-python-uv.sh [VERSION | latest | MINOR] [options]

  (no args)           interactive menu
  3.12.4              install that exact Python version
  3.12                install the newest 3.12.x
  latest              install the newest stable Python

Options:
  --list              show the available Python versions and exit
  --no-system-python  skip distro python3/venv/pip packages
  --no-python         install uv only, skip the managed Python
  -h, --help          show this help

Env: UV_VERSION, PY_DIR (default /opt/uv/python), BIN_DIR (default /usr/local/bin)
EOF
}

PY_DIR="${PY_DIR:-/opt/uv/python}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"

REQUESTED=""; LIST_ONLY=0; SYSTEM_PY=1; SKIP_PY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)          usage; exit 0 ;;
    --list)             LIST_ONLY=1 ;;
    --no-system-python) SYSTEM_PY=0 ;;
    --no-python)        SKIP_PY=1 ;;
    -*)                 usage; die "Unknown option: $1" ;;
    *)                  REQUESTED="$1" ;;
  esac
  shift
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

# ---- detect CPU architecture (uv's target triple) ---------------------------
case "$(uname -m)" in
  x86_64|amd64)  UV_TRIPLE="x86_64-unknown-linux-gnu"  ;;
  aarch64|arm64) UV_TRIPLE="aarch64-unknown-linux-gnu" ;;
  *) die "Unsupported CPU architecture: $(uname -m) (uv's Python builds cover x86_64 and aarch64)." ;;
esac

log "Detected: ${PRETTY_NAME:-$DISTRO} (family: $family, target: $UV_TRIPLE)"

# ---- prerequisites ----------------------------------------------------------
install_prereqs() {
  local missing=()
  for c in curl tar jq sha256sum; do
    if ! command -v "$c" >/dev/null 2>&1; then missing+=("$c"); fi
  done
  if [[ ${#missing[@]} -eq 0 ]]; then return 0; fi

  if [[ -z "$SUDO" && $EUID -ne 0 ]]; then
    die "Missing tools (${missing[*]}) and no sudo available to install them."
  fi
  log "Installing prerequisites: ${missing[*]}"
  case "$family" in
    debian)      $SUDO apt-get update -y && $SUDO apt-get install -y curl tar jq coreutils ca-certificates ;;
    fedora|rhel) $SUDO dnf install -y curl tar jq coreutils ca-certificates ;;
    arch)        $SUDO pacman -Sy --noconfirm --needed curl tar jq coreutils ca-certificates ;;
  esac
}
install_prereqs

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- step 1: system python + venv + pip -------------------------------------
install_system_python() {
  log "Installing distro Python with venv and pip"
  case "$family" in
    debian)      $SUDO apt-get update -y && $SUDO apt-get install -y python3 python3-venv python3-pip ;;
    fedora|rhel) $SUDO dnf install -y python3 python3-pip ;;
    arch)        $SUDO pacman -Sy --noconfirm --needed python python-pip ;;
  esac
}

# ---- step 2: uv (download + verify, then install) ---------------------------
UV_BIN=""   # path to a usable uv binary

fetch_uv() {
  local ver="${UV_VERSION:-}"
  if [[ -z "$ver" ]]; then
    ver="$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/astral-sh/uv/releases/latest | sed 's|.*/||')"
  fi
  [[ -n "$ver" && "$ver" != "latest" ]] || die "Could not determine the latest uv version."
  ver="${ver#v}"

  local file="uv-${UV_TRIPLE}.tar.gz"
  local base="https://github.com/astral-sh/uv/releases/download/${ver}"
  log "Downloading uv ${ver}"
  curl -fsSL -o "$TMP/$file"        "$base/$file"
  curl -fsSL -o "$TMP/$file.sha256" "$base/$file.sha256"

  ( cd "$TMP" && sha256sum -c "$file.sha256" >/dev/null ) || die "uv checksum verification failed."
  tar -xzf "$TMP/$file" -C "$TMP"
  UV_BIN="$TMP/uv-${UV_TRIPLE}/uv"
  [[ -x "$UV_BIN" ]] || die "uv binary not found in the archive."
  ok "uv ${ver} downloaded and verified"
}

install_uv() {
  log "Installing uv to $BIN_DIR"
  $SUDO mkdir -p "$BIN_DIR"
  $SUDO install -m 0755 "$TMP/uv-${UV_TRIPLE}/uv"  "$BIN_DIR/uv"
  $SUDO install -m 0755 "$TMP/uv-${UV_TRIPLE}/uvx" "$BIN_DIR/uvx"
  UV_BIN="$BIN_DIR/uv"
}

# ---- step 3: python versions via uv -----------------------------------------
LIST_JSON=""; ALL_JSON=""; VERSIONS=()

load_versions() {
  # Newest release of each Python line (stable CPython only), newest first.
  LIST_JSON="$("$UV_BIN" python list --only-downloads --output-format json)" \
    || die "uv could not list Python versions."
  ALL_JSON="$("$UV_BIN" python list --only-downloads --all-versions --output-format json)" \
    || die "uv could not list Python versions."

  mapfile -t VERSIONS < <(jq -r '
    [.[] | select(.implementation == "cpython" and .variant == "default"
                  and (.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")))]
    | sort_by([.version_parts.major, .version_parts.minor, .version_parts.patch]) | reverse
    | .[0:10] | .[].version' <<<"$LIST_JSON")
  [[ ${#VERSIONS[@]} -gt 0 ]] || die "Could not parse the Python version list."
}

# Accepts: latest | 3 | 3.12 | 3.12.4 | v3.12.4 | python3.12
resolve_version() {
  local input="${1#python}"
  input="${input#v}"
  if [[ "${input,,}" == "latest" ]]; then
    echo "${VERSIONS[0]}"
  elif [[ "$input" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    jq -r --arg p "${input}." '
      [.[] | select(.implementation == "cpython" and .variant == "default"
                    and (.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
                    and (.version | startswith($p)))]
      | sort_by([.version_parts.major, .version_parts.minor, .version_parts.patch]) | reverse
      | .[0].version // empty' <<<"$ALL_JSON"
  else
    jq -r --arg v "$input" '
      [.[] | select(.implementation == "cpython" and .variant == "default" and .version == $v)]
      | .[0].version // empty' <<<"$ALL_JSON"
  fi
}

print_list() {
  echo
  echo "Newest release of each Python line:"
  local i=1 v tag
  for v in "${VERSIONS[@]}"; do
    tag=""
    if [[ $i -eq 1 ]]; then tag=" (latest)"; fi
    printf '  %2d) %s%s\n' "$i" "$v" "$tag"
    i=$((i + 1))
  done
  echo
  return 0
}

# ---- run: list-only mode ----------------------------------------------------
if [[ $LIST_ONLY -eq 1 ]]; then
  fetch_uv
  load_versions
  print_list
  exit 0
fi

# ---- run: install -----------------------------------------------------------
if [[ $SYSTEM_PY -eq 1 ]]; then install_system_python; fi
fetch_uv
install_uv

CHOSEN=""
if [[ $SKIP_PY -eq 0 ]]; then
  load_versions
  if [[ -n "$REQUESTED" ]]; then
    CHOSEN="$(resolve_version "$REQUESTED")"
    [[ -n "$CHOSEN" ]] || die "No Python build found for '$REQUESTED' on $UV_TRIPLE."
  else
    [[ -t 0 ]] || die "No version given and no terminal for the menu. Pass one: ./install-python-uv.sh latest"
    print_list
    while [[ -z "$CHOSEN" ]]; do
      read -rp "Pick 1-${#VERSIONS[@]}, 'latest', a line (e.g. 3.12) or a version (e.g. 3.12.4), s to skip, q to quit [latest]: " answer
      answer="${answer:-latest}"
      if [[ "$answer" == "q" || "$answer" == "Q" ]]; then
        log "Cancelled."; exit 0
      elif [[ "$answer" == "s" || "$answer" == "S" || "${answer,,}" == "skip" ]]; then
        break
      elif [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= ${#VERSIONS[@]} )); then
        CHOSEN="${VERSIONS[$((answer - 1))]}"
      else
        CHOSEN="$(resolve_version "$answer")"
        if [[ -z "$CHOSEN" ]]; then warn "No Python build found for '$answer'. Try again."; fi
      fi
    done
  fi
fi

PY_EXE=""
if [[ -n "$CHOSEN" ]]; then
  log "Installing Python $CHOSEN with uv"
  $SUDO mkdir -p "$PY_DIR" "$BIN_DIR"
  $SUDO env UV_PYTHON_INSTALL_DIR="$PY_DIR" UV_PYTHON_BIN_DIR="$BIN_DIR" \
    "$UV_BIN" python install "$CHOSEN"

  [[ "$CHOSEN" =~ ^([0-9]+\.[0-9]+) ]]
  MINOR="${BASH_REMATCH[1]}"
  PY_EXE="$BIN_DIR/python$MINOR"
  if ! PY_OUT="$("$PY_EXE" --version 2>&1)"; then
    die "Python installed but doesn't run: $PY_OUT"
  fi
  ok "$PY_OUT  ($PY_EXE)"

  if [[ -x "/usr/bin/python$MINOR" && "$BIN_DIR" != "/usr/bin" ]]; then
    warn "Distro Python $MINOR also exists at /usr/bin/python$MINOR; the uv one in $BIN_DIR now comes first in PATH."
  fi
else
  log "Skipping uv-managed Python."
fi

# ---- summary ----------------------------------------------------------------
echo
log "Summary"
echo "  uv      : $("$UV_BIN" --version)"
if command -v python3 >/dev/null 2>&1; then echo "  python3 : $(python3 --version 2>&1) (first on PATH: $(command -v python3))"; fi
if [[ -n "$PY_EXE" ]]; then echo "  uv py   : $("$PY_EXE" --version 2>&1) ($PY_EXE)"; fi
echo
log "Quick start:"
echo "    uv venv --python ${MINOR:-3.12} .venv && source .venv/bin/activate"
echo "    uv pip install requests          # or: uv add requests  (inside a uv project)"
echo "    uv python list --only-installed  # see installed interpreters"
ok "Done."
