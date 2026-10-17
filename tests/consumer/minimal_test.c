// Link test for the minimal profile: avutil + swscale, one real RGB->YUV conversion.
#include <stdio.h>
#include <string.h>
#include <libavutil/avutil.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>

#ifdef CONSUMER_CXX
#define main test_main   /* called from main.cpp */
#endif

int main(void) {
    const int w = 64, h = 48;
    uint8_t *src[4], *dst[4];
    int src_ls[4], dst_ls[4];
    struct SwsContext *sws;
    printf("FFmpeg %s, swscale %u, license: %s\n", av_version_info(), swscale_version(),
           avutil_license());
    if (strncmp(avutil_license(), "LGPL ", 5) != 0) {
        printf("license MISMATCH: expected LGPL\n");
        return 1;
    }
    if (av_image_alloc(src, src_ls, w, h, AV_PIX_FMT_RGB24, 32) < 0 ||
        av_image_alloc(dst, dst_ls, w, h, AV_PIX_FMT_YUV420P, 32) < 0)
        return 1;
    sws = sws_getContext(w, h, AV_PIX_FMT_RGB24, w, h, AV_PIX_FMT_YUV420P,
                         SWS_BILINEAR, NULL, NULL, NULL);
    if (!sws) return 1;
    int rows = sws_scale(sws, (const uint8_t *const *)src, src_ls, 0, h, dst, dst_ls);
    printf("sws_scale converted %d rows: %s\n", rows, rows == h ? "OK" : "FAIL");
    sws_freeContext(sws);
    av_freep(&src[0]);
    av_freep(&dst[0]);
    return rows == h ? 0 : 1;
}
