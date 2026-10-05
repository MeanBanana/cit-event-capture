// overview.dart — System Administrator landing tab ("Overview").
//
// Sections, top to bottom (from the Figma "Screen 2: Admin Dashboard"):
//   1. SYSTEM STATUS — LIVE      four stat tiles
//   2. RECENT ACTIVITY           latest events with a NEW / VER tag
//   3. RECENT ACTIVE INVESTIGATORS
//   4. RECENT SUBMISSIONS        with a View button
//
// Like the citizen pages, this file returns only a body. AdminDashboard
// draws the Scaffold, header and tabs.
//
// Everything below uses hard-coded sample data so the layout can be reviewed.
// It reuses the same model classes (and the same sample people) as the
// Investigators and Submissions tabs, so when the Supabase fetch is ready the
// same rows can feed all three tabs.

import 'package:flutter/material.dart';
import 'package:argus_shield/theme/app_theme.dart';
import 'package:argus_shield/theme/argus_widgets.dart';
import 'package:argus_shield/admin_screens/investigators.dart';
import 'package:argus_shield/admin_screens/submissions.dart';

/// Tab positions in AdminDashboard, used by the "see more" links.
/// Keep these in step with the order of tabs in admin_dashboard.dart.
const int _investigatorsTabIndex = 1;
const int _submissionsTabIndex = 2;

/// Numbers for the four stat tiles.
///
/// Where each one will come from in the database:
///   totalCases    count of crimescene rows
///   activeCases   crimescene rows with status 'open' or 'under_review'
///   pendingCases  crimescene rows with no active caseassignment
///   investigators count of investigator rows
class SystemStats {
  final int totalCases;
  final int activeCases;
  final int pendingCases;
  final int investigators;

  const SystemStats({
    required this.totalCases,
    required this.activeCases,
    required this.pendingCases,
    required this.investigators,
  });
}

/// One line in the Recent Activity feed.
class ActivityItem {
  final String tag; // short label in the box, e.g. 'NEW', 'VER'
  final String text;
  final DateTime at;

  const ActivityItem({required this.tag, required this.text, required this.at});
}

class AdminOverview extends StatelessWidget {
  const AdminOverview({super.key});

  // ---- Sample data — swap for Supabase results later --------------------

  static const SystemStats _stats = SystemStats(
    totalCases: 5,
    activeCases: 2,
    pendingCases: 1,
    investigators: 4,
  );

  static List<ActivityItem> get _activity => [
        ActivityItem(
          tag: 'NEW',
          text: 'New citizen submission on INC-0042',
          at: DateTime.now().subtract(const Duration(hours: 2)),
        ),
        ActivityItem(
          tag: 'VER',
          text: 'Inv. Mokoena verified detection D-001 on INC-0042',
          at: DateTime.now().subtract(const Duration(hours: 6)),
        ),
      ];

  // Same sample investigator as the Investigators tab, plus a second one.
  static const List<InvestigatorSummary> _investigators = [
    InvestigatorSummary(
      userId: 1,
      firstName: 'Thabo',
      surname: 'Mokoena',
      rank: 'Sgt.',
      badgeNumber: 'JHB-4471',
      station: 'Kempton Park SAPS',
      unit: 'CIT Task Force',
      dutyStatus: 'on_duty',
      email: 'thabo.mokoena@saps.gov.za',
      phoneNumber: '082 555 0147',
      activeCases: 3,
    ),
    InvestigatorSummary(
      userId: 2,
      firstName: 'Anri',
      surname: 'Pieterse',
      rank: 'Sgt.',
      badgeNumber: 'JHB-4483',
      station: 'Kempton Park SAPS',
      unit: 'CIT Task Force',
      dutyStatus: 'available',
      email: 'anri.pieterse@saps.gov.za',
      activeCases: 2,
    ),
  ];

  // Same sample incident as the Submissions tab.
  static List<CrimeSceneSummary> get _submissions => [
        CrimeSceneSummary(
          incidentId: 42,
          location: 'R21 Highway, near OR Tambo off-ramp, Kempton Park',
          dateTime: DateTime(2026, 9, 28, 14, 35),
          attackType: 'Vehicle ambush',
          status: 'open',
          description:
              'Cash van forced off the road by two sedans. Armed suspects '
              'fled north with cash cases. Dashcam and phone footage submitted.',
          reportedBy: 7,
          reporterName: 'Lerato Dlamini',
          mediaCount: 3,
        ),
      ];

  // -----------------------------------------------------------------------

  /// Switches AdminDashboard to another tab (used by "see more").
  void _goToTab(BuildContext context, int index) =>
      DefaultTabController.maybeOf(context)?.animateTo(index);

