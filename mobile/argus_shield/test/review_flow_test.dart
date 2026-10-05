// Tests for reviewing submissions: filter chips, Reject, Accept (new case /
// existing case) and the submission details page (Duplicate).
// Uses AdminFakeService, which keeps everything in memory.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:argus_shield/admin_screens/submissions.dart';
import 'package:argus_shield/admin_screens/submission_detail.dart';
import 'package:argus_shield/models/case_summary.dart';

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

  testWidgets('the Pending chip asks the database for pending only',
      (tester) async {
    final fake = makeService();
    await open(tester, fake);

    await tester.tap(find.text('Pending'));
    await tester.pumpAndSettle();

    expect(fake.calls, contains('recentSubmissions:pending'));
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
