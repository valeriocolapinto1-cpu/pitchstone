import DOMPurify from "dompurify";
import { marked } from "marked";
import { AREAS, LABELS, NODE_TYPES, type NodeRecord, titleKey } from "./model";
import { Repository } from "./repository";
import { IndexedDBStore } from "./store";
import { AuthError, HttpTransport, SyncClient } from "./sync";

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const store = new IndexedDBStore();
const deviceId = localStorage.getItem("deviceId") ?? `pc-${crypto.randomUUID().slice(0, 8)}`;
localStorage.setItem("deviceId", deviceId);
const repo = new Repository(store, deviceId);
const sync = new SyncClient(store, new HttpTransport(), deviceId);
let selected: string | undefined;

function active(): NodeRecord[] {
  return store.nodes().filter((n) => !n.deleted_at).sort((a, b) => b.updated_at.localeCompare(a.updated_at));
}

function renderList() {
  const q = titleKey($<HTMLInputElement>("search").value);
  const list = $("list");
  list.replaceChildren(...active()
    .filter((n) => !q || titleKey(`${n.title} ${n.body_md}`).includes(q))
    .map((n) => {
      const li = document.createElement("li");
      li.textContent = n.title || "Senza titolo";
      li.className = n.id === selected ? "active" : "";
      li.onclick = () => open(n.id);
      return li;
    }));
}

