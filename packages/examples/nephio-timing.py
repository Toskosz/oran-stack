#!/usr/bin/env python3
"""Local SQLite store for Nephio deploy wait timings.

Used by deploy-oran-lab.sh so a long wait can be compared against the mean
and p90 of previous successful runs of the same package/step.

  python3 packages/examples/nephio-timing.py summary
  python3 packages/examples/nephio-timing.py ingest-log
"""
from __future__ import annotations

import argparse
import math
import re
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DB = ROOT / ".nephio-timing.sqlite"
DEFAULT_LOG = ROOT / ".nephio-deploy.log"

SCHEMA = """
CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  workspace TEXT NOT NULL,
  package TEXT NOT NULL DEFAULT '',
  step TEXT NOT NULL,
  recorded_at TEXT NOT NULL,
  elapsed_s INTEGER NOT NULL,
  status TEXT NOT NULL,
  force_fresh INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_events_step
  ON events(package, step, status);
"""


def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def connect(db: Path) -> sqlite3.Connection:
    db.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db))
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    conn.executescript(SCHEMA)
    return conn


def parse_bool(value: str) -> int:
    return 1 if str(value).lower() in {"1", "true", "yes"} else 0


def stats_for(conn: sqlite3.Connection, package: str, step: str) -> dict | None:
    rows = conn.execute(
        """
        SELECT elapsed_s FROM events
        WHERE package = ? AND step = ? AND status = 'ok'
        ORDER BY elapsed_s
        """,
        (package, step),
    ).fetchall()
    values = [int(r[0]) for r in rows if r[0] is not None]
    if not values:
        return None
    n = len(values)
    mean = sum(values) / n
    p90_index = min(n - 1, max(0, math.ceil(0.9 * n) - 1))
    return {
        "n": n,
        "mean": mean,
        "p90": values[p90_index],
        "min": values[0],
        "max": values[-1],
    }


def fmt_secs(value: float) -> str:
    secs = int(round(value))
    if secs < 60:
        return f"{secs}s"
    minutes, rem = divmod(secs, 60)
    if minutes < 60:
        return f"{minutes}m{rem:02d}s" if rem else f"{minutes}m"
    hours, minutes = divmod(minutes, 60)
    return f"{hours}h{minutes:02d}m"


def hint_text(stats: dict | None, elapsed: int) -> str:
    if stats is None:
        return "no baseline yet"
    note = (
        f"typical {fmt_secs(stats['mean'])} mean / {fmt_secs(stats['p90'])} p90 "
        f"(n={stats['n']})"
    )
    if elapsed <= 0:
        return note
    slow = elapsed > stats["p90"] * 1.2 and elapsed > stats["mean"] + 45
    if stats["n"] == 1:
        slow = elapsed > stats["mean"] * 2 and elapsed > 120
    if slow:
        return f"SLOWER THAN USUAL vs {note}"
    return note


