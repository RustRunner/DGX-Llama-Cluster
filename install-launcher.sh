#!/bin/bash

##############################################################
# DGX Spark llama.cpp Cluster — Desktop Launcher Installer
#
# Usage:
#   ./install-launcher.sh            Install launcher + dock icon
#   ./install-launcher.sh --remove   Remove launcher + dock icon
#
# Any user on a DGX Spark can run this; no root required.
# Requires setup_node1_llama.sh to have been run first
# (it installs start-everything.sh to /usr/local/bin).
##############################################################

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# ── Paths ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_IMG="$SCRIPT_DIR/assets/dgx-spark-stack.png"
ICON_DIR="$HOME/.local/share/icons/hicolor"
APP_DIR="$HOME/.local/share/applications"
DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || echo "$HOME/Desktop")"
APP_ID="llama-cluster"

# ── Helper: print a step banner ──────────────────────────────
step() { echo -e "\n${GREEN}${BOLD}[$1] $2${NC}"; }

# ── Uninstall mode ───────────────────────────────────────────
if [[ "${1:-}" == "--remove" ]]; then
    echo -e "${BOLD}Removing DGX Spark Cluster launcher...${NC}"
    rm -f "$DESKTOP_DIR/$APP_ID.desktop"
    rm -f "$APP_DIR/$APP_ID.desktop"
    for size in 256 128 64 48; do
        rm -f "$ICON_DIR/${size}x${size}/apps/$APP_ID.png"
    done
    update-desktop-database "$APP_DIR" 2>/dev/null || true
    gtk-update-icon-cache -f -t "$ICON_DIR" 2>/dev/null || true

    # Remove from dock
    CURRENT_FAVS=$(gsettings get org.gnome.shell favorite-apps 2>/dev/null || echo "[]")
    if echo "$CURRENT_FAVS" | grep -q "'$APP_ID.desktop'"; then
        NEW_FAVS=$(echo "$CURRENT_FAVS" | sed "s/, '$APP_ID.desktop'//; s/'$APP_ID.desktop', //; s/'$APP_ID.desktop'//")
        gsettings set org.gnome.shell favorite-apps "$NEW_FAVS" 2>/dev/null || true
    fi

    echo -e "${GREEN}Removed.${NC}"
    exit 0
fi

# ── Step 0: Preflight checks ────────────────────────────────
step "0/4" "Preflight checks"

if [ ! -f "$SOURCE_IMG" ]; then
    echo -e "${RED}Error: Icon image not found at${NC}"
    echo "  $SOURCE_IMG"
    echo "Make sure assets/dgx-spark-stack.png exists next to this script."
    exit 1
fi

# Auto-install Pillow if missing
if ! python3 -c "from PIL import Image" 2>/dev/null; then
    echo -e "${YELLOW}Python Pillow not found — installing...${NC}"
    if pip3 install --user Pillow 2>/dev/null; then
        echo "  Pillow installed via pip"
    elif sudo apt-get install -y python3-pil 2>/dev/null; then
        echo "  Pillow installed via apt"
    else
        echo -e "${RED}Error: Could not install Pillow automatically.${NC}"
        echo "  Please install it manually:  pip3 install Pillow"
        exit 1
    fi
fi

# Check that start-everything.sh is in PATH (installed by setup_node1_llama.sh)
if ! command -v start-everything.sh &>/dev/null; then
    echo -e "${YELLOW}Warning: start-everything.sh not found in PATH.${NC}"
    echo "  Run setup_node1_llama.sh first to install it to /usr/local/bin."
    echo "  The launcher icon will be created, but won't work until the script is installed."
else
    echo "  start-everything.sh: found at $(command -v start-everything.sh)"
fi

echo "  All checks passed"

# ── Step 1: Generate freedesktop-compliant icons ─────────────
step "1/4" "Generating icons"

export _SOURCE_IMG="$SOURCE_IMG"
export _ICON_DIR="$ICON_DIR"
export _APP_ID="$APP_ID"

python3 << 'PYEOF'
import os, sys
from PIL import Image

src_path = os.environ.get("_SOURCE_IMG", "")
icon_base = os.environ.get("_ICON_DIR", "")
app_id = os.environ.get("_APP_ID", "llama-cluster")

src = Image.open(src_path).convert("RGBA")
bbox = src.getbbox()
cropped = src.crop(bbox) if bbox else src

