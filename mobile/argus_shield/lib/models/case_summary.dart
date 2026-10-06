// case_summary.dart — one case as the admin screens need it.
// Rows come from the list_cases database function.

/// An investigator actively assigned to a case (from list_cases).
class CaseInvestigator {
  final int userId;
  final String name; // e.g. 'Sgt. Thabo Mokoena'
  final String? badgeNumber;
  final int? assignmentId;
  final bool isLead; // the case's lead investigator

  const CaseInvestigator({
    required this.userId,
    required this.name,
    this.badgeNumber,
    this.assignmentId,
    this.isLead = false,
  });

  factory CaseInvestigator.fromMap(Map<String, dynamic> row) {
    return CaseInvestigator(
      userId: (row['userid'] as num).toInt(),
      name: row['name'] as String,
      badgeNumber: row['badgenumber'] as String?,
      assignmentId: (row['assignmentid'] as num?)?.toInt(),
      isLead: (row['islead'] as bool?) ?? false,
    );
  }
}

/// One of the newest submissions in a case, shown on the case card so the
/// admin can see what's inside without opening it.
class CasePreviewItem {
  final int incidentId;
  final String location;
  final DateTime? dateReported;
  final String reviewStatus; // 'accepted' or 'duplicate'
  final String? description; // the citizen's
  final String? aiSummary;

  const CasePreviewItem({
    required this.incidentId,
    required this.location,
    this.dateReported,
    this.reviewStatus = 'accepted',
    this.description,
    this.aiSummary,
  });

  factory CasePreviewItem.fromMap(Map<String, dynamic> row) {
    final reported = row['datereported'] as String?;
    return CasePreviewItem(
      incidentId: (row['incidentid'] as num).toInt(),
      location: row['location'] as String,
      dateReported: reported == null ? null : DateTime.parse(reported).toLocal(),
      reviewStatus: (row['reviewstatus'] as String?) ?? 'accepted',
      description: row['description'] as String?,
      aiSummary: row['aisummary'] as String?,
    );
  }

  /// 42 → "INC-0042".
  String get reference => 'INC-${incidentId.toString().padLeft(4, '0')}';
}

class CaseSummary {
  final int caseId;
  final String title;
  final String? description;
  final String status; // 'open' | 'under_review' | 'closed'
  final DateTime dateCreated;
  final DateTime? dateClosed;
  final String? createdByName;
  final int incidentCount; // submissions in the case
  final List<CaseInvestigator> investigators; // active assignments, lead first
  final DateTime? lastActivity; // newest event on the case
  final int mediaCount; // clips / photos across all its submissions
  final List<String> plates; // number plates the AI read, max 3
  final List<CasePreviewItem> preview; // the 3 newest submissions

  /// People the AI saw that no investigator has reviewed yet, and people
  /// an investigator on the case confirmed as suspects. Each is the
  /// highest of the case's submissions (most seen at once in one clip),
  /// so A = 2, B = 1, C = 1 gives 2. Counts only: under POPIA nothing
  /// about a possible suspect is shown until an investigator confirms them.
  final int possibleSuspects;
  final int confirmedSuspects;

  const CaseSummary({
    required this.caseId,
    required this.title,
    this.description,
    required this.status,
    required this.dateCreated,
    this.dateClosed,
    this.createdByName,
    this.incidentCount = 0,
    this.investigators = const [],
    this.lastActivity,
    this.mediaCount = 0,
    this.plates = const [],
    this.preview = const [],
    this.possibleSuspects = 0,
    this.confirmedSuspects = 0,
  });

  factory CaseSummary.fromMap(Map<String, dynamic> row) {
    DateTime? time(String key) => row[key] == null
        ? null
        : DateTime.parse(row[key] as String).toLocal();

    return CaseSummary(
      caseId: (row['caseid'] as num).toInt(),
      title: row['title'] as String,
      description: row['description'] as String?,
      status: row['status'] as String,
      dateCreated: time('datecreated')!,
      dateClosed: time('dateclosed'),
      createdByName: row['createdbyname'] as String?,
      incidentCount: (row['incidentcount'] as num?)?.toInt() ?? 0,
      investigators: ((row['investigators'] as List?) ?? const [])
          .map((i) => CaseInvestigator.fromMap(i as Map<String, dynamic>))
          .toList(),
      lastActivity: time('lastactivity'),
      mediaCount: (row['mediacount'] as num?)?.toInt() ?? 0,
      plates: ((row['plates'] as List?) ?? const []).cast<String>(),
      preview: ((row['preview'] as List?) ?? const [])
          .map((p) => CasePreviewItem.fromMap(p as Map<String, dynamic>))
          .toList(),
      possibleSuspects: (row['possiblesuspects'] as num?)?.toInt() ?? 0,
      confirmedSuspects: (row['confirmedsuspects'] as num?)?.toInt() ?? 0,
    );
  }

  /// Display reference, e.g. case 3 → "CASE-0003".
  String get reference => caseReference(caseId);

  bool get isClosed => status == 'closed';

  /// The lead investigator, or null when there is none.
  CaseInvestigator? get lead {
    for (final i in investigators) {
      if (i.isLead) return i;
    }
    return null;
  }
}

/// 3 → "CASE-0003".
String caseReference(int caseId) => 'CASE-${caseId.toString().padLeft(4, '0')}';
