# ZWConnect route and module architecture

The deployable output remains in `dist/`, but code is grouped by responsibility instead of one flat assets directory.

## Public routes

- `/` — marketplace, profiles, shops and product browsing
- `/account/` — customer account entry
- `/cart/` — cart and payment-proof entry
- `/owner/` — owner workspace entry
- `/worker/` — worker POS entry
- `/inventory/` — inventory workspace entry
- `/purchasing/` — purchasing and expense entry
- `/admin/` — dedicated site administrator portal
- `/courier/` — dedicated courier portal

## Shared modules

- `assets/core/` — Supabase client, offline action queue and route shell
- `assets/marketplace/` — public discovery and shop application
- `assets/customer/` — customer authentication, cart and order flow
- `assets/portals/` — owner and worker feature implementation
- `assets/admin/` — site administration only
- `assets/courier/` — courier jobs, rates and tracking
- `assets/brand/` — logo, favicon and PWA icons

Role enforcement remains in Supabase Row Level Security and RPC functions. Route separation improves navigation and maintainability but does not replace database authorization.
