// citizen_store.dart — shared data and operations for the citizen tabs.
//
// One CitizenStore is created by CitizenHome and passed to every tab, so
// they all see the same data. It's a ChangeNotifier: after a change it calls
// notifyListeners() and any ListenableBuilder watching it rebuilds.
//
//   * Profile     loaded from / saved to Supabase through SupabaseService.
//   * Submissions sent to Supabase (incident + footage), then analysed by
//                 the AI worker; the Submissions tab lists them from there.

import 'dart:collection';
import 'package:flutter/foundation.dart';
import '../supabase_service.dart';
import '../saved_contact_details.dart';
import '../models/citizen_profile.dart';
import '../models/my_submission.dart';

// Files that import citizen_store.dart can keep using these models.
export '../models/citizen_profile.dart';
export '../models/my_submission.dart';

/// One video or photo the citizen picked or recorded (not uploaded yet).
class FootageFile {
  /// Display name reported by the picker, e.g. "VID_20261012_191502.mp4".
  final String name;

  /// Size in bytes (checked against the 50 MB upload limit).
  final int size;

  /// Reads the file when it is sent (not before: videos are big).
  final Future<Uint8List> Function() readBytes;

  /// The picker's MIME type, if it gave one.
  final String? mimeType;

  const FootageFile({
    required this.name,
    required this.size,
    required this.readBytes,
    this.mimeType,
  });

  static const _imageTypes = {
    '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png',
    '.webp': 'image/webp', '.heic': 'image/heic', '.heif': 'image/heif',
    '.bmp': 'image/bmp', '.gif': 'image/gif', '.tif': 'image/tiff',
    '.tiff': 'image/tiff',
  };
  static const _videoTypes = {
    '.mp4': 'video/mp4', '.mov': 'video/quicktime', '.m4v': 'video/x-m4v',
    '.3gp': 'video/3gpp', '.webm': 'video/webm', '.mkv': 'video/x-matroska',
    '.avi': 'video/x-msvideo',
  };

  String get _ext {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot).toLowerCase();
  }

  /// 'image' or 'video' (what the media table and the AI need).
  String get mediaType => _imageTypes.containsKey(_ext) ||
          (mimeType?.startsWith('image/') ?? false)
      ? 'image'
      : 'video';

  /// The upload's content type; the bucket only accepts these types.
  String get contentType =>
      _imageTypes[_ext] ?? _videoTypes[_ext] ??
      (mimeType != null && (mimeType!.startsWith('image/') || mimeType!.startsWith('video/'))
          ? mimeType!
          : (mediaType == 'image' ? 'image/jpeg' : 'video/mp4'));

  /// "12.4 MB"
  String get sizeLabel => size >= 1024 * 1024
      ? '${(size / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(size / 1024).ceil()} KB';
}

/// How far a report has got, for the progress bar on the Upload page.
class SendProgress {
  final String message;
  final double fraction; // 0..1

  const SendProgress(this.message, this.fraction);
}

/// Sending stopped part-way (no connection, file refused ...). The incident
/// may already exist: pass [incidentId] and [uploaded] back to
/// CitizenStore.sendReport to carry on where it stopped, without making a
/// second incident or uploading a file twice.
class SendReportFailed implements Exception {
  final String message;
  final int? incidentId;
  final int uploaded;

  const SendReportFailed(this.message, {this.incidentId, this.uploaded = 0});

  @override
  String toString() => message;
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
  List<MySubmission> _submissions = const [];
  bool _submissionsLoading = false;
  String? _submissionsError;

  CitizenProfile? _profile;
  bool _profileLoading = false;
  String? _profileError;
  bool _disposed = false;

  /// The citizen's reports from Supabase, newest first (read-only view).
  UnmodifiableListView<MySubmission> get submissions =>
      UnmodifiableListView(_submissions);

  /// True while the reports are being fetched.
  bool get submissionsLoading => _submissionsLoading;

  /// A message to show if loading the reports failed, otherwise null.
  String? get submissionsError => _submissionsError;

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

