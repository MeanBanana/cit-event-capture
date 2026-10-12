// admin_ui.dart — small pieces shared by the admin screens: date formats,
// status tags, error messages, snackbars and confirm dialogs.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:argus_shield/theme/app_theme.dart';

/// 28/09/2026 14:35 — formatted without adding the intl package.
String formatDateTime(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
}

/// 28/09/2026
String formatDate(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year}';
}

/// Incident or case status ('open' / 'under_review' / 'closed') → label
/// and colour.
(String, Color) statusStyle(String status) {
  switch (status) {
    case 'open':
      return ('Open', AppColors.danger);
    case 'under_review':
      return ('Under review', AppColors.accent);
    case 'closed':
      return ('Closed', AppColors.success);
    default:
      return (status, AppColors.textMuted);
  }
}

/// The admin's review decision on a submission → label and colour.
(String, Color) reviewStyle(String reviewStatus) {
  switch (reviewStatus) {
    case 'pending':
      return ('Pending review', AppColors.accent);
    case 'accepted':
      return ('In a case', AppColors.success);
    case 'rejected':
      return ('Rejected', AppColors.danger);
    case 'duplicate':
      return ('Duplicate', AppColors.textHint);
    default:
      return (reviewStatus, AppColors.textMuted);
  }
}

/// Small outlined label, e.g. "OPEN" or "PENDING REVIEW".
class StatusTag extends StatelessWidget {
  final String label;
  final Color color;

  const StatusTag({super.key, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label.toUpperCase(),
        style: AppText.caption.copyWith(color: color, fontSize: 11),
      ),
    );
  }
}

/// Icon + text line used on cards and detail pages.
class DetailLine extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;

  const DetailLine({
    super.key,
    required this.icon,
    required this.text,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color ?? AppColors.accent),
          const SizedBox(width: AppSpacing.small),
          Expanded(
            child: Text(
              text,
              style: color == null
                  ? AppText.bodyMuted
                  : AppText.bodyMuted.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// Courier heading for a section of a detail page, e.g. "INVESTIGATORS".
class SectionLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;

  const SectionLabel(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.medium, bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text.toUpperCase(),
              style: AppText.cardTitle.copyWith(fontSize: 15, letterSpacing: 1),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Small outlined action button (Reject / View / Accept ...).
class SmallActionButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback? onPressed;

  const SmallActionButton({
    super.key,
    required this.label,
    required this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color, width: 2),
        textStyle: AppText.buttonSmall.copyWith(fontSize: 13),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 38),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      child: FittedBox(fit: BoxFit.scaleDown, child: Text(label)),
    );
  }
}

/// A readable message for an error thrown by SupabaseService. Messages
/// raised by our database functions (e.g. "Case 5 is closed ...") are
/// shown as they are.
String errorText(Object error) {
  if (error is PostgrestException) return error.message;
  // Edge Functions (e.g. create-investigator) answer { "error": "..." }.
  if (error is FunctionException) {
    final details = error.details;
    if (details is Map && details['error'] is String) {
      return details['error'] as String;
    }
    if (error.status == 404) {
      return 'This feature is not set up on the server yet.';
    }
  }
  return 'Something went wrong. Check your connection and try again.';
}

void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Yes/no question. Returns true only when the user confirms.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title, style: AppText.cardTitle),
      content: Text(message, style: AppText.body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          style: TextButton.styleFrom(
            foregroundColor:
                destructive ? AppColors.danger : AppColors.accent,
          ),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Small filled chip for a fact the AI found, e.g. "2 vehicles" or a
/// number plate. Optional [icon] in front.
class FactChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color color;

  const FactChip(this.label,
      {super.key, this.icon, this.color = AppColors.textMuted});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
          ],
          // Flexible + ellipsis: a long reason never overflows the chip
          Flexible(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: AppText.bodyMuted.copyWith(fontSize: 12, color: color)),
          ),
        ],
      ),
    );
  }
}

/// "1 vehicle" / "2 vehicles".
String plural(int n, String one, [String? many]) =>
    '$n ${n == 1 ? one : (many ?? '${one}s')}';

/// What a card says about suspects, e.g. "2 confirmed suspects · about 1
/// possible suspect awaiting investigator review". Null when there are
/// none of either.
///
/// Possible suspects are people the AI saw that no investigator has
/// reviewed yet; only an investigator assigned to the case can confirm or
/// dismiss them (POPIA), so the admin screens only ever show this count.
String? suspectSummary({required int possible, required int confirmed}) {
  if (possible <= 0 && confirmed <= 0) return null;
  final text = [
    if (confirmed > 0) plural(confirmed, 'confirmed suspect'),
    if (possible > 0)
      'about ${plural(possible, 'possible suspect')} awaiting investigator review',
  ].join(' · ');
  return text[0].toUpperCase() + text.substring(1);
}

