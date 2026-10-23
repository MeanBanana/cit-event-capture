// The crime scene models (list_case_crime_scenes / get_crime_scene rows), and
// how corrections show up in a submission's AI findings.

import 'package:flutter_test/flutter_test.dart';

import 'package:argus_shield/models/crime_scene.dart';
import 'package:argus_shield/submission_evidence_source.dart';

import 'crime_scene_fake_service.dart';

void main() {
  group('CrimeSceneCardInfo', () {
    test('reads a list_case_crime_scenes row', () {
      final card = CrimeSceneCardInfo.fromMap(fakeCardRow(42,
          status: 'analysing', suspects: 3, vehicles: 2, weapons: 0));
      expect(card.reference, 'INC-0042');
      expect(card.location, 'Rivonia Rd, Sandton');
      expect(card.description, 'Two men with a rifle stopped the cash van.');
      expect((card.suspects, card.vehicles, card.weapons), (3, 2, 0));
      expect(card.analysis, AnalysisStatus.analysing);
      expect(card.analysis.inProgress, isTrue);
      expect(card.bestTime, card.dateTime); // no capture time yet
    });

    test('unknown or missing analysis status counts as pending', () {
      expect(AnalysisStatus.parse(null), AnalysisStatus.pending);
      expect(AnalysisStatus.parse('something'), AnalysisStatus.pending);
      expect(AnalysisStatus.parse('no_footage'), AnalysisStatus.noFootage);
      expect(AnalysisStatus.done.inProgress, isFalse);
      expect(AnalysisStatus.failed.inProgress, isFalse);
    });
  });

  group('CrimeSceneDetail', () {
    test('reads a get_crime_scene result', () {
      final scene = CrimeSceneDetail.fromMap(fakeScene(42));
      expect(scene.reference, 'INC-0042');
      expect(scene.caseReference, 'CASE-0003');
      expect(scene.analysis, AnalysisStatus.done);
      expect(scene.canCorrect, isTrue);
      expect(scene.hasGps, isTrue);
      expect(scene.files.single.number, 1);
      expect(scene.files.single.status, 'completed');
      expect(scene.detections.map((d) => d.label),
          ['Person 1', 'Vehicle 1', 'Weapon 1']);
      expect(scene.ofKind('vehicle').single.detectionId, 12);

      final car = scene.ofKind('vehicle').single;
      expect(car.crops, ['42/ai/run/1_clip/vehicle_1.png']);
      expect(car.field('plate')!.value, 'ND123456');
      expect(car.field('model')!.ai, isNull);
      // "dismissed" is not shown as a detail line
      expect(car.detailFields.map((f) => f.field),
          ['vehicle_type', 'make', 'model', 'colour', 'plate']);
      expect(car.isCorrected, isFalse);
    });

    test('a scene still waiting for the AI has no findings', () {
      final scene = CrimeSceneDetail.fromMap(fakeScene(42, status: 'pending'));
      expect(scene.analysis, AnalysisStatus.pending);
      expect(scene.canCorrect, isFalse);
      expect(scene.detections, isEmpty);
    });
  });

  group('Corrections', () {
    CorrectionEntry entry(String? field, String? original, String? corrected) =>
        CorrectionEntry.fromMap({
          'correction_id': 1,
          'detection_id': 12,
          'label': 'Vehicle 1',
          'field': field,
          'original': original,
          'corrected': corrected,
          'note': null,
          'by': 'Thabo Mokoena',
          'at': '2026-10-13T09:30:00Z',
        });

    test('log lines read naturally', () {
      expect(entry('plate', 'ND123456', 'ND654321').text,
          'Vehicle 1 · Number plate: ND123456 → ND654321');
      expect(entry('plate', 'ND123456', null).text,
          'Vehicle 1 · Number plate: ND123456 → no readable plate');
      expect(entry('weapon_type', 'long_gun', 'handgun').text,
          'Vehicle 1 · Weapon type: long gun → handgun');
      expect(entry('dismissed', 'false', 'true').text,
          'Vehicle 1 marked as not real');
      expect(entry('dismissed', 'true', 'false').text,
          'Vehicle 1 restored (it is real)');
      // corrections logged before fields were recorded
      expect(entry(null, 'a', 'b').text, 'Vehicle 1 · value: a → b');
    });

    test('field labels and values', () {
      expect(fieldLabel('upper_clothing'), 'Top colour');
      expect(fieldLabel('vehicle_type'), 'Vehicle type');
      expect(displayValue('colour', null), 'unknown');
      expect(displayValue('plate', ''), 'no readable plate');
      expect(displayValue('weapon_type', 'long_gun'), 'long gun');
      expect(weaponTypes, contains('machete'));
    });
  });

  group('Submission findings with corrections', () {
    Map<String, dynamic> row(int id, String kind, Map<String, dynamic> attributes,
            [Map<String, dynamic> corrections = const {}]) =>
        {
          'detectionid': id,
          'mediaid': 101,
          'detectiontype': kind,
          'trackid': id,
          'firstseen': 1.0,
          'attributes': attributes,
          'crops': const [],
          'corrections': corrections,
        };

    test('corrected values replace the AI\'s', () {
      final map = buildSubmissionEvidence(42, [
        row(1, 'vehicle', {'class_name': 'car', 'make': 'Toyota', 'colour': 'white',
          'plate': 'ND123456'}, {'plate': 'ND654321', 'make': 'Nissan'}),
        row(2, 'person', {'upper_clothing': 'black', 'lower_clothing': 'blue'},
            {'upper_clothing': 'red'}),
      ], {101: 1}, {});

      final car = (map['vehicles'] as List).single as Map;
      expect(car['attributes']['plate'], 'ND654321');
      expect(car['attributes']['make'], 'Nissan');
      expect(car['description'], 'white Nissan car · plate ND654321');
      final who = (map['people'] as List).single as Map;
      expect(who['attributes']['upper_clothing'], 'red');
    });

    test('a dismissed detection keeps its number but says it is not real', () {
      final map = buildSubmissionEvidence(42, [
        row(3, 'weapon', {'class_name': 'long_gun'}, {'dismissed': true}),
        row(4, 'weapon', {'class_name': 'knife'}),
      ], {101: 1}, {});
      final weapons = (map['weapons'] as List).cast<Map>();
      expect(weapons.map((w) => w['label']), ['Weapon 1', 'Weapon 2']);
      expect(weapons[0]['description'],
          'not a real weapon (an investigator dismissed it)');
      expect(weapons[1]['description'], 'knife');
    });

    test('rows without corrections (older data) still work', () {
      final r = row(5, 'vehicle', {'class_name': 'car', 'colour': 'white'})
        ..remove('corrections');
      final map = buildSubmissionEvidence(42, [r], {101: 1}, {});
      expect(((map['vehicles'] as List).single as Map)['attributes']['colour'],
          'white');
    });
  });
}
