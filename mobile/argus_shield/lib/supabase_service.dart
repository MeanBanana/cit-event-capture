import 'dart:math';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'connection_status.dart';
import 'models/investigator_summary.dart';
import 'models/system_stats.dart';
import 'models/crime_scene_summary.dart';
import 'models/activity_item.dart';
import 'models/case_summary.dart';
import 'models/case_assignment_info.dart';
import 'models/submission_groups.dart';
import 'models/citizen_profile.dart';
import 'models/my_submission.dart';
import 'models/crime_scene.dart';
import 'models/case_message.dart';

/// Sort order for submission lists, by date reported.
enum SubmissionOrder { newest, oldest }

/// Every Supabase call the app makes goes through here.
///
/// A quick note on accounts (database/README.md has the long version):
/// registering just calls auth.signUp with the form fields in `data`, and a
/// database trigger creates the "User" and citizen rows. The app never
/// inserts into those tables itself, and the database would refuse anyway,
/// otherwise anyone could make themselves an admin. Login takes a username,
/// looks up the email with email_for_username and signs in with that.
class SupabaseService {
  // Getter rather than a field so we can construct this before Supabase is
  // initialised, which the widget tests rely on.
  SupabaseClient get supabase => Supabase.instance.client;

  // --- register
  Future<Map<String, dynamic>> registerUser({
    required String firstname,
    required String surname,
    required String username,
    required String email,
    required String phone,
    required String residence,
    required String password,
  }) async {
    try {
      // check the username first so we can give a clear message
      final available = await supabase.rpc(
        'username_available',
        params: {'p_username': username.trim()},
      );
      if (available != true) {
        return {"success": false, "message": "That username is already taken."};
      }

      // create the account
      final authResponse = await supabase.auth.signUp(
        email: email.trim(),
        password: password,
        data: {
          'username': username.trim(),
          'firstname': firstname.trim(),
          'surname': surname.trim(),
          'phonenumber': '+27${phone.trim()}', // the form only collects the 9 digits after +27
          'residence': residence.trim(),
        },
      );

      final user = authResponse.user;
      if (user == null) {
        return {"success": false, "message": "Sign up failed."};
      }
      // With "Confirm email" on, Supabase doesn't error for an email that's
      // already registered, it hands back a user with no identities instead.
      if (user.identities != null && user.identities!.isEmpty) {
        return {"success": false, "message": "An account with this email already exists."};
      }

      // With "Confirm email" off, signUp logs them straight in. Sign out so
      // they log in themselves from the login page.
      if (authResponse.session != null) {
        await supabase.auth.signOut();
      }

      return {"success": true, "message": "User successfully registered"};
    } on AuthWeakPasswordException {
      return {"success": false, "message": "Password is too weak."};
    } on AuthException catch (e) {
      if (isNetworkError(e)) {
        return {"success": false, "message": networkErrorText(e)};
      }
      if (e.code == 'user_already_exists' || e.code == 'email_exists') {
        return {"success": false, "message": "An account with this email already exists."};
      }
      if (e.message.contains('Database error saving new user')) {
        // the sign-up trigger rejected it (username taken or invalid)
        return {
          "success": false,
          "message": "Username is invalid or already taken. Use 3-30 letters, numbers, _ or .",
        };
      }
      return {"success": false, "message": e.message};
    } on PostgrestException catch (e) {
      if (isNetworkError(e)) {
        return {"success": false, "message": networkErrorText(e)};
      }
      return {"success": false, "message": e.message};
    } catch (e) {
      if (isNetworkError(e)) {
        return {"success": false, "message": networkErrorText(e)};
      }
      return {"success": false, "message": e.toString()};
    }
  }

  // --- login
  /// On success the result includes "profile" (userid, username, firstname,
  /// surname, email, phonenumber, role) and "mustChangePassword", which is
  /// true for a new admin/investigator still on their temporary password.
  Future<Map<String, dynamic>> loginUser({
    required String username,
    required String password,
  }) async {
    // Same message for a wrong username and a wrong password, so the login
    // screen can't be used to find out which usernames exist.
    const badLogin = "Username or password is incorrect. Please check again.";
    try {
      final email = await supabase.rpc(
        'email_for_username',
        params: {'p_username': username.trim()},
      );
      if (email is! String) {
        // no account with that username
        return {"success": false, "message": badLogin};
      }

      final authResponse = await supabase.auth.signInWithPassword(
        email: email,
        password: password,
      );

      final profile = await supabase
          .from('User')
          .select('userid, username, firstname, surname, email, phonenumber, role')
          .eq('authid', authResponse.user!.id)
          .single();

      return {
        "success": true,
        "message": "Welcome ${profile['firstname']}",
        "profile": profile,
        "mustChangePassword":
            authResponse.user!.appMetadata['must_change_password'] == true,
      };
    } on AuthException catch (e) {
      if (isNetworkError(e)) {
        return {"success": false, "message": networkErrorText(e)};
      }
      if (e.code == 'email_not_confirmed') {
        return {"success": false, "message": "Please confirm your email address first."};
      }
      if (e.code == 'user_banned') {
        return {"success": false, "message": "This account has been disabled. Contact an administrator."};
      }
      return {"success": false, "message": badLogin};
    } on PostgrestException catch (e) {
      if (isNetworkError(e)) {
        return {"success": false, "message": networkErrorText(e)};
      }
      return {"success": false, "message": e.message};
    } catch (e) {
      if (isNetworkError(e)) {
        return {"success": false, "message": networkErrorText(e)};
      }
      return {"success": false, "message": e.toString()};
    }
  }

