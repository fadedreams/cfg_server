#!/usr/bin/env bash
# =============================================================================
# Selkies remote desktop setup - works on most systemd + glibc x86_64 Linux
# distros (run as root).
#
# Supported package managers / families:
#   apt     Debian, Ubuntu, Mint, Pop!_OS, Kali, Raspberry Pi OS (x86_64) ...
#   dnf/yum Fedora, RHEL, Rocky, AlmaLinux, CentOS Stream, Oracle Linux, Amazon Linux
#   pacman  Arch, Manjaro, EndeavourOS ...
#   zypper  openSUSE Leap / Tumbleweed, SLES
# NOT supported: Alpine (musl), non-systemd distros, ARM (the Selkies build is x86_64).
#
# Usage:  bash selkies.sh [[SERVER_IP]:PORT]
#         bash selkies.sh                 -> auto-detected public IP, default port
#         bash selkies.sh :8088           -> auto-detected public IP, port 8088
#         bash selkies.sh 8088            -> same as :8088
#         bash selkies.sh 7.7.7.7         -> your IP, default port
#         bash selkies.sh 7.7.7.7:8088    -> your IP, your port
# If no IP is given, the public IPv4 is auto-detected (falls back to DEFAULT_SERVER_IP).
# Result: https://<SERVER_IP>:<PORT>  (login with the user/password below)
# Includes: XFCE, terminal, Firefox as DEFAULT browser (dark UI + dark pages), openssl,
#           systemd services, DARK THEME, crisp SVG icons (Papirus-Dark)
#           + sane icon sizes in Thunar
# =============================================================================
set -euo pipefail

# ----------------------------- CONFIG (edit me) ------------------------------
SELKIES_URL="https://github.com/selkies-project/selkies/releases/download/9232d04/selkies-0.0.0.dev0-x86_64-linux-gnu.tar.gz"
# Fallbacks used only when nothing is passed / auto-detect fails.
DEFAULT_SERVER_IP="185.179.152.192"
DEFAULT_PORT="8080"
AUTH_USER="admin"
AUTH_PASS="admin"
RESOLUTION="1920x1080x24"
DISPLAY_NUM=":1"
INSTALL_DIR="/opt/selkies"
CERT_DIR="/etc/selkies"

# Dark theme (Arc-Dark is preferred; falls back to Adwaita-dark if unavailable)
GTK_THEME_NAME="Arc-Dark"
ICON_THEME_NAME="Papirus-Dark"

# Force dark mode on web pages in Firefox (1 = on, 0 = follow the page's own style)
FIREFOX_DARK_PAGES="1"

# Thunar icon size. Options: 38, 50, 75, 100, 150  (percent; 75 = ~48px, 100 = ~64px)
THUNAR_ZOOM="75"
# -----------------------------------------------------------------------------

