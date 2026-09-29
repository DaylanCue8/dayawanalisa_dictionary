import 'package:flutter/physics.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_settings.dart';

/// iOS "liquid glass" style segmented selector.
///
/// - Tap a segment: the pill springs over with a little overshoot and
///   stretches along the direction of travel, then jiggles to rest.
/// - Long-press or drag: the pill lifts (grows, turns into frosted glass,
///   casts a shadow) and follows the finger with a soft, wobbly lag.
///   Releasing snaps it to the nearest segment and selects it.
///
/// It draws only the pill and the items; the caller provides the track
/// (e.g. a [GlassContainer]) around it.
class LiquidGlassSelector extends StatefulWidget {
  final int count;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  /// Builds segment [index]. [selectedness] runs 0..1 as the pill moves
  /// over it, so text/icon colors can blend smoothly while dragging.
  final Widget Function(BuildContext context, int index, double selectedness)
  itemBuilder;

  final double height;
  final Color pillColor;
  final BorderRadius pillRadius;

  const LiquidGlassSelector({
    super.key,
    required this.count,
    required this.selectedIndex,
    required this.onChanged,
    required this.itemBuilder,
    this.height = 36,
    this.pillColor = const Color(0xFFFFFF00),
    this.pillRadius = const BorderRadius.all(Radius.circular(9)),
  });

  @override
  State<LiquidGlassSelector> createState() => _LiquidGlassSelectorState();
}

