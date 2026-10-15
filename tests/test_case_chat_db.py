"""
Tests for the case chat (migration 20261015100000_case_chat.sql): who can
read and post in a case's chat, the sender names, live-update paging, and
that messages can't be changed.

Runs against the LOCAL Supabase database like test_ai_pipeline_db.py (every
test is rolled back):
    cd database && supabase db reset
    python tests/test_case_chat_db.py
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_ai_pipeline_db import DbError, make_user, session  # noqa: E402


def setup(db):
    admin = make_user(db, "admin")
    alice = make_user(db, "investigator", firstname="Alice", surname="Mokoena")
    bob = make_user(db, "investigator", firstname="Bob", surname="Naidoo")
    outsider = make_user(db, "investigator", firstname="Olga")
    citizen = make_user(db, "citizen")
    case = db.val("INSERT INTO public.cases (title, createdby) VALUES ('N12 test', %s) "
                  "RETURNING caseid", [admin["userid"]])
    for inv in (alice, bob):
        db.rows("INSERT INTO public.caseassignment (assignedto, assignedby, caseid) "
                "VALUES (%s, %s, %s)", [inv["userid"], admin["userid"], case])
    return admin, alice, bob, outsider, citizen, case


def send(db, who, case, body):
    return db.one("SELECT * FROM public.send_case_message(%s, %s)", [case, body], who)


def listing(db, who, case, after=None):
    return db.rows("SELECT * FROM public.list_case_messages(%s, %s)", [case, after], who)


def test_assigned_investigators_chat():
    with session() as db:
        admin, alice, bob, outsider, citizen, case = setup(db)
        m1 = send(db, alice, case, "  Suspect vehicle seen on R21  ")
        assert m1["body"] == "Suspect vehicle seen on R21"          # trimmed
        assert m1["sender_name"] == "Alice Mokoena" and m1["is_mine"]
        send(db, bob, case, "On my way")

        seen_by_bob = listing(db, bob, case)
        assert [m["body"] for m in seen_by_bob] == ["Suspect vehicle seen on R21", "On my way"]
        assert [m["is_mine"] for m in seen_by_bob] == [False, True]
        # live updates: only what's newer than the last one the app has
        assert [m["body"] for m in listing(db, alice, case, after=m1["messageid"])] == ["On my way"]
        # plain table reads follow the same rule (this is what Realtime uses)
        assert len(db.rows("SELECT * FROM public.casemessage", who=alice)) == 2
        assert len(db.rows("SELECT * FROM public.casemessage", who=admin)) == 2   # oversight


def test_outsiders_cannot_read_or_post():
    with session() as db:
        admin, alice, bob, outsider, citizen, case = setup(db)
        send(db, alice, case, "hello")
        for who in (outsider, citizen):
            assert db.rows("SELECT * FROM public.casemessage", who=who) == []
            db_fails(lambda: listing(db, who, case), "assigned")
            db_fails(lambda: send(db, who, case, "let me in"), "assigned")
            db_fails(lambda: db.rows("INSERT INTO public.casemessage (caseid, body) VALUES (%s, 'x')",
                                     [case], who), "row-level security")
        db_fails(lambda: send(db, admin, case, "admin note"), "assigned")    # admins read only


def test_rules():
    with session() as db:
        admin, alice, bob, outsider, citizen, case = setup(db)
        db_fails(lambda: send(db, alice, case, "   "), "type a message")
        db_fails(lambda: send(db, alice, case, "x" * 2001), "2000")
        m = send(db, alice, case, "first")
        # nobody changes or deletes messages
        db_fails(lambda: db.rows("UPDATE public.casemessage SET body = 'edited'", who=alice), "permission")
        db_fails(lambda: db.rows("DELETE FROM public.casemessage", who=alice), "permission")
        # can't post as someone else
        db_fails(lambda: db.rows("INSERT INTO public.casemessage (caseid, senderid, body) "
                                 "VALUES (%s, %s, 'fake')", [case, bob["userid"]], alice),
                 "row-level security")
        # unassigned: chat gone at once
        db.rows("UPDATE public.caseassignment SET assignmentstatus = 'reassigned', dateunassigned = now() "
                "WHERE assignedto = %s AND caseid = %s", [bob["userid"], case])
        assert db.rows("SELECT * FROM public.casemessage", who=bob) == []
        db_fails(lambda: send(db, bob, case, "still here?"), "assigned")
        # closed case: read-only
        db.rows("UPDATE public.cases SET status = 'closed' WHERE caseid = %s", [case])
        db_fails(lambda: send(db, alice, case, "after closing"), "closed")
        assert [x["messageid"] for x in listing(db, alice, case)] == [m["messageid"]]
        # deleting the case deletes its chat
        db.rows("DELETE FROM public.cases WHERE caseid = %s", [case])
        assert db.val("SELECT count(*) FROM public.casemessage WHERE caseid = %s", [case]) == 0


def db_fails(fn, contains):
    try:
        fn()
    except DbError as e:
        assert contains.lower() in str(e).lower(), f"failed with {e} (expected '{contains}')"
        return
    raise AssertionError(f"expected an error containing '{contains}', but it worked")


if __name__ == "__main__":
    tests = [v for k, v in dict(globals()).items() if k.startswith("test_")]
    failed = 0
    for t in tests:
        try:
            t()
            print(f"ok    {t.__name__}")
        except Exception as e:                      # noqa: BLE001
            failed += 1
            print(f"FAIL  {t.__name__}: {e}")
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    sys.exit(1 if failed else 0)
