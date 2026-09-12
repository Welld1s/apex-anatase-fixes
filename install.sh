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
#     Steam setup               - silent autostart, desktop gamepad tweak,
#                                 on-screen keyboard scaling fix
#
#   The script is idempotent: it checks current state before making changes.
#
# Version: 1.3.2
# =============================================================================

SCRIPT_VERSION="1.3.2"
echo "apex-anatase-fixes v$SCRIPT_VERSION"
echo "============================"

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

# Read a variable from the environment of the user's graphical session.
# kwin_wayland does not export DISPLAY/XAUTHORITY in its own environ, so we
# try several sources in order and return the first non-empty value.
read_session_var() {
    local user="$1" var="$2"
    local uid pid name val

    uid=$(id -u "$user" 2>/dev/null || echo "")

    for name in plasmashell kwin_wayland kwin_x11 Xwayland xdg-desktop-portal-kde; do
        pid=$(pgrep -u "$user" -x "$name" 2>/dev/null | head -1)
        [[ -z "$pid" ]] && continue
        val=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
              | grep "^${var}=" | head -1 | cut -d= -f2-)
        if [[ -n "$val" ]]; then
            echo "$val"
            return 0
        fi
    done

    if [[ -n "$uid" ]]; then
        val=$(sudo -u "$user" \
                env XDG_RUNTIME_DIR="/run/user/$uid" \
                systemctl --user show-environment 2>/dev/null \
              | grep "^${var}=" | head -1 | cut -d= -f2-)
        if [[ -n "$val" ]]; then
            echo "$val"
            return 0
        fi
    fi

    if [[ "$var" == "XAUTHORITY" && -n "$uid" ]]; then
        val=$(ls -1t /run/user/"$uid"/xauth_* 2>/dev/null | head -1 || true)
        if [[ -n "$val" ]]; then
            echo "$val"
            return 0
        fi
    fi

    return 1
}

steam_as_user() {
    local user home uid
    user=$(get_real_user)
    home=$(get_real_home)
    uid=$(id -u "$user")

    local s_display s_wayland s_xauth s_runtime
    s_display=$(read_session_var "$user" DISPLAY         || echo "")
    s_wayland=$(read_session_var "$user" WAYLAND_DISPLAY || echo "")
    s_xauth=$(read_session_var   "$user" XAUTHORITY      || echo "")
    s_runtime=$(read_session_var "$user" XDG_RUNTIME_DIR || echo "/run/user/$uid")

    sudo -u "$user" env \
        HOME="$home" \
        DISPLAY="${s_display:-${DISPLAY:-:0}}" \
        WAYLAND_DISPLAY="${s_wayland:-${WAYLAND_DISPLAY:-wayland-0}}" \
        XAUTHORITY="${s_xauth:-$home/.Xauthority}" \
        XDG_RUNTIME_DIR="$s_runtime" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=${s_runtime}/bus" \
        XDG_CURRENT_DESKTOP="KDE" \
        "$@"
}

