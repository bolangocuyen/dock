#!/usr/bin/env bash
# =============================================================================
# build.sh — Android aarch64 /system Bootstrap Orchestration Script
# =============================================================================
# Usage:
#   ./build.sh [OPTIONS]
#
# Options:
#   --target TARGET    Build only up to the named stage (default: final)
#   --push REGISTRY    Push final image to registry after build
#   --no-cache         Pass --no-cache to docker build
#   --jobs N           Parallel job count passed to make (default: nproc)
#   --tag TAG          Image tag (default: android-system-aarch64:api35-llvm22)
#   --validate         Run post-build validation checks
#   -h, --help         Show this help
#
# Environment variables (override defaults):
#   NDK_VERSION        NDK version string (default: r27d)
#   LLVM_VERSION       LLVM release tag    (default: llvmorg-22.1.0)
#   API_LEVEL          Android API level   (default: 35)
#   PREFIX             Install prefix      (default: /system)
# =============================================================================

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
NDK_VERSION="${NDK_VERSION:-r27d}"
LLVM_VERSION="${LLVM_VERSION:-llvmorg-22.1.0}"
API_LEVEL="${API_LEVEL:-35}"
PREFIX="${PREFIX:-/system}"
TARGET_STAGE="final"
PUSH_REGISTRY=""
NO_CACHE=""
JOBS="$(nproc)"
IMAGE_TAG="android-system-aarch64:api35-llvm22"
VALIDATE=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Colour output helpers ─────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)   TARGET_STAGE="$2"; shift 2 ;;
        --push)     PUSH_REGISTRY="$2"; shift 2 ;;
        --no-cache) NO_CACHE="--no-cache"; shift ;;
        --jobs)     JOBS="$2"; shift 2 ;;
        --tag)      IMAGE_TAG="$2"; shift 2 ;;
        --validate) VALIDATE=1; shift ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) error "Unknown option: $1" ;;
    esac
done

# ── Prerequisites check ──────────────────────────────────────────────────────
info "Checking prerequisites..."

require_cmd() {
    command -v "$1" &>/dev/null || error "Required command not found: $1"
}
require_cmd docker
require_cmd git
require_cmd wget

# Docker BuildKit must be enabled for multi-stage cache mounts
export DOCKER_BUILDKIT=1

DOCKER_VERSION="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0.0.0")"
info "Docker version: ${DOCKER_VERSION}"

# ── Disk space pre-check ─────────────────────────────────────────────────────
# LLVM build requires ~50 GB of disk in /tmp + Docker layer cache
AVAIL_GB="$(df -BG /var/lib/docker 2>/dev/null | awk 'NR==2 {gsub("G",""); print $4}' || echo 999)"
if [[ "${AVAIL_GB}" -lt 60 ]]; then
    warn "Only ${AVAIL_GB} GB available in Docker storage. LLVM build needs ~60 GB."
    warn "Proceeding anyway — build may fail on disk exhaustion."
fi

# ── Build arguments ──────────────────────────────────────────────────────────
BUILD_ARGS=(
    "--build-arg" "NDK_VERSION=${NDK_VERSION}"
    "--build-arg" "LLVM_VERSION=${LLVM_VERSION}"
    "--build-arg" "API_LEVEL=${API_LEVEL}"
    "--build-arg" "PREFIX=${PREFIX}"
)

# ── Cache configuration ───────────────────────────────────────────────────────
# Use a local registry cache if available (speeds up repeated builds significantly)
CACHE_ARGS=()
if docker inspect android-buildcache &>/dev/null 2>&1; then
    info "Local BuildKit cache registry detected — using layer cache"
    CACHE_ARGS=(
        "--cache-from" "type=registry,ref=android-buildcache/llvm-native:latest"
        "--cache-from" "type=registry,ref=android-buildcache/libs-1:latest"
    )
fi

# ── Stage build times (approximate, on 32-core machine) ──────────────────────
# base:         ~3 min  (apt + NDK download + git clones)
# llvm-native:  ~8 min  (only tblgen, very narrow build)
# llvm-cross:   ~45 min (full LLVM + clang + lld + compiler-rt for aarch64)
# libs-1:       ~5 min  (bzip2, zlib, xz, zstd)
# libs-2:       ~8 min  (libffi, ncurses, readline, mpdecimal)
# tools:        ~15 min (make, ninja, cmake)
# curl-stage:   ~10 min (openssl + curl)
# assembler:    ~2 min  (copy + validation)
# final:        ~1 min  (scratch copy)

info "Starting build: target=${TARGET_STAGE} tag=${IMAGE_TAG}"
info "NDK=${NDK_VERSION}  LLVM=${LLVM_VERSION}  API=${API_LEVEL}  PREFIX=${PREFIX}"
echo ""

