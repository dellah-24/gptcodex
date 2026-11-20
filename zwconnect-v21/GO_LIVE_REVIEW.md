# ZWConnect go-live review

Reviewed on 20 November 2026 (Africa/Harare).

## Implemented in this release

- Public catalogue browsing remains available without an account.
- Checkout, payment-proof submission, order tracking, delivery requests, courier selection and delivery receipt now require an authenticated customer account.
- Customer accounts are separate from site-admin, shop-owner, worker and courier roles at database level.
- Customer order history is limited to the signed-in customer; private tracking tokens are retained as a second identifier.
- Payment-proof uploads use a customer-owned private storage path. Shop staff and administrators retain role-scoped review access.
- Anonymous execution was removed from all customer order and delivery RPCs.
- Server-side triggers prevent direct API callers from creating anonymous orders or assigning another customer's user ID.
- Auth forms include password reset, email verification support, consent capture, accessible labels and mobile layouts.
- Security headers disable framing, MIME sniffing, camera/microphone access and unnecessary browser payment access.
- The offline shell caches the new account experience. Authenticated customer actions can remain queued on the device and sync after reconnecting.
- Every offline action and inventory movement is bound to its originating authenticated user, shop and stable device ID. Signing out keeps it on the device; another account cannot view, overwrite or sync it.
- Customer carts, local order records, worker carts, purchasing records and expense drafts use account/shop-specific storage namespaces.
- Account switching refreshes the cloud stock snapshot before replaying only the newly signed-in account's pending local movements.

## Existing controls verified

- Site admin, shop owner, worker and courier roles are distinct; worker access is capped at seven per shop.
- Owner and courier applications require proof and administrative approval.
- Product stock updates use authenticated, idempotent actions and real-time product refresh.
- Case and singular-unit sales are separate, with retail/wholesale/hybrid shop modes.
- FIFO cost layers preserve profit accuracy when purchase prices change during the day.
- Payment approval posts stock, sale and ledger records with the authenticated worker or owner identity.
- Couriers can hold only one active job; customer and courier completion are both required.
- Audit and attended-support views are capped at 20 entries as requested.

## Deployment operations required before accepting real money

- Apply every SQL migration to the production Supabase project, ending with `20261120_customer_accounts_and_go_live.sql`.
- Configure the Supabase URL and public anon key in the production client bootstrap; never expose the service-role key.
- Add `https://zwconnect.co.zw` and its auth callback path to Supabase Auth redirect URLs.
- Enable email verification and configure a branded SMTP sender.
- Confirm daily Supabase backups, point-in-time recovery needs, error monitoring and an incident contact.
- Replace demo catalogue records with production data and run one end-to-end order using a test shop, customer and courier.
- Publish Terms, Privacy, Refund/Cancellation and Prohibited Goods policies before onboarding shops.

Manual payment proof remains a shop-confirmed workflow, not an automatic bank or mobile-money settlement. The interface states this clearly; reconciliation and disputes still require an operating policy.
