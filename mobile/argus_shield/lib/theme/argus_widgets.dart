// argus_widgets.dart — small building blocks shared by every screen, so the
// header, field labels and main buttons look the same everywhere.

import 'package:flutter/material.dart';
import 'app_theme.dart';

/// The Argus Shield header: "Argus Shield" with "CIT Intelligence System"
/// underneath. Optionally shows the signed-in role on the right and a TabBar
/// (or any other widget) along the bottom.
class ArgusAppBar extends StatelessWidget implements PreferredSizeWidget {
  /// e.g. 'Citizen'. Leave null on pages shown before logging in.
  final String? roleLabel;
  final PreferredSizeWidget? bottom;

  const ArgusAppBar({super.key, this.roleLabel, this.bottom});

  @override
  Size get preferredSize =>
      Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) {
    final role = roleLabel;
    return AppBar(
      backgroundColor: AppColors.header,
      foregroundColor: AppColors.textPrimary,
      surfaceTintColor: Colors.transparent,
      centerTitle: true,
      title: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Argus Shield', style: AppText.appTitle),
          Text('CIT Intelligence System', style: AppText.appSubtitle),
        ],
      ),
      actions: [
        if (role != null)
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(role.toUpperCase(), style: AppText.caption),
            ),
          ),
      ],
      bottom: bottom,
    );
  }
}

/// Left-aligned label shown above a text field.
class FieldLabel extends StatelessWidget {
  final String text;

  const FieldLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(text, style: AppText.fieldLabel),
      ),
    );
  }
}

/// The big square orange action button ("Access System", "Submit Report").
/// Pass `onPressed: null` to show it disabled.
class PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;

  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: AppSpacing.buttonMaxWidth, // shrinks to fit narrower screens
      height: AppSpacing.buttonHeight,
      child: ElevatedButton(
        onPressed: onPressed,
        // scaleDown keeps long labels on one line on small phones
        child: FittedBox(fit: BoxFit.scaleDown, child: Text(label)),
      ),
    );
  }
}
