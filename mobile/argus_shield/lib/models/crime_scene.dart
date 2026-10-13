// crime_scene.dart — the crime scenes of a case and what investigators can
// correct about them.
//
//   CrimeSceneCardInfo   one card on the case page (list_case_crime_scenes)
//   CrimeSceneDetail     the crime scene page (get_crime_scene): its files,
//                        every person / vehicle / weapon the AI found with
//                        each correctable field, and the corrections log
//
// The database decides who may see / correct what; see migration
// 20261013100000_crime_scenes_and_corrections.sql.

import 'package:argus_shield/models/crime_scene_summary.dart'
    show incidentReference;

/// Where the AI is with a crime scene's footage.
enum AnalysisStatus {
  /// Nothing was uploaded.
  noFootage,

  /// Waiting for the AI worker (queued, or not submitted yet).
  pending,

  /// The AI worker is analysing it right now.
  analysing,

  /// No file could be analysed.
  failed,

  /// Analysed (some files may have failed, see filesFailed).
  done;

  static AnalysisStatus parse(String? value) => switch (value) {
        'no_footage' => AnalysisStatus.noFootage,
        'pending' => AnalysisStatus.pending,
        'analysing' => AnalysisStatus.analysing,
        'failed' => AnalysisStatus.failed,
        'done' => AnalysisStatus.done,
        _ => AnalysisStatus.pending,
      };

  /// True while the AI may still change what it found.
  bool get inProgress =>
      this == AnalysisStatus.pending || this == AnalysisStatus.analysing;
}

/// One crime scene of a case, as its card shows it.
class CrimeSceneCardInfo {
  final int incidentId;
  final String location;
  final String? description;
  final String? attackType;
  final DateTime dateTime; // the time the citizen typed
  final DateTime? capturedAt; // earliest capture time in the footage
  final String reviewStatus; // 'accepted' | 'duplicate' ...
  final int mediaCount;

  /// Most seen in any one clip (the same person in two clips counts once).
  final int suspects;
  final int confirmedSuspects;
  final int vehicles;
  final int weapons;

  final AnalysisStatus analysis;
  final int filesDone;
  final int filesFailed;
  final int correctionCount;

  const CrimeSceneCardInfo({
    required this.incidentId,
    required this.location,
    this.description,
    this.attackType,
    required this.dateTime,
    this.capturedAt,
    this.reviewStatus = 'accepted',
    this.mediaCount = 0,
    this.suspects = 0,
    this.confirmedSuspects = 0,
    this.vehicles = 0,
    this.weapons = 0,
    this.analysis = AnalysisStatus.done,
    this.filesDone = 0,
    this.filesFailed = 0,
    this.correctionCount = 0,
  });

  factory CrimeSceneCardInfo.fromMap(Map<String, dynamic> row) =>
      CrimeSceneCardInfo(
        incidentId: (row['incidentid'] as num).toInt(),
        location: (row['location'] as String?) ?? '',
        description: row['description'] as String?,
        attackType: row['attacktype'] as String?,
        dateTime: parseTime(row['datetime'])!,
        capturedAt: parseTime(row['capturedat']),
        reviewStatus: (row['reviewstatus'] as String?) ?? 'accepted',
        mediaCount: _int(row['mediacount']),
        suspects: _int(row['suspects']),
        confirmedSuspects: _int(row['confirmedsuspects']),
        vehicles: _int(row['vehicles']),
        weapons: _int(row['weapons']),
        analysis: AnalysisStatus.parse(row['analysisstatus'] as String?),
        filesDone: _int(row['filesdone']),
        filesFailed: _int(row['filesfailed']),
        correctionCount: _int(row['correctioncount']),
      );

  String get reference => incidentReference(incidentId);

  /// The footage's capture time when it has one, else the typed time.
  DateTime get bestTime => capturedAt ?? dateTime;

  bool get isDuplicate => reviewStatus == 'duplicate';
}

/// One clip / photo of a crime scene.
class SceneFile {
  final int mediaId;
  final int number; // Clip 1, 2 ...
  final String mediaType; // 'video' | 'image' | 'audio'
  final String storagePath;
  final String status; // 'pending' | 'processing' | 'completed' | 'failed'
  final DateTime? capturedAt;
  final String? aiDescription;

  const SceneFile({
    required this.mediaId,
    required this.number,
    required this.mediaType,
    required this.storagePath,
    this.status = 'pending',
    this.capturedAt,
    this.aiDescription,
  });

  factory SceneFile.fromMap(Map<String, dynamic> m) => SceneFile(
        mediaId: (m['media_id'] as num).toInt(),
        number: (m['number'] as num).toInt(),
        mediaType: (m['media_type'] as String?) ?? 'video',
        storagePath: (m['storage_path'] as String?) ?? '',
        status: (m['status'] as String?) ?? 'pending',
        capturedAt: parseTime(m['captured_at']),
        aiDescription: m['ai_description'] as String?,
      );
}

