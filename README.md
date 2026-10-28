# iOS Emul

iPhone programa, kuri paleidžia iOS iš `.ipsw` failo emuliuojamame Apple įrenginyje, pačiame
telefone. Kompiuterio nereikia nei programai įdiegti, nei iOS įrašyti į virtualų įrenginį.

[![CI](https://github.com/vytska69/Ios-emul/actions/workflows/ci.yml/badge.svg)](https://github.com/vytska69/Ios-emul/actions/workflows/ci.yml)
[![IPA](https://github.com/vytska69/Ios-emul/actions/workflows/ipa.yml/badge.svg)](https://github.com/vytska69/Ios-emul/actions/workflows/ipa.yml)
[![Rolling release](https://img.shields.io/badge/release-Rolling-3C78D8)](https://github.com/vytska69/Ios-emul/releases/tag/Rolling)

Emuliatorius paremtas [QEMUAppleSilicon](https://github.com/ChefKissInc/QEMUAppleSilicon) mašinomis,
sukompiliuotomis kaip biblioteka ir paleidžiamomis programos viduje.

## Būsena

Toliausiai pažengęs iPhone 11 su iOS 14.0. Jis įsidiegia tiesiai iš IPSW, be restore, ir pasileidžia
iki sąrankos ekrano „Hello“, o su „Skip setup“ iki pagrindinio ekrano. Telefone (iPhone 16e su JIT)
veikia ir programėlės, pavyzdžiui Settings ir jų skiltys.

Lietimas veikia: perbraukus aukštyn užrakinimo ekrane atsidaro pagrindinis ekranas (slaptažodžio
iOS nebeprašo), veikia ir valdymo centras.

- Slaptažodžio nėra: emuliuotas saugos procesorius (SEP) netikrina tikrų raktų, todėl programa
  pataiso iOS taip, kad jis praneštų „slaptažodis nenustatytas“.
- Be „Skip setup“ perbraukus „Hello“ sąranka nebegrįžta į pradžią (anksčiau lūždavo `backboardd`,
  piešiantis ekraną be GPU).
- Garso nėra. iOS garso sistema mato tik tuščią „Null“ įrenginį: garso lusto (CS42L77) tvarkyklė
  negauna DSP programinės įrangos, todėl garsiakalbio nėra, o VirtualAudio nebaigia paleidimo.
  Tiriama bandomojoje šakoje `test/audio-mca`.

| Įrenginys | iOS | Kur pasiekia |
|---|---|---|
| iPhone 11 | 14.0 | Pagrindinis ekranas su „Skip setup“, kitaip sąrankos ekranas „Hello“; lietimas veikia |
| iPhone 11 | 14.1–14.8 | Ekrano kol kas nepasiekia (14.8: SpringBoard lūžta piešdamas ikonas); lietimo pakeitimai nuo versijos nepriklauso, bet nepatikrinti |
| iPhone 6s / 6s Plus | 15.8 | Branduolys sustoja ties ekrano valdikliu |
| iPhone XR | 14.0 | Branduolys sustoja prieš pirmą išvestį |
| iPod touch 1G / 2G | 1.x–2.x | Tik macOS, į programą neįdėta |

Kitus IPSW programa importuoja ir parodo, kokių įrenginio dalių emuliatorius dar neturi.
Išsamiau: [docs/status.md](docs/status.md). Kas pasikeitė: [distribution/whats-new.md](distribution/whats-new.md).

## Įdiegimas

Kiekvienas sėkmingas build'as atnaujina [Rolling release](https://github.com/vytska69/Ios-emul/releases/tag/Rolling).

- **SideStore arba AltStore Classic:** pridėk šaltinį
  `https://github.com/vytska69/Ios-emul/releases/download/Rolling/sidestore.json`.
- **TrollStore:** atidaryk `https://github.com/vytska69/Ios-emul/releases/download/Rolling/IOSEmul.ipa`.
- **AltStore PAL netinka:** jis diegia tik notarizuotas programas.

Reikia iOS 16 ar naujesnės.

Kai kurie kiti diegimo įrankiai pasirašydami išmeta programos teises. Be `get-task-allow` neįsijungia
JIT. Be `increased-memory-limit` ir `extended-virtual-addressing` 4 GB mašina netelpa į atmintį.
Tai, su kuo programa iš tikrųjų pasirašyta, rodo *Settings → Diagnostics*. SideStore šias teises
išlaiko.

## Naudojimas

1. *Download* skirtuke pasirink įrenginį ir iOS versiją. IPSW atsisiunčia iš Apple serverių, o
   baigus patikrinamas SHA-1. Turimą `.ipsw` galima importuoti ir per Files.
2. Firmware puslapyje paspausk *Boot*. Pirmą kartą iOS įdiegiama į virtualų diską, ir pirmas startas
   užtrunka apie 20 min.
3. Kol ekrane nieko nėra, programa rodo starto žingsnius ir laiką. Mašina valdoma lietimais ir
   mygtukais Home, Lock ir Vol −/+.

Su įjungtu *Settings → Emulator → Run in background* mašina veikia ir išėjus iš programos. Tada
programa groja tylų garsą, todėl naudoja bateriją.

*Settings → Emulator → Sound* turi mygtuką „Play test tone“, kuris pagroja toną be emuliatoriaus, ir
garso būseną. Ten matyti, ar emuliuotas telefonas apskritai skleidė garsą.

## JIT

Programoje yra du QEMU varikliai: JIT ir interpretatorius. Interpretatorius kelis kartus lėtesnis,
bet jam nieko nereikia. JIT reikia leidimo, kurį įjungia StikDebug arba TrollStore „Open with JIT“.
*Settings → Emulator → Engine* pagal nutylėjimą pasirenka JIT, jei jis įjungtas.

iPhone su TXM (iPhone 15 Pro, 16, 16e, 17 ir naujesni, iOS 26+) JIT atmintį turi paruošti StikDebug:
*Settings → Emulator → Enable JIT with StikDebug*, tada grįžk į programą ir paleisk mašiną.

## Ribos

- Hipervizoriaus nėra. Apple iPhone programoms jo neduoda, todėl visas kodas emuliuojamas.
- Vienu metu galima paleisti vieną mašiną. Kitai reikia iš naujo atidaryti programą.
- GPU neemuliuojamas. iOS ekraną piešia procesoriumi, ir tai lėčiausia starto dalis.
- Emuliuotas iPhone neaktyvuojamas, o Data tomas nešifruojamas.
- Garso ir tinklo (Wi-Fi) emuliuotame iPhone kol kas nėra.
- Greitis žemas net su JIT: emuliuojamas visas telefonas, o ekraną piešia procesorius.
  Keli QEMU branduoliai (MTTCG) šiai mašinai nepadeda.
- iOS 16+ kol kas nepasileidžia: Preboot tome trūksta cryptex failų.
- iPhone 6s mašina visada turi 2 GB RAM.
- Naudok tik teisėtai turimus IPSW ir laikykis Apple licencijos.

## Dokumentacija

- [docs/status.md](docs/status.md): kas veikia, kas stabdo ir kaip iPhone 11 pasiekia userland.
- [docs/development.md](docs/development.md): kompiliavimas, CLI, CI boot testai, pagalbiniai
  scenarijai ir QEMU patch'ai.
- [docs/roadmap.md](docs/roadmap.md): planas.

## Licencija ir padėkos

Apple mašinų modeliai paimti iš [QEMUAppleSilicon](https://github.com/ChefKissInc/QEMUAppleSilicon)
(GPLv3/AGPLv3) ir pakeisti patch'ais iš `qemu/patches/inferno/`. Tai išvestinis build'as: pagal
upstream sąlygas jame nėra jų logotipo ir pavadinimo, o projektas su ChefKiss nesusijęs.

iOS build'as remiasi [UTM](https://github.com/utmapp/UTM) priklausomybių kompiliavimu, iPod mašinos
paimtos iš [devos50/qemu-ios](https://github.com/devos50/qemu-ios), o TXM JIT protokolas – iš
[StikDebug](https://github.com/StikDebug/StikJIT).
