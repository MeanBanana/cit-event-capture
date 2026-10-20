"""
Tests for combining a case's people / vehicles / weapons by hand
(migration 20261020120000_combine_case_entities.sql): "Person 2 is the same
as Person 1" on the View crops screen.

Runs against the LOCAL Supabase database like test_ai_pipeline_db.py (every
test is rolled back):
    cd database && supabase db reset
    python tests/test_combine_entities_db.py
"""

import sys
from datetime import timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_ai_pipeline_db import (  # noqa: E402
    PERSON_A, PERSON_B, RUN_TIME, SANDTON, World, analysed_case, entity, evidence, jobs,
    look, person, report, results, run_case_jobs, save_case, session, vehicle, weapon,
    worker_analyse)


def two_people(db, w):
    """Submission 1: Person 1 (A) with Weapon 1 + Vehicle 1.
    Submission 2: someone who looks different (B) with a gun and another car:
    the AI makes them Person 2, Weapon 2, Vehicle 2."""
    one, _, case_id, _ = analysed_case(db, w)
    two, media2 = report(db, w.citizen, files=1, lat=SANDTON[0], lon=SANDTON[1])
    db.rpc("submit_for_analysis", who=w.citizen, p_incidentid=two)
    worker_analyse(db, two, results(two, media2, [[person(1, look(PERSON_B, 0.97, 50), upper="grey"),
                                                   weapon(2, held_by=1),
                                                   vehicle(3, plate="CA 999-111", make="BMW", colour="black")]],
                                    location=SANDTON, capture=RUN_TIME + timedelta(hours=1)))
    db.rpc("add_incidents_to_case", who=w.admin, p_caseid=case_id, p_incidentids=[two])
    run_case_jobs(db)
    view = evidence(db, case_id, w.admin)
    assert view["counts"] == {"people": 2, "vehicles": 2, "weapons": 2}, view["counts"]
    return case_id, one, two


def combine(db, who, case_id, frm, into):
    return db.rpc("combine_case_entities", who=who, p_caseid=case_id, p_from=frm, p_into=into)


def test_combine_people_moves_pictures_and_guns(db, w):
    case_id, one, two = two_people(db, w)
    view = evidence(db, case_id, w.admin)
    p1, p2 = entity(view, "Person 1"), entity(view, "Person 2")
    out = combine(db, w.admin, case_id, "p2", "p1")
    assert out == {"entity_id": "p1", "label": "Person 1", "moved": 1}, out
    view = evidence(db, case_id, w.admin)
    assert view["counts"]["people"] == 1
    merged = entity(view, "Person 1")
    assert len(merged["crops"]) == len(p1["crops"]) + len(p2["crops"])
    assert merged["submission_count"] == 2
    # the moved pictures are an admin decision now
    statuses = db.rows("SELECT d.matchstatus, d.matchreasons FROM public.detection d "
                       "JOIN public.media m USING (mediaid) WHERE m.incidentid = %s "
                       "AND d.detectiontype = 'person'", [two])
    assert statuses == [{"matchstatus": "confirmed", "matchreasons": ["combined with Person 2 by hand"]}]
    # Weapon 2 was held by Person 2 -> now by Person 1
    held = db.rows("SELECT w.number, h.number AS holder FROM public.caseentity w "
                   "JOIN public.caseentity h ON h.entityid = w.heldbyentityid "
                   "WHERE w.caseid = %s AND w.kind = 'weapon' ORDER BY w.number", [case_id])
    assert held == [{"number": 1, "holder": 1}, {"number": 2, "holder": 1}], held
    # re-vote queued, summary outdated, history written
    assert [j["kind"] for j in jobs(db, caseid=case_id, status="queued")] == ["summary"]
    assert db.val("SELECT aisummarystatus FROM public.cases WHERE caseid = %s", [case_id]) == "outdated"
    ev = db.one("SELECT * FROM public.caseevent WHERE caseid = %s ORDER BY eventid DESC LIMIT 1", [case_id])
    assert (ev["eventtype"], ev["detail"], ev["actor"]) == \
        ("ai_entities_combined", "Person 2 is the same as Person 1", w.admin["userid"])
    # the worker re-votes and never splits them again
    run_case_jobs(db)
    view = evidence(db, case_id, w.admin)
    assert view["counts"]["people"] == 1 and entity(view, "Person 1")["submission_count"] == 2
    assert db.val("SELECT aisummarystatus FROM public.cases WHERE caseid = %s", [case_id]) == "ready"


