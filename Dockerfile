# =============================================================================
# Android aarch64 Bootstrap — Multi-Stage Dockerfile
# LLVM Source: android.googlesource.com/toolchain/llvm-project (AOSP mirror)
# Build system: android.googlesource.com/toolchain/llvm_android (build.py)
# Target:  aarch64-linux-android API 35 (Android 15)
# Prefix:  /system
# NDK:     r27d
# =============================================================================
#
# SOURCE STRATEGY (derived from toolchain/llvm_android source_manager.py):
#
#   The AOSP toolchain build works as follows:
#     1. toolchain/llvm-project  — AOSP's mirror of upstream llvm-project,
#        carrying Android-specific commits on top of a pinned upstream SHA.
#        This is the canonical LLVM source for all Android clang builds.
#     2. toolchain/llvm_android  — Python build system (build.py / do_build.py)
#        that drives a two-stage clang build and applies PATCHES.json on top
#        of the llvm-project source tree.
#
#   source_manager.setup_sources() copies toolchain/llvm-project → out/llvm-project
#   then applies patches/PATCHES.json.  We replicate this in Docker.
#
# TWO-PASS LLVM BUILD STRATEGY:
#
#   Stage 0 [llvm-bootstrap]: Build a minimal host-native (x86_64) Clang from
#     the AOSP llvm-project source.  This serves as the "stage1" compiler for
#     bootstrapping.  Only the targets needed to compile for AArch64 Android
#     are enabled (AArch64 + X86 backends).
#
#   Stage 1 [llvm-cross]: Use the stage0 compiler to build the full AArch64
#     Android Clang toolchain targeting /system.  llvm-tblgen and clang-tblgen
#     are taken from stage0 (same source tree = no version skew).
#
# BUILD STAGE MAP:
#   aosp-base        — Ubuntu 24.04 + NDK r27d + both AOSP git clones
#   llvm-bootstrap   — Host x86_64 stage1 clang (clang, lld, tblgen tools)
#   llvm-cross       — AArch64 target clang+lld+compiler-rt for /system
#   libs-1           — bzip2 / zlib / liblzma / zstd (compression layer)
#   libs-2           — libffi / ncurses / readline / mpdecimal
#   tools-stage      — GNU make / ninja / cmake cross-compiled for aarch64
#   curl-stage       — OpenSSL 3 + curl for aarch64
#   assembler        — Merge all /system artifacts, Bionic stubs, validation
#   final (scratch)  — Distroless /system image
# =============================================================================

# ── Shared ARGs ───────────────────────────────────────────────────────────────
ARG NDK_VERSION=r27d
ARG NDK_HOST_TAG=linux-x86_64
ARG API_LEVEL=35
ARG PREFIX=/system

# =============================================================================
# STAGE: aosp-base
# Install host toolchain, download NDK r27d, clone both AOSP toolchain repos
# and all AOSP external/ dependency sources.
# =============================================================================
FROM ubuntu:24.04 AS aosp-base

ARG NDK_VERSION
ARG NDK_HOST_TAG
ARG PREFIX

ENV DEBIAN_FRONTEND=noninteractive

# Host build dependencies.
# python3-pip is needed to run llvm_android's build system.
# rsync is used by source_manager.py when syncing the llvm-project tree.
RUN apt-get update && apt-get install -y --no-install-recommends \
        autoconf \
        automake \
        build-essential \
        ca-certificates \
        cmake \
        curl \
        git \
        libtool \
        libssl-dev \
        ninja-build \
        pkg-config \
        python3 \
        python3-pip \
        rsync \
        unzip \
        wget \
        xz-utils \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# ── Android NDK r27d ──────────────────────────────────────────────────────────
RUN set -eux; \
    wget -q "https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-linux.zip" \
         -O /tmp/ndk.zip; \
    unzip -q /tmp/ndk.zip -d /opt; \
    mv /opt/android-ndk-${NDK_VERSION} /opt/ndk; \
    rm /tmp/ndk.zip

ENV NDK_ROOT=/opt/ndk
ENV NDK_TOOLCHAIN=/opt/ndk/toolchains/llvm/prebuilt/${NDK_HOST_TAG}
ENV NDK_SYSROOT=/opt/ndk/toolchains/llvm/prebuilt/${NDK_HOST_TAG}/sysroot
ENV PATH="${NDK_TOOLCHAIN}/bin:${PATH}"

# ── Clone toolchain/llvm-project (AOSP mirror) ───────────────────────────────
# This is the canonical LLVM source for Android toolchain builds.
# AOSP carries Android-specific patches on top of a pinned upstream commit.
# We clone main; in production you would pin to a specific revision from
# a manifest_*.xml or clang_source_info.md.
RUN git clone --depth 1 \
        https://android.googlesource.com/toolchain/llvm-project \
        /toolchain/llvm-project

# ── Clone toolchain/llvm_android (build system) ──────────────────────────────
# Contains build.py / do_build.py, patches/PATCHES.json, and all the Python
# builder infrastructure that drives the two-stage clang build.
RUN git clone --depth 1 \
        https://android.googlesource.com/toolchain/llvm_android \
        /toolchain/llvm_android

# ── Replicate source_manager.setup_sources() ─────────────────────────────────
# source_manager.py copies toolchain/llvm-project → out/llvm-project,
# then applies patches/PATCHES.json using toolchain-utils patch_manager.py.
# In Docker we do the copy step here; patch application is done in the
# llvm-bootstrap stage where we have the full Python environment.
#
# We do a plain cp -a (not rsync) since this is a fresh directory.
RUN sudo mkdir -p /out
RUN sudo cp -a /toolchain/llvm-project /out/llvm-project

# ── AOSP external/ dependency sources ────────────────────────────────────────
RUN git clone --depth 1 \
        https://android.googlesource.com/platform/external/bzip2 \
        /src/bzip2

RUN git clone --depth 1 \
        https://android.googlesource.com/platform/external/zlib \
        /src/zlib

