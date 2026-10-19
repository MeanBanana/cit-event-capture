// submissions.dart — System Administrator view of every reported incident.
//
// A "submission" is an incident a citizen reported (public.crimescene).
// Cases (public.cases) group submissions into one investigation; they have
// their own tab and page.
//
// The page has a search bar and a row of views:
//   Newest / Oldest  every submission by date reported
//   Location         grouped by location ("N1, Midrand" + "n1 midrand"
//                    together); tap a group to see its submissions
//   Status           filtered by the admin's review decision
//                    (Pending / In a case / Rejected / Duplicates)
//   Case             each case with a preview of its submissions;
//                    "View case" opens the case page
//   Linked           submissions the AI linked through the same vehicle
//                    or suspect; add them to a case together
//
// Every list loads 30 rows at a time and fetches more as you scroll
// (PagedList), so the page stays fast however many submissions there are.
//
// Above the list, a bar shows how many pending submissions the database
// thinks belong to existing cases; it opens SuggestedMatchesPage, where the
// admin reviews them and accepts the ticked ones in one tap.
//
// Each submission card shows the citizen's description AND the AI's
// summary of the footage, plus chips for what the AI saw (vehicles,
// people, weapons, number plates). Pending cards have Reject · View ·
// Accept (see review_actions.dart); tapping a card opens
// SubmissionDetailPage.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/theme/argus_widgets.dart';
import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/models/crime_scene_summary.dart';
import 'package:argus_shield/models/case_summary.dart';
import 'package:argus_shield/models/submission_groups.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';
import 'package:argus_shield/admin_screens/paged_list.dart';
import 'package:argus_shield/admin_screens/review_actions.dart';
import 'package:argus_shield/admin_screens/submission_detail.dart';
import 'package:argus_shield/admin_screens/case_detail.dart';
import 'package:argus_shield/admin_screens/cases.dart';
import 'package:argus_shield/admin_screens/suggested_matches.dart';
import 'package:argus_shield/app_settings.dart';

// Other screens (e.g. overview.dart) import CrimeSceneSummary from here.
export 'package:argus_shield/models/crime_scene_summary.dart';

/// The ways the Submissions tab can show its list.
enum SubmissionView { newest, oldest, location, status, cases, linked }

/// Body of the Submissions tab. Like the citizen pages, it has no Scaffold
/// or header of its own — AdminDashboard draws those.
class AdminSubmissions extends StatefulWidget {
  /// Optional so tests can pass in a fake; the app uses the real service.
  final SupabaseService? service;

  const AdminSubmissions({super.key, this.service});

  /// How long to wait after the last key press before searching.
  static const searchDelay = Duration(milliseconds: 400);

  /// The view chips: label → view.
  static const views = <(String, SubmissionView)>[
    ('Newest', SubmissionView.newest),
    ('Oldest', SubmissionView.oldest),
    ('Location', SubmissionView.location),
    ('Status', SubmissionView.status),
    ('Case', SubmissionView.cases),
    ('Linked', SubmissionView.linked),
  ];

  /// The Status view's chips: label → review status passed to the database.
  static const statuses = <(String, String)>[
    ('Pending', 'pending'),
    ('In a case', 'accepted'),
    ('Rejected', 'rejected'),
    ('Duplicates', 'duplicate'),
  ];

  @override
  State<AdminSubmissions> createState() => _AdminSubmissionsState();
}

class _AdminSubmissionsState extends State<AdminSubmissions> {
  late final SupabaseService _service = widget.service ?? SupabaseService();
  final _searchController = TextEditingController();
  Timer? _searchTimer;

  SubmissionView _view = SubmissionView.newest;
  String _review = 'pending'; // the Status view's chip
  String _query = ''; // what's typed in the search bar
  String _activeQuery = ''; // what the list was loaded with

