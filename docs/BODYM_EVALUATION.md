# BodyM ile mevcut ölçüm motorunun karşılaştırması (2026-10-31)

**Karar: Senaryo D. BodyM kullanılamıyor; mevcut ölçüm motoru korunuyor.** Gerekçe aşağıda. Karşılaştırma altyapısı hazır (`ScanValidation.compare`). Gerçek mezura verisi gelince aynı kişiler üzerinde yeniden değerlendirilebilir.

## 1. Mevcut motor: her ölçü nasıl bulunuyor

**Ölçek:** Kullanıcının yazdığı boy cetvel olarak kullanılır.

- Genişlikler kişi maskesinin boyuna göre ölçeklenir.
- Uzunluklar Vision iskeletine oturtulan ANSUR II eklem yüksekliği oranlarıyla ölçeklenir (`JointHeights`). Böylece saç, gölge ya da bol kıyafet uzunlukları bozamaz.

| Ölçü | Kaynak | Yöntem |
|---|---|---|
| Göğüs, bel, kalça çevresi | **Görüntü** (8 durak) | Cauchy formülü: dışbükey kesitin çevresi = π × tüm açılardan ortalama genişlik. 8 durakta (45° aralıkla) o seviyedeki silüet genişliğinin ortalaması × π. Mezuranın dışbükey zarfı izlemesiyle aynıdır, kesit şekli varsayılmaz. Tek kare yedek yol: ön genişlik + yan derinlikle elips çevresi × düzeltme katsayısı. |
| Uyluk çevresi | Görüntü + istatistik | Uyluk seviyesindeki genişlikler. Görünmeyen kısım göğüs/bel/kalçaya koşullu ANSUR korelasyonuyla tamamlanır (`GirthCorrelations`). |
| Omuz genişliği | **Görüntü** (iskelet) | Vision omuz eklemleri arası × 1,10 (eklem merkezinden akromiyona). |
| Kol uzunluğu | **Görüntü** (iskelet) | Omuz→dirsek→bilek, iki kolun ortalaması × 1,05. İki kol uyuşmazsa belirsizlik büyür. |
| İç bacak | **Görüntü** | Silüette bacak arası ile zemin arası; bulunamazsa kalça eklemi yüksekliği × oran. |
| Gövde, dış bacak | Görüntü (iskelet) | Boyun–kalça ve kalça–zemin, ANSUR oranlarıyla. |
| Üst kol çevresi | Görüntü (kollar açıkken) | Kol kalınlığı; yoksa tahmin. |
| Ön kol, bilek, diz, baldır, ayak bileği, boyun | **Tahmin** | Boy, kilo ve BMI'dan ANSUR II + NHANES regresyonu (`AnthropometricPrior`); ölçülen çevrelere koşullu. Kesin ölçülmüş gibi gösterilmez, aralıkla verilir. |
| Kıyafetli taramada gövde çevreleri | Görüntü + kıyafet modeli | Silüet = vücut + kıyafet payı. Pay dağılımıyla Bayes birleştirmesi yapılır, %90 aralık verilir (`ClothingAwareReconstruction`). **Kalibre edilmedi.** |

Her ölçü değer, kaynak (`scan` / `manual` / `estimated`), belirsizlik (SD), %90 aralık, kıyafet durumu ve onay bilgisiyle saklanır (`MeasuredValue`, `MeasurementAssessment`). Aralığı geniş ölçüler için ilgili duraklar yeniden çekilir (`StationScan.stopsToRetake`).

## 2. BodyM: kaynak koddan bulgular

Depo: `Harshalnikumbh/bodym-measurement-estimation`. İçinde README, tek bir Colab not defteri ve bir örnek görsel var; toplam 53 KB.

