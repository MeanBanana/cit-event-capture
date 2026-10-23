// Shared state for the citizen tabs.
//
// CitizenHome makes one CitizenStore and hands it to every tab so they're all
// looking at the same data. It's a ChangeNotifier, so anything wrapped in a
// ListenableBuilder rebuilds when it calls notifyListeners().
//
// The profile is loaded from and saved to Supabase via SupabaseService.
// Reports go to Supabase (incident + footage), the AI worker picks them up,
// and the Submissions tab lists them from there.

import 'dart:collection';
import 'package:flutter/foundation.dart';
import '../supabase_service.dart';
import '../saved_contact_details.dart';
import '../models/citizen_profile.dart';
import '../models/my_submission.dart';

// re-exported so files importing citizen_store.dart still get these models
export '../models/citizen_profile.dart';
export '../models/my_submission.dart';

/// A video or photo the citizen picked or recorded, not uploaded yet.
class FootageFile {
  /// Name from the picker, e.g. "VID_20261012_191502.mp4".
  final String name;

  /// Size in bytes, checked against the 50 MB upload limit.
  final int size;

  /// Reads the file only when it's actually being sent, videos are big.
  final Future<Uint8List> Function() readBytes;

  /// MIME type from the picker, if it gave us one.
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

  /// 'image' or 'video', which is what the media table and the AI expect.
  String get mediaType => _imageTypes.containsKey(_ext) ||
          (mimeType?.startsWith('image/') ?? false)
      ? 'image'
      : 'video';

  /// Content type for the upload. The bucket only accepts these.
  String get contentType =>
      _imageTypes[_ext] ?? _videoTypes[_ext] ??
      (mimeType != null && (mimeType!.startsWith('image/') || mimeType!.startsWith('video/'))
          ? mimeType!
          : (mediaType == 'image' ? 'image/jpeg' : 'video/mp4'));

  /// e.g. "12.4 MB"
  String get sizeLabel => size >= 1024 * 1024
      ? '${(size / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(size / 1024).ceil()} KB';
}

/// Progress of a report being sent, for the Upload page's progress bar.
class SendProgress {
  final String message;
  final double fraction; // 0..1

  const SendProgress(this.message, this.fraction);
}

/// Sending stopped part way (lost connection, file rejected...). The
/// incident might already exist, so pass [incidentId] and [uploaded] back to
/// CitizenStore.sendReport to pick up where it left off without making a
/// second incident or uploading the same file twice.
class SendReportFailed implements Exception {
  final String message;
  final int? incidentId;
  final int uploaded;

  const SendReportFailed(this.message, {this.incidentId, this.uploaded = 0});

  @override
  String toString() => message;
}

/// The citizen's data and everything the tabs can do with it.
class CitizenStore extends ChangeNotifier {
  /// [service] and [savedContacts] are only optional so tests can swap in fakes.
  CitizenStore({SupabaseService? service, SavedContactStore? savedContacts})
      : _service = service ?? SupabaseService(),
        _savedContacts = savedContacts ?? SavedContactStore();

  final SupabaseService _service;

  /// Email/phone remembered on this phone for the Forgot password form.
  final SavedContactStore _savedContacts;

  List<MySubmission> _submissions = const [];
  bool _submissionsLoading = false;
  String? _submissionsError;

  CitizenProfile? _profile;
  bool _profileLoading = false;
  String? _profileError;
  bool _disposed = false;

  /// The citizen's reports, newest first.
  UnmodifiableListView<MySubmission> get submissions =>
      UnmodifiableListView(_submissions);

  /// True while reports are loading.
  bool get submissionsLoading => _submissionsLoading;

  /// Error to show if loading reports failed, otherwise null.
  String? get submissionsError => _submissionsError;

  /// Null until loadProfile() succeeds.
  CitizenProfile? get profile => _profile;

  /// True while the profile is loading.
  bool get profileLoading => _profileLoading;

  /// Error to show if the last load failed, otherwise null.
  String? get profileError => _profileError;

  // --- profile

  /// Load the logged-in citizen's profile.
  ///
  /// Calling it again while a load is running does nothing. Errors end up in
  /// [profileError] instead of being thrown, so the Profile tab can show them
  /// with a Retry button.
  Future<void> loadProfile() async {
    if (_profileLoading) return;
    _profileLoading = true;
    // Only notify when we're clearing an old error (i.e. Retry). On the first
    // load nobody is listening yet, and notifying mid-build throws.
    if (_profileError != null) {
      _profileError = null;
      _notify();
    }

    try {
      final profile = await _service.getMyCitizenProfile();
      _profile = profile;
      // keep the copy saved on the phone in sync with the database
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

  /// Validate the form and send only what changed.
  ///
  /// [phone] is the 9 digits after +27. Throws ArgumentError for bad input,
  /// returns {success, message}, and updates [profile] on success.
  ///
  /// If Supabase wants the email confirmed, [profile] keeps the old email
  /// until they click the link (the next load picks up the new one).
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

    // validate here as well, in case something calls this without going through the form
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

    // Even a failed save might have gotten the phone/residence through first
    // (the message says so), so reload to show exactly what's in the database.
    if (result["success"] == true) {
      _profile = current.copyWith(
        email: result["emailChangedNow"] == true ? newEmail : null,
        phoneNumber: phoneChanged ? '+27$newPhone' : null,
        residence: residenceChanged ? newResidence : null,
      );
      // Update the phone's copy too. A pending email doesn't count until it's
      // confirmed, the next profile load will pick it up.
      _savedContacts.save(email: _profile!.email, phone: _profile!.phoneNumber);
      _notify();
    } else if (phoneChanged || residenceChanged) {
      await loadProfile();
    }
    return result;
  }

  // --- submissions

  /// Max files per report. The AI worker treats them as one submission.
  static const maxFiles = 5;

  /// Load the citizen's own reports. Errors go into [submissionsError].
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

  /// Send a report: create the incident, upload each file, then start the
  /// AI analysis. Returns the incident id.
  ///
  /// [latitude]/[longitude] is the phone's GPS, only if the citizen agreed to
  /// share it. Throws ArgumentError for bad input (nothing gets sent), and
  /// [SendReportFailed] if it stopped part way. To retry, pass its incidentId
  /// and uploaded count back in as [resumeIncidentId] / [alreadyUploaded].
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
    // validate here as well, in case something calls this without going through the form
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

      // Refresh the Submissions tab right away. Not awaited, the report is
      // already sent even if this refresh fails.
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

  /// The profile (we need its userId as the reporter), loading it first if
  /// needed or waiting on a load that's already running.
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

  // --- helpers

  /// notifyListeners, but only if we haven't been disposed. A save or load
  /// can finish after the citizen logged out and CitizenHome threw the store
  /// away, and notifying then would throw.
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
