# iOS Emul

**Tikslas: universalus iOS emuliatorius.** Bet kurį iPhone, iPad ar iPod touch `.ipsw` failą
atsidarai telefone ir naudoji jo operacinę sistemą emuliuojamame Apple įrenginyje. Nuo iPhoneOS 1
iki naujausios iOS, nuo A4 iki naujausių lustų. Be kompiuterio: nei programai įdiegti, nei iOS
įdiegti į virtualų įrenginį.

Viešai to dar niekas nedaro. Šis projektas eina ten etapais, ir kiekvienas etapas turi išmatuojamą
rezultatą: kiek toli bootina tikras IPSW.

> **Dabar:** iOS 14.0 ant emuliuojamo iPhone 11 įdiegiamas be restore ir praeina 11 launchd boot
> žingsnių (`fsck` … `fips`, macOS CI). Simuliuotas SEP užkrauna SEP firmware, inicializuoja
> gigalocker ir įjungia raktų saugyklą; System, Preboot, xART ir Data tomai prijungiami. Trūksta
> sistemos keybag'o, kurį paprastai sukuria restore: pirmas boot'as todėl paleidžia iOS „Erase All
> Content“ pabaigimą, kuris dabar stoja ties nesuformatuota effaceable saugykla.
> iPhone 6s (A9) su iOS 15.8: kernelis praeina didžiąją dalį IOKit ir stoja ties ekrano
> valdikliu. iPhone XR (A12) jau paleidžiamas ant iPhone 11 mašinos: mašina susirenka iš XR
> DeviceTree ir kernelis gauna valdymą, bet stoja ties pirmomis instrukcijomis.
> Telefone: Rolling release IPA (nuo 0.1.85) turi QEMU emuliatoriaus branduolį; programa
> parsisiunčia IPSW iš ipsw.me, juos patikrina, analizuoja ir gali paleisti emuliuojamą mašiną.
> Žr. [Būsena](#būsena).

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
   atvaizdas, parašomas GPT 4 KiB blokams, į APFS konteinerį įrašomi Preboot, xART ir Data tomai,
   kuriuos paprastai sukuria restore, o DeviceTree `fstab` pritaikomas. Todėl `idevicerestore` ir
   kompiuterio nereikia.
4. **SEP be vartotojo failų.** Duomenų apsaugai iOS reikia Secure Enclave. Užuot reikalavus SEP ROM
   dump'o, simuliuotas SEP pats atlieka boot'ą: kernelis jam paduoda IPSW SEP firmware (Preboot
   tome), SEP paskelbia savo endpoint'us ir atsako į raktų saugyklos ir xART užklausas.
5. **Matavimas, ne spėjimas.** `Boot test` workflow bootina tikrus IPSW ir užrašo toliausią etapą
   (XNU → IOKit → root → launchd → SpringBoard) bei panic'ą. Taisoma tai, kas sustoja pirmiausia.
6. **Viešos žinios.** Inferno (A9/A13), Asahi Linux (M1/M2: AIC2, DART, PMGR, DCP, SPMI) ir devos50
   (S5L89xx) jau ištyrė didelę dalį hardware; jų darbas naudojamas kaip pagrindas.

Visas planas su etapais: [ROADMAP.md](ROADMAP.md).

## Kelias iki tikslo

| # | Etapas | Būsena |
|---|---|---|
| 0 | Programa telefone be kompiuterio (IPA per GitHub Actions, SideStore/TrollStore) | Veikia: Rolling IPA su QEMU branduoliu, IPSW parsisiuntimas iš ipsw.me |
| 1 | DeviceTree parseris ir hardware padengimo ataskaita | Atlikta |
| 1b | Įdiegimas be restore (UDIF, GPT, APFS tomai, fstab) | Veikia iOS 14: Preboot, xART ir Data tomai įrašomi, `fsck_apfs` švarus, iOS juos prijungia |
| 1c | Simuliuotas SEP (SEP boot, raktų saugykla, xART, gigalocker) | SEP boot, gigalocker ir raktų saugyklos endpoint'as veikia; toliau sistemos keybag'as |
| 2 | Bendra DeviceTree valdoma mašina | Pradėta: T8030 mašina praleidžia blokus, kurių kito lusto DeviceTree neturi (A12) |
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
| iOS 14.0, iPhone 11, tiesioginis įdiegimas | Praeina `fsck`, `mount-phase-1`, `data-protection`, `finish-obliteration`, `commit-boot-mode`, `mount-phase-2` (Data tomas ant `/private/var`), `init-with-data-volume`, `MSUEarlyBootTask`, `fips`. Stoja `keybag`: nėra `/private/var/keybags/systembag.kb`, todėl iOS persikrauna ratu |
| APFS rašytuvas | Prideda tomus su katalogais, failais, savininkais ir teisėmis; daugiapakopiai B-medžiai dideliems tomams. CI tikrina `fsck_apfs` ir macOS mount'u (6000 katalogų, 300 failų) |
| iOS 15.8, iPhone 6s Plus (A9), tiesioginis įdiegimas | Kernelis paleidžia IOKit (AIC, AES, SPI, I2C, PCIe, NVMe MMU), tada panic „Kernel data abort“ iškart po `AppleSynopsysMIPIDSIController::start` (ekrano kelias) |
| iOS 14.0, iPhone XR (A12), ant T8030 mašinos | Mašina susirenka iš XR DeviceTree (patch'ai 0010, 0011), kernelis gauna valdymą, bet pirmos instrukcijos sukelia išimtį (CPU0 ties vektoriumi `0x200`); kita – nustatyti, kuri A12 instrukcija ar registras |
| SpringBoard | Dar nepasiekta |
| QEMU iOS'ui | Kompiliuojasi ir įdedamas į IPA (biblioteka be `qemu-system` programos); pirmas toks build'as 0.1.85 |
| IPSW skaitymas programoje | Pozicinis skaitymas (`pread`): keli vienu metu skaitantys procesai nebegauna vienas kito baitų (anksčiau tai rodė „CRC mismatch“ ir „Corrupt compressed data (deflate)“ ant sveikų failų) |
| Atmintis telefone | QEMU vertimo kešas ribojamas 256 MiB; prieš boot'ą patikrinama, ar VM telpa į iOS leidžiamą atmintį, kitaip parodoma klaida (iOS programą, viršijusią ribą, uždaro be pranešimo) |
| Rolling release | Publikuojamas į [`Rolling`](https://github.com/vytska69/Ios-emul/releases/tag/Rolling) kiekvienam IPA build'ui; SideStore šaltinio versijos imamos iš paties IPA |

Šiuo metu emuliuojamos mašinos:

| Backend | Įrenginiai | iOS |
|---|---|---|
| `inferno-t8030` | iPhone 11 (A13); 11 Pro / Pro Max / SE 2 eksperimentiškai; iPhone XR (A12) paleidžiamas tik su `--force-backend` | 14 išbandyta; 13, 15–18, 26 eksperimentinės |
| `inferno-s8000` | iPhone 6s / 6s Plus (A9), visada 2 GiB RAM (QEMU modelis kito dydžio nepriima) | 9–15 eksperimentinės; 15.8 pasiekia IOKit |
| `qemu-ios` | iPod touch 1G / 2G | iPhoneOS 1.x–2.x |

Kiti IPSW importuojami ir išanalizuojami: programa parodo, kokio hardware trūksta. Naujo lusto
paleidimas pradedamas nuo `ipsw-emu boot --force-backend inferno-t8030` (Boot test workflow
įvestis `force_backend`). Boot test išsaugo įrenginio `arm-io` medį, o pasibaigus laikui išveda
visų CPU registrus, todėl matosi, kur sustoja ir tylus boot'as.

## Įdiegimas

Kiekvienas IPA build'as atnaujina [rolling release](https://github.com/vytska69/Ios-emul/releases/tag/Rolling):

- **SideStore / AltStore Classic:** pridėk šaltinį
  `https://github.com/vytska69/Ios-emul/releases/download/Rolling/sidestore.json`. Šaltinio
  `version` ir `buildVersion` imami iš IPA `Info.plist`, todėl sutampa su atsisiunčiamu failu.
  **AltStore PAL** (ES versija) šio šaltinio nepriims: ji diegia tik Apple notarizuotas programas
  su `marketplaceID`, o šis build'as nėra notarizuotas.
- **TrollStore:** atidaryk
  `https://github.com/vytska69/Ios-emul/releases/download/Rolling/IOSEmul.ipa`.

**IPSW gavimas.** Programoje „+“ → *Download from ipsw.me* parodo visus iPhone, iPad ir iPod touch
įrenginius (emuliuojami viršuje) ir jų IPSW su dydžiu, data ir tuo, ar emuliatorius gali juos
paleisti. Failas siunčiamas iš Apple CDN fone (tęsiasi ir uždarius programą, nutrūkęs siuntimas
pratęsiamas nuo tos vietos), įrašomas į `Firmware` aplanką (matomas Files programoje) ir
importuojamas automatiškai. Atsisiųstas failas patikrinamas pagal ipsw.me SHA-1; sugadintas
ištrinamas ir siūloma siųsti iš naujo. Turimą `.ipsw` galima ir tiesiog importuoti iš Files.

Jei programa užsidaro paleidus VM, ją vėl atidarius firmware puslapyje rodoma QEMU paskutinė
išvestis. Jei VM netelpa į atmintį, kurią iOS leidžia programai, boot'as nepradedamas ir parodoma,
kiek atminties reikia.

Nuo 0.1.85 IPA turi emuliatoriaus branduolį. Greitam darbui QEMU reikia JIT (TrollStore,
SideStore su JIT įjungikliu); be jo naudok `scripts/build-qemu-ios.sh --tci` build'ą. Kiek toli
bootina kiekvienas iOS, rodo [Būsena](#būsena): telefone tai tas pats kelias, kurį CI tikrina macOS'e.

## Struktūra

```
Sources/IPSWKit/       IPSW: ZIP64, BuildManifest/Restore.plist, IMG4/IM4P, LZFSE/LZSS,
                       DeviceTree (skaitymas ir rašymas), UDIF, GPT, APFS tomų rašymas
Sources/EmulatorKit/   Backend'ai, suderinamumas, hardware padengimas, QEMU paleidimas, VNC
Sources/ipsw-emu/      CLI: inspect / boot (--qemu-debug, --force-backend) / dt (--product, --path) /
                       apfs-add-volume (--role, --owners) / apfs-dump
App/IOSEmul/           SwiftUI programa
qemu/patches/inferno/  Patch'ai Inferno QEMU: iOS embedding, JIT, SEP, debranding, NVRAM kintamieji (0009),
                       kitų lustų DeviceTree T8030 mašinoje (0010, 0011)
scripts/               build-qemu-ios.sh, build-inferno-macos.sh, make-sidestore-source.py,
                       dt-survey.py, gen-inferno-coverage.py
research/devicetrees/  13 SoC DeviceTree inventoriai: kiekvieno lusto darbo sąrašas
.github/workflows/     ci (testai + APFS patikra), ipa (QEMU iOS + IPA + release), boot-test (tikri IPSW,
                       SEP žurnalas), rootfs-probe (IPSW root failų sistemos tyrimas, failų
                       ištraukimas), dt-survey
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
- **iOS 16+** Preboot tome reikia sistemos cryptex failų. Tomų rašytuvas jau moka rašyti failus,
  bet cryptex'ų įdiegimas dar nepadarytas.
- **Gigalocker vardas** xART tome kol kas paimtas iš emuliuojamo iPhone 11 boot žurnalo; kitiems
  įrenginiams jo apskaičiavimas dar nežinomas. Failas yra 6 MiB nulių, kaip jį sukuria `seputil`.
- **Sistemos keybag'as.** Restore jį sukuria per SEP ir užšifruoja effaceable saugyklos `BAG1`
  raktu. Simuliuoto SEP raktų saugykla bet kokį keybag'ą priima, bet effaceable saugykla ir
  `systembag.kb` dar tušti. Pirmas boot'as po įdiegimo todėl paleidžia iOS „Erase All Content“
  pabaigimą (`oblit-inprogress` NVRAM'e): iOS ištrina Data, atšaukia raktus ir išvalo gigalocker'ius,
  bet stoja ties „Failed to write effaceable.“, nes effaceable saugykla (NVMe namespace 6)
  nesuformatuota. Ją paruošti yra kitas žingsnis.
- **Data tomas** kol kas turi tik pagrindinius katalogus. Restore į jį nukopijuoja visą rootfs
  `/private/var` (~17 tūkst. įrašų); tam reikia APFS skaitytuvo su suspaustų failų palaikymu.
- **iPhone 6s RAM** visada 2 GiB: tiek priima QEMU S8000 modelis. Telefone, kuriame programai
  leidžiama mažiau nei ~2,6 GiB, šios mašinos paleisti nepavyks.
- **A12 (iPhone XR)** kol kas tik ant iPhone 11 mašinos: senesnis USB valdiklis (`usb-complex`)
  dar nemodeliuojamas, todėl USB praleidžiamas, o kernelis stoja ties pirmomis instrukcijomis.
- **JIT.** Greitam QEMU reikia JIT leidimo (TrollStore, SideStore su JIT įjungikliu, debugger).
- **Vienas VM per paleidimą.** QEMU laiko globalią būseną, o iOS neleidžia kurti procesų.
- Naudokite tik teisėtai turimą programinę įrangą ir laikykitės Apple licencijos sąlygų.
- Apple mašinų modeliai paimti iš [QEMUAppleSilicon](https://github.com/ChefKissInc/QEMUAppleSilicon)
  (GPLv3/AGPLv3) ir modifikuoti patch'ais iš `qemu/patches/inferno/`. Tai išvestinis build'as: pagal
  upstream branding sąlygas jame nėra jų paveikslėlio ir „ChefKiss Inferno“ pavadinimo, o šis
  projektas nėra su ChefKiss susijęs ar jų remiamas.
