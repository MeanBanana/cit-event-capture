// What happens after you press the login button. Uses a fake SupabaseService
// so no network or Supabase project is needed.
//
// After the button the LoadingScreen shows a message for 3 seconds, then
// opens the next screen. Each test checks the message first (logIn), then
// lets the 3 seconds run out (finishLoading).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:argus_shield/login.dart';
import 'package:argus_shield/reset_password.dart';
import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/citizen/citizen_dashboard.dart';
import 'package:argus_shield/admin_screens/admin_dashboard.dart';
import 'package:argus_shield/investigator_dashboard/investigator_dashboard.dart';

/// Hands back a canned login result instead of calling Supabase.
class FakeSupabaseService extends SupabaseService {
  FakeSupabaseService(this.result);

  final Map<String, dynamic> result;
  int loginCalls = 0;
  int logoutCalls = 0;
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

  @override
  Future<void> logout() async {
    logoutCalls++;
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
  // phone-sized screen (360 x 800 logical pixels) so the login form fits
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

  /// Fill in the form, press the button, and stop while the loading screen
  /// is showing its message.
  Future<void> logIn(WidgetTester tester, FakeSupabaseService service,
      {String username = 'thandi', String password = 'secret123'}) async {
    await tester.pumpWidget(MaterialApp(home: LoginPage(service: service)));
    await tester.enterText(find.byType(TextField).at(0), username);
    await tester.enterText(find.byType(TextField).at(1), password);
    await tester.tap(find.text('Access System'));
    await tester.pump(); // run the (fake) login and start the navigation
    await tester.pump(const Duration(milliseconds: 500)); // page transition
  }

  /// Let the loading screen's 3 seconds pass and the next screen open.
  /// Fixed pumps rather than pumpAndSettle, because the admin Overview has a
  /// border that animates forever and would never settle.
  Future<void> finishLoading(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3)); // loading delay ends
    await tester.pump(); // start the page transition
    await tester.pump(const Duration(seconds: 1)); // finish the transition
    await tester.pump(); // remove the loading screen
  }

  testWidgets('a citizen is taken to the citizen dashboard', (tester) async {
    final service = FakeSupabaseService(successFor('citizen'));
    await logIn(tester, service);
    expect(find.text('Welcome Thandi'), findsOneWidget);

    await finishLoading(tester);
    expect(service.loginCalls, 1);
    expect(service.lastUsername, 'thandi');
    expect(find.byType(CitizenDashboard), findsOneWidget);
    expect(find.byType(LoginPage), findsNothing);
    expect(find.text('Upload'), findsOneWidget);
    expect(find.text('Submissions'), findsOneWidget);
    expect(find.text('Profile'), findsOneWidget);
  });

  testWidgets('an admin is taken to the admin dashboard', (tester) async {
    final service = FakeSupabaseService(successFor('admin'));
    await logIn(tester, service);
    expect(find.text('Welcome Thandi'), findsOneWidget);

    await finishLoading(tester);
    expect(find.byType(AdminDashboard), findsOneWidget);
    expect(find.text('SYSTEM ADMINISTRATOR'), findsOneWidget);
    expect(find.byType(CitizenDashboard), findsNothing);
    expect(find.byType(LoginPage), findsNothing);
    expect(service.logoutCalls, 0);
  });

  for (final role in ['citizen', 'admin']) {
    testWidgets('$role: the login page is replaced, so Back does not return to it',
        (tester) async {
      await logIn(tester, FakeSupabaseService(successFor(role)));
      await finishLoading(tester);

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      expect(navigator.canPop(), isFalse);
    });
  }

  testWidgets('an investigator is taken to the investigator dashboard',
      (tester) async {
    final service = FakeSupabaseService(successFor('investigator'));
    await logIn(tester, service);
    expect(find.text('Welcome Thandi'), findsOneWidget);

    await finishLoading(tester);
    expect(find.byType(InvestigatorDashboard), findsOneWidget);
    expect(find.byType(CitizenDashboard), findsNothing);
    expect(find.byType(AdminDashboard), findsNothing);
    expect(find.byType(LoginPage), findsNothing);
    expect(service.logoutCalls, 0);
  });

  for (final role in ['admin', 'investigator']) {
    testWidgets('$role on a temporary password must choose a password first',
        (tester) async {
      final service = FakeSupabaseService(
          {...successFor(role), "mustChangePassword": true});
      await logIn(tester, service);
      expect(find.text('Please choose your own password'), findsOneWidget);

      await finishLoading(tester);
      expect(find.byType(ResetPasswordPage), findsOneWidget);
      expect(find.text('Choose Password'), findsOneWidget);
      expect(find.byType(AdminDashboard), findsNothing);
      expect(find.byType(InvestigatorDashboard), findsNothing);
      // no way Back to the dashboard or the login page
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      expect(navigator.canPop(), isFalse);
    });
  }

  testWidgets('an unknown role is signed out again', (tester) async {
    final service = FakeSupabaseService(successFor('visitor'));
    await logIn(tester, service);
    expect(service.logoutCalls, 1);
    expect(find.text('This account has no dashboard. Contact an administrator.'),
        findsOneWidget);

    await finishLoading(tester);
    expect(find.byType(CitizenDashboard), findsNothing);
    expect(find.byType(LoginPage), findsOneWidget);
  });

  testWidgets('a failed login returns to the login page with the error',
      (tester) async {
    await logIn(
      tester,
      FakeSupabaseService({
        "success": false,
        "message": "Username or password is incorrect. Please check again.",
      }),
    );
    expect(find.text('Username or password is incorrect. Please check again.'),
        findsOneWidget);

    await finishLoading(tester);
    expect(find.byType(CitizenDashboard), findsNothing);
    expect(find.byType(AdminDashboard), findsNothing);
    expect(find.byType(LoginPage), findsOneWidget);
  });

  testWidgets('empty fields do not call Supabase', (tester) async {
    final service = FakeSupabaseService(successFor('citizen'));
    await logIn(tester, service, username: '   ', password: '');
    // stays on the login page with "required" under both fields
    expect(find.text('Username is required'), findsOneWidget);
    expect(find.text('Password is required.'), findsOneWidget);

    await finishLoading(tester);
    expect(service.loginCalls, 0);
    expect(find.byType(CitizenDashboard), findsNothing);
    expect(find.byType(LoginPage), findsOneWidget);
  });
}
