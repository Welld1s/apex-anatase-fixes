#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# apex-steamos-fingerprint-fix
#
# Fixes the OneXPlayer Apex fingerprint reader waking the device from sleep
# on SteamOS. Extracted from apex-anatase-fixes v1.3.11.
#
# Fixes applied:
#   1. Disable PCIe PME wake on the xHCI controller hosting the
#      fingerprint reader (runtime sysfs + persistent udev rule).
#   2. Add kernel argument to ignore the ACPI GPIO wake line:
#      gpiolib_acpi.ignore_wake=AMDI0030:00@58
#
# The kernel argument is made persistent across SteamOS updates by hooking
# into RAUC's post-install phase. A wrapper script calls the stock
# post-install first, then re-applies the kernel argument to the newly
# installed boot entries.
#
# The script is idempotent.
# Version: 1.0.1
# =============================================================================

SCRIPT_VERSION="1.0.1"
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

# RAUC hook paths (using /etc because it is persistent and writable on SteamOS)
RAUC_CONF="/etc/rauc/system.conf"
RAUC_STOCK_POSTINSTALL="/usr/lib/rauc/post-install.sh"
RAUC_HOOK_DIR="/etc/rauc/apex-fingerprint-fix"
RAUC_WRAPPER="${RAUC_HOOK_DIR}/rauc-post-install-wrapper.sh"
RAUC_KARG_HOOK="${RAUC_HOOK_DIR}/add-kernel-arg.sh"

