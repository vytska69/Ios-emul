#include <stdint.h>
#include <math.h>
/* QuartzCore (18A373) CA::OGL::SW::scanline, its loop at 0x183706fcc: each pixel's
 * luminance through a cubic, then the pixel moved towards that grey (alpha towards 255)
 * by amount/256, in the code's own integer lanes. */
static inline int32_t fcvtzs32(float f)
{
    if (f != f) return 0;
    if (f >= 2147483648.0f) return INT32_MAX;
    if (f <= -2147483648.0f) return INT32_MIN;
    return (int32_t)f;
}
void lum_loop(const uint32_t *src, uint32_t *dst, uint32_t n, uint32_t amount,
              const float c[4], const float w[3])
{
    for (uint32_t i = 0; i < n; i++) {
        uint32_t p = src[i];
        float l = (float)((p >> 8) & 0xff) * w[0];
        l = fmaf((float)((p >> 16) & 0xff), w[1], l);
        l = fmaf((float)(p & 0xff), w[2], l);
        float t = fmaf(c[0], l, c[1]);
        t = fmaf(l, t, c[2]);
        t = fmaf(l, t, c[3]);
        t = t * 255.0f;
        int32_t g = fcvtzs32(t);
        g = g < 0 ? 0 : g > 255 ? 255 : g;
        uint32_t g16 = (uint32_t)g | (uint32_t)g << 8;
        uint32_t g3 = g16 | (uint32_t)g << 16;
        uint32_t br = p & 0x00ff00ff, ga = (p >> 8) & 0x00ff00ff;
        uint32_t tga = 0x00ff0000u | ((g16 >> 8) & 0xff);
        uint32_t d1 = ((g3 & 0x00ff00ff) - br) * amount;
        uint32_t d2 = (tga - ga) * amount;
        uint32_t lo = (br + (d1 >> 8)) & 0x00ff00ff;
        uint32_t hi = (d2 + (ga << 8)) & 0xff00ff00u;
        dst[i] = lo | hi;
    }
}
