// Vista "Penna" del nodo: pagine a penna con tavoletta grafica, penna, mouse o dito
// (Pointer Events). I tratti si salvano in PSINK1 (ADR 0015) e arrivano all'iPad con la sync.

import {
  base64ToBytes, bytesToBase64, decodeInk, displayColor, encodeInk, inkFormat, type InkPage, type InkPoint,
  type InkStroke, pageHeight, strokesHit, widthAt,
} from "./ink";
import type { InkBackground, InkPageRecord } from "./model";
import type { Repository } from "./repository";

type Tool = "pen" | "marker" | "eraser";

const COLORS = [
  { name: "Nero", value: "#000000ff" },
  { name: "Blu", value: "#007affff" },
  { name: "Rosso", value: "#ff3b30ff" },
  { name: "Verde", value: "#34c759ff" },
  { name: "Giallo", value: "#ffcc00ff" },
];
const SIZES = [
  { name: "Sottile", pen: 1.5, marker: 10 },
  { name: "Media", pen: 3, marker: 18 },
  { name: "Spessa", pen: 6, marker: 28 },
];
const BACKGROUNDS: { value: InkBackground; label: string }[] = [
  { value: "blank", label: "Bianco" },
  { value: "lines", label: "A righe" },
  { value: "grid", label: "A quadretti" },
];
/** Spaziatura di righe e quadretti in unità di pagina, come sull'iPad. */
const LINE_SPACING = 32;
const GRID_SPACING = 24;
/** Limite del database per pagina. */
const MAX_BYTES = 2_000_000;
/** Raggio della gomma in pixel dello schermo. */
const ERASER_RADIUS = 10;

function element<K extends keyof HTMLElementTagNameMap>(
  tag: K, props: Partial<HTMLElementTagNameMap[K]> = {}, ...children: (Node | string)[]
): HTMLElementTagNameMap[K] {
  const el: HTMLElementTagNameMap[K] = Object.assign(document.createElement(tag), props);
  el.append(...children);
  return el;
}

function readPref<T extends string>(key: string, allowed: readonly T[], fallback: T): T {
  try {
    const value = localStorage.getItem(key) as T | null;
    return value && allowed.includes(value) ? value : fallback;
  } catch {
    return fallback;
  }
}

function writePref(key: string, value: string) {
  try { localStorage.setItem(key, value); } catch { /* solo una preferenza */ }
}

/** Traccia il tratto con curve quadratiche tra i punti medi; la larghezza segue la pressione. */
export function drawStroke(ctx: CanvasRenderingContext2D, stroke: InkStroke, scale: number, dark: boolean) {
  const color = displayColor(stroke.color, dark);
  const alpha = parseInt(color.slice(7, 9), 16) / 255;
  const pts = stroke.points;
  ctx.save();
  ctx.strokeStyle = ctx.fillStyle = color.slice(0, 7);
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  ctx.globalAlpha = alpha * (stroke.tool === "marker" ? 0.4 : stroke.tool === "pencil" ? 0.85 : 1);
  const at = (i: number) => [pts[i][0] * scale, pts[i][1] * scale] as const;
  const mid = (i: number) => [(pts[i][0] + pts[i + 1][0]) * scale / 2, (pts[i][1] + pts[i + 1][1]) * scale / 2] as const;
  if (pts.length === 1) {
    const [x, y] = at(0);
    ctx.beginPath();
    ctx.arc(x, y, Math.max(0.5, widthAt(stroke, pts[0][2]) * scale / 2), 0, Math.PI * 2);
    ctx.fill();
  } else if (stroke.tool === "marker") {
    // Larghezza costante e un solo percorso: la trasparenza non si somma sulle giunture.
    ctx.lineWidth = stroke.width * scale;
    ctx.beginPath();
    ctx.moveTo(...at(0));
    for (let i = 1; i < pts.length - 1; i++) ctx.quadraticCurveTo(...at(i), ...mid(i));
    ctx.lineTo(...at(pts.length - 1));
    ctx.stroke();
  } else {
    // Un pezzo di curva per punto, ciascuno con la larghezza della sua pressione.
    let start: readonly [number, number] = at(0);
    for (let i = 1; i < pts.length; i++) {
      ctx.beginPath();
      ctx.moveTo(...start);
      const last = i === pts.length - 1;
      const end = last ? at(i) : mid(i);
      if (last) ctx.lineTo(...end);
      else ctx.quadraticCurveTo(...at(i), ...end);
      ctx.lineWidth = Math.max(0.5, widthAt(stroke, (pts[i - 1][2] + pts[i][2]) / 2) * scale);
      ctx.stroke();
      start = end;
    }
  }
  ctx.restore();
}

