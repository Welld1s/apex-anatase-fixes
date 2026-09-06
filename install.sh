#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# apex-anatase-fixes
#
# Description:
#   Applies all known fixes for OneXPlayer Apex running Anatase OS.
#   Includes:
#     - Fingerprint wake blocker (PME + kernel arg)
#     - Sleep stability kernel arg
#     - GameMode desktop shortcut
#
#   The script is idempotent: it checks current state before making changes
#   and only applies what is missing.
#
# Version: 1.0.3
# =============================================================================

# -----------------------------------------------------------------------------
# Script metadata
# -----------------------------------------------------------------------------
SCRIPT_VERSION="1.0.2"
echo "apex-anatase-fixes v$SCRIPT_VERSION"

# -----------------------------------------------------------------------------
# Auto-elevate to root if not already
# -----------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "[1/3] Requesting root privileges..."
    exec sudo "$0" "$@"
fi

# -----------------------------------------------------------------------------
# Terminal colors
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
# Hardware identification (DMI)
EXPECTED_BOARD_VENDOR="ONE-NETBOOK"
EXPECTED_BOARD_NAME="ONEXPLAYER APEX"

# Fingerprint reader (FocalTech)
FP_VENDOR="2808"
FP_PRODUCT="c652"
FP_KARG="gpiolib_acpi.ignore_wake=AMDI0030:00@58"
FP_UDEV_RULE="/etc/udev/rules.d/90-fingerprint-no-wake.rules"
FP_UDEV_CONTENT='# Block wake from the xHCI controller hosting the FocalTech fingerprint
# reader. Managed by apex-anatase-fixes.sh.
ACTION=="add", SUBSYSTEM=="pci", KERNEL=="%s", ATTR{power/wakeup}="disabled"
'

# Sleep-related kernel arguments (key=value)
SLEEP_KARGS=(
    "amd_iommu=off"
)

# GameMode desktop shortcut
GAMEMODE_DESKTOP_SRC="/usr/share/applications/gamemode.desktop"
GAMEMODE_DESKTOP_NAME="gamemode.desktop"

# -----------------------------------------------------------------------------
# Change tracking flags
# -----------------------------------------------------------------------------
fp_changed=0
any_karg_changed=0
sleep_changed=0
gamemode_shortcut_copied=0

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------
error() {
    echo -e "${RED}$*${NC}" >&2
    exit 1
}

get_real_user() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        echo "$SUDO_USER"
    else
        echo "$USER"
    fi
}

get_real_home() {
    local user
    user=$(get_real_user)
    eval echo "~$user"
}

# -----------------------------------------------------------------------------
# OS, branch, and hardware validation
# -----------------------------------------------------------------------------
check_os() {
    if [[ ! -f /etc/os-release ]]; then
        error "Anatase OS not detected."
    fi
    source /etc/os-release
    if [[ "$ID" != "anatase" ]]; then
        error "This script is for Anatase OS (detected: $ID)."
    fi
}

check_rolling_branch() {
    if ! command -v bootc &>/dev/null; then
        error "bootc not found – is this Anatase OS?"
    fi
    local json
    json=$(bootc status --json 2>/dev/null) || error "Failed to get bootc status."
    local image
    image=$(echo "$json" | grep -o '"image":"[^"]*"' | head -1 | cut -d'"' -f4)
    [[ -z "$image" ]] && error "Could not determine current image."
    if [[ "$image" != *":rolling" ]]; then
        error "Not on rolling branch.\nCurrent: $image\nPlease rebase via HHD → Updates → Change Branch (Rebase) → Branch → Rolling"
    fi
}

check_hardware() {
    local vendor name
    vendor=$(cat /sys/class/dmi/id/board_vendor 2>/dev/null) || error "Cannot read DMI."
    name=$(cat /sys/class/dmi/id/board_name 2>/dev/null) || error "Cannot read DMI."
    [[ "$vendor" == "$EXPECTED_BOARD_VENDOR" && "$name" == "$EXPECTED_BOARD_NAME" ]] \
        || error "Not a OneXPlayer Apex (detected: $vendor $name)."
    lsusb -d "${FP_VENDOR}:${FP_PRODUCT}" &>/dev/null \
        || error "Fingerprint reader not found."
}

