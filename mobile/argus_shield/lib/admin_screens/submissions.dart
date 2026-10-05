// submissions.dart — System Administrator view of every reported incident.
//
// Same layout as investigators.dart: a search bar and a scrollable list of
// cards.
//
// A "submission" is an incident a citizen reported (public.crimescene).
// Cases (public.cases) are created later by an admin to group incidents;
// they have their own screen.
//
// Data comes from SupabaseService:
//   * on opening: getRecentSubmissions()  -> the 20 most recently reported
//   * while searching: searchSubmissions() -> incident number or location
// The search runs in the database, so it finds any submission, not only
// the 20 already on screen. The chips filter on the admin's review
// decision (Pending / In a case / Rejected / Duplicates).
//
// Pending cards have Reject · View · Accept (see review_actions.dart);
// tapping a card opens SubmissionDetailPage.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/models/crime_scene_summary.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';
import 'package:argus_shield/admin_screens/review_actions.dart';
import 'package:argus_shield/admin_screens/submission_detail.dart';

// Other screens (e.g. overview.dart) import CrimeSceneSummary from here.
export 'package:argus_shield/models/crime_scene_summary.dart';

/// Body of the Submissions tab. Like the citizen pages, it has no Scaffold
/// or header of its own — AdminDashboard draws those.
class AdminSubmissions extends StatefulWidget {
  /// Optional so tests can pass in a fake; the app uses the real service.
  final SupabaseService? service;

  const AdminSubmissions({super.key, this.service});

  /// How long to wait after the last key press before searching.
  static const searchDelay = Duration(milliseconds: 400);

  /// Filter chips: label → review status passed to the database
  /// (null = all).
  static const filters = <(String, String?)>[
    ('All', null),
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

  String _query = '';
  String? _review; // current filter chip (null = all)
  List<CrimeSceneSummary> _submissions = const [];
  bool _loading = true;
  String? _error;

  // Only the newest request may update the screen (see investigators.dart).
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _fetch(); // _loading already starts as true
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// Loads the recent submissions, or the search results when there is
  /// search text.
  Future<void> _fetch() async {
    final id = ++_requestId;
    final query = _query.trim();
    try {
      final rows = query.isEmpty
          ? await _service.getRecentSubmissions(review: _review)
          : await _service.searchSubmissions(query, review: _review);
      if (!mounted || id != _requestId) return;
      setState(() {
        _submissions = rows;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || id != _requestId) return;
      setState(() {
        _error = 'Could not load submissions. Check your connection.';
        _loading = false;
      });
    }
  }

  /// Shows the spinner and loads again (search changed, or "Try again").
  void _reload() {
    _searchTimer?.cancel();
    setState(() {
      _loading = true;
      _error = null;
    });
    _fetch();
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

  void _onFilter(String? review) {
    if (review == _review) return;
    _review = review;
    _reload();
  }

  Future<void> _openDetails(CrimeSceneSummary s) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SubmissionDetailPage(submission: s, service: _service),
      ),
    );
    if (mounted) _reload(); // the review may have changed
  }

  Future<void> _runReview(
      Future<bool> Function(BuildContext, SupabaseService, CrimeSceneSummary)
          action,
      CrimeSceneSummary s) async {
    final changed = await action(context, _service, s);
    if (changed && mounted) _reload();
  }

