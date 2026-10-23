// One investigator as the admin screens see it.

/// Fields come from "User" joined with investigator, via the
/// list_investigators function (see SupabaseService.getRecentInvestigators).
class InvestigatorSummary {
  final int userId;
  final String firstName;
  final String surname;
  final String? rank; // e.g. 'Sgt.', can be null
  final String badgeNumber; // e.g. 'JHB-4471'
  final String station; // e.g. 'Kempton Park SAPS'
  final String? unit; // e.g. 'CIT Task Force', can be null
  final String dutyStatus; // 'on_duty' | 'available' | 'off_duty'
  final String email;
  final String? phoneNumber;
  final int activeCases; // active caseassignment rows
  final DateTime? dateCreated; // when the account was made

  const InvestigatorSummary({
    required this.userId,
    required this.firstName,
    required this.surname,
    this.rank,
    required this.badgeNumber,
    required this.station,
    this.unit,
    required this.dutyStatus,
    required this.email,
    this.phoneNumber,
    this.activeCases = 0,
    this.dateCreated,
  });

  /// Build one from a list_investigators row (keys are the column names).
  factory InvestigatorSummary.fromMap(Map<String, dynamic> row) {
    return InvestigatorSummary(
      userId: (row['userid'] as num).toInt(),
      firstName: row['firstname'] as String,
      surname: row['surname'] as String,
      rank: row['rank'] as String?,
      badgeNumber: row['badgenumber'] as String,
      station: row['station'] as String,
      unit: row['unit'] as String?,
      dutyStatus: row['dutystatus'] as String,
      email: row['email'] as String,
      phoneNumber: row['phonenumber'] as String?,
      activeCases: (row['activecases'] as num?)?.toInt() ?? 0,
      dateCreated: row['datecreated'] == null
          ? null
          : DateTime.parse(row['datecreated'] as String),
    );
  }

  String get fullName => '$firstName $surname';

  /// "Sgt. Thabo Mokoena", or just the name if there's no rank.
  String get displayName => rank == null ? fullName : '$rank $fullName';
}
