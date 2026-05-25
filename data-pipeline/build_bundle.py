"""Build the bundled YGO data set.

Sources:
  - YGOPRODeck cardinfo.php   — all cards in one dump (~13k cards) with per-printing rarity
  - YGOPRODeck cardsets.php   — list of all official TCG sets
  - YGOJSON aggregate dump    — for set logo URLs (locales[].image) where present
  - Yugipedia MediaWiki API   — fallback set logos at <SETCODE>-LogoEN.png

Output: YGORip/Resources/Bundled/
  sets.json              — array of set records (code, name, tcg_date, era, shelf, logoAsset, logoStyle)
  cards.json             — global card index keyed by card ID (deduped card definitions)
  set-cards-<code>.json  — per-set printing records: {id, rarity, code, price}
  set-logos/<code>.png   — mirrored logo PNGs (one-time scrape)

Pack composition is era-driven and hand-authored in Swift (PullRateEngine). Every set
opens as a foil pack with its era's rarity distribution — no product-type-specific
configs (Structure / Tin / Premium / etc. all use their tcg_date era's odds).

Usage:
  python3 build_bundle.py                # full build (slow first run, ~5-15 min for logos)
  python3 build_bundle.py --no-logos     # skip the slow Yugipedia logo fetch
  python3 build_bundle.py --sets-only    # just rebuild sets.json (fast)
"""

import argparse
import json
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).parent
RAW = ROOT / "raw"
RAW.mkdir(exist_ok=True)
OUT = ROOT.parent / "YGORip" / "Resources" / "Bundled"
OUT.mkdir(parents=True, exist_ok=True)
LOGOS_OUT = OUT / "set-logos"
LOGOS_OUT.mkdir(exist_ok=True)

YGOPRODECK_BASE = "https://db.ygoprodeck.com/api/v7"
YGOJSON_AGGREGATE = "https://ygojson.org/v1/aggregate/cards.json"  # may need to mirror, see below
YUGIPEDIA_API = "https://yugipedia.com/api.php"

USER_AGENT = "ygo-rip-build/1.0 (https://github.com/lavailabs/ygo-rip; contact: ygorip@lavailabs.com)"


# -----------------------------------------------------------------------------
# Era bucketing
# -----------------------------------------------------------------------------
# Map tcg_date to a series-era key. Roughly aligned with the Yu-Gi-Oh anime
# series that dominated each window. Boundaries are deliberately fuzzy — they
# only affect UI shelving and which hand-authored PackConfig the set uses.

ERA_RANGES = [
    # (era_key, tcg_date_min, tcg_date_max_exclusive)
    ("lob",    "2002-01-01", "2004-10-20"),  # Original DM era — LOB through DCR
    ("gx",     "2004-10-20", "2008-09-01"),  # GX era — RDS through LODT
    ("5ds",    "2008-09-01", "2011-08-15"),  # 5D's era — CRMS through STBL
    ("zexal",  "2011-08-15", "2014-05-15"),  # Zexal era — GENF through PRIO
    ("arcv",   "2014-05-15", "2017-11-09"),  # Arc-V era — DUEA through MP17
    ("vrains", "2017-11-09", "2020-04-23"),  # VRAINS era — COTD through ETCO
    ("sevens", "2020-04-23", "2023-01-19"),  # Sevens era — ROTD through PHHY
    ("gorush", "2023-01-19", "9999-12-31"),  # Go Rush / current
]


def era_for_date(tcg_date):
    """Return era key for a tcg_date string ('YYYY-MM-DD') or None."""
    if not tcg_date:
        return None
    for key, start, end in ERA_RANGES:
        if start <= tcg_date < end:
            return key
    return None


# -----------------------------------------------------------------------------
# Crossover / brand-collaboration blocklist (IP safety)
# -----------------------------------------------------------------------------
# YGOPRODeck lists Konami's brand-partnership promo cards (Adidas, Nike, etc.)
# alongside real sets. We don't ship these — the partner brand's IP is not
# covered by our YGO disclaimer, and the cards are typically one-off promos
# anyway, not pack-openable products.
#
# Match by name keyword (case-insensitive). Add to this list as new
# collaborations appear.

