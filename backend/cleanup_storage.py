"""
cleanup_storage.py - delete the files of submissions that no longer exist
from the 'submissions' bucket (after deleting test data with
database/oneoff/keep_only_n12_case.sql; Supabase doesn't allow deleting
bucket files from SQL).

Each submission's files are in  submissions/<incidentid>/...  (its media and
the AI's crops). A folder whose incident id is no longer in crimescene is
removed. Run on the GPU PC (needs the service key in backend/.env):

    python backend\\cleanup_storage.py          (shows what it would delete)
    python backend\\cleanup_storage.py --yes    (deletes it - can't be undone)
"""

import argparse
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from worker import BUCKET, make_client  # noqa: E402


def list_files(storage, folder):
    """Every file path under folder (recursively)."""
    paths, offset = [], 0
    while True:
        page = storage.list(folder, {"limit": 1000, "offset": offset})
        for item in page:
            path = f"{folder}/{item['name']}" if folder else item["name"]
            if item.get("id") is None:          # a folder
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
