
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
typedef struct { uint64_t xregs[32]; } CPUARMState;
#define BASE 0x10000000ull
#define SIZE (4u<<20)
static uint8_t *img; static uint8_t kpage[4096];
static uint8_t *P(uint64_t a){ if(a>=0x183876000ull && a<0x183877000ull) return kpage+(a-0x183876000ull); if(a<BASE||a>=BASE+SIZE){fprintf(stderr,"bad %llx\n",(unsigned long long)a);exit(2);} return img+(a-BASE);}
static uint64_t ldq(uint64_t a){uint64_t v;memcpy(&v,P(a),8);return v;}
static uint32_t ldl(uint64_t a){uint32_t v;memcpy(&v,P(a),4);return v;}
#define cpu_ldq_le_mmuidx_ra(e,a,m,r) ldq(a)
#define cpu_ldl_le_mmuidx_ra(e,a,m,r) ldl(a)
#define cpu_ldub_mmuidx_ra(e,a,m,r) (*P(a))
#define cpu_stl_le_mmuidx_ra(e,a,v,m,r) do{uint32_t _v=(v);memcpy(P(a),&_v,4);}while(0)
#define arm_env_mmu_index(e) 0
#include <math.h>

#define CA_SAMPLER_ARGB8_ADDR 0x183720c2cull
#define CA_SAMPLER_ARGB8_K11 0x183876d3cull
#define CA_SAMPLER_ARGB8_K12 0x183876d38ull

#pragma clang fp contract(off)
#pragma STDC FP_CONTRACT OFF

static inline int32_t ca_fcvtzs(float f)
{
    if (f != f) {
        return 0;
    }
    if (f >= 2147483648.0f) {
        return INT32_MAX;
    }
    if (f <= -2147483648.0f) {
        return INT32_MIN;
    }
    return (int32_t)f;
}

static inline int16_t ca_sqrdmulh16(int16_t a, int16_t b)
{
    int32_t p = 2 * (int32_t)a * (int32_t)b + (1 << 15);
    p >>= 16;
    return p > INT16_MAX ? INT16_MAX : p;
}

static inline float ca_frsqrte(float f)
{
#if defined(__aarch64__)
    float r;
    asm("frsqrte %s0, %s1" : "=w"(r) : "w"(f));
    return r;
#else
    return 1.0f / sqrtf(f);
#endif
}

static inline float ca_ldf(CPUARMState *env, uint64_t a, int mmu, uintptr_t ra)
{
    uint32_t w = cpu_ldl_le_mmuidx_ra(env, a, mmu, ra);
    float f;
    memcpy(&f, &w, 4);
    return f;
}