| Soru | Bulgu |
|---|---|
| Mimari | Ön ve yan silüet için iki ayrı ResNet-34 (SE dikkat bloklu). Boy/kilo/cinsiyet MLP'si. Sigmoid kapılı birleştirme ve 13 çıktılı MLP. |
| Altyapı | PyTorch 2, torchvision; gerçek fotoğrafta arka plan silmek için rembg. |
| Girdi | Ön + yan **ikili silüet maskesi**, boy, kilo, cinsiyet (boy ve kilo zorunlu). |
| Çıktı | Ayak bileği, kol boyu, pazı, baldır, göğüs, ön kol, kalça, bacak boyu, omuz genişliği, omuz–ağ, uyluk, bel, bilek (cm). |
| Eğitilmiş ağırlık | **Yok.** Not defteri modeli yazarın Google Drive'ına kaydediyor; depoda ağırlık yok. |
| Raporlanan hata | 13 ölçünün **ortalaması** 1,22 cm MAE. Ölçü başına tablo yok. Bilek, ayak bileği gibi küçük ölçüler ortalamayı düşürür; göğüs, bel ve kalçanın hatası bu sayıdan çıkarılamaz. |
| Test verisi | BodyM eğitim bölümünden rastgele %15 (303 kişi). Aynı stüdyo, aynı çekim düzeni. Dış veride doğrulama yok. |
| Kıyafet | Veri seti sayfası kıyafeti belirtmiyor; "bazı kişiler sağlamlığı test etmek için farklı kıyafetlerle birden çok kez çekildi" diyor. Normal ya da bol kıyafet için ayrı bir doğruluk raporu yok. |
| Core ML | Teknik olarak mümkün (ResNet-34 ×2 + MLP, ~45 M parametre, ~90 MB float16). **Dönüştürülecek ağırlık olmadığı için yapılmadı.** |
| Cihazda | Ağırlık olsaydı Neural Engine'de çalışabilirdi. Ancak gerçek fotoğraftan silüet için ayrıca bir arka plan silme modeli gerekir; o modelin lisansı ayrıca kontrol edilmeli. Uygulamada Vision kişi maskesi kullanılabilirdi. **Ölçülmedi.** |
| Kod lisansı | **Lisans dosyası yok:** varsayılan olarak tüm hakları saklı. Kodun kopyalanması bile izin gerektirir. |
| Veri lisansı | BodyM veri seti (Amazon, AWS Open Data; 2.505 kişi; ölçüler laboratuvarda 3D taramayla) lisansı **CC BY-NC 4.0** olarak adlandırılıyor, bağlantı ise CC BY 4.0'a gidiyor. Bu çelişki netleşene kadar ticari kullanım yasak varsayılır. Bu veriyle eğitilmiş ağırlıkların ücretli bir uygulamada kullanılması lisans riski taşır. Kendi eğitimimiz de aynı kısıta takılır. |

## 3. Karşılaştırma tablosu

Aynı kişiler üzerinde gerçek mezura verisi **yok**. Bu yüzden iki sistem için de gerçek doğruluk "Henüz ölçülmedi".

