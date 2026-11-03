
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

/*
 * QuartzCore (18A373) CA::OGL::SW::image_sampler<Format::ARGB8_Host, unsigned int,
 * false, true, false, true>: the affine bilinear read with the texture's edges
 * clamped (one row pair for the whole span), written from its code.
 */
static void ios_hcall_ca_clamp_argb8(CPUARMState *env, uintptr_t ra)
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
    int32_t maxu = cpu_ldl_le_mmuidx_ra(env, tex + 0x20, mmu, ra);
    int32_t maxv = cpu_ldl_le_mmuidx_ra(env, tex + 0x24, mmu, ra);
    int32_t u = cpu_ldl_le_mmuidx_ra(env, sd + 0x34, mmu, ra);
    int32_t du = cpu_ldl_le_mmuidx_ra(env, sd + 0x38, mmu, ra);
    int32_t v = cpu_ldl_le_mmuidx_ra(env, sd + 0x3c, mmu, ra);

    int32_t y0 = (v > 0x8000 ? v : 0x8000) - 0x8000;
    y0 = y0 < maxv ? y0 : maxv;
    int32_t y1 = (v > -0x8000 ? v : -0x8000) + 0x8000;
    y1 = y1 < maxv ? y1 : maxv;
    uint64_t row0 = base + stride * (int64_t)(int16_t)(y0 >> 16);
    uint64_t row1 = base + stride * (int64_t)(int16_t)(y1 >> 16);
    int16_t fy = ((uint32_t)y0 >> 1) & 0x7f80;

    while (count--) {
        int32_t x0 = (u > 0x8000 ? u : 0x8000) - 0x8000;
        x0 = x0 < maxu ? x0 : maxu;
        int32_t x1 = (u > -0x8000 ? u : -0x8000) + 0x8000;
        x1 = x1 < maxu ? x1 : maxu;
        int64_t c0 = x0 >> 16, c1 = x1 >> 16;
        uint32_t px[4] = {
            cpu_ldl_le_mmuidx_ra(env, row0 + c0 * 4, mmu, ra),
            cpu_ldl_le_mmuidx_ra(env, row0 + c1 * 4, mmu, ra),
            cpu_ldl_le_mmuidx_ra(env, row1 + c0 * 4, mmu, ra),
            cpu_ldl_le_mmuidx_ra(env, row1 + c1 * 4, mmu, ra),
        };
        int16_t fx = ((uint32_t)x0 >> 1) & 0x7f80;
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
        u += du;
    }
}

static uint32_t rs=12345; static uint32_t rnd(void){rs^=rs<<13;rs^=rs>>17;rs^=rs<<5;return rs;}
static void stl(uint64_t a,uint32_t v){memcpy(P(a),&v,4);} static void stq(uint64_t a,uint64_t v){memcpy(P(a),&v,8);}
int main(int argc,char**argv){
  rs=atoi(argv[1]);
  img=calloc(1,SIZE);
  uint64_t sd=BASE, tex=BASE+0x1000, tb=BASE+0x100000, out=BASE+0x200000;
  for(uint32_t i=0;i<0x80000/4;i++){ stl(tb+4*i,rnd()); }
  uint32_t tw=8+rnd()%120, th=4+rnd()%60;
  stq(sd,tex); stq(tex,tb+0x8000); stq(tex+0x10,tw*4+16);
  stl(tex+0x20,((tw-1)<<16)|(rnd()&0xffff)); stl(tex+0x24,((th-1)<<16)|(rnd()&0xffff));
  stl(sd+0x34,(int32_t)(rnd()%((tw+8)<<16))-(4<<16)); stl(sd+0x38,(int32_t)(rnd()%120000)-40000);
  stl(sd+0x3c,(int32_t)(rnd()%((th+8)<<16))-(4<<16));
  CPUARMState e={0}; e.xregs[0]=sd; e.xregs[1]=100; e.xregs[2]=out;
  FILE*f=fopen("img.bin","wb"); fwrite(img,1,SIZE,f); fclose(f);
  f=fopen("regs.bin","wb"); fwrite(e.xregs,8,4,f); fclose(f);
  ios_hcall_ca_clamp_argb8(&e,0);
  f=fopen("out_c.bin","wb"); fwrite(P(out),1,400,f); fclose(f);
  return 0;
}