w, h = cropped.size
side = max(w, h)
pad = int(side * 0.05)
canvas = side + pad * 2

square = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
square.paste(cropped, ((canvas - w) // 2, (canvas - h) // 2), cropped)

for res in (256, 128, 64, 48):
    out_dir = os.path.join(icon_base, f"{res}x{res}", "apps")
    os.makedirs(out_dir, exist_ok=True)
    square.resize((res, res), Image.LANCZOS).save(
        os.path.join(out_dir, f"{app_id}.png")
    )
    print(f"  {res}x{res}/apps/{app_id}.png")
PYEOF

# Refresh icon cache so GNOME picks it up immediately
gtk-update-icon-cache -f -t "$ICON_DIR" 2>/dev/null || true

# ── Step 2: Create .desktop file ────────────────────────────
step "2/4" "Creating desktop launcher"
mkdir -p "$APP_DIR" "$DESKTOP_DIR"

cat > "$APP_DIR/$APP_ID.desktop" << EOF
[Desktop Entry]
Version=1.0
Name=DGX Spark Cluster
GenericName=LLM Inference Cluster
Comment=Launch the DGX Spark llama.cpp cluster
Icon=$APP_ID
Type=Application
Exec=gnome-terminal --title="DGX Spark Cluster" -- sudo start-everything.sh
Terminal=false
Categories=Development;
Keywords=llama;llm;spark;dgx;cluster;inference;
StartupNotify=true
EOF

# Validate before copying
if command -v desktop-file-validate &>/dev/null; then
    if desktop-file-validate "$APP_DIR/$APP_ID.desktop" 2>&1 | grep -q "error"; then
        echo -e "${RED}Desktop file validation failed — check the output above.${NC}"
        exit 1
    fi
fi

cp "$APP_DIR/$APP_ID.desktop" "$DESKTOP_DIR/$APP_ID.desktop"
chmod +x "$DESKTOP_DIR/$APP_ID.desktop"
# Trust the desktop file so GNOME doesn't show "Untrusted application" dialog
gio set "$DESKTOP_DIR/$APP_ID.desktop" metadata::trusted true 2>/dev/null || true
update-desktop-database "$APP_DIR" 2>/dev/null || true

echo "  Installed to $APP_DIR/$APP_ID.desktop"
echo "  Installed to $DESKTOP_DIR/$APP_ID.desktop"

# ── Step 3: Pin to GNOME dock ───────────────────────────────
step "3/4" "Adding to dock"

CURRENT_FAVS=$(gsettings get org.gnome.shell favorite-apps 2>/dev/null || echo "[]")
if echo "$CURRENT_FAVS" | grep -q "$APP_ID.desktop"; then
    echo "  Already pinned"
else
    if [ "$CURRENT_FAVS" = "[]" ] || [ "$CURRENT_FAVS" = "@as []" ]; then
        NEW_FAVS="['$APP_ID.desktop']"
    else
        NEW_FAVS=$(echo "$CURRENT_FAVS" | sed "s/]$/, '$APP_ID.desktop']/")
    fi
    gsettings set org.gnome.shell favorite-apps "$NEW_FAVS" 2>/dev/null && \
        echo "  Pinned to dock" || \
        echo -e "  ${YELLOW}Could not pin to dock (GNOME Shell not running?)${NC}"
fi

# ── Step 4: Final verification ──────────────────────────────
step "4/4" "Verifying installation"

OK=true
if [ ! -f "$DESKTOP_DIR/$APP_ID.desktop" ]; then
    echo -e "  ${RED}Desktop file missing${NC}"
    OK=false
fi
if [ ! -f "$ICON_DIR/256x256/apps/$APP_ID.png" ]; then
    echo -e "  ${RED}Icon files missing${NC}"
    OK=false
fi
if ! command -v start-everything.sh &>/dev/null; then
    echo -e "  ${YELLOW}start-everything.sh not in PATH (launcher will fail until installed)${NC}"
fi

if [ "$OK" = true ]; then
    echo -e "  ${GREEN}All files in place${NC}"
fi

# ── Done ─────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Done!${NC}"
echo ""
echo "  You should see a \"DGX Spark Cluster\" icon on your desktop and dock."
echo "  If the desktop icon shows a gear, right-click it → Allow Launching."
echo ""
echo "  To remove:  $0 --remove"