# -----------------------------------------------------------------------------
# Fingerprint controller detection and PME disable
# -----------------------------------------------------------------------------
find_fp_controller() {
    local usb_devices="/sys/bus/usb/devices"
    for dev in "$usb_devices"/*; do
        [[ -d "$dev" ]] || continue
        local vid pid
        vid=$(cat "$dev/idVendor" 2>/dev/null || echo "")
        pid=$(cat "$dev/idProduct" 2>/dev/null || echo "")
        [[ "$vid" == "$1" && "$pid" == "$2" ]] || continue
        local bus
        bus=$(cat "$dev/busnum" 2>/dev/null || echo "")
        [[ -n "$bus" ]] || continue
        local root="$usb_devices/usb$bus"
        [[ -L "$root" ]] || continue
        local target
        target=$(readlink -f "$root")
        local pci
        pci=$(basename "$(dirname "$target")")
        if [[ "$pci" =~ ^0000:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$ ]]; then
            echo "$pci"
            return 0
        fi
    done
    return 1
}

disable_fp_pme() {
    local ctrl="$1"
    local wake="/sys/bus/pci/devices/$ctrl/power/wakeup"
    [[ -f "$wake" ]] || error "Controller $ctrl not accessible."

    local changed=0
    local current
    current=$(cat "$wake" 2>/dev/null || echo "")
    if [[ "$current" != "disabled" ]]; then
        echo "disabled" | tee "$wake" >/dev/null
        changed=1
    fi

    local need_update=1
    if [[ -f "$FP_UDEV_RULE" ]]; then
        grep -q "KERNEL==\"$ctrl\"" "$FP_UDEV_RULE" && need_update=0
    fi
    if [[ $need_update -eq 1 ]]; then
        printf "$FP_UDEV_CONTENT" "$ctrl" > "$FP_UDEV_RULE"
        udevadm control --reload-rules
        changed=1
    fi

    [[ $changed -eq 1 ]] && fp_changed=1
}

# -----------------------------------------------------------------------------
# Kernel argument management
# -----------------------------------------------------------------------------
add_simple_karg() {
    local karg="$1"
    if rpm-ostree kargs | grep -q "$karg"; then
        return 0
    fi
    rpm-ostree kargs --append-if-missing="$karg" &>/dev/null \
        || error "Failed to add: $karg"
    any_karg_changed=1
    return 1
}

set_karg_uniquely() {
    local arg="$1"
    local key="${arg%%=*}"
    [[ -n "$key" && "$key" != "$arg" ]] || error "Expected 'key=value', got: $arg"

    local changed=0
    local current
    current=$(rpm-ostree kargs)
    local old=()
    while IFS= read -r line; do
        [[ "$line" == "$key="* ]] && old+=("$line")
    done <<< "$current"

    for o in "${old[@]}"; do
        rpm-ostree kargs --delete-if-present="$o" &>/dev/null && changed=1
    done

    if ! rpm-ostree kargs | grep -q "$arg"; then
        rpm-ostree kargs --append-if-missing="$arg" &>/dev/null && changed=1
    fi

    if [[ $changed -eq 1 ]]; then
        any_karg_changed=1
        sleep_changed=1
    fi
}

# -----------------------------------------------------------------------------
# GameMode shortcut (supports localized Desktop folder names)
# -----------------------------------------------------------------------------
copy_gamemode_shortcut() {
    local user
    user=$(get_real_user)
    local home
    home=$(get_real_home)

    local desktop_dir="${home}/Desktop"
    if [[ ! -d "$desktop_dir" ]]; then
        local user_dirs="${home}/.config/user-dirs.dirs"
        if [[ -f "$user_dirs" ]]; then
            local raw_dir
            raw_dir=$(grep -E '^XDG_DESKTOP_DIR=' "$user_dirs" | cut -d'"' -f2 | head -1)
            if [[ -n "$raw_dir" ]]; then
                raw_dir="${raw_dir/#\~/$home}"
                raw_dir="${raw_dir/#\$HOME/$home}"
                if [[ "$raw_dir" != /* ]]; then
                    raw_dir="${home}/${raw_dir}"
                fi
                desktop_dir="$raw_dir"
            fi
        fi
    fi

    if [[ ! -d "$desktop_dir" ]]; then
        return 0
    fi

    local dest="${desktop_dir}/${GAMEMODE_DESKTOP_NAME}"

    if [[ ! -f "$GAMEMODE_DESKTOP_SRC" ]]; then
        return 0
    fi

    local need_copy=0
    if [[ -f "$dest" ]]; then
        if ! cmp -s "$GAMEMODE_DESKTOP_SRC" "$dest"; then
            need_copy=1
        fi
    else
        need_copy=1
    fi

    if [[ $need_copy -eq 1 ]]; then
        cp -f "$GAMEMODE_DESKTOP_SRC" "$dest"
        chown "$user":"$user" "$dest"
        chmod +x "$dest"
        gamemode_shortcut_copied=1
    fi
}

# -----------------------------------------------------------------------------
# Main script execution
# -----------------------------------------------------------------------------
echo "[2/3] Preparing..."
check_os
check_rolling_branch
check_hardware

ctrl=$(find_fp_controller "$FP_VENDOR" "$FP_PRODUCT" || echo "")
[[ -n "$ctrl" ]] || error "Fingerprint controller not found."

echo "[3/3] Applying fixes..."
disable_fp_pme "$ctrl"
add_simple_karg "$FP_KARG"
for karg in "${SLEEP_KARGS[@]}"; do
    set_karg_uniquely "$karg"
done
copy_gamemode_shortcut

# -----------------------------------------------------------------------------
# Final output
# -----------------------------------------------------------------------------
if [[ $fp_changed -eq 0 && $any_karg_changed -eq 0 && $gamemode_shortcut_copied -eq 0 ]]; then
    echo -e "${GREEN}All fixes are already applied.${NC}"
else
    if [[ $fp_changed -eq 1 || $any_karg_changed -eq 1 || $gamemode_shortcut_copied -eq 1 ]]; then
        echo -e "${GREEN}All fixes applied successfully.${NC}"
    fi
    if [[ $any_karg_changed -eq 1 ]]; then
        echo -e "${YELLOW}Reboot required for kernel arguments to take effect.${NC}"
    fi
    if [[ $sleep_changed -eq 1 ]]; then
        echo -e "${YELLOW}Also, ensure BIOS setting: Advanced -> ACPI Settings -> Enable ACPI Auto Configuration -> Enabled${NC}"
    fi
fi
