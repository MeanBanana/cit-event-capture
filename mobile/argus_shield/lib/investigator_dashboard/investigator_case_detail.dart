import 'package:flutter/material.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';
import 'package:argus_shield/admin_screens/case_evidence_section.dart';
import 'package:argus_shield/admin_screens/crime_scene_card.dart';
import 'package:argus_shield/admin_screens/crime_scene_page.dart';
import 'package:argus_shield/admin_screens/footage_list.dart'
    show usesRealDatabase;
import 'package:argus_shield/case_evidence_source.dart';
import 'package:argus_shield/models/case_summary.dart';
import 'package:argus_shield/models/crime_scene.dart';
import 'package:argus_shield/models/submission_groups.dart';
import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/theme/app_theme.dart';

/// Assigned-case brief for investigators. Administrative review and
/// assignment controls are intentionally omitted from this surface.
///
///   N1 Midrand CIT robbery                       [OPEN]  Mark under review
///   Two vans hit on the N1 ...
///   ┌ Crime scenes (2) ┬ AI summary ┬ Activity ┐
///   │ [card] INC-0042 · description · location · 2 suspects ...      │
///   │ [card] INC-0043 · ...                                          │
///
/// The crime scenes are the first tab, so they are what an investigator
/// sees on opening a case (no scrolling past the AI summary). Each card
/// opens the crime scene page: its footage, everything the AI found and the
/// corrections (crime_scene_page.dart). The case-wide AI summary (people /
/// vehicles / weapons combined over all crime scenes) and the case history
/// have their own tabs.
class InvestigatorCaseDetailPage extends StatefulWidget {
  final int caseId;
  final SupabaseService? service;

  const InvestigatorCaseDetailPage({
    super.key,
    required this.caseId,
    this.service,
  });

  @override
  State<InvestigatorCaseDetailPage> createState() =>
      _InvestigatorCaseDetailPageState();
}

