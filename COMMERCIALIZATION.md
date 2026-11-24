# TapCard ZW commercial launch guide

## Implemented foundation

- Secure email/password customer accounts through Supabase Auth.
- Free, Pro and Business entitlements with 1, 10 and 50-card limits.
- Trial, active, past-due, cancelled and expired subscription states.
- Seven-day offline entitlement grace period; NFC and existing local cards are
  never deleted when a subscription lapses.
- Android Keystore encryption for session tokens.
- Offline event queue with automatic retry and a 100-event device cap.
- Separate Cloudflare Pages admin portal with subscriber management, usage
  metrics, support tickets and subscription audit records.
- Supabase Row Level Security; admin access is granted server-side only.
- Backend lead records with consent tracking, ready for a public profile form.

## Production configuration

Build Android with public Supabase client settings:

```bash
gradle -PSUPABASE_URL=https://PROJECT.supabase.co \
  -PSUPABASE_ANON_KEY=PUBLIC_ANON_KEY \
  :app:assembleRelease
```

The anonymous key is designed for client use. Never package the service-role
key. Apply the SQL migration before distributing a cloud-enabled build.

## Payments

For an APK distributed through Google Play, configure Pro and Business products
in Play Console and use Google Play Billing for in-app subscription checkout.
Purchase tokens must be sent to a server/Edge Function, verified with the
Google Play Developer API, hashed, then reflected in `subscriptions`. Do not
trust a plan value sent by the phone.

The current admin RPC supports trials, promotions and manually reconciled
subscriptions. It deliberately does not pretend to verify payments. Production
checkout requires the merchant account, Play Console product IDs and backend
credentials owned by Tempest Technologies.

## Recommended next marketable features

1. Hosted public profile pages with dynamic links so contact details can change
   without reinstalling or rewriting the NFC payload.
2. Two-way contact exchange and lead capture, including consent, notes, tags,
   CSV export and CRM webhooks.
3. Per-card analytics: views, NFC taps, QR scans, contact saves and conversion
   funnels. Hosted links are required to measure recipient activity reliably.
4. Business teams: invitations, branded templates, card approval and role-based
   controls.
5. Custom domains, company colours, logos and removal of TapCard branding.
6. Google/Apple Wallet passes, email signatures and virtual meeting backgrounds.
7. Account deletion, data export, privacy policy, terms, refund policy and a
   customer support workflow before public launch.

## Suggested positioning

- Free: one offline NFC/QR card.
- Pro: up to ten cards, themes and cloud usage analytics.
- Business: up to fifty cards, admin-managed access and priority support.

Do not advertise team management, CRM sync or recipient-view analytics as live
until their customer-facing screens and hosted profile service are deployed.
