// Tests for the Cases tab and the case details page.
// Uses AdminFakeService, which keeps everything in memory.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:argus_shield/admin_screens/cases.dart';
import 'package:argus_shield/admin_screens/case_detail.dart';
import 'package:argus_shield/models/case_summary.dart';
import 'package:argus_shield/models/investigator_summary.dart';
import 'package:argus_shield/models/submission_groups.dart';

import 'admin_fake_service.dart';

AdminFakeService makeService() => AdminFakeService(
      submissions: [
        fakeIncident(41, 'N1 North, Midrand',
            reviewStatus: 'accepted', caseId: 1, caseTitle: 'Existing robbery'),
        fakeIncident(42, 'Shoprite, Main Road, Germiston'),
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

  group('Cases tab', () {
    Future<void> open(WidgetTester tester, AdminFakeService fake) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: AdminCases(service: fake)),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('lists the cases', (tester) async {
      await open(tester, makeService());

      expect(find.byType(CaseCard), findsOneWidget);
      expect(find.text('CASE-0001'), findsOneWidget);
      expect(find.text('Existing robbery'), findsOneWidget);
      expect(find.text('1 submission'), findsOneWidget);
      expect(find.text('No investigator assigned'), findsOneWidget);
    });

    testWidgets('the Closed chip filters by status', (tester) async {
      final fake = makeService();
      await open(tester, fake);

      // the chips scroll sideways on a phone; bring "Closed" into view
      await tester.ensureVisible(find.text('Closed'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Closed'));
      await tester.pumpAndSettle();

      expect(fake.calls, contains('listCases::closed'));
      expect(find.text('No cases with this status.'), findsOneWidget);
    });

    testWidgets('+ New case creates it and opens its page', (tester) async {
      final fake = makeService();
      await open(tester, fake);

      await tester.tap(find.text('+ New case'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byType(TextField).at(1), 'Germiston cross-pavement');
      await tester.tap(find.text('Create case'));
      await tester.pumpAndSettle();

      expect(fake.calls, contains('createCase:Germiston cross-pavement:[]'));
      expect(find.byType(CaseDetailPage), findsOneWidget);
      expect(find.text('CASE-0002'), findsOneWidget);
      expect(find.text('Germiston cross-pavement'), findsOneWidget);
    });
  });

  group('Case details page', () {
    Future<AdminFakeService> open(WidgetTester tester) async {
      final fake = makeService();
      await tester.pumpWidget(MaterialApp(
        home: CaseDetailPage(caseId: 1, service: fake),
      ));
      await tester.pumpAndSettle();
      return fake;
    }

    testWidgets('shows the case, its incidents and no investigator yet',
        (tester) async {
      await open(tester);

      expect(find.text('CASE-0001'), findsOneWidget);
      expect(find.text('Existing robbery'), findsOneWidget);
      expect(find.text('INC-0041'), findsOneWidget);
      expect(find.text('No investigator assigned yet.'), findsOneWidget);
    });

    testWidgets('assign an investigator, then remove them', (tester) async {
      final fake = await open(tester);

      await tester.tap(find.text('+ Assign'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sgt. Thabo Mokoena'));
      await tester.pumpAndSettle();

      expect(fake.calls, contains('assign:1:2'));
      expect(find.text('Sgt. Thabo Mokoena'), findsOneWidget);
      expect(find.text('No investigator assigned yet.'), findsNothing);

      await tester.tap(find.byTooltip('Remove from case'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await tester.pumpAndSettle();

      expect(fake.calls, contains('unassign:1'));
      expect(find.text('Previously assigned'), findsOneWidget);
      expect(find.text('No investigator assigned yet.'), findsOneWidget);
    });

    testWidgets('+ Add puts pending submissions into the case',
        (tester) async {
      final fake = await open(tester);

      await tester.tap(find.text('+ Add'));
      await tester.pumpAndSettle();
      expect(fake.calls, contains('searchSubmissions::pending'));

      await tester.tap(find.text('INC-0042 · Shoprite, Main Road, Germiston'));
      await tester.pump();
      await tester.tap(find.text('Add 1 incident'));
      await tester.pumpAndSettle();

      expect(fake.calls, contains('addIncidents:1:[42]'));
      expect(find.text('Submissions (2)'.toUpperCase()), findsOneWidget);
    });

    testWidgets('the first investigator is lead; the star changes the lead',
        (tester) async {
      final fake = makeService()
        ..investigators.add(const InvestigatorSummary(
          userId: 3,
          firstName: 'Lerato',
          surname: 'Dlamini',
          badgeNumber: 'JHB-5120',
          station: 'Kempton Park SAPS',
          dutyStatus: 'available',
          email: 'ldlamini@argus.test',
        ));
      await fake.assignInvestigator(1, 2);
      await fake.assignInvestigator(1, 3);
      await tester.pumpWidget(MaterialApp(
        home: CaseDetailPage(caseId: 1, service: fake),
      ));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.star), findsOneWidget); // Thabo, the lead
      expect(find.byIcon(Icons.star_border), findsOneWidget); // Lerato

      await tester.tap(find.byTooltip('Make lead'));
      await tester.pumpAndSettle();
      expect(fake.calls, contains('lead:2'));
      expect(find.text('Lerato Dlamini is now the lead on CASE-0001'),
          findsOneWidget);
    });

    testWidgets('recommended submissions can be added with one tap',
        (tester) async {
      final fake = makeService()
        ..incidentSuggestions = const [
          IncidentSuggestion(
            incidentId: 42,
            score: 70,
            reasons: ['40 min apart', 'Same location'],
            matchedIncidentId: 41,
          ),
        ];
      await tester.pumpWidget(MaterialApp(
        home: CaseDetailPage(caseId: 1, service: fake),
      ));
      await tester.pumpAndSettle();

      expect(find.text('RECOMMENDED FOR THIS CASE'), findsOneWidget);
      expect(find.text('LIKELY MATCH'), findsOneWidget);
      expect(find.text('40 min apart'), findsOneWidget);

      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(fake.calls, contains('addIncidents:1:[42]'));
      expect(find.text('Submissions (2)'.toUpperCase()), findsOneWidget);
    });

    testWidgets('remove from case keeps the submission (back to pending)',
        (tester) async {
      final fake = await open(tester);

      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from case'));
      await tester.pumpAndSettle();
      expect(find.textContaining('goes back to Pending review'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await tester.pumpAndSettle();

      expect(fake.calls, contains('reopen:41'));
      // still there, just not in the case
      expect(fake.submissions.any((s) => s.incidentId == 41 && s.isPending),
          isTrue);
      expect(find.text('No submissions in this case yet.'), findsOneWidget);
    });

    testWidgets('closing asks first, then locks assigning and adding',
        (tester) async {
      final fake = await open(tester);

      await tester.tap(find.text('Closed'));
      await tester.pumpAndSettle();
      expect(find.text('Close CASE-0001?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Close case'));
      await tester.pumpAndSettle();

      expect(fake.calls, contains('updateCase:1:null:closed'));
      OutlinedButton button(String label) => tester.widget<OutlinedButton>(
          find.ancestor(
              of: find.text(label), matching: find.byType(OutlinedButton)));
      expect(button('+ Assign').onPressed, isNull);
      expect(button('+ Add').onPressed, isNull);
    });
  });
}
