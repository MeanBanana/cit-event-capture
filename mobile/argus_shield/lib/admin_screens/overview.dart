// The admin's Overview tab, the first thing they land on. Laid out like the
// Figma "Admin Dashboard" screen: system status tiles, recent activity,
// recently active investigators and recent submissions.
//
// Like the citizen pages this only builds the body, AdminDashboard handles
// the Scaffold, header and tabs. Everything comes live from Supabase and you
// can pull down to refresh.

import 'package:flutter/material.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/theme/argus_widgets.dart';
import 'package:argus_shield/admin_screens/admin_ui.dart';
import 'package:argus_shield/admin_screens/investigators.dart';
import 'package:argus_shield/admin_screens/submissions.dart';
import 'package:argus_shield/supabase_service.dart';
import 'package:argus_shield/models/system_stats.dart';
import 'package:argus_shield/models/activity_item.dart';
import 'package:argus_shield/admin_screens/review_actions.dart';
import 'package:argus_shield/admin_screens/submission_detail.dart';
import 'package:argus_shield/app_settings.dart';

/// Tab indexes in AdminDashboard, for the "see more" links. If you reorder
/// the tabs in admin_dashboard.dart, update these too.
const int _investigatorsTabIndex = 2;
const int _submissionsTabIndex = 3;

class AdminOverview extends StatefulWidget {
  /// Tests pass a fake in here, the app just uses the real one.
  final SupabaseService? service;

  const AdminOverview({super.key, this.service});

  /// How many investigators to show under "Recent active investigators".
  static const int recentInvestigatorCount = 3;

  /// How many submissions to show under "Recent submissions".
  static const int recentSubmissionCount = 2;

  /// How many items to show under "Recent activity".
  static const int recentActivityCount = 5;

  /// How many items the full activity log loads. recent_activity caps out
  /// at 50 anyway.
  static const int fullActivityCount = 50;

  @override
  State<AdminOverview> createState() => _AdminOverviewState();
}

class _AdminOverviewState extends State<AdminOverview> {
  late final SupabaseService _service = widget.service ?? SupabaseService();

