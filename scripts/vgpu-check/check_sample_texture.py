# QuartzCore sample_texture (0x183707e14, 18A373) in Unicorn up to its sampler call against
# st_ref.c (hypercall 15): the SamplerData, the sampler index and the output after it.
# Build: cc -O2 -ffp-contract=off -shared -fPIC -o st_ref.so st_ref.c -lm; python3 check_sample_texture.py 3000
import ctypes, os, random, struct, sys
from unicorn import *
from unicorn.arm64_const import *
here = os.path.dirname(os.path.abspath(__file__))
lib = ctypes.CDLL(os.path.join(here, 'st_ref.so'))
class StIn(ctypes.Structure):
    _fields_ = [('x1', ctypes.c_uint64), ('x4', ctypes.c_uint64), ('x5', ctypes.c_uint64), ('x6', ctypes.c_uint64), ('x7', ctypes.c_uint64),
                ('w2', ctypes.c_uint32), ('w3', ctypes.c_uint32), ('mode', ctypes.c_uint8), ('b40', ctypes.c_uint8), ('b41', ctypes.c_uint8),
                ('t18', ctypes.c_uint32), ('t1c', ctypes.c_uint32), ('t20', ctypes.c_int32), ('t24', ctypes.c_int32),
                ('x4_c', ctypes.c_float), ('a', ctypes.c_float * 2), ('b', ctypes.c_float * 2), ('c', ctypes.c_float * 2),
                ('k_d04', ctypes.c_float), ('count', ctypes.c_uint32), ('q', ctypes.c_uint8 * 16), ('have_p', ctypes.c_int),
                ('p4', ctypes.c_uint8), ('p0', ctypes.c_uint32), ('p8w', ctypes.c_uint32), ('p10', ctypes.c_uint32),
                ('p8', ctypes.c_float), ('pc', ctypes.c_float)]
class StOut(ctypes.Structure):
    _fields_ = [('frame', ctypes.c_uint8 * 0x70), ('written', ctypes.c_uint8 * 0x70), ('index', ctypes.c_uint32)]
code = bytearray(open(os.path.join(here, 'sample_texture.bin'), 'rb').read())
for i in range(0, len(code), 4):
    w = struct.unpack_from('<I', code, i)[0]
    if w == 0xD503237F: struct.pack_into('<I', code, i, 0xD503201F)   # pacibsp -> nop
    if w == 0xD65F0FFF: struct.pack_into('<I', code, i, 0xD65F03C0)   # retab -> ret
    if w == 0xD63F091F: struct.pack_into('<I', code, i, 0xD63F0100)   # blraaz x8 -> blr x8
START = 0x183707e14; STUB = 0x20000000; K = struct.unpack('<f', bytes.fromhex('a4707d3f'))[0]
def f32(x): return struct.unpack('<f', struct.pack('<f', x))[0]
def rf(r):
    c = r.random()
    if c < 0.1: return 0.0
    if c < 0.15: return -0.0
    if c < 0.5: return f32(r.uniform(-4, 4))
    if c < 0.8: return f32(r.uniform(-300, 300))
    return f32(r.uniform(-20000, 20000))
