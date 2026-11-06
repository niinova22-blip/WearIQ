# Size systems: Türkiye, Europe, United States

How clothing sizes are written in the three markets WearIQ serves, which body
measurement decides each one, and how the app uses this. Code:
`WearIQKit/Sources/ProductMeasurementParser/SizeSystems.swift` (ladders and
conversions), `StandardSizeCharts.swift` (the body behind each label),
`SizeOrder.swift` (`SizeLabel`, W/L parsing), `SizeOptions.swift` (reading a page's
size selectors) and `ModelFitParser.swift` (the model's sizes).

## The European standard: EN 13402 (TS EN 13402 in Türkiye)

- A size names the **body** it fits, in centimetres, not the garment's measurements.
- Every garment type has one **primary dimension** that the label follows, and may add
  one or two secondary ones in brackets:
  - tops, knitwear, jackets, coats, dresses: **chest/bust girth** (height secondary);
  - trousers and jeans: **waist girth**, with **inside leg** as the secondary;
  - women's skirts and trousers: waist, with **hip girth** often the deciding one;
  - shirts: neck girth (collar 37–46 cm) alongside letters;
  - children: body height (104, 110, 116 …).
- Letter sizes (XS–3XL) are a coarse layer over these: men's steps are about 8 cm of
  chest, women's about 4–8 cm.

## The labels per market

| Garment | Türkiye | Europe | United States |
|---|---|---|---|
| T-shirts, shirts, knitwear, jackets, coats | XS–XXL | XS–XXL | XS–XXL |
| Women's dresses and skirts | 34–46 (36 = S, 38 = M, 40 = L) | 34–46 (FR/ES numbering; DE is 2 lower, IT 4 higher) | 0–16 (US 4 = EU 36, US = EU − 32) |
| Women's trousers | 34–46 | 34–46 | 0–16 |
| Jeans, men and women | W/L in inches: 31/32 | W/L: W31 L32 | W/L: 31×32 |
| Men's non-denim trousers | 44–58 (48 ≈ waist 82–88 cm) | 44–58 | W/L inches |
| Men's suits and blazers | 44–58 (chest ÷ 2) | 44–58 | chest in inches (38, 40, 42) |

- **W/L**: W is the waist in inches (W32 ≈ 81 cm), L the inside leg in inches
  (L32 ≈ 81 cm). Stores in all three markets sell jeans this way; Mavi, Levi's, LTB,
  Diesel list each waist with each length as separate variants.
- **Women's 34–46** grow about 4 cm of bust, waist and hip per size: 36 is bust 84,
  waist 68, hip 92.
- Brands differ by about a size either way. A store's own size table always beats
  these typical values; the app says so when it falls back on them.

## What the app does with it

- **Recommendations use the store's own labels**, because that is what is bought. On
  Mavi's jeans that is "31/32", never the "L" of the T-shirt the model wears with them.
- **Profile → Size system** (Automatic, Türkiye, Europe, United States). Automatic
  follows the app's language: Turkish → Türkiye, English → Europe, English on a US
  device → United States.
- When a store lists **no sizes**, the typical sizes of the user's system are compared
  (`SizeSystems.ladder`): W/L for jeans, 34–46 or 0–16 for women's dresses and
  trousers, 44–58 for men's trousers in Türkiye and Europe.
- When the store's label is in **another system** (a US store's "6"), the result shows
  it in the user's: "In your size system: TR 38" (`SizeSystems.equivalent`, matched by
  the body each size fits).
- The **size passport** lists the user's sizes in their system.

## Pages with more than one size on them

A product page often carries sizes that aren't the product's:

1. **The model's other garments.** "Erkek Manken: Jean: Bel 31 / Boy 32, Üst: L": the
   jeans are 31/32, the top L. `ModelFit` keeps `topSize` and `bottomSize`, and a
   pair of trousers is anchored on the bottom size only.
2. **Two models.** Mavi lists a woman's and a man's body, then who wears what. Each body
   line is matched to its named model by order; the model of the product's audience
   is used, and with two and no audience, neither.
3. **Who it's for.** The product's name, the store's department (breadcrumb), the link,
   then the description, in that order. A text naming both ("kadın ve erkeklerin
   kullanımına uygun unisex") decides nothing.
4. **Hidden and recommended products.** Mavi keeps an Insider "Beden Seç: XS S M L"
   sheet for a recommended T-shirt hidden on its jeans pages, and carousels list other
   products' sizes. Only visible selectors outside recommendation widgets, carousels,
   filters and quantity pickers are read (`SizeOptions.script`, also in the Safari
   extension's `content.js`).
5. **Other products' variants in script data.** Mavi's page state holds the W/L rows of
   every jeans on the page; only the rows whose barcode is one of the product's own
   (JSON-LD `gtin13`) count.
6. **Size guides with several tables** (tops and jeans, men and women): the table with
   the garment's measurements (waist/inside leg for trousers, chest for tops) and a
   title for its audience wins (`SizeTableReader.best(_:fit:category:audience:)`).
7. **Model waist vs jeans waist.** A model's waist is taken at the narrowest point, well
   above where jeans sit, so inch-sized trousers are not shifted to it.

## Sources

- EN 13402-2 primary and secondary dimensions: BSI, "Size designation of clothes —
  Primary and secondary dimensions"; summary at apparelsearch.com/definitions
  (EN 13402 European Clothing Size Standard).
- Turkish women's sizes (34–46, 36 = S): sorubak.com "Bedenimi nasıl ölçeceğim?".
- EU/US women's conversion (US = EU − 32, bust/waist per size): fashion-era.com,
  size.ly international conversion charts, Urban Outfitters size charts.
- Men's trousers: egitimsistem.com "Kot ve kumaş pantolon beden karşılaştırma",
  gents.nl trouser size chart (EU 46 ≈ W30–W32; sources differ by a size).
