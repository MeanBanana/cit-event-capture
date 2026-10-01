// citizen_store.dart — shared data classes and operations for the local demo.

import 'dart:collection';
import 'package:flutter/foundation.dart';

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

/// A citizen's editable contact details.
class CitizenProfile {
  final String name;
  final String email;
  final String phone;

  const CitizenProfile({
    required this.name,
    required this.email,
    required this.phone,
  });
}

/// Encapsulates the citizen data and operations for the local prototype.
/// Nothing here is persisted to disk or sent to Supabase.
class CitizenStore extends ChangeNotifier {
  // Underscore names are private to this Dart file/library.
  final List<CitizenSubmission> _submissions = [];
  CitizenProfile? _profile;
  int _nextReference = 1;

  /// Read-only view: pages cannot add/remove records through this getter.
  UnmodifiableListView<CitizenSubmission> get submissions =>
      UnmodifiableListView(_submissions);

  /// Null until the citizen saves contact details for the first time.
  CitizenProfile? get profile => _profile;

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
    notifyListeners();
    return submission;
  }

  /// Replaces the saved contact profile only when all basic checks pass.
  /// Throws ArgumentError for invalid input and preserves the existing profile.
  void saveProfile({
    required String name,
    required String email,
    required String phone,
  }) {
    final error = (name.trim().isEmpty ? 'Enter your full name' : null) ??
        (!email.trim().contains('@') ? 'Enter a valid email address' : null) ??
        (phone.trim().isEmpty ? 'Enter your phone number' : null);
    if (error != null) throw ArgumentError(error);

    // Replace the immutable object with a new snapshot of the saved fields.
    _profile = CitizenProfile(
      name: name.trim(),
      email: email.trim(),
      phone: phone.trim(),
    );
    notifyListeners();
  }
}
