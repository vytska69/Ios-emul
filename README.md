# iOS Emul

**Tikslas: universalus iOS emuliatorius.** Bet kurį iPhone, iPad ar iPod touch `.ipsw` failą
atsidarai telefone ir naudoji jo operacinę sistemą emuliuojamame Apple įrenginyje. Nuo iPhoneOS 1
iki naujausios iOS, nuo A4 iki naujausių lustų. Be kompiuterio: nei programai įdiegti, nei iOS
įdiegti į virtualų įrenginį.

Viešai to dar niekas nedaro. Šis projektas eina ten etapais, ir kiekvienas etapas turi išmatuojamą
rezultatą: kiek toli bootina tikras IPSW.

> **Dabar:** iOS 14.0 ant emuliuojamo iPhone 11 bootina iki launchd (macOS CI). Telefone
> emuliacija dar neveikia, nes QEMU dar nesikompiliuoja iOS'ui. Žr. [Būsena](#būsena).

## Kaip pasiekti universalumą

Kiekvienas Apple lustas turi savo periferiją (pertraukimų valdiklis, laikmačiai, PMGR, DART, NVMe,
SEP, ekranas, lietimas), ir jos dokumentacijos nėra. Todėl emuliatorius kuriamas ne po vieną
įrenginį rankomis, o taip:

1. **IPSW pats aprašo savo hardware.** Kiekviename IPSW yra DeviceTree su visais įrenginiais, jų
   `compatible` vardais, MMIO adresais ir pertraukimais. Programa jį perskaito ir parodo, kuri
   hardware dalis jau emuliuojama ir kurios trūksta.
2. **Viena mašina, kuri susirenka pati.** Vietoj atskiros mašinos kiekvienam įrenginiui kuriama
   bendra mašina, kuri pasistato iš IPSW DeviceTree: žinomiems blokams prijungia modelius,
   nežinomiems – stub'us. Kiekvienas naujas modelis (pvz., AIC2 ar naujas DART) iškart padeda visiems
   lustams, kurie jį naudoja.
3. **Įdiegimas be restore.** iOS į virtualų diską įrašoma tiesiai iš IPSW: išskleidžiamas UDIF
   atvaizdas, parašomas GPT 4 KiB blokams, į APFS konteinerį įrašomi tomai, kuriuos paprastai sukuria
   restore. Todėl `idevicerestore` ir kompiuterio nereikia.
4. **Matavimas, ne spėjimas.** `Boot test` workflow bootina tikrus IPSW ir užrašo toliausią etapą
   (XNU → IOKit → root → launchd → SpringBoard) bei panic'ą. Taisoma tai, kas sustoja pirmiausia.
5. **Viešos žinios.** Inferno (A9/A13), Asahi Linux (M1/M2: AIC2, DART, PMGR, DCP, SPMI) ir devos50
   (S5L89xx) jau ištyrė didelę dalį hardware; jų darbas naudojamas kaip pagrindas.

Visas planas su etapais: [ROADMAP.md](ROADMAP.md).

## Kelias iki tikslo

| # | Etapas | Būsena |
|---|---|---|
| 0 | Programa telefone be kompiuterio (IPA per GitHub Actions, SideStore/TrollStore) | Workflow paruoštas; QEMU iOS build'as dar taisomas |
| 1 | DeviceTree parseris ir hardware padengimo ataskaita | Atlikta |
| 1b | Įdiegimas be restore (UDIF, GPT, APFS tomai, fstab) | Vyksta: System ir Preboot tomai rašomi, `fsck_apfs` švarus |
| 2 | Bendra DeviceTree valdoma mašina | Planuojama |
| 3 | A14 (T8101) ir M1 (T8103) | Planuojama |
| 4 | Restore programoje (USB-over-TCP) | Planuojama |
| 5 | A15–A18, M2, M4 | Planuojama |
| 6 | 32 bitų era (A4–A6, iOS 4–10) | Planuojama |
| 7 | Greitis (JIT, TCG optimizacijos) | Planuojama |

## Būsena

| Dalis | Būsena |
|---|---|
| IPSW analizė (ZIP64, BuildManifest, IMG4, LZFSE/LZSS, DeviceTree, UDIF) | Veikia, padengta testais |
| Suderinamumo ir hardware padengimo ataskaita | Veikia programoje ir `ipsw-emu inspect` |
| iOS 14.0, iPhone 11, restore režimas | Bootina iki launchd |
| iOS 14.0, iPhone 11, tiesioginis įdiegimas | Bootino iki launchd ir stojo `mount-phase-1`, nes nebuvo Preboot tomo; Preboot rašytuvas ką tik praėjo `fsck_apfs`, boot testas su juo vyksta |
| SpringBoard | Dar nepasiekta |
| QEMU iOS'ui | Dar nesikompiliuoja; klaidos taisomos po vieną (`qemu/patches/inferno/`) |
| Rolling release | Paruoštas, pirmas dar nepublikuotas |

