# Moments: design decisions

People live for a few moments. Moments notices them on a drive and plays the song that fits: 日落大道 on the sunset drive home from a national park, Green Green Grass on a happy highway.

This file records the decisions behind v1 and why each was made.

## Product

| Decision | Choice | Why |
|---|---|---|
| Goal | Portfolio project, tested on my own drives | Real moments make a better demo than synthetic ones |
| Form | Native iPhone app that picks songs and plays them through Spotify | Spotify no longer allows in-app plugins; the Web API can still read the library and control playback |
| Songs | Mostly from your own library, about 1 in 5 discoveries | In a perfect moment you want a song you already love |
| When it acts | Only at detected moments, plus a manual start | Rare is what makes it special; no taps while driving |
| "Recent events" | The trip itself: where you've been and for how long | Free from GPS, private, and enough for "leaving Yosemite after 10 hours" |
| Sensing | GPS, sun position, weather, map place names; no camera | Cheap and private; live Google Maps data (route, ETA) is a later step |

## Moments (v1)

| Moment | Trigger | Playback |
|---|---|---|
| Sunset | Sun between 6° and −4° elevation, afternoon | Cuts in |
| Rain | Rain state differs from the start of the trip | Cuts in |
| Leaving a long stop | Stayed ≥ 90 min somewhere that isn't home, moved ≥ 1 km, within 30 min of leaving | Waits for the current song |
| Nearing home | Within 3 km of home, trip ≥ 15 min and went ≥ 5 km away | Cuts in |

- At most one moment song every 15 minutes, and each moment type fires once per trip.
- Conditions stay true for a while, so a moment held back by the cooldown can still fire later.
- When several moments happen at once (sunset while leaving the park), the first in priority order leads (sunset, nearing home, leaving, rain) and the others fold into the description.
- Cutting in is queue + skip, with no fade: Spotify usually blocks remote volume control when it's playing on an iPhone.

## Picking a song

1. **Song cards.** The backend asks Claude, once per song, to describe how it feels: mood, energy, scenes, language, and a confidence level. Spotify no longer gives new apps audio features, so this replaces them.
2. **Shortlist on the phone.** The moment becomes a query ("golden hour, sunset drive, warm, nostalgic…"). Each card is scored by on-device sentence-embedding similarity (Apple NaturalLanguage), plus a bonus for songs tagged for this moment, a bonus for anthems, and the feedback score. Songs with low-confidence cards are dropped unless you tagged them. The top 30 survive.
3. **Pick.** The backend sends the moment summary, the 30 cards and your recent hits and misses to Claude. Claude returns a ranked top 3, each with a one-line reason. IDs are validated against the candidates.
4. **Play #1.** A skip within 20 seconds is a miss and #2 plays right away.

**Feedback.** Each song has a score per moment type: a play-through is +1, a skip is −2, a 4–5★ rating is +2 and a 1–2★ rating is −2. A score of −4 or lower blocks the song for that moment. Your last 10 hits and misses go into the prompt as examples.

**Repeats.** Anthems (starred) can play every time. Everything else waits 5 trips before it can come back.

**Discovery.** Spotify's recommendations endpoint is closed to new apps, so discovery comes from Spotify search: unheard songs by your top artists. Only if that comes up short does Claude suggest songs, and Spotify search must confirm each one exists.

## No signal

National parks and mountain roads often have no signal, which is exactly where the best moments happen.

- **Pick ahead.** While there's signal (at trip start and every 15 minutes), the app picks songs for the moments likely to come next and saves them on the phone for 3 hours.
- **Fallback rule.** With nothing saved, it plays your tagged songs for that moment, anthems first.

## Privacy

- Raw location stays on the phone.
- The backend only sees a summary: moment type, local time, weather, public place name and kind, trip length, and how long the last stop was.
- Place names are never sent within 3 km of home or for the "nearing home" moment.
- Weather lookups send a location rounded to about 1 km.

## Evaluation

- **Hit rate:** the share of moment songs played through, out of those played through or skipped.
- **Ratings:** 1–5★ per moment in the trip recap.
- **Baseline:** 20% of moments (adjustable) get a shuffle pick from your top tracks instead. The recap hides which picks were baseline until you rate them.
- Stats are shown per arm. Simulated drives are excluded, and they don't train the picker.

## Architecture

```
iPhone (SwiftUI, iOS 17)                       Cloudflare Worker (TypeScript)
├─ Sensors: location, motion, car Bluetooth     ├─ POST /v1/cards     → Claude: song cards
├─ Weather (Open-Meteo), place names (Apple)    ├─ POST /v1/pick      → Claude: ranked top 3 + reasons
├─ MomentCore (Swift package, pure logic)       ├─ POST /v1/discover  → Claude: discovery fallback
│   ├─ TripDetector, MomentDetector, Sun        └─ GET  /spotify/callback → forwards OAuth to moments://
│   ├─ Shortlister, FeedbackStore, Rotation
│   ├─ MomentConductor (trip orchestration)     Spotify Web API (PKCE login, library, queue/skip)
│   └─ DriveTrace (simulator), Stats
├─ Live Activity (lock screen)
└─ Trip recap, ratings, stats
```

The Claude API key lives only in the Worker. The app authenticates to the Worker with a shared token.

## Later

- Live route and ETA (Google Routes API, or an in-app destination), so "nearing home" can trigger on ETA rather than distance.
- More moments: open highway, scenic coast, night driving, first drive of a holiday.
- Camera scenery (dashcam + vision model).
- A smarter shortlist that learns per-user weights from hits and misses.