class _LiquidGlassSelectorState extends State<LiquidGlassSelector>
    with TickerProviderStateMixin {
  // Underdamped, so a tap overshoots slightly and wobbles into place.
  static const _snapSpring = SpringDescription(
    mass: 1,
    stiffness: 420,
    damping: 17,
  );
  // Stiffer while dragging, so the pill trails the finger like jelly
  // without falling far behind.
  static const _followSpring = SpringDescription(
    mass: 1,
    stiffness: 900,
    damping: 32,
  );

  /// Pill position in segment units (0 = first segment).
  late final AnimationController _position = AnimationController.unbounded(
    vsync: this,
    value: widget.selectedIndex.toDouble(),
  );

  /// 0 = resting, 1 = lifted (long-press / drag).
  late final AnimationController _lift = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 320),
  );

  bool _dragging = false;
  double _dragTarget = 0;
  int _hoverIndex = 0;
  double _segmentWidth = 1;

  @override
  void didUpdateWidget(LiquidGlassSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging && oldWidget.selectedIndex != widget.selectedIndex) {
      _springTo(widget.selectedIndex.toDouble(), _snapSpring);
    }
  }

  @override
  void dispose() {
    _position.dispose();
    _lift.dispose();
    super.dispose();
  }

  void _springTo(double target, SpringDescription spring) {
    _position.animateWith(
      SpringSimulation(spring, _position.value, target, _position.velocity),
    );
  }

  double _indexAt(double dx) =>
      (dx / _segmentWidth - 0.5).clamp(0.0, widget.count - 1.0);

  void _onTap(TapUpDetails details) {
    final index = _indexAt(details.localPosition.dx).round();
    _springTo(index.toDouble(), _snapSpring);
    if (index != widget.selectedIndex) {
      _haptic(HapticFeedback.selectionClick);
      _commit(index);
    }
  }

  /// Vibration feedback, unless turned off in Settings.
  void _haptic(Future<void> Function() feedback) {
    if (AppSettings.instance.hapticsEnabled) feedback();
  }

  int _commitToken = 0;

  /// Tells the parent about the new selection once the pill has mostly
  /// arrived. Parents often do heavy work on change (building a whole tab,
  /// re-cutting images); doing it on the same frame the spring starts
  /// stalls the animation and the pill appears to jump instead of glide.
  /// The items already recolor with the pill, so it still feels instant.
  void _commit(int index) {
    final token = ++_commitToken;
    Future.delayed(const Duration(milliseconds: 240), () {
      if (mounted && token == _commitToken && index != widget.selectedIndex) {
        widget.onChanged(index);
      }
    });
  }

  void _startDrag(Offset local) {
    _dragging = true;
    _commitToken++; // a new drag overrides any selection still pending
    _hoverIndex = _position.value.round();
    _lift.forward();
    _haptic(HapticFeedback.lightImpact);
    _followTo(local);
  }

  void _followTo(Offset local) {
    final target = _indexAt(local.dx);
    _dragTarget = target;
    _springTo(target, _followSpring);
    final hover = target.round();
    if (hover != _hoverIndex) {
      _hoverIndex = hover;
      _haptic(HapticFeedback.selectionClick);
    }
  }

  void _endDrag() {
    if (!_dragging) return;
    _dragging = false;
    _lift.reverse();
    // Snap to where the finger is, not where the lagging pill has got to,
    // so a quick swipe still lands on the segment it was released over.
    final index = _dragTarget.round().clamp(0, widget.count - 1);
    _springTo(index.toDouble(), _snapSpring);
    _commit(index);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _segmentWidth = constraints.maxWidth / widget.count;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: _onTap,
          onHorizontalDragStart: (d) => _startDrag(d.localPosition),
          onHorizontalDragUpdate: (d) => _followTo(d.localPosition),
          onHorizontalDragEnd: (_) => _endDrag(),
          onHorizontalDragCancel: _endDrag,
          onLongPressStart: (d) => _startDrag(d.localPosition),
          onLongPressMoveUpdate: (d) => _followTo(d.localPosition),
          onLongPressEnd: (_) => _endDrag(),
          onLongPressCancel: _endDrag,
          // Own layer, so each animation frame repaints only the selector,
          // not the frosted bar / page around it.
          child: RepaintBoundary(
            child: SizedBox(
              height: widget.height,
              child: AnimatedBuilder(
                animation: Listenable.merge([_position, _lift]),
                builder: (context, _) => Stack(
                  clipBehavior: Clip.none,
                  children: [_buildPill(), _buildItems()],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPill() {
    final lift = Curves.easeOut.transform(_lift.value);
    // Velocity in segments/second drives the jelly stretch: wider and
    // flatter while moving fast, springing back (and past) as it settles.
    final speed = _position.velocity.abs();
    final stretch = (speed * 0.045).clamp(0.0, 0.35);
    final scaleX = (1 + stretch) * (1 + 0.10 * lift);
    final scaleY = (1 - stretch * 0.45) * (1 + 0.22 * lift);

    // Resting: solid accent. Lifted: see-through frosted glass tinted with
    // the accent, with a bright rim and a soft shadow underneath.
    final fill = Color.lerp(
      widget.pillColor,
      widget.pillColor.withValues(alpha: 0.35),
      lift,
    )!;

    return Positioned(
      left: _position.value * _segmentWidth,
      top: 0,
      width: _segmentWidth,
      height: widget.height,
      child: Transform.scale(
        scaleX: scaleX,
        scaleY: scaleY,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: widget.pillRadius,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.10 + 0.15 * lift),
                blurRadius: 6 + 14 * lift,
                offset: Offset(0, 2 + 6 * lift),
              ),
            ],
          ),
          // No BackdropFilter here: the track around the selector is already
          // frosted, and a second live blur redrawn every animation frame is
          // what made the pill stutter on Android. A white sheen + bright rim
          // over the see-through tint gives the same glassy look for free.
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: widget.pillRadius,
              // BoxDecoration can't take both; the gradient already ends in
              // the fill color while lifted.
              color: lift > 0 ? null : fill,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.25 + 0.55 * lift),
                width: 1 + lift,
              ),
              gradient: lift > 0
                  ? LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.white.withValues(alpha: 0.45 * lift),
                        fill,
                      ],
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildItems() {
    return Row(
      children: [
        for (var i = 0; i < widget.count; i++)
          Expanded(
            child: Center(
              child: widget.itemBuilder(
                context,
                i,
                (1 - (_position.value - i).abs()).clamp(0.0, 1.0),
              ),
            ),
          ),
      ],
    );
  }
}
