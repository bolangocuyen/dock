# Android aarch64 `/system` Bootstrap

A multi-stage Dockerfile and build system that cross-compiles a complete
Unix-like runtime for `aarch64-linux-android` API 35, installed under
`/system`, and packages it as a distroless `FROM scratch` image.

---

## Architecture Overview

```
ubuntu:24.04 (host)
│
├─ base ──────────────────── NDK r27d download + all git clones
│   │
│   ├─ llvm-native ────────── Pass-1: x86_64 llvm-tblgen + clang-tblgen
│   │   └─ llvm-cross ─────── Pass-2: LLVM 22 → aarch64-linux-android35
│   │
│   ├─ libs-1 ──────────────── bzip2 / zlib / liblzma / zstd
│   │   └─ libs-2 ──────────── libffi / ncurses / readline / mpdecimal
│   │       └─ tools ─────────── GNU make / ninja / cmake (aarch64)
│   │           └─ curl-stage ─── OpenSSL 3 + curl (aarch64)
│   │
│   └─ assembler ────────────── Merges all /system artifacts, Bionic stubs,
│                                profile script, symlinks, ELF validation
│
└─ final (FROM scratch) ─────── Distroless /system image
```

### Two-Pass LLVM Strategy

Building LLVM for a cross-compilation target requires the build machine to
run TableGen — the LLVM code generation meta-compiler — natively. You cannot
cross-compile TableGen itself (it generates C++ source as a build step).

| Pass | Stage | Arch | What is built |
|------|-------|------|---------------|
| 1 | `llvm-native` | `x86_64` (host) | `llvm-tblgen`, `clang-tblgen` only |
| 2 | `llvm-cross` | `aarch64` (target) | Full LLVM 22: clang, lld, compiler-rt |

Pass-2 receives the pass-1 binaries via `COPY --from=llvm-native` and
passes them to CMake via `-DLLVM_TABLEGEN` and `-DCLANG_TABLEGEN`.

---

## Prerequisites

| Tool | Minimum Version | Notes |
|------|-----------------|-------|
| Docker | 24.x with BuildKit | `DOCKER_BUILDKIT=1` is set automatically |
| Disk space | ~80 GB | LLVM build generates ~50 GB of intermediates |
| RAM | 32 GB recommended | LLVM link phase is memory-intensive |
| CPU cores | 8+ recommended | Build parallelism via `-j$(nproc)` |

---

## Build Instructions

### Quick build

```bash
chmod +x build.sh
./build.sh
```

### Build a specific stage (iterative development)

```bash
# Download NDK and clone all sources (~3 min)
./build.sh --target base

# Build host tblgen only (~8 min)
./build.sh --target llvm-native

# Full cross LLVM (continues from cached llvm-native layer, ~45 min)
./build.sh --target llvm-cross

# Everything up through curl
./build.sh --target curl-stage

# Final scratch image
./build.sh --target final --validate
```

### Docker Compose (per-stage caching)

```bash
docker compose build base
docker compose build llvm-native
docker compose build llvm-cross
docker compose build libs-1 libs-2 tools curl-stage
docker compose build assembler
docker compose build final
```

### Custom build arguments

```bash
NDK_VERSION=r27d \
LLVM_VERSION=llvmorg-22.1.0 \
API_LEVEL=35 \
./build.sh --tag my-registry/android-system:latest --push my-registry
```

---

## Toolchain & Flag Reference

### Cross-compilation environment (all non-LLVM packages)

```bash
# Compiler wrappers (NDK r27d, inject --target and --sysroot automatically)
CC=aarch64-linux-android35-clang
CXX=aarch64-linux-android35-clang++

# LLVM tool aliases
AR=llvm-ar
AS=llvm-as
LD=ld.lld
RANLIB=llvm-ranlib
STRIP=llvm-strip

# Flags
CFLAGS="-O3 -I/system/include"
CXXFLAGS="-O3 -I/system/include"
LDFLAGS="-L/system/lib64 -L/system/lib \
         -Wl,-rpath=/system/lib64:/system/lib \
         -Wl,-z,max-page-size=16384 \
         -Wl,-dynamic-linker,/system/bin/linker64"
```

### Key linker flags explained

| Flag | Purpose |
|------|---------|
| `-Wl,-z,max-page-size=16384` | Android 15 mandatory 16 KB page alignment. Without this, binaries crash on devices with `CONFIG_ARM64_16K_PAGES=y`. |
| `-Wl,-dynamic-linker,/system/bin/linker64` | Hardcodes Bionic's linker into `PT_INTERP`. Without this, the kernel would look for `/lib64/ld-linux-aarch64.so.1` (glibc), which does not exist on Android. |
| `-Wl,-rpath=/system/lib64:/system/lib` | Bakes runtime library search path into the ELF `RUNPATH`. Bionic honours `RUNPATH`; `LD_LIBRARY_PATH` is a fallback. |

---

## Autoconf `--build` / `--host` Separation

Every autoconf-based package is configured with explicit `--build` and
`--host` flags:

```bash
./configure \
    --build=x86_64-linux-gnu   # machine running the configure script
    --host=aarch64-linux-android  # machine that will run the output
```

This prevents autoconf from running `AC_RUN_IFELSE` tests (which would
execute aarch64 binaries on the x86_64 host, causing immediate SIGILL or
`exec format error`) and forces it to use static cross-compilation probes
instead.

