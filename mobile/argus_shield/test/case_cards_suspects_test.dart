// Suspect counts (possible/confirmed, POPIA) and the suggested submission on
// case cards. Runs against AdminFakeService.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:argus_shield/admin_screens/admin_ui.dart';
import 'package:argus_shield/admin_screens/cases.dart';
import 'package:argus_shield/admin_screens/case_detail.dart';
import 'package:argus_shield/admin_screens/submissions.dart';
import 'package:argus_shield/models/case_summary.dart';
import 'package:argus_shield/models/submission_groups.dart';

import 'admin_fake_service.dart';

CaseSummary fakeCase(int id, String title,
        {String status = 'open', int possible = 0, int confirmed = 0}) =>
    CaseSummary(
      caseId: id,
      title: title,
      status: status,
      dateCreated: DateTime(2026, 10, 1),
      possibleSuspects: possible,
      confirmedSuspects: confirmed,
    );

const strongSuggestion = CaseCardSuggestion(
  caseId: 1,
  incidentId: 42,
  score: 110,
  reasons: ['Same plate ND123456GP', '814 m apart'],
  otherCount: 1,
  plate: 'ND123456GP',
  plateMatch: 'same',
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

  group('suspectSummary', () {
    test('nothing to say when there are no people', () {
      expect(suspectSummary(possible: 0, confirmed: 0), isNull);
    });

    test('possible suspects only (the highest submission: A=2, B=1, C=1)', () {
      expect(suspectSummary(possible: 2, confirmed: 0),
          'About 2 possible suspects awaiting investigator review');
    });

    test('confirmed and possible together', () {
      expect(suspectSummary(possible: 1, confirmed: 2),
          '2 confirmed suspects · about 1 possible suspect awaiting investigator review');
    });

    test('confirmed only, and its colour', () {
      expect(suspectSummary(possible: 0, confirmed: 1), '1 confirmed suspect');
      expect(suspectColor(confirmed: 1), isNot(suspectColor(confirmed: 0)));
    });
  });

  group('fromMap', () {
    test('CaseSummary reads the suspect counts (0 when missing)', () {
      final row = {
        'caseid': 3,
        'title': 'R21',
        'status': 'open',
        'datecreated': '2026-10-01T08:00:00+00:00',
      };
      expect(CaseSummary.fromMap(row).possibleSuspects, 0);
      final c = CaseSummary.fromMap(
          {...row, 'possiblesuspects': 2, 'confirmedsuspects': 1});
      expect(c.possibleSuspects, 2);
      expect(c.confirmedSuspects, 1);
    });

    test('CrimeSceneSummary reads the suspect counts', () {
      final s = CrimeSceneSummary.fromMap({
        'incidentid': 7,
        'location': 'Germiston',
        'datetime': '2026-10-01T08:00:00+00:00',
        'status': 'open',
        'reportedby': 4,
        'possiblesuspects': 1,
        'confirmedsuspects': 2,
      });
      expect(s.possibleSuspects, 1);
      expect(s.confirmedSuspects, 2);
      expect(s.hasAiFacts, isTrue);
    });

    test('CaseCardSuggestion, with and without a plate', () {
      final s = CaseCardSuggestion.fromMap({
        'caseid': 1,
        'incidentid': 14,
        'score': 110,
        'reasons': ['Same plate ND123456GP'],
        'othercount': 1,
        'plate': 'ND123456GP',
        'platematch': 'same',
      });
      expect(s.reference, 'INC-0014');
      expect(s.plate, 'ND123456GP');
      expect(s.plateMatch, 'same');
      expect(s.otherCount, 1);

      final none = CaseCardSuggestion.fromMap({
        'caseid': 2,
        'incidentid': 18,
        'score': 60,
        'reasons': <String>[],
        'othercount': 0,
        'plate': null,
        'platematch': null,
      });
      expect(none.plate, isNull);
      expect(none.plateMatch, isNull);
    });

    test('case history names the suspect reviews', () {
      final e = CaseEvent.fromMap({
        'eventid': 1,
        'eventtype': 'suspect_dismissed',
        'incidentid': 16,
        'detail': 'person P-044: Security guard',
        'occurredat': '2026-10-06T08:00:00+00:00',
      });
      expect(e.text,
          'INC-0016 Person dismissed as a suspect · person P-044: Security guard');
    });
  });

  group('Case cards', () {
    Future<void> open(WidgetTester tester, AdminFakeService fake) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: AdminCases(service: fake)),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('show possible and confirmed suspects', (tester) async {
      await open(
          tester,
          AdminFakeService(cases: [
            fakeCase(1, 'N1 Midrand', possible: 2),
            fakeCase(2, 'R21 Kempton Park', possible: 1, confirmed: 2),
            fakeCase(3, 'No footage yet'),
          ]));

      expect(find.text('About 2 possible suspects awaiting investigator review'),
          findsOneWidget);
      expect(
          find.text('2 confirmed suspects · '
              'about 1 possible suspect awaiting investigator review'),
          findsOneWidget);
      // no line at all for a case without people
      expect(find.byIcon(Icons.person_search_outlined), findsNWidgets(2));
    });

    testWidgets('show the best suggested submission with its plate',
        (tester) async {
      final fake = AdminFakeService(cases: [fakeCase(1, 'N1 Midrand')])
        ..caseCardSuggestions = [strongSuggestion];
      await open(tester, fake);

      expect(fake.calls, contains('caseCardSuggestions:[1]'));
      expect(find.text('SUGGESTED SUBMISSION (+1 MORE)'), findsOneWidget);
      expect(find.text('INC-0042 · Strong match'), findsOneWidget);
      expect(find.text('ND123456GP'), findsOneWidget);
      expect(find.text('same plate as in this case'), findsOneWidget);
      expect(find.text('Same plate ND123456GP · 814 m apart'), findsOneWidget);
    });

    testWidgets('a plate not in the case is labelled as an unconfirmed AI read',
        (tester) async {
      final fake = AdminFakeService(cases: [fakeCase(2, 'R21')])
        ..caseCardSuggestions = const [
          CaseCardSuggestion(
              caseId: 2, incidentId: 18, score: 60, plate: 'KL22MNGP'),
        ];
      await open(tester, fake);

      expect(find.text('SUGGESTED SUBMISSION'), findsOneWidget);
      expect(find.text('INC-0018 · Likely match'), findsOneWidget);
      expect(find.text('AI read, not confirmed'), findsOneWidget);
    });

    testWidgets('closed cases are not asked for suggestions', (tester) async {
      final fake = AdminFakeService(cases: [
        fakeCase(1, 'N1 Midrand'),
        fakeCase(7, 'Soweto', status: 'closed', confirmed: 1),
      ])
        ..caseCardSuggestions = [strongSuggestion];
      await open(tester, fake);

      expect(fake.calls, contains('caseCardSuggestions:[1]'));
      expect(find.text('1 confirmed suspect'), findsOneWidget);
      expect(find.textContaining('SUGGESTED SUBMISSION'), findsOneWidget);
    });

    testWidgets('the cards still show when suggestions fail', (tester) async {
      final fake = AdminFakeService(cases: [fakeCase(1, 'N1 Midrand', possible: 2)])
        ..failCaseCardSuggestions = true;
      await open(tester, fake);

      expect(find.byType(CaseCard), findsOneWidget);
      expect(find.text('About 2 possible suspects awaiting investigator review'),
          findsOneWidget);
      expect(find.textContaining('SUGGESTED SUBMISSION'), findsNothing);
    });
  });

  testWidgets('the case page shows the suspect counts', (tester) async {
    final fake = AdminFakeService(
        cases: [fakeCase(1, 'R21 Kempton Park', possible: 1, confirmed: 2)]);
    await tester.pumpWidget(MaterialApp(
      home: CaseDetailPage(caseId: 1, service: fake),
    ));
    await tester.pumpAndSettle();

    expect(
        find.text('2 confirmed suspects · '
            'about 1 possible suspect awaiting investigator review'),
        findsOneWidget);
  });

  testWidgets('submission chips: suspects instead of a plain people count',
      (tester) async {
    CrimeSceneSummary incident({int people = 0, int possible = 0, int confirmed = 0}) =>
        CrimeSceneSummary(
          incidentId: 1,
          location: 'N1',
          dateTime: DateTime(2026, 10, 5),
          status: 'open',
          reportedBy: 4,
          reporterName: 'Sam',
          personCount: people,
          possibleSuspects: possible,
          confirmedSuspects: confirmed,
        );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          AiFactChips(submission: incident(people: 3, possible: 1, confirmed: 2)),
          AiFactChips(submission: incident(people: 2)), // all dismissed
        ]),
      ),
    ));

    expect(find.text('2 confirmed suspects'), findsOneWidget);
    expect(find.text('about 1 possible suspect'), findsOneWidget);
    expect(find.text('3 people'), findsNothing);
    expect(find.text('2 people'), findsOneWidget);
  });
}
