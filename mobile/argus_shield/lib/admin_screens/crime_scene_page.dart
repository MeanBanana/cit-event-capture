// Full page for one crime scene in a case, opened from its card on the case
// page (investigators and admins).
//
//   INC-0042                                       [ANALYSED]
//   Part of CASE-0003 · N1 Midrand CIT robbery
//   Two men with a rifle stopped the cash van ...
//   📍 Rivonia Rd, Sandton   🕑 12/10/2026 10:01 (footage time)
//   [2 suspects] [1 vehicle] [1 weapon]
//   ┌ Footage (2) ┬ Findings (4) ┬ Log (1) ┐
//
// Footage comes first since that's what the investigator usually wants.
// Findings has the AI summary and every person/vehicle/weapon with a Correct
// button. Log lists every correction on this scene.
//
// The header stays put across tabs so the key facts are always visible.
// While the AI hasn't finished, the header says so and we poll every few
// seconds; findings and Correct buttons show up once it's done. Corrections
// go through correct_detection() and land in correctionlog against this scene.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/theme/argus_widgets.dart';
import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/case_evidence_source.dart';
import 'package:argus_shield/submission_evidence_source.dart';
import 'package:argus_shield/models/crime_scene.dart';
import 'package:argus_shield/models/submission_groups.dart' show MediaItem;
import 'package:argus_shield/admin_screens/admin_ui.dart';
import 'package:argus_shield/admin_screens/crime_scene_card.dart';
import 'package:argus_shield/admin_screens/entity_crops_page.dart';
import 'package:argus_shield/admin_screens/footage_list.dart'
    show ClipCard, usesRealDatabase;
import 'package:argus_shield/admin_screens/media_viewer_page.dart';
import 'package:argus_shield/admin_screens/pickers.dart' show showAdminSheet;

class CrimeScenePage extends StatefulWidget {
  final int incidentId;

  /// Tests pass a fake in here, the app just uses the real one.
  final SupabaseService? service;

  /// 'Investigator' or 'Admin', for the top bar and footage viewer.
  final String roleLabel;

  /// Where the AI pictures come from. Null means the bucket with the real
  /// service, or no pictures at all with a fake one (tests).
  final CaseEvidenceSource? pictures;

  /// Where a detection's own pictures come from (the Pictures button). Null
  /// means the submission's detections with the real service, or no
  /// Pictures button with a fake one (tests).
  final CaseEvidenceSource? detectionPictures;

  /// How often to re-check while the AI is busy. Null means don't.
  final Duration? refreshEvery;

  const CrimeScenePage({
    super.key,
    required this.incidentId,
    this.service,
    this.roleLabel = 'Investigator',
    this.pictures,
    this.detectionPictures,
    this.refreshEvery = const Duration(seconds: 20),
  });

  @override
  State<CrimeScenePage> createState() => _CrimeScenePageState();
}

class _CrimeScenePageState extends State<CrimeScenePage> {
  late final SupabaseService _service = widget.service ?? SupabaseService();
  late final bool _realDatabase = usesRealDatabase(widget.service);
  late final CaseEvidenceSource? _pictures = widget.pictures ??
      (_realDatabase ? CaseEvidenceSource.standard : null);
  late final CaseEvidenceSource? _detectionPictures = widget.detectionPictures ??
      (_realDatabase ? SubmissionEvidenceSource() : null);

