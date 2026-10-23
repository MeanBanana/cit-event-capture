// Every picture of one person/vehicle/weapon in a case, across all its
// submissions.
//
//   Person 1                     top black, bottom blue · face seen
//   Top black (82%) · Bottom blue (64%) · Face seen
//   [ Is this Person 1?  pictures  reasons   [No] [Yes] ]   (open questions)
//   [ Same as another person?  [Person 1 ▾]  [Combine] ]    (cases only)
//   ┌───┬───┬───┐
//   │   │   │   │   3 columns, grows as submissions add pictures
//   ├───┼───┼───┤
//   ...
// Tap a picture to see it big (pinch to zoom) with a Download button that
// saves it to the gallery.

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/theme/argus_widgets.dart';
import 'package:argus_shield/models/case_evidence.dart';
import 'package:argus_shield/case_evidence_source.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';

class EntityCropsPage extends StatefulWidget {
  final int caseId;

  /// Which entry to show. [entityId] ("p1") on a case, or [detectionId] on a
  /// crime scene/submission, where the label numbers can differ.
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

  /// The entry being shown. Switches to the other one after combining.
  late String? _entityId = widget.entityId;

  /// The case's other entries of the same kind, for "Same as...".
  List<EvidenceEntity> _others = const [];
  bool _loading = true;
  bool _busy = false;

  /// The source as an [EntityCombiner], or null if it can't combine. We go
  /// through Object first because EntityCombiner isn't a subtype of
  /// CaseEvidenceSource, so an `is` check on the source wouldn't narrow it.
  EntityCombiner? get _combiner {
    final Object source = widget.source;
    return source is EntityCombiner ? source : null;
  }

  /// Only cases can combine, not a single submission's clips.
  bool get _canCombine =>
      widget.detectionId == null && (_combiner?.canCombine ?? false);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final evidence = await widget.source.load(widget.caseId);
    if (!mounted) return;
    final all = [...?evidence?.people, ...?evidence?.vehicles, ...?evidence?.weapons];
    EvidenceEntity? found;
    for (final e in all) {
      final match = widget.detectionId != null
          ? e.detectionId == widget.detectionId
          : e.entityId == _entityId;
      if (match) found = e;
    }
    final shown = found;
    setState(() {
      _entity = shown;
      _others = shown == null
          ? const []
          : [
              for (final e in all)
                if (e.kind == shown.kind && e.entityId != shown.entityId) e,
            ];
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

  /// "This is the same as [target]": confirm, move all of this entry's
  /// pictures over to [target], then show [target].
  Future<void> _combine(EvidenceEntity target) async {
    final e = _entity;
    final combiner = _combiner;
    if (e == null || combiner == null) return;
    final pictures = plural(e.crops.length, 'picture');
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Combine ${e.label} with ${target.label}?'),
        content: Text(
            '${e.label} and ${target.label} will become one ${e.kind}: '
            '${e.label}\'s $pictures move to ${target.label} and '
            '${e.label} is removed from the case.\n\n'
            'The AI will not split them again, so only do this if you are '
            'sure it is the same ${e.kind}.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Combine'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final into = await combiner.combine(widget.caseId, e.entityId, target.entityId);
      _entityId = into;
      if (mounted) {
        showSnack(context,
            '${e.label} combined with ${target.label}. The AI is updating the details.');
      }
    } catch (err) {
      if (mounted) showSnack(context, errorText(err));
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
        if (_canCombine && _others.isNotEmpty)
          _CombineCard(
            key: ValueKey('combine-${e.entityId}'),
            entity: e,
            others: _others,
            onCombine: _busy ? null : _combine,
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

/// A grid square: the picture with its submission underneath.
class _CropTile extends StatelessWidget {
  final EvidenceCrop crop;
  final CaseEvidenceSource source;
  final VoidCallback onTap;

  const _CropTile(
      {required this.crop, required this.source, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: panelColor(context),
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
                  color: AppColors.neutral),
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

/// "Is this Person 1?" with the new pictures, the reasons and Yes/No.
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
        color: cardColor(context),
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
          // Wrap rather than Row, on narrow phones the buttons don't fit
          // side by side so the second one drops to the next line
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

/// "Same as another person?": pick Person 1/2/3... and combine.
class _CombineCard extends StatefulWidget {
  final EvidenceEntity entity;
  final List<EvidenceEntity> others;
  final ValueChanged<EvidenceEntity>? onCombine;

  const _CombineCard({
    super.key,
    required this.entity,
    required this.others,
    required this.onCombine,
  });

  @override
  State<_CombineCard> createState() => _CombineCardState();
}

class _CombineCardState extends State<_CombineCard> {
  String? _picked;

  @override
  Widget build(BuildContext context) {
    final e = widget.entity;
    final kind = e.kind;
    final target = widget.others.where((o) => o.entityId == _picked).firstOrNull;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cardColor(context),
        border: Border.all(color: AppColors.fieldBorder),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Same $kind as another one?',
              style: AppText.body.copyWith(fontWeight: FontWeight.bold)),
          Text(
            'If ${e.label} is really one of the others, combine them: '
            'all of ${e.label}\'s pictures move there.',
            style: AppText.bodyMuted.copyWith(fontSize: 13),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            key: const ValueKey('combine-target'),
            initialValue: _picked,
            isExpanded: true,
            dropdownColor: cardColor(context),
            decoration: InputDecoration(
              labelText: '${e.label} is the same as',
              isDense: true,
            ),
            items: [
              for (final o in widget.others)
                DropdownMenuItem(
                  value: o.entityId,
                  child: Text(
                    o.summaryLine.isEmpty ? o.label : '${o.label} · ${o.summaryLine}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: widget.onCombine == null
                ? null
                : (value) => setState(() => _picked = value),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: SmallActionButton(
              label: target == null ? 'Combine' : 'Combine with ${target.label}',
              color: AppColors.accent,
              onPressed: target == null || widget.onCombine == null
                  ? null
                  : () => widget.onCombine!(target),
            ),
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
      backgroundColor: cardColor(context),
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
                  icon: const Icon(Icons.close, color: AppColors.neutral),
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
                      color: AppColors.neutral, size: 48),
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
