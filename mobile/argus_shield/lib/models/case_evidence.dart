// What the AI found across a whole case: the summary, and an entry per
// person/vehicle/weapon with all their crops.
//
// Same shape as case_matcher.case_view() (try `python case_matcher.py view 1`).
// The app gets it from get_case_evidence, see case_evidence_source.dart.

/// One picture of a person/vehicle/weapon.
class EvidenceCrop {
  /// A path in the submissions bucket, or an asset path for the sample data.
  final String path;

  /// person | face | vehicle | plate | weapon
  final String type;
  final int? submission;
  final String fileName;
  final double seenSeconds; // when they first show up in the clip
  final DateTime? captureTime;

  const EvidenceCrop({
    required this.path,
    required this.type,
    this.submission,
    this.fileName = '',
    this.seenSeconds = 0,
    this.captureTime,
  });

  factory EvidenceCrop.fromMap(Map<String, dynamic> m) => EvidenceCrop(
        path: m['path'] as String,
        type: (m['type'] as String?) ?? 'person',
        submission: (m['submission'] as num?)?.toInt(),
        fileName: (m['file_name'] as String?) ?? '',
        seenSeconds: ((m['seen_seconds'] as num?) ?? 0).toDouble(),
        captureTime: _date(m['capture_time']),
      );

  /// e.g. "Submission 5 · face · 12.4 s"
  String get caption => [
        if (submission != null) 'Submission $submission',
        type,
        if (seenSeconds > 0) '${seenSeconds.toStringAsFixed(1)} s',
      ].join(' · ');

  /// Download file name, e.g. "argus_s5_face_clip1.png".
  String get downloadName {
    final base = path.split('/').last.split('\\').last;
    return 'argus_s${submission ?? 0}_$base';
  }
}

/// "Is this Person 2?", a possible match waiting on the admin.
class MatchQuestion {
  final String memberKey; // e.g. "s5/f1/person/3"
  final int? submission;
  final String fileName;
  final double? score;
  final List<String> reasons;
  final List<EvidenceCrop> crops;

  const MatchQuestion({
    required this.memberKey,
    this.submission,
    this.fileName = '',
    this.score,
    this.reasons = const [],
    this.crops = const [],
  });

  factory MatchQuestion.fromMap(Map<String, dynamic> m) => MatchQuestion(
        memberKey: m['member_key'] as String,
        submission: (m['submission'] as num?)?.toInt(),
        fileName: (m['file_name'] as String?) ?? '',
        score: (m['score'] as num?)?.toDouble(),
        reasons: [for (final r in (m['reasons'] as List? ?? const [])) r.toString()],
        crops: [
          for (final c in (m['crops'] as List? ?? const []))
            EvidenceCrop.fromMap(Map<String, dynamic>.from(c as Map)),
        ],
      );
}

/// A detail that changed because a later submission showed more, like a
/// plate nobody could read before.
class EvidenceUpdate {
  final String field;
  final String? oldValue;
  final String? newValue;
  final int? submission;

  const EvidenceUpdate(
      {required this.field, this.oldValue, this.newValue, this.submission});

  factory EvidenceUpdate.fromMap(Map<String, dynamic> m) => EvidenceUpdate(
        field: m['field'] as String,
        oldValue: m['old']?.toString(),
        newValue: m['new']?.toString(),
        submission: (m['submission'] as num?)?.toInt(),
      );

  /// e.g. "plate: unknown → ND123456 (from submission 5)"
  String get text {
    final label = field.replaceAll('_', ' ');
    return '$label: ${oldValue ?? 'unknown'} → ${newValue ?? 'unknown'}'
        '${submission == null ? '' : ' (from submission $submission)'}';
  }
}

/// Person 1, Vehicle 2, Weapon 1 etc.
class EvidenceEntity {
  final String entityId;

  /// The detection behind this entry. Only set for submission evidence (one
  /// entry per detection), null on a case where an entry merges several.
  final int? detectionId;
  final String kind; // person | vehicle | weapon
  final String label;
  final String description; // "top black, bottom blue · face seen"
  final Map<String, dynamic> attributes;
  final String? cover; // path of the best picture
  final int submissionCount;
  final List<EvidenceCrop> crops;
  final List<MatchQuestion> questions;
  final List<EvidenceUpdate> updated;

  /// Which clip it's from. Only on the submission page, where each clip's
  /// people are listed separately.
  final int? clip;

  const EvidenceEntity({
    required this.entityId,
    this.detectionId,
    required this.kind,
    required this.label,
    required this.description,
    this.attributes = const {},
    this.cover,
    this.submissionCount = 1,
    this.crops = const [],
    this.questions = const [],
    this.updated = const [],
    this.clip,
  });

