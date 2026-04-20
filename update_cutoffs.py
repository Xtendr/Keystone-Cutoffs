#!/usr/bin/env python3
"""
update_cutoffs.py
Fetches Mythic+ season cutoff data from the Raider.io API and writes it
to CutoffData.lua so the KeystoneCutoffs WoW addon can read it globally.

Supported regions: eu, us, kr, tw
"""

import json
import os
import sys
import urllib.request
import urllib.error
from datetime import datetime, timezone

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

REGIONS = ["eu", "us", "kr", "tw"]
SEASON   = "season-mn-1"
BASE_URL = "https://raider.io/api/v1/mythic-plus/season-cutoffs"
SCORE_TIERS_URL = "https://raider.io/api/v1/mythic-plus/score-tiers"
RUNS_URL = "https://raider.io/api/v1/mythic-plus/runs"

# Dungeons active in season-mn-1.
# challengeModeID matches icon.mapID used by C_MythicPlus.GetSeasonBestForMap().
# Verified against Raider.IO static-data API (expansion_id=11).
SEASON_DUNGEONS = [
    {"slug": "algethar-academy",         "name": "Algeth'ar Academy",       "challengeModeID": 402},
    {"slug": "magisters-terrace",        "name": "Magisters' Terrace",      "challengeModeID": 558},
    {"slug": "maisara-caverns",          "name": "Maisara Caverns",         "challengeModeID": 560},
    {"slug": "nexuspoint-xenas",         "name": "Nexus-Point Xenas",       "challengeModeID": 559},
    {"slug": "pit-of-saron",            "name": "Pit of Saron",            "challengeModeID": 556},
    {"slug": "seat-of-the-triumvirate",  "name": "Seat of the Triumvirate", "challengeModeID": 239},
    {"slug": "skyreach",                "name": "Skyreach",                "challengeModeID": 161},
    {"slug": "windrunner-spire",        "name": "Windrunner Spire",        "challengeModeID": 557},
]

# Estimated date the season ends (used as a display hint in the Lua table).
SEASON_END_DATE = "September 1, 2026"

# Percentile keys present in the Raider.io payload.
PERCENTILE_KEYS = ["p999", "p990", "p900", "p750", "p600"]

# Named-title keys (fixed thresholds like Keystone Myth / Legend / etc.)
TITLE_KEYS = [
    "keystoneMyth",
    "keystoneLegend",
    "keystoneHero",
    "keystoneMaster",
    "keystoneConqueror",
    "keystoneExplorer",
]

# Path to output file (relative to this script).
OUTPUT_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "CutoffData.lua")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def build_headers() -> dict:
    """Return request headers, injecting the API key if available."""
    headers = {
        "Accept": "application/json",
        "User-Agent": "KeystoneCutoffs-WoW-Addon/1.0",
    }
    api_key = os.environ.get("RAIDER_IO_API_KEY", "").strip()
    if api_key:
        headers["Authorization"] = f"Token {api_key}"
    return headers


def fetch_cutoffs(region: str) -> dict:
    """Fetch cutoff data for *region* from the Raider.io API."""
    url = f"{BASE_URL}?season={SEASON}&region={region}"
    headers = build_headers()

    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            raw = response.read().decode("utf-8")
            return json.loads(raw)
    except urllib.error.HTTPError as exc:
        print(f"  [ERROR] HTTP {exc.code} fetching {region}: {exc.reason}", file=sys.stderr)
        return {}
    except urllib.error.URLError as exc:
        print(f"  [ERROR] Network error fetching {region}: {exc.reason}", file=sys.stderr)
        return {}
    except Exception as exc:  # noqa: BLE001
        print(f"  [ERROR] Unexpected error fetching {region}: {exc}", file=sys.stderr)
        return {}


# ---------------------------------------------------------------------------
# Lua serialisation helpers
# ---------------------------------------------------------------------------

def lua_number(value) -> str:
    """Format a number for Lua: integer if whole, otherwise 2 decimal places."""
    if value is None:
        return "nil"
    try:
        f = float(value)
        return str(int(f)) if f == int(f) else f"{f:.2f}"
    except (TypeError, ValueError):
        return "nil"


def faction_block(data: dict, indent: str) -> str:
    """Render a horde/alliance/all block as a Lua inline table."""
    if not data:
        return "nil"
    score = lua_number(data.get("quantileMinValue"))
    pop   = lua_number(data.get("totalPopulationCount"))
    frac  = f'{float(data.get("quantilePopulationFraction", 0)) * 100:.3f}'
    return (
        f"{{ score = {score}, population = {pop}, percentile = {frac} }}"
    )


