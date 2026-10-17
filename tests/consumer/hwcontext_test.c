/* Compile check: public hwcontext headers that include dependency headers
 * (AMF, libvpl, libva) build with only what the artifact ships and
 * FindCustomFFmpeg exports. Added by CMakeLists.txt when the artifact has
 * those headers. */
#include <libavutil/hwcontext.h>
#ifdef CONSUMER_HW_AMF
#include <libavutil/hwcontext_amf.h>
#endif
#ifdef CONSUMER_HW_QSV
#include <libavutil/hwcontext_qsv.h>
#endif
#ifdef CONSUMER_HW_VAAPI
#include <libavutil/hwcontext_vaapi.h>
#include <libavutil/hwcontext_drm.h>
#endif

int consumer_hwcontext_headers(void)
{
    int n = 0;
#ifdef CONSUMER_HW_AMF
    n += sizeof(AVAMFDeviceContext) > 0;
#endif
#ifdef CONSUMER_HW_QSV
    n += sizeof(AVQSVDeviceContext) > 0;
#endif
#ifdef CONSUMER_HW_VAAPI
    n += sizeof(AVVAAPIDeviceContext) > 0;
    n += sizeof(AVDRMDeviceContext) > 0;
#endif
    return n;
}
