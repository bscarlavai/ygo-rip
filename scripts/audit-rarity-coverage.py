#!/usr/bin/env python3
"""
YGO Rip rarity coverage audit.

Mirrors the pattern from poke-rip's audit. Checks the engine's hardcoded
per-era weight tables against the rarities present in bundled card data.

Four passes:
  1. Engine → card-data (failing): a rarity in an era's weight tables that no
     bundled set for that era actually has — silent slot drift. Known
     chase-variant-dedup absences are suppressed (KNOWN_DEDUPED_CHASE).
  2. Card-data → engine (informational): a rarity in card data not handled by
     any era weight table. Usually fine — tier fallback reaches it — but new
     strings showing up here after a bundle update deserve a look.
  3. Hot pack reachability (failing): for each era, the chase weights filtered
     to rank ≥ 3 must leave at least one entry (otherwise hot packs degrade to
     the full chase weight table, which masks the bug).
  4. Per-set reachability (failing): simulates PackPrefetcher's slot-fill
     fallback chain per set; any card whose rarity can never be picked means
     that set's collection is permanently incompletable.

YGO's per-era PackConfigs are hardcoded in Swift (YGORip/Services/
PullRateEngine.swift). This audit mirrors those configs in Python — keep
them in sync. Drift is partially self-detected: an entry the audit thinks
exists but the engine no longer rolls (or vice versa) shows up as either a
spurious unreachable warning or an unhandled-rarity warning.

Run before shipping a bundle update; CI-ready (exits non-zero on findings).
"""

import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
BUNDLED = REPO_ROOT / "YGORip" / "Resources" / "Bundled"

# Mirrors PackConfig.config(forEra:) in YGORip/Services/PullRateEngine.swift.
# Keys are the era strings used in sets.json; values are the config name we
# share between sibling-era sets.
ERA_GROUPS = {
    "lob": "lob",
    "gx": "classic", "5ds": "classic", "zexal": "classic",
    "arcv": "modern", "vrains": "modern", "sevens": "modern", "gorush": "modern",
}

# Mirrors the three PackConfig literals in PullRateEngine.swift.
# Each entry maps slot-table name → list of rarity strings the engine can roll
# from that table for that era.
ERA_WEIGHT_TABLES: dict[str, dict[str, list[str]]] = {
    "lob": {
        "commonSlotWeights": ["Common", "Short Print", "Super Short Print"],
        "rareSlotWeights": ["Rare", "Super Rare", "Ultra Rare", "Secret Rare"],
        "reverseHoloWeights": [],
    },
    "classic": {
        "commonSlotWeights": ["Common", "Short Print"],
        "rareSlotWeights": ["Rare", "Super Rare", "Ultra Rare", "Secret Rare", "Ultimate Rare", "Ghost Rare"],
        "reverseHoloWeights": [],
    },
    "modern": {
        "commonSlotWeights": ["Common", "Short Print"],
        "rareSlotWeights": [
            "Super Rare", "Ultra Rare", "Secret Rare", "Ultimate Rare",
            "Starlight Rare", "Quarter Century Secret Rare",
            "Collector's Rare", "Prismatic Secret Rare",
        ],
        "reverseHoloWeights": ["Rare"],
    },
}

# Mirrors CardRarityRank.rank(for:) in PullRateEngine.swift — used for the
# hot pack reachability check (filter chase weights to rank ≥ 3).
RARITY_RANK = {
    "common": 0, "short print": 0,
    "rare": 1,
    "super rare": 2,
    "ultra rare": 3, "ultimate rare": 3,
    "secret rare": 4, "ghost rare": 4, "starlight rare": 4,
    "quarter century secret rare": 4, "collector's rare": 4,
    "prismatic secret rare": 4, "platinum secret rare": 4,
}


def rank_for(rarity: str) -> int:
    return RARITY_RANK.get(rarity.lower(), 0)


