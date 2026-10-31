import struct
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import export_placements as ep  # noqa: E402

HEADER = ("guid\tentry\tmap\tscript_name\t" + "\t".join(ep.PLACEMENT) + "\trevision\tsaved_at\t"
          + "\t".join("base_" + c for c in ep.PLACEMENT) + "\tbase_command\tbase_captured_at")


def line(guid, verified, base, script="worldforged_pickup", revision=1, entry=90387, map_id=1,
         command="pitch"):
    base_fields = ["NULL"] * 8 if base is None else [repr(v) for v in base]
    tail = ["NULL", "NULL"] if base is None else [command, "2026-10-28 12:00:00"]
    return "\t".join([str(guid), str(entry), str(map_id), script, *[repr(v) for v in verified],
                      str(revision), "2026-10-28 12:05:00", *base_fields, *tail])


BASE = (-8913.2333984375, -120.5, 82.12000274658203, 1.5, 0.0, 0.0, 0.6816387772560120, 0.7316888570785522)
MOVED = (-8913.2333984375, -120.5, 82.12000274658203, 1.5,
         0.0284985, -0.0265590, 0.6810453, 0.7310514)


class Float32Text(unittest.TestCase):
    def test_round_trips_as_float32(self):
        for value in (-8913.2333984375, 0.1, 1e-8, 82.12000274658203, 0.0, -0.0265590):
            text = ep.float32_text(value)
            want = struct.unpack("<f", struct.pack("<f", value))[0]
            self.assertEqual(struct.unpack("<f", struct.pack("<f", float(text)))[0], want, text)

    def test_is_short(self):
        self.assertEqual(ep.float32_text(0.5), "0.5")
        self.assertEqual(ep.float32_text(82.0), "82.0")


class Parse(unittest.TestCase):
    def test_types_and_nulls(self):
        rows = ep.parse_batch("\n".join([HEADER, line(6940236, MOVED, None)]))
        self.assertEqual(rows[0]["guid"], 6940236)
        self.assertIsNone(rows[0]["base_position_x"])
        self.assertFalse(ep.has_baseline(rows[0]))

    def test_escapes(self):
        rows = ep.parse_batch("\n".join([HEADER, line(5, MOVED, BASE, script="a\\\\b")]))
        self.assertEqual(rows[0]["script_name"], "a\\b")

    def test_rejects_bad_field_count(self):
        with self.assertRaises(ep.ExportError):
            ep.parse_batch(HEADER + "\n1\t2")


class Render(unittest.TestCase):
    def setUp(self):
        self.rows = ep.parse_batch("\n".join([
            HEADER,
            line(6940236, MOVED, BASE, revision=2),
            line(6940237, BASE, BASE, command="save"),
            line(6940238, MOVED, None, script=""),
        ]))

    def test_sql_is_guarded_and_never_deletes(self):
        sql = ep.render_sql(self.rows, "T")
        self.assertIn("WHERE `guid` = 6940236 AND `id` = 90387 AND `map` = 1;", sql)
        self.assertEqual(sql.count("UPDATE `gameobject`"), 3)
        self.assertNotIn("DELETE", sql.upper().replace("-- ", ""))
        self.assertIn("nothing to change", sql)

    def test_toml_is_valid_and_disabled(self):
        text, skipped = ep.render_toml(self.rows, "T")
        doc = tomllib.loads(text)
        self.assertEqual(doc["format_version"], 1)
        self.assertEqual(doc["compatibility"]["schema_profile"], "acore-gameobject-v1")
        self.assertEqual(len(doc["correction"]), 1)
        c = doc["correction"][0]
        self.assertEqual(c["id"], "GP-6940236-r2")
        self.assertFalse(c["enabled"])
        self.assertEqual(c["target"], {"guid": 6940236, "entry": 90387, "map": 1,
                                       "script_name": "worldforged_pickup"})
        self.assertAlmostEqual(c["expected"][0]["rotation2"], BASE[6], places=6)
        self.assertAlmostEqual(c["final"]["rotation0"], MOVED[4], places=6)
        self.assertEqual(sorted(c["final"]), sorted(ep.PLACEMENT))
        self.assertEqual(len(skipped), 2)

    def test_toml_passes_the_correction_runner_validator_when_available(self):
        runner = Path(r"I:\Worldforged AFK Module")
        if not (runner / "wfpf" / "manifest.py").exists():
            self.skipTest("Worldforged Placement Fixes not present")
        sys.dont_write_bytecode = True
        sys.path.insert(0, str(runner))
        try:
            from wfpf import manifest
        finally:
            sys.path.remove(str(runner))
        text, _ = ep.render_toml(self.rows, "T")
        corrections, problems = manifest.parse_document(tomllib.loads(text), "export.toml")
        self.assertEqual(problems, [])
        self.assertEqual([c.id for c in corrections], ["GP-6940236-r2"])


class Cli(unittest.TestCase):
    def test_refuses_to_overwrite_and_filters_guid(self):
        with tempfile.TemporaryDirectory() as tmp:
            tsv = Path(tmp) / "in.tsv"
            tsv.write_text("\n".join([HEADER, line(1, MOVED, BASE), line(2, MOVED, BASE)]), encoding="utf-8")
            out = Path(tmp) / "out.sql"
            self.assertEqual(ep.main(["--input", str(tsv), "--sql", str(out), "--guid", "2"]), 0)
            self.assertIn("`guid` = 2 ", out.read_text())
            self.assertNotIn("`guid` = 1 ", out.read_text())
            self.assertEqual(ep.main(["--input", str(tsv), "--sql", str(out)]), 1)


if __name__ == "__main__":
    unittest.main()
