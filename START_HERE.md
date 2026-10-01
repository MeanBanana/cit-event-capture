# Argus Shield — simple separation

Eight Dart files directly inside lib; no extra folders inside lib.

| File | Responsibility |
| --- | --- |
| main.dart | Only the imports and main() entry point |
| argus_app.dart | ArgusApp: MaterialApp and ownership of CitizenStore |
| citizen_dashboard.dart | CitizenDashboard: header, tabs, and page objects |
| upload_page.dart | UploadPage: form, camera/gallery, report action |
| submissions_page.dart | SubmissionsPage and its SubmissionCard helper |
| profile_page.dart | ProfilePage: contact fields and save action |
| citizen_store.dart | CitizenStore plus the small data classes it stores |
| app_styles.dart | Shared colours, FormLabel, and fieldDecoration |

Small related helper classes stay with the class that uses them, instead of each
getting its own file. The three main subpages each have their own file. Their
private State classes stay in the same file as their StatefulWidget.

## Install

1. Stop the running app and back up your existing lib folder outside your project.
2. Extract the ZIP and open argus_simple_documented.
3. Replace the project's lib folder with this lib folder. Do not put it inside the
   existing lib folder; main.dart should be at argus_shield/lib/main.dart.
4. Keep your existing pubspec.yaml, pubspec.lock, android, and ios folders.
5. image_picker is still needed and was already added to your project.
6. Copy citizen_store_test.dart into test. Replace the default Flutter counter
   widget_test.dart with this widget_test.dart. Preserve any custom tests separately.
7. These tests assume pubspec.yaml's name is argus_shield. Update their package
   imports if your actual package name differs.
8. Run the following from Android Studio's terminal in the project folder:

```powershell
& "C:\Users\Elian\Flutter\flutter\bin\flutter.bat" pub get
& "C:\Users\Elian\Flutter\flutter\bin\dart.bat" format lib test
& "C:\Users\Elian\Flutter\flutter\bin\flutter.bat" analyze
& "C:\Users\Elian\Flutter\flutter\bin\flutter.bat" test
```

9. Select the Pixel 7 emulator and Run the app from scratch.

## OOP explanation

- Classes: separate main screen and subpage classes; data classes describe records.
- Objects: one CitizenStore is created and passed into all three pages.
- Encapsulation: _submissions and _profile are private to citizen_store.dart.
  The submissions getter is read-only. submitReport and saveProfile control edits.
- Inheritance: pages extend Flutter widget classes; CitizenStore extends ChangeNotifier.
- Polymorphism: widget classes override build so Flutter renders their own screens.
- Composition: the app owns the store; the dashboard contains the page objects.

main.dart starts ArgusApp; ArgusApp opens CitizenDashboard; CitizenDashboard
passes the shared CitizenStore to UploadPage, SubmissionsPage, and ProfilePage.
SubmissionsPage listens to store changes with ListenableBuilder.

## Behaviour

The existing navy/gold/coral styling and local demo flow are retained. Selecting
media and submitting a valid report creates a card and switches to Submissions.
Profile edits are saved to shared session memory. Both forms keep their state
while switching tabs. Empty fields are rejected; email validation checks for @,
as in the earlier simple prototype. This is a basic presence check, not email verification.

Data clears when the app restarts. No Supabase connection, auth, uploaded media,
or encryption is implemented. Selected file paths are temporary picker paths.
The privacy notice describes demo behaviour. References are unique only within
the session and start with DEMO. Contact email edits do not change an auth account.
Android picker lost-data recovery is not implemented yet.

## Verification

Test a valid upload, an empty upload, cancellation of the picker, two reports in
newest-first order, profile validation/save, switching tabs, and a full restart.
The included automated tests check the store and profile navigation.
Flutter/Dart is not installed in the delivery environment, so analyze and tests
must be run on your computer. File imports, delimiter counts, and ZIP integrity
were checked here; those checks do not replace the Flutter analyzer or tests.

Read CODE_DOCUMENTATION.md for the class explanations and testing checklist.
