import { vi } from "vitest";

export type Rows = Record<string, Record<string, unknown>[]>;

/** Supabase finto: RPC di backup con paginazione per id e bucket `backups` in memoria. */
export function fake(data: Rows, { ink = [] as { id: string; ink_data: string }[], failPut }: { ink?: { id: string; ink_data: string }[]; failPut?: (path: string) => boolean } = {}) {
  const objects = new Map<string, string>();
  const calls: { fn: string; args: Record<string, unknown> }[] = [];
  const fetchImpl = vi.fn<typeof fetch>(async (input, init) => {
    const url = new URL(String(input));
    const body = typeof init?.body === "string" ? init.body : init?.body ? new TextDecoder().decode(init.body as Uint8Array) : "";
    if (url.pathname.startsWith("/rest/v1/rpc/")) {
      const fn = url.pathname.split("/").pop() ?? "";
      const args = body ? (JSON.parse(body) as Record<string, unknown>) : {};
      calls.push({ fn, args });
      if (fn === "backup_counts") {
        return Response.json({
          nodes: data.nodes?.length ?? 0, edges: data.edges?.length ?? 0, node_versions: data.node_versions?.length ?? 0,
          ink_pages: data.ink_pages?.length ?? 0, attachments: data.attachments?.length ?? 0, purged: data.purged?.length ?? 0,
        });
      }
      if (fn === "backup_rows") {
        const rows = (data[String(args.p_table)] ?? []).filter((row) => !args.p_after || String(row.id) > String(args.p_after));
        const limit = Number(args.p_limit);
        const page = rows.slice(0, 2);
        return Response.json({ rows: page, last: page.at(-1)?.id ?? null, more: rows.length > Math.min(2, limit) });
      }
      if (fn === "backup_ink_rows") return Response.json({ rows: ink, last: ink.at(-1)?.id ?? null, more: false });
      if (fn === "backup_mark_done") return Response.json(null);
      if (fn === "backup_restore_finish") return Response.json(2);
      if (fn.startsWith("backup_restore")) return Response.json(Array.isArray(args.p_rows) ? args.p_rows.length : null);
      if (fn === "db_size_bytes") return Response.json(400 * 1024 * 1024);
      return new Response("rpc sconosciuta", { status: 404 });
    }
    const objectPrefix = "/storage/v1/object/backups/";
    if (url.pathname.startsWith("/storage/v1/object/list/backups")) {
      const { prefix } = JSON.parse(body) as { prefix: string };
      const base = prefix === "" ? "" : `${prefix}/`;
      const seen = new Map<string, Entry>();
      for (const path of objects.keys()) {
        if (!path.startsWith(base)) continue;
        const rest = path.slice(base.length);
        const [first, ...tail] = rest.split("/");
        if (!seen.has(first)) seen.set(first, { name: first, id: tail.length === 0 ? "f" : null });
      }
      const sortBy = (JSON.parse(body) as { sortBy: { order: string } }).sortBy;
      const entries = [...seen.values()].sort((a, b) => a.name.localeCompare(b.name));
      return Response.json(sortBy.order === "desc" ? entries.reverse() : entries);
    }
    if (url.pathname.startsWith(objectPrefix) && init?.method === "POST") {
      const path = decodeURIComponent(url.pathname.slice(objectPrefix.length));
      if (failPut?.(path)) return new Response("no", { status: 500 });
      if (objects.has(path)) return new Response("esiste", { status: 400 });
      objects.set(path, body);
      return Response.json({ Key: path });
    }
    if (url.pathname.startsWith(objectPrefix) && (!init?.method || init.method === "GET")) {
      const found = objects.get(decodeURIComponent(url.pathname.slice(objectPrefix.length)));
      return found === undefined ? new Response("no", { status: 404 }) : new Response(found);
    }
    if (url.pathname === "/storage/v1/object/backups" && init?.method === "DELETE") {
      for (const path of (JSON.parse(body) as { prefixes: string[] }).prefixes) objects.delete(path);
      return Response.json([]);
    }
    return new Response(`inatteso ${url.pathname}`, { status: 599 });
  });
  return { fetchImpl, objects, calls };
}

export interface Entry {
  name: string;
  id: string | null;
}

export const id = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
export const node = (n: number, extra: Record<string, unknown> = {}) => ({ id: id(n), type: "concept", area: "studio", title: `n${n}`, ...extra });
export const sample: Rows = {
  nodes: [node(1), node(2), node(3)],
  edges: [{ id: id(101), source_id: id(1), target_id: id(2) }],
  node_versions: [{ id: id(201), node_id: id(1), version: 1 }],
  ink_pages: [{ id: id(301), node_id: id(1) }],
  attachments: [],
  purged: [{ id: id(401), entity: "node" }],
};
export const ink = [{ id: id(301), ink_data: "QUJDRA==" }];

