-- New rule for suggesting cases.
--
-- All the suggestion functions (suggest_cases_for_incident,
-- list_suggested_matches, suggest_incidents_for_case, case_card_suggestions)
-- score pairs with match_incidents(), so that's the only thing changing. Same
-- arguments and result, so nothing changes in the app.
--
--                       before               now
--   place (GPS)         <= 5km +30           <= 1km +30, <= 300m +40
--   place (no GPS)      same text +20        same text +20, but only when one
--                                            side has no GPS
--   time                <= 2h +30            <= 2h +30, <= 24h +20,
--                       <= 24h +10           <= 14 days +10
--   plate, AI link,     unchanged            unchanged
--   look-alike vehicle
--   shown when          score >= 30          near (<= 1km, or same text with
--                                            no GPS) AND <= 14 days apart, OR
--                                            same/1-char-off plate, OR an AI link
--
-- There's also a new reason with no points attached (mirrors
-- case_matcher._evidence): "may show Person 2 (looks 81% alike)" when someone
-- in one submission looks like a person already in the other's case. Uses
-- pgvector with the same formula and 0.78 cut-off as ai/appearance.py.
--
-- Plate reasons start working on their own now that the worker fills
-- vehicledetail. list_suggested_matches keeps its minimum score (the app asks
-- for 60 in the bulk list), the per-submission suggestions show everything
-- the rule lets through. And as always nothing joins a case without an admin.

CREATE OR REPLACE FUNCTION public.match_incidents(p_candidates integer[], p_targets integer[])
  RETURNS TABLE (candidateid integer, targetid integer, score integer, reasons text[])
  LANGUAGE sql STABLE
  SET search_path = ''
