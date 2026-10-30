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

**Sonuç (6.068 kişi):** Kalibrasyon öncesi bias göğüste −%0,99, belde −%0,25, kalçada −%0,46
idi (8 yön, köşeli kesitlerin ortalama genişliğini biraz eksik örnekler). `StationScan.calibration`
bu sapmayı giderir. Kalibrasyon sonrası:

| Bölge | Bias | Ortalama mutlak hata | %95'lik hata | Eski önden+yandan elips |
|---|---|---|---|---|
| Göğüs | −%0,02 | %1,16 | %2,93 | bias −%17,5 |
| Bel | −%0,02 | %0,96 | %2,42 | bias −%5,3 |
| Kalça | −%0,01 | %1,04 | %2,58 | bias −%8,4 |

Test, bias %0,5'i veya %95'lik hata %4'ü aşarsa başarısız olur.

**Makullük kontrolü:** Boy/kilo istatistiklerinin (3σ) doğru bir okumayı (±%3) yanlışlıkla
reddetme oranı bütün ölçülerde %0,2'nin altındadır (test eşiği %2).

**Sınırları:** Bu simülasyon motorun geometrisini ve duraklardaki açı hatalarına
dayanıklılığını doğrular; kamera, segmentasyon ve kıyafet kaynaklı hataları ölçmez. Onlar için
1–3. bölümlerdeki gerçek kişili protokol gerekir. Amazon'un BodyM veri seti (önden ve yandan
silüet + ölçü, 2.505 kişi) bu açığı kısmen kapatabilir, ancak lisansı (CC BY-NC 4.0 / CC BY 4.0
belirsizliği) ticari kullanım için netleşmeden kullanılmamalıdır.

### Yöntem karşılaştırması (ANSUR II, her üç kişiden biri, aynı simülasyon)

| Yöntem | Göğüs MAE | Bel MAE | Kalça MAE |
|---|---|---|---|
| 8 durak (kullanılan) | %0,99 | %1,03 | %1,09 |
| 4 durak (yalnızca 180°) | %1,27 | %1,43 | %1,51 |
| Önden + yandan genişlikten regresyon (boy, kilo, cinsiyet ile; çapraz doğrulamalı) | %1,51 | %1,22 | %1,09 |

Silüet genişliği karşıdan aynı göründüğü için 4 durak teoride yeterlidir, ancak durak
hatalarının ortalaması daha az alındığından ~%40 daha hatalıdır. 8 durak tutuldu.

### İskeletten ölçek (`JointHeights`)

Vision eklemlerinin boy oranları ANSUR II işaret noktası yüksekliklerinden alınmıştır: ayak bileği
0,040 (lateral malleol), diz 0,279 (femur epikondili), kalça eklemi 0,52 (trokanterin biraz
üstü), omuz eklemi 0,80 (akromiyonun ~%2 altı), boyun 0,818 (suprasternale). Bu oranlar
kişiler arasında boyun yaklaşık %1'i kadar değişir. Eklemlere oturtulan doğru, boyu ve zemini
piksel cinsinden verir. Eklemler arasındaki uzunluklar (omuz, kol, gövde, iç/dış bacak) bu
ölçekle hesaplanır; maskenin saç, gölge ya da bol kıyafet yüzünden taşması onları bozamaz.

**Doğrulama:** Her kişinin eklemleri kendi ANSUR yüksekliklerine (1 cm algılama gürültüsüyle)
yerleştirildiğinde iskeletten bulunan boy: bias −%0,14, ortalama mutlak hata %1,01, %95'lik
hata %2,45 (6.068 kişi).

Göğüs, bel ve kalça seviyeleri de iskeletten konur: ANSUR'un nüfus yükseklikleri (göğüs 0,728,
göbek 0,601, kalça 0,507), kişinin kendi kalça ve omuz eklemleri arasına gerilerek.


## 6. Kıyafetli taramalar (Clothed scans)

