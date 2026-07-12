#!/usr/bin/env python3
"""Read-only probe for recent NetEase Music song IDs and local metadata."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


HOME = Path.home()
DEFAULT_CACHE_DIR = HOME / "Library/Containers/com.netease.163music/Data/Library/Caches/online_play_cache"
DEFAULT_DB_PATH = HOME / "Library/Containers/com.netease.163music/Data/Documents/storage/sqlite_storage.sqlite3"
SONG_ID_PATTERN = re.compile(r"^(\d+)-_-_\d+-_-_[^.]+\.info$")
METADATA_KEYS = {
    "title": ("title", "name", "trackName", "songName"),
    "artist": ("artist", "artists", "artistName", "ar", "singer", "author"),
    "album": ("album", "albumName", "al"),
    "duration": ("duration", "dt", "durationMs", "length"),
}


@dataclass(frozen=True)
class CacheHit:
    song_id: str
    path: Path
    mtime: float


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Print recent NetEase Music song IDs from online_play_cache and metadata from sqlite_storage.sqlite3."
    )
    parser.add_argument("--minutes", type=int, default=30, help="Look back this many minutes for .info files.")
    parser.add_argument("--cache-dir", type=Path, default=DEFAULT_CACHE_DIR, help="NetEase online_play_cache path.")
    parser.add_argument("--db", type=Path, default=DEFAULT_DB_PATH, help="NetEase sqlite_storage.sqlite3 path.")
    parser.add_argument("--limit", type=int, default=20, help="Maximum recent cache entries to print.")
    return parser.parse_args()


def recent_cache_hits(cache_dir: Path, minutes: int) -> list[CacheHit]:
    cutoff = dt.datetime.now().timestamp() - minutes * 60
    hits: list[CacheHit] = []

    if not cache_dir.is_dir():
        return hits

    for path in cache_dir.iterdir():
        if not path.is_file() or path.suffix != ".info":
            continue

        match = SONG_ID_PATTERN.match(path.name)
        if not match:
            continue

        try:
            mtime = path.stat().st_mtime
        except OSError:
            continue

        if mtime >= cutoff:
            hits.append(CacheHit(song_id=match.group(1), path=path, mtime=mtime))

    return sorted(hits, key=lambda item: item.mtime, reverse=True)


def sqlite_rows_for_song_id(db_path: Path, song_id: str) -> list[dict[str, Any]]:
    if not db_path.is_file():
        return []

    rows: list[dict[str, Any]] = []
    uri = f"file:{db_path}?mode=ro"

    try:
        with sqlite3.connect(uri, uri=True) as connection:
            connection.row_factory = sqlite3.Row
            tables = connection.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
            ).fetchall()

            for table_row in tables:
                table = str(table_row["name"])
                columns = connection.execute(f'PRAGMA table_info("{table}")').fetchall()
                column_names = [str(column["name"]) for column in columns]
                if not column_names:
                    continue

                exact_clauses = [
                    f'CAST("{column}" AS TEXT) = ?'
                    for column in column_names
                    if column.lower() in {"id", "tid", "songid", "song_id", "trackid", "track_id"}
                ]
                text_clauses = [
                    f'CAST("{column}" AS TEXT) LIKE ?'
                    for column in column_names
                    if column.lower() in {
                        "jsonstr",
                        "json",
                        "data",
                        "track",
                        "content",
                        "value",
                        "request",
                        "response",
                    }
                ]

                clauses = exact_clauses + text_clauses
                if not clauses:
                    continue

                params = [song_id] * len(exact_clauses) + [f"%{song_id}%"] * len(text_clauses)
                query = f'SELECT * FROM "{table}" WHERE {" OR ".join(clauses)} LIMIT 5'

                try:
                    for row in connection.execute(query, params):
                        values = dict(row)
                        values["_table"] = table
                        rows.append(values)
                except sqlite3.Error:
                    continue
    except sqlite3.Error:
        return []

    return rows


def strings_context_for_song_id(db_path: Path, song_id: str) -> str | None:
    strings_bin = shutil.which("strings")
    if not strings_bin or not db_path.is_file():
        return None

    try:
        result = subprocess.run(
            [strings_bin, str(db_path)],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None

    lines = result.stdout.splitlines()
    for index, line in enumerate(lines):
        if song_id in line:
            start = max(0, index - 3)
            end = min(len(lines), index + 4)
            return " | ".join(compact_text(item) for item in lines[start:end] if compact_text(item))

    return None


def collect_json_objects(value: Any) -> list[Any]:
    objects: list[Any] = []

    if isinstance(value, (dict, list)):
        objects.append(value)
        return objects

    if not isinstance(value, str):
        return objects

    text = value.strip()
    if not text:
        return objects

    for candidate in (text, text.replace('\\"', '"')):
        if not candidate.startswith(("{", "[")):
            continue
        try:
            objects.append(json.loads(candidate))
        except json.JSONDecodeError:
            continue

    return objects


def walk_json(value: Any) -> list[Any]:
    values = [value]
    if isinstance(value, dict):
        for child in value.values():
            values.extend(walk_json(child))
    elif isinstance(value, list):
        for child in value:
            values.extend(walk_json(child))
    return values


def first_present(mapping: dict[str, Any], keys: tuple[str, ...]) -> Any | None:
    lower_lookup = {key.lower(): key for key in mapping.keys()}
    for key in keys:
        actual = lower_lookup.get(key.lower())
        if actual is not None:
            value = mapping.get(actual)
            if value not in (None, "", []):
                return value
    return None


def normalize_people(value: Any) -> str | None:
    if value in (None, "", []):
        return None
    if isinstance(value, str):
        return compact_text(value)
    if isinstance(value, dict):
        name = first_present(value, ("name", "artistName", "title"))
        return compact_text(str(name)) if name else None
    if isinstance(value, list):
        names = [normalize_people(item) for item in value]
        names = [name for name in names if name]
        return ", ".join(names) if names else None
    return compact_text(str(value))


def normalize_album(value: Any) -> str | None:
    if value in (None, "", []):
        return None
    if isinstance(value, str):
        return compact_text(value)
    if isinstance(value, dict):
        name = first_present(value, ("name", "albumName", "title"))
        return compact_text(str(name)) if name else None
    return compact_text(str(value))


def normalize_duration(value: Any) -> str | None:
    if value in (None, ""):
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return compact_text(str(value))

    if number > 10_000:
        seconds = number / 1000
    else:
        seconds = number

    if seconds < 0 or seconds > 2 * 60 * 60:
        return None

    minutes = int(seconds // 60)
    remaining = int(round(seconds % 60))
    return f"{minutes}:{remaining:02d}"


def compact_text(value: str) -> str:
    return " ".join(value.replace("\x00", " ").split())


def extract_metadata(rows: list[dict[str, Any]]) -> tuple[dict[str, str], str | None]:
    metadata: dict[str, str] = {}
    source_table: str | None = None

    for row in rows:
        if source_table is None:
            source_table = str(row.get("_table", ""))

        row_candidates: list[dict[str, Any]] = []
        row_candidates.append({key: value for key, value in row.items() if not key.startswith("_")})

        for value in row.values():
            for parsed in collect_json_objects(value):
                for item in walk_json(parsed):
                    if isinstance(item, dict):
                        row_candidates.append(item)

        for candidate in row_candidates:
            if "title" not in metadata:
                title = first_present(candidate, METADATA_KEYS["title"])
                if title:
                    metadata["title"] = compact_text(str(title))

            if "artist" not in metadata:
                artist = first_present(candidate, METADATA_KEYS["artist"])
                normalized = normalize_people(artist)
                if normalized:
                    metadata["artist"] = normalized

            if "album" not in metadata:
                album = first_present(candidate, METADATA_KEYS["album"])
                normalized = normalize_album(album)
                if normalized:
                    metadata["album"] = normalized

            if "duration" not in metadata:
                duration = first_present(candidate, METADATA_KEYS["duration"])
                normalized = normalize_duration(duration)
                if normalized:
                    metadata["duration"] = normalized

            if {"title", "artist", "album", "duration"}.issubset(metadata.keys()):
                return metadata, source_table

    return metadata, source_table


def format_mtime(timestamp: float) -> str:
    return dt.datetime.fromtimestamp(timestamp).strftime("%Y-%m-%d %H:%M")


def print_hit(hit: CacheHit, db_path: Path, cache_dir: Path) -> None:
    rows = sqlite_rows_for_song_id(db_path, hit.song_id)
    metadata, source_table = extract_metadata(rows)
    strings_context = None if metadata else strings_context_for_song_id(db_path, hit.song_id)

    try:
        cache_path = hit.path.relative_to(cache_dir.parent)
    except ValueError:
        cache_path = hit.path

    print(f"songId: {hit.song_id}")
    print(f"title: {metadata.get('title', '(unknown)')}")
    print(f"artist: {metadata.get('artist', '(unknown)')}")
    print(f"album: {metadata.get('album', '(unknown)')}")
    print(f"duration: {metadata.get('duration', '(unknown)')}")
    print(f"mtime: {format_mtime(hit.mtime)}")
    print(f"cache: {cache_path}")
    print(f"metadataSource: sqlite:{source_table}" if source_table else "metadataSource: (not found in sqlite rows)")
    if strings_context:
        print(f"stringsContext: {strings_context[:500]}")
    print()


def main() -> int:
    args = parse_args()
    cache_dir = args.cache_dir.expanduser()
    db_path = args.db.expanduser()

    print(f"cacheDir: {cache_dir}")
    print(f"sqlite: {db_path}")
    print(f"windowMinutes: {args.minutes}")
    print()

    hits = recent_cache_hits(cache_dir, args.minutes)
    if not hits:
        print("No recent .info cache files found.")
        return 0

    seen: set[str] = set()
    unique_hits: list[CacheHit] = []
    for hit in hits:
        if hit.song_id in seen:
            continue
        seen.add(hit.song_id)
        unique_hits.append(hit)

    for hit in unique_hits[: max(1, args.limit)]:
        print_hit(hit, db_path, cache_dir)

    return 0


if __name__ == "__main__":
    sys.exit(main())
