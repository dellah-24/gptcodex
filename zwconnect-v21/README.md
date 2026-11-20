# ZWConnect

An advanced, multi-industry POS dashboard designed for Zimbabwean retailers.

## Reorganized production layout

This package separates public discovery, customer ordering, owner operations,
worker POS, inventory, purchasing, administration and courier work into clear
routes and asset modules. See `docs/ARCHITECTURE.md` for the complete map.

Key entry routes are `/`, `/account/`, `/cart/`, `/owner/`, `/worker/`,
`/inventory/`, `/purchasing/`, `/admin/` and `/courier/`. The routes reuse one
Supabase client and one account-bound offline queue; route separation does not
duplicate authentication state or allow roles to overlap.

## Included in this prototype

- Public, no-login browsing across 15 business profiles
- Profile-specific shop listings, public prices and stock availability
- Browser geolocation, manual city selection and OpenStreetMap maps
- Distance sorting calculated locally with the Haversine formula
- Owner registration and site-admin approval workflow
- Owner-managed worker invitations with a 7-account database limit
- Separate site_admin, shop_owner and worker platform roles
- Role-specific admin, owner and worker portal previews
- Dedicated site administration workspace at `/admin/`
- Owner approvals, business oversight, accounts, profiles and audit views
- Responsive desktop, tablet and mobile UI
- Supabase marketplace schema, functions, triggers and RLS policies
- Static Cloudflare-compatible build in `dist/`
- Product sharing links and social preview metadata for `https://zwconnect.co.zw`
- Admin-managed shop subscriptions, durations and trial periods
- Owner-only subscription visibility; workers cannot access billing details
- Site-admin shop editing and deletion with preserved audit history
- Private shop-proof uploads for owner applications and admin review
- Installable PWA shortcut with ZWConnect-branded icons
- Offline-first product movements with IndexedDB queueing and automatic reconnect sync
- Supabase Realtime product subscriptions and idempotent movement processing
- Global command search for shops, products, profiles and common actions
- Owner quick actions, low-stock attention list and shop-health checklist
- Durable IndexedDB action queue for sales, applications, worker invitations and admin changes
- Idempotent Supabase transactions for offline sales, approvals, subscriptions and shop updates
- Separate singular-unit and full-case pricing with base-unit stock deduction
- Retail-only, wholesale-only and hybrid store trading modes with enforced sale rules
- Restart-safe replay of pending sales, inventory movements and worker invitations
- Owner-managed company payment methods and customer payment-reference submission
- Atomic payment confirmation that posts sales, base-unit stock movements and double-entry ledger records
- Admin-approved bicycle courier marketplace with public courier details and delivery quotes
- Dedicated courier portal for jobs, distance/location rates, service area and subscription status
- Separate admin-controlled courier subscriptions, trials, fees and access status
- Multi-product customer cart with live stock checks and unit/case quantities
- Image-or-text payment proof, shop review notes and private order tracking codes
- Post-confirmation delivery requests with courier minimum fares, adjustable bids and customer selection
- One-tap Google Maps directions for courier pickup and drop-off points
- Private customer courier tracking with live map updates and collection/drop-off ETAs
- LP Gas retail and wholesale profile with cylinder sizes, refills, exchanges, licence and safety controls
- Owner and worker POS sales with the authenticated seller recorded on every sales-ledger posting
- FIFO purchase-cost layers for accurate profit across differently priced stock batches
- Owner-delegated purchasing and expense permissions for multiple regular workers

## Production connection

Create a Supabase project, run `supabase/schema.sql`, then connect the UI with
`@supabase/supabase-js`. Keep `SUPABASE_SERVICE_ROLE_KEY` server-side only;
the browser should use the anonymous key with Row Level Security enabled.

The deployment is static and compatible with Cloudflare Pages. A Cloudflare
Worker or Supabase Edge Function must create worker Auth accounts and send
invitations because those actions require the server-side service-role key.
Keep all privileged keys in Worker environment variables.

Public-facing pages and the admin workspace display the design credit:
`Designed by Tempest Technologies`.

## Reserved site administrator

The authenticated Supabase account using `dylankoshita96@gmail.com` is assigned
the single `site_admin` role by a database trigger. For an existing Supabase
project, run `supabase/migrations/20261119_reserved_admin_email.sql` once in the
SQL editor. The public portal login routes that email to `/admin/`.

