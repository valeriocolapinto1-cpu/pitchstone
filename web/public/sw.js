// Guscio dell'app in cache: la PWA si apre anche offline (i dati sono in IndexedDB).
const CACHE = "pitchstone-v5";
// Riempito dalla build con i file con hash (vite.config.ts); in sviluppo resta vuoto.
const ASSETS = "__PRECACHE__";
const SHELL = ["/", "/index.html", "/manifest.webmanifest", "/icon.svg", "/icon-192.png", "/icon-512.png", "/apple-touch-icon.png"];
// Percorsi che parlano con il Worker: mai in cache.
const API = ["/sync", "/ai", "/storage", "/account", "/status", "/health", "/cdn-cgi"];

self.addEventListener("install", (e) => {
  e.waitUntil(
    caches.open(CACHE)
      // Un file mancante non deve impedire l'installazione: gli asset si prendono uno a uno.
      .then((c) => Promise.all([...SHELL, ...(Array.isArray(ASSETS) ? ASSETS : [])].map((url) => c.add(url).catch(() => {}))))
      .then(() => self.skipWaiting()),
  );
});
// Via le cache vecchie, che potevano contenere redirect al login di Access.
self.addEventListener("activate", (e) => e.waitUntil(
  caches.keys()
    .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
    .then(() => self.clients.claim()),
));
self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  // Altre origini (Ollama su localhost) passano dirette: una pagina in cache al posto
  // della loro risposta farebbe sembrare acceso il modello locale.
  if (url.origin !== self.location.origin) return;
  if (e.request.method !== "GET" || API.some((p) => url.pathname === p || url.pathname.startsWith(`${p}/`))) return;
  e.respondWith(fetch(e.request).then((r) => {
    // Solo risposte vere della nostra origine: mai un redirect al login o un errore.
    if (r.ok && r.type === "basic") {
      const copy = r.clone();
      caches.open(CACHE).then((c) => c.put(e.request, copy));
    }
    return r;
  }).catch(() => caches.match(e.request).then((r) => r ?? caches.match("/index.html"))));
});