# `\bcollaboration\b` catches all the obvious ones (Adidas/Nike/EFootball
# collaboration cards). Brand names are belt-and-suspenders for future promos
# that drop the word "collaboration" from the set name. Do NOT add
# `\bcrossover\b` — that's a legitimate Konami booster term ("Crossover
# Breakers" is an in-universe archetype set, not a brand crossover).
COLLAB_BLOCKLIST_PATTERNS = [
    r"\bcollaboration\b",
    r"\badidas\b",
    r"\bnike\b",
    r"\befootball\b",
]


def is_collab_set(name):
    n = (name or "").lower()
    return any(re.search(p, n) for p in COLLAB_BLOCKLIST_PATTERNS)


# -----------------------------------------------------------------------------
# Set-type / shelf classification (name-based)
# -----------------------------------------------------------------------------
# YGOPRODeck's cardsets.php doesn't expose set type — we infer from the name.

PREMIUM_PATTERNS = [
    r"\blegendary collection\b",
    r"\brarity collection\b",
    r"\b25th anniversary\b",
    r"\bgold series\b",
    r"\bgold edition\b",
    r"\bpremium pack\b",
    r"\bhidden arsenal\b",
    r"\bmaximum gold\b",
    r"\bdragons of legend\b",
    r"\bduelist pack\b",
    r"\bchampion pack\b",
]

STRUCTURE_PATTERNS = [
    r"\bstructure deck\b",
    r"\bstarter deck\b",
]

TIN_PATTERNS = [
    r"\bmega.?tin\b",
    r"\bgold sarcophagus tin\b",
    r"\bcollector'?s tin\b",
    r"\btin of the pharaoh'?s gods\b",
    r"\btin of lost memories\b",
    r"\btin of ancient battles\b",
]

SPEED_DUEL_PATTERNS = [
    r"\bspeed duel\b",
]

BATTLE_PACK_PATTERNS = [
    r"\bbattle pack\b",
]

WORLD_PREMIERE_PATTERNS = [
    r"\bworld championship\b",
    r"\btournament pack\b",
    r"\bturbo pack\b",
    r"\bastral pack\b",
    r"\bonslaught of the fire kings\b.*\bstructure\b",  # safety
]


def classify_shelf(name):
    """Return the UI shelf key for a set name (or None if it's a main-booster
    set — those get shelved by era).

    Drives Home-screen grouping only; pack opening is era-driven, not shelf-
    driven. Every set opens as a foil pack with era-appropriate odds.
    """
    n = name.lower()
    if any(re.search(p, n) for p in STRUCTURE_PATTERNS):       return "structure"
    if any(re.search(p, n) for p in TIN_PATTERNS):             return "tin"
    if any(re.search(p, n) for p in SPEED_DUEL_PATTERNS):      return "speed_duel"
    if any(re.search(p, n) for p in BATTLE_PACK_PATTERNS):     return "battle_pack"
    if any(re.search(p, n) for p in WORLD_PREMIERE_PATTERNS):  return "world_premiere"
    if any(re.search(p, n) for p in PREMIUM_PATTERNS):         return "premium"
    return None


def shelf_for(name, tcg_date):
    """Determine shelf, falling back to era bucketing for main boosters."""
    shelf = classify_shelf(name)
    if shelf:
        return shelf
    era = era_for_date(tcg_date)
    if era:
        return f"era_{era}"
    return "other"


# -----------------------------------------------------------------------------
# Card trimming
# -----------------------------------------------------------------------------

# Fields we keep from YGOPRODeck card records. The full response carries a lot
# we don't need at runtime (banlist info, archetype linkage, etc.); we trim
# aggressively to keep the bundle small.
def trim_card(card):
    """Strip a YGOPRODeck card to runtime fields. Returns None on bad records."""
    cid = card.get("id")
    if cid is None:
        return None
    out = {
        "id": cid,
        "name": card.get("name", ""),
        "type": card.get("type", ""),           # 'Effect Monster', 'Spell Card', etc.
        "frameType": card.get("frameType", ""), # 'normal', 'effect', 'fusion', 'spell', 'trap', ...
        "desc": card.get("desc", ""),
    }
    # Monster-only fields
    if "atk" in card:    out["atk"] = card["atk"]
    if "def" in card:    out["def"] = card["def"]
    if "level" in card:  out["level"] = card["level"]
    if "race" in card:   out["race"] = card["race"]
    if "attribute" in card: out["attribute"] = card["attribute"]
    if "archetype" in card: out["archetype"] = card["archetype"]
    if "scale" in card:  out["scale"] = card["scale"]  # Pendulum scale
    if "linkval" in card: out["linkval"] = card["linkval"]
    if "linkmarkers" in card: out["linkmarkers"] = card["linkmarkers"]
    return out


