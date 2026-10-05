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

/// Shape of the small marker beside the role name in [RoleAppBar].
enum RoleMarker {
  /// Citizen screens.
  circle,

  /// System Administrator screens.
  diamond,
}

/// Header for screens after logging in. Two lines:
///   ● CITIZEN                  ◆ SYSTEM ADMINISTRATOR
///   Argus Shield               Argus Shield
///
/// The toolbar is made taller than the default 56px so the 30px
/// "Argus Shield" title and the role line both fit without cropping.
class RoleAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String roleLabel;
  final RoleMarker marker;
  final PreferredSizeWidget? bottom;

  const RoleAppBar({
    super.key,
    required this.roleLabel,
    this.marker = RoleMarker.circle,
    this.bottom,
  });

  static const double _toolbarHeight = 76;

  @override
  Size get preferredSize =>
      Size.fromHeight(_toolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) {
    return AppBar(
      backgroundColor: AppColors.header,
      foregroundColor: AppColors.textPrimary,
      surfaceTintColor: Colors.transparent,
      toolbarHeight: _toolbarHeight,
      centerTitle: false,
      titleSpacing: AppSpacing.medium,
      title: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _RoleMarkerIcon(marker: marker),
              const SizedBox(width: 8),
              Text(roleLabel.toUpperCase(), style: AppText.caption),
            ],
          ),
          const SizedBox(height: 2),
          const Text('Argus Shield', style: AppText.appTitle),
        ],
      ),
      bottom: bottom,
    );
  }
}

/// The small orange circle (citizen) or diamond (admin) before the role.
class _RoleMarkerIcon extends StatelessWidget {
  final RoleMarker marker;

  const _RoleMarkerIcon({required this.marker});

  @override
  Widget build(BuildContext context) {
    switch (marker) {
      case RoleMarker.circle:
        return Container(
          width: 10,
          height: 10,
          decoration: const BoxDecoration(
            color: AppColors.accent,
            shape: BoxShape.circle,
          ),
        );
      case RoleMarker.diamond:
        // A square turned 45° — sized so its corners match the circle's width.
        return SizedBox(
          width: 10,
          height: 10,
          child: Center(
            child: Transform.rotate(
              angle: 0.785398, // 45° in radians (pi / 4)
              child: Container(width: 7.5, height: 7.5, color: AppColors.accent),
            ),
          ),
        );
    }
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
