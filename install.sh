#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# apex-anatase-fixes
#
# Description:
#   Applies all known fixes for OneXPlayer Apex running Anatase OS.
#   Includes:
#     - Fingerprint wake blocker (PME + kernel arg)
#     - Sleep stability kernel args
#     - GameMode desktop shortcut
#
#   The script is idempotent: it checks current state before making changes
#   and only applies what is missing.
#
# Version: 1.0.0
# =============================================================================

# -----------------------------------------------------------------------------
# Script metadata – displayed immediately, before any privilege escalation.
# -----------------------------------------------------------------------------
SCRIPT_VERSION="1.0.0"
echo "apex-anatase-fixes v$SCRIPT_VERSION"

# -----------------------------------------------------------------------------
# Auto-elevate to root if the script is not already running as root.
# Most operations (writing to /sys, installing udev rules, modifying kernel
# arguments) require root privileges. The script will prompt for the user's
# password via sudo if needed.
# -----------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "[1/3] Requesting root privileges..."
    exec sudo "$0" "$@"
fi

# -----------------------------------------------------------------------------
# Terminal color definitions for improved readability of output messages.
# - RED   : used for fatal errors
# - GREEN : used for success messages
# - YELLOW : used for important notes and warnings
# - NC    : resets color to default
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'  # No Color

# -----------------------------------------------------------------------------
# Configuration constants
# -----------------------------------------------------------------------------

# Hardware identification via DMI (Desktop Management Interface).
# These values are hardcoded in the system firmware and uniquely identify the
# OneXPlayer Apex board.
EXPECTED_BOARD_VENDOR="ONE-NETBOOK"
EXPECTED_BOARD_NAME="ONEXPLAYER APEX"

# Fingerprint reader: FocalTech USB device (vendor 0x2808, product 0xc652).
FP_VENDOR="2808"
FP_PRODUCT="c652"

# Kernel argument that disables the GPIO wake line for the fingerprint sensor.
# This is specific to the Apex board's wiring (GPIO pin 58 on the AMDI0030:00
# ACPI device). Without this, a light touch still wakes the device even after
# PME is disabled, because there is a separate wake path.
FP_KARG="gpiolib_acpi.ignore_wake=AMDI0030:00@58"

# Udev rule file that will be created to persist the PME wake setting.
FP_UDEV_RULE="/etc/udev/rules.d/90-loadout-fingerprint-no-wake.rules"

# Content of the udev rule: when the fingerprint controller PCI device is
# added, its power/wakeup attribute is set to "disabled".
# The %s placeholder will be replaced with the actual controller PCI address.
FP_UDEV_CONTENT='# Block wake from the xHCI controller hosting the FocalTech fingerprint
# reader. Managed by apex-anatase-fixes.sh.
ACTION=="add", SUBSYSTEM=="pci", KERNEL=="%s", ATTR{power/wakeup}="disabled"
'

# Sleep-related kernel arguments. These are "key=value" parameters.
# For each entry, the script will ensure that only one instance exists with
# the exact specified value, removing any previous conflicting values.
# Currently only amd_iommu=off is needed for sleep stability.
SLEEP_KARGS=(
    "amd_iommu=off"
)

# Source and destination for the GameMode desktop shortcut.
GAMEMODE_DESKTOP_SRC="/usr/share/applications/gamemode.desktop"
GAMEMODE_DESKTOP_NAME="gamemode.desktop"

# -----------------------------------------------------------------------------
# Change tracking flags
# These variables are set to 1 when a specific change is made, so that the
# final summary only reports what was actually modified.
# -----------------------------------------------------------------------------
fp_changed=0                # PME or udev rule for fingerprint was changed
any_karg_changed=0          # Any kernel argument was added or removed
sleep_changed=0             # Any sleep-related argument was changed
gamemode_shortcut_copied=0  # GameMode shortcut was copied to Desktop

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------

# Print an error message in red and exit with non-zero status.
# All error messages are sent to stderr.
error() {
    echo -e "${RED}$*${NC}" >&2
    exit 1
}

# Determine the real user who invoked sudo (or the current user if not sudo).
# This is used to properly set ownership of the copied desktop shortcut.
get_real_user() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        echo "$SUDO_USER"
    else
        echo "$USER"
    fi
}

# Determine the home directory of the real user.
get_real_home() {
    local user
    user=$(get_real_user)
    eval echo "~$user"
}

# -----------------------------------------------------------------------------
# Validation functions: OS, branch, and hardware
# -----------------------------------------------------------------------------

