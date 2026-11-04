#include <stdint.h>
#include <string.h>
/* QuartzCore (18A373) CA::OGL::SW::scanline, its un-premultiplying loop at 0x18370621c:
 * each pixel in place to opaque, colours divided by alpha, with the code's float steps. */
static inline uint32_t fcvtzu32(float f)
{
    if (!(f > 0.0f)) return 0;               /* also NaN */
    if (f >= 4294967296.0f) return UINT32_MAX;
    return (uint32_t)f;
}
/* bic w, w, w, asr #31; sub #0xff; and asr #31; add #0xff: as a signed value, to [0, 255]. */
static inline uint32_t clamp255(uint32_t v)
{
    int32_t x = (int32_t)v;
    return x < 0 ? 0 : x > 255 ? 255 : (uint32_t)x;
}
void unpremul_loop(uint32_t *px, uint32_t n, float k, float eps)
{
    for (uint32_t i = 0; i < n; i++) {
        uint32_t p = px[i];
        float a = (float)(p >> 24) * k;
        float r = (float)((p >> 16) & 0xff) * k;
        float g = (float)((p >> 8) & 0xff) * k;
        float b = (float)(p & 0xff) * k;
        float m = a;
        if (!(m >= eps)) m = eps;                 /* fmaxnm(a, eps): a is never NaN */
        float inv = 1.0f / m;
        uint32_t R = clamp255(fcvtzu32(inv * (r * 255.0f)));
        uint32_t G = clamp255(fcvtzu32(inv * (g * 255.0f)));
        uint32_t B = clamp255(fcvtzu32(inv * (b * 255.0f)));
        px[i] = 0xff000000u | R << 16 | G << 8 | B;
    }
}