export class InkEditor {
  readonly root: HTMLElement;
  private nodeId?: string;
  private pageId?: string;
  /** Byte (base64) da cui è partita la tela: servono a riconoscere una sync nel frattempo. */
  private loaded = "";
  private page: InkPage = { width: 800, height: 1131.2, strokes: [] };
  private editable = false;
  private undoStack: InkStroke[][] = [];
  private redoStack: InkStroke[][] = [];
  private dirty = false;
  private saveTimer?: number;

  private tool: Tool = readPref("inkTool", ["pen", "marker", "eraser"], "pen");
  private penColor = readPref("inkPenColor", COLORS.map((c) => c.value), COLORS[0].value);
  private markerColor = readPref("inkMarkerColor", COLORS.map((c) => c.value), COLORS[4].value);
  private size = Number(readPref("inkSize", ["0", "1", "2"], "1"));

  // Tratto in corso
  private pointerId?: number;
  private erasing = false;
  private current?: InkStroke;
  private startTime = 0;
  private eraserLast?: [number, number];
  private beforeErase?: InkStroke[];

  private scale = 1;
  private readonly tabs = element("div", { className: "ink-tabs", role: "tablist" });
  private readonly tools = element("div", { className: "ink-tools" });
  private readonly scroller = element("div", { className: "ink-scroll" });
  private readonly paper = element("div", { className: "ink-paper" });
  private readonly base = element("canvas", { className: "ink-base" });
  private readonly live = element("canvas", { className: "ink-live" });
  private readonly notice = element("div", { className: "ink-notice", hidden: true });
  private readonly status = element("span", { className: "ink-status" });
  private readonly empty = element("div", { className: "ink-empty", hidden: true });
  private readonly buttons = new Map<string, HTMLButtonElement>();
  private readonly backgroundSelect: HTMLSelectElement = element("select", { ariaLabel: "Sfondo" });

