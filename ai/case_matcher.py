"""
case_matcher.py - links submissions to cases and combines what the AI found
in each submission into ONE list of people, vehicles and weapons per case.

Three jobs:

  1. SUGGEST a case for a new submission (shown to admins in the Submissions
     tab). A case is suggested when one of its submissions was filmed within
     SUGGEST_KM (1 km, GPS from the video / photo itself) and SUGGEST_DAYS
     (14 days) of the new one - or when the same number plate shows up.
     Extra evidence (same plate, same-looking vehicle, a person who looks
     alike) raises the score and is listed as reasons.
     Nothing joins a case until an admin accepts.

  2. MERGE an accepted submission into the case. Every person / vehicle /
     weapon it found is compared with the case's existing ones:
        vehicle  same plate (or 1 character off, make and colour agreeing)
                 -> the same vehicle. Same make + colour + type, no plate
                 -> "Is this Vehicle 2?" for the admin.
        person   appearance fingerprint (appearance.py) + clothing colours:
                 very alike and same clothing -> the same person; fairly
                 alike -> "Is this Person 2?"; else a new person.
        weapon   follows the person holding it (Person 2's long gun stays
                 Person 2's long gun); otherwise a new weapon.
     Two people seen AT THE SAME TIME in one clip are never merged into one.
     Its crops are added to that person's / vehicle's list, and each one's
     combined details are re-voted over everything linked to it - a new clip
     can fill a gap (a plate nobody could read before) or outvote a weak
     reading. Changes are listed under "updated".

  3. VIEW: case_view(case) gives exactly what the case screen shows: the
     summary, counts, and per person / vehicle / weapon its details, cover
     picture, all its crops (for the 3-column grid) and open questions.

Until the Supabase side is built, cases are kept as JSON files in cases/
(one per case), so everything can be tried on a laptop:

    python case_matcher.py suggest "crops/submission 5/results.json"
    python case_matcher.py create  "crops/submission 1/results.json" --title "N1 Midrand CIT robbery"
    python case_matcher.py add 1   "crops/submission 5/results.json"      (admin accepted)
    python case_matcher.py questions 1
    python case_matcher.py confirm 1 s5/f1/person/3 yes                   (or: no)
    python case_matcher.py show 1
    python case_matcher.py view 1 > case_1_view.json                      (what the app shows)

A submission without GPS in its files (WhatsApp strips it) can be given the
phone's location instead: --lat -26.0045 --lon 28.1271

Later the worker calls the same functions (suggest_cases, merge_submission,
confirm_match, case_view) and stores the result in Supabase instead of cases/.
"""

import argparse
import json
import math
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

from appearance import PERSON_MAYBE, PERSON_SAME, similarity
from clothing import clothing_word

CASES_DIR = Path("cases")
SUGGEST_KM = 1.0
SUGGEST_DAYS = 14
SAME_DAY_HOURS = 12        # people change clothes: appearance only links within this
SURE_SHARE = 0.5           # a clothing / make / colour answer counts as "known" from here
VEHICLE_MAYBE = 0.85       # same type + colour, no plate/make: ask from this look-alike score


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

def _time(text):
    if not text:
        return None
    try:
        t = datetime.fromisoformat(str(text).replace("Z", "+00:00"))
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)


def distance_km(a, b):
    """Haversine distance between two {"latitude", "longitude"} dicts."""
    if not a or not b or a.get("latitude") is None or b.get("latitude") is None:
        return None
    lat1, lon1, lat2, lon2 = map(math.radians, (a["latitude"], a["longitude"],
                                                b["latitude"], b["longitude"]))
    h = (math.sin((lat2 - lat1) / 2) ** 2
         + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2)
    return 2 * 6371 * math.asin(math.sqrt(h))


def normalize_plate(plate):
    """'nd 123-456 gp' -> 'ND123456GP' (None if nothing is left)."""
    text = re.sub(r"[^A-Za-z0-9]", "", plate or "").upper()
    return text or None


def _levenshtein(a, b):
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1,
                               previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


def plates_similar(a, b):
    """Exactly one character apart (an OCR mix-up like 0/O or 8/B), both at
    least 5 characters - same rule as the database's plates_similar()."""
    return (a and b and len(a) >= 5 and len(b) >= 5 and abs(len(a) - len(b)) <= 1
            and _levenshtein(a, b) == 1)


def _known(value, share):
    return value if value and (share or 0) >= SURE_SHARE else None


def _fmt_km(km):
    return f"{round(km * 1000)} m" if km < 1 else f"{km:.1f} km"


def _fmt_gap(hours):
    if hours < 1:
        return f"{max(1, round(hours * 60))} min"
    if hours < 48:
        return f"{round(hours)} h"
    return f"{round(hours / 24)} days"


# ---------------------------------------------------------------------------
# A submission, as the matcher sees it
# ---------------------------------------------------------------------------

