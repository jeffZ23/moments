import { z } from "zod";

// ---------- Shared ----------

export const MomentType = z.enum(["sunset", "rain", "leavingLongStop", "nearingHome"]);

export const MomentSummary = z.object({
  type: MomentType,
  detail: z.string().max(200),
  localTime: z.string().max(60),
  weather: z.string().max(80).optional(),
  placeKind: z.string().max(60).optional(),
  placeName: z.string().max(80).optional(),
  tripMinutes: z.number().int().min(0),
  lastStopMinutes: z.number().int().min(0).optional(),
  lastStopName: z.string().max(80).optional(),
  recentPlays: z
    .array(
      z.object({
        name: z.string().max(200),
        artists: z.array(z.string().max(100)).max(5),
        outcome: z.enum(["played", "skipped"]),
      }),
    )
    .max(10)
    .default([]),
});
export type MomentSummary = z.infer<typeof MomentSummary>;

const TrackRef = z.object({
  name: z.string().min(1).max(200),
  artists: z.array(z.string().max(100)).min(1).max(5),
});

// ---------- /v1/cards ----------

export const CardsRequest = z.object({
  tracks: z
    .array(
      TrackRef.extend({
        id: z.string().min(1).max(64),
        album: z.string().max(200).optional(),
        releaseYear: z.number().int().optional(),
      }),
    )
    .min(1)
    .max(50),
});
export type CardsRequest = z.infer<typeof CardsRequest>;

export const Card = z.object({
  id: z.string(),
  description: z.string(),
  moods: z.array(z.string()),
  energy: z.number().int().min(1).max(5),
  scenes: z.array(z.string()),
  language: z.string(),
  confidence: z.enum(["high", "medium", "low"]),
});
export type Card = z.infer<typeof Card>;

export const CardsModelOutput = z.object({ cards: z.array(Card) });

export const cardsJSONSchema = {
  type: "object",
  properties: {
    cards: {
      type: "array",
      items: {
        type: "object",
        properties: {
          id: { type: "string" },
          description: { type: "string" },
          moods: { type: "array", items: { type: "string" } },
          energy: { type: "integer", enum: [1, 2, 3, 4, 5] },
          scenes: { type: "array", items: { type: "string" } },
          language: { type: "string" },
          confidence: { type: "string", enum: ["high", "medium", "low"] },
        },
        required: ["id", "description", "moods", "energy", "scenes", "language", "confidence"],
        additionalProperties: false,
      },
    },
  },
  required: ["cards"],
  additionalProperties: false,
} as const;

// ---------- /v1/pick ----------

export const PickRequest = z.object({
  moment: MomentSummary,
  candidates: z
    .array(
      TrackRef.extend({
        id: z.string().min(1).max(64),
        card: z.object({
          description: z.string().max(400),
          moods: z.array(z.string().max(40)).max(8),
          energy: z.number().int().min(1).max(5),
          scenes: z.array(z.string().max(40)).max(8),
          language: z.string().max(40),
        }),
        userTagged: z.boolean().default(false),
        anthem: z.boolean().default(false),
        isDiscovery: z.boolean().default(false),
      }),
    )
    .min(1)
    .max(40),
  examples: z
    .object({
      hits: z.array(TrackRef.extend({ moment: MomentType })).max(10).default([]),
      misses: z.array(TrackRef.extend({ moment: MomentType })).max(10).default([]),
    })
    .default({ hits: [], misses: [] }),
  count: z.number().int().min(1).max(3).default(3),
});
export type PickRequest = z.infer<typeof PickRequest>;

export const PickModelOutput = z.object({
  picks: z.array(z.object({ id: z.string(), reason: z.string() })),
});

export const pickJSONSchema = {
  type: "object",
  properties: {
    picks: {
      type: "array",
      items: {
        type: "object",
        properties: { id: { type: "string" }, reason: { type: "string" } },
        required: ["id", "reason"],
        additionalProperties: false,
      },
    },
  },
  required: ["picks"],
  additionalProperties: false,
} as const;

// ---------- /v1/discover ----------

export const DiscoverRequest = z.object({
  moment: MomentSummary,
  tasteArtists: z.array(z.string().max(100)).min(1).max(30),
  exclude: z.array(TrackRef).max(100).default([]),
  count: z.number().int().min(1).max(8).default(5),
});
export type DiscoverRequest = z.infer<typeof DiscoverRequest>;

export const DiscoverModelOutput = z.object({
  songs: z.array(z.object({ title: z.string(), artist: z.string(), reason: z.string() })),
});

export const discoverJSONSchema = {
  type: "object",
  properties: {
    songs: {
      type: "array",
      items: {
        type: "object",
        properties: {
          title: { type: "string" },
          artist: { type: "string" },
          reason: { type: "string" },
        },
        required: ["title", "artist", "reason"],
        additionalProperties: false,
      },
    },
  },
  required: ["songs"],
  additionalProperties: false,
} as const;
