# Argus Shield: Citizen Dashboard Code Documentation

## 1. Purpose and implementation scope

The citizen dashboard is the Flutter front end through which a citizen selects
evidence, describes an incident, views reports, and edits contact details. It has
three subpages: Upload, Submissions, and Profile. A shared dashboard header and
gold tab bar provide navigation between these pages.

This implementation is a local prototype. Reports and profile details remain in
memory during the current app session. The selected file is represented by its
name and temporary path. It is not uploaded, encrypted, or processed by an AI
service. Authentication, permanent storage, and Supabase integration are pending.

## 2. File and class responsibilities

All eight application files are directly inside lib.

| File | Main class or function | Responsibility |
| --- | --- | --- |
| main.dart | main() | Calls runApp with ArgusApp |
| argus_app.dart | ArgusApp | Creates MaterialApp and owns the shared CitizenStore |
| citizen_dashboard.dart | CitizenDashboard | Displays the header and tab navigation; creates the three pages |
| upload_page.dart | UploadPage | Selects/records media, validates incident inputs, adds a demo report |
| submissions_page.dart | SubmissionsPage; SubmissionCard | Observes stored reports and displays a card for each |
| profile_page.dart | ProfilePage | Shows contact inputs and saves valid details into the store |
| citizen_store.dart | CitizenStore; data classes | Encapsulates session data and the methods that change it |
| app_styles.dart | Colour constants; FormLabel; fieldDecoration() | Keeps styling consistent between pages |

UploadPage and ProfilePage are StatefulWidget classes because they contain
editable controls. Their private State classes remain in the same files.
CitizenDashboard and SubmissionCard are StatelessWidget classes: their build
methods describe presentation using the values they receive. SubmissionsPage
uses ListenableBuilder to refresh its content when the store changes, so it does
not need its own StatefulWidget state.

## 3. Application startup and object ownership

main() creates the root ArgusApp widget. Its State creates one CitizenStore.
ArgusApp passes that store to CitizenDashboard, which passes the same object to
all three pages through constructor parameters. This allows an action in Upload
to change the information displayed in Submissions.

The store is a final field of the app's State, so ordinary screen rebuilds do not
create an empty replacement store. ArgusApp disposes the notifier when it is
removed from the widget tree. A full application restart creates a fresh store.

## 4. Data classes

MediaAttachment holds name and path. The path comes from image_picker and may
refer to temporary storage. Holding this path does not make a permanent copy.

CitizenSubmission holds reference, location, createdAt, description, and
attachment. createdAt records when the user added the report, not when the
incident happened. The reference is a session counter such as DEMO-0001; it is
not an official case reference or a globally unique backend ID.

CitizenProfile holds name, email, and phone. Its fields are final. Saving an edit
creates a replacement object rather than modifying the previously saved object.
The email is contact information; saving it does not change an auth account.

## 5. Upload workflow

The form key allows _submitReport() to call Form.validate(). Text controllers
hold the incident location and description. The footage box opens a bottom sheet
to choose an image or video; _recordVideo() opens the device camera.

Picker operations return Future values because the app waits while the user
interacts with the native picker. A null result means cancellation. The mounted
check prevents setState from running after the page has been removed. Exceptions
are caught and displayed through _showMessage(), which creates a SnackBar.

_submitReport() checks required fields and verifies that an attachment exists.
It calls CitizenStore.submitReport(), clears accepted form input, and switches
to tab index 1, Submissions. Invalid fields produce validation messages without
adding a record. Upload and Profile use AutomaticKeepAliveClientMixin to retain
their input while changing tabs; this does not persist data after app shutdown.

## 6. Submission and profile workflows

CitizenStore.submitReport() trims text and rejects empty incident fields or
attachment metadata. It creates a report snapshot, inserts it at list index 0,
and calls notifyListeners(). ListenableBuilder responds by rebuilding the
Submissions list. An empty-state message appears before the first report.

ProfilePage loads any saved profile in initState(). _saveProfile() validates the
form and calls CitizenStore.saveProfile(). That method checks the values again,
trims whitespace, replaces the profile, and notifies listeners. The page displays
a session-save message. Empty fields are rejected. Email validation checks only
for an @ character; it does not establish that the address is valid or owned by
the citizen. Phone validation only checks that a value has been supplied.

## 7. OOP concepts used

| Concept | Example in this implementation |
| --- | --- |
| Classes and objects | CitizenSubmission defines a record type; each report is an object of that type |
| Encapsulation | CitizenStore keeps _submissions and _profile private and changes them through methods |
| Abstraction | Pages call submitReport() or saveProfile() without editing the store's collection directly |
| Inheritance | Widgets extend Flutter widget classes; CitizenStore extends ChangeNotifier |
| Polymorphism | Widget classes override build(), which Flutter invokes to render the appropriate widget |
| Composition | ArgusApp owns a store, and CitizenDashboard contains three page widgets |

The submissions getter returns an UnmodifiableListView. Pages can read reports
but cannot add or remove entries through that view. An underscore marks a member
as private to its Dart library/file, rather than private only to a class.
Splitting files supports organisation; these class responsibilities and controlled
operations provide the actual OOP design.

## 8. Comments and documentation conventions

The supplied code uses // for implementation notes and /// for documentation
attached to classes, methods, and important fields. The comments explain object
ownership, validation, asynchronous behaviour, state updates, and resource cleanup.
They should be updated whenever the described behaviour changes.

## 9. Running and verification

Follow START_HERE.md to copy the lib folder into the existing Android Studio
project. Keep the project's existing platform folders and pubspec files.
image_picker is the required non-SDK package. The optional tests assume the
package name is argus_shield. Run these commands from the project terminal:

```powershell
& "C:\Users\Elian\Flutter\flutter\bin\flutter.bat" pub get
& "C:\Users\Elian\Flutter\flutter\bin\dart.bat" format lib test
& "C:\Users\Elian\Flutter\flutter\bin\flutter.bat" analyze
& "C:\Users\Elian\Flutter\flutter\bin\flutter.bat" test
```

Select the Android emulator and run lib/main.dart. Record your actual results
in the checklist below; do not mark a check passed without running it.

| Check | Expected result | Actual result |
| --- | --- | --- |
| Navigate between all tabs | Correct page, header, and gold tabs displayed | To record |
| Submit with empty fields | Validation appears; no record added | To record |
| Cancel media selection | Page stays usable; no new attachment | To record |
| Submit valid report | Card appears; tab changes; accepted inputs clear | To record |
| Submit a second report | Newest report appears first with a distinct demo reference | To record |
| Save invalid profile | Validation appears; previously saved profile is preserved | To record |
| Save valid profile and switch tabs | Contact values remain during the session | To record |
| Fully restart the app | Session reports and saved profile reset | To record |
| Camera and video selection | Selected filename appears, or a clear error message is shown | To record |

Included tests cover record order/references, protected collection access,
validation, notifications, session isolation, and profile navigation. Flutter
analysis and tests have not been executed in the delivery environment because it
does not have a Flutter/Dart SDK. Imports and source structure were checked, and
the commented version was compared with the simpler version to confirm that
comments did not alter executable code. Emulator visual matching remains a
manual check.

## 10. Remaining integration work

Supabase authentication, private media storage, database access policies, durable
submissions, real administrator review statuses, and profile persistence must be
implemented against the team's agreed schema. Backend-generated references must
replace session demo references. Android picker recovery after the operating
system kills the app is also pending. The UI privacy notice currently describes
the prototype's demo behaviour and must reflect the actual implementation after
integration.
