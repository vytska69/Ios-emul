# vImage vAlpha_Blend_Premultiplied_BGRA_8888_CV_vec (18A373) in Unicorn against valpha_ref.c, the
# hypercall 11 code (patch 0076). Build the reference first: cc -O2 -shared -fPIC -o valpha_ref.so valpha_ref.c
import ctypes, os, random, struct, sys
from unicorn import *
from unicorn.arm64_const import *
lib = ctypes.CDLL(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'valpha_ref.so'))
code = bytearray(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'valpha_blend.bin'),'rb').read())
for i in range(0, len(code), 4):   # retab -> ret, pacibsp -> nop
    w = struct.unpack_from('<I', code, i)[0]
    if w == 0xD65F0FFF: struct.pack_into('<I', code, i, 0xD65F03C0)
    if w == 0xD503237F: struct.pack_into('<I', code, i, 0xD503201F)
BASE = 0x19baec000
def run(seed):
    r = random.Random(seed)
    w = r.choice([1, 2, 3, 7, 8, 9, 15, 16, 17, 31, 33, r.randint(1, 80)]); h = r.randint(1, 4)
    rb = [4 * w + 4 * r.randint(0, 3) for _ in range(3)]
    def img(k):
        px = []
        for _ in range(rb[k] // 4 * h):
            if r.random() < 0.3:   # premultiplied-looking
                a = r.randint(0, 255); px.append(a << 24 | r.randint(0, a) << 16 | r.randint(0, a) << 8 | r.randint(0, a))
            else: px.append(r.getrandbits(32))
        return px
    top, back = img(0), img(1); dst0 = [0xdeadbeef] * (rb[2] // 4 * h)
    mu = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    mu.mem_map(BASE, 0x2000); mu.mem_write(0x19baecff4, bytes(code))
    mu.mem_map(0x10000000, 1 << 20); mu.mem_map(0x7000000, 0x100000)
    A = [0x10000000, 0x10040000, 0x10080000]; S = 0x100c0000
    mu.mem_write(A[0], struct.pack(f'<{len(top)}I', *top)); mu.mem_write(A[1], struct.pack(f'<{len(back)}I', *back))
    mu.mem_write(A[2], struct.pack(f'<{len(dst0)}I', *dst0))
    for k in range(3): mu.mem_write(S + 32 * k, struct.pack('<4Q', A[k], h, w, rb[k]))
    mu.reg_write(UC_ARM64_REG_CPACR_EL1, 3 << 20); mu.reg_write(UC_ARM64_REG_SP, 0x7080000)
    for reg, v in zip([UC_ARM64_REG_X0, UC_ARM64_REG_X1, UC_ARM64_REG_X2, UC_ARM64_REG_X3], [S, S + 32, S + 64, 0]): mu.reg_write(reg, v)
    RET = 0x7000000; mu.reg_write(UC_ARM64_REG_X30, RET); mu.mem_write(RET, struct.pack('<I', 0xD503201F))
    mu.emu_start(0x19baecff4, RET)
    got = struct.unpack(f'<{len(dst0)}I', mu.mem_read(A[2], 4 * len(dst0)))
    bad = 0
    for y in range(h):
        T = (ctypes.c_uint32 * w)(*top[y * rb[0] // 4: y * rb[0] // 4 + w]); B = (ctypes.c_uint32 * w)(*back[y * rb[1] // 4: y * rb[1] // 4 + w])
        D = (ctypes.c_uint32 * w)(); lib.valpha_row(T, B, D, ctypes.c_size_t(w))
        for x in range(w):
            if got[y * rb[2] // 4 + x] != D[x]:
                if bad == 0: print('seed', seed, 'w', w, 'x', x, hex(top[y*rb[0]//4+x]), hex(back[y*rb[1]//4+x]), hex(got[y*rb[2]//4+x]), hex(D[x]))
                bad += 1
        pad = got[y * rb[2] // 4 + w: (y + 1) * rb[2] // 4]
        bad += sum(1 for p in pad if p != 0xdeadbeef)
    return bad, w * h
n = int(sys.argv[1]) if len(sys.argv) > 1 else 300
tot = bad = 0
for s in range(n):
    b, p = run(s); bad += b; tot += p
print(f'vAlpha_Blend: {bad} mismatches of {tot} pixels in {n} cases')