die() { echo "ERROR: $*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
  die "Please run as root (e.g. sudo -i, then re-run the command)."
fi

# ------------------------- environment sanity checks -------------------------
[[ "$(uname -m)" == "x86_64" ]] || die "This Selkies build is x86_64 only (you have $(uname -m))."
if ldd --version 2>&1 | grep -qi musl; then
  die "musl-based distro (e.g. Alpine) detected. The Selkies build needs glibc."
fi
if ! command -v systemctl >/dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
  die "systemd is required (services are installed as systemd units)."
fi

# ----------------------------- distro detection ------------------------------
OS_ID="unknown"; OS_LIKE=""; OS_VERSION_ID=""
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"; OS_LIKE="${ID_LIKE:-}"; OS_VERSION_ID="${VERSION_ID:-}"
fi

PM=""
if   command -v apt-get >/dev/null 2>&1; then PM="apt"
elif command -v dnf     >/dev/null 2>&1; then PM="dnf"
elif command -v yum     >/dev/null 2>&1; then PM="yum"
elif command -v pacman  >/dev/null 2>&1; then PM="pacman"
elif command -v zypper  >/dev/null 2>&1; then PM="zypper"
else die "No supported package manager found (apt, dnf, yum, pacman, zypper)."; fi
echo "==> Detected: $OS_ID ${OS_VERSION_ID} (package manager: $PM)"

export DEBIAN_FRONTEND=noninteractive

# ------------------------ package manager abstraction ------------------------
pm_update() {
  case "$PM" in
    apt)    apt-get update ;;
    dnf)    dnf -y makecache ;;
    yum)    yum -y makecache ;;
    pacman) pacman -Syu --noconfirm ;;   # full upgrade: partial upgrades break Arch
    zypper) zypper --non-interactive --gpg-auto-import-keys refresh ;;
  esac
}
pm_install() {   # hard install: fails the script if it fails
  case "$PM" in
    apt)    apt-get install -y "$@" ;;
    dnf)    dnf install -y --allowerasing "$@" ;;
    yum)    yum install -y "$@" ;;
    pacman) pacman -S --noconfirm --needed --ask=4 "$@" ;;
    zypper) zypper --non-interactive install "$@" ;;
  esac
}
pm_try() {       # soft install: one package at a time, never aborts
  local p
  for p in "$@"; do
    pm_install "$p" >/dev/null 2>&1 && echo "    installed: $p" || echo "    skipped (not available): $p"
  done
}
pm_remove() {    # one package at a time so an unknown/uninstalled name can't abort the rest
  local p
  for p in "$@"; do
    case "$PM" in
      apt)    dpkg -s "$p" >/dev/null 2>&1 && apt-get purge -y "$p" ;;
      dnf)    rpm -q "$p" >/dev/null 2>&1 && dnf remove -y "$p" ;;
      yum)    rpm -q "$p" >/dev/null 2>&1 && yum remove -y "$p" ;;
      pacman) pacman -Qi "$p" >/dev/null 2>&1 && pacman -Rns --noconfirm "$p" ;;
      zypper) rpm -q "$p" >/dev/null 2>&1 && zypper --non-interactive remove "$p" ;;
    esac || true
  done
}
fetch() {        # fetch URL OUTPUT  (curl or wget, whichever exists)
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"
  else wget -q "$1" -O "$2"; fi
}

# ------------------------- parse the first argument --------------------------
# "", "IP", "IP:PORT", ":PORT" or "PORT"
ARG="${1:-}"
SERVER_IP=""
PORT="$DEFAULT_PORT"
if [[ "$ARG" == *:* ]]; then
  SERVER_IP="${ARG%%:*}"
  PORT="${ARG##*:}"
elif [[ "$ARG" =~ ^[0-9]+$ ]]; then
  PORT="$ARG"                 # digits only = a port, not an IP
elif [[ -n "$ARG" ]]; then
  SERVER_IP="$ARG"
fi
[[ -z "$PORT" ]] && PORT="$DEFAULT_PORT"

echo "==> [1/9] Installing packages (desktop, terminal, openssl, audio, fonts, themes)"
pm_update