# Ensure the system is running Anatase OS by checking /etc/os-release.
check_os() {
    if [[ ! -f /etc/os-release ]]; then
        error "Anatase OS not detected."
    fi
    # Source the file to read the ID field
    source /etc/os-release
    if [[ "$ID" != "anatase" ]]; then
        error "This script is for Anatase OS (detected: $ID)."
    fi
}

# Ensure the system is on the "rolling" branch using bootc status.
# The script extracts the image reference from the JSON output and checks
# if it ends with ":rolling". If not, it exits with instructions on how to
# rebase using the HHD tool (Updates → Change Branch (Rebase) → Branch → Rolling).
check_rolling_branch() {
    if ! command -v bootc &>/dev/null; then
        error "bootc command not found – is this Anatase OS?"
    fi

    local json_output
    if ! json_output=$(bootc status --json 2>/dev/null); then
        error "Failed to get bootc status. Are you running as root?"
    fi

    # Extract the image field from the JSON (first occurrence)
    local image_ref
    image_ref=$(echo "$json_output" | grep -o '"image":"[^"]*"' | head -1 | cut -d'"' -f4)
    if [[ -z "$image_ref" ]]; then
        error "Could not determine current image from bootc status."
    fi

    if [[ "$image_ref" != *":rolling" ]]; then
        error "Anatase OS is not on the rolling branch.\nCurrent image: $image_ref\nPlease rebase via:\n  HHD -> Updates -> Change Branch (Rebase) -> Branch -> Rolling\nRun the script again after a reboot."
    fi
}

# Ensure the hardware is a OneXPlayer Apex by checking:
# 1. DMI board vendor and name (must match ONE-NETBOOK and ONEXPLAYER APEX).
# 2. The presence of the FocalTech fingerprint reader (USB 2808:c652).
check_hardware() {
    # Read DMI values from sysfs
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

    # Verify the fingerprint reader is present
    if ! lsusb -d "${FP_VENDOR}:${FP_PRODUCT}" &>/dev/null; then
        error "Fingerprint reader not found. This is not a OneXPlayer Apex."
    fi
}

# -----------------------------------------------------------------------------
# Fingerprint controller detection and PME disabling
# -----------------------------------------------------------------------------

