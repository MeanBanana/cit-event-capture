// The people/vehicles/weapons the AI found in a single submission, shaped like
// a case's evidence so the submission page can reuse the case widgets (cards,
// pictures grid, enlarged view with Download).
//
// Every tracked object in every clip gets its own card. Merging the same
// person across clips only happens once the submission is accepted into a
// case.
//
// Reads the detection rows the worker saved. Admins and investigators on the
// case can read them (RLS), citizens never can.

import 'package:flutter/foundation.dart';

import 'package:argus_shield/case_evidence_source.dart';
import 'package:argus_shield/models/case_evidence.dart';

class SubmissionEvidenceSource extends SupabaseEvidenceSource {
  /// [client] is only for tests, the app uses Supabase.instance.client.
  SubmissionEvidenceSource([super.client]);

  /// Takes an [incidentId], not a case id.
  @override
  Future<CaseEvidence?> load(int incidentId) async {
    try {
      final media = await db
          .from('media')
          .select('mediaid, storagepath')
          .eq('incidentid', incidentId)
          .order('mediaid') as List;
      if (media.isEmpty) return null;
      final clipNumber = {
        for (var i = 0; i < media.length; i++) (media[i]['mediaid'] as num).toInt(): i + 1,
      };
      final rows = await db
          .from('detection')
          .select('detectionid, mediaid, detectiontype, trackid, firstseen, attributes, crops, corrections')
          .inFilter('mediaid', clipNumber.keys.toList())
          // same order get_crime_scene numbers them in (see [byLabelOrder])
          .order('mediaid')
          .order('firstseen', nullsFirst: true)
          .order('detectionid') as List;
      if (rows.isEmpty) return null;

      final weaponIds = [
        for (final r in rows)
          if (r['detectiontype'] == 'weapon') (r['detectionid'] as num).toInt(),
      ];
      final heldBy = <int, int>{};
      if (weaponIds.isNotEmpty) {
        final wd = await db
            .from('weapondetail')
            .select('detectionid, heldbydetectionid')
            .inFilter('detectionid', weaponIds) as List;
        for (final w in wd) {
          if (w['heldbydetectionid'] != null) {
            heldBy[(w['detectionid'] as num).toInt()] = (w['heldbydetectionid'] as num).toInt();
          }
        }
      }
      return CaseEvidence.fromMap(
          buildSubmissionEvidence(incidentId, rows.cast<Map>(), clipNumber, heldBy));
    } catch (e) {
      debugPrint('Could not load the AI findings of incident $incidentId: $e');
      return null;
    }
  }

  /// A single submission never has "Is this Person 2?" questions.
  @override
  Future<void> answer(int caseId, String memberKey, {required bool yes}) async {}

  /// Each clip's people stay separate on purpose, merging only happens in a case.
  @override
  bool get canCombine => false;

  @override
  Future<String> combine(int caseId, String fromId, String intoId) =>
      throw UnsupportedError('Combine people in the case, not in one submission.');
}

/// Corrected field (detection.corrections) -> the attribute it overrides.
const correctedAttribute = <String, String>{
  'upper_clothing': 'upper_clothing',
  'lower_clothing': 'lower_clothing',
  'vehicle_type': 'class_name',
  'make': 'make',
  'model': 'model',
  'colour': 'colour',
  'plate': 'plate',
  'weapon_type': 'class_name',
};

