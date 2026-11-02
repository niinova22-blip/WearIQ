# Vücut ölçüm motoru: eğitim ve optimizasyon altyapısı (2026-11-03)

Hedef: kullanıcının boyu, kilosu ve 360° dönüş videosundan göğüs, bel ve kalça çevrelerini en düşük santimetre hatasıyla bulmak. Ağır işler (eğitim) bilgisayarda yapılıyor; ölçüm tamamen iPhone'da ve internetsiz çalışıyor.

Kurallar:
- Çalışan motor bozulmadı ve yerinden çıkarılmadı.
- Yeni model ancak gerçek mezura karşılaştırmasıyla kanıtlanırsa üretime geçebilir.

## 1. Mevcut mimari (analiz)

Uygulamadaki dönüş ölçümü şu adımlardan oluşuyor:

1. **Ön fotoğraf.** Vision iskeleti ve kişi maskesi çıkarılıyor. Seviyeler ANSUR II nüfus oranlarıyla belirleniyor (göğüs 0,728, bel 0,601, kalça 0,507 boy oranı) ve kişinin kendi omuz ve kalça eklemleri arasına geriliyor (`JointHeights`).
2. **10 saniyelik dönüş videosu.** Her karede maskenin o seviyelerdeki satır genişliği alınıyor. cm'ye çevirme: piksel × boy ÷ maskenin baş-taban yüksekliği (`RotationScanAnalyzer`).
3. **Açı.** Kol açıklığının |cos θ| sinyalinden bulunuyor (`TurnRecording.angles`).
4. **Çevre.** Her seviyede genişlik açıya karşı robust çift harmonik eğriye oturtuluyor. Çevre = π × ortalama genişlik (Cauchy formülü) × ANSUR kalibrasyonu (`TurnRecording.girths`).
5. **Birleştirme.** Sonuç 8 durak ölçümü, nüfus istatistikleri, kıyafet adımı ve gerekirse yandan ek çekimle birleştiriliyor.
6. **Kol ve bacak çevreleri.** Silüetten ölçülmüyor. Boy, kilo ve yaştan tahmin ediliyor, ölçülen göğüs/bel/kalçaya göre koşullanıyor (`AnthropometricPrior`, `GirthCorrelations`).

Mevcut doğrulamanın zayıf yanı şuydu: `FilmedTurnValidationTests` ANSUR'un en, derinlik ve çevre ölçülerine uydurulmuş **ideal kesitler** kullanıyor. Bu kesitlerde Cauchy formülü tanım gereği doğru çıkıyor. Bu yüzden testler şu gerçek etkileri hiç ölçmüyordu:
- perspektif,
- seviyenin yanlış satıra düşmesi,
- saç,
- gerçek gövde kesitleri.

## 2. Veri kaynakları ve lisanslar

