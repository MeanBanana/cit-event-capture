// crime_scene_summary.dart — one reported incident (a "submission") as the
// admin screens need it.

/// Field names follow public.crimescene (incidentid, location, datetime,
/// attacktype, status, description, reportedby, datereported, caseid,
/// reviewstatus, reviewedat, reviewnote, duplicateof, latitude, longitude,
/// locationkey, aisummary, aisummarystatus, aisummaryat). The
/// reporter's name comes from public."User" via reportedby, the media
/// count from public.media, and the vehicle / person / weapon counts and
/// plates from the AI's detections. Rows come from the list_submissions
/// database function (see SupabaseService.listSubmissionsPage).
class CrimeSceneSummary {
  final int incidentId;
  final String location;
  final DateTime dateTime; // when the incident happened
  final String? attackType; // nullable in the database
  final String status; // 'open' | 'under_review' | 'closed'
  final String? description; // nullable in the database
  final int reportedBy; // User.userid
  final String reporterName; // User.firstname + surname
  final int mediaCount; // rows in media for this incident
  final DateTime? dateReported; // when it was reported (submitted)
  final int? caseId; // the case it belongs to; null = not in a case yet
  final String? caseTitle; // title of that case

  /// The admin's decision: 'pending' (not reviewed yet), 'accepted' (in a
  /// case), 'rejected', or 'duplicate' (of [duplicateOf]).
  final String reviewStatus;
  final DateTime? reviewedAt;
  final String? reviewNote; // e.g. why it was rejected
  final int? duplicateOf; // incidentid of the original

  final double? latitude; // from the phone's GPS, when it was shared
  final double? longitude;

  /// The location in a standard form ("N1, Midrand" -> "n1 midrand"),
  /// used to group submissions by location.
  final String? locationKey;

  /// The AI's short summary of all this submission's footage (null until
  /// the AI pipeline has written one).
  final String? aiSummary;

  /// 'none' (not analysed), 'processing', 'ready', 'outdated' (new footage
  /// added since the summary) or 'failed'.
  final String aiSummaryStatus;
  final DateTime? aiSummaryAt;

  /// What the AI saw: the most vehicles / people / weapons in any one clip,
  /// and up to 3 number plates it read.
  final int vehicleCount;
  final int personCount;
  final int weaponCount;
  final List<String> plates;

  /// People the AI saw that no investigator has reviewed yet (most in one
  /// clip), and people an investigator on the case confirmed as suspects.
  /// Under POPIA only these counts are shown until someone is confirmed.
  final int possibleSuspects;
  final int confirmedSuspects;

  /// Earliest capture time in the footage's own metadata (null when no
  /// clip has one). Better evidence than the time the citizen typed.
  final DateTime? capturedAt;

  /// True when [capturedAt] and the typed [dateTime] are more than 3 hours
  /// apart: the admin should check which one is right.
  final bool timeMismatch;

  const CrimeSceneSummary({
    required this.incidentId,
    required this.location,
    required this.dateTime,
    this.attackType,
    required this.status,
    this.description,
    required this.reportedBy,
    required this.reporterName,
    this.mediaCount = 0,
    this.dateReported,
    this.caseId,
    this.caseTitle,
    this.reviewStatus = 'pending',
    this.reviewedAt,
    this.reviewNote,
    this.duplicateOf,
    this.latitude,
    this.longitude,
    this.locationKey,
    this.aiSummary,
    this.aiSummaryStatus = 'none',
    this.aiSummaryAt,
    this.vehicleCount = 0,
    this.personCount = 0,
    this.weaponCount = 0,
    this.plates = const [],
    this.possibleSuspects = 0,
    this.confirmedSuspects = 0,
    this.capturedAt,
    this.timeMismatch = false,
  });

  /// Builds one from a row returned by list_submissions
  /// (keys are the database column names). Times are converted to the
  /// phone's local time for display.
  factory CrimeSceneSummary.fromMap(Map<String, dynamic> row) {
    DateTime? time(String key) => row[key] == null
        ? null
        : DateTime.parse(row[key] as String).toLocal();

    return CrimeSceneSummary(
      incidentId: (row['incidentid'] as num).toInt(),
      location: row['location'] as String,
      dateTime: time('datetime')!,
      attackType: row['attacktype'] as String?,
      status: row['status'] as String,
      description: row['description'] as String?,
      reportedBy: (row['reportedby'] as num).toInt(),
      // null when the signed-in user may not see the reporter's profile
      reporterName: (row['reportername'] as String?) ?? 'Unknown',
      mediaCount: (row['mediacount'] as num?)?.toInt() ?? 0,
      dateReported: time('datereported'),
      caseId: (row['caseid'] as num?)?.toInt(),
      caseTitle: row['casetitle'] as String?,
      reviewStatus: (row['reviewstatus'] as String?) ?? 'pending',
      reviewedAt: time('reviewedat'),
      reviewNote: row['reviewnote'] as String?,
      duplicateOf: (row['duplicateof'] as num?)?.toInt(),
      latitude: _toDouble(row['latitude']),
      longitude: _toDouble(row['longitude']),
      locationKey: row['locationkey'] as String?,
      aiSummary: row['aisummary'] as String?,
      aiSummaryStatus: (row['aisummarystatus'] as String?) ?? 'none',
      aiSummaryAt: time('aisummaryat'),
      vehicleCount: (row['vehiclecount'] as num?)?.toInt() ?? 0,
      personCount: (row['personcount'] as num?)?.toInt() ?? 0,
      weaponCount: (row['weaponcount'] as num?)?.toInt() ?? 0,
      plates: ((row['plates'] as List?) ?? const []).cast<String>(),
      possibleSuspects: (row['possiblesuspects'] as num?)?.toInt() ?? 0,
      confirmedSuspects: (row['confirmedsuspects'] as num?)?.toInt() ?? 0,
      capturedAt: time('capturedat'),
      timeMismatch: (row['timemismatch'] as bool?) ?? false,
    );
  }

  /// numeric columns arrive as a number, or as text for large precision
  static double? _toDouble(Object? value) => switch (value) {
        num n => n.toDouble(),
        String s => double.tryParse(s),
        _ => null,
      };

  /// Display reference, e.g. incident 42 → "INC-0042".
  String get reference => incidentReference(incidentId);

  /// "CASE-0003" when in a case, otherwise null.
  String? get caseReference =>
      caseId == null ? null : 'CASE-${caseId.toString().padLeft(4, '0')}';

  bool get isPending => reviewStatus == 'pending';
  bool get isAccepted => reviewStatus == 'accepted';
  bool get isRejected => reviewStatus == 'rejected';
  bool get isDuplicate => reviewStatus == 'duplicate';

  bool get hasGps => latitude != null && longitude != null;

  /// The best time we have for when it happened: the footage's capture
  /// time, otherwise the time the citizen typed.
  DateTime get bestTime => capturedAt ?? dateTime;

  /// True when the AI found anything worth showing as a chip.
  bool get hasAiFacts =>
      vehicleCount > 0 ||
      personCount > 0 ||
      weaponCount > 0 ||
      plates.isNotEmpty ||
      possibleSuspects > 0 ||
      confirmedSuspects > 0;
}

/// 42 → "INC-0042".
String incidentReference(int incidentId) =>
    'INC-${incidentId.toString().padLeft(4, '0')}';
