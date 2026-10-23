// Investigator case chat: messages render (others on the left with names,
// mine on the right), sending works, live updates come in, closed cases are
// read-only, and the tab fits on a phone next to the other three.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:argus_shield/investigator_dashboard/case_chat_tab.dart';
import 'package:argus_shield/investigator_dashboard/investigator_case_detail.dart';
import 'package:argus_shield/models/case_message.dart';

import 'crime_scene_fake_service.dart';

class FakeChatService extends CrimeSceneFakeService {
  FakeChatService({super.caseStatus});

  final List<CaseMessage> messages = [];
  final List<String> sent = [];
  void Function()? onNew;
  bool stopped = false;
  int _nextId = 1;

  CaseMessage add(String body, {bool mine = false, String name = 'Bob Naidoo',
      int sender = 7, DateTime? at}) {
    final m = CaseMessage(
      messageId: _nextId++, caseId: 3, senderId: mine ? 5 : sender,
      senderName: mine ? 'Alice Mokoena' : name, isMine: mine, body: body,
      sentAt: at ?? DateTime.now(),
    );
    messages.add(m);
    return m;
  }

  @override
  Future<List<CaseMessage>> getCaseMessages(int caseId,
          {int? afterId, int limit = 200}) async =>
      [for (final m in messages) if (afterId == null || m.messageId > afterId) m];

  @override
  Future<CaseMessage> sendCaseMessage(int caseId, String body) async {
    sent.add(body);
    return add(body, mine: true);
  }

  @override
  void Function() watchCaseMessages(int caseId, void Function() onNewMessage) {
    onNew = onNewMessage;
    return () => stopped = true;
  }
}

Future<void> pumpChat(WidgetTester tester, FakeChatService fake,
    {bool readOnly = false}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: CaseChatTab(caseId: 3, service: fake, readOnly: readOnly),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the chat: names on others\' messages, mine on the right',
      (tester) async {
    final fake = FakeChatService()
      ..add('Suspect vehicle seen on the R21')
      ..add('Silver Polo, no plates', )
      ..add('On my way', mine: true);
    await pumpChat(tester, fake);

    expect(find.text('Suspect vehicle seen on the R21'), findsOneWidget);
    expect(find.text('On my way'), findsOneWidget);
    // the name once above Bob's two messages in a row, never on mine
    expect(find.text('Bob Naidoo'), findsOneWidget);
    expect(find.text('Alice Mokoena'), findsNothing);
    expect(find.text('Today'), findsOneWidget);

    final mine = tester.getCenter(find.text('On my way'));
    final theirs = tester.getCenter(find.text('Silver Polo, no plates'));
    expect(mine.dx, greaterThan(theirs.dx));
  });

  testWidgets('sending adds the message and clears the box', (tester) async {
    final fake = FakeChatService();
    await pumpChat(tester, fake);
    expect(find.textContaining('No messages yet'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('chat-input')), '  Roadblock set up  ');
    await tester.tap(find.byKey(const ValueKey('chat-send')));
    await tester.pumpAndSettle();

    expect(fake.sent, ['Roadblock set up']);
    expect(find.text('Roadblock set up'), findsOneWidget);
    final box = tester.widget<TextField>(find.byKey(const ValueKey('chat-input')));
    expect(box.controller!.text, isEmpty);

    // an empty message isn't sent
    await tester.tap(find.byKey(const ValueKey('chat-send')));
    await tester.pumpAndSettle();
    expect(fake.sent, hasLength(1));
  });

  testWidgets('messages from other investigators appear by themselves',
      (tester) async {
    final fake = FakeChatService()..add('First');
    await pumpChat(tester, fake);
    expect(fake.onNew, isNotNull);

    fake.add('Shots fired at the depot', name: 'Carel Botha', sender: 9);
    fake.onNew!();                       // what Realtime does
    await tester.pumpAndSettle();

    expect(find.text('Shots fired at the depot'), findsOneWidget);
    expect(find.text('Carel Botha'), findsOneWidget);
    // a repeated notification doesn't show it twice
    fake.onNew!();
    await tester.pumpAndSettle();
    expect(find.text('Shots fired at the depot'), findsOneWidget);

    // leaving the page stops the live connection
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(fake.stopped, isTrue);
  });

  testWidgets('a closed case\'s chat is read-only', (tester) async {
    final fake = FakeChatService()..add('Case closed, thanks all');
    await pumpChat(tester, fake, readOnly: true);
    expect(find.text('Case closed, thanks all'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-input')), findsNothing);
    expect(find.textContaining('read-only'), findsOneWidget);
  });

  testWidgets('the Chat tab fits on a phone next to the other tabs',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);   // 360 x 780 phone
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final fake = FakeChatService()..add('Hello team');
    await tester.pumpWidget(MaterialApp(
      home: InvestigatorCaseDetailPage(caseId: 3, service: fake),
    ));
    await tester.pumpAndSettle();

    final bar = tester.getRect(find.byType(TabBar));
    for (final label in ['Scenes (0)', 'AI summary', 'Activity', 'Chat']) {
      final tab = tester.getRect(find.descendant(
          of: find.byType(TabBar), matching: find.text(label)));
      expect(tab.left >= bar.left && tab.right <= bar.right, isTrue,
          reason: '"$label" is not fully on screen');
    }

    await tester.tap(find.text('Chat'));
    await tester.pumpAndSettle();
    expect(find.text('Hello team'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-input')), findsOneWidget);
  });
}