Günlük kıyafetle tarama `ClothingAwareReconstruction` ile yapılır: silüet çevresi = vücut + kıyafetin eklediği pay. Pay, kıyafet türüne göre bir olasılık dağılımı olarak modellenir (`EaseModel`). Vücut değeri Bayes kuralıyla, silüet, bu dağılım ve boy/kilo istatistiği (ya da kişinin yakın tarihli dar kıyafetli veya mezura ölçüsü) birleştirilerek bulunur. Sabit bir santimetre düşülmez. Sonuç her ölçü için şunları içerir: değer, %90 aralık, olası kıyafet türü ve kıyafetin eklediği tahmini pay.

**Durum: kalibre edilmedi.** Kıyafet payı dağılımları başlangıç değerleridir:

- Kaynakları: `EaseTable`'daki tasarım payları ve iki cihaz taraması (bol tişört: bel +10 cm; kazak: +13/+15/+7 cm).
- Gerçek eşli veriyle ayarlanana kadar günlük kıyafetli taramalar için doğruluk iddiası yapılmaz.
- Otomatik testte (`intervalsCoverTheTruthOnSimulatedClothedScans`) %90 aralıkların, modelden üretilen sentetik veride %85–95 kapsadığı doğrulanır. Bu yalnızca hesabı test eder, modelin gerçeğe uygunluğunu değil.

### Eşli veri protokolü

1. **Kişiler ve referans:** En az 30 kişi, her biri mezurayla ölçülür (ISO 8559-1 noktaları: göğüs, bel, kalça, uyluk).
2. **Taramalar:** Her kişi şu gruplarda ikişer kez taranır: `skin` (iç çamaşırı), `fitted` (dar spor kıyafeti), `tshirt` (normal tişört), `shirt` (gömlek), `loose` (bol tişört), `loosetrousers` (bol pantolon), `thick` (kalın), `layered` (katmanlı).
3. **Kayıt:** Sonuçlar `subject,group,dimension,scanned,low,high,tape` başlıklı CSV'ye yazılır.
4. **Puanlama:** `ScanValidation.score` grup ve ölçü başına şunları hesaplar: ortalama mutlak hata, sapma, hata dağılımı (SD, 95. yüzdelik), tekrar tarama tutarlılığı, başarısızlık oranı ve %90 aralığın mezura değerini kapsama oranı.
5. **Raporlama:** Normal kıyafetli grupların hatası, dar kıyafetli gruplarınkiyle karşılaştırılarak ayrıca raporlanır.

### Kalibrasyon

- **Pay dağılımları:** Her kıyafet türü için `EaseModel` ortalaması ve SD'si, eşli veride gözlenen `(silüet − mezura) / mezura` değerlerinden yeniden kestirilir.
- **Kapsama hedefi:** %90 aralığın kapsama oranı 0,85–0,95 arasında olmalıdır. Altındaysa SD büyütülür, üstündeyse küçültülür.
- **Silüet hatası:** `outlineRelError` (%3), `skin` grubunun mezura hatasından yeniden ölçülür.

## 7. Kumaş simülasyonu

- **Çözücü:** `TriangleCloth`, XPBD ile çalışır. Kenarlar esneme uyumluluğuyla, bükülme kumaşın dökümünden gelen uyumlulukla çözülür. Her köşe kumaş ağırlığından kütle alır. Vücuda çarpışmada sürtünme uygulanır ve kumaşın kendi kendisiyle çarpışması uzamsal bir hash ile ayrılır.
- **Testler (`FitReportTests`):** Bölgeler drapeden hesaplanır. Aynı tişörtün S, M ve L bedenleri farklı gerilim verir (S göğüste çok dar, M rahat, L bol). Esnek kumaş aynı kesimi daha rahat taşır. Belirsiz bel, bel bölgesinde bir sonuç aralığı üretir.
- **Doğrulanmamış:** Gerilme eşikleri (konforlu esnemenin %30, %60 ve %100'ü) gerçek deneme sonuçlarıyla karşılaştırılmadı. Beden önerisi doğrulaması (bölüm 4) simülasyon için de yapılmalıdır: aynı kişi M ve L bedeni gerçekten dener ve simülasyon kararıyla karşılaştırılır.