def load_submission(results_path, latitude=None, longitude=None):
    """Reads a results.json (from main.py) into a submission record.
    latitude / longitude: the phone's location, used only when no file in the
    submission has GPS of its own."""
    results_path = Path(results_path)
    data = json.loads(results_path.read_text(encoding="utf-8"))
    if "files" not in data:
        raise ValueError(f"{results_path} is not a submission results.json")
    return submission_record(data, str(results_path), latitude, longitude)


def submission_record(data, results_path=None, latitude=None, longitude=None):
    number = data.get("submission")
    location = data.get("location")
    if not location and latitude is not None and longitude is not None:
        location = {"latitude": float(latitude), "longitude": float(longitude), "source": "phone"}
    record = {
        "submission": number,
        "results_path": results_path,
        "location": location,
        "capture_time": data.get("capture_time"),
        "processed_at": data.get("processed_at"),
        "files": [],
        "members": [],
    }
    for index, f in enumerate(data["files"], start=1):
        if "error" in f:
            continue
        name = Path(str(f.get("source_path", f"file{index}"))).name
        record["files"].append({"file_index": index, "file_name": name,
                                "source_type": f.get("source_type"),
                                "capture_time": f.get("capture_time")})
        people = {}
        for d in f.get("detections", []):
            member = _member(number, index, name, f, d)
            record["members"].append(member)
            if member["kind"] == "person":
                people[d["track_id"]] = member["key"]
        for member in record["members"]:          # weapon -> the holder's key
            if member["file_index"] == index and member["kind"] == "weapon":
                member["held_by"] = people.get(member.pop("held_by_track", None))
    return record


def _member(submission, file_index, file_name, f, d):
    """One tracked person / vehicle / weapon from one file."""
    kind = d["detection_type"]
    member = {
        "key": f"s{submission}/f{file_index}/{kind}/{d['track_id']}",
        "submission": submission,
        "file_index": file_index,
        "file_name": file_name,
        "kind": kind,
        "track_id": d["track_id"],
        "first_seen": d.get("first_seen_seconds", 0.0),
        "last_seen": d.get("last_seen_seconds", d.get("first_seen_seconds", 0.0)),
        "capture_time": f.get("capture_time"),
        "appearance": d.get("appearance"),
        "status": None,             # first | auto | confirmed | suggested
        "score": None,
        "reasons": [],
    }
    crops = []

    def add(path, picture):
        if path:
            crops.append({"path": path, "type": picture})

    if kind == "person":
        member["attributes"] = {k: d.get(k) for k in (
            "upper_clothing", "upper_clothing_confidence", "lower_clothing",
            "lower_clothing_confidence", "face_visible", "face_size_px", "clothing_views")}
        add(d.get("person_crop_path"), "person")
        add(d.get("face_crop_path"), "face")
        for p in d.get("extra_crop_paths") or []:
            add(p, "person")
    elif kind == "vehicle":
        member["attributes"] = {
            "class_name": d.get("class_name"),
            "make": d.get("make"), "make_confidence": d.get("make_confidence"),
            "make_views": d.get("make_views"),
            "colour": d.get("colour"), "colour_confidence": d.get("colour_confidence"),
            "plate": normalize_plate(d.get("plate")),
            "plate_confidence": d.get("plate_confidence"), "plate_reads": d.get("plate_reads"),
            "frames_seen": d.get("frames_seen"),
        }
        add(d.get("crop_path"), "vehicle")
        add(d.get("plate_crop_path"), "plate")
        for p in d.get("extra_crop_paths") or []:
            add(p, "vehicle")
    else:
        member["attributes"] = {"kind": d.get("class_name"),
                                "weapon_confidence": d.get("weapon_confidence"),
                                "frames_seen": d.get("frames_seen")}
        member["held_by_track"] = d.get("held_by_person")
        add(d.get("crop_path"), "weapon")
    member["crops"] = crops
    return member


# ---------------------------------------------------------------------------
# Is this member the same as that entity?
# ---------------------------------------------------------------------------
# Each returns (decision, score, reasons): decision is "auto" (same),
# "suggest" (ask the admin) or None (different / don't know).

def _linked(entity):
    """Members whose link is settled (count for votes and comparisons)."""
    return [m for m in entity["members"] if m["status"] in ("first", "auto", "confirmed")]


def _hours_apart(a, b):
    ta, tb = _time(a), _time(b)
    return None if ta is None or tb is None else abs((ta - tb).total_seconds()) / 3600


