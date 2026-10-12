// case_evidence_source.dart — where the case screen gets the AI's combined
// people / vehicles / weapons and their pictures from.
//
//   SupabaseEvidenceSource (what the app uses)
//     load():   get_case_evidence(caseId) - the same JSON shape as
//               ai/case_matcher.py case_view(), built from the tables
//     image():  the picture from the private 'submissions' bucket
//     bytes():  the same, for downloading
//     answer(): answer_entity_match(detectionId, yes/no)
//   SampleEvidenceSource
//     a sample bundled with the app (assets/sample_case/), made by running
//     the real pipeline + case_matcher.py on test clips. Marked "Sample data"
//     on screen. Handy for demos without a worker:
//       CaseEvidenceSource.standard = SampleEvidenceSource();

import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

  /// What the app uses.
  static CaseEvidenceSource standard = SupabaseEvidenceSource();
}

/// The real data: the case's AI evidence from Supabase and its pictures from
/// the private 'submissions' bucket. Admins and investigators assigned to
/// the case only (the database and the bucket's policies check that).
class SupabaseEvidenceSource implements CaseEvidenceSource {
  static const bucket = 'submissions';

  /// [_client] only for tests; the app uses Supabase.instance.client.
  SupabaseEvidenceSource([this._client]);

  final SupabaseClient? _client;

  // A getter, so this can be created before Supabase is initialised.
  SupabaseClient get _supabase => _client ?? Supabase.instance.client;

  @override
  Future<CaseEvidence?> load(int caseId) async {
    try {
      final data =
          await _supabase.rpc('get_case_evidence', params: {'p_caseid': caseId});
      if (data == null) return null; // no such case
      final evidence =
          CaseEvidence.fromMap(Map<String, dynamic>.from(data as Map));
      // nothing analysed / combined yet -> "No AI analysis for this case yet."
      if (evidence.isEmpty && evidence.aiSummary.trim().isEmpty) return null;
      return evidence;
    } catch (e) {
      debugPrint('Could not load the AI evidence of case $caseId: $e');
      return null;
    }
  }

  /// Downloaded with the signed-in user's session (not a public or signed
  /// URL), so the bucket's policies decide and a link never expires while
  /// the screen is open. Flutter's image cache keeps each picture once.
  @override
  ImageProvider image(String path) => _BucketImage(path, bytes);

  @override
  Future<Uint8List> bytes(String path) =>
      _supabase.storage.from(bucket).download(path);

  /// memberKey is the detection id (see get_case_evidence).
  @override
  Future<void> answer(int caseId, String memberKey, {required bool yes}) async {
    final detectionId = int.tryParse(memberKey);
    if (detectionId == null) {
      throw ArgumentError('Not a detection id: $memberKey');
    }
    await _supabase.rpc('answer_entity_match',
        params: {'p_detectionid': detectionId, 'p_yes': yes});
  }
}

/// A picture from the bucket, loaded through [load] (keyed by its path so
/// the image cache shares it between the grid and the full-size viewer).
@immutable
class _BucketImage extends ImageProvider<_BucketImage> {
  const _BucketImage(this.path, this.load);

  final String path;
  final Future<Uint8List> Function(String path) load;

  @override
  Future<_BucketImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_BucketImage>(this);

  @override
  ImageStreamCompleter loadImage(_BucketImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
        codec: _codec(decode),
        scale: 1.0,
        debugLabel: path,
      );

  Future<ui.Codec> _codec(ImageDecoderCallback decode) async {
    final data = await load(path);
    return decode(await ui.ImmutableBuffer.fromUint8List(data));
  }

  @override
  bool operator ==(Object other) => other is _BucketImage && other.path == path;

  @override
  int get hashCode => path.hashCode;
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
