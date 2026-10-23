// The admin Submissions tab and CrimeSceneSummary.fromMap, against the
// in-memory AdminFakeService.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:argus_shield/admin_screens/submissions.dart';
import 'package:argus_shield/admin_screens/case_detail.dart';
import 'package:argus_shield/admin_screens/cases.dart';
import 'package:argus_shield/models/case_summary.dart';
import 'package:argus_shield/models/submission_groups.dart';
import 'package:argus_shield/supabase_service.dart';

import 'admin_fake_service.dart';

/// Fails every submissions request while [fail] is true.
class FlakyService extends AdminFakeService {
  FlakyService({super.submissions});
  bool fail = false;

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
    if (fail) {
      calls.add('listSubmissions:failed');
      throw Exception('offline');
    }
    return super.listSubmissionsPage(
        search: search,
        review: review,
        caseId: caseId,
        locationKey: locationKey,
        ids: ids,
        order: order,
        after: after,
        limit: limit);
  }
}

FlakyService makeService() => FlakyService(submissions: [
      fakeIncident(42, 'R21 Highway, Kempton Park',
          aiSummary: 'Two sedans box in a cash van.', plates: ['ND123456GP']),
      fakeIncident(41, 'N1 km 42, Midrand',
          reviewStatus: 'accepted', caseId: 1, caseTitle: 'Midrand robbery'),
    ]);

/// How many times the submissions list got requested.
int pageCalls(AdminFakeService fake) =>
    fake.calls.where((c) => c.startsWith('listSubmissions:')).length;