  CrimeSceneDetail? _scene;
  bool _loading = true;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    _timer?.cancel();
    try {
      final scene = await _service.getCrimeScene(widget.incidentId);
      if (!mounted) return;
      setState(() {
        _scene = scene;
        _error = scene == null ? 'This crime scene no longer exists.' : null;
        _loading = false;
      });
      final every = widget.refreshEvery;
      if (scene != null && scene.analysis.inProgress && every != null) {
        _timer = Timer(every, _load);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load this crime scene. Pull down to try again.';
        _loading = false;
      });
      // One failed check (network blip, say) shouldn't stop us polling if
      // the AI was still busy last time we successfully checked.
      final every = widget.refreshEvery;
      if (_scene != null && _scene!.analysis.inProgress && every != null) {
        _timer = Timer(every, _load);
      }
    }
  }

  Future<void> _correct(SceneDetection d) async {
    final message = await showAdminSheet<String>(
      context,
      title: 'Correct ${d.label}',
      builder: (sheetContext) => CorrectionForm(
        detection: d,
        onSave: (field, value, note) => _service.correctDetection(
            d.detectionId, field, value,
            note: note),
      ),
    );
    if (message != null && mounted) {
      showSnack(context, message);
      await _load();
    }
  }

  Future<void> _openPictures(SceneDetection d, CaseEvidenceSource source) async {
    // match on detection id, the label's number could belong to a different detection
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EntityCropsPage(
          caseId: widget.incidentId,
          detectionId: d.detectionId,
          source: source,
        ),
      ),
    );
  }

  void _view(CrimeSceneDetail s, SceneFile f) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MediaViewerPage(
          storagePath: f.storagePath,
          mediaType: f.mediaType,
          title: '${s.reference} · Clip ${f.number}',
          roleLabel: widget.roleLabel,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _scene;
    return Scaffold(
      appBar: ArgusAppBar(roleLabel: widget.roleLabel),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : s == null
              ? RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: AppSpacing.page,
                    children: [
                      Text(_error ?? 'This crime scene no longer exists.',
                          style: AppText.bodyMuted,
                          textAlign: TextAlign.center),
                    ],
                  ),
                )
              : DefaultTabController(
                  length: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _SceneHeader(
                        scene: s,
                        onRefresh: s.analysis.inProgress ? _load : null,
                      ),
                      Material(
                        color: AppColors.header,
                        child: TabBar(
                          tabs: [
                            Tab(text: 'Footage (${s.files.length})'),
                            Tab(text: 'Findings (${s.detections.length})'),
                            Tab(text: 'Log (${s.corrections.length})'),
                          ],
                        ),
                      ),
                      Expanded(
                        child: TabBarView(
                          children: [
                            _tab(_footageTab(s)),
                            _tab(_findingsTab(s)),
                            _tab(_logTab(s)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }

  /// One tab, a list you can pull down to reload the scene.
  Widget _tab(List<Widget> children) => RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          physics: const AlwaysScrollableScrollPhysics(),
          children: children,
        ),
      );

  List<Widget> _footageTab(CrimeSceneDetail s) => [
        if (s.hasGps)
          DetailLine(
            icon: Icons.my_location,
            text: 'GPS ${s.latitude!.toStringAsFixed(5)}, '
                '${s.longitude!.toStringAsFixed(5)}',
          ),
        if (s.files.isEmpty)
          const Text('No footage was sent with this report.',
              style: AppText.bodyMuted)
        else
          for (final f in s.files)
            ClipCard(
              number: f.number,
              clip: MediaItem(
                mediaId: f.mediaId,
                mediaType: f.mediaType,
                storagePath: f.storagePath,
                captured: f.capturedAt,
                processingStatus: f.status,
                aiDescription: f.aiDescription,
              ),
              onView: f.mediaType == 'audio' || !_realDatabase
                  ? null
                  : () => _view(s, f),
            ),
      ];

  List<Widget> _findingsTab(CrimeSceneDetail s) {
    if (s.analysis.inProgress) {
      return [
        _EmptyState(
          icon: s.analysis == AnalysisStatus.analysing
              ? Icons.autorenew
              : Icons.hourglass_empty,
          text: s.analysis == AnalysisStatus.analysing
              ? 'The AI is still analysing this footage. Its findings will appear here when it is done.'
              : 'Waiting for the AI to analyse this footage. Its findings will appear here when it is done.',
        ),
      ];
    }
    return [
      if (s.aiSummary?.trim().isNotEmpty == true) ...[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.auto_awesome_outlined,
                size: 18, color: AppColors.accent),
            const SizedBox(width: AppSpacing.small),
            Expanded(
              child: Text(s.aiSummary!.trim(),
                  style: AppText.body.copyWith(fontSize: 15)),
            ),
          ],
        ),
        const SizedBox(height: 12),
      ],
      if (s.detections.isEmpty)
        _EmptyState(
          icon: Icons.search_off,
          text: s.analysis == AnalysisStatus.done
              ? 'The AI found no people, vehicles or weapons in this footage.'
              : 'Nothing to show.',
        )
      else ...[
        Text(
          s.canCorrect
              ? 'Something the AI got wrong? Tap Correct. Every change is kept '
                  'in the log.'
              : s.caseClosed
                  ? 'The case is closed: corrections can\'t be made.'
                  : 'Corrections can\'t be made right now.',
          style: AppText.bodyMuted.copyWith(fontSize: 13),
        ),
        for (final (kind, title) in const [
          ('person', 'People'),
          ('vehicle', 'Vehicles'),
          ('weapon', 'Weapons'),
        ])
          if (s.ofKind(kind).isNotEmpty) ...[
            SectionLabel('$title (${s.ofKind(kind).length})'),
            for (final d in s.ofKind(kind))
              DetectionTile(
                detection: d,
                pictures: _pictures,
                onCorrect: d.canCorrect ? () => _correct(d) : null,
                onPictures: _detectionPictures != null && d.crops.isNotEmpty
                    ? () => _openPictures(d, _detectionPictures)
                    : null,
              ),
          ],
      ],
    ];
  }

  List<Widget> _logTab(CrimeSceneDetail s) => [
        if (s.corrections.isEmpty)
          const _EmptyState(
            icon: Icons.history,
            text: 'No corrections yet. Corrections made in the Findings tab '
                'are listed here, with who made them and why.',
          )
        else
          for (final c in s.corrections) _CorrectionRow(entry: c),
      ];
}