---

## Package Build Notes

### bzip2

bzip2 ships no autoconf; we invoke `make` directly with overridden tool
variables. The shared library is built separately via `Makefile-libbz2_so`
because the main Makefile only produces a static archive.

### ncurses

`--enable-widec` is mandatory for Python's `curses` module. Without it,
`_curses` fails to link against `libncursesw`. The `--with-terminfo-dirs`
flag bakes `/system/share/terminfo` into the binary so `setupterm()`
locates terminfo data without `$TERMINFO` being set.

`--without-cxx-binding` avoids a configure probe that tries to link a
C++ test binary — on Bionic, the `std::` namespace layout differs enough
to cause false negatives.

### mpdecimal

mpdecimal's configure does not support `--host`/`--build`. We override
`CC` on the `make` command line and pass `--with-machine=ansi64` to
select the portable 64-bit C implementation rather than the x86_64 inline
assembly path.

### LLVM / compiler-rt

`COMPILER_RT_DEFAULT_TARGET_ONLY=ON` prevents compiler-rt from trying to
build sanitizer libraries for the host architecture. On a cross build this
would try to build `x86_64` sanitizers using the aarch64 clang wrapper,
which fails immediately.

`LLVM_ENABLE_LIBEDIT=OFF` is required because libedit is not available in
the NDK sysroot. Without it, the clang binary ends up with an unresolved
`-ledit` at link time.

### curl

curl is linked against the OpenSSL 3.x built in the same stage rather than
the NDK's mbedTLS stub. OpenSSL's `Configure android-arm64` target handles
the NDK toolchain detection automatically via `ANDROID_NDK_ROOT`.

---

## Validation

The `assembler` stage runs inline ELF validation before the scratch copy:

```bash
# What the Dockerfile runs:
llvm-readelf -h  /system/bin/clang   # Class: ELF64, Machine: AArch64
llvm-readelf -d  /system/bin/clang   # NEEDED: libc.so, libm.so, ...
llvm-readelf -l  /system/bin/clang   # PT_LOAD p_align: 0x4000 (16384)
```

Expected output for the page-alignment check:
```
LOAD  ... 0x4000  # = 16384 = 16 KB ✓
```

For on-device or QEMU validation:
```bash
# On an Android 15 device (adb shell) or aarch64 QEMU userspace:
/system/bin/clang --version
/system/bin/ld.lld --version
/system/bin/cmake --version
/system/bin/curl --version
```

---

## `/system` Directory Layout

```
/system/
├── bin/
│   ├── clang             ← LLVM 22 Clang (aarch64)
│   ├── clang++           ← symlink → clang
│   ├── ld.lld            ← LLD linker
│   ├── llvm-ar           ← LLVM archiver
│   ├── llvm-ranlib       ← LLVM ranlib
│   ├── llvm-strip        ← LLVM strip
│   ├── cmake             ← CMake 3.31 (aarch64)
│   ├── ninja             ← Ninja 1.12 (aarch64)
│   ├── make              ← GNU Make 4.4 (aarch64)
│   ├── curl              ← curl 8.x (aarch64)
│   └── linker64          ← Bionic dynamic linker (OS-provided on device)
├── lib64/
│   ├── libc.so           ← Bionic C library stub
│   ├── libm.so           ← Bionic math library stub
│   ├── libdl.so          ← Bionic dynamic loader stub
│   ├── liblog.so         ← Android logging stub
│   ├── libLLVM.so        ← LLVM shared library
│   ├── libclang.so       ← Clang shared library
│   ├── libbz2.so         ← bzip2
│   ├── libz.so           ← zlib
│   ├── liblzma.so        ← xz/liblzma
│   ├── libzstd.so        ← zstd
│   ├── libffi.so         ← libffi
│   ├── libncursesw.so    ← ncurses (wide char)
│   ├── libreadline.so    ← readline
│   ├── libssl.so         ← OpenSSL 3
│   ├── libcrypto.so      ← OpenSSL 3
│   ├── libcurl.so        ← curl
│   └── pkgconfig/        ← .pc files for all libraries
├── include/              ← Headers for all installed packages
├── share/
│   └── terminfo/         ← ncurses terminal database
└── etc/
    └── profile           ← Environment initialization script
```

---

## Known Limitations

1. **No shell binary.** A shell (`mksh`, `toybox sh`) is not built by this
   Dockerfile. Add a build stage before `assembler` that builds one from
   the AOSP `platform/external/toybox` or `platform/external/mksh` mirror.

2. **linker64 is a stub.** The Docker scratch image contains a placeholder
   `linker64`. On a real Android 15 device, `/system/bin/linker64` is
   provided by the OS firmware and cannot be replaced. The placeholder
   exists only to satisfy the `FROM scratch` image structure.

3. **Python not included.** CPython aarch64 cross-compilation is a separate
   patch-heavy process (see `posixmodule.c` Android adaptations). It can be
   added as a stage after `libs-2`, depending on the full set of patches.

4. **No `termux-exec` wrapper.** For use inside Termux, binaries with
   `/system/bin/linker64` in `PT_INTERP` will not execute unless
   `termux-exec` is installed (which rewrites `PT_INTERP` on the fly).
