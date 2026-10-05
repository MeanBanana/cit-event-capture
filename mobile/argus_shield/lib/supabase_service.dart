import 'package:supabase_flutter/supabase_flutter.dart';
import 'models/investigator_summary.dart';
import 'models/system_stats.dart';
import 'models/crime_scene_summary.dart';
import 'models/activity_item.dart';
import 'models/case_summary.dart';
import 'models/case_assignment_info.dart';

/// All Supabase calls for accounts (register, login, logout).
///
/// How accounts work (see database/README.md):
///  * Registering calls supabase.auth.signUp with the form fields in `data`.
///    A database trigger then creates the "User" row and the "citizen" row.
///    The app must NEVER insert into "User" or "citizen" itself - the database
///    blocks it, so nobody can give themselves a role such as admin.
///  * Logging in: the user types a username, we look up their email with
///    email_for_username, then sign in with email + password.
class SupabaseService {
  // A getter (not a field) so this class can be created before Supabase is
  // initialised, e.g. in widget tests.
  SupabaseClient get supabase => Supabase.instance.client;

  // ---------------------------------------------------------------- REGISTER
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
      // 1. Check the username first so the user gets a clear message
      final available = await supabase.rpc(
        'username_available',
        params: {'p_username': username.trim()},
      );
      if (available != true) {
        return {"success": false, "message": "That username is already taken."};
      }

      // 2. Create the account. The keys in `data` must be spelled exactly like
      //    this - the database trigger reads them to fill "User" and "citizen".
      final authResponse = await supabase.auth.signUp(
        email: email.trim(),
        password: password,
        data: {
          'username': username.trim(),
          'firstname': firstname.trim(),
          'surname': surname.trim(),
          'phonenumber': '+27${phone.trim()}', // form collects the 9 digits after +27
          'residence': residence.trim(),
        },
      );

      final user = authResponse.user;
      if (user == null) {
        return {"success": false, "message": "Sign up failed."};
      }
      // With "Confirm email" turned on, Supabase does not return an error for an
      // email that is already registered - it returns a user with no identities.
      if (user.identities != null && user.identities!.isEmpty) {
        return {"success": false, "message": "An account with this email already exists."};
      }

      // signUp logs the new user in straight away (when "Confirm email" is off).
      // Sign out so they log in themselves on the login page.
      if (authResponse.session != null) {
        await supabase.auth.signOut();
      }

