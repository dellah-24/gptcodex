const CACHE='zwconnect-shell-v14-modular';
const SHELL=[
 './','./index.html','./manifest.webmanifest','./admin/','./courier/','./owner/','./worker/','./inventory/','./purchasing/','./account/','./cart/',
 './assets/core/supabase-config.js','./assets/core/offline-actions.js','./assets/core/route-shell.css','./assets/core/route-shell.js',
 './assets/marketplace/styles.css','./assets/marketplace/app.js',
 './assets/customer/cart-flow.css','./assets/customer/cart-flow.js','./assets/customer/customer-auth.css','./assets/customer/customer-auth.js',
 './assets/portals/production-portals.css','./assets/portals/production-portals.js',
 './assets/admin/admin.css','./assets/admin/admin-production.css','./assets/admin/admin-auth-guard.js','./assets/admin/admin.js','./assets/admin/admin-production.js',
 './assets/courier/courier.css','./assets/courier/courier-flow.css','./assets/courier/courier.js','./assets/courier/courier-production.js',
 './assets/brand/zwconnect-logo.png','./assets/brand/zwconnect-favicon.png','./assets/brand/zwconnect-icon-192.png','./assets/brand/zwconnect-icon-512.png'
];
self.addEventListener('install',event=>{event.waitUntil(caches.open(CACHE).then(cache=>cache.addAll(SHELL)).then(()=>self.skipWaiting()))});
self.addEventListener('activate',event=>{event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(key=>key!==CACHE).map(key=>caches.delete(key)))).then(()=>self.clients.claim()))});
self.addEventListener('fetch',event=>{if(event.request.method!=='GET')return;event.respondWith(fetch(event.request).then(response=>{const copy=response.clone();caches.open(CACHE).then(cache=>cache.put(event.request,copy));return response}).catch(()=>caches.match(event.request).then(cached=>cached||caches.match('./index.html'))))});
