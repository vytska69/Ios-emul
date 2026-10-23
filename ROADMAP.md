# Planas: bet kuris IPSW, be kompiuterio

Tikslas: paleisti bet kurio iPhone/iPad IPSW operacinę sistemą tiesiai telefone. Šiandien to nedaro
niekas viešai. Tai kelių mėnesių darbas, todėl jis suskaidytas į etapus, kurių kiekvienas duoda
išmatuojamą rezultatą.

## Kodėl tai sunku ir kaip tai įveikiam

Kiekvienas Apple SoC turi savo periferijos rinkinį (AIC, PMGR, DART, ANS/NVMe, SEP, DCP/ekranas,
lietimo valdiklis…), o dokumentacijos nėra. Bet **kiekvienas IPSW turi DeviceTree**, kuriame
išvardinti visi įrenginiai su `compatible` vardais, MMIO adresais ir pertraukimais. Tad:

1. **DeviceTree yra mašinos aprašas.** Vietoj rankomis rašomos mašinos kiekvienam įrenginiui darom
   *bendrą* mašiną, kuri pasistato pati iš IPSW DeviceTree: žinomiems `compatible` prijungia
   modelius, nežinomiems – registruojantį stub'ą.
2. **Padengimo ataskaita yra darbo sąrašas.** Kiekvienam IPSW programa parodo, kurie įrenginiai jau
   emuliuojami ir kurių trūksta. Kiekvienas naujas modelis didina padengimą visiems SoC, kurie tą
   bloką naudoja (pvz., AIC2 naudoja M1, M2, A14+).
3. **Naudojam viešas žinias.** Inferno (A9/A13), Asahi Linux (M1/M2: AIC2, DART, PMGR, DCP, SPMI)
   ir devos50 (S5L89xx) jau išnagrinėjo didelę dalį hardware.

## Etapai

| # | Etapas | Rezultatas | Būsena |
|---|---|---|---|
| 0 | CI žalias, `.ipa` per GitHub Actions | Programa įsidiegia telefone per SideStore/TrollStore, kompiuterio nereikia | Atlikta: Rolling IPA su QEMU branduoliu (nuo 0.1.85), IPSW parsisiuntimas iš ipsw.me |
| 1 | DeviceTree parseris + padengimo ataskaita | Kiekvienam IPSW matosi, kiek % hardware emuliuojama ir ko trūksta | Atlikta |
| 1b | Įdiegimas be restore | iOS įrašoma į virtualų diską tiesiai iš IPSW: UDIF → GPT → APFS konteineris, Preboot/xART/Data tomai, pritaikytas `fstab` | Veikia iOS 14 (iPhone 11): visi tomai prijungiami, `fsck_apfs` švarus |
| 1c | Simuliuotas SEP | SEP ROM dump'o nereikia: SEP boot'as su IPSW firmware, raktų saugykla, xART, gigalocker | SEP boot, gigalocker ir raktų saugykla veikia; 11 launchd žingsnių praeina, stoja `keybag` (nėra sistemos keybag'o) |
| 2 | Bendra DT valdoma mašina (`apple-generic`) mūsų QEMU fork'e | A13 bootina per bendrą kelią, kaip ir per Inferno T8030 | Pradėta: T8030 mašina praleidžia blokus, kurių DeviceTree neturi, ir XR (A12) mašina susirenka (patch'ai 0010, 0011) |
| 3 | A14 (T8101) ir M1 (T8103) | iPhone 12 / iPad Air 4 / iPad Pro M1 iki launchd, vėliau SpringBoard | Planuojama |
| 4 | Restore programoje | `idevicerestore` + libimobiledevice įkompiliuoti į programą, jungiasi prie VM per vidinį USB-over-TCP | Planuojama (1b daugeliu atvejų jį pakeičia) |
| 5 | A15–A18, M2, M4 | Naujos CPU sistemos instrukcijos (SPRR, GXF, AMX…), AIC v3, nauji ANS/DCP | Planuojama |
| 6 | 32 bitų era (A4–A6, iOS 4–10) | IMG3 + AES (raktai pateikiami vartotojo), S5L8920/8930/8940/8950 mašinos; uždaro iOS 3–8 skylę | Planuojama |
| 7 | Greitis | TCG optimizacijos ir JIT režimas iOS (TrollStore/JIT įjungikliai), TCI kaip atsarginis | Planuojama |

### Artimiausi žingsniai

