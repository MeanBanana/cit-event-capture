// Tests for the citizen's report: CitizenStore.sendReport (incident ->
// upload each file -> start the analysis, with "Try again" carrying on after
// a failure) and the Submissions tab listing the citizen's reports.
// A fake SupabaseService stands in for Supabase.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/citizen/citizen_store.dart';
import 'package:argus_shield/citizen/submissions_page.dart';
import 'package:argus_shield/citizen/upload_page.dart';

class FakeCitizenService extends SupabaseService {
  final calls = <String>[];
  final List<MySubmission> reports = [];
  int nextIncident = 57;

  /// Make the upload of this file name fail once (to test Try again).
  String? failUploadOf;

  @override
  Future<CitizenProfile> getMyCitizenProfile() async => const CitizenProfile(
      userId: 4, username: 'sam', firstName: 'Sam', surname: 'Citizen',
      email: 'sam@example.com');

  @override
  Future<int> createIncident({
    required int reporterId,
    required String location,
    required String description,
    required DateTime when,
    double? latitude,
    double? longitude,
  }) async {
    calls.add('incident:$reporterId:$location:$latitude:$longitude');
    return nextIncident;
  }

  @override
  Future<String> uploadIncidentFile({
    required int incidentId,
    required int uploaderId,
    required String fileName,
    required Uint8List bytes,
    required String contentType,
    required String mediaType,
  }) async {
    if (fileName == failUploadOf) {
      failUploadOf = null;
      throw Exception('connection lost');
    }
    calls.add('upload:$incidentId:$fileName:$contentType:$mediaType:${bytes.length}');
    return '$incidentId/media/x';
  }

  @override
  Future<int> submitForAnalysis(int incidentId) async {
    calls.add('analyse:$incidentId');
    reports.insert(0, MySubmission(
        incidentId: incidentId, location: 'N1 Midrand', aiStatus: 'processing',
        fileCount: 2, reportedAt: DateTime(2026, 10, 12, 19, 42)));
    return 1;
  }

  @override
  Future<List<MySubmission>> getMySubmissions(int reporterId, {int limit = 50}) async {
    calls.add('list:$reporterId');
    return List.of(reports);
  }
}

FootageFile footage(String name, {int size = 1000}) => FootageFile(
      name: name,
      size: size,
      readBytes: () async => Uint8List(size),
    );

void main() {
  group('CitizenStore.sendReport', () {
    test('creates the incident, uploads every file, starts the analysis', () async {
      final fake = FakeCitizenService();
      final store = CitizenStore(service: fake);
      final progress = <double>[];

      final id = await store.sendReport(
        location: ' N1 Midrand ',
        description: 'Two cars blocked the van',
        files: [footage('clip.mp4'), footage('photo.JPG', size: 500)],
        latitude: -25.9946,
        longitude: 28.1265,
        onProgress: (p) => progress.add(p.fraction),
      );

      expect(id, 57);
      expect(fake.calls.take(4), [
        'incident:4:N1 Midrand:-25.9946:28.1265',
        'upload:57:clip.mp4:video/mp4:video:1000',
        'upload:57:photo.JPG:image/jpeg:image:500',
        'analyse:57',
      ]);
      expect(progress.last, 1);
      await Future<void>.delayed(Duration.zero); // the list refresh
      expect(store.submissions.single.reference, 'INC-0057');
    });

    test('checks the input before sending anything', () async {
      final fake = FakeCitizenService();
      final store = CitizenStore(service: fake);

      Future<void> send(List<FootageFile> files, {String location = 'N1'}) =>
          store.sendReport(location: location, description: 'x', files: files);

      await expectLater(send([]), throwsArgumentError);
      await expectLater(send([footage('a.mp4')], location: ' '), throwsArgumentError);
      await expectLater(send([for (var i = 0; i < 6; i++) footage('$i.mp4')]),
          throwsArgumentError);
      await expectLater(send([footage('big.mp4', size: 60 * 1024 * 1024)]),
          throwsArgumentError);
      expect(fake.calls, isEmpty);
    });

    test('Try again carries on: no second incident, no file sent twice', () async {
      final fake = FakeCitizenService()..failUploadOf = 'b.mp4';
      final store = CitizenStore(service: fake);
      final files = [footage('a.mp4'), footage('b.mp4'), footage('c.jpg')];

      SendReportFailed? failure;
      try {
        await store.sendReport(location: 'N1', description: 'x', files: files);
      } on SendReportFailed catch (e) {
        failure = e;
      }
      expect(failure, isNotNull);
      expect(failure!.incidentId, 57);
      expect(failure.uploaded, 1);
      expect(failure.message, contains('1 of 3'));
      expect(fake.calls.where((c) => c.startsWith('analyse')), isEmpty);

      fake.calls.clear();
      await store.sendReport(
        location: 'N1', description: 'x', files: files,
        resumeIncidentId: failure.incidentId, alreadyUploaded: failure.uploaded,
      );
      expect(fake.calls.take(3), [
        'upload:57:b.mp4:video/mp4:video:1000',
        'upload:57:c.jpg:image/jpeg:image:1000',
        'analyse:57',
      ]);
    });
  });

  testWidgets('Submissions tab shows the citizen\'s reports and their status',
      (tester) async {
    final fake = FakeCitizenService()
      ..reports.addAll([
        MySubmission(incidentId: 58, location: 'R21 Kempton Park',
            reviewStatus: 'accepted', aiStatus: 'ready', fileCount: 3,
            reportedAt: DateTime(2026, 10, 12, 20, 5)),
        MySubmission(incidentId: 57, location: 'N1 Midrand',
            aiStatus: 'processing', fileCount: 1,
            reportedAt: DateTime(2026, 10, 12, 19, 42)),
      ]);
    final store = CitizenStore(service: fake);
    await store.loadSubmissions();

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SubmissionsPage(store: store))));
    await tester.pumpAndSettle();

    expect(find.text('INC-0058'), findsOneWidget);
    expect(find.text('ADDED TO A CASE'), findsOneWidget);
    expect(find.textContaining('3 files · Footage analysed'), findsOneWidget);
    expect(find.text('INC-0057'), findsOneWidget);
    expect(find.text('RECEIVED'), findsOneWidget);
    expect(find.textContaining('1 file · Footage being analysed'), findsOneWidget);
  });

  testWidgets('Upload page asks for footage before sending', (tester) async {
    final fake = FakeCitizenService();
    final store = CitizenStore(service: fake);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: UploadPage(store: store, getLocation: () async => null)),
    ));

    await tester.enterText(find.byType(TextFormField).first, 'N1 Midrand');
    await tester.enterText(find.byType(TextFormField).last, 'Two cars');
    await tester.ensureVisible(find.text('Submit Report'));
    await tester.tap(find.text('Submit Report'));
    await tester.pump();

    expect(find.text('Please select or record footage first.'), findsOneWidget);
    expect(fake.calls, isEmpty);
    expect(find.text("Share my phone's location"), findsOneWidget);
  });
}
