# QuartzCore circle_sampler<false, true> (0x18370d624, 18A373) in Unicorn against squircle_ref.c.
# Its powf calls (through the stub at 0x181c544a0) are answered with the host's powf, the one the
# reference and QEMU use. Build: cc -O2 -ffp-contract=off -shared -fPIC -o squircle_ref.so squircle_ref.c -lm
import ctypes, ctypes.util, os, random, struct, sys
from unicorn import *
from unicorn.arm64_const import *
here = os.path.dirname(os.path.abspath(__file__))
lib = ctypes.CDLL(os.path.join(here, 'squircle_ref.so'))
libm = ctypes.CDLL(ctypes.util.find_library('m'))
libm.powf.argtypes = [ctypes.c_float, ctypes.c_float]; libm.powf.restype = ctypes.c_float
F2, F5 = ctypes.c_float * 2, ctypes.c_float * 5
lib.squircle.argtypes = [F2, F2, F2, F2, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32), F5, ctypes.c_float, ctypes.c_float]
code = open(os.path.join(here, 'circle_sampler01.bin'), 'rb').read()
START = 0x18370d624
RET = START + len(code) - 4
POWF = 0x181c544a0
K = [0x3f9978d5, 0x402b851f, 0x3ebf0b76, 0x3f1978d5, 0x4354ad5f]
def bits2f(b): return struct.unpack('<f', struct.pack('<I', b))[0]
def f32(x): return struct.unpack('<f', struct.pack('<f', x))[0]
def run(seed):
    r = random.Random(seed); n = r.randint(1, 64); idx = r.randint(0, 3)
    def vec(scale):
        return [f32(r.choice([r.uniform(-scale, scale), 0.0, -0.0, r.uniform(-1e-3, 1e-3)])) for _ in range(2)]
    v0, v1 = vec(0.05), vec(0.05)
    v2, v3 = vec(1.5), vec(1.5)
    mu = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    mu.mem_map(START & ~0xfff, 0x2000); mu.mem_write(START, code)
    mu.mem_map(0x183876000, 0x1000); mu.mem_write(0x183876d40, struct.pack('<5I', *K))
    mu.mem_map(POWF & ~0xfff, 0x1000); mu.mem_write(POWF, b'\xc0\x03\x5f\xd6')
    base = 0x10000000
    mu.mem_map(base, 0x20000)
    mu.mem_map(0x20000000, 0x10000)   # stack
    sd, t10, t18, t20, t28, out = base, base + 0x1000, base + 0x2000, base + 0x3000, base + 0x4000, base + 0x8000
    mu.mem_write(sd + 8, struct.pack('<I', idx))
    mu.mem_write(sd + 0x10, struct.pack('<4Q', t10, t18, t20, t28))
    off = idx * 8 + 0x20
    mu.mem_write(t18 + off, struct.pack('<2f', *v0)); mu.mem_write(t28 + off, struct.pack('<2f', *v1))
    mu.mem_write(t20 + off, struct.pack('<2f', *v2)); mu.mem_write(t10 + off, struct.pack('<2f', *v3))
    def hook(uc, addr, size, user):
        a = struct.unpack('<f', struct.pack('<I', uc.reg_read(UC_ARM64_REG_S0)))[0]
        b = struct.unpack('<f', struct.pack('<I', uc.reg_read(UC_ARM64_REG_S1)))[0]
        res = libm.powf(a, b)
        uc.reg_write(UC_ARM64_REG_S0, struct.unpack('<I', struct.pack('<f', res))[0])
    mu.hook_add(UC_HOOK_CODE, hook, begin=POWF, end=POWF)
    mu.reg_write(UC_ARM64_REG_CPACR_EL1, 3 << 20)
    mu.reg_write(UC_ARM64_REG_SP, 0x20008000)
    mu.reg_write(UC_ARM64_REG_X0, sd); mu.reg_write(UC_ARM64_REG_X1, n); mu.reg_write(UC_ARM64_REG_X2, out)
    mu.emu_start(START + 4, RET)        # past pacibsp
    got = struct.unpack(f'<{n}I', mu.mem_read(out, 4 * n))
    D = (ctypes.c_uint32 * n)()
    lib.squircle(F2(*v0), F2(*v1), F2(*v2), F2(*v3), n, D, F5(*[bits2f(k) for k in K]),
                 bits2f(0x3f9978d5), bits2f(0xbe4bc6a8))
    bad = [i for i in range(n) if got[i] != D[i]]
    if bad: print('seed', seed, bad[0], hex(got[bad[0]]), hex(D[bad[0]]), v0, v1, v2, v3)
    return len(bad), n
tot = bad = 0
for s in range(int(sys.argv[1]) if len(sys.argv) > 1 else 3000):
    b, n = run(s); bad += b; tot += n
print(f'circle_sampler<0,1>: {bad} mismatches of {tot} pixels')
