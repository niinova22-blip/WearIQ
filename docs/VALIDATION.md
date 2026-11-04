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

## 8. Ölçüm iyileştirmeleri (2026-10-30)

- **Duruş başına üç kare:** Her durakta 150 ms arayla üç fotoğraf ölçülür ve seviye başına ortanca genişlik alınır. Tek karedeki segmentasyon kayması sonucu belirlemez. Cihazda henüz ölçülmedi.
- **Ölçüler arası ilişki** (`GirthCorrelations`, `scripts/fit_correlations.py`): Boy, kilo ve BMI'dan sonra kalan farklar ölçüler arasında kısmen ortaktır. Uyluk ve detay çevreleri, ölçülen göğüs/bel/kalçaya göre koşullanır. ANSUR II'de (6.068 kişi, kalça ve bel %1,5 gürültüyle ölçülmüş varsayımıyla) uyluk ortalama mutlak hatası 1,77'den 1,49 cm'ye, baldır 1,29'dan 1,22 cm'ye düşer. Bel için kazanç küçüktür (3,5 → 3,4 cm), bu yüzden belde kullanılmaz.
- **Yalınayak uyarısı:** Ölçek girilen boydan gelir. Ayakkabı veya kabarık saç silüet yüksekliğini artırır ve tüm genişlikleri küçültür (örneğin 3 cm ayakkabı ≈ %1,7). Tarama rehberi yalınayak ve saç toplu taramayı ister.
- **Araştırılıp uygulanmayanlar:**
  - LiDAR/derinlik: kullanıcının iPhone 11'inde yok.
  - SMPL: ticari lisans doğrulanmadı.
  - Yumuşak maske ile alt-piksel kenar: `BinaryMask` boru hattının cihazda yeniden doğrulanmasını gerektirir.
  - Öğrenilmiş görüntüden-ölçü modeli: eğitim verisi yok.

## 9. Kumaşın giydirilmesi (animasyon)

- **Yöntem:** Kıyafet 8 cm yukarıdan bırakılır. Tutma noktaları (omuz, bel bandı) 0,4 s içinde yerine iner. Kumaş yerçekimiyle düşer, sallanır ve oturur: 2 s, adım başına 0,985 hız korunur. Kareler 30 fps kaydedilir ve avatar ekranında oynatılır.
- **Testler (`DressingTests`):**
  - Kıyafet en az 5 cm aşağı iner.
  - İlk karelerdeki hareket, son karelerdekinin 5 katından fazladır.
  - Son kare bitmiş kıyafettir ve vücudun içine girmez.
- **Süre:** Masaüstü CPU'da, release derlemede tam çözünürlükte 1,9 s (animasyonsuz 0,6 s). iPhone süresi ölçülmedi.

## 10. Sesli yönlendirme

Taramanın sabit cümleleri önceden kaydedilmiş seslerdir (`WearIQ/Resources/Voice`, `scripts/generate_voice.py`).

- **Motor:** Chatterbox Multilingual (Resemble AI, MIT lisansı). Çıktılarında Resemble'ın duyulmaz Perth filigranı vardır.
- **Kontrol:** Her cümle üç kez üretilip Whisper large-v3-turbo ile geri yazıya çevrildi, en iyi okuma tutuldu (2026-10-31). 106 klibin hepsi %12 karakter hatasının altında, en kötüsü %8 (bkz. `scripts/voice_manifest.json`). Sayılar yazıyla okunuyor ("kırk beş"). Türkçe daha yavaş ve sakin ayarlarla üretiliyor.
- **Yedek:** Klibi olmayan metin (hata ayrıntısı gibi) sistem sentezleyicisiyle okunur.

## 11. Omuz genişliği ve uyum haritası (2026-10-31)

