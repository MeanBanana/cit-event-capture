// The temporary password on the New investigator form.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:argus_shield/admin_screens/new_investigator_form.dart';
import 'package:argus_shield/temp_password.dart';

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1080, 4800); // tall: the whole form fits
    view.devicePixelRatio = 3.0;
  });
  tearDown(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  Future<List<NewInvestigatorDetails>> pumpForm(WidgetTester tester) async {
    final sent = <NewInvestigatorDetails>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: NewInvestigatorForm(onCreate: (d) async => sent.add(d)),
      ),
    ));
    return sent;
  }

  Future<void> fillDetails(WidgetTester tester) async {
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Thabo'); // first name
    await tester.enterText(fields.at(1), 'Mokoena'); // surname
    await tester.enterText(fields.at(2), 'tmokoena'); // username
    await tester.enterText(fields.at(3), 'thabo@saps.gov.za'); // email
    await tester.enterText(fields.at(6), 'JHB-1'); // badge number
    await tester.enterText(fields.at(7), 'Sandton SAPS'); // station
  }

  testWidgets('a temporary password is required', (tester) async {
    final sent = await pumpForm(tester);
    await fillDetails(tester);
    await tester.tap(find.text('Create investigator account'));
    await tester.pump();

    expect(find.text('Enter or generate a temporary password'), findsOneWidget);
    expect(sent, isEmpty);
  });

  testWidgets('Generate fills in a valid password, which is sent',
      (tester) async {
    final sent = await pumpForm(tester);
    await fillDetails(tester);
    await tester.tap(find.text('Generate'));
    await tester.pump();

    final field = tester.widget<TextFormField>(find.byKey(const Key('temp-password')));
    final password = field.controller!.text;
    expect(validateTempPassword(password), isNull);
    expect(find.text(password), findsOneWidget); // shown, to note down

    await tester.tap(find.text('Create investigator account'));
    await tester.pump();
    expect(sent.single.password, password);
    expect(sent.single.username, 'tmokoena');
  });
}
