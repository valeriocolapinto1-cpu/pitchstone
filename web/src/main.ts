import DOMPurify from "dompurify";
import { marked } from "marked";
import { AREAS, LABELS, NODE_TYPES, type NodeRecord, titleKey } from "./model";
import { Repository } from "./repository";
import { IndexedDBStore } from "./store";
import { HttpTransport, SyncClient } from "./sync";

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

function open(id: string) {
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

let saveTimer: number | undefined;
function scheduleSave() {
  clearTimeout(saveTimer);
  saveTimer = window.setTimeout(save, 600);
}

function save() {
  if (!selected) return;
  const node = repo.updateNode(selected, {
    title: $<HTMLInputElement>("title").value,
    type: $<HTMLSelectElement>("type").value as NodeRecord["type"],
    area: $<HTMLSelectElement>("area").value as NodeRecord["area"],
    tags: $<HTMLInputElement>("tags").value.split(",").map((t) => t.trim()).filter(Boolean),
    body_md: $<HTMLTextAreaElement>("body").value,
  });
  renderPreview(node);
  renderList();
  void store.flush();
}

async function runSync() {
  try {
    const result = await sync.sync();
    $("status").textContent = result === "skipped" ? $("status").textContent : `Sincronizzato ${new Date().toLocaleTimeString()}`;
    renderList();
    if (selected && document.activeElement?.tagName !== "TEXTAREA") open(selected);
  } catch {
    $("status").textContent = "Offline: le modifiche partono al ritorno della rete";
  }
}

async function main() {
  await store.load();
  for (const t of NODE_TYPES) $("type").append(new Option(LABELS.type[t], t));
  for (const a of AREAS) $("area").append(new Option(LABELS.area[a], a));
  for (const id of ["title", "type", "area", "tags", "body"]) $(id).addEventListener("input", scheduleSave);
  $("search").addEventListener("input", renderList);
  $("new").onclick = () => { const n = repo.createNode({ title: "Nuovo nodo" }); open(n.id); };
  $("trash").onclick = () => { if (selected) { repo.trashNode(selected); selected = undefined; $("editor").hidden = true; $("preview").replaceChildren(); renderList(); } };
  $("preview").addEventListener("click", (e) => {
    const title = (e.target as HTMLElement).dataset.title;
    if (!title) return;
    const found = active().find((n) => titleKey(n.title) === titleKey(title)) ?? repo.createNode({ title });
    open(found.id);
  });
  document.addEventListener("keydown", (e) => {
    if (!(e.metaKey || e.ctrlKey)) return;
    if (e.key === "k") { e.preventDefault(); $("search").focus(); }
    if (e.key === "n") { e.preventDefault(); $("new").click(); }
  });
  renderList();
  if ("serviceWorker" in navigator) void navigator.serviceWorker.register("/sw.js");
  await runSync();
  setInterval(runSync, 30_000);
  window.addEventListener("online", runSync);
}

void main();