1. Effaceable saugykla, kad pirmo boot'o „Erase All Content“ sukurtų sistemos keybag'ą.
2. iPhone XR (A12, atidėta): kernelis panikuoja `rtclock` inicializacijoje dar prieš serial išvestį,
   nors patch 0014 grąžino CPU mazgus su `timebase-frequency`. Kita – `-d exec,nochain,int` kelias iki
   pirmos išimties (įrankiai: `scripts/xref.py`, `scripts/adt.py`, boot testo `after` įvestis);
   vėliau `usb-complex` USB modelis.
3. iPhone 6s (A9) su iOS 15.8: kernelio „data abort“ po MIPI DSI valdiklio paleidimo (ekrano
   kelias S8000 mašinoje).
4. iOS 14 iki SpringBoard: pilnas `/private/var` Data tome. Tam reikia APFS skaitytuvo, kuris
   nukopijuoja System tomo `/private/var` su savininkais, xattr'ais ir suspaustais failais.
5. Tas pats kelias iOS 13 ir 15–18 ant T8030; iOS 16+ dar reikia cryptex'ų Preboot tome.

Kiekvienas etapas push'inamas į GitHub atskirais commit'ais. Kiekvieną komponentą dengia testai, o CI
jį kompiliuoja macOS runneryje.

## Ribos, kurių neperšoksim be vartotojo failų

- **SecureROM / SEP ROM** yra lusto viduje, ne IPSW. Be jų bootinam su simuliuotu SEP: jis atlieka
  SEP ROM vaidmenį (priima IPSW SEP firmware ir paskelbia SEPOS endpoint'us), todėl duomenų apsauga
  veikia be dump'o. Tikrą SEP galima įjungti, jei vartotojas pateikia savo dump'ą.
- **Šifruoti komponentai.** 64 bitų IPSW iBoot/SEP yra šifruoti GID raktu. Kernelcache nuo iOS 10
  nešifruotas, todėl bootinam tiesiai kernelį ir iBoot'o nereikia. 32 bitų erai reikia viešai
  žinomų arba vartotojo pateiktų raktų.

## iPod touch 1G/2G programoje (vėliau)

- `devos50/qemu-ios` dar nekompiliuojamas į IPA (tik Inferno); kol to nėra, programėlė iPod touch
  IPSW žymi kaip nepalaikomus.
- Boot ROM (SecureROM) yra Apple kodas lustuose, jo negalima platinti su programa. Variantai:
  leisti importuoti savo dump'ą (assetų parinkimas jau yra), arba paleisti be ROM – įkelti LLB/iBoot
  iš IPSW tiesiai (reikia iššifruotų vaizdų).
- NOR ir NAND vaizdus generuoti pačioje programėlėje iš IPSW, o ne qemu-ios įrankiais.

## iPhone 11 tiesioginis įdiegimas: effaceable storage

- Branduolys pasiekia launchd, o `mobile_obliterator` (pirmo paleidimo trynimas) panikuoja
  „Failed to write effaceable.“
- NVMe sekimas: effaceable namespace (nsid 6) perskaitomas vieną kartą (`unable to find content`) ir
  į jį **niekada nerašoma**; ANS „tunnel“ (0xd8) komandos tėra buferių nustatymas. Branduolys
  atsisako rašyti, nes sritis nesuformatuota. Ją formatuoja restore procesas (restored per
  `AppleEffaceableStorage` vartotojo klientą), ne įprastas boot'as.
- Kelias: arba atkartoti suformatuotos srities turinį tiesioginiame įdiegime, arba (patikimiau) prieš
  `mobile_obliterator` paleisti nedidelį įrankį, kuris iškviečia effaceable „format“ metodą, arba
  pasiekti tikrą restore programoje (4 etapas).
- `AppleEffaceableStorage` vartotojo kliento selektoriai (iphone-dataprotection, iOS 4–5 laikų, gali
  būti pasikeitę): 0 getCapacity, 1 getBytes, 2 setBytes, 3 isFormatted, **4 format**, 5 getLocker,
  6 setLocker, 7 effaceLocker, 8 lockerSpace. Lockeriai: `Lk` (0x4c6b) magic, u16 ilgis, u32 žyma
  (`BAG1`, `Dkey`, `EMF!`, `LWVM`), duomenys.
- Kliūtis įrankiui: tiesioginis įdiegimas sisteminį tomą kopijuoja iš IPSW kaip yra, o naujų
  LaunchDaemon'ų iOS 14 launchd nepaleidžia (jie imami iš sisteminio kešo). Reikėtų arba sisteminio
  tomo failų keitimo APFS rašytuve (pvz. `mobile_obliterator` apvalkalo), arba branduolio pataiso.