def compare_person(member, entity):
    others = _linked(entity)
    sims = [s for s in (similarity(member["appearance"], o["appearance"]) for o in others)
            if s is not None]
    if not sims:
        return None, 0.0, []
    sim = max(sims)
    a = member["attributes"]
    e = entity["attributes"]
    reasons, conflict, agree = [f"looks {round(sim * 100)}% alike"], [], []
    for part, key in (("top", "upper_clothing"), ("bottom", "lower_clothing")):
        mine = _known(a.get(key), a.get(f"{key}_confidence"))
        theirs = _known(e.get(key), e.get(f"{key}_share"))
        if mine and theirs:
            (agree if mine == theirs else conflict).append((part, mine, theirs))
    if agree:
        reasons.append("same clothing (" + ", ".join(f"{p} {clothing_word(m)}" for p, m, _ in agree) + ")")
    if conflict:
        reasons.append("clothing differs (" + ", ".join(
            f"{p} {clothing_word(m)} vs {clothing_word(t)}" for p, m, t in conflict) + ")")
    score = sim + 0.03 * len(agree) - 0.05 * len(conflict)
    gaps = [h for h in (_hours_apart(member["capture_time"], o["capture_time"]) for o in others)
            if h is not None]
    far_apart = bool(gaps) and min(gaps) > SAME_DAY_HOURS
    if far_apart:
        reasons.append(f"filmed {_fmt_gap(min(gaps))} apart (clothes may have changed)")
    if sim >= PERSON_SAME and not conflict and not far_apart:
        return "auto", score, reasons
    if sim >= PERSON_MAYBE:
        return "suggest", score, reasons
    return None, score, reasons


def compare_vehicle(member, entity):
    a, e = member["attributes"], entity["attributes"]
    mine_plate = a.get("plate")
    their_plates = {m["attributes"].get("plate") for m in _linked(entity)} - {None}
    make_a = _known(a.get("make"), a.get("make_confidence"))
    make_e = _known(e.get("make"), e.get("make_share"))
    colour_a = _known(a.get("colour"), a.get("colour_confidence"))
    colour_e = _known(e.get("colour"), e.get("colour_share"))
    make_clash = make_a and make_e and make_a != make_e
    colour_clash = colour_a and colour_e and colour_a != colour_e

    if mine_plate and mine_plate in their_plates:
        return "auto", 1.0, [f"same plate {mine_plate}"]
    near = next((p for p in their_plates if plates_similar(mine_plate, p)), None)
    if near and not make_clash and not colour_clash:
        return "auto", 0.9, [f"similar plate {mine_plate} / {near} (1 character different)"]
    if mine_plate and their_plates:
        return None, 0.0, [f"different plates ({mine_plate} vs {', '.join(sorted(their_plates))})"]
    if make_clash or colour_clash:
        return None, 0.0, []
    if not colour_a or not colour_e:
        return None, 0.0, []                    # too little to go on
    same_type = a.get("class_name") == e.get("class_name")
    sims = [s for s in (similarity(member["appearance"], o["appearance"]) for o in _linked(entity))
            if s is not None]
    sim = max(sims) if sims else 0.0
    look = " ".join(x for x in (colour_a, make_a or make_e, a.get("class_name")) if x)
    if make_a and make_e and same_type:
        return "suggest", 0.7 + 0.1 * sim, [f"both a {look}", "no plate to compare"]
    if same_type and sim >= VEHICLE_MAYBE:
        return "suggest", 0.6 + 0.1 * sim, [f"both a {look}", f"looks {round(sim * 100)}% alike",
                                            "no plate or make to compare"]
    return None, 0.0, []


def compare_weapon(member, entity, person_entity_of):
    holder = person_entity_of.get(member.get("held_by"))
    kind = member["attributes"].get("kind")
    if holder and entity.get("held_by_entity") == holder and kind and \
            entity["attributes"].get("kind") == kind:
        return "auto", 1.0, [f"{kind.replace('_', ' ')} held by the same person"]
    return None, 0.0, []


# ---------------------------------------------------------------------------
# Merging a submission into a case
# ---------------------------------------------------------------------------

def _overlaps(member, entity):
    """Does the entity already have someone from the SAME file at the SAME
    time? Then this member is a different person/vehicle (both on screen)."""
    for o in entity["members"]:
        if o["submission"] == member["submission"] and o["file_index"] == member["file_index"]:
            if member["first_seen"] <= o["last_seen"] and o["first_seen"] <= member["last_seen"]:
                return True
    return False


def _compare(member, entity, person_entity_of):
    if member["kind"] == "person":
        return compare_person(member, entity)
    if member["kind"] == "vehicle":
        return compare_vehicle(member, entity)
    return compare_weapon(member, entity, person_entity_of)


def _new_entity(case, member):
    kind = member["kind"]
    case["counters"][kind] = case["counters"].get(kind, 0) + 1
    label = {"person": "Person", "vehicle": "Vehicle", "weapon": "Weapon"}[kind]
    entity = {"entity_id": f"{kind[0]}{case['counters'][kind]}",
              "kind": kind, "label": f"{label} {case['counters'][kind]}",
              "members": [], "attributes": {}, "updated": []}
    case["entities"].append(entity)
    return entity


