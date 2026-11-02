import subprocess, struct
from unicorn import *
from unicorn.arm64_const import *
F = {0: [('argb8_nearest.bin', 0x183721590)], 1: [('texmul.bin', 0x183708a8c)],
     2: [('darken_blend.bin', 0x18370c264), ('darken_f.bin', 0x1837097e0)]}
def run(which, seed):
    subprocess.run(['./t3', str(which), str(seed)], check=True)
    regs = struct.unpack('<4Q', open('regs.bin','rb').read())
    mu = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    mapped = set()
    for name, addr in F[which]:
        for pg in range(addr & ~0xfff, (addr + 0x1000) & ~0xfff | 0xfff, 0x1000):
            if pg not in mapped: mu.mem_map(pg, 0x1000); mapped.add(pg)
        code = bytearray(open(name,'rb').read())
        for i in range(0, len(code), 4):
            if struct.unpack_from('<I', code, i)[0] == 0xD65F0FFF: struct.pack_into('<I', code, i, 0xD65F03C0)
        mu.mem_write(addr, bytes(code))
    mu.mem_map(0x10000000, 4<<20); mu.mem_write(0x10000000, open('img.bin','rb').read())
    mu.mem_map(0x1d02d1000, 0x1000); mu.mem_write(0x1d02d1b78, struct.pack('<Q', 0x1d02d1f00)); mu.mem_write(0x1d02d1f00, struct.pack('<Q', 0x1234))
    mu.mem_map(0x7000000, 0x100000)
    mu.reg_write(UC_ARM64_REG_CPACR_EL1, 3 << 20); mu.reg_write(UC_ARM64_REG_SP, 0x7080000)
    for r, v in zip([UC_ARM64_REG_X0, UC_ARM64_REG_X1, UC_ARM64_REG_X2, UC_ARM64_REG_X3], regs): mu.reg_write(r, v)
    RET = 0x7000000; mu.reg_write(UC_ARM64_REG_X30, RET); mu.mem_write(RET, struct.pack('<I', 0xD503201F))
    mu.emu_start(F[which][0][1], RET)
    n = 100 if which == 0 else 200
    o = mu.mem_read(0x10200000, 4*n); c = open('out_c.bin','rb').read()
    bad = [i for i in range(n) if o[4*i:4*i+4] != c[4*i:4*i+4]]
    if bad: print(which, seed, len(bad), o[4*bad[0]:4*bad[0]+4].hex(), c[4*bad[0]:4*bad[0]+4].hex())
    return len(bad)
for w in (0, 1, 2):
    print(F[w][0][0], 'mismatching', sum(run(w, s) for s in range(1, 51)))
