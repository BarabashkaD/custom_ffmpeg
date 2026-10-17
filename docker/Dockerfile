FROM alpine:3.21

RUN apk add --no-cache \
    # Compiler toolchain
    clang lld llvm \
    # Assemblers (NASM for x86 SIMD, Yasm as fallback some projects check for)
    nasm yasm \
    # Build systems
    make cmake ninja bash \
    # Meson (dav1d's only build system)
    meson \
    # pkg-config
    pkgconf \
    # Autotools (needed by libogg, libvorbis, opus autogen.sh)
    autoconf automake libtool \
    # Python3 (needed by libvpx configure)
    python3 \
    # Source management
    git \
    # Download tools (mp3lame archive)
    curl tar xz \
    # GNU diffutils (Alpine ships BusyBox diff which lacks --version; some configure
    # scripts e.g. libvpx probe 'diff --version' to verify GNU diff is present)
    diffutils

LABEL org.opencontainers.image.title="custom-ffmpeg-builder" \
      org.opencontainers.image.description="FFmpeg cross-compiler toolchain (tools only)"

# No COPY, no ENTRYPOINT — all scripts and configs come from mounted volumes
