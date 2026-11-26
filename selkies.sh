#!/usr/bin/env bash
# =============================================================================
# Selkies remote desktop setup (Ubuntu/Debian, run as root)
# Usage:  bash selkies.sh [SERVER_IP[:PORT]]
#         e.g.  bash selkies.sh 7.7.7.7
#               bash selkies.sh 7.7.7.7:8089
# (IP optional; falls back to DEFAULT_SERVER_IP. Port optional; falls back to DEFAULT_PORT)
# Result: https://<SERVER_IP>:<PORT>  (login with the user/password below)
# Includes: XFCE, terminal, Firefox, openssl, systemd services, DARK THEME,
#           crisp SVG icons (Papirus-Dark) + sane icon sizes in Thunar
# =============================================================================
set -euo pipefail

# ----------------------------- CONFIG (edit me) ------------------------------
SELKIES_URL="https://github.com/selkies-project/selkies/releases/download/9232d04/selkies-0.0.0.dev0-x86_64-linux-gnu.tar.gz"
# Server IP / port: pass as the first argument (IP or IP:PORT), otherwise defaults are used.
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

# Thunar icon size. Options: 38, 50, 75, 100, 150  (percent; 75 = ~48px, 100 = ~64px)
THUNAR_ZOOM="75"
# -----------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (e.g. sudo -i, then re-run the command)." >&2
  exit 1
fi

# Parse "IP" or "IP:PORT" from the first argument
ARG="${1:-$DEFAULT_SERVER_IP}"
if [[ "$ARG" == *:* ]]; then
  SERVER_IP="${ARG%%:*}"
  PORT="${ARG##*:}"
else
  SERVER_IP="$ARG"
  PORT="$DEFAULT_PORT"
fi

# Basic IPv4 sanity check (the IP goes into the TLS certificate)
if ! [[ "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "Invalid server IP: '$SERVER_IP'" >&2
  echo "Usage: bash selkies.sh [SERVER_IP[:PORT]]" >&2
  exit 1
fi

# Port sanity check (1-65535)
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  echo "Invalid port: '$PORT' (must be 1-65535)" >&2
  echo "Usage: bash selkies.sh [SERVER_IP[:PORT]]" >&2
  exit 1
fi
echo "==> Using server: $SERVER_IP  port: $PORT"

export DEBIAN_FRONTEND=noninteractive

echo "==> [1/9] Installing packages (desktop, terminal, openssl, audio, fonts, themes)"
apt-get update
apt-get install -y \
  xvfb xfce4 xfce4-terminal dbus-x11 pulseaudio \
  openssl wget curl ca-certificates tar gnupg \
  fonts-noto fonts-liberation \
  gnome-themes-extra adwaita-icon-theme hicolor-icon-theme \
  librsvg2-common gtk-update-icon-cache
# librsvg2-common = SVG loader for GTK. Without it, icons fall back to blurry,
# upscaled bitmaps (this was the cause of the fuzzy folder icons).

# Install themes separately so one missing package doesn't block the other
apt-get install -y arc-theme || echo "    arc-theme not available, will fall back"
apt-get install -y papirus-icon-theme || echo "    papirus-icon-theme not available, will fall back"

echo "==> [2/9] Installing Firefox from Mozilla's apt repo (not the snap)"
install -d -m 0755 /etc/apt/keyrings
wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O /etc/apt/keyrings/packages.mozilla.org.asc
echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
  > /etc/apt/sources.list.d/mozilla.list
printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' \
  > /etc/apt/preferences.d/mozilla
apt-get update
apt-get install -y firefox

echo "==> [3/9] Setting default terminal and browser for XFCE"
update-alternatives --set x-terminal-emulator /usr/bin/xfce4-terminal.wrapper 2>/dev/null || true
# Stop a running desktop first so it doesn't overwrite the config files we write
systemctl stop selkies-desktop 2>/dev/null || true
mkdir -p /root/.config/xfce4
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
for d in /usr/share/icons/*/; do
  [[ -f "$d/index.theme" ]] && gtk-update-icon-cache -f -q "$d" 2>/dev/null || true
done

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

# Firefox: dark browser UI + tell websites the user prefers dark
FF_POLICY_DIR=/usr/lib/firefox/distribution
mkdir -p "$FF_POLICY_DIR"
cat > "$FF_POLICY_DIR/policies.json" <<'EOF'
{
  "policies": {
    "DontCheckDefaultBrowser": true,
    "Preferences": {
      "browser.theme.toolbar-theme": { "Value": 0, "Status": "default" },
      "browser.theme.content-theme": { "Value": 0, "Status": "default" },
      "layout.css.prefers-color-scheme.content-override": { "Value": 0, "Status": "default" }
    }
  }
}
EOF

echo "==> [5/9] Downloading Selkies"
TMP_TAR="$(mktemp /tmp/selkies.XXXXXX.tar.gz)"
wget -q --show-progress "$SELKIES_URL" -O "$TMP_TAR"
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

echo "==> [8/9] Creating systemd services (auto-start on boot)"
cat > /etc/systemd/system/selkies-xvfb.service <<EOF
[Unit]
Description=Xvfb virtual display for Selkies
After=network.target

[Service]
ExecStart=/usr/bin/Xvfb $DISPLAY_NUM -screen 0 $RESOLUTION
Restart=always

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/selkies-desktop.service <<EOF
[Unit]
Description=XFCE desktop session for Selkies
After=selkies-xvfb.service
Requires=selkies-xvfb.service

[Service]
Environment=DISPLAY=$DISPLAY_NUM
Environment=HOME=/root
Environment=GTK_THEME=$GTK_THEME_NAME
ExecStartPre=/bin/sleep 2
ExecStartPre=-/usr/bin/pulseaudio --start --exit-idle-time=-1
ExecStart=/usr/bin/dbus-launch --exit-with-session /usr/bin/startxfce4
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

echo "==> [9/9] Opening firewall port (only if ufw is active)"
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow "$PORT"/tcp
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
echo "Theme:       $GTK_THEME_NAME (icons: $ICON_THEME_NAME, Thunar zoom: ${THUNAR_ZOOM}%)"
echo "(Accept the self-signed certificate warning: Advanced -> Proceed)"
echo
echo "Useful commands:"
echo "  systemctl restart selkies selkies-desktop selkies-xvfb"
echo "  journalctl -u selkies -f"