  /// Bumped to reload the list from the top (after an action).
  int _generation = 0;

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
    });
  }

  void _onSearchChanged(String value) {
    setState(() => _query = value);
    _searchTimer?.cancel();
    _searchTimer = Timer(AdminSubmissions.searchDelay, _reload);
  }

  void _clearSearch() {
    _searchController.clear();
    _query = '';
    _reload();
  }

  void _setView(SubmissionView view) {
    if (view == _view) return;
    setState(() => _view = view);
    _reload();
  }

  void _setReview(String review) {
    if (review == _review) return;
    setState(() => _review = review);
    _reload();
  }

  // ---- actions --------------------------------------------------------------

  Future<void> _openDetails(CrimeSceneSummary s) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SubmissionDetailPage(submission: s, service: _service),
      ),
    );
    if (mounted) _reload(); // the review may have changed
  }

  Future<void> _runReview(ReviewAction action, CrimeSceneSummary s) async {
    final changed = await action(context, _service, s);
    if (changed && mounted) _reload();
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

  Future<void> _openLocation(LocationGroup group) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SubmissionListPage(
          title: group.label,
          subtitle: '${plural(group.submissionCount, 'submission')} at this location',
          service: _service,
          locationKey: group.locationKey,
        ),
      ),
    );
    if (mounted) _reload();
  }

  // ---- page -------------------------------------------------------------------

  String get _searchHint => switch (_view) {
        SubmissionView.location => appSettings.t('searchLocations'),
        SubmissionView.cases => appSettings.t('searchCases'),
        _ => appSettings.t('searchIncidents'),
      };

  @override
  Widget build(BuildContext context) {
    final searchable = _view != SubmissionView.linked;
    final views = <(String, SubmissionView)>[
      (appSettings.t('newest'), SubmissionView.newest),
      (appSettings.t('oldest'), SubmissionView.oldest),
      (appSettings.t('location'), SubmissionView.location),
      (appSettings.t('status'), SubmissionView.status),
      (appSettings.t('case'), SubmissionView.cases),
      (appSettings.t('linked'), SubmissionView.linked),
    ];
    final statuses = <(String, String)>[
      (appSettings.t('pending'), 'pending'),
      (appSettings.t('inACase'), 'accepted'),
      (appSettings.t('rejected'), 'rejected'),
      (appSettings.t('duplicates'), 'duplicate'),
    ];

    return ListenableBuilder(
      listenable: appSettings,
      builder: (context, _) => Padding(
      padding: AppSpacing.tab,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(appSettings.t('submissions'), style: titleOnPage(context)),
          const SizedBox(height: AppSpacing.small),
          Text(
            appSettings.t('submissionsIntro'),
            style: mutedOnPage(context),
          ),
          const SizedBox(height: AppSpacing.medium),

          if (searchable) ...[
            TextField(
              controller: _searchController,
              style: bodyOnPage(context),
              textInputAction: TextInputAction.search,
              onChanged: _onSearchChanged,
              onSubmitted: (_) => _reload(), // search now, don't wait
              decoration: InputDecoration(
                hintText: _searchHint,
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
          ],

          ChipRow<SubmissionView>(
            options: views,
            selected: _view,
            onSelected: _setView,
          ),
          if (_view == SubmissionView.status) ...[
            const SizedBox(height: 4),
            ChipRow<String>(
              options: statuses,
              selected: _review,
              onSelected: _setReview,
            ),
          ],
          const SizedBox(height: AppSpacing.medium),

          Expanded(child: _buildList()),
        ],
      ),
      ),
    );
  }

  Widget _buildList() {
    final q = _activeQuery;
    final key = ValueKey('$_view/$_review/$q/$_generation');

    switch (_view) {
      case SubmissionView.newest:
      case SubmissionView.oldest:
      case SubmissionView.status:
        final review = _view == SubmissionView.status ? _review : null;
        final order = _view == SubmissionView.oldest
            ? SubmissionOrder.oldest
            : SubmissionOrder.newest;
        return PagedList<CrimeSceneSummary>(
          key: key,
          pageSize: SupabaseService.pageSize,
          idOf: (s) => s.incidentId,
          loadPage: (loaded) => _service.listSubmissionsPage(
            search: q,
            review: review,
            order: order,
            after: loaded.isEmpty ? null : loaded.last,
          ),
          // "N submissions match existing cases: review and accept"
          header: q.isEmpty && (review == null || review == 'pending')
              ? SuggestedMatchesBanner(service: _service, onChanged: _reload)
              : null,
          errorText: 'Could not load submissions. Check your connection.',
          emptyText: q.isNotEmpty
              ? 'No submissions match your search.'
              : review == null
                  ? 'No incidents have been reported yet.'
                  : 'No submissions in this list.',
          itemBuilder: (context, s) => CrimeSceneCard(
            submission: s,
            onTap: () => _openDetails(s),
            onAccept: () => _runReview(acceptSubmission, s),
            onReject: () => _runReview(rejectSubmission, s),
          ),
        );

      case SubmissionView.location:
        return PagedList<LocationGroup>(
          key: key,
          pageSize: SupabaseService.pageSize,
          idOf: (g) => g.locationKey,
          loadPage: (loaded) =>
              _service.listLocationGroups(search: q, offset: loaded.length),
          errorText: 'Could not load locations. Check your connection.',
          emptyText: q.isNotEmpty
              ? 'No locations match your search.'
              : 'No incidents have been reported yet.',
          spacing: AppSpacing.small,
          itemBuilder: (context, g) =>
              LocationGroupCard(group: g, onTap: () => _openLocation(g)),
        );

      case SubmissionView.cases:
        return PagedList<CaseSummary>(
          key: key,
          pageSize: 20,
          idOf: (c) => c.caseId,
          loadPage: (loaded) => _service.listCasesPage(
              query: q, after: loaded.isEmpty ? null : loaded.last),
          errorText: 'Could not load cases. Check your connection.',
          emptyText: q.isNotEmpty
              ? 'No cases match your search.'
              : 'No cases yet. Accept a submission to start one.',
          header: q.isNotEmpty
              ? null
              : Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.medium),
                  child: _NotInCaseTile(onTap: () {
                    setState(() => _review = 'pending');
                    _setView(SubmissionView.status);
                  }),
                ),
          itemBuilder: (context, c) => CaseCard(
            caseSummary: c,
            showPreview: true,
            onTap: () => _openCase(c.caseId),
            onViewCase: () => _openCase(c.caseId),
          ),
        );

      case SubmissionView.linked:
        return PagedList<LinkedGroup>(
          key: key,
          pageSize: 20,
          idOf: (g) => g.groupId,
          loadPage: (loaded) => _service.listLinkedGroups(offset: loaded.length),
          errorText: 'Could not load linked submissions. Check your connection.',
          emptyText: 'No linked submissions found.\n\nSubmissions appear here '
              'when the AI links the same vehicle or suspect across reports.',
          itemBuilder: (context, g) => LinkedGroupCard(
            group: g,
            service: _service,
            onOpenSubmission: _openDetails,
            onOpenCase: _openCase,
            onChanged: _reload,
          ),
        );
    }
  }
}