class _InvestigatorCaseDetailPageState
    extends State<InvestigatorCaseDetailPage> {
  late final SupabaseService _service = widget.service ?? SupabaseService();

  /// The AI pictures read Supabase directly: not with the fake services of
  /// the widget tests.
  late final bool _showEvidence = usesRealDatabase(widget.service);

  /// Padding of each tab's list.
  static const _tabPadding = EdgeInsets.fromLTRB(16, 16, 16, 32);

  /// Changes on pull-to-refresh, so the AI summary loads again.
  int _version = 0;
  CaseSummary? _case;
  List<CrimeSceneCardInfo> _scenes = const [];
  List<CaseEvent> _events = const [];
  bool _loading = true;
  bool _updating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        _service.getCase(widget.caseId),
        _service.listCaseCrimeScenes(widget.caseId),
        _service.getCaseEvents(widget.caseId, limit: 30),
      ]);
      if (!mounted) return;
      setState(() {
        _case = results[0] as CaseSummary?;
        _scenes = results[1] as List<CrimeSceneCardInfo>;
        _events = results[2] as List<CaseEvent>;
        _version++;
        _error = _case == null ? 'This case is no longer available.' : null;
        _loading = false;
      });
    } catch (error) {
      debugPrint('Could not load case ${widget.caseId}: $error');
      if (!mounted) return;
      setState(() {
        _error = 'Could not load this case. Pull down to try again.';
        _loading = false;
      });
    }
  }

  Future<void> _changeStatus(String status) async {
    final current = _case;
    if (current == null || _updating) return;
    setState(() => _updating = true);
    try {
      await _service.updateCase(current.caseId, status: status);
      if (mounted) {
        final label = status == 'under_review' ? 'under review' : 'open';
        showSnack(context, '${current.reference} marked $label');
      }
      await _load();
    } catch (error) {
      if (mounted) showSnack(context, errorText(error));
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  Future<void> _openScene(CrimeSceneCardInfo scene) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CrimeScenePage(
          incidentId: scene.incidentId,
          service: widget.service,
          roleLabel: 'Investigator',
        ),
      ),
    );
    // corrections change the counts and the case's AI summary
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final current = _case;
    return Scaffold(
      appBar: AppBar(
        title: Text(current?.reference ?? 'Case brief'),
        backgroundColor: AppColors.header,
        foregroundColor: AppColors.textPrimary,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : current == null || _error != null
              ? RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: AppSpacing.page,
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      Text(
                        _error ?? 'This case is no longer available.',
                        textAlign: TextAlign.center,
                        style: AppText.bodyMuted
                            .copyWith(color: AppColors.danger),
                      ),
                    ],
                  ),
                )
              : DefaultTabController(
                  length: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _CaseHeader(
                        caseSummary: current,
                        updating: _updating,
                        onStatusChanged: _changeStatus,
                      ),
                      Material(
                        color: AppColors.header,
                        child: TabBar(
                          tabs: [
                            // fixed tabs sharing the width: all three always on screen, so
                            // labels are kept short enough to fit a third of a phone
                            Tab(text: 'Scenes (${_scenes.length})'),
                            const Tab(text: 'AI summary'),
                            const Tab(text: 'Activity'),
                          ],
                        ),
                      ),
                      Expanded(
                        child: TabBarView(
                          children: [
                            _tab(_scenesTab()),
                            _tab(_summaryTab(current)),
                            _tab(_activityTab()),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }

  /// One tab: a list that can be pulled down to reload the case.
  Widget _tab(List<Widget> children) => RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: _tabPadding,
          physics: const AlwaysScrollableScrollPhysics(),
          children: children,
        ),
      );

  List<Widget> _scenesTab() {
    final waiting = _scenes.where((s) => s.analysis.inProgress).length;
    return [
      if (waiting > 0)
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.small),
          child: Row(
            children: [
              const Icon(Icons.hourglass_empty,
                  size: 18, color: AppColors.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${plural(waiting, 'crime scene')} still waiting for the AI. '
                  'Pull down to check again.',
                  style: AppText.bodyMuted
                      .copyWith(fontSize: 13, color: AppColors.accent),
                ),
              ),
            ],
          ),
        ),
      if (_scenes.isEmpty)
        const Padding(
          padding: EdgeInsets.only(top: AppSpacing.medium),
          child: Text(
            'No crime scenes are linked to this case yet.',
            style: AppText.bodyMuted,
            textAlign: TextAlign.center,
          ),
        )
      else
        for (final scene in _scenes)
          CaseSceneCard(
            key: ValueKey('scene-${scene.incidentId}'),
            scene: scene,
            onTap: () => _openScene(scene),
          ),
    ];
  }

  List<Widget> _summaryTab(CaseSummary current) => [
        if (_showEvidence)
          CaseEvidenceSection(
            key: ValueKey('case-evidence-${current.caseId}-$_version'),
            caseId: current.caseId,
            source: CaseEvidenceSource.standard,
            title: 'AI summary (whole case)',
          )
        else
          const Text(
            'The case\'s AI summary is loaded from the server.',
            style: AppText.bodyMuted,
          ),
      ];

  List<Widget> _activityTab() => [
        if (_events.isEmpty)
          const Text('No activity recorded yet.', style: AppText.bodyMuted)
        else
          for (final event in _events) _CaseEventRow(event: event),
      ];
}

/// Title, description and status of the case, above the tabs. Kept short
/// (description clipped to two lines) so the tabs stay near the top.
class _CaseHeader extends StatelessWidget {
  final CaseSummary caseSummary;
  final bool updating;
  final ValueChanged<String> onStatusChanged;

  const _CaseHeader({
    required this.caseSummary,
    required this.updating,
    required this.onStatusChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = caseSummary;
    final (status, color) = statusStyle(c.status);
    final nextStatus = c.status == 'open' ? 'under_review' : 'open';
    final description = c.description?.trim() ?? '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(c.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.sectionTitle),
          if (description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.bodyMuted),
          ],
          const SizedBox(height: 8),
          // Wrap, not Row: if the action doesn't fit beside the tag on a
          // narrow phone it goes to the next line instead of overflowing
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatusTag(label: status, color: color),
              if (c.isClosed)
                Text('Read-only',
                    style: AppText.bodyMuted.copyWith(fontSize: 13))
              else if (updating)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                TextButton.icon(
                  key: const ValueKey('case-status-action'),
                  onPressed: () => onStatusChanged(nextStatus),
                  icon: const Icon(Icons.sync, size: 18),
                  label: Text(
                    nextStatus == 'under_review'
                        ? 'Mark under review'
                        : 'Reopen as open',
                    overflow: TextOverflow.ellipsis,
                    style: AppText.body
                        .copyWith(fontSize: 14, color: AppColors.accent),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CaseEventRow extends StatelessWidget {
  final CaseEvent event;

  const _CaseEventRow({required this.event});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.medium),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.circle, size: 9, color: AppColors.accent),
          const SizedBox(width: AppSpacing.small),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(event.text, style: AppText.body),
                const SizedBox(height: 3),
                Text(
                  '${formatDateTime(event.occurredAt)}${event.actorName == null ? '' : ' · ${event.actorName}'}',
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