- **Omuz tanımı:** Tarama, iki omuz kemiği arasındaki düz mesafeyi (biakromiyal genişlik) ölçer. Kıyafet tabloları ise omzu sırtın üzerinden, dikişten dikişe verir. Bu ikisi doğrudan karşılaştırılınca her gömleğin omzu ~4 cm geniş, yani "bol" çıkıyordu.
  - Taranmış ya da tahmin edilmiş omuz değeri artık 1,085 ile çarpılıyor. Oranın kaynağı ANSUR II ortalamaları: interscye (sırt üzeri) / biakromiyal, erkek 45,0/41,6, kadın 39,6/36,5.
  - Bu oran kişiden kişiye değişiyor; belirsizliğe ±1 cm eklendi.
  - Mezurayla girilen değer (uygulama zaten sırt üzerinden ölçtürüyor) olduğu gibi kullanılıyor.
  - Test: `ScannedShoulders`.
- **Uyum renkleri (`FitTone`):** Mavi tam, sarı bol, kırmızı uzun, mor dar, turuncu kısa.
  - Mor (dar): yalnızca vücuda değen ve kumaşın rahat esnemesinin %60'ını aşan yerler.
  - Sarı (bol): normal bir kesimin payından (gövdede 2,5 cm, pantolon bacağında 3,2 cm) daha uzak duran kumaş.
  - Kırmızı/turuncu: bilek, normal etek boyu ve bilek kemiği referanslarına göre.
  - Bu eşikler kalibre edilmedi.
- **Uyum çizgileri:** Omuz dikişi (omuz ucundan koltuk altına inen kol oyuğu düzlemi), kol ucu, etek ve paça, bel bandı. Olması gereken yer beyaz kesikli çizgiyle gösteriliyor. Test: `FitLinesTests`.
- **Sallanma:** Avatar çevrilirken kıyafet sönümlü bir yay gibi (~1,2 Hz, sönüm oranı 0,22) geride kalıp geri salınıyor. Her köşe kendi `sway` ağırlığı kadar dönüyor: askı noktasında 0, bol bir etekte 1'e kadar. Bu tam bir kumaş simülasyonu değil, GPU'da yapılan bir görsel yaklaşık.
- **Simülasyon belirliliği:** Kumaş kısıtları artık sabit sırada çözülüyor. Önceden sözlük sırası her çalıştırmada değiştiği için aynı kıyafet ±0,1 farklı gerilim verebiliyordu.

## 12. Tarama çerçevesi (2026-10-31)

- Telefon dik tutulduğunda görüntü 9:16'dır. Kollar yana açıkken kol açıklığı boya yakın olduğu için, vücut görüntü yüksekliğinin ~%50'sinden büyükse eller yanlardan taşar. Önceden önden konumlanmada %66'ya kadar izin veriliyordu, bu yüzden dönüşte eller kesiliyor ve dönüş açısı yanlış okunuyordu.
- Artık konumlanma burun–bilek mesafesini görüntünün %34–45'inde tutuyor.
- Dönüşte önce sırayla tam görünürlük, sonra kenarlardan taşma kontrol ediliyor (`StopGuide.cutEdges`, test `FramingTests`).

## 13. Filme alınan dönüşün her karesi (2026-11-02)

10 saniyelik dönüş saniyede 10 kare ile yaklaşık 100 kare verir. Önceden bu karelerden yalnızca 8 yön seçiliyor, her yönün çevresindeki karelerin medyanı alınıyordu. Artık `TurnRecording.girths` her kareye kol açıklığından bulunan açıyı veriyor (45° geçişleri, yanlar ve sırt düğüm noktası). Ardından seviye başına genişlik–açı eğrisine çift harmoniklerden (2θ, 4θ, 6θ) oluşan bir eğri Huber ağırlıklı en küçük karelerle oturtuluyor. Eğriden 3σ'dan fazla sapan kareler dışarıda bırakılıyor. Cauchy formülüne göre çevre, π × ortalama genişliktir; bu da eğrinin sabit terimidir. Bu yüzden düzensiz dönüş hızı sonucu kaydırmaz.

Simülasyon (`FilmedTurnValidationTests`): ANSUR II'deki her üç kişiden biri (n=2.023). 8–12 saniyelik düzensiz dönüş, başta ve sonda bekleme, %2 maske gürültüsü ve her 20 karede bir %5–15 genişlemiş kare var.