def fetch_score_tiers() -> list:
    """Fetch the season's score tiers (includes rgb colors)."""
    url = f"{SCORE_TIERS_URL}?season={SEASON}"
    headers = build_headers()

    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            raw = response.read().decode("utf-8")
            payload = json.loads(raw)
            # Raider.IO may return either:
            # 1) a plain list of tiers, or
            # 2) an object with tiers nested under known keys.
            if isinstance(payload, list):
                return payload
            if not isinstance(payload, dict):
                return []
            for key in ("tiers", "scoreTiers"):
                value = payload.get(key)
                if isinstance(value, list):
                    return value
            return []
    except urllib.error.HTTPError as exc:
        print(f"  [ERROR] HTTP {exc.code} fetching score tiers: {exc.reason}", file=sys.stderr)
        return []
    except urllib.error.URLError as exc:
        print(f"  [ERROR] Network error fetching score tiers: {exc.reason}", file=sys.stderr)
        return []
    except Exception as exc:  # noqa: BLE001
        print(f"  [ERROR] Unexpected error fetching score tiers: {exc}", file=sys.stderr)
        return []


def normalize_score_tiers(tiers: list) -> list:
    entries = []
    for tier in tiers:
        score = tier.get("score")
        color = tier.get("rgbHex") or tier.get("color")
        if score is None or not color:
            continue
        try:
            numeric_score = float(score)
        except (TypeError, ValueError):
            continue
        cleaned_color = color.strip()
        if not cleaned_color.startswith("#"):
            cleaned_color = "#" + cleaned_color
        if len(cleaned_color) != 7:
            continue
        entries.append({"score": numeric_score, "color": cleaned_color.upper()})
    return entries


def fetch_dungeon_benchmark(region: str, dungeon_slug: str, title_count: int) -> int | None:
    """Return the key level at the title-count position in the per-dungeon leaderboard.

    How it works
    ------------
    The per-dungeon runs leaderboard is sorted best-first (one entry per
    character's best run in that dungeon).  Position title_count represents the
    player ranked at the exact title boundary in that specific dungeon, which
    approximates the key level a typical title-caliber player has completed there.

    We use the exact quantilePopulationCount from Raider.IO (not a derived value)
    and fetch the single leaderboard page that contains that position.  If the
    page is empty (leaderboard shorter than title_count), we walk backward to the
    last available entry.
    """
    if title_count <= 0:
        return None

    # Raider.IO pages are 0-indexed, 20 runs each.
    page = (title_count - 1) // 20
    pos  = (title_count - 1) % 20

    for attempt_page in range(page, max(-1, page - 10), -1):
        if attempt_page < 0:
            break
        url = (f"{RUNS_URL}?season={SEASON}&region={region}"
               f"&dungeon={dungeon_slug}&affixes=all&page={attempt_page}")
        req = urllib.request.Request(url, headers=build_headers())
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                payload = json.loads(response.read().decode("utf-8"))
            rankings = payload.get("rankings", [])
            if not rankings:
                continue                            # page empty – try one page earlier
            # Use the requested position if on the target page, otherwise last entry.
            idx   = pos if attempt_page == page else len(rankings) - 1
            entry = rankings[min(idx, len(rankings) - 1)]
            level = entry.get("run", {}).get("mythic_level")
            return int(level) if level is not None else None
        except urllib.error.HTTPError as exc:
            print(f"    [WARN] HTTP {exc.code} – {dungeon_slug}/{region}", file=sys.stderr)
        except Exception as exc:  # noqa: BLE001
            print(f"    [WARN] Benchmark fetch failed {dungeon_slug}/{region}: {exc}",
                  file=sys.stderr)
        break   # non-empty-page errors are not retried

    return None


def fetch_all_dungeon_benchmarks(all_data: dict) -> dict:
    """Fetch the title-boundary key level per dungeon per region.

    The benchmark key is the level at position title_count in the per-dungeon
    leaderboard, i.e. what a player ranked exactly at the title boundary has
    done in each dungeon.  This reflects what a typical title player actually
    completes, accounting for the fact that different players compensate across
    different dungeons.

    Returns { region: { challengeModeID: keyLevel, ... }, ... }
    """
    benchmarks: dict = {}

    for region in REGIONS:
        payload  = all_data.get(region, {})
        cutoffs  = payload.get("cutoffs", {})
        p999_all = cutoffs.get("p999", {}).get("all", {})

        # Use the exact player count that Raider.IO reports directly.
        title_count = int(p999_all.get("quantilePopulationCount", 0))

        if title_count <= 0:
            print(f"  [WARN] No p999 population count for {region}, skipping benchmarks.")
            continue

        print(f"  {region}: {title_count} title players – "
              f"fetching {len(SEASON_DUNGEONS)} dungeon benchmarks …")

        region_data: dict = {}
        for dungeon in SEASON_DUNGEONS:
            level = fetch_dungeon_benchmark(region, dungeon["slug"], title_count)
            if level is not None:
                region_data[dungeon["challengeModeID"]] = level
                print(f"    {dungeon['name']}: +{level}")
            else:
                print(f"    {dungeon['name']}: (no data)")

        if region_data:
            benchmarks[region] = region_data

    return benchmarks


