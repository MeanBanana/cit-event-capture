// admin_fake_service.dart — an in-memory stand-in for SupabaseService used
// by the case / review tests. It keeps submissions, cases and assignments
// in lists and changes them like the database functions do, so a test can
// tap through a whole flow (accept -> case -> assign ...) without Supabase.
//
// Every call is recorded in [calls], e.g. 'reject:42:Not CIT'.
// (No "_test" in the file name, so `flutter test` doesn't run it on its own.)

import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/models/crime_scene_summary.dart';
import 'package:argus_shield/models/case_summary.dart';
import 'package:argus_shield/models/case_assignment_info.dart';
import 'package:argus_shield/models/investigator_summary.dart';
import 'package:argus_shield/models/submission_groups.dart';

CrimeSceneSummary fakeIncident(
  int id,
  String location, {
  String reviewStatus = 'pending',
  int? caseId,
  String? caseTitle,
  int? duplicateOf,
  String? note,
  String? aiSummary,
  List<String> plates = const [],
  DateTime? reported,
}) =>
    CrimeSceneSummary(
      incidentId: id,
      location: location,
      dateTime: DateTime(2026, 10, 5, 9, 15),
      dateReported: reported ?? DateTime(2026, 10, 5, 9, 30),
      status: 'open',
      description: 'Report $id',
      reportedBy: 4,
      reporterName: 'Sam Citizen',
      reviewStatus: reviewStatus,
      caseId: caseId,
      caseTitle: caseTitle,
      duplicateOf: duplicateOf,
      reviewNote: note,
      locationKey: location.toLowerCase(),
      aiSummary: aiSummary,
      aiSummaryStatus: aiSummary == null ? 'none' : 'ready',
      plates: plates,
    );

const fakeInvestigator = InvestigatorSummary(
  userId: 2,
  firstName: 'Thabo',
  surname: 'Mokoena',
  rank: 'Sgt.',
  badgeNumber: 'JHB-4471',
  station: 'Kempton Park SAPS',
  dutyStatus: 'on_duty',
  email: 'tmokoena@argus.test',
);

class AdminFakeService extends SupabaseService {
  AdminFakeService({
    List<CrimeSceneSummary>? submissions,
    List<CaseSummary>? cases,
    List<InvestigatorSummary>? investigators,
  })  : submissions = submissions ?? [],
        cases = cases ?? [],
        investigators = investigators ?? [fakeInvestigator] {
    _recount();
  }

  final List<CrimeSceneSummary> submissions;
  final List<CaseSummary> cases;
  final List<InvestigatorSummary> investigators;
  final List<CaseAssignmentInfo> assignments = [];
  final List<String> calls = [];

  /// What the suggestion functions return (tests fill these in).
  List<IncidentSuggestion> incidentSuggestions = [];
  List<CaseSuggestion> caseSuggestions = [];
  List<LinkedGroup> linkedGroups = [];
  List<SuggestedMatch> suggestedMatches = [];
  List<CaseCardSuggestion> caseCardSuggestions = [];

  /// Makes getCaseCardSuggestions throw (the cards must still show).
  bool failCaseCardSuggestions = false;

  // ---- helpers ---------------------------------------------------------------

  void _setReview(int incidentId,
      {required String status, int? caseId, int? duplicateOf, String? note}) {
    final i = submissions.indexWhere((s) => s.incidentId == incidentId);
    if (i < 0) throw Exception('Incident $incidentId not found');
    final old = submissions[i];
    String? title;
    for (final c in cases) {
      if (c.caseId == caseId) title = c.title;
    }
    submissions[i] = fakeIncident(old.incidentId, old.location,
        reviewStatus: status,
        caseId: caseId,
        caseTitle: title,
        duplicateOf: duplicateOf,
        note: note,
        aiSummary: old.aiSummary,
        plates: old.plates,
        reported: old.dateReported);
    _recount();
  }

