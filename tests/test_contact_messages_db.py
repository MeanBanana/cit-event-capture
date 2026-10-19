"""
Tests for website contact messages (migration 20261019100000_contact_messages.sql):
anyone can send one through submit_contact_message, nobody can touch the
table directly, and only the root admin can read and mark them.

Runs against the LOCAL Supabase database like test_ai_pipeline_db.py (every
test is rolled back):
    cd database && supabase db reset
    python tests/test_contact_messages_db.py
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_admin_accounts_db import fails, root_and_admins  # noqa: E402
from test_ai_pipeline_db import session  # noqa: E402


def send(db, who="anon", **kw):
    args = {"p_name": "Thandi Mokoena", "p_email": "thandi@example.com",
            "p_role": "Police station", "p_organisation": "Kempton Park SAPS",
            "p_message": "We'd like a demo.", **kw}
    return db.rpc("submit_contact_message", who=who, **args)


def test_anyone_can_send_and_only_root_reads():
    with session() as db:
        boss, kp, _ = root_and_admins(db)
        new_id = send(db)
        assert isinstance(new_id, int)
        # the website (anon) can't read or change the table directly
        fails(lambda: db.rows("SELECT * FROM public.contactmessage", who="anon"), "permission denied")
        fails(lambda: db.rows("INSERT INTO public.contactmessage (name, email, role) "
                              "VALUES ('x y', 'a@b.co', 'Other')", who="anon"), "permission denied")
        fails(lambda: db.rows("SELECT * FROM public.contactmessage", who=kp), "permission denied")
        # a normal (station) admin can't list them; anon can't call the list at all
        fails(lambda: db.rows("SELECT * FROM public.list_contact_messages()", who=kp), "only the root")
        fails(lambda: db.rows("SELECT * FROM public.list_contact_messages()", who="anon"), "permission denied")
        rows = db.rows("SELECT * FROM public.list_contact_messages()", who=boss)
        assert [r["id"] for r in rows] == [new_id]
        r = rows[0]
        assert (r["name"], r["email"], r["role"], r["status"]) == \
            ("Thandi Mokoena", "thandi@example.com", "Police station", "new")


def test_root_marks_messages():
    with session() as db:
        boss, kp, _ = root_and_admins(db)
        mid = send(db)
        fails(lambda: db.rows("SELECT public.set_contact_message_status(%s, 'read')", [mid], who=kp),
              "only the root")
        db.rows("SELECT public.set_contact_message_status(%s, 'replied')", [mid], who=boss)
        r = db.rows("SELECT * FROM public.list_contact_messages('replied')", who=boss)[0]
        assert r["status"] == "replied" and r["handledat"] is not None and r["handledby_name"] == "Deacon Nel"
        assert db.rows("SELECT * FROM public.list_contact_messages('new')", who=boss) == []
        db.rows("SELECT public.set_contact_message_status(%s, 'new')", [mid], who=boss)
        r = db.rows("SELECT * FROM public.list_contact_messages()", who=boss)[0]
        assert r["status"] == "new" and r["handledat"] is None
        fails(lambda: db.rows("SELECT public.set_contact_message_status(%s, 'deleted')", [mid], who=boss),
              "unknown status")


def test_checks_and_limits():
    with session() as db:
        fails(lambda: send(db, p_name=" "), "your name")
        fails(lambda: send(db, p_email="not-an-email"), "valid email")
        fails(lambda: send(db, p_role="Hacker"), "who you are")
        fails(lambda: send(db, p_message="x" * 2001), "under 2000")
        # optional fields can be left out
        assert send(db, p_organisation=None, p_message="  ") is not None
        # 3 an hour from one address (one already sent above)
        send(db)
        send(db, p_email="THANDI@example.com ")
        fails(lambda: send(db), "too many messages")
        # one visitor (same IP) can't send more than 5 an hour with new addresses
        db.rows("SELECT set_config('request.headers', %s, true)",
                ['{"x-forwarded-for": "41.13.7.9, 10.0.0.1"}'])
        for i in range(5):
            send(db, p_email=f"v{i}@example.com")
        fails(lambda: send(db, p_email="v9@example.com"), "too many messages")
        hashes = {r["senderhash"] for r in db.rows(
            "SELECT senderhash FROM public.contactmessage WHERE email LIKE 'v%%@example.com'")}
        assert len(hashes) == 1 and "41.13" not in next(iter(hashes))


if __name__ == "__main__":
    tests = [v for k, v in dict(globals()).items() if k.startswith("test_")]
    failed = 0
    for t in tests:
        try:
            t()
            print("PASS", t.__name__)
        except Exception as e:  # noqa: BLE001
            failed += 1
            print("FAIL", t.__name__, e)
    print(f"{len(tests) - failed}/{len(tests)} passed")
    sys.exit(1 if failed else 0)
