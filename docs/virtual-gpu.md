# Virtualus GPU: darbo užrašai

Tikslas: iOS piešimą, kurį dabar emuliuotas procesorius atlieka programiškai (QuartzCore
`CA::OGL::SWContext`, nes AGX GPU nėra), perkelti į emuliatorių: iš pradžių į tiesiogiai
vykdomą kodą, vėliau į įrenginio GPU per Metal.

## 1. Kanalas: hiperkvietimas `HINT #127`

`qemu/patches/inferno/0048-ios-hypercall-channel.patch`.

- Instrukcija `hint #127` (`0xD5032FFF`). Tikrame procesoriuje ji yra NOP, o QEMU kviečia
  `helper_ios_hcall`.
- `x16` – kvietimo numeris, `x0`–`x5` – argumentai, `x0` – rezultatas.
- 0 `PING`: `x0 = 'IOSG'` (`0x494f5347`), `x1` = protokolo versija (1).
- 1 `MEMMOVE(dst, src, len)`: pirmiausia patikrina visus puslapius (klaida įvyksta prieš
  bet kokį įrašymą, o kvietimas po to kartojamas iš naujo); persidengiančius kopijuoja per buferį.
- 2 `MEMSET(dst, byte, len)`.
- Svečio pusėje funkcijos dalis pakeičiama į `mov x16, #N; hint #127; ret`
  (`SharedCachePatches`, 18A373). Taip daroma `_platform_memmove` nuo 4 KB
  (0x1C7996610) ir `_platform_memset`/`_platform_bzero` nuo 32 KB (0x1C7996DC4, 0x1C7996D60).
- Patikrinta CI: iOS įsijungia, atsirakina, Settings veikia, ringtonai groja.

## 2. iOS 14 programinis piešimas (QuartzCore, 18A373)

- `CA::OGL::SWContext::draw_elements(PrimitiveMode, count, const u16 *indices, const Vertex *,
  u32, u32, const ClipPlane *)` (0x183703608). Gauna visą piešimo paketą.
  - `x0` = SWContext; `[ctx+0x8]` – piešimo būsena (`x21`): tekstūrų vienetai, kiekvienam
    `u16` režimas ties `+0xbc + 2*i` (1–2: vaizdas, 3: ?, 4: kvadratas/apskritimas),
    tekstūros rodyklė ties `+0xe0 + 8*i`, vienetų skaičius pagal `tex_image_count[ [state+0x10] ]`.
  - Kiekvienam vienetui kuriama 0x58 baitų `SamplerData` (steke ties `sp+0x1a0`).
  - Tekstūros objektas: `+0x10` paviršius (IOSurface ar Image), `+0x3c` vėliavos,
    `+0x50` IOSurface, `+0x58` formatas (-1: nežinomas), `+0x78` vėliava.
  - Paskirties sritis: `ctx+0x6c0..0x6cc` (x0, y0, x1, y1), apkarpoma pagal `ctx+0x18..0x24`,
    kai `ctx+0x38` ≠ 0.
  - Sampler funkcijos pagal formatą: lentelė `CA::OGL::SW::sampler_functions(unsigned)::samplers`
    (formatai 0..0x1c, po 16 įrašų).
- `CA::OGL::SW::scan_convert(RenderState const*, Poly*, unsigned)` dalija daugiakampius į
  eilutes. Kiekvienai eilutei kviečiama sampler grandinė.
- `render_sampler<T, bool, bool>(const SamplerData *, unsigned count, T *out, unsigned unit)`
  (pvz., 0x18370c898): per `[[sd]+0x38][unit]` iškviečia žemesnį sampler, kuris užpildo
  laikiną buferį. Tada kiekvienam pikseliui:
  `v = clamp(byte * k * sd[0x44] + sd[0x4c] + 0.5, 0, 1) * 255 + 0.5`, ir baitas pakartojamas į
  visus 4 kanalus (alfa kaukė).
- Kitos funkcijos: `image_sampler<Format, T, …>`, `square_sampler`, `circle_sampler`,
  `gaussian_sampler`, `sample_texture`, `tex_color_matrix_4x4_bias`, maišymo režimai
  (`…DarkenSover…`).

## 3. Jau vykdoma tiesiogiai (hiperkvietimai)