  /// Keeps each case's submission count, preview and investigators in step.
  void _recount() {
    for (var i = 0; i < cases.length; i++) {
      final c = cases[i];
      final inCase = submissions.where((s) => s.caseId == c.caseId).toList();
      cases[i] = CaseSummary(
        caseId: c.caseId,
        title: c.title,
        description: c.description,
        status: c.status,
        dateCreated: c.dateCreated,
        dateClosed: c.status == 'closed' ? DateTime(2026, 10, 6) : null,
        createdByName: c.createdByName,
        incidentCount: inCase.length,
        investigators: [
          for (final a in assignments)
            if (a.caseId == c.caseId && a.isActive)
              CaseInvestigator(
                  userId: a.userId,
                  name: a.name,
                  badgeNumber: a.badgeNumber,
                  assignmentId: a.assignmentId,
                  isLead: a.isLead),
        ],
        preview: [
          for (final s in inCase.take(3))
            CasePreviewItem(
              incidentId: s.incidentId,
              location: s.location,
              dateReported: s.dateReported,
              reviewStatus: s.reviewStatus,
              description: s.description,
              aiSummary: s.aiSummary,
            ),
        ],
        possibleSuspects: c.possibleSuspects,
        confirmedSuspects: c.confirmedSuspects,
      );
    }
  }

  CaseAssignmentInfo _copyAssignment(CaseAssignmentInfo a,
          {String? status, DateTime? unassigned, bool? isLead}) =>
      CaseAssignmentInfo(
        assignmentId: a.assignmentId,
        userId: a.userId,
        name: a.name,
        badgeNumber: a.badgeNumber,
        station: a.station,
        dutyStatus: a.dutyStatus,
        status: status ?? a.status,
        dateAssigned: a.dateAssigned,
        dateUnassigned: unassigned ?? a.dateUnassigned,
        caseId: a.caseId,
        isLead: isLead ?? a.isLead,
      );

  // ---- submissions -------------------------------------------------------------

  List<CrimeSceneSummary> _subs(String? review, [String query = '']) {
    final q = query.trim().toLowerCase();
    return submissions
        .where((s) => review == null || s.reviewStatus == review)
        .where((s) =>
            q.isEmpty ||
            s.location.toLowerCase().contains(q) ||
            s.incidentId.toString() == q)
        .toList();
  }

  @override
  Future<List<CrimeSceneSummary>> listSubmissionsPage({
    String? search,
    String? review,
    int? caseId,
    String? locationKey,
    List<int>? ids,
    SubmissionOrder order = SubmissionOrder.newest,
    CrimeSceneSummary? after,
    int limit = SupabaseService.pageSize,
  }) async {
    calls.add('listSubmissions:$review:${search ?? ''}:${order.name}');
    var rows = _subs(review, search ?? '')
        .where((s) => caseId == null || s.caseId == caseId)
        .where((s) => locationKey == null || s.locationKey == locationKey)
        .where((s) => ids == null || ids.contains(s.incidentId))
        .toList();
    if (order == SubmissionOrder.oldest) rows = rows.reversed.toList();
    if (after != null) {
      final i = rows.indexWhere((s) => s.incidentId == after.incidentId);
      rows = i < 0 ? [] : rows.sublist(i + 1);
    }
    return rows.take(limit).toList();
  }

  @override
  Future<CrimeSceneSummary?> getSubmission(int incidentId) async {
    for (final s in submissions) {
      if (s.incidentId == incidentId) return s;
    }
    return null;
  }

  @override
  Future<List<CrimeSceneSummary>> getRecentSubmissions(
      {int limit = 20, String? review}) async {
    calls.add('recentSubmissions:$review');
    return _subs(review);
  }

  @override
  Future<List<CrimeSceneSummary>> searchSubmissions(String query,
      {int limit = 20, String? review}) async {
    calls.add('searchSubmissions:$query:$review');
    return _subs(review, query);
  }

  @override
  Future<List<CrimeSceneSummary>> getCaseIncidents(int caseId) async =>
      submissions.where((s) => s.caseId == caseId).toList();

  @override
  Future<List<MediaItem>> getIncidentMedia(int incidentId) async => const [];

