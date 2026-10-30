// The AI SUMMARY block for a case or a submission, laid out like the
// pipeline's console output:
//
//   AI SUMMARY
//   ✦ 2 submissions, filmed 11 Oct 14:00 to 14:40. AI found ...
//   2 people · 1 vehicle · 1 weapon
//   [pic] Person 1: top white / bottom black · face visible   [View crops]
//         2 submissions · 7 pictures
//   [pic] Vehicle 1: white Toyota car · plate ND123456        [View crops]
//   [pic] Weapon 1: long gun · held by Person 1               [View crops]
//
// On a case each entry is merged across all its submissions (case_matcher:
// same look or plate = one entry) and the summary covers the whole case. On
// a submission it's just that submission, one entry per clip
// (SubmissionEvidenceSource). View crops opens all of an entry's pictures.

import 'package:flutter/material.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/models/case_evidence.dart';
import 'package:argus_shield/case_evidence_source.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';
import 'package:argus_shield/admin_screens/entity_crops_page.dart';

class CaseEvidenceSection extends StatefulWidget {
  /// Case id on the case page, incident id on the submission page.
  final int caseId;

  /// Tests pass a fake in here, the app uses the standard one.
  final CaseEvidenceSource? source;

  /// Section heading.
  final String title;

  /// Summary text to show. Null means use the case's AI summary from
  /// [source] (the submission page passes its own).
  final String? summary;

  /// Small grey line under the summary, e.g. "Still analysing 1 file".
  final String? summaryNote;

  /// Goes under the summary, e.g. the submission's fact chips.
  final Widget? belowSummary;

  /// True on the submission page, where entries say which clip they're from
  /// rather than how many submissions.
  final bool perSubmission;

  /// Shown when the AI hasn't found anything (yet).
  final String emptyText;

  /// Passed on to the pictures page's app bar.
  final String roleLabel;

  const CaseEvidenceSection({
    super.key,
    required this.caseId,
    this.source,
    this.title = 'AI summary',
    this.summary,
    this.summaryNote,
    this.belowSummary,
    this.perSubmission = false,
    this.emptyText = 'No AI analysis for this case yet.',
    this.roleLabel = 'Admin',
  });

  @override
  State<CaseEvidenceSection> createState() => _CaseEvidenceSectionState();
}

class _CaseEvidenceSectionState extends State<CaseEvidenceSection> {
  late final CaseEvidenceSource _source =
      widget.source ?? CaseEvidenceSource.standard;
  CaseEvidence? _evidence;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CaseEvidenceSection old) {
    super.didUpdateWidget(old);
    if (old.caseId != widget.caseId) _load();
  }

  Future<void> _load() async {
    final evidence = await _source.load(widget.caseId);
    if (!mounted) return;
    setState(() {
      _evidence = evidence;
      _loading = false;
    });
  }

  Future<void> _open(EvidenceEntity entity) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EntityCropsPage(
          caseId: widget.caseId,
          entityId: entity.entityId,
          source: _source,
          roleLabel: widget.roleLabel,
        ),
      ),
    );
    if (mounted) await _load(); // answering may have moved pictures around
  }

  @override
  Widget build(BuildContext context) {
    final e = _evidence;
    final summary = (widget.summary ?? e?.aiSummary ?? '').trim();
    final entities = [
      if (e != null) ...e.people,
      if (e != null) ...e.vehicles,
      if (e != null) ...e.weapons,
    ];
    final open = e?.openQuestions ?? 0;
    final counts = e == null
        ? ''
        : '${plural(e.people.length, 'person', 'people')} · '
            '${plural(e.vehicles.length, 'vehicle')} · '
            '${plural(e.weapons.length, 'weapon')}'
            '${open > 0 ? ' · ${plural(open, 'match', 'matches')} to check' : ''}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionLabel(widget.title),
        if (e != null && e.isSample)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: FactChip('Sample data – not this case',
                icon: Icons.science_outlined, color: AppColors.neutral),
          ),
        if (summary.isNotEmpty)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.auto_awesome_outlined,
                  size: 18, color: AppColors.accent),
              const SizedBox(width: AppSpacing.small),
              Expanded(
                child: Text(summary, style: AppText.body.copyWith(fontSize: 15)),
              ),
            ],
          ),
        if (widget.summaryNote != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(widget.summaryNote!,
                style: AppText.bodyMuted.copyWith(
                    fontSize: 13, fontStyle: FontStyle.italic)),
          ),
        if (widget.belowSummary != null) ...[
          const SizedBox(height: 8),
          widget.belowSummary!,
        ],
        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: LinearProgressIndicator(),
          )
        else if (entities.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(widget.emptyText,
                style: AppText.bodyMuted.copyWith(fontStyle: FontStyle.italic)),
          )
        else ...[
          const SizedBox(height: 10),
          Text(
            counts,
            style: AppText.bodyMuted.copyWith(
                fontSize: 13, color: open > 0 ? AppColors.accent : null),
          ),
          const SizedBox(height: 8),
          for (final entity in entities)
            EntityLine(
              entity: entity,
              source: _source,
              perSubmission: widget.perSubmission,
              onView: () => _open(entity),
            ),
        ],
      ],
    );
  }
}

/// One line of the AI summary:
///   [picture] Person 1: top white / bottom black · face visible  [View crops]
///             2 submissions · 7 pictures · 1 to check
class EntityLine extends StatelessWidget {
  final EvidenceEntity entity;
  final CaseEvidenceSource source;
  final bool perSubmission;
  final VoidCallback onView;

  const EntityLine({
    super.key,
    required this.entity,
    required this.source,
    required this.onView,
    this.perSubmission = false,
  });

  static IconData iconFor(String kind) => switch (kind) {
        'person' => Icons.person_outline,
        'vehicle' => Icons.directions_car_outlined,
        _ => Icons.report_gmailerrorred_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final e = entity;
    final questions = e.questions.length;
    final facts = [
      if (perSubmission && e.clip != null) 'Clip ${e.clip}',
      if (!perSubmission) plural(e.submissionCount, 'submission'),
      plural(e.crops.length, 'picture'),
      if (questions > 0) '$questions to check',
    ].join(' · ');

    return InkWell(
      onTap: onView,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: cardColor(context),
          border: Border.all(
              color: questions > 0 ? AppColors.accent : AppColors.fieldBorder),
          borderRadius: BorderRadius.circular(4),
        ),
        child: NavyText(
          child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                width: 48,
                height: 48,
                child: e.cover == null
                    ? ColoredBox(
                        color: panelColor(context),
                        child: Icon(iconFor(e.kind), color: AppColors.neutral),
                      )
                    : Image(
                        image: source.image(e.cover!),
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) =>
                            Icon(iconFor(e.kind), color: AppColors.neutral),
                      ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(children: [
                      TextSpan(
                          text: '${e.label}: ',
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      TextSpan(text: e.summaryLine),
                    ]),
                    style: AppText.body.copyWith(fontSize: 14),
                  ),
                  const SizedBox(height: 2),
                  Text(facts,
                      style: AppText.bodyMuted.copyWith(
                          fontSize: 12,
                          color: questions > 0 ? AppColors.accent : null)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SmallActionButton(
                label: 'View crops', color: AppColors.accent, onPressed: onView),
          ],
        ),
        ),
      ),
    );
  }
}