x11_as_user() {
    steam_as_user xprop "$@"
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
        busctl --user --quiet call org.kde.KWin "$@"
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
# Stage: Preparation
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

# Read a single HHD setting. Tolerates a few output shapes:
#   "value", "key=value", "key: value", quotes, trailing whitespace.
hhd_get() {
    local key="$1" out
    out=$(hhdctl get "$key" 2>/dev/null | head -1) || return 1
    [[ -z "$out" ]] && return 1
    out="${out#"$key"=}"
    out="${out#"$key": }"
    out="${out#"$key":}"
    out=$(printf '%s' "$out" | awk '{ sub(/^[ \t]+/,""); sub(/[ \t]+$/,""); print }')
    out="${out#\"}"; out="${out%\"}"
    out="${out#\'}"; out="${out%\'}"
    printf '%s' "$out"
}

# Returns 0 if every setting in HHD_SETTINGS already matches the live config.
hhd_settings_match() {
    local setting key expected current
    for setting in "${HHD_SETTINGS[@]}"; do
        key="${setting%%=*}"
        expected="${setting#*=}"
        if ! current=$(hhd_get "$key"); then
            return 1
        fi
        if [[ "$current" != "$expected" ]]; then
            return 1
        fi
    done
    return 0
}

run_hhd_stage() {
    command -v hhdctl &>/dev/null || return 1

    if hhd_settings_match; then
        print_status "HHD settings" "not needed"
        return 0
    fi

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
    win_list=$(x11_as_user -root _NET_CLIENT_LIST 2>/dev/null \
               | sed 's/.*# //' | tr ',' '\n' | tr -d ' ')

    local candidates=()

    for win in $win_list; do
        [[ -n "$win" ]] || continue

        local wmclass
        wmclass=$(x11_as_user -id "$win" WM_CLASS 2>/dev/null \
                  | sed 's/^[^=]*= //' | tr -d '"' \
                  | tr 'A-Z' 'a-z' | tr -s ' ' | sed 's/^ //;s/ $//')
        case "$wmclass" in
            *steamwebhelper*) ;;
            *) continue ;;
        esac

        local name
        name=$(x11_as_user -id "$win" _NET_WM_NAME 2>/dev/null \
               | sed 's/^[^=]*= //' | tr -d '"')
        [[ -n "$name" ]] || continue

        local lname
        lname=$(echo "$name" | tr 'A-Z' 'a-z')
        case "$lname" in
            *keyboard*|*клавиатура*)
                echo "$win"
                return 0
                ;;
        esac
        candidates+=("$win:$name")
    done

    if [[ ${#candidates[@]} -eq 1 ]]; then
        echo "${candidates[0]%%:*}"
        return 0
    fi

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

    kwin_call /Scripting org.kde.kwin.Scripting loadScript s "$script_file" &>/dev/null || true
    kwin_call /Scripting org.kde.kwin.Scripting start &>/dev/null || true

    sleep 0.5
    kwin_call /Scripting org.kde.kwin.Scripting unloadScript s "$script_name" &>/dev/null || true

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
# KWin rule helpers (Steam keyboard)
# -----------------------------------------------------------------------------

# Expected key=value pairs for the Steam keyboard rule. Only "title" is dynamic.
steam_rule_expected() {
    local title="$1"
    cat <<EOF
Description=Window settings for Steam Keyboard
above=true
aboverule=2
ignoregeometry=true
ignoregeometryrule=2
maximizehoriz=true
maximizehorizrule=2
opacityinactive=75
opacityinactiverule=2
position=0,238
positionrule=2
skiptaskbar=true
skiptaskbarrule=2
title=${title}
titlematch=2
wmclass=steam
wmclasscomplete=true
wmclassmatch=2
EOF
}

# All expected keys, one per line, sorted and unique.
steam_rule_expected_keys() {
    steam_rule_expected "$1" | cut -d= -f1 | sort -u
}

# Returns 0 if every expected key has the expected value in the rule group.
steam_rule_params_ok() {
    local uuid="$1" title="$2" line key expected current
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        key="${line%%=*}"
        expected="${line#*=}"
        current=$(steam_as_user kreadconfig6 --file kwinrulesrc \
            --group "$uuid" --key "$key" --default "" 2>/dev/null || echo "")
        [[ "$current" == "$expected" ]] || return 1
    done < <(steam_rule_expected "$title")
    return 0
}

# Returns 0 if the rule group contains no keys beyond the expected set.
steam_rule_no_extra_keys() {
    local uuid="$1" title="$2"
    local kwinrulesrc expected present k
    kwinrulesrc="$(get_real_home)/.config/kwinrulesrc"
    [[ -f "$kwinrulesrc" ]] || return 0

    expected=$(steam_rule_expected_keys "$title")
    present=$(awk -v g="[$uuid]" '
        $0 == g { s=1; next }
        /^\[/ { s=0 }
        s && /^[^=]+=/ { sub(/=.*/, ""); print }
    ' "$kwinrulesrc" | sort -u)

    while IFS= read -r k; do
        [[ -n "$k" ]] || continue
        if ! grep -qxF "$k" <<< "$expected"; then
            return 1
        fi
    done <<< "$present"
    return 0
}

# Find a rule UUID whose "title" equals the given title. Prints UUID on match.
steam_rule_find_by_title() {
    local title="$1" uuid rule_title rules
    rules=$(steam_as_user kreadconfig6 --file kwinrulesrc --group General \
        --key rules --default "" 2>/dev/null || echo "")
    IFS=',' read -ra _arr <<< "$rules"
    for uuid in "${_arr[@]}"; do
        [[ -n "$uuid" ]] || continue
        rule_title=$(steam_as_user kreadconfig6 --file kwinrulesrc \
            --group "$uuid" --key title --default "" 2>/dev/null || echo "")
        if [[ "$rule_title" == "$title" ]]; then
            echo "$uuid"
            return 0
        fi
    done
    return 1
}

# Delete a rule: remove UUID from [General]/rules and drop the whole group.
steam_rule_delete() {
    local uuid="$1" rules new_rules r
    rules=$(steam_as_user kreadconfig6 --file kwinrulesrc --group General \
        --key rules --default "" 2>/dev/null || echo "")
    new_rules=""
    IFS=',' read -ra _arr <<< "$rules"
    for r in "${_arr[@]}"; do
        [[ -n "$r" && "$r" != "$uuid" ]] || continue
        if [[ -z "$new_rules" ]]; then
            new_rules="$r"
        else
            new_rules="${new_rules},${r}"
        fi
    done
    steam_as_user kwriteconfig6 --file kwinrulesrc --group General \
        --key rules "$new_rules" 2>/dev/null || true
    steam_as_user kwriteconfig6 --file kwinrulesrc --group "$uuid" \
        --delete-group 2>/dev/null || true
}

# Write the full rule (all expected keys) with the given UUID and title.
steam_rule_write() {
    local uuid="$1" title="$2" line key val rules
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        key="${line%%=*}"
        val="${line#*=}"
        steam_as_user kwriteconfig6 --file kwinrulesrc \
            --group "$uuid" --key "$key" "$val"
    done < <(steam_rule_expected "$title")

    rules=$(steam_as_user kreadconfig6 --file kwinrulesrc --group General \
        --key rules --default "" 2>/dev/null || echo "")
    if [[ ",$rules," != *",$uuid,"* ]]; then
        if [[ -z "$rules" ]]; then
            steam_as_user kwriteconfig6 --file kwinrulesrc --group General \
                --key rules "$uuid"
        else
            steam_as_user kwriteconfig6 --file kwinrulesrc --group General \
                --key rules "${rules},${uuid}"
        fi
    fi
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
    if ! pgrep -u "$user" -f "steamwebhelper" >/dev/null 2>&1; then
        echo "Launching Steam (this may take a while)..."

        local exec_line
        exec_line=$(grep -m1 '^Exec=' "$STEAM_DESKTOP_SRC" 2>/dev/null | cut -d= -f2- || echo "")
        if [[ -z "$exec_line" ]]; then
            STEAM_FAIL_REASON="Steam failed to launch."
            return 1
        fi

        exec_line=${exec_line//%U/}
        exec_line=${exec_line//%u/}
        exec_line=${exec_line//%F/}
        exec_line=${exec_line//%f/}
        exec_line=${exec_line//%i/}
        exec_line=${exec_line//%c/}
        exec_line=${exec_line//%k/}
        exec_line=$(echo "$exec_line" | tr -s ' ' | sed 's/ $//')

        local sess_display sess_wayland sess_xauth sess_runtime
        sess_display=$(read_session_var "$user" DISPLAY         || echo "")
        sess_wayland=$(read_session_var "$user" WAYLAND_DISPLAY || echo "")
        sess_xauth=$(read_session_var   "$user" XAUTHORITY      || echo "")
        sess_runtime=$(read_session_var "$user" XDG_RUNTIME_DIR || echo "/run/user/$uid")

        sudo -u "$user" \
            env HOME="$home" \
                XDG_RUNTIME_DIR="$sess_runtime" \
                DBUS_SESSION_BUS_ADDRESS="unix:path=${sess_runtime}/bus" \
            systemd-run --user --quiet --collect \
                --unit="steam-launch-$$" \
                --setenv=DISPLAY="${sess_display:-:0}" \
                --setenv=WAYLAND_DISPLAY="${sess_wayland:-wayland-0}" \
                --setenv=XAUTHORITY="${sess_xauth:-$home/.Xauthority}" \
                --setenv=XDG_CURRENT_DESKTOP=KDE \
                -- $exec_line \
            >/dev/null 2>&1 || true

        for _ in $(seq 1 60); do
            sleep 1
            pgrep -u "$user" -f "steamwebhelper" >/dev/null 2>&1 && break
        done
        sleep 5

        if ! pgrep -u "$user" -f "steamwebhelper" >/dev/null 2>&1; then
            STEAM_FAIL_REASON="Steam failed to launch."
            return 1
        fi
    fi

    # ---- 4. Find keyboard window --------------------------------------------
    local win=""
    win=$(find_steam_keyboard_window 2>/dev/null || true)

    if [[ -z "$win" ]]; then
        steam_as_user steam "steam://open/keyboard" &>/dev/null &
        for _ in $(seq 1 30); do
            sleep 0.5
            win=$(find_steam_keyboard_window 2>/dev/null || true)
            [[ -n "$win" ]] && break
        done
    fi

    if [[ -z "$win" ]]; then
        STEAM_FAIL_REASON="Steam keyboard window not found."
        return 1
    fi

    # ---- 5. Read title and close --------------------------------------------
    local title
    title=$(x11_as_user -id "$win" _NET_WM_NAME 2>/dev/null \
            | sed 's/^[^=]*= //' | tr -d '"')
    if [[ -z "$title" ]]; then
        STEAM_FAIL_REASON="Steam keyboard window title unavailable."
        return 1
    fi

    close_window_by_caption "$title" || true

    # ---- 6. Reconcile KWin window rule --------------------------------------
    local existing_uuid=""
    existing_uuid=$(steam_rule_find_by_title "$title" || true)

    if [[ -n "$existing_uuid" ]]; then
        if steam_rule_params_ok "$existing_uuid" "$title" \
           && steam_rule_no_extra_keys "$existing_uuid" "$title"; then
            : # existing rule is exactly what we want - nothing to do
        else
            steam_rule_delete "$existing_uuid"
            steam_rule_write "$STEAM_RULE_UUID" "$title"
            kwin_call /KWin org.kde.KWin reconfigure &>/dev/null || true
            changed=1
        fi
    else
        steam_rule_write "$STEAM_RULE_UUID" "$title"
        kwin_call /KWin org.kde.KWin reconfigure &>/dev/null || true
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