static void ios_hcall_ca_image_sampler_argb8(CPUARMState *env, uintptr_t ra)
{
    uint64_t *x = env->xregs;
    int mmu = arm_env_mmu_index(env);
    uint64_t sd = x[0], out = x[2], slide = x[17] - CA_SAMPLER_ARGB8_ADDR;
    uint32_t count = (uint32_t)x[1];

    if (!count) {
        return;
    }
    uint64_t tex = cpu_ldq_le_mmuidx_ra(env, sd, mmu, ra);
    uint64_t base = cpu_ldq_le_mmuidx_ra(env, tex, mmu, ra);
    uint64_t stride = cpu_ldq_le_mmuidx_ra(env, tex + 0x10, mmu, ra);
    int32_t maxu = cpu_ldl_le_mmuidx_ra(env, tex + 0x20, mmu, ra);
    int32_t maxv = cpu_ldl_le_mmuidx_ra(env, tex + 0x24, mmu, ra);
    uint32_t tw = cpu_ldl_le_mmuidx_ra(env, tex + 0x18, mmu, ra);
    uint32_t th = cpu_ldl_le_mmuidx_ra(env, tex + 0x1c, mmu, ra);
    float sx = ca_ldf(env, tex + 0x28, mmu, ra), sy = ca_ldf(env, tex + 0x2c, mmu, ra);
    int32_t u = cpu_ldl_le_mmuidx_ra(env, sd + 0x34, mmu, ra);
    int32_t du = cpu_ldl_le_mmuidx_ra(env, sd + 0x38, mmu, ra);
    int32_t v = cpu_ldl_le_mmuidx_ra(env, sd + 0x3c, mmu, ra);
    int32_t dv = cpu_ldl_le_mmuidx_ra(env, sd + 0x40, mmu, ra);
    float w = ca_ldf(env, cpu_ldq_le_mmuidx_ra(env, sd + 0x10, mmu, ra) + 0xc, mmu, ra);
    float dw = ca_ldf(env, cpu_ldq_le_mmuidx_ra(env, sd + 0x18, mmu, ra) + 0xc, mmu, ra);
    uint32_t mode = (uint32_t)cpu_ldub_mmuidx_ra(env, sd + 0x30, mmu, ra) - 1;
    float m54x = ca_ldf(env, sd + 0x54, mmu, ra), m54y = ca_ldf(env, sd + 0x58, mmu, ra);
    float m5cx = ca_ldf(env, sd + 0x5c, mmu, ra), m5cy = ca_ldf(env, sd + 0x60, mmu, ra);
    float k11 = ca_ldf(env, CA_SAMPLER_ARGB8_K11 + slide, mmu, ra);
    float k12 = ca_ldf(env, CA_SAMPLER_ARGB8_K12 + slide, mmu, ra);

    while (count--) {
        float inv = 1.0f / w;
        float fu = inv * (float)u, fv = inv * (float)v;
        int32_t iu = ca_fcvtzs(fu), iv = ca_fcvtzs(fv);
        float r0, r1;

        switch (mode) {
        case 0: {   /* distance (radial gradient) */
            float a = (float)iu * sx, b = (float)iv * sy;
            float a2 = a * a, b2 = b * b;
            float s = a2 + b2;
            float t = fmaxf(s, k11);
            r0 = s * ca_frsqrte(t);
            goto scale;
        }
        case 1: {   /* angle */
            float a = sx * (float)iu, b = sy * (float)iv;
            r0 = fmaf(atan2f(b, a), k12, 32768.0f);
            goto scale;
        }
        case 2: {   /* repeat */
            float a = (float)iu * (sx * (1.0f / 65536.0f));
            float b = (float)iv * (sy * (1.0f / 65536.0f));
            a = fminf(a - floorf(a), 0x1.fffffep-1f);
            b = fminf(b - floorf(b), 0x1.fffffep-1f);
            a = fmaf(a, m54x, m5cx) * (float)tw;
            b = fmaf(b, m54y, m5cy) * (float)th;
            iu = ca_fcvtzs(a * 65536.0f);
            iv = ca_fcvtzs(b * 65536.0f);
            break;
        }
        case 4: {   /* clamp to a range */
            float lox = m54x * (float)maxu, loy = m54y * (float)maxv;
            float hix = m5cx * (float)maxu, hiy = m5cy * (float)maxv;
            float a = (float)iu, b = (float)iv;
            a = a > hix ? hix : a;
            b = b > hiy ? hiy : b;
            a = lox > a ? lox : a;
            b = loy > b ? loy : b;
            iu = ca_fcvtzs(a);
            iv = ca_fcvtzs(b);
            break;
        }
        default:
            break;
        scale:
            r1 = 0.5f;
            iu = ca_fcvtzs(r0 * (float)tw);
            iv = ca_fcvtzs(r1 * (float)th);
            break;
        }

        int32_t x0 = (iu > 0x8000 ? iu : 0x8000) - 0x8000;
        x0 = x0 < maxu ? x0 : maxu;
        int32_t x1 = (iu > -0x8000 ? iu : -0x8000) + 0x8000;
        x1 = x1 < maxu ? x1 : maxu;
        int32_t y0 = (iv > 0x8000 ? iv : 0x8000) - 0x8000;
        y0 = y0 < maxv ? y0 : maxv;
        int32_t y1 = (iv > -0x8000 ? iv : -0x8000) + 0x8000;
        y1 = y1 < maxv ? y1 : maxv;

        uint64_t row0 = base + stride * (int64_t)(int16_t)(y0 >> 16);
        uint64_t row1 = base + stride * (int64_t)(int16_t)(y1 >> 16);
        int64_t c0 = x0 >> 16, c1 = x1 >> 16;
        uint32_t px[4] = {
            cpu_ldl_le_mmuidx_ra(env, row0 + c0 * 4, mmu, ra),
            cpu_ldl_le_mmuidx_ra(env, row0 + c1 * 4, mmu, ra),
            cpu_ldl_le_mmuidx_ra(env, row1 + c0 * 4, mmu, ra),
            cpu_ldl_le_mmuidx_ra(env, row1 + c1 * 4, mmu, ra),
        };
        int16_t fy = ((uint32_t)y0 >> 1) & 0x7f80;
        int16_t fx = ((uint32_t)x0 >> 1) & 0x7f80;
        int16_t r[8];
        for (int i = 0; i < 8; i++) {
            uint8_t a = px[i >> 2] >> (8 * (i & 3));       /* row 0: col 0, col 1 */
            uint8_t b = px[2 + (i >> 2)] >> (8 * (i & 3)); /* row 1 */
            int16_t d = (int16_t)((uint16_t)b - (uint16_t)a);
            r[i] = (int16_t)(ca_sqrdmulh16(d, fy) + a);
        }
        uint32_t o = 0;
        for (int i = 0; i < 4; i++) {
            int16_t e = (int16_t)(r[4 + i] - r[i]);
            int16_t q = (int16_t)(r[i] + ca_sqrdmulh16(e, fx));
            o |= (uint32_t)(uint8_t)q << (8 * i);
        }
        cpu_stl_le_mmuidx_ra(env, out, o, mmu, ra);
        out += 4;
        w = dw + w;
        u += du;
        v += dv;
    }
}