/// Builds the get_case_evidence-shaped map from one submission's detection
/// rows. Kept apart from the database calls so it can be tested.
Map<String, dynamic> buildSubmissionEvidence(
  int incidentId,
  List<Map> rows,
  Map<int, int> clipNumber,
  Map<int, int> heldBy,
) {
  final counters = <String, int>{};
  final labelOf = <int, String>{};
  final groups = <String, List<Map<String, dynamic>>>{
    'person': [], 'vehicle': [], 'weapon': [],
  };

  // people first so weapons can say who was holding them
  final sorted = [...rows]..sort(byLabelOrder);

  for (final r in sorted) {
    final kind = r['detectiontype'] as String;
    if (!groups.containsKey(kind)) continue;
    final id = (r['detectionid'] as num).toInt();
    final number = counters[kind] = (counters[kind] ?? 0) + 1;
    final label = '${kind[0].toUpperCase()}${kind.substring(1)} $number';
    labelOf[id] = label;
    final a = Map<String, dynamic>.from((r['attributes'] as Map?) ?? const {});
    // investigator corrections beat the AI
    final fixes = Map<String, dynamic>.from((r['corrections'] as Map?) ?? const {});
    for (final fix in fixes.entries) {
      final key = correctedAttribute[fix.key];
      if (key != null) a[key] = fix.value;
    }
    final dismissed = fixes['dismissed'] == true;
    final clip = clipNumber[(r['mediaid'] as num).toInt()] ?? 1;
    final seen = ((r['firstseen'] as num?) ?? 0).toDouble();

    final attributes = switch (kind) {
      'person' => {
          'upper_clothing': a['upper_clothing'],
          'upper_clothing_share': a['upper_clothing_confidence'],
          'lower_clothing': a['lower_clothing'],
          'lower_clothing_share': a['lower_clothing_confidence'],
          'face_visible': a['face_visible'] == true,
        },
      'vehicle' => {
          'class_name': a['class_name'],
          'make': a['make'],
          'make_share': a['make_confidence'],
          'model': a['model'],
          'colour': a['colour'],
          'colour_share': a['colour_confidence'],
          'plate': a['plate'],
          'plate_share': a['plate_confidence'],
        },
      _ => {
          'kind': a['class_name'],
          'kind_share': a['weapon_confidence'],
          'held_by': labelOf[heldBy[id]],
        },
    };

    final crops = [
      for (final c in ((r['crops'] as List?) ?? const []))
        {
          'path': (c as Map)['path'],
          'type': c['type'],
          'submission': incidentId,
          'file_name': 'Clip $clip',
          'seen_seconds': seen,
        },
    ];

    groups[kind]!.add({
      'entity_id': '${kind[0]}$number',
      'detection_id': id,
      'kind': kind,
      'label': label,
      'description': dismissed
          ? 'not a real $kind (an investigator dismissed it)'
          : describeDetection(kind, attributes),
      'clip': clip,
      'attributes': attributes,
      'cover': crops.isEmpty ? null : crops.first['path'],
      'submission_count': 1,
      'crops': crops,
      'questions': const [],
      'updated': const [],
    });
  }

  return {
    'case_id': incidentId,
    'ai_summary': '',
    'open_questions': 0,
    'people': groups['person'],
    'vehicles': groups['vehicle'],
    'weapons': groups['weapon'],
  };
}

/// The order detections get numbered in (Person 1, Person 2...). By kind,
/// then the same as get_crime_scene / detection_label in the database: clip,
/// first seen (unknowns first), then detectionid. It's a total order so the
/// numbers never depend on what order the rows came back in.
int byLabelOrder(Map a, Map b) {
  const order = {'person': 0, 'vehicle': 1, 'weapon': 2};
  int num0(Map r, String key) => (r[key] as num).toInt();
  var c = (order[a['detectiontype']] ?? 3).compareTo(order[b['detectiontype']] ?? 3);
  if (c != 0) return c;
  c = num0(a, 'mediaid').compareTo(num0(b, 'mediaid'));
  if (c != 0) return c;
  final sa = a['firstseen'] as num?, sb = b['firstseen'] as num?;
  if (sa == null || sb == null) {
    c = sa == null ? (sb == null ? 0 : -1) : 1;
  } else {
    c = sa.compareTo(sb);
  }
  if (c != 0) return c;
  return num0(a, 'detectionid').compareTo(num0(b, 'detectionid'));
}

/// e.g. "top black, bottom blue · face seen", "white Toyota car · plate
/// ND123456", "long gun · held by Person 1". Same wording as the case page.
String describeDetection(String kind, Map<String, dynamic> a) {
  String? text(String key) {
    final v = a[key];
    return v == null || (v is String && v.isEmpty) ? null : v.toString().replaceAll('_', ' ');
  }

  switch (kind) {
    case 'person':
      final parts = <String>[];
      if (text('upper_clothing') != null || text('lower_clothing') != null) {
        parts.add('top ${clothingWord(text('upper_clothing'))}, '
            'bottom ${clothingWord(text('lower_clothing'))}');
      }
      parts.add(a['face_visible'] == true ? 'face seen' : 'no clear face');
      return parts.join(' · ');
    case 'vehicle':
      final look = [text('colour'), text('make'), text('model'), text('class_name')]
          .whereType<String>()
          .join(' ');
      final plate = text('plate');
      return '${look.isEmpty ? 'vehicle' : look} · '
          '${plate == null ? 'no readable plate' : 'plate $plate'}';
    default:
      final held = text('held_by');
      return '${text('kind') ?? 'unsure'}${held == null ? '' : ' · held by $held'}';
  }
}
