import importlib.util
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from unittest import TestCase, main
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("update_cutoffs", ROOT / "update_cutoffs.py")
UPDATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UPDATE)


def iso(day, hour=0):
    return f"2026-08-{day:02d}T{hour:02d}:00:00Z"


def season(slug, starts, ends, dungeon_id):
    return {
        "slug": slug,
        "is_main_season": True,
        "starts": starts,
        "ends": ends,
        "dungeons": [{
            "slug": f"dungeon-{dungeon_id}",
            "name": f"Dungeon {dungeon_id}",
            "challenge_mode_id": dungeon_id,
        }],
    }


class SeasonSelectionTests(TestCase):
    def setUp(self):
        self.s1 = season(
            "season-mn-1",
            {region: "2026-03-25T04:00:00Z" for region in UPDATE.REGIONS},
            {"us": iso(18, 15), "eu": iso(19, 4), "kr": iso(19, 23), "tw": iso(19, 23)},
            402,
        )
        self.s2 = season(
            "season-mn-2",
            {"us": iso(18, 15), "eu": iso(19, 4), "kr": iso(19, 23), "tw": iso(19, 23)},
            {region: "2030-01-01T00:00:00Z" for region in UPDATE.REGIONS},
            588,
        )
        self.static_data = {"seasons": [self.s2, self.s1]}

    def test_keeps_previous_season_during_regional_rollout(self):
        now = datetime(2026, 8, 19, 8, tzinfo=timezone.utc)
        selected = UPDATE.select_release_season(self.static_data, now)
        self.assertEqual("season-mn-1", selected["slug"])

    def test_switches_after_every_region_has_started(self):
        now = datetime(2026, 8, 20, 8, tzinfo=timezone.utc)
        selected = UPDATE.select_release_season(self.static_data, now)
        self.assertEqual("season-mn-2", selected["slug"])
        self.assertEqual(588, UPDATE.season_dungeons(selected)[0]["challengeModeID"])

    def test_override_is_explicit_and_validated(self):
        with patch.dict(os.environ, {UPDATE.SEASON_OVERRIDE_ENV: "season-mn-2"}):
            selected = UPDATE.select_release_season(
                self.static_data, datetime(2026, 8, 15, tzinfo=timezone.utc)
            )
        self.assertEqual("season-mn-2", selected["slug"])

    def test_far_future_end_is_not_presented_as_real(self):
        now = datetime(2026, 8, 15, tzinfo=timezone.utc)
        ends = UPDATE.regional_end_dates(self.s2, now)
        self.assertEqual({region: "Not announced" for region in UPDATE.REGIONS}, ends)

    def test_real_regional_end_dates_are_preserved(self):
        now = datetime(2026, 8, 15, tzinfo=timezone.utc)
        ends = UPDATE.regional_end_dates(self.s1, now)
        self.assertEqual("August 18, 2026", ends["us"])
        self.assertEqual("August 19, 2026", ends["eu"])


class PublicationSafetyTests(TestCase):
    def setUp(self):
        self.title = {
            "quantileMinValue": 3500,
            "quantilePopulationCount": 20,
            "quantilePopulationFraction": 0.001,
        }
        self.all_data = {
            region: {"cutoffs": {"p999": {"all": dict(self.title)}}}
            for region in UPDATE.REGIONS
        }
        self.dungeons = [
            {"slug": "one", "name": "One", "challengeModeID": 101},
            {"slug": "two", "name": "Two", "challengeModeID": 102},
        ]

    def test_rejects_any_missing_region(self):
        del self.all_data["tw"]
        self.assertIn("tw: missing cutoff table", UPDATE.validate_cutoff_data(self.all_data))

    def test_rejects_missing_title_boundary(self):
        del self.all_data["eu"]["cutoffs"]["p999"]["all"]["quantileMinValue"]
        self.assertIn("eu: missing top-0.1% score", UPDATE.validate_cutoff_data(self.all_data))

    def test_rejects_partial_benchmark_coverage(self):
        benchmarks = {
            region: {101: 17, 102: 17} for region in UPDATE.REGIONS
        }
        del benchmarks["kr"][102]
        errors = UPDATE.validate_benchmarks(self.all_data, benchmarks, self.dungeons)
        self.assertEqual(["kr: missing dungeon benchmarks [102]"], errors)

    def test_accepts_complete_dataset(self):
        benchmarks = {
            region: {101: 17, 102: 17} for region in UPDATE.REGIONS
        }
        self.assertEqual([], UPDATE.validate_cutoff_data(self.all_data))
        self.assertEqual(
            [], UPDATE.validate_benchmarks(self.all_data, benchmarks, self.dungeons)
        )

    def test_partial_api_failure_preserves_existing_file(self):
        current_season = season(
            "season-mn-1",
            {region: "2026-03-25T04:00:00Z" for region in UPDATE.REGIONS},
            {region: "2026-08-19T23:00:00Z" for region in UPDATE.REGIONS},
            101,
        )
        payloads = dict(self.all_data)
        payloads["tw"] = {}

        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir) / "CutoffData.lua"
            output.write_text("known-good", encoding="utf-8")
            with (
                patch.object(UPDATE, "OUTPUT_FILE", str(output)),
                patch.object(UPDATE, "fetch_static_data", return_value={"seasons": [current_season]}),
                patch.object(UPDATE, "fetch_cutoffs", side_effect=lambda region, _season: payloads[region]),
                self.assertRaises(SystemExit),
            ):
                UPDATE.main()
            self.assertEqual("known-good", output.read_text(encoding="utf-8"))


if __name__ == "__main__":
    main()
