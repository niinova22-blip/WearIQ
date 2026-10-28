# WearIQ

Vücut ölçülerini bir kez tarayıp kıyafetlerin nasıl oturacağını tahmin eden, beden öneren iOS uygulaması.
SwiftUI · iOS 17+ · SwiftData · Vision · StoreKit 2.

## Yapı

```
project.yml            XcodeGen tanımı (.xcodeproj CI'da / Mac'te üretilir)
WearIQ/                iOS uygulaması (App, Core, Features, Resources)
WearIQTests/           Uygulama testleri
WearIQKit/             Platformdan bağımsız Swift paketi
  WearIQCore           Ölçü ve kıyafet modelleri
  FitEngine            Bölgesel uyum + beden önerisi
  BodyMeasurementEngine  Vision çıktısından ölçü + belirsizlik
  ProductMeasurementParser  OCR beden tablosu ayrıştırıcı
  ScanQuota            Günlük 4 tarama hakkı
docs/VALIDATION.md     Ölçüm doğruluğu test protokolü
```

## Derleme

- **Motor testleri** (macOS/Linux/Windows): `cd WearIQKit && swift test`
- **iOS** (Mac): `brew install xcodegen && xcodegen generate && open WearIQ.xcodeproj`
- **CI:** Her push'ta GitHub Actions macOS runner'ında motor testleri, iOS derlemesi ve uygulama testleri çalışır.

## Aşama durumu

| Aşama | Durum |
|---|---|
| 1. Proje, mimari, tasarım sistemi, navigasyon | ✅ |
| 2. Onboarding, kamera, vücut tarama, ölçü düzeltme | ✅ CI'da derleniyor. Gerçek cihazda henüz denenmedi |
| 3. Ürün linki, barkod, OCR, kıyafet taslağı | ✅ Barkoddan ürün kataloğu eşlemesi yok (ücretsiz katalog yok) |
| 4. FIT Engine | ✅ Bolluk payları henüz kalibre edilmedi (bkz. docs/VALIDATION.md) |
| 5. Sonuç ekranı, geçmiş, günlük 4 tarama | ✅ |
| 6. StoreKit 2 + AdMob | ✅ Satın alma akışı testleri yalnızca Mac'te çalışıyor. AdMob şu an Google test ID'leriyle |
| 7. Gardırop, kombin motoru, ölçü takibi | ✅ |
| 8. Sanal deneme | ⛔ Modül var, özellik bilinçli olarak kapalı (bulut modeli + açık rıza gerekir) |
| 8. App Store hazırlığı | 🟡 TestFlight iş akışı ve metadata hazır. Team ID, API anahtarı ve AdMob ID'leri bekleniyor |

Yayın adımları: `docs/APP_STORE.md`
