// In-memory stand-in for SupabaseService for the crime scene/corrections
// tests. Each scene is kept as the JSON get_crime_scene would return, and
// corrections get applied the way correct_detection does them (value,
// corrected flag, log entry), so a test can correct something and watch the
// page update.
//
// Every call gets logged in [calls], e.g. 'correct:12:plate:ND654321:Clear'.
// No "_test" in the name so `flutter test` doesn't run it on its own.

import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/models/case_summary.dart';
import 'package:argus_shield/models/crime_scene.dart';
import 'package:argus_shield/models/submission_groups.dart';

/// A detection, shaped like get_crime_scene returns it.
Map<String, dynamic> fakeDetection(
  int id,
  String kind,
  int number,
  Map<String, String?> fields, {
  int clip = 1,
  bool canCorrect = true,
}) =>
    {
      'detection_id': id,
      'kind': kind,
      'label': '${kind[0].toUpperCase()}${kind.substring(1)} $number',
      'media_id': 100 + clip,
      'clip': clip,
      'first_seen': 12.0,
      'crops': [
        {'path': '42/ai/run/1_clip/${kind}_$number.png', 'type': kind},
      ],
      'dismissed': false,
      'suspect_status': kind == 'person' ? 'possible' : null,
      'can_correct': canCorrect,
      'fields': [
        for (final f in fields.entries)
          {'field': f.key, 'ai': f.value, 'value': f.value, 'corrected': false},
        {'field': 'dismissed', 'ai': 'false', 'value': 'false', 'corrected': false},
      ],
      'correction_count': 0,
    };

/// A crime scene shaped like get_crime_scene returns it. [status] is one of
/// 'done', 'pending', 'analysing', 'failed', 'no_footage'.
Map<String, dynamic> fakeScene(
  int incidentId, {
  int caseId = 3,
  String status = 'done',
  bool caseClosed = false,
  String location = 'Rivonia Rd, Sandton',
  String? description = 'Two men with a rifle stopped the cash van.',
  List<Map<String, dynamic>>? detections,
}) {
  final done = status == 'done';
  return {
    'incident_id': incidentId,
    'case_id': caseId,
    'case_title': 'N1 Midrand CIT robbery',
    'case_closed': caseClosed,
    'location': location,
    'description': description,
    'attack_type': 'CIT robbery',
    'datetime': '2026-10-12T10:00:00Z',
    'captured_at': done ? '2026-10-12T10:01:00Z' : null,
    'latitude': -26.1076,
    'longitude': 28.0567,
    'gps_source': 'file',
    'review_status': 'accepted',
    'ai_summary': done ? '1 person with a long gun, 1 white Toyota.' : null,
    'ai_summary_status': done ? 'ready' : 'processing',
    'analysis': {'status': status, 'files': 1, 'done': done ? 1 : 0, 'failed': 0},
    'can_correct': done && !caseClosed,
    'files': [
      {
        'media_id': 101,
        'number': 1,
        'media_type': 'video',
        'storage_path': '$incidentId/media/clip1.mp4',
        'status': done ? 'completed' : (status == 'analysing' ? 'processing' : 'pending'),
        'captured_at': done ? '2026-10-12T10:01:00Z' : null,
        'ai_description': done ? 'A man with a long gun next to a white car.' : null,
      },
    ],
    'detections': done
        ? (detections ??
            [
              fakeDetection(11, 'person', 1,
                  {'upper_clothing': 'black', 'lower_clothing': 'blue'},
                  canCorrect: !caseClosed),
              fakeDetection(12, 'vehicle', 1, {
                'vehicle_type': 'car',
                'make': 'Toyota',
                'model': null,
                'colour': 'white',
                'plate': 'ND123456',
              }, canCorrect: !caseClosed),
              fakeDetection(13, 'weapon', 1, {'weapon_type': 'long_gun'},
                  canCorrect: !caseClosed),
            ])
        : <Map<String, dynamic>>[],
    'corrections': <Map<String, dynamic>>[],
  };
}

