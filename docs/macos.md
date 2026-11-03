# Mac versija

`App/Mac` – atskira macOS programa („iOS Emul.app“). Ji naudoja tą patį diegiklį (`EmulatorKit`)
kaip iPhone programa. QEMU yra programos viduje kaip pagalbinis procesas
(`Contents/MacOS/qemu-system-aarch64`), jo bibliotekos – `Contents/Frameworks`, duomenys –
`Contents/Resources/qemu` (programa perduoda `-L`). Surenka `.github/workflows/mac.yml`,
QEMU įdeda `scripts/bundle-qemu-macos.sh`. Rezultatas – `IOSEmul-mac.zip` Rolling leidime.

Mašinos laikomos `~/Library/Application Support/IOSEmul/Machines`.

## Varikliai

| Variklis | Būsena |
|---|---|
| Vertimas (TCG, JIT) | Veikia taip pat, kaip CI įkrovos testai (`ipsw-emu boot`) |
| Hypervisor.framework (`-accel hvf`) | Bandomasis; T8030 mašina dar neparuošta |

CI macOS mašinos pačios yra virtualios („Apple M1 (Virtual)“), jose Hypervisor.framework
nėra. HVF tikrinamas tik tikrame Mac'e.

## Kodėl HVF iOS 14 nėra paprastas

- **GXF (PPL).** iOS 14 branduolys A13 įeina į PPL per Apple instrukciją `genter` (0x00201420) ir
  išeina per `gexit` (0x00201400). Inferno ją emuliuoja TCG (`a13_gxf.c`, `EXCP_GENTER`).
  Hypervisor.framework svečiui GXF nesuteikia: `genter` svečio EL1 būtų neapibrėžta instrukcija,
  kurią gauna pats svečias, o ne QEMU. Planas: branduolyje `genter`/`gexit` pakeisti `hvc`
  instrukcijomis ir GXF perjungimą (GL1 registrai: VBAR, ELR, SPSR, TPIDR, SP) atlikti QEMU HVC
  apdorojime, naudojant tą pačią `env->gxf` būseną.
- **Apple sistemos registrai** (HID, IPI, APRR/SPRR, GXF_CONFIG). Su HCR_EL2.TIDCP jie
  perimami į QEMU; `hvf.c` jau turi atsarginį kelią per `cpregs` lentelę („fallback“), kurioje
  yra `a13.c` ir `a13_gxf.c` registrai. APRR/SPRR leidimų aparatūroje nėra: rašymai
  ignoruojami, PPL atminties apsauga neveiks, bet funkciškai branduolys turėtų veikti.
- **Laikmačiai ir IPI.** iOS laikmatį ir greitus IPI gauna kaip FIQ. QEMU HVF virtualų laikmatį
  jungia prie GIC; T8030 mašinoje jį reikės nukreipti į AIC/FIQ
  (`hv_vcpu_set_pending_interrupt(..., HV_INTERRUPT_TYPE_FIQ)`).
- **Procesoriaus ID registrai.** HVF rodo tikro Mac'o procesorių. Branduolys tikrina MIDR (A13 –
  Lightning/Thunder), todėl MIDR ir kiti ID registrai turi būti A13.

## Eiga

1. Mac programa su TCG (padaryta).
2. `-accel hvf` su T8030: mašina sukuriama, procesorius pradeda vykdyti branduolį (pirmas
   tikslas – pirmos eilutės `serial.log`).
3. GXF per `hvc`, Apple registrai, FIQ laikmatis.
4. Įkrova iki SpringBoard, tada greičio matavimai.