/// The top of the page above the tabs: reference and status, what happened,
/// where and when, the counts, and the AI status.
class _SceneHeader extends StatelessWidget {
  final CrimeSceneDetail scene;
  final VoidCallback? onRefresh; // "check again" while the AI is working

  const _SceneHeader({required this.scene, this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final s = scene;
    final description = s.description?.trim() ?? '';
    final message = analysisMessage(s.analysis,
        files: s.fileCount, filesFailed: s.filesFailed);
    // same numbers as the crime scene card (see countOf)
    final count = s.countOf;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(s.reference, style: AppText.sectionTitle)),
              AnalysisTag(status: s.analysis, filesFailed: s.filesFailed),
            ],
          ),
          if (s.caseReference != null)
            Text(
              'Part of ${s.caseReference}'
              '${s.caseTitle == null ? '' : ' · ${s.caseTitle}'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.bodyMuted.copyWith(fontSize: 13),
            ),
          const SizedBox(height: 8),
          Text(
            description.isEmpty ? 'No description given.' : description,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: description.isEmpty
                ? AppText.bodyMuted.copyWith(fontStyle: FontStyle.italic)
                : AppText.body.copyWith(fontSize: 15),
          ),
          const SizedBox(height: 8),
          DetailLine(icon: Icons.place_outlined, text: s.location),
          DetailLine(
            icon: Icons.schedule,
            text: '${formatDateTime(s.bestTime)}'
                '${s.capturedAt == null ? ' (reported time)' : ' (footage time)'}'
                '${s.attackType?.isNotEmpty == true ? ' · ${s.attackType}' : ''}',
          ),
          if (s.analysis == AnalysisStatus.done)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                FactChip(plural(count('person'), 'suspect'),
                    icon: Icons.person_search_outlined),
                FactChip(plural(count('vehicle'), 'vehicle'),
                    icon: Icons.directions_car_outlined),
                FactChip(plural(count('weapon'), 'weapon'),
                    icon: Icons.warning_amber,
                    color: count('weapon') > 0
                        ? AppColors.danger
                        : AppColors.neutral),
              ],
            ),
          if (message != null) ...[
            const SizedBox(height: AppSpacing.small),
            _AnalysisBanner(
              status: s.analysis,
              message: message,
              onRefresh: onRefresh,
            ),
          ],
        ],
      ),
    );
  }
}

/// Icon and a sentence for a tab that has nothing in it (yet).
class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String text;

  const _EmptyState({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.large),
      child: Column(
        children: [
          Icon(icon, size: 40, color: AppColors.neutral),
          const SizedBox(height: 12),
          Text(text,
              textAlign: TextAlign.center,
              style: AppText.bodyMuted.copyWith(fontStyle: FontStyle.italic)),
        ],
      ),
    );
  }
}