# Regional code preference for deduping printings within a single set.
# The same card-in-the-same-set is often listed multiple times (original numbering,
# European numbering, modern EN reprint). We want one printing per (set, card),
# preferring the modern EN version that matches what an English-language player
# would actually see.
#
# Returns a sort key — LOWER is better.
def _printing_priority(set_code_full):
    """Score a printing code for dedup. Lower = preferred."""
    if not set_code_full or "-" not in set_code_full:
        return 9
    region = set_code_full.split("-", 1)[1]
    # Strip trailing digits to get just the region letters
    region_letters = re.match(r"([A-Z]+)", region)
    region_letters = region_letters.group(1) if region_letters else ""
    # Modern English: 'EN' is the gold standard
    if region_letters == "EN":
        return 0
    # Original-era numbering had no region letters (e.g. 'LOB-001')
    if region_letters == "":
        return 1
    # English variants (sometimes used for special products)
    if region_letters in ("E",):
        return 2
    # Any other regional code (G=German, F=French, I=Italian, P=Portuguese, S=Spanish, K=Korean, A=Asian-English, J=Japanese)
    return 5


def index_printings(cards):
    """Build: set_name → [{id, rarity, code, price}], deduped per (set, card_id).

    YGOPRODeck records each printing under `card_sets[]` with set_name,
    set_code (a per-printing identifier like 'LOB-EN001'), set_rarity, etc.
    Multiple regional printings of the same card in the same set (e.g.
    LOB-001 / LOB-E001 / LOB-EN001) collapse to one entry — we keep the
    EN version, falling back to original numbering, then other regions.
    """
    # First pass: collect all (set_name, card_id) → best printing
    best = {}  # (set_name, card_id) → (priority, printing dict)
    for card in cards:
        cid = card.get("id")
        if cid is None:
            continue
        prices = card.get("card_prices") or [{}]
        tcg_price = prices[0].get("tcgplayer_price") if prices else None
        for printing in card.get("card_sets", []):
            set_name = printing.get("set_name")
            set_code_full = printing.get("set_code", "")
            rarity = printing.get("set_rarity", "Common")
            if not set_name:
                continue
            priority = _printing_priority(set_code_full)
            key = (set_name, cid)
            entry = (priority, {
                "id": cid,
                "rarity": rarity,
                "code": set_code_full,
                "price": tcg_price,
            })
            existing = best.get(key)
            if existing is None or priority < existing[0]:
                best[key] = entry

    # Group by set_name
    per_set = {}
    for (set_name, _cid), (_prio, printing) in best.items():
        per_set.setdefault(set_name, []).append(printing)
    return per_set


# -----------------------------------------------------------------------------
# Fetching
# -----------------------------------------------------------------------------

def fetch(url, dest, force=False):
    if dest.exists() and not force:
        return dest
    print(f"  fetch {url}", file=sys.stderr)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=60) as resp, open(dest, "wb") as out:
        out.write(resp.read())
    return dest


def fetch_cards():
    return fetch(f"{YGOPRODECK_BASE}/cardinfo.php", RAW / "cardinfo.json")


def fetch_sets():
    return fetch(f"{YGOPRODECK_BASE}/cardsets.php", RAW / "cardsets.json")


