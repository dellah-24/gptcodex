import {createClient} from 'https://esm.sh/@supabase/supabase-js@2'

const headers={'Content-Type':'application/json','Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type'}

Deno.serve(async request=>{
 if(request.method==='OPTIONS')return new Response('ok',{headers})
 try{
  const supabaseUrl=Deno.env.get('SUPABASE_URL')!,anonKey=Deno.env.get('SUPABASE_ANON_KEY')!,serviceKey=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  const authorization=request.headers.get('Authorization')||''
  const caller=createClient(supabaseUrl,anonKey,{global:{headers:{Authorization:authorization}}})
  const admin=createClient(supabaseUrl,serviceKey,{auth:{autoRefreshToken:false,persistSession:false}})
  const {invitation_id}=await request.json()
  const {data:invitation,error:readError}=await caller.from('worker_invitation_requests').select('*').eq('id',invitation_id).single()
  if(readError||!invitation)throw readError||new Error('Invitation request not found')
  if(invitation.status==='sent'||invitation.status==='accepted')return new Response(JSON.stringify({ok:true,status:invitation.status}),{headers})
  const {count}=await admin.from('shop_workers').select('id',{count:'exact',head:true}).eq('shop_id',invitation.shop_id).eq('active',true)
  if((count||0)>=7)throw new Error('This shop has reached the 7-worker limit')
  let userId:string|undefined,page=1
  while(!userId&&page<=10){const {data,error}=await admin.auth.admin.listUsers({page,perPage:1000});if(error)throw error;userId=data.users.find(user=>user.email?.toLowerCase()===invitation.email.toLowerCase())?.id;if(data.users.length<1000)break;page++}
  if(!userId){const {data,error}=await admin.auth.admin.inviteUserByEmail(invitation.email,{data:{full_name:invitation.name,zwconnect_shop_id:invitation.shop_id}});if(error)throw error;userId=data.user.id}
  const {data:existingRole,error:roleReadError}=await admin.from('account_roles').select('role').eq('user_id',userId).maybeSingle();if(roleReadError)throw roleReadError
  if(existingRole&&existingRole.role!=='worker')throw new Error('This email already has a different platform role')
  if(!existingRole){const {error}=await admin.from('account_roles').insert({user_id:userId,role:'worker'});if(error)throw error}
  const {error:workerError}=await admin.from('shop_workers').upsert({shop_id:invitation.shop_id,user_id:userId,job:invitation.job,active:true,invited_by:invitation.requested_by},{onConflict:'shop_id,user_id'});if(workerError)throw workerError
  const {error:updateError}=await admin.from('worker_invitation_requests').update({status:'sent',processed_at:new Date().toISOString()}).eq('id',invitation.id);if(updateError)throw updateError
  return new Response(JSON.stringify({ok:true,status:'sent'}),{headers})
 }catch(error){return new Response(JSON.stringify({ok:false,error:String(error instanceof Error?error.message:error)}),{status:400,headers})}
})
