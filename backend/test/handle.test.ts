import { describe, expect, it } from "vitest";
import type { CompleteJSON, JSONRequest } from "../src/claude.js";
import { ModelError } from "../src/claude.js";
import { handle } from "../src/index.js";

const env = { ANTHROPIC_API_KEY: "unused", APP_TOKEN: "secret" };

function post(path: string, body: unknown, token = "secret") {
  return new Request(`https://example.test${path}`, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

/** A fake model that records the request and returns a fixed payload. */
function fakeModel(payload: unknown) {
  const calls: JSONRequest<unknown>[] = [];
  const complete: CompleteJSON = async <T>(req: JSONRequest<T>) => {
    calls.push(req as JSONRequest<unknown>);
    return req.validator.parse(payload);
  };
  return { complete, calls };
}

const moment = {
  type: "sunset",
  detail: "sun is setting on the drive home",
  localTime: "18:42, Saturday",
  weather: "clear, 21°C",
  placeKind: "national park",
  placeName: "Yosemite National Park",
  tripMinutes: 35,
  lastStopMinutes: 320,
  lastStopName: "Yosemite Valley",
};

const card = { description: "warm golden-hour ballad", moods: ["warm"], energy: 2, scenes: ["golden hour"], language: "Mandarin" };

describe("auth and routing", () => {
  it("rejects a wrong token", async () => {
    const res = await handle(post("/v1/pick", {}, "nope"), env, fakeModel({}).complete);
    expect(res.status).toBe(401);
  });

  it("returns 404 for unknown paths and 405 for GET", async () => {
    expect((await handle(post("/v1/nope", {}), env)).status).toBe(404);
    const get = new Request("https://example.test/v1/pick");
    expect((await handle(get, env)).status).toBe(405);
  });

  it("serves health without auth", async () => {
    const res = await handle(new Request("https://example.test/health"), env);
    expect(await res.json()).toEqual({ ok: true });
  });

  it("forwards the Spotify OAuth callback into the app scheme", async () => {
    const res = await handle(new Request("https://example.test/spotify/callback?code=abc&state=xyz&extra=1"), env);
    expect(res.status).toBe(302);
    expect(res.headers.get("location")).toBe("moments://spotify-callback?code=abc&state=xyz");
    const bad = await handle(new Request("https://example.test/spotify/callback?code=abc"), env);
    expect(bad.status).toBe(400);
  });

  it("validates request bodies", async () => {
    const res = await handle(post("/v1/pick", { moment, candidates: [] }), env, fakeModel({}).complete);
    expect(res.status).toBe(400);
  });
});

describe("/v1/pick", () => {
  const candidates = [
    { id: "a", name: "日落大道", artists: ["梁博"], card, userTagged: true, anthem: true },
    { id: "b", name: "出现又离开", artists: ["梁博"], card },
    { id: "c", name: "Green Green Grass", artists: ["George Ezra"], card: { ...card, energy: 4 } },
  ];

  it("keeps only valid, unique candidate ids, capped at count", async () => {
    const { complete, calls } = fakeModel({
      picks: [
        { id: "a", reason: "Golden light, the long road home." },
        { id: "zzz", reason: "hallucinated" },
        { id: "a", reason: "duplicate" },
        { id: "b", reason: "Second best." },
        { id: "c", reason: "Third." },
      ],
    });
    const res = await handle(post("/v1/pick", { moment, candidates, count: 2 }), env, complete);
    expect(res.status).toBe(200);
    const body = (await res.json()) as { picks: { id: string }[] };
    expect(body.picks.map((p) => p.id)).toEqual(["a", "b"]);
    expect(calls[0].user).toContain("Yosemite National Park");
    expect(calls[0].user).toContain("stayed 320 min");
    expect(calls[0].effort).toBe("medium");
  });

  it("fails with 502 when nothing valid comes back", async () => {
    const { complete } = fakeModel({ picks: [{ id: "zzz", reason: "x" }] });
    const res = await handle(post("/v1/pick", { moment, candidates }), env, complete);
    expect(res.status).toBe(502);
  });

  it("maps model errors to their status", async () => {
    const complete: CompleteJSON = async () => {
      throw new ModelError("rate limited", 429);
    };
    const res = await handle(post("/v1/pick", { moment, candidates }), env, complete);
    expect(res.status).toBe(429);
  });
});

describe("/v1/cards", () => {
  it("drops cards for ids that were not requested", async () => {
    const good = { id: "t1", description: "d", moods: ["warm"], energy: 2, scenes: ["golden hour"], language: "Mandarin", confidence: "high" };
    const { complete } = fakeModel({ cards: [good, { ...good, id: "other" }] });
    const res = await handle(post("/v1/cards", { tracks: [{ id: "t1", name: "日落大道", artists: ["梁博"] }] }), env, complete);
    const body = (await res.json()) as { cards: { id: string }[] };
    expect(body.cards.map((c) => c.id)).toEqual(["t1"]);
  });
});

describe("/v1/discover", () => {
  it("filters suggestions that are in the exclude list", async () => {
    const { complete } = fakeModel({
      songs: [
        { title: "日落大道", artist: "梁博", reason: "x" },
        { title: "Shotgun", artist: "George Ezra", reason: "Sunny and loose." },
      ],
    });
    const res = await handle(
      post("/v1/discover", { moment, tasteArtists: ["梁博", "George Ezra"], exclude: [{ name: "日落大道", artists: ["梁博"] }] }),
      env,
      complete,
    );
    const body = (await res.json()) as { songs: { title: string }[] };
    expect(body.songs.map((s) => s.title)).toEqual(["Shotgun"]);
  });
});