# -----------------------------------------------------------------------------
# State
# -----------------------------------------------------------------------------
reboot_needed=0
bios_needed=0
karg_failed=0

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
# Kernel argument helper
# -----------------------------------------------------------------------------
add_kernel_arg() {
    local karg="$1"

    # Method 1: rpm-ostree (kept for compatibility, rarely used on SteamOS)
    if command -v rpm-ostree >/dev/null 2>&1; then
        local kargs
        kargs=$(rpm-ostree kargs 2>/dev/null || echo "")
        if [[ "$kargs" == *"$karg"* ]]; then
            return 2
        fi
        if rpm-ostree kargs --append-if-missing="$karg" &>/dev/null; then
            return 0
        fi
    fi

    # Method 2: GRUB (fallback)
    if [[ -f /etc/default/grub ]]; then
        local current
        current=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub \
                  | cut -d'"' -f2 || echo "")
        if [[ "$current" == *"$karg"* ]]; then
            return 2
        fi
        sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"\\(.*\\)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\\1 $karg\"|" \
            /etc/default/grub
        if command -v update-grub >/dev/null 2>&1; then
            update-grub &>/dev/null || true
        elif command -v grub-mkconfig >/dev/null 2>&1; then
            grub-mkconfig -o /boot/grub/grub.cfg &>/dev/null || true
        fi
        return 0
    fi

    # Method 3: systemd-boot entries (SteamOS)
    local entries_dir=""
    for d in /boot/efi/loader/entries /boot/loader/entries; do
        if [[ -d "$d" ]]; then
            entries_dir="$d"
            break
        fi
    done

    if [[ -z "$entries_dir" ]]; then
        return 1
    fi

    local entry modified=0 total_with_options=0
    for entry in "$entries_dir"/*.conf; do
        [[ -f "$entry" ]] || continue
        grep -q "^options " "$entry" || continue
        total_with_options=$((total_with_options + 1))
        if grep -q "$karg" "$entry"; then
            continue
        fi
        [[ -f "${entry}.bak" ]] || cp "$entry" "${entry}.bak"
        sed -i "s|^options \\(.*\\)|options \\1 $karg|" "$entry"
        modified=1
    done

    if [[ $total_with_options -eq 0 ]]; then
        return 1
    fi
    if [[ $modified -eq 1 ]]; then
        return 0
    fi
    return 2
}

# -----------------------------------------------------------------------------
# Contents of the RAUC hook scripts
# -----------------------------------------------------------------------------
write_karg_hook() {
    local tmp
    tmp=$(mktemp)

    cat > "$tmp" <<'HOOK_EOF'
#!/usr/bin/env bash
# Managed by apex-steamos-fingerprint-fix.sh
# Called from the RAUC post-install wrapper to re-apply the fingerprint
# wake kernel argument to the newly installed boot entries.
set -euo pipefail

FP_KARG="gpiolib_acpi.ignore_wake=AMDI0030:00@58"

add_kernel_arg() {
    local karg="$1"
    local entries_dir=""
    for d in /boot/efi/loader/entries /boot/loader/entries; do
        if [[ -d "$d" ]]; then
            entries_dir="$d"
            break
        fi
    done

    if [[ -z "$entries_dir" ]]; then
        echo "apex-fingerprint-fix: no systemd-boot entries directory found" >&2
        return 1
    fi

    local entry modified=0 total_with_options=0
    for entry in "$entries_dir"/*.conf; do
        [[ -f "$entry" ]] || continue
        grep -q "^options " "$entry" || continue
        total_with_options=$((total_with_options + 1))
        if grep -q "$karg" "$entry"; then
            continue
        fi
        [[ -f "${entry}.bak" ]] || cp "$entry" "${entry}.bak"
        sed -i "s|^options \\(.*\\)|options \\1 $karg|" "$entry"
        modified=1
    done

    if [[ $total_with_options -eq 0 ]]; then
        echo "apex-fingerprint-fix: no boot entries with 'options' found" >&2
        return 1
    fi
    if [[ $modified -eq 1 ]]; then
        echo "apex-fingerprint-fix: kernel argument re-applied to boot entries"
    fi
    return 0
}

add_kernel_arg "$FP_KARG"
HOOK_EOF

    chmod 755 "$tmp"
    mkdir -p "$(dirname "$RAUC_KARG_HOOK")"
    if [[ ! -f "$RAUC_KARG_HOOK" ]] || ! cmp -s "$tmp" "$RAUC_KARG_HOOK"; then
        cp "$tmp" "$RAUC_KARG_HOOK"
        chmod 755 "$RAUC_KARG_HOOK"
    fi
    rm -f "$tmp"
}

write_wrapper_hook() {
    local tmp
    tmp=$(mktemp)

    cat > "$tmp" <<WRAPPER_EOF
#!/usr/bin/env bash
# Managed by apex-steamos-fingerprint-fix.sh
# Wrapper around SteamOS stock RAUC post-install.
# Runs the stock hook first, then re-applies our kernel argument.
set -euo pipefail

STOCK="${RAUC_STOCK_POSTINSTALL}"
OUR_HOOK="${RAUC_KARG_HOOK}"

# Run the stock post-install if it exists (it almost certainly does).
if [[ -x "\$STOCK" ]]; then
    "\$STOCK" "\$@"
else
    echo "apex-fingerprint-fix: stock post-install not found at \$STOCK" >&2
fi

# Then apply our kernel argument fix.
if [[ -x "\$OUR_HOOK" ]]; then
    "\$OUR_HOOK" "\$@" || true
fi
WRAPPER_EOF

    chmod 755 "$tmp"
    mkdir -p "$(dirname "$RAUC_WRAPPER")"
    if [[ ! -f "$RAUC_WRAPPER" ]] || ! cmp -s "$tmp" "$RAUC_WRAPPER"; then
        cp "$tmp" "$RAUC_WRAPPER"
        chmod 755 "$RAUC_WRAPPER"
    fi
    rm -f "$tmp"
}

# -----------------------------------------------------------------------------
# Stage: RAUC post-install hook
# -----------------------------------------------------------------------------
run_rauc_hook_stage() {
    local changed=0 failed=0

    # ---- 1. Write the helper scripts to /etc/rauc/... ----------------------
    if ! write_karg_hook; then
        failed=1
    fi
    if ! write_wrapper_hook; then
        failed=1
    fi

    # ---- 2. Patch /etc/rauc/system.conf ------------------------------------
    if [[ $failed -eq 0 ]]; then
        if [[ ! -f "$RAUC_CONF" ]]; then
            print_status "RAUC post-install hook" "error" "$RAUC_CONF not found."
            return 1
        fi

        # Check whether our wrapper is already configured.
        if grep -q "post-install=${RAUC_WRAPPER}" "$RAUC_CONF" 2>/dev/null; then
            changed=0  # already in place
        else
            # Back up once before first modification.
            [[ -f "${RAUC_CONF}.apex-fix.bak" ]] || cp "$RAUC_CONF" "${RAUC_CONF}.apex-fix.bak"

            # Replace the existing post-install line.
            if grep -q '^post-install=' "$RAUC_CONF"; then
                sed -i "s|^post-install=.*|post-install=${RAUC_WRAPPER}|" "$RAUC_CONF"
            else
                # Insert after [handlers] if present, otherwise append.
                if grep -q '^\[handlers\]' "$RAUC_CONF"; then
                    sed -i "/^\[handlers\]/a post-install=${RAUC_WRAPPER}" "$RAUC_CONF"
                else
                    printf '\n[handlers]\npost-install=%s\n' "$RAUC_WRAPPER" >> "$RAUC_CONF"
                fi
            fi
            changed=1
        fi
    fi

    # ---- 3. Restart RAUC so the new config is loaded -----------------------
    if [[ $failed -eq 0 && $changed -eq 1 ]]; then
        if systemctl restart rauc &>/dev/null; then
            :
        else
            echo -e "${YELLOW}Warning: could not restart RAUC service; config will take effect on next boot.${NC}" >&2
        fi
    fi

    if [[ $failed -eq 1 ]]; then
        print_status "RAUC post-install hook" "error"
        return 1
    fi
    if [[ $changed -eq 1 ]]; then
        print_status "RAUC post-install hook" "done"
    else
        print_status "RAUC post-install hook" "not needed"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
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

# --- Stage: Fingerprint fix --------------------------------------------------
changed=0
fail_reason=""

wake="/sys/bus/pci/devices/${controller}/power/wakeup"
if [[ ! -f "$wake" ]]; then
    print_status "Fingerprint sensor tweaks" "error" "Wake path not accessible."
    exit 1
fi

current=$(cat "$wake" 2>/dev/null || echo "")
if [[ "$current" != "disabled" ]]; then
    if echo "disabled" | tee "$wake" >/dev/null; then
        changed=1
    else
        fail_reason="Failed to disable PME."
    fi
fi

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

karg_rc=0
add_kernel_arg "$FP_KARG" || karg_rc=$?
if [[ $karg_rc -eq 0 ]]; then
    changed=1
    reboot_needed=1
    bios_needed=1
elif [[ $karg_rc -eq 1 ]]; then
    karg_failed=1
fi

if [[ -n "$fail_reason" ]]; then
    print_status "Fingerprint sensor tweaks" "error" "$fail_reason"
elif [[ $changed -eq 1 ]]; then
    print_status "Fingerprint sensor tweaks" "done"
else
    print_status "Fingerprint sensor tweaks" "not needed"
fi

# --- Stage: RAUC post-install hook -------------------------------------------
run_rauc_hook_stage || true

# -----------------------------------------------------------------------------
# Final report
# -----------------------------------------------------------------------------
echo
if [[ $reboot_needed -eq 1 ]]; then
    echo -e "${YELLOW}Reboot required to apply the kernel argument.${NC}"
fi
if [[ $bios_needed -eq 1 ]]; then
    echo -e "${YELLOW}Also, ensure BIOS setting:${NC}"
    echo -e "${YELLOW}  Advanced -> ACPI Settings -> Enable ACPI Auto Configuration -> Enabled${NC}"
fi
if [[ $karg_failed -eq 1 ]]; then
    echo -e "${YELLOW}WARNING: Could not automatically add kernel argument:${NC}"
    echo -e "${YELLOW}  $FP_KARG${NC}"
    echo -e "${YELLOW}The udev rule fix (PCIe PME) is still active, and the RAUC${NC}"
    echo -e "${YELLOW}post-install hook has been installed to re-attempt on next update.${NC}"
fi