/// Colour for [suspectSummary]: red once someone is confirmed, otherwise
/// the accent (needs an investigator's attention).
Color suspectColor({required int confirmed}) =>
    confirmed > 0 ? AppColors.danger : AppColors.accent;

/// What to say about the AI summary when there isn't a usable one yet.
/// Returns null when [summary] should be shown as it is.
String? aiStatusNote(String status, {required bool hasSummary, int mediaCount = 1}) {
  if (mediaCount == 0 && !hasSummary) return 'No footage to analyse';
  switch (status) {
    case 'processing':
      return hasSummary ? 'Updating…' : 'AI analysis in progress…';
    case 'outdated':
      return 'New footage not analysed yet';
    case 'failed':
      return 'AI analysis failed';
    case 'ready':
      return hasSummary ? null : 'AI found nothing to report';
    default: // 'none'
      return hasSummary ? null : 'No AI analysis yet';
  }
}

/// The two descriptions of a submission: the citizen's own words and the
/// AI's summary of the footage. [maxLines] shortens both on cards.
class SubmissionDescriptions extends StatelessWidget {
  final String? citizen;
  final String? ai;
  final String aiStatus;
  final int mediaCount;
  final int? maxLines;

  /// False leaves out the AI SUMMARY block (the submission page shows it in
  /// its own section, with the people / vehicles / weapons under it).
  final bool showAi;

  const SubmissionDescriptions({
    super.key,
    required this.citizen,
    required this.ai,
    this.aiStatus = 'none',
    this.mediaCount = 1,
    this.maxLines,
    this.showAi = true,
  });

  @override
  Widget build(BuildContext context) {
    final note = aiStatusNote(aiStatus, hasSummary: ai != null, mediaCount: mediaCount);
    final overflow = maxLines == null ? null : TextOverflow.ellipsis;

    Widget block(String label, IconData icon, Widget text) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: AppColors.accent),
              const SizedBox(width: AppSpacing.small),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: AppText.caption
                            .copyWith(color: AppColors.textHint, fontSize: 11)),
                    const SizedBox(height: 2),
                    text,
                  ],
                ),
              ),
            ],
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        block(
          'CITIZEN',
          Icons.record_voice_over_outlined,
          Text(
            citizen == null || citizen!.trim().isEmpty
                ? 'No description given'
                : citizen!,
            style: citizen == null
                ? AppText.bodyMuted.copyWith(fontStyle: FontStyle.italic)
                : AppText.body.copyWith(fontSize: 15),
            maxLines: maxLines,
            overflow: overflow,
          ),
        ),
        if (showAi) block(
          'AI SUMMARY',
          Icons.auto_awesome_outlined,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (ai != null)
                Text(ai!,
                    style: AppText.body.copyWith(fontSize: 15),
                    maxLines: maxLines,
                    overflow: overflow),
              if (note != null)
                Text(note,
                    style: AppText.bodyMuted.copyWith(
                        fontSize: 13,
                        fontStyle: FontStyle.italic,
                        color: aiStatus == 'failed'
                            ? AppColors.danger
                            : AppColors.textHint)),
            ],
          ),
        ),
      ],
    );
  }
}

/// A row of choice chips (used for the view and filter rows). Scrolls
/// sideways on narrow phones.
class ChipRow<T> extends StatelessWidget {
  final List<(String, T)> options;
  final T selected;
  final ValueChanged<T> onSelected;

  const ChipRow({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final (label, value) in options) ...[
            ChoiceChip(
              label: Text(label),
              selected: selected == value,
              onSelected: (_) => onSelected(value),
              selectedColor: AppColors.accent,
              backgroundColor: AppColors.header,
              labelStyle: AppText.body.copyWith(
                fontSize: 13,
                color: selected == value
                    ? AppColors.header
                    : AppColors.textPrimary,
              ),
              showCheckmark: false,
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

/// The card frame every admin list uses (dark box, thin border, ripple).
class AdminCard extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final Color borderColor;

  const AdminCard({
    super.key,
    required this.child,
    this.onTap,
    this.borderColor = AppColors.fieldBorder,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.header,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: borderColor),
        borderRadius: BorderRadius.circular(4),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    );
  }
}
