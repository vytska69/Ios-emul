# iOS Emul

iPhone/iPad programa, kuri importuoja `.ipsw` failą ir paleidžia jo iOS emuliuojamoje Apple
mašinoje (QEMU) tiesiai telefone. Svečio ekranas rodomas programoje per VNC, su lietimo įvestimi.
Tikslas yra, kad kompiuterio nereikėtų nei programai įdiegti, nei iOS įdiegti į virtualų įrenginį.

## Būsena (2026-10)

| Dalis | Būsena |
|---|---|
| IPSW analizė (ZIP64, BuildManifest, IMG4, LZFSE/LZSS, DeviceTree, UDIF) | Veikia, padengta testais |
| Suderinamumo ir hardware padengimo ataskaita | Veikia programoje ir `ipsw-emu inspect` |
| iOS 14.0 iPhone 11 (`inferno-t8030`), restore režimas | Bootina iki launchd (macOS CI) |
| iOS 14.0 iPhone 11, tiesioginis įdiegimas be restore | Bootina iki launchd, stringa `mount-phase-1` dėl trūkstamo Preboot tomo. Taisoma: žr. „Be kompiuterio“ |
| SpringBoard / naudojamas iOS | Dar nepasiekta |
| QEMU sukompiliuotas iOS'ui (framework programoje) | Dar nepavyko: kompiliavimo klaidos taisomos po vieną (`qemu/patches/inferno/`) |
| Rolling release su IPA ir SideStore šaltiniu | Workflow paruoštas; pirmas release dar nepublikuotas |
| A14+, M serija, 32 bitų įrenginiai | Neemuliuojama, žr. [ROADMAP.md](ROADMAP.md) |

Boot testai kol kas vyksta macOS CI su `ipsw-emu`, ne telefone. Telefone emuliacija veiks tik tada,
kai QEMU susikompiliuos iOS'ui.

## Įdiegimas

Kiekvienas IPA build'as atnaujina [rolling release](https://github.com/vytska69/Ios-emul/releases/tag/rolling):

- **SideStore / AltStore:** pridėk šaltinį
  `https://github.com/vytska69/Ios-emul/releases/download/rolling/sidestore.json`.
- **TrollStore:** atidaryk
  `https://github.com/vytska69/Ios-emul/releases/download/rolling/IOSEmul.ipa`.

Kol QEMU iOS'ui nesikompiliuoja, release'e esanti programa neturi emuliatoriaus branduolio: ji
atsidaro ir analizuoja IPSW, bet paleisti negali. Release aprašymas ir SideStore įrašas tai nurodo.
Kai branduolys susikompiliuos, kitas build'as šią versiją pakeis.

## Ką palaiko

Universalaus „bet kurio IPSW“ emuliatoriaus nėra: kiekvienam Apple SoC reikia atskirai emuliuoti
pertraukimų valdiklį, laikmačius, PMGR, SEP, NVMe ir ekrano grandinę. Todėl programa veikia per
backend'us, o kiekvienas IPSW gauna ataskaitą su priežastimi, kodėl jis paleidžiamas ar ne.