# Chase rarities the engine rolls on purpose even though the pipeline's
# chase-variant dedup (CLAUDE.md §8) collapses them out of bundled card data:
# the same card number ships at e.g. Ultra + Ghost, and we keep only the base
# printing until foil-tier extensions land. When rolled, the slot falls back
# to the same tier (Secret pool) — harmless. Suppressed in the engine→card-data
# and hot-pack passes so they don't mask real drift.
KNOWN_DEDUPED_CHASE = {
    ("classic", "Ghost Rare"),
    ("modern", "Collector's Rare"),
}


# Mirrors CardModel.rarityRank(for:) in YGORip/Models/CardModel.swift — the
# tier mapping PackPrefetcher uses for slot-fill fallback. Distinct from
# RARITY_RANK above (CardRarityRank is the engine's coarser hot-pack mirror).
CARD_MODEL_RANK = {
    "common": 0, "short print": 0, "super short print": 0,
    "rare": 1, "normal parallel rare": 1, "duel terminal normal parallel rare": 1,
    "mosaic rare": 1, "starfoil rare": 1, "shatterfoil rare": 1,
    "super rare": 2, "duel terminal rare parallel rare": 2,
    "duel terminal super parallel rare": 2,
    "ultra rare": 3, "ultimate rare": 3, "platinum rare": 3,
    "ultra parallel rare": 3, "duel terminal ultra parallel rare": 3,
    "ultra rare (pharaoh's rare)": 3,
    "secret rare": 4, "ghost rare": 4, "starlight rare": 4,
    "quarter century secret rare": 4, "collector's rare": 4, "collectors rare": 4,
    "prismatic secret rare": 4, "platinum secret rare": 4,
    "gold rare": 4, "gold secret rare": 4, "premium gold rare": 4,
    "ghost/gold rare": 4, "grand master rare": 4, "ultra secret rare": 4,
    "extra secret rare": 4, "extra secret": 4, "10000 secret rare": 4,
}


def card_model_rank(rarity: str) -> int:
    return CARD_MODEL_RANK.get(rarity.lower(), 0)


def load_sets() -> list[dict]:
    data = json.loads((BUNDLED / "sets.json").read_text())
    if isinstance(data, dict):
        data = data.get("data", [])
    return data


def gather_era_card_rarities() -> dict[str, set[str]]:
    """era config name (lob/classic/modern) → set of all rarity strings present
    in any bundled set assigned to that era."""
    sets = load_sets()
    code_to_config: dict[str, str] = {}
    for s in sets:
        era = s.get("era")
        if era is None:
            continue
        config = ERA_GROUPS.get(era)
        if config is None:
            continue
        code_to_config[s["code"]] = config

    by_config: dict[str, set[str]] = defaultdict(set)
    for code, config in code_to_config.items():
        card_file = BUNDLED / f"set-cards-{code}.json"
        if not card_file.exists():
            continue
        data = json.loads(card_file.read_text())
        if isinstance(data, dict):
            data = data.get("data", [])
        for c in data:
            r = c.get("rarity")
            if r:
                by_config[config].add(r)
    return by_config


def audit_engine_to_cards(era_card_rarities: dict[str, set[str]]) -> list[str]:
    """Engine → card-data: every rarity the engine can roll must exist in real
    bundled card data for at least one set in that era."""
    problems: list[str] = []
    for era, tables in ERA_WEIGHT_TABLES.items():
        card_rarities = era_card_rarities.get(era, set())
        for table_name, rarities in tables.items():
            for r in rarities:
                if r not in card_rarities and (era, r) not in KNOWN_DEDUPED_CHASE:
                    problems.append(
                        f"  [{era}] {table_name} entry {r!r} not present in any bundled set's card data"
                    )
    return problems


def audit_cards_to_engine(era_card_rarities: dict[str, set[str]]) -> list[str]:
    """Card-data → engine: card rarities no era table can roll. INFORMATIONAL
    only — most hits are variant rarities (Duel Terminal, Gold Series, Battle
    Pack foils) living in sets with no Commons, where the tier fallback
    reaches them fine. The per-set reachability pass is the precise, failing
    version of this question; this list is kept as a radar for new rarity
    strings arriving in bundle updates."""
    problems: list[str] = []
    for era, card_rarities in era_card_rarities.items():
        all_handled: set[str] = set()
        for rarities in ERA_WEIGHT_TABLES[era].values():
            all_handled.update(rarities)
        for r in sorted(card_rarities):
            if r not in all_handled:
                problems.append(
                    f"  [{era}] card-data rarity {r!r} not in any weight table"
                )
    return problems


