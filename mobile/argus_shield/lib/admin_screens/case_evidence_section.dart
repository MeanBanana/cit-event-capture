// case_evidence_section.dart — the AI part of a case page:
//
//   AI SUMMARY   "2 submissions, filmed 11 Oct 14:00 to 14:40. AI found ..."
//   3 people · 2 vehicles · 2 weapons
//   PEOPLE
//     [photo] Person 1   top black, bottom blue · face seen     [View]
//             2 submissions · 7 pictures · 1 to check
//   VEHICLES ...
//   WEAPONS ...
//
// Each person / vehicle / weapon combines every submission in the case that
// shows them (ai/case_matcher.py). "View" opens all of their pictures.

import 'package:flutter/material.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/models/case_evidence.dart';
import 'package:argus_shield/case_evidence_source.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';
import 'package:argus_shield/admin_screens/entity_crops_page.dart';

class CaseEvidenceSection extends StatefulWidget {
  final int caseId;

  /// Optional so tests can pass in a fake; the app uses the standard one.
  final CaseEvidenceSource? source;

  const CaseEvidenceSection({super.key, required this.caseId, this.source});

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
        ),
      ),
    );
    if (mounted) await _load(); // answers may have moved pictures
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: LinearProgressIndicator(),
      );
    }
    final e = _evidence;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel('AI summary'),
        if (e == null)
          Text('No AI analysis for this case yet.',
              style: AppText.bodyMuted.copyWith(fontStyle: FontStyle.italic))
        else ...[
          if (e.isSample)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: FactChip('Sample data – not this case',
                  icon: Icons.science_outlined, color: AppColors.textHint),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.auto_awesome_outlined,
                  size: 18, color: AppColors.accent),
              const SizedBox(width: AppSpacing.small),
              Expanded(
                child: Text(e.aiSummary,
                    style: AppText.body.copyWith(fontSize: 15)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '${plural(e.people.length, 'person', 'people')} · '
            '${plural(e.vehicles.length, 'vehicle')} · '
            '${plural(e.weapons.length, 'weapon')}'
            '${e.openQuestions > 0 ? ' · ${plural(e.openQuestions, 'match', 'matches')} to check' : ''}',
            style: AppText.bodyMuted.copyWith(
                fontSize: 13,
                color: e.openQuestions > 0 ? AppColors.accent : null),
          ),
          for (final (title, group) in [
            ('People', e.people),
            ('Vehicles', e.vehicles),
            ('Weapons', e.weapons),
          ])
            if (group.isNotEmpty) ...[
              SectionLabel(title),
              for (final entity in group)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.small),
                  child: EntityCard(
                    entity: entity,
                    source: _source,
                    onView: () => _open(entity),
                  ),
                ),
            ],
        ],
      ],
    );
  }
}

/// One person / vehicle / weapon: cover picture, label, details, View.
class EntityCard extends StatelessWidget {
  final EvidenceEntity entity;
  final CaseEvidenceSource source;
  final VoidCallback onView;

  const EntityCard({
    super.key,
    required this.entity,
    required this.source,
    required this.onView,
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
      plural(e.submissionCount, 'submission'),
      plural(e.crops.length, 'picture'),
      if (questions > 0) '$questions to check',
    ].join(' · ');

    return AdminCard(
      onTap: onView,
      borderColor: questions > 0 ? AppColors.accent : AppColors.fieldBorder,
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              width: 56,
              height: 56,
              child: e.cover == null
                  ? ColoredBox(
                      color: AppColors.background,
                      child: Icon(iconFor(e.kind), color: AppColors.textHint),
                    )
                  : Image(
                      image: source.image(e.cover!),
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          Icon(iconFor(e.kind), color: AppColors.textHint),
                    ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.label,
                    style: AppText.body.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(e.description,
                    style: AppText.body.copyWith(fontSize: 14)),
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
              label: 'View', color: AppColors.accent, onPressed: onView),
        ],
      ),
    );
  }
}
