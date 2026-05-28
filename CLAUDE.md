# YGORip

> Yu-Gi-Oh! TCG pack opening simulator — rip packs, chase Ultra/Secret/Starlight Rares, build your collection.

## Quick Reference
- **Language:** Swift 6.0, SwiftUI
- **Min deployment:** iOS 18.0
- **Pattern:** MV (Model-View) — no per-view ViewModels
- **Dependencies:** RevenueCat (subscriptions/IAP)
- **Bundle ID:** com.lavailabs.ygorip
- **Sister projects:** `../poke-rip` and `../mtg-rip` — same harness, different TCG flavor.
  The animation system, image cache, StoreKit, AppState shape, foil shader, and design
  system were ported wholesale from mtg-rip (which was itself ported from poke-rip).
  Keep them in sync where it makes sense.

## Build
```bash
xcodegen generate && xcodebuild -scheme YGORip -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

### When to regenerate the Xcode project
- **Code-only edits** (Swift, JSON, asset content): no regen needed. Xcode picks up source changes automatically.
- **Structural changes** (new/renamed files, project.yml settings, dependencies, entitlements, fonts): run `xcodegen generate` — never `rm -rf YGORip.xcodeproj` first. xcodegen overwrites in place; Xcode prompts once with "Use Version on Disk" and reloads.
- **Never run xcodegen in a loop** — every regen interrupts an open Xcode session with the modal popup.

## Key architectural decisions (read first)

These were deliberate choices for the YGO port. Don't undo them without revisiting the reasoning.

### 1. Images: on-device cache only, no CDN mirror
YGOPRODeck **forbids hotlinking** card images and will IP-block violators. The cheap-but-acceptable
read of their TOS: an iOS app fetching once via `ImageCacheService` and persisting to disk
(same code path as mtg-rip/poke-rip) is *downloading*, not hotlinking. Each card image hits
their CDN exactly once per device, then lives in `FileManager` caches dir until purged.

- **Do not** strip the local image cache to "save space."
- **Do not** introduce a feature that re-fetches images on a schedule.
- If YGOPRODeck ever complains, the escape hatch is mirroring to our own bucket (S3 +
  CloudFront). Not worth the setup cost until forced.

### 2. Per-set identity: boss-card cropped art, not set logos
Sibling apps lean on per-set logos for visual identity — poke-rip uses
pokemontcg.io's `set.images.logo`, mtg-rip uses Keyrune glyphs. Neither
has a YGO equivalent: YGOPRODeck doesn't serve set logos at all, and the
Yugipedia "logos" we tried are either full-pack-art photographs (which
looked like "a pack inside a pack" on the Home grid) or only available
for the ~60 newest sets.

Instead, every set in `sets.json` has a `featuredCardID` — the numeric
YGOPRODeck ID of the set's "boss / cover" card — picked at pipeline time
by an era-aware heuristic in `data-pipeline/build_bundle.py`:

- **Modern era** (Arc-V onward, 2014+): highest rarity tier in the set,
  tie-broken by lowest set_number. The cover is reliably the Quarter
  Century / Starlight / Collector's chase card.
- **Pre-modern** (LOB through Zexal): Ultra Rare at the lowest
  set_number. Old sets didn't have higher tiers; cover was always the
  Ultra Rare at `<CODE>-001` (e.g. LOB's Blue-Eyes White Dragon at
  LOB-001, MRD's Gate Guardian, SDK's Blue-Eyes). Falls back to the
  highest-tier card if no Ultras exist (sparse promo sets).

The `SetGridCard` renders that card's cropped art
(`https://images.ygoprodeck.com/images/cards_cropped/{id}.jpg`) as the
tile background, with a bottom darken-gradient + name/counter overlay.
The cropped art is YGOPRODeck's pre-rendered artwork-only crop (no card
frame / name / stats / text). Each cropped image is ~30–60 KB,
lazy-fetched via `ImageCacheService` (memory + disk cache) on tile
appear — no bundle bloat, no upfront download.