def audit_hot_pack_reachability(era_card_rarities: dict[str, set[str]]) -> list[str]:
    """Hot pack rolls chase weights filtered to rank ≥ 3. Verify the filter
    leaves a non-empty list, and that each remaining rarity is in card data."""
    problems: list[str] = []
    for era, tables in ERA_WEIGHT_TABLES.items():
        chase = tables.get("rareSlotWeights", [])
        hot = [r for r in chase if rank_for(r) >= 3]
        if not hot:
            problems.append(
                f"  [{era}] no chase rarity is rank ≥ 3; hot packs fall back to full chase weights"
            )
            continue
        card_rarities = era_card_rarities.get(era, set())
        for r in hot:
            if r not in card_rarities and (era, r) not in KNOWN_DEDUPED_CHASE:
                problems.append(
                    f"  [{era}] hot pack rarity {r!r} not present in any bundled set's card data"
                )
    return problems


def audit_per_set_reachability() -> list[str]:
    """Per-set unpullable-card check — the precise version of pass 1.

    Mirrors PackPrefetcher.generate's slot-fill chain: exact rarity-string
    match first, then same CardModel tier, then adjacent (±1) tier, then
    anything. The fallback only fires when the *exact* pool is empty — so in
    a set that has cards for every rarity the era's tables roll, a rarity
    that NO table rolls is permanently unpullable and the collection can
    never reach 100%. (Real user bug: Spell Ruler stuck at 100/104 because
    its 4 Super Short Prints weren't in any lob-era weight table.)

    The era-level passes miss this because they can't see which sets trigger
    the fallback. This pass evaluates each set's pools individually.
    """
    problems: list[str] = []
    for s in load_sets():
        code = s["code"]
        card_file = BUNDLED / f"set-cards-{code}.json"
        if not card_file.exists():
            continue
        data = json.loads(card_file.read_text())
        if isinstance(data, dict):
            data = data.get("data", [])
        if not data:
            continue

        counts = Counter(c["rarity"] for c in data if c.get("rarity"))
        present = set(counts)
        tiers_present: dict[int, set[str]] = defaultdict(set)
        for r in present:
            tiers_present[card_model_rank(r)].add(r)

        # era None falls back to modern in PackConfig.config(for:).
        config = ERA_GROUPS.get(s.get("era") or "gorush", "modern")
        rolled = [r for table in ERA_WEIGHT_TABLES[config].values() for r in table]

        reachable: set[str] = set()
        for r in rolled:
            if r in present:
                reachable.add(r)
                continue
            tier = card_model_rank(r)
            same = tiers_present.get(tier, set())
            if same:
                reachable |= same
                continue
            adjacent = tiers_present.get(tier - 1, set()) | tiers_present.get(tier + 1, set())
            reachable |= adjacent if adjacent else present

        unreachable = present - reachable
        if unreachable:
            n = sum(counts[r] for r in unreachable)
            detail = ", ".join(f"{r} ×{counts[r]}" for r in sorted(unreachable))
            problems.append(
                f"  [{code}] {n} unpullable card(s) — collection capped at "
                f"{sum(counts.values()) - n}/{sum(counts.values())}: {detail}"
            )
    return problems


def main() -> int:
    era_card_rarities = gather_era_card_rarities()

    passes = [
        ("Engine → card-data", audit_engine_to_cards(era_card_rarities), True),
        ("Card-data → engine (informational)", audit_cards_to_engine(era_card_rarities), False),
        ("Hot pack reachability", audit_hot_pack_reachability(era_card_rarities), True),
        ("Per-set reachability", audit_per_set_reachability(), True),
    ]

    failed = False
    for name, problems, failing in passes:
        if problems:
            failed = failed or failing
            print(f"{'⚠' if failing else 'ℹ'} {name}: {len(problems)} issue(s)")
            for p in problems:
                print(p)
        else:
            print(f"✓ {name}")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
