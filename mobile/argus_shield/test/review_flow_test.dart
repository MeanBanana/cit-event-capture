// Tests for reviewing submissions: the Status view, Reject, Accept (new
// case / existing case / suggested case / "not listed" -> create and open)
// and the submission details page (Duplicate).
// Uses AdminFakeService, which keeps everything in memory.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:argus_shield/admin_screens/submissions.dart';
import 'package:argus_shield/admin_screens/submission_detail.dart';
import 'package:argus_shield/admin_screens/case_detail.dart';
import 'package:argus_shield/models/case_summary.dart';
import 'package:argus_shield/models/submission_groups.dart';

import 'admin_fake_service.dart';

AdminFakeService makeService() => AdminFakeService(
      submissions: [
        fakeIncident(42, 'R21 Highway, Kempton Park'),
        fakeIncident(41, 'N1 North, Midrand',
            reviewStatus: 'accepted', caseId: 1, caseTitle: 'Existing robbery'),
      ],
      cases: [
        CaseSummary(
          caseId: 1,
          title: 'Existing robbery',
          status: 'open',
          dateCreated: DateTime(2026, 10, 1),
          incidentCount: 1,
        ),
      ],
    );

void main() {
  setUp(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1080, 4800); // tall phone, 360 x 1600
    view.devicePixelRatio = 3.0;
  });
  tearDown(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  Future<void> open(WidgetTester tester, AdminFakeService fake) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: AdminSubmissions(service: fake)),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('cards show the review status; only pending has Accept/Reject',
      (tester) async {
    await open(tester, makeService());

    expect(find.byType(CrimeSceneCard), findsNWidgets(2));
    expect(find.text('PENDING REVIEW'), findsOneWidget);
    expect(find.text('IN A CASE'), findsOneWidget);
    expect(find.text('CASE-0001 · Existing robbery'), findsOneWidget);
    expect(find.text('Accept'), findsOneWidget);
    expect(find.text('Reject'), findsOneWidget);
  });

  testWidgets('the Status view asks the database for pending only',
      (tester) async {
    final fake = makeService();
    await open(tester, fake);

    await tester.ensureVisible(find.text('Status')); // chips scroll sideways

    await tester.pumpAndSettle();

    await tester.tap(find.text('Status'));
    await tester.pumpAndSettle();

    expect(fake.calls, contains('listSubmissions:pending::newest'));
    expect(find.byType(CrimeSceneCard), findsOneWidget);
    expect(find.text('INC-0042'), findsOneWidget);
  });

  testWidgets('Reject asks for a reason and rejects', (tester) async {
    final fake = makeService();
    await open(tester, fake);

    await tester.tap(find.text('Reject'));
    await tester.pumpAndSettle();
    expect(find.text('Reject INC-0042?'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'Not a CIT incident');
    await tester.tap(find.widgetWithText(TextButton, 'Reject'));
    await tester.pumpAndSettle();

    expect(fake.calls, contains('reject:42:Not a CIT incident'));
    expect(find.text('INC-0042 rejected'), findsOneWidget); // snackbar
    expect(find.text('REJECTED'), findsOneWidget); // list reloaded
  });

  testWidgets('Accept → Create a new case', (tester) async {
    final fake = makeService();
    await open(tester, fake);

    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create a new case'));
    await tester.pumpAndSettle();

    // title is filled in from the location
    expect(find.text('R21 Highway, Kempton Park'), findsWidgets);
    await tester.tap(find.text('Create case with INC-0042'));
    await tester.pumpAndSettle();

    expect(fake.calls, contains('createCase:R21 Highway, Kempton Park:[42]'));
    expect(find.text('INC-0042 added to new case CASE-0002'), findsOneWidget);
    expect(find.text('PENDING REVIEW'), findsNothing);
  });

  testWidgets('Accept → Add to an existing case', (tester) async {
    final fake = makeService();
    await open(tester, fake);

    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to an existing case'));
    await tester.pumpAndSettle();

    expect(fake.calls, contains('listCases::active')); // only open cases
    // .last = the one in the panel (the card behind it shows it too)
    await tester.tap(find.text('CASE-0001 · Existing robbery').last);
    await tester.pumpAndSettle();

    expect(fake.calls, contains('addIncidents:1:[42]'));
    expect(find.text('INC-0042 added to CASE-0001'), findsOneWidget);
  });

  testWidgets('Accept shows suggested cases first, with the reasons',
      (tester) async {
    final fake = makeService()
      ..caseSuggestions = const [
        CaseSuggestion(
          caseId: 1,
          score: 110,
          reasons: ['Same plate ND123456GP', '750 m apart'],
          matchedIncidentId: 41,
        ),
      ];
    await open(tester, fake);

    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();

    expect(find.text('SUGGESTED CASES'), findsOneWidget);
    expect(find.text('STRONG MATCH'), findsOneWidget);
    expect(find.text('Same plate ND123456GP'), findsOneWidget);
    expect(find.text('matches INC-0041'), findsOneWidget);

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(fake.calls, contains('addIncidents:1:[42]'));
    expect(find.text('INC-0042 added to CASE-0001'), findsOneWidget);
  });

  testWidgets('suggested matches: review the list, accept in one tap',
      (tester) async {
    final fake = makeService();
    fake.submissions.add(fakeIncident(43, 'N1, Midrand'));
    fake.suggestedMatches = const [
      SuggestedMatch(
        incidentId: 42,
        caseId: 1,
        score: 110,
        reasons: ['Same plate ND123456GP', '40 min apart'],
        matchedIncidentId: 41,
      ),
      SuggestedMatch(
        incidentId: 43,
        caseId: 1,
        score: 65,
        reasons: ['3.0 km apart'],
        matchedIncidentId: 41,
        otherCases: 1, // ambiguous: starts unticked
      ),
    ];
    await open(tester, fake);

    // the bar above the list
    expect(find.text('2 submissions match existing cases'), findsOneWidget);
    await tester.tap(find.text('2 submissions match existing cases'));
    await tester.pumpAndSettle();

    // nothing was added just by looking
    expect(fake.calls.where((c) => c.startsWith('acceptSuggested')), isEmpty);
    expect(find.text('Suggested matches'), findsOneWidget);
    expect(find.text('1 of 2 selected'), findsOneWidget);
    expect(find.text('STRONG MATCH'), findsOneWidget);
    expect(find.text('Same plate ND123456GP'), findsOneWidget);
    expect(find.text('Also matches 1 other case: check before accepting.'),
        findsOneWidget);

    await tester.tap(find.text('Accept 1 match'));
    await tester.pumpAndSettle();

    expect(fake.calls, contains('acceptSuggested:[42->1]'));
    expect(find.text('1 submission added to cases'), findsOneWidget);
    expect(find.text('0 of 1 selected'), findsOneWidget); // only 43 is left
  });

  testWidgets('case not listed: create it and go to the case page',
      (tester) async {
    final fake = makeService();
    await open(tester, fake);

    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add to an existing case'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Case not listed? Create a new case'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create case and open it'));
    await tester.pumpAndSettle();

    expect(fake.calls, contains('createCase:R21 Highway, Kempton Park:[42]'));
    expect(find.byType(CaseDetailPage), findsOneWidget);
    expect(find.text('CASE-0002'), findsOneWidget);
  });

  testWidgets('details page: mark as duplicate', (tester) async {
    final fake = makeService();
    await tester.pumpWidget(MaterialApp(
      home: SubmissionDetailPage(
          submission: fake.submissions.first, service: fake),
    ));
    await tester.pumpAndSettle();

    expect(find.text('INC-0042'), findsOneWidget);
    expect(
        find.text('Waiting for an admin to accept, reject or mark it '
            'as a duplicate.'),
        findsOneWidget);

    await tester.tap(find.text('Duplicate'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('INC-0041 · N1 North, Midrand'));
    await tester.pumpAndSettle();

    expect(fake.calls, contains('duplicate:42:41'));
    expect(find.textContaining('Duplicate of INC-0041'), findsOneWidget);
    expect(find.text('Reopen for review'), findsOneWidget);
  });
}