  // --- logout
  Future<void> logout() => supabase.auth.signOut();

  // --- reset password
  // sendPasswordReset gets Supabase to email a link. The link opens the app
  // via the deep link below (set up in AndroidManifest.xml, Info.plist, and
  // the dashboard's Redirect URLs). supabase_flutter picks it up, signs the
  // user in just for this and fires AuthChangeEvent.passwordRecovery, which
  // main.dart listens for to open ResetPasswordPage. That page calls
  // updatePassword and logs out so they sign in with the new one.
  // Because it's PKCE, the link only works on the phone that asked for it.

  /// Where the reset email's link sends people.
  static const passwordResetRedirect = 'argusshield://reset-password';

  /// Email a password reset link. Supabase answers the same whether or not
  /// the email exists, so this doesn't leak which emails are registered.
  Future<Map<String, dynamic>> sendPasswordReset(String email) async {
    try {
      await supabase.auth.resetPasswordForEmail(
        email.trim(),
        redirectTo: passwordResetRedirect,
      );
      return {
        "success": true,
        "message": "If an account exists for $email, a reset link has been "
            "sent. Open it on this phone.",
      };
    } on AuthException catch (e) {
      if (isNetworkError(e)) {
        return {"success": false, "message": networkErrorText(e)};
      }
      if (e.statusCode == '429' || e.code == 'over_email_send_rate_limit') {
        return {
          "success": false,
          "message": "Too many reset emails. Please wait a while and try again.",
        };
      }
      return {"success": false, "message": e.message};
    } catch (e) {
      if (isNetworkError(e)) {
        return {"success": false, "message": networkErrorText(e)};
      }
      return {
        "success": false,
        "message": "Could not send the reset email. Check your connection.",
      };
    }
  }

  /// Set a new password for whoever's signed in, either after a reset link
  /// or on first login with a temporary password (the database clears
  /// must_change_password when this happens).
  Future<Map<String, dynamic>> updatePassword(String newPassword) async {
    try {
      await supabase.auth.updateUser(UserAttributes(password: newPassword));
      return {"success": true, "message": "Password changed, please log in"};
    } on AuthWeakPasswordException {
      return {"success": false, "message": "Password is too weak."};
    } on AuthException catch (e) {
      if (isNetworkError(e)) {
        return {"success": false, "message": networkErrorText(e)};
      }
      if (e.code == 'same_password') {
        return {
          "success": false,
          "message": "Choose a password that is different from your old one.",
        };
      }
      if (e is AuthSessionMissingException ||
          e.code == 'session_not_found' ||
          e.code == 'session_expired') {
        return {
          "success": false,
          "message": "This reset link has expired. Please request a new one.",
        };
      }
      return {"success": false, "message": e.message};
    } catch (e) {
      if (isNetworkError(e)) {
        return {"success": false, "message": networkErrorText(e)};
      }
      return {
        "success": false,
        "message": "Could not change the password. Check your connection.",
      };
    }
  }

  // --- citizen profile
  // RLS only lets a citizen read and update their own "User" and citizen
  // rows, and a trigger stops them changing their role or email there. So
  // phone and residence are plain updates, email goes through Auth (which
  // sends a confirmation link, and on_auth_user_email_changed copies it into
  // "User".email once confirmed), and names can't be changed here at all.

  /// The logged-in citizen's profile. Throws if nobody's logged in or the
  /// rows can't be read, so the screen can show an error and a Retry button.
  Future<CitizenProfile> getMyCitizenProfile() async {
    final authUser = supabase.auth.currentUser;
    if (authUser == null) {
      throw StateError('Nobody is logged in.');
    }

    final user = await supabase
        .from('User')
        .select('userid, username, firstname, surname, email, phonenumber')
        .eq('authid', authUser.id)
        .single();

    // maybeSingle because older accounts might not have a citizen row yet
    final citizen = await supabase
        .from('citizen')
        .select('residence')
        .eq('userid', user['userid'])
        .maybeSingle();

    return CitizenProfile.fromMaps(user, citizen);
  }

