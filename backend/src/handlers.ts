import type { CompleteJSON } from "./claude.js";
import { ModelError } from "./claude.js";
import {
  type Card,
  CardsModelOutput,
  type CardsRequest,
  cardsJSONSchema,
  DiscoverModelOutput,
  type DiscoverRequest,
  discoverJSONSchema,
  type MomentSummary,
  PickModelOutput,
  type PickRequest,
  pickJSONSchema,
} from "./schemas.js";

// ---------- Prompts ----------

const CARDS_SYSTEM = `You write short "song cards" for a driving-music app. A card describes how a song FEELS, so the app can match songs to moments on the road (sunset drives, rain, leaving a national park, the last miles home).

For each track:
- description: one or two sentences in English about mood, sound and the kind of moment it suits. Concrete, sensory, no hype.
- moods: 2-5 lowercase words (e.g. "nostalgic", "carefree", "melancholic", "triumphant", "warm").
- energy: 1 (very calm) to 5 (very intense).
- scenes: 1-4 lowercase driving scenes it fits (e.g. "golden hour", "open highway", "rainy night", "coming home", "mountain road").
- language: the language the song is sung in ("English", "Mandarin", "instrumental", ...).
- confidence: "high" if you genuinely know this exact recording, "medium" if you know the artist's style well but not this song, "low" if you are guessing. Never invent details about a song you do not know; give a generic description and mark it low instead.

Return one card per input track, using the same id.`;

const PICK_SYSTEM = `You are the music brain of a driving app built on one idea: people live for a few moments, and the right song can make a moment unforgettable. The app detected a moment on the driver's trip. Choose the songs from the candidate list that fit THIS moment best, ranked best first.

How to choose:
- Fit the feeling of the moment as a whole: time of day, light, weather, where they have been, how long they have been driving, where they are heading.
- Songs the driver tagged for this kind of moment (userTagged) and their anthems are strong signals. Prefer them when they genuinely fit, but a better-fitting song can win.
- Learn from the driver's past hits and misses.
- Avoid songs they just skipped and avoid repeating a song from recentPlays.
- Only choose ids from the candidate list.

Each reason is one line, at most 90 characters, written to the driver in second person, about why this song fits right now. Do not state facts about a song that are not in its card.`;

const DISCOVER_SYSTEM = `You suggest real, existing songs the driver probably has not heard, for a moment on their drive. Stay close to the taste implied by the artists they love. Only suggest songs you are confident exist as released recordings, with the exact title and primary artist as listed on streaming services. Never suggest songs in the exclude list. Each reason is one line, at most 90 characters, to the driver.`;

function describeMoment(m: MomentSummary): string {
  const lines = [
    `Moment: ${m.type} — ${m.detail}`,
    `Local time: ${m.localTime}`,
    `Trip so far: ${m.tripMinutes} min`,
  ];
  if (m.weather) lines.push(`Weather: ${m.weather}`);
  if (m.placeName || m.placeKind) {
    lines.push(`Place: ${[m.placeName, m.placeKind && `(${m.placeKind})`].filter(Boolean).join(" ")}`);
  }
  if (m.lastStopMinutes !== undefined) {
    lines.push(`Last stop: ${m.lastStopName ?? "a stop"}, stayed ${m.lastStopMinutes} min`);
  }
  if (m.recentPlays.length > 0) {
    lines.push(
      "Recently played:",
      ...m.recentPlays.map((p) => `- ${p.name} — ${p.artists.join(", ")} (${p.outcome})`),
    );
  }
  return lines.join("\n");
}

// ---------- Handlers ----------

export async function makeCards(req: CardsRequest, complete: CompleteJSON): Promise<{ cards: Card[] }> {
  const user = JSON.stringify({ tracks: req.tracks });
  const out = await complete({
    system: CARDS_SYSTEM,
    user,
    jsonSchema: cardsJSONSchema,
    validator: CardsModelOutput,
    effort: "low",
    maxTokens: 16000,
  });
  const wanted = new Set(req.tracks.map((t) => t.id));
  const seen = new Set<string>();
  const cards = out.cards.filter((c) => {
    if (!wanted.has(c.id) || seen.has(c.id)) return false;
    seen.add(c.id);
    return true;
  });
  return { cards };
}

export async function pickSongs(
  req: PickRequest,
  complete: CompleteJSON,
): Promise<{ picks: { id: string; reason: string }[] }> {
  const candidates = req.candidates.map((c) => ({
    id: c.id,
    song: `${c.name} — ${c.artists.join(", ")}`,
    card: c.card,
    userTagged: c.userTagged,
    anthem: c.anthem,
    discovery: c.isDiscovery,
  }));
  const fmt = (t: { name: string; artists: string[]; moment: string }) =>
    `- ${t.name} — ${t.artists.join(", ")} (at ${t.moment})`;
  const user = [
    describeMoment(req.moment),
    "",
    "Past hits:",
    ...(req.examples.hits.length ? req.examples.hits.map(fmt) : ["(none yet)"]),
    "Past misses (skipped):",
    ...(req.examples.misses.length ? req.examples.misses.map(fmt) : ["(none yet)"]),
    "",
    `Choose the top ${req.count}, ranked.`,
    "Candidates:",
    JSON.stringify(candidates),
  ].join("\n");

  const out = await complete({
    system: PICK_SYSTEM,
    user,
    jsonSchema: pickJSONSchema,
    validator: PickModelOutput,
    effort: "medium",
    maxTokens: 16000,
  });

  const valid = new Set(req.candidates.map((c) => c.id));
  const seen = new Set<string>();
  const picks = out.picks
    .filter((p) => valid.has(p.id) && !seen.has(p.id) && seen.add(p.id))
    .slice(0, req.count)
    .map((p) => ({ id: p.id, reason: p.reason.trim().slice(0, 140) }));
  if (picks.length === 0) throw new ModelError("model picked no valid candidates", 502);
  return { picks };
}

export async function discoverSongs(
  req: DiscoverRequest,
  complete: CompleteJSON,
): Promise<{ songs: { title: string; artist: string; reason: string }[] }> {
  const user = [
    describeMoment(req.moment),
    "",
    `Artists the driver loves: ${req.tasteArtists.join(", ")}`,
    "Exclude (already known):",
    ...req.exclude.map((t) => `- ${t.name} — ${t.artists.join(", ")}`),
    "",
    `Suggest ${req.count} songs.`,
  ].join("\n");
  const out = await complete({
    system: DISCOVER_SYSTEM,
    user,
    jsonSchema: discoverJSONSchema,
    validator: DiscoverModelOutput,
    effort: "medium",
    maxTokens: 16000,
  });
  const excluded = new Set(req.exclude.map((t) => t.name.toLowerCase()));
  const songs = out.songs.filter((s) => !excluded.has(s.title.toLowerCase())).slice(0, req.count);
  return { songs };
}