# Core tools needed before anything else (curl/wget/openssl/tar).
# Skipped when already present (avoids curl vs curl-minimal conflicts on RHEL/Fedora).
need_tools=()
command -v openssl >/dev/null 2>&1 || need_tools+=(openssl)
command -v tar     >/dev/null 2>&1 || need_tools+=(tar)
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then need_tools+=(curl); fi
if (( ${#need_tools[@]} )); then pm_install "${need_tools[@]}"; fi
case "$PM" in apt) pm_try ca-certificates gnupg wget ;; *) pm_try ca-certificates ;; esac

# No IP given -> auto-detect public IPv4
if [[ -z "$SERVER_IP" ]]; then
  DETECTED=""
  for url in ifconfig.me api.ipify.org icanhazip.com; do
    if command -v curl >/dev/null 2>&1; then
      DETECTED="$(curl -4 -fsS --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    else
      DETECTED="$(wget -4 -qO- --timeout=8 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    fi
    if [[ "$DETECTED" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then break; fi
    DETECTED=""
  done
  if [[ -n "$DETECTED" ]]; then
    SERVER_IP="$DETECTED"
    echo "==> Auto-detected public IP: $SERVER_IP"
  else
    SERVER_IP="$DEFAULT_SERVER_IP"
    echo "==> Could not auto-detect public IP, using default: $SERVER_IP"
  fi
fi

# Basic IPv4 sanity check (the IP goes into the TLS certificate)
if ! [[ "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  die "Invalid server IP: '$SERVER_IP'  (usage: bash selkies.sh [[SERVER_IP]:PORT])"
fi
# Port sanity check (1-65535)
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  die "Invalid port: '$PORT' (must be 1-65535)"
fi
echo "==> Using server: $SERVER_IP  port: $PORT"

# Desktop + virtual display (hard requirements) and cosmetic extras (soft)
case "$PM" in
  apt)
    pm_install xvfb xfce4 xfce4-terminal dbus-x11
    pm_try pulseaudio fonts-noto fonts-liberation gnome-themes-extra adwaita-icon-theme \
           hicolor-icon-theme librsvg2-common gtk-update-icon-cache arc-theme papirus-icon-theme
    ;;
  dnf|yum)
    # RHEL-family: XFCE lives in EPEL
    if [[ "$OS_ID $OS_LIKE" =~ (rhel|centos|rocky|almalinux|ol|amzn) ]] && ! [[ "$OS_ID" == "fedora" ]]; then
      echo "    Enabling EPEL (needed for XFCE on RHEL-family)"
      pm_try epel-release
      command -v crb >/dev/null 2>&1 && crb enable >/dev/null 2>&1 || true
      command -v dnf >/dev/null 2>&1 && dnf config-manager --set-enabled crb >/dev/null 2>&1 || true
      command -v dnf >/dev/null 2>&1 && dnf config-manager --set-enabled powertools >/dev/null 2>&1 || true
      pm_update
    fi
    pm_install xorg-x11-server-Xvfb xfce4-session xfce4-panel xfce4-settings xfdesktop xfwm4 \
               xfce4-terminal Thunar
    pm_try dbus-x11 xfce4-appfinder pulseaudio pulseaudio-utils google-noto-sans-fonts \
           liberation-fonts adwaita-icon-theme hicolor-icon-theme librsvg2 gtk-update-icon-cache \
           gnome-themes-extra arc-theme papirus-icon-theme
    ;;
  pacman)
    pm_install xorg-server-xvfb xfce4 xfce4-terminal dbus
    pm_try pulseaudio noto-fonts ttf-liberation gnome-themes-extra adwaita-icon-theme \
           hicolor-icon-theme librsvg gtk-update-icon-cache arc-gtk-theme papirus-icon-theme
    ;;
  zypper)
    pm_try xorg-x11-server-Xvfb xorg-x11-server-extra
    pm_install xfce4-session xfce4-panel xfce4-settings xfdesktop xfwm4 xfce4-terminal Thunar
    pm_try dbus-1-x11 pulseaudio noto-sans-fonts liberation-fonts adwaita-icon-theme \
           hicolor-icon-theme gdk-pixbuf-loader-rsvg gtk3-tools gnome-themes-extra \
           arc-theme papirus-icon-theme
    ;;
esac
# Without an SVG loader, icons fall back to blurry upscaled bitmaps (fuzzy folder icons).

# Resolve the binaries we need for the systemd units
XVFB_BIN="$(command -v Xvfb || true)"
STARTXFCE_BIN="$(command -v startxfce4 || true)"
[[ -n "$XVFB_BIN"      ]] || die "Xvfb was not installed - install your distro's Xvfb package and re-run."
[[ -n "$STARTXFCE_BIN" ]] || die "startxfce4 was not installed - install XFCE and re-run."
command -v xfce4-terminal >/dev/null 2>&1 || die "xfce4-terminal was not installed."

# dbus: dbus-launch (dbus-x11) if present, otherwise dbus-run-session
if command -v dbus-launch >/dev/null 2>&1; then
  DBUS_CMD="$(command -v dbus-launch) --exit-with-session"
elif command -v dbus-run-session >/dev/null 2>&1; then
  DBUS_CMD="$(command -v dbus-run-session) --"
else
  die "Neither dbus-launch nor dbus-run-session found."
fi

# Audio: classic PulseAudio (or pipewire-pulse providing the same socket)
PULSE_BIN="$(command -v pulseaudio || true)"
[[ -n "$PULSE_BIN" ]] || echo "    NOTE: pulseaudio not installed - the desktop will have no audio."

echo "==> [2/9] Installing Firefox"
# Falkon is NOT installed by this script anymore. If an earlier run installed it
# (or Epiphany), uninstall it and wipe its leftovers so Firefox is the only browser.
pm_remove falkon qt5-gtk-platformtheme epiphany-browser epiphany >/dev/null 2>&1 || true
rm -rf /root/.config/falkon /root/.local/share/falkon /root/.cache/falkon 2>/dev/null || true

FIREFOX_BIN=""
case "$PM" in
  apt)
    # On Ubuntu the distro "firefox" is a snap stub that doesn't work as a root
    # systemd service. Mozilla's own .deb repo works on Ubuntu and Debian.
    install -d -m 0755 /etc/apt/keyrings
    if fetch https://packages.mozilla.org/apt/repo-signing-key.gpg /etc/apt/keyrings/packages.mozilla.org.asc; then
      echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
        > /etc/apt/sources.list.d/mozilla.list
      cat > /etc/apt/preferences.d/mozilla <<'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF
      apt-get update
      pm_install firefox && FIREFOX_BIN="$(command -v firefox || true)"
    fi
    if [[ -z "$FIREFOX_BIN" ]]; then
      echo "    Mozilla repo failed, trying firefox-esr from the distro repos"
      pm_install firefox-esr && FIREFOX_BIN="$(command -v firefox-esr || true)"
    fi
    ;;
  dnf|yum|pacman)
    pm_install firefox && FIREFOX_BIN="$(command -v firefox || true)" ;;
  zypper)
    pm_install MozillaFirefox && FIREFOX_BIN="$(command -v firefox || true)" ;;
