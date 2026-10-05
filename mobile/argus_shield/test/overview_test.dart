// Tests for the admin Overview tab: the SYSTEM STATUS numbers and the
// recent investigators come from Supabase (a fake here), not sample data.
//
// Note: the Active tile's border animates forever, so these tests use
// pump() instead of pumpAndSettle().

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:argus_shield/admin_screens/overview.dart';
import 'package:argus_shield/admin_screens/investigators.dart';
import 'package:argus_shield/models/system_stats.dart';
import 'package:argus_shield/supabase_service.dart';

class FakeSupabaseService extends SupabaseService {
  bool fail = false;
  int? lastLimit;
  List<InvestigatorSummary> investigators = const [
    InvestigatorSummary(
      userId: 1,
      firstName: 'Thabo',
      surname: 'Mokoena',
      badgeNumber: 'JHB-4471',
      station: 'Kempton Park SAPS',
      dutyStatus: 'on_duty',
      email: 'thabo@argus.test',
      activeCases: 3,
    ),
  ];

  @override
  Future<SystemStats> getAdminStats() async {
    if (fail) throw Exception('offline');
    return const SystemStats(
        totalCases: 7, activeCases: 4, pendingCases: 2, investigators: 5);
  }

  @override
  Future<List<InvestigatorSummary>> getRecentInvestigators(
      {int limit = 20}) async {
    lastLimit = limit;
    if (fail) throw Exception('offline');
    return investigators;
  }
}

void main() {
  // A tall phone screen so the whole Overview list is built.
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

  Future<void> open(WidgetTester tester, FakeSupabaseService fake) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(body: AdminOverview(service: fake)),
      ));

  test('SystemStats.fromMap reads an admin_overview_stats row', () {
    final s = SystemStats.fromMap({
      'totalcases': 7,
      'activecases': 4,
      'pendingcases': 2,
      'investigators': 5,
    });
    expect([s.totalCases, s.activeCases, s.pendingCases, s.investigators],
        [7, 4, 2, 5]);
  });

  testWidgets('tiles show "—" while loading, then the live numbers',
      (tester) async {
    final fake = FakeSupabaseService();
    await open(tester, fake);
    expect(find.text('—'), findsNWidgets(4));

    await tester.pump();
    expect(find.text('—'), findsNothing);
    expect(find.text('7'), findsOneWidget); // total
    expect(find.text('4'), findsOneWidget); // active
    expect(find.text('2'), findsOneWidget); // pending
    expect(find.text('5'), findsOneWidget); // investigators
  });

  testWidgets('shows the newest investigators from the database',
      (tester) async {
    final fake = FakeSupabaseService();
    await open(tester, fake);
    await tester.pump();

    expect(fake.lastLimit, AdminOverview.recentInvestigatorCount);
    expect(find.text('Thabo Mokoena'), findsOneWidget);
    expect(find.text('● ON DUTY · CASES: 3'), findsOneWidget);
    // the old hard-coded sample investigator is gone
    expect(find.text('Sgt. Anri Pieterse'), findsNothing);
  });

  testWidgets('no investigators shows a message', (tester) async {
    final fake = FakeSupabaseService()..investigators = const [];
    await open(tester, fake);
    await tester.pump();

    expect(find.text('No investigators have been added yet.'), findsOneWidget);
  });

  testWidgets('an error shows a message and leaves the tiles as "—"',
      (tester) async {
    final fake = FakeSupabaseService()..fail = true;
    await open(tester, fake);
    await tester.pump();

    expect(find.text('Could not load live data. Pull down to try again.'),
        findsOneWidget);
    expect(find.text('—'), findsNWidgets(4));
  });
}
