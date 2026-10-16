// Guscio dell'app in cache: la PWA si apre anche offline (i dati sono in IndexedDB).
const CACHE = "pitchstone-v1";
self.addEventListener("install", (e) => e.waitUntil(caches.open(CACHE).then((c) => c.addAll(["/", "/index.html"]))));
self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || ["/sync", "/ai", "/storage"].some((p) => url.pathname.startsWith(p))) return;
  e.respondWith(fetch(e.request).then((r) => {
    const copy = r.clone();
    caches.open(CACHE).then((c) => c.put(e.request, copy));
    return r;
  }).catch(() => caches.match(e.request).then((r) => r ?? caches.match("/index.html"))));
});