  /// Save the citizen's changes. Only pass what changed, null means leave it.
  /// [phone] is the 9 digits after +27, same as the register form.
  ///
  /// Returns {success, message, emailPending, emailChangedNow}. emailPending
  /// means a confirmation email went out and the new address only kicks in
  /// once they click it. emailChangedNow means the project doesn't require
  /// confirmation.
  Future<Map<String, dynamic>> updateMyCitizenProfile({
    required int userId,
    String? email,
    String? phone,
    String? residence,
  }) async {
    // so the error message can mention what already got saved
    final saved = <String>[];
    try {
      if (phone != null) {
        // .select() gives back the updated rows. If RLS blocks an update
        // Postgres doesn't error, it just updates nothing, so we have to
        // check the row count rather than assume it worked.
        final rows = await supabase
            .from('User')
            .update({'phonenumber': '+27${phone.trim()}'})
            .eq('userid', userId)
            .select('userid');
        if ((rows as List).isEmpty) {
          return {"success": false, "message": "Your phone number could not be saved."};
        }
        saved.add('phone number');
      }

      if (residence != null) {
        final rows = await supabase
            .from('citizen')
            .update({'residence': residence.trim()})
            .eq('userid', userId)
            .select('userid');
        if ((rows as List).isEmpty) {
          return {
            "success": false,
            "message": _partly(saved, "Your residence could not be saved."),
          };
        }
        saved.add('residence');
      }

      var emailPending = false;
      var emailChangedNow = false;
      if (email != null) {
        final response =
            await supabase.auth.updateUser(UserAttributes(email: email.trim()));
        // With "Secure email change" on (the default) Supabase parks the new
        // address in newEmail until the link is clicked. With it off, the
        // email changes immediately.
        emailPending = response.user?.newEmail != null;
        emailChangedNow = !emailPending;
        if (emailChangedNow) saved.add('email');
      }

      final parts = <String>[
        if (saved.isNotEmpty)
          'Your ${saved.join(' and ')} ${saved.length == 1 ? 'was' : 'were'} saved.',
        if (emailPending)
          'We sent a confirmation link to ${email!.trim()}. '
              'Your email changes once you open it.',
      ];
      return {
        "success": true,
        "message": parts.join(' '),
        "emailPending": emailPending,
        "emailChangedNow": emailChangedNow,
      };
    } on AuthException catch (e) {
      if (isNetworkError(e)) {
        return {"success": false, "message": _partly(saved, networkErrorText(e))};
      }
      final reason = (e.code == 'email_exists' || e.code == 'user_already_exists')
          ? "That email address is already used by another account."
          : e.code == 'over_email_send_rate_limit'
              ? "Too many emails sent. Please wait a few minutes and try again."
              : "Your email could not be changed: ${e.message}";
      return {"success": false, "message": _partly(saved, reason)};
    } on PostgrestException catch (e) {
      if (isNetworkError(e)) {
        return {"success": false, "message": _partly(saved, networkErrorText(e))};
      }
      return {"success": false, "message": _partly(saved, e.message)};
    } catch (e) {
      if (isNetworkError(e)) {
        return {"success": false, "message": _partly(saved, networkErrorText(e))};
      }
      return {"success": false, "message": _partly(saved, e.toString())};
    }
  }

  /// "Your phone number was saved, but `reason`", for when part of it had
  /// already gone through before the failure.
  String _partly(List<String> saved, String reason) => saved.isEmpty
      ? reason
      : "Your ${saved.join(' and ')} ${saved.length == 1 ? 'was' : 'were'} saved, but: $reason";

  // --- investigators
  // Both of these use the list_investigators function (joins "User" and
  // investigator, counts active assignments, newest first). The database
  // decides who gets rows. Errors are thrown so the screen can show them.

  /// The [limit] newest investigators.
  Future<List<InvestigatorSummary>> getRecentInvestigators({int limit = 20}) =>
      _listInvestigators(limit: limit);

  /// Investigators whose badge number or name contains [query], case
  /// insensitive ("jhb" finds "JHB-4471", "thabo m" finds "Thabo Mokoena").
  /// Empty [query] gives the newest ones.
  Future<List<InvestigatorSummary>> searchInvestigators(
    String query, {
    int limit = 20,
  }) =>
      _listInvestigators(search: query, limit: limit);

