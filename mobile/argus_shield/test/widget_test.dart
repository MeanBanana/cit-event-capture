// Basic smoke tests for the Argus Shield screens.
//
// These only build the screens - they do not talk to Supabase, so they can run
// without a network connection.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:argus_shield/login.dart';
import 'package:argus_shield/register_citizen.dart';

void main() {
  testWidgets('Login page shows the login form', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginPage()));

    expect(find.text('Login'), findsOneWidget);
    expect(find.text('Access System'), findsOneWidget);
    expect(find.text('Register as citizen'), findsOneWidget);
  });

  testWidgets('Register page shows the registration form', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: RegisterPage()));

    expect(find.text('Register as citizen'), findsOneWidget);
    expect(find.text('Register Account'), findsOneWidget);
  });
}
