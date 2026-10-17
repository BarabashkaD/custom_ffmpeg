# Full profile — the LGPL profile plus the GPL encoders x264 and x265.
# Enables: x264, x265, VP8/VP9, Opus, Vorbis, Ogg, WebP, MP3 (lame), zlib.
# License of the result: GPL version 2 or later — any program using it must be
# GPL-compatible. For proprietary consumers use the lgpl profile.
include("${CMAKE_CURRENT_LIST_DIR}/lgpl.cmake")

set(FFMPEG_EXPECTED_LICENSE "GPL version 2 or later")

list(APPEND FFMPEG_CONFIGURE_EXTRA
    --enable-libx264
    --enable-libx265
    --enable-gpl
)

list(APPEND FFMPEG_REQUIRED_ENCODERS
    libx264
    libx265
)