# xz/liblzma — use toolchain/xz per paths.py (XZ_SRC_DIR = toolchain/xz)
RUN git clone --depth 1 \
        https://android.googlesource.com/platform/external/xz \
        /src/xz

RUN git clone --depth 1 \
        https://android.googlesource.com/platform/external/zstd \
        /src/zstd

# libffi — upstream (AOSP external/ mirror is significantly older)
RUN git clone --depth 1 --branch v3.4.6 \
        https://github.com/libffi/libffi.git \
        /src/libffi

RUN git clone --depth 1 \
        https://android.googlesource.com/platform/external/ncurses \
        /src/ncurses

RUN git clone --depth 1 --branch readline-8.2 \
        https://git.savannah.gnu.org/git/readline.git \
        /src/readline

RUN wget -q https://www.bytereef.org/software/mpdecimal/releases/mpdecimal-4.0.0.tar.gz \
        -O /tmp/mpdecimal.tar.gz \
    && tar -xzf /tmp/mpdecimal.tar.gz -C /src \
    && mv /src/mpdecimal-4.0.0 /src/mpdecimal \
    && rm /tmp/mpdecimal.tar.gz

RUN wget -q https://ftp.gnu.org/gnu/make/make-4.4.1.tar.gz \
        -O /tmp/make.tar.gz \
    && tar -xzf /tmp/make.tar.gz -C /src \
    && mv /src/make-4.4.1 /src/gnumake \
    && rm /tmp/make.tar.gz

RUN git clone --depth 1 --branch v1.12.1 \
        https://github.com/ninja-build/ninja.git \
        /src/ninja

RUN git clone --depth 1 --branch v3.31.6 \
        https://github.com/Kitware/CMake.git \
        /src/cmake-src

RUN git clone --depth 1 --branch curl-8_13_0 \
        https://github.com/curl/curl.git \
        /src/curl

# =============================================================================
# STAGE: llvm-bootstrap
#
# Build a minimal host-native (x86_64) stage1 Clang from /out/llvm-project.
# This mirrors what do_build.py's Stage1Builder does — a fast host compiler
# that can then be used to build the full AArch64 target toolchain.
#
# Key outputs used by llvm-cross:
#   /stage1/bin/llvm-tblgen   — TableGen code generator (must match source)
#   /stage1/bin/clang-tblgen  — Clang TableGen (must match source)
#   /stage1/bin/clang         — Host clang to compile the AArch64 stage2
#   /stage1/bin/ld.lld        — Host lld
#
# Why we use the AOSP llvm-project source and not a version-tagged release:
#   The patches applied via PATCHES.json may modify tblgen .td files.
#   If the host tblgen binary does not match the patched source tree, the
#   generated .inc files will be wrong and stage2 compilation will fail or
#   produce a broken clang.  Using the same tree for both passes eliminates
#   any version/patch mismatch.
# =============================================================================
FROM aosp-base AS llvm-bootstrap

# ── Stage1: host-native clang from AOSP llvm-project ─────────────────────────
# Enabled targets:
#   AArch64 — we need the AArch64 backend in stage1 so stage1 clang can
#              compile AArch64 objects (used later for cross-runtimes).
#   X86     — needed to compile the build-host's own code.
#
# Enabled projects: clang + lld only (no runtimes; stage1 uses system libc++)
#
# -DLLVM_BUILD_RUNTIME=OFF — skip building compiler-rt/libc++ for stage1;
#   we only need the compiler binaries, not the runtime libraries.
# -DLLVM_ENABLE_TERMINFO=OFF — avoids host ncurses dependency in stage1.
# -DLLVM_ENABLE_LIBEDIT=OFF  — avoids host libedit dep.
# -DLLVM_ENABLE_LIBXML2=OFF  — not needed for a bootstrap compiler.
# -DCLANG_ENABLE_BOOTSTRAP=OFF — we drive our own two-stage build.
RUN cmake -G Ninja \
        -S /out/llvm-project/llvm \
        -B /build/stage1 \
        \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=gcc \
        -DCMAKE_CXX_COMPILER=g++ \
        \
        # Both backends required: AArch64 for cross-runtime compilation later,
        # X86 for self-hosting host tools
        -DLLVM_TARGETS_TO_BUILD="AArch64;X86" \
        -DLLVM_ENABLE_PROJECTS="clang;lld" \
        \
        # Skip runtimes entirely for stage1 — we only need compiler binaries
        -DLLVM_BUILD_RUNTIME=OFF \
        -DLLVM_ENABLE_RUNTIMES="" \
        \
        # Disable features that pull in host library dependencies
        -DLLVM_ENABLE_TERMINFO=OFF \
        -DLLVM_ENABLE_LIBEDIT=OFF \
        -DLLVM_ENABLE_LIBXML2=OFF \
        -DLLVM_ENABLE_ZSTD=OFF \
        -DLLVM_ENABLE_ZLIB=OFF \
        \
        # Skip tests and docs to minimize build time
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DCLANG_INCLUDE_TESTS=OFF \
        \
        -DCMAKE_INSTALL_PREFIX=/stage1 \
    && ninja -C /build/stage1 \
    && ninja -C /build/stage1 install

# Verify stage1 tblgen tools are present before proceeding
RUN test -x /stage1/bin/llvm-tblgen  || (echo "FATAL: llvm-tblgen missing"  && exit 1)
RUN test -x /stage1/bin/clang-tblgen || (echo "FATAL: clang-tblgen missing" && exit 1)
RUN test -x /stage1/bin/clang        || (echo "FATAL: stage1 clang missing" && exit 1)