  String get _countText {
    final n = _submissions.length;
    if (_query.trim().isEmpty) {
      return n == 1
          ? 'Showing the most recent submission'
          : 'Showing the $n most recent submissions';
    }
    return '$n ${n == 1 ? 'match' : 'matches'} for "${_query.trim()}"';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: AppSpacing.page,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Submissions', style: AppText.sectionTitle),
          const SizedBox(height: AppSpacing.small),
          const Text(
            'Review every incident reported to Argus Shield.',
            style: AppText.bodyMuted,
          ),
          const SizedBox(height: AppSpacing.medium),

          // Search bar — borders and focus colour come from the app theme.
          TextField(
            controller: _searchController,
            style: AppText.body,
            textInputAction: TextInputAction.search,
            onChanged: _onSearchChanged,
            onSubmitted: (_) => _reload(), // search now, don't wait
            decoration: InputDecoration(
              hintText: 'Search by incident number/location',
              prefixIcon: const Icon(Icons.search, color: AppColors.accent),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, color: AppColors.textMuted),
                      tooltip: 'Clear search',
                      onPressed: _clearSearch,
                    ),
            ),
          ),
          const SizedBox(height: AppSpacing.small),

          // Filter chips (scroll sideways on narrow phones)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final (label, value) in AdminSubmissions.filters) ...[
                  ChoiceChip(
                    label: Text(label),
                    selected: _review == value,
                    onSelected: (_) => _onFilter(value),
                    selectedColor: AppColors.accent,
                    backgroundColor: AppColors.header,
                    labelStyle: AppText.body.copyWith(
                      fontSize: 13,
                      color: _review == value
                          ? AppColors.header
                          : AppColors.textPrimary,
                    ),
                    showCheckmark: false,
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.small),
          if (!_loading && _error == null)
            Text(
              _countText,
              style: AppText.caption.copyWith(color: AppColors.textMuted),
            ),
          const SizedBox(height: AppSpacing.medium),

          // Only the list scrolls; the title and search bar stay in place.
          Expanded(child: _buildList()),
        ],
      ),
    );
  }

  Widget _buildList() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: AppText.bodyMuted, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.small),
            TextButton(onPressed: _reload, child: const Text('Try again')),
          ],
        ),
      );
    }

    if (_submissions.isEmpty) {
      return Center(
        child: Text(
          _query.trim().isNotEmpty
              ? 'No submissions match your search.'
              : _review == null
                  ? 'No incidents have been reported yet.'
                  : 'No submissions in this list.',
          style: AppText.bodyMuted,
          textAlign: TextAlign.center,
        ),
      );
    }

    // Pull down to refresh.
    return RefreshIndicator(
      onRefresh: _fetch,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _submissions.length,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.medium),
        itemBuilder: (context, index) {
          final s = _submissions[index];
          return CrimeSceneCard(
            submission: s,
            onTap: () => _openDetails(s),
            onAccept: () => _runReview(acceptSubmission, s),
            onReject: () => _runReview(rejectSubmission, s),
          );
        },
      ),
    );
  }
}

/// One incident's details. Same style as InvestigatorCard.
///
/// Tapping the card calls [onTap] (opens the details page). For a pending
/// submission, passing [onAccept] / [onReject] adds the wireframe's
/// Reject · View · Accept buttons.
class CrimeSceneCard extends StatelessWidget {
  final CrimeSceneSummary submission;
  final VoidCallback? onTap;
  final VoidCallback? onAccept;
  final VoidCallback? onReject;

  const CrimeSceneCard({
    super.key,
    required this.submission,
    this.onTap,
    this.onAccept,
    this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final s = submission;
    final (statusLabel, statusColor) = statusStyle(s.status);
    final (reviewLabel, reviewColor) = reviewStyle(s.reviewStatus);
    final showActions = s.isPending && (onAccept != null || onReject != null);

    return Material(
      color: AppColors.header,
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: s.isPending ? AppColors.accent : AppColors.fieldBorder,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Reference + review decision + incident status
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Text(s.reference, style: AppText.cardTitle)),
                  const SizedBox(width: AppSpacing.small),
                  StatusTag(label: statusLabel, color: statusColor),
                ],
              ),
              const SizedBox(height: 6),
              StatusTag(label: reviewLabel, color: reviewColor),
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
              DetailLine(
                  icon: Icons.schedule,
                  text: 'Happened ${formatDateTime(s.dateTime)}'),
              if (s.dateReported != null)
                DetailLine(
                    icon: Icons.upload_outlined,
                    text: 'Reported ${formatDateTime(s.dateReported!)}'),
              DetailLine(
                icon: Icons.person_outline,
                text: 'Reported by ${s.reporterName}',
              ),
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

              if (s.description != null) ...[
                const SizedBox(height: 4),
                Text(s.description!, style: AppText.bodyMuted),
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
        ),
      ),
    );
  }
}
