import {
  answer, type ChatMessage, corpus, DEFAULT_OLLAMA_MODEL, linkCitations, loadSettings, nodeFromLink,
  OllamaProvider, saveSettings, WorkerProvider,
} from "./chat";
import { clearLocal, ERASE_CONFIRMATION, eraseServer, exportEverything } from "./account";
import { InkEditor } from "./inkEditor";
import { AREAS, isLocalOnly, LABELS, LOCAL_ONLY_TAG, NODE_TYPES, type NodeRecord, titleKey } from "./model";
import { Privacy } from "./privacy";
import { Repository } from "./repository";
import { IndexedDBStore } from "./store";
import { describeFailure, describeStatus, fetchStatus, type StatusLine } from "./status";
import { Poller, type PollResult } from "./polling";
import { AuthError, HttpTransport, OutdatedError, SyncClient } from "./sync";
import "./style.css";

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const store = new IndexedDBStore();
const deviceId = localStorage.getItem("deviceId") ?? `pc-${crypto.randomUUID().slice(0, 8)}`;
localStorage.setItem("deviceId", deviceId);
const repo = new Repository(store, deviceId);
const privacy = new Privacy(store);
// Solo locali e sospetti di salute non partono: le loro modifiche restano in outbox.
const sync = new SyncClient(store, new HttpTransport(), deviceId, (id) => privacy.isBlockedId(id));
let selected: string | undefined;
const ink = new InkEditor(repo, () => persist());

function active(): NodeRecord[] {
  return store.nodes().filter((n) => !n.deleted_at).sort((a, b) => b.updated_at.localeCompare(a.updated_at));
}

const dateFormat = new Intl.DateTimeFormat("it-IT", { day: "numeric", month: "short" });
const timeFormat = new Intl.DateTimeFormat("it-IT", { hour: "2-digit", minute: "2-digit" });

/** Oggi l'ora, prima il giorno: come l'elenco dell'iPad. */
function shortDate(iso: string): string {
  const date = new Date(iso);
  return date.toDateString() === new Date().toDateString() ? timeFormat.format(date) : dateFormat.format(date);
}

