// investigator_summary.dart — one investigator as the admin screens need it.

/// Field names follow the database: public."User" (firstname, surname,
/// email, phonenumber) joined with public.investigator (rank, badgenumber,
/// station, unit, dutystatus). Rows come from the list_investigators
/// database function (see SupabaseService.getRecentInvestigators).
class InvestigatorSummary {
  final int userId;
  final String firstName;
  final String surname;
  final String? rank; // e.g. 'Sgt.' — nullable in the database
  final String badgeNumber; // e.g. 'JHB-4471'
  final String station; // e.g. 'Kempton Park SAPS'
  final String? unit; // e.g. 'CIT Task Force' — nullable in the database
  final String dutyStatus; // 'on_duty' | 'available' | 'off_duty'
  final String email;
  final String? phoneNumber;
  final int activeCases; // count of active rows in caseassignment
  final DateTime? dateCreated; // when the account was created

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

  /// Builds one from a row returned by list_investigators
  /// (keys are the database column names).
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

  /// "Sgt. Thabo Mokoena", or just the name when no rank is stored.
  String get displayName => rank == null ? fullName : '$rank $fullName';
}
