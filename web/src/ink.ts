// Formato portabile dei disegni (ADR 0015): "PSINK1\n" + JSON con i tratti in
// coordinate di pagina. Lo stesso codec esiste sull'iPad (PortableInk in PitchstoneSync):
// la codifica è canonica, così i due lati producono gli stessi byte.

export const PSINK_PREFIX = "PSINK1\n";
/** Larghezza logica delle pagine nuove create sul PC; l'altezza parte da A4. */
export const DEFAULT_PAGE_WIDTH = 800;
export const A4_RATIO = 1.414;

export const INK_TOOLS = ["pen", "marker", "pencil"] as const;
export type InkTool = (typeof INK_TOOLS)[number];

/** Un punto: x, y, pressione 0...1, secondi dall'inizio del tratto. */
export type InkPoint = [number, number, number, number];

export interface InkStroke {
  tool: InkTool;
  /** "#rrggbbaa", colore nell'aspetto chiaro (come PencilKit). */
  color: string;
  /** Larghezza a pressione 0,5, in unità di pagina. */
  width: number;
  points: InkPoint[];
}

export interface InkPage {
  width: number;
  height: number;
  strokes: InkStroke[];
}

export type InkFormat = "empty" | "psink1" | "other";

/** Pagina vuota: zero byte. PSINK1: portabile. Altro: PKDrawing dell'iPad. */
export function inkFormat(bytes: Uint8Array): InkFormat {
  if (bytes.length === 0) return "empty";
  const prefix = new TextEncoder().encode(PSINK_PREFIX);
  if (bytes.length >= prefix.length && prefix.every((b, i) => bytes[i] === b)) return "psink1";
  return "other";
}

/** Arrotonda a `digits` decimali, simmetrico rispetto allo zero (come `rounded()` di Swift). */
function round(value: number, digits: number): number {
  if (!Number.isFinite(value)) return 0;
  const k = 10 ** digits;
  const r = Math.round(Math.abs(value) * k) / k;
  return r === 0 ? 0 : value < 0 ? -r : r;
}

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