/// "Waiting for review" shortcut at the top of the Case view.
class _NotInCaseTile extends StatelessWidget {
  final VoidCallback onTap;

  const _NotInCaseTile({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return AdminCard(
      onTap: onTap,
      borderColor: AppColors.accent,
      child: const Row(
        children: [
          Icon(Icons.inbox_outlined, color: AppColors.accent),
          SizedBox(width: AppSpacing.small),
          Expanded(
            child: Text('Not in a case yet: see pending submissions',
                style: AppText.bodyMuted),
          ),
          Icon(Icons.chevron_right, color: AppColors.neutral),
        ],
      ),
    );
  }
}

// =============================================================================
// Cards
// =============================================================================

/// One incident's details: reference, review decision, where and when, the
/// citizen's and the AI's descriptions, and chips for what the AI saw.
///
/// Tapping the card calls [onTap] (opens the details page). For a pending
/// submission, passing [onAccept] / [onReject] adds the wireframe's
/// Reject · View · Accept buttons. [menu] (e.g. a ⋮ button) goes top right.
class CrimeSceneCard extends StatelessWidget {
  final CrimeSceneSummary submission;
  final VoidCallback? onTap;
  final VoidCallback? onAccept;
  final VoidCallback? onReject;
  final Widget? menu;

  /// Shorter descriptions (3 lines each); the details page shows them all.
  final bool compact;

  const CrimeSceneCard({
    super.key,
    required this.submission,
    this.onTap,
    this.onAccept,
    this.onReject,
    this.menu,
    this.compact = true,
  });

