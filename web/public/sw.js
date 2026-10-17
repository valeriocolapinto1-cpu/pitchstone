// Guscio dell'app in cache: la PWA si apre anche offline (i dati sono in IndexedDB).
const CACHE = "pitchstone-v4";
self.addEventListener("install", (e) => e.waitUntil(caches.open(CACHE).then((c) => c.addAll(["/", "/index.html"]))));
// Via le cache vecchie, che potevano contenere redirect al login di Access.
self.addEventListener("activate", (e) => e.waitUntil(
  caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))),
));
self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  // Altre origini (Ollama su localhost) passano dirette: una pagina in cache al posto
  // della loro risposta farebbe sembrare acceso il modello locale.
  if (url.origin !== self.location.origin) return;
  if (e.request.method !== "GET" || ["/sync", "/ai", "/storage", "/account", "/cdn-cgi"].some((p) => url.pathname.startsWith(p))) return;
  e.respondWith(fetch(e.request).then((r) => {
    // Solo risposte vere della nostra origine: mai un redirect al login o un errore.
    if (r.ok && r.type === "basic") {
      const copy = r.clone();
      caches.open(CACHE).then((c) => c.put(e.request, copy));
    }
    return r;
  }).catch(() => caches.match(e.request).then((r) => r ?? caches.match("/index.html"))));
});