For an existing database, also run
`supabase/migrations/20261119_subscriptions_and_shop_admin.sql` to add shop
subscriptions, trial periods, admin shop management and the related RLS rules.

Run `supabase/migrations/20261119_shop_proof_uploads.sql` to add the private
`shop-proofs` Storage bucket, proof metadata and applicant/admin-only policies.

Run `supabase/migrations/20261119_offline_inventory_sync.sql` to add the
idempotent product-movement function, movement audit table and Realtime product
publication. The browser integration expects the authenticated Supabase client
at `window.zwconnectSupabase`.

Run `supabase/migrations/20261120_full_offline_action_sync.sql` to enable the
full offline action queue for sales, worker invitation requests, owner
applications, approval decisions, shop edits/deletions and subscriptions. Each
action uses a client-generated UUID and is removed from the device only after
Supabase confirms the transaction. Configure each loaded shop with its real
Supabase UUID (`shop.dbId`) or provide the name-to-UUID map in
`localStorage['zwconnect-shop-database-ids']` when using the static adapter.

Deploy `supabase/functions/process-worker-invitation/index.ts` as the
`process-worker-invitation` Edge Function. It uses the service-role key only on
the server to send the Auth invitation, assign the single `worker` role and
create the shop-scoped worker record after the queued request reaches Supabase.

Run `supabase/migrations/20261120_case_and_unit_sales.sql` to add case size,
case price, package type and store trading-mode fields. A store may be retail
only, wholesale only, or hybrid. Inventory remains stored in singular base
units: a case sale deducts `cases sold × case_size`, while a singular sale
deducts only its entered unit quantity. The database rejects a retail sale at
a wholesale-only store and a case sale at a retail-only store.

Run `supabase/migrations/20261120_payments_and_couriers.sql`, followed by
`supabase/migrations/20261120_cart_delivery_bidding.sql`, to enable owner-set
payment details, private image/text payment proof, atomic shop confirmation,
customer order tracking, delivery publication and courier fare bidding. Stock,
sale, movement-audit and ledger rows are posted only when an authorised shop
owner or worker confirms the payment.

Run `supabase/migrations/20261120_production_portal_hardening.sql`, followed by
`supabase/migrations/20261120_courier_live_tracking.sql`, to enforce one active
courier job and enable private live tracking. Courier coordinates are accepted
only for the assigned active job and are exposed to a customer only when the
matching order ID and private tracking token are supplied.

Run `supabase/migrations/20261120_lpg_profile_and_sales_ledger.sql` to add the
LP Gas retail/wholesale profile, cylinder and safety metadata, an owner-facing
sales register and attributable ledger postings. Direct POS sales post a
`pos_sale` entry whose completed-by name and non-overlapping role are stamped
from the authenticated Supabase account.

Run `supabase/migrations/20261120_fifo_purchasing_and_expenses.sql` to add
shop-scoped purchasing privileges, separate purchase batches, supplier invoices,
procurement expenses and FIFO cost allocation. Each sale consumes the oldest
remaining cost layers, records COGS per sale item and calculates gross and net
profit without merging morning and afternoon purchase prices.

Run `supabase/migrations/20261120_production_portal_hardening.sql` last. It
adds bulk shop/courier subscriptions, administrator-managed business profiles,
the support and complaints hub, 20-record attended-ticket and audit retention,
the three-image shop profile limit, owner subscription requests, idempotent
offline endpoints, and the one-active-delivery courier/customer receipt
handoff. The partial unique index and RPC transition checks enforce the courier
limit even when two devices submit at the same time.

Product links use the canonical domain `https://zwconnect.co.zw`. Point that
domain at the Cloudflare deployment before sharing links publicly so previews
and product destinations resolve correctly.

Run `supabase/migrations/20261120_payments_and_couriers.sql` after the case/unit
migration. It adds payment methods, pending customer orders, ledger entries,
platform fee rules, courier applications, approved courier profiles, rate
cards, courier subscriptions and deliveries. Stock is never deducted when a
customer merely submits payment details: the owner confirmation function locks
and validates stock, creates the sale and ledger entries, deducts base units,
and opens any requested delivery in one transaction.