  @override
  Widget build(BuildContext context) {
    final s = submission;
    final (reviewLabel, reviewColor) = reviewStyle(s.reviewStatus);
    final showActions = s.isPending && (onAccept != null || onReject != null);

    return AdminCard(
      onTap: onTap,
      borderColor: s.isPending ? AppColors.accent : AppColors.fieldBorder,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Reference + review decision (+ menu)
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: Text(s.reference, style: AppText.cardTitle)),
              const SizedBox(width: AppSpacing.small),
              StatusTag(label: reviewLabel, color: reviewColor),
              ?menu,
            ],
          ),
          if (s.attackType != null) ...[
            const SizedBox(height: 6),
            Text(
              s.attackType!.toUpperCase(),
              style: AppText.caption.copyWith(fontSize: 13),
            ),
          ],
          const SizedBox(height: 12),
          const Divider(color: AppColors.fieldBorder, height: 1),
          const SizedBox(height: 12),

          DetailLine(icon: Icons.location_on_outlined, text: s.location),
          WhenLines(submission: s),
          if (s.dateReported != null)
            DetailLine(
                icon: Icons.upload_outlined,
                text: 'Reported ${formatDateTime(s.dateReported!)} '
                    'by ${s.reporterName}'),
          DetailLine(
            icon: Icons.perm_media_outlined,
            text: '${s.mediaCount} media '
                '${s.mediaCount == 1 ? 'file' : 'files'}',
          ),
          if (s.caseReference != null)
            DetailLine(
              icon: Icons.folder_open,
              text: '${s.caseReference}'
                  '${s.caseTitle == null ? '' : ' · ${s.caseTitle}'}',
              color: AppColors.success,
            ),
          if (s.isDuplicate && s.duplicateOf != null)
            DetailLine(
              icon: Icons.copy_all,
              text: 'Duplicate of ${incidentReference(s.duplicateOf!)}',
            ),
          if (s.isRejected && s.reviewNote != null)
            DetailLine(icon: Icons.block, text: 'Reason: ${s.reviewNote}'),

          const SizedBox(height: 4),
          SubmissionDescriptions(
            citizen: s.description,
            ai: s.aiSummary,
            aiStatus: s.aiSummaryStatus,
            mediaCount: s.mediaCount,
            maxLines: compact ? 3 : null,
          ),
          if (s.hasAiFacts) ...[
            const SizedBox(height: 4),
            AiFactChips(submission: s),
          ],

          if (showActions) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: SmallActionButton(
                      label: 'Reject',
                      color: AppColors.danger,
                      onPressed: onReject),
                ),
                const SizedBox(width: AppSpacing.small),
                Expanded(
                  child: SmallActionButton(
                      label: 'View',
                      color: AppColors.textPrimary,
                      onPressed: onTap),
                ),
                const SizedBox(width: AppSpacing.small),
                Expanded(
                  child: SmallActionButton(
                      label: 'Accept',
                      color: AppColors.success,
                      onPressed: onAccept),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// When it happened: "Filmed ..." from the footage's metadata when there
/// is a capture time, otherwise "Happened ..." as the citizen typed it.
/// Warns when the two are more than 3 hours apart.
class WhenLines extends StatelessWidget {
  final CrimeSceneSummary submission;

  const WhenLines({super.key, required this.submission});

  @override
  Widget build(BuildContext context) {
    final s = submission;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DetailLine(
          icon: s.capturedAt == null ? Icons.schedule : Icons.videocam_outlined,
          text: s.capturedAt == null
              ? 'Happened ${formatDateTime(s.dateTime)} (as reported)'
              : 'Filmed ${formatDateTime(s.capturedAt!)}',
        ),
        if (s.timeMismatch)
          DetailLine(
            icon: Icons.warning_amber_outlined,
            text: 'Citizen said ${formatDateTime(s.dateTime)}: '
                'check which time is right',
            color: AppColors.accent,
          ),
      ],
    );
  }
}

/// Chips for what the AI saw in a submission's footage.
class AiFactChips extends StatelessWidget {
  final CrimeSceneSummary submission;

  const AiFactChips({super.key, required this.submission});