# Find the PCI address (e.g., "0000:67:00.0") of the xHCI controller that
# hosts the fingerprint reader. This is done by locating the USB device with
# the correct VID/PID, then walking up to the parent PCI device.
find_fp_controller() {
    local usb_devices="/sys/bus/usb/devices"
    local vendor="$1"
    local prod="$2"

    for dev in "$usb_devices"/*; do
        [[ -d "$dev" ]] || continue
        local idVendor
        local idProduct
        idVendor=$(cat "$dev/idVendor" 2>/dev/null || echo "")
        idProduct=$(cat "$dev/idProduct" 2>/dev/null || echo "")
        [[ "$idVendor" == "$vendor" && "$idProduct" == "$prod" ]] || continue

        local busnum
        busnum=$(cat "$dev/busnum" 2>/dev/null || echo "")
        [[ -n "$busnum" ]] || continue

        local root_dev="${usb_devices}/usb$busnum"
        [[ -L "$root_dev" ]] || continue

        local target
        target=$(readlink -f "$root_dev")
        local pci_name
        pci_name=$(basename "$(dirname "$target")")

        # Ensure the result looks like a PCI device name
        if [[ "$pci_name" =~ ^0000:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$ ]]; then
            echo "$pci_name"
            return 0
        fi
    done
    return 1
}

# Disable PCIe PME wake for the fingerprint controller.
# This performs two complementary actions:
# 1. Writes "disabled" to /sys/bus/pci/devices/.../power/wakeup (runtime effect).
# 2. Installs or updates a udev rule that will re-apply the setting on every boot.
#
# The global flag fp_changed is set if any change is made.
disable_fp_pme() {
    local controller="$1"
    local wake_path="/sys/bus/pci/devices/$controller/power/wakeup"
    if [[ ! -f "$wake_path" ]]; then
        error "Fingerprint controller $controller not accessible."
    fi

    local changed=0

    # Runtime setting
    local current_wake
    current_wake=$(cat "$wake_path" 2>/dev/null || echo "")
    if [[ "$current_wake" != "disabled" ]]; then
        echo "disabled" | tee "$wake_path" >/dev/null
        changed=1
    fi

    # Udev rule: only if missing or targeting a different controller
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

    [[ $changed -eq 1 ]] && fp_changed=1
}

# -----------------------------------------------------------------------------
# Kernel argument management (rpm-ostree)
# -----------------------------------------------------------------------------

# Add a kernel argument by simply checking for its exact presence.
# This function is used for arguments that are not part of the SLEEP_KARGS set
# and do not require removal of conflicting values (e.g., the fingerprint GPIO
# argument). The argument is added only if it is not already present.
# Sets any_karg_changed=1 if the argument was added.
add_simple_karg() {
    local karg="$1"

    if rpm-ostree kargs | grep -q "$karg"; then
        return 0  # already present
    fi

    if ! rpm-ostree kargs --append-if-missing="$karg" &>/dev/null; then
        error "Failed to add kernel argument: $karg"
    fi

    any_karg_changed=1
    return 1
}

# Set a "key=value" kernel argument cleanly, ensuring no duplicate keys.
# This function is used exclusively for sleep-related arguments (SLEEP_KARGS).
# It works as follows:
#   1. Finds all existing arguments that start with "key=" and removes them.
#   2. Adds the exact "key=value" if it is not already present.
# This prevents conflicts and ensures only one instance of the key exists.
# Sets any_karg_changed=1 and sleep_changed=1 if any change occurred.
set_karg_uniquely() {
    local arg="$1"
    local key="${arg%%=*}"   # everything before the first '='

    if [[ -z "$key" || "$key" == "$arg" ]]; then
        error "set_karg_uniquely expects 'key=value' format. Got: $arg"
    fi

    local changed=0

    # Get current kargs as a string and collect all arguments starting with key=
    local current_kargs
    current_kargs=$(rpm-ostree kargs)
    local old_args=()
    while IFS= read -r line; do
        if [[ "$line" == "$key="* ]]; then
            old_args+=("$line")
        fi
    done <<< "$current_kargs"

    # Remove each old argument
    for old in "${old_args[@]}"; do
        if rpm-ostree kargs --delete-if-present="$old" &>/dev/null; then
            changed=1
        fi
    done

    # Add the new argument if not already present (after removals it should be gone)
    if ! rpm-ostree kargs | grep -q "$arg"; then
        if rpm-ostree kargs --append-if-missing="$arg" &>/dev/null; then
            changed=1
        fi
    fi

    if [[ $changed -eq 1 ]]; then
        any_karg_changed=1
        sleep_changed=1
    fi
}

# -----------------------------------------------------------------------------
# GameMode desktop shortcut
# -----------------------------------------------------------------------------

# Copy the system-wide GameMode .desktop file to the user's Desktop folder.
# This is a convenience for users who want easy access to GameMode.
# The copy is performed only if:
#   - The source file exists.
#   - The Desktop folder exists (or can be determined via XDG user dirs).
#   - The destination file is missing or has different content.
# The ownership is set to the real user who invoked sudo.
copy_gamemode_shortcut() {
    local user
    user=$(get_real_user)
    local home
    home=$(get_real_home)

    # Determine the Desktop directory, falling back to XDG_USER_DIRS if needed.
    local desktop_dir="${home}/Desktop"
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

    # If still not found, skip silently.
    if [[ ! -d "$desktop_dir" ]]; then
        return 0
    fi

    local dest="${desktop_dir}/${GAMEMODE_DESKTOP_NAME}"

    # Source must exist.
    if [[ ! -f "$GAMEMODE_DESKTOP_SRC" ]]; then
        return 0
    fi

    # Determine if copy is needed: missing or different content.
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

# Phase 2: Preparation – validate OS, branch, and hardware.
echo "[2/3] Preparing..."
check_os
check_rolling_branch
check_hardware

# Locate the fingerprint controller.
controller=$(find_fp_controller "$FP_VENDOR" "$FP_PRODUCT" || echo "")
if [[ -z "$controller" ]]; then
    error "Fingerprint controller not found."
fi

# Phase 3: Apply all fixes.
echo "[3/3] Applying fixes..."

# 3.1 Disable fingerprint PME wake (runtime + udev).
disable_fp_pme "$controller"

# 3.2 Add the fingerprint GPIO kernel argument (simple presence check).
add_simple_karg "$FP_KARG"

# 3.3 Apply sleep stability arguments – each set cleanly without duplicates.
for karg in "${SLEEP_KARGS[@]}"; do
    set_karg_uniquely "$karg"
done

# 3.4 Copy GameMode shortcut to Desktop.
copy_gamemode_shortcut

# -----------------------------------------------------------------------------
# Final output – summarise only what changed.
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