/// One correctable field of a detection: what the AI said and what counts.
class DetectionField {
  final String field; // 'plate', 'make', 'weapon_type', 'dismissed' ...
  final String? ai; // the AI's value (null = it didn't say)
  final String? value; // what counts now
  final bool corrected; // value comes from an investigator

  const DetectionField({
    required this.field,
    this.ai,
    this.value,
    this.corrected = false,
  });

  factory DetectionField.fromMap(Map<String, dynamic> m) => DetectionField(
        field: m['field'] as String,
        ai: m['ai']?.toString(),
        value: m['value']?.toString(),
        corrected: (m['corrected'] as bool?) ?? false,
      );

  String get label => fieldLabel(field);
}

/// A person / vehicle / weapon the AI found in the crime scene's footage.
class SceneDetection {
  final int detectionId;
  final String kind; // 'person' | 'vehicle' | 'weapon'
  final String label; // 'Vehicle 1'
  final int clip;
  final double? firstSeen; // seconds into the clip
  final List<String> crops; // bucket paths, clearest first
  final bool dismissed; // "not a real vehicle"
  final String? suspectStatus; // people: 'possible' | 'confirmed' | 'dismissed'
  final bool canCorrect;
  final List<DetectionField> fields;
  final int correctionCount;

  const SceneDetection({
    required this.detectionId,
    required this.kind,
    required this.label,
    this.clip = 1,
    this.firstSeen,
    this.crops = const [],
    this.dismissed = false,
    this.suspectStatus,
    this.canCorrect = false,
    this.fields = const [],
    this.correctionCount = 0,
  });

  factory SceneDetection.fromMap(Map<String, dynamic> m) => SceneDetection(
        detectionId: (m['detection_id'] as num).toInt(),
        kind: m['kind'] as String,
        label: m['label'] as String,
        clip: (m['clip'] as num?)?.toInt() ?? 1,
        firstSeen: (m['first_seen'] as num?)?.toDouble(),
        crops: [
          for (final c in (m['crops'] as List?) ?? const [])
            if (c is Map && c['path'] is String) c['path'] as String,
        ],
        dismissed: (m['dismissed'] as bool?) ?? false,
        suspectStatus: m['suspect_status'] as String?,
        canCorrect: (m['can_correct'] as bool?) ?? false,
        fields: [
          for (final f in (m['fields'] as List?) ?? const [])
            DetectionField.fromMap(Map<String, dynamic>.from(f as Map)),
        ],
        correctionCount: _int(m['correction_count']),
      );

  DetectionField? field(String name) {
    for (final f in fields) {
      if (f.field == name) return f;
    }
    return null;
  }

  /// The fields shown as "Make: Toyota" lines (not the dismissed flag).
  List<DetectionField> get detailFields =>
      [for (final f in fields) if (f.field != 'dismissed') f];

  bool get isCorrected => fields.any((f) => f.corrected);
}

/// One line of the corrections log.
class CorrectionEntry {
  final int correctionId;

  /// The crime scene the correction belongs to (correctionlog.incidentid).
  final int? incidentId;
  final int detectionId;
  final String? label; // 'Vehicle 1'
  final String? field; // null for corrections made before fields were logged
  final String? original;
  final String? corrected;
  final String? note;
  final String? byName;
  final DateTime at;

  const CorrectionEntry({
    required this.correctionId,
    this.incidentId,
    required this.detectionId,
    this.label,
    this.field,
    this.original,
    this.corrected,
    this.note,
    this.byName,
    required this.at,
  });

  factory CorrectionEntry.fromMap(Map<String, dynamic> m) => CorrectionEntry(
        correctionId: (m['correction_id'] as num).toInt(),
        incidentId: (m['incident_id'] as num?)?.toInt(),
        detectionId: (m['detection_id'] as num).toInt(),
        label: m['label'] as String?,
        field: m['field'] as String?,
        original: m['original']?.toString(),
        corrected: m['corrected']?.toString(),
        note: m['note'] as String?,
        byName: m['by'] as String?,
        at: parseTime(m['at'])!,
      );

  /// "Vehicle 1 · Number plate: ND123456 → ND654321"
  String get text {
    final who = label ?? 'Detection $detectionId';
    if (field == 'dismissed') {
      return corrected == 'true'
          ? '$who marked as not real'
          : '$who restored (it is real)';
    }
    final name = field == null ? 'value' : fieldLabel(field!);
    return '$who · $name: ${displayValue(field, original)} → '
        '${displayValue(field, corrected)}';
  }
}

