import sys, subprocess, struct
from unicorn import *
from unicorn.arm64_const import *
F = {0: ('xrgb8_affine.bin', 0x1837200e4), 1: ('argb8_affine.bin', 0x1837211ac), 2: ('colormatrix.bin', 0x183708fd8)}
def run(which, seed):
    subprocess.run(['./t2', str(which), str(seed)], check=True)
    name, addr = F[which]
    code = open(name, 'rb').read()
    img = open('img.bin','rb').read(); kp = open('kpage.bin','rb').read()
    mu = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    page = addr & ~0xfff
    mu.mem_map(page, 0x3000); mu.mem_write(addr, code)
    mu.mem_map(0x10000000, 4<<20); mu.mem_write(0x10000000, img)
    mu.mem_map(0x183876000, 0x1000); mu.mem_write(0x183876000, kp)
    mu.mem_map(0x7000000, 0x100000)
    mu.reg_write(UC_ARM64_REG_CPACR_EL1, 3 << 20); mu.reg_write(UC_ARM64_REG_SP, 0x7080000)
    if which < 2:
        regs = [0x10000000, 100, 0x10200000, 0]
    else:
        regs = [0x10200000, 0x10300000, 200, 0x10002000]
    for r, v in zip([UC_ARM64_REG_X0, UC_ARM64_REG_X1, UC_ARM64_REG_X2, UC_ARM64_REG_X3], regs): mu.reg_write(r, v)
    RET = 0x7000000; mu.reg_write(UC_ARM64_REG_X30, RET); mu.mem_write(RET, struct.pack('<I', 0xD503201F))
    mu.emu_start(addr, RET)
    n = 100 if which < 2 else 200
    o = mu.mem_read(0x10200000, 4*n); c = open('out_c.bin','rb').read()
    bad = [i for i in range(n) if o[4*i:4*i+4] != c[4*i:4*i+4]]
    if bad: print(which, seed, len(bad), 'first', bad[0], o[4*bad[0]:4*bad[0]+4].hex(), c[4*bad[0]:4*bad[0]+4].hex())
    return len(bad)
for w in (0, 1, 2):
    tot = sum(run(w, s) for s in range(1, 51))
    print('function', F[w][0], 'mismatching pixels', tot)