| Nr. | Funkcija | Adresas (18A373) | Pataisa | Patikrinta |
|---|---|---|---|---|
| 3 | `image_sampler<ARGB8_Host, unsigned, 1,1,1,1>` (perspektyvinis, 5 kraštų režimai) | 0x183720c2c | 0050 | Unicorn, 200 atvejų, 0 skirtumų (be `atan2f` režimo) |
| 4 | `image_sampler<XRGB8_Host, unsigned, 0,0,0,1>` (afininis) | 0x1837200e4 | 0051 | Unicorn, 50 atvejų, 0 skirtumų |
| 5 | `image_sampler<ARGB8_Host, unsigned, 0,0,0,1>` (afininis) | 0x1837211ac | 0051 | Unicorn, 50 atvejų, 0 skirtumų |
| 6 | `tex_color_matrix_4x4_bias` | 0x183708fd8 | 0051 | Unicorn, 50 atvejų, 0 skirtumų |
| 7 | `image_sampler<ARGB8_Host, unsigned, 0,0,0,0>` (artimiausias taškas) | 0x183721590 | 0053 | Unicorn, 50 atvejų, 0 skirtumų |
| 8 | `tex_multiply_color` | 0x183708a8c | 0053 | Unicorn, 50 atvejų, 0 skirtumų |
| 9 | `Blend::Mode<DarkenSover, false>::blend` (su `DarkenSover::f`) | 0x18370c264 | 0053 | Unicorn, 50 atvejų, 0 skirtumų |
| 10 | `image_sampler<ARGB8_Host, unsigned, 0,1,0,1>` (afininis, kraštai prispausti) | 0x183721014 | 0057 | Unicorn, 200 atvejų, 0 skirtumų |
| 11 | vImage `vAlpha_Blend_Premultiplied_BGRA_8888_CV_vec` (iš anksto padaugintų BGRA vaizdų maišymas: NEON ciklas pirmiems `width & ~7` taškams, skaliarinis likusiems) | 0x19baecff4 | 0076 | Unicorn, 300 atvejų, 10878 taškai, 0 skirtumų |
| 12 | `Blend::Mode<Sover, true>::blend` (vienos eilutės „source over“, apvalkalas aplink 11-ąją, be vImage gijų ir QoS užklausų) | 0x18370c1e8 | 0077 | ta pati formulė kaip 11 (vienai eilutei) |
| 13 | `scanline` ciklas, kuris iš anksto padaugintus taškus paverčia nepermatomais (spalva / alfa, `float`) | 0x18370621c (ciklo vidus) | 0078 | Unicorn, 38824 taškai, 0 skirtumų |
| 14 | `scanline` ciklas: šviesumas per kubinę kreivę ir taško artinimas prie tos pilkos (spalvų sodrumo efektas už suliejimų) | 0x183706fcc (ciklo vidus) | 0079 | Unicorn, 9279 taškai, atsitiktiniai koeficientai, 0 skirtumų |
| 15 | `sample_texture` (rastrizatoriaus eilutės paruošimas: `SamplerData`, samplerio parinkimas, „alfa pirma“ perstumdymas); natyvus sampleris (3, 4, 5, 7, 10) kviečiamas tiesiai, kitaip hiperkvietimas atlieka pakeistą prologą ir kodas tęsiasi | 0x183707e14 | 0082 | Unicorn iki samplerio kvietimo: 3000 atvejų, 0 skirtumų |

Puslapių talpykla (`0055`): hiperkvietimai adresą verčia kartą puslapiui, o ne kiekvienam pikseliui; jų laikas emuliuotų procesorių laike sumažėjo nuo ~2,8 % iki ~1,4 %.

Išmatuota (CI, braukiant): `image_sampler<ARGB8_Host, 1,1,1,1>` emuliuotų procesorių laike
nukrito nuo ~3,3 % iki ~0,4 %. Su 3 ir 4–6 numeriais emuliuotas iOS piešia taip pat, kaip
be jų (užrakinimo ir pagrindinio ekrano, Settings ekrano nuotraukos).

Laiko skaitymas (`mach_absolute_time`, `mach_continuous_time`, ~3,6 %) nėra klaida:
`isb; mrs cntvct_el0`, kviečiama labai dažnai. Hiperkvietimas čia nepadėtų.

`SamplerData` (iš kodo): `+0x00` tekstūra, `+0x10`/`+0x18` rodyklės į `w` ir `dw` (`+0xc`),
`+0x30` kraštų režimas, `+0x34/+0x38` u ir du, `+0x3c/+0x40` v ir dv (16.16), `+0x54..+0x60`
režimų koeficientai. Tekstūra: `+0x00` pikseliai, `+0x10` eilutės ilgis baitais, `+0x18/+0x1c` plotis
ir aukštis, `+0x20/+0x24` didžiausios koordinatės (16.16), `+0x28/+0x2c` mastelis.

Profilis braukiant (prieš šiuos pakeitimus): branduolys apie 75 % emuliuotų procesorių laiko,
programos apie 25 %. Iš programų laiko visas QuartzCore piešimas sudaro apie 6–8 % viso laiko,
iš to šios keturios funkcijos apie 5 %.

## 4. Planas

1. Dažniausiai naudojamas sampler funkcijas (pagal profilį `image_sampler` variantus ir
   `tex_color_matrix`) perrašyti C kalba emuliatoriuje taip, kad rezultatai sutaptų bitas į bitą, ir
   nukreipti per hiperkvietimą. Tikrinti, ar ekrano kadrai sutampa su programiniu piešimu.
2. Perimti visą `draw_elements`: piešimo būseną ir trikampius perduoti emuliatoriui, o šis
   piešia per Metal tiesiai į svečio paviršių.
