#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# apex-anatase-fixes
#
# Description:
#   Applies all known fixes for OneXPlayer Apex running Anatase OS.
#   Stages:
#     Preparation               - validate OS, version, hardware
#     Fingerprint sensor tweaks - PME disable + udev rule + GPIO kernel arg
#     Gamemode shortcut         - copy .desktop to user's Desktop
#     HHD settings              - apply curated HHD preset
#
#   The script is idempotent: it checks current state before making changes.
#
# Version: 1.2.0
# =============================================================================

# -----------------------------------------------------------------------------
# Script metadata
# -----------------------------------------------------------------------------
SCRIPT_VERSION="1.2.0"
echo "apex-anatase-fixes v$SCRIPT_VERSION"

# -----------------------------------------------------------------------------
# Auto-elevate to root if not already
# -----------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "Requesting root privileges..."
    exec sudo "$0" "$@"
fi

# -----------------------------------------------------------------------------
# Terminal colors
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
WHITE='\033[0;37m'
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

# GameMode desktop shortcut
GAMEMODE_DESKTOP_SRC="/usr/share/applications/gamemode.desktop"
GAMEMODE_DESKTOP_NAME="gamemode.desktop"

# Minimum required Anatase OS version
MIN_ANATASE_VERSION="20260907.10"

# HHD settings preset
HHD_RESET_DELAY=5
HHD_SETTINGS=(
    "tdp.unified.tdp.mode=custom"
    "tdp.unified.tdp.custom.tdp=55"
    "tdp.unified.fan.mode=manual_edge"
    "tdp.unified.fan.manual_edge.st40=20"
    "tdp.unified.fan.manual_edge.st45=30"
    "tdp.unified.fan.manual_edge.st50=30"
    "tdp.unified.fan.manual_edge.st55=30"
    "tdp.unified.fan.manual_edge.st60=30"
    "tdp.unified.fan.manual_edge.st65=30"
    "tdp.unified.fan.manual_edge.st70=42"
    "tdp.unified.fan.manual_edge.st80=70"
    "tdp.unified.fan.manual_edge.st90=100"
    "tdp.amd_energy.mode.mode=manual"
    "tdp.amd_energy.mode.manual.cpu_pref=balance_power"
    "tdp.amd_energy.mode.manual.cpu_boost=enabled"
    "tdp.amd_energy.mode.manual.sched=disabled"
    "rgb.handheld.mode.mode=oxp"
    "rgb.handheld.mode.oxp.mode=cyberpunk"
    "rgb.handheld.mode.oxp.brightnessd=medium"
    "controllers.oxp.controller_mode.mode=hori_steam"
    "controllers.oxp.controller_mode.hori_steam.flip_z=false"
    "controllers.oxp.vibration_strength=v1"
    "gamemode.power.hibernate_auto=false"
    "gamemode.gamescope.autologin.mode=enabled"
    "gamemode.battery.charge_limit=disabled"
    "gamemode.battery.charge_bypass=awake"
)

# -----------------------------------------------------------------------------
# State
# -----------------------------------------------------------------------------
reboot_needed=0
bios_needed=0

stages_ok=0
stages_error=0

