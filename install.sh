#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# apex-anatase-fixes
#
# Description:
#   Applies all known fixes for OneXPlayer Apex running Anatase OS.
#   Stages:
#     Preparation              - validate OS, version, hardware
#     Fingerprint sensor tweaks - PME disable + udev rule + GPIO kernel arg
#     Gamemode shortcut        - copy .desktop to user's Desktop
#     HHD settings             - apply curated HHD preset
#     Steam setup              - silent autostart, kwinrc gamepad fix,
#                                keyboard window rule
#
#   The script is idempotent: it checks current state before making changes.
#
# Version: 1.3.0
# =============================================================================

# -----------------------------------------------------------------------------
# Script metadata
# -----------------------------------------------------------------------------
SCRIPT_VERSION="1.3.0"
echo "apex-anatase-fixes v$SCRIPT_VERSION"

# -----------------------------------------------------------------------------
# Auto-elevate to root if not already, preserving graphical session variables
# so the Steam launcher can find the display server later.
# -----------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "Requesting root privileges..."
    exec sudo --preserve-env=DISPLAY,WAYLAND_DISPLAY,XAUTHORITY,XDG_RUNTIME_DIR "$0" "$@"
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
EXPECTED_BOARD_VENDOR="ONE-NETBOOK"
EXPECTED_BOARD_NAME="ONEXPLAYER APEX"

FP_VENDOR="2808"
FP_PRODUCT="c652"
FP_KARG="gpiolib_acpi.ignore_wake=AMDI0030:00@58"
FP_UDEV_RULE="/etc/udev/rules.d/90-fingerprint-no-wake.rules"
FP_UDEV_CONTENT='# Block wake from the xHCI controller hosting the FocalTech fingerprint
# reader. Managed by apex-anatase-fixes.sh.
ACTION=="add", SUBSYSTEM=="pci", KERNEL=="%s", ATTR{power/wakeup}="disabled"
'

GAMEMODE_DESKTOP_SRC="/usr/share/applications/gamemode.desktop"
GAMEMODE_DESKTOP_NAME="gamemode.desktop"

MIN_ANATASE_VERSION="20260907.10"

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

# Steam setup
STEAM_DESKTOP_SRC="/var/lib/flatpak/exports/share/applications/org.anatase.Steam.Silent.desktop"
STEAM_DESKTOP_NAME="org.anatase.Steam.Silent.desktop"
STEAM_RULE_UUID="94ba89ad-c6f6-41ba-9d44-4113517758ff"

# -----------------------------------------------------------------------------
# State
# -----------------------------------------------------------------------------
reboot_needed=0
bios_needed=0

stages_ok=0
stages_error=0

PREP_FAIL_REASON=""
FP_FAIL_REASON=""
STEAM_FAIL_REASON=""

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

steam_as_user() {
    local user home uid
    user=$(get_real_user)
    home=$(get_real_home)
    uid=$(id -u "$user")
    sudo -u "$user" env \
        HOME="$home" \
        DISPLAY="${DISPLAY:-:0}" \
        WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
        XAUTHORITY="$home/.Xauthority" \
        XDG_RUNTIME_DIR="/run/user/$uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        XDG_CURRENT_DESKTOP="KDE" \
        "$@"
}

kwin_call() {
    local user home uid
    user=$(get_real_user)
    home=$(get_real_home)
    uid=$(id -u "$user")
    sudo -u "$user" env \
        HOME="$home" \
        XDG_RUNTIME_DIR="/run/user/$uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        busctl --user --quiet call org.kde.KWin "$@" 2>/dev/null || true
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
    if [[ ! -f /etc/os-release ]]; then
        PREP_FAIL_REASON="Anatase OS not detected."
        return 1
    fi
    source /etc/os-release
    if [[ "$ID" != "anatase" ]]; then
        PREP_FAIL_REASON="Not Anatase OS (detected: $ID)."
        return 1
    fi

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
        print_status "Fingerprint sensor tweaks" "not needed"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Stage: Gamemode shortcut
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
        print_status "Gamemode shortcut" "not needed"
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
        print_status "Gamemode shortcut" "not needed"
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
# Steam helpers
# -----------------------------------------------------------------------------

find_steam_keyboard_window() {
    local win_list win
    win_list=$(steam_as_user xprop -root _NET_CLIENT_LIST 2>/dev/null \
               | sed 's/.*# //' | tr ',' '\n' | tr -d ' ')

    for win in $win_list; do
        [[ -n "$win" ]] || continue

        local wmclass
        wmclass=$(steam_as_user xprop -id "$win" WM_CLASS 2>/dev/null \
                  | sed 's/^[^=]*= //' | tr -d '"')
        case "$wmclass" in
            "steamwebhelper, steam"|"steamwebhelper, steamwebhelper") ;;
            *) continue ;;
        esac

        local wmtype
        wmtype=$(steam_as_user xprop -id "$win" _NET_WM_WINDOW_TYPE 2>/dev/null)
        case "$wmtype" in
            *"_NET_WM_WINDOW_TYPE_UTILITY"*) ;;
            *) continue ;;
        esac

        local ct
        ct=$(steam_as_user xprop -id "$win" _KDE_NET_WM_USER_CREATION_TIME 2>/dev/null \
             | awk -F'= ' '{print $2}' | tr -d ' ')
        [[ -n "$ct" && "$ct" != "0" ]] || continue

        echo "$win"
        return 0
    done
    return 1
}

