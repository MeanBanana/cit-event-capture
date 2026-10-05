// case_assignment_info.dart — one investigator assignment on a case (current
// or past). Rows come from the list_case_assignments database function.
class CaseAssignmentInfo {
  final int assignmentId;
  final int? caseId;
  final int userId;
  final String name; // e.g. 'Sgt. Thabo Mokoena'
  final String? badgeNumber;
  final String? station;
  final String? dutyStatus; // 'on_duty' | 'available' | 'off_duty'
  final String status; // 'active' | 'reassigned' | 'closed'
  final DateTime dateAssigned;
  final DateTime? dateUnassigned;
  final String? assignedByName;

  const CaseAssignmentInfo({
    required this.assignmentId,
    this.caseId,
    required this.userId,
    required this.name,
    this.badgeNumber,
    this.station,
    this.dutyStatus,
    required this.status,
    required this.dateAssigned,
    this.dateUnassigned,
    this.assignedByName,
  });

  factory CaseAssignmentInfo.fromMap(Map<String, dynamic> row) {
    DateTime? time(String key) => row[key] == null
        ? null
        : DateTime.parse(row[key] as String).toLocal();

    return CaseAssignmentInfo(
      assignmentId: (row['assignmentid'] as num).toInt(),
      caseId: (row['caseid'] as num?)?.toInt(),
      userId: (row['userid'] as num).toInt(),
      name: row['name'] as String,
      badgeNumber: row['badgenumber'] as String?,
      station: row['station'] as String?,
      dutyStatus: row['dutystatus'] as String?,
      status: row['assignmentstatus'] as String,
      dateAssigned: time('dateassigned')!,
      dateUnassigned: time('dateunassigned'),
      assignedByName: row['assignedbyname'] as String?,
    );
  }

  bool get isActive => status == 'active';
}