| Backend | Įrenginiai | iOS | Šaltinis |
|---|---|---|---|
| `inferno-t8030` | iPhone 11 (A13); 11 Pro / Pro Max / SE 2 eksperimentiškai | 14 išbandyta; 13, 15–18, 26 eksperimentinės | [QEMUAppleSilicon](https://github.com/ChefKissInc/QEMUAppleSilicon), modifikuotas |
| `inferno-s8000` | iPhone 6s / 6s Plus (A9) | 9–15 eksperimentinės | QEMUAppleSilicon, modifikuotas |
| `qemu-ios` | iPod touch 1G / 2G | iPhoneOS 1.x–2.x | [devos50/qemu-ios](https://github.com/devos50/qemu-ios) |

Kiti IPSW importuojami ir išanalizuojami, bet pažymimi „Unsupported“. Naują SoC galima bandyti su
`ipsw-emu boot --force-backend inferno-t8030` ir taisyti tai, kas sustoja pirmiausia.

## Be kompiuterio

Numatytas režimas „Install directly“ daro tai, ką paprastai atlieka restore iš kompiuterio:

1. IPSW `OS` komponentas yra UDIF (`.dmg`) atvaizdas. Jis skaitomas tiesiai iš IPSW ir išskleidžiamas
   į virtualų NVMe diską.
2. Atvaizdo GPT skirtas 512 baitų sektoriams, o iPhone NVMe naudoja 4096 baitų blokus, todėl
   rašomas naujas GPT. APFS konteineris tampa `disk0s1`, System tomas – `disk0s1s1`.
3. iOS ieško tomų pagal rolę ir be Preboot tomo nepraeina `mount-phase-1`. Į konteinerį tiesiogiai
   įrašomas naujas Preboot tomas su firmware katalogu (`Sources/IPSWKit/APFS.swift`). CI tikrina jį
   Apple'o `fsck_apfs` ir prijungia per macOS.
4. DeviceTree `fstab` pakeičiamas: nesukurti tomai išmetami, o Data tomas pakeičiamas efemeriniu,
   kurį iOS sukuria paleidimo metu.

Restore per ramdisk lieka kaip alternatyva, bet jam kol kas reikia `idevicerestore` iš kompiuterio
per Inferno USB-over-TCP.

## Struktūra

```
Sources/IPSWKit/       IPSW: ZIP64, BuildManifest/Restore.plist, IMG4/IM4P, LZFSE/LZSS,
                       DeviceTree (skaitymas ir rašymas), UDIF, GPT, APFS tomo rašymas
Sources/EmulatorKit/   Backend'ai, suderinamumas, hardware padengimas, QEMU paleidimas, VNC
Sources/ipsw-emu/      CLI: inspect / boot / dt / apfs-add-volume
App/IOSEmul/           SwiftUI programa
qemu/patches/inferno/  Patch'ai Inferno QEMU: shared lib + libucontext, SEP be duomenų šifravimo,
                       debranding, iOS JIT (APRR), iOS antraštės
scripts/               build-qemu-ios.sh, make-sidestore-source.py, dt-survey.py
research/devicetrees/  13 SoC DeviceTree inventoriai
.github/workflows/     ci (testai, APFS patikra, simulator build), ipa (QEMU iOS + IPA + release),
                       boot-test (tikri IPSW), dt-survey
```

## Matavimas

- `Boot test` workflow parsisiunčia tikrus IPSW, bootina juos per `ipsw-emu` ir suvestinėje parodo
  toliausią etapą (XNU → IOKit → root → launchd → SpringBoard) bei panic'o eilutę.
- `DeviceTree survey` per HTTP range nuskaito tik DeviceTree iš naujausio kiekvieno SoC IPSW.
- `ipsw-emu inspect <ipsw>` parodo suderinamumą ir hardware padengimą.

## Kompiliavimas

Reikia macOS su Xcode 16.

```sh
swift test
brew install xcodegen
scripts/build-qemu-ios.sh        # QEMU → App/Frameworks (ilgai trunka)
xcodegen generate
open IOSEmul.xcodeproj
```

`scripts/build-qemu-ios.sh --tci` sukompiliuoja TCG interpretatorių vietoj JIT: veikia be JIT
leidimo, bet kelis kartus lėčiau.

## Apribojimai

- **JIT.** Greitam QEMU reikia JIT leidimo (TrollStore, SideStore su JIT įjungikliu arba debugger).
  Be jo naudokite `--tci` build'ą.
- **Vienas VM per paleidimą.** QEMU laiko globalią būseną, o iOS neleidžia kurti procesų, todėl po
  VM sustabdymo programą reikia paleisti iš naujo.
- **Failai, kurių nėra IPSW.** SEP ROM, iPod boot ROM ir AP ticket'as gaunami iš savo įrenginio;
  programa leidžia juos pasirinkti ir paaiškina, kam jie reikalingi.
- **iOS 16+** Preboot tome dar reikia sistemos cryptex failų. Tomo rašytuvas kol kas kuria tik
  katalogus, todėl šios versijos tiesioginiu būdu dar nebootins.
- Naudokite tik teisėtai turimą programinę įrangą ir laikykitės Apple licencijos sąlygų.
- Apple mašinų modeliai paimti iš QEMUAppleSilicon (GPLv3/AGPLv3) ir modifikuoti patch'ais iš
  `qemu/patches/inferno/`. Tai išvestinis build'as: pagal upstream branding sąlygas jame nėra jų
  paveikslėlio ir „ChefKiss Inferno“ pavadinimo, o šis projektas nėra su ChefKiss susijęs ar jų remiamas.
