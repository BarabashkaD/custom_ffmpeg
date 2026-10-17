# LGPL profile — everything that keeps FFmpeg under the LGPL (no x264/x265, no
# --enable-gpl), for proprietary consumers. H.264/HEVC: FFmpeg's own decoders,
# encoding through the OS encoders (Media Foundation / VideoToolbox) and the
# GPU vendor encoders.
# Enables: VP8/VP9, AV1 (SVT-AV1 encoding, dav1d decoding), Opus, Vorbis, Ogg,
# WebP, MP3 (lame), zlib; NVIDIA NVENC/NVDEC/CUVID, AMD AMF and Intel QSV on
# Windows and Linux, VAAPI on Linux.
# License of the result: LGPL version 2.1 or later.
# Programs: ffmpeg + ffprobe (bin/), also needed by most FATE tests
set(FFMPEG_DISABLE_DOC        ON)

# configure's license line must match — guards against GPL parts sneaking in
set(FFMPEG_EXPECTED_LICENSE "LGPL version 2.1 or later")

# All libs (libpostproc was removed from FFmpeg in 8.0)
set(FFMPEG_ENABLE_LIBS
    avutil
    avcodec
    avformat
    avdevice
    avfilter
    swscale
    swresample
)

# --disable-autodetect: only what is listed here gets enabled, so the feature
# set does not depend on what happens to be installed on the build machine
set(FFMPEG_CONFIGURE_EXTRA
    --disable-autodetect
    --enable-ffmpeg
    --enable-ffprobe
    --disable-ffplay
    --enable-zlib
    --enable-libvpx
    --enable-libopus
    --enable-libvorbis
    --enable-libwebp
    --enable-libmp3lame
    --enable-libsvtav1
    --enable-libdav1d
)

# ── GPU vendor encoders/decoders (Windows + Linux, not macOS) ────────────────
# The vendor runtime is loaded from the GPU driver at run time — no link
# dependency on it (NVIDIA/AMD: headers only; Intel: the MIT dispatcher),
# LGPL-compatible. Without the GPU/driver the codecs fail cleanly when opened.

# NVIDIA NVENC / NVDEC / CUVID (ffnvcodec dep). cuda-nvcc / libnpp would be
# nonfree and are not used. cuda-llvm: the CUDA filters (scale_cuda,
# yadif_cuda, overlay_cuda, ...) are compiled by clang to PTX and embedded; the
# driver JIT-compiles them at run time. Needs only clang's NVPTX target — no
# CUDA SDK (FFmpeg ships compat/cuda/cuda_runtime.h).
set(_NVIDIA_CONFIGURE
    --enable-ffnvcodec
    --enable-nvenc
    --enable-nvdec
    --enable-cuvid
    --enable-cuda-llvm
)
set(_NVIDIA_REQUIRED
    ffnvcodec
    cuda
    nvenc
    nvdec
    cuvid
    h264_nvenc_encoder
    hevc_nvenc_encoder
    av1_nvenc_encoder
    h264_nvdec_hwaccel
    hevc_nvdec_hwaccel
    vp9_nvdec_hwaccel
    av1_nvdec_hwaccel
    h264_cuvid_decoder
    hevc_cuvid_decoder
    vp9_cuvid_decoder
    av1_cuvid_decoder
    cuda_llvm
    hwupload_cuda_filter
    scale_cuda_filter
    yadif_cuda_filter
    bwdif_cuda_filter
    overlay_cuda_filter
)

# AMD AMF (amf dep): H.264/HEVC/AV1 encoders, decoders, scaling filters,
# display capture source
set(_AMF_CONFIGURE
    --enable-amf
)
set(_AMF_REQUIRED
    amf
    h264_amf_encoder
    hevc_amf_encoder
    av1_amf_encoder
    h264_amf_decoder
    hevc_amf_decoder
    av1_amf_decoder
    vp9_amf_decoder
    vpp_amf_filter
    sr_amf_filter
    amf_capture_filter
)

# Intel Quick Sync Video (libvpl dep: the VPL dispatcher, MIT, linked in; it
# loads the runtime from the Intel driver: libmfx64-gen.dll / libmfx-gen.so.1.2).
# Windows and Linux; on Linux FFmpeg's QSV device sits on a VAAPI device, so
# it needs the VAAPI block below as well.
set(_INTEL_CONFIGURE
    --enable-libvpl
)
set(_INTEL_REQUIRED
    libvpl
    qsv
    h264_qsv_encoder
    hevc_qsv_encoder
    av1_qsv_encoder
    vp9_qsv_encoder
    h264_qsv_decoder
    hevc_qsv_decoder
    av1_qsv_decoder
    vp9_qsv_decoder
    vpp_qsv_filter
)

