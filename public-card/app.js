const config=window.TAPCARD_CONFIG||{};
const configured=config.supabaseUrl?.startsWith("https://")&&config.supabaseAnonKey;
const client=configured?supabase.createClient(config.supabaseUrl,config.supabaseAnonKey):null;
const $=id=>document.getElementById(id);
const slug=location.pathname.match(/\/c\/([a-z0-9]{8,32})\/?$/i)?.[1]?.toLowerCase()||new URLSearchParams(location.search).get("c");
let card=null;

const safeUrl=value=>{if(!value)return null;try{const url=new URL(/^https?:\/\//i.test(value)?value:`https://${value}`);return ["http:","https:"].includes(url.protocol)?url.href:null}catch{return null}};
const addLink=(label,href,kind="link")=>{if(!href)return;const a=document.createElement("a");a.className=`link ${kind}`;a.href=href;a.target=href.startsWith("http")?"_blank":"_self";a.rel="noopener";const strong=document.createElement("strong");strong.textContent=label;const small=document.createElement("small");small.textContent=href.replace(/^https?:\/\//,"").replace(/\/$/,"");a.append(strong,small);$("links").append(a)};
const escapeVcard=value=>String(value||"").replace(/\\/g,"\\\\").replace(/;/g,"\\;").replace(/,/g,"\\,").replace(/\r?\n/g,"\\n");

function render(value){
  card=value;document.title=`${value.name} · TapCard ZW`;
  document.body.dataset.theme=value.theme||"green";
  $("name").textContent=value.name;$("role").textContent=[value.title,value.company].filter(Boolean).join(" • ");
  $("monogram").textContent=value.name.split(/\s+/).slice(0,2).map(part=>part[0]).join("").toUpperCase()||"TZ";
  if(value.bio){$("bio").textContent=value.bio;$("bio").classList.remove("hidden")}
  addLink("Call",value.phone?`tel:${value.phone}`:null,"phone");
  addLink("Email",value.email?`mailto:${value.email}`:null,"email");
  addLink("Website",safeUrl(value.website));
  addLink("LinkedIn",safeUrl(value.linkedin));
  addLink("Instagram",safeUrl(value.instagram));
  addLink("WhatsApp",value.whatsapp?`https://wa.me/${value.whatsapp.replace(/\D/g,"")}`:null);
  addLink("Book a meeting",safeUrl(value.booking_url),"booking");
  if(value.address)addLink("Location",`https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(value.address)}`,"location");
  $("loading").classList.add("hidden");$("profile").classList.remove("hidden");
}

function downloadContact(){
  const lines=["BEGIN:VCARD","VERSION:3.0",`FN:${escapeVcard(card.name)}`];
  if(card.company)lines.push(`ORG:${escapeVcard(card.company)}`);if(card.title)lines.push(`TITLE:${escapeVcard(card.title)}`);
  if(card.phone)lines.push(`TEL;TYPE=CELL:${escapeVcard(card.phone)}`);if(card.email)lines.push(`EMAIL:${escapeVcard(card.email)}`);
  if(card.website)lines.push(`URL:${safeUrl(card.website)}`);if(card.address)lines.push(`ADR:;;${escapeVcard(card.address)};;;;`);
  if(card.bio)lines.push(`NOTE:${escapeVcard(card.bio)}`);lines.push("END:VCARD");
  const a=document.createElement("a");a.href=URL.createObjectURL(new Blob([lines.join("\r\n")+"\r\n"],{type:"text/vcard"}));
  a.download=`${card.name.replace(/[^a-z0-9]+/gi,"-")||"tapcard"}.vcf`;a.click();setTimeout(()=>URL.revokeObjectURL(a.href),1000);
}

$("saveContact").addEventListener("click",downloadContact);
$("shareCard").addEventListener("click",async()=>{if(navigator.share)await navigator.share({title:card.name,text:`Connect with ${card.name}`,url:location.href});else{await navigator.clipboard.writeText(location.href);$("shareCard").textContent="Link copied"}});
$("leadForm").addEventListener("submit",async event=>{
  event.preventDefault();if($("websiteCheck").value)return;
  if(!$("leadEmail").value.trim()&&!$("leadPhone").value.trim()){$("formMessage").textContent="Add an email address or phone number.";return}
  $("submitLead").disabled=true;$("formMessage").textContent="Sending securely…";
  const {error}=await client.rpc("tapcard_submit_lead",{card_slug:slug,lead_name:$("leadName").value.trim(),lead_email:$("leadEmail").value.trim(),lead_phone:$("leadPhone").value.trim(),lead_company:$("leadCompany").value.trim(),lead_note:$("leadNote").value.trim(),consent:$("consent").checked});
  if(error){$("formMessage").textContent=error.message;$("submitLead").disabled=false;return}
  $("leadForm").reset();$("formMessage").textContent="Details sent. You are now connected.";$("submitLead").textContent="Sent";
});

async function load(){
  if(!client||!slug){$("loading").classList.add("hidden");$("error").classList.remove("hidden");return}
  const {data,error}=await client.rpc("tapcard_get_public_card",{card_slug:slug});
  if(error||!data){$("loading").classList.add("hidden");$("error").classList.remove("hidden");return}render(data);
}
load();