def run(seed):
    r = random.Random(seed)
    w2 = r.randint(0, 3); count = r.randint(1, 300)
    mode = r.choice([0, 0, 0, 0, 1, 3, 5]); w3 = r.getrandbits(4) & ~1
    b40 = r.choice([0, 1, 8, 9, r.getrandbits(8)]); b41 = r.choice([b40, b40, 0, 1, 8, 9])
    t18 = r.choice([1, 2, 16, 64, r.randint(1, 4096)]); t1c = r.choice([1, 2, 16, 64, r.randint(1, 4096)])
    t20 = r.choice([(t18 - 1) << 16, r.randint(0, 1 << 28), r.randint(-5, 5)]); t24 = r.choice([(t1c - 1) << 16, r.randint(0, 1 << 28)])
    x4c = r.choice([1.0, f32(r.uniform(0.01, 4)), 0.0, -2.0])
    A = [rf(r) for _ in range(2)]; B = [rf(r) for _ in range(2)]; C = [rf(r) for _ in range(2)]
    have_p = r.random() < 0.4; p0 = r.randint(0, 5); p4 = r.choice([0, 1]); p8 = rf(r); pc = rf(r); p10 = r.getrandbits(32)
    fmt = r.choice([0xf, 0xf, 0, 3]); q = bytes(r.getrandbits(8) for _ in range(16))
    mu = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    mu.mem_map(START & ~0xfff, 0x2000); mu.mem_write(START, bytes(code))
    mu.mem_map(0x183876000, 0x1000); mu.mem_write(0x183876d04, struct.pack('<f', K))
    mu.mem_map(0x1d02d1000, 0x1000); mu.mem_write(0x1d02d1b78, struct.pack('<Q', 0x1d02d1f00)); mu.mem_write(0x1d02d1f00, struct.pack('<Q', 0x5a5a))
    mu.mem_map(0x10000000, 0x100000)
    T = 0x10000000; TAB = 0x10001000; CTX = 0x10002000; C2 = 0x10003000; P = 0x10004000; V = [0x10005000, 0x10006000, 0x10007000]; OUT = 0x10010000
    tex = bytearray(0x48)
    struct.pack_into('<IIii', tex, 0x18, t18, t1c, t20, t24); struct.pack_into('<Q', tex, 0x30, TAB); tex[0x40] = b40; tex[0x41] = b41
    mu.mem_write(T, bytes(tex)); mu.mem_write(TAB, struct.pack('<256Q', *[STUB + 16 * i for i in range(256)]))
    mu.mem_write(CTX + 8, struct.pack('<Q', C2))
    c2 = bytearray(0x200); struct.pack_into('<Q', c2, 0x1d0, P if have_p else 0); c2[0x1d8:0x1e8] = q; c2[0x11 + w2] = fmt
    mu.mem_write(C2, bytes(c2))
    pb = bytearray(0x20); struct.pack_into('<I', pb, 0, p0); pb[4] = p4; struct.pack_into('<ff', pb, 8, p8, pc); struct.pack_into('<I', pb, 0x10, p10)
    mu.mem_write(P, bytes(pb))
    for base, vals in zip(V, (A, B, C)):
        buf = bytearray(0x60); struct.pack_into('<ff', buf, 0x20 + 8 * w2, *vals); mu.mem_write(base, bytes(buf))
    mu.mem_write(V[0] + 0xc, struct.pack('<f', x4c))
    mu.mem_map(STUB, 0x1000); mu.mem_write(STUB, struct.pack('<I', 0xD65F03C0) * 0x400)
    SP = 0x10080000; mu.mem_write(SP, struct.pack('<BxxxIQ', mode, count, OUT))
    mu.mem_write(SP - 0xa0, b'\xee' * 0xa0)
    seen = {}
    def hook(uc, address, size, ud):
        if STUB <= address < STUB + 0x1000 and 'idx' not in seen:
            seen['idx'] = (address - STUB) // 16
            seen['frame'] = bytes(uc.mem_read(uc.reg_read(UC_ARM64_REG_X0), 0x70))
            seen['args'] = (uc.reg_read(UC_ARM64_REG_X0), uc.reg_read(UC_ARM64_REG_X1), uc.reg_read(UC_ARM64_REG_X2))
            pat = [(seed * 2654435761 + i * 40503) & 0xffffffff for i in range(count)]
            seen['pat'] = pat; uc.mem_write(OUT, struct.pack(f'<{count}I', *pat))
    mu.hook_add(UC_HOOK_CODE, hook, begin=STUB, end=STUB + 0x1000)
    mu.reg_write(UC_ARM64_REG_CPACR_EL1, 3 << 20); mu.reg_write(UC_ARM64_REG_SP, SP)
    regs = [CTX, T, w2, w3, V[0], V[1], V[2], 0x77]
    for i, v in enumerate(regs): mu.reg_write(UC_ARM64_REG_X0 + i, v)
    RET = 0x7000000; mu.mem_map(RET, 0x1000); mu.reg_write(UC_ARM64_REG_X30, RET)
    try:
        mu.emu_start(START, RET)
    except UcError as e:
        print('fault pc', hex(mu.reg_read(UC_ARM64_REG_PC)), 'lr', hex(mu.reg_read(UC_ARM64_REG_X30)), e); raise
    out = struct.unpack(f'<{count}I', mu.mem_read(OUT, 4 * count))
    si = StIn(x1=T, x4=V[0], x5=V[1], x6=V[2], x7=0x77, w2=w2, w3=w3, mode=mode, b40=b40, b41=b41, t18=t18, t1c=t1c, t20=t20, t24=t24,
              x4_c=x4c, k_d04=K, count=count, have_p=int(have_p), p4=p4, p0=p0, p8w=struct.unpack('<I', struct.pack('<f', p8))[0], p10=p10, p8=p8, pc=pc)
    si.a[:] = A; si.b[:] = B; si.c[:] = C; si.q[:] = list(q)
    so = StOut(); lib.st_setup(ctypes.byref(si), ctypes.byref(so))
    errs = []
    if so.index != seen['idx']: errs.append(f'index {so.index} vs {seen["idx"]}')
    if seen['args'] != (SP - 0xa0, count, OUT): errs.append(f'args {seen["args"]}')
    fr = seen['frame']
    for off in range(0x70):
        if so.written[off] and so.frame[off] != fr[off]: errs.append(f'frame +{off:#x}'); break
    for off in range(0x34, 0x64):   # what the code leaves alone must stay as it was
        if not so.written[off] and off not in range(0x44, 0x54) and fr[off] != 0xee: errs.append(f'unexpected write +{off:#x}'); break
    exp = (ctypes.c_uint32 * count)(*seen['pat']); lib.st_post(exp, count, fmt)
    if list(exp) != list(out): errs.append('post')
    if errs and seed < 100000: print('seed', seed, errs[:3], 'w3', w3, 'mode', mode, 'b40/41', b40, b41, 'A,B,C', A, B, C)
    return len(errs) > 0
n = int(sys.argv[1]) if len(sys.argv) > 1 else 500
bad = sum(run(s) for s in range(n))
print(f'sample_texture setup: {bad} mismatching cases of {n}')
