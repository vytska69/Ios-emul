#include <stdint.h>
#include <math.h>
/* QuartzCore (18A373) CA::OGL::SW::circle_sampler<false, true> (0x18370d624): a rounded
 * rectangle's ("squircle") coverage, one grey byte (replicated) per pixel, written from its
 * code. k[0..4] are its constants (0x183876d40..d50), c7/c16 the two it builds in registers.
 * The edge band goes through powf, the host's here (the guest's libm in QuartzCore). */
static inline int32_t fcvtzs32(float f)
{
    if (f != f) return 0;
    if (f >= 2147483648.0f) return INT32_MAX;
    if (f <= -2147483648.0f) return INT32_MIN;
    return (int32_t)f;
}
void squircle(const float v0[2], const float v1[2], const float v2in[2], const float v3in[2],
              uint32_t n, uint32_t *out, const float k[5], float c7, float c16)
{
    float a0 = fabsf(v0[0]), a1 = fabsf(v0[1]);
    float v2[2] = { v2in[0], v2in[1] }, v3[2] = { v3in[0], v3in[1] };
    for (uint32_t i = 0; i < n; i++) {
        float t0 = a0 + fabsf(v2[0]);
        float t1 = a1 + fabsf(v2[1]);
        float p0 = fmaf(c7, fabsf(v3[0]), c16);
        float p1 = fmaf(c7, fabsf(v3[1]), c16);
        p0 = p0 > 0.0f ? p0 : 0.0f;
        p1 = p1 > 0.0f ? p1 : 0.0f;
        float s12 = t0 > t1 ? t0 : t1;
        float s1 = s12 * k[0];
        float q0 = p0 * p0, q1 = p1 * p1;
        float s3 = q0 + q1;
        float s8 = 1.0f - s1;
        uint32_t a;
        if (s3 < s8) {
            a = 0xff;
        } else {
            float cube = q0 * p0;
            cube = fmaf(q1, p1, cube);
            float s13 = s1 + 1.0f;
            if (!(cube <= s13) && !isnan(cube) && !isnan(s13)) {
                a = 0;
            } else {
                float w0 = powf(p0, k[1]);
                float w1 = powf(p1, k[1]);
                float s = w1 + w0;
                if (s < s8) {
                    a = 0xff;
                } else if (!(s <= s13) && !isnan(s) && !isnan(s13)) {
                    a = 0;
                } else {
                    float r = powf(s, k[2]);
                    float u = fmaf(s12, k[3], 1.0f);
                    float z = u - r;
                    z = z * k[4];
                    z = z / s12;
                    z = z + 0.5f;
                    int32_t kk = fcvtzs32(z);
                    if (kk < 0) kk = 0;
                    a = kk < 0xff ? (uint32_t)kk : 0xff;
                }
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