/*
 * QuartzCore (18A373) CA::OGL::SW::image_sampler<Format::XRGB8_Host / ARGB8_Host,
 * unsigned int, false, false, false, true>: the affine (no perspective, no edge
 * mode) bilinear read, written from its code like the ARGB8 one above. XRGB8
 * sets alpha to 0xff on every texel it reads.
 */
static void ios_hcall_ca_affine_sampler(CPUARMState *env, uintptr_t ra, int xrgb)
{
    uint64_t *x = env->xregs;
    int mmu = arm_env_mmu_index(env);
    uint64_t sd = x[0], out = x[2];
    uint32_t count = (uint32_t)x[1];

    if (!count) {
        return;
    }
    uint64_t tex = cpu_ldq_le_mmuidx_ra(env, sd, mmu, ra);
    uint64_t base = cpu_ldq_le_mmuidx_ra(env, tex, mmu, ra);
    uint64_t stride = cpu_ldq_le_mmuidx_ra(env, tex + 0x10, mmu, ra);
    int32_t u = cpu_ldl_le_mmuidx_ra(env, sd + 0x34, mmu, ra);
    int32_t du = cpu_ldl_le_mmuidx_ra(env, sd + 0x38, mmu, ra);
    int32_t v = cpu_ldl_le_mmuidx_ra(env, sd + 0x3c, mmu, ra);
    int32_t y0 = v - 0x8000, y1 = v + 0x8000;
    uint64_t row0 = base + stride * (int64_t)(int16_t)(y0 >> 16);
    uint64_t row1 = base + stride * (int64_t)(int16_t)(y1 >> 16);
    int16_t fy = ((uint32_t)y0 >> 1) & 0x7f80;
    uint32_t or = xrgb ? 0xff000000u : 0;
    int32_t xf = u - 0x8000;

    while (count--) {
        int64_t c0 = xf >> 16, c1 = (int32_t)(xf + 0x10000) >> 16;
        uint32_t px[4] = {
            cpu_ldl_le_mmuidx_ra(env, row0 + c0 * 4, mmu, ra) | or,
            cpu_ldl_le_mmuidx_ra(env, row0 + c1 * 4, mmu, ra) | or,
            cpu_ldl_le_mmuidx_ra(env, row1 + c0 * 4, mmu, ra) | or,
            cpu_ldl_le_mmuidx_ra(env, row1 + c1 * 4, mmu, ra) | or,
        };
        int16_t fx = ((uint32_t)xf >> 1) & 0x7f80;
        int16_t r[8];
        for (int i = 0; i < 8; i++) {
            uint8_t a = px[i >> 2] >> (8 * (i & 3));
            uint8_t b = px[2 + (i >> 2)] >> (8 * (i & 3));
            r[i] = (int16_t)(ca_sqrdmulh16((int16_t)((uint16_t)b - (uint16_t)a), fy) + a);
        }
        uint32_t o = 0;
        for (int i = 0; i < 4; i++) {
            int16_t q = (int16_t)(r[i] + ca_sqrdmulh16((int16_t)(r[4 + i] - r[i]), fx));
            o |= (uint32_t)(uint8_t)q << (8 * i);
        }
        cpu_stl_le_mmuidx_ra(env, out, o, mmu, ra);
        out += 4;
        xf += du;
    }
}

