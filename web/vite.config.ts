import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { defineConfig, type Plugin } from "vite";

/** Scrive in `dist/sw.js` l'elenco dei file con hash: il service worker li mette in cache all'installazione. */
function precache(): Plugin {
  return {
    name: "pitchstone-precache",
    apply: "build",
    closeBundle() {
      const dist = join(process.cwd(), "dist");
      const assets = readdirSync(join(dist, "assets")).map((name) => `/assets/${name}`);
      const worker = join(dist, "sw.js");
      writeFileSync(worker, readFileSync(worker, "utf8").replace('"__PRECACHE__"', JSON.stringify(assets)));
    },
  };
}

// La PWA è servita dal Worker ai-proxy (stessa origine di /sync e /ai, dietro
// Cloudflare Access): in sviluppo le chiamate vanno al Worker locale.
export default defineConfig({
  plugins: [precache()],
  build: { outDir: "dist", emptyOutDir: true },
  server: {
    proxy: {
      "/sync": "http://localhost:8787", "/ai": "http://localhost:8787", "/storage": "http://localhost:8787",
      "/account": "http://localhost:8787", "/status": "http://localhost:8787",
    },
  },
});