esac
if [[ -z "$FIREFOX_BIN" ]]; then
  echo "    WARNING: Firefox could not be installed. The desktop will still work;"
  echo "             install a browser manually afterwards."
fi

echo "==> [3/9] Setting default terminal and browser (Firefox) for XFCE"
if [[ -n "$FIREFOX_BIN" ]]; then
  # Debian's firefox-esr has no plain "firefox" command; XFCE's helper expects one
  if [[ "$(basename "$FIREFOX_BIN")" == "firefox-esr" && ! -e /usr/local/bin/firefox ]]; then
    ln -s "$FIREFOX_BIN" /usr/local/bin/firefox
  fi
  # Find Firefox's .desktop file name
  FIREFOX_DESKTOP=""
  for d in firefox.desktop firefox-esr.desktop org.mozilla.firefox.desktop; do
    if [[ -f "/usr/share/applications/$d" ]]; then FIREFOX_DESKTOP="$d"; break; fi
  done
  [[ -n "$FIREFOX_DESKTOP" ]] || FIREFOX_DESKTOP="firefox.desktop"

  # (a) Debian-family alternatives
  if command -v update-alternatives >/dev/null 2>&1; then
    for alt in x-www-browser gnome-www-browser; do
      update-alternatives --install /usr/bin/$alt $alt "$FIREFOX_BIN" 200 2>/dev/null || true
      update-alternatives --set $alt "$FIREFOX_BIN" 2>/dev/null || true
    done
  fi
  # (b) XDG default applications (what links/open-with use on every distro)
  mkdir -p /root/.config
  cat > /root/.config/mimeapps.list <<EOF
