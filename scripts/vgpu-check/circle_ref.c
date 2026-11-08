#include <stdint.h>
#include <math.h>
/* QuartzCore (18A373) CA::OGL::SW::circle_sampler<false, false> (0x18370d938): a circle's
 * coverage, one grey byte (replicated to the four channels) per pixel. v0/v1 step v3/v2 each
 * pixel; |v0| + |v2| is the edge width, v3 the position in the unit circle. */
static inline int32_t fcvtzs32(float f)
{
    if (f != f) return 0;
    if (f >= 2147483648.0f) return INT32_MAX;
    if (f <= -2147483648.0f) return INT32_MIN;
    return (int32_t)f;
}
void circle00(const float v0[2], const float v1[2], const float v2in[2], const float v3in[2],
              uint32_t n, uint32_t *out)
{
    float a0 = fabsf(v0[0]), a1 = fabsf(v0[1]);
    float v2[2] = { v2in[0], v2in[1] }, v3[2] = { v3in[0], v3in[1] };
    for (uint32_t i = 0; i < n; i++) {
        float t0 = a0 + fabsf(v2[0]);
        float t1 = a1 + fabsf(v2[1]);
        float s7 = t0 > t1 ? t0 : t1;
        float m0 = v3[0] * v3[0];
        float m1 = v3[1] * v3[1];
        float s16 = m0 + m1;
        float lo = 1.0f - s7;
        uint32_t a;
        if (s16 < lo) {
            a = 0xff;
        } else {
            float hi = s7 + 1.0f;
            if (!(s16 <= hi) && !isnan(s16) && !isnan(hi)) {
                a = 0;
            } else {
                float q = sqrtf(s16);
                float r = s16 / q;
                float w = fmaf(s7, 0.5f, 1.0f);
                float z = w - r;
                z = z * 255.0f;
                z = z / s7;
                z = z + 0.5f;
                int32_t k = fcvtzs32(z);
                if (k < 0) k = 0;
                a = k < 0xff ? (uint32_t)k : 0xff;
            }
        }
        a |= a << 8;
        a |= a << 16;
        out[i] = a;
        v3[0] = v0[0] + v3[0];
        v3[1] = v0[1] + v3[1];
        v2[0] = v1[0] + v2[0];
        v2[1] = v1[1] + v2[1];
    }
}