void main() {
  group('CrimeSceneSummary.fromMap', () {
    test('reads a list_submissions row', () {
      final s = CrimeSceneSummary.fromMap({
        'incidentid': 42,
        'location': 'R21 Highway, Kempton Park',
        'datetime': '2026-09-28T12:35:00+00:00',
        'attacktype': 'Vehicle ambush',
        'status': 'under_review',
        'description': 'Cash van forced off the road.',
        'reportedby': 4,
        'reportername': 'Sam Citizen',
        'mediacount': 3,
        'datereported': '2026-09-28T13:00:00+00:00',
        'caseid': 2,
        'latitude': -25.99,
        'longitude': '28.130000', // numeric can arrive as text
        'locationkey': 'r21 highway kempton park',
        'aisummary': 'Two sedans box in a cash van.',
        'aisummarystatus': 'ready',
        'aisummaryat': '2026-09-28T14:00:00+00:00',
        'vehiclecount': 2,
        'personcount': 3,
        'weaponcount': 1,
        'plates': ['ND123456GP'],
        'capturedat': '2026-09-28T08:00:00+00:00',
        'timemismatch': true,
      });
      expect(s.reference, 'INC-0042');
      expect(s.location, 'R21 Highway, Kempton Park');
      expect(s.dateTime.isAtSameMomentAs(DateTime.utc(2026, 9, 28, 12, 35)),
          isTrue);
      expect(s.dateTime.isUtc, isFalse); // shown in the phone's local time
      expect(s.attackType, 'Vehicle ambush');
      expect(s.status, 'under_review');
      expect(s.reporterName, 'Sam Citizen');
      expect(s.mediaCount, 3);
      expect(s.dateReported!.isAtSameMomentAs(DateTime.utc(2026, 9, 28, 13)),
          isTrue);
      expect(s.caseId, 2);
      expect(s.latitude, -25.99);
      expect(s.longitude, 28.13);
      expect(s.hasGps, isTrue);
      expect(s.aiSummary, 'Two sedans box in a cash van.');
      expect(s.aiSummaryStatus, 'ready');
      expect(s.vehicleCount, 2);
      expect(s.personCount, 3);
      expect(s.weaponCount, 1);
      expect(s.plates, ['ND123456GP']);
      expect(s.hasAiFacts, isTrue);
      expect(s.capturedAt!.isAtSameMomentAs(DateTime.utc(2026, 9, 28, 8)),
          isTrue);
      expect(s.timeMismatch, isTrue);
      expect(s.bestTime, s.capturedAt); // footage time wins
    });

    test('handles the optional columns being null', () {
      final s = CrimeSceneSummary.fromMap({
        'incidentid': 7,
        'location': 'Germiston',
        'datetime': '2026-10-01T08:00:00+00:00',
        'attacktype': null,
        'status': 'open',
        'description': null,
        'reportedby': 4,
        'reportername': null, // reporter's profile not visible
        'mediacount': null,
        'datereported': null,
        'caseid': null,
      });
      expect(s.reference, 'INC-0007');
      expect(s.attackType, isNull);
      expect(s.description, isNull);
      expect(s.reporterName, 'Unknown');
      expect(s.mediaCount, 0);
      expect(s.dateReported, isNull);
      expect(s.caseId, isNull);
      expect(s.aiSummary, isNull);
      expect(s.aiSummaryStatus, 'none');
      expect(s.plates, isEmpty);
      expect(s.hasGps, isFalse);
      expect(s.hasAiFacts, isFalse);
      expect(s.capturedAt, isNull);
      expect(s.timeMismatch, isFalse);
      expect(s.bestTime, s.dateTime); // falls back to the typed time
    });
  });

  group('Submissions screen', () {
    // phone-sized screen, 360 x 1600 logical pixels, the cards are big
    setUp(() {
      final view =
          TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
      view.physicalSize = const Size(1080, 4800);
      view.devicePixelRatio = 3.0;
    });
    tearDown(() {
      final view =
          TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });

    Future<FlakyService> open(WidgetTester tester, [FlakyService? service]) async {
      final fake = service ?? makeService();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: AdminSubmissions(service: fake)),
      ));
      return fake;
    }

    Future<void> typeSearch(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextField), text);
      await tester.pump(AdminSubmissions.searchDelay);
      await tester.pump(); // let the (fake) search finish
    }

    testWidgets('shows a spinner, then the newest submissions', (tester) async {
      final fake = await open(tester);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pump();
      expect(pageCalls(fake), 1);
      expect(fake.calls.last, 'listSubmissions:null::newest');
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(CrimeSceneCard), findsNWidgets(2));
      expect(find.text('INC-0042'), findsOneWidget);
      expect(find.text('R21 Highway, Kempton Park'), findsOneWidget);
    });

    testWidgets('cards show the citizen and the AI description',
        (tester) async {
      await open(tester);
      await tester.pump();

      expect(find.text('CITIZEN'), findsNWidgets(2));
      expect(find.text('AI SUMMARY'), findsNWidgets(2));
      expect(find.text('Report 42'), findsOneWidget); // citizen's words
      expect(find.text('Two sedans box in a cash van.'), findsOneWidget);
      expect(find.text('No footage to analyse'), findsOneWidget); // INC-0041
      expect(find.text('ND123456GP'), findsOneWidget); // plate chip
    });

    testWidgets('shows the filmed time and warns when it disagrees',
        (tester) async {
      final fake = FlakyService(submissions: [
        CrimeSceneSummary(
          incidentId: 50,
          location: 'Germiston Mall',
          dateTime: DateTime(2026, 10, 5, 13, 0), // what the citizen typed
          capturedAt: DateTime(2026, 10, 5, 9, 0), // from the video
          timeMismatch: true,
          status: 'open',
          reportedBy: 4,
          reporterName: 'Sam Citizen',
        ),
        fakeIncident(49, 'N1, Midrand'), // no capture time
      ]);
      await open(tester, fake);
      await tester.pump();

      expect(find.text('Filmed 05/10/2026 09:00'), findsOneWidget);
      expect(
          find.text('Citizen said 05/10/2026 13:00: check which time is right'),
          findsOneWidget);
      expect(find.text('Happened 05/10/2026 09:15 (as reported)'),
          findsOneWidget);
    });

    testWidgets('the search hint names incident number and location',
        (tester) async {
      await open(tester);
      await tester.pump();
      expect(find.text('Search by incident number/location'), findsOneWidget);
    });

    testWidgets('searches the database after typing stops', (tester) async {
      final fake = await open(tester);
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'kempton');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byType(TextField), ' Kempton ');
      expect(pageCalls(fake), 1); // nothing sent while still typing

      await tester.pump(AdminSubmissions.searchDelay);
      await tester.pump();
      expect(pageCalls(fake), 2); // one request, trimmed
      expect(fake.calls.last, 'listSubmissions:null:Kempton:newest');
      expect(find.byType(CrimeSceneCard), findsOneWidget);
    });

    testWidgets('pressing search on the keyboard searches straight away',
        (tester) async {
      final fake = await open(tester);
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'midrand');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.pump();
      expect(fake.calls.last, 'listSubmissions:null:midrand:newest');
      final before = pageCalls(fake);

      await tester.pump(AdminSubmissions.searchDelay);
      await tester.pump();
      expect(pageCalls(fake), before); // not sent a second time
    });

    testWidgets('clearing the search shows everything again', (tester) async {
      final fake = await open(tester);
      await tester.pump();
      await typeSearch(tester, 'kempton');
      expect(find.byType(CrimeSceneCard), findsOneWidget);

      await tester.tap(find.byTooltip('Clear search'));
      await tester.pump();
      await tester.pump();
      expect(fake.calls.last, 'listSubmissions:null::newest');
      expect(find.byType(CrimeSceneCard), findsNWidgets(2));
    });

    testWidgets('no matches shows a message', (tester) async {
      await open(tester);
      await tester.pump();
      await typeSearch(tester, 'nowhere');

      expect(find.byType(CrimeSceneCard), findsNothing);
      expect(find.text('No submissions match your search.'), findsOneWidget);
    });

    testWidgets('an error shows a message, and Try again reloads',
        (tester) async {
      final fake = makeService()..fail = true;
      await open(tester, fake);
      await tester.pump();

      expect(find.text('Could not load submissions. Check your connection.'),
          findsOneWidget);

      fake.fail = false;
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(CrimeSceneCard), findsNWidgets(2));
    });

    testWidgets('Oldest asks for the oldest first', (tester) async {
      final fake = await open(tester);
      await tester.pump();

      await tester.ensureVisible(find.text('Oldest')); // chips scroll sideways

      await tester.pumpAndSettle();

      await tester.tap(find.text('Oldest'));
      await tester.pumpAndSettle();
      expect(fake.calls.last, 'listSubmissions:null::oldest');
      expect(find.byType(CrimeSceneCard), findsNWidgets(2));
    });

    testWidgets('Status starts on Pending and has the review chips',
        (tester) async {
      final fake = await open(tester);
      await tester.pump();

      await tester.ensureVisible(find.text('Status')); // chips scroll sideways

      await tester.pumpAndSettle();

      await tester.tap(find.text('Status'));
      await tester.pumpAndSettle();
      expect(fake.calls.last, 'listSubmissions:pending::newest');
      expect(find.byType(CrimeSceneCard), findsOneWidget);
      expect(find.text('INC-0042'), findsOneWidget);

      await tester.tap(find.text('In a case'));
      await tester.pumpAndSettle();
      expect(fake.calls.last, 'listSubmissions:accepted::newest');
      expect(find.text('INC-0041'), findsOneWidget);
    });

    testWidgets('Location groups submissions; a group opens its list',
        (tester) async {
      final fake = FlakyService(submissions: [
        fakeIncident(43, 'N1 km 42, Midrand'),
        fakeIncident(42, 'R21 Highway, Kempton Park'),
        fakeIncident(41, 'N1 km 42, Midrand'),
      ]);
      await open(tester, fake);
      await tester.pump();

      await tester.ensureVisible(find.text('Location')); // chips scroll sideways

      await tester.pumpAndSettle();

      await tester.tap(find.text('Location'));
      await tester.pumpAndSettle();
      expect(find.byType(LocationGroupCard), findsNWidgets(2));
      expect(find.text('Search locations'), findsOneWidget);
      expect(find.textContaining('2 submissions · 2 pending'), findsOneWidget);

      await tester.tap(find.text('N1 km 42, Midrand'));
      await tester.pumpAndSettle();
      expect(find.byType(SubmissionListPage), findsOneWidget);
      expect(find.byType(CrimeSceneCard), findsNWidgets(2));
    });

    testWidgets('Case shows case cards with a preview; View case opens it',
        (tester) async {
      final fake = makeService();
      fake.cases.add(CaseSummary(
        caseId: 1,
        title: 'Midrand robbery',
        status: 'open',
        dateCreated: DateTime(2026, 10, 1),
      ));
      await fake.reopenSubmission(42); // refreshes the case counts (42 stays pending)
      await open(tester, fake);
      await tester.pump();

      await tester.ensureVisible(find.text('Case')); // chips scroll sideways

      await tester.pumpAndSettle();

      await tester.tap(find.text('Case'));
      await tester.pumpAndSettle();
      expect(find.byType(CaseCard), findsOneWidget);
      expect(find.text('Midrand robbery'), findsOneWidget);
      expect(find.text('1 submission'), findsOneWidget);
      expect(find.textContaining('INC-0041 · N1 km 42, Midrand'), findsOneWidget);
      expect(find.text('Not in a case yet: see pending submissions'),
          findsOneWidget);

      await tester.tap(find.text('View case'));
      await tester.pumpAndSettle();
      expect(find.byType(CaseDetailPage), findsOneWidget);
      expect(find.text('CASE-0001'), findsOneWidget);
    });

    testWidgets('Linked shows a message when the AI linked nothing',
        (tester) async {
      await open(tester);
      await tester.pump();

      await tester.ensureVisible(find.text('Linked')); // chips scroll sideways

      await tester.pumpAndSettle();

      await tester.tap(find.text('Linked'));
      await tester.pumpAndSettle();
      expect(find.textContaining('No linked submissions found.'), findsOneWidget);
      expect(find.byType(TextField), findsNothing); // no search here
    });

    testWidgets('Linked group lists its submissions and adds the pending ones',
        (tester) async {
      final fake = FlakyService(submissions: [
        fakeIncident(43, 'Mall of Africa, Midrand'),
        fakeIncident(42, 'N1, Midrand', plates: ['ND123456GP']),
        fakeIncident(41, 'N1 North, Midrand', plates: ['ND123456GP']),
      ]);
      fake.linkedGroups = const [
        LinkedGroup(
          groupId: 41,
          incidentIds: [42, 41],
          pendingCount: 2,
          linkCount: 1,
          verifiedLinks: 1,
          bestConfidence: 0.96,
          plates: ['ND123456GP'],
        ),
      ];
      await open(tester, fake);
      await tester.pump();

      await tester.ensureVisible(find.text('Linked')); // chips scroll sideways

      await tester.pumpAndSettle();

      await tester.tap(find.text('Linked'));
      await tester.pumpAndSettle();
      expect(find.byType(LinkedGroupCard), findsOneWidget);
      expect(find.text('2 linked submissions'), findsOneWidget);
      expect(find.text('96% best match'), findsOneWidget);
      expect(find.byType(SubmissionRow), findsNWidgets(2));

      await tester.tap(find.text('Add 2 pending submissions to a case'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create a new case'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create case with 2 submissions'));
      await tester.pumpAndSettle();

      expect(fake.calls, contains('createCase:N1, Midrand:[42, 41]'));
    });

    testWidgets('loads 30 at a time and fetches more when scrolling',
        (tester) async {
      final fake = FlakyService(submissions: [
        for (var id = 45; id >= 1; id--) fakeIncident(id, 'Place $id'),
      ]);
      await open(tester, fake);
      await tester.pump();
      expect(pageCalls(fake), 1);

      await tester.scrollUntilVisible(find.text('INC-0001'), 2000,
          scrollable: find.byType(Scrollable).last);
      await tester.pump();
      expect(pageCalls(fake), 2); // the second page came in
      expect(find.text('INC-0001'), findsOneWidget);
    });
  });
}