[Default Applications]
x-scheme-handler/http=$FIREFOX_DESKTOP
x-scheme-handler/https=$FIREFOX_DESKTOP
x-scheme-handler/about=$FIREFOX_DESKTOP
x-scheme-handler/unknown=$FIREFOX_DESKTOP
text/html=$FIREFOX_DESKTOP
application/xhtml+xml=$FIREFOX_DESKTOP
application/x-extension-htm=$FIREFOX_DESKTOP
application/x-extension-html=$FIREFOX_DESKTOP
application/x-extension-xhtml=$FIREFOX_DESKTOP

[Added Associations]
x-scheme-handler/http=$FIREFOX_DESKTOP;
x-scheme-handler/https=$FIREFOX_DESKTOP;
text/html=$FIREFOX_DESKTOP;
EOF
  if command -v xdg-settings >/dev/null 2>&1; then
    HOME=/root xdg-settings set default-web-browser "$FIREFOX_DESKTOP" 2>/dev/null || true
  fi
  if command -v xdg-mime >/dev/null 2>&1; then
    HOME=/root xdg-mime default "$FIREFOX_DESKTOP" x-scheme-handler/http x-scheme-handler/https text/html 2>/dev/null || true
  fi
fi
if command -v update-alternatives >/dev/null 2>&1; then
  update-alternatives --set x-terminal-emulator /usr/bin/xfce4-terminal.wrapper 2>/dev/null || true
fi
# Stop a running desktop first so it doesn't overwrite the config files we write
systemctl stop selkies-desktop 2>/dev/null || true
mkdir -p /root/.config/xfce4
# (c) XFCE's own "Preferred Applications" (panel launcher, Thunar, exo-open)
cat > /root/.config/xfce4/helpers.rc <<'EOF'
TerminalEmulator=xfce4-terminal
WebBrowser=firefox
EOF

echo "==> [4/9] Applying dark theme everywhere (GTK2/GTK3, XFCE, Thunar, terminal, Firefox)"
# Fall back if Arc-Dark / Papirus are not installed
if [[ ! -d /usr/share/themes/$GTK_THEME_NAME ]]; then
  echo "    $GTK_THEME_NAME not found, falling back to Adwaita-dark"
  GTK_THEME_NAME="Adwaita-dark"
fi
if [[ ! -d /usr/share/icons/$ICON_THEME_NAME ]]; then
  echo "    $ICON_THEME_NAME not found, falling back to Adwaita"
  ICON_THEME_NAME="Adwaita"
fi

