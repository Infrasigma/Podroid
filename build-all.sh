#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Podroid Unified Build & Deploy Script
# Coordinates kernel, initramfs, rootfs, QEMU, and APK builds.
# (libtermux.so is no longer built here — the vendored terminal-emulator
#  module compiles it via AGP's NDK build using src/main/jni/Android.mk.)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JNILIBS="${SCRIPT_DIR}/app/src/main/jniLibs/arm64-v8a"
ASSETS="${SCRIPT_DIR}/app/src/main/assets"
ADMISSION_OUT="${SCRIPT_DIR}/build/admission"

# ── Colors ────────────────────────────────────────────────────────────────────
BLUE='\033[1;34m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m' # No Color

log() { printf "${BLUE}==>${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}WARNING:${NC} %s\n" "$*"; }
error() { printf "${RED}ERROR:${NC} %s\n" "$*"; exit 1; }
success() { printf "${GREEN}SUCCESS:${NC} %s\n" "$*"; }

# ── Help ──────────────────────────────────────────────────────────────────────
show_help() {
    cat <<EOF
Podroid Unified Build Tool

Usage: $0 [command] [options]

Commands:
  all           Build everything (Kernel, Initramfs, Rootfs, QEMU, APK)
  kernel        Build custom kernel only (podroid_kernel.config + Linux source)
  initramfs     Build custom kernel + Alpine VM initramfs (vmlinuz + initrd)
  rootfs        Build Alpine rootfs squashfs (alpine-rootfs.squashfs)
  qemu          Build QEMU + podroid-bridge + podroid-launcher
  apk           Build the Android APK (also builds libtermux.so via Gradle NDK)
  deploy        Build APK, uninstall old version, and install to device
  test          Perform full build, install, and automated boot validation
  admission     Build/install/boot and run ACE guest admission through Podroid's native terminal transport
  clean         Remove build artifacts and temporary containers

Options:
  --fast        Skip QEMU native builds if binaries already exist
  --help        Show help message

EOF
}

# ── NDK Detection ─────────────────────────────────────────────────────────────
find_ndk() {
    if [ -n "${ANDROID_NDK_ROOT:-}" ] && [ -d "$ANDROID_NDK_ROOT" ]; then
        echo "$ANDROID_NDK_ROOT"
    elif [ -n "${ANDROID_HOME:-}" ] && [ -d "${ANDROID_HOME}/ndk" ]; then
        ls -d "${ANDROID_HOME}/ndk/"* 2>/dev/null | sort -V | tail -1
    elif [ -d "$HOME/Android/Sdk/ndk" ]; then
        ls -d "$HOME/Android/Sdk/ndk/"* 2>/dev/null | sort -V | tail -1
    else
        return 1
    fi
}

# ── Verification Helpers ──────────────────────────────────────────────────────
verify_16kb_align() {
    local lib="$1"
    python3 - "$lib" << 'PY'
import struct, sys
path = sys.argv[1]
with open(path, 'rb') as f:
    data = f.read()
e_phoff = struct.unpack_from('<Q', data, 32)[0]
e_phentsize = struct.unpack_from('<H', data, 54)[0]
e_phnum = struct.unpack_from('<H', data, 56)[0]
aligns = []
for i in range(e_phnum):
    off = e_phoff + i * e_phentsize
    if struct.unpack_from('<I', data, off)[0] == 1:
        aligns.append(struct.unpack_from('<Q', data, off + 48)[0])
ok = all(a >= 16384 for a in aligns)
if not ok:
    print(f"FAILED: {path} is not 16KB page aligned!")
    sys.exit(1)
PY
}

# ── Build Functions ───────────────────────────────────────────────────────────

build_kernel() {
    local kernel_ver
    kernel_ver=$(grep -E '^podroidKernelVersion=' "${SCRIPT_DIR}/gradle.properties" | cut -d= -f2)
    log "Building custom kernel ${kernel_ver} for aarch64 (Docker)..."
    docker build --network=host \
        --build-arg "KERNEL_VERSION=${kernel_ver}" \
        -t podroid-kernel-builder --target kernel-builder "$SCRIPT_DIR"
    log "Extracting kernel artifact..."
    docker rm -f podroid-kernel-extract 2>/dev/null || true
    docker create --name podroid-kernel-extract podroid-kernel-builder
    mkdir -p "$ASSETS"
    docker cp podroid-kernel-extract:/output/vmlinuz-virt "$ASSETS/vmlinuz-virt"
    docker rm podroid-kernel-extract >/dev/null
    success "Custom kernel ready."
}