def build_lua(all_data: dict, score_colors: list, dungeon_benchmarks: dict) -> str:
    """Convert the collected API data into a Lua table string."""
    now_utc = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    lines = [
        "-- CutoffData.lua",
        "-- Auto-generated by update_cutoffs.py – do not edit manually.",
        f"-- Last updated : {now_utc}",
        f"-- Season       : {SEASON}",
        f"-- Season end   : {SEASON_END_DATE}",
        "",
        "KeystoneCutoffsData = {",
        f'    seasonEnd = "{SEASON_END_DATE}",',
        f'    updatedAt = "{now_utc}",',
        f'    season    = "{SEASON}",',
        "    regions   = {",
    ]

    for region in REGIONS:
        payload = all_data.get(region, {})
        cutoffs = payload.get("cutoffs", {})

        lines.append(f"        [{region!r}] = {{")

        if not cutoffs:
            lines.append("            -- No data available for this region.")
        else:
            # --- Percentile cutoffs ---
            lines.append("            percentiles = {")
            for key in PERCENTILE_KEYS:
                entry = cutoffs.get(key, {})
                if not entry:
                    continue
                all_obj   = entry.get("all", {})
                horde_obj = entry.get("horde", {})
                ally_obj  = entry.get("alliance", {})
                lines.append(f"                [{key!r}] = {{")
                lines.append(f"                    all      = {faction_block(all_obj,   '')},")
                lines.append(f"                    horde    = {faction_block(horde_obj, '')},")
                lines.append(f"                    alliance = {faction_block(ally_obj,  '')},")
                lines.append("                },")
            lines.append("            },")

            # --- Named-title cutoffs ---
            lines.append("            titles = {")
            for key in TITLE_KEYS:
                entry = cutoffs.get(key, {})
                if not entry:
                    continue
                fixed_score = lua_number(entry.get("score"))
                all_obj     = entry.get("all", {})
                horde_obj   = entry.get("horde", {})
                ally_obj    = entry.get("alliance", {})
                lines.append(f"                [{key!r}] = {{")
                lines.append(f"                    fixedScore = {fixed_score},")
                lines.append(f"                    all        = {faction_block(all_obj,   '')},")
                lines.append(f"                    horde      = {faction_block(horde_obj, '')},")
                lines.append(f"                    alliance   = {faction_block(ally_obj,  '')},")
                lines.append("                },")
            lines.append("            },")

            # --- Metadata ---
            updated_at = cutoffs.get("updatedAt", "unknown")
            lines.append(f'            updatedAt = "{updated_at}",')

        lines.append("        },")  # end region

    lines.append("    },")   # end regions
    lines.append("    scoreColors = {")
    for entry in score_colors:
        lines.append(
            f'        {{ score = {lua_number(entry["score"])}, color = "{entry["color"]}" }},'
        )
    lines.append("    },")
    lines.append("    -- Per-dungeon key level at the title (top 0.1%) boundary.")
    lines.append("    -- Key = in-game challenge mode ID (icon.mapID). Updated daily.")
    lines.append("    dungeonBenchmarks = {")
    for region in REGIONS:
        rdata = dungeon_benchmarks.get(region)
        if not rdata:
            lines.append(f"        [{region!r}] = {{}},  -- no data")
            continue
        lines.append(f"        [{region!r}] = {{")
        for cmid, level in sorted(rdata.items()):
            lines.append(f"            [{cmid}] = {level},")
        lines.append("        },")
    lines.append("    },")
    lines.append("}")        # end KeystoneCutoffsData
    lines.append("")         # trailing newline

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    api_key_present = bool(os.environ.get("RAIDER_IO_API_KEY", "").strip())
    if api_key_present:
        print("RAIDER_IO_API_KEY found – requests will be authenticated.")
    else:
        print("RAIDER_IO_API_KEY not set – sending unauthenticated requests.")

    all_data: dict = {}
    for region in REGIONS:
        print(f"Fetching cutoffs for region: {region} …")
        payload = fetch_cutoffs(region)
        if payload:
            all_data[region] = payload
            print(f"  OK – {len(payload.get('cutoffs', {}))} keys received.")
        else:
            print(f"  WARN – empty payload for {region}, region will be skipped in output.")

    if not all_data:
        print("No data fetched for any region. Aborting.", file=sys.stderr)
        sys.exit(1)

    print("Fetching score tiers for gradient data …")
    score_tiers = fetch_score_tiers()
    score_colors = normalize_score_tiers(score_tiers)
    score_colors.sort(key=lambda entry: entry["score"], reverse=True)

    print("Fetching per-dungeon title-pace benchmarks …")
    dungeon_benchmarks = fetch_all_dungeon_benchmarks(all_data)

    lua_content = build_lua(all_data, score_colors, dungeon_benchmarks)

    with open(OUTPUT_FILE, "w", encoding="utf-8") as fh:
        fh.write(lua_content)

    print(f"\nWrote {len(lua_content):,} bytes -> {OUTPUT_FILE}")


if __name__ == "__main__":
    main()
