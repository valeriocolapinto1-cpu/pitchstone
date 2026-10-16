import { defineConfig } from "vite";

// La PWA è servita dal Worker ai-proxy (stessa origine di /sync e /ai, dietro
// Cloudflare Access): in sviluppo le chiamate vanno al Worker locale.
export default defineConfig({
  build: { outDir: "dist", emptyOutDir: true },
  server: { proxy: { "/sync": "http://localhost:8787", "/ai": "http://localhost:8787", "/storage": "http://localhost:8787" } },
});
