#!/data/data/com.termux/files/usr/bin/bash
# MR MATRIX TOOLS V1 — Xiaomi LOGO!!! V5 workflow for Termux
# SHOVON XOS 2026 NOV 01

set -o pipefail
umask 077

RESET='\033[0m'; BOLD='\033[1m'; DIM='\033[2m'
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[34m'
MAGENTA='\033[35m'; CYAN='\033[36m'; WHITE='\033[37m'
BRIGHT_RED='\033[91m'; BRIGHT_GREEN='\033[92m'; BRIGHT_YELLOW='\033[93m'
BRIGHT_BLUE='\033[94m'; BRIGHT_MAGENTA='\033[95m'; BRIGHT_CYAN='\033[96m'
BRIGHT_WHITE='\033[97m'
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PYTHON="$(command -v python 2>/dev/null || command -v python3 2>/dev/null || true)"

if [[ -d /storage/emulated/0 && -w /storage/emulated/0 ]]; then
    DEFAULT_BASE="/storage/emulated/0/MR_MATRIX_TOOLS"
else
    DEFAULT_BASE="$HOME/MR_MATRIX_TOOLS"
fi
BASE="${MR_MATRIX_HOME:-$DEFAULT_BASE}"
WORK="$BASE/workspace"
DECOMPILE="$BASE/decompile"
OUTPUT="$BASE/output"
RECOMPILE_OUT="$OUTPUT/recompile"
BACKUP="$BASE/backup"
LOG="$BASE/logs"
ZIP_TEMPLATE="$SCRIPT_DIR/mr_matrix"
PARTITION=""
PARTITION_DEV=""
PARTITION_SIZE=""
PARTITION_RO=""
LOGFILE="$LOG/mr_matrix.log"

mkdir -p "$WORK" "$DECOMPILE" "$OUTPUT" "$RECOMPILE_OUT" "$BACKUP" "$LOG"

root_available() {
    command -v su >/dev/null 2>&1 && su -c 'id' 2>/dev/null | grep -q 'uid=0'
}

# Resolve the by-name symlink as root: many Android builds hide these links
# from the unprivileged Termux namespace.
detect_partition() {
    local result
    result="$(su -c '
        for p in /dev/block/by-name/logo /dev/block/bootdevice/by-name/logo /dev/block/platform/*/by-name/logo /dev/block/platform/*/*/by-name/logo; do
            [ -e "$p" ] || continue
            r=$(readlink -f "$p" 2>/dev/null)
            [ -n "$r" ] && [ -b "$r" ] || continue
            s=$(blockdev --getsize64 "$r" 2>/dev/null)
            case "$s" in ""|*[!0-9]*) continue;; esac
            [ "$s" -gt 0 ] || continue
            ro=$(blockdev --getro "$r" 2>/dev/null); [ -n "$ro" ] || ro=unknown
            printf "%s|%s|%s|%s\n" "$p" "$r" "$s" "$ro"
            exit 0
        done
        find /dev/block -type l -name logo -print 2>/dev/null | while IFS= read -r p; do
            [ -e "$p" ] || continue
            r=$(readlink -f "$p" 2>/dev/null)
            [ -n "$r" ] && [ -b "$r" ] || continue
            s=$(blockdev --getsize64 "$r" 2>/dev/null)
            case "$s" in ""|*[!0-9]*) continue;; esac
            [ "$s" -gt 0 ] || continue
            ro=$(blockdev --getro "$r" 2>/dev/null); [ -n "$ro" ] || ro=unknown
            printf "%s|%s|%s|%s\n" "$p" "$r" "$s" "$ro"
            break
        done
    ' 2>/dev/null | head -n 1)"
    [[ -n "$result" ]] || { PARTITION=""; PARTITION_DEV=""; PARTITION_SIZE=""; PARTITION_RO=""; return 1; }
    PARTITION="${result%%|*}"
    local rest="${result#*|}"
    PARTITION_DEV="${rest%%|*}"
    rest="${rest#*|}"
    PARTITION_SIZE="${rest%%|*}"
    PARTITION_RO="${rest##*|}"
    [[ -n "$PARTITION_DEV" && "$PARTITION_SIZE" =~ ^[0-9]+$ ]]
}

human_size() {
    awk -v b="${1:-0}" 'BEGIN { if (b >= 1073741824) printf "%.2f GiB", b/1073741824; else if (b >= 1048576) printf "%.2f MiB", b/1048576; else if (b >= 1024) printf "%.2f KiB", b/1024; else printf "%d bytes", b }'
}

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOGFILE"; }
pause() { printf '\nPress Enter to continue...'; IFS= read -r _ || true; }
# Cache the network result because the main menu redraws after every action.
# This prevents a slow/offline connection probe from delaying every menu return.
NETWORK_CACHE_STATUS="unknown"
NETWORK_CACHE_TS=0
NETWORK_CACHE_TTL=15

termux_is_online() {
    local now age status=offline
    now="$(date +%s 2>/dev/null)"
    [[ "$now" =~ ^[0-9]+$ ]] || now=0

    if [[ "$NETWORK_CACHE_STATUS" != unknown && "$now" -ge "$NETWORK_CACHE_TS" ]]; then
        age=$((now - NETWORK_CACHE_TS))
        if (( age < NETWORK_CACHE_TTL )); then
            [[ "$NETWORK_CACHE_STATUS" == online ]]
            return $?
        fi
    fi

    # A real HTTPS probe avoids treating Wi-Fi/mobile-data being enabled as
    # proof of internet access. Keep strict upper bounds for slow/offline links.
    if command -v curl >/dev/null 2>&1; then
        if curl -fsS --range 0-0 --connect-timeout 1 --max-time 2 -o /dev/null https://packages.termux.dev/ >/dev/null 2>&1; then
            status=online
        fi
    elif command -v wget >/dev/null 2>&1; then
        if wget -q --spider -T 2 https://packages.termux.dev/ >/dev/null 2>&1; then
            status=online
        fi
    fi

    NETWORK_CACHE_STATUS="$status"
    NETWORK_CACHE_TS="$now"
    [[ "$status" == online ]]
}

