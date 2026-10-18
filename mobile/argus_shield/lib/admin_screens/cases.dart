// cases.dart — System Administrator view of every case (the "Cases" tab).
//
// A case groups one or more submissions into one investigation and has
// investigators assigned to it. Here the admin can:
//   * see all cases as cards, most recently active first (20 at a time,
//     more load as you scroll)
//   * search by case number ("3", "CASE-0003") or title
//   * filter by status (Open / Under review / Closed)
//   * create a new case
//   * tap a case to open CaseDetailPage (submissions, investigators,
//     status, suggestions, history)
//
// Each card also shows the case's suspects (possible = seen by the AI, not
// yet reviewed by an investigator; confirmed = confirmed by an
// investigator on the case) and, for cases that are not closed, the best
// suggested pending submission with its most relevant number plate.
//
// Data comes from SupabaseService.listCasesPage (the list_cases function);
// the suggestions from getCaseCardSuggestions, fetched once per page after
// the cards appear, so a slow or failed suggestion call never holds up or
// breaks the list.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/models/case_summary.dart';
import 'package:argus_shield/models/submission_groups.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';
import 'package:argus_shield/admin_screens/paged_list.dart';
import 'package:argus_shield/admin_screens/pickers.dart';
import 'package:argus_shield/admin_screens/case_detail.dart';
import 'package:argus_shield/app_settings.dart';

/// Body of the Cases tab. Like the other admin tabs, it has no Scaffold or
/// header of its own — AdminDashboard draws those.
class AdminCases extends StatefulWidget {
  /// Optional so tests can pass in a fake; the app uses the real service.
  final SupabaseService? service;

  const AdminCases({super.key, this.service});

  /// How long to wait after the last key press before searching.
  static const searchDelay = Duration(milliseconds: 400);

  /// Filter chips: label → status passed to the database (null = all).
  static const filters = <(String, String?)>[
    ('All', null),
    ('Open', 'open'),
    ('Under review', 'under_review'),
    ('Closed', 'closed'),
  ];

  @override
  State<AdminCases> createState() => _AdminCasesState();
}

class _AdminCasesState extends State<AdminCases> {
  late final SupabaseService _service = widget.service ?? SupabaseService();
  final _searchController = TextEditingController();
  Timer? _searchTimer;

  String _query = '';
  String _activeQuery = '';
  String? _status; // current filter chip (null = all)
  int _generation = 0; // bump to reload from the top

  /// Best suggested submission per case id, filled in page by page.
  final Map<int, CaseCardSuggestion> _suggestions = {};

