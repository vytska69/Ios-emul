# QuartzCore circle_sampler<false, false> (0x18370d938, 18A373) in Unicorn against circle_ref.c
# (hypercall 16). Build: cc -O2 -ffp-contract=off -shared -fPIC -o circle_ref.so circle_ref.c -lm
import ctypes, os, random, struct, sys
from unicorn import *
from unicorn.arm64_const import *
here = os.path.dirname(os.path.abspath(__file__))
lib = ctypes.CDLL(os.path.join(here, 'circle_ref.so'))
F2 = ctypes.c_float * 2
lib.circle00.argtypes = [F2, F2, F2, F2, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32)]
code = open(os.path.join(here, 'circle_sampler00.bin'), 'rb').read()
START = 0x18370d938
RET = START + len(code) - 4          # its ret
def f32(x): return struct.unpack('<f', struct.pack('<f', x))[0]
def run(seed):
    r = random.Random(seed); n = r.randint(1, 64); idx = r.randint(0, 3)
    def vec(scale):
        return [f32(r.choice([r.uniform(-scale, scale), 0.0, -0.0, r.uniform(-1e-3, 1e-3)])) for _ in range(2)]
    v0, v1 = vec(0.05), vec(0.05)
    v2, v3 = vec(1.5), vec(1.5)
    mu = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    mu.mem_map(START & ~0xfff, 0x2000); mu.mem_write(START, code)
    base = 0x10000000
    mu.mem_map(base, 0x20000)
    sd, t10, t18, t20, t28, out = base, base + 0x1000, base + 0x2000, base + 0x3000, base + 0x4000, base + 0x8000
    mu.mem_write(sd + 8, struct.pack('<I', idx))
    mu.mem_write(sd + 0x10, struct.pack('<4Q', t10, t18, t20, t28))
    off = idx * 8 + 0x20
    mu.mem_write(t18 + off, struct.pack('<2f', *v0))
    mu.mem_write(t28 + off, struct.pack('<2f', *v1))
    mu.mem_write(t20 + off, struct.pack('<2f', *v2))
    mu.mem_write(t10 + off, struct.pack('<2f', *v3))
    mu.reg_write(UC_ARM64_REG_CPACR_EL1, 3 << 20)
    mu.reg_write(UC_ARM64_REG_X0, sd); mu.reg_write(UC_ARM64_REG_X1, n); mu.reg_write(UC_ARM64_REG_X2, out)
    mu.emu_start(START, RET)
    got = struct.unpack(f'<{n}I', mu.mem_read(out, 4 * n))
    D = (ctypes.c_uint32 * n)()
    lib.circle00(F2(*v0), F2(*v1), F2(*v2), F2(*v3), n, D)
    bad = [i for i in range(n) if got[i] != D[i]]
    if bad: print('seed', seed, bad[0], hex(got[bad[0]]), hex(D[bad[0]]), v0, v1, v2, v3)
    return len(bad), n
tot = bad = 0
for s in range(int(sys.argv[1]) if len(sys.argv) > 1 else 3000):
    b, n = run(s); bad += b; tot += n
print(f'circle_sampler<0,0>: {bad} mismatches of {tot} pixels')
