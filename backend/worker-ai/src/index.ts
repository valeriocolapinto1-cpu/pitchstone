export interface Env {
  GEMINI_API_KEY: string;
}

export default {
  async fetch(request): Promise<Response> {
    const { pathname } = new URL(request.url);
    if (request.method === "GET" && pathname === "/health") {
      return Response.json({ status: "ok" });
    }
    return new Response("Not Found", { status: 404 });
  },
} satisfies ExportedHandler<Env>;