  @override
  void dispose() {
    _searchTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _reload() {
    _searchTimer?.cancel();
    setState(() {
      _activeQuery = _query.trim();
      _generation++;
      _suggestions.clear();
    });
  }

  /// Loads one page of cases, then (without waiting) their suggestions.
  Future<List<CaseSummary>> _loadPage(String query, List<CaseSummary> loaded) async {
    final page = await _service.listCasesPage(
      query: query,
      status: _status,
      after: loaded.isEmpty ? null : loaded.last,
    );
    unawaited(_loadSuggestions(page, _generation));
    return page;
  }

  /// Suggestions are extra information: if they fail, the cards simply
  /// show without them.
  Future<void> _loadSuggestions(List<CaseSummary> page, int generation) async {
    final ids = [for (final c in page) if (!c.isClosed) c.caseId];
    if (ids.isEmpty) return;
    try {
      final found = await _service.getCaseCardSuggestions(ids);
      if (!mounted || generation != _generation || found.isEmpty) return;
      setState(() {
        for (final s in found) {
          _suggestions[s.caseId] = s;
        }
      });
    } catch (_) {
      // leave the cards without suggestions
    }
  }

  void _onSearchChanged(String value) {
    setState(() => _query = value);
    _searchTimer?.cancel();
    _searchTimer = Timer(AdminCases.searchDelay, _reload);
  }

  void _clearSearch() {
    _searchController.clear();
    _query = '';
    _reload();
  }

  void _onFilter(String? status) {
    if (status == _status) return;
    _status = status;
    _reload();
  }

  Future<void> _openCase(int caseId) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CaseDetailPage(caseId: caseId, service: _service),
      ),
    );
    if (mounted) _reload();
  }

  /// New case (no submissions yet), then open it to add some.
  Future<void> _newCase() async {
    final caseId = await showAdminSheet<int>(
      context,
      title: 'New case',
      builder: (sheetContext) => NewCaseForm(
        onCreate: (title, description) async {
          final id =
              await _service.createCase(title: title, description: description);
          if (sheetContext.mounted) Navigator.pop(sheetContext, id);
        },
      ),
    );
    if (caseId == null || !mounted) return;
    showSnack(context, '${caseReference(caseId)} created');
    await _openCase(caseId);
  }

  @override
  Widget build(BuildContext context) {
    final q = _activeQuery;
    final filters = <(String, String?)>[
      (appSettings.t('all'), null),
      (appSettings.t('open'), 'open'),
      (appSettings.t('underReview'), 'under_review'),
      (appSettings.t('closed'), 'closed'),
    ];
    return ListenableBuilder(
      listenable: appSettings,
      builder: (context, _) => Padding(
      padding: AppSpacing.tab,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(appSettings.t('cases'), style: titleOnPage(context)),
              ),
              SmallActionButton(
                label: appSettings.t('newCase'),
                color: AppColors.accent,
                onPressed: _newCase,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.small),
          Text(
            appSettings.t('casesIntro'),
            style: mutedOnPage(context),
          ),
          const SizedBox(height: AppSpacing.medium),

          TextField(
            controller: _searchController,
            style: bodyOnPage(context),
            textInputAction: TextInputAction.search,
            onChanged: _onSearchChanged,
            onSubmitted: (_) => _reload(),
            decoration: InputDecoration(
              hintText: appSettings.t('searchCases'),
              hintStyle: mutedOnPage(context),
              prefixIcon: const Icon(Icons.search, color: AppColors.accent),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: Icon(Icons.close, color: pageInkMuted(context)),
                      tooltip: appSettings.t('clearSearch'),
                      onPressed: _clearSearch,
                    ),
            ),
          ),
          const SizedBox(height: AppSpacing.small),

          ChipRow<String?>(
            options: filters,
            selected: _status,
            onSelected: _onFilter,
          ),
          const SizedBox(height: AppSpacing.medium),

          Expanded(
            child: PagedList<CaseSummary>(
              key: ValueKey('$_status/$q/$_generation'),
              pageSize: 20,
              idOf: (c) => c.caseId,
              loadPage: (loaded) => _loadPage(q, loaded),
              errorText: appSettings.t('loadCasesError'),
              emptyText: q.isNotEmpty
                  ? appSettings.t('noCasesSearch')
                  : _status == null
                      ? appSettings.t('noCasesYet')
                      : appSettings.t('noCasesStatus'),
              itemBuilder: (context, c) => CaseCard(
                caseSummary: c,
                suggestion: _suggestions[c.caseId],
                showPreview: true,
                onTap: () => _openCase(c.caseId),
                onViewCase: () => _openCase(c.caseId),
              ),
            ),
          ),
        ],
      ),
    ),
    );
  }
}

/// One case, in the same card style as a submission: reference and
/// status, title and description, what's inside (submissions, footage,
/// suspects, plates), who is on it, the best suggested submission, and
/// optionally a preview of its newest submissions with a "View case"
/// button.
class CaseCard extends StatelessWidget {
  final CaseSummary caseSummary;
  final VoidCallback? onTap;

  /// The best suggested pending submission for the case (not shown for
  /// closed cases).
  final CaseCardSuggestion? suggestion;

  /// Shows the newest submissions (citizen + AI descriptions) in the card.
  final bool showPreview;

  /// When set, a "View case" button at the bottom calls it.
  final VoidCallback? onViewCase;

  const CaseCard({
    super.key,
    required this.caseSummary,
    this.onTap,
    this.suggestion,
    this.showPreview = false,
    this.onViewCase,
  });