| Seviye | 8 yön: sapma / ort. hata / %95 | Her kare: sapma / ort. hata / %95 |
|---|---|---|
| Göğüs | +0,45% / 0,73% / 1,46% | +0,01% / 0,26% / 0,65% |
| Bel | +0,83% / 0,85% / 1,75% | +0,01% / 0,28% / 0,69% |
| Kalça | +0,93% / 0,94% / 1,86% | −0,00% / 0,29% / 0,71% |

Kötü kayıtta (%4 gürültü, her beş karede bir genişlemiş kare) ortalama hata 8 yönde %1,9, her karede %1,2 çıkıyor. Gürültü içinde kalan genişlemiş kareler ayırt edilemediği için %1,2'lik bir sapma kalıyor; bu yine de 8 yönün %1,9'undan az. İki yöntem %6'dan fazla ayrışırsa uygulama 8 yönün değerini kullanıyor.

Sınır: bu, karelerin rastgele hatasını ölçer. Maskenin her karede aynı yönde yaptığı hatayı (kıyafet, saç, ölçek) ölçmez; onu ancak mezura eşli veri gösterir (§6).

## 14. 100 kullanıcılık denetim, kesim mantığı ve yandan ek çekim (2026-11-02)

**Popülasyon denetimi** (`PopulationAudit`): ANSUR II'den rastgele 50 erkek ve 50 kadın seçildi. Ölçümlerin yarısı mezuradan (±1 cm), yarısı taramadan (±2,5 cm, omuz kemikten kemiğe) geliyor. Her kullanıcının sevdiği bir üst kesimi (slim, regular, relaxed, oversize) ve paça kesimi (skinny, slim, boru, geniş, ispanyol, daralan) var. Her kullanıcı üç tür mağazadan 7–8 ürün alıyor: ölçü tablolu, vücut tablolu, tablosuz (yalnızca manken bedeni ve boyu bilinen). Toplam 750 ürün, her bedeni denetlendi.

Her bedende şunlar kontrol edildi:
- Büyük beden hiçbir bölgede daha dar ya da kısa değil.
- Avatar, tablonun vermediği ölçüleri bedenle birlikte büyütüyor.
- Avatarın kararı tablonunkiyle aynı.
- Önerilen bedenin kritik bölgesi (göğüs ya da bel), daha büyük bir beden oraya uyarken dar çıkmıyor.
- Kesim notu aynı bedeni öneriyor.

Ayrıca 35 gerçek giydirmede renklerin, bölge raporunun ve kenar yerleşimlerinin tabloyla tutarlılığına bakıldı.

