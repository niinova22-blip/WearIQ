# Ölçüm ve beden önerisi doğrulama protokolü

WearIQ, bu protokolle ölçülmüş bir doğruluk sonucu olmadan hiçbir yerde
"±X cm hassasiyet" iddia etmez.

## 1. Referans veri seti (vücut ölçümü)

- **Katılımcı:** En az 60 kişi. Cinsiyet, boy (155–200 cm) ve beden (XS–3XL) dengeli dağılmalı.
- **Referans ölçüler:** Eğitimli bir ölçücü, ISO 8559-1 noktalarına göre esnemeyen mezurayla
  her ölçüyü 2 kez alır. İki ölçüm arasında fark > 1 cm ise üçüncü ölçüm alınır ve medyan kullanılır.
  Ölçülenler: boy, omuz (akromiyon–akromiyon), kol (akromiyon–bilek), göğüs, bel, kalça,
  uyluk, gövde (C7–bel), iç bacak, dış bacak.
- **Tarama:** Her katılımcı uygulamayla 3 kez tarama yapar (farklı ışık ve kıyafet koşullarında: dar spor kıyafeti / normal tişört).
- **Saklama:** Fotoğraflar yalnızca açık yazılı onamla ve şifreli olarak tutulur. Analizden sonra silinir.

## 2. Metrikler (ölçü başına)

| Metrik | Anlamı |
|---|---|
| MAE (cm) | Ortalama mutlak hata |
| Bias (cm) | Sistematik sapma, kalibrasyon katsayılarını düzeltmek için kullanılır |
| P90 hata | Kullanıcıların %90'ının hatası bunun altında kalır |
| Tekrarlanabilirlik | Aynı kişinin 3 taraması arasındaki standart sapma |
| Kapsama | Gerçek değerin, uygulamanın gösterdiği ±1σ aralığında kalma oranı (hedef ≈ %68) |

**Kapsama**, belirsizlik değerlerinin dürüst olup olmadığını gösterir. Bu oran %68'in çok altındaysa
`BodyMeasurementEngine.Calibration` içindeki hata katsayıları artırılır.

## 3. Kalibrasyon

`BodyMeasurementEngine.Calibration` (omuz katsayısı, çevre şekil katsayıları, derinlik oranları)
veri setinin %70'i üzerinde en küçük kareler yöntemiyle ayarlanır. Kalan %30 yalnızca raporlama için kullanılır.

## 4. Beden önerisi doğrulaması

- 20 katılımcı × en az 5 ürün (gömlek, tişört, ceket, pantolon). Her ürünün 2–3 bedeni gerçekten denenir.
- Katılımcı her bölge için "dar / ideal / bol" değerlendirmesi yapar ve tercih ettiği bedeni seçer.
- **Metrikler:** Önerilen bedenin seçilen bedenle eşleşme oranı, bölgesel karar doğruluğu
  (karışıklık matrisi), "arada" denilen durumların oranı.
- `EaseTable` içindeki bolluk payı aralıkları bu sonuçlarla ayarlanır.

## 5. Otomatik testler

`WearIQKit/Tests` içindeki birim testleri matematiği ve kuralları doğrular, gerçek dünya doğruluğunu
doğrulamaz. Gerçek doğruluk yalnızca bu protokolle ölçülür.

## 4. ANSUR II ile motor doğrulaması (otomatik test)

`WearIQKit/Tests/BodyMeasurementEngineTests/AnsurValidationTests.swift`, ABD Ordusu'nun
ANSUR II ölçüm araştırmasını (2012, kamu malı, 4.082 erkek + 1.986 kadın, mezura ve kumpasla
ölçülmüş; https://www.openlab.psu.edu/ansur2/) kullanır. Veri dosyaları testin `Data/`
klasöründedir.

**Yöntem:** Her kişinin göğüs, bel ve kalça kesiti; ANSUR'daki önden genişlik, yandan derinlik
ve mezura çevresine birebir uyan bir süperelips (|x/a|ⁿ + |y/b|ⁿ = 1) olarak modellenir. Göğüs
mezurası sırt kaslarının üzerinden geçtiği için kumpas genişliğinin izin verdiğinden büyükse,
yuvarlatılmış kutu biçimi (n = 4) oranı korunarak büyütülür. Sonra 8 duraklı dönüş bu kesitler
üzerinde simüle edilir: her durak ±15° rastgele sapmalı, her genişlik %1,5 silüet gürültülü.
`StationScan` sonucu mezura değeriyle karşılaştırılır.

**Sonuç (6.068 kişi):**

| Bölge | Bias | Ortalama mutlak hata | %95'lik hata | Eski önden+yandan elips |
|---|---|---|---|---|
| Göğüs | −%0,99 | %1,28 | %3,20 | bias −%17,5 |
| Bel | −%0,25 | %0,98 | %2,43 | bias −%5,3 |
| Kalça | −%0,46 | %1,09 | %2,77 | bias −%8,4 |

Test, bias %1,5'i veya %95'lik hata %4'ü aşarsa başarısız olur.

**Makullük kontrolü:** Boy/kilo istatistiklerinin (3σ) doğru bir okumayı (±%3) yanlışlıkla
reddetme oranı bütün ölçülerde %0,2'nin altındadır (test eşiği %2).

**Sınırları:** Bu simülasyon motorun geometrisini ve duraklardaki açı hatalarına
dayanıklılığını doğrular; kamera, segmentasyon ve kıyafet kaynaklı hataları ölçmez. Onlar için
1–3. bölümlerdeki gerçek kişili protokol gerekir. Amazon'un BodyM veri seti (önden ve yandan
silüet + ölçü, 2.505 kişi) bu açığı kısmen kapatabilir, ancak lisansı (CC BY-NC 4.0 / CC BY 4.0
belirsizliği) ticari kullanım için netleşmeden kullanılmamalıdır.
