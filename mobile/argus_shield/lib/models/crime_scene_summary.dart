// crime_scene_summary.dart — one reported incident (a "submission") as the
// admin screens need it.

/// Field names follow public.crimescene (incidentid, location, datetime,
/// attacktype, status, description, reportedby, datereported, caseid,
/// reviewstatus, reviewedat, reviewnote, duplicateof). The
/// reporter's name comes from public."User" via reportedby, and the media
/// count from public.media. Rows come from the list_submissions database
/// function (see SupabaseService.getRecentSubmissions).
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
    );
  }

  /// Display reference, e.g. incident 42 → "INC-0042".
  String get reference => incidentReference(incidentId);

  /// "CASE-0003" when in a case, otherwise null.
  String? get caseReference =>
      caseId == null ? null : 'CASE-${caseId.toString().padLeft(4, '0')}';

  bool get isPending => reviewStatus == 'pending';
  bool get isAccepted => reviewStatus == 'accepted';
  bool get isRejected => reviewStatus == 'rejected';
  bool get isDuplicate => reviewStatus == 'duplicate';
}

/// 42 → "INC-0042".
String incidentReference(int incidentId) =>
    'INC-${incidentId.toString().padLeft(4, '0')}';