/// The "Waiting for the AI..." box at the top.
class _AnalysisBanner extends StatelessWidget {
  final AnalysisStatus status;
  final String message;
  final VoidCallback? onRefresh;

  const _AnalysisBanner({
    required this.status,
    required this.message,
    this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final (_, color, icon) = analysisStyle(status);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          if (status == AnalysisStatus.analysing)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: AppText.body.copyWith(fontSize: 14))),
          if (onRefresh != null)
            IconButton(
              key: const ValueKey('scene-refresh'),
              icon: const Icon(Icons.refresh, color: AppColors.accent),
              tooltip: 'Check again',
              onPressed: onRefresh,
            ),
        ],
      ),
    );
  }
}

/// One person/vehicle/weapon the AI found, with its fields and a Correct
/// button.
class DetectionTile extends StatelessWidget {
  final SceneDetection detection;
  final CaseEvidenceSource? pictures;
  final VoidCallback? onCorrect; // null hides the button
  final VoidCallback? onPictures; // null hides the button

  const DetectionTile({
    super.key,
    required this.detection,
    this.pictures,
    this.onCorrect,
    this.onPictures,
  });

  static IconData iconFor(String kind) => switch (kind) {
        'person' => Icons.person_outline,
        'vehicle' => Icons.directions_car_outlined,
        _ => Icons.report_gmailerrorred_outlined,
      };

