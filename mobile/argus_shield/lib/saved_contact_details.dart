// Remembers the last logged-in user's email and phone on this phone, so the
// Forgot password form can be pre-filled for them.
//
// LoginPage loads it on open, a successful login saves it, and editing the
// citizen profile keeps it up to date.
//
// It's stored with shared_preferences, which is a plain key-value file and
// NOT encrypted. Only non-secret stuff goes here, never passwords or tokens.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What's saved. Either value can be null if nothing's been saved yet.
class SavedContact {
  final String? email;

  /// The 9 digits after +27, e.g. '821234567'.
  final String? phone;

  const SavedContact({this.email, this.phone});

  bool get isEmpty =>
      (email == null || email!.isEmpty) && (phone == null || phone!.isEmpty);
}

/// Reads and writes [SavedContact] on the phone.
///
/// Every method swallows its own errors. If storage isn't available (widget
/// tests, for one) the app just carries on as if nothing was saved.
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

  /// Save what's given. Null or empty values leave the old value alone, so a
  /// login without a phone number doesn't wipe a saved one.
  ///
  /// [phone] can be in any format ('+27821234567', '0821234567',
  /// '821234567'), we store the 9 local digits.
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

  /// Forget both values (for a future "Not you?" or sign-out option).
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

/// A South African number as the 9 digits after +27, so '+27821234567',
/// '27821234567', '0821234567' and '821234567' all give '821234567'.
/// Returns '' for null or anything that isn't a valid SA number.
String localSaPhone(String? phone) {
  final digits = (phone ?? '').replaceAll(RegExp(r'\D'), '');
  if (digits.length == 11 && digits.startsWith('27')) return digits.substring(2);
  if (digits.length == 10 && digits.startsWith('0')) return digits.substring(1);
  if (digits.length == 9) return digits;
  return '';
}
