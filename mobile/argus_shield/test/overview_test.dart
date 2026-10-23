// The admin Overview tab: the System status numbers and recent investigators
// should come from Supabase (faked here), not hard-coded sample data.
//
// The Active tile's border animates forever, so these use pump() rather than
// pumpAndSettle().

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:argus_shield/admin_screens/overview.dart';
import 'package:argus_shield/admin_screens/investigators.dart';
import 'package:argus_shield/admin_screens/submissions.dart';
import 'package:argus_shield/models/system_stats.dart';
import 'package:argus_shield/models/activity_item.dart';
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

  List<CrimeSceneSummary> submissions = [
    CrimeSceneSummary(
      incidentId: 31,
      location: 'N1 km 42, Midrand',
      dateTime: DateTime(2026, 10, 5, 9, 15),
      status: 'open',
      description: 'Cash van rammed at the toll plaza.',
      reportedBy: 4,
      reporterName: 'Sam Citizen',
    ),
    CrimeSceneSummary(
      incidentId: 30,
      location: 'R21 Kempton Park',
      dateTime: DateTime(2026, 10, 4, 18, 0),
      status: 'under_review',
      reportedBy: 4,
      reporterName: 'Sam Citizen',
      caseId: 1,
      reviewStatus: 'accepted',
    ),
  ];
  int? lastSubmissionLimit;

  @override
  Future<List<CrimeSceneSummary>> getRecentSubmissions(
      {int limit = 20, String? review}) async {
    lastSubmissionLimit = limit;
    if (fail) throw Exception('offline');
    return submissions;
  }

  List<ActivityItem> activity = [
    ActivityItem(
      tag: 'NEW',
      text: 'New citizen submission: INC-0031, N1 km 42, Midrand',
      at: DateTime.now().subtract(const Duration(hours: 2)),
    ),
    ActivityItem(
      tag: 'ASGN',
      text: 'Sgt. Thabo Mokoena assigned to CASE-0004',
      at: DateTime.now().subtract(const Duration(minutes: 45)),
    ),
  ];
  int? lastActivityLimit;

  @override
  Future<List<ActivityItem>> getRecentActivity({int limit = 5}) async {
    lastActivityLimit = limit;
    if (fail) throw Exception('offline');
    return activity;
  }

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
  // tall phone screen so the whole Overview list gets built
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

  test('ActivityItem.fromMap reads a recent_activity row', () {
    final a = ActivityItem.fromMap({
      'tag': 'CASE',
      'message': 'Case CASE-0004 created: Midrand toll plaza ramming',
      'occurredat': '2026-10-05T15:20:00+00:00',
    });
    expect(a.tag, 'CASE');
    expect(a.text, 'Case CASE-0004 created: Midrand toll plaza ramming');
    expect(a.at.isAtSameMomentAs(DateTime.utc(2026, 10, 5, 15, 20)), isTrue);
    expect(a.at.isUtc, isFalse); // shown in the phone's local time
  });

  testWidgets('recent activity comes from the database', (tester) async {
    final fake = FakeSupabaseService();
    await open(tester, fake);
    await tester.pump();

    expect(fake.lastActivityLimit, AdminOverview.recentActivityCount);
    expect(find.text('New citizen submission: INC-0031, N1 km 42, Midrand'),
        findsOneWidget);
    expect(find.text('2h ago'), findsOneWidget);
    expect(find.text('ASGN'), findsOneWidget);
    expect(find.text('45m ago'), findsOneWidget);
    // the old hard-coded sample events are gone
    expect(find.textContaining('INC-0042'), findsNothing);
    expect(find.textContaining('verified detection'), findsNothing);
  });

  testWidgets('no activity shows a message', (tester) async {
    final fake = FakeSupabaseService()..activity = [];
    await open(tester, fake);
    await tester.pump();

    expect(find.text('No activity yet.'), findsOneWidget);
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

  testWidgets('shows the newest submissions from the database',
      (tester) async {
    final fake = FakeSupabaseService();
    await open(tester, fake);
    await tester.pump();

    expect(fake.lastSubmissionLimit, AdminOverview.recentSubmissionCount);
    expect(find.text('N1 km 42, Midrand'), findsOneWidget);
    expect(find.text('Cash van rammed at the toll plaza.'), findsOneWidget);
    // pending review (with Reject / Accept) / already in a case
    expect(find.text('PENDING REVIEW'), findsOneWidget);
    expect(find.text('ADDED TO CASE-0001'), findsOneWidget);
    expect(find.text('Accept'), findsOneWidget); // only on the pending one
    expect(find.text('Reject'), findsOneWidget);
    expect(find.text('View'), findsNWidgets(2));
    // the old hard-coded sample incident is gone
    expect(find.textContaining('OR Tambo'), findsNothing);
  });

  testWidgets('no submissions shows a message', (tester) async {
    final fake = FakeSupabaseService()..submissions = [];
    await open(tester, fake);
    await tester.pump();

    expect(find.text('No incidents have been reported yet.'), findsOneWidget);
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
