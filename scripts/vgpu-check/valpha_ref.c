#include <stdint.h>
#include <stddef.h>
/* vImage vAlpha_Blend_Premultiplied_BGRA_8888_CV_vec (18A373), one row: the first
 * width & ~7 pixels as its NEON loop computes them, the rest as its scalar loop. */
static inline uint32_t vec_px(uint32_t t, uint32_t b)
{
    uint32_t a = t >> 24, o = 0;
    for (int c = 0; c < 4; c++) {
        uint32_t bc = (b >> (8 * c)) & 0xff, tc = (t >> (8 * c)) & 0xff;
        uint32_t m = (((bc * a + 0x80) & 0xffff) * 0x101) >> 16;
        uint32_t d = tc + ((bc - m) & 0xff);
        o |= (d > 255 ? 255 : d) << (8 * c);
    }
    return o;
}
static inline uint32_t scalar_px(uint32_t t, uint32_t b)
{
    uint32_t ia = (t >> 24) ^ 0xff, o = 0;
    for (int c = 0; c < 4; c++) {
        uint32_t bc = (b >> (8 * c)) & 0xff, tc = (t >> (8 * c)) & 0xff;
        uint32_t v = (ia * bc + tc * 255) * 257;
        uint32_t d = v > 0xff7f7f ? 255 : (v + 0x8080) >> 16;
        o |= d << (8 * c);
    }
    return o;
}
void valpha_row(const uint32_t *top, const uint32_t *back, uint32_t *dst, size_t width)
{
    size_t vec = width >= 8 ? width & ~(size_t)7 : 0;
    for (size_t i = 0; i < vec; i++) dst[i] = vec_px(top[i], back[i]);
    for (size_t i = vec; i < width; i++) dst[i] = scalar_px(top[i], back[i]);
}