  @override
  Widget build(BuildContext context) {
    final s = submission;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        if (s.vehicleCount > 0)
          FactChip(plural(s.vehicleCount, 'vehicle'),
              icon: Icons.directions_car_outlined),
        for (final plate in s.plates)
          FactChip(plate, icon: Icons.pin_outlined, color: AppColors.accent),
        // People: as suspects once there is something to review or
        // confirmed (only investigators on the case decide, POPIA);
        // otherwise just how many people were seen.
        if (s.confirmedSuspects > 0)
          FactChip(plural(s.confirmedSuspects, 'confirmed suspect'),
              icon: Icons.person_outline, color: AppColors.danger),
        if (s.possibleSuspects > 0)
          FactChip('about ${plural(s.possibleSuspects, 'possible suspect')}',
              icon: Icons.person_search_outlined, color: AppColors.accent),
        if (s.confirmedSuspects == 0 &&
            s.possibleSuspects == 0 &&
            s.personCount > 0)
          FactChip(plural(s.personCount, 'person', 'people'),
              icon: Icons.person_outline),
        if (s.weaponCount > 0)
          const FactChip('weapon seen',
              icon: Icons.warning_amber_outlined, color: AppColors.danger),
      ],
    );
  }
}

/// One location on the Location view.
class LocationGroupCard extends StatelessWidget {
  final LocationGroup group;
  final VoidCallback onTap;

