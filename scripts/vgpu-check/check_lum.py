# QuartzCore scanline's luminance loop (0x183706fcc, 18A373) in Unicorn against lum_ref.c
# (hypercall 14). Build: cc -O2 -ffp-contract=off -shared -fPIC -o lum_ref.so lum_ref.c -lm
import ctypes, os, random, struct, sys
from unicorn import *
from unicorn.arm64_const import *
here = os.path.dirname(os.path.abspath(__file__))
lib = ctypes.CDLL(os.path.join(here, 'lum_ref.so'))
F4, F3 = ctypes.c_float * 4, ctypes.c_float * 3
lib.lum_loop.argtypes = [ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32), ctypes.c_uint32, ctypes.c_uint32, F4, F3]
code = open(os.path.join(here, 'lum_loop.bin'), 'rb').read()
START, END = 0x183706fcc, 0x183706fcc + len(code)
def f32(x): return struct.unpack('<f', struct.pack('<f', x))[0]
def run(seed):
    r = random.Random(seed); n = r.randint(1, 48)
    px = [r.getrandbits(32) for _ in range(n)]
    amount = r.randint(1, 256)
    w = [f32(r.choice([0.587 / 255, 0.299 / 255, 0.114 / 255, r.uniform(0, 0.01)])) for _ in range(3)]
    c = [f32(r.uniform(-3, 3)) for _ in range(4)]
    mu = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    mu.mem_map(START & ~0xfff, 0x2000); mu.mem_write(START, code)
    mu.mem_map(0x183876000, 0x1000); mu.mem_write(0x183876cf4, struct.pack('<3f', *w))
    mu.mem_map(0x10000000, 0x10000); mu.mem_write(0x10000000, struct.pack(f'<{n}I', *px))
    mu.reg_write(UC_ARM64_REG_CPACR_EL1, 3 << 20)
    mu.reg_write(UC_ARM64_REG_X13, 0x10000000); mu.reg_write(UC_ARM64_REG_X12, 0x10008000)
    mu.reg_write(UC_ARM64_REG_X10, n); mu.reg_write(UC_ARM64_REG_X11, amount)
    mu.reg_write(UC_ARM64_REG_X8, 0xff00ff00); mu.reg_write(UC_ARM64_REG_X9, 0x00ff00ff)
    for i, reg in enumerate([UC_ARM64_REG_S0, UC_ARM64_REG_S1, UC_ARM64_REG_S2, UC_ARM64_REG_S3]):
        mu.reg_write(reg, struct.unpack('<I', struct.pack('<f', c[i]))[0])
    mu.emu_start(START, END)
    got = struct.unpack(f'<{n}I', mu.mem_read(0x10008000, 4 * n))
    S = (ctypes.c_uint32 * n)(*px); D = (ctypes.c_uint32 * n)()
    lib.lum_loop(S, D, n, amount, F4(*c), F3(*w))
    bad = [i for i in range(n) if got[i] != D[i]]
    if bad: print('seed', seed, hex(px[bad[0]]), hex(got[bad[0]]), hex(D[bad[0]]), amount, c, w)
    return len(bad), n
tot = bad = 0
for s in range(int(sys.argv[1]) if len(sys.argv) > 1 else 300):
    b, n = run(s); bad += b; tot += n
print(f'luminance loop: {bad} mismatches of {tot} pixels')
