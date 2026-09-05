#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# apex-anatase-fixes
#
# Description:
#   Applies all known fixes for OneXPlayer Apex running Anatase OS.
#   Includes:
#     - Fingerprint wake blocker (PME + kernel arg)
#     - Sleep stability kernel args (amd_iommu=off, modprobe.blacklist=amdxdna)
#     - GameMode desktop shortcut (copied from system-wide .desktop file)
#
#   The script is idempotent: it checks current state before making changes
#   and only applies what is missing.
#
# Version: 1.0.0
# =============================================================================

# -----------------------------------------------------------------------------
# Script metadata
# -----------------------------------------------------------------------------
SCRIPT_VERSION="1.0.0"
echo "apex-anatase-fixes v$SCRIPT_VERSION"

# -----------------------------------------------------------------------------
# Auto-elevate to root if not already
# -----------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "[1/3] Requesting root privileges..."
    exec sudo "$0" "$@"
fi

# -----------------------------------------------------------------------------
# Color definitions for terminal output
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'            # No Color

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
FP_UDEV_RULE="/etc/udev/rules.d/90-loadout-fingerprint-no-wake.rules"
FP_UDEV_CONTENT='# Block wake from the xHCI controller hosting the FocalTech fingerprint
# reader. Managed by apex-anatase-fixes.sh.
ACTION=="add", SUBSYSTEM=="pci", KERNEL=="%s", ATTR{power/wakeup}="disabled"
'

# Sleep fixes (kernel command line arguments)
SLEEP_KARGS=(
    "amd_iommu=off"
    "modprobe.blacklist=amdxdna"
)

# GameMode desktop shortcut (source and destination name)
GAMEMODE_DESKTOP_SRC="/usr/share/applications/gamemode.desktop"
GAMEMODE_DESKTOP_NAME="gamemode.desktop"

# -----------------------------------------------------------------------------
# Global flags to track changes
# -----------------------------------------------------------------------------
fp_changed=0                # Fingerprint PME or udev rule changed
any_karg_changed=0          # Any kernel argument was added
sleep_changed=0             # Sleep-related kernel arguments added
gamemode_shortcut_copied=0  # GameMode .desktop file copied to Desktop

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------

# Print an error message in red and exit with non-zero code
error() {
    echo -e "${RED}[ERROR] $*${NC}" >&2
    exit 1
}

# Determine the real user who invoked sudo (or current user if not sudo)
get_real_user() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        echo "$SUDO_USER"
    else
        echo "$USER"
    fi
}

# Determine the real user's home directory
get_real_home() {
    local user
    user=$(get_real_user)
    eval echo "~$user"
}

# -----------------------------------------------------------------------------
# OS and hardware validation
# -----------------------------------------------------------------------------

# Verify that we are running on Anatase OS (ID=anatase)
check_os() {
    if [[ ! -f /etc/os-release ]]; then
        error "Anatase OS not detected."
    fi
    # shellcheck source=/dev/null
    source /etc/os-release
    if [[ "$ID" != "anatase" ]]; then
        error "This script is for Anatase OS (detected: $ID)."
    fi
}

# Verify that the hardware is a OneXPlayer Apex (via DMI and fingerprint reader)
check_hardware() {
    # 1. DMI board vendor and name
    local board_vendor
    local board_name
    if [[ -f /sys/class/dmi/id/board_vendor ]]; then
        board_vendor=$(cat /sys/class/dmi/id/board_vendor)
    else
        error "Cannot read DMI information. Is this a standard PC?"
    fi

    if [[ -f /sys/class/dmi/id/board_name ]]; then
        board_name=$(cat /sys/class/dmi/id/board_name)
    else
        error "Cannot read DMI information. Is this a standard PC?"
    fi

    if [[ "$board_vendor" != "$EXPECTED_BOARD_VENDOR" ]] || [[ "$board_name" != "$EXPECTED_BOARD_NAME" ]]; then
        error "This hardware is not a OneXPlayer Apex (detected: $board_vendor $board_name)."
    fi

    # 2. Fingerprint reader (FocalTech 2808:c652)
    if ! lsusb -d "${FP_VENDOR}:${FP_PRODUCT}" &>/dev/null; then
        error "Fingerprint reader not found. This is not a OneXPlayer Apex."
    fi
}

# -----------------------------------------------------------------------------
# Fingerprint wake blocker (PME + udev)
# -----------------------------------------------------------------------------

