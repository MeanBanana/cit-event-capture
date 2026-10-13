// crime_scene_card.dart — one crime scene of a case, as a small card:
//
//   INC-0042                                   [ANALYSED]
//   ─────────────────────────────────────────────────────
//   📍 Rivonia Rd, Sandton
//   ≡  Two men with a rifle stopped the van at the robot ...
//   [👤 2 suspects] [🚗 1 vehicle] [⚠ 1 weapon]
//
// Tapping it opens the crime scene page (crime_scene_page.dart) with the
// footage, everything the AI found and the corrections. Used on the
// investigator's case page and the admin's.

import 'package:flutter/material.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/models/crime_scene.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';

/// Label, colour and icon for where the AI is with a crime scene.
(String, Color, IconData) analysisStyle(AnalysisStatus status,
    {int filesFailed = 0}) {
  return switch (status) {
    AnalysisStatus.noFootage => ('No footage', AppColors.textHint, Icons.videocam_off_outlined),
    AnalysisStatus.pending => ('Waiting for AI', AppColors.textHint, Icons.hourglass_empty),
    AnalysisStatus.analysing => ('AI analysing', AppColors.accent, Icons.autorenew),
    AnalysisStatus.failed => ('Analysis failed', AppColors.danger, Icons.error_outline),
    AnalysisStatus.done => filesFailed > 0
        ? ('Partly analysed', AppColors.accent, Icons.check_circle_outline)
        : ('Analysed', AppColors.success, Icons.check_circle_outline),
  };
}

/// One sentence about where the AI is, or null when it is simply done.
String? analysisMessage(AnalysisStatus status,
    {int files = 0, int filesFailed = 0}) {
  return switch (status) {
    AnalysisStatus.noFootage => 'No footage was sent with this report.',
    AnalysisStatus.pending =>
      'The footage (${plural(files, 'file')}) is waiting to be analysed by the AI. '
          'Findings and corrections will be available once it is done.',
    AnalysisStatus.analysing =>
      'The AI is analysing the footage right now. '
          'Findings and corrections will be available once it is done.',
    AnalysisStatus.failed =>
      'The AI could not analyse this footage. Ask an admin to send it for analysis again.',
    AnalysisStatus.done => filesFailed > 0
        ? '${plural(filesFailed, 'file')} could not be analysed; the rest was.'
        : null,
  };
}

/// The status tag shown on cards and at the top of the crime scene page.
class AnalysisTag extends StatelessWidget {
  final AnalysisStatus status;
  final int filesFailed;

  const AnalysisTag({super.key, required this.status, this.filesFailed = 0});

  @override
  Widget build(BuildContext context) {
    final (label, color, _) = analysisStyle(status, filesFailed: filesFailed);
    return StatusTag(label: label, color: color);
  }
}

class CaseSceneCard extends StatelessWidget {
  final CrimeSceneCardInfo scene;
  final VoidCallback? onTap;

  /// Optional ⋮ menu (the admin's case page: move / remove).
  final Widget? menu;

  const CaseSceneCard({
    super.key,
    required this.scene,
    this.onTap,
    this.menu,
  });

  @override
  Widget build(BuildContext context) {
    final s = scene;
    final description = s.description?.trim() ?? '';
    final counted = s.analysis == AnalysisStatus.done;

    // Same parts as the admin's submission cards (submissions.dart
    // CrimeSceneCard): AdminCard, Courier reference + status tag, divider,
    // icon lines and fact chips - with fewer lines, so it stays compact.
    // Grey outline like the admin's submission cards: they only turn gold
    // for submissions still pending review, and every crime scene in a case
    // has been accepted.
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AdminCard(
        onTap: onTap,
        borderColor: AppColors.fieldBorder,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    s.isDuplicate ? '${s.reference} · dup.' : s.reference,
                    style: AppText.cardTitle,
                  ),
                ),
                const SizedBox(width: AppSpacing.small),
                AnalysisTag(status: s.analysis, filesFailed: s.filesFailed),
                ?menu,
              ],
            ),
            const SizedBox(height: 10),
            const Divider(color: AppColors.fieldBorder, height: 1),
            const SizedBox(height: 10),
            DetailLine(icon: Icons.location_on_outlined, text: s.location),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.notes, size: 18, color: AppColors.accent),
                const SizedBox(width: AppSpacing.small),
                Expanded(
                  child: Text(
                    description.isEmpty ? 'No description given.' : description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: description.isEmpty
                        ? AppText.bodyMuted
                            .copyWith(fontStyle: FontStyle.italic)
                        : AppText.body.copyWith(fontSize: 15),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                FactChip(
                  counted ? plural(s.suspects, 'suspect') : 'Suspects: –',
                  icon: Icons.person_search_outlined,
                  color: counted && s.suspects > 0
                      ? AppColors.accent
                      : AppColors.textMuted,
                ),
                FactChip(
                  counted ? plural(s.vehicles, 'vehicle') : 'Vehicles: –',
                  icon: Icons.directions_car_outlined,
                ),
                FactChip(
                  counted ? plural(s.weapons, 'weapon') : 'Weapons: –',
                  icon: Icons.warning_amber_outlined,
                  color: counted && s.weapons > 0
                      ? AppColors.danger
                      : AppColors.textMuted,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