PREP_FAIL_REASON=""
FP_FAIL_REASON=""

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
# Print a stage line and, optionally, a reason on the next line in red.
print_status() {
    local stage="$1" status="$2" reason="${3:-}"
    local color
    case "$status" in
        done|exists) color="$GREEN" ;;
        error)       color="$RED" ;;
        *)           color="$NC" ;;
    esac
    printf "${WHITE}%s${NC} - ${color}%s${NC}\n" "$stage" "$status"
    if [[ -n "$reason" ]]; then
        echo -e "${RED}${reason}${NC}"
    fi
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
# Fingerprint controller lookup
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# Stage: Preparation (hard gate — exits on failure)
# -----------------------------------------------------------------------------
prepare() {
    # OS check
    if [[ ! -f /etc/os-release ]]; then
        PREP_FAIL_REASON="Anatase OS not detected."
        return 1
    fi
    source /etc/os-release
    if [[ "$ID" != "anatase" ]]; then
        PREP_FAIL_REASON="Not Anatase OS (detected: $ID)."
        return 1
    fi

    # Version check
    if ! command -v bootc &>/dev/null; then
        PREP_FAIL_REASON="bootc not found."
        return 1
    fi
    local json version
    if ! json=$(bootc status --json 2>/dev/null); then
        PREP_FAIL_REASON="Failed to get bootc status."
        return 1
    fi
    version=$(echo "$json" | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4)
    if [[ -z "$version" ]]; then
        PREP_FAIL_REASON="Could not determine Anatase OS version."
        return 1
    fi
    if [[ "$version" < "$MIN_ANATASE_VERSION" ]]; then
        PREP_FAIL_REASON="Anatase OS version $version is too old (minimum: $MIN_ANATASE_VERSION).\nPlease update via HHD → Updates."
        return 1
    fi

    # Hardware check (DMI only – fingerprint reader is non-critical)
    local vendor name
    if ! vendor=$(cat /sys/class/dmi/id/board_vendor 2>/dev/null); then
        PREP_FAIL_REASON="Cannot read DMI information."
        return 1
    fi
    if ! name=$(cat /sys/class/dmi/id/board_name 2>/dev/null); then
        PREP_FAIL_REASON="Cannot read DMI information."
        return 1
    fi
    if [[ "$vendor" != "$EXPECTED_BOARD_VENDOR" || "$name" != "$EXPECTED_BOARD_NAME" ]]; then
        PREP_FAIL_REASON="Not a OneXPlayer Apex (detected: $vendor $name)."
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Stage: Fingerprint sensor tweaks
# -----------------------------------------------------------------------------
# Non-critical stage: if the reader is not present or its controller cannot
# be located, the stage is reported as an error (with reason on the next line)
# but does not stop the script.
# -----------------------------------------------------------------------------
run_fingerprint_stage() {
    if ! lsusb -d "${FP_VENDOR}:${FP_PRODUCT}" &>/dev/null; then
        FP_FAIL_REASON="Fingerprint reader not found."
        return 1
    fi

    local controller
    if ! controller=$(find_fp_controller); then
        FP_FAIL_REASON="Fingerprint controller not found."
        return 1
    fi

    local changed=0
    local wake="/sys/bus/pci/devices/${controller}/power/wakeup"

    if [[ ! -f "$wake" ]]; then
        FP_FAIL_REASON="Fingerprint wake path not accessible."
        return 1
    fi

    local current
    current=$(cat "$wake" 2>/dev/null || echo "")
    if [[ "$current" != "disabled" ]]; then
        echo "disabled" | tee "$wake" >/dev/null || { FP_FAIL_REASON="Failed to disable PME."; return 1; }
        changed=1
    fi

    local need_update=1
    if [[ -f "$FP_UDEV_RULE" ]]; then
        grep -q "KERNEL==\"$controller\"" "$FP_UDEV_RULE" && need_update=0
    fi
    if [[ $need_update -eq 1 ]]; then
        printf "$FP_UDEV_CONTENT" "$controller" > "$FP_UDEV_RULE" \
            || { FP_FAIL_REASON="Failed to write udev rule."; return 1; }
        udevadm control --reload-rules \
            || { FP_FAIL_REASON="Failed to reload udev rules."; return 1; }
        changed=1
    fi

    local kargs
    kargs=$(rpm-ostree kargs 2>/dev/null) \
        || { FP_FAIL_REASON="Failed to read kernel arguments."; return 1; }
    if [[ "$kargs" != *"$FP_KARG"* ]]; then
        rpm-ostree kargs --append-if-missing="$FP_KARG" &>/dev/null \
            || { FP_FAIL_REASON="Failed to add GPIO kernel argument."; return 1; }
        changed=1
        reboot_needed=1
        bios_needed=1
    fi

    if [[ $changed -eq 1 ]]; then
        print_status "Fingerprint sensor tweaks" "done"
    else
        print_status "Fingerprint sensor tweaks" "exists"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Stage: Gamemode shortcut (supports localized Desktop folder names)
# -----------------------------------------------------------------------------
run_gamemode_stage() {
    local user home desktop_dir user_dirs raw_dir dest

    user=$(get_real_user)
    home=$(get_real_home)

    desktop_dir="${home}/Desktop"
    if [[ ! -d "$desktop_dir" ]]; then
        user_dirs="${home}/.config/user-dirs.dirs"
        if [[ -f "$user_dirs" ]]; then
            raw_dir=$(grep -E '^XDG_DESKTOP_DIR=' "$user_dirs" | cut -d'"' -f2 | head -1)
            if [[ -n "$raw_dir" ]]; then
                raw_dir="${raw_dir/#\~/$home}"
                raw_dir="${raw_dir/#\$HOME/$home}"
                [[ "$raw_dir" != /* ]] && raw_dir="${home}/${raw_dir}"
                desktop_dir="$raw_dir"
            fi
        fi
    fi

    if [[ ! -d "$desktop_dir" || ! -f "$GAMEMODE_DESKTOP_SRC" ]]; then
        print_status "Gamemode shortcut" "exists"
        return 0
    fi

    dest="${desktop_dir}/${GAMEMODE_DESKTOP_NAME}"

    local need_copy=0
    if [[ -f "$dest" ]]; then
        cmp -s "$GAMEMODE_DESKTOP_SRC" "$dest" || need_copy=1
    else
        need_copy=1
    fi

    if [[ $need_copy -eq 1 ]]; then
        cp -f "$GAMEMODE_DESKTOP_SRC" "$dest" || return 1
        chown "$user":"$user" "$dest" || return 1
        chmod +x "$dest" || return 1
        print_status "Gamemode shortcut" "done"
    else
        print_status "Gamemode shortcut" "exists"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Stage: HHD settings
# -----------------------------------------------------------------------------
run_hhd_stage() {
    command -v hhdctl &>/dev/null || return 1

    hhdctl set hhd.settings.reset=true &>/dev/null || return 1
    sleep "$HHD_RESET_DELAY"

    local setting
    for setting in "${HHD_SETTINGS[@]}"; do
        hhdctl set "$setting" &>/dev/null || true
    done

    print_status "HHD settings" "done"
    return 0
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
if prepare; then
    print_status "Preparation" "done"
    stages_ok=$((stages_ok + 1))
else
    print_status "Preparation" "error" "$PREP_FAIL_REASON"
    echo -e "${RED}All fixes failed to install.${NC}"
    exit 1
fi

if run_fingerprint_stage; then
    stages_ok=$((stages_ok + 1))
else
    print_status "Fingerprint sensor tweaks" "error" "$FP_FAIL_REASON"
    stages_error=$((stages_error + 1))
fi

if run_gamemode_stage; then
    stages_ok=$((stages_ok + 1))
else
    print_status "Gamemode shortcut" "error"
    stages_error=$((stages_error + 1))
fi

if run_hhd_stage; then
    stages_ok=$((stages_ok + 1))
else
    print_status "HHD settings" "error"
    stages_error=$((stages_error + 1))
fi

# -----------------------------------------------------------------------------
# Final report
# -----------------------------------------------------------------------------
if [[ $stages_error -eq 0 ]]; then
    echo -e "${GREEN}All fixes installed successfully.${NC}"
elif [[ $stages_ok -eq 1 ]]; then
    echo -e "${RED}All fixes failed to install.${NC}"
else
    echo -e "${YELLOW}Completed with errors.${NC}"
fi

if [[ $reboot_needed -eq 1 ]]; then
    echo -e "${YELLOW}Reboot required for kernel arguments to take effect.${NC}"
fi
if [[ $bios_needed -eq 1 ]]; then
    echo -e "${YELLOW}Also, ensure BIOS setting: Advanced -> ACPI Settings -> Enable ACPI Auto Configuration -> Enabled${NC}"
fi
