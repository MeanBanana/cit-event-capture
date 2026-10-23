"""
Admin account tests (20261018100000_admin_accounts.sql): the sign-up trigger
making admin rows, there only ever being one root admin, and only root being
able to list admins or move them between stations.

Same setup as test_ai_pipeline_db.py, every test gets rolled back:
    cd database && supabase db reset
    python tests/test_admin_accounts_db.py
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_ai_pipeline_db import DbError, make_user, session  # noqa: E402


def fails(fn, contains):
    try:
        fn()
    except DbError as e:
        assert contains.lower() in str(e).lower(), f"failed with {e} (expected '{contains}')"
        return
    raise AssertionError(f"expected an error containing '{contains}', but it worked")


def root_and_admins(db):
    boss = make_user(db, "citizen", firstname="Deacon", surname="Nel")
    username = db.val('SELECT username FROM public."User" WHERE userid = %s', [boss["userid"]])
    db.val("SELECT public.make_root_admin(%s, 'Argus HQ')", [username])
    kp = make_user(db, "admin", firstname="Kim", surname="Pillay",
                   admin_station="Kempton Park SAPS", createdby=str(boss["userid"]))
    sandton = make_user(db, "admin", firstname="Sipho", admin_station="Sandton SAPS")
    return boss, kp, sandton


def test_signup_creates_normal_admin_rows():
    with session() as db:
        boss, kp, sandton = root_and_admins(db)
        row = db.one("SELECT * FROM public.admin WHERE userid = %s", [kp["userid"]])
        assert row["admin_type"] == "normal" and row["admin_station"] == "Kempton Park SAPS"
        assert row["createdby"] == boss["userid"]
        # root admin gets converted from a citizen, and the citizen row goes away
        assert db.val('SELECT role::text FROM public."User" WHERE userid = %s', [boss["userid"]]) == "admin"
        assert db.val("SELECT count(*) FROM public.citizen WHERE userid = %s", [boss["userid"]]) == 0
        assert db.val("SELECT admin_type::text FROM public.admin WHERE userid = %s", [boss["userid"]]) == "root"
        # you can't make yourself root by fiddling with your own metadata
        sneaky = make_user(db, "admin", admin_station="X", admin_type="root")
        assert db.val("SELECT admin_type::text FROM public.admin WHERE userid = %s", [sneaky["userid"]]) == "normal"


def test_only_one_root():
    with session() as db:
        boss, kp, sandton = root_and_admins(db)
        other = db.val('SELECT username FROM public."User" WHERE userid = %s', [kp["userid"]])
        fails(lambda: db.val("SELECT public.make_root_admin(%s, 'X')", [other]), "already a root admin")
        fails(lambda: db.rows("UPDATE public.admin SET admin_type = 'root' WHERE userid = %s",
                              [kp["userid"]]), "admin_one_root")
        inv = make_user(db, "investigator")
        inv_name = db.val('SELECT username FROM public."User" WHERE userid = %s', [inv["userid"]])
        db.rows("UPDATE public.admin SET admin_type = 'normal' WHERE admin_type = 'root'")
        fails(lambda: db.val("SELECT public.make_root_admin(%s, 'X')", [inv_name]), "investigator")
        # make_root_admin isn't callable from either app
        fails(lambda: db.val("SELECT public.make_root_admin(%s, 'X')", [other], who=kp), "permission")


def test_root_only_functions():
    with session() as db:
        boss, kp, sandton = root_and_admins(db)
        listed = db.rows("SELECT * FROM public.list_admins()", who=boss)
        assert [r["admin_type"] for r in listed][0] == "root"
        assert {r["admin_station"] for r in listed} >= {"Argus HQ", "Kempton Park SAPS", "Sandton SAPS"}
        kp_row = next(r for r in listed if r["userid"] == kp["userid"])
        assert kp_row["createdby_name"] == "Deacon Nel"

        assert db.val("SELECT public.is_root_admin()", who=boss) is True
        assert db.val("SELECT public.is_root_admin()", who=kp) is False
        me = db.val("SELECT public.current_admin()", who=kp)
        assert me["admin_type"] == "normal" and me["admin_station"] == "Kempton Park SAPS"
        assert db.val("SELECT public.current_admin()", who=make_user(db, "citizen")) is None

        for who in (kp, make_user(db, "investigator"), make_user(db, "citizen")):
            fails(lambda: db.rows("SELECT * FROM public.list_admins()", who=who), "root administrator")
            fails(lambda: db.rows("SELECT public.set_admin_station(%s, 'Hacked')", [sandton["userid"]], who=who),
                  "root administrator")

        db.rows("SELECT public.set_admin_station(%s, '  Midrand SAPS ')", [sandton["userid"]], who=boss)
        assert db.val("SELECT admin_station FROM public.admin WHERE userid = %s", [sandton["userid"]]) == "Midrand SAPS"
        fails(lambda: db.rows("SELECT public.set_admin_station(%s, ' ')", [sandton["userid"]], who=boss), "enter a station")

        # straight table reads: you see your own row (root sees everyone), and nobody can edit
        assert len(db.rows("SELECT * FROM public.admin", who=kp)) == 1
        assert len(db.rows("SELECT * FROM public.admin", who=boss)) == 3
        assert db.rows("SELECT * FROM public.admin", who=make_user(db, "citizen")) == []
        fails(lambda: db.rows("UPDATE public.admin SET admin_station = 'X'", who=boss), "permission")
        fails(lambda: db.rows("DELETE FROM public.admin", who=boss), "permission")


def test_deleting_the_user_deletes_the_admin_row():
    with session() as db:
        boss, kp, sandton = root_and_admins(db)
        db.rows('DELETE FROM public."User" WHERE userid = %s', [sandton["userid"]])
        assert db.val("SELECT count(*) FROM public.admin WHERE userid = %s", [sandton["userid"]]) == 0


def test_changing_the_password_clears_must_change_password():
    # 20261020100000_must_change_password.sql
    with session() as db:
        kp = make_user(db, "admin", admin_station="Kempton Park SAPS")
        flag = "SELECT raw_app_meta_data FROM auth.users WHERE id = %s"
        # create-admin / create-investigator set a temp password and the flag
        db.rows("UPDATE auth.users SET raw_app_meta_data = raw_app_meta_data || "
                "'{\"must_change_password\": true}', encrypted_password = 'temp-hash' "
                "WHERE id = %s", [kp["authid"]])
        # the first password, set while the account is being created, leaves the flag alone
        assert db.val(flag, [kp["authid"]])["must_change_password"] is True

        # so does anything else, e.g. signing in
        db.rows("UPDATE auth.users SET last_sign_in_at = now(), encrypted_password = 'temp-hash' "
                "WHERE id = %s", [kp["authid"]])
        assert db.val(flag, [kp["authid"]])["must_change_password"] is True

        # picking a new password clears it, role stays the same
        db.rows("UPDATE auth.users SET encrypted_password = 'new-hash' WHERE id = %s", [kp["authid"]])
        meta = db.val(flag, [kp["authid"]])
        assert "must_change_password" not in meta and meta["role"] == "admin"


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