build_initramfs() {
    local kernel_ver
    kernel_ver=$(grep -E '^podroidKernelVersion=' "${SCRIPT_DIR}/gradle.properties" | cut -d= -f2)
    log "Building custom kernel + Alpine Initramfs (Docker)..."
    docker build --network=host \
        --build-arg "KERNEL_VERSION=${kernel_ver}" \
        -t podroid-builder --target packer "$SCRIPT_DIR"

    log "Extracting initramfs artifacts..."
    docker rm podroid-extract 2>/dev/null || true
    docker create --name podroid-extract podroid-builder /bin/true
    mkdir -p "$ASSETS"
    docker cp podroid-extract:/output/vmlinuz-virt "$ASSETS/vmlinuz-virt"
    docker cp podroid-extract:/output/initrd.img "$ASSETS/initrd.img"
    docker rm podroid-extract >/dev/null
    success "Kernel + initramfs ready."
}

build_rootfs() {
    log "Building Alpine rootfs squashfs..."
    local sysver
    sysver=$(grep -E '^[[:space:]]*versionCode[[:space:]]*=' "${SCRIPT_DIR}/app/build.gradle.kts" | grep -oE '[0-9]+' | head -1)
    docker build -f "${SCRIPT_DIR}/build-rootfs/Dockerfile.rootfs" \
        -t podroid-rootfs:latest \
        --build-arg "SYSTEM_VERSION=${sysver:-0}" \
        --output type=local,dest="${ASSETS}" \
        "${SCRIPT_DIR}/build-rootfs/"
    success "Built ${ASSETS}/alpine-rootfs.squashfs ($(du -h "${ASSETS}/alpine-rootfs.squashfs" | cut -f1)), system-version ${sysver:-0}"
}

build_qemu() {
    local qemu_ver
    qemu_ver=$(grep -E '^podroidQemuVersion=' "${SCRIPT_DIR}/gradle.properties" | cut -d= -f2)
    log "Building QEMU ${qemu_ver} for Android ARM64 (Docker)..."
    docker build --build-arg "QEMU_VERSION=${qemu_ver}" \
        -t podroid-qemu-builder --target final "${SCRIPT_DIR}"

    log "Extracting QEMU artifacts..."
    docker rm -f podroid-qemu-extract 2>/dev/null || true
    docker create --name podroid-qemu-extract podroid-qemu-builder /bin/true

    mkdir -p "$JNILIBS" "$ASSETS/qemu/keymaps"
    docker cp podroid-qemu-extract:/libqemu-system-aarch64.so "$JNILIBS/"
    docker cp podroid-qemu-extract:/libslirp.so "$JNILIBS/"
    docker cp podroid-qemu-extract:/libpodroid-bridge.so "$JNILIBS/"
    docker cp podroid-qemu-extract:/libpodroid-launcher.so "$JNILIBS/"
    docker cp podroid-qemu-extract:/qemu/efi-virtio.rom "$ASSETS/qemu/"
    docker cp podroid-qemu-extract:/qemu/keymaps/. "$ASSETS/qemu/keymaps/"
    docker rm podroid-qemu-extract >/dev/null

    verify_16kb_align "$JNILIBS/libqemu-system-aarch64.so"
    success "QEMU and bridge ready."
}

build_apk() {
    log "Building APK via Gradle..."
    ./gradlew assembleDebug
    success "APK built: app/build/outputs/apk/debug/app-debug.apk"
}

deploy_apk() {
    log "Deploying to device..."
    adb uninstall com.excp.podroid.debug || warn "Uninstall failed (likely not installed)."
    adb install -r app/build/outputs/apk/debug/app-debug.apk
    success "Deployed and ready."
}

