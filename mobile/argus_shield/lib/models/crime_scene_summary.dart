// One reported incident (a "submission") as the admin screens see it.

/// Fields mirror public.crimescene. On top of that we get the reporter's name
/// from "User", the media count, and the AI's vehicle/person/weapon counts
/// and plates. Rows come from list_submissions (see
/// SupabaseService.listSubmissionsPage).
class CrimeSceneSummary {
  final int incidentId;
  final String location;
  final DateTime dateTime; // when it happened
  final String? attackType; // nullable in the database
  final String status; // 'open' | 'under_review' | 'closed'
  final String? description; // nullable in the database
  final int reportedBy; // User.userid
  final String reporterName; // User.firstname + surname
  final int mediaCount; // number of media rows
  final DateTime? dateReported; // when it was submitted
  final int? caseId; // null if it's not in a case yet
  final String? caseTitle;

  /// The admin's decision: 'pending', 'accepted' (it's in a case),
  /// 'rejected', or 'duplicate' (of [duplicateOf]).
  final String reviewStatus;
  final DateTime? reviewedAt;
  final String? reviewNote; // e.g. why it got rejected
  final int? duplicateOf; // incidentid of the original

  final double? latitude; // phone GPS, if they shared it
  final double? longitude;

  /// Normalised location ("N1, Midrand" -> "n1 midrand") for grouping.
  final String? locationKey;

  /// The AI's short summary of the footage. Null until the pipeline writes one.
  final String? aiSummary;

  /// 'none' (not analysed), 'processing', 'ready', 'outdated' (footage added
  /// since) or 'failed'.
  final String aiSummaryStatus;
  final DateTime? aiSummaryAt;

  /// What the AI saw: max vehicles/people/weapons in any one clip, and up to
  /// 3 plates.
  final int vehicleCount;
  final int personCount;
  final int weaponCount;
  final List<String> plates;

  /// Unreviewed people the AI saw (max in one clip) and people an
  /// investigator confirmed. Under POPIA we only show counts until someone's
  /// confirmed.
  final int possibleSuspects;
  final int confirmedSuspects;

  /// Earliest capture time from the footage itself, null if no clip has
  /// one. More trustworthy than what the citizen typed.
  final DateTime? capturedAt;

  /// True if [capturedAt] and the typed [dateTime] are more than 3 hours
  /// apart, so the admin should check which is right.
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

  /// Build one from a list_submissions row (keys are the column names).
  /// Times get converted to the phone's local time for display.
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
      // null if the user isn't allowed to see the reporter's profile
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

  /// numeric columns can come back as a number, or as a string for big precision
  static double? _toDouble(Object? value) => switch (value) {
        num n => n.toDouble(),
        String s => double.tryParse(s),
        _ => null,
      };

  /// e.g. incident 42 -> "INC-0042"
  String get reference => incidentReference(incidentId);

  /// "CASE-0003" if it's in a case, otherwise null.
  String? get caseReference =>
      caseId == null ? null : 'CASE-${caseId.toString().padLeft(4, '0')}';

  bool get isPending => reviewStatus == 'pending';
  bool get isAccepted => reviewStatus == 'accepted';
  bool get isRejected => reviewStatus == 'rejected';
  bool get isDuplicate => reviewStatus == 'duplicate';

  bool get hasGps => latitude != null && longitude != null;

  /// Best guess at when it happened: capture time, or else the typed time.
  DateTime get bestTime => capturedAt ?? dateTime;

  /// True if the AI found anything worth a chip.
  bool get hasAiFacts =>
      vehicleCount > 0 ||
      personCount > 0 ||
      weaponCount > 0 ||
      plates.isNotEmpty ||
      possibleSuspects > 0 ||
      confirmedSuspects > 0;
}

/// 42 -> "INC-0042"
String incidentReference(int incidentId) =>
    'INC-${incidentId.toString().padLeft(4, '0')}';
