"""
Deletes bucket files for submissions that no longer exist.

Mostly for after wiping test data (database/oneoff/keep_only_n12_case.sql),
since Supabase won't let you delete storage objects from SQL. Any top-level
folder whose incident id isn't in crimescene any more gets removed.

    python backend/cleanup_storage.py          dry run, just lists
    python backend/cleanup_storage.py --yes    actually deletes (no undo!)
"""

import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from worker import BUCKET, make_client  # noqa: E402


def list_files(storage, folder):
    """All file paths under `folder`, recursively."""
    paths, offset = [], 0
    while True:
        page = storage.list(folder, {"limit": 1000, "offset": offset})
        for item in page:
            path = f"{folder}/{item['name']}" if folder else item["name"]
            if item.get("id") is None:          # folders come back without an id
                paths += list_files(storage, path)
            else:
                paths.append(path)
        if len(page) < 1000:
            return paths
        offset += 1000


def main(argv=None):
    parser = argparse.ArgumentParser(description="Delete bucket files of deleted submissions.")
    parser.add_argument("--yes", action="store_true", help="really delete (default: only show)")
    args = parser.parse_args(argv)

    client = make_client()
    storage = client.storage.from_(BUCKET)
    existing = {row["incidentid"] for row in
                client.table("crimescene").select("incidentid").execute().data}

    top = storage.list("", {"limit": 1000})
    gone = [item["name"] for item in top
            if item.get("id") is None and item["name"].isdigit()
            and int(item["name"]) not in existing]
    if not gone:
        print("Nothing to delete: every folder belongs to an existing submission.")
        return

    total = 0
    for folder in gone:
        files = list_files(storage, folder)
        total += len(files)
        print(f"{folder}/  {len(files)} file(s)" + ("  -> deleting" if args.yes else ""))
        if args.yes:
            for i in range(0, len(files), 100):
                storage.remove(files[i:i + 100])
    kept = sorted(existing)
    print(f"\n{'Deleted' if args.yes else 'Would delete'} {total} file(s) in "
          f"{len(gone)} folder(s). Kept the folders of submission(s) {kept}.")
    if not args.yes:
        print("Run again with --yes to delete them.")


if __name__ == "__main__":
    main()