/// Everything the crime scene page shows.
class CrimeSceneDetail {
  final int incidentId;
  final int? caseId;
  final String? caseTitle;
  final bool caseClosed;
  final String location;
  final String? description;
  final String? attackType;
  final DateTime dateTime;
  final DateTime? capturedAt;
  final double? latitude;
  final double? longitude;
  final String? aiSummary;
  final AnalysisStatus analysis;
  final int fileCount;
  final int filesDone;
  final int filesFailed;
  final bool canCorrect;
  final List<SceneFile> files;
  final List<SceneDetection> detections;
  final List<CorrectionEntry> corrections;

  const CrimeSceneDetail({
    required this.incidentId,
    this.caseId,
    this.caseTitle,
    this.caseClosed = false,
    required this.location,
    this.description,
    this.attackType,
    required this.dateTime,
    this.capturedAt,
    this.latitude,
    this.longitude,
    this.aiSummary,
    this.analysis = AnalysisStatus.done,
    this.fileCount = 0,
    this.filesDone = 0,
    this.filesFailed = 0,
    this.canCorrect = false,
    this.files = const [],
    this.detections = const [],
    this.corrections = const [],
  });

  factory CrimeSceneDetail.fromMap(Map<String, dynamic> m) {
    final a = Map<String, dynamic>.from((m['analysis'] as Map?) ?? const {});
    List<Map<String, dynamic>> list(String key) => [
          for (final x in (m[key] as List?) ?? const [])
            Map<String, dynamic>.from(x as Map),
        ];
    return CrimeSceneDetail(
      incidentId: (m['incident_id'] as num).toInt(),
      caseId: (m['case_id'] as num?)?.toInt(),
      caseTitle: m['case_title'] as String?,
      caseClosed: (m['case_closed'] as bool?) ?? false,
      location: (m['location'] as String?) ?? '',
      description: m['description'] as String?,
      attackType: m['attack_type'] as String?,
      dateTime: parseTime(m['datetime'])!,
      capturedAt: parseTime(m['captured_at']),
      latitude: _double(m['latitude']),
      longitude: _double(m['longitude']),
      aiSummary: m['ai_summary'] as String?,
      analysis: AnalysisStatus.parse(a['status'] as String?),
      fileCount: _int(a['files']),
      filesDone: _int(a['done']),
      filesFailed: _int(a['failed']),
      canCorrect: (m['can_correct'] as bool?) ?? false,
      files: [for (final f in list('files')) SceneFile.fromMap(f)],
      detections: [for (final d in list('detections')) SceneDetection.fromMap(d)],
      corrections: [
        for (final c in list('corrections')) CorrectionEntry.fromMap(c),
      ],
    );
  }

  String get reference => incidentReference(incidentId);

  String? get caseReference =>
      caseId == null ? null : 'CASE-${caseId.toString().padLeft(4, '0')}';

  DateTime get bestTime => capturedAt ?? dateTime;

  bool get hasGps => latitude != null && longitude != null;

  List<SceneDetection> ofKind(String kind) =>
      [for (final d in detections) if (d.kind == kind) d];
}

// ---- Field names and values -------------------------------------------------

/// The weapon types the database accepts (weapondetail.weapontype).
const weaponTypes = <String>[
  'handgun',
  'long_gun',
  'rifle',
  'shotgun',
  'knife',
  'machete',
  'explosive',
  'other',
  'unknown',
];

/// 'plate' -> 'Number plate'
String fieldLabel(String field) => switch (field) {
      'upper_clothing' => 'Top colour',
      'lower_clothing' => 'Bottom colour',
      'vehicle_type' => 'Vehicle type',
      'make' => 'Make',
      'model' => 'Model',
      'colour' => 'Colour',
      'plate' => 'Number plate',
      'weapon_type' => 'Weapon type',
      'dismissed' => 'Not real',
      _ => field.replaceAll('_', ' '),
    };

/// A value as people read it: null -> 'none', 'long_gun' -> 'long gun'.
String displayValue(String? field, String? value) {
  if (value == null || value.isEmpty) {
    return field == 'plate' ? 'no readable plate' : 'unknown';
  }
  if (field == 'dismissed') return value == 'true' ? 'yes' : 'no';
  return value.replaceAll('_', ' ');
}

// ---- Parsing helpers ----------------------------------------------------------

DateTime? parseTime(Object? value) =>
    value is String ? DateTime.parse(value).toLocal() : null;

int _int(Object? value) => switch (value) {
      num n => n.toInt(),
      String s => int.tryParse(s) ?? 0,
      _ => 0,
    };

double? _double(Object? value) => switch (value) {
      num n => n.toDouble(),
      String s => double.tryParse(s),
      _ => null,
    };
