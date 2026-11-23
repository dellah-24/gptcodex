# TapCard ZW

An offline-first Android digital business card with NFC, QR and vCard sharing.

## Download APK

[Download TapCard ZW v1.1.0](downloads/TapCard-ZW-v1.1.0-debug.apk)

Version 1.1.0 transfers contacts exclusively between two NFC-capable Android
phones. The APK is debug-signed for direct testing on Android 8.0 or newer. A
production-store release should use a securely retained release signing key.

## Features

- Create and edit a personal or company contact card
- Generate an offline vCard 3.0 QR code
- Share a full contact card directly between two Android phones
- Send with NFC Forum Type 4 Host Card Emulation and receive with NFC reader mode
- Export a `.vcf` contact file through the Android share sheet
- Continue using QR and vCard on phones without NFC
- Store profile data locally with no account, analytics or cloud requirement
- Material mobile interface with light and dark theme support

## Compatibility strategy

Phone-to-phone NFC uses two explicit modes. The sending phone emulates an NFC
Forum Type 4 card containing both a primary URI and vCard 3.0. The receiving
phone enters reader mode, extracts the vCard and offers to save it to Contacts.
Both phones must have NFC enabled and remain unlocked during the tap.

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

1. Complete the profile and tap **Save card**.
2. On the sending phone, tap **Share by NFC**.
3. On the second phone, open TapCard ZW and tap **Receive card**.
4. Keep both phones unlocked and touch their NFC areas together until the receiving phone responds.
5. Tap **Save contact** on the receiving phone, or use the QR code if the devices cannot establish an NFC connection.

Designed by [Tempest Technologies](https://tempesttechnologies.co.zw).

## Licence

MIT — see [LICENSE](LICENSE).