def _link(member, entity, status, score=None, reasons=()):
    member.update(status=status, score=None if score is None else round(score, 3),
                  reasons=list(reasons))
    entity["members"].append(member)
    _revote(entity)            # later comparisons see the updated details


def _candidates(member, entities, case, person_entity_of):
    rejected = {tuple(p) for p in case["rejected"]}
    found = []
    for entity in entities:
        if entity["kind"] != member["kind"] or (member["key"], entity["entity_id"]) in rejected:
            continue
        if _overlaps(member, entity):
            continue
        decision, score, reasons = _compare(member, entity, person_entity_of)
        if decision:
            found.append((decision, score, reasons, entity))
    found.sort(key=lambda c: (c[0] == "auto", c[1]), reverse=True)
    return found


def merge_submission(case, sub):
    """Adds an accepted submission to the case. Returns a report:
    {"linked": [...], "questions": [...], "new": [...], "updated": [...]}."""
    if any(s["submission"] == sub["submission"] for s in case["submissions"]):
        raise ValueError(f"Submission {sub['submission']} is already in case {case['case_id']}")
    case["submissions"].append({k: sub[k] for k in ("submission", "results_path", "location",
                                                    "capture_time", "processed_at", "files")})
    before = {e["entity_id"]: dict(e["attributes"]) for e in case["entities"]}
    report = {"linked": [], "questions": [], "new": [], "updated": []}
    person_entity_of = {m["key"]: e["entity_id"] for e in case["entities"]
                        if e["kind"] == "person" for m in e["members"]}

    members = [json.loads(json.dumps(m)) for m in sub["members"]]   # own copies
    for kind in ("person", "vehicle", "weapon"):                     # weapons need people first
        todo = [m for m in members if m["kind"] == kind]

        # 1) the best pairs with the case's EXISTING entities first
        existing = [e for e in case["entities"] if e["kind"] == kind]
        pairs = []
        for m in todo:
            for decision, score, reasons, entity in _candidates(m, existing, case, person_entity_of):
                pairs.append((decision == "auto", score, m["key"], decision, reasons, entity, m))
        pairs.sort(key=lambda p: (p[0], p[1]), reverse=True)
        placed = set()
        for _, score, key, decision, reasons, entity, m in pairs:
            if key in placed or _overlaps(m, entity):
                continue
            _link(m, entity, "auto" if decision == "auto" else "suggested", score, reasons)
            placed.add(key)
            (report["linked"] if decision == "auto" else report["questions"]).append(
                (m["key"], entity["label"], round(score, 2), reasons))

        # 2) the rest: one by one, so a second clip of the same person in this
        #    submission joins the entity the first clip just created
        for m in sorted((m for m in todo if m["key"] not in placed),
                        key=lambda m: -(m["last_seen"] - m["first_seen"])):
            fresh = [e for e in case["entities"] if e["kind"] == kind
                     and e["entity_id"] not in before]
            found = _candidates(m, fresh, case, person_entity_of)
            if found:
                decision, score, reasons, entity = found[0]
                _link(m, entity, "auto" if decision == "auto" else "suggested", score, reasons)
                (report["linked"] if decision == "auto" else report["questions"]).append(
                    (m["key"], entity["label"], round(score, 2), reasons))
            else:
                entity = _new_entity(case, m)
                if kind == "weapon":
                    entity["held_by_entity"] = person_entity_of.get(m.get("held_by"))
                _link(m, entity, "first")
                report["new"].append((m["key"], entity["label"]))
            if kind == "person":
                person_entity_of[m["key"]] = entity["entity_id"]

        for e in case["entities"]:
            if e["kind"] == kind:
                _revote(e)
        if kind == "person":
            person_entity_of.update({m["key"]: e["entity_id"] for e in case["entities"]
                                     if e["kind"] == "person" for m in e["members"]})

    for e in case["entities"]:
        _revote(e, case)
        old = before.get(e["entity_id"])
        if old is None:
            continue
        for field in _SHOWN_FIELDS[e["kind"]]:
            if old.get(field) != e["attributes"].get(field):
                change = {"field": field, "old": old.get(field), "new": e["attributes"].get(field),
                          "submission": sub["submission"]}
                e["updated"].append(change)
                report["updated"].append((e["label"], field, change["old"], change["new"]))
    case["summary"] = summary_text(case)
    case["updated_at"] = datetime.now(timezone.utc).isoformat()
    return report


_SHOWN_FIELDS = {
    "person": ("upper_clothing", "lower_clothing", "face_visible"),
    "vehicle": ("class_name", "make", "colour", "plate"),
    "weapon": ("kind", "held_by"),
}


def _vote(pairs):
    """[(value, weight)] -> (winner, share of the weight, {top 3})."""
    totals = Counter()
    for value, weight in pairs:
        if value and weight > 0:
            totals[value] += weight
    total = sum(totals.values())
    if not total:
        return None, 0.0, {}
    ranked = totals.most_common(3)
    return ranked[0][0], round(ranked[0][1] / total, 2), {v: round(w / total, 2) for v, w in ranked}


