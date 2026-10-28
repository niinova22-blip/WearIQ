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
| 4. FIT Engine çekirdeği (öne alındı) | ✅ motor + testler. Bolluk payları henüz kalibre edilmedi |
| 5. Günlük kota yöneticisi | ✅ motor + Keychain deposu. Paywall bağlantısı yok |
| 2. Onboarding, kamera, vücut tarama | ⏳ Ölçüm matematiği hazır, Vision/kamera katmanı yok |
| 3. Ürün linki, barkod, OCR | ⏳ Beden tablosu ayrıştırıcı hazır, Vision OCR/link servisi yok |
| 6–8 | ⏳ |
