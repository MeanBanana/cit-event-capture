// Tests for the admin Submissions tab and CrimeSceneSummary.fromMap.
//
// A fake SupabaseService stands in for the real one, so these tests run
// without a network connection or a Supabase project.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:argus_shield/admin_screens/submissions.dart';
import 'package:argus_shield/supabase_service.dart';

CrimeSceneSummary incident(int id, String location, {int media = 0}) =>
    CrimeSceneSummary(
      incidentId: id,
      location: location,
      dateTime: DateTime(2026, 10, 5, 9, 15),
      status: 'open',
      reportedBy: 4,
      reporterName: 'Sam Citizen',
      mediaCount: media,
    );

final recent = [
  incident(42, 'R21 Highway, Kempton Park', media: 3),
  incident(41, 'N1 km 42, Midrand'),
];

/// Records what the screen asked for and returns canned lists.
class FakeSupabaseService extends SupabaseService {
  int recentCalls = 0;
  final List<String> searches = [];
  bool fail = false;
  List<CrimeSceneSummary> searchResult = [recent.first];

  @override
  Future<List<CrimeSceneSummary>> getRecentSubmissions(
      {int limit = 20, String? review}) async {
    recentCalls++;
    if (fail) throw Exception('offline');
    return recent;
  }

  @override
  Future<List<CrimeSceneSummary>> searchSubmissions(String query,
      {int limit = 20, String? review}) async {
    searches.add(query);
    if (fail) throw Exception('offline');
    return searchResult;
  }
}

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
    });
  });

  group('Submissions screen', () {
    // A phone-sized screen (360 x 800 logical pixels).
    setUp(() {
      final view =
          TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
      view.physicalSize = const Size(1080, 3600); // tall: cards are big
      view.devicePixelRatio = 3.0;
    });
    tearDown(() {
      final view =
          TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });

    Future<FakeSupabaseService> open(WidgetTester tester,
        [FakeSupabaseService? service]) async {
      final fake = service ?? FakeSupabaseService();
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

    testWidgets('shows a spinner, then the recent submissions',
        (tester) async {
      final fake = await open(tester);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pump();
      expect(fake.recentCalls, 1);
      expect(fake.searches, isEmpty);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(CrimeSceneCard), findsNWidgets(2));
      expect(find.text('INC-0042'), findsOneWidget);
      expect(find.text('R21 Highway, Kempton Park'), findsOneWidget);
      expect(find.text('3 media files'), findsOneWidget);
      expect(find.text('Showing the 2 most recent submissions'),
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

      await tester.enterText(find.byType(TextField), 'INC');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byType(TextField), ' INC-0042 ');
      expect(fake.searches, isEmpty); // nothing sent while still typing

      await tester.pump(AdminSubmissions.searchDelay);
      await tester.pump();
      expect(fake.searches, ['INC-0042']); // one request, trimmed
      expect(find.byType(CrimeSceneCard), findsOneWidget);
      expect(find.text('1 match for "INC-0042"'), findsOneWidget);
    });

    testWidgets('pressing search on the keyboard searches straight away',
        (tester) async {
      final fake = await open(tester);
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'midrand');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(fake.searches, ['midrand']);

      await tester.pump(AdminSubmissions.searchDelay);
      await tester.pump();
      expect(fake.searches, ['midrand']); // not sent a second time
    });

    testWidgets('clearing the search shows the recent list again',
        (tester) async {
      final fake = await open(tester);
      await tester.pump();
      await typeSearch(tester, '42');

      await tester.tap(find.byTooltip('Clear search'));
      await tester.pump();
      await tester.pump();
      expect(fake.recentCalls, 2);
      expect(find.byType(CrimeSceneCard), findsNWidgets(2));
    });

    testWidgets('no matches shows a message', (tester) async {
      final fake = FakeSupabaseService()..searchResult = [];
      await open(tester, fake);
      await tester.pump();
      await typeSearch(tester, 'nowhere');

      expect(find.byType(CrimeSceneCard), findsNothing);
      expect(find.text('No submissions match your search.'), findsOneWidget);
    });

    testWidgets('an error shows a message, and Try again reloads',
        (tester) async {
      final fake = FakeSupabaseService()..fail = true;
      await open(tester, fake);
      await tester.pump();

      expect(find.text('Could not load submissions. Check your connection.'),
          findsOneWidget);

      fake.fail = false;
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump();
      expect(fake.recentCalls, 2);
      expect(find.byType(CrimeSceneCard), findsNWidgets(2));
    });
  });
}
