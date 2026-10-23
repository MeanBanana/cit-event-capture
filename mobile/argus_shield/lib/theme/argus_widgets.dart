// Small widgets every screen shares, so the header, field labels and main
// buttons look the same everywhere.

import 'package:flutter/material.dart';
import 'app_theme.dart';

/// The "Argus Shield / CIT Intelligence System" header. Can show the
/// signed-in role on the right and a TabBar (or anything else) along the
/// bottom.
class ArgusAppBar extends StatelessWidget implements PreferredSizeWidget {
  /// e.g. 'Citizen'. Leave it null on screens before login.
  final String? roleLabel;
  final PreferredSizeWidget? bottom;

  /// Extra buttons on the right, before the role name (e.g. Settings).
  final List<Widget>? actions;

  const ArgusAppBar({
    super.key,
    this.roleLabel,
    this.bottom,
    this.actions,
  });

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
        ...?actions,
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

/// The little marker next to the role name in [RoleAppBar].
enum RoleMarker {
  /// citizen screens
  circle,

  /// admin screens
  diamond,
}

/// Header for screens after login, two lines:
///   ● CITIZEN                  ◆ SYSTEM ADMINISTRATOR
///   Argus Shield               Argus Shield
///
/// Taller than the default 56px toolbar, otherwise the 30px title and the
/// role line don't both fit.
class RoleAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String roleLabel;
  final RoleMarker marker;
  final PreferredSizeWidget? bottom;
  final List<Widget>? actions;

  const RoleAppBar({
    super.key,
    required this.roleLabel,
    this.marker = RoleMarker.circle,
    this.bottom,
    this.actions,
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
      actions: actions,
      bottom: bottom,
    );
  }
}

/// Orange circle for citizens, diamond for admins.
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
        // a square rotated 45°, sized so its corners line up with the circle's width
        return SizedBox(
          width: 10,
          height: 10,
          child: Center(
            child: Transform.rotate(
              angle: 0.785398, // pi / 4
              child: Container(width: 7.5, height: 7.5, color: AppColors.accent),
            ),
          ),
        );
    }
  }
}

/// Left-aligned label above a text field.
class FieldLabel extends StatelessWidget {
  final String text;

  const FieldLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          text,
          style: AppText.fieldLabel.copyWith(color: pageInk(context)),
        ),
      ),
    );
  }
}

/// The big square orange button ("Access System", "Submit Report").
/// `onPressed: null` shows it disabled.
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
      width: AppSpacing.buttonMaxWidth, // shrinks on narrower screens
      height: AppSpacing.buttonHeight,
      child: ElevatedButton(
        onPressed: onPressed,
        // scaleDown so long labels stay on one line on small phones
        child: FittedBox(fit: BoxFit.scaleDown, child: Text(label)),
      ),
    );
  }
}

/// Sidekick to [PrimaryButton] for the other options on a screen ("Use the
/// AI's value", "Not a real weapon"). Same square full-width shape but
/// outlined and a bit shorter, so the main action still stands out.
/// [color] defaults to the accent, use AppColors.danger for destructive stuff.
class SecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Color color;

  const SecondaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.color = AppColors.accent,
  });

  static const double height = 56;

  @override
  Widget build(BuildContext context) {
    final text = FittedBox(fit: BoxFit.scaleDown, child: Text(label));
    return SizedBox(
      width: AppSpacing.buttonMaxWidth, // shrinks on narrower screens
      height: height,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          disabledForegroundColor: color.withValues(alpha: 0.4),
          side: BorderSide(
              color: onPressed == null ? color.withValues(alpha: 0.4) : color,
              width: 2),
          shape: const RoundedRectangleBorder(),
          textStyle: AppText.buttonSmall.copyWith(fontSize: 18),
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        child: icon == null
            ? text
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 22),
                  const SizedBox(width: 8),
                  Flexible(child: text),
                ],
              ),
      ),
    );
  }
}

/// A box with a dashed border that keeps crawling around the edge, a bit like
/// warning tape. For drawing the eye to something urgent, e.g. the Active
/// cases tile on the admin Overview.
///
///   AnimatedStripeBorder(
///     color: AppColors.danger,
///     child: Text('2 active'),
///   )
///
/// A CustomPainter draws the rounded outline as separate dashes, and an
/// AnimationController nudges where the first dash starts a little further
/// each frame. After one dash + gap the pattern looks the same again, so the
/// loop is seamless.
class AnimatedStripeBorder extends StatefulWidget {
  final Widget child;

  /// Dash colour.
  final Color color;

  /// Border thickness.
  final double strokeWidth;

