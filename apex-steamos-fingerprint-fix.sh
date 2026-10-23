#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# apex-steamos-fingerprint-fix
#
# Fixes the OneXPlayer Apex fingerprint reader waking the device from sleep
# on SteamOS.
#
# Fixes applied:
#   1. Disable PCIe PME wake on the xHCI controller hosting the
#      fingerprint reader (runtime sysfs + persistent udev rule).
#   2. Add kernel argument to ignore the ACPI GPIO wake line:
#      gpiolib_acpi.ignore_wake=AMDI0030:00@58
#      (Applied via /etc/default/grub + update-grub, since SteamOS uses GRUB)
#
# The script is idempotent.
# Version: 1.0.3
# =============================================================================

SCRIPT_VERSION="1.0.3"
echo "apex-steamos-fingerprint-fix v$SCRIPT_VERSION"
echo "==========================================="

if [[ $EUID -ne 0 ]]; then
    echo "Requesting root privileges..."
    exec sudo --preserve-env=DISPLAY,WAYLAND_DISPLAY,XAUTHORITY,XDG_RUNTIME_DIR "$0" "$@"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
WHITE='\033[0;37m'
NC='\033[0m'

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
EXPECTED_BOARD_VENDOR="ONE-NETBOOK"
EXPECTED_BOARD_NAME="ONEXPLAYER APEX"

FP_VENDOR="2808"
FP_PRODUCT="c652"
FP_KARG="gpiolib_acpi.ignore_wake=AMDI0030:00@58"
FP_UDEV_RULE="/etc/udev/rules.d/90-fingerprint-no-wake.rules"
FP_UDEV_CONTENT='# Block wake from the xHCI controller hosting the FocalTech fingerprint
# reader. Managed by apex-steamos-fingerprint-fix.sh.
ACTION=="add", SUBSYSTEM=="pci", KERNEL=="%s", ATTR{power/wakeup}="disabled"
'

GRUB_DEFAULT_FILE="/etc/default/grub"

# -----------------------------------------------------------------------------
# State
# -----------------------------------------------------------------------------
reboot_needed=0
bios_needed=0

stages_ok=0
stages_error=0

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
print_status() {
    local stage="$1" status="$2" reason="${3:-}"
    local color
    case "$status" in
        done|"not needed") color="$GREEN" ;;
        error)             color="$RED" ;;
        *)                 color="$NC" ;;
    esac
    printf "${WHITE}%s${NC} - ${color}%s${NC}\n" "$stage" "$status"
    if [[ -n "$reason" ]]; then
        echo -e "${RED}${reason}${NC}"
    fi
}