/*
 * QuartzCore (18A373) CA::OGL::SW::tex_color_matrix_4x4_bias(unsigned *out,
 * unsigned const *in, unsigned long count, float const *m): a color matrix on
 * premultiplied pixels (unpremultiply, 4x4 matrix plus bias, premultiply),
 * written from its code. x17 is the function's address, for its constant.
 */
#define CA_COLOR_MATRIX_ADDR 0x183708fd8ull
#define CA_COLOR_MATRIX_K0 0x183876c24ull

static inline float ca_clamp01(float f)
{
    /* fmin then fmax (not the number-preferring forms). */
    f = (f != f || f < 1.0f) ? f : 1.0f;
    f = (f != f || f > 0.0f) ? f : 0.0f;
    return f;
}

static inline uint32_t ca_fcvtzu(float f)
{
    if (f != f || f <= 0.0f) {
        return 0;
    }
    if (f >= 4294967296.0f) {
        return UINT32_MAX;
    }
    return (uint32_t)f;
}

static void ios_hcall_ca_color_matrix(CPUARMState *env, uintptr_t ra)
{
    uint64_t *x = env->xregs;
    int mmu = arm_env_mmu_index(env);
    uint64_t out = x[0], in = x[1], n = x[2], mp = x[3];
    float m[20];

    if (!n) {
        return;
    }
    for (int i = 0; i < 20; i++) {
        m[i] = ca_ldf(env, mp + 4 * i, mmu, ra);
    }
    float k0 = ca_ldf(env, CA_COLOR_MATRIX_K0 + (x[17] - CA_COLOR_MATRIX_ADDR), mmu, ra);

    while (n--) {
        uint32_t p = cpu_ldl_le_mmuidx_ra(env, in, mmu, ra), o = 0;
        uint32_t a8 = p >> 24;

        if (a8) {
            float fa = (float)a8;
            float aa = fa * k0;
            float inv = 1.0f / fa;
            float r = inv * (float)((p >> 16) & 0xff);
            float g = inv * (float)((p >> 8) & 0xff);
            float b = inv * (float)(p & 0xff);
            float s16 = g * m[4];
            s16 = fmaf(r, m[0], s16);
            s16 = fmaf(b, m[8], s16);
            s16 = fmaf(aa, m[12], s16);
            float l0 = m[6] * g, l1 = m[7] * g;
            l0 = fmaf(m[2], r, l0);
            l1 = fmaf(m[3], r, l1);
            float s7 = g * m[5];
            float s6 = fmaf(r, m[1], s7);
            float R = m[16] + s16;
            l0 = fmaf(m[10], b, l0);
            l1 = fmaf(m[11], b, l1);
            l0 = fmaf(m[14], aa, l0);
            l1 = fmaf(m[15], aa, l1);
            float B = m[18] + l0, A = m[19] + l1;
            R = R * A;
            float G = fmaf(b, m[9], s6);
            G = fmaf(aa, m[13], G);
            G = m[17] + G;
            G = G * A;
            B = A * B;
            uint32_t ia = ca_fcvtzu(fmaf(ca_clamp01(A), 255.0f, 0.5f));
            uint32_t ir = ca_fcvtzu(fmaf(ca_clamp01(R), 255.0f, 0.5f));
            uint32_t ig = ca_fcvtzu(fmaf(ca_clamp01(G), 255.0f, 0.5f));
            uint32_t ib = ca_fcvtzu(fmaf(ca_clamp01(B), 255.0f, 0.5f));
            o = (ia << 24) | (ir << 16) | (ig << 8) | ib;
        }
        cpu_stl_le_mmuidx_ra(env, out, o, mmu, ra);
        out += 4;
        in += 4;
    }
}

