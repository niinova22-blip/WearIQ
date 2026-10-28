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
