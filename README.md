# TapCard ZW

An offline-first Android digital business card with NFC, QR and vCard sharing.

## Features

- Create and edit a personal or company contact card
- Generate an offline vCard 3.0 QR code
- Write a website, profile link or vCard to a physical NDEF NFC tag
- Emulate an NFC Forum Type 4 URL card using Android Host Card Emulation
- Export a `.vcf` contact file through the Android share sheet
- Continue using QR and vCard on phones without NFC
- Store profile data locally with no account, analytics or cloud requirement
- Material mobile interface with light and dark theme support

## Compatibility strategy

When a website or LinkedIn URL exists, physical NFC tags contain a compact NDEF
URI record. This is the most reliable tap-to-open format across Android and
iPhone and fits small NTAG213 tags. If there is no URL, the app writes a vCard
MIME record. The on-screen QR code always contains vCard 3.0 so the receiving
phone can offer to save the contact directly.

Phone-to-phone NFC uses Host Card Emulation and exposes the primary URI as an
NFC Forum Type 4 tag. HCE support and background scanning vary by device, so QR
is intentionally kept as the universal fallback.

## GitHub inspiration

The implementation was informed by, but does not copy code from:

- [shamana-s/nfc](https://github.com/shamana-s/nfc) — compact NDEF URI writing and cross-platform tag behaviour
- [Merloko/business-card-scanner](https://github.com/Merloko/business-card-scanner) — offline-first digital card, QR and NFC workflow
- [ExpressAnalytics/ea-nfc-demo](https://github.com/ExpressAnalytics/ea-nfc-demo) — NFC Forum Type 4 Host Card Emulation and the Android vCard compatibility caveat
- [overtonlabs/qr-business-card](https://github.com/overtonlabs/qr-business-card) — vCard 3.0 QR interoperability and escaping rules

## Build

Requirements: JDK 17, Android SDK 35 and Gradle 8.10.2.

```bash
gradle :app:testDebugUnitTest :app:assembleDebug
```

The APK is generated at `app/build/outputs/apk/debug/app-debug.apk`.

GitHub Actions builds and uploads `TapCard-ZW-debug-apk` on every push to the
`tapcard-nfc-apk` branch.

## Using NFC

1. Complete the profile and tap **Save card**.
2. For a physical NFC tag, tap **Write NFC tag** and hold an NDEF-compatible tag against the phone.
3. For phone-to-phone sharing, keep NFC enabled and the phone unlocked, then place the receiving phone near it.
4. If the receiving phone does not react, let the person scan the QR code.

Designed by [Tempest Technologies](https://tempesttechnologies.co.zw).

## Licence

MIT — see [LICENSE](LICENSE).