find_fp_controller() {
    local usb_devices="/sys/bus/usb/devices"
    local dev vid pid bus root target pci
    for dev in "$usb_devices"/*; do
        [[ -d "$dev" ]] || continue
        vid=$(cat "$dev/idVendor" 2>/dev/null || echo "")
        pid=$(cat "$dev/idProduct" 2>/dev/null || echo "")
        [[ "$vid" == "$FP_VENDOR" && "$pid" == "$FP_PRODUCT" ]] || continue
        bus=$(cat "$dev/busnum" 2>/dev/null || echo "")
        [[ -n "$bus" ]] || continue
        root="$usb_devices/usb$bus"
        [[ -L "$root" ]] || continue
        target=$(readlink -f "$root")
        pci=$(basename "$(dirname "$target")")
        if [[ "$pci" =~ ^0000:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$ ]]; then
            echo "$pci"
            return 0
        fi
    done
    return 1
}

check_steamos() {
    [[ -f /etc/os-release ]] || return 1
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "steamos" ]]
}

check_hardware() {
    local vendor name
    vendor=$(cat /sys/class/dmi/id/board_vendor 2>/dev/null || echo "")
    name=$(cat /sys/class/dmi/id/board_name 2>/dev/null || echo "")
    [[ "$vendor" == "$EXPECTED_BOARD_VENDOR" && "$name" == "$EXPECTED_BOARD_NAME" ]]
}

# -----------------------------------------------------------------------------
# Kernel argument helper (GRUB specific for SteamOS)
# Returns: 0 = newly added, 1 = failed, 2 = already present
# -----------------------------------------------------------------------------
add_kernel_arg() {
    local karg="$1"

    if grep -q "$karg" "$GRUB_DEFAULT_FILE" 2>/dev/null; then
        return 2
    fi

    if [[ ! -f "$GRUB_DEFAULT_FILE" ]]; then
        return 1
    fi

    [[ -f "${GRUB_DEFAULT_FILE}.apex-fix.bak" ]] || cp "$GRUB_DEFAULT_FILE" "${GRUB_DEFAULT_FILE}.apex-fix.bak"

    if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_DEFAULT_FILE"; then
        sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"\\(.*\\)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\\1 $karg\"|" "$GRUB_DEFAULT_FILE"
    elif grep -q '^GRUB_CMDLINE_LINUX=' "$GRUB_DEFAULT_FILE"; then
        sed -i "s|^GRUB_CMDLINE_LINUX=\"\\(.*\\)\"|GRUB_CMDLINE_LINUX=\"\\1 $karg\"|" "$GRUB_DEFAULT_FILE"
    else
        echo "GRUB_CMDLINE_LINUX_DEFAULT=\"$karg\"" >> "$GRUB_DEFAULT_FILE"
    fi

    local rebuild_ok=0
    if command -v update-grub >/dev/null 2>&1; then
        update-grub &>/dev/null && rebuild_ok=1
    elif command -v grub-mkconfig >/dev/null 2>&1; then
        grub-mkconfig -o /boot/efi/EFI/steamos/grub.cfg &>/dev/null && rebuild_ok=1
    fi

    if [[ $rebuild_ok -eq 0 ]]; then
        cp "${GRUB_DEFAULT_FILE}.apex-fix.bak" "$GRUB_DEFAULT_FILE"
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
# --- Stage: Preparation ------------------------------------------------------
if ! check_steamos; then
    print_status "Preparation" "error" "SteamOS not detected."
    exit 1
fi
if ! check_hardware; then
    print_status "Preparation" "error" "Not a OneXPlayer Apex."
    exit 1
fi
if ! controller=$(find_fp_controller); then
    print_status "Preparation" "error" "Fingerprint reader not found."
    exit 1
fi
print_status "Preparation" "done"
stages_ok=$((stages_ok + 1))

# --- Stage: Fingerprint fix --------------------------------------------------
changed=0
fail_reason=""

# 1. Runtime PME disable
wake="/sys/bus/pci/devices/${controller}/power/wakeup"
if [[ ! -f "$wake" ]]; then
    print_status "Fingerprint sensor tweaks" "error" "Wake path not accessible."
    stages_error=$((stages_error + 1))
    fail_reason="Wake path not accessible."
else
    current=$(cat "$wake" 2>/dev/null || echo "")
    if [[ "$current" != "disabled" ]]; then
        if echo "disabled" | tee "$wake" >/dev/null; then
            changed=1
        else
            fail_reason="Failed to disable PME."
        fi
    fi

    # 2. Persistent udev rule
    need_update=1
    if [[ -f "$FP_UDEV_RULE" ]]; then
        grep -q "KERNEL==\"$controller\"" "$FP_UDEV_RULE" && need_update=0
    fi
    if [[ $need_update -eq 1 ]]; then
        mkdir -p "$(dirname "$FP_UDEV_RULE")"
        if printf "$FP_UDEV_CONTENT" "$controller" > "$FP_UDEV_RULE"; then
            udevadm control --reload-rules || fail_reason="Failed to reload udev rules."
            changed=1
        else
            fail_reason="Failed to write udev rule."
        fi
    fi

    # 3. Kernel argument (GRUB)
    karg_rc=0
    add_kernel_arg "$FP_KARG" || karg_rc=$?
    if [[ $karg_rc -eq 0 ]]; then
        changed=1
        reboot_needed=1
        bios_needed=1
    elif [[ $karg_rc -eq 1 ]]; then
        fail_reason="Could not automatically add kernel argument to GRUB."
    fi

    # Итог стадии
    if [[ -n "$fail_reason" ]]; then
        print_status "Fingerprint sensor tweaks" "error" "$fail_reason"
        stages_error=$((stages_error + 1))
    elif [[ $changed -eq 1 ]]; then
        print_status "Fingerprint sensor tweaks" "done"
        stages_ok=$((stages_ok + 1))
    else
        print_status "Fingerprint sensor tweaks" "not needed"
        stages_ok=$((stages_ok + 1))
    fi
fi

# -----------------------------------------------------------------------------
# Final report
# -----------------------------------------------------------------------------
if [[ $stages_error -eq 0 ]]; then
    echo -e "${GREEN}Fix installed successfully.${NC}"
else
    echo -e "${RED}Fix failed to install.${NC}"
fi

if [[ $reboot_needed -eq 1 ]]; then
    echo -e "${YELLOW}Reboot required to apply the fix.${NC}"
fi
if [[ $bios_needed -eq 1 ]]; then
    echo -e "${YELLOW}Also, ensure BIOS setting: Advanced -> ACPI Settings -> Enable ACPI Auto Configuration -> Enabled${NC}"
fi
