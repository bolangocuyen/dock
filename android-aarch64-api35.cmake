# =============================================================================
# Android AArch64 CMake Toolchain File
# File: android-aarch64-api35.cmake
#
# For use when cross-compiling individual packages for aarch64-linux-android
# API 35 targeting the /system prefix.
#
# This file covers the libs-1 / libs-2 / tools use case (NDK wrapper compilers).
# For compiling LLVM itself, use the inline toolchain file in the Dockerfile's
# llvm-cross stage, which uses the stage1 clang directly.
#
# Usage:
#   cmake -DCMAKE_TOOLCHAIN_FILE=/path/to/android-aarch64-api35.cmake \
#         -DANDROID_NDK=/opt/ndk \
#         -DPREFIX=/system \
#         ...
# =============================================================================

if(NOT DEFINED ANDROID_NDK)
    if(DEFINED ENV{NDK_ROOT})
        set(ANDROID_NDK $ENV{NDK_ROOT})
    else()
        message(FATAL_ERROR
            "ANDROID_NDK is not set. Pass -DANDROID_NDK=/opt/ndk "
            "or export NDK_ROOT=/opt/ndk before invoking cmake.")
    endif()
endif()

if(NOT DEFINED PREFIX)
    set(PREFIX "/system")
endif()

# ── System identity ───────────────────────────────────────────────────────────
set(CMAKE_SYSTEM_NAME      Android)
set(CMAKE_SYSTEM_VERSION   35)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_ANDROID_ARCH_ABI arm64-v8a)
set(CMAKE_ANDROID_NDK      ${ANDROID_NDK})
set(CMAKE_ANDROID_STL_TYPE c++_static)

# ── NDK toolchain paths ───────────────────────────────────────────────────────
set(NDK_HOST_TAG   linux-x86_64)
set(NDK_TOOLCHAIN  ${ANDROID_NDK}/toolchains/llvm/prebuilt/${NDK_HOST_TAG})
set(NDK_BIN        ${NDK_TOOLCHAIN}/bin)

# NDK wrapper scripts: aarch64-linux-android35-clang already injects
#   --target=aarch64-linux-android35  --sysroot=<NDK_SYSROOT>
# These are correct for userspace code linking against Bionic.
# (Do NOT use these wrappers to compile LLVM itself — see llvm-cross stage.)
set(CMAKE_C_COMPILER   ${NDK_BIN}/aarch64-linux-android35-clang
    CACHE FILEPATH "C compiler")
set(CMAKE_CXX_COMPILER ${NDK_BIN}/aarch64-linux-android35-clang++
    CACHE FILEPATH "C++ compiler")
set(CMAKE_AR      ${NDK_BIN}/llvm-ar     CACHE FILEPATH "ar")
set(CMAKE_RANLIB  ${NDK_BIN}/llvm-ranlib CACHE FILEPATH "ranlib")
set(CMAKE_LINKER  ${NDK_BIN}/ld.lld      CACHE FILEPATH "linker")
set(CMAKE_NM      ${NDK_BIN}/llvm-nm     CACHE FILEPATH "nm")
set(CMAKE_OBJCOPY ${NDK_BIN}/llvm-objcopy CACHE FILEPATH "objcopy")
set(CMAKE_OBJDUMP ${NDK_BIN}/llvm-objdump CACHE FILEPATH "objdump")
set(CMAKE_STRIP   ${NDK_BIN}/llvm-strip  CACHE FILEPATH "strip")

# ── Compiler & linker flags ───────────────────────────────────────────────────
set(ANDROID_C_FLAGS   "-O3 -I${PREFIX}/include")
set(ANDROID_CXX_FLAGS "-O3 -I${PREFIX}/include")

# Linker flags applied to every ELF produced:
#   -Wl,-z,max-page-size=16384
#     Android 15 (API 35) mandates 16 KB page alignment on devices with
#     CONFIG_ARM64_16K_PAGES.  Binaries without this flag crash on load.
#
#   -Wl,-dynamic-linker,/system/bin/linker64
#     Hardcodes Bionic's dynamic linker into PT_INTERP.  Without this,
#     lld defaults to /lib64/ld-linux-aarch64.so.1 (glibc path), which
#     does not exist on Android, causing immediate exec failure.
#
#   -Wl,-rpath=/system/lib64:/system/lib
#     Bakes the runtime library search path into ELF RUNPATH so shared
#     libraries are found without LD_LIBRARY_PATH on the target device.
set(ANDROID_LDFLAGS
    "-L${PREFIX}/lib64 \
     -L${PREFIX}/lib \
     -Wl,-rpath=/system/lib64:/system/lib \
     -Wl,-z,max-page-size=16384 \
     -Wl,-dynamic-linker,/system/bin/linker64")

set(CMAKE_C_FLAGS_INIT               ${ANDROID_C_FLAGS})
set(CMAKE_CXX_FLAGS_INIT             ${ANDROID_CXX_FLAGS})
set(CMAKE_EXE_LINKER_FLAGS_INIT      ${ANDROID_LDFLAGS})
set(CMAKE_SHARED_LINKER_FLAGS_INIT   "-Wl,-z,max-page-size=16384 -L${PREFIX}/lib64")
set(CMAKE_MODULE_LINKER_FLAGS_INIT   "-Wl,-z,max-page-size=16384 -L${PREFIX}/lib64")

# ── Sysroot & find_* routing ──────────────────────────────────────────────────
set(CMAKE_SYSROOT ${NDK_TOOLCHAIN}/sysroot)
set(CMAKE_FIND_ROOT_PATH ${NDK_TOOLCHAIN}/sysroot ${PREFIX})

# NEVER: never use host programs (prevents x86_64 binary contamination)
# ONLY:  only search target sysroot + prefix for libraries and headers
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# ── pkg-config ────────────────────────────────────────────────────────────────
set(ENV{PKG_CONFIG_PATH}        "${PREFIX}/lib64/pkgconfig:${PREFIX}/lib/pkgconfig")
set(ENV{PKG_CONFIG_LIBDIR}      "${PREFIX}/lib64/pkgconfig")
set(ENV{PKG_CONFIG_SYSROOT_DIR} "${NDK_TOOLCHAIN}/sysroot")

# ── Install layout ────────────────────────────────────────────────────────────
set(CMAKE_INSTALL_PREFIX    ${PREFIX}  CACHE PATH   "Install prefix")
set(CMAKE_INSTALL_LIBDIR    lib64      CACHE STRING "Library dir (AArch64 ABI)")
set(CMAKE_INSTALL_BINDIR    bin        CACHE STRING "Binary dir")
set(CMAKE_INSTALL_INCLUDEDIR include   CACHE STRING "Header dir")

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

# ── LLVM source info ──────────────────────────────────────────────────────────
# Note: LLVM itself is NOT built with this toolchain file.
# LLVM is built in the llvm-cross Docker stage using the stage1 clang directly
# with an inline CMake toolchain file that avoids NDK wrapper injection.
# This file is for all other packages (libs-1, libs-2, tools, curl).
