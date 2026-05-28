#!/usr/bin/env python3
"""
YGO Rip rarity coverage audit.

Mirrors the pattern from poke-rip's audit. Checks the engine's hardcoded
per-era weight tables against the rarities present in bundled card data.

Three passes:
  1. Card-data → engine: a rarity in card data not handled by any era weight
     table for that era. PackPrefetcher's tier-aware fallback will pick *a*
     card from a same/adjacent tier, but the distribution intent is broken.
  2. Engine → card-data: a rarity in an era's weight tables that no bundled
     set for that era actually has — silent slot drift.
  3. Hot pack reachability: for each era, the chase weights filtered to
     rank ≥ 3 must leave at least one entry (otherwise hot packs degrade to
     the full chase weight table, which masks the bug).

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
        "commonSlotWeights": ["Common", "Short Print"],
        "rareSlotWeights": ["Rare", "Super Rare", "Ultra Rare", "Secret Rare"],
        "reverseHoloWeights": [],
    },
    "classic": {
        "commonSlotWeights": ["Common"],
        "rareSlotWeights": ["Rare", "Super Rare", "Ultra Rare", "Secret Rare", "Ultimate Rare", "Ghost Rare"],
        "reverseHoloWeights": [],
    },
    "modern": {
        "commonSlotWeights": ["Common"],
        "rareSlotWeights": [
            "Super Rare", "Ultra Rare", "Secret Rare",
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
                if r not in card_rarities:
                    problems.append(
                        f"  [{era}] {table_name} entry {r!r} not present in any bundled set's card data"
                    )
    return problems


def audit_cards_to_engine(era_card_rarities: dict[str, set[str]]) -> list[str]:
    """Card-data → engine: every card rarity should be rollable by *some* slot
    in the era's config. PackPrefetcher's tier-aware fallback hides this, but
    distribution intent is broken if a rarity is unreachable."""
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
            if r not in card_rarities:
                problems.append(
                    f"  [{era}] hot pack rarity {r!r} not present in any bundled set's card data"
                )
    return problems


def main() -> int:
    era_card_rarities = gather_era_card_rarities()

    passes = [
        ("Engine → card-data", audit_engine_to_cards(era_card_rarities)),
        ("Card-data → engine", audit_cards_to_engine(era_card_rarities)),
        ("Hot pack reachability", audit_hot_pack_reachability(era_card_rarities)),
    ]

    failed = False
    for name, problems in passes:
        if problems:
            failed = True
            print(f"⚠ {name}: {len(problems)} issue(s)")
            for p in problems:
                print(p)
        else:
            print(f"✓ {name}")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