/*
 * More of QuartzCore's (18A373) CPU renderer, written from its code: the
 * nearest-texel ARGB8 read (image_sampler<ARGB8_Host, unsigned, 0,0,0,0>),
 * tex_multiply_color (a pixel times a color), and the DarkenSover blend loop
 * (Blend::Mode<DarkenSover, false>::blend with its per-pixel function f).
 */
static void ios_hcall_ca_nearest_argb8(CPUARMState *env, uintptr_t ra)
{
    uint64_t *x = env->xregs;
    int mmu = arm_env_mmu_index(env);
    uint64_t sd = x[0], out = x[2];
    uint32_t count = (uint32_t)x[1];

    if (!count) {
        return;
    }
    uint64_t tex = cpu_ldq_le_mmuidx_ra(env, sd, mmu, ra);
    int32_t u = cpu_ldl_le_mmuidx_ra(env, sd + 0x34, mmu, ra);
    int32_t du = cpu_ldl_le_mmuidx_ra(env, sd + 0x38, mmu, ra);
    int32_t v = cpu_ldl_le_mmuidx_ra(env, sd + 0x3c, mmu, ra);
    uint64_t row = cpu_ldq_le_mmuidx_ra(env, tex, mmu, ra) +
                   cpu_ldq_le_mmuidx_ra(env, tex + 0x10, mmu, ra) * (int64_t)(int16_t)(v >> 16);

    while (count--) {
        cpu_stl_le_mmuidx_ra(env, out,
                             cpu_ldl_le_mmuidx_ra(env, row + (int64_t)(u >> 16) * 4, mmu, ra),
                             mmu, ra);
        out += 4;
        u += du;
    }
}

static void ios_hcall_ca_multiply_color(CPUARMState *env, uintptr_t ra)
{
    uint64_t *x = env->xregs;
    int mmu = arm_env_mmu_index(env);
    uint64_t out = x[0], in = x[1], n = x[3];
    uint32_t c = (uint32_t)x[2];
    uint32_t ca = (c >> 24) + 1, cr = ((c >> 16) & 0xff) + 1;
    uint32_t cg = ((c >> 8) & 0xff) + 1, cb = (c & 0xff) + 1;

    while (n--) {
        uint32_t p = cpu_ldl_le_mmuidx_ra(env, in, mmu, ra);
        uint32_t a = ((p >> 24) * ca) >> 8;
        uint32_t r = ((((p >> 16) & 0xff) * cr) << 8) & 0x1ff0000;
        uint32_t g = ((p >> 8) & 0xff) * cg;
        uint32_t b = (p & 0xff) * cb;
        uint32_t o = (uint32_t)((((uint64_t)a << 32) | b) >> 8);
        cpu_stl_le_mmuidx_ra(env, out, o | (g & 0x1ff00) | r, mmu, ra);
        out += 4;
        in += 4;
    }
}

