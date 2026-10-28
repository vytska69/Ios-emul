# Planas

Tikslas: paleisti bet kurio iPhone ar iPad IPSW tiesiai telefone. Darbas suskaidytas į etapus, ir
kiekvieno rezultatas matuojamas `Boot test` workflow.

## Principas

Kiekvienas Apple SoC turi savo periferiją: AIC, PMGR, DART, ANS/NVMe, SEP, ekraną, lietimo
valdiklį. Viešos dokumentacijos jai nėra, bet kiekvienas IPSW turi DeviceTree su visais įrenginiais,
jų `compatible` vardais, MMIO adresais ir pertraukimais. Todėl:

1. Mašina statoma iš IPSW DeviceTree. Žinomiems blokams prijungiami modeliai, nežinomiems –
   registruojantis stub'as.
2. Padengimo ataskaita yra darbo sąrašas. Kiekvienas naujas modelis padeda visiems lustams, kurie
   tą bloką naudoja.
3. Naudojamos viešos žinios: QEMUAppleSilicon (A9, A13), Asahi Linux (M1, M2), devos50 (S5L89xx).

## Etapai

| # | Etapas | Būsena |
|---|---|---|
| 0 | IPA per GitHub Actions, diegimas per SideStore ar TrollStore | Atlikta |
| 1 | DeviceTree parseris ir padengimo ataskaita | Atlikta |
| 1b | Įdiegimas be restore: UDIF, GPT, APFS tomai, `fstab` | Veikia su iOS 14 |
| 1c | Simuliuotas SEP: boot, raktų saugykla, xART, gigalocker, sistemos keybag'as | Veikia su iOS 14 |
| 2 | Bendra DeviceTree valdoma mašina | Pradėta: A12 ant T8030 |
| 3 | A14 (T8101) ir M1 (T8103) | Planuojama |
| 4 | Restore programoje: `idevicerestore` per vidinį USB per TCP | Planuojama |
| 5 | A15–A18, M2, M4: SPRR, GXF, AMX, AIC v3 | Planuojama |
| 6 | 32 bitų era (A4–A6, iOS 4–10): IMG3, vartotojo raktai | Planuojama |
| 7 | Greitis | Matuojama, žr. [status.md](status.md) |

## Artimiausi žingsniai

1. **iPhone 11, iOS 14: naudojamas telefonas.** Pagrindinis ekranas ir programėlės jau veikia.
   - Garsas: CS42L77 DSP programinė įranga, kad iOS atsirastų garsiakalbis (žr. [status.md](status.md)).
   - Rasti retos NVMe panikos priežastį.
2. **Greitis telefone.**
   - Išbandyti 30 Hz ekrano atnaujinimą ir mažiau vCPU.
   - Išsiaiškinti, kodėl interpretatorius uždaro programą.
3. **Pilnas Data tomas.** System tomo `/private/var` kopija su savininkais, xattr'ais ir suspaustais
   failais.
4. **Kitos iOS versijos ant T8030.** iOS 13 ir 15–18. Nuo iOS 16 Preboot tome reikia cryptex'ų.
5. **Šifruotas Data tomas.** Simuliuotame SEP įgyvendinti AKS ref-key ir media raktus.
6. **iPhone XR (A12), atidėta.** Panika `rtclock` inicializacijoje. Kitas žingsnis:
   `-d exec,nochain,int` iki pirmos išimties.
7. **iPhone 6s (A9), iOS 15.8.** „Data abort“ po MIPI DSI valdiklio paleidimo.

## Ribos

- **SecureROM ir SEP ROM yra lusto viduje, ne IPSW.** Mašina bootina su simuliuotu SEP, kuris
  priima IPSW SEP firmware. Tikrą SEP būtų galima naudoti su vartotojo dump'u.
- **iBoot ir SEP IPSW'e užšifruoti GID raktu.** Kernelcache nuo iOS 10 nešifruotas, todėl
  bootinamas tiesiai. 32 bitų erai reikia viešų arba vartotojo raktų.
- **iPod touch boot ROM negalima platinti su programa.** Reikia leisti importuoti savo dump'ą arba
  įkelti iššifruotus LLB ir iBoot tiesiai.