# Filename patterns on Yugipedia, in preference order (best first).
#
# - `LogoEN.png` — clean text-only logo (preferred — embeds well in UI)
# - `BoosterEN.png` — full pack-art photograph (use as full-pack visual)
# - `DeckNA.png` etc. — Starter / Structure deck box art (full-pack visual)
# - Regional variants for sets without EN-tagged variants
#
# Each candidate also has a `style`: "logo" (clean overlay) vs "packArt"
# (full-pack replacement). The UI branches on this to render correctly.
LOGO_FILENAME_CANDIDATES = [
    # (filename, style)
    ("LogoEN",       "logo"),
    ("BoosterEN",    "packArt"),
    ("BoosterNA",    "packArt"),
    ("BoosterAE",    "packArt"),
    ("DeckNA",       "packArt"),
    ("DeckEN",       "packArt"),
    ("DeckEU",       "packArt"),
    ("DeckAU",       "packArt"),
    ("BoxEN",        "packArt"),
    ("PackEN",       "packArt"),
    ("BoxNA",        "packArt"),
    ("TinEN",        "packArt"),
    ("TinNA",        "packArt"),
]

# Cap on longest side, in pixels. Yugipedia serves source-resolution images
# (often 2000+ px wide, 10MB+ each); 512px is plenty for the largest in-app
# rendering surface (FoilPackView sealed pack) and shrinks the bundle ~50×.
LOGO_MAX_DIMENSION = 512


def _resize_image(path):
    """Downscale an image to LOGO_MAX_DIMENSION on its longest side.

    Uses macOS `sips` (no Python deps). Idempotent — sips is a no-op when the
    image is already within the size cap.
    """
    try:
        import subprocess
        subprocess.run(
            ["sips", "-Z", str(LOGO_MAX_DIMENSION), str(path)],
            check=True,
            capture_output=True,
            timeout=30,
        )
    except Exception as e:
        print(f"  resize failed for {path.name}: {e}", file=sys.stderr)


def fetch_set_logo(set_code):
    """Find and download the best matching set image from Yugipedia.

    Returns a tuple of (local_path, style) on success, where style is
    "logo" (clean text overlay) or "packArt" (full-pack replacement),
    or (None, None) on failure.

    Strategy:
      1. Enumerate all `<SETCODE>-*` files in one MediaWiki `allimages` query.
      2. Pick the highest-priority filename match (Logo > Booster > Deck > Box).
      3. Fetch the chosen image URL, downscale to ≤512px on the longest side.

    Two HTTP requests per set (enumerate + download), ~1 req/sec total.
    """
    dest = LOGOS_OUT / f"{set_code}.png"
    style_file = LOGOS_OUT / f"{set_code}.style"
    if dest.exists() and style_file.exists():
        return dest, style_file.read_text().strip()

    # 1. Enumerate
    params = {
        "action": "query",
        "list": "allimages",
        "aiprefix": f"{set_code}-",
        "ailimit": "200",
        "format": "json",
    }
    api_url = f"{YUGIPEDIA_API}?{urllib.parse.urlencode(params)}"
    try:
        req = urllib.request.Request(api_url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read())
        images = data.get("query", {}).get("allimages", [])
        if not images:
            return None, None

        # Build an index of {bare_name_without_ext: image_record}
        by_basename = {}
        for img in images:
            name = img.get("name", "")
            base = name.rsplit(".", 1)[0]
            if "-" not in base:
                continue
            rest = base.split("-", 1)[1]
            if any(rest == cand for cand, _style in LOGO_FILENAME_CANDIDATES):
                # If multiple extensions (.png + .jpg), prefer .png
                if rest in by_basename and not name.endswith(".png"):
                    continue
                by_basename[rest] = img

        if not by_basename:
            return None, None

        # 2. Pick highest-priority candidate
        chosen = None
        chosen_style = None
        for candidate, style in LOGO_FILENAME_CANDIDATES:
            if candidate in by_basename:
                chosen = by_basename[candidate]
                chosen_style = style
                break
        if not chosen:
            return None, None

        image_url = chosen.get("url")
        if not image_url:
            return None, None

        # 3. Fetch + resize
        time.sleep(0.5)
        req = urllib.request.Request(image_url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=30) as resp, open(dest, "wb") as out:
            out.write(resp.read())
        _resize_image(dest)
        style_file.write_text(chosen_style)
        return dest, chosen_style
    except Exception as e:
        print(f"  logo fetch failed for {set_code}: {e}", file=sys.stderr)
        return None, None


# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-logos", action="store_true", help="Skip set-logo scrape (fast iteration)")
    ap.add_argument("--sets-only", action="store_true", help="Only rebuild sets.json (assumes raw/ is populated)")
    ap.add_argument("--force-refresh", action="store_true", help="Re-download YGOPRODeck dumps even if cached")
    args = ap.parse_args()

    # 1. Fetch raw dumps
    sets_path = fetch_sets() if not args.force_refresh else fetch(f"{YGOPRODECK_BASE}/cardsets.php", RAW / "cardsets.json", force=True)
    cards_path = fetch_cards() if not args.force_refresh else fetch(f"{YGOPRODECK_BASE}/cardinfo.php", RAW / "cardinfo.json", force=True)

    raw_sets = json.loads(sets_path.read_text())
    raw_cards_blob = json.loads(cards_path.read_text())
    raw_cards = raw_cards_blob.get("data", [])

    print(f"Loaded {len(raw_sets)} sets, {len(raw_cards)} cards from YGOPRODeck", file=sys.stderr)

    # Wipe stale per-set printing files so dropped/collab/collision sets don't
    # leave orphaned data in the bundle. sets.json + cards.json are rewritten
    # in full each run, but set-cards-*.json files would otherwise accumulate.
    if not args.sets_only:
        for stale in OUT.glob("set-cards-*.json"):
            stale.unlink()

    # 2. Build global card index (deduped)
    cards_index = {}
    for raw in raw_cards:
        trimmed = trim_card(raw)
        if trimmed:
            cards_index[trimmed["id"]] = trimmed
    print(f"Indexed {len(cards_index)} unique cards", file=sys.stderr)

    # 3. Build per-set printing index (keyed by set NAME, since that's what card_sets[] uses)
    printings_by_name = index_printings(raw_cards)

    # YGOPRODeck reuses set_code across many records (e.g. SDY is both
    # "Starter Deck: Yugi" and a "Summoned Skull Sample promotional card"
    # entry; ETCO covers the main 101-card booster AND a 1-card "Premiere!"
    # promo). Since SetModel.apiID = set_code in SwiftData, we can only keep
    # one record per code. Strategy: keep the entry with the most cards —
    # virtually always the main booster, not a promo/special-edition variant.
    # We also use this canonical-name to look up printings, fixing the bug
    # where promo records overwrote main-set printing files.
    sets_by_code = {}
    code_collision_dropped = []
    for s in raw_sets:
        code = s.get("set_code", "")
        if not code:
            continue
        existing = sets_by_code.get(code)
        if existing is None or s.get("num_of_cards", 0) > existing.get("num_of_cards", 0):
            if existing is not None:
                code_collision_dropped.append((code, existing.get("set_name", ""), existing.get("num_of_cards", 0)))
            sets_by_code[code] = s
        else:
            code_collision_dropped.append((code, s.get("set_name", ""), s.get("num_of_cards", 0)))
    canonical_sets = list(sets_by_code.values())
    print(f"Dedup by set_code: {len(raw_sets)} → {len(canonical_sets)} canonical sets ({len(code_collision_dropped)} variants dropped)", file=sys.stderr)

    # 4. Build set records — join YGOPRODeck cardsets.php list with printings_by_name
    set_records = []
    sets_no_printings = []
    collab_skipped = []
    for s in canonical_sets:
        name = s.get("set_name", "")
        code = s.get("set_code", "")
        tcg_date = s.get("tcg_date", "") or ""
        num_cards = s.get("num_of_cards", 0)
        if not code:
            continue
        if is_collab_set(name):
            collab_skipped.append((code, name))
            continue
        printings = printings_by_name.get(name, [])
        if not printings:
            sets_no_printings.append((code, name))
            # Still emit the set record — it just won't have card pulls
        record = {
            "code": code,
            "name": name,
            "tcgDate": tcg_date,
            "totalCards": num_cards,
            "era": era_for_date(tcg_date),
            "shelf": shelf_for(name, tcg_date),
        }
        set_records.append(record)

        # Emit per-set printing file
        if not args.sets_only:
            (OUT / f"set-cards-{code}.json").write_text(
                json.dumps(printings, separators=(",", ":"))
            )

    # 5. Write global card index
    if not args.sets_only:
        cards_list = sorted(cards_index.values(), key=lambda c: c["id"])
        (OUT / "cards.json").write_text(json.dumps(cards_list, separators=(",", ":")))

    # Sort sets by release date for deterministic output
    set_records.sort(key=lambda r: (r["tcgDate"] or "9999-99-99", r["code"]))
    (OUT / "sets.json").write_text(json.dumps(set_records, separators=(",", ":"), ensure_ascii=False))

    # 6. Set-logo scrape (slow — many sets, polite rate limit)
    logos_fetched = 0
    logos_missing = []
    logo_style_counts = {"logo": 0, "packArt": 0}
    if not args.no_logos and not args.sets_only:
        print(f"\nFetching set logos from Yugipedia (slow — ~1 req/sec)...", file=sys.stderr)
        for record in set_records:
            path, style = fetch_set_logo(record["code"])
            if path:
                logos_fetched += 1
                record["logoStyle"] = style
                logo_style_counts[style] = logo_style_counts.get(style, 0) + 1
            else:
                logos_missing.append(record["code"])
            time.sleep(0.5)  # polite — ~2 req/sec including the previous sleep
            if (logos_fetched + len(logos_missing)) % 50 == 0:
                print(f"  ...{logos_fetched + len(logos_missing)}/{len(set_records)} done "
                      f"({logos_fetched} ok, {len(logos_missing)} missing)", file=sys.stderr)

        # Rewrite sets.json with the populated logoStyle fields.
        (OUT / "sets.json").write_text(json.dumps(set_records, separators=(",", ":"), ensure_ascii=False))

    # 7. Report
    print(f"\n=== Done ===", file=sys.stderr)
    print(f"  Sets shipped:           {len(set_records)}", file=sys.stderr)
    print(f"  Sets with no printings: {len(sets_no_printings)}", file=sys.stderr)
    print(f"  Sets blocked (collab):  {len(collab_skipped)}", file=sys.stderr)
    print(f"  Unique cards:           {len(cards_index)}", file=sys.stderr)

    if not args.sets_only:
        cards_size = (OUT / "cards.json").stat().st_size
        printings_size = sum(p.stat().st_size for p in OUT.glob("set-cards-*.json"))
        print(f"  cards.json:             {cards_size/1024/1024:.1f} MB", file=sys.stderr)
        print(f"  set-cards-*.json:       {printings_size/1024/1024:.1f} MB", file=sys.stderr)

    sets_size = (OUT / "sets.json").stat().st_size
    print(f"  sets.json:              {sets_size/1024:.0f} KB", file=sys.stderr)

    if not args.no_logos and not args.sets_only:
        logos_size = sum(p.stat().st_size for p in LOGOS_OUT.glob("*.png"))
        print(f"  set-logos/:             {logos_size/1024/1024:.1f} MB ({logos_fetched} files)", file=sys.stderr)
        print(f"    Style breakdown:      logo={logo_style_counts.get('logo', 0)}, packArt={logo_style_counts.get('packArt', 0)}", file=sys.stderr)
        print(f"  Logos missing:          {len(logos_missing)}", file=sys.stderr)

    # Shelf distribution
    from collections import Counter
    shelves = Counter(r["shelf"] for r in set_records)
    print(f"\n  Shelf distribution:", file=sys.stderr)
    for shelf, count in shelves.most_common():
        print(f"    {shelf:25s} {count}", file=sys.stderr)

    eras = Counter(r["era"] or "(none)" for r in set_records)
    print(f"\n  Era distribution:", file=sys.stderr)
    for era, count in eras.most_common():
        print(f"    {era:25s} {count}", file=sys.stderr)

    if sets_no_printings:
        print(f"\n  Sets with no printings (first 10):", file=sys.stderr)
        for code, name in sets_no_printings[:10]:
            print(f"    {code}: {name}", file=sys.stderr)

    if collab_skipped:
        print(f"\n  Collab/crossover sets blocked:", file=sys.stderr)
        for code, name in collab_skipped:
            print(f"    {code}: {name}", file=sys.stderr)


if __name__ == "__main__":
    main()
