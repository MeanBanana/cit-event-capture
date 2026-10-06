// citizen_store.dart — shared data and operations for the citizen tabs.
//
// One CitizenStore is created by CitizenHome and passed to every tab, so
// they all see the same data. It's a ChangeNotifier: after a change it calls
// notifyListeners() and any ListenableBuilder watching it rebuilds.
//
//   * Profile     loaded from / saved to Supabase through SupabaseService.
//   * Submissions still a local demo (kept in memory, not uploaded).

import 'dart:collection';
import 'package:flutter/foundation.dart';
import '../supabase_service.dart';
import '../saved_contact_details.dart';
import '../models/citizen_profile.dart';

// Files that import citizen_store.dart can keep using CitizenProfile.
export '../models/citizen_profile.dart';

/// Metadata about the selected file. This does not upload or encrypt the file.
class MediaAttachment {
  /// Display name reported by the picker.
  final String name;
  /// Temporary picker path; no permanent copy is created by this prototype.
  final String path;

  const MediaAttachment({required this.name, required this.path});
}

/// An immutable snapshot of an incident report added in this app session.
class CitizenSubmission {
  /// Demo reference that is unique within one store instance.
  final String reference;
  final String location;
  /// Time the report was added; not the time the incident occurred.
  final DateTime createdAt;
  final String description;
  final MediaAttachment attachment;

  const CitizenSubmission({
    required this.reference,
    required this.location,
    required this.createdAt,
    required this.description,
    required this.attachment,
  });
}

/// Holds the citizen's data and the operations the tabs use.
class CitizenStore extends ChangeNotifier {
  /// [service] and [savedContacts] are optional so tests can pass in fakes.
  CitizenStore({SupabaseService? service, SavedContactStore? savedContacts})
      : _service = service ?? SupabaseService(),
        _savedContacts = savedContacts ?? SavedContactStore();

  final SupabaseService _service;

  /// The email/phone remembered on this phone for the Forgot password form.
  final SavedContactStore _savedContacts;

  // Underscore names are private to this Dart file/library.
  final List<CitizenSubmission> _submissions = [];
  int _nextReference = 1;

  CitizenProfile? _profile;
  bool _profileLoading = false;
  String? _profileError;
  bool _disposed = false;

  /// Read-only view: pages cannot add/remove records through this getter.
  UnmodifiableListView<CitizenSubmission> get submissions =>
      UnmodifiableListView(_submissions);

  /// Null until loadProfile() succeeds.
  CitizenProfile? get profile => _profile;

  /// True while the profile is being fetched.
  bool get profileLoading => _profileLoading;

  /// A message to show if the last load failed, otherwise null.
  String? get profileError => _profileError;

  // ---------------------------------------------------------------- PROFILE

  /// Fetches the logged-in citizen's profile from Supabase.
  ///
  /// Safe to call more than once: a second call while one is running is
  /// ignored. Errors are caught and stored in [profileError] rather than
  /// thrown, so the Profile tab can show them with a Retry button.
  Future<void> loadProfile() async {
    if (_profileLoading) return;
    _profileLoading = true;
    // Only notify when clearing an old error (a Retry tap). On the very first
    // load nothing is listening yet, and notifying during a build would throw.
    if (_profileError != null) {
      _profileError = null;
      _notify();
    }

    try {
      final profile = await _service.getMyCitizenProfile();
      _profile = profile;
      // Keep the copy on this phone in step with the database.
      _savedContacts.save(email: profile.email, phone: profile.phoneNumber);
    } catch (e) {
      debugPrint('loadProfile failed: $e');
      _profileError =
          'Your profile could not be loaded. Check your connection and try again.';
    } finally {
      _profileLoading = false;
      _notify();
    }
  }

  /// Validates the form values and sends only the changed ones to Supabase.
  ///
  /// [phone] is the 9 digits after +27. Throws ArgumentError for invalid
  /// input. Returns {success, message}; on success [profile] is updated.
  ///
  /// If Supabase asks for email confirmation, the email in [profile] stays
  /// the old one until the citizen opens the link (the next load shows it).
  Future<Map<String, dynamic>> saveProfile({
    required String email,
    required String phone,
    required String residence,
  }) async {
    final current = _profile;
    if (current == null) {
      return {"success": false, "message": "Your profile has not loaded yet."};
    }

    final newEmail = email.trim();
    final newPhone = phone.trim();
    final newResidence = residence.trim();

    // Store-level validation protects the data even if a caller bypasses the form.
    final error =
        (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(newEmail)
                ? 'Enter a valid email address'
                : null) ??
            (!RegExp(r'^\d{9}$').hasMatch(newPhone)
                ? 'Phone number must be 9 digits, no initial 0'
                : null) ??
            (newResidence.isEmpty ? 'Enter your residence' : null);
    if (error != null) throw ArgumentError(error);

    final emailChanged = newEmail.toLowerCase() != current.email.toLowerCase();
    final phoneChanged = newPhone != current.localPhone;
    final residenceChanged = newResidence != (current.residence ?? '');

    if (!emailChanged && !phoneChanged && !residenceChanged) {
      return {"success": true, "message": "No changes to save."};
    }

    final result = await _service.updateMyCitizenProfile(
      userId: current.userId,
      email: emailChanged ? newEmail : null,
      phone: phoneChanged ? newPhone : null,
      residence: residenceChanged ? newResidence : null,
    );

    // Update the local copy with whatever was saved. Even when the result is
    // a failure, the phone/residence may already have gone through (the
    // message says so), so reload to show exactly what the database has.
    if (result["success"] == true) {
      _profile = current.copyWith(
        email: result["emailChangedNow"] == true ? newEmail : null,
        phoneNumber: phoneChanged ? '+27$newPhone' : null,
        residence: residenceChanged ? newResidence : null,
      );
      // Update the copy on this phone too. A pending email isn't saved until
      // it's confirmed (the next profile load picks it up).
      _savedContacts.save(email: _profile!.email, phone: _profile!.phoneNumber);
      _notify();
    } else if (phoneChanged || residenceChanged) {
      await loadProfile();
    }
    return result;
  }

  // ------------------------------------------------------------ SUBMISSIONS

  /// Adds validated incident details and attachment metadata to memory.
  /// Throws ArgumentError for missing values; does not upload the media file.
  CitizenSubmission submitReport({
    required String location,
    required String description,
    required MediaAttachment attachment,
  }) {
    // Store-level validation protects the data even if a caller bypasses the form.
    final error = (location.trim().isEmpty ? 'Enter the incident location' : null) ??
        (description.trim().isEmpty ? 'Enter a description' : null);
    if (error != null) throw ArgumentError(error);
    if (attachment.name.trim().isEmpty || attachment.path.trim().isEmpty) {
      throw ArgumentError('Please select or record footage first.');
    }

    // final model fields form a snapshot instead of sharing editable controllers.
    final submission = CitizenSubmission(
      // The counter increments after use; padding displays DEMO-0001, etc.
      reference: 'DEMO-${(_nextReference++).toString().padLeft(4, '0')}',
      location: location.trim(),
      createdAt: DateTime.now(),
      description: description.trim(),
      attachment: attachment,
    );
    // Insert at zero so the newest report appears first.
    _submissions.insert(0, submission);
    // Listening widgets refresh after a successful change.
    _notify();
    return submission;
  }

  // ---------------------------------------------------------------- HELPERS

  /// notifyListeners, unless the store has been disposed. A save or load can
  /// finish after the citizen has logged out and CitizenHome has disposed
  /// the store; notifying then would throw.
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
