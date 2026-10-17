// Link test for the full and lgpl profiles: all FFmpeg libraries and the
// external encoders must resolve and register, and the library license must be
// the one the profile promises (CONSUMER_LGPL: lgpl profile). The C++
// dependencies also run: a short libx265 encode (full) and a QSV device probe.
#include <stdio.h>
#include <string.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavfilter/avfilter.h>
#include <libavdevice/avdevice.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
#include <libavutil/avutil.h>
#include <libavutil/hwcontext.h>
#include <libavutil/opt.h>

#ifdef CONSUMER_CXX
#define main test_main   /* called from main.cpp */
#endif

#ifdef CONSUMER_LGPL
#define EXPECTED_LICENSE "LGPL"
#else
#define EXPECTED_LICENSE "GPL"
#endif

/* Encode a few small frames: runs the encoder library's code, not just its
 * registration (MSVC static builds: x265 is C++ and is linked in the copy
 * built for the consumer's runtime). Returns the number of packets or < 0. */
static int encode_frames(const char *name, int frames) {
    const AVCodec *codec = avcodec_find_encoder_by_name(name);
    AVCodecContext *ctx = codec ? avcodec_alloc_context3(codec) : NULL;
    AVFrame *frame = av_frame_alloc();
    AVPacket *pkt = av_packet_alloc();
    int ret = AVERROR(ENOMEM), packets = 0;
    if (!ctx || !frame || !pkt)
        goto end;
    ctx->width = 64;
    ctx->height = 64;
    ctx->pix_fmt = AV_PIX_FMT_YUV420P;
    ctx->time_base.num = 1;
    ctx->time_base.den = 25;
    av_opt_set(ctx->priv_data, "preset", "ultrafast", 0);
    av_opt_set(ctx->priv_data, "x265-params", "log-level=error", 0);
    if ((ret = avcodec_open2(ctx, codec, NULL)) < 0)
        goto end;
    frame->format = ctx->pix_fmt;
    frame->width = ctx->width;
    frame->height = ctx->height;
    if ((ret = av_frame_get_buffer(frame, 0)) < 0)
        goto end;
    for (int i = 0; i <= frames; i++) {
        if (i < frames) {
            if ((ret = av_frame_make_writable(frame)) < 0)
                goto end;
            for (int p = 0; p < 3; p++)
                for (int y = 0; y < (p ? 32 : 64); y++)
                    for (int x = 0; x < (p ? 32 : 64); x++)
                        frame->data[p][y * frame->linesize[p] + x] = (uint8_t)(x + y + 3 * i);
            frame->pts = i;
        }
        if ((ret = avcodec_send_frame(ctx, i < frames ? frame : NULL)) < 0)
            goto end;
        while ((ret = avcodec_receive_packet(ctx, pkt)) >= 0) {
            packets++;
            av_packet_unref(pkt);
        }
        if (ret != AVERROR(EAGAIN) && ret != AVERROR_EOF)
            goto end;
    }
    ret = packets;
end:
    av_packet_free(&pkt);
    av_frame_free(&frame);
    avcodec_free_context(&ctx);
    return ret;
}

/* Open a QSV device when the build has one: runs the libvpl dispatcher (C++).
 * Without an Intel GPU runtime this fails, which is fine — it must not crash. */
static void probe_qsv(void) {
    enum AVHWDeviceType type = AV_HWDEVICE_TYPE_NONE;
    while ((type = av_hwdevice_iterate_types(type)) != AV_HWDEVICE_TYPE_NONE) {
        if (type == AV_HWDEVICE_TYPE_QSV) {
            AVBufferRef *dev = NULL;
            int level = av_log_get_level(), ret;
            av_log_set_level(AV_LOG_QUIET);
            ret = av_hwdevice_ctx_create(&dev, type, NULL, NULL, 0);
            av_log_set_level(level);
            printf("  hwdevice qsv         %s\n", ret >= 0 ? "OK" : "not available on this machine");
            av_buffer_unref(&dev);
        }
    }
}

int main(void) {
    const char *encoders[] = {
#ifndef CONSUMER_LGPL
        "libx264", "libx265",
#endif
        "libvpx", "libvpx-vp9", "libopus", "libvorbis", "libwebp", "libmp3lame", "png"};
    const char *decoders[] = {"h264", "hevc", "vp9", "png"};
    const char *license = avutil_license();
    int missing = 0;
    avdevice_register_all();
    printf("FFmpeg %s, license: %s\n", av_version_info(), license);
    for (size_t i = 0; i < sizeof(encoders) / sizeof(*encoders); i++) {
        const AVCodec *c = avcodec_find_encoder_by_name(encoders[i]);
        printf("  encoder %-12s %s\n", encoders[i], c ? "OK" : "MISSING");
        missing += !c;
    }
    for (size_t i = 0; i < sizeof(decoders) / sizeof(*decoders); i++) {
        const AVCodec *c = avcodec_find_decoder_by_name(decoders[i]);
        printf("  decoder %-12s %s\n", decoders[i], c ? "OK" : "MISSING");
        missing += !c;
    }
#ifndef CONSUMER_LGPL
    {
        int packets = encode_frames("libx265", 5);
        printf("  encode  libx265      %d packets%s\n", packets, packets == 5 ? "" : " FAILED");
        missing += packets != 5;
    }
#endif
    probe_qsv();
    if (strncmp(license, EXPECTED_LICENSE " ", strlen(EXPECTED_LICENSE) + 1) != 0) {
        printf("  license MISMATCH: expected %s\n", EXPECTED_LICENSE);
        missing++;
    }
    printf("swscale %u, swresample %u, avfilter %u, avformat %u\n",
           swscale_version(), swresample_version(), avfilter_version(), avformat_version());
    return missing ? 1 : 0;
}
