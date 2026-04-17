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


def build_lua(all_data: dict, score_colors: list) -> str:
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

    lua_content = build_lua(all_data, score_colors)

    with open(OUTPUT_FILE, "w", encoding="utf-8") as fh:
        fh.write(lua_content)

    print(f"\nWrote {len(lua_content):,} bytes → {OUTPUT_FILE}")


if __name__ == "__main__":
    main()
