// case_evidence_source.dart — where the case screen gets the AI's combined
// people / vehicles / weapons and their pictures from.
//
// For now: a SAMPLE bundled with the app (assets/sample_case/), made by
// running the real pipeline + ai/case_matcher.py on test clips, so the
// screens can be built and shown. It is marked "Sample data" on screen.
//
// When the Supabase side is built (case evidence stored per case, crops in
// the private 'submissions' bucket), add a SupabaseEvidenceSource that
//   * load():   reads the case's case_view JSON (same shape as the sample)
//   * image():  NetworkImage of a signed URL (createSignedUrls for the paths)
//   * bytes():  downloads the file from the bucket
//   * answer(): calls the database function that confirms / rejects a match
// and return it from CaseEvidenceSource.standard. Nothing else changes.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';

import 'package:argus_shield/models/case_evidence.dart';

abstract class CaseEvidenceSource {
  /// The case's AI evidence, or null when there is none yet.
  Future<CaseEvidence?> load(int caseId);

  /// A picture to show (thumbnail or full size).
  ImageProvider image(String path);

  /// The picture's bytes, for downloading.
  Future<Uint8List> bytes(String path);

  /// The admin's answer to "Is this Person 2?".
  Future<void> answer(int caseId, String memberKey, {required bool yes});

  /// What the app uses. Switch to the Supabase source once it exists.
  static CaseEvidenceSource standard = SampleEvidenceSource();
}

/// The bundled sample. Answers are kept in memory while the app runs.
class SampleEvidenceSource implements CaseEvidenceSource {
  static const asset = 'assets/sample_case/case_view.json';
  static Map<String, dynamic>? _data; // shared, so answers survive navigation

  Future<Map<String, dynamic>> _sample() async {
    return _data ??= Map<String, dynamic>.from(
        jsonDecode(await rootBundle.loadString(asset)) as Map);
  }

  @override
  Future<CaseEvidence?> load(int caseId) async {
    try {
      return CaseEvidence.fromMap(await _sample(), isSample: true);
    } catch (e) {
      debugPrint('Sample case evidence not available: $e');
      return null;
    }
  }

  @override
  ImageProvider image(String path) => AssetImage(path);

  @override
  Future<Uint8List> bytes(String path) async =>
      (await rootBundle.load(path)).buffer.asUint8List();

  @override
  Future<void> answer(int caseId, String memberKey, {required bool yes}) async {
    final data = await _sample();
    for (final group in ['people', 'vehicles', 'weapons']) {
      for (final raw in (data[group] as List)) {
        final entity = raw as Map;
        final questions = (entity['questions'] as List? ?? []);
        final i = questions.indexWhere((q) => (q as Map)['member_key'] == memberKey);
        if (i < 0) continue;
        final q = questions.removeAt(i) as Map;
        final crops = q['crops'] as List;
        if (yes) {
          (entity['crops'] as List).addAll(crops);
          entity['submission_count'] = ((entity['submission_count'] as num?) ?? 1) + 1;
        } else {
          // not the same: it becomes its own person / vehicle (as the
          // real matcher does)
          final list = data[group] as List;
          final kind = entity['kind'] as String;
          final name = kind[0].toUpperCase() + kind.substring(1);
          list.add({
            'entity_id': '${kind[0]}${list.length + 1}',
            'kind': kind,
            'label': '$name ${list.length + 1}',
            'description': 'from submission ${q['submission']}',
            'attributes': <String, dynamic>{},
            'cover': crops.isEmpty ? null : (crops.first as Map)['path'],
            'submission_count': 1,
            'crops': crops,
            'questions': [],
            'updated': [],
          });
        }
        data['open_questions'] = ((data['open_questions'] as num?) ?? 1) - 1;
        return;
      }
    }
  }
}
