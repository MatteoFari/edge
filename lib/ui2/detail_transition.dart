import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme/theme_switcher.dart' show ThemeReactive, themedRoute;
import 'theme.dart';

typedef DetailOpener = Future<T?> Function<T>(Widget destination);

/// A detail page grows from its own card. The builder wires the existing
/// Pressable, so the card keeps its semantics and minimum touch target.
/// [source] lets a button inside a larger RepaintBoundary expand that surface.
class DetailLink extends StatefulWidget {
  final Widget Function(DetailOpener open) builder;
  final GlobalKey? source;
  final Color? color;
  final BorderRadius? radius;

  const DetailLink({
    super.key,
    required this.builder,
    this.source,
    this.color,
    this.radius,
  });

  @override
  State<DetailLink> createState() => _DetailLinkState();
}

class _DetailLinkState extends State<DetailLink> {
  final _boundary = GlobalKey();
  bool _opening = false;

  Future<T?> _open<T>(Widget destination) async {
    if (!mounted || _opening) return null;
    _opening = true;
    ui.Image? image;
    try {
      final navigator = Navigator.of(context);
      final morph =
          isExpressive(context) &&
          Theme.of(context).platform == TargetPlatform.android;
      final enabled = Motion.enabled(context);
      if (morph && enabled) {
        // The press feedback may have dirtied the boundary. Capture its next
        // painted frame, with no analytics work or page layout in the snapshot.
        await WidgetsBinding.instance.endOfFrame;
      }
      if (!mounted ||
          !navigator.mounted ||
          !(ModalRoute.of(context)?.isCurrent ?? true)) {
        return null;
      }
      final overlay = navigator.overlay?.context.findRenderObject();
      final source = (widget.source ?? _boundary).currentContext
          ?.findRenderObject();
      Rect? origin;
      if (morph &&
          enabled &&
          overlay is RenderBox &&
          source is RenderRepaintBoundary &&
          source.hasSize &&
          source.attached) {
        origin =
            source.localToGlobal(Offset.zero, ancestor: overlay) & source.size;
        if (!origin.isEmpty && origin.overlaps(Offset.zero & overlay.size)) {
          try {
            image = source.toImageSync(
              pixelRatio: math.min(MediaQuery.devicePixelRatioOf(context), 2),
            );
          } catch (_) {
            // A lost/dirty source never makes its detail page inaccessible.
            origin = null;
          }
        } else {
          origin = null;
        }
      }
      final name = destination.runtimeType.toString();
      final PageRoute<T> route;
      if (morph && (!enabled || (origin != null && image != null))) {
        route = _DetailMorphRoute<T>(
          builder: (_) => destination,
          name: name,
          origin: origin,
          snapshot: image,
          color: widget.color ?? P.of(context).card,
          radius: widget.radius ?? R.cardOf(context),
          enabled: enabled,
        );
        image = null; // The route owns it through its reverse transition.
      } else {
        route = themedRoute<T>((_) => destination, name: name);
      }
      final result = await navigator.push<T>(route);
      await route.completed;
      return result;
    } finally {
      image?.dispose();
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) =>
      RepaintBoundary(key: _boundary, child: widget.builder(_open));
}

/// MaterialPageRoute retains normal route lifecycle, focus and Back handling.
/// Other platforms use themedRoute, including its native swipe-back behavior.
class _DetailMorphRoute<T> extends MaterialPageRoute<T> {
  final Rect? origin;
  final ui.Image? snapshot;
  final Color color;
  final BorderRadius radius;
  final bool enabled;

  _DetailMorphRoute({
    required WidgetBuilder builder,
    required String name,
    required this.origin,
    required this.snapshot,
    required this.color,
    required this.radius,
    required this.enabled,
  }) : super(
         builder: (_) => ThemeReactive(builder: builder),
         settings: RouteSettings(name: name),
         allowSnapshotting: false,
       );

  @override
  Duration get transitionDuration => enabled ? Motion.spatial : Duration.zero;
  @override
  Duration get reverseTransitionDuration => transitionDuration;

  // The underlying card stays still while its surface covers the page.
  @override
  bool canTransitionFrom(TransitionRoute<dynamic> previousRoute) => false;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (!enabled ||
        !Motion.enabled(context) ||
        origin == null ||
        animation.status == AnimationStatus.completed) {
      return child;
    }
    final p = P.of(context);
    final t = Motion.spatialCurve(
      context,
    ).transform(animation.value).clamp(0.0, 1.0);
    final content = Interval(
      .18,
      .8,
      curve: Motion.effectsCurve(context),
    ).transform(animation.value);
    final source =
        1 -
        Interval(
          0,
          .3,
          curve: Motion.effectsCurve(context),
        ).transform(animation.value);
    return AbsorbPointer(
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, box) {
            final rect = Rect.lerp(origin, Offset.zero & box.biggest, t)!;
            final corners = BorderRadius.lerp(radius, BorderRadius.zero, t)!;
            return ClipPath(
              key: const ValueKey('detail-morph-surface'),
              clipper: _DetailClipper(corners.toRRect(rect)),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: Color.lerp(color, p.bg, t)!),
                  Opacity(opacity: content, child: child),
                  if (snapshot != null && source > 0)
                    Positioned(
                      left: rect.left,
                      top: rect.top,
                      width: origin!.width,
                      height: origin!.height,
                      child: Opacity(
                        opacity: source,
                        child: RawImage(image: snapshot, fit: BoxFit.fill),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    snapshot?.dispose();
    super.dispose();
  }
}

class _DetailClipper extends CustomClipper<Path> {
  final RRect rect;
  const _DetailClipper(this.rect);
  @override
  Path getClip(Size size) => Path()..addRRect(rect);
  @override
  bool shouldReclip(_DetailClipper old) => rect != old.rect;
}