close_window_by_caption() {
    local title="$1"

    local escaped_title
    escaped_title=$(printf '%s' "$title" | sed 's/\\/\\\\/g; s/"/\\"/g')

    local script_name="apex-close-keyboard-$$"
    local script_file="/tmp/${script_name}.js"
    cat > "$script_file" << EOF
(function () {
    const target = "${escaped_title}";
    for (const w of workspace.windowList()) {
        if (w.caption === target) {
            w.closeWindow();
        }
    }
})();
EOF
    chmod 644 "$script_file"

    kwin_call /Scripting org.kde.kwin.Scripting loadScript s "$script_file"
    kwin_call /Scripting org.kde.kwin.Scripting start
    sleep 0.5
    kwin_call /Scripting org.kde.kwin.Scripting unloadScript s "$script_name"

    rm -f "$script_file"
    return 0
}

steam_ensure_kwinrc() {
    local user home kwinrc current_val new_val
    user=$(get_real_user)
    home=$(get_real_home)
    kwinrc="${home}/.config/kwinrc"

    if [[ -f "$kwinrc" ]]; then
        current_val=$(awk '
            /^\[Xwayland\]/ {s=1; next}
            /^\[/ {s=0}
            s && /^XwaylandEisNoPromptApps=/ {sub(/^[^=]*=/, ""); print}
        ' "$kwinrc")
    fi

    [[ ",${current_val}," == *",steam,"* ]] && return 1

    if [[ -z "$current_val" ]]; then
        new_val="steam"
    else
        new_val="${current_val},steam"
    fi

    steam_as_user kwriteconfig6 --file kwinrc --group Xwayland \
        --key XwaylandEisNoPromptApps "$new_val" 2>/dev/null || true

    return 0
}

# -----------------------------------------------------------------------------
# Stage: Steam setup
# -----------------------------------------------------------------------------
run_steam_stage() {
    local user home uid
    user=$(get_real_user)
    home=$(get_real_home)
    uid=$(id -u "$user")

    if ! command -v xprop >/dev/null 2>&1; then
        STEAM_FAIL_REASON="xprop is not installed."
        return 1
    fi
    if ! command -v busctl >/dev/null 2>&1; then
        STEAM_FAIL_REASON="busctl is not installed."
        return 1
    fi
    if ! command -v kwriteconfig6 >/dev/null 2>&1; then
        STEAM_FAIL_REASON="kwriteconfig6 is not installed."
        return 1
    fi

    local changed=0

    # ---- 1. Silent autostart -------------------------------------------------
    local autostart_dir="${home}/.config/autostart"
    local desktop_dst="${autostart_dir}/${STEAM_DESKTOP_NAME}"

    if [[ ! -f "$desktop_dst" ]]; then
        if [[ ! -f "$STEAM_DESKTOP_SRC" ]]; then
            STEAM_FAIL_REASON="Source .desktop not found: $STEAM_DESKTOP_SRC"
            return 1
        fi
        sudo -u "$user" mkdir -p "$autostart_dir"
        sudo -u "$user" cp "$STEAM_DESKTOP_SRC" "$desktop_dst"
        changed=1
    fi

    # ---- 2. kwinrc Xwayland entry -------------------------------------------
    if steam_ensure_kwinrc; then
        changed=1
        reboot_needed=1
    fi

    # ---- 3. Launch Steam if not running -------------------------------------
    # Full Exec= line taken from the .desktop file verbatim.
    # `su -` gives a login session (needed for flatpak-portal), and the
    # graphical session variables are re-exported explicitly because `su -`
    # resets the environment.
    if ! pgrep -u "$user" -f "steamwebhelper" >/dev/null 2>&1; then
        echo "Launching Steam (this may take a while)..."

        local exec_line
        exec_line=$(grep -E '^Exec=' "$STEAM_DESKTOP_SRC" | head -1 | cut -d= -f2-)

        if [[ -z "$exec_line" ]]; then
            STEAM_FAIL_REASON="Could not read Exec= from $STEAM_DESKTOP_SRC"
            return 1
        fi

        su - "$user" -c "
            export DISPLAY='$DISPLAY' \
                   WAYLAND_DISPLAY='$WAYLAND_DISPLAY' \
                   XDG_RUNTIME_DIR='/run/user/$uid' \
                   DBUS_SESSION_BUS_ADDRESS='unix:path=/run/user/$uid/bus' \
                   XAUTHORITY='$home/.Xauthority' \
                   XDG_CURRENT_DESKTOP='KDE'
            setsid $exec_line >/dev/null 2>&1 < /dev/null &
        "

        for _ in $(seq 1 60); do
            sleep 1
            pgrep -u "$user" -f "steamwebhelper" >/dev/null 2>&1 && break
        done
        sleep 5
    fi

    # ---- 4. Find keyboard window --------------------------------------------
    local win=""
    win=$(find_steam_keyboard_window || true)

    if [[ -z "$win" ]]; then
        steam_as_user steam "steam://open/keyboard" &>/dev/null &
        for _ in $(seq 1 30); do
            sleep 0.5
            win=$(find_steam_keyboard_window || true)
            [[ -n "$win" ]] && break
        done
    fi

    if [[ -z "$win" ]]; then
        STEAM_FAIL_REASON="Steam keyboard window not found."
        return 1
    fi

    # ---- 5. Read title and close --------------------------------------------
    local title
    title=$(steam_as_user xprop -id "$win" _NET_WM_NAME 2>/dev/null \
            | sed 's/^[^=]*= //' | tr -d '"')
    if [[ -z "$title" ]]; then
        STEAM_FAIL_REASON="Could not read keyboard window title."
        return 1
    fi

    close_window_by_caption "$title" || true

    # ---- 6. Write KWin window rule ------------------------------------------
    local existing_title
    existing_title=$(steam_as_user kreadconfig6 --file kwinrulesrc \
        --group "$STEAM_RULE_UUID" --key title --default "" 2>/dev/null || echo "")

    if [[ "$existing_title" != "$title" ]]; then
        steam_as_user kwriteconfig6 --file kwinrulesrc --group "$STEAM_RULE_UUID" --key Description "Window settings for Steam Keyboard"
        steam_as_user kwriteconfig6 --file kwinrulesrc --group "$STEAM_RULE_UUID" --key above "true"
        steam_as_user kwriteconfig6 --file kwinrulesrc --group "$STEAM_RULE_UUID" --key aboverule "2"
        steam_as_user kwriteconfig6 --file kwinrulesrc --group "$STEAM_RULE_UUID" --key ignoregeometry "true"
        steam_as_user kwriteconfig6 --file kwinrulesrc --group "$STEAM_RULE_UUID" --key ignoregeometryrule "2"
        steam_as_user kwriteconfig6 --file kwinrulesrc --group "$STEAM_RULE_UUID" --key maximizehoriz "true"
        steam_as_user kwriteconfig6 --file kwinrulesrc --group "$STEAM_RULE_UUID" --key maximizehorizrule "2"
        steam_as_user kwriteconfig6 --file kwinrulesrc --group "$STEAM_RULE_UUID" --key opacityinactive "75"
        steam_as_user kwriteconfig6 --file kwinrulesrc --group "$STEAM_RULE_UUID" --key opacityinactiverule "2"
        steam_as_user kwriteconfig6 --file kwinrulesrc --group "$STEAM_RULE_UUID" --key position "0,238"
        steam_as_user kwriteconfig6 --file kwinrulesrc --group "$STEAM_RULE_UUID" --key positionrule "2"
        steam_as_user kwriteconfig6 --file kwinrulesrc --group "$STEAM_RULE_UUID" --key skiptaskbar "true"
        steam_as_user kwriteconfig6 --file kwinrulesrc --group "$STEAM_RULE_UUID" --key skiptaskbarrule "2"
        steam_as_user kwriteconfig6 --file kwinrulesrc --group "$STEAM_RULE_UUID" --key title "$title"
        steam_as_user kwriteconfig6 --file kwinrulesrc --group "$STEAM_RULE_UUID" --key titlematch "2"
        steam_as_user kwriteconfig6 --file kwinrulesrc --group "$STEAM_RULE_UUID" --key wmclass "steam"
        steam_as_user kwriteconfig6 --file kwinrulesrc --group "$STEAM_RULE_UUID" --key wmclasscomplete "true"
        steam_as_user kwriteconfig6 --file kwinrulesrc --group "$STEAM_RULE_UUID" --key wmclassmatch "2"

        local rules
        rules=$(steam_as_user kreadconfig6 --file kwinrulesrc --group General \
            --key rules --default "" 2>/dev/null || echo "")
        if [[ ",$rules," != *",$STEAM_RULE_UUID,"* ]]; then
            if [[ -z "$rules" ]]; then
                steam_as_user kwriteconfig6 --file kwinrulesrc --group General --key rules "$STEAM_RULE_UUID"
            else
                steam_as_user kwriteconfig6 --file kwinrulesrc --group General --key rules "${rules},${STEAM_RULE_UUID}"
            fi
        fi

        kwin_call /KWin org.kde.KWin reconfigure

        changed=1
    fi

    if [[ $changed -eq 1 ]]; then
        print_status "Steam setup" "done"
    else
        print_status "Steam setup" "not needed"
    fi
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

if run_steam_stage; then
    stages_ok=$((stages_ok + 1))
else
    print_status "Steam setup" "error" "$STEAM_FAIL_REASON"
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
    echo -e "${YELLOW}Reboot required to apply some fixes.${NC}"
fi
if [[ $bios_needed -eq 1 ]]; then
    echo -e "${YELLOW}Also, ensure BIOS setting: Advanced -> ACPI Settings -> Enable ACPI Auto Configuration -> Enabled${NC}"
fi
