// Record del server, nel formato di /sync/push e /sync/pull (lo stesso dell'iPad).
// Sul PC non esistono dati di salute: il server non li ha e la PWA non li crea.

export const NODE_TYPES = ["concept", "idea", "project", "exam", "person"] as const;
export const AREAS = ["studio", "progetti", "lavoro", "persone", "interessi"] as const;
export type NodeType = (typeof NODE_TYPES)[number];
export type Area = (typeof AREAS)[number];

export interface NodeRecord {
  id: string;
  type: NodeType;
  title: string;
  body_md: string;
  area: Area;
  tags: string[];
  version: number;
  created_at: string;
  updated_at: string;
  deleted_at: string | null;
  device_id: string;
}

export interface EdgeRecord {
  id: string;
  source_id: string;
  target_id: string;
  kind: "link" | "ai" | "manual";
  label: string | null;
  version: number;
  created_at: string;
  deleted_at: string | null;
}

/** Pagine a penna e allegati come arrivano dal server. Gli allegati sul PC si vedono soltanto. */
export interface ExtraRecord {
  id: string;
  node_id: string | null;
  deleted_at: string | null;
  [key: string]: unknown;
}

export const INK_BACKGROUNDS = ["blank", "lines", "grid"] as const;
export type InkBackground = (typeof INK_BACKGROUNDS)[number];

/**
 * Pagina a penna (tabella `ink_pages`). `ink_data` è in base64 come nel JSON della sync:
 * PSINK1 (ADR 0015) si modifica anche sul PC, un PKDrawing solo sull'iPad.
 * Con `attachment_id` è un'annotazione su un PDF, non una pagina del nodo.
 */
export interface InkPageRecord extends ExtraRecord {
  node_id: string;
  page_no: number;
  background: InkBackground;
  ink_data: string;
  attachment_id: string | null;
  pdf_page: number | null;
  version: number;
  created_at: string;
  updated_at: string;
  device_id: string;
}

export type Entity = "node" | "edge" | "ink_page";

/** Tag che tiene un appunto solo su questo computer: niente server, niente Gemini. */
export const LOCAL_ONLY_TAG = "solo-locale";

export function isLocalOnly(node: Pick<NodeRecord, "tags">): boolean {
  return node.tags.includes(LOCAL_ONLY_TAG);
}

export interface PendingChange {
  entity: Entity;
  id: string;
  /** Ultima versione del server su cui si basa la modifica; null per un record nuovo. */
  baseVersion: number | null;
  /** Cresce a ogni modifica locale: una voce cambiata durante il push resta in outbox. */
  revision: number;
  rejection?: string;
}

export const LABELS = {
  type: { concept: "Concetto", idea: "Idea", project: "Progetto", exam: "Esame", person: "Persona" },
  area: { studio: "Studio", progetti: "Progetti", lavoro: "Lavoro e clienti", persone: "Persone", interessi: "Interessi" },
} as const;

/** Titolo per i confronti dei `[[link]]`: senza maiuscole, accenti e spazi doppi. */
export function titleKey(title: string): string {
  return title.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase().split(/\s+/).filter(Boolean).join(" ");
}

/** Destinazioni dei `[[Titolo]]`, `[[Titolo|testo]]` e `[[Titolo#sezione]]`, fuori dal codice. */
export function wikiTargets(markdown: string): string[] {
  const text = markdown.replace(/```[\s\S]*?```/g, "").replace(/`[^`\n]*`/g, "");
  const seen = new Set<string>();
  const result: string[] = [];
  for (const match of text.matchAll(/\[\[([^\]\n]+?)\]\]/g)) {
    const target = match[1].split("|")[0].split("#")[0].trim();
    if (target && !seen.has(titleKey(target))) {
      seen.add(titleKey(target));
      result.push(target);
    }
  }
  return result;
}
