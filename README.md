# TapCard ZW

An offline-first Android digital business card with NFC, QR and vCard sharing.

## Download APK

[Download TapCard ZW v1.3.0](downloads/TapCard-ZW-v1.3.0-debug.apk)

Open the selected card on the first phone. Its NFC card activates automatically
while that screen remains open; the second unlocked phone uses its normal NFC
reader and requires no TapCard button or receiving mode. The APK is debug-signed
for direct testing on Android 8.0 or newer.

## Features

- Create up to 10 independent personal, work or company cards
- Switch the active NFC card, rename it, duplicate it, delete it and choose its colour
- Generate an offline vCard 3.0 QR code
- Make the card screen behave as an NFC Forum Type 4 digital card
- Let another unlocked NFC phone open the primary profile link automatically
- Export a `.vcf` contact file through the Android share sheet
- Continue using QR and vCard on phones without NFC
- Store profile data locally with no account, analytics or cloud requirement
- Material mobile interface with light and dark theme support

## Compatibility strategy

Phone-to-phone NFC is automatic. While the saved card screen is open, the phone
emulates an NFC Forum Type 4 card containing a primary profile URI and vCard
3.0. The second phone only needs to be unlocked with NFC enabled; its normal NFC
reader opens the primary profile link when the phones touch.

The on-screen QR code contains the same vCard 3.0 data and remains available as
a fallback because NFC antenna position and HCE support vary by device.

## GitHub inspiration

The implementation was informed by, but does not copy code from:

- [shamana-s/nfc](https://github.com/shamana-s/nfc) — compact NDEF URI interoperability
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

1. Select a card from the card switcher, or tap **New** to create another one.
2. Complete that profile and tap **Save card**.
3. Keep the TapCard screen open; the selected card activates automatically.
4. Unlock the second phone and make sure its NFC is enabled.
5. Touch the phones’ NFC areas together until the second phone opens the profile link.
6. Use the QR code if the devices cannot establish an NFC connection.

Each card is saved as a separate local record, so changing one card never
overwrites another. Use **Manage** to rename, duplicate or delete the selected
card. At least one card is always retained.

Designed by [Tempest Technologies](https://tempesttechnologies.co.zw).

## Licence

MIT — see [LICENSE](LICENSE).