print_status_block() {
    if root_available; then
        printf "  ${BRIGHT_GREEN}• ROOT ACCESS${RESET}   ${DIM}:${RESET} ${BRIGHT_RED}${BOLD}GRANTED${RESET}\n"
    else
        printf "  ${BRIGHT_GREEN}• ROOT ACCESS${RESET}   ${DIM}:${RESET} ${BRIGHT_YELLOW}${BOLD}NOT GRANTED${RESET}\n"
    fi

    if detect_partition; then
        printf "  ${BRIGHT_CYAN}• LOGO SIZE${RESET}     ${DIM}:${RESET} ${BRIGHT_WHITE}%s BYTES${RESET} ${BRIGHT_GREEN}(%s)${RESET}\n" \
            "$PARTITION_SIZE" "$(human_size "$PARTITION_SIZE")"
    else
        printf "  ${BRIGHT_CYAN}• LOGO SIZE${RESET}     ${DIM}:${RESET} ${BRIGHT_YELLOW}PARTITION NOT DETECTED${RESET}\n"
    fi

    if termux_is_online; then
        printf "  ${BRIGHT_CYAN}• TERMUX STATUS${RESET} ${DIM}:${RESET} ${BRIGHT_GREEN}ONLINE${RESET} ${DIM}|${RESET} ${BRIGHT_YELLOW}IIN${RESET} ${DIM}(Internet available)${RESET}\n"
    else
        printf "  ${BRIGHT_CYAN}• TERMUX STATUS${RESET} ${DIM}:${RESET} ${BRIGHT_YELLOW}OFFLINE${RESET} ${DIM}| IIN unavailable${RESET}\n"
    fi
}

header() {
    clear 2>/dev/null || true
    printf "\n"
    printf "  ${BRIGHT_GREEN}${BOLD}███╗   ███╗██████╗${RESET}\n"
    printf "  ${BRIGHT_GREEN}${BOLD}████╗ ████║██╔══██╗${RESET}\n"
    printf "  ${BRIGHT_GREEN}${BOLD}██╔████╔██║██████╔╝${RESET}\n"
    printf "  ${BRIGHT_GREEN}${BOLD}██║╚██╔╝██║██╔══██╗${RESET}\n"
    printf "  ${BRIGHT_GREEN}${BOLD}██║ ╚═╝ ██║██║  ██║${RESET}\n"
    printf "  ${BRIGHT_GREEN}${BOLD}╚═╝     ╚═╝╚═╝  ╚═╝${RESET}\n\n"
    printf "  ${BRIGHT_CYAN}${BOLD}M R   M A T R I X${RESET}\n"
    printf "  ${BRIGHT_WHITE}${BOLD}MR MATRIX RN10 PRO / MAX${RESET}\n"
    printf "  ${BRIGHT_GREEN}${BOLD}XIAOMI LOGO!!! V5 ENGINE${RESET}\n"
    printf "  ${BRIGHT_MAGENTA}${BOLD}MR MATRIX TOOLS V1${RESET} ${DIM}${WHITE}|${RESET} ${BRIGHT_CYAN}${BOLD}SHOVON XOS${RESET}\n\n"
    if [[ "${1:-}" == "main" ]]; then
        print_status_block
        printf '\n'

    fi
}

need_python() {
    if [[ -z "$PYTHON" ]]; then
        echo "Python is missing. Install it with: pkg install python"
        return 1
    fi
    if [[ ! -f "$SCRIPT_DIR/logo.py" ]]; then
        echo "logo.py is missing beside mr_matrix.sh. Re-extract the complete MR MATRIX package."
        return 1
    fi
    return 0
}

find_source() {
    local chosen
    if [[ -s "$WORK/logo.img" ]]; then
        printf 'Use existing workspace image? [Y/n]: '
        IFS= read -r chosen || return 1
        case "$chosen" in
            ""|[Yy]) return 0 ;;
            [Nn]) ;;
            *) printf '%s\n' 'Cancelled: answer Y or N.'; return 1 ;;
        esac
    fi
    printf 'Enter full path to source logo.img (blank = cancel): '
    IFS= read -r chosen || return 1
    [[ -n "$chosen" && -f "$chosen" ]] || { echo 'Cancelled: source file not found.'; return 1; }
    [[ "$chosen" -ef "$WORK/logo.img" ]] && return 0
    local staged="$WORK/.logo.img.$$"
    cp -f -- "$chosen" "$staged" && mv -f -- "$staged" "$WORK/logo.img" || {
        rm -f -- "$staged"
        return 1
    }
    echo "Source copied to: $WORK/logo.img"
}

