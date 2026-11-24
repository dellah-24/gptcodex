// These are public client values; authorization is enforced by Supabase RLS.
// Replace them for deployment. Never use the service-role key here.
window.TAPCARD_CONFIG = window.TAPCARD_CONFIG || {
  supabaseUrl: "https://YOUR_PROJECT.supabase.co",
  supabaseAnonKey: "YOUR_PUBLIC_ANON_KEY"
};