  /// Placeholder for buttons that will do something once Supabase is wired.
  void _notReady(BuildContext context, String action) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$action is not connected yet.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: AppSpacing.page,
      children: [
        // 1. System status ------------------------------------------------
        const _SectionHeading('System status — live'),
        Row(
          children: [
            Expanded(
              child: _StatTile(
                title: 'Total cases',
                value: _stats.totalCases,
                subtitle: 'all time',
              ),
            ),
            const SizedBox(width: AppSpacing.medium),
            Expanded(
              child: _StatTile(
                title: 'Active',
                value: _stats.activeCases,
                subtitle: 'ongoing',
                color: AppColors.danger,
                animatedBorder: true, // red stripes run round the box
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.medium),
        Row(
          children: [
            Expanded(
              child: _StatTile(
                title: 'Pending',
                value: _stats.pendingCases,
                subtitle: 'unassigned',
                color: AppColors.accent,
              ),
            ),
            const SizedBox(width: AppSpacing.medium),
            Expanded(
              child: _StatTile(
                title: 'Investigators',
                value: _stats.investigators,
                subtitle: 'registered',
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.large),

        // 2. Recent activity ----------------------------------------------
        const _SectionHeading('Recent activity'),
        for (final item in _activity) _ActivityRow(item: item),
        _SeeMore(onTap: () => _notReady(context, 'Full activity log')),
        const SizedBox(height: AppSpacing.medium),

        // 3. Recent active investigators ----------------------------------
        const _SectionHeading('Recent active investigators'),
        for (final inv in _investigators) ...[
          _InvestigatorMiniCard(
            investigator: inv,
            onProfile: () => _notReady(context, 'Investigator profile'),
          ),
          const SizedBox(height: AppSpacing.small),
        ],
        _SeeMore(onTap: () => _goToTab(context, _investigatorsTabIndex)),
        const SizedBox(height: AppSpacing.medium),

        // 4. Recent submissions -------------------------------------------
        const _SectionHeading('Recent submissions'),
        for (final s in _submissions) ...[
          _SubmissionReviewCard(
            submission: s,
            onView: () => _notReady(context, 'View submission'),
          ),
          const SizedBox(height: AppSpacing.small),
        ],
        _SeeMore(onTap: () => _goToTab(context, _submissionsTabIndex)),
      ],
    );
  }
}

// =========================================================================
// Building blocks
// =========================================================================

/// Centred Courier heading above each section, e.g. "RECENT ACTIVITY".
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
          style: AppText.cardTitle.copyWith(fontSize: 15, letterSpacing: 1),
        ),
      ),
    );
  }
}

/// Small right-aligned "see more" link under a section.
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
          foregroundColor: AppColors.textHint,
          textStyle: AppText.bodyMuted.copyWith(fontSize: 13),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          minimumSize: const Size(0, 32),
        ),
        child: const Text('see more'),
      ),
    );
  }
}

/// One of the four boxes under SYSTEM STATUS.
/// [color] tints the border, title and number; null keeps it neutral.
/// [animatedBorder] swaps the plain border for running stripes
/// (AnimatedStripeBorder in theme/argus_widgets.dart).
class _StatTile extends StatelessWidget {
  final String title;
  final int value;
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
            color: highlight ?? AppColors.textPrimary,
          ),
        ),
        Text(
          '$value',
          style: AppText.body.copyWith(
            fontSize: 30,
            fontWeight: FontWeight.bold,
            height: 1.1,
            color: highlight ?? AppColors.textPrimary,
          ),
        ),
        Text(subtitle, style: AppText.bodyMuted.copyWith(fontSize: 13)),
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

/// One line of the Recent Activity feed: tag box, text, "2h ago".
class _ActivityRow extends StatelessWidget {
  final ActivityItem item;

  const _ActivityRow({required this.item});

  /// "just now", "45m ago", "2h ago", "3d ago".
  static String _timeAgo(DateTime at) {
    final diff = DateTime.now().difference(at);
    if (diff.inMinutes < 1) return 'just now';
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
                Text(item.text, style: AppText.body.copyWith(fontSize: 14)),
                Text(
                  _timeAgo(item.at),
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

/// Compact investigator row: avatar, name, badge · unit, duty, PROFILE.
class _InvestigatorMiniCard extends StatelessWidget {
  final InvestigatorSummary investigator;
  final VoidCallback onProfile;

  const _InvestigatorMiniCard({
    required this.investigator,
    required this.onProfile,
  });

  /// Database value → label and colour for the duty line.
  static (String, Color) _duty(String dutyStatus) {
    switch (dutyStatus) {
      case 'on_duty':
        return ('On duty', AppColors.success);
      case 'available':
        return ('Available', AppColors.accent);
      case 'off_duty':
        return ('Off duty', AppColors.textHint);
      default:
        return (dutyStatus, AppColors.textMuted);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inv = investigator;
    final (dutyLabel, dutyColor) = _duty(inv.dutyStatus);
    final initials = '${inv.firstName[0]}${inv.surname[0]}';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.header,
        border: Border.all(color: AppColors.accent),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: AppColors.textPrimary,
            child: Text(
              initials,
              style: AppText.buttonSmall.copyWith(
                fontSize: 13,
                color: AppColors.header,
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
                    color: AppColors.textMuted,
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
          // Smaller than the theme's big 30px button, so style it here.
          ElevatedButton(
            onPressed: onProfile,
            style: ElevatedButton.styleFrom(
              foregroundColor: AppColors.header,
              textStyle: AppText.buttonSmall.copyWith(fontSize: 13),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              minimumSize: const Size(0, 36),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
            ),
            child: const Text('PROFILE'),
          ),
        ],
      ),
    );
  }
}

/// A submission waiting for the admin: details plus a View button.
class _SubmissionReviewCard extends StatelessWidget {
  final CrimeSceneSummary submission;
  final VoidCallback onView;

  const _SubmissionReviewCard({
    required this.submission,
    required this.onView,
  });

  /// 2026-09-28 / 14:35 — formatted without adding the intl package.
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
        color: AppColors.header,
        border: Border.all(color: AppColors.accent, width: 2),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Every submission shown here is waiting for an admin decision.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.accent),
              borderRadius: BorderRadius.circular(2),
            ),
            child: Text(
              'PENDING REVIEW',
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
              color: AppColors.textMuted,
            ),
          ),
          const SizedBox(height: 12),
          // Single action, bottom-right of the card.
          Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: 110,
              child: _OutlineAction(
                label: 'View',
                color: AppColors.fieldBorder,
                textColor: AppColors.textPrimary,
                onPressed: onView,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Outlined button used for View.
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
        foregroundColor: textColor ?? color,
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