backup_logo() {
    local dest stamp actual_size dd_output dd_status size_mib suffix=0
    if ! root_available; then
        printf "  ${BRIGHT_RED}Root access unavailable. Grant root to Termux and retry.${RESET}\n"
        return 1
    fi
    if ! detect_partition; then
        printf "  ${BRIGHT_RED}Logo partition could not be detected.${RESET}\n"
        return 1
    fi

    stamp="$(date '+%Y%m%d_%H%M%S')"
    dest="$BACKUP/${stamp}.img"
    while [[ -e "$dest" ]]; do
        ((suffix+=1))
        dest="$BACKUP/${stamp}_${suffix}.img"
    done
    if [[ ! "$PARTITION_DEV" =~ ^/dev/block/[A-Za-z0-9_./-]+$ ]]; then
        printf "  ${BRIGHT_RED}Detected partition path is invalid; backup cancelled.${RESET}\n"
        return 1
    fi

    # Keep paths compact and readable on narrow Termux screens.
    printf "  ${BRIGHT_CYAN}Source :${RESET} ${BRIGHT_WHITE}%s${RESET}\n" "$PARTITION_DEV"
    printf "  ${BRIGHT_CYAN}Backup :${RESET} ${BRIGHT_WHITE}MR_MATRIX_TOOLS/backup/${RESET}\n"
    printf "           ${BRIGHT_GREEN}%s${RESET}\n\n" "$(basename "$dest")"

    # Root reads the block device; the unprivileged Termux process writes the file.
    dd_output="$(su -c "dd if='$PARTITION_DEV' bs=4M" 2>&1 > "$dest")"
    dd_status=$?
    if [[ -n "$dd_output" ]]; then
        printf '[%s] backup dd output: %s\n' "$(date '+%F %T')" "$dd_output" >> "$LOGFILE"
    fi
    if [[ $dd_status -ne 0 || ! -s "$dest" ]]; then
        rm -f -- "$dest"
        printf "  ${BRIGHT_RED}Backup failed. Check root, storage permissions, and kernel/SELinux policy.${RESET}\n"
        [[ -n "$dd_output" ]] && printf "  ${DIM}%s${RESET}\n" "$dd_output"
        return 1
    fi

    actual_size="$(wc -c < "$dest" | tr -d ' ')"
    if [[ "$actual_size" != "$PARTITION_SIZE" ]]; then
        rm -f -- "$dest"
        printf "  ${BRIGHT_RED}Backup rejected: expected %s bytes, received %s bytes.${RESET}\n" "$PARTITION_SIZE" "$actual_size"
        return 1
    fi

    size_mib="$(awk -v b="$actual_size" 'BEGIN { printf "%.2f MiB", b/1048576 }')"
    local workspace_tmp="$WORK/.logo.img.$$"
    if ! cp -f -- "$dest" "$workspace_tmp" || ! mv -f -- "$workspace_tmp" "$WORK/logo.img"; then
        rm -f -- "$workspace_tmp"
        printf "  ${BRIGHT_YELLOW}Backup saved, but workspace copy failed.${RESET}\n"
        printf "  ${BRIGHT_CYAN}Backup file:${RESET} %s\n" "$dest"
        return 1
    fi

    log "Verified partition backup created: $dest bytes=$actual_size"
    printf "  ${BRIGHT_GREEN}${BOLD}BACKUP VERIFIED${RESET}\n"
    printf "  ${BRIGHT_CYAN}Internal storage:${RESET} ${BRIGHT_WHITE}MR_MATRIX_TOOLS/backup/${RESET}\n"
    printf "                   ${BRIGHT_GREEN}%s${RESET}\n" "$(basename "$dest")"
    printf "  ${BRIGHT_YELLOW}File Size       :${RESET} ${BRIGHT_WHITE}%s bytes (%s)${RESET}\n" "$actual_size" "$size_mib"
    printf "  ${BRIGHT_MAGENTA}Workspace       :${RESET} ${BRIGHT_WHITE}MR_MATRIX_TOOLS/workspace/${RESET}\n"
    printf "                   ${BRIGHT_WHITE}logo.img${RESET}\n"
}

