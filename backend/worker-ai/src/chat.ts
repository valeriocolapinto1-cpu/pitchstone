// Chat con Gemini (ADR 0009). La chiave resta nel Worker; il client manda
// istruzioni, fonti già filtrate (mai dati di salute) e conversazione.
import { BadRequest } from "./sync";

export const DEFAULT_MODEL = "gemini-2.5-flash";
const MAX_SYSTEM_CHARS = 120_000;
const MAX_MESSAGES = 40;
const MAX_MESSAGE_CHARS = 20_000;

export interface ChatRequest {
  system: string;
  messages: { role: "user" | "assistant"; text: string }[];
  maxOutputTokens: number;
}

export function validateChat(body: unknown): ChatRequest {
  if (typeof body !== "object" || body === null) throw new BadRequest("body non valido");
  const { system, messages, maxOutputTokens } = body as Record<string, unknown>;
  if (typeof system !== "string" || system.length > MAX_SYSTEM_CHARS) throw new BadRequest("system non valido");
  if (!Array.isArray(messages) || messages.length === 0 || messages.length > MAX_MESSAGES) {
    throw new BadRequest(`messages deve avere da 1 a ${MAX_MESSAGES} elementi`);
  }
  const checked = messages.map((message: unknown): ChatRequest["messages"][number] => {
    const { role, text } = (message ?? {}) as Record<string, unknown>;
    if (role !== "user" && role !== "assistant") throw new BadRequest("ruolo non valido");
    if (typeof text !== "string" || text.length === 0 || text.length > MAX_MESSAGE_CHARS) {
      throw new BadRequest("testo non valido");
    }
    return { role, text };
  });
  if (checked[checked.length - 1].role !== "user") throw new BadRequest("l'ultimo messaggio deve essere una domanda");
  if (typeof maxOutputTokens !== "number" || !Number.isInteger(maxOutputTokens) || maxOutputTokens < 1 || maxOutputTokens > 8192) {
    throw new BadRequest("maxOutputTokens non valido");
  }
  return { system, messages: checked, maxOutputTokens };
}

interface GeminiResponse {
  candidates?: { content?: { parts?: { text?: string }[] }; finishReason?: string }[];
  promptFeedback?: { blockReason?: string };
}

export async function chat(apiKey: string, model: string, request: ChatRequest): Promise<Response> {
  try {
    return await callGemini(apiKey, model, request);
  } catch {
    // Rete o JSON non valido: il client passa al modello locale.
    return Response.json({ error: "Gemini non raggiungibile" }, { status: 502 });
  }
}

async function callGemini(apiKey: string, model: string, request: ChatRequest): Promise<Response> {
  const upstream = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`,
    {
      method: "POST",
      headers: { "content-type": "application/json", "x-goog-api-key": apiKey },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: request.system }] },
        contents: request.messages.map((message) => ({
          role: message.role === "assistant" ? "model" : "user",
          parts: [{ text: message.text }],
        })),
        // Senza "thinking": i suoi token conterebbero nel limite della risposta e nella quota gratuita.
        generationConfig: {
          maxOutputTokens: request.maxOutputTokens,
          temperature: 0.3,
          thinkingConfig: { thinkingBudget: 0 },
        },
      }),
    },
  );
  if (upstream.status === 429) {
    // Limite del piano gratuito: il client passa al modello locale.
    return Response.json({ error: "limite di Gemini raggiunto" }, { status: 429 });
  }
  if (!upstream.ok) {
    // Il testo di Google non arriva al client: potrebbe ripetere parti della richiesta.
    return Response.json({ error: `Gemini ha risposto ${upstream.status}` }, { status: 502 });
  }
  const data = (await upstream.json()) as GeminiResponse;
  const text = (data.candidates?.[0]?.content?.parts ?? []).map((part) => part.text ?? "").join("");
  if (text.trim().length === 0) {
    const reason = data.promptFeedback?.blockReason ?? data.candidates?.[0]?.finishReason ?? "risposta vuota";
    return Response.json({ error: `nessuna risposta (${reason})` }, { status: 502 });
  }
  if (data.candidates?.[0]?.finishReason === "MAX_TOKENS") {
    return Response.json({ text: `${text}\n\n_(Risposta interrotta: troppo lunga.)_` });
  }
  return Response.json({ text });
}
