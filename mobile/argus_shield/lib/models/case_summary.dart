// case_summary.dart — one case as the admin screens need it.
// Rows come from the list_cases database function.

/// An investigator actively assigned to a case (from list_cases).
class CaseInvestigator {
  final int userId;
  final String name; // e.g. 'Sgt. Thabo Mokoena'
  final String? badgeNumber;

  const CaseInvestigator({
    required this.userId,
    required this.name,
    this.badgeNumber,
  });

  factory CaseInvestigator.fromMap(Map<String, dynamic> row) {
    return CaseInvestigator(
      userId: (row['userid'] as num).toInt(),
      name: row['name'] as String,
      badgeNumber: row['badgenumber'] as String?,
    );
  }
}

class CaseSummary {
  final int caseId;
  final String title;
  final String? description;
  final String status; // 'open' | 'under_review' | 'closed'
  final DateTime dateCreated;
  final DateTime? dateClosed;
  final String? createdByName;
  final int incidentCount;
  final List<CaseInvestigator> investigators; // active assignments only
  final DateTime? lastActivity; // created, or an incident added

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
    );
  }

  /// Display reference, e.g. case 3 → "CASE-0003".
  String get reference => 'CASE-${caseId.toString().padLeft(4, '0')}';

  bool get isClosed => status == 'closed';
}
