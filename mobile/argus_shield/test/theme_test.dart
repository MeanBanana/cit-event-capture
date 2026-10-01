// Renders every screen with the real Argus theme on a phone-sized screen.
// Fails if the theme is broken or a page overflows (yellow/black stripes).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:argus_shield/login.dart';
import 'package:argus_shield/register_citizen.dart';
import 'package:argus_shield/loadingscreen.dart';
import 'package:argus_shield/citizen/citizen_home.dart';
import 'package:argus_shield/theme/app_theme.dart';

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1080, 2400); // 360 x 800 logical pixels
    view.devicePixelRatio = 3.0;
  });
  tearDown(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  Future<void> pumpThemed(WidgetTester tester, Widget home) async {
    await tester.pumpWidget(MaterialApp(theme: buildArgusTheme(), home: home));
    await tester.pumpAndSettle();
  }

  testWidgets('login page uses the theme', (tester) async {
    await pumpThemed(tester, const LoginPage());

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, isNull); // comes from the theme
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).scaffoldBackgroundColor,
      AppColors.background,
    );
    expect(find.text('Argus Shield'), findsOneWidget);
    expect(find.text('CIT Intelligence System'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('register page renders', (tester) async {
    await pumpThemed(tester, const RegisterPage());
    expect(find.text('Register Account'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('citizen dashboard tabs all render', (tester) async {
    await pumpThemed(tester, const CitizenHome());
    expect(find.text('CITIZEN'), findsOneWidget);
    expect(find.text('Submit footage'), findsOneWidget);

    await tester.tap(find.text('Submissions'));
    await tester.pumpAndSettle();
    expect(find.text('My submissions'), findsOneWidget);

    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();
    expect(find.text('My profile'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('loading screen renders', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildArgusTheme(),
      home: const LoadingScreen(
        resultMessage: 'User successfully registered. You can now log in.',
        nextScreen: SizedBox(),
      ),
    ));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.takeException(), isNull);
    // let the 3 second redirect timer finish so the test ends cleanly
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
  });
}