def _revote(entity, case=None):
    """The entity's combined details, voted over all its settled members."""
    linked = _linked(entity)
    a = {}
    if entity["kind"] == "person":
        for key in ("upper_clothing", "lower_clothing"):
            value, share, top = _vote(
                (m["attributes"].get(key),
                 (m["attributes"].get(f"{key}_confidence") or 0)
                 * max(1, m["attributes"].get("clothing_views") or 1) ** 0.5)
                for m in linked)
            a[key], a[f"{key}_share"], a[f"{key}_top3"] = (value if share >= 0.4 else None), share, top
        a["face_visible"] = any(m["attributes"].get("face_visible") for m in linked)
        a["face_size_px"] = max((m["attributes"].get("face_size_px") or 0 for m in linked), default=0)
        cover = max(linked, key=lambda m: (m["attributes"].get("face_size_px") or 0,
                                           len(m["crops"])), default=None)
    elif entity["kind"] == "vehicle":
        value, share, _ = _vote((m["attributes"].get("class_name"),
                                 m["attributes"].get("frames_seen") or 1) for m in linked)
        a["class_name"] = value
        for key, weight_key in (("make", "make_views"), ("colour", None)):
            value, share, top = _vote(
                (m["attributes"].get(key),
                 (m["attributes"].get(f"{key}_confidence") or 0)
                 * ((m["attributes"].get(weight_key) or 1) if weight_key else 1))
                for m in linked)
            a[key], a[f"{key}_share"], a[f"{key}_top3"] = (value if share >= 0.4 else None), share, top
        value, share, top = _vote(
            (m["attributes"].get("plate"),
             (m["attributes"].get("plate_confidence") or 0) * (m["attributes"].get("plate_reads") or 1))
            for m in linked)
        a["plate"], a["plate_share"], a["plate_top3"] = value, share, top
        a["plate_seen_in"] = len({m["submission"] for m in linked
                                  if value and m["attributes"].get("plate") == value})
        cover = max(linked, key=lambda m: (bool(m["attributes"].get("plate")),
                                           m["attributes"].get("make_views") or 0,
                                           m["attributes"].get("frames_seen") or 0), default=None)
    else:
        value, share, top = _vote(
            (m["attributes"].get("kind"),
             (m["attributes"].get("weapon_confidence") or 0) * (m["attributes"].get("frames_seen") or 1))
            for m in linked)
        a["kind"], a["kind_share"], a["kind_top3"] = value, share, top
        if case is not None:
            holder = next((e for e in case["entities"]
                           if e["entity_id"] == entity.get("held_by_entity")), None)
            a["held_by"] = holder["label"] if holder else None
        else:
            a["held_by"] = entity["attributes"].get("held_by")
        cover = linked[0] if linked else None
    a["submissions"] = sorted({m["submission"] for m in linked})
    entity["attributes"] = a
    entity["cover"] = cover["crops"][0]["path"] if cover and cover["crops"] else None


# ---------------------------------------------------------------------------
# Admin answers "Is this Person 2?"
# ---------------------------------------------------------------------------

def place_member(case, member):
    """Puts ONE member into its best entity (rejected pairs skipped), or
    into a new entity. Used after an admin's "No" (the worker's 'rematch'
    job). Returns the entity; member["status"] says how it was placed."""
    person_entity_of = {m["key"]: e["entity_id"] for e in case["entities"]
                        if e["kind"] == "person" for m in e["members"]}
    found = _candidates(member, case["entities"], case, person_entity_of)
    if found:
        decision, score, reasons, target = found[0]
        _link(member, target, "auto" if decision == "auto" else "suggested", score, reasons)
    else:
        target = _new_entity(case, member)
        if member["kind"] == "weapon":
            target["held_by_entity"] = person_entity_of.get(member.get("held_by"))
        _link(member, target, "first")
    _revote(target, case)
    return target


def revote_case(case):
    """Re-votes every entity's details and rewrites the summary (after an
    admin's answer, or a submission leaving the case)."""
    for entity in case["entities"]:
        _revote(entity, case)
    case["summary"] = summary_text(case)
    case["updated_at"] = datetime.now(timezone.utc).isoformat()


def open_questions(case):
    return [(e, m) for e in case["entities"] for m in e["members"] if m["status"] == "suggested"]