# Rebuild icon caches so the new theme is picked up cleanly
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  for d in /usr/share/icons/*/; do
    [[ -f "$d/index.theme" ]] && gtk-update-icon-cache -f -q "$d" 2>/dev/null || true
  done
fi

# GTK3 apps (Thunar, panel, terminal, Firefox UI, etc.)
mkdir -p /root/.config/gtk-3.0
cat > /root/.config/gtk-3.0/settings.ini <<EOF
[Settings]
gtk-theme-name=$GTK_THEME_NAME
gtk-icon-theme-name=$ICON_THEME_NAME
gtk-application-prefer-dark-theme=1
gtk-font-name=Sans 10
gtk-xft-antialias=1
gtk-xft-hinting=1
gtk-xft-hintstyle=hintslight
gtk-xft-rgba=rgb
gtk-xft-dpi=98304
EOF

# GTK2 apps
cat > /root/.gtkrc-2.0 <<EOF
gtk-theme-name="$GTK_THEME_NAME"
gtk-icon-theme-name="$ICON_THEME_NAME"
gtk-font-name="Sans 10"
EOF

# XFCE settings daemon (applies theme to the whole session)
XFCONF_DIR=/root/.config/xfce4/xfconf/xfce-perchannel-xml
mkdir -p "$XFCONF_DIR"
cat > "$XFCONF_DIR/xsettings.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="$GTK_THEME_NAME"/>
    <property name="IconThemeName" type="string" value="$ICON_THEME_NAME"/>
  </property>
  <property name="Xft" type="empty">
    <property name="DPI" type="int" value="96"/>
    <property name="Antialias" type="int" value="1"/>
    <property name="Hinting" type="int" value="1"/>
    <property name="HintStyle" type="string" value="hintslight"/>
    <property name="RGBA" type="string" value="rgb"/>
  </property>
</channel>
EOF

# Window manager (title bars / borders)
cat > "$XFCONF_DIR/xfwm4.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="$GTK_THEME_NAME"/>
  </property>
</channel>
EOF

# Thunar: icon view at a smaller, crisp size (default is large and gets upscaled)
cat > "$XFCONF_DIR/thunar.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="thunar" version="1.0">
  <property name="default-view" type="string" value="ThunarIconView"/>
  <property name="last-icon-view-zoom-level" type="string" value="THUNAR_ZOOM_LEVEL_${THUNAR_ZOOM}_PERCENT"/>
  <property name="last-view" type="string" value="ThunarIconView"/>
</channel>
EOF

# Dark terminal colors
mkdir -p /root/.config/xfce4/terminal
cat > /root/.config/xfce4/terminal/terminalrc <<'EOF'
[Configuration]
ColorForeground=#d3dae3
ColorBackground=#1e2028
ColorCursor=#d3dae3
MiscAlwaysShowTabs=FALSE
EOF

# Firefox: dark browser UI + dark web pages via an enterprise policy file.
#   ui.systemUsesDarkTheme = 1                  -> Firefox UI (and "auto" pages) go dark
#   prefers-color-scheme.content-override = 0   -> force dark for web pages (2 = follow system)
#   Status "default" means you can still change these in about:config / Settings.
if [[ "$FIREFOX_DARK_PAGES" == "1" ]]; then CONTENT_OVERRIDE=0; else CONTENT_OVERRIDE=2; fi
POLICY_JSON="$(cat <<EOF
{
  "policies": {
    "DisableAppUpdate": true,
    "DisableTelemetry": true,
    "DontCheckDefaultBrowser": true,
    "OverrideFirstRunPage": "",
    "OverridePostUpdatePage": "",
    "NoDefaultBookmarks": true,
    "Preferences": {
      "ui.systemUsesDarkTheme": { "Value": 1, "Status": "default" },
      "layout.css.prefers-color-scheme.content-override": { "Value": $CONTENT_OVERRIDE, "Status": "default" },
      "extensions.activeThemeID": { "Value": "firefox-compact-dark@mozilla.org", "Status": "default" },
      "browser.theme.toolbar-theme": { "Value": 0, "Status": "default" },
      "browser.theme.content-theme": { "Value": 0, "Status": "default" }
    }
  }
}
EOF
)"
# Distros differ in where Firefox reads policies from: write to /etc and to every
# installed Firefox "distribution" directory so all of them are covered.
mkdir -p /etc/firefox/policies
echo "$POLICY_JSON" > /etc/firefox/policies/policies.json
for fdir in /usr/lib/firefox* /usr/lib64/firefox* /opt/firefox*; do
  if [[ -d "$fdir" ]]; then
    mkdir -p "$fdir/distribution"
    echo "$POLICY_JSON" > "$fdir/distribution/policies.json"
  fi
done

echo "==> [5/9] Downloading Selkies"
TMP_TAR="$(mktemp /tmp/selkies.XXXXXX.tar.gz)"
fetch "$SELKIES_URL" "$TMP_TAR"
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
tar -xzf "$TMP_TAR" -C "$INSTALL_DIR" --strip-components=1
rm -f "$TMP_TAR"
chmod +x "$INSTALL_DIR/bin/selkies"

echo "==> [6/9] Generating self-signed HTTPS certificate for $SERVER_IP"
mkdir -p "$CERT_DIR"
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout "$CERT_DIR/selkies.key" -out "$CERT_DIR/selkies.crt" \
  -subj "/CN=$SERVER_IP" \
  -addext "subjectAltName=IP:$SERVER_IP"
chmod 600 "$CERT_DIR/selkies.key"

echo "==> [7/9] Writing credentials file"
cat > "$CERT_DIR/selkies.env" <<EOF
DISPLAY=$DISPLAY_NUM
SELKIES_BASIC_AUTH_USER=$AUTH_USER
SELKIES_BASIC_AUTH_PASSWORD=$AUTH_PASS
EOF
chmod 600 "$CERT_DIR/selkies.env"

# SELinux (Fedora/RHEL/openSUSE): make sure systemd may execute the binary in /opt
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
  echo "    SELinux is enforcing - labelling $INSTALL_DIR and $CERT_DIR"
  chcon -R -t bin_t "$INSTALL_DIR" 2>/dev/null || true
  restorecon -R "$CERT_DIR" 2>/dev/null || true
fi

echo "==> [8/9] Creating systemd services (auto-start on boot)"

cat > /etc/systemd/system/selkies-xvfb.service <<EOF
[Unit]
Description=Xvfb virtual display for Selkies
After=network.target

[Service]
ExecStart=$XVFB_BIN $DISPLAY_NUM -screen 0 $RESOLUTION
Restart=always

[Install]
WantedBy=multi-user.target
EOF

PULSE_LINE=""
[[ -n "$PULSE_BIN" ]] && PULSE_LINE="ExecStartPre=-$PULSE_BIN --start --exit-idle-time=-1"

cat > /etc/systemd/system/selkies-desktop.service <<EOF
[Unit]
Description=XFCE desktop session for Selkies
After=selkies-xvfb.service
Requires=selkies-xvfb.service

[Service]
Environment=DISPLAY=$DISPLAY_NUM
Environment=HOME=/root
Environment=GTK_THEME=$GTK_THEME_NAME
# Firefox: software rendering (no GPU in Xvfb)
Environment=MOZ_WEBRENDER=0
Environment=LIBGL_ALWAYS_SOFTWARE=1
ExecStartPre=/bin/sleep 2
$PULSE_LINE
ExecStart=$DBUS_CMD $STARTXFCE_BIN
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/selkies.service <<EOF
[Unit]
Description=Selkies web remote desktop
After=selkies-desktop.service
Requires=selkies-xvfb.service

[Service]
EnvironmentFile=$CERT_DIR/selkies.env
Environment=HOME=/root
WorkingDirectory=$INSTALL_DIR
ExecStartPre=/bin/sleep 4
ExecStart=$INSTALL_DIR/bin/selkies --addr=0.0.0.0 --port=$PORT --enable_https=true --https_cert=$CERT_DIR/selkies.crt --https_key=$CERT_DIR/selkies.key
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable selkies-xvfb selkies-desktop selkies
systemctl restart selkies-xvfb selkies-desktop selkies

echo "==> [9/9] Opening firewall port (ufw / firewalld, only if active)"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "$PORT"/tcp
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="$PORT"/tcp
  firewall-cmd --reload
fi

sleep 6
echo
echo "---------------------------------------------------------------"
systemctl --no-pager --lines=0 status selkies-xvfb selkies-desktop selkies | grep -E "●|Active:" || true
echo "---------------------------------------------------------------"
ss -tlnp | grep ":$PORT" || echo "WARNING: nothing is listening on $PORT yet - check: journalctl -u selkies -n 50"
echo
echo "Done. Open:  https://$SERVER_IP:$PORT"
echo "Login:       $AUTH_USER / $AUTH_PASS"
echo "Distro:      $OS_ID $OS_VERSION_ID ($PM)"
echo "Theme:       $GTK_THEME_NAME (icons: $ICON_THEME_NAME, Thunar zoom: ${THUNAR_ZOOM}%)"
echo "Browser:     Firefox (dark UI; dark web pages: $([[ "$FIREFOX_DARK_PAGES" == "1" ]] && echo on || echo off))"
echo "(Accept the self-signed certificate warning: Advanced -> Proceed)"
echo "NOTE: if your cloud provider has its own firewall/security group, open TCP $PORT there too."
echo
echo "Useful commands:"
echo "  systemctl restart selkies selkies-desktop selkies-xvfb"
echo "  journalctl -u selkies -f"
