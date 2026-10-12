// The submission page's AI SUMMARY: detection rows -> the same shape as a
// case's evidence (one line per person / vehicle / weapon with View crops,
// which clip it is in, who held which weapon).

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:argus_shield/admin_screens/case_evidence_section.dart';
import 'package:argus_shield/case_evidence_source.dart';
import 'package:argus_shield/models/case_evidence.dart';
import 'package:argus_shield/submission_evidence_source.dart';

final _rows = <Map>[
  {
    'detectionid': 12, 'mediaid': 7, 'detectiontype': 'weapon', 'trackid': 2,
    'firstseen': 2.5, 'attributes': {'class_name': 'long_gun', 'weapon_confidence': 0.9},
    'crops': [{'path': '57/ai/r/1_clip/weapon_2.png', 'type': 'weapon'}],
  },
  {
    'detectionid': 11, 'mediaid': 7, 'detectiontype': 'person', 'trackid': 1,
    'firstseen': 1.0,
    'attributes': {'upper_clothing': 'white', 'upper_clothing_confidence': 0.8,
                   'lower_clothing': 'black', 'face_visible': true},
    'crops': [
      {'path': '57/ai/r/1_clip/person_1.png', 'type': 'person'},
      {'path': '57/ai/r/1_clip/face_1.png', 'type': 'face'},
    ],
  },
  {
    'detectionid': 13, 'mediaid': 8, 'detectiontype': 'vehicle', 'trackid': 3,
    'firstseen': 0.0,
    'attributes': {'class_name': 'car', 'make': 'Toyota', 'colour': 'white',
                   'plate': 'ND123456', 'plate_confidence': 0.85},
    'crops': [{'path': '57/ai/r/2_clip/vehicle_3.png', 'type': 'vehicle'}],
  },
];

Map<String, dynamic> _evidence() =>
    buildSubmissionEvidence(57, _rows, {7: 1, 8: 2}, {12: 11});

/// A 1x1 transparent PNG, so pictures "load" in tests.
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class _FakeSource implements CaseEvidenceSource {
  @override
  Future<CaseEvidence?> load(int caseId) async => CaseEvidence.fromMap(_evidence());
  @override
  ImageProvider image(String path) => MemoryImage(_png);
  @override
  Future<Uint8List> bytes(String path) async => _png;
  @override
  Future<void> answer(int caseId, String memberKey, {required bool yes}) async {}
}

void main() {
  test('detections become Person / Vehicle / Weapon entries with their pictures', () {
    final e = CaseEvidence.fromMap(_evidence());

    final person = e.people.single;
    expect(person.label, 'Person 1');
    expect(person.clip, 1);
    expect(person.summaryLine,
        'top white / bottom black · face visible (picture captured)');
    expect(person.crops.map((c) => c.type), ['person', 'face']);
    expect(person.cover, '57/ai/r/1_clip/person_1.png');

    expect(e.vehicles.single.summaryLine, 'white Toyota car · plate ND123456');
    expect(e.vehicles.single.clip, 2);
    expect(e.weapons.single.summaryLine, 'long gun · held by Person 1');
    expect(e.weapons.single.detailLines, contains(('Held by', 'Person 1')));
    expect(e.openQuestions, 0);
  });

  testWidgets('AI summary text, then each entry with its clip and View crops',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: [
          CaseEvidenceSection(
            caseId: 57,
            source: _FakeSource(),
            summary: 'Detected 1 possible suspect with a long gun.',
            perSubmission: true,
          ),
        ]),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('AI SUMMARY'), findsOneWidget);
    expect(find.text('Detected 1 possible suspect with a long gun.'), findsOneWidget);
    expect(find.text('Person 1: top white / bottom black · face visible (picture captured)'),
        findsOneWidget);
    expect(find.text('Vehicle 1: white Toyota car · plate ND123456'), findsOneWidget);
    expect(find.text('Weapon 1: long gun · held by Person 1'), findsOneWidget);
    expect(find.text('Clip 1 · 2 pictures'), findsOneWidget);
    expect(find.text('Clip 2 · 1 picture'), findsOneWidget);
    expect(find.text('View crops'), findsNWidgets(3));

    await tester.tap(find.text('View crops').first);
    await tester.pumpAndSettle();
    expect(find.text('PICTURES (2)'), findsOneWidget);
  });
}