İlk çalıştırmada bulunan ve düzeltilen hatalar:
- **Tablosuz ürünlerde kol ve boy.** Mankenin boyundan bulunan kol ve boy her bedene aynı yazılıyordu; ±3,5 cm belirsizlik de toleransa ekleniyordu. Sonuç: M'den 2XL'e kadar her beden "kol ideal" çıkıyordu. Artık uzunluklar bedenle derecelendiriliyor (`Grading`: göğsün her cm'si için boy 0,3 cm, kol 0,2 cm). Belirsizlik de tolerans değil, güven olarak işleniyor.
- **Avatarda tablonun vermediği bölgeler.** Pantolon uyluğu, üst bel ve basen sabit kalıyordu. 40 beden pantolon belde ve basende bol, uylukta ve dizde "tam" görünüyordu. Artık hepsi tablonun verdiği bölgeden derecelendiriliyor. Bol basen bacak boyunca, bol göğüs kollarda da gösteriliyor.
- **Dar göğüslü beden önerisi.** Geniş omuz (dikişin kola düşmesi), dar göğüsten ağır cezalandırılıyordu. Basen ve uyluk bolluğu da kapanmayan belden ağır sayılıyordu. Bu yüzden 12 kullanıcıya dar beden öneriliyordu. Bolluk cezaları düşürüldü: omuzda 0,35, pantolon basen ve uyluğunda 0,4.
- **Kesime göre "dar" kelimesi.** Relaxed bir tişörtün 8 cm bollukla normal bir tişört kadar rahat olduğu halde "dar" denmesi düzeltildi. Kesim aralığının dışında ama gündelik bir kesimin aralığında kalan bir beden artık "kesiminden daha yakın" ya da "kesiminden daha bol" olarak adlandırılıyor (`byCutOnly`).

Düzeltmelerden sonra: 46.551 kontrolde 0 bulgu. Giydirme örnekleminde 201 kontrolde 0 bulgu.

**Kesim algılama.** Ürün adından kesim bulma genişletildi. Kadın modelleri: mom, boyfriend, palazzo, kuloş, kalem, bodycon, A kesim, kloş, pileli, evase, balon, paperbag. Erkek modelleri: muscle, comfort, kargo, carrot. Etek ve elbisede kalem, A kesim ve kloş avatarda eteğin açılmasını belirliyor.

**Maske temizleme** (`isolatingPerson`): kişi maskesine karışan sandalye, askı ya da kapı gibi nesneler ayıklanıyor. Yalnızca iskelete bağlı ve kemiklerin çevresindeki ölçeğe göre genişletilmiş kapsüllerin içinde kalan pikseller tutuluyor. Kapsüller boyun–kalça uzunluğuyla ölçeklendiği için mesafeden bağımsız; bol kıyafet ve etek için pay bırakılıyor.

**Yandan ek çekim** (`FollowUpShot`): dönüşten sonra göğüs, bel ya da kalçadan biri belirsiz kalırsa tek bir fotoğraf daha isteniyor. Belirsizlik ölçütü: ±%2,5'ten geniş olması ya da 8 yön ile her kare yönteminin %3'ten fazla ayrışması. Kullanıcı sağına çeyrek dönüp hareketsiz durduğunda fotoğraf otomatik çekiliyor. Bu net kare yan yönü ve karşısını temsil ediyor, dönüşün sonucuyla güven ağırlıklı birleştiriliyor. Simülasyonda bel hatasını yarıdan fazla azaltıyor (`FollowUpShotTests`).

## 15. 400 kişilik güven denetimi (2026-11-03)

### Araştırma: kullanıcının bu araca güvenmesi için ne gerekiyor?

- **İadelerin başlıca sebebi beden ve kalıp.** Coresight anketinde iade sebeplerinin %53'ü beden/kalıp. McKinsey (2021) giyim iadelerinin yaklaşık %70'ini kalıba ya da stile bağlıyor. Narvar (2019): ABD'li alışverişçilerin %48'i aynı ürünü birkaç bedende sipariş edip birini tutuyor ("bracketing").
- **Kullanıcı tek ve net bir cevap istiyor, ama dürüst olanını.** İki beden arasında kalmak, tablonun yazı-tura attırdığı yer. Etkili öneri, ürüne özel tek bir beden söyler. Zalando'nun kontrollü testinde (KDD 2021, grup başına 720 bin kullanıcı) beden önerisi bedenle ilgili iadeleri %3,8 azalttı. Satıcıların "%20–50 azalma" iddiaları bağımsız doğrulanmamış.
- **Kalıp tercihi bedeni değiştiriyor.** 175 kadınla yapılan bir çalışmada (3DBody.Tech 2023) tercih edilen oturuş, seçilen bedeni anlamlı şekilde etkiledi.
- **Avatar gerçekçiliği ve benzerlik güveni artırıyor.** Avatarın gerçekçiliği hem bilişsel hem duygusal güveni artırıyor (ITAA 2025). Kişinin kendine benzemesi satın alma niyetini artırıyor. Vücut şeklinde yaklaşık doğru bir temsil, yüz ve saç detayından daha önemli (Brunel tezi).
- **Vücut çeşitliliği.** ABD'li kadınların büyük kısmı büyük beden sayılıyor, ama yalnızca %24'ü kendini öyle tanımlıyor (Baymard 2026). Yorumlarda en çok aranan bilgi beden ve kalıp (%48). SizeUSA'da kadınların en yaygın vücut şekli dikdörtgen (~%49), ardından kaşık/armut. Kum saati yalnızca ~%8–12.

Buradan çıkan dört ilke testlere dönüştürüldü:
1. **Çelişki yok.**
2. **Doğru beden, açıkça söylenmiş.**
3. **Emin değilse bunu söylüyor.**
4. **Deneme kabini gibi tepki veriyor:** daha dar istersen daha büyük beden, esnek kumaşta daha büyük beden, daha iri vücuda daha küçük beden önerilmiyor.

### Nüfus (`Population`)

- **ANSUR II'den 240 kişi** (120 erkek, 120 kadın). Her ölçüsü mezurayla alınmış. BMI, boy ve basen−göğüs farkı boyunca eşit adımlarla seçildi, en uçlar dahil.
- **NHANES 2017–2020'den 160 kişi** (80 erkek, 80 kadın; ABD sivil nüfusu). Daha yaşlı ve daha kilolu, BMI 60'a kadar. Boy, kilo, bel ve basen ölçülmüş; diğer ölçüler ANSUR ilişkilerinden.

Toplam 400 kişi. BMI dağılımı: 18,5 altı 7, 18,5–25 arası 124, 25–30 arası 158, 30–35 arası 71, 35 üstü 40. Yaş 18–79, 21 kişi 60 yaş üstü. Kadınlarda beş vücut şekli var (dikdörtgen, armut, kaşık/alt kum saati, elma, ters üçgen), erkeklerde dört.

Her kişi üç şekilde biliniyor:
- mezura (referans),
- tarama (±2,5 cm gerçek gürültü eklendi),
- yalnızca boy ve kilo.

### Avatar vücudu kişinin ölçülerinde mi? (`PopulationBodyTests`)

Önce: şekil modeli (SOMA-X, 32 bileşen, ±3,5 SD) BMI 45 üstü vücutları 10–20 cm ince kuruyordu. Bir örnek: 161 cm beli olan kadın 141 cm çıkıyordu; giysiler de buna göre çiziliyordu.

Düzeltme (`SomaModel.body(for:)`): model sınırına geldiğinde gövde göğüs, göbek ve basen hizasında kendi merkezi etrafında, istenen÷çıkan oranıyla genişletiliyor. Bacaklar uyluk oranıyla genişliyor; dizde bu oranın yarısı kalıyor, bilekte hiç kalmıyor. Kollar göğsün yanıyla birlikte dışa kayıyor.

400 kişide sonuç:

| | Ortalama hata | En büyük hata |
|---|---|---|
| Göğüs | 0,03 cm | 0,40 cm (önce 20,1) |
| Bel | 0,11 cm | 0,46 cm (önce 20,4) |
| Basen | 0,03 cm | 0,34 cm (önce 13,9) |
| Uyluk | 0,03 cm | 0,34 cm (önce 16,4) |

En uç vücutlar render edilerek kontrol edildi (`RenderProbe/population`).

### Denetim (`PopulationAudit`)

- **Kapsam:** 400 kişi × 10 ürün = 4.000 ürün. Ürün tipleri: tişört, gömlek, kazak, ceket, kaban, elbise, etek, her paça kesiminde pantolon ve şort.
- **Kumaş:** her esneklikte.
- **Mağaza türleri:** ölçü tablolu, vücut tablolu (harf, EU ya da inç; 4XL/5XL dahil), tablosuz.
- **Ölçek:** 383.407 kontrol ve 385 giydirme (her tipten).

İlk çalıştırmada bulunan ve düzeltilen hatalar:
- **Kimseye uymayan ürün.** Çok zayıf ya da çok iri bir vücuda tablonun ucundaki beden "yüksek güvenle" öneriliyordu (207 bulgu). Artık güven düşük, başlıkta "İyi oturan beden yok · en yakını L" yazıyor ve açıklama başka marka ya da kesim öneriyor (`FitAnalysis.noSizeFits`).
- **Önemli bölgede uymayan beden.** Kolu kısa ya da beli bol olan beden yerine göğsü dar beden seçilebiliyordu (56 bulgu). Artık önemli bölgede (üstte göğüs, altta bel) uyan bir beden varsa, uymayan beden önerilmiyor.
- **Tablosuz kabanlar.** Kaban boyu vücut ölçüsü gibi yazılıyordu. Her beden "uzun" görünüyor, bu da öneriyi en küçük bedene itiyordu. Artık kabanın boyu stil sayılıyor, karşılaştırmaya girmiyor.
- **Standart tablonun aralığı.** Markanın ±2 cm sapması da tolerans sayılınca bedenler ±8,5 cm genişliyordu: 103 cm göğse 92'lik beden "biraz dar" deniyordu. Artık beden aralığı tolerans, marka sapması belirsizlik olarak işleniyor.
- **Kadın pantolonunda EU numaraları.** 36/38/40 inç olarak okunuyordu: 38 bedenin beli ~70 cm yerine 97 cm sanılıyordu. Artık çift ve 34'ün üstündeki numaralar EU, tek numaralar ya da 33'e kadar olanlar inç (W) olarak okunuyor. Kadın 3XL–5XL, erkek 4XL–5XL ve EU 56–60 tabloları eklendi.
- **Boy ve kiloyla tahmin.** "Yüksek güven" deyip mezuranın bulduğundan farklı beden öneriyordu (%34). Artık tahminden gelen öneri hiçbir zaman "emin" değil, ve kullanıcıya bunun yalnızca boy ve kiloya dayandığı, taramanın sonucu kesinleştireceği söyleniyor.
- **Taramadan gelen güven.** Güven, bölgenin uyma olasılığına göre hesaplanıyordu. Bu yüzden "emin" denen önerilerin %22'si mezuranınkinden farklıydı. Artık önemli ölçü kendi belirsizliği kadar oynatılınca önerilen beden değişiyorsa güven düşüyor: ±0,6σ içinde değişiyorsa düşük, ±1,6σ içinde değişiyorsa orta. "Emin" denip gerçek vücutta belirgin şekilde daha kötü olan beden oranı %0,8.

Düzeltmelerden sonra: 383.407 kontrolde 0 bulgu. Giydirmede 2.701 kontrolde 0 bulgu (kumaş vücudun içinde değil, uzun giysiler kalçanın altına iniyor).

Sonuçlar:

| | Hepsi | BMI 35+ |
|---|---|---|
| Bir beden göğse uyuyor (üst) | %96,4 | %76,7 |
| Bir beden bele uyuyor (alt) | %91,3 | %37,5 |
| Tarama, mezurayla aynı beden | %78,8 | %88,0 |
| Tarama, en fazla bir beden fark | %99,9 | %100 |
| Tarama, belirgin şekilde daha kötü beden | %7,2 | %4,0 |
| Yalnızca boy ve kilo, mezurayla aynı beden | %65,5 | %79,2 |
| Yalnızca boy ve kilo, belirgin şekilde daha kötü beden | %16,8 | %11,0 |

Ne söylüyor:
- Çok kilolu kullanıcılarda bel için çoğu zaman tabloda uyan beden yok. Uygulama bunu artık açıkça söylüyor.
- Boy ve kiloyla tahmin, altı üründen birinde belirgin şekilde daha kötü bir beden seçiyor. Taramanın değeri burada. Tahmin bu yüzden hiçbir zaman "emin" değil.

Sınırlar:
- NHANES kişilerinin göğüs, uyluk ve boy ölçüleri ölçülmüş değil, ANSUR ilişkilerinden tahmin.
- Mağaza tabloları üretildi; gerçek mağazalardan değil.
- Gevşeklik payları hâlâ mezura ve kullanıcı geri bildirimiyle kalibre edilmeli (§6).

Kaynaklar:
- [Coresight / 3DLOOK](https://3dlook.ai/content-hub/the-true-cost-of-apparel-returns/)
- [Zalando, Narvar özeti](https://www.size.ly/blog/ecommerce-return-statistics)
- [Baymard 2026](https://baymard.com/blog/apparel-and-accessories-quantitative-ux-insights-2026)
- [ITAA 2025 VTO güveni](https://www.iastatedigitalpress.com/itaa/article/id/18719/)
- [Brunel avatar tezi](https://bura.brunel.ac.uk/handle/2438/14433?mode=full)
- [3DBody.Tech 2023](https://proc.3dbody.tech/papers/2023/2360peng.pdf)
- [Virtusize](https://virtusize.com/articles/why-size-charts-alone-dont-solve-fit)
- [Kleep](https://kleep.ai/blog/size-charts-are-lying-to-your-customers)
- [SizeUSA vücut şekilleri](https://www.degruyterbrill.com/document/doi/10.1515/aut-2024-0021/html)

## 16. Ölçüleri yayımlanmış gerçek kişilerle karşılaştırma (2026-11-05)

Kaynak: Heinz, Peterson, Johnson & Kerk (2003), "Exploring Relationships in Body Dimensions", *Journal of Statistics Education* 11(2).
- 507 kişi: 247 erkek, 260 kadın.
- Fiziksel olarak aktif yetişkinler, yaş ortalaması 30.
- Mezurayla ölçülmüş 21 ölçü, boy ve kilo.
- ANSUR'dan bağımsız bir nüfus. Hiçbir modelimiz bu veriyle eğitilmedi.
- Lisansı net olmadığı için veri depoda yok. `PublicBodiesTests`, `BDIMS_CSV` ile yerel bir kopyayı okur (openintro.org/data/csv/bdims.csv).

Tanım farkları:
- Kadınların "göğüs" ölçüsü bu veride göğsün üstünden alınmış, o yüzden kadın göğsü karşılaştırılmadı.
- Uygulamanın beli göbek hizasında; karşılaştırmada verinin göbek çevresi (`nav_gi`) kullanıldı.

### Avatar gövdesi

Mezura ölçüleriyle kurulan avatar geri ölçüldüğünde her ölçüde ortalama hata 0,12 cm'nin altında kaldı. SOMA-X tabanlı gövde, gerçek kişilerin ölçü bileşimlerine ulaşabiliyor.

### Video dönüşü (simülasyon): bulunan hata ve düzeltme

Her kişinin gövdesi telefonun önünde dönerken filme alındı (`ScanSimulator`). Uygulamanın tarama yolu aynen çalıştırıldı: 8 yön, her kare, birleştirme.

| | Önce: ortalama hata (sapma) | Şimdi: ortalama hata (sapma) |
|---|---|---|
| Erkek göğüs | 5,45 cm (−4,60) | 1,53 cm (+0,25) |
| Erkek bel | 2,78 cm (−0,18) | 1,31 cm (+0,01) |
| Erkek basen | 3,39 cm (−3,02) | 1,22 cm (+0,31) |
| Kadın göğüs (gövde) | 2,97 cm (−0,07) | 1,25 cm (−0,01) |
| Kadın bel | 4,23 cm (−1,96) | 2,16 cm (−1,04) |
| Kadın basen | 2,59 cm (−1,65) | 1,17 cm (+0,13) |

Sebep (etkiler tek tek kapatılarak bulundu, `SCAN_OFF`): asıl kaynak kameranın perspektifi. Telefon 2–3 m uzakta ve kişinin ortasına eğik bakıyor. Bu etki kapatılınca erkek göğsündeki sapma −4,6 cm'den −1,0 cm'ye iniyor. Saç ve maske genişlemesi kısmen ters yönde çalışıyor.

Düzeltme (`LearnedGirthModel.correct`):
- Motor C, aynı karelerden her seviye için bir perspektif katsayısı çıkarıyor (C ÷ düz okuma).
- Bu katsayı 8 yönün, yandan ek çekimin ve her kare ölçümünün hepsine uygulanıyor; tarama kendi içinde tutarlı kalıyor.
- Katsayı ±%15'in dışındaysa C öğrendiği alanın dışında demektir; o seviye düz okumayla kalıyor.
- ANSUR'un ayrılmış test kişilerinde de sapma her seviyede 1 cm'nin altında (`LearnedGirthModelTests/productionScanWithPerspectiveCorrection`).

Karar: önceden 20 kişilik mezura doğrulaması bekleniyordu. Uygulama sahibi yalnızca kendini ölçebildiği için kural değiştirildi. Bağımsız nüfustaki bu kanıtla düzeltme üretime alındı. Gerçek telefondaki kontrol, sahibinin doğrulama modunda yaptığı kendi mezuralı taraması.

### Yalnızca boy ve kilo (tahmin)

| | Erkek: sapma / ortalama hata | Kadın: sapma / ortalama hata |
|---|---|---|
| Göğüs | −0,26 / 3,17 | (karşılaştırılamaz) |
| Bel (göbek) | +0,45 / 3,73 | −3,85 / 5,47 |
| Basen | +0,02 / 2,10 | +0,88 / 2,31 |
| Uyluk | +2,61 / 3,03 | +0,44 / 1,66 |
| Omuz (biakromiyal) | +0,10 / 1,41 | +0,06 / 1,18 |
| Önkol | +1,75 / 1,88 (düzeltildi) | +1,56 / 1,58 (düzeltildi) |

- **Önkol:** ANSUR önkolu kasılı ölçer, giysi ise gevşek kola göre dikilir. Üst kol bu yüzden düzeltilmişti, önkol unutulmuştu. Bu verideki farkla düzeltildi: erkekte −1,75, kadında −1,56 cm.
- **Kadın göbek çevresi:** bu veride yaşla birlikte büyüyor (18–25 yaşta −2,5, 35–50 yaşta −6,0). Göbek ile en ince bel arasındaki fark kadınlarda 12–17 cm, erkeklerde 2–4 cm. Bu, ölçümün göbekten aşağıda, leğen kemiği hizasında alındığını düşündürüyor. ANSUR ve NHANES'in toplam 10 binden fazla kişisiyle uyumlu modeli tek bir küçük veriyle kaydırmak yerine model değiştirilmedi. Tahminin belirsizlik aralığı (σ ≈ 7 cm) bu farkı zaten kapsıyor.
- **Erkek uyluğu:** büyük olasılıkla tanım farkı. ANSUR uyluğu kalça kıvrımının en alt noktasında ölçüyor, bu veri ise kıvrımın altında. Model değiştirilmedi.

### Ölçüleri yayımlanmış tanınmış kişiler (güvenilirliği düşük)

Kaynak ve kapsam:
- Bir ünlü ölçü sitesinden boy, kilo ve göğüs–bel–kalça değerleri yayımlanmış 70 kadın ve 4 erkek (`PUBLIC_FIGURES_JSON`, depoda değil).
- Değerler yuvarlanmış ve çoğu doğrulanmamış. Bel, en ince noktadan verilmiş.

Sonuçlar:
- **Avatar:** yayımlanan göğüs ve kalçayı 0,01 cm içinde kuruyor. Bunlara 61 cm bel / 89 cm kalça gibi kum saati vücutlar da dahil.
- **Yalnızca boy ve kilo:** kadınlarda kalçayı 4,9 cm büyük, göğsü 2,3 cm küçük tahmin ediyor. Tahmin ortalama insan içindir; manken ve oyuncu vücutları ortalamadan uzak. Taramanın gerekli olduğunu gösteren beklenen bir sonuç; model değiştirilmedi.
- **Bel:** göbek hizası tahmini, yayımlanan en ince belden 12,5 cm büyük.
  - Mezuralı veride de göbek ile en ince bel arasındaki fark kadınlarda 12–17 cm.
  - Kadın beden tablolarının "bel" sütunu çoğu zaman en ince yerden ölçülür. Uygulama ise bedeni göbek hizasında ölçüyor.
  - ANSUR'da en ince bel olmadığı için kanıtsız değişiklik yapılmadı.
  - Açık iş: taramada en ince beli ayrıca ölçmek ve kadın tablolarında onu kullanmak.
