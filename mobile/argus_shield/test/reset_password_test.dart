// The "New Password" screen opened by the reset link. Uses a fake
// SupabaseService so no network or Supabase project is needed.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:argus_shield/login.dart';
import 'package:argus_shield/reset_password.dart';
import 'package:argus_shield/supabase_service.dart';

/// Hands back a canned updatePassword result instead of calling Supabase.
class FakeResetService extends SupabaseService {
  FakeResetService([this.result = const {
    "success": true,
    "message": "Password changed, please log in",
  }]);

  final Map<String, dynamic> result;
  final List<String> passwordsSent = [];
  int logoutCalls = 0;

  @override
  Future<Map<String, dynamic>> updatePassword(String newPassword) async {
    passwordsSent.add(newPassword);
    return result;
  }

  @override
  Future<void> logout() async {
    logoutCalls++;
  }
}

void main() {
  // phone-sized screen (360 x 800 logical pixels) so the form fits
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

  Future<void> openPage(WidgetTester tester, FakeResetService service) =>
      tester.pumpWidget(MaterialApp(home: ResetPasswordPage(service: service)));

  Future<void> fillIn(WidgetTester tester, String password, String confirm) async {
    await tester.enterText(find.byType(TextFormField).at(0), password);
    await tester.enterText(find.byType(TextFormField).at(1), confirm);
    await tester.tap(find.text('Save Password'));
    await tester.pump();
  }

  /// Let the loading screen's 3 seconds pass and the login page open.
  Future<void> finishLoading(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
  }

  testWidgets('shows the new password form', (tester) async {
    await openPage(tester, FakeResetService());
    expect(find.text('New Password'), findsOneWidget);
    expect(find.text('New password'), findsOneWidget);
    expect(find.text('Confirm new password'), findsOneWidget);
    expect(find.text('Save Password'), findsOneWidget);
  });

  testWidgets('passwords that do not match are not sent', (tester) async {
    final service = FakeResetService();
    await openPage(tester, service);
    await fillIn(tester, 'secret123', 'secret124');

    expect(find.text('Passwords do not match'), findsOneWidget);
    expect(service.passwordsSent, isEmpty);
    expect(service.logoutCalls, 0);
  });

  testWidgets('a password that is too short is not sent', (tester) async {
    final service = FakeResetService();
    await openPage(tester, service);
    await fillIn(tester, 'abc', 'abc');

    expect(find.text('Use at least 6 characters'), findsOneWidget);
    expect(service.passwordsSent, isEmpty);
  });

  testWidgets('a saved password signs out and returns to the login page',
      (tester) async {
    final service = FakeResetService();
    await openPage(tester, service);
    await fillIn(tester, 'newSecret1', 'newSecret1');
    await tester.pump(); // logout + navigation

    expect(service.passwordsSent, ['newSecret1']);
    expect(service.logoutCalls, 1);
    expect(find.text('Password changed, please log in'), findsOneWidget);

    await finishLoading(tester);
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.byType(ResetPasswordPage), findsNothing);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    expect(navigator.canPop(), isFalse);
  });

  testWidgets('an error from Supabase is shown and the user stays signed in',
      (tester) async {
    final service = FakeResetService(const {
      "success": false,
      "message": "This reset link has expired. Please request a new one.",
    });
    await openPage(tester, service);
    await fillIn(tester, 'newSecret1', 'newSecret1');
    await tester.pump();

    expect(find.text('This reset link has expired. Please request a new one.'),
        findsOneWidget);
    expect(service.logoutCalls, 0);
    expect(find.byType(ResetPasswordPage), findsOneWidget);
  });

  testWidgets('Cancel signs out and returns to the login page', (tester) async {
    final service = FakeResetService();
    await openPage(tester, service);
    await tester.tap(find.text('Cancel'));
    await tester.pump(); // run the (fake) logout
    await tester.pump(); // start the navigation to the loading screen

    expect(service.logoutCalls, 1);
    expect(service.passwordsSent, isEmpty);
    expect(find.text('Password not changed'), findsOneWidget);

    await finishLoading(tester);
    expect(find.byType(LoginPage), findsOneWidget);
  });
}
