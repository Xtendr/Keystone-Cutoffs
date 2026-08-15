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
BASE_URL = "https://raider.io/api/v1/mythic-plus/season-cutoffs"
SCORE_TIERS_URL = "https://raider.io/api/v1/mythic-plus/score-tiers"
RUNS_URL = "https://raider.io/api/v1/mythic-plus/runs"
STATIC_DATA_URL = "https://raider.io/api/v1/mythic-plus/static-data?expansion_id=11"
SEASON_OVERRIDE_ENV = "KEYSTONE_CUTOFFS_SEASON"

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
        "User-Agent": "KeystoneCutoffs-WoW-Addon/1.2.1",
    }
    api_key = os.environ.get("RAIDER_IO_API_KEY", "").strip()
    if api_key:
        headers["Authorization"] = f"Token {api_key}"
    return headers


def fetch_static_data() -> dict:
    """Fetch Raider.IO's authoritative season schedule and dungeon pool."""
    req = urllib.request.Request(STATIC_DATA_URL, headers=build_headers())
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))
    except (urllib.error.HTTPError, urllib.error.URLError, ValueError) as exc:
        print(f"[ERROR] Could not fetch season metadata: {exc}", file=sys.stderr)
        return {}


def parse_api_datetime(value: str) -> datetime:
    """Parse an ISO-8601 timestamp returned by Raider.IO."""
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def select_release_season(static_data: dict, now: datetime | None = None) -> dict:
    """Select the newest main season that has started in every supported region.

    Midnight seasons roll out at different regional reset times. Waiting until
    all four regions have started prevents a daily package from mixing seasons
    or erasing regions that still return 404 for the new season.
    """
    now = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    seasons = [s for s in static_data.get("seasons", []) if s.get("is_main_season")]

    override = os.environ.get(SEASON_OVERRIDE_ENV, "").strip()
    if override:
        for season in seasons:
            if season.get("slug") == override:
                return season
        raise ValueError(f"Unknown season override: {override}")

    eligible = []
    for season in seasons:
        starts = season.get("starts", {})
        try:
            global_start = max(parse_api_datetime(starts[region]) for region in REGIONS)
        except (KeyError, TypeError, ValueError):
            continue
        if global_start <= now:
            eligible.append((global_start, season))

    if not eligible:
        raise ValueError("No main Mythic+ season has started in every supported region")
    return max(eligible, key=lambda item: item[0])[1]


def season_dungeons(season_info: dict) -> list:
    """Return the release dungeon pool using in-game challenge mode IDs."""
    dungeons = []
    for dungeon in season_info.get("dungeons", []):
        challenge_mode_id = dungeon.get("challenge_mode_id")
        slug = dungeon.get("slug")
        name = dungeon.get("name")
        if challenge_mode_id is None or not slug or not name:
            continue
        dungeons.append({
            "slug": slug,
            "name": name,
            "challengeModeID": int(challenge_mode_id),
        })
    if not dungeons:
        raise ValueError(f"Season {season_info.get('slug', 'unknown')} has no valid dungeons")
    return dungeons


def format_end_date(value: str | None, now: datetime | None = None) -> str:
    """Format a regional end date, rejecting Raider.IO's far-future sentinel."""
    if not value:
        return "Not announced"
    try:
        end = parse_api_datetime(value)
    except (TypeError, ValueError):
        return "Not announced"
    now = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    if end.year >= 2030 or (end - now).days > 730:
        return "Not announced"
    return f"{end.strftime('%B')} {end.day}, {end.year}"


def regional_end_dates(season_info: dict, now: datetime | None = None) -> dict:
    ends = season_info.get("ends", {})
    return {region: format_end_date(ends.get(region), now) for region in REGIONS}


def season_end_summary(region_ends: dict) -> str:
    values = list(dict.fromkeys(region_ends.get(region, "Not announced") for region in REGIONS))
    if len(values) == 1:
        return values[0]
    return "Varies by region"


def fetch_cutoffs(region: str, season: str) -> dict:
    """Fetch cutoff data for *region* from the Raider.io API."""
    url = f"{BASE_URL}?season={season}&region={region}"
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


def fetch_score_tiers(season: str) -> list:
    """Fetch the season's score tiers (includes rgb colors)."""
    url = f"{SCORE_TIERS_URL}?season={season}"
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


def fetch_dungeon_benchmark(
    region: str, dungeon_slug: str, title_count: int, season: str
) -> int | None:
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
        url = (f"{RUNS_URL}?season={season}&region={region}"
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


def fetch_all_dungeon_benchmarks(
    all_data: dict, season: str, dungeons: list
) -> dict:
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
              f"fetching {len(dungeons)} dungeon benchmarks …")

        region_data: dict = {}
        for dungeon in dungeons:
            level = fetch_dungeon_benchmark(
                region, dungeon["slug"], title_count, season
            )
            if level is not None:
                region_data[dungeon["challengeModeID"]] = level
                print(f"    {dungeon['name']}: +{level}")
            else:
                print(f"    {dungeon['name']}: (no data)")

        if region_data:
            benchmarks[region] = region_data

    return benchmarks


