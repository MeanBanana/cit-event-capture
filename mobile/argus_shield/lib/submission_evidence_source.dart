// submission_evidence_source.dart — the people / vehicles / weapons the AI
// found in ONE submission (before or without a case), in the same shape as a
// case's evidence, so the submission page can reuse the case screens: the
// cards with View, the 3-column pictures grid, the enlarged picture with
// Download.
//
// Each tracked object in each clip is one card (Person 1, Vehicle 1 ...).
// Combining the same person across clips / submissions happens when the
// submission is accepted into a case (the case page shows that).
//
// Reads the detection rows the AI worker saved (ai_save_analysis): admins and
// investigators on the case may read them (RLS), citizens never.

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:argus_shield/case_evidence_source.dart';
import 'package:argus_shield/models/case_evidence.dart';

class SubmissionEvidenceSource extends SupabaseEvidenceSource {
  /// [client] only for tests; the app uses Supabase.instance.client.
  SubmissionEvidenceSource([SupabaseClient? client])
      : _client2 = client,
        super(client);

  final SupabaseClient? _client2;
  SupabaseClient get _db => _client2 ?? Supabase.instance.client;

  /// [incidentId] (not a case id): this submission's detections.
  @override
  Future<CaseEvidence?> load(int incidentId) async {
    try {
      final media = await _db
          .from('media')
          .select('mediaid, storagepath')
          .eq('incidentid', incidentId)
          .order('mediaid') as List;
      if (media.isEmpty) return null;
      final clipNumber = {
        for (var i = 0; i < media.length; i++) (media[i]['mediaid'] as num).toInt(): i + 1,
      };
      final rows = await _db
          .from('detection')
          .select('detectionid, mediaid, detectiontype, trackid, firstseen, attributes, crops')
          .inFilter('mediaid', clipNumber.keys.toList())
          .order('mediaid')
          .order('firstseen') as List;
      if (rows.isEmpty) return null;

      final weaponIds = [
        for (final r in rows)
          if (r['detectiontype'] == 'weapon') (r['detectionid'] as num).toInt(),
      ];
      final heldBy = <int, int>{};
      if (weaponIds.isNotEmpty) {
        final wd = await _db
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

  /// One submission has no "Is this Person 2?" questions.
  @override
  Future<void> answer(int caseId, String memberKey, {required bool yes}) async {}
}

/// The get_case_evidence-shaped map for one submission's detection rows
/// (separate from the database calls so it can be tested).
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

  // people first, so weapons can say who held them
  final sorted = [...rows]..sort((a, b) {
      const order = {'person': 0, 'vehicle': 1, 'weapon': 2};
      return (order[a['detectiontype']] ?? 3).compareTo(order[b['detectiontype']] ?? 3);
    });

  for (final r in sorted) {
    final kind = r['detectiontype'] as String;
    if (!groups.containsKey(kind)) continue;
    final id = (r['detectionid'] as num).toInt();
    final number = counters[kind] = (counters[kind] ?? 0) + 1;
    final label = '${kind[0].toUpperCase()}${kind.substring(1)} $number';
    labelOf[id] = label;
    final a = Map<String, dynamic>.from((r['attributes'] as Map?) ?? const {});
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
      'kind': kind,
      'label': label,
      'description': describeDetection(kind, attributes),
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

/// "top black, bottom blue · face seen" / "white Toyota car · plate ND123456"
/// / "long gun · held by Person 1" (same wording as the case page).
String describeDetection(String kind, Map<String, dynamic> a) {
  String? text(String key) {
    final v = a[key];
    return v == null || (v is String && v.isEmpty) ? null : v.toString().replaceAll('_', ' ');
  }

  switch (kind) {
    case 'person':
      final parts = <String>[];
      if (text('upper_clothing') != null || text('lower_clothing') != null) {
        parts.add('top ${text('upper_clothing') ?? 'unsure'}, '
            'bottom ${text('lower_clothing') ?? 'unsure'}');
      }
      parts.add(a['face_visible'] == true ? 'face seen' : 'no clear face');
      return parts.join(' · ');
    case 'vehicle':
      final look = [text('colour'), text('make'), text('class_name')].whereType<String>().join(' ');
      final plate = text('plate');
      return '${look.isEmpty ? 'vehicle' : look} · '
          '${plate == null ? 'no readable plate' : 'plate $plate'}';
    default:
      final held = text('held_by');
      return '${text('kind') ?? 'unsure'}${held == null ? '' : ' · held by $held'}';
  }
}