  // null/empty while loading, or if it failed
  SystemStats? _stats;
  List<InvestigatorSummary> _investigators = const [];
  List<CrimeSceneSummary> _submissions = const [];
  List<ActivityItem> _activity = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // TabBarView rebuilds this every time the tab is opened, so the numbers
    // are fresh whenever the admin comes back here
    _fetch();
  }

  /// Load stats, activity, investigators and submissions all at once.
  Future<void> _fetch() async {
    try {
      final results = await Future.wait([
        _service.getAdminStats(),
        _service.getRecentInvestigators(
            limit: AdminOverview.recentInvestigatorCount),
        _service.getRecentSubmissions(
            limit: AdminOverview.recentSubmissionCount),
        _service.getRecentActivity(limit: AdminOverview.recentActivityCount),
      ]);
      if (!mounted) return;
      setState(() {
        _stats = results[0] as SystemStats;
        _investigators = results[1] as List<InvestigatorSummary>;
        _submissions = results[2] as List<CrimeSceneSummary>;
        _activity = results[3] as List<ActivityItem>;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = appSettings.t('loadError');
        _loading = false;
      });
    }
  }

  /// Open a submission, and reload when they come back in case they
  /// accepted/rejected it in there.
  Future<void> _openSubmission(CrimeSceneSummary s) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SubmissionDetailPage(submission: s, service: _service),
      ),
    );
    if (mounted) _fetch();
  }

  /// Accept/Reject right from the card, then refresh the numbers.
  Future<void> _runReview(
      Future<bool> Function(BuildContext, SupabaseService, CrimeSceneSummary)
          action,
      CrimeSceneSummary s) async {
    final changed = await action(context, _service, s);
    if (changed && mounted) _fetch();
  }

  /// Jump AdminDashboard to another tab (for "see more").
  void _goToTab(BuildContext context, int index) =>
      DefaultTabController.maybeOf(context)?.animateTo(index);

  /// "see more" under Recent activity opens the full log.
  Future<void> _openActivityLog() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ActivityLogPage(service: _service)),
    );
    if (mounted) _fetch();
  }

  @override
  Widget build(BuildContext context) {
    final stats = _stats; // tiles show "—" while this is null

    // pull to refresh
    return ListenableBuilder(
      listenable: appSettings,
      builder: (context, _) => RefreshIndicator(
      onRefresh: _fetch,
      child: ListView(
        // same side margins as the other admin tabs, plus a bit of space
        // under the last card so it doesn't sit right on the edge
        padding: AppSpacing.tab.copyWith(bottom: 12),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          // system status
          _SectionHeading(appSettings.t('systemStatus')),
          if (_error != null) ...[
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: AppText.bodyMuted.copyWith(color: AppColors.danger),
            ),
            const SizedBox(height: AppSpacing.small),
          ],
          Row(
            children: [
              Expanded(
                child: _StatTile(
                  title: appSettings.t('totalCases'),
                  value: stats?.totalCases,
                  subtitle: appSettings.t('allTime'),
                ),
              ),
              const SizedBox(width: AppSpacing.medium),
              Expanded(
                child: _StatTile(
                  title: appSettings.t('active'),
                  value: stats?.activeCases,
                  subtitle: appSettings.t('ongoing'),
                  color: AppColors.danger,
                  animatedBorder: true, // red stripes running round the box
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.medium),
          Row(
            children: [
              Expanded(
                child: _StatTile(
                  title: appSettings.t('pending'),
                  value: stats?.pendingCases,
                  subtitle: appSettings.t('unassigned'),
                  color: AppColors.accent,
                ),
              ),
              const SizedBox(width: AppSpacing.medium),
              Expanded(
                child: _StatTile(
                  title: appSettings.t('investigators'),
                  value: stats?.investigators,
                  subtitle: appSettings.t('registered'),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.large),

          // recent activity
          _SectionHeading(appSettings.t('recentActivity')),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.medium),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_activity.isEmpty && _error == null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.small),
              child: Text(
                appSettings.t('noActivity'),
                textAlign: TextAlign.center,
                style: AppText.bodyMuted.copyWith(color: _muted(context)),
              ),
            ),
          for (final item in _activity) _ActivityRow(item: item),
          _SeeMore(onTap: _openActivityLog),
          const SizedBox(height: AppSpacing.medium),

          // recent active investigators
          _SectionHeading(appSettings.t('recentInvestigators')),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.medium),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_investigators.isEmpty && _error == null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.small),
              child: Text(
                appSettings.t('noInvestigators'),
                textAlign: TextAlign.center,
                style: AppText.bodyMuted.copyWith(color: _muted(context)),
              ),
            ),
          for (final inv in _investigators) ...[
            // PROFILE expands the card to show their full details
            _InvestigatorMiniCard(
              key: ValueKey('overview-investigator-${inv.userId}'),
              investigator: inv,
            ),
            const SizedBox(height: AppSpacing.small),
          ],
          _SeeMore(onTap: () => _goToTab(context, _investigatorsTabIndex)),
          const SizedBox(height: AppSpacing.medium),

          // recent submissions
          _SectionHeading(appSettings.t('recentSubmissions')),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(AppSpacing.medium),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_submissions.isEmpty && _error == null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.small),
              child: Text(
                appSettings.t('noSubmissions'),
                textAlign: TextAlign.center,
                style: AppText.bodyMuted.copyWith(color: _muted(context)),
              ),
            ),
          for (final s in _submissions) ...[
            _SubmissionReviewCard(
              submission: s,
              onView: () => _openSubmission(s),
              onAccept: () => _runReview(acceptSubmission, s),
              onReject: () => _runReview(rejectSubmission, s),
            ),
            const SizedBox(height: AppSpacing.small),
          ],
          _SeeMore(onTap: () => _goToTab(context, _submissionsTabIndex)),
        ],
      ),
      ),
    );
  }
}

// --- building blocks

/// Text on the page background, white in dark mode and dark in light mode.
Color _muted(BuildContext context) => Theme.of(context).brightness == Brightness.dark
    ? AppColors.neutral
    : Colors.black54;

Color _onSurface(BuildContext context) => Theme.of(context).colorScheme.onSurface;

/// The centred Courier heading above each section, e.g. "RECENT ACTIVITY".
class _SectionHeading extends StatelessWidget {
  final String text;

  const _SectionHeading(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Center(
        child: Text(
          text.toUpperCase(),
          style: AppText.cardTitle.copyWith(
            fontSize: 15,
            letterSpacing: 1,
            color: _onSurface(context),
          ),
        ),
      ),
    );
  }
}

/// The little right-aligned "see more" link under a section.
class _SeeMore extends StatelessWidget {
  final VoidCallback onTap;