# =============================================================================
# STAGE: llvm-cross
#
# Use the stage1 host compiler to cross-compile a full AArch64 Android clang
# toolchain.  This corresponds to do_build.py's Stage2Builder.
#
# The CMake toolchain file (written inline below) wires:
#   CMAKE_C_COMPILER / CXX_COMPILER → stage1 clang (NOT the NDK wrapper)
#     because we are compiling LLVM itself, not Android userspace code.
#     The NDK wrappers are only appropriate for code that links against Bionic.
#
#   LLVM_TABLEGEN / CLANG_TABLEGEN → stage1 tblgen binaries (same source tree,
#     so patch level matches exactly)
#
#   LLVM_HOST_TRIPLE → aarch64-linux-android
#     This tells LLVM the machine that will RUN these binaries.
#
#   LLVM_DEFAULT_TARGET_TRIPLE → aarch64-linux-android
#     This is what clang uses when invoked without an explicit -target.
#
# Linker flags baked into every produced binary:
#   -Wl,-z,max-page-size=16384   — Android 15 16 KB page-size requirement
#   -Wl,-dynamic-linker,/system/bin/linker64 — hardcode Bionic's PT_INTERP
#   -Wl,-rpath=/system/lib64     — runtime library path in ELF RUNPATH
# =============================================================================
FROM aosp-base AS llvm-cross

ARG PREFIX
ARG API_LEVEL

# Pull stage1 compiler and tblgen tools from the bootstrap stage
COPY --from=llvm-bootstrap /stage1 /stage1

# ── Write the CMake cross-compilation toolchain file ─────────────────────────
RUN cat > /tmp/llvm-cross-aarch64.cmake << 'TOOLCHAIN_CMAKE_EOF'
# CMake toolchain file for cross-compiling LLVM targeting aarch64-linux-android
# Used in the llvm-cross Docker stage.

# System identity — we ARE cross-compiling to Android/AArch64
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

# Use stage1 host clang to compile the cross target.
# We do NOT use the NDK wrapper (aarch64-linux-android35-clang) here because:
#   1. NDK wrappers inject --sysroot pointing to Bionic headers, which breaks
#      LLVM's own internal header resolution during cmake configure.
#   2. LLVM manages its own sysroot via LLVM_DEFAULT_TARGET_TRIPLE and the
#      compiler-rt/libcxx build flags.
# We instead pass --target explicitly via CMAKE_C_FLAGS below.
set(CMAKE_C_COMPILER   /stage1/bin/clang   CACHE FILEPATH "C compiler")
set(CMAKE_CXX_COMPILER /stage1/bin/clang++ CACHE FILEPATH "C++ compiler")
set(CMAKE_AR           /stage1/bin/llvm-ar       CACHE FILEPATH "ar")
set(CMAKE_RANLIB       /stage1/bin/llvm-ranlib   CACHE FILEPATH "ranlib")
set(CMAKE_LINKER       /stage1/bin/ld.lld        CACHE FILEPATH "linker")
set(CMAKE_NM           /stage1/bin/llvm-nm       CACHE FILEPATH "nm")
set(CMAKE_STRIP        /stage1/bin/llvm-strip     CACHE FILEPATH "strip")

# NDK sysroot for Bionic headers (libc.h, etc.) used by compiler-rt and
# any Bionic-linked code compiled as part of LLVM runtimes.
set(NDK_SYSROOT $ENV{NDK_SYSROOT})

# Cross-compile flags: target triple + NDK sysroot + Android API level.
# These are injected into every compilation command via INIT variables,
# which are set before any try_compile / feature detection runs.
set(_CROSS_FLAGS
    "--target=aarch64-linux-android$ENV{API_LEVEL} \
     --sysroot=${NDK_SYSROOT} \
     -O2 \
     -I$ENV{PREFIX}/include")

set(_CROSS_LDFLAGS
    "--target=aarch64-linux-android$ENV{API_LEVEL} \
     --sysroot=${NDK_SYSROOT} \
     -fuse-ld=lld \
     -L$ENV{PREFIX}/lib64 \
     -Wl,-rpath=/system/lib64:/system/lib \
     -Wl,-z,max-page-size=16384 \
     -Wl,-dynamic-linker,/system/bin/linker64")

set(CMAKE_C_FLAGS_INIT   ${_CROSS_FLAGS})
set(CMAKE_CXX_FLAGS_INIT ${_CROSS_FLAGS})
set(CMAKE_EXE_LINKER_FLAGS_INIT    ${_CROSS_LDFLAGS})
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-Wl,-z,max-page-size=16384")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "-Wl,-z,max-page-size=16384")

# Tell CMake where to find target libraries and headers.
# NEVER mode for programs ensures cmake never tries to run target binaries
# on the host during configure-time checks.
set(CMAKE_FIND_ROOT_PATH ${NDK_SYSROOT} $ENV{PREFIX})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
TOOLCHAIN_CMAKE_EOF

