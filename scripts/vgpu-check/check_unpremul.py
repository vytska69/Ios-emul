# QuartzCore scanline's un-premultiplying loop (0x18370621c, 18A373) in Unicorn against
# unpremul_ref.c (hypercall 13). Build: cc -O2 -ffp-contract=off -shared -fPIC -o unpremul_ref.so unpremul_ref.c
import ctypes, os, random, struct, sys
from unicorn import *
from unicorn.arm64_const import *
here = os.path.dirname(os.path.abspath(__file__))
lib = ctypes.CDLL(os.path.join(here, 'unpremul_ref.so'))
lib.unpremul_loop.argtypes = [ctypes.POINTER(ctypes.c_uint32), ctypes.c_uint32, ctypes.c_float, ctypes.c_float]
code = open(os.path.join(here, 'unpremul_loop.bin'), 'rb').read()
START, END = 0x18370621c, 0x18370621c + len(code)
def f32(x): return struct.unpack('<f', struct.pack('<f', x))[0]
def run(seed, k, eps):
    r = random.Random(seed); n = r.randint(1, 64)
    px = []
    for _ in range(n):
        c = r.random()
        if c < 0.3: a = r.randint(0, 255); px.append(a << 24 | r.randint(0, a) << 16 | r.randint(0, a) << 8 | r.randint(0, a))
        elif c < 0.4: px.append(r.randint(0, 3) << 24 | r.getrandbits(24))
        else: px.append(r.getrandbits(32))
    mu = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    mu.mem_map(START & ~0xfff, 0x2000); mu.mem_write(START, code)
    mu.mem_map(0x183876000, 0x1000)
    mu.mem_write(0x183876c24, struct.pack('<f', k)); mu.mem_write(0x183876c34, struct.pack('<f', eps))
    mu.mem_map(0x10000000, 0x10000); mu.mem_write(0x10000000, struct.pack(f'<{n}I', *px))
    mu.reg_write(UC_ARM64_REG_CPACR_EL1, 3 << 20)
    mu.reg_write(UC_ARM64_REG_X9, 0x10000000); mu.reg_write(UC_ARM64_REG_X11, n)
    mu.reg_write(UC_ARM64_REG_X8, 0x183876000); mu.reg_write(UC_ARM64_REG_X10, 0x183876000)
    mu.emu_start(START, END)
    got = struct.unpack(f'<{n}I', mu.mem_read(0x10000000, 4 * n))
    buf = (ctypes.c_uint32 * n)(*px); lib.unpremul_loop(buf, n, k, eps)
    bad = [i for i in range(n) if got[i] != buf[i]]
    if bad: print('seed', seed, hex(px[bad[0]]), hex(got[bad[0]]), hex(buf[bad[0]]), k, eps)
    return len(bad), n
tot = bad = 0
for s in range(int(sys.argv[1]) if len(sys.argv) > 1 else 300):
    for k, eps in ((f32(1 / 255), f32(1e-6)), (f32(1 / 255), 0.0), (1.0, f32(0.5)), (f32(0.0039215689), f32(1e-3))):
        b, n = run(s, k, eps); bad += b; tot += n
print(f'unpremultiply loop: {bad} mismatches of {tot} pixels')
