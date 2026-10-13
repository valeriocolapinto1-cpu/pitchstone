import { describe, expect, it } from "vitest";
import worker from "../src/index";

function call(path: string, method = "GET"): Promise<Response> {
  const request = new Request(`https://ai-proxy.example${path}`, { method });
  return worker.fetch(request as Request<unknown, IncomingRequestCfProperties>);
}

describe("ai-proxy", () => {
  it("risponde 200 su /health", async () => {
    const response = await call("/health");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: "ok" });
  });

  it("risponde 404 sulle altre route", async () => {
    expect((await call("/")).status).toBe(404);
    expect((await call("/health", "POST")).status).toBe(404);
  });
});