/** Prima riga di testo del Markdown, senza simboli. */
function snippet(md: string): string {
  const line = md.split("\n").map((l) => l.replace(/^[#>\-*+\s\d.[\]x]+/i, "").trim()).find(Boolean) ?? "";
  return line.replace(/\[\[([^\]|#]+)[^\]]*\]\]/g, "$1").replace(/[*_`~]/g, "");
}

/** Testo normalizzato per la ricerca: si ricalcola solo se titolo o corpo sono cambiati. */
const searchCache = new Map<string, { title: string; body: string; key: string }>();
function searchKey(n: NodeRecord): string {
  const hit = searchCache.get(n.id);
  if (hit && hit.title === n.title && hit.body === n.body_md) return hit.key;
  const key = titleKey(`${n.title} ${n.body_md}`);
  searchCache.set(n.id, { title: n.title, body: n.body_md, key });
  return key;
}

/** Nodi nel cestino, i più recenti per primi: il server li elimina dopo 30 giorni. */
function trashed(): NodeRecord[] {
  return store.nodes().filter((n) => n.deleted_at).sort((a, b) => (b.deleted_at ?? "").localeCompare(a.deleted_at ?? ""));
}

let showTrash = false;

function renderList() {
  const q = titleKey($<HTMLInputElement>("search").value);
  const all = showTrash ? trashed() : active();
  const shown = q ? all.filter((n) => searchKey(n).includes(q)) : all;
  $("count").textContent = q ? `${shown.length} di ${all.length}` : all.length === 1 ? "1 nodo" : `${all.length} nodi`;
  $("count").textContent += showTrash ? " nel cestino" : "";
  const items = shown.map((n) => {
    const li = document.createElement("li");
    const dot = document.createElement("span");
    dot.className = "dot";
    dot.style.background = `var(--${n.area})`;
    const name = document.createElement("span");
    name.className = "name";
    name.textContent = n.title || "Senza titolo";
    const date = document.createElement("span");
    date.className = "date";
    date.textContent = shortDate(n.updated_at);
    const text = document.createElement("span");
    text.className = "snippet";
    text.textContent = (privacy.isBlocked(n) ? "🔒 " : "") + (snippet(n.body_md) || LABELS.type[n.type]);
    li.append(dot, name, date, text);
    li.className = n.id === selected && !showTrash ? "active" : "";
    if (showTrash) {
      const restore = document.createElement("button");
      restore.className = "ghost restore";
      restore.textContent = "Ripristina";
      restore.onclick = () => {
        repo.restoreNode(n.id);
        persist();
        renderList();
      };
      li.append(restore);
    } else {
      li.onclick = () => open(n.id);
    }
    return li;
  });
  if (items.length === 0) {
    const li = document.createElement("li");
    li.className = "empty";
    li.textContent = q ? "Nessun risultato" : showTrash ? "Il cestino è vuoto" : "Ancora nessun appunto: creane uno con ＋";
    items.push(li);
  }
  $("list").replaceChildren(...items);
}

let undoTimer: ReturnType<typeof setTimeout> | undefined;
/** Dopo "Sposta nel cestino": qualche secondo per tornare indietro con un tocco. */
function offerUndo(id: string) {
  clearTimeout(undoTimer);
  const bar = $("undo");
  const button = document.createElement("button");
  button.className = "ghost";
  button.textContent = "Annulla";
  button.onclick = () => {
    clearTimeout(undoTimer);
    bar.hidden = true;
    repo.restoreNode(id);
    persist();
    renderList();
  };
  bar.replaceChildren(document.createTextNode("Nodo spostato nel cestino"), button);
  bar.hidden = false;
  undoTimer = setTimeout(() => { bar.hidden = true; }, 8000);
}

function setStatus(state: "ok" | "offline" | "error", ...content: (string | Node)[]) {
  $("status").dataset.state = state;
  $("status").replaceChildren(...content);
}

function updateAreaDot() {
  $("area-dot").style.background = `var(--${$<HTMLSelectElement>("area").value})`;
}

const MODES = ["write", "split", "preview", "ink"] as const;
type Mode = (typeof MODES)[number];
function mode(): Mode { return $("panes").dataset.mode as Mode; }
function setMode(next: Mode) {
  if (next !== "ink") ink.flush();
  $("panes").dataset.mode = next;
  for (const b of document.querySelectorAll<HTMLButtonElement>("#view-mode button")) {
    b.setAttribute("aria-pressed", String(b.dataset.mode === next));
  }
  if (next === "ink" && selected) ink.show(selected);
  try { localStorage.setItem("viewMode", next); } catch { /* solo una preferenza */ }
}

/** marked e DOMPurify si caricano al primo uso: non pesano sull'avvio. */
type Markdown = { sanitize: (html: string) => string; parse: (md: string) => string };
let markdownReady: Promise<Markdown> | undefined;
function markdown(): Promise<Markdown> {
  markdownReady ??= Promise.all([import("dompurify"), import("marked")]).then(([purify, md]) => ({
    sanitize: (html) => purify.default.sanitize(html),
    parse: (text) => md.marked.parse(text) as string,
  }));
  return markdownReady;
}

let previewToken = 0;
async function renderPreview(node: NodeRecord) {
  const token = ++previewToken;
  const { sanitize, parse } = await markdown();
  if (token !== previewToken) return;
  const md = node.body_md.replace(/\[\[([^\]|#\n]+)(?:[#|][^\]\n]*)?\]\]/g, (_, t: string) => `<span class="wiki" data-title="${t.replace(/"/g, "")}">${t}</span>`);
  $("preview").innerHTML = sanitize(`<h1>${sanitize(node.title)}</h1>` + parse(md));
}

/** Salva su disco dopo ogni modifica; un errore resta visibile nello stato. */
function persist() {
  store.flush().catch(() => { setStatus("error", "Errore nel salvataggio locale"); });
}

function open(id: string) {
  flushSave();
  const node = store.node(id);
  if (!node) return;
  selected = id;
  $("node").hidden = false;
  $("empty").hidden = true;
  document.body.classList.add("open");
  $<HTMLInputElement>("title").value = node.title;
  $<HTMLSelectElement>("type").value = node.type;
  $<HTMLSelectElement>("area").value = node.area;
  $<HTMLInputElement>("tags").value = node.tags.join(", ");
  $<HTMLTextAreaElement>("body").value = node.body_md;
  updateAreaDot();
  renderPreview(node);
  renderHealthBanner(node);
  if (mode() === "ink") ink.show(id);
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

/** Salva subito la modifica in attesa (testo e penna): prima di cambiare nodo, del cestino e della sync. */
function flushSave() {
  ink.flush();
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
  renderHealthBanner(node);
  renderList();
  persist();
}

// MARK: Privacy

/** Avviso sopra il testo: nodo tenuto solo qui, oppure sospetto di salute in attesa di una scelta. */
function renderHealthBanner(node: NodeRecord) {
  const box = $("health");
  box.replaceChildren();
  const button = (text: string, action: () => void) => {
    const b = document.createElement("button");
    b.textContent = text;
    b.onclick = () => { flushSave(); action(); persist(); open(node.id); poller.poke(); };
    return b;
  };
  const message = document.createElement("span");
  if (isLocalOnly(node)) {
    message.textContent = "Solo su questo computer: non va al server né a Gemini.";
    box.append(message, button("Rimetti nella sincronizzazione", () => setLocalOnly(node.id, false)));
  } else if (privacy.isHeld(node)) {
    message.textContent = "Sembra un dato di salute: resta su questo computer, non va al server né a Gemini, finché non scegli.";
    box.append(message, button("Non è un dato di salute", () => privacy.dismiss(node)), button("Tieni solo qui", () => setLocalOnly(node.id, true)));
  } else {
    box.hidden = true;
    return;
  }
  box.hidden = false;
}

/** Tiene un nodo solo sul PC (o lo rimette in sync). Se era già sul server lo si toglie da lì. */
function setLocalOnly(id: string, on: boolean) {
  const node = store.node(id);
  if (!node) return;
  const tags = on ? [...new Set([...node.tags, LOCAL_ONLY_TAG])] : node.tags.filter((t) => t !== LOCAL_ONLY_TAG);
  repo.updateNode(id, { tags });
  if (on && node.version > 0) store.queueRedact(id);
  if (!on) store.unqueueRedact(id);
}

function syncEnabled(): boolean {
  try { return localStorage.getItem("syncEnabled") !== "0"; } catch { return true; }
}

/** Modifiche rifiutate dal server: si scartano (vale il server) o si riprovano. */
function renderRejections() {
  const box = $("rejections");
  box.hidden = sync.rejections.length === 0;
  box.replaceChildren(...sync.rejections.map((p) => {
    const row = document.createElement("div");
    const label = document.createElement("span");
    const name = p.entity === "node" ? store.node(p.id)?.title || "Senza titolo" : p.entity === "ink_page" ? "Pagina a penna" : "Collegamento";
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
        poller.poke();
      };
      return b;
    };
    row.append(label, button("Scarta", () => sync.discard(p.entity, p.id)), button("Riprova", () => sync.retry(p.entity, p.id)));
    return row;
  }));
}

function closeEditor() {
  selected = undefined;
  $("node").hidden = true;
  $("empty").hidden = false;
  document.body.classList.remove("open");
  $("preview").replaceChildren();
}

/** Mentre si scrive il modulo non si ricarica: si perderebbero cursore e testo. */
function editing(): boolean {
  return saveTimer !== undefined || $("node").contains(document.activeElement);
}

let lastSync: Date | undefined;

function renderConnection(lines: StatusLine[]) {
  $("connection-result").replaceChildren(...lines.map((line) => {
    const row = document.createElement("div");
    row.className = line.ok ? "ok" : "warn";
    row.textContent = `${line.ok ? "✓" : "⚠"} ${line.label}: ${line.text}`;
    return row;
  }));
}

async function checkConnection() {
  $("connection-result").textContent = "Controllo…";
  try {
    renderConnection(describeStatus(await fetchStatus(), lastSync, store.pending().length));
  } catch (error) {
    renderConnection([describeFailure(error)]);
  }
}

async function runSync(): Promise<PollResult | "skipped"> {
  flushSave();
  if (!syncEnabled()) {
    setStatus("offline", "Sincronizzazione disattivata: gli appunti restano su questo computer");
    return "skipped";
  }
  let outcome: PollResult | "skipped" = "ok";
  try {
    const result = await sync.sync();
    if (result === "skipped") outcome = "skipped";
    else { lastSync = new Date(); setStatus("ok", `Sincronizzato alle ${timeFormat.format(lastSync)}`); }
  } catch (error) {
    if (error instanceof OutdatedError) {
      outcome = "auth";
      setStatus("error", error.message);
    } else if (error instanceof AuthError) {
      outcome = "auth";
      const link = document.createElement("a");
      link.href = "/";
      link.textContent = "Accedi di nuovo";
      link.onclick = (e) => { e.preventDefault(); location.reload(); };
      setStatus("error", "Sessione scaduta: ", link);
    } else {
      outcome = "offline";
      setStatus("offline", "Offline: le modifiche partono al ritorno della rete");
    }
  }
  renderRejections();
  renderList();
  if (selected && !store.node(selected)) closeEditor();
  else if (selected && !editing()) open(selected);
  // La penna si aggiorna anche mentre la si usa: i tratti non salvati restano.
  else if (selected && mode() === "ink") ink.show(selected);
  return outcome;
}

// Ogni 30 secondi, con calma se la rete non va, fermi se la sessione è scaduta, a riposo a scheda nascosta.
const poller = new Poller(runSync, () => document.visibilityState === "hidden");

// MARK: Tutor

let chatHistory: ChatMessage[] = [];
let chatAbort: AbortController | undefined;

function chatSettings() {
  return { model: $<HTMLInputElement>("chat-model").value, localOnly: $<HTMLInputElement>("chat-local-only").checked };
}

function appendMessage(role: "user" | "assistant" | "error", content: string | Node[]): HTMLElement {
  const div = document.createElement("div");
  div.className = `msg ${role === "error" ? "assistant error" : role}`;
  if (typeof content === "string") div.textContent = content;
  else div.append(...content);
  $("chat-log").append(div);
  div.scrollIntoView({ block: "end" });
  return div;
}

async function ask(question: string) {
  const settings = chatSettings();
  const fetchFn = (input: string, init?: RequestInit) => fetch(input, init);
  const providers = { local: new OllamaProvider(settings.model.trim() || DEFAULT_OLLAMA_MODEL, fetchFn), online: new WorkerProvider(fetchFn) };
  appendMessage("user", question);
  const pending = appendMessage("assistant", "…");
  const controller = new AbortController();
  chatAbort = controller;
  $<HTMLButtonElement>("chat-send").disabled = true;
  try {
    const reply = await answer(question, chatHistory, corpus(store.nodes(), (n) => privacy.isBlocked(n)), providers, {
      localOnly: settings.localOnly,
      signal: controller.signal,
      // Mai un invio a Gemini in silenzio: i frammenti degli appunti escono dal PC solo se l'utente conferma.
      confirmOnline: async (reason) => confirm(`Il modello locale non risponde (${reason}).\n\nInviare a Gemini, attraverso il server, i frammenti degli appunti che servono per rispondere?`),
    });
    if (controller.signal.aborted) return;
    chatHistory.push({ role: "user", text: question }, { role: "assistant", text: reply.text });
    const body = document.createElement("div");
    const { sanitize, parse } = await markdown();
    body.innerHTML = sanitize(parse(linkCitations(reply.text, reply.citations)));
    const meta = document.createElement("div");
    meta.className = "meta";
    meta.textContent = reply.fallbackReason ? `${reply.providerLabel} · locale non usato: ${reply.fallbackReason}` : reply.providerLabel;
    const nodes: Node[] = [body];
    if (reply.citations.length) {
      const sources = document.createElement("div");
      sources.className = "sources";
      sources.append("Fonti: ");
      for (const c of reply.citations) {
        const a = document.createElement("a");
        a.href = `#nodo/${encodeURIComponent(c.nodeId)}`;
        a.textContent = `[${c.number}] ${c.title}`;
        sources.append(a, " ");
      }
      nodes.push(sources);
    }
    nodes.push(meta);
    pending.replaceChildren(...nodes);
  } catch (error) {
    if (controller.signal.aborted) return;
    pending.className = "msg assistant error";
    pending.textContent = error instanceof Error ? error.message : String(error);
  } finally {
    if (chatAbort === controller) {
      chatAbort = undefined;
      $<HTMLButtonElement>("chat-send").disabled = false;
    }
  }
}

function setupChat() {
  const settings = loadSettings(localStorage);
  $<HTMLInputElement>("chat-model").value = settings.model;
  $<HTMLInputElement>("chat-local-only").checked = settings.localOnly;
  for (const id of ["chat-model", "chat-local-only"]) $(id).addEventListener("change", () => saveSettings(localStorage, chatSettings()));
  const toggle = () => {
    $("chat").hidden = !$("chat").hidden;
    if (!$("chat").hidden) $("chat-input").focus();
  };
  $("chat-toggle").onclick = toggle;
  $("chat-close").onclick = () => { $("chat").hidden = true; };
  $("chat-new").onclick = () => {
    chatAbort?.abort();
    chatAbort = undefined;
    $<HTMLButtonElement>("chat-send").disabled = false;
    chatHistory = [];
    $("chat-log").replaceChildren();
  };
  $("chat-form").addEventListener("submit", (e) => {
    e.preventDefault();
    const input = $<HTMLTextAreaElement>("chat-input");
    const question = input.value.trim();
    if (!question || chatAbort) return;
    input.value = "";
    void ask(question);
  });
  $("chat-input").addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
      e.preventDefault();
      $<HTMLFormElement>("chat-form").requestSubmit();
    }
  });
  // Le citazioni aprono il nodo della fonte.
  $("chat-log").addEventListener("click", (e) => {
    const link = (e.target as HTMLElement).closest("a");
    const id = link ? nodeFromLink(link.getAttribute("href") ?? "") : undefined;
    if (!id) return;
    e.preventDefault();
    if (store.node(id) && !store.node(id)?.deleted_at) open(id);
  });
  return toggle;
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

// MARK: Account

function setupAccount() {
  const enabled = $<HTMLInputElement>("sync-enabled");
  enabled.checked = syncEnabled();
  enabled.onchange = () => {
    try { localStorage.setItem("syncEnabled", enabled.checked ? "1" : "0"); } catch { /* resta per questa sessione */ }
    poller.poke();
  };
  const report = (text: string) => setStatus("ok", text);
  $("export-all").onclick = async () => {
    try {
      const file = await exportEverything((input, init) => fetch(input, init));
      const url = URL.createObjectURL(new Blob([JSON.stringify(file)], { type: "application/json" }));
      const link = document.createElement("a");
      link.href = url;
      link.download = `pitchstone-esportazione-${file.exported_at.slice(0, 10)}.json`;
      link.click();
      URL.revokeObjectURL(url);
      report("Esportazione completa scaricata");
    } catch (error) {
      setStatus("error", error instanceof AuthError ? "Sessione scaduta: ricarica la pagina" : "Esportazione non riuscita");
    }
  };
  const leave = async () => {
    await clearLocal(store);
    location.href = "/cdn-cgi/access/logout";
  };
  $("clear-local").onclick = async () => {
    if (!confirm("Cancellare dal computer tutti gli appunti, le preferenze e la copia dell'app? Sul server restano.")) return;
    await clearLocal(store);
    location.reload();
  };
  $("logout").onclick = async () => {
    if (!confirm("Uscire? I dati locali di questo computer vengono cancellati; sul server restano.")) return;
    await leave();
  };
  $("erase-server").onclick = async () => {
    const typed = prompt(`Questo cancella TUTTO dal server: appunti, storico, disegni, allegati e backup. Non si può annullare.\n\nScrivi "${ERASE_CONFIRMATION}" per confermare.`);
    if (typed !== ERASE_CONFIRMATION) return;
    try {
      const result = await eraseServer((input, init) => fetch(input, init));
      await clearLocal(store);
      alert(result.storage ? "Tutto cancellato dal server e da questo computer." : "Database cancellato, ma alcuni file (allegati o backup) non si sono potuti togliere: ripeti l'operazione.");
      location.reload();
    } catch (error) {
      setStatus("error", error instanceof AuthError ? "Sessione scaduta: ricarica la pagina" : "Cancellazione non riuscita");
    }
  };
}

async function main() {
  await holdTab();
  await store.load();
  // A riposo, dopo l'avvio: l'anteprima funziona anche offline senza pesare sul primo disegno.
  setTimeout(() => { void markdown(); }, 2000);
  if (!store.persistent) {
    const warning = $("storage-warning");
    warning.textContent = `L'archivio locale non è disponibile (${store.failure}): gli appunti restano solo finché la scheda è aperta.`;
    warning.hidden = false;
  }
  void store.requestPersistence();
  setupAccount();
  for (const t of NODE_TYPES) $("type").append(new Option(LABELS.type[t], t));
  for (const a of AREAS) $("area").append(new Option(LABELS.area[a], a));
  for (const id of ["title", "type", "area", "tags", "body"]) $(id).addEventListener("input", scheduleSave);
  let searchTimer: ReturnType<typeof setTimeout> | undefined;
  $("search").addEventListener("input", () => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(renderList, 150);
  });
  $("area").addEventListener("change", updateAreaDot);
  for (const b of document.querySelectorAll<HTMLButtonElement>("#view-mode button")) {
    b.onclick = () => setMode(b.dataset.mode as Mode);
  }
  $("panes").append(ink.root);
  let savedMode: string | null = null;
  try { savedMode = localStorage.getItem("viewMode"); } catch { /* vista predefinita */ }
  setMode(MODES.includes(savedMode as Mode) ? (savedMode as Mode) : "split");
  $("back").onclick = () => {
    flushSave();
    persist();
    closeEditor();
    renderList();
  };
  const toggleChat = setupChat();
  $("new").onclick = () => {
    flushSave();
    const n = repo.createNode({ title: "Nuovo nodo" });
    persist();
    open(n.id);
  };
  $("trash").onclick = () => {
    flushSave();
    if (!selected) return;
    const id = selected;
    repo.trashNode(id);
    persist();
    closeEditor();
    renderList();
    offerUndo(id);
  };
  $("connection-check").onclick = () => { void checkConnection(); };
  $("trash-view").onclick = () => {
    showTrash = !showTrash;
    $("trash-view").setAttribute("aria-pressed", String(showTrash));
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
    else poller.poke();
  });
  document.addEventListener("keydown", (e) => {
    if (!(e.metaKey || e.ctrlKey)) return;
    // Annulla e ripristina della penna, se il cursore non è in un campo di testo.
    const typing = document.activeElement?.matches("input, textarea, select") ?? false;
    if (mode() === "ink" && !typing && (e.key.toLowerCase() === "z" || e.key === "y")) {
      e.preventDefault();
      if (e.key === "y" || e.shiftKey) ink.redo();
      else ink.undo();
      return;
    }
    if (e.key === "k") { e.preventDefault(); $("search").focus(); }
    if (e.key === "n") { e.preventDefault(); $("new").click(); }
    if (e.key === "j") { e.preventDefault(); toggleChat(); }
  });
  renderList();
  renderRejections();
  if ("serviceWorker" in navigator) void navigator.serviceWorker.register("/sw.js");
  poller.start();
  poller.poke();
  window.addEventListener("online", () => poller.poke());
}

void main();