def validate_cutoff_data(all_data: dict) -> list:
    """Return validation errors that must block publication."""
    errors = []
    for region in REGIONS:
        cutoffs = all_data.get(region, {}).get("cutoffs", {})
        title = cutoffs.get("p999", {}).get("all", {})
        if not cutoffs:
            errors.append(f"{region}: missing cutoff table")
        elif title.get("quantileMinValue") is None:
            errors.append(f"{region}: missing top-0.1% score")
        elif title.get("quantilePopulationCount") is None:
            errors.append(f"{region}: missing top-0.1% population")
    return errors


def validate_benchmarks(all_data: dict, benchmarks: dict, dungeons: list) -> list:
    """Require full dungeon coverage whenever a title population exists."""
    errors = []
    expected_ids = {dungeon["challengeModeID"] for dungeon in dungeons}
    for region in REGIONS:
        title = (
            all_data.get(region, {})
            .get("cutoffs", {})
            .get("p999", {})
            .get("all", {})
        )
        title_count = int(title.get("quantilePopulationCount", 0) or 0)
        if title_count <= 0:
            continue
        present_ids = set(benchmarks.get(region, {}))
        missing = sorted(expected_ids - present_ids)
        if missing:
            errors.append(f"{region}: missing dungeon benchmarks {missing}")
    return errors


def build_lua(
    all_data: dict,
    score_colors: list,
    dungeon_benchmarks: dict,
    season: str,
    season_ends: dict,
) -> str:
    """Convert the collected API data into a Lua table string."""
    now_utc = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    lines = [
        "-- CutoffData.lua",
        "-- Auto-generated by update_cutoffs.py – do not edit manually.",
        f"-- Last updated : {now_utc}",
        f"-- Season       : {season}",
        f"-- Season end   : {season_end_summary(season_ends)}",
        "",
        "KeystoneCutoffsData = {",
        f'    seasonEnd = "{season_end_summary(season_ends)}",',
        "    seasonEnds = {",
    ]
    for region in REGIONS:
        lines.append(f'        ["{region}"] = "{season_ends[region]}",')
    lines.extend([
        "    },",
        f'    updatedAt = "{now_utc}",',
        f'    season    = "{season}",',
        "    regions   = {",
    ])

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

    print("Fetching season schedule and dungeon pool …")
    static_data = fetch_static_data()
    if not static_data:
        sys.exit(1)
    try:
        season_info = select_release_season(static_data)
        season = season_info["slug"]
        dungeons = season_dungeons(season_info)
    except (KeyError, TypeError, ValueError) as exc:
        print(f"[ERROR] Invalid season metadata: {exc}", file=sys.stderr)
        sys.exit(1)

    season_ends = regional_end_dates(season_info)
    print(f"Selected {season} with {len(dungeons)} dungeons.")

    all_data: dict = {}
    for region in REGIONS:
        print(f"Fetching cutoffs for region: {region} …")
        payload = fetch_cutoffs(region, season)
        if payload:
            all_data[region] = payload
            print(f"  OK – {len(payload.get('cutoffs', {}))} keys received.")
        else:
            print(f"  WARN – empty payload for {region}, region will be skipped in output.")

    cutoff_errors = validate_cutoff_data(all_data)
    if cutoff_errors:
        print("Cutoff validation failed; preserving the existing file:", file=sys.stderr)
        for error in cutoff_errors:
            print(f"  - {error}", file=sys.stderr)
        sys.exit(1)

    print("Fetching score tiers for gradient data …")
    score_tiers = fetch_score_tiers(season)
    score_colors = normalize_score_tiers(score_tiers)
    score_colors.sort(key=lambda entry: entry["score"], reverse=True)
    if not score_colors:
        print("Score-tier validation failed; preserving the existing file.", file=sys.stderr)
        sys.exit(1)

    print("Fetching per-dungeon title-pace benchmarks …")
    dungeon_benchmarks = fetch_all_dungeon_benchmarks(all_data, season, dungeons)
    benchmark_errors = validate_benchmarks(all_data, dungeon_benchmarks, dungeons)
    if benchmark_errors:
        print("Benchmark validation failed; preserving the existing file:", file=sys.stderr)
        for error in benchmark_errors:
            print(f"  - {error}", file=sys.stderr)
        sys.exit(1)

    lua_content = build_lua(
        all_data, score_colors, dungeon_benchmarks, season, season_ends
    )

    temp_output = OUTPUT_FILE + ".tmp"
    with open(temp_output, "w", encoding="utf-8") as fh:
        fh.write(lua_content)
    os.replace(temp_output, OUTPUT_FILE)

    print(f"\nWrote {len(lua_content):,} bytes -> {OUTPUT_FILE}")


if __name__ == "__main__":
    main()