/// A card row, shaped like list_case_crime_scenes returns it.
Map<String, dynamic> fakeCardRow(
  int incidentId, {
  String status = 'done',
  String location = 'Rivonia Rd, Sandton',
  String? description = 'Two men with a rifle stopped the cash van.',
  int suspects = 1,
  int vehicles = 1,
  int weapons = 1,
}) =>
    {
      'incidentid': incidentId,
      'location': location,
      'description': description,
      'attacktype': 'CIT robbery',
      'datetime': '2026-10-12T10:00:00Z',
      'capturedat': null,
      'reviewstatus': 'accepted',
      'mediacount': 1,
      'suspects': suspects,
      'confirmedsuspects': 0,
      'vehicles': vehicles,
      'weapons': weapons,
      'analysisstatus': status,
      'filesdone': status == 'done' ? 1 : 0,
      'filesfailed': 0,
      'correctioncount': 0,
    };

class CrimeSceneFakeService extends SupabaseService {
  CrimeSceneFakeService({
    List<Map<String, dynamic>>? cards,
    List<Map<String, dynamic>>? scenes,
    this.caseStatus = 'open',
  })  : cards = cards ?? [],
        scenes = {for (final s in scenes ?? const []) s['incident_id'] as int: s};

  final List<Map<String, dynamic>> cards;
  final Map<int, Map<String, dynamic>> scenes;
  final String caseStatus;
  final List<String> calls = [];

  /// Make correctDetection fail with this database message.
  String? failWith;

  /// How many of the next getCrimeScene calls should fail (e.g. no network).
  int failLoads = 0;

  @override
  Future<CaseSummary?> getCase(int caseId) async => CaseSummary(
        caseId: caseId,
        title: 'N1 Midrand CIT robbery',
        status: caseStatus,
        dateCreated: DateTime(2026, 10, 12),
        incidentCount: cards.length,
      );

  @override
  Future<List<CaseEvent>> getCaseEvents(int caseId,
          {CaseEvent? before, int limit = 30}) async =>
      const [];

  @override
  Future<List<CrimeSceneCardInfo>> listCaseCrimeScenes(int caseId) async {
    calls.add('listCaseCrimeScenes:$caseId');
    return [for (final c in cards) CrimeSceneCardInfo.fromMap(c)];
  }

  @override
  Future<CrimeSceneDetail?> getCrimeScene(int incidentId) async {
    calls.add('getCrimeScene:$incidentId');
    if (failLoads > 0) {
      failLoads--;
      throw Exception('No internet connection');
    }
    final s = scenes[incidentId];
    return s == null ? null : CrimeSceneDetail.fromMap(s);
  }

  @override
  Future<void> correctDetection(int detectionId, String field, String? value,
      {String? note}) async {
    final text = note?.trim() ?? '';
    calls.add('correct:$detectionId:$field:${value ?? ''}:$text');
    if (failWith != null) {
      throw PostgrestException(message: failWith!);
    }
    for (final s in scenes.values) {
      for (final d in (s['detections'] as List).cast<Map<String, dynamic>>()) {
        if (d['detection_id'] != detectionId) continue;
        final f = (d['fields'] as List)
            .cast<Map<String, dynamic>>()
            .firstWhere((x) => x['field'] == field);
        final old = f['value'] as String?;
        f['value'] = value;
        f['corrected'] = value != f['ai'];
        if (field == 'dismissed') d['dismissed'] = value == 'true';
        d['correction_count'] = (d['correction_count'] as int) + 1;
        (s['corrections'] as List).insert(0, {
          'correction_id': (s['corrections'] as List).length + 1,
          'incident_id': s['incident_id'],
          'detection_id': detectionId,
          'label': d['label'],
          'field': field,
          'original': old,
          'corrected': value,
          'note': text.isEmpty ? null : text,
          'by': 'Thabo Mokoena',
          'at': '2026-10-13T09:30:00Z',
        });
        return;
      }
    }
    throw PostgrestException(message: 'Detection $detectionId not found');
  }
}
