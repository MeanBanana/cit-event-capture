import 'package:flutter/material.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';
import 'package:argus_shield/admin_screens/case_evidence_section.dart';
import 'package:argus_shield/admin_screens/crime_scene_card.dart';
import 'package:argus_shield/admin_screens/crime_scene_page.dart';
import 'package:argus_shield/admin_screens/footage_list.dart'
    show usesRealDatabase;
import 'package:argus_shield/case_evidence_source.dart';
import 'package:argus_shield/investigator_dashboard/case_chat_tab.dart';
import 'package:argus_shield/models/case_summary.dart';
import 'package:argus_shield/models/crime_scene.dart';
import 'package:argus_shield/models/submission_groups.dart';
import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/app_settings.dart';

/// A case as an investigator sees it. None of the admin review/assignment
/// controls on purpose.
///
///   N1 Midrand CIT robbery                       [OPEN]  Mark under review
///   Two vans hit on the N1 ...
///   ┌ Scenes (2) ┬ AI summary ┬ Activity ┬ Chat ┐
///   │ [card] INC-0042 · description · location · 2 suspects ...      │
///   │ [card] INC-0043 · ...                                          │
///
/// Crime scenes are the first tab so that's what you see on opening a case,
/// no scrolling past the summary. Each card opens crime_scene_page.dart. The
/// case-wide AI summary and the history have their own tabs, and Chat is the
/// group chat for everyone on the case (case_chat_tab.dart).
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

  /// The AI pictures go straight to Supabase, so they're off with the
  /// widget tests' fake services.
  late final bool _showEvidence = usesRealDatabase(widget.service);

  /// Padding for each tab's list.
  static const _tabPadding = EdgeInsets.fromLTRB(16, 16, 16, 32);

  /// Bumped on pull-to-refresh so the AI summary reloads.
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
    // corrections change the counts and the case summary
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final current = _case;
    return Scaffold(
      appBar: AppBar(
        title: Text(current?.reference ?? appSettings.t('caseBrief')),
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
                        _error ?? appSettings.t('caseGone'),
                        textAlign: TextAlign.center,
                        style: AppText.bodyMuted
                            .copyWith(color: AppColors.danger),
                      ),
                    ],
                  ),
                )
              : DefaultTabController(
                  length: 4,
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
                          labelColor: Colors.white,
                          unselectedLabelColor: Colors.white70,
                          indicatorColor: AppColors.accent,
                          // fixed tabs splitting the width so all four always
                          // fit, hence the short labels and small padding
                          labelPadding:
                              const EdgeInsets.symmetric(horizontal: 4),
                          tabs: [
                            Tab(text: '${appSettings.t('scenes')} (${_scenes.length})'),
                            Tab(text: appSettings.t('aiSummaryTab')),
                            Tab(text: appSettings.t('activity')),
                            Tab(text: appSettings.t('chat')),
                          ],
                        ),
                      ),
                      Expanded(
                        child: TabBarView(
                          children: [
                            _tab(_scenesTab()),
                            _tab(_summaryTab(current)),
                            _tab(_activityTab()),
                            CaseChatTab(
                              key: ValueKey('chat-${current.caseId}'),
                              caseId: current.caseId,
                              service: _service,
                              readOnly: current.isClosed,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
    );
  }

  /// One tab, a list you can pull down to reload the case.
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
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.medium),
          child: Text(
            appSettings.t('noScenesLinked'),
            style: mutedOnPage(context),
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
            title: appSettings.t('aiSummaryTab'),
          )
        else
          Text(
            appSettings.t('aiFromServer'),
            style: mutedOnPage(context),
          ),
      ];

  List<Widget> _activityTab() => [
        if (_events.isEmpty)
          Text(appSettings.t('noActivityRecorded'), style: mutedOnPage(context))
        else
          for (final event in _events) _CaseEventRow(event: event),
      ];
}

/// Title, description and status above the tabs. Description is clipped to
/// two lines so the tabs stay near the top.
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
              style: titleOnPage(context)),
          if (description.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: mutedOnPage(context)),
          ],
          const SizedBox(height: 8),
          // Wrap rather than Row, so on a narrow phone the action drops to
          // the next line instead of overflowing
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatusTag(label: status, color: color),
              if (c.isClosed)
                Text(appSettings.t('readOnly'),
                    style: mutedOnPage(context).copyWith(fontSize: 13))
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
                        ? appSettings.t('markUnderReview')
                        : appSettings.t('reopenOpen'),
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
                Text(event.text, style: bodyOnPage(context)),
                const SizedBox(height: 3),
                Text(
                  '${formatDateTime(event.occurredAt)}${event.actorName == null ? '' : ' · ${event.actorName}'}',
                  style: mutedOnPage(context).copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