START_TS="$(date +%s)"

# ── Main docker build ─────────────────────────────────────────────────────────
docker build \
    ${NO_CACHE} \
    --progress=plain \
    --target "${TARGET_STAGE}" \
    --tag "${IMAGE_TAG}" \
    "${BUILD_ARGS[@]}" \
    "${CACHE_ARGS[@]}" \
    --file "${SCRIPT_DIR}/Dockerfile" \
    "${SCRIPT_DIR}"

END_TS="$(date +%s)"
ELAPSED=$(( END_TS - START_TS ))
ELAPSED_MIN=$(( ELAPSED / 60 ))
ELAPSED_SEC=$(( ELAPSED % 60 ))

ok "Build completed in ${ELAPSED_MIN}m ${ELAPSED_SEC}s"

# ── Image size report ─────────────────────────────────────────────────────────
IMAGE_SIZE="$(docker image inspect "${IMAGE_TAG}" \
    --format '{{.Size}}' 2>/dev/null \
    | awk '{printf "%.1f MB", $1/1024/1024}')"
info "Final image size: ${IMAGE_SIZE}"

# ── Post-build validation ─────────────────────────────────────────────────────
if [[ "${VALIDATE}" -eq 1 ]]; then
    echo ""
    info "Running post-build validation..."

    # ELF architecture check
    info "Checking ELF architecture of /system/bin/clang..."
    docker run --rm --entrypoint /bin/sh "${IMAGE_TAG}" -c \
        'file /system/bin/clang 2>/dev/null || echo "file not available"' \
        2>/dev/null || true

    # Library dependency check via llvm-readelf (inside the assembler stage)
    info "Checking dynamic dependencies of /system/bin/clang..."
    ASSEMBLER_IMG="${IMAGE_TAG}-assembler-check"
    docker build \
        ${NO_CACHE:+--no-cache} \
        --progress=plain \
        --target assembler \
        --tag "${ASSEMBLER_IMG}" \
        "${BUILD_ARGS[@]}" \
        --file "${SCRIPT_DIR}/Dockerfile" \
        "${SCRIPT_DIR}" 2>/dev/null || true

    if docker image inspect "${ASSEMBLER_IMG}" &>/dev/null 2>&1; then
        docker run --rm "${ASSEMBLER_IMG}" \
            sh -c '
                NDK_BIN=/opt/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin
                echo "=== ELF Class & Machine ==="
                ${NDK_BIN}/llvm-readelf -h /system/bin/clang \
                    | grep -E "(Class|Machine|Entry)"
                echo "=== NEEDED libraries ==="
                ${NDK_BIN}/llvm-readelf -d /system/bin/clang \
                    | grep NEEDED
                echo "=== PT_LOAD alignment (expect 16384 or 65536 on 16KB kernel) ==="
                ${NDK_BIN}/llvm-readelf -l /system/bin/clang \
                    | grep -A1 "LOAD"
                echo "=== RUNPATH ==="
                ${NDK_BIN}/llvm-readelf -d /system/bin/clang \
                    | grep -E "(RPATH|RUNPATH)"
            ' || warn "Extended validation failed (non-fatal)"
        docker image rm "${ASSEMBLER_IMG}" &>/dev/null || true
    fi

    ok "Validation complete"
fi

# ── Optional push ─────────────────────────────────────────────────────────────
if [[ -n "${PUSH_REGISTRY}" ]]; then
    REMOTE_TAG="${PUSH_REGISTRY}/${IMAGE_TAG}"
    info "Tagging image as ${REMOTE_TAG}..."
    docker tag "${IMAGE_TAG}" "${REMOTE_TAG}"
    info "Pushing ${REMOTE_TAG}..."
    docker push "${REMOTE_TAG}"
    ok "Pushed: ${REMOTE_TAG}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Build Summary${RESET}"
echo "  Image:    ${IMAGE_TAG}"
echo "  Size:     ${IMAGE_SIZE}"
echo "  NDK:      ${NDK_VERSION}"
echo "  LLVM:     ${LLVM_VERSION}"
echo "  API:      ${API_LEVEL}"
echo "  Prefix:   ${PREFIX}"
echo "  Elapsed:  ${ELAPSED_MIN}m ${ELAPSED_SEC}s"
echo ""
echo "Run the image:"
echo "  docker run --rm ${IMAGE_TAG}"
echo ""
echo "Inspect /system contents:"
echo "  docker run --rm --entrypoint /bin/sh ${IMAGE_TAG} \\
      -c 'ls /system/bin'"
echo ""