  static String _time(double seconds) {
    final s = seconds.round();
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final d = detection;
    final cover = d.crops.isEmpty ? null : d.crops.first;
    final facts = [
      'Clip ${d.clip}',
      if (d.firstSeen != null) 'seen at ${_time(d.firstSeen!)}',
      if (d.kind == 'person' && d.suspectStatus == 'confirmed') 'confirmed suspect',
      if (d.kind == 'person' && d.suspectStatus == 'dismissed') 'not a suspect',
      if (d.correctionCount > 0) plural(d.correctionCount, 'correction'),
    ].join(' · ');

    final details = Opacity(
        opacity: d.dismissed ? 0.6 : 1,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                width: 56,
                height: 56,
                child: cover == null || pictures == null
                    ? ColoredBox(
                        color: panelColor(context),
                        child: Icon(iconFor(d.kind), color: AppColors.neutral),
                      )
                    : Image(
                        image: pictures!.image(cover),
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) =>
                            Icon(iconFor(d.kind), color: AppColors.neutral),
                      ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(d.label,
                          style: AppText.body.copyWith(fontWeight: FontWeight.bold)),
                      if (d.dismissed)
                        const StatusTag(label: 'Not real', color: AppColors.danger),
                      if (d.isCorrected && !d.dismissed)
                        const StatusTag(label: 'Corrected', color: AppColors.accent),
                    ],
                  ),
                  const SizedBox(height: 4),
                  for (final f in d.detailFields)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text.rich(
                        TextSpan(children: [
                          TextSpan(
                              text: '${f.label}: ',
                              style: const TextStyle(color: AppColors.neutral)),
                          TextSpan(
                            text: displayValue(f.field, f.value),
                            style: f.corrected
                                ? const TextStyle(
                                    color: AppColors.accent,
                                    fontWeight: FontWeight.bold)
                                : null,
                          ),
                          if (f.corrected)
                            TextSpan(
                              text: '  (AI: ${displayValue(f.field, f.ai)})',
                              style: const TextStyle(
                                  color: AppColors.neutral, fontSize: 12),
                            ),
                        ]),
                        style: AppText.body.copyWith(fontSize: 14),
                      ),
                    ),
                  const SizedBox(height: 2),
                  Text(facts, style: AppText.bodyMuted.copyWith(fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      );

    return Container(
      key: ValueKey('detection-${d.detectionId}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cardColor(context),
        border: Border.all(
            color: d.dismissed ? AppColors.neutral : AppColors.fieldBorder),
        borderRadius: BorderRadius.circular(4),
      ),
      child: NavyText(
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          details,
          if (onCorrect != null || onPictures != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                if (onCorrect != null)
                  Expanded(
                    child: SecondaryButton(
                      key: ValueKey('correct-${d.detectionId}'),
                      label: d.dismissed ? 'Restore' : 'Correct',
                      icon: d.dismissed ? Icons.undo : Icons.edit_outlined,
                      onPressed: onCorrect,
                    ),
                  ),
                if (onCorrect != null && onPictures != null)
                  const SizedBox(width: 10),
                if (onPictures != null)
                  Expanded(
                    child: SecondaryButton(
                      label: 'Pictures',
                      icon: Icons.photo_library_outlined,
                      color: AppColors.neutral,
                      onPressed: onPictures,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
      ),
    );
  }
}

/// Sheet for correcting a detection: pick a field, type the right value,
/// optionally say why, Save. Or mark it as not real / bring it back. Pops
/// with a snackbar message when something got saved.
class CorrectionForm extends StatefulWidget {
  final SceneDetection detection;

  /// Saves one correction (field, new value or null for none, note).
  final Future<void> Function(String field, String? value, String? note) onSave;

  const CorrectionForm({
    super.key,
    required this.detection,
    required this.onSave,
  });

  @override
  State<CorrectionForm> createState() => _CorrectionFormState();
}

class _CorrectionFormState extends State<CorrectionForm> {
  late DetectionField? _field = widget.detection.detailFields.isEmpty
      ? null
      : widget.detection.detailFields.first;
  late final _value = TextEditingController(text: _field?.value ?? '');
  late String _weaponType =
      weaponTypes.contains(_field?.value) ? _field!.value! : 'unknown';
  final _note = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _value.dispose();
    _note.dispose();
    super.dispose();
  }

  void _pick(DetectionField f) {
    setState(() {
      _field = f;
      _value.text = f.value ?? '';
      _weaponType = weaponTypes.contains(f.value) ? f.value! : 'unknown';
      _error = null;
    });
  }

  Future<void> _save(String field, String? value, String done) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(field, value, _note.text);
      if (mounted) Navigator.pop(context, done);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = errorText(e);
          _saving = false;
        });
      }
    }
  }

  void _saveField() {
    final f = _field;
    if (f == null) return;
    final value =
        f.field == 'weapon_type' ? _weaponType : _value.text.trim();
    _save(f.field, value.isEmpty ? null : value,
        '${widget.detection.label}: ${f.label.toLowerCase()} corrected');
  }

  void _dismiss() {
    if (_note.text.trim().isEmpty) {
      setState(() => _error =
          'Say why this is not a real ${widget.detection.kind} (the reason is kept in the log).');
      return;
    }
    _save('dismissed', 'true',
        '${widget.detection.label} marked as not a real ${widget.detection.kind}');
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.detection;
    final f = _field;

    return ListView(
      children: [
        if (d.dismissed) ...[
          Text(
            '${d.label} is marked as not a real ${d.kind}. Restore it to '
            'correct its details.',
            style: AppText.body,
          ),
        ] else ...[
          const _Step('1', 'What is wrong?'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in d.detailFields)
                ChoiceChip(
                  key: ValueKey('field-${option.field}'),
                  label: Text(option.label),
                  selected: f?.field == option.field,
                  onSelected: _saving ? null : (_) => _pick(option),
                  selectedColor: AppColors.accent,
                  backgroundColor: cardColor(context),
                  labelStyle: AppText.body.copyWith(
                    fontSize: 13,
                    color: f?.field == option.field
                        ? AppColors.header
                        : pageInk(context),
                  ),
                  showCheckmark: false,
                ),
            ],
          ),
          if (f != null) ...[
            const SizedBox(height: 20),
            const _Step('2', 'The right value'),
            Text(
              'AI said: ${displayValue(f.field, f.ai)}'
              '${f.corrected ? ' · now: ${displayValue(f.field, f.value)}' : ''}',
              style: AppText.bodyMuted.copyWith(fontSize: 13),
            ),
            const SizedBox(height: 8),
            if (f.field == 'weapon_type')
              DropdownButtonFormField<String>(
                key: const ValueKey('correct-weapon-type'),
                initialValue: _weaponType,
                dropdownColor: cardColor(context),
                decoration: const InputDecoration(labelText: 'Weapon type'),
                items: [
                  for (final t in weaponTypes)
                    DropdownMenuItem(
                      value: t,
                      child: Text(displayValue('weapon_type', t),
                          style: AppText.body),
                    ),
                ],
                onChanged: _saving
                    ? null
                    : (v) => setState(() => _weaponType = v ?? 'unknown'),
              )
            else
              TextField(
                key: const ValueKey('correct-value'),
                controller: _value,
                enabled: !_saving,
                style: AppText.body,
                textCapitalization: f.field == 'plate'
                    ? TextCapitalization.characters
                    : TextCapitalization.none,
                decoration: InputDecoration(
                  labelText: 'Correct ${f.label.toLowerCase()}',
                  helperText: f.field == 'plate'
                      ? 'Leave empty if the plate can\'t be read'
                      : 'Leave empty if unknown',
                ),
              ),
          ],
        ],
        const SizedBox(height: 20),
        _Step(d.dismissed ? '1' : '3', 'Why? (kept in the log)'),
        TextField(
          key: const ValueKey('correct-note'),
          controller: _note,
          enabled: !_saving,
          style: AppText.body,
          maxLength: 500,
          maxLines: 2,
          decoration: const InputDecoration(
            hintText: 'e.g. The plate is clear in the clip at 0:12',
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(_error!,
                key: const ValueKey('correct-error'),
                style: AppText.bodyMuted.copyWith(color: AppColors.danger)),
          ),
        if (_saving) const LinearProgressIndicator(),
        const SizedBox(height: 8),
        if (!d.dismissed && f != null) ...[
          PrimaryButton(
            key: const ValueKey('correct-save'),
            label: 'Save correction',
            onPressed: _saving ? null : _saveField,
          ),
          if (f.corrected) ...[
            const SizedBox(height: 12),
            SecondaryButton(
              key: const ValueKey('correct-restore'),
              label: 'Use the AI\'s value (${displayValue(f.field, f.ai)})',
              icon: Icons.undo,
              onPressed: _saving
                  ? null
                  : () => _save(f.field, f.ai,
                      '${d.label}: ${f.label.toLowerCase()} back to the AI\'s value'),
            ),
          ],
          const SizedBox(height: 28),
          const Divider(color: AppColors.fieldBorder),
          const SizedBox(height: 12),
          Text(
            'Is this not a ${d.kind} at all (e.g. a shadow or a reflection)? '
            'Write why above, then:',
            style: AppText.bodyMuted.copyWith(fontSize: 13),
          ),
          const SizedBox(height: 8),
          SecondaryButton(
            key: const ValueKey('correct-dismiss'),
            label: 'Not a real ${d.kind}',
            icon: Icons.block,
            color: AppColors.danger,
            onPressed: _saving ? null : _dismiss,
          ),
        ],
        if (d.dismissed)
          PrimaryButton(
            key: const ValueKey('correct-undismiss'),
            label: 'Restore ${d.kind}',
            onPressed: _saving
                ? null
                : () => _save('dismissed', 'false', '${d.label} restored'),
          ),
      ],
    );
  }
}

/// Numbered step heading in the correction form ("2  The right value").
class _Step extends StatelessWidget {
  final String number;
  final String text;

  const _Step(this.number, this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
                color: AppColors.accent, shape: BoxShape.circle),
            child: Text(number,
                style: AppText.body.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppColors.header)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: AppText.body
                    .copyWith(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}

/// One line in the corrections log.
class _CorrectionRow extends StatelessWidget {
  final CorrectionEntry entry;

  const _CorrectionRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    final e = entry;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 3),
            child: Icon(Icons.edit_note, size: 18, color: AppColors.accent),
          ),
          const SizedBox(width: AppSpacing.small),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.text, style: AppText.body.copyWith(fontSize: 14)),
                if (e.note?.trim().isNotEmpty == true)
                  Text('“${e.note!.trim()}”',
                      style: AppText.bodyMuted
                          .copyWith(fontSize: 13, fontStyle: FontStyle.italic)),
                Text(
                  '${formatDateTime(e.at)}${e.byName == null ? '' : ' · ${e.byName}'}',
                  style: AppText.bodyMuted.copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