  Future<List<InvestigatorSummary>> _listInvestigators({
    String? search,
    required int limit,
  }) async {
    final text = search?.trim() ?? '';
    final rows = await supabase.rpc(
      'list_investigators',
      params: {
        'p_search': text.isEmpty ? null : text,
        'p_limit': limit,
      },
    );
    return (rows as List)
        .map((row) => InvestigatorSummary.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  /// Create an investigator account (admins only) with the temporary
  /// [password] the admin picked.
  ///
  /// Goes through the create-investigator Edge Function, since only the
  /// service key can create a login with the investigator role. The login is
  /// flagged must_change_password so they pick their own on first login.
  ///
  /// [phone] is optional, 9 digits after +27. Throws FunctionException on
  /// failure, and details['error'] holds a message meant for the admin (see
  /// errorText in admin_ui.dart).
  Future<void> createInvestigator({
    required String firstName,
    required String surname,
    required String username,
    required String email,
    String? phone,
    String? rank,
    required String badgeNumber,
    required String station,
    String? unit,
    required String password,
  }) async {
    await supabase.functions.invoke(
      'create-investigator',
      body: {
        'firstname': firstName.trim(),
        'surname': surname.trim(),
        'username': username.trim(),
        'email': email.trim(),
        'phone': phone?.trim() ?? '',
        'rank': rank?.trim() ?? '',
        'badgenumber': badgeNumber.trim(),
        'station': station.trim(),
        'unit': unit?.trim() ?? '',
        'password': password,
      },
    );
  }

  /// Login username for [userId]. The investigator list doesn't include it
  /// but the Update form needs it. Admins can read any "User" row.
  Future<String?> getUsername(int userId) async {
    final row = await supabase
        .from('User')
        .select('username')
        .eq('userid', userId)
        .maybeSingle();
    return row?['username'] as String?;
  }

  /// Update an investigator's details and login via manage-investigator
  /// (changing someone's email or password needs the service key).
  /// [password] is optional, and if given it's a temporary one they'll have
  /// to change next login. Throws FunctionException like [createInvestigator].
  Future<void> updateInvestigator({
    required int userId,
    required String firstName,
    required String surname,
    required String username,
    required String email,
    String? phone,
    String? rank,
    required String badgeNumber,
    required String station,
    String? unit,
    String? password,
  }) async {
    await supabase.functions.invoke(
      'manage-investigator',
      body: {
        'action': 'update',
        'userid': userId,
        'firstname': firstName.trim(),
        'surname': surname.trim(),
        'username': username.trim(),
        'email': email.trim(),
        'phone': phone?.trim() ?? '',
        'rank': rank?.trim() ?? '',
        'badgenumber': badgeNumber.trim(),
        'station': station.trim(),
        'unit': unit?.trim() ?? '',
        if (password != null && password.isNotEmpty) 'password': password,
      },
    );
  }

  /// Remove an investigator's account (manage-investigator). Returns
  /// 'deleted' if they'd never done anything, or 'anonymised' if their case
  /// work has to stay on record as "Former investigator" (login gets banned).
  Future<String> deleteInvestigator(int userId) async {
    final response = await supabase.functions.invoke(
      'manage-investigator',
      body: {'action': 'delete', 'userid': userId},
    );
    final data = response.data;
    return data is Map && data['mode'] is String ? data['mode'] as String : 'deleted';
  }

  /// Permanently delete a rejected submission, its footage and everything
  /// the AI found (delete-submission). Returns a warning if some files
  /// couldn't be removed, otherwise null.
  Future<String?> deleteSubmission(int incidentId) async {
    final response = await supabase.functions.invoke(
      'delete-submission',
      body: {'incidentid': incidentId},
    );
    final data = response.data;
    return data is Map && data['warning'] is String ? data['warning'] as String : null;
  }

  // --- admin stats
  /// The four System status numbers on the admin Overview.
  Future<SystemStats> getAdminStats() async {
    final rows = await supabase.rpc('admin_overview_stats') as List;
    return SystemStats.fromMap(rows.first as Map<String, dynamic>);
  }

  /// The [limit] newest Recent activity items for the admin Overview.
  Future<List<ActivityItem>> getRecentActivity({int limit = 5}) async {
    final rows = await supabase.rpc(
      'recent_activity',
      params: {'p_limit': limit},
    );
    return (rows as List)
        .map((row) => ActivityItem.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  // --- submissions
  // All of these go through list_submissions, which returns incidents with
  // the reporter, media count, review details, AI summary and what the AI
  // saw. The database decides what you get back.
  //
  // [review] filters by the admin's decision: null for everything, or
  // 'pending', 'accepted', 'rejected', 'duplicate'.

  /// Rows per page.
  static const int pageSize = 30;

  /// One page of submissions, for lists that load more as you scroll.
  ///
  /// Pass the last submission you've got as [after] for the next page (null
  /// for the first). A page shorter than [limit] means you've hit the end.
  /// The database uses a cursor rather than OFFSET, so page 100 is as quick
  /// as page 1.
  ///
  /// Optional filters: [search] (incident number like "42"/"INC-0042", or
  /// location text), [review], [caseId], [locationKey] (from
  /// listLocationGroups) and [ids].
  Future<List<CrimeSceneSummary>> listSubmissionsPage({
    String? search,
    String? review,
    int? caseId,
    String? locationKey,
    List<int>? ids,
    SubmissionOrder order = SubmissionOrder.newest,
    CrimeSceneSummary? after,
    int limit = pageSize,
  }) async {
    final text = search?.trim() ?? '';
    final rows = await supabase.rpc('list_submissions', params: {
      'p_search': text.isEmpty ? null : text,
      'p_limit': limit,
      'p_review': review,
      'p_caseid': caseId,
      'p_order': order.name,
      'p_after_time': after?.dateReported?.toUtc().toIso8601String(),
      'p_after_id': after?.incidentId,
      'p_locationkey': locationKey,
      'p_ids': ids,
    });
    return (rows as List)
        .map((row) => CrimeSceneSummary.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  /// One submission, or null if it doesn't exist or you can't see it.
  Future<CrimeSceneSummary?> getSubmission(int incidentId) async {
    final rows = await listSubmissionsPage(ids: [incidentId], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// The [limit] most recent incidents. Used by the Overview.
  Future<List<CrimeSceneSummary>> getRecentSubmissions({
    int limit = 20,
    String? review,
  }) =>
      listSubmissionsPage(limit: limit, review: review);

  /// Incidents matching [query], either an incident number ("42",
  /// "INC-0042", "inc 42") or location text. Empty gives the most recent.
  /// The pickers use this.
  Future<List<CrimeSceneSummary>> searchSubmissions(
    String query, {
    int limit = 20,
    String? review,
  }) =>
      listSubmissionsPage(search: query, limit: limit, review: review);

  /// First 100 incidents in a case (accepted ones plus their duplicates).
  Future<List<CrimeSceneSummary>> getCaseIncidents(int caseId) =>
      listSubmissionsPage(caseId: caseId, limit: 100);

  /// A submission's clips/photos and what the AI saw in each.
  Future<List<MediaItem>> getIncidentMedia(int incidentId) async {
    final rows = await supabase
        .rpc('list_incident_media', params: {'p_incidentid': incidentId}) as List;
    return rows
        .map((row) => MediaItem.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  // --- crime scenes and corrections
  // A case is made up of crime scenes. Admins and assigned investigators can
  // see them, the database checks that.

  /// A card per crime scene in the case: description, location, suspect/
  /// vehicle/weapon counts and how far the AI has got with its footage.
  Future<List<CrimeSceneCardInfo>> listCaseCrimeScenes(int caseId) async {
    final rows = await supabase
        .rpc('list_case_crime_scenes', params: {'p_caseid': caseId}) as List;
    return rows
        .map((row) => CrimeSceneCardInfo.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  /// One crime scene in full: files, detections (with their correctable
  /// fields) and the corrections log. Null if it doesn't exist.
  Future<CrimeSceneDetail?> getCrimeScene(int incidentId) async {
    final data = await supabase
        .rpc('get_crime_scene', params: {'p_incidentid': incidentId});
    if (data == null) return null;
    return CrimeSceneDetail.fromMap(Map<String, dynamic>.from(data as Map));
  }

  /// Correct one field of a detection ('plate', 'make', 'colour',
  /// 'weapon_type', 'dismissed', ...). null or '' for [value] means none.
  /// Gets logged with [note]. Fails while the AI is still on the footage, and
  /// for investigators once the case is closed.
  Future<void> correctDetection(int detectionId, String field, String? value,
      {String? note}) async {
    final text = note?.trim() ?? '';
    await supabase.rpc('correct_detection', params: {
      'p_detectionid': detectionId,
      'p_field': field,
      'p_value': value,
      'p_note': text.isEmpty ? null : text,
    });
  }

  // --- AI worker

  /// Kick off the AI analysis. Call it once, after the last file (of 1-5) is
  /// uploaded and its media row exists. Only the reporting citizen or an
  /// admin can, and calling it again while it's queued or running does
  /// nothing. Returns the job id. The submission shows "AI processing" until
  /// aisummarystatus goes to ready or failed.
  Future<int> submitForAnalysis(int incidentId) async {
    final jobId = await supabase
        .rpc('submit_for_analysis', params: {'p_incidentid': incidentId});
    return (jobId as num).toInt();
  }

  /// For admins: is a worker up? Returns {online, workers, queued, running,
  /// failed_24h}, where workers has gpu/version/last seen for each one.
  Future<Map<String, dynamic>> getAiWorkerStatus() async {
    final status = await supabase.rpc('ai_worker_status');
    return Map<String, dynamic>.from(status as Map);
  }

  // --- grouping

  /// Submissions grouped by location, most recent first. [search] filters
  /// the location text. [offset] is how many groups you already have. There
  /// aren't many groups so plain offset paging is fine here.
  Future<List<LocationGroup>> listLocationGroups({
    String? search,
    String? review,
    int offset = 0,
    int limit = pageSize,
  }) async {
    final text = search?.trim() ?? '';
    final rows = await supabase.rpc('list_location_groups', params: {
      'p_search': text.isEmpty ? null : text,
      'p_review': review,
      'p_limit': limit,
      'p_offset': offset,
    }) as List;
    return rows
        .map((row) => LocationGroup.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  /// Submissions linked together by AI cross-reference links (same vehicle
  /// or suspect turning up in different reports). Groups with something
  /// pending come first.
  Future<List<LinkedGroup>> listLinkedGroups({
    int offset = 0,
    int limit = 20,
  }) async {
    final rows = await supabase.rpc('list_linked_groups',
        params: {'p_limit': limit, 'p_offset': offset}) as List;
    return rows
        .map((row) => LinkedGroup.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  // --- suggestions

  /// Pending submissions that probably belong in this case, best first.
  Future<List<IncidentSuggestion>> suggestIncidentsForCase(int caseId,
      {int limit = 5}) async {
    final rows = await supabase.rpc('suggest_incidents_for_case',
        params: {'p_caseid': caseId, 'p_limit': limit}) as List;
    return rows
        .map((row) => IncidentSuggestion.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  /// Pending submissions that very likely belong in an open case (score >=
  /// [minScore]), each with its best case, strongest first. Feeds the
  /// "Suggested matches" list.
  Future<List<SuggestedMatch>> listSuggestedMatches(
      {int minScore = 60, int limit = 50}) async {
    final rows = await supabase.rpc('list_suggested_matches',
        params: {'p_minscore': minScore, 'p_limit': limit}) as List;
    return rows
        .map((row) => SuggestedMatch.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  /// Accept the ticked matches in one transaction. Anything someone else
  /// reviewed in the meantime gets skipped. Returns how many were added.
  Future<int> acceptSuggestedMatches(List<SuggestedMatch> matches) async {
    final added = await supabase.rpc('accept_suggested_matches', params: {
      'p_incidentids': [for (final m in matches) m.incidentId],
      'p_caseids': [for (final m in matches) m.caseId],
    });
    return (added as num).toInt();
  }

  /// Open cases this submission probably belongs to, best first.
  Future<List<CaseSuggestion>> suggestCasesForIncident(int incidentId,
      {int limit = 3}) async {
    final rows = await supabase.rpc('suggest_cases_for_incident',
        params: {'p_incidentid': incidentId, 'p_limit': limit}) as List;
    return rows
        .map((row) => CaseSuggestion.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  /// For a page of case cards, each case's best suggested pending submission
  /// and its most relevant plate. Closed cases and cases with no suggestion
  /// are left out. Max 50 cases per call.
  Future<List<CaseCardSuggestion>> getCaseCardSuggestions(
      List<int> caseIds) async {
    if (caseIds.isEmpty) return const [];
    final rows = await supabase.rpc('case_card_suggestions',
        params: {'p_caseids': caseIds.take(50).toList()}) as List;
    return rows
        .map((row) => CaseCardSuggestion.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  // --- review (admins only)
  // Each one is a single database function that checks you're an admin and
  // does everything in one go. They throw on failure, and the
  // PostgrestException message says why (e.g. "Case 5 is closed ...").

  /// Reject a submission. It stays on record but isn't used.
  Future<void> rejectSubmission(int incidentId, {String? note}) async {
    await supabase.rpc('reject_submission',
        params: {'p_incidentid': incidentId, 'p_note': note});
  }

  /// Mark [incidentId] as a duplicate of [originalId]. It joins the
  /// original's case if there is one.
  Future<void> markDuplicate(int incidentId, int originalId) async {
    await supabase.rpc('mark_duplicate',
        params: {'p_incidentid': incidentId, 'p_originalid': originalId});
  }

  /// Undo a review, putting it back to pending and out of its case. "Remove
  /// from case" uses this too.
  Future<void> reopenSubmission(int incidentId) async {
    await supabase.rpc('reopen_submission', params: {'p_incidentid': incidentId});
  }

  // --- cases (admins)

  /// Create a case, optionally with some incidents in it already (they get
  /// accepted). Returns the new case id.
  Future<int> createCase({
    required String title,
    String? description,
    List<int> incidentIds = const [],
  }) async {
    final id = await supabase.rpc('create_case', params: {
      'p_title': title,
      'p_description': description,
      'p_incidentids': incidentIds,
    });
    return (id as num).toInt();
  }

  /// Add (or move) incidents into an existing case that isn't closed.
  Future<void> addIncidentsToCase(int caseId, List<int> incidentIds) async {
    await supabase.rpc('add_incidents_to_case',
        params: {'p_caseid': caseId, 'p_incidentids': incidentIds});
  }

  /// Cases, most recently active first. [status] is null for all, 'active'
  /// (open + under review), 'open', 'under_review' or 'closed'. [query]
  /// matches a case number ("3", "CASE-0003") or title text.
  Future<List<CaseSummary>> listCases({
    String? query,
    String? status,
    int limit = 20,
  }) =>
      listCasesPage(query: query, status: status, limit: limit);

  /// One page of cases for scroll-to-load lists. Pass the last case you have
  /// as [after], or null for the first page.
  Future<List<CaseSummary>> listCasesPage({
    String? query,
    String? status,
    CaseSummary? after,
    int limit = 20,
  }) async {
    final text = query?.trim() ?? '';
    final rows = await supabase.rpc('list_cases', params: {
      'p_search': text.isEmpty ? null : text,
      'p_status': status,
      'p_limit': limit,
      'p_after_time': after == null
          ? null
          : (after.lastActivity ?? after.dateCreated).toUtc().toIso8601String(),
      'p_after_id': after?.caseId,
    });
    return (rows as List)
        .map((row) => CaseSummary.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  /// One case, or null if it doesn't exist or you can't see it.
  Future<CaseSummary?> getCase(int caseId) async {
    final rows = await supabase.rpc('list_cases', params: {'p_caseid': caseId})
        as List;
    return rows.isEmpty
        ? null
        : CaseSummary.fromMap(rows.first as Map<String, dynamic>);
  }

  /// Change a case's title, description and/or status. Only what you pass
  /// gets changed, and closing fills in the closed date automatically.
  ///
  /// Status goes through set_case_status: admins can set anything, assigned
  /// investigators can only switch between open and under review.
  Future<void> updateCase(
    int caseId, {
    String? title,
    String? description,
    String? status,
  }) async {
    final changes = <String, dynamic>{
      if (title != null) 'title': title.trim(),
      if (description != null)
        'description': description.trim().isEmpty ? null : description.trim(),
    };
    if (changes.isNotEmpty) {
      await supabase.from('cases').update(changes).eq('caseid', caseId);
    }
    if (status != null) {
      await supabase.rpc('set_case_status',
          params: {'p_caseid': caseId, 'p_status': status});
    }
  }

  /// A case's history, newest first, 30 at a time. Pass the last event you
  /// have as [before] for the next page.
  Future<List<CaseEvent>> getCaseEvents(int caseId,
      {CaseEvent? before, int limit = 30}) async {
    final rows = await supabase.rpc('list_case_events', params: {
      'p_caseid': caseId,
      'p_limit': limit,
      'p_before': before?.eventId,
    }) as List;
    return rows
        .map((row) => CaseEvent.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  /// Investigators on a case, active ones first and then past assignments.
  Future<List<CaseAssignmentInfo>> getCaseAssignments(int caseId) async {
    final rows = await supabase
        .rpc('list_case_assignments', params: {'p_caseid': caseId}) as List;
    return rows
        .map((row) => CaseAssignmentInfo.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  /// Assign an investigator to a case. No-op if they're already on it. The
  /// first one on a case becomes lead. Returns the assignment id.
  Future<int> assignInvestigator(int caseId, int userId) async {
    final id = await supabase.rpc('assign_investigator',
        params: {'p_caseid': caseId, 'p_userid': userId});
    return (id as num).toInt();
  }

  /// Make an active assignment the lead. The old lead stays on the case.
  Future<void> setCaseLead(int assignmentId) async {
    await supabase.rpc('set_case_lead', params: {'p_assignmentid': assignmentId});
  }

  /// End an assignment. The row stays as history.
  Future<void> unassignInvestigator(int assignmentId) async {
    await supabase.rpc('unassign_investigator',
        params: {'p_assignmentid': assignmentId});
  }

  // --- citizen submissions
  // How a citizen's report gets to the AI worker, all done as the signed-in
  // citizen (RLS only lets them touch their own incident):
  //   createIncident      the crimescene row
  //   uploadIncidentFile  the file to submissions/<id>/media/ plus a media
  //                       row, once per file
  //   submitForAnalysis   queues the 'analyse' job

  /// Bucket for footage and AI results.
  static const submissionsBucket = 'submissions';

  /// Per-file upload limit, has to match config.toml [storage].
  static const maxFileBytes = 50 * 1024 * 1024;

  /// Create the citizen's incident and return its id. [latitude]/[longitude]
  /// is the phone's GPS, null if they didn't share it.
  Future<int> createIncident({
    required int reporterId,
    required String location,
    required String description,
    required DateTime when,
    double? latitude,
    double? longitude,
  }) async {
    final hasGps = latitude != null && longitude != null;
    final row = await supabase
        .from('crimescene')
        .insert({
          'location': location,
          'description': description,
          'datetime': when.toUtc().toIso8601String(),
          'reportedby': reporterId,
          'latitude': hasGps ? double.parse(latitude.toStringAsFixed(6)) : null,
          'longitude': hasGps ? double.parse(longitude.toStringAsFixed(6)) : null,
          'gpssource': hasGps ? 'phone' : 'typed',
        })
        .select('incidentid')
        .single();
    return (row['incidentid'] as num).toInt();
  }

  /// Upload one file for an incident and record it. Returns its bucket path.
  /// [mediaType] is 'image' or 'video'.
  Future<String> uploadIncidentFile({
    required int incidentId,
    required int uploaderId,
    required String fileName,
    required Uint8List bytes,
    required String contentType,
    required String mediaType,
  }) async {
    final dot = fileName.lastIndexOf('.');
    final ext = dot < 0 ? '' : fileName.substring(dot).toLowerCase();
    // random name, since the citizen's own file names could be anything
    final random = Random.secure();
    final name = List.generate(16, (_) => random.nextInt(16).toRadixString(16)).join();
    final path = '$incidentId/media/$name$ext';

    await supabase.storage.from(submissionsBucket).uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: contentType, upsert: false),
        );
    await supabase.from('media').insert({
      'incidentid': incidentId,
      'uploadedby': uploaderId,
      'mediatype': mediaType,
      'storagepath': path,
      'filesize': bytes.length,
    });
    return path;
  }

  /// The citizen's own reports, newest first.
  Future<List<MySubmission>> getMySubmissions(int reporterId, {int limit = 50}) async {
    final rows = await supabase
        .from('crimescene')
        .select('incidentid, location, datetime, datereported, description, '
            'reviewstatus, aisummarystatus')
        .eq('reportedby', reporterId)
        .order('datereported', ascending: false)
        .limit(limit) as List;
    if (rows.isEmpty) return const [];
    final ids = [for (final r in rows) (r['incidentid'] as num).toInt()];
    final media = await supabase
        .from('media')
        .select('incidentid')
        .inFilter('incidentid', ids) as List;
    final counts = <int, int>{};
    for (final m in media) {
      final id = (m['incidentid'] as num).toInt();
      counts[id] = (counts[id] ?? 0) + 1;
    }
    return [
      for (final r in rows)
        MySubmission.fromMap(r as Map<String, dynamic>,
            fileCount: counts[(r['incidentid'] as num).toInt()] ?? 0),
    ];
  }

  // --- case chat
  // A group chat per case for its assigned investigators (Chat tab on the
  // investigator's case page). The database decides who can read and post,
  // see 20261015100000_case_chat.sql.

  /// The case chat, oldest first (newest 200). With [afterId], only messages
  /// after that one, for live updates.
  Future<List<CaseMessage>> getCaseMessages(int caseId,
      {int? afterId, int limit = 200}) async {
    final rows = await supabase.rpc('list_case_messages', params: {
      'p_caseid': caseId,
      'p_after_id': afterId,
      'p_limit': limit,
    }) as List;
    return rows
        .map((row) => CaseMessage.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  /// Post [body] to the case chat and get the new message back.
  Future<CaseMessage> sendCaseMessage(int caseId, String body) async {
    final rows = await supabase.rpc('send_case_message',
        params: {'p_caseid': caseId, 'p_body': body}) as List;
    return CaseMessage.fromMap(rows.single as Map<String, dynamic>);
  }

  /// Calls [onNewMessage] whenever someone posts (via Realtime). Returns a
  /// function that stops listening.
  void Function() watchCaseMessages(int caseId, void Function() onNewMessage) {
    final channel = supabase
        .channel('case-chat-')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'casemessage',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'caseid',
            value: caseId,
          ),
          callback: (_) => onNewMessage(),
        )
        .subscribe();
    return () => supabase.removeChannel(channel);
  }
}
