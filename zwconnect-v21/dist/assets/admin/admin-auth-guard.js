(function(){
 async function authenticate(form){
  const client=window.zwconnectSupabase;
  const submit=form.querySelector('[type="submit"]');
  const values=Object.fromEntries(new FormData(form));
  if(!client){window.alert('Supabase is not configured. Add the project URL and anonymous key before admin sign-in.');return}
  submit.disabled=true;submit.textContent='Verifying administrator…';
  try{
   const {data,error}=await client.auth.signInWithPassword({email:String(values.email||'').trim().toLowerCase(),password:values.password});
   if(error)throw error;
   const {data:role,error:roleError}=await client.from('account_roles').select('role').eq('user_id',data.user.id).single();
   if(roleError||role?.role!=='site_admin')throw roleError||new Error('This account is not assigned the site_admin role.');
   await window.ZWOffline?.setContext('site_admin',{userId:data.user.id,email:data.user.email,shopId:null,force:true});
   window.unlock?.();window.toast?.('Administrator identity verified','shield-check');
  }catch(error){
   try{await client.auth.signOut({scope:'local'})}catch{}
   window.toast?.(error.message||'Administrator sign-in failed','shield-x');
  }finally{submit.disabled=false;submit.textContent='Continue to administration'}
 }
 document.addEventListener('submit',event=>{
  if(event.target.id!=='adminLogin'||new URLSearchParams(location.search).get('demo')==='1')return;
  event.preventDefault();event.stopImmediatePropagation();authenticate(event.target);
 },true);
})();
