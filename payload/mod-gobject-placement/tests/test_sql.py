"""Database-level tests on a DISPOSABLE MySQL (never the AFK database).

Set GP_TEST_MYSQL (path to mysql.exe) and GP_TEST_PORT (a throwaway server; root without password on
127.0.0.1). The tests create and drop the schemas gp_test_world and gp_test_characters only.

The statements below are the ones GObjectPlacementCommands.cpp sends, with the same text and order.
"""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import export_placements as ep  # noqa: E402

MYSQL = os.environ.get("GP_TEST_MYSQL")
PORT = os.environ.get("GP_TEST_PORT")
WORLD, CHARS = "gp_test_world", "gp_test_characters"
COLUMNS = ("guid, entry, map, script_name, position_x, position_y, position_z, orientation, "
           "rotation0, rotation1, rotation2, rotation3")


def sql(statement, database=None, stdin=None):
    command = [MYSQL, "-h127.0.0.1", f"-P{PORT}", "-uroot", "--batch", "--skip-column-names",
               "--default-character-set=utf8mb4"]
    if statement is not None:
        command += ["-e", statement]
    if database:
        command.append(database)
    result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", input=stdin)
    if result.returncode:
        raise AssertionError(result.stderr)
    return [line.split("\t") for line in result.stdout.splitlines()]


def source(path, database):
    sql(None, database, stdin=Path(path).read_text(encoding="utf-8"))


def values(p):
    return ", ".join(str(v) if not isinstance(v, str) else f"'{v}'" for v in p)


def baseline_once(p, command, account):
    sql(f"INSERT IGNORE INTO gobject_placement_baseline ({COLUMNS}, captured_by_command, captured_by_account) "
        f"VALUES ({values(p)}, '{command}', {account})", CHARS)


def save(p, account):
    guid = p[0]
    sql("START TRANSACTION; "
        f"INSERT IGNORE INTO gobject_placement_baseline ({COLUMNS}, captured_by_command, captured_by_account) "
        f"VALUES ({values(p)}, 'save', {account}); "
        f"INSERT INTO gobject_placement_verified ({COLUMNS}, saved_by_account) VALUES ({values(p)}, {account}) "
        "ON DUPLICATE KEY UPDATE entry = VALUES(entry), map = VALUES(map), script_name = VALUES(script_name), "
        "position_x = VALUES(position_x), position_y = VALUES(position_y), position_z = VALUES(position_z), "
        "orientation = VALUES(orientation), rotation0 = VALUES(rotation0), rotation1 = VALUES(rotation1), "
        "rotation2 = VALUES(rotation2), rotation3 = VALUES(rotation3), "
        "saved_by_account = VALUES(saved_by_account), saved_at = CURRENT_TIMESTAMP, revision = revision + 1; "
        f"INSERT INTO gobject_placement_history ({COLUMNS}, saved_by_account, saved_at, revision) "
        f"SELECT {COLUMNS}, saved_by_account, saved_at, revision FROM gobject_placement_verified WHERE guid = {guid}; "
        "COMMIT;", CHARS)


def rotate(guid, q):
    sql(f"UPDATE gameobject SET rotation0 = {q[0]}, rotation1 = {q[1]}, rotation2 = {q[2]}, rotation3 = {q[3]} "
        f"WHERE guid = {guid}", WORLD)


