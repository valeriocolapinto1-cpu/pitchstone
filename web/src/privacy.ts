// Regole di privacy del PC: un appunto non parte per il server né per Gemini se è tenuto solo in locale
// (tag `solo-locale`) o se sembra un dato di salute e l'utente non ha detto che è innocuo.
import { assess, type HealthAssessment, isHeld } from "./health";
import { isLocalOnly, type NodeRecord } from "./model";
import type { Store } from "./store";

export function nodeText(node: Pick<NodeRecord, "title" | "body_md">): string {
  return `${node.title}\n${node.body_md}`;
}

export class Privacy {
  private cache = new Map<string, { key: string; result: HealthAssessment }>();

  constructor(private store: Store) {}

  /** Esito del rilevatore, ricalcolato solo quando il testo del nodo cambia. */
  assessment(node: NodeRecord): HealthAssessment {
    const key = `${node.updated_at}|${node.title.length}|${node.body_md.length}`;
    const cached = this.cache.get(node.id);
    if (cached && cached.key === key) return cached.result;
    const result = assess(nodeText(node));
    this.cache.set(node.id, { key, result });
    return result;
  }

  /** Sospetto e non ancora giudicato: resta sul PC, anche nel cestino. */
  isHeld(node: NodeRecord): boolean {
    return !isLocalOnly(node) && isHeld(this.assessment(node), this.store.dismissedSignals(node.id));
  }

  /** Non deve lasciare il PC: né sync né prompt. */
  isBlocked(node: NodeRecord): boolean {
    return isLocalOnly(node) || this.isHeld(node);
  }

  isBlockedId(id: string): boolean {
    const node = this.store.node(id);
    return node ? this.isBlocked(node) : false;
  }

  /** "Non è un dato di salute": i segnali di adesso non bloccano più il nodo. */
  dismiss(node: NodeRecord) {
    this.store.setDismissedSignals(node.id, [...this.store.dismissedSignals(node.id), ...this.assessment(node).signals]);
  }
}