decompile_logo() {
    need_python || return 1
    find_source || return 1
    printf "  ${BRIGHT_CYAN}Source :${RESET} workspace/logo.img (%s)\n" "$(human_size "$(wc -c < "$WORK/logo.img" | tr -d ' ')")"
    printf "  ${BRIGHT_CYAN}Output :${RESET} MR_MATRIX_TOOLS/decompile/\n\n"
    printf "  ${BRIGHT_YELLOW}Validating LOGO table and extracting BMPs...${RESET}\n"

    local decompile_output bmp_count f stage_dir
    stage_dir="$(mktemp -d "$DECOMPILE/.extract.XXXXXX" 2>/dev/null)" || {
        printf "  ${BRIGHT_RED}Could not create temporary extraction directory.${RESET}\n"
        return 1
    }

    if decompile_output=$("$PYTHON" "$SCRIPT_DIR/logo.py" extract -i "$WORK/logo.img" -o "$stage_dir" 2>&1); then
        printf '%s\n' "$decompile_output" >> "$LOGFILE"
        bmp_count=0
        for f in "$stage_dir"/logo-*.bmp; do
            [[ -f "$f" ]] && ((bmp_count+=1))
        done
        if [[ "$bmp_count" -ne 4 ]]; then
            rm -rf -- "$stage_dir"
            printf "  ${BRIGHT_RED}Decompile validation failed: expected 4 BMP files, found %s.${RESET}\n" "$bmp_count"
            printf '%s\n' "$decompile_output"
            return 1
        fi

        rm -f -- "$DECOMPILE"/logo-*.bmp || {
            rm -rf -- "$stage_dir"
            printf "  ${BRIGHT_RED}Could not replace previous extracted BMP files.${RESET}\n"
            return 1
        }
        for f in "$stage_dir"/logo-*.bmp; do
            mv -f -- "$f" "$DECOMPILE/" || {
                rm -rf -- "$stage_dir"
                printf "  ${BRIGHT_RED}Could not install extracted BMP files.${RESET}\n"
                return 1
            }
        done
        rm -rf -- "$stage_dir"

        {
            echo 'MR MATRIX TOOLS V1 — Decompile manifest'
            echo "Source: $WORK/logo.img"
            echo "Bytes: $(wc -c < "$WORK/logo.img" | tr -d ' ')"
            echo "Date: $(date '+%F %T')"
            echo
            for f in "$DECOMPILE"/logo-*.bmp; do
                [[ -f "$f" ]] || continue
                "$PYTHON" - "$f" <<'PYINFO'
import os
import struct
import sys

path = sys.argv[1]
with open(path, "rb") as image_file:
    data = image_file.read(54)
if len(data) >= 54 and data[:2] == b"BM":
    width = struct.unpack("<i", data[18:22])[0]
    height = struct.unpack("<i", data[22:26])[0]
    bits = struct.unpack("<H", data[28:30])[0]
    print(f"{os.path.basename(path)} | {width}x{height} | {bits}-bit | {os.path.getsize(path)} bytes")
PYINFO
            done
        } > "$DECOMPILE/manifest.txt"

        # Build a compact, data-driven extraction report for the success screen.
        # Read the BMP headers once; do not infer dimensions or bit depth from names.
        local source_bytes source_size image_report total_image_bytes
        source_bytes="$(wc -c < "$WORK/logo.img" | tr -d ' ')"
        source_size="$(human_size "$source_bytes")"
        image_report="$("$PYTHON" - "$DECOMPILE" <<'PYREPORT'
import os
import struct
import sys

folder = sys.argv[1]
files = [os.path.join(folder, f"logo-{i}.bmp") for i in range(4)]
total = 0
for path in files:
    with open(path, "rb") as image_file:
        header = image_file.read(54)
    if len(header) < 54 or header[:2] != b"BM":
        raise SystemExit(f"Invalid BMP header: {os.path.basename(path)}")
    width = struct.unpack_from("<i", header, 18)[0]
    height = abs(struct.unpack_from("<i", header, 22)[0])
    depth = struct.unpack_from("<H", header, 28)[0]
    size = os.path.getsize(path)
    total += size
    if width <= 0 or height <= 0:
        raise SystemExit(f"Invalid BMP dimensions: {os.path.basename(path)}")
    print(f"{os.path.basename(path)}|{width}x{height}|{depth}-bit|{size}")
print(f"TOTAL|{total}")
PYREPORT
        )" || {
            printf "  ${BRIGHT_RED}Could not read extracted BMP metadata.${RESET}\n"
            return 1
        }
        total_image_bytes="$(printf '%s\n' "$image_report" | awk -F'|' '$1 == "TOTAL" {print $2}')"

        printf "\n  ${BRIGHT_GREEN}${BOLD}DECOMPILE COMPLETE${RESET}\n"
        printf "  ${DIM}------------------------------------------------${RESET}\n"
        printf "  ${BRIGHT_GREEN}${BOLD}EXTRACTION SUMMARY${RESET}\n"
        printf "  ${BRIGHT_CYAN}Result       :${RESET} ${BRIGHT_GREEN}SUCCESS${RESET}\n"
        printf "  ${BRIGHT_CYAN}Source       :${RESET} workspace/logo.img\n"
        printf "  ${BRIGHT_CYAN}Source size  :${RESET} %s (%s bytes)\n" "$source_size" "$source_bytes"
        printf "  ${BRIGHT_CYAN}Images       :${RESET} %s of 4 BMP files extracted\n" "$bmp_count"
        printf "\n  ${BRIGHT_WHITE}${BOLD}EXTRACTED IMAGE DETAILS${RESET}\n"
        printf "  ${DIM}FILE        DIMENSIONS  DEPTH  SIZE${RESET}\n"
        while IFS='|' read -r image_name dimensions bit_depth image_bytes; do
            [[ "$image_name" == TOTAL || -z "$image_name" ]] && continue
            printf "  ${BRIGHT_GREEN}%-10s${RESET} ${WHITE}%-11s${RESET} ${BRIGHT_YELLOW}%-6s${RESET} %s\n" \
                "$image_name" "$dimensions" "$bit_depth" "$(human_size "$image_bytes")"
        done <<< "$image_report"
        printf "  ${DIM}------------------------------------------------${RESET}\n"
        printf "  ${BRIGHT_CYAN}Image data   :${RESET} %s\n" "$(human_size "$total_image_bytes")"
        printf "  ${BRIGHT_CYAN}Output folder:${RESET} MR_MATRIX_TOOLS/decompile/\n"
        printf "  ${BRIGHT_CYAN}Manifest     :${RESET} decompile/manifest.txt\n"
        printf "\n  ${BRIGHT_YELLOW}${BOLD}NEXT STEP${RESET}\n"
        printf "  Edit the four BMP files, then select option 3\n"
        printf "  to generate the recovery ZIP.\n"
        printf "  ${DIM}Preserve image dimensions, order and BMP format.\n"
        log "Decompile completed: source_bytes=$source_bytes images=$bmp_count image_bytes=$total_image_bytes"
    else
        rm -rf -- "$stage_dir"
        printf '%s\n' "$decompile_output" | tee -a "$LOGFILE"
        printf "  ${BRIGHT_RED}Decompile failed. Check logs/mr_matrix.log.${RESET}\n"
        return 1
    fi
}

recompile_logo() {
    need_python || return 1
    [[ -s "$WORK/logo.img" ]] || { printf '  %s\n' "Source missing: $WORK/logo.img. Run Backup or Decompile first."; return 1; }
    local args=() i f src_size out_size final_zip tmpdir tmp_img tmp_zip device_codename
    for i in 0 1 2 3; do
        f="$DECOMPILE/logo-$i.bmp"
        [[ -s "$f" ]] || { printf '  %s\n' "Missing edited image: $f. Run Decompile first."; return 1; }
        args+=( -a "$f" )
    done
    [[ -s "$ZIP_TEMPLATE/META-INF/com/google/android/update-binary" && -s "$ZIP_TEMPLATE/META-INF/com/google/android/updater-script" ]] || {
        printf '  %s\n' 'Recovery ZIP template is missing. Re-extract the complete MR MATRIX package.'; return 1;
    }
    device_codename="$(getprop ro.product.device 2>/dev/null)"
    case "$device_codename" in
        sweet|sweetin) ;;
        *)
            printf '  %s\n' "Unsupported device codename: ${device_codename:-unknown}. This installer is restricted to sweet/sweetin."
            return 1
            ;;
    esac
    if ! detect_partition; then
        printf '  %s\n' 'Cannot verify the current LOGO partition. Grant root access and retry.'
        return 1
    fi
    src_size="$(wc -c < "$WORK/logo.img" | tr -d ' ')"
    if [[ "$src_size" != "$PARTITION_SIZE" ]]; then
        printf '  %s\n' "Source image size ($src_size bytes) does not match the detected LOGO partition ($PARTITION_SIZE bytes)."
        return 1
    fi
    mkdir -p "$RECOMPILE_OUT" "$WORK" || return 1
    final_zip="$RECOMPILE_OUT/mr_matrix_system_boot.zip"
    tmpdir="$(mktemp -d "$WORK/.recompile.XXXXXX" 2>/dev/null)" || { printf '  %s\n' 'Could not create temporary workspace.'; return 1; }
    tmp_img="$tmpdir/logo.img"
    tmp_zip="$tmpdir/mr_matrix_system_boot.zip"
    printf "  ${BRIGHT_CYAN}Source :${RESET} workspace/logo.img (%s)\n" "$(human_size "$(wc -c < "$WORK/logo.img" | tr -d ' ')")"
    printf "  ${BRIGHT_CYAN}Images :${RESET} 4 edited BMP files\n"
    printf "  ${BRIGHT_CYAN}Output :${RESET} MR_MATRIX_TOOLS/output/recompile/\n\n"
    printf "  ${BRIGHT_YELLOW}Rebuilding logo and packaging flashable ZIP...${RESET}\n"
    if ! "$PYTHON" "$SCRIPT_DIR/logo.py" replace -i "$WORK/logo.img" "${args[@]}" -o "$tmp_img" 2>&1 | tee -a "$LOGFILE"; then
        rm -rf -- "$tmpdir"; printf '  %s\n' 'Recompile failed. Existing flashable ZIP was left untouched.'; return 1
    fi
    out_size="$(wc -c < "$tmp_img" | tr -d ' ')"
    if [[ "$src_size" != "$out_size" ]]; then
        rm -rf -- "$tmpdir"; printf '  %s\n' 'Validation failed: rebuilt image size differs from source.'; return 1
    fi
    # Build the recovery ZIP privately. No raw .img/.bin remains in output/recompile.
    if ! "$PYTHON" - "$ZIP_TEMPLATE" "$tmp_img" "$tmp_zip" <<'PY'
