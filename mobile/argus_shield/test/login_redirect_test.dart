// Tests for what happens after the login button is pressed.
//
// A fake SupabaseService stands in for the real one, so these tests run
// without a network connection or a Supabase project.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:argus_shield/login.dart';
import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/citizen/citizen_dashboard.dart';

/// Returns a canned login result instead of calling Supabase.
class FakeSupabaseService extends SupabaseService {
  FakeSupabaseService(this.result);

  final Map<String, dynamic> result;
  int loginCalls = 0;
  String? lastUsername;

  @override
  Future<Map<String, dynamic>> loginUser({
    required String username,
    required String password,
  }) async {
    loginCalls++;
    lastUsername = username;
    return result;
  }
}

Map<String, dynamic> successFor(String role) => {
      "success": true,
      "message": "Welcome Thandi",
      "profile": {
        "userid": 7,
        "username": "thandi",
        "firstname": "Thandi",
        "surname": "Nkosi",
        "role": role,
      },
    };

void main() {
  // A phone-sized screen (360 x 800 logical pixels) so the login form fits.
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1080, 2400);
    view.devicePixelRatio = 3.0;
  });
  tearDown(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  Future<void> logIn(WidgetTester tester, FakeSupabaseService service,
      {String username = 'thandi', String password = 'secret123'}) async {
    await tester.pumpWidget(MaterialApp(home: LoginPage(service: service)));
    await tester.enterText(find.byType(TextField).at(0), username);
    await tester.enterText(find.byType(TextField).at(1), password);
    await tester.tap(find.text('Access System'));
    await tester.pumpAndSettle();
  }

  testWidgets('a citizen is taken to the citizen dashboard', (tester) async {
    final service = FakeSupabaseService(successFor('citizen'));
    await logIn(tester, service);

    expect(service.loginCalls, 1);
    expect(service.lastUsername, 'thandi');
    expect(find.byType(CitizenDashboard), findsOneWidget);
    expect(find.byType(LoginPage), findsNothing);
    expect(find.text('Upload'), findsOneWidget);
    expect(find.text('Submissions'), findsOneWidget);
    expect(find.text('Profile'), findsOneWidget);
    expect(find.text('Welcome Thandi'), findsOneWidget);
  });

  testWidgets('the login page is replaced, so back does not return to it',
      (tester) async {
    await logIn(tester, FakeSupabaseService(successFor('citizen')));

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    expect(navigator.canPop(), isFalse);
  });

  for (final role in ['investigator', 'admin']) {
    testWidgets('a(n) $role is NOT sent to the citizen dashboard',
        (tester) async {
      await logIn(tester, FakeSupabaseService(successFor(role)));

      expect(find.byType(CitizenDashboard), findsNothing);
      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.text('Welcome Thandi (logged in as $role)'), findsOneWidget);
    });
  }

  testWidgets('a failed login stays on the login page with the error',
      (tester) async {
    await logIn(
      tester,
      FakeSupabaseService({
        "success": false,
        "message": "Invalid username or password.",
      }),
    );

    expect(find.byType(CitizenDashboard), findsNothing);
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.text('Invalid username or password.'), findsOneWidget);
  });

  testWidgets('empty fields do not call Supabase', (tester) async {
    final service = FakeSupabaseService(successFor('citizen'));
    await logIn(tester, service, username: '   ', password: '');

    expect(service.loginCalls, 0);
    expect(find.byType(CitizenDashboard), findsNothing);
    expect(find.text('Enter your username and password'), findsOneWidget);
  });
}
