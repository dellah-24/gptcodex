# Public recipient profiles

This Cloudflare Pages application renders `/c/{slug}` links without requiring
the recipient to install TapCard. It supports contact saving, social and booking
links, Web Share, two-way contact exchange, consent capture and view analytics.

Deploy with root directory `public-card`, build command `npm run build`, output
directory `dist`, and the public `SUPABASE_URL` and `SUPABASE_ANON_KEY` build
variables. Apply both Supabase migrations first. The resulting domain must be
passed to the Android build as `PUBLIC_PROFILE_BASE_URL`.