import os
import shutil
import stat
import sys
import zipfile

root, logo_image, out = sys.argv[1:]
required = [
    'META-INF/com/google/android/update-binary',
    'META-INF/com/google/android/updater-script',
]
for relative_path in required:
    if not os.path.isfile(os.path.join(root, relative_path)):
        raise SystemExit('Missing recovery component: ' + relative_path)

with zipfile.ZipFile(
    out, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9
) as archive:
    image_info = zipfile.ZipInfo('logo.img')
    image_info.compress_type = zipfile.ZIP_DEFLATED
    image_info.external_attr = (stat.S_IFREG | 0o644) << 16
    with open(logo_image, 'rb') as source_file:
        with archive.open(image_info, 'w', force_zip64=True) as target_file:
            shutil.copyfileobj(source_file, target_file, length=1024 * 1024)

    for relative_path in required:
        source_path = os.path.join(root, relative_path)
        entry_info = zipfile.ZipInfo(relative_path)
        entry_info.compress_type = zipfile.ZIP_DEFLATED
        file_mode = 0o755 if relative_path.endswith('/update-binary') else 0o644
        entry_info.external_attr = (stat.S_IFREG | file_mode) << 16
        with open(source_path, 'rb') as source_file:
            with archive.open(entry_info, 'w') as target_file:
                shutil.copyfileobj(source_file, target_file)

with zipfile.ZipFile(out, 'r') as archive:
    bad_entry = archive.testzip()
    names = set(archive.namelist())
    expected_names = {'logo.img', *required}
    if bad_entry:
        raise SystemExit('ZIP CRC test failed at ' + bad_entry)
    if names != expected_names:
        raise SystemExit('Unexpected ZIP entries: ' + repr(sorted(names)))
    if archive.getinfo('logo.img').file_size != os.path.getsize(logo_image):
        raise SystemExit('ZIP logo.img length mismatch')

    for relative_path in required:
        actual_mode = (archive.getinfo(relative_path).external_attr >> 16) & 0o777
        expected_mode = 0o755 if relative_path.endswith('/update-binary') else 0o644
        if actual_mode != expected_mode:
            raise SystemExit('Incorrect ZIP permissions: ' + relative_path)

print('Flashable ZIP structure, permissions, image size and CRC checks passed.')
PY
    then
        rm -rf -- "$tmpdir"; printf '  %s\n' 'Recovery ZIP packaging failed. Existing flashable ZIP was left untouched.'; return 1
    fi
    if ! mv -f -- "$tmp_zip" "$final_zip"; then
        rm -rf -- "$tmpdir"; printf '  %s\n' 'Could not install the validated ZIP into output/recompile.'; return 1
    fi
    local zip_size zip_hash
    zip_size="$(wc -c < "$final_zip" | tr -d ' ')"
    zip_hash="$(sha256sum "$final_zip" 2>/dev/null | awk '{print $1}')"
    rm -rf -- "$tmpdir"
    printf "\n  ${BRIGHT_GREEN}${BOLD}RECOMPILE SUCCESS${RESET}\n"
    printf "  ${BRIGHT_CYAN}Source :${RESET} workspace/logo.img\n"
    printf "  ${BRIGHT_CYAN}Images :${RESET} 4 edited BMP files\n"
    printf "  ${BRIGHT_CYAN}ZIP    :${RESET} validated (size + CRC)\n"
    printf "  ${BRIGHT_CYAN}Output :${RESET} output/recompile/mr_matrix_system_boot.zip\n"
    printf "  ${BRIGHT_YELLOW}Flash only in a compatible recovery after verifying your backup.${RESET}\n"
    log "Recompile ZIP created: $final_zip size=$zip_size sha256=$zip_hash"
}

physical_info() {
    printf "  ${BRIGHT_CYAN}${BOLD}Partition information${RESET}\n\n"
    printf "  ${BRIGHT_CYAN}Android :${RESET} %s\n" "$(getprop ro.build.version.release 2>/dev/null || echo unknown)"
    printf "  ${BRIGHT_CYAN}Device  :${RESET} %s\n" "$(getprop ro.product.device 2>/dev/null || echo unknown)"
    printf "  ${BRIGHT_CYAN}Model   :${RESET} %s\n" "$(getprop ro.product.model 2>/dev/null || echo unknown)"
    printf "  ${BRIGHT_CYAN}Kernel  :${RESET} %s\n" "$(uname -r 2>/dev/null || echo unknown)"
    if ! detect_partition; then
        printf "  ${BRIGHT_RED}Link    :${RESET} unavailable\n"
        printf "  ${BRIGHT_RED}Target  :${RESET} not detected\n"
        printf "  ${BRIGHT_RED}Bytes   :${RESET} unavailable\n"
        printf "  ${BRIGHT_RED}Size    :${RESET} unavailable\n"
        return 1
    fi
    printf "  ${BRIGHT_CYAN}Link    :${RESET} %s\n" "$PARTITION"
    printf "  ${BRIGHT_CYAN}Target  :${RESET} %s\n" "$PARTITION_DEV"
    printf "  ${BRIGHT_CYAN}Bytes   :${RESET} %s\n" "$PARTITION_SIZE"
    printf "  ${BRIGHT_CYAN}Size    :${RESET} %s\n" "$(human_size "$PARTITION_SIZE")"
}

