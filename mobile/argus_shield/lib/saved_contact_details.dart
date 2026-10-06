// saved_contact_details.dart — remembers the last logged-in user's email
// and phone number on this phone, so the Forgot password form can be
// filled in for them.
//
// Flow:
//   1. LoginPage opens      -> load()  (empty the first time the app is used)
//   2. Login succeeds       -> save()  (inserts, or overwrites older values)
//   3. Citizen edits profile -> save() (keeps the copy up to date)
//
// Stored with shared_preferences: a small key-value file private to this
// app. It is not encrypted, so only non-secret details belong here - never
// passwords or tokens.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What was saved. Either value can be null (nothing saved yet).
class SavedContact {
  final String? email;

  /// The 9 digits after +27, e.g. '821234567'.
  final String? phone;

  const SavedContact({this.email, this.phone});

  bool get isEmpty =>
      (email == null || email!.isEmpty) && (phone == null || phone!.isEmpty);
}

/// Reads and writes [SavedContact] on the device.
///
/// Every method catches its own errors: if storage isn't available (e.g. in
/// widget tests) the app carries on as if nothing was saved.
class SavedContactStore {
  static const _emailKey = 'argus.saved_email';
  static const _phoneKey = 'argus.saved_phone';

  /// The saved details, or an empty [SavedContact].
  Future<SavedContact> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return SavedContact(
        email: prefs.getString(_emailKey),
        phone: prefs.getString(_phoneKey),
      );
    } catch (e) {
      debugPrint('SavedContactStore.load failed: $e');
      return const SavedContact();
    }
  }

  /// Saves the values given. A null or empty value leaves the old one alone,
  /// so a login that returns no phone number doesn't wipe a saved one.
  ///
  /// [phone] may be in any format ('+27821234567', '0821234567',
  /// '821234567'); it is stored as the 9 local digits.
  Future<void> save({String? email, String? phone}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cleanEmail = email?.trim() ?? '';
      final cleanPhone = localSaPhone(phone);
      if (cleanEmail.isNotEmpty) await prefs.setString(_emailKey, cleanEmail);
      if (cleanPhone.isNotEmpty) await prefs.setString(_phoneKey, cleanPhone);
    } catch (e) {
      debugPrint('SavedContactStore.save failed: $e');
    }
  }

  /// Forgets both values (e.g. for a "Not you?" or sign-out option later).
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_emailKey);
      await prefs.remove(_phoneKey);
    } catch (e) {
      debugPrint('SavedContactStore.clear failed: $e');
    }
  }
}

/// A South African number as the 9 digits after +27:
/// '+27821234567' / '27821234567' / '0821234567' / '821234567' -> '821234567'.
/// Returns '' for null or anything that isn't a valid SA mobile/landline.
String localSaPhone(String? phone) {
  final digits = (phone ?? '').replaceAll(RegExp(r'\D'), '');
  if (digits.length == 11 && digits.startsWith('27')) return digits.substring(2);
  if (digits.length == 10 && digits.startsWith('0')) return digits.substring(1);
  if (digits.length == 9) return digits;
  return '';
}
