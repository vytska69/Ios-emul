import sys, subprocess, struct
from unicorn import *
from unicorn.arm64_const import *
code = bytearray(open('image_sampler_argb8_18A373.bin','rb').read())
# retab -> ret (unicorn may lack PAC); pacibsp is a hint
for i in range(0, len(code), 4):
    w = struct.unpack_from('<I', code, i)[0]
    if w == 0xD65F0FFF: struct.pack_into('<I', code, i, 0xD65F03C0)
CODE = 0x183720c2c; PAGE = CODE & ~0xfff
def run(mode, seed):
    subprocess.run(['./samptest', str(mode), str(seed)], check=True)
    img = open('img.bin','rb').read(); kp = open('kpage.bin','rb').read()
    mu = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
    mu.ctl_set_cpu_model(UC_CPU_ARM64_MAX) if hasattr(mu,'ctl_set_cpu_model') else None
    mu.mem_map(PAGE, 0x2000); mu.mem_write(CODE, bytes(code))
    mu.mem_map(0x10000000, 4<<20); mu.mem_write(0x10000000, img)
    mu.mem_map(0x183876000, 0x1000); mu.mem_write(0x183876000, kp)
    mu.mem_map(0x7000000, 0x100000)
    # enable FP/SIMD: CPACR_EL1.FPEN
    mu.reg_write(UC_ARM64_REG_CPACR_EL1, 3 << 20)
    mu.reg_write(UC_ARM64_REG_SP, 0x7080000)
    mu.reg_write(UC_ARM64_REG_X0, 0x10000000); mu.reg_write(UC_ARM64_REG_X1, 200)
    mu.reg_write(UC_ARM64_REG_X2, 0x10200000); mu.reg_write(UC_ARM64_REG_X3, 0)
    RET = 0x7000000; mu.reg_write(UC_ARM64_REG_X30, RET)
    mu.mem_write(RET, struct.pack('<I', 0xD503201F))
    mu.emu_start(CODE, RET)
    o = mu.mem_read(0x10200000, 800); c = open('out_c.bin','rb').read()
    bad = sum(1 for i in range(200) if o[4*i:4*i+4] != c[4*i:4*i+4])
    return bad
tot = 0
for mode in (int(m) for m in sys.argv[1:]):
    for seed in range(1, 41):
        b = run(mode, seed)
        if b: print("mode", mode, "seed", seed, "mismatching pixels", b)
        tot += b
print("total mismatching pixels", tot)