  factory EvidenceEntity.fromMap(Map<String, dynamic> m) => EvidenceEntity(
        entityId: m['entity_id'] as String,
        detectionId: (m['detection_id'] as num?)?.toInt(),
        kind: m['kind'] as String,
        label: m['label'] as String,
        description: (m['description'] as String?) ?? '',
        attributes: Map<String, dynamic>.from((m['attributes'] as Map?) ?? const {}),
        cover: m['cover'] as String?,
        submissionCount: ((m['submission_count'] as num?) ?? 1).toInt(),
        crops: [
          for (final c in (m['crops'] as List? ?? const []))
            EvidenceCrop.fromMap(Map<String, dynamic>.from(c as Map)),
        ],
        questions: [
          for (final q in (m['questions'] as List? ?? const []))
            MatchQuestion.fromMap(Map<String, dynamic>.from(q as Map)),
        ],
        updated: [
          for (final u in (m['updated'] as List? ?? const []))
            EvidenceUpdate.fromMap(Map<String, dynamic>.from(u as Map)),
        ],
        clip: (m['clip'] as num?)?.toInt(),
      );

  /// One-line description for the AI summary, worded like the pipeline's
  /// console output:
  ///   person   "top white / bottom black · face visible (picture captured)"
  ///   vehicle  "white Toyota car · plate ND123456"
  ///   weapon   "long gun · held by Person 1"
  /// Falls back to [description] if there aren't any details.
  String get summaryLine {
    String? text(String key) {
      final v = attributes[key];
      if (v == null || (v is String && v.trim().isEmpty)) return null;
      return v.toString().replaceAll('_', ' ');
    }

    if (attributes.isEmpty) return description;
    switch (kind) {
      case 'person':
        final upper = text('upper_clothing'), lower = text('lower_clothing');
        return [
          if (upper != null || lower != null)
            'top ${clothingWord(upper)} / bottom ${clothingWord(lower)}',
          attributes['face_visible'] == true
              ? 'face visible (picture captured)'
              : 'face not clear enough',
        ].join(' · ');
      case 'vehicle':
        final look = [text('colour'), text('make'), text('model'), text('class_name')]
            .whereType<String>()
            .join(' ');
        final plate = text('plate');
        return '${look.isEmpty ? 'vehicle' : look} · '
            '${plate == null ? 'no readable plate' : 'plate $plate'}';
      default:
        final held = text('held_by');
        return '${text('kind') ?? 'unsure what kind'}'
            '${held == null ? '' : ' · held by $held'}';
    }
  }

  /// Details as label/value lines for the crops page, e.g. ("Top", "black
  /// (82%)"). Unknown values are skipped.
  List<(String, String)> get detailLines {
    String pct(String key) {
      final v = attributes[key];
      return v is num ? ' (${(v * 100).round()}%)' : '';
    }

    String? value(String key) {
      final v = attributes[key];
      if (v == null || (v is String && v.isEmpty)) return null;
      if (v == 'none' && key.endsWith('_clothing')) return 'no clothing';
      return v.toString().replaceAll('_', ' ');
    }

    final lines = <(String, String)>[];
    void add(String label, String key, [String? shareKey]) {
      final v = value(key);
      if (v != null) lines.add((label, '$v${shareKey == null ? '' : pct(shareKey)}'));
    }

    switch (kind) {
      case 'person':
        add('Top', 'upper_clothing', 'upper_clothing_share');
        add('Bottom', 'lower_clothing', 'lower_clothing_share');
        lines.add(('Face', attributes['face_visible'] == true ? 'seen' : 'not clear'));
      case 'vehicle':
        add('Type', 'class_name');
        add('Make', 'make', 'make_share');
        add('Model', 'model');
        add('Colour', 'colour', 'colour_share');
        add('Plate', 'plate', 'plate_share');
      default:
        add('Weapon', 'kind', 'kind_share');
        add('Held by', 'held_by');
    }
    return lines;
  }
}

/// Everything for the AI section of the case screen.
class CaseEvidence {
  final int caseId;
  final String aiSummary;
  final int openQuestions;
  final List<EvidenceEntity> people;
  final List<EvidenceEntity> vehicles;
  final List<EvidenceEntity> weapons;

  /// True for the bundled sample, which gets a "sample data" note.
  final bool isSample;

  const CaseEvidence({
    required this.caseId,
    required this.aiSummary,
    this.openQuestions = 0,
    this.people = const [],
    this.vehicles = const [],
    this.weapons = const [],
    this.isSample = false,
  });

  bool get isEmpty => people.isEmpty && vehicles.isEmpty && weapons.isEmpty;

  factory CaseEvidence.fromMap(Map<String, dynamic> m, {bool isSample = false}) {
    List<EvidenceEntity> group(String key) => [
          for (final e in (m[key] as List? ?? const []))
            EvidenceEntity.fromMap(Map<String, dynamic>.from(e as Map)),
        ];
    return CaseEvidence(
      caseId: ((m['case_id'] as num?) ?? 0).toInt(),
      aiSummary: (m['ai_summary'] as String?) ?? '',
      openQuestions: ((m['open_questions'] as num?) ?? 0).toInt(),
      people: group('people'),
      vehicles: group('vehicles'),
      weapons: group('weapons'),
      isSample: isSample,
    );
  }
}

/// How a clothing value reads: "black", "no clothing" (the AI stores "none"
/// for bare skin) or "unsure" (not seen, or couldn't tell).
String clothingWord(String? value) {
  if (value == null || value.isEmpty) return 'unsure';
  return value == 'none' ? 'no clothing' : value;
}

DateTime? _date(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toLocal();
}
