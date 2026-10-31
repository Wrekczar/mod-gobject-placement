"""Export verified gameobject placements (mod-gobject-placement) for review.

Reads gobject_placement_verified + gobject_placement_baseline from the characters database (one
read-only SELECT through the mysql client) or from a saved `mysql --batch` result, and writes:

  --sql FILE   UPDATE statements for world.gameobject, guarded by guid + entry + map
  --toml FILE  "move" corrections in the Worldforged Placement Fixes manifest format (all disabled)

It never executes SQL against the world database and never writes to any database.

Examples:
  python export_placements.py --mysql H:\\CoA-Server\\DB\\mysql\\bin\\mysql.exe ^
      --defaults-file local\\afk-readonly.cnf --database acore_characters --sql out.sql --toml out.toml
  python export_placements.py --input placements.tsv --toml out.toml --guid 6940236
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import struct
import subprocess
import sys
from pathlib import Path

PLACEMENT = ("position_x", "position_y", "position_z", "orientation",
             "rotation0", "rotation1", "rotation2", "rotation3")
QUERY = (
    "SELECT v.guid, v.entry, v.map, v.script_name, "
    + ", ".join(f"CAST(v.{c} AS DOUBLE) AS {c}" for c in PLACEMENT) + ", "
    "v.revision, v.saved_at, "
    + ", ".join(f"CAST(b.{c} AS DOUBLE) AS base_{c}" for c in PLACEMENT) + ", "
    "b.captured_by_command AS base_command, b.captured_at AS base_captured_at "
    "FROM gobject_placement_verified v "
    "LEFT JOIN gobject_placement_baseline b ON b.guid = v.guid AND b.entry = v.entry AND b.map = v.map "
    "ORDER BY v.guid"
)
INTEGER_COLUMNS = ("guid", "entry", "map", "revision")
POSITION_TOLERANCE = 0.05
ANGLE_TOLERANCE = 0.01


class ExportError(Exception):
    pass


def float32_text(value: float) -> str:
    """Shortest decimal that reads back as the same 32-bit FLOAT the database stores."""
    target = struct.unpack("<f", struct.pack("<f", value))[0]
    for digits in range(6, 10):
        text = f"{target:.{digits}g}"
        if struct.unpack("<f", struct.pack("<f", float(text)))[0] == target:
            break
    if "e" not in text and "." not in text:
        text += ".0"
    return text


def _unescape(field: str) -> str | None:
    if field == "NULL":
        return None
    out, i = [], 0
    while i < len(field):
        ch = field[i]
        if ch == "\\" and i + 1 < len(field):
            out.append({"t": "\t", "n": "\n", "0": "\0", "\\": "\\"}.get(field[i + 1], field[i + 1]))
            i += 2
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def parse_batch(text: str) -> list[dict]:
    """Parse `mysql --batch` output (tab separated, header row, backslash escapes, NULL)."""
    lines = [line for line in text.splitlines() if line != ""]
    if not lines:
        return []
    header = lines[0].split("\t")
    rows = []
    for number, line in enumerate(lines[1:], start=2):
        fields = line.split("\t")
        if len(fields) != len(header):
            raise ExportError(f"line {number}: expected {len(header)} fields, got {len(fields)}")
        raw = dict(zip(header, (_unescape(f) for f in fields)))
        rows.append(_typed(raw, number))
    return rows


def _typed(raw: dict, number: int) -> dict:
    row = dict(raw)
    for key in INTEGER_COLUMNS:
        row[key] = int(raw[key])
    for key in PLACEMENT:
        row[key] = _finite(raw[key], key, number)
        base = raw.get("base_" + key)
        row["base_" + key] = None if base is None else _finite(base, "base_" + key, number)
    row["script_name"] = raw.get("script_name") or ""
    return row


def _finite(text: str | None, key: str, number: int) -> float:
    if text is None:
        raise ExportError(f"line {number}: {key} is NULL")
    value = float(text)
    if not math.isfinite(value):
        raise ExportError(f"line {number}: {key} is not finite")
    return value


def query_database(mysql: str, defaults_file: str, database: str) -> list[dict]:
    command = [mysql, f"--defaults-file={defaults_file}", "--batch", "--default-character-set=utf8mb4",
               "-e", QUERY, database]
    result = subprocess.run(command, capture_output=True, text=True, encoding="utf-8")
    if result.returncode != 0:
        raise ExportError(f"mysql exited with {result.returncode}: {result.stderr.strip()}")
    return parse_batch(result.stdout)


def has_baseline(row: dict) -> bool:
    return all(row["base_" + key] is not None for key in PLACEMENT)


def unchanged(row: dict) -> bool:
    if not has_baseline(row):
        return False
    for key in PLACEMENT:
        tolerance = POSITION_TOLERANCE if key.startswith("position") else ANGLE_TOLERANCE
        if abs(row[key] - row["base_" + key]) > tolerance:
            return False
    return True


def _assignments(row: dict, prefix: str = "") -> list[str]:
    return [f"{key} = {float32_text(row[prefix + key])}" for key in PLACEMENT]


def render_sql(rows: list[dict], generated: str) -> str:
    out = [
        f"-- mod-gobject-placement export, generated {generated}.",
        "-- Review before use. The exporter never runs this file. Stop the world server before applying,",
        "-- and back up the world database first. Each UPDATE only matches the same guid, entry and map.",
        "",
    ]
    for row in rows:
        out.append(f"-- spawn {row['guid']} entry {row['entry']} map {row['map']}"
                   f"{' script ' + row['script_name'] if row['script_name'] else ''}"
                   f": revision {row['revision']} saved {row['saved_at']}")
        if unchanged(row):
            out.append("-- (same as its baseline: nothing to change)")
        out.append("UPDATE `gameobject` SET " + ", ".join(_assignments(row))
                   + f" WHERE `guid` = {row['guid']} AND `id` = {row['entry']} AND `map` = {row['map']};")
        out.append("")
    return "\n".join(out)


def _toml_string(text: str) -> str:
    return json.dumps(text, ensure_ascii=False)


def _toml_state(row: dict, prefix: str) -> list[str]:
    return [f"{key} = {float32_text(row[prefix + key])}" for key in PLACEMENT]


def render_toml(rows: list[dict], generated: str) -> tuple[str, list[str]]:
    skipped = []
    out = [
        f"# mod-gobject-placement export, generated {generated}.",
        "# Every correction is disabled. Before enabling one, confirm its [[correction.expected]] block is the",
        "# placement the upstream database ships: it is the baseline captured the first time .gobject pitch,",
        "# roll or save touched the spawn, so an earlier .gobject move/turn would already be part of it.",
        "",
        "format_version = 1",
        "",
        "[compatibility]",
        'schema_profile = "acore-gameobject-v1"',
    ]
    for row in rows:
        if not has_baseline(row):
            skipped.append(f"spawn {row['guid']}: no baseline row, cannot state the expected placement")
            continue
        if unchanged(row):
            skipped.append(f"spawn {row['guid']}: verified placement equals its baseline")
            continue
        correction_id = "GP-{}-r{}".format(row["guid"], row["revision"])
        out += [
            "",
            "[[correction]]",
            f"id = {_toml_string(correction_id)}",
            'action = "move"',
            "enabled = false",
            "description = " + _toml_string(
                f"Spawn {row['guid']} (entry {row['entry']}): placement verified in game with .gobject save"),
            "provenance = " + _toml_string(
                f"mod-gobject-placement revision {row['revision']} saved {row['saved_at']}; baseline captured by "
                f".gobject {row['base_command']} at {row['base_captured_at']}; exported {generated}"),
            "",
            "[correction.target]",
            f"guid = {row['guid']}",
            f"entry = {row['entry']}",
            f"map = {row['map']}",
        ]
        if row["script_name"]:
            out.append(f"script_name = {_toml_string(row['script_name'])}")
        out += ["", "[[correction.expected]]", *_toml_state(row, "base_"),
                "", "[correction.final]", *_toml_state(row, "")]
    out.append("")
    return "\n".join(out), skipped


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--input", help="saved `mysql --batch` output of the export query")
    source.add_argument("--mysql", help="path to mysql.exe (runs one read-only SELECT)")
    parser.add_argument("--defaults-file", help="MySQL option file with credentials (with --mysql)")
    parser.add_argument("--database", help="characters database name (with --mysql)")
    parser.add_argument("--guid", type=int, action="append", help="only these spawn guids (repeatable)")
    parser.add_argument("--sql", help="write a standalone SQL correction file")
    parser.add_argument("--toml", help="write a Worldforged Placement Fixes manifest")
    parser.add_argument("--print-query", action="store_true", help="print the SELECT and exit")
    args = parser.parse_args(argv)

    if args.print_query:
        print(QUERY + ";")
        return 0
    if not args.sql and not args.toml:
        parser.error("give --sql and/or --toml")
    try:
        if args.input:
            rows = parse_batch(Path(args.input).read_text(encoding="utf-8"))
        else:
            if not args.defaults_file or not args.database:
                parser.error("--mysql needs --defaults-file and --database")
            rows = query_database(args.mysql, args.defaults_file, args.database)
    except (ExportError, OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    if args.guid:
        wanted = set(args.guid)
        missing = wanted - {row["guid"] for row in rows}
        for guid in sorted(missing):
            print(f"warning: spawn {guid} has no verified placement", file=sys.stderr)
        rows = [row for row in rows if row["guid"] in wanted]

    generated = dt.datetime.now().astimezone().isoformat(timespec="seconds")
    for target in (args.sql, args.toml):
        if target and Path(target).exists():
            print(f"error: {target} exists; not overwriting", file=sys.stderr)
            return 1
    if args.sql:
        Path(args.sql).write_text(render_sql(rows, generated), encoding="utf-8", newline="\n")
    if args.toml:
        text, skipped = render_toml(rows, generated)
        Path(args.toml).write_text(text, encoding="utf-8", newline="\n")
        for reason in skipped:
            print(f"skipped: {reason}", file=sys.stderr)
    print(f"{len(rows)} verified placement(s) exported", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
