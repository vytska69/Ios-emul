# iOS Emul

**Universalus iOS emuliatorius telefone.** Atsidarai bet kurio iPhone, iPad ar iPod touch `.ipsw`
failą ir paleidi tą iOS emuliuojamame Apple įrenginyje, pačiame telefone. Be kompiuterio: nei
programai įdiegti, nei iOS į virtualų įrenginį įrašyti.

[![CI](https://github.com/vytska69/Ios-emul/actions/workflows/ci.yml/badge.svg)](https://github.com/vytska69/Ios-emul/actions/workflows/ci.yml)
[![IPA](https://github.com/vytska69/Ios-emul/actions/workflows/ipa.yml/badge.svg)](https://github.com/vytska69/Ios-emul/actions/workflows/ipa.yml)
[![Rolling release](https://img.shields.io/badge/release-Rolling-3C78D8)](https://github.com/vytska69/Ios-emul/releases/tag/Rolling)

[Įdiegimas](#įdiegimas) · [JIT](#jit-ir-varikliai) · [Būsena](#būsena) · [Kaip tai veikia](#kaip-tai-veikia) ·
[Programa](#programa) · [Kūrėjams](#kūrėjams) · [Ribos](#ribos) · [ROADMAP](ROADMAP.md) ·
[Kas naujo](distribution/whats-new.md)

> **Dabar.** iPhone 11 su iOS 14.0 įsidiegia be restore ir pasiekia `launchd` ir macOS CI'e, ir
> telefone (iPhone 16e, iOS 27.2, JIT per StikDebug). Abiem atvejais sustoja ties sistemos keybag'u,
> kurio dar nėra, nes effaceable saugykla nesuformatuota. iPhone 6s su iOS 15.8 pasiekia IOKit.
> Plačiau: [Būsena](#būsena).

---

## Įdiegimas

Kiekvienas sėkmingas IPA build'as atnaujina [Rolling release](https://github.com/vytska69/Ios-emul/releases/tag/Rolling).

| Būdas | Ką daryti |
|---|---|
| **SideStore / AltStore Classic** | Pridėk šaltinį `https://github.com/vytska69/Ios-emul/releases/download/Rolling/sidestore.json`. Atnaujinimuose „What's New“ rodo, kas pasikeitė. |
| **TrollStore** | Atidaryk `https://github.com/vytska69/Ios-emul/releases/download/Rolling/IOSEmul.ipa`. |
| **AltStore PAL** | Netinka: diegia tik Apple notarizuotas programas, o šis build'as nenotarizuotas. |

Reikia iOS 16 ar naujesnės.

**IPSW gavimas.** *Download* skirtuke matyti visi iPhone, iPad ir iPod touch modeliai iš ipsw.me
(emuliuojami viršuje), su IPSW dydžiu, data ir tuo, ar emuliatorius gali juos paleisti. Failas
siunčiamas iš Apple CDN fone, nutrūkęs siuntimas tęsiamas nuo tos vietos, o baigus patikrinamas
pagal ipsw.me SHA-1 ir importuojamas automatiškai. Turimą `.ipsw` galima importuoti ir iš Files;
jis skaitomas vietoje, nekopijuojamas.

## JIT ir varikliai

Programoje yra du QEMU varikliai:

| Variklis | Greitis | Ko reikia |
|---|---|---|
| **JIT** | Greitas | JIT leidimo programai (StikDebug, TrollStore „Open with JIT“) |
| **Interpreter** (TCI) | Kelis kartus lėtesnis | Nieko |

*Settings → Emulator → Engine*: **Automatic** (JIT, jei įjungtas, kitaip interpretatorius), **JIT**
arba **Interpreter**.

**iOS 26 ir naujesni įrenginiai su TXM** (iPhone 15 Pro, 16, 16e, 17 ir naujesni). Čia vien
prisijungęs debugger'is nebeleidžia programai pačiai paversti atminties vykdoma: JIT kodas
nepasileidžia, ir mašina sustoja iškart po starto. Programa todėl paprašo StikDebug paruošti JIT
atmintį per jų [`brk #0xf00d` protokolą](https://github.com/StikDebug/StikJIT/blob/main/INTEGRATION.md)
(QEMU patch 0016):

1. *Settings → Emulator* → **Enable JIT with StikDebug**. Programa atidaro
   `stikdebug://enable-jit?bundle-id=…&pid=…&script-name=universal.js`.
2. StikDebug prisijungia su `universal.js` skriptu; grįžus programa paruošia JIT atmintį ir parašo
   „JIT enabled; … MB prepared“.
3. Paleisk mašiną. Vertimo kešas lieka paruošto dydžio iki kito programos paleidimo.

Jei JIT vis tiek nesiseka, pasirink **Interpreter**.

## Būsena

Kiekvienas IPSW matuojamas tuo pačiu keliu: XNU → IOKit → root → launchd → SpringBoard. `Boot test`
workflow tai daro macOS CI'e su tikrais IPSW, programa telefone eina tuo pačiu keliu.

| Įrenginys ir iOS | Kur pasiekia | Kas stabdo |
|---|---|---|
| iPhone 11 (A13), iOS 14.0, tiesioginis įdiegimas | `launchd`; praeina `fsck`, `mount-phase-1`, `data-protection`, SEP boot ir gigalocker | Pirmo paleidimo „Erase All Content“ (`mobile_obliterator`) panikuoja „Failed to write effaceable.“: effaceable saugykla (NVMe nsid 6) nesuformatuota, branduolys į ją net nebando rašyti. Ją paprastai suformatuoja restore |
| iPhone 11, iOS 14.0, restore režimas | Restore ramdisk iki `launchd` | Reikia restore šeimininko (USB-over-TCP, ROADMAP 4 etapas) |
| iPhone 6s / 6s Plus (A9), iOS 15.8 | IOKit (AIC, AES, SPI, I2C, PCIe, NVMe) | „Kernel data abort“ po `AppleSynopsysMIPIDSIController::start` (ekrano kelias) |
| iPhone XR (A12), iOS 14.0, ant iPhone 11 mašinos | Mašina susikuria, MMU įjungiamas | Panika `rtclock` inicializacijoje dar prieš serial išvestį. Atidėta, kol tvarkomas iPhone 11 |
| Telefone (iPhone 16e, iOS 27.2, JIT per StikDebug) | Tas pats kaip CI: `launchd` per kelias sekundes, `fsck` … `fips`; VNC ekranas prisijungia (832×1792) | `keybag`: nėra `systembag.kb` („tears in rain… Time to die“), iOS persikrauna ratu |
| SpringBoard | Dar nepasiekta | |

**Emuliuojamos mašinos**

| Backend | Įrenginiai | iOS |
|---|---|---|
| `inferno-t8030` | iPhone 11 (A13); 11 Pro / Pro Max / SE 2 eksperimentiškai; iPhone XR (A12) tik su `--force-backend` | 14 išbandyta; 13, 15–18, 26 eksperimentinės |
| `inferno-s8000` | iPhone 6s / 6s Plus (A9), visada 2 GiB RAM | 9–15 eksperimentinės; 15.8 pasiekia IOKit |
| `qemu-ios` | iPod touch 1G / 2G | iPhoneOS 1.x–2.x, tik macOS (į programą dar neįdėta) |

Kiti IPSW importuojami ir išanalizuojami: programa parodo, kokio hardware trūksta.

## Kaip tai veikia

Apple lustų periferija (pertraukimų valdiklis, laikmačiai, PMGR, DART, NVMe, SEP, ekranas)
nedokumentuota. Todėl einama taip:

1. **IPSW pats aprašo savo hardware.** Kiekvienas IPSW turi DeviceTree su visais įrenginiais,
   MMIO adresais ir pertraukimais. Programa jį perskaito ir parodo, kas jau emuliuojama.
2. **Viena mašina, kuri susirenka pati.** Mašina pasistato iš IPSW DeviceTree: žinomiems blokams
   prijungia modelius, nežinomus praleidžia. Kiekvienas naujas modelis padeda visiems lustams.
3. **Įdiegimas be restore.** iOS įrašoma tiesiai iš IPSW: išskleidžiamas UDIF atvaizdas,
   parašomas GPT 4 KiB blokams, į APFS konteinerį įrašomi Preboot, xART ir Data tomai, pritaikomas
   `fstab`. `idevicerestore` ir kompiuterio nereikia.
4. **SEP be vartotojo failų.** Simuliuotas SEP pats atlieka boot'ą su IPSW SEP firmware ir atsako
   į raktų saugyklos ir xART užklausas.
5. **QEMU telefone.** QEMU kompiliuojamas kaip biblioteka (iOS neleidžia kurti procesų) ir
   paleidžiamas programos viduje; ekranas rodomas per VNC.
6. **Matavimas, ne spėjimas.** `Boot test` bootina tikrus IPSW, užrašo toliausią etapą, panic'ą,
   registrus ir atmintį; taisoma tai, kas sustoja pirmiausia.
7. **Viešos žinios.** Inferno / QEMUAppleSilicon (A9/A13), Asahi Linux (M1/M2), devos50 (S5L89xx).

Etapai:

| # | Etapas | Būsena |
|---|---|---|
| 0 | Programa telefone be kompiuterio (IPA per GitHub Actions, SideStore/TrollStore) | Veikia |
| 1 | DeviceTree parseris ir hardware padengimo ataskaita | Atlikta |
| 1b | Įdiegimas be restore (UDIF, GPT, APFS tomai, fstab) | Veikia iOS 14 |
| 1c | Simuliuotas SEP (boot, raktų saugykla, xART, gigalocker) | Veikia; toliau sistemos keybag'as ir effaceable |
| 2 | Bendra DeviceTree valdoma mašina | Pradėta (A12 ant T8030) |
| 3 | A14 (T8101) ir M1 (T8103) | Planuojama |
| 4 | Restore programoje (USB-over-TCP) | Planuojama |
| 5 | A15–A18, M2, M4 | Planuojama |
| 6 | 32 bitų era (A4–A6, iOS 4–10) | Planuojama |
| 7 | Greitis (savas arm64→arm64 vertėjas, HVF ten, kur yra hipervizorius) | Planuojama |

Visas planas: [ROADMAP.md](ROADMAP.md).

## Programa

Trys skirtukai:

- **Machines.** Importuotų IPSW kortelės su iOS versijos ženkliuku. Firmware puslapyje: boot režimai
  (tiesioginis įdiegimas arba restore), RAM ir CPU, suderinamumas, hardware padengimas, įrenginiai.
- **Download.** ipsw.me katalogas su filtrais iPhone / iPad / iPod ir paieška.
- **Settings.** Temos (Aurora, Ember, Circuit, Mono), boot numatytieji, emuliatorius (variklis,
  JIT, vertimo kešas, verbose boot, ekrano neužmigdymas), siuntimai, saugykla, *About*.

**Mašinos ekranas.** Lietimas siunčiamas kaip pelė, mygtukai Home ir Lock. Kol ekranas dar
neįsijungė, rodoma, ar QEMU dar kuria mašiną, ar ji jau veikia, kur yra CPU 0 ir ar jis juda, o
laukelyje – branduolio serial išvestis (arba QEMU žurnalas, kol branduolys nieko neišspausdino).

**Eksperimentinės funkcijos.** *About* puslapyje 7 kartus paspausk versijos numerį:

- QEMU debug flags (`in_asm`, `int`, `exec` …), papildomi boot-args ir QEMU argumentai, prievartinis backend.
- Mašinos įrankiai: pauzė, tęsimas, perkrovimas, ekrano nuotrauka, QEMU monitorius, serial konsolė, kadrų skaitiklis.
- Firmware įrankiai: IPSW failų naršyklė, DeviceTree naršyklė, žurnalai (`serial.log`, `qemu.log`, `qemu-debug.log`), mašinos trynimas.
- Emuliuoto iOS nustatymai, įrašomi į Data tomą prieš pirmą paleidimą: VoiceOver, Zoom,
  AssistiveTouch, didesnis ar paryškintas tekstas, mažiau judesio, šviesi ar tamsi išvaizda, kalba
  ir regionas, 24 val. laikrodis, įrenginio vardas, sąrankos ekranų praleidimas.

Jei programa užsidaro veikiant mašinai, kitą kartą firmware puslapyje rodoma paskutinė QEMU
išvestis. Jei mašina netelpa į iOS programai leidžiamą atmintį, boot'as nepradedamas.

## Kūrėjams

### Struktūra

```
Sources/IPSWKit/       IPSW: ZIP64, BuildManifest, IMG4/IM4P, LZFSE/LZSS, DeviceTree, UDIF, GPT,
                       APFS tomų rašymas
Sources/EmulatorKit/   Backend'ai, suderinamumas, padengimas, QEMU paleidimas (variklis, JIT), VNC,
                       emuliuoto iOS nustatymai
Sources/ipsw-emu/      CLI
App/IOSEmul/           SwiftUI programa
qemu/patches/inferno/  Patch'ai Inferno QEMU (žr. žemiau)
qemu/keymaps/          QEMU VNC klaviatūros išdėstymai
scripts/               QEMU build'ai, SideStore šaltinis, DeviceTree ir branduolio analizės įrankiai
research/devicetrees/  13 SoC DeviceTree inventoriai
distribution/          Ikona ir whats-new.md (SideStore „What's New“)
.github/workflows/     ci, ipa, boot-test, rootfs-probe, dt-survey
```

### Kompiliavimas

Reikia macOS su Xcode 16.

```sh
swift test
brew install xcodegen
scripts/build-qemu-ios.sh                                     # JIT QEMU → App/Frameworks (ilgai)
QEMU_IOS_OUT=build-qemu-tci-out scripts/build-qemu-ios.sh --tci # interpretatorius
xcodegen generate && open IOSEmul.xcodeproj
```

IPA workflow abu QEMU sudeda į vieną IPA: interpretatorius įdedamas kaip
`qemu-aarch64-softmmu-tci.framework`, o `QEMURunner` pasirenka variklį paleidimo metu.

### CLI

```sh
ipsw-emu inspect firmware.ipsw                                  # identitetai, suderinamumas, padengimas
ipsw-emu dt firmware.ipsw --product iPhone12,1 --path /arm-io   # DeviceTree mazgas
ipsw-emu boot firmware.ipsw --work vm --product iPhone12,1 --mode direct \
  --seconds 600 [--force-backend inferno-t8030] [--qemu-debug guest_errors] \
  [--monitor "info registers; x /16wx 0x…"] [--qemu-args "-accel tcg,split-wx=on"]
ipsw-emu apfs-add-volume disk.img --role data|preboot|xart …   # APFS tomų rašytuvas
ipsw-emu apfs-dump disk.img
```

### Boot test

`Boot test` workflow (Actions → Run workflow) bootina tikrus IPSW macOS'e. Įvestys: `product`,
`versions`, `modes` (`direct`, `auto`), `force_backend`, `qemu_debug` (pvz.
`trace:pci_nvme_io_cmd`), `seconds`, `monitor` (QEMU monitoriaus komandos pasibaigus laikui, pvz.
`pmemsave`), `qemu_args` ir `after` (shell komandos po boot'o). Pasibaigus laikui išvedami visų CPU
registrai, žodžiai aplink PC ir paskutinės debug žurnalo eilutės prieš pirmą išimtį.

Pagalbiniai įrankiai:

- `scripts/xref.py` – randa branduolio kodą, kuris skaito ar rašo globalų kintamąjį, `pmemsave` atminties kopijoje.
- `scripts/adt.py` – išspausdina neapdorotą Apple DeviceTree (pvz. tą, kurį QEMU perdavė branduoliui).
- `scripts/dt-survey.py`, `scripts/gen-inferno-coverage.py` – DeviceTree inventoriai ir padengimo lentelė.

### QEMU patch'ai

| # | Ką daro |
|---|---|
| 0001, 0008 | QEMU kaip biblioteka iOS'ui (UTM pagrindu), libucontext |
| 0002, 0006, 0007 | Simuliuotas SEP: be duomenų šifravimo, iš anksto įkeltas SEPOS, pranešimų žurnalas |
| 0003 | Išvestinio build'o debranding'as |
| 0004, 0005 | iOS JIT rašymo apsauga, `statfs` antraštės |
| 0009 | T8030 NVRAM kintamieji (`nvram-vars`) |
| 0010–0014 | Kitų lustų (A12) DeviceTree T8030 mašinoje: DART, PCIe SID, MIPI DSI, APRR registrai, CPU mazgai |
| 0015 | ANS NVMe „tunnel“ komandų žurnalas |
| 0016 | iOS 26+ (TXM) JIT per StikDebug `brk #0xf00d` |
| 0017–0019 | Interpretatoriaus (TCI) build'as: `Int128` dydis ir 128 bitų atomikai, be disasemblerio |
| 0020 | Branduolio pataisa: tuščia effaceable saugykla laikoma suformatuota (iOS 14) |

### Pakeitimai programoje

Kiekvienas programą pasiekiantis pakeitimas tame pačiame commit'e prideda eilutę į
[`distribution/whats-new.md`](distribution/whats-new.md), parašytą paprastam vartotojui; ji
rodoma SideStore „What's New“ ir Rolling release puslapyje (žr. [`CLAUDE.md`](CLAUDE.md)).

## Ribos

- **Failai, kurių nėra IPSW.** SecureROM ir SEP ROM yra lusto viduje; bootinama su simuliuotu SEP.
  iPod boot ROM negali būti platinamas su programa.
- **Effaceable ir sistemos keybag'as.** Restore juos sukuria per SEP; tiesioginis įdiegimas jų dar
  neturi, todėl iPhone 11 pirmas paleidimas sustoja (žr. [ROADMAP](ROADMAP.md)).
- **iOS 16+** Preboot tome reikia sistemos cryptex failų; dar nepadaryta.
- **Data tomas** kol kas turi tik pagrindinius katalogus.
- **iPhone 6s RAM** visada 2 GiB (tiek priima QEMU S8000 modelis).
- **Hipervizoriaus nėra.** iPhone programoms Apple nesuteikia virtualizacijos (EL2), todėl tai
  emuliacija su JIT; UTM HV versija veikia tik M1+ iPad su jailbreak ar TrollStore.
- **Vienas VM per paleidimą.** QEMU laiko globalią būseną, o iOS neleidžia kurti procesų.
- **32 bitų era** reikalaus viešai žinomų ar vartotojo pateiktų firmware raktų.

## Licencija ir padėkos

Naudokite tik teisėtai turimą programinę įrangą ir laikykitės Apple licencijos sąlygų.

Apple mašinų modeliai paimti iš [QEMUAppleSilicon](https://github.com/ChefKissInc/QEMUAppleSilicon)
(GPLv3/AGPLv3) ir modifikuoti patch'ais iš `qemu/patches/inferno/`. Tai išvestinis build'as: pagal
upstream branding sąlygas jame nėra jų paveikslėlio ir „ChefKiss Inferno“ pavadinimo, o šis
projektas nėra su ChefKiss susijęs ar jų remiamas. iOS build'as remiasi [UTM](https://github.com/utmapp/UTM)
priklausomybių kompiliavimu; iPod touch mašinos – [devos50/qemu-ios](https://github.com/devos50/qemu-ios);
TXM JIT protokolas – [StikDebug](https://github.com/StikDebug/StikJIT).
