// temp_password.dart — temporary passwords for new staff accounts.
//
// An admin gives a new investigator a temporary password (the web console
// does the same for new admins). At their first log-in the app makes them
// choose their own (see login.dart and ResetPasswordPage). The rules match
// the create-investigator / create-admin Edge Functions.

import 'dart:math';

// Letters and digits without look-alikes (0/O, 1/l/I), so the password can
// be read out or typed over without mistakes.
const _letters = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ';
const _digits = '23456789';

final _hasLetter = RegExp(r'[A-Za-z]');
final _hasDigit = RegExp(r'\d');

/// A random temporary password with letters and digits.
String generateTempPassword({int length = 12, Random? random}) {
  final rng = random ?? Random.secure();
  const all = _letters + _digits;
  while (true) {
    final password =
        List.generate(length, (_) => all[rng.nextInt(all.length)]).join();
    if (_hasLetter.hasMatch(password) && _hasDigit.hasMatch(password)) {
      return password;
    }
  }
}

/// Null if [value] is a valid temporary password, otherwise the message.
String? validateTempPassword(String? value) {
  final text = value ?? '';
  if (text.isEmpty) return 'Enter or generate a temporary password';
  if (text.length < 8 || text.length > 72 ||
      !_hasLetter.hasMatch(text) ||
      !_hasDigit.hasMatch(text)) {
    return 'Use 8-72 characters with letters and numbers';
  }
  return null;
}
