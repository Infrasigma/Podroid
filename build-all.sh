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
  admission     Build/install/boot and run ACE guest admission via SSH when enabled
  clean         Remove build artifacts and temporary containers

Options:
  --fast        Skip QEMU native builds if binaries already exist
  --help        Show this help message

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
    python3 - "$lib" << 'EOF'
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
EOF
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
    local boot_ok=false
    log "Waiting for VM to boot (timeout: ${timeout}s)..."
    for _i in $(seq 1 "$timeout"); do
        local console
        console=$(adb shell run-as "$pkg" cat files/console.log 2>/dev/null || echo "")
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
    local ssh_port=19922

    mkdir -p "$ADMISSION_OUT"
    adb devices 2>/dev/null | grep -q 'device$' || error "EXTERNAL PHYSICAL GATE: no ADB-connected Android device."

    build_apk
    build_rootfs
    build_qemu
    deploy_apk

    log "Resetting VM storage for clean admission run..."
    adb shell am force-stop "$pkg" 2>/dev/null || true
    adb shell run-as "$pkg" rm -f files/storage.img 2>/dev/null || true
    adb shell run-as "$pkg" rm -f files/console.log 2>/dev/null || true
    adb shell am start -n "$pkg/$activity" >/dev/null 2>&1

    wait_for_vm_ready 60

    # SSH is the stable machine-readable guest channel already exposed by Podroid.
    # Do not silently enable it: doing so would change user configuration and could
    # hide a real physical-gate failure.
    adb forward "tcp:${ssh_port}" tcp:9922 >/dev/null 2>&1 || true

    if ! command -v ssh >/dev/null 2>&1; then
        emit_status="name=ace_guest_channel status=UNKNOWN observed=ssh-client-unavailable expected=guest-command-channel reason=host ssh client is unavailable"
        printf '%s\n' "$emit_status" | tee "$ADMISSION_OUT/summary.txt"
        error "EXTERNAL PHYSICAL GATE: host ssh client unavailable; VM booted but guest admission command channel was not established."
    fi

    if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -p "$ssh_port" root@127.0.0.1 true >/dev/null 2>&1; then
        log "Guest SSH channel established; running ace-podroid-admission."
        ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p "$ssh_port")
        ssh "${ssh_opts[@]}" root@127.0.0.1 /usr/local/bin/ace-podroid-admission \
            | tee "$ADMISSION_OUT/admission.txt"
    else
        printf '%s\n' \
            'name=ace_guest_channel status=UNKNOWN observed=ssh-unavailable expected=guest-command-channel reason=Podroid VM booted but SSH on phone port 9922 is not reachable; SSH is disabled or not exposed.' \
            | tee "$ADMISSION_OUT/admission.txt"
        error "EXTERNAL PHYSICAL GATE: guest boot succeeded, but SSH guest channel on port 9922 is unavailable. No admission result was fabricated."
    fi

    if grep -q 'status=FAIL' "$ADMISSION_OUT/admission.txt"; then
        error "ACE admission produced one or more FAIL results. See $ADMISSION_OUT/admission.txt"
    fi
    if grep -q 'status=UNKNOWN' "$ADMISSION_OUT/admission.txt"; then
        warn "ACE admission contains UNKNOWN results. This is not admission certification."
        return 2
    fi
    success "All emitted admission criteria are PASS. Physical ACE admission evidence collected."
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