A single bundled `ygo_logo.png` (the Yu-Gi-Oh! wordmark) ships in the
bundle for the Foil Pack visual + as a fallback for the rare set without
a `featuredCardID`.

### 3. Pull rates: hand-authored per era
No community dataset exists for YGO pack composition (no MTGJSON `booster`-field equivalent;
Konami doesn't publish modern odds). `PullRateEngine` carries a hand-authored `PackEra` enum
mapped from each set's `tcg_date`. Era buckets (rough):
- **LOB era** (2002–2004): 9 cards, 8 commons + 1 of {Rare/SR/UR/ScR} at roughly 1:5 SR, 1:12 UR, 1:24 ScR
- **Classic** (2004–2016): 9 cards, UR slot pushed to 1:24
- **Modern** (2016–present): 9 cards, ~1:6 UR/SR slot, ~2 ScR + 4 UR per 24-pack box, Starlight ~1:24 boxes
- **Premium** (Legendary Collection, 25th Anniversary, Rarity Collection, etc.): bespoke per-product configs

Source community wisdom: Yugipedia "Ultra Rare" article, Cardmarket "Box Math" series,
YGOPRODeck's "Set Theory" articles.

**Audit before shipping a bundle update:** run `python3 scripts/audit-rarity-coverage.py`, must exit 0. Three passes:
- Engine → card-data: a rarity in a `PackConfig` weight table with no matching cards in any bundled set for that era. Silent drift — `PackPrefetcher`'s tier-aware fallback hides the bug.
- Card-data → engine: a rarity in card data that no weight table can roll. Usually means new rarities (Ghost Rare reappearing, new Secret variants) need to be added to the era configs, or that garbage strings ("New", "European debut") slipped through `build_bundle.py` and need data-pipeline cleanup.
- Hot pack reachability: for each era, the chase weights filtered to rank ≥ 3 must be non-empty and reachable in card data.

The audit mirrors `PullRateEngine.swift`'s hardcoded era configs in Python — if you change those configs, update `ERA_WEIGHT_TABLES` in the audit too. Drift is partially self-detected via the cross-direction warnings.

### 4. No keyrune.ttf / no set-symbol font
mtg-rip ships keyrune.ttf for corner glyphs. YGORip does **not** — YGO has no equivalent
font and visually leans on pack logos instead. The `UIAppFonts` entry was removed from
Info.plist and the `Resources/Fonts/` directory was deleted.

### 5. Palette: keep the sibling-app foil/holo look
YGORip uses the same core palette as poke-rip and mtg-rip — deep navy background
(`#0F1923`), card-surface elevated dark (`#1A2634`), silver/holo `accent`
(`#C0C8D4`), gold `#FFD700` for chase/premium moments, plus the iridescent
holo gradient. The three apps are intentionally a coherent family rather than
three separately-branded flavors. **Don't** retheme to red-on-black to match
the YGO logo — the foil aesthetic is the franchise here.

YGO-specific palette additions live in `Theme.rarityColor(for:)` — the
full ladder gets distinct colors (silver Rare, cyan Super, gold Ultra, copper
Ultimate, hot-pink Starlight, emerald Collector's, violet Prismatic/Secret,
ghost-lavender Ghost, deep-gold Quarter Century). Pack wrappers get
era-specific identities via `PackPalette` (LOB gold-on-brown, GX red+yellow,
5D's electric blue, Zexal violet+gold, Arc-V red+green, VRAINS cyan+magenta,
Sevens pink+gold, Modern purple+gold), with separate non-era palettes for
Premium/Tin/Structure/Speed Duel/Battle Pack/World Premiere.

### 6. Bundle rebuild: YGOPRODeck `set_code` collisions
**Important when re-running `data-pipeline/build_bundle.py` after new YGO sets release.**

YGOPRODeck's `cardsets.php` lists **multiple records that share the same
`set_code`** — 137 collisions in the May 2026 snapshot. Most common pattern:
the main booster (e.g. ETCO "Eternity Code" with 101 cards) + one or more
promo/special-edition variants reusing its code (e.g. "Eternity Code
Premiere! promotional card" with 1 card). Set codes like `JUMP` (Shonen Jump
promos), `LART` (Lost Art Promotions), `HL02`–`HL07` (Hobby League
participation cards) have 6–70 variant entries each.

`SetModel.apiID = set_code` so SwiftData can only hold one record per code.
The pipeline collapses duplicates by **keeping the entry with the most
`num_of_cards`** (almost always the main booster, never a promo). The dropped
variants are reported at end of build under "Collab/crossover sets blocked"
plus a separate dedup counter.

When new sets are added by Konami:
- If the new booster reuses an existing code (rare), the pipeline will pick
  whichever has more `num_of_cards`. This may need manual override.
- If YGOPRODeck adds new promo variants with old codes, the dedup picks the
  main set correctly — no action needed.
- Always sanity-check the "Sets with no printings" report. Sets in the bundle
  with 0 printings either have YGOPRODeck data gaps (older starter decks) or
  are corner cases we should drop.

### 7. SwiftData bundle-bump cleanup
`SetSyncService` is **not** insert-only — both sync paths garbage-collect
stale rows before upserting. The cleanup is lazy (per-touch) rather than
launch-time:
- `syncAllSets` (HomeView launch) drops `SetModel` rows whose `apiID` is
  no longer in `sets.json`, with manual cascade to `CardModel` (`setID`
  match) and `PullRecord` (`setID` match). The cascade is manual because
  `PullRecord` references via soft string IDs, not a SwiftData
  relationship.
- `syncCards(forSetID:)` (SetDetail open) drops `CardModel` rows for
  that set whose `apiID` is no longer in `set-cards-<code>.json`, with
  cascade to `PullRecord` (`cardAPIID` match).

This covers two kinds of drift: a whole set disappearing (collab found
late, code-collision dedup picks a different winner) and per-printing
churn (dedup logic changes, rarity-variant collapse, etc.). No version
field needed — set-membership is the comparison.

Pre-1.0, this is mostly defensive; once users are installed and
collecting, it keeps "Reset Collection" from being the only escape
hatch.

### 8. Chase-variant tracking (deferred)
Modern YGO sets print the same card at multiple rarities under the same
English numbering — Diabellstar at AGOV-EN006 ships as both Secret Rare
and Quarter Century Secret Rare; same set_code, same image. The
pipeline currently dedupes to the lowest rarity (base printing) so the
pull engine's normal slots can find every card. Chase variants (QCSR /
Starlight / Collector's / Prismatic / Ghost) are intentionally absent
from the pool until two things land together:
1. **Foil tier extensions**: `FoilTreatment` is 5 tiers today; YGO has
   9–10 visually distinct real-world rarities. Distinguishing QCSR
   from Secret needs new shader features (25th-anniversary stamp
   overlay, starlight particle layer) — not just new uniform values.
2. **Per-variant slot odds**: `PullRateEngine`'s era configs would
   need explicit chase-variant slots with low odds (~1:24 box) and
   the engine would need to pick which rarity of a given card to
   pull.

The data model is ready to extend: track `pulledRarities: Set<String>`
on each `(CardModel, set)` tuple à la MTG's old `isFoil` flag, so the
checklist stays one-row-per-card and the collector aspect surfaces in
card inspect or via rarity pips. Don't ship variants without the foil
tiers — pulling a "QCSR" that renders identically to a Secret undercuts
the chase moment more than collapsing them does.

## Architecture

### MV Pattern
Views observe models directly via `@Query` and `@Observable`. No ViewModels.

- **`AppState`** — app-level coordination: pack regen counter, premium status, first-launch state
- **Services** — domain logic as actors/structs:
  - `YGOPRODeckService` — YGOPRODeck API client (live price refresh, on-demand card lookup)
    *(Currently still named `ScryfallService` — pending rewrite, see follow-up tasks)*
  - `SetSyncService` — loads bundled JSON into SwiftData
  - `PullRateEngine` / `PackConfig` — booster simulation, per-era hand-authored configs
  - `ImageCacheService` — YGOPRODeck card images (on-device cache only)
  - `StoreKitService` — RevenueCat-backed IAP, 3 tip tiers
- **SwiftData `@Model`** — single source of truth for pulled cards, set metadata, pull history
- One `@Query` observer per data source — parent owns query, passes results to children

### Core Loop
```
User taps "Rip" → PullRateEngine.generatePack(config:) returns rarity slot results
→ View picks actual cards from set's pool matching each slot's rarity
→ Pack opening animation sequence
→ Cards saved to SwiftData → Collection updated → Summary shown
```

## Project Structure
```
YGORip/
  App/
    YGORipApp.swift           Entry point, ModelContainer setup
    AppState.swift            App-level state (pack regen, premium status)
    ContentView.swift         Root TabView
    Theme.swift               Colors, spacing, radii
  Models/
    CardModel.swift           SwiftData @Model — pulled card instance (YGOPRODeck-backed)
    SetModel.swift            SwiftData @Model — cached set metadata
    PullRecord.swift          SwiftData @Model — individual pull with timestamp
  Services/
    ScryfallService.swift     (LEGACY NAME) — to be replaced with YGOPRODeckService
    SetSyncService.swift      Bundled JSON → SwiftData hydration
    PullRateEngine.swift      Pack simulation, hand-authored per-era PackConfig
    ImageCacheService.swift   URLCache + FileManager image pipeline
    StoreKitService.swift     RevenueCat-backed IAP
    GyroService.swift         CoreMotion → SwiftUI for gyro-reactive foil
    NetworkMonitor.swift      Connectivity status
  Views/
    Home/                     Set browser, era shelves (LOB era, Classic, Modern, Premium)
    SetDetail/                Set info, collection progress, "Rip a Pack" CTA
    PackOpening/              4-phase animation sequence (THE core experience)
    CardInspect/              Hi-res card view, pinch-to-zoom, attribute/type/level/ATK/DEF
    Collection/               Grid, binder, list views with sort/filter
    Stats/                    Profile, rarity breakdown, luckiest pulls
    Settings/                 Tip tiers, debug, disclaimer
    Components/               Shared: RarityBadge, NewBadge, CachedCardImage, etc.
  Animation/
    ParticleSystem.swift      Lightweight particle emitter for rare reveals
  Foil/
    FoilTreatment.swift       5 treatment tiers + forYGORarity(...) mapper
    FoilMotionProvider.swift  Tilt source: auto sweep / drag / CoreMotion gyro
    FoilEffect.swift          foilShader + foilRotation modifiers (+ combined foilEffect)
    FoilPreview.swift         DEBUG-only sandbox at Settings → Foil Sandbox
  Shaders/
    FoilShaders.metal         cardShimmer stitchable + helpers
  Resources/
    Assets.xcassets
    Bundled/                  ALL pack metadata + set logos ship here
    YGORip.storekit           StoreKit configuration
```

## Data Layer

### Bundled metadata (offline-first)
All set/card/booster metadata ships in `Resources/Bundled/`. The app needs no network
to browse sets, open packs, or display card info — only card images stream live from YGOPRODeck.

Bundle layout (target):
```
Bundled/
  sets.json                 — array of set records (set code, name, tcg_date, total cards, era, logo asset name)
  cards/<code>.json         — per-set card metadata with per-printing rarity
  boosters/<code>.json      — pack slot config (era → PackConfig)
  set-logos/<code>.png      — set logo image, ~200×80, mirrored from YGOJSON / Yugipedia
```

### Building the bundle
```bash
cd data-pipeline && python3 build_bundle.py
```
Pulls YGOJSON aggregated dump + YGOPRODeck card data, mirrors set logos from
YGOJSON `locales[].image` (fallback: Yugipedia `<SETCODE>-LogoEN.png`), assigns
each set an era from `tcg_date`, emits trimmed JSON + logo PNGs into
`YGORip/Resources/Bundled/`. Idempotent — re-runs use cached raw files.

*(Pipeline is currently a placeholder ported from mtg-rip — see follow-up tasks for the rewrite.)*

### SwiftData mutations
- Always wrap in `withAnimation` for coordinated @Query re-evaluation
- Never mutate + navigate simultaneously — dismiss first, delay mutation
- Explicit `modelContext.save()` after every pack open

## API Layer (YGOPRODeck)

Base URL: `https://db.ygoprodeck.com/api/v7`. Free, no key required.

We hit YGOPRODeck for:
- **Bulk card data** — `cardinfo.php` returns all ~13k cards in one response (treat as a bulk dump, not a polling endpoint).
- **Set metadata** — `cardsets.php` for the list of all official sets.
- **Live price refresh** on inspect view — card response includes `card_prices[]` (TCGPlayer, Cardmarket, CoolStuffInc, eBay, Amazon). No separate TCGPlayer call needed.
- **Image URLs** — constructed deterministically:
  - Full: `https://images.ygoprodeck.com/images/cards/{id}.jpg`
  - Small: `https://images.ygoprodeck.com/images/cards_small/{id}.jpg`
  - Cropped art: `https://images.ygoprodeck.com/images/cards_cropped/{id}.jpg`

### Rate limits & rules
- **20 req/sec**, 1-hour IP block on violation.
- Card data cache TTL is 2 days on their side. **Don't poll** — download once, store locally, refresh via `checkDBVer.php`.
- **No image hotlinking** — see "Key architectural decisions" #1 above.

## Pull Rate Engine

`PullRateEngine.generatePack(config:)` returns `[SlotResult]` (rarity strings + foil flag).
PackOpeningView then resolves each slot to a random card from the set's pool matching that rarity.

`PackConfig.config(forSeries:)` (legacy-named — takes a set code) loads the set's
era-mapped config from bundled JSON.

YGO rarity ladder (in roughly ascending desirability):
`Common → Rare → Super Rare → Ultra Rare → Secret Rare → Ultimate Rare → Ghost Rare → Starlight Rare → Quarter Century Secret Rare → Collector's Rare → Prismatic Secret Rare`

Per-printing rarity comes from YGOJSON / YGOPRODeck's `card_sets[].set_rarity`. The
same card ID can appear in multiple sets at different rarities — `CardModel` instances
are per-printing, not per-card-ID.

## Animation System

Four-phase pack opening — see poke-rip's CLAUDE.md for the full breakdown. Architecture
is identical; only the rarity-tier mapping differs (Starlight Rare and Quarter Century
Secret Rare get the screen-darken + particle treatment that Pokemon's Hyper Rare did).

## Foil System

A single Metal shader (`cardShimmer`) renders all card foil — moving sheen + iridescence + tilt-twinkling sparkles — driven by a tilt vector from auto idle sweep, finger drag, or device gyro.

### YGO foil reality
YGO printed cards have **physical foil** baked into the print (unlike MTG where Scryfall returns the non-foil art). YGOPRODeck images mostly show the non-foil version; we use the shader to *generate* the foil look based on rarity. Rare and above get foil treatment in the app even though the source image is flat.

### Architecture
- **`Shaders/FoilShaders.metal`** — `cardShimmer` stitchable with three uniforms (`sheenStrength`, `rainbowSaturation`, `sparkleDensity`). Layers sheen + iridescence + jittered tilt-twinkle sparkles via `colorDodge`.
- **`Foil/FoilTreatment.swift`** — five tiers (`.none / .subtle / .holo / .illustration / .secret`). `FoilTreatment.forYGORarity(...)` maps YGO rarity strings to a tier with the game-feel rules below.
- **`Foil/FoilEffect.swift`** — split into `foilShader` (colorEffect pass) and `foilRotation` (3D tilt + drop shadow). Insert overlays (NEW badge, ShimmerSweep) between the two when they should rotate with the card without being foil-tinted.
- **`Foil/FoilMotionProvider.swift`** — `@Observable @MainActor` class exposing a single `tilt: CGSize` in `[-1, 1]`. Sources: `.auto` (idle figure-8 sweep), `.drag` (manual via gesture), `.device` (CoreMotion via `GyroService.shared`, falls back to `.auto` in the simulator).
- **`Foil/FoilPreview.swift`** — DEBUG-only sandbox at `Settings → Debug → Foil Sandbox`.

### Rarity → foil tier mapping (game-feel emphasis, target)
| YGO rarity | Tier |
|---|---|
| Common | `.none` |
| Rare | `.subtle` (silver name letters in real life) |
| Super Rare | `.holo` |
| Ultra Rare | `.illustration` (gold name + holo art) |
| Secret Rare | `.secret` |
| Ultimate Rare | `.secret` (embossed in real life) |
| Ghost Rare / Starlight / Quarter Century / Prismatic | `.secret` + extra sparkle |
| Collector's Rare | `.secret` |

*(`FoilTreatment.forYGORarity` is currently still the MTG mapper — pending rewrite.)*

### Settings
`Settings → Card Motion` picker (None / Idle / Gyro) is a UI bridge over two underlying `AppState` booleans (`idleHoloShimmerEnabled`, `gyroEnabled`). iOS Reduce Motion overrides everything. Gyro is **not** premium-gated.

### Where applied
- **`CardInspectView`** — full effect with tap-and-hold drag-to-tilt.
- **`PackOpeningView`** — reveal phase, lower rotation magnitude (6° vs 12°). Treatment driven by per-pull rarity.
- **Not applied** to Collection grid, Stats, or pack summary thumbnails — running a shader on dozens of small cards isn't worth the perf cost.

## Monetization (RevenueCat + StoreKit 2)

### Free Tier
- 1 pack regenerates every 2 hours
- All sets accessible
- Full collection tracking
- Standard pack opening animation

### Tip Tiers (any unlocks "Unlimited Rips")
- `com.lavailabs.ygorip.tip.support` — Supporter ($1.99)
- `com.lavailabs.ygorip.tip.super` — Super Supporter ($4.99)
- `com.lavailabs.ygorip.tip.legendary` — Legendary Supporter ($9.99)

All three unlock the same thing: unlimited rips. Foil effects and gyro are **not**
premium-gated — every user gets them.

### Gating Pattern
- `AppState.isUnlimitedRips: Bool` — single check
- 2hr regen via timestamp comparison
- Gate the "Rip a Pack" button, not navigation — users can always browse

### RevenueCat API key
`StoreKitService.apiKey` is still the **mtg-rip** key (`appl_EYzymVSQEQyjxSkvUAucPprPvaj`).
Must be regenerated for the YGORip RevenueCat project before TestFlight/App Store
submission.

## Set Organization (UI shelves)

The Home screen groups sets by what a Yu-Gi-Oh fan would recognize, not by data type.
`shelf` field on `SetModel` drives this.

Target shelves (subject to refinement):
- `core_lob` — LOB-era originals (LOB, MRD, MRL, PSV — the classics)
- `gx_era` — Yu-Gi-Oh GX era sets (CRV through LODT)
- `5ds_era` — 5D's era (CRMS through STBL)
- `zexal_era` — Zexal era (GENF through PRIO)
- `arcv_era` — Arc-V era (SECE through MP17)
- `vrains_era` — VRAINS era (COTD through SAST)
- `current` — current/modern sets (post-2018)
- `premium` — Legendary Collection, 25th Anniversary, Rarity Collection, etc.
- `structure_decks` — Structure Deck reprints (separate vibe)
- `world_premiere` — TCG-exclusive sets / World Championship promos

## IP Disclaimer
Not produced, endorsed, supported by, or affiliated with Konami Digital Entertainment,
Konami Group Corporation, Studio Dice, Shueisha, TV Tokyo, or any of their subsidiaries.
Yu-Gi-Oh! and all related card names, artwork, and trademarks are property of their
respective owners. Card images and metadata sourced from YGOPRODeck and YGOJSON —
community APIs.