  const _SeeMore({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          foregroundColor: _muted(context),
          textStyle: AppText.bodyMuted.copyWith(fontSize: 13),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          minimumSize: const Size(0, 32),
        ),
        child: Text(appSettings.t('seeMore')),
      ),
    );
  }
}

/// One of the four System status tiles. [color] tints the border, title and
/// number (null keeps it neutral). [animatedBorder] swaps the plain border
/// for running stripes (AnimatedStripeBorder in theme/argus_widgets.dart).
class _StatTile extends StatelessWidget {
  final String title;
  final int? value; // null shows "—" (still loading, or it failed)
  final String subtitle;
  final Color? color;
  final bool animatedBorder;

  const _StatTile({
    required this.title,
    required this.value,
    required this.subtitle,
    this.color,
    this.animatedBorder = false,
  });

  @override
  Widget build(BuildContext context) {
    final highlight = color;
    final onSurface = _onSurface(context);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.cardTitle.copyWith(
            fontSize: 15,
            fontWeight: FontWeight.normal,
            color: highlight ?? onSurface,
          ),
        ),
        Text(
          value?.toString() ?? '—',
          style: AppText.body.copyWith(
            fontSize: 30,
            fontWeight: FontWeight.bold,
            height: 1.1,
            color: highlight ?? onSurface,
          ),
        ),
        Text(
          subtitle,
          style: AppText.bodyMuted.copyWith(fontSize: 13, color: _muted(context)),
        ),
      ],
    );

    if (animatedBorder) {
      return AnimatedStripeBorder(
        color: highlight ?? AppColors.danger,
        child: content,
      );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(
          color: highlight ?? AppColors.fieldBorder,
          width: highlight == null ? 1 : 2,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: content,
    );
  }
}

/// A line in the activity feed: tag, text and "2h ago".
class _ActivityRow extends StatelessWidget {
  final ActivityItem item;

  const _ActivityRow({required this.item});

  /// "just now", "45m ago", "2h ago", "3d ago"
  static String _timeAgo(DateTime at) {
    final diff = DateTime.now().difference(at);
    if (diff.inMinutes < 1) return appSettings.t('justNow');
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.fieldBorder)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 2),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: AppColors.accent.withValues(alpha: 0.25),
              border: Border.all(color: AppColors.accent),
              borderRadius: BorderRadius.circular(2),
            ),
            child: Text(
              item.tag,
              style: AppText.caption.copyWith(fontSize: 9, letterSpacing: 0.4),
            ),
          ),
          const SizedBox(width: AppSpacing.small),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.text,
                  style: AppText.body.copyWith(
                    fontSize: 14,
                    color: _onSurface(context),
                  ),
                ),
                Text(
                  _timeAgo(item.at),
                  style: AppText.bodyMuted.copyWith(
                    fontSize: 12,
                    color: _muted(context),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact investigator row: avatar, name, badge and unit, duty, PROFILE.
/// PROFILE expands it to show everything, HIDE collapses it again.
class _InvestigatorMiniCard extends StatefulWidget {
  final InvestigatorSummary investigator;

  const _InvestigatorMiniCard({super.key, required this.investigator});

  @override
  State<_InvestigatorMiniCard> createState() => _InvestigatorMiniCardState();
}

class _InvestigatorMiniCardState extends State<_InvestigatorMiniCard> {
  bool _expanded = false;

  /// Maps the duty value from the database to a label and colour.
  static (String, Color) _duty(String dutyStatus) {
    switch (dutyStatus) {
      case 'on_duty':
        return (appSettings.t('onDuty'), AppColors.success);
      case 'available':
        return (appSettings.t('available'), AppColors.accent);
      case 'off_duty':
        return (appSettings.t('offDuty'), AppColors.neutral);
      default:
        return (dutyStatus, AppColors.neutral);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inv = widget.investigator;
    final (dutyLabel, dutyColor) = _duty(inv.dutyStatus);
    final initials = '${inv.firstName[0]}${inv.surname[0]}';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cardColor(context),
        border: Border.all(color: AppColors.accent),
        borderRadius: BorderRadius.circular(4),
      ),
      child: NavyText(
        // AnimatedSize so it grows/shrinks smoothly
        child: AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: pageInk(context),
            child: Text(
              initials,
              style: AppText.buttonSmall.copyWith(
                fontSize: 13,
                color: cardColor(context),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  inv.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body.copyWith(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  [inv.badgeNumber, if (inv.unit != null) inv.unit!]
                      .join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: AppFonts.heading,
                    fontSize: 10,
                    color: AppColors.neutral,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '● ${dutyLabel.toUpperCase()} · CASES: ${inv.activeCases}',
                  style: AppText.caption.copyWith(
                    fontSize: 9,
                    color: dutyColor,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.small),
          // the theme's button is a chunky 30px, this needs to be smaller
          ElevatedButton(
            key: ValueKey('profile-${inv.userId}'),
            onPressed: () => setState(() => _expanded = !_expanded),
            style: ElevatedButton.styleFrom(
              foregroundColor: AppColors.header,
              textStyle: AppText.buttonSmall.copyWith(fontSize: 13),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              minimumSize: const Size(0, 36),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            child: Text(appSettings.t(_expanded ? 'hideProfile' : 'profile')),
          ),
        ],
      ),
              if (_expanded) _ProfileDetails(investigator: inv),
            ],
          ),
        ),
      ),
    );
  }
}

