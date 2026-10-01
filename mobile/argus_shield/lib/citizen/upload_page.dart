// upload_page.dart — media picker, incident form, and local submit action.

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../theme/app_theme.dart';
import '../theme/argus_widgets.dart';
import 'citizen_store.dart';

/// Lets a citizen select media and describe an incident before adding a demo report.
class UploadPage extends StatefulWidget {
  final CitizenStore store;

  const UploadPage({
    super.key,
    required this.store,
  });

  @override
  State<UploadPage> createState() => _UploadPageState();
}

// State holds form inputs and the chosen attachment while this page is open.
class _UploadPageState extends State<UploadPage>
    with AutomaticKeepAliveClientMixin<UploadPage> {
  @override
  // Retain unfinished input when the user switches tabs.
  bool get wantKeepAlive => true;
  final _picker = ImagePicker();
  // The key gives access to Form.validate(); controllers hold field text.
  final _formKey = GlobalKey<FormState>();
  final _locationController = TextEditingController();
  final _descriptionController = TextEditingController();

  // Nullable: no attachment exists until gallery/camera selection succeeds.
  MediaAttachment? _selectedFile;

  @override
  void dispose() {
    // Controllers own resources; release them when this page is removed.
    _locationController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  /// Offers image/video selection and waits for the native picker result.
  Future<void> _chooseFromGallery() async {
    // The mock-up permits either an image or video from the gallery.
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('Choose image'),
              onTap: () => Navigator.pop(context, 'image'),
            ),
            ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: const Text('Choose video'),
              onTap: () => Navigator.pop(context, 'video'),
            ),
          ],
        ),
      ),
    );

    // Cancellation needs no error. mounted checks that the page still exists.
    if (choice == null || !mounted) return;

    try {
      final XFile? file = choice == 'image'
          ? await _picker.pickImage(source: ImageSource.gallery)
          : await _picker.pickVideo(source: ImageSource.gallery);

      // setState refreshes the filename displayed inside the footage box.
      if (file != null && mounted) {
        setState(() => _selectedFile = MediaAttachment(name: file.name, path: file.path));
      }
    } catch (error) {
      if (mounted) _showMessage('Could not open gallery: $error');
    }
  }

  /// Opens the device camera to record a video; errors appear in a SnackBar.
  Future<void> _recordVideo() async {
    try {
      final file = await _picker.pickVideo(source: ImageSource.camera);

      if (file != null && mounted) {
        setState(() => _selectedFile = MediaAttachment(name: file.name, path: file.path));
      }
    } catch (error) {
      if (mounted) _showMessage('Could not open camera: $error');
    }
  }

  /// Displays brief feedback at the bottom of the dashboard.
  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// Validates the form, adds a local report, clears input, and opens Submissions.
  void _submitReport() {
    // Run the validators attached to both TextFormField widgets.
    final fieldsValid = _formKey.currentState!.validate();
    final attachment = _selectedFile;
    if (attachment == null) {
      _showMessage('Please select or record footage first.');
      return;
    }
    if (!fieldsValid) return;

    // The store creates the report and notifies the Submissions page.
    widget.store.submitReport(
      location: _locationController.text,
      description: _descriptionController.text,
      attachment: attachment,
    );
    // Clear only after the report has been accepted by the store.
    _locationController.clear();
    _descriptionController.clear();
    setState(() => _selectedFile = null);
    _showMessage('Report added for this demo session.');
    // Tab indexes start at zero: Upload = 0, Submissions = 1, Profile = 2.
    DefaultTabController.of(context).animateTo(1);
  }

  @override
  Widget build(BuildContext context) {
    // Required by AutomaticKeepAliveClientMixin to retain the page state.
    super.build(context);
    // Scrolling accommodates a small screen and the on-screen keyboard.
    return SingleChildScrollView(
      padding: AppSpacing.page,
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Submit footage', style: AppText.sectionTitle),
            const SizedBox(height: AppSpacing.small),
            const Text(
              'If you have witnessed or recorded a cash-in-transit '
              'robbery, select your footage here.',
              style: AppText.body,
            ),
            const SizedBox(height: AppSpacing.medium),

            // Footage box from the mock-up.
            InkWell(
              onTap: _chooseFromGallery,
              borderRadius: BorderRadius.circular(4),
              child: Container(
                width: double.infinity,
                height: 110,
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.fieldBorder),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _selectedFile == null
                          ? 'Tap to select video or image'
                          : _selectedFile!.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.body,
                    ),
                    const SizedBox(height: 7),
                    const Icon(
                      Icons.photo_camera_outlined,
                      size: 42,
                      color: AppColors.accent,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.medium),

            // Recording live is the urgent action, so it uses the danger colour;
            // shape and text colour come from the theme.
            Center(
              child: ElevatedButton(
                onPressed: _recordVideo,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.danger,
                  textStyle: AppText.buttonSmall,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 15,
                  ),
                ),
                child: const Text('Record Live Footage'),
              ),
            ),
            const SizedBox(height: AppSpacing.large),

            const FieldLabel('Incident location'),
            TextFormField(
              controller: _locationController,
              decoration: const InputDecoration(hintText: 'e.g. N1 Southbound'),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Enter the incident location'
                  : null,
            ),
            const SizedBox(height: AppSpacing.medium),

            const FieldLabel('Description*'),
            TextFormField(
              controller: _descriptionController,
              maxLines: 4,
              decoration: const InputDecoration(
                hintText: 'Briefly describe what you witnessed - number of '
                    'vehicles, suspects, direction of travel...',
              ),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Enter a description'
                  : null,
            ),
            const SizedBox(height: AppSpacing.large),

            Text(
              'Privacy notice',
              style: AppText.fieldLabel.copyWith(color: AppColors.accent),
            ),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.accent, width: 2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'Demo mode: reports stay in memory during this app session. '
                'Footage is not uploaded to law enforcement yet.',
                textAlign: TextAlign.center,
                style: AppText.bodyMuted,
              ),
            ),
            const SizedBox(height: AppSpacing.large),

            Center(
              child: PrimaryButton(
                label: 'Submit Report',
                onPressed: _submitReport,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
