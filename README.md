# Moments

**People live for a few moments. Moments plays the song that fits them.**

Moments is an iPhone app for drivers. It watches your drive for moments (a sunset, rain starting, leaving a place you spent all day, the last miles home) and slips the right song from your Spotify library into that moment. Think 日落大道 on the drive home from a national park as the sun goes down.

<!-- Add a screenshot or GIF of the trip recap and the lock-screen Live Activity here. -->

## How it works

1. **Notice the moment.** On-device logic combines GPS, sun position, weather and place names. It detects four moments: sunset, rain, leaving a long stop, and nearing home. There's a 15-minute cooldown, and each moment fires once per trip.
2. **Shortlist.** Every song in your library has a *song card*, a short description of how it feels written once by Claude. The phone ranks cards against the moment using on-device sentence embeddings, songs you tagged for that moment, your anthems, and what you skipped before.
3. **Pick.** Claude chooses a ranked top 3 from the shortlist and writes one line on why each fits right now. The first one plays in Spotify. Short moments cut in, long ones wait for the current song.
4. **Learn.** A skip within 20 seconds is a miss and the backup plays. Playing a song through is a hit. After the drive, the trip recap lets you rate each moment.

It also handles having no signal (it picks ahead and saves the picks, then falls back to your tags), keeps your location private (only a short summary leaves the phone), and has a built-in A/B baseline so you can check that picking actually beats shuffle.

See [docs/DESIGN.md](docs/DESIGN.md) for every decision and the reasoning behind it.

```
ios/
  MomentCore/        Swift package: all decision logic, no UI, fully tested
  Moments/           SwiftUI app: sensors, Spotify, backend client, screens
  MomentsWidget/     Lock-screen Live Activity
backend/             Cloudflare Worker calling Claude (song cards, picks, discovery)
scripts/check-core.sh  Runs the MomentCore scenarios without Xcode
```

## Requirements

- An iPhone on iOS 17+, a Mac with **Xcode 15+**, and an Apple ID (a free one works; free builds expire after 7 days)
- **Spotify Premium** (playback control needs it)
- An **Anthropic API key**
- A free **Cloudflare** account for the backend

## Setup

### 1. Backend

```bash
cd backend
npm install
npx wrangler login
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put APP_TOKEN        # any long random string; the app sends it
npm run deploy                           # prints https://moments-backend.<you>.workers.dev
```

The model defaults to `claude-opus-5-5` and can be changed with `MODEL` in `wrangler.toml`. Song cards are written once per song, in batches of 40.

For local development, copy `.dev.vars.example` to `.dev.vars` and run `npm run dev`.

### 2. Spotify app

1. Create an app at [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) and choose **Web API**.
2. Add the redirect URI `https://moments-backend.<you>.workers.dev/spotify/callback`. Spotify requires an HTTPS redirect, and the Worker forwards it to the app.
3. In **User Management**, add the Spotify account you'll use. Development-mode apps only work for listed users.
4. Copy the **Client ID**. No client secret is needed, because the app uses PKCE.

### 3. iPhone app

```bash
cd ios
cp Secrets.example.xcconfig Secrets.xcconfig   # fill in Client ID, backend URL, APP_TOKEN, your team
brew install xcodegen && xcodegen              # only needed if you add or remove files
open Moments.xcodeproj
```

In Xcode, select the **Moments** scheme and your iPhone, then press Run. On first launch:

1. Connect Spotify. This imports your top, recent and saved songs and writes song cards.
2. Allow location, choosing **Always** so drives are noticed in the background.
3. Set home while you're at home.
4. Tag songs for each moment and star your anthems.

Then start playing something in Spotify (the app needs an active player) and drive.

## Try it without driving

The **Drive** tab has *Simulate the Yosemite sunset drive*. It replays a 4-hour drive from Yosemite Valley to Berkeley in about 4 minutes:

- leaving Yosemite after 10 hours
- the sunset
- a rain shower in the Central Valley
- the last miles home

It uses the real backend and, optionally, real Spotify playback. Simulated drives show up in Trips, but they don't train your picks or count in the stats.

## Tests

```bash
cd backend && npm test             # backend routes and validation, model stubbed
./scripts/check-core.sh            # MomentCore scenarios (works with only the Command Line Tools)
cd ios/MomentCore && swift test    # the same scenarios through XCTest (needs Xcode)
```

The core scenarios include a full replay of the Yosemite drive. They check that exactly four moments fire, in order, at least 15 minutes apart, that the tagged songs are picked, and that place names near home are never sent.

## Limits

- Spotify development mode allows only a few users, needs Premium, and caps search at 10 results. That's fine for personal use, but a public release would need Spotify's extended quota.
- There's no fade on cut-in, because Spotify usually blocks remote volume control on iPhones.
- iOS can stop background location if the battery is low. Opening the app brings it back.
- Song cards come from Claude's own knowledge of a song. Obscure tracks get a low-confidence card and are only used if you tag them.

## License

MIT