/// The investigator's full details, shown when PROFILE is tapped.
class _ProfileDetails extends StatelessWidget {
  final InvestigatorSummary investigator;

  const _ProfileDetails({required this.investigator});

  @override
  Widget build(BuildContext context) {
    final inv = investigator;
    final ink = pageInk(context);
    Widget line(IconData icon, String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 16, color: AppColors.accent),
              const SizedBox(width: 8),
              SizedBox(
                width: 92,
                child: Text(label,
                    style: AppText.bodyMuted
                        .copyWith(fontSize: 13, color: AppColors.neutral)),
              ),
              Expanded(
                child: SelectableText(value,
                    style: AppText.body.copyWith(fontSize: 14, color: ink)),
              ),
            ],
          ),
        );

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(height: 1, color: AppColors.fieldBorder),
          const SizedBox(height: 10),
          line(Icons.person_outline, appSettings.t('fullName'),
              inv.displayName),
          line(Icons.badge_outlined, appSettings.t('badge'), inv.badgeNumber),
          line(Icons.location_city_outlined, appSettings.t('station'),
              inv.station),
          if (inv.unit != null)
            line(Icons.groups_outlined, appSettings.t('unitLabel'), inv.unit!),
          line(Icons.email_outlined, appSettings.t('email'), inv.email),
          line(
              Icons.phone_outlined,
              appSettings.t('phoneNumber'),
              inv.phoneNumber == null || inv.phoneNumber!.isEmpty
                  ? appSettings.t('noPhone')
                  : inv.phoneNumber!),
          line(Icons.folder_open_outlined, appSettings.t('activeCasesLabel2'),
              '${inv.activeCases}'),
          if (inv.dateCreated != null)
            line(Icons.event_outlined, appSettings.t('joined'),
                formatDate(inv.dateCreated!.toLocal())),
        ],
      ),
    );
  }
}

// --- full activity log ("see more" under Recent activity)

/// All recent events (up to [AdminOverview.fullActivityCount]), newest
/// first, with chips to filter down to one kind (NEW, CASE, ASGN...).
class ActivityLogPage extends StatefulWidget {
  /// Tests pass a fake in here, the app just uses the real one.
  final SupabaseService? service;

  const ActivityLogPage({super.key, this.service});

  @override
  State<ActivityLogPage> createState() => _ActivityLogPageState();
}

class _ActivityLogPageState extends State<ActivityLogPage> {
  late final SupabaseService _service = widget.service ?? SupabaseService();
  List<ActivityItem> _items = const [];
  bool _loading = true;
  String? _error;

  /// null for everything, otherwise a tag like 'NEW'.
  String? _tag;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await _service.getRecentActivity(
          limit: AdminOverview.fullActivityCount);
      if (!mounted) return;
      setState(() {
        _items = items;
        _error = null;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = appSettings.t('loadError');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // only show chips for kinds that are actually in the list
    final tags = <String>{for (final i in _items) i.tag}.toList()..sort();
    final tag = tags.contains(_tag) ? _tag : null;
    final shown =
        tag == null ? _items : _items.where((i) => i.tag == tag).toList();

    return ListenableBuilder(
      listenable: appSettings,
      builder: (context, _) => Scaffold(
        appBar: ArgusAppBar(roleLabel: appSettings.t('systemAdministrator')),
        body: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: AppSpacing.tab.copyWith(bottom: 12),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              _SectionHeading(appSettings.t('fullActivityLog')),
              Text(
                appSettings.t('activityLogNote'),
                textAlign: TextAlign.center,
                style: AppText.bodyMuted
                    .copyWith(fontSize: 13, color: _muted(context)),
              ),
              const SizedBox(height: AppSpacing.small),
              if (tags.length > 1) ...[
                ChipRow<String?>(
                  options: <(String, String?)>[
                    (appSettings.t('filterAll'), null),
                    for (final t in tags) (t, t),
                  ],
                  selected: tag,
                  onSelected: (value) => setState(() => _tag = value),
                ),
                const SizedBox(height: AppSpacing.small),
              ],
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(AppSpacing.medium),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null)
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: AppText.bodyMuted.copyWith(color: AppColors.danger),
                )
              else if (shown.isEmpty)
                Text(
                  appSettings.t('noActivity'),
                  textAlign: TextAlign.center,
                  style: AppText.bodyMuted.copyWith(color: _muted(context)),
                )
              else
                for (final item in shown) _ActivityRow(item: item),
            ],
          ),
        ),
      ),
    );
  }
}