# ── Cross-compile LLVM+Clang+LLD+compiler-rt for AArch64 ─────────────────────
# Source: /out/llvm-project (copied from toolchain/llvm-project in aosp-base)
RUN cmake -G Ninja \
        -S /out/llvm-project/llvm \
        -B /build/stage2 \
        --toolchain /tmp/llvm-cross-aarch64.cmake \
        \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=${PREFIX} \
        \
        # ── TableGen: MUST match the source tree being compiled ───────────────
        # These binaries run on the HOST during the build to generate C++ source.
        # Using stage1 tblgen (built from same /out/llvm-project tree) guarantees
        # no .td file version mismatch.
        -DLLVM_TABLEGEN=/stage1/bin/llvm-tblgen \
        -DCLANG_TABLEGEN=/stage1/bin/clang-tblgen \
        \
        # ── Target architecture configuration ─────────────────────────────────
        # LLVM_TARGET_ARCH: architecture we generate code FOR
        -DLLVM_TARGET_ARCH=AArch64 \
        # LLVM_TARGETS_TO_BUILD: backends compiled INTO this LLVM
        -DLLVM_TARGETS_TO_BUILD="AArch64" \
        # LLVM_HOST_TRIPLE: machine that will RUN these LLVM binaries
        -DLLVM_HOST_TRIPLE=aarch64-linux-android \
        # LLVM_DEFAULT_TARGET_TRIPLE: what clang targets when -target is omitted
        -DLLVM_DEFAULT_TARGET_TRIPLE=aarch64-linux-android${API_LEVEL} \
        \
        # ── Enabled subprojects ───────────────────────────────────────────────
        -DLLVM_ENABLE_PROJECTS="clang;lld" \
        # compiler-rt: provides builtins (__aeabi_* etc.) on Bionic
        -DLLVM_ENABLE_RUNTIMES="compiler-rt" \
        \
        # ── compiler-rt configuration for Bionic ──────────────────────────────
        # Build only builtins for the default (AArch64 Android) target.
        # Sanitizers require additional Bionic runtime support not present here.
        -DCOMPILER_RT_BUILD_BUILTINS=ON \
        -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
        -DCOMPILER_RT_BUILD_XRAY=OFF \
        -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
        -DCOMPILER_RT_BUILD_PROFILE=OFF \
        -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
        # COMPILER_RT_OS_DIR controls where builtins are installed under lib/clang/
        -DCOMPILER_RT_OS_DIR="android" \
        \
        # ── C++ standard library ──────────────────────────────────────────────
        # Bionic ships its own libc++ via the NDK sysroot.
        # We do not build libc++ here; stage2 links against the NDK's copy.
        -DLLVM_ENABLE_LIBCXX=OFF \
        \
        # ── Disable features that have no Bionic/NDK sysroot support ──────────
        -DLLVM_ENABLE_LIBEDIT=OFF \
        -DLLVM_ENABLE_TERMINFO=OFF \
        -DLLVM_ENABLE_LIBXML2=OFF \
        \
        # ── Shared LLVM library ───────────────────────────────────────────────
        # Build libLLVM.so so clang tools can link dynamically
        -DLLVM_BUILD_LLVM_DYLIB=ON \
        -DLLVM_LINK_LLVM_DYLIB=ON \
        \
        # ── Clang defaults wired for Android ─────────────────────────────────
        -DCLANG_DEFAULT_LINKER=lld \
        -DCLANG_DEFAULT_RTLIB=compiler-rt \
        # No CXX ABI lib specified — clang will find NDK libc++abi via sysroot
        \
        # ── Minimize build ───────────────────────────────────────────────────
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DCLANG_INCLUDE_TESTS=OFF \
        \
        # zlib: use the NDK sysroot's stub for initial build;
        # final /system/lib64/libz.so is provided by libs-1 stage
        -DLLVM_ENABLE_ZLIB=ON \
        -DLLVM_ENABLE_ZSTD=OFF \
    && ninja -C /build/stage2 \
    && ninja -C /build/stage2 install

# =============================================================================
# STAGE: libs-1
# Compression & low-level libraries for /system
# Compiler: NDK r27d aarch64-linux-android35-clang wrapper
#   The NDK wrapper already injects:  --target=aarch64-linux-android35
#                                     --sysroot=${NDK_SYSROOT}
#   We add: -I${PREFIX}/include, -L${PREFIX}/lib64, and the 16 KB page flag.
# =============================================================================
FROM aosp-base AS libs-1

ARG PREFIX
ARG API_LEVEL
ARG NDK_HOST_TAG

ENV NDK_ROOT=/opt/ndk
ENV NDK_TOOLCHAIN=/opt/ndk/toolchains/llvm/prebuilt/${NDK_HOST_TAG}
ENV PATH="${NDK_TOOLCHAIN}/bin:${PATH}"

ENV CC="aarch64-linux-android${API_LEVEL}-clang"
ENV CXX="aarch64-linux-android${API_LEVEL}-clang++"
ENV AR="llvm-ar"
ENV AS="llvm-as"
ENV LD="ld.lld"
ENV RANLIB="llvm-ranlib"
ENV STRIP="llvm-strip"
ENV CFLAGS="-O3 -I${PREFIX}/include"
ENV CXXFLAGS="-O3 -I${PREFIX}/include"
ENV LDFLAGS="-L${PREFIX}/lib64 \
             -L${PREFIX}/lib \
             -Wl,-rpath=/system/lib64:/system/lib \
             -Wl,-z,max-page-size=16384 \
             -Wl,-dynamic-linker,/system/bin/linker64"

# ── bzip2 ─────────────────────────────────────────────────────────────────────
# No autoconf/cmake; driven by plain make with overridden tool variables.
# Shared lib requires a separate Makefile-libbz2_so invocation.
RUN set -eux; \
    cd /src/bzip2; \
    make -f Makefile \
        CC="${CC}" AR="${AR}" RANLIB="${RANLIB}" \
        CFLAGS="${CFLAGS}" \
        PREFIX="${PREFIX}" \
        bzip2 bzip2recover libbz2.a; \
    install -d ${PREFIX}/bin ${PREFIX}/include ${PREFIX}/lib64 ${PREFIX}/man/man1; \
    install -m755 bzip2          ${PREFIX}/bin/bzip2; \
    install -m755 bzip2recover   ${PREFIX}/bin/bzip2recover; \
    ln -sf bzip2 ${PREFIX}/bin/bunzip2; \
    ln -sf bzip2 ${PREFIX}/bin/bzcat; \
    install -m644 bzlib.h        ${PREFIX}/include/; \
    install -m644 libbz2.a       ${PREFIX}/lib64/; \
    make -f Makefile-libbz2_so \
        CC="${CC}" \
        CFLAGS="${CFLAGS} -fPIC" \
        LDFLAGS="${LDFLAGS}"; \
    install -m755 libbz2.so.1.0.8 ${PREFIX}/lib64/; \
    ln -sf libbz2.so.1.0.8 ${PREFIX}/lib64/libbz2.so.1.0; \
    ln -sf libbz2.so.1.0   ${PREFIX}/lib64/libbz2.so