  @override
  Future<List<LocationGroup>> listLocationGroups({
    String? search,
    String? review,
    int offset = 0,
    int limit = SupabaseService.pageSize,
  }) async {
    calls.add('locationGroups:${search ?? ''}');
    final groups = <String, List<CrimeSceneSummary>>{};
    for (final s in _subs(review)) {
      if (search != null &&
          search.isNotEmpty &&
          !s.location.toLowerCase().contains(search.toLowerCase())) {
        continue;
      }
      groups.putIfAbsent(s.locationKey ?? s.location, () => []).add(s);
    }
    return [
      for (final e in groups.entries)
        LocationGroup(
          locationKey: e.key,
          label: e.value.first.location,
          submissionCount: e.value.length,
          pendingCount: e.value.where((s) => s.isPending).length,
          latestReported: e.value.first.dateReported,
        ),
    ].skip(offset).take(limit).toList();
  }

  @override
  Future<List<LinkedGroup>> listLinkedGroups(
      {int offset = 0, int limit = 20}) async {
    calls.add('linkedGroups');
    return linkedGroups.skip(offset).take(limit).toList();
  }

  @override
  Future<List<IncidentSuggestion>> suggestIncidentsForCase(int caseId,
          {int limit = 5}) async =>
      incidentSuggestions;

  @override
  Future<List<CaseSuggestion>> suggestCasesForIncident(int incidentId,
          {int limit = 3}) async =>
      caseSuggestions;

  @override
  Future<List<CaseCardSuggestion>> getCaseCardSuggestions(
      List<int> caseIds) async {
    calls.add('caseCardSuggestions:$caseIds');
    if (failCaseCardSuggestions) throw Exception('offline');
    return caseCardSuggestions.where((s) => caseIds.contains(s.caseId)).toList();
  }

  @override
  Future<List<SuggestedMatch>> listSuggestedMatches(
          {int minScore = 60, int limit = 50}) async =>
      suggestedMatches
          .where((m) => submissions
              .any((s) => s.incidentId == m.incidentId && s.isPending))
          .toList();

  @override
  Future<int> acceptSuggestedMatches(List<SuggestedMatch> matches) async {
    calls.add('acceptSuggested:'
        '${[for (final m in matches) '${m.incidentId}->${m.caseId}']}');
    var added = 0;
    for (final m in matches) {
      final pending =
          submissions.any((s) => s.incidentId == m.incidentId && s.isPending);
      if (pending) {
        _setReview(m.incidentId, status: 'accepted', caseId: m.caseId);
        added++;
      }
    }
    return added;
  }

  @override
  Future<void> rejectSubmission(int incidentId, {String? note}) async {
    calls.add('reject:$incidentId:$note');
    _setReview(incidentId, status: 'rejected', note: note);
  }

  @override
  Future<void> markDuplicate(int incidentId, int originalId) async {
    calls.add('duplicate:$incidentId:$originalId');
    final original = submissions.firstWhere((s) => s.incidentId == originalId);
    _setReview(incidentId,
        status: 'duplicate', duplicateOf: originalId, caseId: original.caseId);
  }

  @override
  Future<void> reopenSubmission(int incidentId) async {
    calls.add('reopen:$incidentId');
    _setReview(incidentId, status: 'pending');
  }

  // ---- cases -------------------------------------------------------------------

  @override
  Future<int> createCase({
    required String title,
    String? description,
    List<int> incidentIds = const [],
  }) async {
    calls.add('createCase:$title:$incidentIds');
    final id = cases.isEmpty
        ? 1
        : cases.map((c) => c.caseId).reduce((a, b) => a > b ? a : b) + 1;
    cases.add(CaseSummary(
      caseId: id,
      title: title,
      description: description,
      status: 'open',
      dateCreated: DateTime(2026, 10, 5, 10),
      createdByName: 'Ada Admin',
    ));
    for (final i in incidentIds) {
      _setReview(i, status: 'accepted', caseId: id);
    }
    _recount();
    return id;
  }

  @override
  Future<void> addIncidentsToCase(int caseId, List<int> incidentIds) async {
    calls.add('addIncidents:$caseId:$incidentIds');
    for (final i in incidentIds) {
      _setReview(i, status: 'accepted', caseId: caseId);
    }
  }