/// A submission waiting on the admin, with a View button.
class _SubmissionReviewCard extends StatelessWidget {
  final CrimeSceneSummary submission;
  final VoidCallback onView;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  const _SubmissionReviewCard({
    required this.submission,
    required this.onView,
    required this.onAccept,
    required this.onReject,
  });

  /// e.g. 2026-09-28 / 14:35. Done by hand so we don't need the intl package.
  static String _formatDateTime(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} / '
        '${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final s = submission;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cardColor(context),
        border: Border.all(color: AppColors.accent, width: 2),
        borderRadius: BorderRadius.circular(4),
      ),
      child: NavyText(
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // the admin's review decision
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.accent),
              borderRadius: BorderRadius.circular(2),
            ),
            child: Text(
              switch (s.reviewStatus) {
                'pending' => appSettings.t('pendingReview'),
                'accepted' => 'ADDED TO ${s.caseReference ?? 'CASE'}',
                'rejected' => appSettings.t('rejected'),
                'duplicate' => appSettings.t('duplicate'),
                _ => s.reviewStatus.toUpperCase(),
              },
              style: AppText.caption.copyWith(fontSize: 10),
            ),
          ),
          const SizedBox(height: 8),
          if (s.description != null)
            Text(s.description!, style: AppText.body.copyWith(fontSize: 14)),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.location_on, size: 14, color: AppColors.danger),
              const SizedBox(width: 2),
              Expanded(
                child: Text(
                  s.location,
                  style: AppText.body.copyWith(
                    fontSize: 13,
                    color: AppColors.danger,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            _formatDateTime(s.dateTime),
            style: const TextStyle(
              fontFamily: AppFonts.heading,
              fontSize: 11,
              color: AppColors.neutral,
            ),
          ),
          const SizedBox(height: 12),
          // Pending ones get Reject / View / Accept like the wireframe,
          // reviewed ones just get View in the bottom right.
          if (s.isPending)
            Row(
              children: [
                Expanded(
                  child: _OutlineAction(
                    label: appSettings.t('reject'),
                    color: AppColors.danger,
                    onPressed: onReject,
                  ),
                ),
                const SizedBox(width: AppSpacing.small),
                Expanded(
                  child: _OutlineAction(
                    label: appSettings.t('view'),
                    color: AppColors.fieldBorder,
                    textColor: AppColors.textPrimary,
                    onPressed: onView,
                  ),
                ),
                const SizedBox(width: AppSpacing.small),
                Expanded(
                  child: _OutlineAction(
                    label: appSettings.t('accept'),
                    color: AppColors.success,
                    onPressed: onAccept,
                  ),
                ),
              ],
            )
          else
            Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                width: 110,
                child: _OutlineAction(
                  label: appSettings.t('view'),
                  color: AppColors.fieldBorder,
                  textColor: AppColors.textPrimary,
                  onPressed: onView,
                ),
              ),
            ),
        ],
      ),
      ),
    );
  }
}

/// Outlined View button.
class _OutlineAction extends StatelessWidget {
  final String label;
  final Color color;
  final Color? textColor;
  final VoidCallback onPressed;

  const _OutlineAction({
    required this.label,
    required this.color,
    this.textColor,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        // white text needs to go dark in light mode
        foregroundColor: textColor == AppColors.textPrimary
            ? pageInk(context)
            : textColor ?? color,
        side: BorderSide(color: color, width: 2),
        textStyle: AppText.buttonSmall.copyWith(fontSize: 13),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        minimumSize: const Size(0, 38),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      child: FittedBox(fit: BoxFit.scaleDown, child: Text(label)),
    );
  }
}
