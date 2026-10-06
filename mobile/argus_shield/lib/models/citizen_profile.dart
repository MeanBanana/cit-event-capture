// citizen_profile.dart — the logged-in citizen's details shown on the
// Profile tab.
//
// Comes from two tables:
//   public."User"    userid, username, firstname, surname, email, phonenumber
//   public.citizen   residence

/// A citizen's profile. Immutable: saving creates a new copy with copyWith.
class CitizenProfile {
  final int userId;
  final String username;
  final String firstName;
  final String surname;
  final String email;

  /// As stored in the database, e.g. '+27821234567'. Null if never set.
  final String? phoneNumber;

  final String? residence;

  const CitizenProfile({
    required this.userId,
    required this.username,
    required this.firstName,
    required this.surname,
    required this.email,
    this.phoneNumber,
    this.residence,
  });

  /// [user] is a "User" row, [citizen] the matching citizen row (or null).
  factory CitizenProfile.fromMaps(
    Map<String, dynamic> user,
    Map<String, dynamic>? citizen,
  ) {
    return CitizenProfile(
      userId: (user['userid'] as num).toInt(),
      username: user['username'] as String? ?? '',
      firstName: user['firstname'] as String? ?? '',
      surname: user['surname'] as String? ?? '',
      email: user['email'] as String? ?? '',
      phoneNumber: user['phonenumber'] as String?,
      residence: citizen?['residence'] as String?,
    );
  }

  String get fullName => '$firstName $surname'.trim();

  /// The 9 digits after +27, for the phone field (which shows "+27 " itself).
  /// '+27821234567' → '821234567', '0821234567' → '821234567'.
  String get localPhone {
    final digits = (phoneNumber ?? '').replaceAll(RegExp(r'\D'), '');
    if (digits.startsWith('27') && digits.length == 11) return digits.substring(2);
    if (digits.startsWith('0') && digits.length == 10) return digits.substring(1);
    return digits;
  }

  CitizenProfile copyWith({
    String? email,
    String? phoneNumber,
    String? residence,
  }) {
    return CitizenProfile(
      userId: userId,
      username: username,
      firstName: firstName,
      surname: surname,
      email: email ?? this.email,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      residence: residence ?? this.residence,
    );
  }
}
