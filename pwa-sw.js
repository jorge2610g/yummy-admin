const ADMIN_CACHE="yummypro-admin-v2331-demo-api-settings";
const ADMIN_OFFLINE="/offline.html";
const ADMIN_CORE=[ADMIN_OFFLINE,"/manifest.webmanifest","/pwa-icon.svg","/icon-192.png","/icon-512.png","/apple-touch-icon.png"];
self.addEventListener("install",event=>{event.waitUntil(caches.open(ADMIN_CACHE).then(c=>c.addAll(ADMIN_CORE)))});
self.addEventListener("activate",event=>{event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k.startsWith("yummypro-admin-")&&k!==ADMIN_CACHE).map(k=>caches.delete(k)))).then(()=>self.clients.claim()))});
self.addEventListener("message",event=>{if(event.data?.type==="SKIP_WAITING")self.skipWaiting()});
self.addEventListener("fetch",event=>{
 const req=event.request;if(req.method!=="GET")return;
 const url=new URL(req.url);if(url.origin!==self.location.origin)return;
 if(ADMIN_CORE.includes(url.pathname)){
  event.respondWith(
   fetch(req,{cache:"no-store"}).then(async response=>{
    if(response?.ok){const cache=await caches.open(ADMIN_CACHE);await cache.put(req,response.clone())}
    return response;
   }).catch(()=>caches.match(req).then(hit=>hit||caches.match(url.pathname)))
  );
  return;
 }
 if(req.mode==="navigate"){event.respondWith(fetch(req).catch(()=>caches.match(ADMIN_OFFLINE)))}
});