function renderPreview(node: NodeRecord) {
  const md = node.body_md.replace(/\[\[([^\]|#\n]+)(?:[#|][^\]\n]*)?\]\]/g, (_, t: string) => `<span class="wiki" data-title="${t.replace(/"/g, "")}">${t}</span>`);
  $("preview").innerHTML = DOMPurify.sanitize(`<h1>${DOMPurify.sanitize(node.title)}</h1>` + (marked.parse(md) as string));
}

/** Salva su disco dopo ogni modifica; un errore resta visibile nello stato. */
function persist() {
  store.flush().catch(() => { $("status").textContent = "Errore nel salvataggio locale"; });
}

function open(id: string) {
  flushSave();
  const node = store.node(id);
  if (!node) return;
  selected = id;
  $("editor").hidden = false;
  $<HTMLInputElement>("title").value = node.title;
  $<HTMLSelectElement>("type").value = node.type;
  $<HTMLSelectElement>("area").value = node.area;
  $<HTMLInputElement>("tags").value = node.tags.join(", ");
  $<HTMLTextAreaElement>("body").value = node.body_md;
  renderPreview(node);
  renderList();
}

// Il nodo va fissato quando si pianifica il salvataggio: nel frattempo se ne può aprire un altro.
let saveTimer: number | undefined;
let saveId: string | undefined;
function scheduleSave() {
  clearTimeout(saveTimer);
  saveId = selected;
  saveTimer = window.setTimeout(flushSave, 600);
}

/** Salva subito la modifica in attesa: prima di cambiare nodo, del cestino e della sync. */
function flushSave() {
  clearTimeout(saveTimer);
  saveTimer = undefined;
  const id = saveId;
  saveId = undefined;
  if (id) save(id);
}

function save(id: string) {
  // Il modulo mostra ancora questo nodo: flushSave parte prima di ogni cambio.
  if (!store.node(id)) return;
  const node = repo.updateNode(id, {
    title: $<HTMLInputElement>("title").value,
    type: $<HTMLSelectElement>("type").value as NodeRecord["type"],
    area: $<HTMLSelectElement>("area").value as NodeRecord["area"],
    tags: $<HTMLInputElement>("tags").value.split(",").map((t) => t.trim()).filter(Boolean),
    body_md: $<HTMLTextAreaElement>("body").value,
  });
  renderPreview(node);
  renderList();
  persist();
}

/** Modifiche rifiutate dal server: si scartano (vale il server) o si riprovano. */
function renderRejections() {
  const box = $("rejections");
  box.hidden = sync.rejections.length === 0;
  box.replaceChildren(...sync.rejections.map((p) => {
    const row = document.createElement("div");
    const label = document.createElement("span");
    const name = p.entity === "node" ? store.node(p.id)?.title || "Senza titolo" : "Collegamento";
    label.textContent = `${name}: ${p.rejection}`;
    const button = (text: string, action: () => void) => {
      const b = document.createElement("button");
      b.textContent = text;
      b.onclick = () => {
        action();
        persist();
        renderRejections();
        renderList();
        if (selected && !store.node(selected)) closeEditor();
        void runSync();
      };
      return b;
    };
    row.append(label, button("Scarta", () => sync.discard(p.entity, p.id)), button("Riprova", () => sync.retry(p.entity, p.id)));
    return row;
  }));
}

function closeEditor() {
  selected = undefined;
  $("editor").hidden = true;
  $("preview").replaceChildren();
}

/** Mentre si scrive il modulo non si ricarica: si perderebbero cursore e testo. */
function editing(): boolean {
  return saveTimer !== undefined || $("editor").contains(document.activeElement);
}

async function runSync() {
  flushSave();
  try {
    const result = await sync.sync();
    $("status").textContent = result === "skipped" ? $("status").textContent : `Sincronizzato ${new Date().toLocaleTimeString()}`;
  } catch (error) {
    if (error instanceof AuthError) {
      const link = document.createElement("a");
      link.href = "/";
      link.textContent = "Accedi di nuovo";
      link.onclick = (e) => { e.preventDefault(); location.reload(); };
      $("status").replaceChildren("Sessione scaduta: ", link);
    } else {
      $("status").textContent = "Offline: le modifiche partono al ritorno della rete";
    }
  }
  renderRejections();
  renderList();
  if (selected && !store.node(selected)) closeEditor();
  else if (selected && !editing()) open(selected);
}

/**
 * Una sola scheda attiva alla volta: l'archivio è un unico valore in IndexedDB e due schede
 * si sovrascriverebbero a vicenda. Le altre aspettano che la prima si chiuda.
 */
function holdTab(): Promise<void> {
  if (!navigator.locks) return Promise.resolve();
  return new Promise((resolve) => {
    // Il lock resta preso finché la scheda è aperta.
    const hold = () => { resolve(); return new Promise<never>(() => {}); };
    void navigator.locks.request("pitchstone", { ifAvailable: true }, (lock) => {
      if (lock) return hold();
      $("blocked").hidden = false;
      void navigator.locks.request("pitchstone", () => {
        $("blocked").hidden = true;
        return hold();
      });
      return undefined;
    });
  });
}

async function main() {
  await holdTab();
  await store.load();
  for (const t of NODE_TYPES) $("type").append(new Option(LABELS.type[t], t));
  for (const a of AREAS) $("area").append(new Option(LABELS.area[a], a));
  for (const id of ["title", "type", "area", "tags", "body"]) $(id).addEventListener("input", scheduleSave);
  $("search").addEventListener("input", renderList);
  $("new").onclick = () => {
    flushSave();
    const n = repo.createNode({ title: "Nuovo nodo" });
    persist();
    open(n.id);
  };
  $("trash").onclick = () => {
    flushSave();
    if (!selected) return;
    repo.trashNode(selected);
    persist();
    closeEditor();
    renderList();
  };
  $("preview").addEventListener("click", (e) => {
    const title = (e.target as HTMLElement).dataset.title;
    if (!title) return;
    flushSave();
    let found = active().find((n) => titleKey(n.title) === titleKey(title));
    if (!found) {
      found = repo.createNode({ title });
      persist();
    }
    open(found.id);
  });
  // Chiudendo o nascondendo la scheda la modifica in attesa va su disco.
  window.addEventListener("pagehide", () => { flushSave(); persist(); });
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") { flushSave(); persist(); }
  });
  document.addEventListener("keydown", (e) => {
    if (!(e.metaKey || e.ctrlKey)) return;
    if (e.key === "k") { e.preventDefault(); $("search").focus(); }
    if (e.key === "n") { e.preventDefault(); $("new").click(); }
  });
  renderList();
  renderRejections();
  if ("serviceWorker" in navigator) void navigator.serviceWorker.register("/sw.js");
  await runSync();
  setInterval(runSync, 30_000);
  window.addEventListener("online", runSync);
}

void main();
