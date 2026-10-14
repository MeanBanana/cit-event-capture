// entity_crops_page.dart — every picture of ONE person / vehicle / weapon in
// a case, from all of the case's submissions.
//
//   Person 1                     top black, bottom blue · face seen
//   Top black (82%) · Bottom blue (64%) · Face seen
//   [ Is this Person 1?  pictures  reasons   [No] [Yes] ]   (open questions)
//   ┌───┬───┬───┐
//   │   │   │   │   3 columns; grows as submissions add pictures
//   ├───┼───┼───┤
//   ...
// Tap a picture: it opens large (pinch to zoom) with a Download button that
// saves it to the phone's gallery.

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/theme/argus_widgets.dart';
import 'package:argus_shield/models/case_evidence.dart';
import 'package:argus_shield/case_evidence_source.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';

class EntityCropsPage extends StatefulWidget {
  final int caseId;

  /// Which entry to show: [entityId] ("p1"), or on a crime scene / submission
  /// the [detectionId] of the detection (labels can be numbered differently).
  final String? entityId;
  final int? detectionId;
  final CaseEvidenceSource source;

  const EntityCropsPage({
    super.key,
    required this.caseId,
    this.entityId,
    this.detectionId,
    required this.source,
  }) : assert(entityId != null || detectionId != null);

  @override
  State<EntityCropsPage> createState() => _EntityCropsPageState();
}

class _EntityCropsPageState extends State<EntityCropsPage> {
  EvidenceEntity? _entity;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final evidence = await widget.source.load(widget.caseId);
    if (!mounted) return;
    EvidenceEntity? found;
    for (final e in [...?evidence?.people, ...?evidence?.vehicles, ...?evidence?.weapons]) {
      final match = widget.detectionId != null
          ? e.detectionId == widget.detectionId
          : e.entityId == widget.entityId;
      if (match) found = e;
    }
    setState(() {
      _entity = found;
      _loading = false;
    });
  }

  Future<void> _answer(MatchQuestion q, bool yes) async {
    final label = _entity?.label ?? 'this';
    setState(() => _busy = true);
    try {
      await widget.source.answer(widget.caseId, q.memberKey, yes: yes);
      if (mounted) {
        showSnack(context,
            yes ? 'Added to $label' : 'Kept separate from $label');
      }
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    }
    await _load();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final e = _entity;
    return Scaffold(
      appBar: const ArgusAppBar(roleLabel: 'Admin'),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : e == null
              ? const Center(
                  child: Text('Not found in this case any more.',
                      style: AppText.bodyMuted))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                        sliver: SliverToBoxAdapter(child: _header(e)),
                      ),
                      if (e.crops.isEmpty)
                        const SliverPadding(
                          padding: EdgeInsets.all(16),
                          sliver: SliverToBoxAdapter(
                            child: Text('No pictures yet.',
                                style: AppText.bodyMuted),
                          ),
                        ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 30),
                        sliver: SliverGrid.builder(
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            mainAxisSpacing: 6,
                            crossAxisSpacing: 6,
                          ),
                          itemCount: e.crops.length,
                          itemBuilder: (context, i) => _CropTile(
                            crop: e.crops[i],
                            source: widget.source,
                            onTap: () => showCropViewer(
                                context, widget.source, e.crops[i], e.label),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }

  Widget _header(EvidenceEntity e) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(e.label, style: AppText.sectionTitle),
        const SizedBox(height: 4),
        Text(e.summaryLine, style: AppText.body.copyWith(fontSize: 15)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (label, value) in e.detailLines)
              FactChip('$label: $value'),
            FactChip(plural(e.submissionCount, 'submission'),
                icon: Icons.video_library_outlined),
          ],
        ),
        for (final u in e.updated)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: DetailLine(icon: Icons.update, text: 'Updated ${u.text}'),
          ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(),
          ),
        for (final q in e.questions)
          _QuestionCard(
            label: e.label,
            question: q,
            source: widget.source,
            onAnswer: _busy ? null : (yes) => _answer(q, yes),
          ),
        SectionLabel('Pictures (${e.crops.length})'),
        Text('AI-found pictures from every submission in the case. '
            'Tap one to enlarge or download it.',
            style: AppText.bodyMuted.copyWith(fontSize: 13)),
        const SizedBox(height: 8),
      ],
    );
  }
}

/// One square in the grid: the picture with its submission underneath.
class _CropTile extends StatelessWidget {
  final EvidenceCrop crop;
  final CaseEvidenceSource source;
  final VoidCallback onTap;