Šiuo metu emuliuojamos mašinos:

| Backend | Įrenginiai | iOS |
|---|---|---|
| `inferno-t8030` | iPhone 11 (A13); 11 Pro / Pro Max / SE 2 eksperimentiškai | 14 išbandyta; 13, 15–18, 26 eksperimentinės |
| `inferno-s8000` | iPhone 6s / 6s Plus (A9) | 9–15 eksperimentinės |
| `qemu-ios` | iPod touch 1G / 2G | iPhoneOS 1.x–2.x |

Kiti IPSW importuojami ir išanalizuojami: programa parodo, kokio hardware trūksta. Naujo lusto
paleidimas pradedamas nuo `ipsw-emu boot --force-backend inferno-t8030`.

## Įdiegimas

Kiekvienas IPA build'as atnaujina [rolling release](https://github.com/vytska69/Ios-emul/releases/tag/Rolling):

- **SideStore / AltStore Classic:** pridėk šaltinį
  `https://github.com/vytska69/Ios-emul/releases/download/Rolling/sidestore.json`.
  **AltStore PAL** (ES versija) šio šaltinio nepriims: ji diegia tik Apple notarizuotas programas
  su `marketplaceID`, o šis build'as nėra notarizuotas.
- **TrollStore:** atidaryk
  `https://github.com/vytska69/Ios-emul/releases/download/Rolling/IOSEmul.ipa`.

Kol QEMU iOS'ui nesikompiliuoja, programa neturi emuliatoriaus branduolio: IPSW analizuoja, bet
paleisti negali. Release aprašymas tai nurodo, o kitas build'as su branduoliu šią versiją pakeis.

## Struktūra

```
Sources/IPSWKit/       IPSW: ZIP64, BuildManifest/Restore.plist, IMG4/IM4P, LZFSE/LZSS,
                       DeviceTree (skaitymas ir rašymas), UDIF, GPT, APFS tomų rašymas
Sources/EmulatorKit/   Backend'ai, suderinamumas, hardware padengimas, QEMU paleidimas, VNC
Sources/ipsw-emu/      CLI: inspect / boot / dt / apfs-add-volume
App/IOSEmul/           SwiftUI programa
qemu/patches/inferno/  Patch'ai Inferno QEMU (iOS embedding, JIT, SEP, debranding)
scripts/               build-qemu-ios.sh, make-sidestore-source.py, dt-survey.py
research/devicetrees/  13 SoC DeviceTree inventoriai: kiekvieno lusto darbo sąrašas
.github/workflows/     ci, ipa (QEMU iOS + IPA + release), boot-test (tikri IPSW), dt-survey
```

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

## Ribos ir apribojimai

- **Failai, kurių nėra IPSW.** SecureROM ir SEP ROM yra lusto viduje. Be jų bootinama su simuliuotu
  SEP; tikrą SEP galima įjungti pateikus savo dump'ą. iPod boot ROM ir AP ticket'as taip pat gaunami
  iš savo įrenginio.
- **Šifravimas.** 64 bitų IPSW kernelcache nešifruotas (nuo iOS 10), todėl bootinama be iBoot.
  32 bitų erai reikia viešai žinomų arba vartotojo pateiktų raktų.
- **iOS 16+** Preboot tome reikia sistemos cryptex failų; tomų rašytuvas kol kas kuria tik
  katalogus.
- **JIT.** Greitam QEMU reikia JIT leidimo (TrollStore, SideStore su JIT įjungikliu, debugger).
- **Vienas VM per paleidimą.** QEMU laiko globalią būseną, o iOS neleidžia kurti procesų.
- Naudokite tik teisėtai turimą programinę įrangą ir laikykitės Apple licencijos sąlygų.
- Apple mašinų modeliai paimti iš [QEMUAppleSilicon](https://github.com/ChefKissInc/QEMUAppleSilicon)
  (GPLv3/AGPLv3) ir modifikuoti patch'ais iš `qemu/patches/inferno/`. Tai išvestinis build'as: pagal
  upstream branding sąlygas jame nėra jų paveikslėlio ir „ChefKiss Inferno“ pavadinimo, o šis
  projektas nėra su ChefKiss susijęs ar jų remiamas.