  constructor(
    private repo: Repository,
    /** Scrive l'archivio su disco dopo una modifica. */
    private persist: () => void,
  ) {
    this.root = element("div", { id: "ink" });
    this.paper.append(this.base, this.live);
    this.scroller.append(this.paper);
    this.root.append(this.tabs, this.tools, this.notice, this.scroller, this.empty);
    this.buildTools();
    this.buildEmpty();
    this.bindPointer();
    new ResizeObserver(() => this.layout()).observe(this.scroller);
    window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => this.redraw());
  }

  // MARK: Interfaccia

  private button(key: string, label: string, title: string, action: () => void, className = "ghost") {
    const b = element("button", { className, title, textContent: label, type: "button" });
    b.setAttribute("aria-label", title);
    b.onclick = action;
    this.buttons.set(key, b);
    return b;
  }

  private buildTools() {
    const tools = element("div", { className: "segmented", role: "group", ariaLabel: "Strumento" },
      this.button("tool-pen", "Penna", "Penna", () => this.setTool("pen"), ""),
      this.button("tool-marker", "Evidenziatore", "Evidenziatore", () => this.setTool("marker"), ""),
      this.button("tool-eraser", "Gomma", "Gomma: cancella i tratti che tocca (anche il retro della penna)", () => this.setTool("eraser"), ""));
    const colors = element("div", { className: "ink-colors", role: "group", ariaLabel: "Colore" },
      ...COLORS.map((c) => {
        const b = this.button(`color-${c.value}`, "", c.name, () => this.setColor(c.value), "swatch");
        b.style.setProperty("--swatch", c.value.slice(0, 7));
        return b;
      }));
    const sizes = element("div", { className: "segmented ink-sizes", role: "group", ariaLabel: "Spessore" },
      ...SIZES.map((s, i) => {
        const b = this.button(`size-${i}`, "", s.name, () => this.setSize(i), "");
        b.append(element("span", { className: "size-dot" }));
        b.style.setProperty("--dot", `${4 + i * 4}px`);
        return b;
      }));
    for (const bg of BACKGROUNDS) this.backgroundSelect.append(new Option(bg.label, bg.value));
    this.backgroundSelect.onchange = () => this.setBackground(this.backgroundSelect.value as InkBackground);
    this.tools.append(
      tools, colors, sizes,
      this.button("undo", "↶", "Annulla (Ctrl+Z)", () => this.undo()),
      this.button("redo", "↷", "Ripristina (Ctrl+Maiusc+Z)", () => this.redo()),
      this.backgroundSelect,
      element("span", { className: "spacer" }),
      this.status,
    );
    this.updateTools();
  }

  private buildEmpty() {
    const add = element("button", { className: "primary", textContent: "Nuova pagina", type: "button" });
    add.onclick = () => this.addPage();
    this.empty.append(
      element("h2", { textContent: "Nessuna pagina" }),
      element("p", { textContent: "Aggiungi una pagina per scrivere con la tavoletta grafica, la penna o il mouse." }),
      add,
    );
  }

  private updateTools() {
    const disabled = !this.editable;
    for (const [key, b] of this.buttons) {
      if (key.startsWith("tool-")) b.setAttribute("aria-pressed", String(key === `tool-${this.tool}`));
      if (key.startsWith("size-")) b.setAttribute("aria-pressed", String(key === `size-${this.size}`));
      if (key.startsWith("color-")) {
        const color = this.tool === "marker" ? this.markerColor : this.penColor;
        b.setAttribute("aria-pressed", String(key === `color-${color}`));
      }
      b.disabled = disabled;
    }
    this.buttons.get("undo")!.disabled = disabled || this.undoStack.length === 0;
    this.buttons.get("redo")!.disabled = disabled || this.redoStack.length === 0;
    this.backgroundSelect.disabled = !this.pageId;
    this.live.style.cursor = this.tool === "eraser" ? "cell" : "crosshair";
  }

  private setTool(tool: Tool) {
    this.tool = tool;
    writePref("inkTool", tool);
    this.updateTools();
  }

  private setColor(color: string) {
    if (this.tool === "marker") {
      this.markerColor = color;
      writePref("inkMarkerColor", color);
    } else {
      this.penColor = color;
      writePref("inkPenColor", color);
      if (this.tool === "eraser") this.tool = "pen";
    }
    this.updateTools();
  }

  private setSize(size: number) {
    this.size = size;
    writePref("inkSize", String(size));
    if (this.tool === "eraser") this.tool = "pen";
    this.updateTools();
  }

  private setStatus(text: string, error = false) {
    this.status.textContent = text;
    this.status.classList.toggle("error", error);
  }

  // MARK: Pagine

  private pages(): InkPageRecord[] {
    return this.nodeId ? this.repo.inkPages(this.nodeId) : [];
  }

  /** Mostra le pagine del nodo. Lo stesso nodo già aperto si aggiorna senza perdere i tratti. */
  show(nodeId: string) {
    if (nodeId === this.nodeId) {
      this.refresh();
      return;
    }
    this.flush();
    this.nodeId = nodeId;
    this.pageId = undefined;
    this.refresh();
  }

  /** Dopo una sync: elenco delle pagine e, senza tratti da salvare, la pagina aperta. */
  refresh() {
    const pages = this.pages();
    const current = pages.find((p) => p.id === this.pageId);
    if (!current) {
      this.flush();
      this.select(pages[0]);
    } else if (!this.dirty && current.ink_data !== this.loaded) {
      this.select(current);
    } else {
      this.backgroundSelect.value = current.background;
      this.redraw();
    }
    this.renderTabs(pages);
  }

  private renderTabs(pages = this.pages()) {
    const tabs = pages.map((p, i) => {
      const b = element("button", { className: "ink-tab", type: "button", textContent: `Pagina ${i + 1}` });
      b.setAttribute("role", "tab");
      b.setAttribute("aria-selected", String(p.id === this.pageId));
      if (inkFormat(base64ToBytes(p.ink_data)) === "other") b.title = "Scritta sull'iPad";
      b.onclick = () => {
        if (p.id === this.pageId) return;
        this.flush();
        this.select(this.repo.inkPages(p.node_id).find((x) => x.id === p.id));
        this.renderTabs();
      };
      return b;
    });
    const add = element("button", { className: "ghost", type: "button", textContent: "＋ Nuova pagina" });
    add.onclick = () => this.addPage();
    const remove = element("button", { className: "ghost danger", type: "button", textContent: "Elimina pagina", hidden: !this.pageId });
    remove.onclick = () => this.trashPage();
    this.tabs.replaceChildren(...tabs, add, element("span", { className: "spacer" }), remove);
    this.tabs.hidden = pages.length === 0;
    // Una pagina dell'iPad si guarda soltanto: niente strumenti.
    this.tools.hidden = pages.length === 0 || !this.editable;
    this.scroller.hidden = pages.length === 0 || !this.editable;
    this.empty.hidden = pages.length > 0;
  }

  private select(record: InkPageRecord | undefined) {
    this.pageId = record?.id;
    this.loaded = record?.ink_data ?? "";
    this.undoStack = [];
    this.redoStack = [];
    this.dirty = false;
    this.cancelStroke();
    this.notice.hidden = true;
    this.editable = false;
    this.page = { width: 800, height: 1131.2, strokes: [] };
    if (record) {
      this.backgroundSelect.value = record.background;
      const bytes = base64ToBytes(record.ink_data);
      if (inkFormat(bytes) === "other") {
        this.showNotice("Pagina scritta sull'iPad: si modifica lì.");
      } else {
        try {
          this.page = decodeInk(bytes);
          this.editable = true;
        } catch {
          this.showNotice("Questa pagina non si legge sul PC: si modifica sull'iPad.");
        }
      }
    }
    this.setStatus("");
    this.updateTools();
    this.renderTabs();
    this.layout();
  }

  private showNotice(text: string) {
    this.notice.textContent = text;
    this.notice.hidden = false;
  }

  private addPage() {
    if (!this.nodeId) return;
    this.flush();
    const background = this.pages().find((p) => p.id === this.pageId)?.background ?? "lines";
    const page = this.repo.createInkPage(this.nodeId, background);
    this.persist();
    this.select(page);
  }

  private trashPage() {
    if (!this.pageId || !confirm("Eliminare questa pagina? Resta nel cestino per 30 giorni e si ripristina dall'iPad.")) return;
    this.flush();
    this.repo.trashInkPage(this.pageId);
    this.persist();
    this.pageId = undefined;
    this.refresh();
  }

  private setBackground(background: InkBackground) {
    if (!this.pageId) return;
    this.flush();
    this.repo.updateInkPage(this.pageId, { background });
    this.persist();
    this.redraw();
  }

  // MARK: Salvataggio

  private changed() {
    this.dirty = true;
    this.updateTools();
    this.setStatus("Modifiche non salvate");
    clearTimeout(this.saveTimer);
    this.saveTimer = window.setTimeout(() => this.flush(), 1000);
  }

  /** Salva subito i tratti in attesa: prima di cambiare pagina o nodo e prima della sync. */
  flush() {
    clearTimeout(this.saveTimer);
    this.saveTimer = undefined;
    if (!this.dirty || !this.pageId) return;
    this.dirty = false;
    // Pagina eliminata per sempre da un altro dispositivo: non c'è più dove salvare.
    if (!this.repo.inkPage(this.pageId)) return;
    const bytes = encodeInk({ ...this.page, height: pageHeight(this.page.width, this.page.strokes, this.page.height) });
    if (bytes.length > MAX_BYTES) {
      this.dirty = true;
      this.setStatus("Pagina troppo piena per la sincronizzazione: continua in una nuova pagina", true);
      return;
    }
    const data = bytesToBase64(bytes);
    if (data === this.loaded) {
      this.setStatus("");
      return;
    }
    const saved = this.repo.saveDrawing(this.pageId, data, this.loaded);
    this.persist();
    this.loaded = data;
    if (saved.id !== this.pageId) {
      // La pagina era cambiata su un altro dispositivo: i tratti sono finiti in una pagina nuova.
      this.pageId = saved.id;
      this.renderTabs();
      this.showNotice("La pagina era cambiata su un altro dispositivo: i tuoi tratti sono in una nuova pagina.");
    }
    this.setStatus("Salvato");
  }

  // MARK: Annulla

  private pushUndo() {
    this.undoStack.push(this.page.strokes.slice());
    if (this.undoStack.length > 200) this.undoStack.shift();
    this.redoStack = [];
  }

  undo() {
    if (!this.editable || this.pointerId !== undefined) return;
    const previous = this.undoStack.pop();
    if (!previous) return;
    this.redoStack.push(this.page.strokes);
    this.page.strokes = previous;
    this.redraw();
    this.changed();
  }

  redo() {
    if (!this.editable || this.pointerId !== undefined) return;
    const next = this.redoStack.pop();
    if (!next) return;
    this.undoStack.push(this.page.strokes);
    this.page.strokes = next;
    this.redraw();
    this.changed();
  }

  // MARK: Disegno

  private dark() {
    return window.matchMedia("(prefers-color-scheme: dark)").matches;
  }

  /** Dimensioni della tela: la pagina occupa la larghezza disponibile (al massimo 1000 px). */
  private layout() {
    if (!this.editable) return;
    const available = this.scroller.clientWidth - 32;
    if (available <= 0) return;
    const cssWidth = Math.min(1000, available);
    this.scale = cssWidth / this.page.width;
    this.page.height = pageHeight(this.page.width, this.page.strokes, this.page.height);
    const cssHeight = this.page.height * this.scale;
    // Le tele molto alte superano i limiti del browser: si riduce la risoluzione.
    const ratio = Math.min(window.devicePixelRatio || 1, 16000 / cssHeight, 16000 / cssWidth);
    for (const canvas of [this.base, this.live]) {
      canvas.width = Math.round(cssWidth * ratio);
      canvas.height = Math.round(cssHeight * ratio);
      canvas.style.width = `${cssWidth}px`;
      canvas.style.height = `${cssHeight}px`;
      canvas.getContext("2d")!.setTransform(ratio, 0, 0, ratio, 0, 0);
    }
    this.paper.style.width = `${cssWidth}px`;
    this.paper.style.height = `${cssHeight}px`;
    this.redraw();
  }

  private color(name: string): string {
    return getComputedStyle(this.root).getPropertyValue(name).trim();
  }

  private redraw() {
    if (!this.editable) return;
    const ctx = this.base.getContext("2d")!;
    const width = this.page.width * this.scale;
    const height = this.page.height * this.scale;
    ctx.clearRect(0, 0, width, height);
    ctx.fillStyle = this.color("--paper") || "#fff";
    ctx.fillRect(0, 0, width, height);
    const background = this.pages().find((p) => p.id === this.pageId)?.background ?? "blank";
    if (background !== "blank") {
      ctx.fillStyle = this.color("--paper-line") || "#ccc";
      const step = (background === "lines" ? LINE_SPACING : GRID_SPACING) * this.scale;
      for (let y = step; y < height; y += step) ctx.fillRect(0, Math.round(y) - 1, width, 1);
      if (background === "grid") for (let x = step; x < width; x += step) ctx.fillRect(Math.round(x) - 1, 0, 1, height);
    }
    const dark = this.dark();
    for (const stroke of this.page.strokes) drawStroke(ctx, stroke, this.scale, dark);
    this.drawLive();
  }

  private drawLive() {
    const ctx = this.live.getContext("2d")!;
    ctx.clearRect(0, 0, this.page.width * this.scale, this.page.height * this.scale);
    if (this.current) drawStroke(ctx, this.current, this.scale, this.dark());
  }

  // MARK: Puntatore

  private point(e: PointerEvent): InkPoint {
    const rect = this.live.getBoundingClientRect();
    // Pressione vera solo dalla penna; mouse e dito disegnano a metà pressione.
    const pressure = e.pointerType === "pen" && e.pressure > 0 ? e.pressure : 0.5;
    return [
      (e.clientX - rect.left) / this.scale,
      (e.clientY - rect.top) / this.scale,
      pressure,
      Math.max(0, (e.timeStamp - this.startTime) / 1000),
    ];
  }

  private bindPointer() {
    const canvas = this.live;
    canvas.addEventListener("contextmenu", (e) => e.preventDefault());
    canvas.addEventListener("pointerdown", (e) => {
      if (!this.editable || this.pointerId !== undefined) return;
      // Tasto destro del mouse e tasto laterale della penna non disegnano.
      if (e.button !== 0 && e.button !== 5) return;
      e.preventDefault();
      // Il tratto continua anche se la penna esce dalla tela.
      try { canvas.setPointerCapture(e.pointerId); } catch { /* puntatore non più attivo */ }
      this.pointerId = e.pointerId;
      this.startTime = e.timeStamp;
      // Il retro della penna (gomma della Wacom) cancella sempre.
      this.erasing = this.tool === "eraser" || e.button === 5 || (e.buttons & 32) !== 0;
      if (this.erasing) {
        this.beforeErase = this.page.strokes.slice();
        this.eraserLast = undefined;
        this.erase(e);
        return;
      }
      const marker = this.tool === "marker";
      const size = SIZES[this.size] ?? SIZES[1];
      this.current = {
        tool: marker ? "marker" : "pen",
        color: marker ? this.markerColor : this.penColor,
        width: marker ? size.marker : size.pen,
        points: [this.point(e)],
      };
      this.drawLive();
    });
    canvas.addEventListener("pointermove", (e) => {
      if (e.pointerId !== this.pointerId) return;
      // Gli eventi uniti dal browser tra due frame: tratti fluidi anche con la tavoletta.
      const events = typeof e.getCoalescedEvents === "function" ? e.getCoalescedEvents() : [];
      const all = events.length > 0 ? events : [e];
      if (this.erasing) {
        for (const ev of all) this.erase(ev);
        return;
      }
      if (!this.current) return;
      for (const ev of all) {
        const p = this.point(ev);
        const last = this.current.points[this.current.points.length - 1];
        // Punti quasi sovrapposti non aggiungono niente.
        if (Math.hypot(p[0] - last[0], p[1] - last[1]) * this.scale < 0.75) continue;
        this.current.points.push(p);
      }
      this.drawLive();
    });
    const end = (e: PointerEvent) => {
      if (e.pointerId !== this.pointerId) return;
      this.pointerId = undefined;
      if (this.erasing) {
        this.erasing = false;
        const before = this.beforeErase;
        this.beforeErase = undefined;
        if (before && before.length !== this.page.strokes.length) {
          this.undoStack.push(before);
          this.redoStack = [];
          this.changed();
        }
        return;
      }
      const stroke = this.current;
      this.current = undefined;
      if (!stroke || e.type === "pointercancel") {
        this.drawLive();
        return;
      }
      this.pushUndo();
      this.page.strokes = [...this.page.strokes, stroke];
      const height = this.page.height;
      this.page.height = pageHeight(this.page.width, this.page.strokes, height);
      if (this.page.height !== height) this.layout();
      else {
        drawStroke(this.base.getContext("2d")!, stroke, this.scale, this.dark());
        this.drawLive();
      }
      this.changed();
    };
    canvas.addEventListener("pointerup", end);
    canvas.addEventListener("pointercancel", end);
  }

  private erase(e: PointerEvent) {
    const [x, y] = this.point(e);
    const hit = strokesHit(this.page.strokes, x, y, ERASER_RADIUS / this.scale, this.eraserLast);
    this.eraserLast = [x, y];
    if (hit.length === 0) return;
    const gone = new Set(hit);
    this.page.strokes = this.page.strokes.filter((_, i) => !gone.has(i));
    this.redraw();
  }

  private cancelStroke() {
    this.pointerId = undefined;
    this.current = undefined;
    this.erasing = false;
    this.beforeErase = undefined;
  }
}
