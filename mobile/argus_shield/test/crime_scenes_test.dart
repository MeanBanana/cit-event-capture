// Tests for the crime scenes of a case (investigator case page), the crime
// scene page and correcting what the AI found. Uses CrimeSceneFakeService,
// which keeps everything in memory.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:argus_shield/admin_screens/crime_scene_card.dart';
import 'package:argus_shield/admin_screens/crime_scene_page.dart';
import 'package:argus_shield/admin_screens/entity_crops_page.dart';
import 'package:argus_shield/case_evidence_source.dart';
import 'package:argus_shield/models/case_evidence.dart';
import 'package:argus_shield/submission_evidence_source.dart';
import 'package:argus_shield/investigator_dashboard/investigator_case_detail.dart';
import 'package:argus_shield/theme/argus_widgets.dart';

import 'crime_scene_fake_service.dart';

Future<void> openScene(WidgetTester tester, CrimeSceneFakeService fake,
    {int incidentId = 42, bool settle = true}) async {
  await tester.pumpWidget(MaterialApp(
    home: CrimeScenePage(
      incidentId: incidentId,
      service: fake,
      refreshEvery: null, // no timers in tests
    ),
  ));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // a spinning progress indicator never settles
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Taps the tab whose label starts with [label] ("Findings" for
/// "Findings (3)").
Future<void> openTab(WidgetTester tester, String label,
    {bool settle = true}) async {
  final tab = find.descendant(
      of: find.byType(TabBar), matching: find.textContaining(label));
  // a tab that isn't fully on screen can't be tapped by a person either
  final box = tester.getRect(tab);
  final screen = tester.getRect(find.byType(TabBar));
  expect(box.left >= screen.left && box.right <= screen.right, isTrue,
      reason: 'the "$label" tab is not fully on screen');
  await tester.tap(tab);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }
}

/// Scrolls [finder] into view and taps it.
Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// A 1x1 transparent PNG, so pictures "load" in tests.
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// The submission's detection rows, as SubmissionEvidenceSource reads them.
class _RowsSource implements CaseEvidenceSource {
  _RowsSource(this.rows);
  final List<Map> rows;

  @override
  Future<CaseEvidence?> load(int incidentId) async => CaseEvidence.fromMap(
      buildSubmissionEvidence(incidentId, rows, {101: 1}, const {}));
  @override
  ImageProvider image(String path) => MemoryImage(_png);
  @override
  Future<Uint8List> bytes(String path) async => _png;
  @override
  Future<void> answer(int caseId, String memberKey, {required bool yes}) async {}
}

/// Opens the correction sheet of detection [id] (on the Findings tab).
Future<void> openCorrection(WidgetTester tester, int id) =>
    tapVisible(tester, find.byKey(ValueKey('correct-$id')));

void main() {
  setUp(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1080, 4800); // tall phone, 360 x 1600
    view.devicePixelRatio = 3.0;
  });
  tearDown(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  group('Investigator case page', () {
    CrimeSceneFakeService makeService() => CrimeSceneFakeService(
          cards: [
            fakeCardRow(42, suspects: 2, vehicles: 1, weapons: 1),
            fakeCardRow(43,
                status: 'pending',
                location: 'William Nicol Dr, Fourways',
                description: 'Shots fired at the guards.'),
          ],
          scenes: [fakeScene(42)],
        );

    Future<void> open(WidgetTester tester, CrimeSceneFakeService fake) async {
      await tester.pumpWidget(MaterialApp(
        home: InvestigatorCaseDetailPage(caseId: 3, service: fake),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('opens on the crime scenes: one card each, only key facts',
        (tester) async {
      final fake = makeService();
      await open(tester, fake);

      expect(fake.calls, contains('listCaseCrimeScenes:3'));
      // the crime scenes are the first tab: no scrolling past the AI summary
      expect(find.text('Scenes (2)'), findsOneWidget);
      expect(find.text('AI summary'), findsOneWidget);
      expect(find.text('Activity'), findsOneWidget);
      expect(find.byType(CaseSceneCard), findsNWidgets(2));

      // the analysed one: description, location, counts
      expect(find.text('Two men with a rifle stopped the cash van.'),
          findsOneWidget);
      expect(find.text('Rivonia Rd, Sandton'), findsOneWidget);
      expect(find.text('2 suspects'), findsOneWidget);
      expect(find.text('1 vehicle'), findsOneWidget);
      expect(find.text('1 weapon'), findsOneWidget);
      expect(find.text('ANALYSED'), findsOneWidget);

      // the one still waiting for the AI says so and has no counts yet
      expect(find.text('Shots fired at the guards.'), findsOneWidget);
      expect(find.text('WAITING FOR AI'), findsOneWidget);
      expect(find.text('Suspects: –'), findsOneWidget);
      expect(find.textContaining('1 crime scene still waiting for the AI'),
          findsOneWidget);

      // footage is on each crime scene's page, not the case page
      expect(find.textContaining('Clip 1'), findsNothing);
    });

    testWidgets('the case header shows the title and status action',
        (tester) async {
      await open(tester, makeService());
      expect(find.text('N1 Midrand CIT robbery'), findsOneWidget);
      expect(find.text('OPEN'), findsOneWidget);
      expect(find.byKey(const ValueKey('case-status-action')), findsOneWidget);
    });

    testWidgets('the activity tab shows the history', (tester) async {
      await open(tester, makeService());
      await openTab(tester, 'Activity');
      expect(find.text('No activity recorded yet.'), findsOneWidget);
      expect(find.byType(CaseSceneCard), findsNothing);
    });

    testWidgets('tapping a card opens that crime scene', (tester) async {
      final fake = makeService();
      await open(tester, fake);

      await tapVisible(tester, find.byKey(const ValueKey('scene-42')));

      expect(find.byType(CrimeScenePage), findsOneWidget);
      expect(fake.calls, contains('getCrimeScene:42'));
      expect(find.text('INC-0042'), findsOneWidget);
      expect(find.text('Part of CASE-0003 · N1 Midrand CIT robbery'),
          findsOneWidget);
      expect(find.text('Footage (1)'), findsOneWidget);
      expect(find.text('Findings (3)'), findsOneWidget);
      expect(find.text('Log (0)'), findsOneWidget);
    });

    testWidgets('an empty case says so', (tester) async {
      await open(tester, CrimeSceneFakeService());
      expect(find.text('Scenes (0)'), findsOneWidget);
      expect(find.text('No crime scenes are linked to this case yet.'),
          findsOneWidget);
    });
  });

  group('Crime scene page', () {
    testWidgets('opens on the footage, with the key facts above the tabs',
        (tester) async {
      final fake = CrimeSceneFakeService(scenes: [fakeScene(42)]);
      await openScene(tester, fake);

      // header: always visible
      expect(find.text('Two men with a rifle stopped the cash van.'),
          findsOneWidget);
      expect(find.text('Rivonia Rd, Sandton'), findsOneWidget);
      expect(find.text('1 suspect'), findsOneWidget);
      expect(find.text('1 vehicle'), findsOneWidget);
      expect(find.text('1 weapon'), findsOneWidget);

      // first tab: the footage (the scene's tag + the clip's own tag)
      expect(find.textContaining('Clip 1'), findsOneWidget);
      expect(find.text('ANALYSED'), findsNWidgets(2));
      expect(find.text('A man with a long gun next to a white car.'),
          findsOneWidget);
      expect(find.text('Vehicle 1'), findsNothing); // on the Findings tab
    });

    testWidgets('the findings tab lists what the AI found', (tester) async {
      final fake = CrimeSceneFakeService(scenes: [fakeScene(42)]);
      await openScene(tester, fake);
      await openTab(tester, 'Findings');

      expect(find.text('1 person with a long gun, 1 white Toyota.'),
          findsOneWidget);
      expect(find.text('Person 1'), findsOneWidget);
      expect(find.text('Top colour: black'), findsOneWidget);
      expect(find.text('Make: Toyota'), findsOneWidget);
      expect(find.text('Model: unknown'), findsOneWidget);
      expect(find.text('Number plate: ND123456'), findsOneWidget);
      expect(find.text('Weapon type: long gun'), findsOneWidget);
      for (final id in [11, 12, 13]) {
        expect(find.byKey(ValueKey('correct-$id')), findsOneWidget);
      }
      // the Correct buttons are the full-size secondary buttons
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('correct-12')),
              matching: find.byType(OutlinedButton)),
          findsOneWidget);
    });

    testWidgets('the log tab starts empty', (tester) async {
      await openScene(tester, CrimeSceneFakeService(scenes: [fakeScene(42)]));
      await openTab(tester, 'Log');
      expect(find.textContaining('No corrections yet.'), findsOneWidget);
    });

    testWidgets('while waiting for the AI: says so, nothing to correct',
        (tester) async {
      final fake =
          CrimeSceneFakeService(scenes: [fakeScene(42, status: 'pending')]);
      await openScene(tester, fake);

      expect(find.text('WAITING FOR AI'), findsOneWidget);
      expect(find.textContaining('waiting to be analysed by the AI'),
          findsOneWidget);

      await openTab(tester, 'Findings');
      expect(find.textContaining('Waiting for the AI to analyse this footage'),
          findsOneWidget);
      expect(find.byKey(const ValueKey('correct-12')), findsNothing);

      // "check again" loads the scene once more
      await tester.tap(find.byKey(const ValueKey('scene-refresh')));
      await tester.pumpAndSettle();
      expect(fake.calls.where((c) => c == 'getCrimeScene:42').length, 2);
    });

    testWidgets('while the AI is analysing: says so', (tester) async {
      final fake =
          CrimeSceneFakeService(scenes: [fakeScene(42, status: 'analysing')]);
      await openScene(tester, fake, settle: false);

      expect(find.text('AI ANALYSING'), findsOneWidget);
      expect(find.textContaining('analysing the footage right now'),
          findsOneWidget);
      await openTab(tester, 'Findings', settle: false);
      expect(find.textContaining('The AI is still analysing this footage'),
          findsOneWidget);
      expect(find.byKey(const ValueKey('correct-12')), findsNothing);
    });

    testWidgets('correcting a number plate saves it and logs it',
        (tester) async {
      final fake = CrimeSceneFakeService(scenes: [fakeScene(42)]);
      await openScene(tester, fake);
      await openTab(tester, 'Findings');

      await openCorrection(tester, 12);
      expect(find.text('CORRECT VEHICLE 1'), findsOneWidget);
      // the save button is the big login-style button
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('correct-save')),
              matching: find.byType(ElevatedButton)),
          findsOneWidget);
      expect(find.byType(PrimaryButton), findsOneWidget);

      await tapVisible(tester, find.byKey(const ValueKey('field-plate')));
      expect(find.text('AI said: ND123456'), findsOneWidget);
      await tester.enterText(
          find.byKey(const ValueKey('correct-value')), 'ND654321');
      await tester.enterText(
          find.byKey(const ValueKey('correct-note')), 'Clear in frame 210');
      await tapVisible(tester, find.byKey(const ValueKey('correct-save')));

      expect(fake.calls,
          contains('correct:12:plate:ND654321:Clear in frame 210'));
      expect(find.text('Vehicle 1: number plate corrected'), findsOneWidget);

      // still on Findings: the corrected value and what the AI said
      expect(find.text('Number plate: ND654321  (AI: ND123456)'),
          findsOneWidget);
      expect(find.text('CORRECTED'), findsOneWidget);

      // and in the log
      expect(find.text('Log (1)'), findsOneWidget);
      await openTab(tester, 'Log');
      expect(find.text('Vehicle 1 · Number plate: ND123456 → ND654321'),
          findsOneWidget);
      expect(find.text('“Clear in frame 210”'), findsOneWidget);
      expect(find.textContaining('Thabo Mokoena'), findsOneWidget);
    });

    testWidgets('an emptied value is saved as "none"', (tester) async {
      final fake = CrimeSceneFakeService(scenes: [fakeScene(42)]);
      await openScene(tester, fake);
      await openTab(tester, 'Findings');

      await openCorrection(tester, 12);
      await tapVisible(tester, find.byKey(const ValueKey('field-plate')));
      await tester.enterText(find.byKey(const ValueKey('correct-value')), '  ');
      await tapVisible(tester, find.byKey(const ValueKey('correct-save')));

      expect(fake.calls, contains('correct:12:plate::'));
      expect(find.text('Number plate: no readable plate  (AI: ND123456)'),
          findsOneWidget);
    });

    testWidgets('the weapon type is picked from a list', (tester) async {
      final fake = CrimeSceneFakeService(scenes: [fakeScene(42)]);
      await openScene(tester, fake);
      await openTab(tester, 'Findings');

      await openCorrection(tester, 13);
      expect(find.byKey(const ValueKey('correct-value')), findsNothing);
      await tapVisible(
          tester, find.byKey(const ValueKey('correct-weapon-type')));
      await tester.tap(find.text('handgun').last);
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const ValueKey('correct-save')));

      expect(fake.calls, contains('correct:13:weapon_type:handgun:'));
      expect(find.text('Weapon type: handgun  (AI: long gun)'), findsOneWidget);
    });

    testWidgets('a correction can be put back to the AI\'s value',
        (tester) async {
      final fake = CrimeSceneFakeService(scenes: [fakeScene(42)]);
      await openScene(tester, fake);
      await openTab(tester, 'Findings');

      await openCorrection(tester, 12);
      await tapVisible(tester, find.byKey(const ValueKey('field-make')));
      await tester.enterText(
          find.byKey(const ValueKey('correct-value')), 'Nissan');
      await tapVisible(tester, find.byKey(const ValueKey('correct-save')));
      expect(find.text('Make: Nissan  (AI: Toyota)'), findsOneWidget);

      await openCorrection(tester, 12);
      await tapVisible(tester, find.byKey(const ValueKey('field-make')));
      await tapVisible(tester, find.byKey(const ValueKey('correct-restore')));

      expect(fake.calls, contains('correct:12:make:Toyota:'));
      expect(find.text('Make: Toyota'), findsOneWidget);
    });

    testWidgets('marking something as not real needs a reason',
        (tester) async {
      final fake = CrimeSceneFakeService(scenes: [fakeScene(42)]);
      await openScene(tester, fake);
      await openTab(tester, 'Findings');

      await openCorrection(tester, 13);
      await tapVisible(tester, find.byKey(const ValueKey('correct-dismiss')));
      expect(find.textContaining('Say why this is not a real weapon'),
          findsOneWidget);
      expect(fake.calls.where((c) => c.startsWith('correct:')), isEmpty);

      await tester.enterText(
          find.byKey(const ValueKey('correct-note')), 'It is an umbrella');
      await tapVisible(tester, find.byKey(const ValueKey('correct-dismiss')));

      expect(
          fake.calls, contains('correct:13:dismissed:true:It is an umbrella'));
      expect(find.text('NOT REAL'), findsOneWidget);
      // the header no longer counts it
      expect(find.text('0 weapons'), findsOneWidget);

      // and it can be restored
      await openCorrection(tester, 13);
      await tapVisible(tester, find.byKey(const ValueKey('correct-undismiss')));
      expect(fake.calls, contains('correct:13:dismissed:false:'));
      expect(find.text('NOT REAL'), findsNothing);
      expect(find.text('1 weapon'), findsOneWidget);

      await openTab(tester, 'Log');
      expect(find.text('Weapon 1 marked as not real'), findsOneWidget);
      expect(find.text('Weapon 1 restored (it is real)'), findsOneWidget);
    });

    testWidgets('a refusal from the database is shown in the form',
        (tester) async {
      final fake = CrimeSceneFakeService(scenes: [fakeScene(42)])
        ..failWith = 'The AI is still working on the footage of INC-0042: '
            'corrections are possible once it has finished';
      await openScene(tester, fake);
      await openTab(tester, 'Findings');

      await openCorrection(tester, 11);
      await tester.enterText(
          find.byKey(const ValueKey('correct-value')), 'red');
      await tapVisible(tester, find.byKey(const ValueKey('correct-save')));

      expect(find.textContaining('The AI is still working on the footage'),
          findsOneWidget);
      // the sheet stays open so the investigator can try again
      expect(find.byKey(const ValueKey('correct-save')), findsOneWidget);
    });

    testWidgets('a closed case is read-only', (tester) async {
      final fake =
          CrimeSceneFakeService(scenes: [fakeScene(42, caseClosed: true)]);
      await openScene(tester, fake);
      await openTab(tester, 'Findings');

      expect(find.text('Vehicle 1'), findsOneWidget);
      expect(find.byKey(const ValueKey('correct-12')), findsNothing);
      expect(find.textContaining('The case is closed'), findsOneWidget);
    });

    testWidgets('a crime scene without footage says so', (tester) async {
      final scene = fakeScene(42, status: 'no_footage')
        ..['files'] = <Map<String, dynamic>>[]
        ..['analysis'] = {
          'status': 'no_footage',
          'files': 0,
          'done': 0,
          'failed': 0,
        };
      await openScene(tester, CrimeSceneFakeService(scenes: [scene]));

      expect(find.text('NO FOOTAGE'), findsOneWidget);
      // the header banner and the empty Footage tab
      expect(find.text('No footage was sent with this report.'),
          findsNWidgets(2));
    });

    testWidgets('the header counts like the crime scene card', (tester) async {
      // Clip 1: two possible suspects, one confirmed, a guard dismissed as a
      // suspect and someone marked "not a real person". Clip 2: one possible
      // suspect (perhaps the same person again) and a vehicle in each clip.
      Map<String, dynamic> who(int id, int number, int clip, String status,
              {bool dismissed = false}) =>
          fakeDetection(id, 'person', number, {'upper_clothing': 'black'},
              clip: clip)
            ..['suspect_status'] = status
            ..['dismissed'] = dismissed;
      final scene = fakeScene(42, detections: [
        who(1, 1, 1, 'possible'),
        who(2, 2, 1, 'possible'),
        who(3, 3, 1, 'confirmed'),
        who(4, 4, 1, 'dismissed'),
        who(5, 5, 1, 'possible', dismissed: true),
        who(6, 6, 2, 'possible'),
        fakeDetection(7, 'vehicle', 1, {'make': 'Toyota'}, clip: 1),
        fakeDetection(8, 'vehicle', 2, {'make': 'Toyota'}, clip: 2),
      ]);
      scene['files'] = [
        for (final n in [1, 2])
          {
            'media_id': 100 + n,
            'number': n,
            'media_type': 'video',
            'storage_path': '42/media/clip$n.mp4',
            'status': 'completed',
          },
      ];
      await openScene(tester, CrimeSceneFakeService(scenes: [scene]));

      // list_case_crime_scenes: the most in one clip, possible or
      // confirmed, without dismissed ones -> 3 suspects, 1 vehicle
      expect(find.text('3 suspects'), findsOneWidget);
      expect(find.text('1 vehicle'), findsOneWidget);
      expect(find.text('0 weapons'), findsOneWidget);
    });

    testWidgets('keeps checking after one failed check while the AI is busy',
        (tester) async {
      const every = Duration(seconds: 20);
      final fake =
          CrimeSceneFakeService(scenes: [fakeScene(42, status: 'analysing')]);
      await tester.pumpWidget(MaterialApp(
        home: CrimeScenePage(incidentId: 42, service: fake, refreshEvery: every),
      ));
      await tester.pump();
      expect(find.text('AI ANALYSING'), findsOneWidget);

      fake.failLoads = 1; // the next check has no network
      await tester.pump(every);
      await tester.pump();
      expect(fake.calls.where((c) => c.startsWith('getCrimeScene')).length, 2);
      expect(find.text('AI ANALYSING'), findsOneWidget); // still shows what it knew

      fake.scenes[42] = fakeScene(42); // meanwhile the AI finished
      await tester.pump(every);
      await tester.pump();
      expect(fake.calls.where((c) => c.startsWith('getCrimeScene')).length, 3);
      expect(find.text('ANALYSED'), findsWidgets);

      // done: no more checks
      await tester.pump(every * 3);
      expect(fake.calls.where((c) => c.startsWith('getCrimeScene')).length, 3);
    });

    testWidgets('a failed first load does not keep checking', (tester) async {
      const every = Duration(seconds: 20);
      final fake =
          CrimeSceneFakeService(scenes: [fakeScene(42, status: 'analysing')])
            ..failLoads = 1;
      await tester.pumpWidget(MaterialApp(
        home: CrimeScenePage(incidentId: 42, service: fake, refreshEvery: every),
      ));
      await tester.pump();
      expect(find.textContaining('Could not load this crime scene'),
          findsOneWidget);
      await tester.pump(every * 2);
      expect(fake.calls, ['getCrimeScene:42']);
    });
  });

  group('Pictures of a finding', () {
    // Three people in one clip: one with no first-seen time, two seen at the
    // same moment. get_crime_scene numbers them 31, 32, 33 (unknown time
    // first, then by detection id); the rows reach the pictures page in
    // another order.
    Map<String, dynamic> sceneDetection(
            int id, int number, double? seen, String top) =>
        fakeDetection(id, 'person', number,
            {'upper_clothing': top, 'lower_clothing': 'blue'})
          ..['first_seen'] = seen
          ..['crops'] = [
            {'path': '42/ai/run/1_clip/person_$id.png', 'type': 'person'},
          ];
    Map row(int id, double? seen, String top) => {
          'detectionid': id,
          'mediaid': 101,
          'detectiontype': 'person',
          'trackid': id,
          'firstseen': seen,
          'attributes': {
            'upper_clothing': top,
            'lower_clothing': 'blue',
            'face_visible': true,
          },
          'crops': [
            {'path': '42/ai/run/1_clip/person_$id.png', 'type': 'person'},
          ],
        };

    Future<void> openPicturesOf(WidgetTester tester, int detectionId) async {
      final fake = CrimeSceneFakeService(scenes: [
        fakeScene(42, detections: [
          sceneDetection(31, 1, null, 'red'),
          sceneDetection(32, 2, 5.0, 'green'),
          sceneDetection(33, 3, 5.0, 'yellow'),
        ]),
      ]);
      final source = _RowsSource([
        row(33, 5.0, 'yellow'),
        row(32, 5.0, 'green'),
        row(31, null, 'red'),
      ]);
      await tester.pumpWidget(MaterialApp(
        home: CrimeScenePage(
          incidentId: 42,
          service: fake,
          pictures: source,
          detectionPictures: source,
          refreshEvery: null,
        ),
      ));
      await tester.pumpAndSettle();
      await openTab(tester, 'Findings');
      await tapVisible(
          tester,
          find.descendant(
              of: find.byKey(ValueKey('detection-$detectionId')),
              matching: find.text('Pictures')));
      expect(find.byType(EntityCropsPage), findsOneWidget);
    }

    testWidgets('a person with no first-seen time opens their own pictures',
        (tester) async {
      await openPicturesOf(tester, 31);
      expect(find.text('Person 1'), findsOneWidget);
      expect(find.textContaining('top red'), findsOneWidget);
    });

    testWidgets('people seen at the same moment open their own pictures',
        (tester) async {
      await openPicturesOf(tester, 33);
      expect(find.text('Person 3'), findsOneWidget);
      expect(find.textContaining('top yellow'), findsOneWidget);
    });

    testWidgets('no Pictures button without a pictures source',
        (tester) async {
      await openScene(tester, CrimeSceneFakeService(scenes: [fakeScene(42)]));
      await openTab(tester, 'Findings');
      expect(find.text('Pictures'), findsNothing);
    });
  });
}