def confirm_match(case, member_key, accept):
    """Yes: the suggested member really is that entity. No: it is moved out
    (to another match or a new entity) and never suggested there again."""
    for entity in case["entities"]:
        for member in entity["members"]:
            if member["key"] == member_key and member["status"] == "suggested":
                break
        else:
            continue
        break
    else:
        raise ValueError(f"No open question for {member_key} in case {case['case_id']}")

    before = dict(entity["attributes"])
    if accept:
        member["status"] = "confirmed"
        result = f"{member_key} confirmed as {entity['label']}"
    else:
        entity["members"].remove(member)
        case["rejected"].append([member_key, entity["entity_id"]])
        target = place_member(case, member)
        if member["status"] == "first":
            result = f"{member_key} is not {entity['label']}; now {target['label']}"
        else:
            result = f"{member_key} is not {entity['label']}; " + (
                f"linked to {target['label']}" if member["status"] == "auto"
                else f"asking about {target['label']} instead")
    _revote(entity, case)
    for field in _SHOWN_FIELDS[entity["kind"]]:
        if before.get(field) != entity["attributes"].get(field):
            entity["updated"].append({"field": field, "old": before.get(field),
                                      "new": entity["attributes"].get(field),
                                      "submission": member["submission"]})
    case["summary"] = summary_text(case)
    case["updated_at"] = datetime.now(timezone.utc).isoformat()
    return result


# ---------------------------------------------------------------------------
# Suggesting cases for a new submission
# ---------------------------------------------------------------------------

def suggest_cases(sub, cases, limit=3):
    """[{case_id, title, score, distance_km, hours_apart, reasons}], best first."""
    suggestions = []
    for case in cases:
        if case.get("status", "open") == "closed":
            continue
        if any(s["submission"] == sub["submission"] for s in case["submissions"]):
            continue
        kms = [d for d in (distance_km(sub["location"], s["location"]) for s in case["submissions"])
               if d is not None]
        gaps = [h for h in (_hours_apart(sub["capture_time"], s["capture_time"])
                            for s in case["submissions"]) if h is not None]
        km = min(kms) if kms else None
        hours = min(gaps) if gaps else None
        near = km is not None and km <= SUGGEST_KM
        in_time = hours is None or hours <= SUGGEST_DAYS * 24

        evidence, ev_score = _evidence(case, sub)
        plate_hit = any(r.startswith(("same plate", "similar plate")) for r in evidence)
        if not ((near and in_time) or plate_hit):
            continue

        score, reasons = 0, []
        if near:
            score += 40 if km <= 0.3 else 30
            reasons.append(f"{_fmt_km(km)} apart (GPS)")
        if hours is not None and in_time:
            score += 30 if hours <= 2 else 20 if hours <= 24 else 10
            reasons.append(f"filmed {_fmt_gap(hours)} apart")
        score += ev_score
        reasons += evidence
        suggestions.append({"case_id": case["case_id"], "title": case["title"], "score": score,
                            "distance_km": None if km is None else round(km, 3),
                            "hours_apart": None if hours is None else round(hours, 1),
                            "reasons": reasons})
    suggestions.sort(key=lambda s: -s["score"])
    return suggestions[:limit]


def _evidence(case, sub):
    """What the submission has in common with the case (no changes made)."""
    reasons, score = [], 0
    vehicles = [e for e in case["entities"] if e["kind"] == "vehicle"]
    people = [e for e in case["entities"] if e["kind"] == "person"]
    best_vehicle, best_person = (None, 0), (None, 0)
    for m in sub["members"]:
        if m["kind"] == "vehicle":
            for e in vehicles:
                decision, s, why = compare_vehicle(m, e)
                if decision and s > best_vehicle[1]:
                    best_vehicle = (f"{why[0]} ({e['label']})", s)
        elif m["kind"] == "person":
            for e in people:
                decision, s, why = compare_person(m, e)
                if decision and s > best_person[1]:
                    best_person = (f"may show {e['label']} ({why[0]})", s)
    if best_vehicle[0]:
        reasons.append(best_vehicle[0])
        score += 40 if best_vehicle[1] >= 1.0 else 25 if best_vehicle[1] >= 0.9 else 10
    if best_person[0]:
        reasons.append(best_person[0])
        score += 15
    return reasons, score


# ---------------------------------------------------------------------------
# What the case screen shows
# ---------------------------------------------------------------------------

def describe(entity):
    a = entity["attributes"]
    if entity["kind"] == "person":
        parts = []
        if a.get("upper_clothing") or a.get("lower_clothing"):
            parts.append(f"top {clothing_word(a.get('upper_clothing'))}, "
                         f"bottom {clothing_word(a.get('lower_clothing'))}")
        parts.append("face seen" if a.get("face_visible") else "no clear face")
        return " · ".join(parts)
    if entity["kind"] == "vehicle":
        look = " ".join(x for x in (a.get("colour"), a.get("make"), a.get("class_name")) if x)
        parts = [look or "vehicle"]
        if a.get("plate"):
            seen = a.get("plate_seen_in", 1)
            parts.append(f"plate {a['plate']}" + (f" (read in {seen} submissions)" if seen > 1 else ""))
        else:
            parts.append("no readable plate")
        return " · ".join(parts)
    kind = (a.get("kind") or "unsure").replace("_", " ")
    return kind + (f" · held by {a['held_by']}" if a.get("held_by") else "")


