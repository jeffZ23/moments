import Anthropic from "@anthropic-ai/sdk";
import type { z } from "zod";

export type Effort = "low" | "medium" | "high";

export interface JSONRequest<T> {
  system: string;
  user: string;
  jsonSchema: Record<string, unknown>;
  validator: z.ZodType<T>;
  effort: Effort;
  maxTokens: number;
}

/** Calls the model and returns validated JSON. Injected into handlers so tests can stub it. */
export type CompleteJSON = <T>(req: JSONRequest<T>) => Promise<T>;

export class ModelError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
  }
}

export function claudeCompleter(apiKey: string, model: string): CompleteJSON {
  const client = new Anthropic({ apiKey, maxRetries: 2 });

  return async <T>(req: JSONRequest<T>): Promise<T> => {
    let response: Anthropic.Beta.Messages.BetaMessage;
    try {
      response = await client.beta.messages.create({
        model,
        max_tokens: req.maxTokens,
        betas: ["server-side-fallback-2026-07-01"],
        fallbacks: "default",
        output_config: {
          effort: req.effort,
          format: { type: "json_schema", schema: req.jsonSchema },
        },
        system: req.system,
        messages: [{ role: "user", content: req.user }],
      });
    } catch (error) {
      if (error instanceof Anthropic.RateLimitError) throw new ModelError("rate limited", 429);
      if (error instanceof Anthropic.AuthenticationError) throw new ModelError("bad API key", 500);
      if (error instanceof Anthropic.APIError) throw new ModelError(`model error ${error.status}`, 502);
      throw new ModelError("model unreachable", 502);
    }

    if (response.stop_reason === "refusal") throw new ModelError("model declined", 502);
    if (response.stop_reason === "max_tokens") throw new ModelError("model output truncated", 502);

    const text = response.content
      .map((block) => (block.type === "text" ? block.text : ""))
      .join("");
    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch {
      throw new ModelError("model returned invalid JSON", 502);
    }
    const result = req.validator.safeParse(parsed);
    if (!result.success) throw new ModelError("model returned unexpected shape", 502);
    return result.data;
  };
}