def cmd_record(args: argparse.Namespace) -> int:
    conn = connect(Path(args.db))
    conn.execute(
        """
        INSERT INTO events(
          workspace, package, step, recorded_at, elapsed_s, status, force_fresh
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        (
            args.workspace,
            args.package,
            args.step,
            utcnow(),
            int(args.elapsed),
            args.status,
            parse_bool(args.force_fresh),
        ),
    )
    conn.commit()
    conn.close()
    return 0


def cmd_hint(args: argparse.Namespace) -> int:
    conn = connect(Path(args.db))
    stats = stats_for(conn, args.package, args.step)
    conn.close()
    sys.stdout.write(hint_text(stats, int(args.elapsed)) + "\n")
    return 0


def cmd_summary(args: argparse.Namespace) -> int:
    conn = connect(Path(args.db))
    rows = conn.execute(
        """
        SELECT package, step, COUNT(*),
               AVG(elapsed_s), MIN(elapsed_s), MAX(elapsed_s)
        FROM events
        WHERE status = 'ok'
        GROUP BY package, step
        ORDER BY package, step
        """
    ).fetchall()
    if not rows:
        print("no timing samples yet")
        conn.close()
        return 0
    print(
        f"{'package':<16} {'step':<42} {'n':>3} {'mean':>8} {'p90':>8} "
        f"{'min':>8} {'max':>8}"
    )
    for package, step, n, mean, min_s, max_s in rows:
        stats = stats_for(conn, package, step) or {}
        print(
            f"{package:<16} {step:<42} {int(n):>3} "
            f"{fmt_secs(mean):>8} {fmt_secs(stats.get('p90', mean)):>8} "
            f"{fmt_secs(min_s):>8} {fmt_secs(max_s):>8}"
        )
    latest = conn.execute(
        "SELECT workspace, recorded_at, package, step, elapsed_s, status "
        "FROM events ORDER BY id DESC LIMIT 20"
    ).fetchall()
    if latest:
        print("\nlatest samples:")
        for workspace, recorded_at, package, step, elapsed_s, status in latest:
            pkg = package or "(run)"
            print(
                f"  {recorded_at} {status:<7} {pkg}/{step} "
                f"{fmt_secs(elapsed_s)} ({workspace})"
            )
    failed = conn.execute(
        "SELECT workspace, package, step, elapsed_s FROM events "
        "WHERE status != 'ok' ORDER BY id"
    ).fetchall()
    if failed:
        print("\nfailed samples:")
        for workspace, package, step, elapsed_s in failed:
            pkg = package or "(run)"
            print(f"  {pkg}/{step} {fmt_secs(elapsed_s)} ({workspace})")
    conn.close()
    return 0


WAIT_START_RE = re.compile(r"^==> Waiting for (.+)$")
STILL_RE = re.compile(r"^==> still waiting: (.+) \((\d+)s left\)")
PACKAGE_RE = re.compile(r"^==== (\S+) ====$")
FOUND_RE = re.compile(r"^==> Found (.+)$")
READY_RE = re.compile(r"^==> (.+): ready$")
OBSERVED_RE = re.compile(r"^==> Config Sync observed source commit")
APPLIED_RE = re.compile(r"^==> Config Sync applied commit")
TIMEOUT_RE = re.compile(r"^timed out waiting")
ERROR_RE = re.compile(r"^ERROR:")
SYNC_AT_RE = re.compile(r'Scheduled one-time sync for "blueprints" at (.+)$')


def normalize_wait(text: str) -> str:
    text = text.strip()
    if text.startswith("Config Sync to observe a new source commit"):
        return "Config Sync new source commit"
    if text.startswith("Config Sync to apply "):
        return "Config Sync apply"
    if text.startswith("Config Sync apply"):
        return "Config Sync apply"
    return text


def cmd_ingest_log(args: argparse.Namespace) -> int:
    log_path = Path(args.log)
    if not log_path.is_file():
        print(f"log not found: {log_path}", file=sys.stderr)
        return 1
    timeout = int(args.timeout)
    workspace = args.workspace or ""
    package = ""
    step = ""
    elapsed = None
    force_fresh = parse_bool(args.force_fresh)
    inserted = 0
    started_at = None
    run_failed = False
    conn = connect(Path(args.db))

    def close_step(status: str) -> None:
        nonlocal step, elapsed, inserted
        if not step or elapsed is None:
            step = ""
            elapsed = None
            return
        if not workspace:
            step = ""
            elapsed = None
            return
        conn.execute(
            """
            INSERT INTO events(
              workspace, package, step, recorded_at, elapsed_s, status, force_fresh
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (workspace, package, step, utcnow(), int(elapsed), status, force_fresh),
        )
        inserted += 1
        step = ""
        elapsed = None

    for raw in log_path.read_text(errors="replace").splitlines():
        line = raw.strip()
        pkg = PACKAGE_RE.match(line)
        if pkg:
            close_step("ok")
            package = pkg.group(1)
            continue
        sync_at = SYNC_AT_RE.match(line)
        if sync_at and started_at is None:
            started_at = datetime.fromisoformat(sync_at.group(1))
        if not workspace:
            match = re.search(r"workspace (deploy-\d+-\d+)", line)
            if match:
                workspace = match.group(1)
                conn.execute("DELETE FROM events WHERE workspace = ?", (workspace,))
        started = WAIT_START_RE.match(line)
        if started:
            close_step("ok")
            step = normalize_wait(started.group(1))
            elapsed = None
            continue
        still = STILL_RE.match(line)
        if still:
            step = normalize_wait(still.group(1))
            elapsed = max(0, timeout - int(still.group(2)))
            continue
        if OBSERVED_RE.match(line):
            step = "Config Sync new source commit"
            close_step("ok")
            continue
        if APPLIED_RE.match(line):
            step = step or "Config Sync apply"
            if step != "Config Sync apply":
                step = "Config Sync apply"
            close_step("ok")
            continue
        found = FOUND_RE.match(line)
        if found:
            step = found.group(1)
            close_step("ok")
            continue
        ready = READY_RE.match(line)
        if ready:
            step = ready.group(1)
            close_step("ok")
            continue
        if TIMEOUT_RE.match(line) or ERROR_RE.match(line):
            run_failed = True
            close_step("failed")
            continue

    if started_at and workspace:
        ended = datetime.fromtimestamp(log_path.stat().st_mtime, tz=started_at.tzinfo)
        run_elapsed = max(0, int((ended - started_at).total_seconds()))
        conn.execute(
            """
            INSERT INTO events(
              workspace, package, step, recorded_at, elapsed_s, status, force_fresh
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (
                workspace,
                "",
                "run",
                utcnow(),
                run_elapsed,
                "failed" if run_failed else "ok",
                force_fresh,
            ),
        )
        inserted += 1

    conn.commit()
    conn.close()
    print(f"ingested {inserted} samples into {args.db} (workspace={workspace or 'unknown'})")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", default=str(DEFAULT_DB))
    sub = parser.add_subparsers(dest="cmd", required=True)

    record = sub.add_parser("record", help="store one completed wait")
    record.add_argument("--workspace", required=True)
    record.add_argument("--package", default="")
    record.add_argument("--step", required=True)
    record.add_argument("--elapsed", required=True)
    record.add_argument("--status", default="ok")
    record.add_argument("--force-fresh", default="false")
    record.set_defaults(func=cmd_record)

    hint = sub.add_parser("hint", help="print typical duration for a wait")
    hint.add_argument("--package", default="")
    hint.add_argument("--step", required=True)
    hint.add_argument("--elapsed", default="0")
    hint.set_defaults(func=cmd_hint)

    summary = sub.add_parser("summary", help="print mean/p90 by package step")
    summary.set_defaults(func=cmd_summary)

    ingest = sub.add_parser("ingest-log", help="seed samples from a deploy log")
    ingest.add_argument("--log", default=str(DEFAULT_LOG))
    ingest.add_argument("--timeout", default="900")
    ingest.add_argument("--workspace", default="")
    ingest.add_argument("--force-fresh", default="true")
    ingest.set_defaults(func=cmd_ingest_log)
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
