import{cpSync,mkdirSync,rmSync,writeFileSync}from"node:fs";
const url=process.env.SUPABASE_URL||"",key=process.env.SUPABASE_ANON_KEY||"";
if(!url.startsWith("https://")||!key)throw new Error("SUPABASE_URL and SUPABASE_ANON_KEY are required.");
rmSync("dist",{recursive:true,force:true});mkdirSync("dist");
for(const file of["index.html","app.js","styles.css","_headers","_redirects"])cpSync(file,`dist/${file}`);
writeFileSync("dist/config.js",`window.TAPCARD_CONFIG=${JSON.stringify({supabaseUrl:url,supabaseAnonKey:key})};\n`);
console.log("Built TapCard public profiles in public-card/dist");