wait_for_vm_ready() {
    local pkg="com.excp.podroid.debug"
    local timeout="${1:-60}"
    local serial="${2:-}"
    local boot_ok=false
    local -a ADB=(adb)
    [ -n "$serial" ] && ADB=(adb -s "$serial")
    log "Waiting for VM to boot (timeout: ${timeout}s)..."
    for _i in $(seq 1 "$timeout"); do
        local console
        console=$("${ADB[@]}" shell run-as "$pkg" cat files/console.log 2>/dev/null || echo "")
        if echo "$console" | grep -q "Ready!"; then
            boot_ok=true
            break
        fi
        sleep 1
    done
    "$boot_ok" || error "VM failed to reach Ready! within ${timeout}s; inspect adb logcat and console.log."
}

run_boot_test() {
    local pkg="com.excp.podroid.debug"
    local activity="com.excp.podroid.MainActivity"

    log "Starting Automated Boot Test..."
    adb devices 2>/dev/null | grep -q 'device$' || error "No device connected via ADB."
    build_apk
    deploy_apk

    log "Resetting VM storage for clean test..."
    adb shell am force-stop "$pkg" 2>/dev/null || true
    adb shell run-as "$pkg" rm -f files/storage.img 2>/dev/null || true
    adb shell run-as "$pkg" rm -f files/console.log 2>/dev/null || true

    log "Launching App..."
    adb shell am start -n "$pkg/$activity" >/dev/null 2>&1
    echo -e "${YELLOW}>>> Start the VM in Podroid if automatic start is disabled. <<<${NC}"

    wait_for_vm_ready 60

    log "Validating boot output..."
    local console
    console=$(adb shell run-as "$pkg" cat files/console.log 2>/dev/null || echo "")

    local errors=0
    local checks=("Podroid - Alpine Linux" "IP:" "Ready!" "Loading kernel modules")
    for check in "${checks[@]}"; do
        if echo "$console" | grep -q "$check"; then
            success "Check passed: $check"
        else
            warn "Check FAILED: $check"
            errors=$((errors + 1))
        fi
    done

    if [ "$errors" -eq 0 ]; then
        success "Automated Boot Test PASSED."
    else
        error "Automated Boot Test FAILED with $errors errors."
    fi
}

