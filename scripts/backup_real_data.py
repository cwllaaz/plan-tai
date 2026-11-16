"""Create a verified, consistent backup of the real 计划台 SQLite database.

Safety rules:
- Never writes to the source database or its directory.
- Copies the live app.db + -wal + -shm to an isolated raw/ folder first.
- Uses sqlite3's online backup API on the *copy* to produce a single-file
  consistent snapshot (WAL included), then verifies integrity and contents.
- Writes MANIFEST.txt + SHA256SUMS.txt and marks the snapshot read-only.

Usage:
  python scripts/backup_real_data.py
  python scripts/backup_real_data.py --source-dir "C:/.../计划台/data" --dest-dir "D:/backups/x"
"""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import sqlite3
import sys
from datetime import datetime
from pathlib import Path

TABLES = ["projects", "plan_spans", "planner_tasks", "daily_notes", "change_log"]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def default_source_dir() -> Path:
    appdata = os.environ.get("APPDATA")
    if not appdata:
        raise SystemExit("APPDATA is not set; pass --source-dir explicitly")
    return Path(appdata) / "计划台" / "data"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-dir", type=Path, default=None)
    parser.add_argument("--dest-dir", type=Path, default=None)
    args = parser.parse_args()

    source_dir: Path = args.source_dir or default_source_dir()
    source_db = source_dir / "app.db"
    if not source_db.is_file():
        raise SystemExit(f"source database not found: {source_db}")

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    dest_dir: Path = args.dest_dir or (source_dir / "backups" / f"pre-cloud-sync-{stamp}")
    if dest_dir.exists() and any(dest_dir.iterdir()):
        raise SystemExit(f"destination already exists and is not empty: {dest_dir}")
    dest_dir.mkdir(parents=True, exist_ok=True)
    raw_dir = dest_dir / "raw"
    raw_dir.mkdir()

    # 1. Forensic raw copy — the live DB is only read, never opened by SQLite here.
    copied: list[tuple[str, int, str]] = []
    for suffix in ("", "-wal", "-shm"):
        src = source_dir / f"app.db{suffix}"
        if src.is_file():
            dst = raw_dir / f"app.db{suffix}"
            shutil.copy2(src, dst)
            copied.append((dst.name, dst.stat().st_size, sha256(dst)))
    # Preserve a forensic copy of the WAL before SQLite opens the copied DB
    # (opening a WAL database can checkpoint and remove the -wal sidecar).
    wal = raw_dir / "app.db-wal"
    if wal.is_file():
        forensic = raw_dir / "app.db-wal.forensic"
        shutil.copy2(wal, forensic)
        copied.append(
            (forensic.name, forensic.stat().st_size, sha256(forensic))
        )

    # 2. Consistent snapshot via online backup API on the copy.
    snapshot = dest_dir / "app.db"
    source_copy = raw_dir / "app.db"
    src_con = sqlite3.connect(str(source_copy))
    try:
        out_con = sqlite3.connect(str(snapshot))
        try:
            src_con.backup(out_con)
        finally:
            out_con.close()
    finally:
        src_con.close()

    # 3. Verify the snapshot.
    con = sqlite3.connect(f"file:{snapshot.as_posix()}?mode=ro", uri=True)
    try:
        con.execute("PRAGMA foreign_keys = ON")
        integrity = con.execute("PRAGMA integrity_check").fetchall()
        integrity_text = "; ".join(str(row[0]) for row in integrity)
        if integrity_text != "ok":
            raise SystemExit(f"snapshot integrity_check failed: {integrity_text}")
        user_version = con.execute("PRAGMA user_version").fetchone()[0]
        schema_version = None
        if con.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='settings'"
        ).fetchone():
            row = con.execute(
                "SELECT value FROM settings WHERE key='schema_version'"
            ).fetchone()
            schema_version = row[0] if row else None

        counts: dict[str, int | None] = {}
        maxima: dict[str, str | None] = {}
        existing = {
            row[0]
            for row in con.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ).fetchall()
        }
        for table in TABLES:
            if table not in existing:
                counts[table] = None
                maxima[table] = None
                continue
            counts[table] = con.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
            maxima[table] = con.execute(f"SELECT MAX(rowid) FROM {table}").fetchone()[0]
        live_counts = {}
        for table in ("projects", "plan_spans", "planner_tasks", "daily_notes"):
            if table in existing:
                live_counts[table] = con.execute(
                    f"SELECT COUNT(*) FROM {table} WHERE deleted_at IS NULL"
                ).fetchone()[0]
            else:
                live_counts[table] = None
        max_updated = {}
        for table in ("projects", "plan_spans", "planner_tasks", "daily_notes"):
            if table in existing:
                max_updated[table] = con.execute(
                    f"SELECT MAX(updated_at) FROM {table}"
                ).fetchone()[0]
            else:
                max_updated[table] = None
    finally:
        con.close()

    # 4. Clean snapshot sidecars (they may be created by the read-only open).
    for suffix in ("-wal", "-shm"):
        sidecar = dest_dir / f"app.db{suffix}"
        if sidecar.is_file() and sidecar.stat().st_size == 0:
            sidecar.unlink()

    # 5. Manifest + hashes (relative paths, so same-named files in raw/ differ).
    hashes = {
        p.relative_to(dest_dir).as_posix(): sha256(p)
        for p in sorted(dest_dir.rglob("*"))
        if p.is_file()
    }
    manifest_lines = [
        "计划台 V2.0 云同步 — 实施前真实数据安全备份",
        f"createdAtLocal: {datetime.now().astimezone().isoformat()}",
        f"sourceDir: {source_dir}",
        f"snapshot: {snapshot}",
        f"rawCopyDir: {raw_dir}",
        "",
        "== Verification ==",
        f"integrity_check: {integrity_text}",
        f"PRAGMA user_version: {user_version}",
        f"settings.schema_version: {schema_version}",
        "",
        "== Row counts (all rows, including soft-deleted) ==",
        *[f"{k}: {v}" for k, v in counts.items()],
        "",
        "== Live rows (deleted_at IS NULL) ==",
        *[f"{k}: {v}" for k, v in live_counts.items()],
        "",
        "== MAX(updated_at) ==",
        *[f"{k}: {v}" for k, v in max_updated.items()],
        "",
        "== Raw copies (taken before any SQLite open) ==",
        *[f"{name}: {size} bytes  sha256={digest}" for name, size, digest in copied],
        "NOTE: raw/app.db-wal may be checkpointed away when the copy is opened;",
        "      raw/app.db-wal.forensic preserves the original WAL bytes.",
        "",
        "Restore (manual, never automatic):",
        "  1) Close 计划台 completely.",
        "  2) Copy this app.db over %APPDATA%/计划台/data/app.db.",
        "  3) Delete app.db-wal and app.db-shm next to it.",
        "  4) Start 计划台 and verify data.",
        "",
        "NOTE: contains real user data. Never commit to Git.",
    ]
    (dest_dir / "MANIFEST.txt").write_text("\n".join(manifest_lines) + "\n", encoding="utf-8")
    (dest_dir / "SHA256SUMS.txt").write_text(
        "\n".join(f"{digest}  {name}" for name, digest in hashes.items()) + "\n",
        encoding="utf-8",
    )

    # 5. Protect the backup from accidental writes.
    for path in dest_dir.rglob("*"):
        if path.is_file():
            path.chmod(path.stat().st_mode & ~0o222)

    print(f"BACKUP_OK {dest_dir}")
    print("\n".join(manifest_lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