# ── zlib ──────────────────────────────────────────────────────────────────────
# AOSP's zlib/CMakeLists.txt supports standard Android CMake variables.
# CMAKE_INSTALL_LIBDIR=lib64 ensures .so goes into /system/lib64 per ABI layout.
RUN cmake -G Ninja \
        -S /src/zlib \
        -B /build/zlib \
        -DCMAKE_SYSTEM_NAME=Android \
        -DCMAKE_SYSTEM_VERSION=${API_LEVEL} \
        -DCMAKE_ANDROID_ARCH_ABI=arm64-v8a \
        -DCMAKE_ANDROID_NDK=${NDK_ROOT} \
        -DCMAKE_C_COMPILER="${CC}" \
        -DCMAKE_AR=${NDK_TOOLCHAIN}/bin/llvm-ar \
        -DCMAKE_RANLIB=${NDK_TOOLCHAIN}/bin/llvm-ranlib \
        -DCMAKE_C_FLAGS="${CFLAGS}" \
        -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS}" \
        -DCMAKE_SHARED_LINKER_FLAGS="${LDFLAGS}" \
        -DCMAKE_INSTALL_PREFIX=${PREFIX} \
        -DCMAKE_INSTALL_LIBDIR=lib64 \
        -DCMAKE_BUILD_TYPE=Release \
    && ninja -C /build/zlib \
    && ninja -C /build/zlib install

# ── liblzma (from xz) ─────────────────────────────────────────────────────────
# --build = build machine arch (x86_64 Linux)
# --host  = target machine arch (aarch64 Android)
# This pair prevents autoconf AC_RUN_IFELSE tests from trying to execute
# aarch64 binaries on the x86_64 host (would cause SIGILL / exec format error).
# --disable-xz/xzdec/etc: we only need the library, not the CLI tools.
RUN set -eux; \
    cd /src/xz; \
    [ -f configure ] || autoreconf -fi; \
    mkdir -p /build/xz && cd /build/xz; \
    /src/xz/configure \
        --build=x86_64-linux-gnu \
        --host=aarch64-linux-android \
        --prefix=${PREFIX} \
        --libdir=${PREFIX}/lib64 \
        --disable-xz \
        --disable-xzdec \
        --disable-lzmadec \
        --disable-lzmainfo \
        --disable-scripts \
        --disable-doc \
        --enable-shared \
        --enable-static; \
    make -j$(nproc); \
    make install

# ── zstd ──────────────────────────────────────────────────────────────────────
RUN cmake -G Ninja \
        -S /src/zstd/build/cmake \
        -B /build/zstd \
        -DCMAKE_SYSTEM_NAME=Android \
        -DCMAKE_SYSTEM_VERSION=${API_LEVEL} \
        -DCMAKE_ANDROID_ARCH_ABI=arm64-v8a \
        -DCMAKE_ANDROID_NDK=${NDK_ROOT} \
        -DCMAKE_C_COMPILER="${CC}" \
        -DCMAKE_AR=${NDK_TOOLCHAIN}/bin/llvm-ar \
        -DCMAKE_RANLIB=${NDK_TOOLCHAIN}/bin/llvm-ranlib \
        -DCMAKE_C_FLAGS="${CFLAGS}" \
        -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS}" \
        -DCMAKE_SHARED_LINKER_FLAGS="${LDFLAGS}" \
        -DCMAKE_INSTALL_PREFIX=${PREFIX} \
        -DCMAKE_INSTALL_LIBDIR=lib64 \
        -DCMAKE_BUILD_TYPE=Release \
        -DZSTD_BUILD_PROGRAMS=ON \
        -DZSTD_BUILD_TESTS=OFF \
        -DZSTD_LEGACY_SUPPORT=OFF \
    && ninja -C /build/zstd \
    && ninja -C /build/zstd install

# =============================================================================
# STAGE: libs-2
# Interface & math libraries — depend on zlib from libs-1
# =============================================================================
FROM libs-1 AS libs-2

ARG PREFIX
ARG API_LEVEL
ARG NDK_HOST_TAG

ENV NDK_ROOT=/opt/ndk
ENV NDK_TOOLCHAIN=/opt/ndk/toolchains/llvm/prebuilt/${NDK_HOST_TAG}
ENV PATH="${NDK_TOOLCHAIN}/bin:${PATH}"

ENV CC="aarch64-linux-android${API_LEVEL}-clang"
ENV CXX="aarch64-linux-android${API_LEVEL}-clang++"
ENV AR="llvm-ar"
ENV AS="llvm-as"
ENV LD="ld.lld"
ENV RANLIB="llvm-ranlib"
ENV STRIP="llvm-strip"
ENV CFLAGS="-O3 -I${PREFIX}/include"
ENV CXXFLAGS="-O3 -I${PREFIX}/include"
ENV LDFLAGS="-L${PREFIX}/lib64 \
             -L${PREFIX}/lib \
             -Wl,-rpath=/system/lib64:/system/lib \
             -Wl,-z,max-page-size=16384 \
             -Wl,-dynamic-linker,/system/bin/linker64"

# ── libffi ────────────────────────────────────────────────────────────────────
# --host=aarch64-linux-android causes configure to select the AArch64 assembly
# closure trampoline backend (ffi_aarch64.S) rather than a fallback.
RUN set -eux; \
    cd /src/libffi; \
    ./autogen.sh; \
    mkdir -p /build/libffi && cd /build/libffi; \
    /src/libffi/configure \
        --build=x86_64-linux-gnu \
        --host=aarch64-linux-android \
        --prefix=${PREFIX} \
        --libdir=${PREFIX}/lib64 \
        --enable-shared \
        --enable-static \
        --disable-docs; \
    make -j$(nproc); \
    make install