run_admission_test() {
    local pkg="com.excp.podroid.debug"
    local activity="com.excp.podroid.MainActivity"
    local serial=""
    local bridge_pid=""
    local bridge_path=""
    local capture="$ADMISSION_OUT/terminal.capture"
    local report="$ADMISSION_OUT/admission.txt"
    local transport_meta="$ADMISSION_OUT/transport.txt"
    local fifo="$ADMISSION_OUT/terminal.in"
    local token="ACE_ADMISSION_$(date +%s)_$$"
    local command_pid=""
    local exit_marker=""
    local guest_rc=""
    local parse_status=""
    local -a ADB=()

    mkdir -p "$ADMISSION_OUT"

    serial=$(adb devices 2>/dev/null | awk 'NR > 1 && $2 == "device" { print $1; exit }')
    if [ -z "$serial" ]; then
        error "EXTERNAL PHYSICAL GATE: no ADB-connected Android device in state 'device'. Admission cannot begin without a physical device."
    fi
    ADB=(adb -s "$serial")
    printf 'serial=%s\n' "$serial" > "$transport_meta"

    build_apk
    build_rootfs
    build_qemu

    log "Deploying admission APK to physical device ${serial}..."
    "${ADB[@]}" uninstall "$pkg" >/dev/null 2>&1 || true
    "${ADB[@]}" install -r app/build/outputs/apk/debug/app-debug.apk >/dev/null

    log "Resetting dedicated admission VM storage for a clean run..."
    "${ADB[@]}" shell am force-stop "$pkg" 2>/dev/null || true
    "${ADB[@]}" shell run-as "$pkg" rm -f files/storage.img 2>/dev/null || true
    "${ADB[@]}" shell run-as "$pkg" rm -f files/console.log 2>/dev/null || true
    "${ADB[@]}" shell run-as "$pkg" rm -f files/terminal.sock files/ctrl.sock files/serial.sock files/qmp.sock files/host.sock 2>/dev/null || true
    rm -f "$capture" "$report" "$fifo"
    mkfifo "$fifo"

    log "Launching Podroid through its exported foreground START_VM activity path..."
    "${ADB[@]}" shell am start -n "$pkg/$activity" -a com.excp.podroid.action.START_VM >/dev/null 2>&1 || \
        error "Could not launch Podroid START_VM activity intent on the physical device."

    wait_for_vm_ready 60 "$serial"

    log "Locating the existing Podroid terminal bridge and native virtio-console endpoint..."
    local deadline=$((SECONDS + 20))
    while (( SECONDS < deadline )); do
        bridge_pid=$("${ADB[@]}" shell pidof libpodroid-bridge.so 2>/dev/null | tr -d '\r' | awk '{print $1}' || true)
        if [ -n "$bridge_pid" ]; then
            bridge_path=$("${ADB[@]}" shell run-as "$pkg" readlink "/proc/${bridge_pid}/exe" 2>/dev/null | tr -d '\r' || true)
            if [ -n "$bridge_path" ]; then
                break
            fi
        fi
        sleep 1
    done

    if [ -z "$bridge_pid" ] || [ -z "$bridge_path" ]; then
        rm -f "$fifo"
        error "EXTERNAL PHYSICAL GATE: VM is Ready!, but the existing Podroid terminal bridge process could not be resolved; guest command execution was not attempted."
    fi

    {
        printf 'bridge_pid=%s\n' "$bridge_pid"
        printf 'bridge_path=%s\n' "$bridge_path"
        printf 'transport=terminal.sock+ctrl.sock via podroid-bridge\n'
    } >> "$transport_meta"

    log "Detaching the UI bridge and attaching the same native Podroid terminal transport to the admission harness..."
    "${ADB[@]}" shell run-as "$pkg" kill "$bridge_pid" >/dev/null 2>&1 || true
    sleep 1

    : > "$capture"
    : > "$report"
    "${ADB[@]}" exec-out run-as "$pkg" "$bridge_path" "files/terminal.sock" "files/ctrl.sock" < "$fifo" > "$capture" 2>&1 &
    command_pid=$!
    exec {stdin_fd}>"$fifo"

    # The start marker is emitted by the guest shell using octal escapes, so the
    # literal marker does not occur in the echoed command text. The exit marker
    # is emitted only after the admission process returns, and carries its real
    # guest exit status. Both stdout and stderr are intentionally captured through
    # the PTY because a terminal transport exposes the shell's combined stream.
    local guest_cmd
    guest_cmd="printf '\\137\\137ACE_ADMISSION_START_%s__\\n' '$token'; /usr/local/bin/ace-podroid-admission 2>&1; rc=\$?; printf '\\137\\137ACE_ADMISSION_EXIT_%s_%s__\\n' '$token' \"\$rc\""
    printf '%s\n' "$guest_cmd" >&$stdin_fd

    deadline=$((SECONDS + 180))
    while (( SECONDS < deadline )); do
        if [ -f "$capture" ]; then
            exit_marker=$(grep -a -o "__ACE_ADMISSION_EXIT_${token}_[0-9][0-9]*__" "$capture" 2>/dev/null | tail -1 || true)
            if [ -n "$exit_marker" ]; then
                break
            fi
        fi
        if ! kill -0 "$command_pid" 2>/dev/null; then
            break
        fi
        sleep 1
    done

    if [ -z "$exit_marker" ]; then
        warn "Guest admission did not reach its completion sentinel before timeout; sending Ctrl-C and terminating the native transport."
        printf '\003' >&$stdin_fd || true
        sleep 2
        kill "$command_pid" 2>/dev/null || true
        wait "$command_pid" 2>/dev/null || true
        exec {stdin_fd}>&-
        rm -f "$fifo"
        printf 'name=ace_guest_transport status=UNKNOWN observed=no-completion-sentinel expected=guest-command-exit-sentinel reason=timed out waiting for deterministic native terminal completion\n' > "$report"
        printf 'status=UNKNOWN\n' >> "$report"
        "${ADB[@]}" shell am broadcast -a com.excp.podroid.action.STOP_VM >/dev/null 2>&1 || true
        error "ACE admission execution timed out without a completion sentinel. See $report"
    fi

    exec {stdin_fd}>&-
    rm -f "$fifo"
    kill "$command_pid" 2>/dev/null || true
    wait "$command_pid" 2>/dev/null || true

    python3 - "$capture" "$token" "$report" << 'PY'
import pathlib, re, sys
capture = pathlib.Path(sys.argv[1]).read_bytes()
token = sys.argv[2].encode()
report_path = pathlib.Path(sys.argv[3])
start = b"__ACE_ADMISSION_START_" + token + b"__"
exit_re = re.compile(rb"__ACE_ADMISSION_EXIT_" + re.escape(token) + rb"_([0-9]+)__")
start_i = capture.find(start)
match = exit_re.search(capture, start_i + len(start) if start_i >= 0 else 0)
if start_i < 0 or match is None:
    report_path.write_text(
        "name=ace_guest_transport status=UNKNOWN observed=invalid-native-capture expected=start-and-exit-sentinels reason=guest transport evidence was incomplete\n",
        encoding="utf-8",
    )
    raise SystemExit(2)
payload = capture[start_i + len(start):match.start()]
payload = payload.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
report_path.write_bytes(payload)
(report_path.parent / "guest-exit-status.txt").write_text(match.group(1).decode("ascii") + "\n", encoding="ascii")
PY
    parse_status=$?

    if [ "$parse_status" -ne 0 ]; then
        "${ADB[@]}" shell am broadcast -a com.excp.podroid.action.STOP_VM >/dev/null 2>&1 || true
        error "Native terminal transport produced incomplete admission evidence. See $report"
    fi

    if ! grep -q 'summary_end=1' "$report"; then
        "${ADB[@]}" shell am broadcast -a com.excp.podroid.action.STOP_VM >/dev/null 2>&1 || true
        error "Native terminal transport reached an exit sentinel but the guest admission report was incomplete. See $report"
    fi

    guest_rc=$(cat "$ADMISSION_OUT/guest-exit-status.txt")
    {
        printf 'transport=terminal.sock via podroid-bridge\n'
        printf 'guest_exit_status=%s\n' "$guest_rc"
    } >> "$transport_meta"

    if grep -q 'status=FAIL' "$report"; then
        "${ADB[@]}" shell am broadcast -a com.excp.podroid.action.STOP_VM >/dev/null 2>&1 || true
        error "ACE admission produced one or more FAIL results. See $report"
    fi
    if grep -q 'status=UNKNOWN' "$report"; then
        warn "ACE admission contains UNKNOWN results. This is not admission certification."
        "${ADB[@]}" shell am broadcast -a com.excp.podroid.action.STOP_VM >/dev/null 2>&1 || true
        return 2
    fi
    if [ "$guest_rc" -ne 0 ]; then
        "${ADB[@]}" shell am broadcast -a com.excp.podroid.action.STOP_VM >/dev/null 2>&1 || true
        error "Guest admission command returned non-zero exit status ${guest_rc} without a reported FAIL/UNKNOWN line. Evidence is not certifying."
    fi

    "${ADB[@]}" shell am broadcast -a com.excp.podroid.action.STOP_VM >/dev/null 2>&1 || true
    success "All emitted admission criteria are PASS. Physical ACE admission evidence collected through Podroid native terminal transport."
}

# ── Main Logic ────────────────────────────────────────────────────────────────

[ $# -eq 0 ] && { show_help; exit 1; }

FAST=false
for arg in "$@"; do [ "$arg" == "--fast" ] && FAST=true; done

case "$1" in
    kernel)    build_kernel ;;
    initramfs) build_initramfs ;;
    rootfs)    build_rootfs ;;
    qemu)      build_qemu ;;
    apk)       build_apk ;;
    deploy)    build_apk && deploy_apk ;;
    test)      run_boot_test ;;
    admission) run_admission_test ;;
    all)
        build_initramfs
        build_rootfs
        build_qemu
        build_apk
        ;;
    clean)
        log "Cleaning up..."
        ./gradlew clean
        docker rmi podroid-builder podroid-qemu-builder podroid-rootfs:latest 2>/dev/null || true
        success "Cleaned."
        ;;
    *)
        show_help
        exit 1
        ;;
esac