AS $$
  WITH
  inc AS (
    SELECT cs.incidentid, cs.latitude, cs.longitude, cs.locationkey,
           COALESCE(cap.t, cs.datetime) AS t,
           cap.t IS NOT NULL AS filmed       -- true if the time came from the footage
    FROM public.crimescene cs
    LEFT JOIN LATERAL (
      SELECT min(m.capturetimestamp) AS t
      FROM public.media m WHERE m.incidentid = cs.incidentid
    ) cap ON true
    WHERE cs.incidentid = ANY (p_candidates || p_targets)
  ),
  plates AS (
    SELECT DISTINCT m.incidentid, public.normalize_plate(v.licenceplatenumber) AS plate
    FROM public.media m
    JOIN public.detection d     ON d.mediaid = m.mediaid
    JOIN public.vehicledetail v ON v.detectionid = d.detectionid
    WHERE m.incidentid = ANY (p_candidates || p_targets)
      AND public.normalize_plate(v.licenceplatenumber) IS NOT NULL
  ),
  vehicles AS (
    SELECT DISTINCT m.incidentid,
           lower(trim(v.colour)) || ' ' || initcap(trim(v.make)) AS look
    FROM public.media m
    JOIN public.detection d     ON d.mediaid = m.mediaid
    JOIN public.vehicledetail v ON v.detectionid = d.detectionid
    WHERE m.incidentid = ANY (p_candidates || p_targets)
      AND NULLIF(trim(v.colour), '') IS NOT NULL
      AND NULLIF(trim(v.make), '') IS NOT NULL
  ),
  -- people with a fingerprint. label is the case person they were merged
  -- into ('Person 2'), once that's settled
  people AS (
    SELECT m.incidentid, d.appearance, d.colourhist,
           CASE WHEN d.matchstatus IN ('first', 'auto', 'confirmed')
                THEN initcap(e.kind) || ' ' || e.number END AS label
    FROM public.media m
    JOIN public.detection d ON d.mediaid = m.mediaid
    LEFT JOIN public.caseentity e ON e.entityid = d.caseentityid
    WHERE m.incidentid = ANY (p_candidates || p_targets)
      AND d.detectiontype = 'person'
      AND (d.appearance IS NOT NULL OR d.colourhist IS NOT NULL)
  ),
  links AS (
    SELECT * FROM public.incident_links() l
    WHERE l.incident_a = ANY (p_candidates || p_targets)
      AND l.incident_b = ANY (p_candidates || p_targets)
  ),
  pairs AS (
    SELECT c.incidentid AS cid, t.incidentid AS tid,
           (SELECT bool_or(l.verified) FROM links l
             WHERE (l.incident_a, l.incident_b) IN ((c.incidentid, t.incidentid),
                                                    (t.incidentid, c.incidentid))) AS link_verified,
           (SELECT max(l.matchconfidence) FROM links l
             WHERE (l.incident_a, l.incident_b) IN ((c.incidentid, t.incidentid),
                                                    (t.incidentid, c.incidentid))) AS link_conf,
           (SELECT min(p1.plate) FROM plates p1
              JOIN plates p2 ON p2.plate = p1.plate
             WHERE p1.incidentid = c.incidentid AND p2.incidentid = t.incidentid) AS plate,
           (SELECT min(p1.plate || ' / ' || p2.plate) FROM plates p1
              JOIN plates p2 ON public.plates_similar(p1.plate, p2.plate)
             WHERE p1.incidentid = c.incidentid AND p2.incidentid = t.incidentid) AS nearplate,
           CASE WHEN c.latitude IS NOT NULL AND t.latitude IS NOT NULL
                THEN public.distance_km(c.latitude, c.longitude, t.latitude, t.longitude)
           END AS km,
           c.locationkey = t.locationkey AS same_place,
           abs(extract(epoch FROM c.t - t.t)) / 60 AS minutes,
           c.filmed AND t.filmed AS both_filmed,
           (SELECT min(v1.look) FROM vehicles v1
              JOIN vehicles v2 ON v2.look = v1.look
             WHERE v1.incidentid = c.incidentid AND v2.incidentid = t.incidentid) AS look,
           (SELECT 'may show ' || x.label || ' (looks ' || round(x.sim * 100) || '% alike)'
              FROM (SELECT COALESCE(p2.label, p1.label) AS label,
                           public.appearance_similarity(p1.appearance, p1.colourhist,
                                                        p2.appearance, p2.colourhist) AS sim
                      FROM people p1
                      JOIN people p2 ON p2.incidentid = t.incidentid
                     WHERE p1.incidentid = c.incidentid
                       AND COALESCE(p2.label, p1.label) IS NOT NULL) x
             WHERE x.sim >= 0.78
             ORDER BY x.sim DESC, x.label
             LIMIT 1) AS person
    FROM inc c
    JOIN inc t ON t.incidentid = ANY (p_targets) AND t.incidentid <> c.incidentid
    WHERE c.incidentid = ANY (p_candidates)
  ),
  scored AS (
    SELECT p.*,
           -- near means GPS within 1km, or same typed place if one side has no GPS
           (p.km <= 1 OR (p.km IS NULL AND p.same_place)) AS near,
           CASE WHEN p.link_verified THEN 50
                WHEN p.link_verified IS NOT NULL THEN 35 ELSE 0 END
         + CASE WHEN p.plate IS NOT NULL THEN 40
                WHEN p.nearplate IS NOT NULL THEN 25 ELSE 0 END
         + CASE WHEN p.km <= 0.3 THEN 40
                WHEN p.km <= 1 THEN 30
                WHEN p.km IS NULL AND p.same_place THEN 20 ELSE 0 END
         + CASE WHEN p.minutes <= 120 THEN 30
                WHEN p.minutes <= 1440 THEN 20
                WHEN p.minutes <= 14 * 1440 THEN 10 ELSE 0 END
         + CASE WHEN p.look IS NOT NULL THEN 10 ELSE 0 END AS total
    FROM pairs p
  )
  SELECT s.cid, s.tid, s.total,
         array_remove(ARRAY[
           CASE WHEN s.link_verified THEN 'Verified AI link'
                WHEN s.link_verified IS NOT NULL
                  THEN 'AI link' || COALESCE(' (' || round(s.link_conf * 100) || '% match)', '')
           END,
           CASE WHEN s.plate IS NOT NULL THEN 'Same plate ' || s.plate
                WHEN s.nearplate IS NOT NULL
                  THEN 'Similar plate ' || s.nearplate || ' (1 character different)'
           END,
           CASE WHEN s.km IS NOT NULL
                  THEN CASE WHEN s.km < 1 THEN round(s.km * 1000) || ' m apart'
                            ELSE round(s.km, 1) || ' km apart' END
                WHEN s.same_place THEN 'Same location'
           END,
           CASE WHEN s.minutes < 1 THEN 'Same time'
                WHEN s.minutes <= 120 THEN round(s.minutes) || ' min apart'
                WHEN s.minutes <= 2880 THEN round(s.minutes / 60) || ' h apart'
                ELSE round(s.minutes / 1440) || ' days apart'
           END || CASE WHEN s.both_filmed THEN ' (video time)' ELSE '' END,
           CASE WHEN s.look IS NOT NULL THEN 'Both show a ' || s.look END,
           s.person
         ], NULL)
  FROM scored s
  WHERE (s.near AND s.minutes <= 14 * 1440)
     OR s.plate IS NOT NULL
     OR s.nearplate IS NOT NULL
     OR s.link_verified IS NOT NULL
$$;
