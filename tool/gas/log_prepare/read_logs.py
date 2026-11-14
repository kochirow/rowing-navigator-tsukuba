#!/usr/bin/env python3
"""Read a streamed, read-only Drive folder prepared by Apps Script."""

import argparse
import datetime as dt
import hashlib
import json
import re
import sys
from pathlib import Path


def parse_day(value):
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        raise argparse.ArgumentTypeError("expected YYYY-MM-DD")
    try:
        return dt.date.fromisoformat(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(str(exc)) from exc


def child(base, path):
    parts = path.split("/")
    if any(not part or part in (".", "..") or "\\" in part or ":" in part for part in parts):
        raise ValueError("invalid relative path")
    result = base
    for part in parts:
        result = result / part
        if result.is_symlink():
            raise ValueError("symbolic link in input")
    return result


def verified_bytes(path, expected):
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError(f"checksum mismatch: {path.name}")
    return data


def scan(root, start, end):
    ready = []
    incomplete = []
    for day in sorted(root.iterdir()):
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", day.name):
            continue
        if not start.isoformat() <= day.name <= end.isoformat():
            continue
        for folder in sorted(child(root, day.name).iterdir()):
            if not re.fullmatch(r"zip-[a-z0-9_-]+-\d+", folder.name):
                continue
            child(day, folder.name)
            marker = child(folder, "ready.json")
            if not marker.is_file():
                incomplete.append({"day": day.name, "version": folder.name,
                                   "state": "rejected" if child(folder, "rejected.json").is_file() else "pending"})
                continue
            item = json.loads(marker.read_text(encoding="utf-8"))
            if item.get("schema") != 1 or item["day"] != day.name or not item["record"]:
                raise ValueError(f"invalid publication marker: {folder.name}")
            ready.append((folder, item))
    return ready, incomplete


def current_records(versions):
    selected = {}
    for folder, item in versions:
        record = item["record"]
        old = selected.get(record)
        key = (item["receivedAt"], int(item["sourceVersion"]))
        if old:
            old_folder, old_item = old
            if item["receivedAt"] == old_item["receivedAt"] and item["sourceId"] != old_item["sourceId"]:
                raise ValueError(f"ambiguous upload order: {old_folder.name} / {folder.name}")
            if key <= (old_item["receivedAt"], int(old_item["sourceVersion"])):
                continue
        selected[record] = (folder, item)
    return sorted(selected.values(), key=lambda pair: (pair[1]["day"], pair[0].name))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    listing = commands.add_parser("list")
    listing.add_argument("--from", type=parse_day, required=True, dest="start")
    listing.add_argument("--to", type=parse_day, required=True, dest="end")
    for name in ("events", "file"):
        command = commands.add_parser(name)
        command.add_argument("version", help="day/version path from list")
        command.add_argument("--limit", type=int, default=100)
        command.add_argument("--offset", type=int, default=0)
        if name == "file":
            command.add_argument("path", help="path inside the ZIP")
        else:
            command.add_argument("--type")
            command.add_argument("--category")
    args = parser.parse_args()
    try:
        root = args.root.resolve(strict=True)
        if args.command == "list":
            if args.start > args.end:
                raise ValueError("start is after end")
            versions, incomplete = scan(root, args.start, args.end)
            records = []
            for folder, item in current_records(versions):
                records.append({
                    "version": folder.relative_to(root).as_posix(),
                    "record": item["record"], "day": item["day"], "kind": item["kind"],
                    "sourceId": item["sourceId"], "sourceVersion": item["sourceVersion"],
                    "summary": item["summary"],
                    "files": [entry["path"] for entry in item["files"] if not entry.get("directory")],
                })
            print(json.dumps({"records": records, "incomplete": incomplete, "versions": len(versions)}, ensure_ascii=False))
            return
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}/zip-[a-z0-9_-]+-\d+", args.version):
            raise ValueError("expected a version path from list")
        if not 1 <= args.limit <= 500 or args.offset < 0:
            raise ValueError("limit must be 1–500 and offset must be nonnegative")
        folder = child(root, args.version)
        marker = json.loads(child(folder, "ready.json").read_text(encoding="utf-8"))
        if marker.get("schema") != 1 or marker["day"] != folder.parent.name:
            raise ValueError("invalid publication marker")
        if args.command == "events":
            raw = verified_bytes(child(folder, "events-index.jsonl"), marker["indexSha256"])
            rows = [json.loads(line) for line in raw.splitlines()]
            if args.type:
                rows = [row for row in rows if row["type"] == args.type]
            if args.category:
                rows = [row for row in rows if row.get("category") == args.category]
            print(json.dumps({"total": len(rows), "rows": rows[args.offset:args.offset + args.limit]}, ensure_ascii=False))
        else:
            entries = [item for item in marker["files"] if item["path"] == args.path and not item.get("directory")]
            if len(entries) != 1:
                raise ValueError("file unavailable in this version")
            raw = verified_bytes(child(child(folder, "files"), args.path), entries[0]["sha256"])
            lines = raw.decode("utf-8").split("\n")
            for index, line in enumerate(lines[args.offset:args.offset + args.limit], start=args.offset + 1):
                print(f"{index}\t{line[:4000]}")
    except (OSError, ValueError, KeyError, TypeError) as exc:
        parser.exit(1, f"read_logs: {exc}\n")


if __name__ == "__main__":
    main()