# VAAPI (Linux; libva + libdrm deps, MIT, linked in): decoding (hwaccels),
# encoding and filters on Intel, AMD and other Mesa drivers. The VA driver
# (iHD_drv_video.so, radeonsi_drv_video.so, ...) is dlopen()ed from the
# system's driver directory at run time. libdrm: VAAPI device selection,
# DRM PRIME frame mapping (hwcontext_drm), kmsgrab screen capture.
set(_VAAPI_CONFIGURE
    --enable-vaapi
    --enable-libdrm
)
set(_VAAPI_REQUIRED
    vaapi
    vaapi_drm
    vaapi_1
    libdrm
    h264_vaapi_hwaccel
    hevc_vaapi_hwaccel
    vp8_vaapi_hwaccel
    vp9_vaapi_hwaccel
    av1_vaapi_hwaccel
    vvc_vaapi_hwaccel
    mpeg2_vaapi_hwaccel
    mjpeg_vaapi_hwaccel
    h264_vaapi_encoder
    hevc_vaapi_encoder
    av1_vaapi_encoder
    vp8_vaapi_encoder
    vp9_vaapi_encoder
    mjpeg_vaapi_encoder
    mpeg2_vaapi_encoder
    scale_vaapi_filter
    deinterlace_vaapi_filter
    tonemap_vaapi_filter
    transpose_vaapi_filter
    overlay_vaapi_filter
    kmsgrab_indev
)

# ── Platform features ────────────────────────────────────────────────────────
# OS frameworks (no extra dependencies) + the GPU vendor blocks above.
#   TLS for https: Schannel / SecureTransport; Linux has none (would need an
#   extra TLS library dependency)
set(FFMPEG_CONFIGURE_EXTRA_WINDOWS
    --enable-schannel
    --enable-mediafoundation
    --enable-d3d11va
    --enable-dxva2
    --enable-d3d12va
    ${_NVIDIA_CONFIGURE}
    ${_AMF_CONFIGURE}
    ${_INTEL_CONFIGURE}
)
set(FFMPEG_CONFIGURE_EXTRA_MACOS
    --enable-securetransport
    --enable-videotoolbox
    --enable-audiotoolbox
    --enable-avfoundation
    --enable-appkit
    --enable-coreimage
    --enable-metal
)
set(FFMPEG_CONFIGURE_EXTRA_LINUX
    --enable-v4l2-m2m
    ${_NVIDIA_CONFIGURE}
    ${_AMF_CONFIGURE}
    ${_VAAPI_CONFIGURE}
    ${_INTEL_CONFIGURE}
)

# Encoders that must end up enabled. configure can silently drop an encoder
# when its link probe fails (e.g. libvpx with a stray -lm) — build_ffmpeg.sh
# checks config.h after configure and fails the build instead.
set(FFMPEG_REQUIRED_ENCODERS
    libvpx_vp8
    libvpx_vp9
    libopus
    libvorbis
    libwebp
    libmp3lame
    libsvtav1
)

# Other config.h / config_components.h names that must be enabled
# (CONFIG_<NAME> or HAVE_<NAME>, lower case here)
set(FFMPEG_REQUIRED
    ffmpeg
    ffprobe
    zlib
    png_decoder
    png_encoder
    h264_decoder
    hevc_decoder
    libdav1d
    libdav1d_decoder
)
set(FFMPEG_REQUIRED_WINDOWS
    schannel
    https_protocol
    mediafoundation
    h264_mf_encoder
    hevc_mf_encoder
    d3d11va
    dxva2
    d3d12va
    ${_NVIDIA_REQUIRED}
    ${_AMF_REQUIRED}
    ${_INTEL_REQUIRED}
)
set(FFMPEG_REQUIRED_MACOS
    securetransport
    https_protocol
    videotoolbox
    h264_videotoolbox_encoder
    hevc_videotoolbox_encoder
    audiotoolbox
    avfoundation
)
set(FFMPEG_REQUIRED_LINUX
    v4l2_m2m
    ${_NVIDIA_REQUIRED}
    ${_AMF_REQUIRED}
    ${_VAAPI_REQUIRED}
    ${_INTEL_REQUIRED}
)
