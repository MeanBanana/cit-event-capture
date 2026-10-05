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