# Find the xHCI PCI controller that hosts the fingerprint reader
find_fp_controller() {
    local usb_devices="/sys/bus/usb/devices"
    local vendor="$1"
    local prod="$2"

    for dev in "$usb_devices"/*; do
        [[ -d "$dev" ]] || continue
        idVendor=$(cat "$dev/idVendor" 2>/dev/null || echo "")
        idProduct=$(cat "$dev/idProduct" 2>/dev/null || echo "")
        if [[ "$idVendor" == "$vendor" && "$idProduct" == "$prod" ]]; then
            busnum=$(cat "$dev/busnum" 2>/dev/null || echo "")
            [[ -z "$busnum" ]] && continue
            root_dev="$usb_devices/usb$busnum"
            if [[ -L "$root_dev" ]]; then
                target=$(readlink -f "$root_dev")
                pci_name=$(basename "$(dirname "$target")")
                if [[ "$pci_name" =~ ^0000:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$ ]]; then
                    echo "$pci_name"
                    return 0
                fi
            fi
        fi
    done
    return 1
}

# Disable PCIe PME wake for the fingerprint controller:
# - Writes "disabled" to power/wakeup (runtime)
# - Installs (or updates) a udev rule to persist the setting across reboots
# Sets fp_changed=1 if either action was performed
disable_fp_pme() {
    local controller="$1"
    local wake_path="/sys/bus/pci/devices/$controller/power/wakeup"
    if [[ ! -f "$wake_path" ]]; then
        error "Fingerprint controller $controller not accessible."
    fi

    local changed=0

    # 1. Runtime setting
    local current_wake
    current_wake=$(cat "$wake_path" 2>/dev/null || echo "")
    if [[ "$current_wake" != "disabled" ]]; then
        echo "disabled" | tee "$wake_path" >/dev/null
        changed=1
    fi

    # 2. udev rule (only if missing or points to a different controller)
    local rule_needs_update=1
    if [[ -f "$FP_UDEV_RULE" ]]; then
        if grep -q "KERNEL==\"$controller\"" "$FP_UDEV_RULE"; then
            rule_needs_update=0
        fi
    fi

    if [[ $rule_needs_update -eq 1 ]]; then
        printf "$FP_UDEV_CONTENT" "$controller" > "$FP_UDEV_RULE"
        udevadm control --reload-rules
        changed=1
    fi

    if [[ $changed -eq 1 ]]; then
        fp_changed=1
    fi
}

# -----------------------------------------------------------------------------
# Kernel argument management (rpm-ostree)
# -----------------------------------------------------------------------------

# Add a kernel argument using rpm-ostree kargs --append-if-missing.
# Only applies if not already present in the current kargs list.
# Sets global flags:
#   - any_karg_changed = 1 if any argument was added
#   - sleep_changed = 1 if the argument is one of the sleep fixes
add_karg() {
    local karg="$1"
    local is_sleep="$2"          # 1 = sleep fix, 0 = fingerprint karg

    # Check if already present
    if rpm-ostree kargs | grep -q "$karg"; then
        return 0                 # Already present, no change
    fi

    # Add it (idempotent)
    if ! rpm-ostree kargs --append-if-missing="$karg" &>/dev/null; then
        error "Failed to add kernel argument: $karg"
    fi

    any_karg_changed=1
    if [[ $is_sleep -eq 1 ]]; then
        sleep_changed=1
    fi
    return 1
}

# -----------------------------------------------------------------------------
# GameMode desktop shortcut copy
# -----------------------------------------------------------------------------

# Copy the system-wide gamemode.desktop file to the user's Desktop folder.
# Only copies if:
#   - Source file exists
#   - Desktop folder exists
#   - Destination is missing or differs from source (checked with cmp)
# Sets gamemode_shortcut_copied=1 if the copy was performed.
copy_gamemode_shortcut() {
    local user
    user=$(get_real_user)
    local home
    home=$(get_real_home)
    local desktop_dir="${home}/Desktop"

    # Fallback: read XDG_DESKTOP_DIR if ~/Desktop does not exist
    if [[ ! -d "$desktop_dir" ]]; then
        local user_dirs="${home}/.config/user-dirs.dirs"
        if [[ -f "$user_dirs" ]]; then
            # shellcheck source=/dev/null
            source "$user_dirs"
            if [[ -n "${XDG_DESKTOP_DIR:-}" ]]; then
                desktop_dir="${XDG_DESKTOP_DIR/#\~/$home}"
            fi
        fi
    fi

    # Exit early if Desktop folder doesn't exist
    if [[ ! -d "$desktop_dir" ]]; then
        return 0
    fi

    local dest="${desktop_dir}/${GAMEMODE_DESKTOP_NAME}"

    # Source must exist
    if [[ ! -f "$GAMEMODE_DESKTOP_SRC" ]]; then
        return 0
    fi

    # Check if copy is needed (missing or different content)
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

# Phase 2: Preparation (OS and hardware validation)
echo "[2/3] Preparing..."
check_os
check_hardware

# Locate the fingerprint controller
controller=$(find_fp_controller "$FP_VENDOR" "$FP_PRODUCT" || echo "")
if [[ -z "$controller" ]]; then
    error "Fingerprint controller not found."
fi

# Phase 3: Apply fixes
echo "[3/3] Applying fixes..."

# 3.1 Fingerprint wake blocker (PME + udev)
disable_fp_pme "$controller"

# 3.2 Fingerprint kernel argument (closes the GPIO wake path)
add_karg "$FP_KARG" 0

# 3.3 Sleep stability kernel arguments
for karg in "${SLEEP_KARGS[@]}"; do
    add_karg "$karg" 1
done

# 3.4 GameMode desktop shortcut (copy, not symlink)
copy_gamemode_shortcut

# -----------------------------------------------------------------------------
# Final output (only show what actually changed)
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
    if [[ $gamemode_shortcut_copied -eq 1 ]]; then
        echo -e "${GREEN}GameMode shortcut copied to Desktop.${NC}"
    fi
fi
