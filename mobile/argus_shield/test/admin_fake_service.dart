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

CrimeSceneSummary fakeIncident(
  int id,
  String location, {
  String reviewStatus = 'pending',
  int? caseId,
  String? caseTitle,
  int? duplicateOf,
  String? note,
}) =>
    CrimeSceneSummary(
      incidentId: id,
      location: location,
      dateTime: DateTime(2026, 10, 5, 9, 15),
      dateReported: DateTime(2026, 10, 5, 9, 30),
      status: 'open',
      description: 'Report $id',
      reportedBy: 4,
      reporterName: 'Sam Citizen',
      reviewStatus: reviewStatus,
      caseId: caseId,
      caseTitle: caseTitle,
      duplicateOf: duplicateOf,
      reviewNote: note,
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
        investigators = investigators ?? [fakeInvestigator];

  final List<CrimeSceneSummary> submissions;
  final List<CaseSummary> cases;
  final List<InvestigatorSummary> investigators;
  final List<CaseAssignmentInfo> assignments = [];
  final List<String> calls = [];

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
        note: note);
    _recount();
  }

  /// Keeps each case's incident count and investigators in step.
  void _recount() {
    for (var i = 0; i < cases.length; i++) {
      final c = cases[i];
      cases[i] = CaseSummary(
        caseId: c.caseId,
        title: c.title,
        description: c.description,
        status: c.status,
        dateCreated: c.dateCreated,
        dateClosed: c.status == 'closed' ? DateTime(2026, 10, 6) : null,
        createdByName: c.createdByName,
        incidentCount:
            submissions.where((s) => s.caseId == c.caseId).length,
        investigators: [
          for (final a in assignments)
            if (a.caseId == c.caseId && a.isActive)
              CaseInvestigator(
                  userId: a.userId, name: a.name, badgeNumber: a.badgeNumber),
        ],
      );
    }
  }

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
    );
    _recount();
  }

  @override
  Future<List<CaseAssignmentInfo>> getCaseAssignments(int caseId) async =>
      assignments.where((a) => a.caseId == caseId).toList();

  @override
  Future<int> assignInvestigator(int caseId, int userId) async {
    calls.add('assign:$caseId:$userId');
    final person = investigators.firstWhere((p) => p.userId == userId);
    final id = assignments.length + 1;
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
    ));
    _recount();
    return id;
  }

  @override
  Future<void> unassignInvestigator(int assignmentId) async {
    calls.add('unassign:$assignmentId');
    final i = assignments.indexWhere((a) => a.assignmentId == assignmentId);
    final a = assignments[i];
    assignments[i] = CaseAssignmentInfo(
      assignmentId: a.assignmentId,
      userId: a.userId,
      name: a.name,
      badgeNumber: a.badgeNumber,
      station: a.station,
      dutyStatus: a.dutyStatus,
      status: 'closed',
      dateAssigned: a.dateAssigned,
      dateUnassigned: DateTime(2026, 10, 5, 12),
      caseId: a.caseId,
    );
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
