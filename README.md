# WearIQ

Vücut ölçülerini bir kez tarayıp kıyafetlerin nasıl oturacağını tahmin eden, beden öneren iOS uygulaması.
SwiftUI · iOS 17+ · SwiftData · Vision · StoreKit 2.

## Yapı

```
project.yml            XcodeGen tanımı (.xcodeproj CI'da / Mac'te üretilir)
WearIQ/                iOS uygulaması (App, Core, Features, Services, Resources)
WearIQSafari/          Safari uzantısı: alışveriş sayfasında beden rozeti
WearIQShare/           Paylaş menüsü uzantısı (mağaza uygulamasından link)
WearIQWidget/          Ana ekran widget'ı
WearIQTests/           Uygulama testleri · WearIQUITests/  arayüz testleri
WearIQKit/             Platformdan bağımsız Swift paketi
  WearIQCore           Ölçü ve kıyafet modelleri, beden sistemleri
  BodyMeasurementEngine  Vücut taramasından ölçü + belirsizlik
  FitEngine            Bölgesel uyum, beden önerisi, iade riski, stil
  ProductMeasurementParser  Ürün sayfası, beden tablosu (HTML/OCR/Zara rehberi)
  AvatarEngine         3D vücut (SOMA-X) + kumaş simülasyonu
  ShoppingAssistant    Safari uzantısının ortak mantığı, beden pasaportu
  OutfitRecommendationEngine  Kombin ve renk önerileri
  ScanQuota            Ücretsiz planda günlük 5 kontrol
docs/VALIDATION.md     Ölçüm doğruluğu ve güven denetimi
```

## Derleme

- **Motor testleri** (macOS/Linux/Windows): `cd WearIQKit && swift test`
- **iOS** (Mac): `brew install xcodegen && xcodegen generate && open WearIQ.xcodeproj`
- **CI:** Her push'ta GitHub Actions macOS runner'ında motor testleri, iOS derlemesi ve uygulama testleri çalışır.

## Durum

App Store'da yayında (1.0). Ücretsiz plan: günlük 5 kontrol, sonuçtan önce reklam; Premium: sınırsız kontrol, Stil sekmesi, gardırop ve avatar bölge raporu.

Mağaza okuma denetimi: `LIVE_PAGES=<klasör> swift test --filter LivePageAudit` (gerçek sayfaların tarayıcı dökümüyle).

Yayın adımları: `docs/APP_STORE.md`
