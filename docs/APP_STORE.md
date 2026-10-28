# App Store hazırlığı

## 1. App Store Connect'te yapılacaklar (hesap sahibi)

1. **Certificates, IDs & Profiles → Identifiers:** `com.niinova.weariq` App ID'sini oluştur. Farklı bir bundle ID kullanacaksan `project.yml` güncellenmeli.
2. **App Store Connect → Apps → +:** "WearIQ" adlı uygulamayı oluştur (birincil dil: Türkçe, SKU: `weariq-ios`).
3. **Abonelikler:** "WearIQ Premium" abonelik grubunu oluştur ve içine şunları ekle:
   - `com.niinova.weariq.premium.monthly`: 1 ay, başlangıç fiyat hipotezi 6,99 USD
   - `com.niinova.weariq.premium.yearly`: 1 yıl, başlangıç fiyat hipotezi 49,99 USD

   Fiyatlar uygulamada sabit değil, App Store'dan okunur.
4. **Users and Access → Integrations → App Store Connect API:** "App Manager" rolünde bir anahtar oluştur. Key ID, Issuer ID ve `.p8` dosyasını GitHub Secrets'a ekle (bkz. `.github/workflows/release.yml`).
5. **Gizlilik politikası URL'si:** https://niinova22-blip.github.io/WearIQ/privacy.html
6. **AdMob:** Uygulamayı AdMob'a ekle. App ID ve banner/geçiş reklamı birim ID'lerini GitHub depo değişkenlerine (`ADMOB_APP_ID`, `ADMOB_BANNER_ID`, `ADMOB_INTERSTITIAL_ID`) gir.
   - AdMob → Privacy & messaging bölümünden GDPR mesajını ve iOS ATT açıklama mesajını oluştur.
   - `app-ads.txt` için bir geliştirici web sitesi gerekir.

## 2. Metadata

**Ad:** WearIQ
**Alt başlık (TR):** Beden önerisi ve kıyafet uyumu
**Subtitle (EN):** Size advice & fit check

**Anahtar kelimeler (TR, 100 karakter):** beden,beden önerisi,kıyafet,uyum,ölçü,vücut ölçüsü,gardırop,kombin,stil,online alışveriş
**Keywords (EN):** size,fit,clothing size,body measurements,size chart,wardrobe,outfit,style,shopping

**Açıklama (TR):**
WearIQ, vücut ölçülerini bir kez çıkarır ve aldığın her kıyafetin üzerinde nasıl duracağını bölge bölge gösterir.

• Bir kez tara: Telefonunla önden ve yandan iki fotoğraf. Fotoğraflar cihazında işlenir, yüklenmez.
• Ürün bağlantısı, barkod veya beden tablosu ekran görüntüsüyle kıyafeti ekle.
• Omuz, göğüs, bel, kol ve boy için "dar", "ideal", "bol" gibi açık değerlendirmeler ve tahmini cm farkı.
• Her öneride dürüst bir güven seviyesi. Veri eksikse tahmin yürütmek yerine bunu açıkça söyleriz.
• Her gün 4 ücretsiz analiz.

Premium ile: sınırsız analiz, reklamsız kullanım, dijital gardırop, kombin önerileri ve ölçü değişimi takibi.

WearIQ bir sağlık uygulaması değildir ve tıbbi değerlendirme yapmaz.

**Description (EN):** WearIQ measures you once, then shows how each garment will fit, region by region: shoulders, chest, waist, sleeves and length, with estimated differences in cm and an honest confidence level. Add clothes from a product link, barcode or size chart screenshot. Photos are processed on your device and never uploaded. 4 free analyses a day; Premium adds unlimited analyses, no ads, a digital wardrobe, outfit suggestions and measurement tracking. Not a health app.

**Kategori:** Lifestyle (birincil), Shopping (ikincil)
**Yaş sınırı:** 4+ (reklamlar AdMob yaş içeriği filtresiyle G olarak ayarlanmalı)

## 3. App Privacy (gizlilik etiketleri)

| Veri türü | Toplanıyor mu? | Amaç | İzleme |
|---|---|---|---|
| Vücut fotoğrafları / ölçüleri | **Hayır** (yalnızca cihazda) | – | – |
| Device ID (IDFA) | Evet, AdMob tarafından ve yalnızca ATT izniyle | Third-party advertising | Evet |
| Product interaction / advertising data | Evet, AdMob tarafından | Third-party advertising, Analytics | Evet |
| Crash data | Evet, AdMob SDK tarafından | App functionality | Hayır |
| Purchases | Apple tarafından | – | – |

Göndermeden önce Google'ın güncel [AdMob veri açıklaması rehberine](https://developers.google.com/admob/ios/privacy/data-disclosure) göre teyit et.

## 4. App Review notları

> WearIQ needs no account. Body scan: allow camera, prop the phone ~2–3 m away and follow the voice cues; or tap "Enter measurements manually" to type values instead (e.g. height 178, chest 100, waist 86). To analyse a garment: Scan tab → "Enter a size chart manually" → category Shirt, chart shows Garment measurements, add size M with chest 112 → Analyze fit. Free users get 4 analyses per day; the paywall appears after that or from Wardrobe/Style tabs. Photos are processed on-device with Apple Vision and never uploaded.

## 5. Yayın öncesi kontrol listesi

- [ ] Gerçek cihazda vücut tarama denemesi (farklı ışık ve kıyafet koşulları)
- [ ] `docs/VALIDATION.md` protokolüyle ilk doğruluk ölçümü. Sonuç gelmeden mağaza metninde cm hassasiyeti iddia etme.
- [ ] StoreKit satın alma testleri bir Mac'te Xcode ile (`WEARIQ_STOREKIT_PURCHASE_TESTS=1`)
- [ ] Sandbox hesabıyla TestFlight'ta satın alma, geri yükleme ve iptal
- [ ] Gerçek AdMob ID'leri depo değişkenlerinde, Debug derlemelerinde test reklamları
- [ ] Ekran görüntüleri: 6.9" ve 6.5" iPhone, TR ve EN
- [ ] Gerçek bir uygulama ikonu (şu anki geçici)