  /// Length of each dash, and of the gap after it.
  final double dashLength;
  final double gapLength;

  final double borderRadius;

  /// How long it takes the dashes to move one dash + gap. Lower is faster.
  final Duration cycle;

  /// Padding between the border and [child].
  final EdgeInsetsGeometry padding;

  /// Background behind [child], transparent unless set.
  final Color? backgroundColor;

  const AnimatedStripeBorder({
    super.key,
    required this.child,
    this.color = AppColors.danger,
    this.strokeWidth = 2,
    this.dashLength = 10,
    this.gapLength = 6,
    this.borderRadius = 4,
    this.cycle = const Duration(milliseconds: 600),
    this.padding = const EdgeInsets.all(12),
    this.backgroundColor,
  });

  @override
  State<AnimatedStripeBorder> createState() => _AnimatedStripeBorderState();
}

// SingleTickerProviderStateMixin's ticker pauses by itself when the widget is
// off screen, e.g. on another tab.
class _AnimatedStripeBorderState extends State<AnimatedStripeBorder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: widget.cycle)..repeat();

  @override
  void didUpdateWidget(covariant AnimatedStripeBorder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cycle != widget.cycle) {
      _controller
        ..duration = widget.cycle
        ..repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose(); // otherwise Flutter complains about a leaked ticker
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary so only the border repaints 60 times a second, not the child
    return RepaintBoundary(
      child: CustomPaint(
        foregroundPainter: _StripeBorderPainter(
          progress: _controller,
          color: widget.color,
          strokeWidth: widget.strokeWidth,
          dashLength: widget.dashLength,
          gapLength: widget.gapLength,
          borderRadius: widget.borderRadius,
        ),
        child: Container(
          padding: widget.padding,
          decoration: BoxDecoration(
            color: widget.backgroundColor,
            borderRadius: BorderRadius.circular(widget.borderRadius),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class _StripeBorderPainter extends CustomPainter {
  final Animation<double> progress; // loops 0 -> 1
  final Color color;
  final double strokeWidth;
  final double dashLength;
  final double gapLength;
  final double borderRadius;

  // Passing the animation as `repaint` redraws on every tick without
  // rebuilding any widgets.
  _StripeBorderPainter({
    required this.progress,
    required this.color,
    required this.strokeWidth,
    required this.dashLength,
    required this.gapLength,
    required this.borderRadius,
  }) : super(repaint: progress);

  @override
  void paint(Canvas canvas, Size size) {
    // inset by half the stroke so the line sits fully inside the box
    final rect = (Offset.zero & size).deflate(strokeWidth / 2);
    final outline = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(borderRadius)));

    // faint solid line underneath so the edge is still visible in the gaps
    canvas.drawPath(
      outline,
      Paint()
        ..color = color.withValues(alpha: 0.25)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth,
    );

    final dashPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.butt;

    for (final metric in outline.computeMetrics()) {
      final length = metric.length;
      if (length <= 0) continue;

      // Stretch dash + gap a touch so a whole number fits around the box,
      // otherwise you'd see a jump where the outline's start and end meet.
      final requested = dashLength + gapLength;
      final count = (length / requested).round().clamp(1, 100000);
      final pattern = length / count;
      final dash = pattern * (dashLength / requested);

      final shift = progress.value * pattern;

      // Start one pattern before the outline begins, so there's always a dash
      // sliding in at the start while its other half slides out at the end.
      for (double d = shift - pattern; d < length; d += pattern) {
        final start = d.clamp(0.0, length);
        final end = (d + dash).clamp(0.0, length);
        if (end > start) {
          canvas.drawPath(metric.extractPath(start, end), dashPaint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _StripeBorderPainter old) =>
      old.color != color ||
      old.strokeWidth != strokeWidth ||
      old.dashLength != dashLength ||
      old.gapLength != gapLength ||
      old.borderRadius != borderRadius;
}

/// MaterialApp `builder` that keeps every screen above the phone's nav
/// buttons / gesture bar (and clear of side notches in landscape). Newer
/// Android draws apps edge to edge, so without this, anything at the bottom
/// of a page ends up under the system buttons.
///
/// The strip behind the system bar gets the page background so it looks like
/// part of the app. The top's left alone since the app bar already handles
/// the status bar.
///
///   MaterialApp(builder: keepAboveSystemBars, ...)
Widget keepAboveSystemBars(BuildContext context, Widget? child) {
  return ColoredBox(
    color: pageColor(context),
    child: SafeArea(
      top: false,
      child: child ?? const SizedBox.shrink(),
    ),
  );
}
