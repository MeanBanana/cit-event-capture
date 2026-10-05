// Tests for the admin Investigators tab and InvestigatorSummary.fromMap.
//
// A fake SupabaseService stands in for the real one, so these tests run
// without a network connection or a Supabase project.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:argus_shield/admin_screens/investigators.dart';
import 'package:argus_shield/supabase_service.dart';

InvestigatorSummary inv(int id, String first, String last, String badge,
        {int cases = 0}) =>
    InvestigatorSummary(
      userId: id,
      firstName: first,
      surname: last,
      badgeNumber: badge,
      station: 'Kempton Park SAPS',
      dutyStatus: 'available',
      email: '$first@saps.gov.za',
      activeCases: cases,
    );

final recent = [
  inv(1, 'Thabo', 'Mokoena', 'JHB-4471', cases: 3),
  inv(2, 'Naledi', 'Dlamini', 'PTA-1002'),
];

/// Records what the screen asked for and returns canned lists.
class FakeSupabaseService extends SupabaseService {
  int recentCalls = 0;
  final List<String> searches = [];
  bool fail = false;
  List<InvestigatorSummary> searchResult = [recent.first];

  @override
  Future<List<InvestigatorSummary>> getRecentInvestigators(
      {int limit = 20}) async {
    recentCalls++;
    if (fail) throw Exception('offline');
    return recent;
  }

  @override
  Future<List<InvestigatorSummary>> searchInvestigators(String query,
      {int limit = 20}) async {
    searches.add(query);
    if (fail) throw Exception('offline');
    return searchResult;
  }
}

void main() {
  group('InvestigatorSummary.fromMap', () {
    test('reads a list_investigators row', () {
      final i = InvestigatorSummary.fromMap({
        'userid': 7,
        'firstname': 'Thabo',
        'surname': 'Mokoena',
        'email': 'thabo@saps.gov.za',
        'phonenumber': '+27825550147',
        'rank': 'Sgt.',
        'badgenumber': 'JHB-4471',
        'station': 'Kempton Park SAPS',
        'unit': 'CIT Task Force',
        'dutystatus': 'on_duty',
        'datecreated': '2026-10-05T14:16:00+00:00',
        'activecases': 3,
      });
      expect(i.userId, 7);
      expect(i.displayName, 'Sgt. Thabo Mokoena');
      expect(i.badgeNumber, 'JHB-4471');
      expect(i.unit, 'CIT Task Force');
      expect(i.phoneNumber, '+27825550147');
      expect(i.dutyStatus, 'on_duty');
      expect(i.activeCases, 3);
      expect(i.dateCreated, DateTime.utc(2026, 10, 5, 14, 16));
    });

    test('handles the optional columns being null', () {
      final i = InvestigatorSummary.fromMap({
        'userid': 8,
        'firstname': 'Naledi',
        'surname': 'Dlamini',
        'email': 'naledi@saps.gov.za',
        'phonenumber': null,
        'rank': null,
        'badgenumber': 'PTA-1002',
        'station': 'Pretoria Central',
        'unit': null,
        'dutystatus': 'available',
        'datecreated': null,
        'activecases': null,
      });
      expect(i.displayName, 'Naledi Dlamini');
      expect(i.rank, isNull);
      expect(i.unit, isNull);
      expect(i.phoneNumber, isNull);
      expect(i.dateCreated, isNull);
      expect(i.activeCases, 0);
    });
  });

  group('Investigators screen', () {
    // A phone-sized screen (360 x 800 logical pixels).
    setUp(() {
      final view =
          TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
      view.physicalSize = const Size(1080, 2400);
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
        home: Scaffold(body: Investigators(service: fake)),
      ));
      return fake;
    }

    Future<void> typeSearch(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextField), text);
      await tester.pump(Investigators.searchDelay);
      await tester.pump(); // let the (fake) search finish
    }

    testWidgets('shows a spinner, then the recent investigators',
        (tester) async {
      final fake = await open(tester);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pump();
      expect(fake.recentCalls, 1);
      expect(fake.searches, isEmpty);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(InvestigatorCard), findsNWidgets(2));
      expect(find.text('Thabo Mokoena'), findsOneWidget);
      expect(find.text('BADGE JHB-4471'), findsOneWidget);
      expect(find.text('3 active cases'), findsOneWidget);
      expect(find.text('Showing the 2 most recently added investigators'),
          findsOneWidget);
    });

    testWidgets('searches the database after typing stops', (tester) async {
      final fake = await open(tester);
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'jh');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(find.byType(TextField), ' jhb ');
      // nothing sent while the user is still typing
      expect(fake.searches, isEmpty);

      await tester.pump(Investigators.searchDelay);
      await tester.pump();
      expect(fake.searches, ['jhb']); // one request, trimmed
      expect(find.byType(InvestigatorCard), findsOneWidget);
      expect(find.text('1 match for "jhb"'), findsOneWidget);
    });

    testWidgets('pressing search on the keyboard searches straight away',
        (tester) async {
      final fake = await open(tester);
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'thabo');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(fake.searches, ['thabo']);

      // the delayed search was cancelled, so it does not run a second time
      await tester.pump(Investigators.searchDelay);
      await tester.pump();
      expect(fake.searches, ['thabo']);
    });

    testWidgets('clearing the search shows the recent list again',
        (tester) async {
      final fake = await open(tester);
      await tester.pump();
      await typeSearch(tester, 'jhb');

      await tester.tap(find.byTooltip('Clear search'));
      await tester.pump();
      await tester.pump();
      expect(fake.recentCalls, 2);
      expect(find.byType(InvestigatorCard), findsNWidgets(2));
      expect(find.text('Showing the 2 most recently added investigators'),
          findsOneWidget);
    });

    testWidgets('no matches shows a message', (tester) async {
      final fake = FakeSupabaseService()..searchResult = [];
      await open(tester, fake);
      await tester.pump();
      await typeSearch(tester, 'nobody');

      expect(find.byType(InvestigatorCard), findsNothing);
      expect(find.text('No investigators match your search.'), findsOneWidget);
    });

    testWidgets('an error shows a message, and Try again reloads',
        (tester) async {
      final fake = FakeSupabaseService()..fail = true;
      await open(tester, fake);
      await tester.pump();

      expect(find.text('Could not load investigators. Check your connection.'),
          findsOneWidget);
      expect(find.byType(InvestigatorCard), findsNothing);

      fake.fail = false;
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump();
      expect(fake.recentCalls, 2);
      expect(find.byType(InvestigatorCard), findsNWidgets(2));
    });
  });
}