| Kaynak | Lisans | Durum |
|---|---|---|
| **NVIDIA SOMA-X** (HF: nvidia/SOMA-X, GitHub NVlabs/SOMA-X) | Apache-2.0, model kartında "ready for commercial use" | ✅ Kullanıldı. Uygulamada zaten paketli olan PCA gövde modeli (`SomaBody.bin`, 32 bileşen; SizeUSA'nın 9.326 taramasından öğrenilmiş). Paketli modelde iskelet ve rig yok, bu yüzden poz değiştirilemiyor (§3). |
| **ANSUR II** (ABD Ordusu, 2012) | Kamu malı (ABD federal verisi) | ✅ Kullanıldı. 6.068 kişi, 93 mezura ölçüsü; zaten depoda. Gerçek etiketlerin kaynağı. |
| **NHANES 2017–2020** (CDC) | Kamu malı | ✅ Yalnızca test için. BMI 30+ olan 2.699 sivil. Bel ve kalça ölçülmüş; göğüs ve uyluk ANSUR ilişkilerinden tahmin. Kural gereği **eğitim etiketi olarak kullanılmadı.** |
| **Size Korea** (sizekorea.kats.go.kr) | Doğrulanamadı | ❌ Kullanılmadı. Site bu ortamdan yanıt vermedi (zaman aşımı). Herkese açık indirilebilir veri ve ticari kullanım koşulu bulunamadı; literatür verinin başvuruyla ve çoğunlukla araştırma kurumlarına verildiğini gösteriyor. Erişim ve lisans sağlanırsa aynı altyapıya eklenebilir. |
| **HSRD-100** (HF: digitalrealitylab/HSRD-100) | CC BY 4.0, ticari kullanım serbest (atıf zorunlu); dosya içi metadata "Commercial" + fiyat alanları içeriyor | ⚠️ İncelendi, eğitimde kullanılmadı. 10 kişi × 10 poz, toplam 246 GB. **Taramaların hepsi kıyafetli** (ceket, mont, kot vb.). Kural gereği çıplak vücut ölçüsü sayılamaz. Pozlar günlük hareketler (telefona bakma, yürüme, valiz çekme vb.), dönüş pozu yok. Ölçü olarak yalnızca boy ve kilo var. Kullanılabilecek yer: gerçek fotoğraflarla maske ve silüet hattının testi. Bu ise Apple Vision gerektiriyor ve Windows geliştirme makinesinde çalışmıyor (bkz. §7). |

## 3. Sentetik eğitim verisi (`ScanSimulator`, `ScanDataExport`)

Her ANSUR II kişisinin SOMA-X gövdesi o kişinin 8 ölçüsüne göre kuruluyor; çevreler 0,5 cm içinde tutuyor. Gövde, telefonun önünde dönerken simüle ediliyor:

- **Kamera:** 2,0–3,2 m uzakta, 0,6–1,3 m yükseklikte, vücudun ortasına eğik bakıyor; 70–78° dikey görüş açısı; 640–1280 px maske.
- **Seviyeler:** uygulamanın yaptığı gibi nüfus oranlarıyla yerleştiriliyor; Vision eklem hatası ±%0,6 boy.
- **Gürültü:** saç (0,5–3 cm), maske genişlemesi ve piksel gürültüsü, %5 bozuk kare, düzensiz dönüş hızı, 1 cm sallanma.
- **Kollar:** dönüşte omuz hizasında açık tutuluyor. SOMA'nın kolları iskeletsiz kaldırılamadığı için kollar çıkarıldı ve omuz dikişi kapatıldı.
- **Etiket:** aynı mesh'in mezura yöntemiyle (dışbükey zarf) ölçülen çevresi. ANSUR mezurasından farkı: göğüs 0,03, bel 0,12, kalça 0,03 cm.

Simülatörün doğrulanması: ideal koşulda (uzak kamera, gürültü yok, gerçek seviye) Cauchy formülü gerçek gövdede bel 0,06, kalça 0,09, göğüs 0,67 cm ortalama hatayla tutuyor. Geometri doğru.

Gerçek ile sentetik arasındaki farkı kapatmak için alan rastgeleleştirmesi (domain randomization) kullanıldı. Model "geniş" koşullarla eğitildi: her kayıt ya normal koşullarda ya da şu kaydırılmış koşullarda üretildi:
- 1,6–2,0 / 3,2–3,8 m mesafe,
- 0,35–0,6 / 1,3–1,55 m yükseklik,
- 64–70 / 78–84° lens,
- 480–640 px kaba maske, 2× kenar gürültüsü, 3 px genişleme,
- 6–8 / 12–16 s dönüş.

Son sınav **hiç görülmemiş** etkilerle yapıldı:
- telefon 2–5° eğik,
- kullanıcı 1–4° öne ya da arkaya eğik,
- maske bir yana daha fazla genişlemiş.

**Veri sızıntısı yok.** Bölme kişi bazında: ANSUR subject id'den hash, %70 eğitim, %15 doğrulama, %15 test. Eğitim betiği aynı kişinin iki kümede olmadığını kontrol ediyor. Test kişileri tek kayıtla temsil ediliyor; Swift testi bunlar için farklı tohumla yeni kayıtlar üretiyor.

## 4. Model (engine C, `LearnedGirthModel`)

Her seviye için 27 özellik kullanılıyor:
- Cauchy çevresi (log),
- seviyenin ±1–3% boy yukarısı ve aşağısındaki satırların göreli genişlikleri,
- 2θ ve 4θ harmonikleri (önden/yandan oran),
- maskenin üst ve taban satırı (mesafe ve kamera yüksekliği bilgisi),
- boy, log kilo, BMI, cinsiyet,
- diğer iki seviyenin göreli genişliği.

Özellikleri **tek bir Swift kodu** hesaplıyor; eğitim de telefon da aynı kodu kullanıyor. Python ile Swift'in aynı sonucu verdiği doğrulandı.

Modeller:
- ridge regresyon,
- tek gizli katmanlı ağ: 24 tanh nöron, numpy + Adam.

Doğrulama kümesinde her seviyede ağ kazandı; telefona ağ aktarıldı. Hesaplama 1 ms'nin altında, internet yok. Ağırlıklar `LearnedGirthModel+Weights.swift` dosyasında, betik tarafından üretiliyor.

## 5. Sonuçlar (test kümesi, cm)

Satırlarda MAE / RMSE / sistematik hata (bias, + büyük okuyor) var. "Mevcut" = uygulamanın bugünkü motoru, aynı karelerde. "Boy/kilo" = yalnızca boy, kilo, yaş ve cinsiyetle eğitilmiş referans.

**ANSUR test kişileri, normal koşullar (n=961)**

| | Mevcut | Yeni (C) | Boy/kilo |
|---|---|---|---|
| Göğüs | 4,76 / 5,77 / −3,35 | **1,24 / 1,56 / −0,01** | 2,85 / 3,64 / −0,16 |
| Bel | 3,48 / 4,44 / −0,68 | **1,34 / 1,76 / −0,06** | 3,56 / 4,48 / −0,29 |
| Kalça | 2,99 / 3,60 / −2,27 | **1,16 / 1,49 / −0,07** | 2,18 / 2,81 / −0,22 |

**Kaydırılmış kamera ve maske (n=961)**

| | Mevcut | Yeni (C) |
|---|---|---|
| Göğüs | 10,01 / 11,83 / +3,89 | **1,64 / 2,11 / +0,01** |
| Bel | 7,04 / 8,86 / +4,97 | **1,79 / 2,37 / −0,03** |
| Kalça | 6,26 / 8,14 / +1,12 | **1,37 / 1,74 / +0,13** |

**Görülmemiş etkiler: eğik telefon, eğik gövde, asimetrik maske (n=961)**

| | Mevcut | Yeni (C) |
|---|---|---|
| Göğüs | 7,84 / 10,04 / +0,33 | **1,73 / 2,23 / +0,34** |
| Bel | 6,26 / 8,45 / +3,52 | **1,82 / 2,38 / +0,16** |
| Kalça | 5,32 / 7,42 / −0,05 | **1,46 / 1,85 / −0,09** |

**NHANES BMI 30+ siviller (eğitimde olmayan vücut tipi, n=2.699)**

| | Mevcut (normal / görülmemiş) | Yeni C (normal / görülmemiş) |
|---|---|---|
| Göğüs | 4,80 / 7,35 | **2,34 / 2,45** (bias −1,9 / −1,3) |
| Bel | 4,67 / 6,21 | **2,24 / 3,09** (bias −0,9 / −1,1) |
| Kalça | 4,35 / 5,22 | **2,07 / 2,73** (bias −1,5 / −1,7) |

**Telefonun kendi kod yolu, uçtan uca** (`LearnedGirthModelTests`, 241 test kişisi, görülmemiş koşullar, yeni kayıtlar):

| | Yeni (C) | Mevcut |
|---|---|---|
| Göğüs | 1,70 (bias +0,45) | 8,27 |
| Bel | 1,86 (bias +0,16) | 6,22 |
| Kalça | 1,51 (bias −0,10) | 5,37 |

Bu sonuçlardan çıkanlar:
- **Mevcut motorun en büyük hatası perspektiften geliyor.** Telefon 2–3 m uzaktan görüntüdeki satırları ölçüyor; bunlar vücudun yatay kesitleri değil. Kamera kapatılınca (uzak, dar lens) hata 0,1–0,6 cm'ye iniyor.
- **İkinci hata kaynağı seviye yerleşimi:** nüfus oranları ile kişinin kendi meme ucu ve göbek yüksekliği arasındaki fark.
- **Saç ölçeği %1 küçültüyor.**
- **Bu bulgu simülasyondan geliyor.** Gerçek telefonda aynı büyüklükte olup olmadığını ancak mezura verisi gösterir.
- **Çok kilolu vücutlarda yeni model 1,5–2 cm küçük okuyor.** Eğitim ANSUR'un BMI aralığında (çoğu < 35) yapıldı. Ağır vücutlar eklenince bu hata düşer; bunun için ya gerçek ağır vücut taramaları ya da gerçek ölçülü veri gerekiyor.
- **Kol ve bacak çevreleri** (`detail_girths.py`, ANSUR gerçek etiketleri, kişi bazında bölme): mevcut doğrusal yöntem ile ağ arasındaki fark en fazla 0,06 cm. Bu yüzden değiştirilmedi. Sınır modelde değil bilgide: kollar ve bacaklar videoda doğrudan ölçülmüyor.

## 6. Üretime geçiş kuralı

C şu an yalnızca **doğrulama modunda** A ve B'nin yanında çalışıyor. Uygulamanın kaydettiği ölçü her zaman A'nın.

Doğrulama kaydı şunları saklıyor:
- C'nin sonucu,
- C'nin özellik vektörü (`turnFeatures`).

Böylece mezurayla ölçülmüş her tarama gelecekte gerçek bir eğitim örneği olabiliyor.

Bir ölçü için C'nin üretime geçmesi `EngineSelection` kuralına bağlı:
- en az 20 katılımcı,
- kişi bazında eşleştirilmiş |C−mezura| − |A−mezura| ortalaması en az 0,3 cm daha iyi,
- %95 aralık sıfırın altında.

Bu sağlanana kadar A kalıyor.

## 7. Yapılamayanlar ve eksik veriler

- **Gerçek videolarda mezuralı test yok.** Sentetik sonuçlar gerçek telefonda kanıt değil. Doğrulama modunda en az 20 kişinin mezuralı taraması gerekiyor (uygulama içi akış hazır).
- **Size Korea'ya erişilemedi.** Lisans doğrulanamadı.
- **HSRD-100 kıyafetli ve dönüş pozunda değil.** Çıplak etiket olarak kullanılamaz. Gerçek fotoğraflarla maske testi Apple Vision gerektirdiği için Windows'ta yapılamadı. macOS CI'da yapılabilir ama 246 GB'lık verinin indirilmesi ve seçilmesi gerekir.
- **SOMA-X'in iskeleti ve rig'i paketli modelde yok.** Kollar T-pozuna kaldırılamadı, çıkarıldı. Gerçek dönüşte kolların gövdeye değmesi simüle edilmiyor (uygulama bunu ani genişleme filtresiyle ayıklıyor).
- **Gerçek-sentetik farkını kapatmak için gerçek görüntü verisi kullanılmadı.** Kullanılan yöntem alan rastgeleleştirmesi ve görülmemiş koşul testleri. Gerçek mezuralı kayıtlar geldiğinde, `train.py --real validation.json` ile hem değerlendirme hem ince ayar yapılabilir.
- **NHANES'te göğüs ve uyluk ölçülmemiş.** Bu yüzden yalnızca test olarak kullanıldı. Tablodaki "boy/kilo" referansı ANSUR'a göre eğitildi; uygulamanın kendi önsel modeli ANSUR+NHANES ile eğitildiği için NHANES'te daha iyidir.

## 8. Çalıştırma

```sh
cd WearIQKit
# eğitim verisi (geniş koşullar, kişi başına 3 kayıt): ~3 dk
SCAN_DOMAIN=wide SCAN_REPEATS=3 SCAN_DATA=scan_wide.csv swift test --scratch-path .build-opt -Xswiftc -O --filter ScanDataExport
# test setleri
for D in normal shifted unseen; do SCAN_DOMAIN=$D SCAN_DATA=scan_$D.csv swift test --scratch-path .build-opt -Xswiftc -O --filter ScanDataExport; done
for D in normal unseen; do SCAN_SOURCE=nhanes SCAN_DOMAIN=$D SCAN_DATA=scan_nhanes_$D.csv swift test --scratch-path .build-opt -Xswiftc -O --filter ScanDataExport; done
cd ..
# eğitim, karşılaştırma, ağırlıkların Swift'e aktarımı (~10 s)
python scripts/scan_training/train.py scan_wide.csv scan_normal.csv scan_shifted.csv scan_unseen.csv scan_nhanes_normal.csv scan_nhanes_unseen.csv --export
# gerçek mezuralı kayıtlarla değerlendirme
python scripts/scan_training/train.py scan_wide.csv --real weariq-validation.json
# kol ve bacak çevreleri karşılaştırması
python scripts/scan_training/detail_girths.py
```

Teşhis için `SCAN_OFF=levels,hair,camera,mask,sway` etkileri tek tek kapatır.
