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

| # | Etapas | Rezultatas |
|---|---|---|
| 0 | CI žalias, `.ipa` per GitHub Actions | Programa įsidiegia telefone per SideStore/TrollStore, kompiuterio nereikia |
| 1 | DeviceTree parseris + padengimo ataskaita | Kiekvienam IPSW matosi, kiek % hardware emuliuojama ir ko trūksta |
| 2 | Bendra DT valdoma mašina (`apple-generic`) mūsų QEMU fork'e | A13 bootina per bendrą kelią, kaip ir per Inferno T8030 |
| 3 | A14 (T8101) ir M1 (T8103) | iPhone 12 / iPad Air 4 / iPad Pro M1 iki launchd, vėliau SpringBoard |
| 4 | Restore programoje | `idevicerestore` + libimobiledevice įkompiliuoti į programą, jungiasi prie VM per vidinį USB-over-TCP |
| 5 | A15–A18, M2, M4 | Naujos CPU sistemos instrukcijos (SPRR, GXF, AMX…), AIC v3, nauji ANS/DCP |
| 6 | 32 bitų era (A4–A6, iOS 4–10) | IMG3 + AES (raktai pateikiami vartotojo), S5L8920/8930/8940/8950 mašinos; uždaro iOS 3–8 skylę |
| 7 | Greitis | TCG optimizacijos ir JIT režimas iOS (TrollStore/JIT įjungikliai), TCI kaip atsarginis |

Kiekvienas etapas push'inamas į GitHub atskirais commit'ais. Kiekvieną komponentą dengia testai, o CI
jį kompiliuoja macOS runneryje.

## Ribos, kurių neperšoksim be vartotojo failų

- **SecureROM / SEP ROM** yra lusto viduje, ne IPSW. Be jų bootinam be SEP (simuliuotas SEP, kaip
  Inferno), o tikrą SEP galima įjungti, jei vartotojas pateikia savo dump'ą.
- **Šifruoti komponentai.** 64 bitų IPSW iBoot/SEP yra šifruoti GID raktu. Kernelcache nuo iOS 10
  nešifruotas, todėl bootinam tiesiai kernelį ir iBoot'o nereikia. 32 bitų erai reikia viešai
  žinomų arba vartotojo pateiktų raktų.
