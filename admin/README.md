# TapCard ZW admin portal

This is a static, mobile-friendly administration portal intended for Cloudflare
Pages. Authentication and authorization are handled by Supabase. The browser
uses only the public anonymous key; database Row Level Security and the
`is_admin()` checks protect all platform data.

## Deploy

1. Create a Supabase project and run
   `supabase/migrations/202611240001_commercial_platform.sql`.
2. Sign up the intended administrator through the app or Supabase Auth.
3. Edit and run `supabase/promote-admin.sql` in the SQL editor.
4. In Cloudflare Pages set the root directory to `admin`, build command to
   `npm run build`, and output directory to `dist`.
5. Add `SUPABASE_URL` and `SUPABASE_ANON_KEY` as build environment variables.
   Never add the service-role key.
6. Add the final admin domain to Supabase Auth's allowed redirect URLs.

The portal supports dashboard metrics, customer search, subscription and trial
changes, recent activity monitoring, open support tickets and a server-side
admin audit trail.
