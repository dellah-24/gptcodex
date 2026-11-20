# ZWConnect reorganized package

This archive is the modular, Cloudflare Pages-compatible version of ZWConnect.

## Included

- 9 primary application routes
- Dedicated admin and courier portals
- Shared Supabase configuration and account-bound offline action queue
- Customer authentication, cart, payment proof and delivery workflow
- Owner, worker, inventory and purchasing route entry points
- All Supabase SQL migrations and the worker invitation Edge Function
- PWA manifest, service worker, icons and offline shell cache
- Architecture and production setup documentation

## Deployment

Upload the repository to Cloudflare Pages and use `dist` as the static output
directory. Configure the Supabase project URL and anonymous browser key through
the existing ZWConnect configuration mechanism. Never expose the Supabase
service-role key in browser files.

## Validation

All JavaScript files pass `node --check`; the manifest and hosting JSON parse
successfully; all local HTML asset references resolve; duplicate HTML IDs were
checked. Managed browser preview was unavailable because the preview relay did
not open its browser port, so this package records static and syntax validation
only.
