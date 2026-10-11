// Tests for the AI section of the case page: summary, people / vehicles /
// weapons cards, the 3-column pictures page, the enlarged picture with its
// Download button, and answering "Is this Person 1?".

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:argus_shield/admin_screens/case_evidence_section.dart';
import 'package:argus_shield/case_evidence_source.dart';
import 'package:argus_shield/models/case_evidence.dart';

/// A 1x1 transparent PNG, so pictures "load" in tests.
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

Map<String, dynamic> _crop(String path, int submission, String type) =>
    {'path': path, 'type': type, 'submission': submission, 'file_name': 'clip.mp4'};

Map<String, dynamic> _sample() => {
      'case_id': 1,
      'ai_summary': '2 submissions. AI found 1 person, 1 vehicle and 1 weapon.',
      'open_questions': 1,
      'people': [
        {
          'entity_id': 'p1',
          'kind': 'person',
          'label': 'Person 1',
          'description': 'top black, bottom blue · face seen',
          'attributes': {'upper_clothing': 'black', 'upper_clothing_share': 0.8},
          'cover': 'p1a',
          'submission_count': 2,
          'crops': [
            for (var i = 0; i < 7; i++) _crop('p1_$i', i < 4 ? 1 : 2, 'person'),
          ],
          'questions': [
            {
              'member_key': 's3/f1/person/2',
              'submission': 3,
              'file_name': 'other.mp4',
              'score': 0.81,
              'reasons': ['looks 81% alike', 'same clothing (black top)'],
              'crops': [_crop('q1', 3, 'person')],
            }
          ],
          'updated': [],
        }
      ],
      'vehicles': [
        {
          'entity_id': 'v1',
          'kind': 'vehicle',
          'label': 'Vehicle 1',
          'description': 'white Toyota car · plate ND123456',
          'attributes': {'plate': 'ND123456'},
          'cover': null,
          'submission_count': 1,
          'crops': [_crop('v1_0', 1, 'vehicle')],
          'questions': [],
          'updated': [
            {'field': 'plate', 'old': null, 'new': 'ND123456', 'submission': 2}
          ],
        }
      ],
      'weapons': [
        {
          'entity_id': 'w1',
          'kind': 'weapon',
          'label': 'Weapon 1',
          'description': 'long gun · held by Person 1',
          'attributes': {'kind': 'long_gun', 'held_by': 'Person 1'},
          'submission_count': 1,
          'crops': [_crop('w1_0', 1, 'weapon')],
          'questions': [],
          'updated': [],
        }
      ],
    };

class FakeEvidenceSource implements CaseEvidenceSource {
  final Map<String, dynamic>? data;
  final answers = <String>[];

  FakeEvidenceSource(this.data);

  @override
  Future<CaseEvidence?> load(int caseId) async =>
      data == null ? null : CaseEvidence.fromMap(data!);

  @override
  ImageProvider image(String path) => MemoryImage(_png);

  @override
  Future<Uint8List> bytes(String path) async => _png;

  @override
  Future<void> answer(int caseId, String memberKey, {required bool yes}) async {
    answers.add('$memberKey:$yes');
    final person = (data!['people'] as List).first as Map;
    final q = (person['questions'] as List).removeAt(0) as Map;
    if (yes) (person['crops'] as List).addAll(q['crops'] as List);
    data!['open_questions'] = 0;
  }
}

Future<void> _pump(WidgetTester tester, FakeEvidenceSource source) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: ListView(children: [CaseEvidenceSection(caseId: 1, source: source)]),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  test('parses the case_matcher view', () {
    final e = CaseEvidence.fromMap(_sample());
    expect(e.people.single.crops, hasLength(7));
    expect(e.people.single.questions.single.reasons, contains('looks 81% alike'));
    expect(e.vehicles.single.updated.single.text,
        'plate: unknown → ND123456 (from submission 2)');
    expect(e.people.single.detailLines, contains(('Top', 'black (80%)')));
  });

  testWidgets('summary, counts and one card per person / vehicle / weapon',
      (tester) async {
    await _pump(tester, FakeEvidenceSource(_sample()));

    expect(find.text('AI SUMMARY'), findsOneWidget);
    expect(find.textContaining('AI found 1 person'), findsOneWidget);
    expect(find.text('1 person · 1 vehicle · 1 weapon · 1 match to check'),
        findsOneWidget);
    expect(find.text('Person 1'), findsOneWidget);
    expect(find.text('Vehicle 1'), findsOneWidget);
    expect(find.text('Weapon 1'), findsOneWidget);
    expect(find.text('2 submissions · 7 pictures · 1 to check'), findsOneWidget);
    expect(find.text('View'), findsNWidgets(3));
  });

  testWidgets('no evidence yet', (tester) async {
    await _pump(tester, FakeEvidenceSource(null));
    expect(find.text('No AI analysis for this case yet.'), findsOneWidget);
  });

  testWidgets('View shows the pictures 3 per row; tap opens the viewer',
      (tester) async {
    await _pump(tester, FakeEvidenceSource(_sample()));

    await tester.tap(find.text('View').first);
    await tester.pumpAndSettle();

    expect(find.text('PICTURES (7)'), findsOneWidget);
    final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
    final layout =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(layout.crossAxisCount, 3);

    await tester.tap(find.text('S1 · person').first);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
  });

  testWidgets('answering "Is this Person 1?" with yes adds the pictures',
      (tester) async {
    final source = FakeEvidenceSource(_sample());
    await _pump(tester, source);
    await tester.tap(find.text('View').first);
    await tester.pumpAndSettle();

    expect(find.text('Is this Person 1?'), findsOneWidget);
    expect(find.text('looks 81% alike'), findsOneWidget);

    await tester.tap(find.text('Yes, same'));
    await tester.pumpAndSettle();

    expect(source.answers, ['s3/f1/person/2:true']);
    expect(find.text('Is this Person 1?'), findsNothing);
    expect(find.text('PICTURES (8)'), findsOneWidget);
  });
}
