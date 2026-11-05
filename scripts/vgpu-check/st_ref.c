#include <stdint.h>
#include <string.h>
#include <math.h>
/*
 * QuartzCore (18A373) CA::OGL::SW::sample_texture, everything but the sampler call:
 * the SamplerData it builds on its stack (frame = sp after its prologue) and the
 * index of the sampler in the texture's table. Inputs as the code loads them.
 */
typedef struct StIn {
    uint64_t x1, x4, x5, x6, x7;
    uint32_t w2, w3;
    uint8_t mode;              /* stack argument 0 */
    uint8_t b40, b41;          /* texture +0x40, +0x41 */
    uint32_t t18, t1c;         /* texture +0x18, +0x1c */
    int32_t t20, t24;          /* texture +0x20, +0x24 */
    float x4_c;                /* [x4 + 0xc] */
    float a[2], b[2], c[2];    /* x4, x5, x6 at + 0x20 + 8 * w2 */
    float k_d04;               /* QuartzCore const 0x183876d04 */
    uint32_t count;            /* stack argument 1 */
    uint8_t q[16];             /* [ctx + 8] + 0x1d8 */
    int have_p;                /* [[ctx + 8] + 0x1d0] != 0 */
    uint8_t p4;                /* p + 4 */
    uint32_t p0, p8w, p10;     /* p + 0, p + 8 (as word), p + 0x10 */
    float p8, pc;              /* p + 8, p + 0xc */
} StIn;

typedef struct StOut {
    uint8_t frame[0x70];       /* the bytes the code writes, others untouched */
    uint8_t written[0x70];
    uint32_t index;
} StOut;

static void put32(StOut *o, int off, uint32_t v)
{
    memcpy(&o->frame[off], &v, 4); memset(&o->written[off], 1, 4);
}
static void put64(StOut *o, int off, uint64_t v)
{
    memcpy(&o->frame[off], &v, 8); memset(&o->written[off], 1, 8);
}
static void putf(StOut *o, int off, float f) { uint32_t v; memcpy(&v, &f, 4); put32(o, off, v); }

static int32_t fcvtzs16(float f)       /* fcvtzs w, s, #16 */
{
    if (f != f) return 0;
    double d = (double)f * 65536.0;
    if (d >= 2147483648.0) return INT32_MAX;
    if (d <= -2147483649.0) return INT32_MIN;
    return (int32_t)d;
}

