"""
Tests for the root admin's Cases page in the web admin console
(migration 20261021120000_root_case_management.sql): root_list_cases() and
delete_closed_case(), and the cases_delete policy (root admin, closed only).

Runs against the LOCAL Supabase database like test_ai_pipeline_db.py (every
test is rolled back):
    cd database && supabase db reset
    python tests/test_root_cases_db.py
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_admin_deletes_db import root_admin  # noqa: E402
from test_ai_pipeline_db import World, analysed_case, session  # noqa: E402


def set_status(db, case_id, status):
    db.rows("UPDATE public.cases SET status = %s WHERE caseid = %s", [status, case_id])


def delete_case(db, case_id, who):
    return db.rpc("delete_closed_case", who=who, p_caseid=case_id)


def test_root_admin_lists_every_case_with_its_status(db, w):
    boss = root_admin(db)
    one, _, case_id, _ = analysed_case(db, w)
    set_status(db, case_id, "under_review")
    rows = db.rows("SELECT * FROM public.root_list_cases()", who=boss)
    mine = [r for r in rows if r["caseid"] == case_id]
    assert len(mine) == 1, rows
    assert mine[0]["status"] == "under_review" and mine[0]["incidentcount"] == 1, mine[0]
    assert mine[0]["description"] == db.val("SELECT description FROM public.cases WHERE caseid = %s", [case_id])
    assert db.val("SELECT count(*) FROM public.cases") == len(rows)


def test_only_the_root_admin_lists_cases(db, w):
    for who in (w.admin, w.investigator, w.citizen):
        db.fails(db.rows, "SELECT * FROM public.root_list_cases()", who=who,
                 contains="Only the root administrator")
    db.fails(db.rows, "SELECT * FROM public.root_list_cases()", who="anon", contains="permission denied")


def test_root_admin_deletes_a_closed_case(db, w):
    boss = root_admin(db)
    one, _, case_id, _ = analysed_case(db, w)
    db.rows("INSERT INTO public.caseassignment (assignedto, assignedby, caseid, islead) VALUES (%s, %s, %s, true)",
            [w.investigator["userid"], w.admin["userid"], case_id])
    set_status(db, case_id, "closed")
    out = delete_case(db, case_id, boss)
    assert out["caseid"] == case_id and out["incidents"] == 1, out
    assert db.val("SELECT count(*) FROM public.cases WHERE caseid = %s", [case_id]) == 0
    assert db.val("SELECT count(*) FROM public.caseassignment WHERE caseid = %s", [case_id]) == 0
    # the submission is kept and goes back to the review queue
    sub = db.one("SELECT caseid, reviewstatus FROM public.crimescene WHERE incidentid = %s", [one])
    assert sub["caseid"] is None and sub["reviewstatus"] == "pending", sub
    # and the history says so
    assert db.val("SELECT count(*) FROM public.caseevent WHERE eventtype = 'case_deleted' AND detail LIKE %s",
                  [f"CASE-{case_id:04d}%"]) == 1


def test_open_and_under_review_cases_cannot_be_deleted(db, w):
    boss = root_admin(db)
    _, _, case_id, _ = analysed_case(db, w)
    for status in ("open", "under_review"):
        set_status(db, case_id, status)
        db.fails(delete_case, db, case_id, boss, contains="Only closed cases")
    db.fails(delete_case, db, 999999, boss, contains="no longer exists")
    assert db.val("SELECT count(*) FROM public.cases WHERE caseid = %s", [case_id]) == 1


def test_only_the_root_admin_deletes_cases(db, w):
    root_admin(db)
    _, _, case_id, _ = analysed_case(db, w)
    set_status(db, case_id, "closed")
    for who in (w.admin, w.investigator, w.citizen):
        db.fails(delete_case, db, case_id, who, contains="Only the root administrator")
    db.fails(delete_case, db, case_id, "anon", contains="permission denied")
    # a direct table delete by a station admin is stopped by the policy
    db.rows("DELETE FROM public.cases WHERE caseid = %s", [case_id], w.admin)
    assert db.val("SELECT count(*) FROM public.cases WHERE caseid = %s", [case_id]) == 1


if __name__ == "__main__":
    tests = [(n, f) for n, f in dict(globals()).items() if n.startswith("test_")]
    failed = 0
    for name, fn in tests:
        try:
            with session() as db:
                fn(db, World(db))
            print(f"  PASS  {name[5:].replace('_', ' ')}")
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"  FAIL  {name[5:].replace('_', ' ')}\n        {type(e).__name__}: {e}")
    print(f"\n{len(tests) - failed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