    final result = await _service.updateMyCitizenProfile (
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

  /// Most files in one report (the AI worker treats them as one submission).
  static const maxFiles = 5;

  /// Fetches the citizen's own reports. Errors go to [submissionsError].
  Future<void> loadSubmissions() async {
    if (_submissionsLoading) return;
    _submissionsLoading = true;
    _submissionsError = null;
    _notify();
    try {
      final profile = _profile ?? await _ensureProfile();
      _submissions = await _service.getMySubmissions(profile.userId);
    } catch (e) {
      debugPrint('loadSubmissions failed: $e');
      _submissionsError =
          'Your reports could not be loaded. Check your connection and try again.';
    } finally {
      _submissionsLoading = false;
      _notify();
    }
  }

  /// Sends a report to Supabase: creates the incident, uploads every file,
  /// then starts the AI analysis. Returns the incident id.
  ///
  /// [latitude]/[longitude] = the phone's GPS, only if the citizen agreed.
  /// Throws ArgumentError for invalid input (nothing sent) and
  /// [SendReportFailed] if it stopped part-way - pass its incidentId and
  /// uploaded count back as [resumeIncidentId] / [alreadyUploaded] to retry.
  Future<int> sendReport({
    required String location,
    required String description,
    required List<FootageFile> files,
    double? latitude,
    double? longitude,
    int? resumeIncidentId,
    int alreadyUploaded = 0,
    void Function(SendProgress progress)? onProgress,
  }) async {
    // Store-level validation protects the data even if a caller bypasses the form.
    final error = (location.trim().isEmpty ? 'Enter the incident location' : null) ??
        (description.trim().isEmpty ? 'Enter a description' : null) ??
        (files.isEmpty ? 'Please select or record footage first.' : null) ??
        (files.length > maxFiles ? 'A report can have at most $maxFiles files.' : null);
    if (error != null) throw ArgumentError(error);
    final tooBig = files.where((f) => f.size > SupabaseService.maxFileBytes).toList();
    if (tooBig.isNotEmpty) {
      throw ArgumentError('${tooBig.first.name} is ${tooBig.first.sizeLabel}: '
          'files can be at most 50 MB. Trim the video and try again.');
    }

    void progress(String message, double fraction) =>
        onProgress?.call(SendProgress(message, fraction));

    int? incidentId = resumeIncidentId;
    var uploaded = alreadyUploaded;
    try {
      progress('Preparing your report…', 0.02);
      final profile = _profile ?? await _ensureProfile();

      final id = incidentId ?? await _service.createIncident(
        reporterId: profile.userId,
        location: location.trim(),
        description: description.trim(),
        when: DateTime.now(),
        latitude: latitude,
        longitude: longitude,
      );
      incidentId = id;

      for (var i = uploaded; i < files.length; i++) {
        final file = files[i];
        progress('Uploading ${file.name} (${i + 1} of ${files.length}, ${file.sizeLabel})…',
            0.05 + 0.85 * i / files.length);
        await _service.uploadIncidentFile(
          incidentId: id,
          uploaderId: profile.userId,
          fileName: file.name,
          bytes: await file.readBytes(),
          contentType: file.contentType,
          mediaType: file.mediaType,
        );
        uploaded = i + 1;
      }

      progress('Starting the analysis…', 0.95);
      await _service.submitForAnalysis(id);
      progress('Sent', 1);

      // Show it in the Submissions tab straight away (not awaited: the
      // report is already sent even if this refresh fails).
      loadSubmissions();
      return id;
    } catch (e) {
      debugPrint('sendReport failed: $e');
      throw SendReportFailed(
        incidentId == null
            ? 'Your report could not be sent. Check your connection and try again.'
            : 'Sending stopped after $uploaded of ${files.length} file(s). '
                'Check your connection and tap Try again - nothing is lost.',
        incidentId: incidentId,
        uploaded: uploaded,
      );
    }
  }

  /// The profile (its userId is the reporter / uploader id), loading it
  /// first if needed. Waits for a load that is already running.
  Future<CitizenProfile> _ensureProfile() async {
    while (_profileLoading) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (_profile == null) await loadProfile();
    final profile = _profile;
    if (profile == null) {
      throw StateError(_profileError ?? 'Your profile could not be loaded.');
    }
    return profile;
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
