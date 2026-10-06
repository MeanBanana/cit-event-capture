import 'package:supabase_flutter/supabase_flutter.dart';
import 'models/investigator_summary.dart';
import 'models/system_stats.dart';
import 'models/crime_scene_summary.dart';
import 'models/activity_item.dart';
import 'models/case_summary.dart';
import 'models/case_assignment_info.dart';
import 'models/submission_groups.dart';
import 'models/citizen_profile.dart';

/// Sort order for submission lists (by date reported).
enum SubmissionOrder { newest, oldest }

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
  /// {userid, username, firstname, surname, email, phonenumber, role} where
  /// role is 'citizen', 'investigator' or 'admin'.
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
          .select('userid, username, firstname, surname, email, phonenumber, role')
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

  // ------------------------------------------------------- CITIZEN PROFILE
  // Database rules (RLS) let a citizen read and update only their own
  // "User" and citizen rows, and a trigger stops them changing their own
  // role or email there. So:
  //   * phone number  -> "User".phonenumber   (plain update)
  //   * residence     -> citizen.residence    (plain update)
  //   * email         -> Supabase Auth, which emails a confirmation link.
  //     Once confirmed, the on_auth_user_email_changed trigger copies the
  //     new address into "User".email.
  //   * first name / surname are not changed here at all.

  /// The logged-in citizen's profile. Throws if nobody is logged in or the
  /// rows can't be read, so the screen can show an error with a Retry button.
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

    // maybeSingle: an older account might not have a citizen row yet.
    final citizen = await supabase
        .from('citizen')
        .select('residence')
        .eq('userid', user['userid'])
        .maybeSingle();

    return CitizenProfile.fromMaps(user, citizen);
  }

  /// Saves the citizen's changes. Pass only what changed; null = unchanged.
  ///
  /// [phone] is the 9 digits after +27 (like the register form).
  ///
  /// Returns {success, message, emailPending, emailChangedNow}.
  /// emailPending is true when a confirmation email was sent - the new
  /// address only applies after the citizen clicks the link in it.
  /// emailChangedNow is true when the project doesn't ask for confirmation.
  Future<Map<String, dynamic>> updateMyCitizenProfile({
    required int userId,
    String? email,
    String? phone,
    String? residence,
  }) async {
    // Lets the error message say which parts were already saved.
    final saved = <String>[];
    try {
      if (phone != null) {
        // .select() returns the updated rows. If RLS blocked the update,
        // Postgres doesn't raise an error - it just updates 0 rows - so we
        // check for that instead of assuming it worked.
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
        // With "Secure email change" on (the default), Supabase holds the
        // new address in newEmail until the link is clicked. With it off,
        // the email changes straight away.
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
      final reason = (e.code == 'email_exists' || e.code == 'user_already_exists')
          ? "That email address is already used by another account."
          : e.code == 'over_email_send_rate_limit'
              ? "Too many emails sent. Please wait a few minutes and try again."
              : "Your email could not be changed: ${e.message}";
      return {"success": false, "message": _partly(saved, reason)};
    } on PostgrestException catch (e) {
      return {"success": false, "message": _partly(saved, e.message)};
    } catch (e) {
      return {"success": false, "message": _partly(saved, e.toString())};
    }
  }

  /// "Your phone number was saved, but <reason>" when something already
  /// went through before the failure.
  String _partly(List<String> saved, String reason) => saved.isEmpty
      ? reason
      : "Your ${saved.join(' and ')} ${saved.length == 1 ? 'was' : 'were'} saved, but: $reason";

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
  // All of these call the list_submissions database function: incidents
  // (crimescene) with reporter name, media count, review details, the AI
  // summary and what the AI saw. Database rules decide what comes back
  // (admins see every submission).
  //
  // [review] filters on the admin's decision: null = all, or 'pending',
  // 'accepted', 'rejected', 'duplicate'.

  /// How many rows one page of a list loads.
  static const int pageSize = 30;

  /// One page of submissions, for lists that load more as you scroll.
  ///
  /// Pass the last submission you already have as [after] to get the next
  /// page (null = first page). A page shorter than [limit] is the last one.
  /// The database pages with this cursor instead of skipping rows, so page
  /// 100 is as fast as page 1.
  ///
  /// Filters (all optional): [search] (incident number like "42" /
  /// "INC-0042", or text in the location), [review], [caseId], [locationKey]
  /// (a group from listLocationGroups) and [ids] (only these incidents).
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

  /// One submission, or null if it doesn't exist (or may not be seen).
  Future<CrimeSceneSummary?> getSubmission(int incidentId) async {
    final rows = await listSubmissionsPage(ids: [incidentId], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// The [limit] most recently reported incidents, newest first (used by
  /// the Overview).
  Future<List<CrimeSceneSummary>> getRecentSubmissions({
    int limit = 20,
    String? review,
  }) =>
      listSubmissionsPage(limit: limit, review: review);

  /// Incidents matching [query]: an incident number ("42", "INC-0042",
  /// "inc 42") or text in the location (any case). An empty [query] returns
  /// the most recent submissions. Used by the pickers.
  Future<List<CrimeSceneSummary>> searchSubmissions(
    String query, {
    int limit = 20,
    String? review,
  }) =>
      listSubmissionsPage(search: query, limit: limit, review: review);

  /// The first 100 incidents in a case (accepted ones and their duplicates).
  Future<List<CrimeSceneSummary>> getCaseIncidents(int caseId) =>
      listSubmissionsPage(caseId: caseId, limit: 100);

  /// The clips / photos of a submission with what the AI saw in each.
  Future<List<MediaItem>> getIncidentMedia(int incidentId) async {
    final rows = await supabase
        .rpc('list_incident_media', params: {'p_incidentid': incidentId}) as List;
    return rows
        .map((row) => MediaItem.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  // --------------------------------------------------------------- GROUPING

  /// Submissions grouped by location, most recently reported first.
  /// [search] filters on the location text; [offset] = groups already
  /// loaded (groups are few, so plain offset paging is fine here).
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

  /// Groups of submissions joined by AI cross-reference links (the same
  /// vehicle or suspect in different reports). Groups with something still
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

  // ------------------------------------------------------------ SUGGESTIONS

  /// Pending submissions that probably belong in the case, best first.
  Future<List<IncidentSuggestion>> suggestIncidentsForCase(int caseId,
      {int limit = 5}) async {
    final rows = await supabase.rpc('suggest_incidents_for_case',
        params: {'p_caseid': caseId, 'p_limit': limit}) as List;
    return rows
        .map((row) => IncidentSuggestion.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  /// Pending submissions that most likely belong in an existing open case
  /// (score >= [minScore]), each with its best case, strongest first. For
  /// the "Suggested matches" review list.
  Future<List<SuggestedMatch>> listSuggestedMatches(
      {int minScore = 60, int limit = 50}) async {
    final rows = await supabase.rpc('list_suggested_matches',
        params: {'p_minscore': minScore, 'p_limit': limit}) as List;
    return rows
        .map((row) => SuggestedMatch.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  /// Accepts the matches the admin ticked, in one transaction. Ones that
  /// were reviewed by someone else meanwhile are skipped. Returns how many
  /// submissions were added to cases.
  Future<int> acceptSuggestedMatches(List<SuggestedMatch> matches) async {
    final added = await supabase.rpc('accept_suggested_matches', params: {
      'p_incidentids': [for (final m in matches) m.incidentId],
      'p_caseids': [for (final m in matches) m.caseId],
    });
    return (added as num).toInt();
  }

  /// Open cases the submission probably belongs to, best first.
  Future<List<CaseSuggestion>> suggestCasesForIncident(int incidentId,
      {int limit = 3}) async {
    final rows = await supabase.rpc('suggest_cases_for_incident',
        params: {'p_incidentid': incidentId, 'p_limit': limit}) as List;
    return rows
        .map((row) => CaseSuggestion.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  /// For a page of case cards: each case's best suggested pending
  /// submission with its most relevant number plate (closed cases and
  /// cases with no suggestion are left out). At most 50 cases per call.
  Future<List<CaseCardSuggestion>> getCaseCardSuggestions(
      List<int> caseIds) async {
    if (caseIds.isEmpty) return const [];
    final rows = await supabase.rpc('case_card_suggestions',
        params: {'p_caseids': caseIds.take(50).toList()}) as List;
    return rows
        .map((row) => CaseCardSuggestion.fromMap(row as Map<String, dynamic>))
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
  }) =>
      listCasesPage(query: query, status: status, limit: limit);

  /// One page of cases for lists that load more as you scroll: pass the
  /// last case you already have as [after] (null = first page).
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
  ///
  /// The status goes through the set_case_status database function: admins
  /// may set any status, assigned investigators only open <-> under review.
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

  /// A case's history, newest first, 30 at a time: pass the last event you
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

  /// Investigators on a case: active first, then past assignments.
  Future<List<CaseAssignmentInfo>> getCaseAssignments(int caseId) async {
    final rows = await supabase
        .rpc('list_case_assignments', params: {'p_caseid': caseId}) as List;
    return rows
        .map((row) => CaseAssignmentInfo.fromMap(row as Map<String, dynamic>))
        .toList();
  }

  /// Assigns an investigator ([userId]) to a case. Does nothing if they are
  /// already assigned. The first investigator on a case becomes its lead.
  /// Returns the assignment id.
  Future<int> assignInvestigator(int caseId, int userId) async {
    final id = await supabase.rpc('assign_investigator',
        params: {'p_caseid': caseId, 'p_userid': userId});
    return (id as num).toInt();
  }

  /// Makes an active assignment the case's lead investigator (the old lead
  /// stays on the case).
  Future<void> setCaseLead(int assignmentId) async {
    await supabase.rpc('set_case_lead', params: {'p_assignmentid': assignmentId});
  }

  /// Ends an assignment (kept as history).
  Future<void> unassignInvestigator(int assignmentId) async {
    await supabase.rpc('unassign_investigator',
        params: {'p_assignmentid': assignmentId});
  }
}
