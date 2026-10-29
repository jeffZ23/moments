import type { z } from "zod";
import { type CompleteJSON, claudeCompleter, ModelError } from "./claude.js";
import { discoverSongs, makeCards, pickSongs } from "./handlers.js";
import { CardsRequest, DiscoverRequest, PickRequest } from "./schemas.js";

export interface Env {
  ANTHROPIC_API_KEY: string;
  /** Shared secret the iOS app sends as `Authorization: Bearer <APP_TOKEN>`. */
  APP_TOKEN: string;
  MODEL?: string;
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

type Route = {
  schema: z.ZodTypeAny;
  run: (body: any, complete: CompleteJSON) => Promise<unknown>;
};

const routes: Record<string, Route> = {
  "/v1/cards": { schema: CardsRequest, run: makeCards },
  "/v1/pick": { schema: PickRequest, run: pickSongs },
  "/v1/discover": { schema: DiscoverRequest, run: discoverSongs },
};

/** Spotify requires an HTTPS redirect URI; this forwards the OAuth result into the iOS app's URL scheme. */
export const APP_CALLBACK = "moments://spotify-callback";

function spotifyCallback(url: URL): Response {
  const forwarded = new URLSearchParams();
  for (const key of ["code", "state", "error"]) {
    const value = url.searchParams.get(key);
    if (value) forwarded.set(key, value.slice(0, 2048));
  }
  if (!forwarded.has("state") || (!forwarded.has("code") && !forwarded.has("error"))) {
    return json({ error: "missing OAuth parameters" }, 400);
  }
  return new Response(null, { status: 302, headers: { location: `${APP_CALLBACK}?${forwarded}` } });
}

export async function handle(request: Request, env: Env, complete?: CompleteJSON): Promise<Response> {
  const { pathname } = new URL(request.url);

  if (pathname === "/health") return json({ ok: true });
  if (pathname === "/spotify/callback") return spotifyCallback(new URL(request.url));

  const route = routes[pathname];
  if (!route) return json({ error: "not found" }, 404);
  if (request.method !== "POST") return json({ error: "method not allowed" }, 405);

  const auth = request.headers.get("authorization") ?? "";
  if (!env.APP_TOKEN || !timingSafeEqual(auth, `Bearer ${env.APP_TOKEN}`)) {
    return json({ error: "unauthorized" }, 401);
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return json({ error: "invalid JSON" }, 400);
  }
  const parsed = route.schema.safeParse(body);
  if (!parsed.success) {
    return json({ error: "invalid request", issues: parsed.error.issues.slice(0, 5) }, 400);
  }

  try {
    const completer = complete ?? claudeCompleter(env.ANTHROPIC_API_KEY, env.MODEL || "claude-opus-5-5");
    return json(await route.run(parsed.data, completer));
  } catch (error) {
    if (error instanceof ModelError) return json({ error: error.message }, error.status);
    return json({ error: "internal error" }, 500);
  }
}

export default {
  fetch: (request: Request, env: Env) => handle(request, env),
};