| Kriter | Mevcut (WearIQ) | BodyM |
|---|---|---|
| Göğüs çevresi doğruluğu | Henüz ölçülmedi (gerçek kişi). ANSUR II simülasyonunda %0,99 MAE (yalnızca geometri, kamera/segmentasyon hatası yok) | Henüz ölçülmedi. Ölçü başına değer yayımlanmamış |
| Bel çevresi doğruluğu | Henüz ölçülmedi (sim.: %1,03) | Henüz ölçülmedi |
| Kalça çevresi doğruluğu | Henüz ölçülmedi (sim.: %1,09) | Henüz ölçülmedi |
| Omuz genişliği | Henüz ölçülmedi | Henüz ölçülmedi |
| Üst kol çevresi | Henüz ölçülmedi | Henüz ölçülmedi |
| Ön kol çevresi | Tahmin (ölçülmüyor) | Henüz ölçülmedi |
| Üst bacak çevresi | Henüz ölçülmedi | Henüz ölçülmedi |
| Baldır çevresi | Tahmin (ölçülmüyor); ANSUR'da istatistik MAE 1,22 cm | Henüz ölçülmedi |
| Kol uzunluğu | Henüz ölçülmedi | Henüz ölçülmedi |
| Bacak uzunluğu | Henüz ölçülmedi | Henüz ölçülmedi |
| Dar kıyafet | Henüz ölçülmedi | Henüz ölçülmedi (eğitim koşulu buydu) |
| Normal kıyafet | Kıyafet modeli var, kalibre edilmedi | Desteklemiyor (doğrulama yok) |
| Bol kıyafet | Kıyafet modeli var, kalibre edilmedi | Desteklemiyor (doğrulama yok) |
| Tekrarlanabilirlik | Henüz ölçülmedi | Henüz ölçülmedi |
| iOS entegrasyonu | Çalışıyor (Vision, cihazda) | Ağırlık yok; dönüştürülemez |
| Çevrimdışı | Evet | Ağırlık olsaydı mümkün |
| Ticari lisans | Kendi kodumuz; ANSUR II ve NHANES kamu malı | Kod: lisanssız. Veri: CC BY-NC 4.0 → **uygun değil** |
| Performans | Cihazda çalışıyor (TestFlight'ta kullanılıyor); süre ölçülmedi | Henüz ölçülmedi |

Simülasyonda girdi bakımından BodyM'ye en yakın yöntem de denendi: "ön + yan genişlik + boy/kilo/cinsiyet regresyonu", çapraz doğrulamalı. Sonuç: göğüs %1,51, bel %1,22, kalça %1,09. Aynı simülasyonda 8 durak göğüste ve belde daha iyi, kalçada eşit (VALIDATION.md §5). Bu bir BodyM ölçümü değildir; yalnızca iki görüntünün 8 durağa göre ne kadar bilgi taşıdığını gösterir.

## 4. Doğrulama altyapısı

`ScanValidation`:

- **CSV biçimi:** `subject,group,dimension,scanned,low,high,tape,system`. `system` "current", "bodym" ya da başka bir ad olabilir.
- **Sistem ve grup başına metrikler:** MAE, medyan mutlak hata, yüzde hata, sapma (bias), SD, 95. yüzdelik, tekrar tarama tutarlılığı, başarısızlık oranı ve %90 aralığın kapsama oranı.
- **`compare(_:first:second:minimumPeople:)`:**
  - Aynı kişiler üzerinde, kişi başına tekrarların ortalama hatasıyla eşli fark ve %95 aralık hesaplar.
  - **30 kişiden az veride kazanan ilan etmez** (`notEnoughPeople`).
  - Aralık sıfırı kesmiyorsa kazananı söyler.
  - Hibrit birleştirme ağırlığını (her sistemin sapması çıkarılmış hatalardan) yalnızca yeterli veride verir; keyfî oran kullanılmaz.
- **Test:** `ScanComparisonTests` hesapları uydurma sayılarla doğrular. Hiçbir sisteme dair iddia içermez.

Toplama protokolü VALIDATION.md §6'dadır:

- En az 30 kişi; farklı boy ve vücut tipleri.
- Mezura için ISO 8559-1.
- Kıyafet grupları: skin, fitted, tshirt, loose…
- Her grupta iki tarama.

BodyM sütunu ancak ticari kullanıma izin veren ağırlıklar bulunursa doldurulabilir. Yazarın izni ve ticari kullanıma uygun verilerle yeniden eğitim gerekir.

## 5. Sonuç

- Mevcut motor ve SOMA-X avatar akışı değiştirilmedi.
- BodyM'den alınabilecek, lisansı uygun bir yöntem de yok: mimari (iki ResNet + meta füzyon) yaygın bir yöntem, ama elde ağırlık ve ticari veri olmadan işe yaramaz.
- Yeni bir model düşünülürse ölçütler sırasıyla:
  1. Mezura verisinde 8 duraktan anlamlı ölçüde iyi olması (`compare` → `secondBetter`, ≥30 kişi).
  2. Ağırlıkların ve eğitim verisinin ticari lisansı.
  3. Core ML'de cihazda çalışması.