function normalizeColor(value: unknown): string {
  if (typeof value !== "string") return "#000000ff";
  const hex = value.trim().toLowerCase();
  if (/^#[0-9a-f]{8}$/.test(hex)) return hex;
  if (/^#[0-9a-f]{6}$/.test(hex)) return `${hex}ff`;
  return "#000000ff";
}

function normalizePoint(raw: unknown): InkPoint | undefined {
  if (!Array.isArray(raw) || raw.length < 2) return undefined;
  const [x, y, p = 0.5, t = 0] = raw as unknown[];
  if (typeof x !== "number" || typeof y !== "number" || !Number.isFinite(x) || !Number.isFinite(y)) return undefined;
  return [
    round(x, 1),
    round(y, 1),
    round(clamp(typeof p === "number" && Number.isFinite(p) ? p : 0.5, 0, 1), 2),
    round(Math.max(0, typeof t === "number" && Number.isFinite(t) ? t : 0), 3),
  ];
}

/** Tratto con valori arrotondati e nei limiti: quello che si salva. */
export function normalizeStroke(raw: Partial<InkStroke> | Record<string, unknown>): InkStroke | undefined {
  const r = raw as Record<string, unknown>;
  const points = Array.isArray(r.points) ? r.points.map(normalizePoint).filter((p): p is InkPoint => !!p) : [];
  if (points.length === 0) return undefined;
  const width = typeof r.width === "number" && Number.isFinite(r.width) && r.width > 0 ? r.width : 2;
  return {
    tool: INK_TOOLS.includes(r.tool as InkTool) ? (r.tool as InkTool) : "pen",
    color: normalizeColor(r.color),
    width: round(clamp(width, 0.1, 200), 1),
    points,
  };
}

/** Altezza della pagina: A4 o più, se i tratti vanno oltre (come sull'iPad). */
export function pageHeight(width: number, strokes: InkStroke[], minimum = 0): number {
  let bottom = 0;
  for (const s of strokes) for (const p of s.points) bottom = Math.max(bottom, p[1]);
  return round(Math.max(width * A4_RATIO, minimum, strokes.length ? bottom + 200 : 0), 1);
}

/** Byte da salvare in `ink_data`. Una pagina senza tratti ha zero byte. */
export function encodeInk(page: InkPage): Uint8Array {
  const strokes = page.strokes.map(normalizeStroke).filter((s): s is InkStroke => !!s);
  if (strokes.length === 0) return new Uint8Array();
  const width = round(page.width > 0 ? page.width : DEFAULT_PAGE_WIDTH, 1);
  const height = round(Math.max(page.height, 0), 1);
  // Ordine delle chiavi fisso: il codec dell'iPad scrive gli stessi byte.
  const json = JSON.stringify({
    v: 1,
    width,
    height,
    strokes: strokes.map((s) => ({ tool: s.tool, color: s.color, width: s.width, points: s.points })),
  });
  return new TextEncoder().encode(PSINK_PREFIX + json);
}

export class InkFormatError extends Error {}

/** Legge una pagina PSINK1 (o vuota). Un PKDrawing dell'iPad dà errore: non si legge sul PC. */
export function decodeInk(bytes: Uint8Array): InkPage {
  const format = inkFormat(bytes);
  if (format === "empty") return { width: DEFAULT_PAGE_WIDTH, height: DEFAULT_PAGE_WIDTH * A4_RATIO, strokes: [] };
  if (format === "other") throw new InkFormatError("disegno dell'iPad (PKDrawing)");
  let raw: unknown;
  try {
    raw = JSON.parse(new TextDecoder().decode(bytes.subarray(PSINK_PREFIX.length)));
  } catch {
    throw new InkFormatError("JSON non valido");
  }
  if (typeof raw !== "object" || raw === null) throw new InkFormatError("JSON non valido");
  const r = raw as Record<string, unknown>;
  if (r.v !== 1) throw new InkFormatError(`versione ${String(r.v)} non supportata`);
  const width = typeof r.width === "number" && r.width > 0 ? r.width : DEFAULT_PAGE_WIDTH;
  const strokes = (Array.isArray(r.strokes) ? r.strokes : [])
    .map((s) => (typeof s === "object" && s ? normalizeStroke(s as Record<string, unknown>) : undefined))
    .filter((s): s is InkStroke => !!s);
  const height = typeof r.height === "number" && r.height > 0 ? r.height : pageHeight(width, strokes);
  return { width, height, strokes };
}

// MARK: base64, come `ink_data` nel JSON della sync

export function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

export function base64ToBytes(base64: string): Uint8Array {
  const binary = atob(base64.replace(/\s/g, ""));
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

// MARK: Disegno

/** Larghezza del tratto a una pressione: 0,5 dà la larghezza nominale. L'evidenziatore è uniforme. */
export function widthAt(stroke: Pick<InkStroke, "tool" | "width">, pressure: number): number {
  if (stroke.tool === "marker") return stroke.width;
  return stroke.width * (0.4 + 1.2 * clamp(pressure, 0, 1));
}

/** Distanza di un punto da un segmento. */
function segmentDistance(px: number, py: number, ax: number, ay: number, bx: number, by: number): number {
  const dx = bx - ax;
  const dy = by - ay;
  const length = dx * dx + dy * dy;
  const t = length === 0 ? 0 : clamp(((px - ax) * dx + (py - ay) * dy) / length, 0, 1);
  return Math.hypot(px - (ax + t * dx), py - (ay + t * dy));
}

/** I segmenti AB e CD si incrociano. */
function segmentsCross(ax: number, ay: number, bx: number, by: number, cx: number, cy: number, dx: number, dy: number): boolean {
  const side = (px: number, py: number, qx: number, qy: number, rx: number, ry: number) =>
    Math.sign((qx - px) * (ry - py) - (qy - py) * (rx - px));
  return side(ax, ay, bx, by, cx, cy) * side(ax, ay, bx, by, dx, dy) < 0
    && side(cx, cy, dx, dy, ax, ay) * side(cx, cy, dx, dy, bx, by) < 0;
}

/**
 * Gomma a tratti: indici dei tratti toccati da un cerchio di raggio `radius` attorno a (x, y),
 * o dal percorso della gomma da `from` a (x, y), così un movimento veloce non salta tratti.
 */
export function strokesHit(strokes: InkStroke[], x: number, y: number, radius: number, from?: [number, number]): number[] {
  const [fx, fy] = from ?? [x, y];
  const hit: number[] = [];
  strokes.forEach((stroke, index) => {
    const reach = radius + stroke.width / 2;
    const pts = stroke.points;
    for (let i = 0; i < pts.length; i++) {
      const [ax, ay] = pts[i];
      const [bx, by] = pts[Math.min(i + 1, pts.length - 1)];
      const d = segmentsCross(ax, ay, bx, by, fx, fy, x, y) ? 0 : Math.min(
        segmentDistance(x, y, ax, ay, bx, by), segmentDistance(fx, fy, ax, ay, bx, by),
        segmentDistance(ax, ay, fx, fy, x, y), segmentDistance(bx, by, fx, fy, x, y));
      if (d <= reach) {
        hit.push(index);
        return;
      }
    }
  });
  return hit;
}

/** Colore per il tema scuro: come PencilKit, la luminosità si inverte (il nero diventa bianco). */
export function displayColor(color: string, dark: boolean): string {
  const hex = normalizeColor(color);
  if (!dark) return hex;
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const l = (max + min) / 2;
  const d = max - min;
  const s = d === 0 ? 0 : d / (1 - Math.abs(2 * l - 1));
  let h = 0;
  if (d !== 0) {
    if (max === r) h = ((g - b) / d) % 6;
    else if (max === g) h = (b - r) / d + 2;
    else h = (r - g) / d + 4;
  }
  // Luminosità invertita; i colori pieni restano riconoscibili.
  const l2 = 1 - l;
  const c = (1 - Math.abs(2 * l2 - 1)) * s;
  const x = c * (1 - Math.abs((h % 2) - 1));
  const m = l2 - c / 2;
  const sector = Math.floor(((h % 6) + 6) % 6);
  const [r1, g1, b1] = [[c, x, 0], [x, c, 0], [0, c, x], [0, x, c], [x, 0, c], [c, 0, x]][sector];
  const to = (v: number) => Math.round(clamp(v + m, 0, 1) * 255).toString(16).padStart(2, "0");
  return `#${to(r1)}${to(g1)}${to(b1)}${hex.slice(7)}`;
}
