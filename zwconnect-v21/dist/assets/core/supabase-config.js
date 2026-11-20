(function(){
 const config=window.ZWCONNECT_CONFIG||{};
 const url=config.supabaseUrl||document.querySelector('meta[name="zwconnect-supabase-url"]')?.content||'';
 const anonKey=config.supabaseAnonKey||document.querySelector('meta[name="zwconnect-supabase-anon-key"]')?.content||'';
 if(url&&anonKey&&window.supabase?.createClient){
  window.zwconnectSupabase=window.supabase.createClient(url,anonKey,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true},global:{headers:{'X-Client-Info':'zwconnect-web/1.0'}}});
 }
})();
