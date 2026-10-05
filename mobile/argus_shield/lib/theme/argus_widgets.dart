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

/// A box whose border is a line of dashes that keeps running around the
/// edge, like a warning tape. Used to draw attention to something urgent
/// (e.g. the Active cases tile on the admin Overview).
///
///   AnimatedStripeBorder(
///     color: AppColors.danger,
///     child: Text('2 active'),
///   )
///
/// How it works: a CustomPainter draws the rounded-rectangle outline as
/// separate dashes. An AnimationController moves the starting point of the
/// first dash a little further along the outline every frame, so the dashes
/// appear to travel round the box. When it has moved one full dash + gap the
/// pattern looks identical again, so the loop is seamless.
class AnimatedStripeBorder extends StatefulWidget {
  final Widget child;

  /// Colour of the moving dashes.
  final Color color;

  /// Border thickness.
  final double strokeWidth;

  /// Length of each dash and of the gap after it.
  final double dashLength;
  final double gapLength;

  final double borderRadius;

  /// Time for the dashes to move one full dash + gap.
  /// Shorter = faster.
  final Duration cycle;

  /// Space between the border and [child].
  final EdgeInsetsGeometry padding;

  /// Fill behind [child]; transparent by default.
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

// SingleTickerProviderStateMixin gives the controller a ticker that pauses
// automatically when this widget is off screen (e.g. on another tab).
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
    _controller.dispose(); // stop the ticker, or Flutter reports a leak
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary: only the border repaints 60x a second, not the child.
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
  final Animation<double> progress; // 0 → 1, repeating
  final Color color;
  final double strokeWidth;
  final double dashLength;
  final double gapLength;
  final double borderRadius;

  // Passing the animation as `repaint` makes the painter redraw on every
  // tick without rebuilding any widgets.
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
    // Inset by half the stroke so the line sits fully inside the box.
    final rect = (Offset.zero & size).deflate(strokeWidth / 2);
    final outline = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(borderRadius)));

    // Faint solid line underneath, so the box edge stays readable in the gaps.
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

      // Stretch dash + gap slightly so a whole number of them fits round the
      // box. Otherwise there'd be a visible jump where the outline's start
      // and end meet.
      final requested = dashLength + gapLength;
      final count = (length / requested).round().clamp(1, 100000);
      final pattern = length / count;
      final dash = pattern * (dashLength / requested);

      final shift = progress.value * pattern;

      // Start one pattern "before" the outline so a dash is always sliding
      // in at the start while the matching piece slides out at the end.
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