@unittest.skipUnless(MYSQL and PORT, "set GP_TEST_MYSQL and GP_TEST_PORT to a disposable MySQL")
class Database(unittest.TestCase):
    def setUp(self):
        for db in (WORLD, CHARS):
            sql(f"DROP DATABASE IF EXISTS {db}; CREATE DATABASE {db} CHARACTER SET utf8mb4 "
                "COLLATE utf8mb4_unicode_ci")
        core = os.environ.get("GP_TEST_CORE", r"I:\gobject-placement-dev\src")
        source(Path(core) / "data/sql/base/db_world/gameobject.sql", WORLD)
        source(Path(core) / "data/sql/base/db_world/command.sql", WORLD)
        for path in sorted((ROOT / "data/sql/db-characters").glob("*.sql")):
            source(path, CHARS)
        sql("INSERT INTO gameobject (guid, id, map, zoneId, areaId, position_x, position_y, position_z, orientation, "
            "rotation0, rotation1, rotation2, rotation3, spawntimesecs, ScriptName, VerifiedBuild, Comment) VALUES "
            "(6940236, 90387, 1, 331, 414, 100.5, 200.25, 30.125, 1.5, 0, 0, 0.6816388, 0.7316889, 300, "
            "'worldforged_pickup', 12340, 'hand placed'), "
            "(6940237, 90387, 1, 331, 414, 101.5, 201.25, 31.125, 1.5, 0, 0, 0.6816388, 0.7316889, 300, "
            "'worldforged_pickup', 12340, 'same entry, other spawn')", WORLD)

    def tearDown(self):
        for db in (WORLD, CHARS):
            sql(f"DROP DATABASE IF EXISTS {db}")

    def test_migrations_rerun_cleanly(self):
        for path in sorted((ROOT / "data/sql/db-characters").glob("*.sql")):
            source(path, CHARS)
        for _ in range(2):
            for path in sorted((ROOT / "data/sql/db-world").glob("*.sql")):
                source(path, WORLD)
        rows = sql("SELECT name, security FROM command WHERE name LIKE 'gobject %' AND name IN "
                   "('gobject pitch', 'gobject roll', 'gobject save', 'gobject turn') ORDER BY name", WORLD)
        self.assertEqual(rows, [["gobject pitch", "3"], ["gobject roll", "3"], ["gobject save", "3"],
                                ["gobject turn", "3"]])

    def test_rotation_update_touches_only_rotation_of_one_spawn(self):
        ours = "SELECT * FROM gameobject WHERE guid IN (6940236, 6940237) ORDER BY guid"
        before, total = sql(ours, WORLD), sql("SELECT COUNT(*), SUM(CRC32(CONCAT_WS(',', guid, rotation0, "
                                              "rotation1, rotation2, rotation3))) FROM gameobject "
                                              "WHERE guid <> 6940236", WORLD)
        rotate(6940236, (0.0284985, -0.026559, 0.6810453, 0.7310514))
        after = sql(ours, WORLD)
        self.assertEqual(sql("SELECT COUNT(*), SUM(CRC32(CONCAT_WS(',', guid, rotation0, rotation1, rotation2, "
                             "rotation3))) FROM gameobject WHERE guid <> 6940236", WORLD), total,
                         "no other spawn's rotation changed")
        self.assertEqual(after[1], before[1], "the other spawn of the same entry is unchanged")
        changed = [i for i, (a, b) in enumerate(zip(before[0], after[0])) if a != b]
        names = [r[0] for r in sql("SELECT COLUMN_NAME FROM information_schema.COLUMNS WHERE "
                                   f"TABLE_SCHEMA = '{WORLD}' AND TABLE_NAME = 'gameobject' ORDER BY ORDINAL_POSITION")]
        self.assertEqual([names[i] for i in changed], ["rotation0", "rotation1", "rotation2", "rotation3"])
        self.assertEqual(after[0][names.index("ScriptName")], "worldforged_pickup")
        self.assertEqual(after[0][names.index("Comment")], "hand placed")

    def test_baseline_is_kept_and_saves_keep_history(self):
        original = (6940236, 90387, 1, "worldforged_pickup", 100.5, 200.25, 30.125, 1.5,
                    0, 0, 0.6816388, 0.7316889)
        baseline_once(original, "pitch", 7)
        tilted = original[:8] + (0.0284985, -0.026559, 0.6810453, 0.7310514)
        baseline_once(tilted, "roll", 7)
        save(tilted, 7)
        retilted = original[:8] + (0.05, -0.05, 0.68, 0.73)
        save(retilted, 8)

        base = sql("SELECT captured_by_command, rotation0 FROM gobject_placement_baseline WHERE guid = 6940236",
                   CHARS)
        self.assertEqual(base, [["pitch", "0"]], "the first touch wins and is never overwritten")
        verified = sql("SELECT revision, rotation0, saved_by_account FROM gobject_placement_verified", CHARS)
        self.assertEqual(verified, [["2", "0.05", "8"]])
        history = sql("SELECT revision, rotation0 FROM gobject_placement_history WHERE guid = 6940236 "
                      "ORDER BY revision", CHARS)
        self.assertEqual(history, [["1", "0.0284985"], ["2", "0.05"]])

    def test_save_of_unchanged_spawn_records_itself_as_baseline(self):
        p = (6940237, 90387, 1, "worldforged_pickup", 101.5, 201.25, 31.125, 1.5, 0, 0, 0.6816388, 0.7316889)
        save(p, 7)
        self.assertEqual(sql("SELECT captured_by_command FROM gobject_placement_baseline", CHARS), [["save"]])

    def test_script_name_is_escaped(self):
        p = (1, 2, 0, "it\\'s", 0, 0, 0, 0, 0, 0, 0, 1)
        save(p, 1)
        self.assertEqual(sql("SELECT script_name FROM gobject_placement_verified", CHARS), [["it's"]])

    def test_exporter_reads_live_tables_and_writes_reviewable_files(self):
        original = (6940236, 90387, 1, "worldforged_pickup", 100.5, 200.25, 30.125, 1.5,
                    0, 0, 0.6816388, 0.7316889)
        baseline_once(original, "pitch", 7)
        save(original[:8] + (0.0284985, -0.026559, 0.6810453, 0.7310514), 7)
        with tempfile.TemporaryDirectory() as tmp:
            option_file = Path(tmp) / "client.cnf"
            option_file.write_text(f"[client]\nhost=127.0.0.1\nport={PORT}\nuser=root\n", encoding="ascii")
            out_sql, out_toml = Path(tmp) / "fix.sql", Path(tmp) / "fix.toml"
            code = ep.main(["--mysql", MYSQL, "--defaults-file", str(option_file), "--database", CHARS,
                            "--sql", str(out_sql), "--toml", str(out_toml)])
            self.assertEqual(code, 0)
            self.assertIn("GP-6940236-r1", out_toml.read_text(encoding="utf-8"))

            source(out_sql, WORLD)
            row = sql("SELECT ABS(rotation0 - 0.0284985) < 1e-6 AND ABS(rotation1 + 0.026559) < 1e-6 AND "
                      "ABS(rotation2 - 0.6810453) < 1e-6 AND ABS(rotation3 - 0.7310514) < 1e-6, ScriptName "
                      "FROM gameobject WHERE guid = 6940236", WORLD)
            self.assertEqual(row, [["1", "worldforged_pickup"]])
            other = sql("SELECT rotation0 FROM gameobject WHERE guid = 6940237", WORLD)
            self.assertEqual(other, [["0"]])


if __name__ == "__main__":
    unittest.main()