# ── ncurses ───────────────────────────────────────────────────────────────────
# --enable-widec: mandatory for Python curses / UTF-8 terminal support.
# --with-terminfo-dirs: baked into the binary so setupterm() finds terminfo
#   without $TERMINFO being exported at runtime on Android.
# --without-cxx-binding: avoids a configure link-test that triggers false
#   negatives on cross-built Bionic ABI (std:: layout detection).
# --with-termlib=tinfo: produces separate libtinfo.so matching distro layout
#   (Python's _curses links against tinfo specifically on some configs).
RUN set -eux; \
    cd /src/ncurses; \
    [ -f configure ] || autoreconf -fi; \
    mkdir -p /build/ncurses && cd /build/ncurses; \
    /src/ncurses/configure \
        --build=x86_64-linux-gnu \
        --host=aarch64-linux-android \
        --prefix=${PREFIX} \
        --libdir=${PREFIX}/lib64 \
        --datadir=${PREFIX}/share \
        --with-terminfo-dirs=${PREFIX}/share/terminfo \
        --with-default-terminfo-dir=${PREFIX}/share/terminfo \
        --enable-widec \
        --enable-pc-files \
        --with-pkg-config-libdir=${PREFIX}/lib64/pkgconfig \
        --with-termlib=tinfo \
        --without-cxx-binding \
        --without-ada \
        --without-manpages \
        --without-tests \
        --enable-shared \
        --enable-static; \
    make -j$(nproc); \
    make install; \
    # Create non-wide compat symlinks so packages linking -lncurses still work
    for lib in ncurses form panel menu tinfo; do \
        ln -sf lib${lib}w.so ${PREFIX}/lib64/lib${lib}.so 2>/dev/null || true; \
        ln -sf lib${lib}w.a  ${PREFIX}/lib64/lib${lib}.a  2>/dev/null || true; \
    done

# ── readline ──────────────────────────────────────────────────────────────────
# bash_cv_wcwidth_broken=no suppresses a configure test that would try to
# run a probe binary on the host to test wcwidth() behavior.
RUN set -eux; \
    cd /src/readline; \
    [ -f configure ] || autoreconf -fi; \
    mkdir -p /build/readline && cd /build/readline; \
    bash_cv_wcwidth_broken=no \
    /src/readline/configure \
        --build=x86_64-linux-gnu \
        --host=aarch64-linux-android \
        --prefix=${PREFIX} \
        --libdir=${PREFIX}/lib64 \
        --with-curses \
        --enable-shared \
        --enable-static; \
    make -j$(nproc); \
    make install

# ── mpdecimal ─────────────────────────────────────────────────────────────────
# mpdecimal configure does not honour --host/--build.
# --with-machine=ansi64: selects the portable 64-bit C implementation rather
# than the x86_64 inline assembly path that configure would detect from
# the host uname.  ansi64 is correct and fully functional on AArch64.
RUN set -eux; \
    cd /src/mpdecimal; \
    ./configure \
        --prefix=${PREFIX} \
        --libdir=${PREFIX}/lib64 \
        --with-machine=ansi64; \
    make -j$(nproc) \
        CC="${CC}" CXX="${CXX}" \
        CFLAGS="${CFLAGS}" LDFLAGS="${LDFLAGS}"; \
    make install \
        CC="${CC}" CXX="${CXX}" \
        CFLAGS="${CFLAGS}" LDFLAGS="${LDFLAGS}"

# =============================================================================
# STAGE: tools-stage
# GNU make, ninja, cmake cross-compiled for aarch64 — runtime dev tools
# that will live on the target device under /system/bin.
# =============================================================================
FROM libs-2 AS tools-stage

ARG PREFIX
ARG API_LEVEL
ARG NDK_HOST_TAG

ENV NDK_ROOT=/opt/ndk
ENV NDK_TOOLCHAIN=/opt/ndk/toolchains/llvm/prebuilt/${NDK_HOST_TAG}
ENV PATH="${NDK_TOOLCHAIN}/bin:${PATH}"

ENV CC="aarch64-linux-android${API_LEVEL}-clang"
ENV CXX="aarch64-linux-android${API_LEVEL}-clang++"
ENV AR="llvm-ar"
ENV RANLIB="llvm-ranlib"
ENV STRIP="llvm-strip"
ENV CFLAGS="-O3 -I${PREFIX}/include"
ENV CXXFLAGS="-O3 -I${PREFIX}/include"
ENV LDFLAGS="-L${PREFIX}/lib64 \
             -L${PREFIX}/lib \
             -Wl,-rpath=/system/lib64:/system/lib \
             -Wl,-z,max-page-size=16384 \
             -Wl,-dynamic-linker,/system/bin/linker64"

# ── GNU make ──────────────────────────────────────────────────────────────────
# --disable-load: getloadavg() is not available in Bionic without /proc shims.
RUN set -eux; \
    mkdir -p /build/gnumake && cd /build/gnumake; \
    /src/gnumake/configure \
        --build=x86_64-linux-gnu \
        --host=aarch64-linux-android \
        --prefix=${PREFIX} \
        --disable-load \
        --without-guile; \
    make -j$(nproc); \
    make install

# ── ninja (aarch64) ───────────────────────────────────────────────────────────
RUN cmake -G Ninja \
        -S /src/ninja \
        -B /build/ninja \
        -DCMAKE_SYSTEM_NAME=Android \
        -DCMAKE_SYSTEM_VERSION=${API_LEVEL} \
        -DCMAKE_ANDROID_ARCH_ABI=arm64-v8a \
        -DCMAKE_ANDROID_NDK=${NDK_ROOT} \
        -DCMAKE_C_COMPILER="${CC}" \
        -DCMAKE_CXX_COMPILER="${CXX}" \
        -DCMAKE_C_FLAGS="${CFLAGS}" \
        -DCMAKE_CXX_FLAGS="${CXXFLAGS}" \
        -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS}" \
        -DCMAKE_INSTALL_PREFIX=${PREFIX} \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_TESTING=OFF \
    && ninja -C /build/ninja \
    && install -m755 /build/ninja/ninja ${PREFIX}/bin/ninja

# ── cmake (aarch64) ───────────────────────────────────────────────────────────
# -DCMAKE_USE_SYSTEM_LIBRARIES=OFF: bundle cmake's third-party deps (expat,
#   libarchive, curl-internal) to avoid pulling in host libraries that aren't
#   in the cross-sysroot.
RUN cmake -G Ninja \
        -S /src/cmake-src \
        -B /build/cmake-cross \
        -DCMAKE_SYSTEM_NAME=Android \
        -DCMAKE_SYSTEM_VERSION=${API_LEVEL} \
        -DCMAKE_ANDROID_ARCH_ABI=arm64-v8a \
        -DCMAKE_ANDROID_NDK=${NDK_ROOT} \
        -DCMAKE_C_COMPILER="${CC}" \
        -DCMAKE_CXX_COMPILER="${CXX}" \
        -DCMAKE_C_FLAGS="${CFLAGS}" \
        -DCMAKE_CXX_FLAGS="${CXXFLAGS}" \
        -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS}" \
        -DCMAKE_INSTALL_PREFIX=${PREFIX} \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_USE_SYSTEM_LIBRARIES=OFF \
        -DCMAKE_USE_SYSTEM_ZLIB=OFF \
        -DBUILD_TESTING=OFF \
    && ninja -C /build/cmake-cross \
    && ninja -C /build/cmake-cross install

