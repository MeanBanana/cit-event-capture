"""
Tests for deleting an investigator's account and a rejected submission
(migration 20261020130000_admin_delete_investigator_and_submission.sql).
Both functions are called only by Edge Functions with the service key.

Runs against the LOCAL Supabase database like test_ai_pipeline_db.py (every
test is rolled back):
    cd database && supabase db reset
    python tests/test_admin_deletes_db.py
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_ai_pipeline_db import (  # noqa: E402
    PERSON_A, SANDTON, World, analysed_case, look, person, report, results, session,
    vehicle, weapon, worker_analyse)


def remove(db, userid, who="service"):
    return db.rpc("remove_investigator_account", who=who, p_userid=userid)


def delete_sub(db, incidentid, who="service"):
    return db.rpc("delete_rejected_submission", who=who, p_incidentid=incidentid)


def test_new_investigator_is_deleted_completely(db, w):
    out = remove(db, w.other_investigator["userid"])
    assert out["mode"] == "deleted" and out["authid"] == w.other_investigator["authid"], out
    assert db.val('SELECT count(*) FROM public."User" WHERE userid = %s', [w.other_investigator["userid"]]) == 0
    assert db.val("SELECT count(*) FROM public.investigator WHERE userid = %s", [w.other_investigator["userid"]]) == 0
    # the login can now be deleted (nothing points at it any more)
    db.rows("DELETE FROM auth.users WHERE id = %s", [w.other_investigator["authid"]])


def test_investigator_with_history_is_anonymised(db, w):
    _, _, case_id, _ = analysed_case(db, w)
    inv = w.investigator
    name = db.val('SELECT firstname || \' \' || surname FROM public."User" WHERE userid = %s', [inv["userid"]])
    db.rows("INSERT INTO public.caseassignment (assignedto, assignedby, caseid, islead) VALUES (%s, %s, %s, true)",
            [inv["userid"], w.admin["userid"], case_id])
    msg = db.one("SELECT * FROM public.send_case_message(%s, %s)", [case_id, "On my way"], inv)
    out = remove(db, inv["userid"])
    assert out["mode"] == "anonymised" and out["email"] == f"deleted-{inv['userid']}@argus-shield.invalid", out
    user = db.one('SELECT * FROM public."User" WHERE userid = %s', [inv["userid"]])
    assert (user["firstname"], user["surname"], user["username"], user["phonenumber"]) == \
        ("Former", "investigator", f"deleted_{inv['userid']}", None), user
    assert db.val("SELECT count(*) FROM public.investigator WHERE userid = %s", [inv["userid"]]) == 0
    # off the case, with a history line; the chat message stays, under the new name
    a = db.one("SELECT * FROM public.caseassignment WHERE assignedto = %s", [inv["userid"]])
    assert a["assignmentstatus"] == "closed" and a["dateunassigned"] is not None and not a["islead"]
    ev = db.one("SELECT * FROM public.caseevent WHERE caseid = %s AND eventtype = 'unassigned' "
                "ORDER BY eventid DESC LIMIT 1", [case_id])
    assert ev["detail"] == f"{name} (account deleted)", ev
    rows = db.rows("SELECT * FROM public.list_case_messages(%s, NULL)", [case_id], w.admin)
    assert [r["messageid"] for r in rows] == [msg["messageid"]]
    assert "Former investigator" in str(rows[0]), rows[0]
    # not in the investigator list any more; the username and email are free
    listed = db.rows("SELECT * FROM public.list_investigators()", who=w.admin)
    assert inv["userid"] not in [r["userid"] for r in listed]
    assert db.rpc("username_available", p_username=f"t_inv_{inv['authid'][:8]}") is True


def test_only_existing_investigators_and_only_the_service_key(db, w):
    db.fails(remove, db, w.citizen["userid"], contains="no longer exists")
    db.fails(remove, db, w.admin["userid"], contains="no longer exists")
    db.fails(remove, db, 999999, contains="no longer exists")
    for who in (w.admin, w.investigator, w.citizen, "anon"):
        db.fails(remove, db, w.other_investigator["userid"], who=who, contains="permission denied")
        db.fails(delete_sub, db, 1, who=who, contains="permission denied")


def rejected_submission(db, w):
    inc, media = report(db, w.citizen, files=2, lat=SANDTON[0], lon=SANDTON[1])
    db.rpc("submit_for_analysis", who=w.citizen, p_incidentid=inc)
    worker_analyse(db, inc, results(inc, media, [[person(1, look(PERSON_A, 0.97, 10)), vehicle(2),
                                                  weapon(1, held_by=1)], [person(1, look(PERSON_A, 0.95, 11))]],
                                    location=SANDTON))
    db.rpc("reject_submission", who=w.admin, p_incidentid=inc, p_note="not a CIT incident")
    return inc, media


def test_delete_rejected_submission(db, w):
    inc, media = rejected_submission(db, w)
    assert db.val("SELECT count(*) FROM public.detection d JOIN public.media m USING (mediaid) "
                  "WHERE m.incidentid = %s", [inc]) == 4
    out = delete_sub(db, inc)
    assert out == {"incidentid": inc, "files": 2}, out
    for sql in ("SELECT count(*) FROM public.crimescene WHERE incidentid = %s",
                "SELECT count(*) FROM public.media WHERE incidentid = %s",
                "SELECT count(*) FROM public.caseevent WHERE incidentid = %s",
                "SELECT count(*) FROM public.aijob WHERE incidentid = %s"):
        assert db.val(sql, [inc]) == 0, sql
    assert db.val("SELECT count(*) FROM public.detection WHERE mediaid = ANY(%s)", [media]) == 0


def test_only_rejected_ones(db, w):
    inc_pending, _ = report(db, w.citizen, files=1)
    db.fails(delete_sub, db, inc_pending, contains="Only rejected")
    one, _, case_id, _ = analysed_case(db, w)                         # accepted, in a case
    db.fails(delete_sub, db, one, contains="Only rejected")
    db.fails(delete_sub, db, 999999, contains="no longer exists")
    # a rejected one that another submission is a duplicate of
    inc, _ = rejected_submission(db, w)
    dup, _ = report(db, w.citizen, files=1)
    db.rows("UPDATE public.crimescene SET reviewstatus = 'duplicate', duplicateof = %s WHERE incidentid = %s",
            [inc, dup])
    db.fails(delete_sub, db, inc, contains="duplicates of this one")


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
