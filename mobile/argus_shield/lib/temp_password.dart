// Temporary passwords for new staff accounts.
//
// Admins give new investigators a temporary password (the web console does
// the same for new admins), and the app makes them pick their own on first
// login. The rules here match the create-investigator/create-admin Edge
// Functions.

import 'dart:math';

// No look-alike characters (0/O, 1/l/I) so it can be read out or copied by
// hand without mistakes.
const _letters = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ';
const _digits = '23456789';

final _hasLetter = RegExp(r'[A-Za-z]');
final _hasDigit = RegExp(r'\d');

/// Random temporary password, letters and digits.
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

/// Null if [value] is an OK temporary password, otherwise what's wrong with it.
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