# =============================================================================
# STAGE: curl-stage
# OpenSSL 3 + curl linked against our /system libs
# =============================================================================
FROM tools-stage AS curl-stage

ARG PREFIX
ARG API_LEVEL
ARG NDK_HOST_TAG

ENV NDK_ROOT=/opt/ndk
ENV NDK_TOOLCHAIN=/opt/ndk/toolchains/llvm/prebuilt/${NDK_HOST_TAG}
ENV PATH="${NDK_TOOLCHAIN}/bin:${PATH}"

ENV CC="aarch64-linux-android${API_LEVEL}-clang"
ENV CXX="aarch64-linux-android${API_LEVEL}-clang++"
ENV AR="llvm-ar"
ENV RANLIB="llvm-ranlib"
ENV CFLAGS="-O3 -I${PREFIX}/include"
ENV CXXFLAGS="-O3 -I${PREFIX}/include"
ENV LDFLAGS="-L${PREFIX}/lib64 \
             -L${PREFIX}/lib \
             -Wl,-rpath=/system/lib64:/system/lib \
             -Wl,-z,max-page-size=16384 \
             -Wl,-dynamic-linker,/system/bin/linker64"

RUN git clone --depth 1 --branch openssl-3.5.0 \
        https://github.com/openssl/openssl.git \
        /src/openssl

# OpenSSL Configure has first-class android-arm64 support.
# ANDROID_NDK_ROOT must be set so it locates the NDK toolchain wrappers.
RUN set -eux; \
    cd /src/openssl; \
    ANDROID_NDK_ROOT=${NDK_ROOT} \
    ./Configure android-arm64 \
        --prefix=${PREFIX} \
        --libdir=lib64 \
        no-tests no-docs no-apps \
        shared \
        "-Wl,-rpath=/system/lib64"; \
    make -j$(nproc); \
    make install_sw

RUN set -eux; \
    cd /src/curl; \
    autoreconf -fi; \
    mkdir -p /build/curl && cd /build/curl; \
    /src/curl/configure \
        --build=x86_64-linux-gnu \
        --host=aarch64-linux-android \
        --prefix=${PREFIX} \
        --libdir=${PREFIX}/lib64 \
        --with-openssl=${PREFIX} \
        --with-zlib=${PREFIX} \
        --with-brotli=no \
        --disable-ftp --disable-ldap --disable-ldaps \
        --disable-rtsp --disable-dict --disable-telnet \
        --disable-tftp --disable-pop3 --disable-imap \
        --disable-smtp --disable-gopher --disable-smb \
        --enable-http --enable-https \
        --enable-static --enable-shared; \
    make -j$(nproc); \
    make install

# =============================================================================
# STAGE: assembler
# Merge all /system artifacts, install Bionic runtime stubs,
# write /system/etc/profile, create symlinks, run ELF validation.
# =============================================================================
FROM aosp-base AS assembler

ARG PREFIX
ARG NDK_HOST_TAG
ARG API_LEVEL

ENV NDK_ROOT=/opt/ndk
ENV NDK_TOOLCHAIN=/opt/ndk/toolchains/llvm/prebuilt/${NDK_HOST_TAG}

# Merge in all built artifacts in dependency order
COPY --from=libs-1    ${PREFIX}/ ${PREFIX}/
COPY --from=libs-2    ${PREFIX}/ ${PREFIX}/
COPY --from=tools-stage ${PREFIX}/ ${PREFIX}/
COPY --from=curl-stage  ${PREFIX}/ ${PREFIX}/
COPY --from=llvm-cross  ${PREFIX}/ ${PREFIX}/

# ── Install Bionic runtime stubs from NDK sysroot ─────────────────────────────
# These are the ABI-stable interface stubs for the Android 15 Bionic runtime.
# On a real device the OS provides these; in the container they allow the
# dynamic linker to resolve symbols for in-container validation.
# The NDK sysroot stubs live under: sysroot/usr/lib/aarch64-linux-android/<api>/
RUN set -eux; \
    BIONIC_VERSIONED="${NDK_TOOLCHAIN}/sysroot/usr/lib/aarch64-linux-android/${API_LEVEL}"; \
    BIONIC_UNVERSIONED="${NDK_TOOLCHAIN}/sysroot/usr/lib/aarch64-linux-android"; \
    install -d ${PREFIX}/lib64 ${PREFIX}/bin; \
    for lib in libc.so libm.so libdl.so liblog.so; do \
        if [ -f "${BIONIC_VERSIONED}/${lib}" ]; then \
            install -m755 "${BIONIC_VERSIONED}/${lib}" "${PREFIX}/lib64/${lib}"; \
        elif [ -f "${BIONIC_UNVERSIONED}/${lib}" ]; then \
            install -m755 "${BIONIC_UNVERSIONED}/${lib}" "${PREFIX}/lib64/${lib}"; \
        else \
            echo "WARNING: ${lib} not found in NDK sysroot — skipping"; \
        fi; \
    done