def summary_text(case):
    """Plain summary for the top of the case (a Claude-written one can
    replace it later: same place in the data, 'ai_summary')."""
    subs = case["submissions"]
    times = sorted(t for t in (_time(s["capture_time"]) for s in subs) if t)
    people = [e for e in case["entities"] if e["kind"] == "person"]
    vehicles = [e for e in case["entities"] if e["kind"] == "vehicle"]
    weapons = [e for e in case["entities"] if e["kind"] == "weapon"]
    when = ""
    if times:
        first, last = times[0].strftime("%d %b %H:%M"), times[-1].strftime("%d %b %H:%M")
        when = f", filmed {first}" + (f" to {last}" if last != first else "")
    text = (f"{len(subs)} submission{'s' if len(subs) != 1 else ''}{when}. "
            f"AI found {len(people)} {'person' if len(people) == 1 else 'people'}, "
            f"{len(vehicles)} vehicle{'s' if len(vehicles) != 1 else ''} and "
            f"{len(weapons)} weapon{'s' if len(weapons) != 1 else ''}.")
    held = defaultdict(list)                  # Person 1 -> [handgun, long gun]
    for e in weapons:
        holder, kind = e["attributes"].get("held_by"), e["attributes"].get("kind")
        kind = (kind or "weapon").replace("_", " ")
        if holder and kind not in held[holder]:
            held[holder].append(kind)
    for holder, kinds in held.items():
        text += f" {holder} was seen with a " + " and a ".join(kinds) + "."
    plated = [e for e in vehicles if e["attributes"].get("plate")]
    for e in plated[:2]:
        text += f" {e['label']}: {describe(e)}."
    many = [e for e in people + vehicles if len(e["attributes"].get("submissions", [])) > 1]
    if many:
        text += " Seen in more than one submission: " + ", ".join(e["label"] for e in many) + "."
    questions = len(open_questions(case))
    if questions:
        text += f" {questions} possible match{'es' if questions != 1 else ''} to review."
    text += " AI-generated - check against the footage."
    return text[:600]


def case_view(case):
    """Everything the case screen needs (also what the app will get from
    Supabase later)."""
    sub_info = {s["submission"]: s for s in case["submissions"]}

    def crops_of(members):
        out = []
        for m in members:
            for c in m["crops"]:
                out.append({"path": c["path"], "type": c["type"], "submission": m["submission"],
                            "file_name": m["file_name"], "track_id": m["track_id"],
                            "seen_seconds": m["first_seen"], "capture_time": m["capture_time"]})
        return out

    def entity_view(e):
        settled = _linked(e)
        return {
            "entity_id": e["entity_id"],
            "kind": e["kind"],
            "label": e["label"],
            "description": describe(e),
            "attributes": {k: v for k, v in e["attributes"].items() if not k.endswith("_top3")},
            "cover": e.get("cover"),
            "submission_count": len({m["submission"] for m in settled}),
            "crops": crops_of(settled),
            "questions": [{"member_key": m["key"], "submission": m["submission"],
                           "file_name": m["file_name"], "score": m["score"],
                           "reasons": m["reasons"], "crops": crops_of([m])}
                          for m in e["members"] if m["status"] == "suggested"],
            "updated": e["updated"][-5:],
        }

    groups = {k: [entity_view(e) for e in case["entities"] if e["kind"] == k]
              for k in ("person", "vehicle", "weapon")}
    return {
        "case_id": case["case_id"],
        "title": case["title"],
        "ai_summary": case.get("summary") or summary_text(case),
        "submissions": [{"submission": s["submission"], "capture_time": s["capture_time"],
                         "location": s["location"], "file_count": len(s["files"])}
                        for s in sub_info.values()],
        "counts": {"people": len(groups["person"]), "vehicles": len(groups["vehicle"]),
                   "weapons": len(groups["weapon"])},
        "open_questions": len(open_questions(case)),
        "people": groups["person"],
        "vehicles": groups["vehicle"],
        "weapons": groups["weapon"],
    }


# ---------------------------------------------------------------------------
# Cases on disk (until Supabase)
# ---------------------------------------------------------------------------

def new_case(case_id, title):
    return {"case_id": case_id, "title": title, "status": "open",
            "created_at": datetime.now(timezone.utc).isoformat(), "updated_at": None,
            "submissions": [], "entities": [], "rejected": [], "counters": {}, "summary": None}


def load_cases(folder=CASES_DIR):
    folder = Path(folder)
    return [json.loads(p.read_text(encoding="utf-8"))
            for p in sorted(folder.glob("case_*.json"))] if folder.is_dir() else []