      return {"success": true, "message": "User successfully registered"};
    } on AuthWeakPasswordException {
      return {"success": false, "message": "Password is too weak."};
    } on AuthException catch (e) {
      if (e.code == 'user_already_exists' || e.code == 'email_exists') {
        return {"success": false, "message": "An account with this email already exists."};
      }
      if (e.message.contains('Database error saving new user')) {
        // The sign-up trigger rejected the data (username taken or invalid)
        return {
          "success": false,
          "message": "Username is invalid or already taken. Use 3-30 letters, numbers, _ or .",
        };
      }
      return {"success": false, "message": e.message};
    } on PostgrestException catch (e) {
      return {"success": false, "message": e.message};
    } catch (e) {
      return {"success": false, "message": e.toString()};
    }
  }

  // ------------------------------------------------------------------- LOGIN
  /// On success the result also contains "profile":
  /// {userid, username, firstname, surname, role} where role is
  /// 'citizen', 'investigator' or 'admin'.
  Future<Map<String, dynamic>> loginUser({
    required String username,
    required String password,
  }) async {
    // Same message for a wrong username or a wrong password, so the login
    // screen does not reveal which usernames exist.
    const badLogin = "Invalid username or password.";
    try {
      final email = await supabase.rpc(
        'email_for_username',
        params: {'p_username': username.trim()},
      );
      if (email is! String) {
        return {"success": false, "message": badLogin};
      }

      final authResponse = await supabase.auth.signInWithPassword(
        email: email,
        password: password,
      );

      final profile = await supabase
          .from('User')
          .select('userid, username, firstname, surname, role')
          .eq('authid', authResponse.user!.id)
          .single();

      return {
        "success": true,
        "message": "Welcome ${profile['firstname']}",
        "profile": profile,
      };
    } on AuthException catch (e) {
      if (e.code == 'email_not_confirmed') {
        return {"success": false, "message": "Please confirm your email address first."};
      }
      return {"success": false, "message": badLogin};
    } on PostgrestException catch (e) {
      return {"success": false, "message": e.message};
    } catch (e) {
      return {"success": false, "message": e.toString()};
    }
  }

  // ------------------------------------------------------------------ LOGOUT
  Future<void> logout() => supabase.auth.signOut();

  // ----------------------------------------------------------- INVESTIGATORS
  // Both methods call the list_investigators database function, which joins
  // "User" + investigator, counts active case assignments and sorts newest
  // account first. Database rules decide who gets rows back (admins see all
  // investigators). Errors are thrown, so the screen can show a message.

  /// The [limit] most recently created investigators, newest first.
  Future<List<InvestigatorSummary>> getRecentInvestigators({int limit = 20}) =>
      _listInvestigators(limit: limit);

  /// Investigators whose badge number or name contains [query], ignoring
  /// case (e.g. "jhb" finds "JHB-4471", "thabo m" finds "Thabo Mokoena").
  /// An empty [query] returns the most recent investigators.
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

  // ------------------------------------------------------------ ADMIN STATS
  /// The four SYSTEM STATUS numbers for the admin Overview tab, counted by
  /// the admin_overview_stats database function.
  Future<SystemStats> getAdminStats() async {
    final rows = await supabase.rpc('admin_overview_stats') as List;
    return SystemStats.fromMap(rows.first as Map<String, dynamic>);
  }

  /// The [limit] newest events for RECENT ACTIVITY on the admin Overview
  /// (new submissions, cases created/closed, assignments, new investigators,
  /// confirmed suspects, corrections), from the recent_activity function.
  Future<List<ActivityItem>> getRecentActivity({int limit = 5}) async {
    final rows = await supabase.rpc(
      'recent_activity',
      params: {'p_limit': limit},
    );
    return (rows as List)
        .map((row) => ActivityItem.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  // ------------------------------------------------------------- SUBMISSIONS
  // All three call the list_submissions database function: incidents
  // (crimescene) newest REPORTED first, with reporter name, media count and
  // review details. Database rules decide what comes back (admins see every
  // submission).
  //
  // [review] filters on the admin's decision: null = all, or 'pending',
  // 'accepted', 'rejected', 'duplicate'.

  /// The [limit] most recently reported incidents, newest first.
  Future<List<CrimeSceneSummary>> getRecentSubmissions({
    int limit = 20,
    String? review,
  }) =>
      _listSubmissions(limit: limit, review: review);

  /// Incidents matching [query]: an incident number ("42", "INC-0042",
  /// "inc 42") or text in the location (any case). An empty [query] returns
  /// the most recent submissions.
  Future<List<CrimeSceneSummary>> searchSubmissions(
    String query, {
    int limit = 20,
    String? review,
  }) =>
      _listSubmissions(search: query, limit: limit, review: review);

  /// Every incident in a case (accepted ones and their duplicates).
  Future<List<CrimeSceneSummary>> getCaseIncidents(int caseId) =>
      _listSubmissions(limit: 100, caseId: caseId);

  Future<List<CrimeSceneSummary>> _listSubmissions({
    String? search,
    required int limit,
    String? review,
    int? caseId,
  }) async {
    final text = search?.trim() ?? '';
    final rows = await supabase.rpc(
      'list_submissions',
      params: {
        'p_search': text.isEmpty ? null : text,
        'p_limit': limit,
        'p_review': review,
        'p_caseid': caseId,
      },
    );
    return (rows as List)
        .map((row) => CrimeSceneSummary.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  // ------------------------------------------------------- REVIEW (admin only)
  // Each calls one database function that checks the caller is an admin and
  // makes all of its changes at once. On failure they throw; the message of
  // a PostgrestException explains why (e.g. "Case 5 is closed ...").

  /// Rejects a submission. It stays on record but is not used.
  Future<void> rejectSubmission(int incidentId, {String? note}) async {
    await supabase.rpc('reject_submission',
        params: {'p_incidentid': incidentId, 'p_note': note});
  }

  /// Marks [incidentId] as a duplicate of [originalId]; it joins the
  /// original's case, if it has one.
  Future<void> markDuplicate(int incidentId, int originalId) async {
    await supabase.rpc('mark_duplicate',
        params: {'p_incidentid': incidentId, 'p_originalid': originalId});
  }

  /// Undoes a review: back to 'pending' and out of its case. Also used for
  /// "Remove from case".
  Future<void> reopenSubmission(int incidentId) async {
    await supabase.rpc('reopen_submission', params: {'p_incidentid': incidentId});
  }

  // ------------------------------------------------------------ CASES (admin)

  /// Creates a case, optionally with incidents in it (they are accepted).
  /// Returns the new case id.
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

  /// Adds (or moves) incidents into an existing case that is not closed.
  Future<void> addIncidentsToCase(int caseId, List<int> incidentIds) async {
    await supabase.rpc('add_incidents_to_case',
        params: {'p_caseid': caseId, 'p_incidentids': incidentIds});
  }

  /// Cases, most recently active first. [status]: null = all, 'active'
  /// (open + under review), 'open', 'under_review' or 'closed'. [query]
  /// matches a case number ("3", "CASE-0003") or text in the title.
  Future<List<CaseSummary>> listCases({
    String? query,
    String? status,
    int limit = 20,
  }) async {
    final text = query?.trim() ?? '';
    final rows = await supabase.rpc('list_cases', params: {
      'p_search': text.isEmpty ? null : text,
      'p_status': status,
      'p_limit': limit,
    });
    return (rows as List)
        .map((row) => CaseSummary.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  /// One case, or null if it doesn't exist (or may not be seen).
  Future<CaseSummary?> getCase(int caseId) async {
    final rows = await supabase.rpc('list_cases', params: {'p_caseid': caseId})
        as List;
    return rows.isEmpty
        ? null
        : CaseSummary.fromMap(rows.first as Map<String, dynamic>);
  }

  /// Changes a case's title, description and/or status. Only the values
  /// passed are changed. Closing sets the closed date automatically.
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
      'status': ?status, // only added when not null
    };
    if (changes.isEmpty) return;
    await supabase.from('cases').update(changes).eq('caseid', caseId);
  }

  /// Investigators on a case: active first, then past assignments.
  Future<List<CaseAssignmentInfo>> getCaseAssignments(int caseId) async {
    final rows = await supabase
        .rpc('list_case_assignments', params: {'p_caseid': caseId}) as List;
    return rows
        .map((row) => CaseAssignmentInfo.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  /// Assigns an investigator ([userId]) to a case. Does nothing if they are
  /// already assigned. Returns the assignment id.
  Future<int> assignInvestigator(int caseId, int userId) async {
    final id = await supabase.rpc('assign_investigator',
        params: {'p_caseid': caseId, 'p_userid': userId});
    return (id as num).toInt();
  }

  /// Ends an assignment (kept as history).
  Future<void> unassignInvestigator(int assignmentId) async {
    await supabase.rpc('unassign_investigator',
        params: {'p_assignmentid': assignmentId});
  }
}
