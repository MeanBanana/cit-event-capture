// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:argus_shield/argus_app.dart';

void main() {
  // Check that the citizen dashboard displays its three navigation tabs.
  testWidgets('Citizen dashboard displays all tabs',
          (WidgetTester tester) async {
        // Start the application in the test environment.
        await tester.pumpWidget(const ArgusApp());

        // Check the dashboard title.
        expect(find.text('Argus Shield'), findsOneWidget);

        // Check that each navigation tab is present.
        expect(
          find.widgetWithText(Tab, 'Upload'),
          findsOneWidget,
        );
        expect(
          find.widgetWithText(Tab, 'Submissions'),
          findsOneWidget,
        );
        expect(
          find.widgetWithText(Tab, 'Profile'),
          findsOneWidget,
        );
      });
}