def load_case(case_id, folder=CASES_DIR):
    path = Path(folder) / f"case_{int(case_id)}.json"
    if not path.is_file():
        raise SystemExit(f"No case {case_id} (looked for {path})")
    return json.loads(path.read_text(encoding="utf-8"))


def save_case(case, folder=CASES_DIR):
    folder = Path(folder)
    folder.mkdir(exist_ok=True)
    path = folder / f"case_{case['case_id']}.json"
    path.write_text(json.dumps(case, indent=1), encoding="utf-8")
    return path


def _print_report(report):
    for key, label in report["new"]:
        print(f"  {key:24} -> new {label}")
    for key, label, score, reasons in report["linked"]:
        print(f"  {key:24} -> {label}  ({'; '.join(reasons)})")
    for key, label, score, reasons in report["questions"]:
        print(f"  {key:24} -> Is this {label}?  ({'; '.join(reasons)})")
    for label, field, old, new in report["updated"]:
        print(f"  updated {label}: {field} {old!r} -> {new!r}")


def _print_case(case):
    view = case_view(case)
    print(f"Case {view['case_id']}: {view['title']}")
    print(f"AI summary: {view['ai_summary']}")
    c = view["counts"]
    print(f"{c['people']} people, {c['vehicles']} vehicles, {c['weapons']} weapons"
          f" - {view['open_questions']} open question(s)")
    for group in ("people", "vehicles", "weapons"):
        for e in view[group]:
            print(f"  {e['label']:10} {e['description']:55} "
                  f"{len(e['crops'])} crop(s), {e['submission_count']} submission(s)")
            for q in e["questions"]:
                print(f"      ? {q['member_key']}: is this {e['label']}? ({'; '.join(q['reasons'])})")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Suggest cases and combine submissions into cases.")
    parser.add_argument("--cases", default=str(CASES_DIR), help="folder with the case_N.json files")
    sub = parser.add_subparsers(dest="command", required=True)

    def with_location(p):
        p.add_argument("--lat", type=float, help="phone latitude (when the files have no GPS)")
        p.add_argument("--lon", type=float, help="phone longitude")

    p = sub.add_parser("suggest", help="which cases a submission probably belongs to")
    p.add_argument("results")
    with_location(p)
    p = sub.add_parser("create", help="new case from a submission")
    p.add_argument("results")
    p.add_argument("--title", required=True)
    with_location(p)
    p = sub.add_parser("add", help="add an accepted submission to a case")
    p.add_argument("case_id", type=int)
    p.add_argument("results")
    with_location(p)
    p = sub.add_parser("questions", help="open 'Is this Person 2?' questions")
    p.add_argument("case_id", type=int)
    p = sub.add_parser("confirm", help="answer a question")
    p.add_argument("case_id", type=int)
    p.add_argument("member_key")
    p.add_argument("answer", choices=["yes", "no"])
    p = sub.add_parser("show", help="print a case")
    p.add_argument("case_id", type=int)
    p = sub.add_parser("view", help="the case screen's data as JSON")
    p.add_argument("case_id", type=int)
    args = parser.parse_args(argv)
    folder = Path(args.cases)

    if args.command == "suggest":
        record = load_submission(args.results, args.lat, args.lon)
        if not record["location"]:
            print("This submission has no GPS (none in the files; give --lat/--lon): "
                  "only a matching plate can suggest a case.")
        found = suggest_cases(record, load_cases(folder))
        if not found:
            print(f"No case suggested for submission {record['submission']}.")
        for s in found:
            print(f"Suggested: case {s['case_id']} '{s['title']}' (score {s['score']}): "
                  + "; ".join(s["reasons"]))
    elif args.command == "create":
        record = load_submission(args.results, args.lat, args.lon)
        case_id = max((c["case_id"] for c in load_cases(folder)), default=0) + 1
        case = new_case(case_id, args.title)
        report = merge_submission(case, record)
        print(f"Created case {case_id} from submission {record['submission']}: {save_case(case, folder)}")
        _print_report(report)
    elif args.command == "add":
        case = load_case(args.case_id, folder)
        record = load_submission(args.results, args.lat, args.lon)
        report = merge_submission(case, record)
        save_case(case, folder)
        print(f"Added submission {record['submission']} to case {args.case_id}:")
        _print_report(report)
    elif args.command == "questions":
        case = load_case(args.case_id, folder)
        questions = open_questions(case)
        if not questions:
            print("No open questions.")
        for entity, m in questions:
            print(f"  {m['key']}: is this {entity['label']}? ({'; '.join(m['reasons'])})")
    elif args.command == "confirm":
        case = load_case(args.case_id, folder)
        print(confirm_match(case, args.member_key, args.answer == "yes"))
        save_case(case, folder)
    elif args.command == "show":
        _print_case(load_case(args.case_id, folder))
    elif args.command == "view":
        json.dump(case_view(load_case(args.case_id, folder)), sys.stdout, indent=1)
        print()


if __name__ == "__main__":
    main()