list_backups() {
    local files=() f bytes size_mib
    shopt -s nullglob
    files=("$BACKUP"/*.img)
    shopt -u nullglob
    if [[ ${#files[@]} -eq 0 ]]; then
        printf "  ${BRIGHT_YELLOW}No backups found.${RESET}\n"
        printf "  ${DIM}Location: MR_MATRIX_TOOLS/backup/${RESET}\n"
        return 0
    fi
    printf "  ${BRIGHT_CYAN}${BOLD}SAVED LOGO BACKUPS${RESET}\n"
    printf "  ${DIM}Internal storage: MR_MATRIX_TOOLS/backup/${RESET}\n\n"
    for f in "${files[@]}"; do
        [[ -f "$f" ]] || continue
        bytes="$(wc -c < "$f" | tr -d ' ')"
        size_mib="$(awk -v b="$bytes" 'BEGIN { printf "%.2f MiB", b/1048576 }')"
        printf "  ${BRIGHT_GREEN}• %s${RESET}\n" "$(basename "$f")"
        printf "    ${BRIGHT_YELLOW}Size:${RESET} %s bytes ${BRIGHT_WHITE}(%s)${RESET}\n" "$bytes" "$size_mib"
    done
}

config_check() {
    local failed=0 warnings=0 passed=0
    local f missing_commands=""
    local update_binary="$ZIP_TEMPLATE/META-INF/com/google/android/update-binary"
    local updater_script="$ZIP_TEMPLATE/META-INF/com/google/android/updater-script"

    cfg_emit() {
        local tag="$1" color="$2" label="$3"
        printf "  ${color}[%-4s]${RESET} ${WHITE}%s${RESET}\n" "$tag" "$label"
    }
    cfg_pass() { cfg_emit PASS "$BRIGHT_GREEN" "$1"; ((passed+=1)); }
    cfg_warn() { cfg_emit WARN "$BRIGHT_YELLOW" "$1"; ((warnings+=1)); }
    cfg_miss() { cfg_emit MISS "$BRIGHT_RED" "$1"; ((failed+=1)); }

    printf "  ${BRIGHT_CYAN}${BOLD}CONFIGURATION CHECK${RESET}\n"
    printf "  ${DIM}Termux runtime and project resources${RESET}\n\n"

    printf "  ${BRIGHT_GREEN}${BOLD}TERMUX RUNTIME${RESET}\n"
    if [[ "${PREFIX:-}" == *"/com.termux/files/usr"* || -n "${TERMUX_VERSION:-}" || "${HOME:-}" == *"/com.termux/files/home"* ]]; then
        cfg_pass "Platform"
    else
        cfg_warn "Platform"
    fi
    cfg_pass "Bash runtime"
    if [[ -n "$PYTHON" && -x "$PYTHON" ]]; then
        cfg_pass "Python runtime"
    else
        cfg_miss "Python runtime"
    fi

    for f in awk grep sed readlink wc tr date mkdir cp rm mv mktemp find head tee dd; do
        if ! command -v "$f" >/dev/null 2>&1; then
            missing_commands+="${missing_commands:+, }$f"
        fi
    done
    if [[ -z "$missing_commands" ]]; then
        cfg_pass "Core utilities"
    else
        cfg_miss "Core utilities"
    fi

    if command -v blockdev >/dev/null 2>&1; then
        cfg_pass "Partition utility"
    else
        cfg_warn "Partition utility"
    fi

    printf "\n  ${BRIGHT_MAGENTA}${BOLD}CORE PROJECT FILES${RESET}\n"
    if [[ -s "$SCRIPT_DIR/mr_matrix.sh" ]]; then
        cfg_pass "Main Bash script"
        if bash -n "$SCRIPT_DIR/mr_matrix.sh" 2>/dev/null; then
            cfg_pass "Bash syntax"
        else
            cfg_miss "Bash syntax"
        fi
    else
        cfg_miss "Main Bash script"
    fi

    if [[ -s "$SCRIPT_DIR/logo.py" ]]; then
        cfg_pass "Python LOGO engine"
        if [[ -n "$PYTHON" ]] && "$PYTHON" - "$SCRIPT_DIR/logo.py" <<'PYCODE'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
compile(path.read_bytes(), str(path), 'exec')
PYCODE
        then
            cfg_pass "Python syntax"
        else
            cfg_miss "Python syntax"
        fi
        if [[ -n "$PYTHON" ]] && "$PYTHON" -c 'import hashlib,pathlib,shutil,stat,struct,zipfile,zlib' >/dev/null 2>&1; then
            cfg_pass "Python libraries"
        else
            cfg_miss "Python libraries"
        fi
    else
        cfg_miss "Python LOGO engine"
    fi

    if [[ -s "$update_binary" ]]; then
        cfg_pass "Recovery binary"
    else
        cfg_miss "Recovery binary"
    fi
    if [[ -s "$updater_script" ]]; then
        cfg_pass "Recovery script"
    else
        cfg_miss "Recovery script"
    fi

    printf "\n  ${BRIGHT_CYAN}${BOLD}VALIDATION SUMMARY${RESET}\n"
    printf "  ${BRIGHT_GREEN}PASS${RESET} %-3s  ${BRIGHT_YELLOW}WARN${RESET} %-3s  ${BRIGHT_RED}MISS${RESET} %-3s\n" \
        "$passed" "$warnings" "$failed"
    if (( failed == 0 )); then
        printf "\n  ${BRIGHT_GREEN}${BOLD}CONFIGURATION CHECK PASSED${RESET}\n"
        if (( warnings > 0 )); then
            printf "  ${DIM}Required checks passed; review warnings.${RESET}\n"
        else
            printf "  ${DIM}All runtime and project checks passed.${RESET}\n"
        fi
    else
        printf "\n  ${BRIGHT_RED}${BOLD}CONFIGURATION CHECK FAILED${RESET}\n"
        printf "  ${DIM}Review failed checks and run the validation again.${RESET}\n"
    fi
}
confirm_action() {
    local answer
    printf "  ${BRIGHT_YELLOW}Confirm? [y/N]:${RESET} "
    IFS= read -r answer || return 1
    [[ "$answer" == y || "$answer" == Y || "$answer" == yes || "$answer" == YES ]]
}

maintenance() {
    local choice answer
    while true; do
        header
        printf "  ${BRIGHT_CYAN}${BOLD}MAINTENANCE${RESET}\n\n"
        printf "  ${BRIGHT_GREEN}1${RESET}  Configuration check\n"
        printf "  ${BRIGHT_CYAN}2${RESET}  Clean decompile files\n"
        printf "  ${BRIGHT_YELLOW}3${RESET}  Clean recompile output\n"
        printf "  ${BRIGHT_MAGENTA}4${RESET}  Clear tool log\n"
        printf "  ${BRIGHT_WHITE}0${RESET}  Back\n\n"
        printf "  ${BRIGHT_GREEN}Select:${RESET} "
        IFS= read -r choice || return 0
        choice="${choice#"${choice%%[![:space:]]*}"}"
        choice="${choice%"${choice##*[![:space:]]}"}"
        case "$choice" in
            1) header; config_check; pause ;;
            2)
                printf "\n  Remove only logo-*.bmp and manifest.txt from MR_MATRIX_TOOLS/decompile/?\n"
                if confirm_action; then
                    rm -f -- "$DECOMPILE"/logo-*.bmp "$DECOMPILE/manifest.txt"
                    printf "  ${BRIGHT_GREEN}Decompile images and manifest cleared.${RESET}\n"
                    log 'Maintenance: decompile images and manifest cleared.'
                else printf "  ${BRIGHT_YELLOW}Cancelled; files preserved.${RESET}\n"; fi
                pause ;;
            3)
                printf "\n  Remove the generated flashable ZIP and temporary .recompile.* folders?\n"
                printf "  ${BRIGHT_YELLOW}Workspace source and backups will be preserved.${RESET}\n"
                if confirm_action; then
                    rm -f -- "$RECOMPILE_OUT/mr_matrix_system_boot.zip"
                    shopt -s nullglob
                    local temp_builds=("$WORK"/.recompile.*)
                    shopt -u nullglob
                    for answer in "${temp_builds[@]}"; do [[ -d "$answer" ]] && rm -rf -- "$answer"; done
                    printf "  ${BRIGHT_GREEN}Recompile outputs cleared; source and backups preserved.${RESET}\n"
                    log 'Maintenance: recompile output ZIP and temporary build folders cleared.'
                else printf "  ${BRIGHT_YELLOW}Cancelled; outputs preserved.${RESET}\n"; fi
                pause ;;
            4)
                printf "\n  Clear MR_MATRIX_TOOLS/logs/mr_matrix.log?\n"
                if confirm_action; then : > "$LOGFILE" && printf "  ${BRIGHT_GREEN}Log cleared.${RESET}\n"; else printf "  ${BRIGHT_YELLOW}Cancelled; log preserved.${RESET}\n"; fi
                pause ;;
            0) return 0 ;;
            *)
                if [[ -z "$choice" ]]; then printf "\n  ${BRIGHT_YELLOW}[!] No selection entered. Choose 0–4.${RESET}\n"; else printf "\n  ${BRIGHT_YELLOW}[!] Invalid choice: %s. Choose 0–4.${RESET}\n" "$choice"; fi
                pause ;;
        esac
    done
}

troubleshooting() {
    # Fixed-width columns: labels, colons, values, and wrapped lines align exactly.
    local label_width=20
    local value_indent="                        " # 24 spaces: start of the value column
    printf "  ${BRIGHT_YELLOW}${BOLD}TROUBLESHOOTING${RESET} ${DIM}/${RESET} ${BRIGHT_CYAN}${BOLD}QUICK FIXES${RESET}\n\n"

    printf "  ${BRIGHT_RED}${BOLD}REQUIREMENTS${RESET}\n"
    printf "  ${WHITE}%-${label_width}s${DIM}:${RESET} ${BRIGHT_CYAN}pkg install python${RESET}\n" "Python missing"
    printf "  ${WHITE}%-${label_width}s${DIM}:${RESET} ${BRIGHT_CYAN}termux-setup-storage${RESET}\n" "Storage denied"
    printf "  ${WHITE}%-${label_width}s${DIM}:${RESET} Grant root access to\n" "Root unavailable"
    printf "%syour root manager.\n\n" "$value_indent"

    printf "  ${BRIGHT_MAGENTA}${BOLD}IMAGE / RECOMPILE${RESET}\n"
    printf "  ${WHITE}%-${label_width}s${DIM}:${RESET} Use raw Xiaomi LOGO\n" "Invalid LOGO image"
    printf "%simage; not ZIP/sparse.\n" "$value_indent"
    printf "  ${WHITE}%-${label_width}s${DIM}:${RESET} Run option 2 before\n" "BMP files missing"
    printf "%soption 3.\n" "$value_indent"
    printf "  ${WHITE}%-${label_width}s${DIM}:${RESET} Keep 24-bit BMP and\n" "BMP rejected"
    printf "%soriginal dimensions.\n" "$value_indent"
    printf "  ${WHITE}%-${label_width}s${DIM}:${RESET} Check log file:\n" "Recompile failed"
    printf "%s${BRIGHT_CYAN}/storage/emulated/0/${RESET}\n" "$value_indent"
    printf "%s${BRIGHT_CYAN}MR_MATRIX_TOOLS/logs/${RESET}\n" "$value_indent"
    printf "%s${BRIGHT_CYAN}mr_matrix.log${RESET}\n\n" "$value_indent"

    printf "  ${BRIGHT_GREEN}${BOLD}BACKUP / OUTPUT${RESET}\n"
    printf "  ${WHITE}%-${label_width}s${DIM}:${RESET} Check root access\n" "Backup failed"
    printf "%sand system policy.\n" "$value_indent"
    printf "  ${WHITE}%-${label_width}s${DIM}:${RESET} Grant root, retry\n" "Partition missing"
    printf "%spartition detection.\n" "$value_indent"
    printf "  ${WHITE}%-${label_width}s${DIM}:${RESET} Recovery ZIP path:\n" "Recovery ZIP"
    printf "%s${BRIGHT_CYAN}/storage/emulated/0/${RESET}\n" "$value_indent"
    printf "%s${BRIGHT_CYAN}MR_MATRIX_TOOLS/output/${RESET}\n" "$value_indent"
    printf "%s${BRIGHT_CYAN}recompile/${RESET}\n" "$value_indent"
    printf "%s${BRIGHT_CYAN}mr_matrix_system_boot.zip${RESET}\n\n" "$value_indent"

    printf "  ${BRIGHT_YELLOW}${BOLD}FLASH SAFETY${RESET}\n"
    # Controlled line lengths prevent mid-word wrapping on narrow Termux screens.
    printf "  Termux does not flash the partition\n"
    printf "  directly. The recovery ZIP writes the\n"
    printf "  LOGO partition. Verify device compatibility\n"
    printf "  and keep a valid backup before installing.\n"
}

about() {
    # About-only layout: keep the main menu and all tool workflows unchanged.
    header

    # Keep About / License status identical to the main menu.
    print_status_block
    printf "\n"

    printf "  ${BRIGHT_GREEN}${BOLD}ABOUT${RESET} ${DIM}/${RESET} ${BRIGHT_CYAN}${BOLD}LICENSE${RESET}\n"
    printf "  ${DIM}Xiaomi LOGO V5 tools for practical,\n"
    printf "  device-focused Android customization.${RESET}\n\n"

    printf "  ${BRIGHT_GREEN}${BOLD}DEVELOPER${RESET}\n"
    printf "  ${WHITE}Name     ${DIM}:${RESET} ${BRIGHT_WHITE}${BOLD}MD SHOVON${RESET}\n"
    printf "  ${WHITE}GitHub   ${DIM}:${RESET} ${BRIGHT_CYAN}github.com/mdshovon97${RESET}\n"
    printf "  ${WHITE}Telegram ${DIM}:${RESET} ${BRIGHT_MAGENTA}SHOVON XOS${RESET}\n"
    printf "  ${DIM}Android tools built for precise,\n"
    printf "  practical customization.${RESET}\n\n"

    printf "  ${BRIGHT_CYAN}${BOLD}LICENSE${RESET}\n"
    printf "  ${WHITE}License  ${DIM}:${RESET} ${BRIGHT_CYAN}GPL-3.0-or-later${RESET} where specified\n"
    printf "  ${WHITE}Full text${DIM}:${RESET} ${BRIGHT_WHITE}GPL-3.0.txt${RESET}\n"
    printf "  ${WHITE}Details  ${DIM}:${RESET} LICENSES.txt ${DIM}|${RESET} NOTICE\n"
    printf "  ${DIM}Third-party components retain their own\n"
    printf "  license terms.${RESET}\n"
}
while true; do
    header main
    printf "  ${BRIGHT_GREEN}1${RESET}  ${WHITE}Backup current logo${RESET}\n"
    printf "  ${BRIGHT_CYAN}2${RESET}  ${WHITE}Decompile logo${RESET}\n"
    printf "  ${BRIGHT_MAGENTA}3${RESET}  ${WHITE}Recompile logo${RESET}\n"
    printf "  ${BRIGHT_YELLOW}4${RESET}  ${WHITE}Partition information${RESET}\n"
    printf "  ${BRIGHT_BLUE}5${RESET}  ${WHITE}List backups${RESET}\n"
    printf "  ${BRIGHT_CYAN}6${RESET}  ${WHITE}Maintenance${RESET}\n"
    printf "  ${BRIGHT_YELLOW}7${RESET}  ${WHITE}Troubleshooting${RESET}\n"
    printf "  ${BRIGHT_GREEN}8${RESET}  ${WHITE}About / License${RESET}\n"
    printf "  ${BRIGHT_RED}0${RESET}  ${WHITE}Exit${RESET}\n\n"
    printf "  ${BRIGHT_GREEN}${BOLD}SELECT${RESET} ${DIM}>${RESET} "
    IFS= read -r choice || { printf "\n  ${BRIGHT_YELLOW}Input closed; exiting safely.${RESET}\n"; exit 0; }
    choice="${choice#"${choice%%[![:space:]]*}"}"
    choice="${choice%"${choice##*[![:space:]]}"}"
    case "$choice" in
        1) header; backup_logo; pause ;;
        2) header; decompile_logo; pause ;;
        3) header; recompile_logo; pause ;;
        4) header; physical_info; pause ;;
        5) header; list_backups; pause ;;
        6) header; maintenance; pause ;;
        7) header; troubleshooting; pause ;;
        8) about; pause ;;
        0) printf "\n  ${BRIGHT_GREEN}MR MATRIX TOOLS closed safely.${RESET}\n\n"; exit 0 ;;
        *)
            if [[ -z "$choice" ]]; then
                printf "\n  ${BRIGHT_YELLOW}[!] No selection entered. Type a number from 0 to 8.${RESET}\n"
            else
                printf "\n  ${BRIGHT_YELLOW}[!] Invalid choice: %s. Type a number from 0 to 8.${RESET}\n" "$choice"
            fi
            pause ;;

    esac
done