def test_stale_worker_save_does_not_split_them(db, w):
    case_id, _, _ = two_people(db, w)
    stale = db.rpc("ai_load_case", p_caseid=case_id)       # worker loaded before ...
    combine(db, w.admin, case_id, "p2", "p1")
    save_case(db, stale)                                    # ... and saves after
    view = evidence(db, case_id, w.admin)
    assert view["counts"]["people"] == 1, view["counts"]
    assert entity(view, "Person 1")["submission_count"] == 2


def test_combine_vehicles_and_weapons(db, w):
    case_id, _, _ = two_people(db, w)
    before = evidence(db, case_id, w.admin)
    v_crops = len(entity(before, "Vehicle 1")["crops"]) + len(entity(before, "Vehicle 2")["crops"])
    combine(db, w.admin, case_id, "v2", "v1")
    combine(db, w.admin, case_id, "w1", "w2")             # either direction
    view = evidence(db, case_id, w.admin)
    assert view["counts"] == {"people": 2, "vehicles": 1, "weapons": 1}, view["counts"]
    assert len(entity(view, "Vehicle 1")["crops"]) == v_crops
    assert [e["label"] for e in view["weapons"]] == ["Weapon 2"]
    run_case_jobs(db)
    assert evidence(db, case_id, w.admin)["counts"] == {"people": 2, "vehicles": 1, "weapons": 1}


def test_open_question_moves_with_it(db, w):
    case_id, _, _ = two_people(db, w)
    three, media3 = report(db, w.citizen, files=1, lat=SANDTON[0], lon=SANDTON[1])
    db.rpc("submit_for_analysis", who=w.citizen, p_incidentid=three)
    worker_analyse(db, three, results(three, media3, [[person(1, look(PERSON_B, 0.82, 70), upper="grey")]],
                                      location=SANDTON, capture=RUN_TIME + timedelta(hours=2)))
    db.rpc("add_incidents_to_case", who=w.admin, p_caseid=case_id, p_incidentids=[three])
    run_case_jobs(db)
    view = evidence(db, case_id, w.admin)
    assert len(entity(view, "Person 2")["questions"]) == 1, entity(view, "Person 2")
    combine(db, w.admin, case_id, "p2", "p1")
    view = evidence(db, case_id, w.admin)
    q = entity(view, "Person 1")["questions"]
    assert len(q) == 1 and q[0]["submission"] == three and view["open_questions"] == 1


def test_rules(db, w):
    case_id, _, _ = two_people(db, w)
    db.fails(combine, db, w.citizen, case_id, "p2", "p1", contains="Only admins and investigators")
    db.fails(combine, db, w.investigator, case_id, "p2", "p1", contains="Only admins and investigators")
    # an investigator assigned to the case can
    db.rows("INSERT INTO public.caseassignment (assignedto, assignedby, caseid) VALUES (%s, %s, %s)",
            [w.investigator["userid"], w.admin["userid"], case_id])
    db.fails(combine, db, w.investigator, case_id, "p2", "v1", contains="same kind")
    db.fails(combine, db, w.investigator, case_id, "p2", "p2", contains="different one")
    db.fails(combine, db, w.investigator, case_id, "p9", "p1", contains="not found")
    combine(db, w.investigator, case_id, "p2", "p1")
    db.fails(combine, db, w.investigator, case_id, "p2", "p1", contains="not found")   # already gone
    db.rpc("set_case_status", who=w.admin, p_caseid=case_id, p_status="closed")
    db.fails(combine, db, w.admin, case_id, "v2", "v1", contains="closed")


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