  @override
  Future<List<CaseSummary>> listCases(
      {String? query, String? status, int limit = 20}) async {
    calls.add('listCases:${query ?? ''}:$status');
    final q = (query ?? '').trim().toLowerCase();
    return cases
        .where((c) =>
            status == null ||
            (status == 'active' && c.status != 'closed') ||
            c.status == status)
        .where((c) => q.isEmpty || c.title.toLowerCase().contains(q))
        .toList();
  }

  @override
  Future<List<CaseSummary>> listCasesPage({
    String? query,
    String? status,
    CaseSummary? after,
    int limit = 20,
  }) async {
    final all = await listCases(query: query, status: status, limit: limit);
    if (after == null) return all.take(limit).toList();
    final i = all.indexWhere((c) => c.caseId == after.caseId);
    return i < 0 ? [] : all.sublist(i + 1).take(limit).toList();
  }

  @override
  Future<CaseSummary?> getCase(int caseId) async {
    for (final c in cases) {
      if (c.caseId == caseId) return c;
    }
    return null;
  }

  @override
  Future<void> updateCase(int caseId,
      {String? title, String? description, String? status}) async {
    calls.add('updateCase:$caseId:$title:$status');
    final i = cases.indexWhere((c) => c.caseId == caseId);
    final c = cases[i];
    cases[i] = CaseSummary(
      caseId: c.caseId,
      title: title ?? c.title,
      description: description ?? c.description,
      status: status ?? c.status,
      dateCreated: c.dateCreated,
      createdByName: c.createdByName,
      possibleSuspects: c.possibleSuspects,
      confirmedSuspects: c.confirmedSuspects,
    );
    _recount();
  }

  @override
  Future<List<CaseEvent>> getCaseEvents(int caseId,
          {CaseEvent? before, int limit = 30}) async =>
      const [];

  @override
  Future<List<CaseAssignmentInfo>> getCaseAssignments(int caseId) async =>
      assignments.where((a) => a.caseId == caseId).toList();

  @override
  Future<int> assignInvestigator(int caseId, int userId) async {
    calls.add('assign:$caseId:$userId');
    final person = investigators.firstWhere((p) => p.userId == userId);
    final id = assignments.length + 1;
    final hasLead =
        assignments.any((a) => a.caseId == caseId && a.isActive && a.isLead);
    assignments.add(CaseAssignmentInfo(
      assignmentId: id,
      userId: userId,
      name: person.displayName,
      badgeNumber: person.badgeNumber,
      station: person.station,
      dutyStatus: person.dutyStatus,
      status: 'active',
      dateAssigned: DateTime(2026, 10, 5, 11),
      caseId: caseId,
      isLead: !hasLead, // the first investigator becomes lead
    ));
    _recount();
    return id;
  }

  @override
  Future<void> setCaseLead(int assignmentId) async {
    calls.add('lead:$assignmentId');
    final target = assignments.firstWhere((a) => a.assignmentId == assignmentId);
    for (var i = 0; i < assignments.length; i++) {
      final a = assignments[i];
      if (a.caseId == target.caseId && a.isActive) {
        assignments[i] =
            _copyAssignment(a, isLead: a.assignmentId == assignmentId);
      }
    }
    _recount();
  }

  @override
  Future<void> unassignInvestigator(int assignmentId) async {
    calls.add('unassign:$assignmentId');
    final i = assignments.indexWhere((a) => a.assignmentId == assignmentId);
    assignments[i] = _copyAssignment(assignments[i],
        status: 'closed', unassigned: DateTime(2026, 10, 5, 12));
    _recount();
  }

  // ---- investigators (for the assign picker) -----------------------------------

  @override
  Future<List<InvestigatorSummary>> getRecentInvestigators(
          {int limit = 20}) async =>
      investigators;

  @override
  Future<List<InvestigatorSummary>> searchInvestigators(String query,
      {int limit = 20}) async {
    final q = query.trim().toLowerCase();
    return investigators
        .where((p) =>
            q.isEmpty ||
            p.fullName.toLowerCase().contains(q) ||
            p.badgeNumber.toLowerCase().contains(q))
        .toList();
  }
}