  @override
  Widget build(BuildContext context) {
    final c = caseSummary;
    final (statusLabel, statusColor) = statusStyle(c.status);
    final unassigned = c.investigators.isEmpty && !c.isClosed;
    final lead = c.lead;
    final others = c.investigators.where((i) => !i.isLead).toList();
    final suspects = suspectSummary(
        possible: c.possibleSuspects, confirmed: c.confirmedSuspects);
    final suggested = c.isClosed ? null : suggestion;

    return AdminCard(
      onTap: onTap,
      borderColor: unassigned ? AppColors.accent : AppColors.fieldBorder,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(c.reference, style: AppText.cardTitle)),
              const SizedBox(width: AppSpacing.small),
              StatusTag(label: statusLabel, color: statusColor),
            ],
          ),
          const SizedBox(height: 6),
          Text(c.title,
              style: AppText.body.copyWith(fontWeight: FontWeight.bold)),
          if (c.description != null) ...[
            const SizedBox(height: 4),
            Text(c.description!,
                style: AppText.bodyMuted,
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          ],
          const SizedBox(height: 12),
          const Divider(color: AppColors.fieldBorder, height: 1),
          const SizedBox(height: 12),
          DetailLine(
            icon: Icons.description_outlined,
            text: [
              plural(c.incidentCount, appSettings.t('submissionOne'),
                  appSettings.t('submissionMany')),
              if (c.mediaCount > 0)
                '${c.mediaCount} ${c.mediaCount == 1 ? appSettings.t('mediaFileOne') : appSettings.t('mediaFileMany')}',
            ].join(' · '),
          ),
          DetailLine(
            icon: Icons.badge_outlined,
            text: unassigned
                ? appSettings.t('noInvestigatorAssigned')
                : c.investigators.isEmpty
                    ? appSettings.t('noInvestigatorsShort')
                    : [
                        if (lead != null) '${lead.name} (${appSettings.t('lead')})',
                        ...others.map((i) => i.name),
                      ].join(', '),
            color: unassigned ? AppColors.accent : null,
          ),
          DetailLine(
            icon: Icons.event,
            text: '${appSettings.t('created')} ${formatDate(c.dateCreated)}'
                '${c.dateClosed == null ? '' : ' · ${appSettings.t('closedWord')} ${formatDate(c.dateClosed!)}'}'
                '${c.lastActivity == null || c.dateClosed != null ? '' : ' · ${appSettings.t('activeWord')} ${formatDate(c.lastActivity!)}'}',
          ),
          if (suspects != null)
            DetailLine(
              icon: Icons.person_search_outlined,
              text: suspects,
              color: suspectColor(confirmed: c.confirmedSuspects),
            ),
          if (c.plates.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final plate in c.plates)
                  FactChip(plate,
                      icon: Icons.pin_outlined, color: AppColors.accent),
              ],
            ),

          if (suggested != null) ...[
            const SizedBox(height: 12),
            _SuggestedSubmission(suggestion: suggested),
          ],

          if (showPreview && c.preview.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Divider(color: AppColors.fieldBorder, height: 1),
            const SizedBox(height: 8),
            Text(
              c.incidentCount > c.preview.length
                  ? '${appSettings.t('newestWord')} ${c.preview.length} ${appSettings.t('ofWord')} ${c.incidentCount} ${appSettings.t('submissionsLabel')}'
                  : appSettings.t('submissionsLabel'),
              style: AppText.caption.copyWith(color: AppColors.textHint),
            ),
            for (final p in c.preview) _PreviewRow(item: p),
          ],
          if (showPreview && c.preview.isEmpty) ...[
            const SizedBox(height: 4),
            Text(appSettings.t('noSubmissionsInCase'),
                style: AppText.bodyMuted),
          ],

          if (onViewCase != null) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: SmallActionButton(
                label: c.incidentCount > c.preview.length
                    ? '${appSettings.t('viewCase')} (${appSettings.t('all')} ${c.incidentCount} ${appSettings.t('submissionMany')})'
                    : appSettings.t('viewCase'),
                color: AppColors.accent,
                onPressed: onViewCase,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The best suggested pending submission on a case card: which one, how
/// strong, its most relevant plate and why it was suggested. Adding it to
/// the case still happens on the case page ("Recommended for this case").
class _SuggestedSubmission extends StatelessWidget {
  final CaseCardSuggestion suggestion;

  const _SuggestedSubmission({required this.suggestion});

  @override
  Widget build(BuildContext context) {
    final s = suggestion;
    final plateNote = switch (s.plateMatch) {
      'same' => 'same plate as in this case',
      'similar' => '1 character off a plate in this case',
      _ => 'AI read, not confirmed',
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s.otherCount > 0
                ? 'SUGGESTED SUBMISSION (+${s.otherCount} MORE)'
                : 'SUGGESTED SUBMISSION',
            style: AppText.caption.copyWith(color: AppColors.textHint),
          ),
          const SizedBox(height: 4),
          Text(
            '${s.reference} · ${suggestionStrength(s.score)}',
            style: AppText.body.copyWith(fontSize: 14, fontWeight: FontWeight.bold),
          ),
          if (s.plate != null) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FactChip(s.plate!, icon: Icons.pin_outlined, color: AppColors.accent),
                Text(plateNote,
                    style: AppText.bodyMuted.copyWith(fontSize: 12)),
              ],
            ),
          ],
          if (s.reasons.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              s.reasons.join(' · '),
              style: AppText.bodyMuted.copyWith(fontSize: 13),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

/// One submission inside a case card's preview.
class _PreviewRow extends StatelessWidget {
  final CasePreviewItem item;

  const _PreviewRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final p = item;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${p.reference} · ${p.location}'
            '${p.reviewStatus == 'duplicate' ? ' (duplicate)' : ''}',
            style: AppText.body.copyWith(fontSize: 14, fontWeight: FontWeight.bold),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (p.description != null)
            Text('${appSettings.t('citizenPrefix')}: ${p.description}',
                style: AppText.bodyMuted.copyWith(fontSize: 13),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          Text(
            p.aiSummary == null
                ? '${appSettings.t('aiPrefix')}: ${appSettings.t('noAiYet')}'
                : '${appSettings.t('aiPrefix')}: ${p.aiSummary}',
            style: AppText.bodyMuted.copyWith(
                fontSize: 13,
                color: p.aiSummary == null ? AppColors.textHint : null),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