  const _CropTile(
      {required this.crop, required this.source, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.header,
      borderRadius: BorderRadius.circular(4),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image(
              image: source.image(crop.path),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined,
                  color: AppColors.textHint),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                color: Colors.black54,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Text(
                  'S${crop.submission ?? '?'} · ${crop.type}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption.copyWith(fontSize: 10),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Is this Person 1?" with the new pictures, the reasons and Yes / No.
class _QuestionCard extends StatelessWidget {
  final String label;
  final MatchQuestion question;
  final CaseEvidenceSource source;
  final ValueChanged<bool>? onAnswer;

  const _QuestionCard({
    required this.label,
    required this.question,
    required this.source,
    required this.onAnswer,
  });

  @override
  Widget build(BuildContext context) {
    final q = question;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.header,
        border: Border.all(color: AppColors.accent),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Is this $label?',
              style: AppText.body.copyWith(
                  fontWeight: FontWeight.bold, color: AppColors.accent)),
          Text(
            'Possible match from submission ${q.submission ?? '?'}'
            '${q.fileName.isEmpty ? '' : ' (${q.fileName})'}',
            style: AppText.bodyMuted.copyWith(fontSize: 13),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 90,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: q.crops.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (context, i) => SizedBox(
                width: 90,
                child: _CropTile(
                  crop: q.crops[i],
                  source: source,
                  onTap: () => showCropViewer(context, source, q.crops[i],
                      'Possible $label'),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final r in q.reasons) FactChip(r)],
          ),
          const SizedBox(height: 4),
          Text('AI suggestion only – check the pictures before answering.',
              style: AppText.bodyMuted.copyWith(
                  fontSize: 12, fontStyle: FontStyle.italic)),
          const SizedBox(height: 8),
          // Wrap, not Row: on a narrow phone the two buttons don't fit side
          // by side, so the second one moves to the next line
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              SmallActionButton(
                label: 'No, someone else',
                color: AppColors.danger,
                onPressed: onAnswer == null ? null : () => onAnswer!(false),
              ),
              SmallActionButton(
                label: 'Yes, same',
                color: AppColors.success,
                onPressed: onAnswer == null ? null : () => onAnswer!(true),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The enlarged picture (pinch to zoom) with a Download button.
Future<void> showCropViewer(BuildContext context, CaseEvidenceSource source,
    EvidenceCrop crop, String title) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      backgroundColor: AppColors.header,
      insetPadding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 4, 0),
            child: Row(
              children: [
                Expanded(child: Text(title, style: AppText.cardTitle)),
                IconButton(
                  icon: const Icon(Icons.close, color: AppColors.textMuted),
                  tooltip: 'Close',
                  onPressed: () => Navigator.pop(dialogContext),
                ),
              ],
            ),
          ),
          Flexible(
            child: InteractiveViewer(
              maxScale: 6,
              child: Image(
                image: source.image(crop.path),
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const Padding(
                  padding: EdgeInsets.all(40),
                  child: Icon(Icons.broken_image_outlined,
                      color: AppColors.textHint, size: 48),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              [
                crop.caption,
                if (crop.fileName.isNotEmpty) crop.fileName,
                if (crop.captureTime != null) formatDateTime(crop.captureTime!),
              ].join(' · '),
              style: AppText.bodyMuted.copyWith(fontSize: 12),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: _DownloadButton(source: source, crop: crop),
          ),
        ],
      ),
    ),
  );
}

class _DownloadButton extends StatefulWidget {
  final CaseEvidenceSource source;
  final EvidenceCrop crop;

  const _DownloadButton({required this.source, required this.crop});

  @override
  State<_DownloadButton> createState() => _DownloadButtonState();
}

class _DownloadButtonState extends State<_DownloadButton> {
  bool _saving = false;

  Future<void> _download() async {
    setState(() => _saving = true);
    String message;
    try {
      if (!await Gal.hasAccess()) await Gal.requestAccess();
      final bytes = await widget.source.bytes(widget.crop.path);
      final name = widget.crop.downloadName.replaceAll(RegExp(r'\.\w+$'), '');
      await Gal.putImageBytes(bytes, name: name);
      message = 'Saved to your gallery';
    } on GalException catch (e) {
      message = e.type == GalExceptionType.accessDenied
          ? 'Allow photo access in Settings to download pictures'
          : 'Could not save the picture (${e.type.name})';
    } catch (e) {
      message = 'Could not download the picture';
    }
    if (!mounted) return;
    setState(() => _saving = false);
    showSnack(context, message);
  }

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: _saving ? null : _download,
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.accent,
        foregroundColor: AppColors.header,
        minimumSize: const Size.fromHeight(46),
      ),
      icon: _saving
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.download),
      label: const Text('Download'),
    );
  }
}