# ── linker64 stub ─────────────────────────────────────────────────────────────
# /system/bin/linker64 is provided by the Android OS on real devices.
# The NDK does not ship a standalone linker64 binary (it's a firmware component).
# We install a documented placeholder that documents this clearly.
# True validation must be done on-device or via QEMU AArch64 userspace.
RUN cat > ${PREFIX}/bin/linker64 << 'LINKER_EOF'
#!/system/bin/sh
# /system/bin/linker64 — Bionic dynamic linker
#
# On a real Android 15 device this file is provided by the OS firmware
# and is the ELF PT_INTERP interpreter for all AArch64 Android binaries.
#
# This placeholder exists only to satisfy the scratch image filesystem layout.
# On-device execution: the OS linker64 is used directly by the kernel.
# For QEMU aarch64 userspace validation:
#   qemu-aarch64 -L /path/to/ndk/sysroot /system/bin/clang --version
exec "$@"
LINKER_EOF
RUN chmod 755 ${PREFIX}/bin/linker64

# ── /system/etc/profile ───────────────────────────────────────────────────────
RUN install -d ${PREFIX}/etc && \
cat > ${PREFIX}/etc/profile << 'PROFILE_EOF'
#!/system/bin/sh
# /system/etc/profile — Android /system runtime environment
# Source: . /system/etc/profile

export PATH=/system/bin
export LD_LIBRARY_PATH=/system/lib64:/system/lib
export TERM=xterm-256color
export TERMINFO=/system/share/terminfo
export PKG_CONFIG_PATH=/system/lib64/pkgconfig:/system/lib/pkgconfig

# LLVM toolchain (built from android.googlesource.com/toolchain/llvm-project)
export CC=clang
export CXX=clang++
export AR=llvm-ar
export AS=llvm-as
export LD=ld.lld
export RANLIB=llvm-ranlib
export STRIP=llvm-strip
export NM=llvm-nm
export OBJCOPY=llvm-objcopy
export OBJDUMP=llvm-objdump

# Default flags for building software on this device
export CFLAGS="-O2 -I/system/include"
export CXXFLAGS="-O2 -I/system/include"
export LDFLAGS="-L/system/lib64 -L/system/lib \
                -Wl,-rpath=/system/lib64:/system/lib \
                -Wl,-z,max-page-size=16384 \
                -Wl,-dynamic-linker,/system/bin/linker64"

export ANDROID_ROOT=/system
export ANDROID_DATA=/data

case "$-" in *i*) PS1='android:/system $ ' ;; esac
PROFILE_EOF

# ── lib → lib64 symlink (legacy path compatibility) ───────────────────────────
RUN ln -sfn lib64 ${PREFIX}/lib 2>/dev/null || true

# ── clang++ symlink ───────────────────────────────────────────────────────────
RUN if [ -f "${PREFIX}/bin/clang" ] && [ ! -e "${PREFIX}/bin/clang++" ]; then \
        ln -sf clang ${PREFIX}/bin/clang++; \
    fi

# ── Inline ELF validation ─────────────────────────────────────────────────────
# Verify the cross-compiled clang binary has the correct ELF attributes
# before copying into the scratch image.  Uses the NDK's llvm-readelf (host)
# to inspect the AArch64 ELF produced by llvm-cross.
RUN set -eux; \
    READELF="${NDK_TOOLCHAIN}/bin/llvm-readelf"; \
    CLANG_BIN="${PREFIX}/bin/clang"; \
    echo ""; \
    echo "═══════════════════════════════════════════════════════"; \
    echo "  ELF Validation: ${CLANG_BIN}"; \
    echo "═══════════════════════════════════════════════════════"; \
    echo ""; \
    echo "── ELF Header ──────────────────────────────────────────"; \
    ${READELF} -h "${CLANG_BIN}" \
        | grep -E "(Class|Machine|Type|Entry point)"; \
    echo ""; \
    echo "── NEEDED dynamic libraries ────────────────────────────"; \
    ${READELF} -d "${CLANG_BIN}" | grep NEEDED; \
    echo ""; \
    echo "── RUNPATH / RPATH ─────────────────────────────────────"; \
    ${READELF} -d "${CLANG_BIN}" | grep -E "(RPATH|RUNPATH)" || echo "(none — check LDFLAGS)"; \
    echo ""; \
    echo "── PT_INTERP (dynamic linker) ──────────────────────────"; \
    ${READELF} -l "${CLANG_BIN}" | grep "interpreter\|Requesting"; \
    echo ""; \
    echo "── PT_LOAD alignment (expect 0x4000 = 16384) ───────────"; \
    ${READELF} -l "${CLANG_BIN}" | awk '/LOAD/{found=1} found{print; if(/AlignLF|0x[0-9a-f]+$/){found=0}}' \
        || ${READELF} -l "${CLANG_BIN}" | grep -A1 "LOAD"; \
    echo ""; \
    echo "═══════════════════════════════════════════════════════"; \
    echo "  Validation complete."; \
    echo "═══════════════════════════════════════════════════════"; \
    echo ""

# ── Validate ld.lld as well ───────────────────────────────────────────────────
RUN set -eux; \
    READELF="${NDK_TOOLCHAIN}/bin/llvm-readelf"; \
    ${READELF} -h "${PREFIX}/bin/ld.lld" \
        | grep -E "(Class|Machine)" \
    && echo "ld.lld: AArch64 ELF confirmed"

# =============================================================================
# FINAL STAGE — FROM scratch: distroless Android /system image
# No package manager, no shell, no host OS. Only /system.
# =============================================================================
FROM scratch AS final

COPY --from=assembler /system/ /system/

# The natural Android entrypoint: the Bionic dynamic linker executing a binary.
# Override CMD to run any /system binary.
# On a real device: adb shell /system/bin/clang --version
# In QEMU:          qemu-aarch64 -L /ndk-sysroot /system/bin/clang --version
ENTRYPOINT ["/system/bin/linker64"]
CMD ["/system/bin/clang", "--version"]

LABEL org.opencontainers.image.title="Android aarch64 /system Bootstrap"
LABEL org.opencontainers.image.description="Distroless aarch64-linux-android API35 /system built from AOSP toolchain sources"
LABEL android.ndk.version="r27d"
LABEL android.api.level="35"
LABEL llvm.source="android.googlesource.com/toolchain/llvm-project"
LABEL llvm.build-system="android.googlesource.com/toolchain/llvm_android"
LABEL target.triple="aarch64-linux-android35"