  const LocationGroupCard({super.key, required this.group, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final g = group;
    return AdminCard(
      onTap: onTap,
      borderColor: g.pendingCount > 0 ? AppColors.accent : AppColors.fieldBorder,
      child: Row(
        children: [
          const Icon(Icons.location_on_outlined, color: AppColors.accent, size: 28),
          const SizedBox(width: AppSpacing.small),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(g.label,
                    style: AppText.body.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(
                  [
                    plural(g.submissionCount, 'submission'),
                    if (g.pendingCount > 0) '${g.pendingCount} pending',
                    if (g.latestReported != null)
                      'latest ${formatDate(g.latestReported!)}',
                  ].join(' · '),
                  style: AppText.bodyMuted.copyWith(fontSize: 13),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: AppColors.neutral),
        ],
      ),
    );
  }
}

/// Submissions the AI linked together, with their members listed and
/// actions to put the pending ones in a case.
class LinkedGroupCard extends StatefulWidget {
  final LinkedGroup group;
  final SupabaseService service;
  final ValueChanged<CrimeSceneSummary> onOpenSubmission;
  final ValueChanged<int> onOpenCase;
  final VoidCallback onChanged;

  const LinkedGroupCard({
    super.key,
    required this.group,
    required this.service,
    required this.onOpenSubmission,
    required this.onOpenCase,
    required this.onChanged,
  });

  @override
  State<LinkedGroupCard> createState() => _LinkedGroupCardState();
}

class _LinkedGroupCardState extends State<LinkedGroupCard> {
  // The members load when the card is first built (only cards on screen
  // are built), with one call for the whole group.
  late Future<List<CrimeSceneSummary>> _members = _load();

  Future<List<CrimeSceneSummary>> _load() => widget.service.listSubmissionsPage(
      ids: widget.group.incidentIds,
      limit: widget.group.size > 100 ? 100 : widget.group.size);

  Future<void> _addPending(List<CrimeSceneSummary> members) async {
    final pending = members.where((s) => s.isPending).toList();
    if (pending.isEmpty) return;
    final changed = await addSubmissionsToCase(context, widget.service, pending);
    if (changed && mounted) {
      final members = _load();
      setState(() {
        _members = members;
      });
      widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.group;
    final confidence = g.bestConfidence == null
        ? null
        : '${(g.bestConfidence! * 100).round()}% best match';

    return AdminCard(
      borderColor: g.pendingCount > 0 ? AppColors.accent : AppColors.fieldBorder,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.hub_outlined, color: AppColors.accent),
              const SizedBox(width: AppSpacing.small),
              Expanded(
                child: Text(plural(g.size, 'linked submission'),
                    style: AppText.cardTitle.copyWith(fontSize: 16)),
              ),
              if (g.pendingCount > 0)
                StatusTag(
                    label: '${g.pendingCount} pending', color: AppColors.accent),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              FactChip(
                  g.verifiedLinks > 0
                      ? '${plural(g.linkCount, 'AI link')} · ${g.verifiedLinks} verified'
                      : plural(g.linkCount, 'AI link'),
                  icon: Icons.link),
              if (confidence != null) FactChip(confidence),
              for (final plate in g.plates)
                FactChip(plate, icon: Icons.pin_outlined, color: AppColors.accent),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(color: AppColors.fieldBorder, height: 1),
          FutureBuilder<List<CrimeSceneSummary>>(
            future: _members,
            builder: (context, snap) {
              if (snap.hasError) {
                return const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('Could not load these submissions.',
                      style: AppText.bodyMuted),
                );
              }
              if (!snap.hasData) {
                return const Padding(
                  padding: EdgeInsets.all(12),
                  child: Center(
                      child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))),
                );
              }
              final members = snap.data!;
              final pending = members.where((s) => s.isPending).length;
              final caseIds = {
                for (final s in members)
                  if (s.caseId != null) s.caseId!
              };
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final s in members)
                    SubmissionRow(
                        submission: s, onTap: () => widget.onOpenSubmission(s)),
                  const SizedBox(height: 8),
                  if (pending > 0)
                    SmallActionButton(
                      label: 'Add ${plural(pending, 'pending submission')} to a case',
                      color: AppColors.success,
                      onPressed: () => _addPending(members),
                    ),
                  for (final caseId in caseIds) ...[
                    const SizedBox(height: 8),
                    SmallActionButton(
                      label: 'View ${caseReference(caseId)}',
                      color: AppColors.accent,
                      onPressed: () => widget.onOpenCase(caseId),
                    ),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// A one-line submission inside a group or case card: reference, place,
/// date and review tag. Tap to open it.
class SubmissionRow extends StatelessWidget {
  final CrimeSceneSummary submission;
  final VoidCallback? onTap;

  const SubmissionRow({super.key, required this.submission, this.onTap});

  @override
  Widget build(BuildContext context) {
    final s = submission;
    final (label, color) = reviewStyle(s.reviewStatus);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${s.reference} · ${s.location}',
                      style: AppText.body
                          .copyWith(fontSize: 14, fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  Text(
                    s.aiSummary ?? s.description ?? 'No description',
                    style: AppText.bodyMuted.copyWith(fontSize: 13),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            StatusTag(label: label, color: color),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// SubmissionListPage — one location's (or any filter's) submissions
// =============================================================================

/// Full page with a paged list of submissions, e.g. everything reported at
/// one location.
class SubmissionListPage extends StatefulWidget {
  final String title;
  final String? subtitle;
  final SupabaseService? service;
  final String? locationKey;

  const SubmissionListPage({
    super.key,
    required this.title,
    this.subtitle,
    this.service,
    this.locationKey,
  });

  @override
  State<SubmissionListPage> createState() => _SubmissionListPageState();
}

class _SubmissionListPageState extends State<SubmissionListPage> {
  late final SupabaseService _service = widget.service ?? SupabaseService();
  int _generation = 0;

  void _reload() => setState(() => _generation++);

  Future<void> _open(CrimeSceneSummary s) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SubmissionDetailPage(submission: s, service: _service),
      ),
    );
    if (mounted) _reload();
  }

  Future<void> _review(ReviewAction action, CrimeSceneSummary s) async {
    final changed = await action(context, _service, s);
    if (changed && mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const ArgusAppBar(roleLabel: 'Admin'),
      body: Padding(
        padding: AppSpacing.tab,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: AppText.sectionTitle),
            if (widget.subtitle != null) ...[
              const SizedBox(height: AppSpacing.small),
              Text(widget.subtitle!, style: AppText.bodyMuted),
            ],
            const SizedBox(height: AppSpacing.medium),
            Expanded(
              child: PagedList<CrimeSceneSummary>(
                key: ValueKey(_generation),
                pageSize: SupabaseService.pageSize,
                idOf: (s) => s.incidentId,
                loadPage: (loaded) => _service.listSubmissionsPage(
                  locationKey: widget.locationKey,
                  after: loaded.isEmpty ? null : loaded.last,
                ),
                emptyText: 'No submissions here any more.',
                itemBuilder: (context, s) => CrimeSceneCard(
                  submission: s,
                  onTap: () => _open(s),
                  onAccept: () => _review(acceptSubmission, s),
                  onReject: () => _review(rejectSubmission, s),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens the panel to put several submissions in a case (new or existing),
/// e.g. a linked group. True when something changed.
Future<bool> addSubmissionsToCase(BuildContext context, SupabaseService service,
    List<CrimeSceneSummary> submissions) {
  return acceptSubmissions(context, service, submissions);
}
