#include <stdint.h>
#include <stdio.h>
static inline int16_t ca_sqrdmulh16(int16_t a, int16_t b)
{
    int32_t p = 2 * (int32_t)a * (int32_t)b + (1 << 15);
    p >>= 16;
    return p > INT16_MAX ? INT16_MAX : p;
}
/*
 * The bilinear blend of QuartzCore's samplers: rows with usubl/sqrdmulh/uaddw by
 * fy, then the columns by fx, the low byte of each lane kept (uzp1). On an
 * AArch64 host the same NEON instructions, so the result is the guest's.
 */
#if defined(__aarch64__)
#include <arm_neon.h>
#endif
static inline uint32_t ca_bilerp(uint32_t p00, uint32_t p01, uint32_t p10, uint32_t p11,
                                 int16_t fy, int16_t fx)
{
#if defined(__aarch64__)
    uint8x8_t a = vcreate_u8((uint64_t)p00 | ((uint64_t)p01 << 32));
    uint8x8_t b = vcreate_u8((uint64_t)p10 | ((uint64_t)p11 << 32));
    int16x8_t d = vreinterpretq_s16_u16(vsubl_u8(b, a));
    d = vqrdmulhq_s16(d, vdupq_n_s16(fy));
    int16x8_t r = vreinterpretq_s16_u16(vaddw_u8(vreinterpretq_u16_s16(d), a));
    int16x4_t lo = vget_low_s16(r), hi = vget_high_s16(r);
    int16x4_t q = vadd_s16(lo, vqrdmulh_s16(vsub_s16(hi, lo), vdup_n_s16(fx)));
    uint8x8_t n = vmovn_u16(vcombine_u16(vreinterpret_u16_s16(q), vdup_n_u16(0)));
    return vget_lane_u32(vreinterpret_u32_u8(n), 0);
#else
    uint32_t px[4] = { p00, p01, p10, p11 };
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
    return o;
#endif
}

/*
 * The bilinear blend of QuartzCore's samplers: rows with usubl/sqrdmulh/uaddw by
 * fy, then the columns by fx, the low byte of each lane kept (uzp1). On an
 * AArch64 host the same NEON instructions, so the result is the guest's.
 */
static inline uint32_t ca_bilerp_scalar(uint32_t p00, uint32_t p01, uint32_t p10, uint32_t p11,
                                 int16_t fy, int16_t fx)
{
#if 0
    uint8x8_t a = vcreate_u8((uint64_t)p00 | ((uint64_t)p01 << 32));
    uint8x8_t b = vcreate_u8((uint64_t)p10 | ((uint64_t)p11 << 32));
    int16x8_t d = vreinterpretq_s16_u16(vsubl_u8(b, a));
    d = vqrdmulhq_s16(d, vdupq_n_s16(fy));
    int16x8_t r = vreinterpretq_s16_u16(vaddw_u8(vreinterpretq_u16_s16(d), a));
    int16x4_t lo = vget_low_s16(r), hi = vget_high_s16(r);
    int16x4_t q = vadd_s16(lo, vqrdmulh_s16(vsub_s16(hi, lo), vdup_n_s16(fx)));
    uint8x8_t n = vmovn_u16(vcombine_u16(vreinterpret_u16_s16(q), vdup_n_u16(0)));
    return vget_lane_u32(vreinterpret_u32_u8(n), 0);
#else
    uint32_t px[4] = { p00, p01, p10, p11 };
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
    return o;
#endif
}


int main(void){
    uint64_t s=88172645463325252ull; unsigned long bad=0;
    for(long i=0;i<10000000;i++){
        uint32_t v[4];
        for(int k=0;k<4;k++){ s^=s<<13; s^=s>>7; s^=s<<17; v[k]=(uint32_t)s; }
        s^=s<<13; s^=s>>7; s^=s<<17;
        int16_t fy=(int16_t)(s & 0x7f80), fx=(int16_t)((s>>16)&0x7f80);
        if(i%7==0){ fy=(int16_t)s; fx=(int16_t)(s>>16); }
        if(ca_bilerp(v[0],v[1],v[2],v[3],fy,fx)!=ca_bilerp_scalar(v[0],v[1],v[2],v[3],fy,fx)) bad++;
    }
    printf("bilerp neon vs scalar: %lu mismatches of 10000000\n", bad);
    return bad!=0;
}
