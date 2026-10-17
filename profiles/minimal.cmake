# Minimal profile — only avutil + swscale for CPU color conversion
# Explicitly disable all libs we don't need to avoid unnecessary dependencies
set(FFMPEG_DISABLE_EVERYTHING ON)
set(FFMPEG_DISABLE_PROGRAMS   ON)
set(FFMPEG_DISABLE_DOC        ON)

set(FFMPEG_DISABLE_LIBS
    avdevice
    avcodec
    avformat
    avfilter
    swresample
)

set(FFMPEG_ENABLE_LIBS
    avutil
    swscale
)

set(FFMPEG_EXPECTED_LICENSE "LGPL version 2.1 or later")

# No system integrations (hwcontexts, TLS, ...): same result on every machine,
# no extra system libraries for consumers. License: LGPL version 2.1 or later.
set(FFMPEG_CONFIGURE_EXTRA
    --disable-autodetect
)
