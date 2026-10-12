// upload_page.dart — the citizen reports an incident: 1-5 videos / photos,
// where it happened and what they saw. Submit sends it to Argus Shield:
// the incident and the footage go to Supabase, and the AI worker analyses
// it (CitizenStore.sendReport). Admins then see it in their Submissions tab.

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../theme/app_theme.dart';
import '../theme/argus_widgets.dart';
import 'citizen_store.dart';
import 'phone_location.dart';

/// Lets a citizen pick footage, describe the incident and send the report.
class UploadPage extends StatefulWidget {
  final CitizenStore store;

  /// The phone's GPS. Optional so tests can replace it; the app uses the
  /// real one (phone_location.dart).
  final Future<(double, double)?> Function()? getLocation;

  const UploadPage({
    super.key,
    required this.store,
    this.getLocation,
  });

  @override
  State<UploadPage> createState() => _UploadPageState();
}

// State holds form inputs and the chosen footage while this page is open.
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

  /// The picked / recorded files, in the order they will be uploaded.
  final List<FootageFile> _files = [];

  /// Share the phone's location with the report (the citizen can switch it off).
  bool _shareLocation = true;

  // Sending state
  bool _sending = false;
  SendProgress? _progress;
  String? _sendError;

  // Set when sending stopped part-way: Try again carries on from here.
  int? _resumeIncidentId;
  int _alreadyUploaded = 0;

  int get _room => CitizenStore.maxFiles - _files.length;

  @override
  void dispose() {
    // Controllers own resources; release them when this page is removed.
    _locationController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<FootageFile> _toFootage(XFile file) async => FootageFile(
        name: file.name,
        size: await file.length(),
        readBytes: file.readAsBytes,
        mimeType: file.mimeType,
      );

  Future<void> _addFiles(List<XFile> picked) async {
    if (picked.isEmpty) return;
    final footage = [for (final f in picked.take(_room)) await _toFootage(f)];
    if (!mounted) return;
    setState(() {
      _files.addAll(footage);
      _sendError = null;
    });
    if (picked.length > footage.length) {
      _showMessage('Only ${CitizenStore.maxFiles} files fit in one report.');
    }
  }

  /// Opens the gallery for videos and photos (up to the files still allowed).
  Future<void> _chooseFromGallery() async {
    if (_sending) return;
    if (_room <= 0) {
      _showMessage('A report can have at most ${CitizenStore.maxFiles} files.');
      return;
    }
    try {
      // pickMultipleMedia needs a limit of at least 2
      final picked = _room == 1
          ? [?await _picker.pickMedia()]
          : await _picker.pickMultipleMedia(limit: _room);
      await _addFiles(picked);
    } catch (error) {
      if (mounted) _showMessage('Could not open gallery: $error');
    }
  }

  /// Opens the device camera to record a video; errors appear in a SnackBar.
  Future<void> _recordVideo() async {
    if (_sending) return;
    if (_room <= 0) {
      _showMessage('A report can have at most ${CitizenStore.maxFiles} files.');
      return;
    }
    try {
      final file = await _picker.pickVideo(source: ImageSource.camera);
      if (file != null) await _addFiles([file]);
    } catch (error) {
      if (mounted) _showMessage('Could not open camera: $error');
    }
  }

  void _removeFile(int index) {
    if (_sending || _resumeIncidentId != null) return; // files already sent stay
    setState(() => _files.removeAt(index));
  }

  /// Displays brief feedback at the bottom of the dashboard.
  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Validates the form and sends the report (or carries on after a failure).
  Future<void> _submitReport() async {
    if (_sending) return;
    // Run the validators attached to both TextFormField widgets.
    final fieldsValid = _formKey.currentState!.validate();
    if (_files.isEmpty) {
      _showMessage('Please select or record footage first.');
      return;
    }
    if (!fieldsValid) return;

    setState(() {
      _sending = true;
      _sendError = null;
      _progress = const SendProgress('Preparing your report…', 0.01);
    });

    (double, double)? gps;
    if (_shareLocation && _resumeIncidentId == null) {
      setState(() => _progress = const SendProgress('Getting your location…', 0.02));
      gps = await (widget.getLocation ?? currentPhoneLocation)();
    }

    try {
      final incidentId = await widget.store.sendReport(
        location: _locationController.text,
        description: _descriptionController.text,
        files: List.of(_files),
        latitude: gps?.$1,
        longitude: gps?.$2,
        resumeIncidentId: _resumeIncidentId,
        alreadyUploaded: _alreadyUploaded,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      // Clear only after the report is safely sent.
      _locationController.clear();
      _descriptionController.clear();
      setState(() {
        _files.clear();
        _sending = false;
        _progress = null;
        _resumeIncidentId = null;
        _alreadyUploaded = 0;
      });
      final reference = 'INC-${incidentId.toString().padLeft(4, '0')}';
      _showMessage('Report $reference sent. Thank you - it will be analysed shortly.');
      // Tab indexes start at zero: Upload = 0, Submissions = 1, Profile = 2.
      DefaultTabController.maybeOf(context)?.animateTo(1);
    } on ArgumentError catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _progress = null;
      });
      _showMessage('${e.message}');
    } on SendReportFailed catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _progress = null;
        _sendError = e.message;
        _resumeIncidentId = e.incidentId;
        _alreadyUploaded = e.uploaded;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Required by AutomaticKeepAliveClientMixin to retain the page state.
    super.build(context);
    final resuming = _resumeIncidentId != null;
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
              'robbery, select your footage here (up to 5 videos or photos).',
              style: AppText.body,
            ),
            const SizedBox(height: AppSpacing.medium),

            // Footage box from the mock-up.
            InkWell(
              onTap: _sending || resuming ? null : _chooseFromGallery,
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
                      _files.isEmpty
                          ? 'Tap to select videos or images'
                          : _room > 0
                              ? 'Tap to add more (${_files.length} of ${CitizenStore.maxFiles})'
                              : '${CitizenStore.maxFiles} of ${CitizenStore.maxFiles} files selected',
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

            // The selected files
            for (var i = 0; i < _files.length; i++)
              _FileRow(
                file: _files[i],
                sent: i < _alreadyUploaded,
                onRemove: _sending || resuming ? null : () => _removeFile(i),
              ),
            const SizedBox(height: AppSpacing.medium),

            // Recording live is the urgent action, so it uses the danger colour;
            // shape and text colour come from the theme.
            Center(
              child: ElevatedButton(
                onPressed: _sending || resuming ? null : _recordVideo,
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
              enabled: !_sending && !resuming,
              decoration: const InputDecoration(hintText: 'e.g. N1 Southbound'),
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Enter the incident location'
                  : null,
            ),
            const SizedBox(height: AppSpacing.small),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _shareLocation,
              onChanged: _sending || resuming
                  ? null
                  : (v) => setState(() => _shareLocation = v),
              activeThumbColor: AppColors.accent,
              title: const Text("Share my phone's location", style: AppText.body),
              subtitle: const Text(
                'Helps link your report to other reports of the same incident. '
                'Only used for this report.',
                style: AppText.bodyMuted,
              ),
            ),
            const SizedBox(height: AppSpacing.small),

            const FieldLabel('Description*'),
            TextFormField(
              controller: _descriptionController,
              enabled: !_sending && !resuming,
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
                'Your footage and report are sent securely to Argus Shield. '
                'Only authorised administrators and investigators can see them. '
                'The footage is analysed by AI (vehicles, number plates, people, '
                'weapons) to help investigators; a person always checks the results.',
                textAlign: TextAlign.center,
                style: AppText.bodyMuted,
              ),
            ),
            const SizedBox(height: AppSpacing.large),

            if (_progress != null) ...[
              LinearProgressIndicator(
                value: _progress!.fraction,
                color: AppColors.accent,
                backgroundColor: AppColors.header,
              ),
              const SizedBox(height: 8),
              Text(_progress!.message, style: AppText.bodyMuted),
              const SizedBox(height: AppSpacing.medium),
            ],
            if (_sendError != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.danger),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(_sendError!,
                    style: AppText.body.copyWith(color: AppColors.danger)),
              ),
              const SizedBox(height: AppSpacing.medium),
            ],

            Center(
              child: PrimaryButton(
                label: _sending
                    ? 'Sending…'
                    : resuming
                        ? 'Try again'
                        : 'Submit Report',
                onPressed: _sending ? null : _submitReport,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One selected file: name, size, remove button (or "sent" after a
/// partial upload).
class _FileRow extends StatelessWidget {
  final FootageFile file;
  final bool sent;
  final VoidCallback? onRemove;

  const _FileRow({required this.file, required this.sent, this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Icon(
            file.mediaType == 'image' ? Icons.image_outlined : Icons.videocam_outlined,
            color: AppColors.accent,
            size: 20,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(file.name,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body),
          ),
          const SizedBox(width: 8),
          Text(
            file.size > 50 * 1024 * 1024 ? '${file.sizeLabel} - too big' : file.sizeLabel,
            style: AppText.bodyMuted.copyWith(
                color: file.size > 50 * 1024 * 1024 ? AppColors.danger : null),
          ),
          if (sent)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Icon(Icons.check_circle, color: AppColors.success, size: 20),
            )
          else
            IconButton(
              icon: const Icon(Icons.close, size: 20, color: AppColors.textMuted),
              tooltip: 'Remove',
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }
}