void st_setup(const StIn *in, StOut *o)
{
    memset(o, 0, sizeof(*o));
    put64(o, 0x0, in->x1);
    put32(o, 0x8, in->w2); put32(o, 0xc, in->w3);
    put64(o, 0x10, in->x4); put64(o, 0x18, in->x5);
    put64(o, 0x20, in->x6); put64(o, 0x28, in->x7);
    o->frame[0x30] = in->mode; o->written[0x30] = 1;
    if (in->mode == 5 || in->mode == 3) {
        memcpy(&o->frame[0x54], in->q, 16); memset(&o->written[0x54], 1, 16);
    }
    uint32_t w11 = in->b40, w9 = in->b40 != in->b41 ? 0 : 0;
    float s0 = 0.5f, s1, s2;
    uint32_t persp = in->w3 & 4;
    if (in->b40 == in->b41) {
        s1 = (float)in->t18; s2 = (float)in->t1c;
    } else {
        float s3, s4;
        if (!persp) {
            s1 = in->b[0]; s2 = in->b[1];
            s3 = fabsf(s1);
            s4 = in->c[0]; s1 = in->c[1];
            s4 = fabsf(s4);
            s3 = s3 + s4;
            s2 = fabsf(s2);
        } else {
            s1 = 1.0f / in->x4_c;
            s2 = in->b[0]; s4 = in->b[1];
            s2 = s2 * s1; s2 = fabsf(s2);
            s3 = in->c[0]; float s5 = in->c[1];
            s3 = s1 * s3; s3 = fabsf(s3);
            s3 = s2 + s3;
            s2 = s1 * s4; s2 = fabsf(s2);
            s1 = s1 * s5;
        }
        s1 = fabsf(s1);
        s4 = s2 + s1;
        s1 = (float)in->t18; s2 = (float)in->t1c;
        s4 = s4 * s2;
        s3 = fmaf(s3, s1, s4);
        s3 = s3 * s0;
        w11 = (s3 < in->k_d04) ? in->b41 : in->b40;     /* fcmp; csel mi */
    }
    (void)w9;
    float s3 = in->a[0] * s1, s5 = in->a[1];
    float s4 = in->b[0] * s1, s6 = in->b[1];
    s1 = s5 * s2;
    s2 = s6 * s2;
    int32_t w13 = fcvtzs16(s3), w10 = fcvtzs16(s1), w15 = fcvtzs16(s4), w14 = fcvtzs16(s2);
    put32(o, 0x34, (uint32_t)w13); put32(o, 0x38, (uint32_t)w15);
    put32(o, 0x3c, (uint32_t)w10); put32(o, 0x40, (uint32_t)w14);
    uint32_t w3 = ((in->t1c != 1) && !(s6 == 0.0f)) | w11;
    if (persp || in->mode) {
        w3 |= 6;
    } else {
        int bit2 = 0;
        uint32_t n1 = in->count - 1;
        int32_t e9 = (int32_t)(n1 * (uint32_t)w15 + (uint32_t)w13);
        int32_t e12 = (int32_t)(n1 * (uint32_t)w14 + (uint32_t)w10);
        int32_t lo_u = w15 < 0 ? e9 : w13, hi_u = w15 < 0 ? w13 : e9;
        int32_t lo_v = w14 < 0 ? e12 : w10, hi_v = w14 < 0 ? w10 : e12;
        if (w11 & 8) {
            lo_u = (int32_t)((uint32_t)lo_u - 0x8000); hi_u = (int32_t)((uint32_t)hi_u + 0x8000);
            lo_v = (int32_t)((uint32_t)lo_v - 0x8000); hi_v = (int32_t)((uint32_t)hi_v + 0x8000);
        }
        if (lo_u < 0 || lo_v < 0 || hi_u > in->t20 || hi_v > in->t24) {
            bit2 = 1;
        } else {
            float a5 = s3 >= 0.0f ? s3 : -s3;
            if (a5 > 8192.0f) bit2 = 1;
            else {
                a5 = s1 >= 0.0f ? s1 : -s1;
                if (a5 > 8192.0f) bit2 = 1;
                else {
                    float n = (float)n1;
                    float t6 = fmaf(s4, n, s3);
                    float t3 = -fmaf(s4, n, s3);
                    float m = !(t6 >= 0.0f) ? t3 : t6;          /* fcsel lt */
                    if (m > 8192.0f) bit2 = 1;
                    else {
                        float u3 = fmaf(s2, n, s1);
                        float u1 = -fmaf(s2, n, s1);
                        float mm = !(u3 >= 0.0f) ? u1 : u3;
                        if (mm > 8192.0f) bit2 = 1;           /* b.le skips: ordered > only */
                    }
                }
            }
        }
        if (bit2) w3 |= 2;
    }
    if (in->have_p) {
        float sp44 = in->p4 == 0 ? 1.0f : -1.0f;
        putf(o, 0x44, sp44);
        put32(o, 0x48, in->p10);
        uint32_t c = in->p0 - 1;
        if (c <= 3) {
            if (c == 0) {
                put32(o, 0x4c, in->p8w);
            } else {
                float v3 = -0.5f, v0 = 0.5f;
                if (c == 2) { v0 = 0.0f; v3 = -1.0f; }
                else if (c == 3) { v3 = 0.0f; v0 = 1.0f; }
                float q1 = fmaf(v3, in->pc, in->p8);
                float q0 = fmaf(v0, in->pc, in->p8);
                if (q0 > q1) { putf(o, 0x4c, q1); putf(o, 0x50, q0); }
                else { putf(o, 0x4c, q0); putf(o, 0x50, q1); }
            }
        }
    }
    o->index = w3;
}

/* After the sampler: when [ctx2 + w2 + 0x11] is 0xf, each output pixel ROR'd so alpha leads. */
void st_post(uint32_t *out, uint32_t count, uint8_t fmt)
{
    if (fmt != 0xf || !count) return;
    for (uint32_t i = 0; i < count; i++) {
        uint32_t w = out[i];
        uint32_t a = w >> 24;
        uint32_t e = (a << 8) | (w >> 24);         /* extr w9, w10, w9, #24 */
        e = (uint32_t)((((uint64_t)a << 32) | w) >> 24);
        out[i] = e | (e << 16);
    }
}