static inline uint32_t ca_darken_sover(uint32_t d, uint32_t s)
{
    const uint64_t mask = 0x00ff00ff00ff00ffull;
    uint64_t r = (d >> 16) & 0xff, g = (d >> 8) & 0xff, b = d & 0xff;
    uint64_t l = (r * 0x36 + (g * 0xb7 + b * 0x13)) >> 8;
    uint64_t t = (l + 1) * l;
    uint64_t k = (((t >> 8) + 1) * ((t >> 8) & 0xffffffffull)) >> 8;
    k += 1;
    uint64_t sx = ((uint64_t)s | ((uint64_t)s << 24)) & mask;
    sx = ((sx * k) >> 8) & mask;
    uint32_t sv = (uint32_t)(sx >> 24) | (uint32_t)sx;
    uint32_t inv = 0x100 - (sv >> 24);
    uint64_t dx = ((uint64_t)d | ((uint64_t)d << 24)) & mask;
    dx = ((dx * inv) >> 8) & mask;
    uint32_t dv = (uint32_t)(dx >> 24) | (uint32_t)dx;
    return dv + sv;
}

static void ios_hcall_ca_darken_blend(CPUARMState *env, uintptr_t ra)
{
    uint64_t *x = env->xregs;
    int mmu = arm_env_mmu_index(env);
    uint64_t out = x[0], dst = x[1], src = x[2], n = x[3];

    while (n--) {
        uint32_t s = cpu_ldl_le_mmuidx_ra(env, src, mmu, ra);
        uint32_t d = cpu_ldl_le_mmuidx_ra(env, dst, mmu, ra);
        cpu_stl_le_mmuidx_ra(env, out, ca_darken_sover(d, s), mmu, ra);
        out += 4;
        dst += 4;
        src += 4;
    }
}

static uint32_t rs=12345; static uint32_t rnd(void){rs^=rs<<13;rs^=rs>>17;rs^=rs<<5;return rs;}
static void stl(uint64_t a,uint32_t v){memcpy(P(a),&v,4);} static void stq(uint64_t a,uint64_t v){memcpy(P(a),&v,8);}
int main(int argc,char**argv){
  int which=atoi(argv[1]); rs=atoi(argv[2]);
  img=calloc(1,SIZE);
  uint64_t sd=BASE, tex=BASE+0x1000, tb=BASE+0x100000, out=BASE+0x200000, in=BASE+0x300000, in2=BASE+0x340000;
  for(uint32_t i=0;i<0x80000/4;i++){ stl(tb+4*i,rnd()); }
  for(int i=0;i<300;i++){ stl(in+4*i,rnd()); stl(in2+4*i,rnd()); }
  CPUARMState e={0};
  if(which==0){ uint32_t tw=8+rnd()%120; stq(sd,tex); stq(tex,tb+0x4000); stq(tex+0x10,tw*4+16);
    stl(sd+0x34,(rnd()%(tw<<15))+0x10000); stl(sd+0x38,rnd()%60000); stl(sd+0x3c,(rnd()%(64<<16)));
    e.xregs[0]=sd; e.xregs[1]=100; e.xregs[2]=out; }
  else if(which==1){ e.xregs[0]=out; e.xregs[1]=in; e.xregs[2]=rnd(); e.xregs[3]=200; }
  else { e.xregs[0]=out; e.xregs[1]=in; e.xregs[2]=in2; e.xregs[3]=200; }
  FILE*f=fopen("img.bin","wb"); fwrite(img,1,SIZE,f); fclose(f); f=fopen("kpage.bin","wb"); fwrite(kpage,1,4096,f); fclose(f);
  f=fopen("regs.bin","wb"); fwrite(e.xregs,8,4,f); fclose(f);
  if(which==0) ios_hcall_ca_nearest_argb8(&e,0); else if(which==1) ios_hcall_ca_multiply_color(&e,0); else ios_hcall_ca_darken_blend(&e,0);
  f=fopen("out_c.bin","wb"); fwrite(P(out),1,800,f); fclose(f);
  return 0;
}
