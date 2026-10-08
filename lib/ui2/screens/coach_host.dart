import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../../data/day_label.dart';
import '../../l10n/app_localizations.dart';
import '../ui2.dart';
import 'coach.dart';
import 'coach_personalization.dart' show CoachSurfaceHeader;

/// One shell-level chat, mounted lazily and retained when dismissed. Resizing
/// the surface never replaces its engine, transcript, draft or scroll state.
class CoachHost extends StatefulWidget {
  final ShellDomain domain;
  final Widget Function(BuildContext context, Widget entry) builder;

  const CoachHost({super.key, required this.domain, required this.builder});

  @override
  State<CoachHost> createState() => _CoachHostState();
}

class _CoachHostState extends State<CoachHost>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final _hostKey = GlobalKey();
  final _pillKey = GlobalKey();
  final _chatFocus = FocusScopeNode(debugLabel: 'Coach panel');
  late final AnimationController _surface;
  late final AnimationController _extent;
  late final AnimationController _label;
  late final Listenable _animation;
  Timer? _idle;
  bool _visible = false, _compact = true, _open = false, _full = false;
  bool _closing = false;
  bool _built = false;
  Rect? _origin;
  double _labelExtent = 0, _originLabelExtent = 0;
  double _labelSpace = 0;
  double _entryDrag = 0;
  String _entryLabel = '';
  String? _homeDay;
  String? _viewingDay, _viewingSection;
  VoidCallback? _pageBack;

  @override
  void initState() {
    super.initState();
    _surface = AnimationController(vsync: this);
    _extent = AnimationController(vsync: this);
    _label = AnimationController(vsync: this);
    _animation = Listenable.merge([_surface, _extent]);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(CoachHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.domain != widget.domain) {
      _idle?.cancel();
      _visible = false;
      _entryDrag = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!isExpressive(context) && (_open || _closing)) {
      _open = false;
      _closing = false;
      _surface.value = 0;
      _extent.value = 0;
      _full = false;
      _chatFocus.unfocus();
    }
    if (!Motion.enabled(context)) {
      if (_closing) {
        _closing = false;
        _full = false;
        _rest();
      }
      _surface.value = _open ? 1 : 0;
      _extent.value = _full ? 1 : 0;
      _label.value = _compact ? 0 : 1;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _idle?.cancel();
      if (_visible && !_compact && mounted) {
        setState(() => _compact = true);
        if (!_open && !_closing) _move(_label, 0);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _idle?.cancel();
    _surface.dispose();
    _extent.dispose();
    _label.dispose();
    _chatFocus.dispose();
    super.dispose();
  }

  void _rest() {
    _idle?.cancel();
    if (!_visible || _compact || _open || _closing) return;
    _idle = Timer(Motion.coachSettle, () {
      if (mounted && !_open && _visible) {
        setState(() => _compact = true);
        _move(_label, 0);
      }
    });
  }

  bool _scroll(ScrollNotification event) {
    // Main page lists are depth 0, or 1 under SubPages. Chart scrollers and
    // horizontal page swipes do not control the entry. Use pointer movement,
    // including overscroll at either boundary, rather than changes in the
    // scroll position's direction. Ballistic/programmatic scrolling stays quiet.
    if (_open ||
        _closing ||
        event.depth > 1 ||
        event.metrics.axis != Axis.vertical ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return false;
    }
    if (event is ScrollStartNotification) {
      _entryDrag = 0;
    } else if (event is ScrollEndNotification) {
      _entryDrag = 0;
      _rest();
    } else if (event is ScrollUpdateNotification ||
        event is OverscrollNotification) {
      final drag = event is ScrollUpdateNotification
          ? event.dragDetails
          : (event as OverscrollNotification).dragDetails;
      final dy = drag?.delta.dy;
      if (dy == null || dy == 0) return false;
      // Scrolling back toward the page's top shows Coach; moving farther down
      // hides it. Ignore tiny finger reversals and keep boundary pulls working.
      _entryDrag = _entryDrag.sign == dy.sign ? _entryDrag + dy : dy;
      if (_entryDrag.abs() < S.x2) return false;
      final reveal = dy > 0;
      if (_visible != reveal || (reveal && _compact)) {
        setState(() {
          _visible = reveal;
          _compact = !reveal;
        });
        _move(_label, reveal ? 1 : 0);
      }
      // Also arm here: reaching a clamped boundary can omit an idle-direction
      // notification, and a fling need not finish when the finger lifts.
      _rest();
    }
    return false;
  }

  void _openChat() {
    if (_open || _closing) return;
    final source = _pillKey.currentContext?.findRenderObject();
    final host = _hostKey.currentContext?.findRenderObject();
    if (source is RenderBox && host is RenderBox && source.hasSize) {
      _origin =
          host.globalToLocal(source.localToGlobal(Offset.zero)) & source.size;
    }
    _originLabelExtent = _labelExtent;
    // Pause an in-flight label morph at the sampled origin. Closing returns to
    // that same shape before the entry resumes its remaining size transition.
    _label.stop();
    _idle?.cancel();
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _viewingDay = widget.domain == ShellDomain.home
          ? _homeDay ?? todayLabel()
          : todayLabel();
      _viewingSection = widget.domain.label;
      _built = _open = _visible = true;
      _full = false;
    });
    _extent.value = 0;
    _move(_surface, 1);
  }

  void _move(AnimationController controller, double target) {
    // animateTo applies the same spring toward either endpoint. Playing a
    // forward spring backwards gives dismissal a slow start and a hard finish.
    controller.animateTo(
      target,
      duration: motion(
        context,
        controller == _label ? Motion.spatialFast : Motion.spatial,
      ),
      curve: Motion.spatialCurve(context),
    );
  }

  void _expand() {
    if (!_open || _full) return;
    setState(() => _full = true);
    _move(_extent, 1);
  }

  void _collapse() {
    if (!_open) return;
    if (!_full) {
      _close();
      return;
    }
    setState(() => _full = false);
    _move(_extent, 0);
  }

  void _collapseFromChat() {
    _chatFocus.unfocus();
    _collapse();
  }

  void _back() {
    if (!_open) return;
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      _chatFocus.unfocus();
    } else if (_pageBack != null) {
      _pageBack!();
    } else {
      _collapse();
    }
  }

  void _close() {
    if (!_open) return;
    _chatFocus.unfocus();
    setState(() {
      _open = false;
      _closing = true;
    });
    _surface
        .animateTo(
          0,
          duration: motion(context, Motion.spatial),
          curve: Motion.spatialCurve(context),
        )
        .then((_) {
          if (!mounted || _open) return;
          setState(() {
            _full = false;
            _closing = false;
          });
          _extent.value = 0;
          _move(_label, _compact ? 0 : 1);
          _rest();
        });
  }

  Widget _entry(BuildContext c) {
    final p = P.of(c), l = AppLocalizations.of(c);
    final visible = _visible;
    final label = l?.coachFloatingLabel ?? 'Ask Coach';
    final painter = TextPainter(
      text: TextSpan(text: label, style: F.body),
      textDirection: Directionality.of(c),
      textScaler: MediaQuery.textScalerOf(c),
      maxLines: 1,
    )..layout();
    final space = S.x2 + painter.width;
    final height = math.max(S.tap + S.x2, painter.height + S.x4);
    painter.dispose();
    _labelSpace = space;
    _entryLabel = label;
    final fits = space + S.tap + S.x2 <= MediaQuery.sizeOf(c).width - S.x8;
    final compact = !fits;
    return SizedBox(
      // The anchor stays above the dock while its visual slides away. Opening
      // from another action must not morph from the hidden, translated pill.
      key: _pillKey,
      child: Visibility(
        visible: !_open && !_closing,
        maintainState: true,
        maintainAnimation: true,
        maintainSize: true,
        child: IgnorePointer(
          ignoring: !visible,
          child: ExcludeSemantics(
            excluding: !visible,
            child: AnimatedSlide(
              offset: visible ? Offset.zero : Offset(0, S.x6 / height),
              duration: motion(c, Motion.spatialFast),
              curve: Motion.spatialCurve(c),
              child: AnimatedOpacity(
                opacity: visible ? 1 : 0,
                duration: motion(c, Motion.fast),
                curve: Motion.effectsCurve(c),
                child: AnimatedBuilder(
                  animation: _label,
                  builder: (c, _) {
                    final t = compact ? 0.0 : _label.value;
                    _labelExtent = t;
                    return Pressable(
                      key: const ValueKey('coach-entry'),
                      semanticLabel: label,
                      onTap: _openChat,
                      child: Container(
                        width: S.tap + S.x2 + space * t,
                        height: height,
                        decoration: BoxDecoration(
                          color: p.fill(kCoachAccent),
                          borderRadius: R.rPill,
                          boxShadow: p.el(2),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: S.x2),
                        child: _entryContents(c, label, space, t),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _entryContents(BuildContext c, String label, double space, double t) {
    final p = P.of(c);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        brandGlyph(kEdgeMarkAsset, size: S.x8)(p.inkOnFill),
        SizedBox(
          width: space * t,
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: space,
              maxWidth: space,
              child: Opacity(
                opacity: t,
                child: Padding(
                  padding: const EdgeInsets.only(left: S.x2),
                  child: Text(
                    label,
                    style: F.body.copyWith(color: p.inkOnFill),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _header(
    BuildContext c,
    VoidCallback menu,
    VoidCallback newChat,
    String subtitle,
    bool showNewChat,
  ) {
    final p = P.of(c);
    return PanelHandle(
      key: const ValueKey('coach-panel-handle'),
      onExpand: _expand,
      onCollapse: _collapse,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: S.x2, bottom: S.x1),
            child: Container(
              width: S.x8,
              height: S.x1,
              decoration: BoxDecoration(color: p.line, borderRadius: R.rPill),
            ),
          ),
          CoachSurfaceHeader(
            subtitle: subtitle,
            onMenu: menu,
            onNew: showNewChat ? newChat : null,
            onExpand: _full ? _collapse : _expand,
            expanded: _full,
            onClose: _close,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext c) {
    final expressive = isExpressive(c);
    final child = CoachEntryScope(
      open: _openChat,
      onHomeDay: (day) => _homeDay = day,
      child: Semantics(
        key: const ValueKey('coach-entry-actions'),
        container: expressive,
        // A stable screen-reader action keeps Coach reachable while its visual
        // entry follows the same scroll/idle behavior with any Android service.
        customSemanticsActions: expressive
            ? {
                CustomSemanticsAction(
                  label:
                      AppLocalizations.of(c)?.coachFloatingLabel ?? 'Ask Coach',
                ): _openChat,
              }
            : null,
        child: NotificationListener<ScrollNotification>(
          onNotification: expressive ? _scroll : null,
          child: widget.builder(c, _entry(c)),
        ),
      ),
    );
    return PopScope(
      canPop: !_open && !_closing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: LayoutBuilder(
        builder: (c, box) {
          final p = P.of(c), media = MediaQuery.of(c);
          final bottom = math.max(0.0, box.maxHeight - media.viewInsets.bottom);
          final origin =
              _origin ??
              Rect.fromLTWH(
                box.maxWidth - S.x16 - S.x4,
                bottom - S.x16 * 2,
                S.tap + S.x2,
                S.tap + S.x2,
              );
          final panelBottom = math.min(bottom - S.x2, origin.bottom);
          final available = math.max(
            0.0,
            panelBottom - media.padding.top - S.x2,
          );
          final height = media.viewInsets.bottom > 0
              ? available
              : math.min(
                  available,
                  math.max(S.x16 * 4, available * (bigText(c) ? .8 : .62)),
                );
          final compact = Rect.fromLTWH(
            S.x2,
            panelBottom - height,
            math.max(0.0, box.maxWidth - S.x4),
            height,
          );
          final full = Rect.fromLTWH(0, 0, box.maxWidth, bottom);
          // Keep the chat child outside the animation builder. Each frame only
          // lays out its existing render tree; markdown, engine and draft are
          // not rebuilt by the surface spring.
          final chat = _built
              ? RepaintBoundary(
                  child: MediaQuery.removeViewInsets(
                    context: c,
                    removeBottom: true,
                    child: MediaQuery.removePadding(
                      context: c,
                      removeLeft: true,
                      removeTop: true,
                      removeRight: true,
                      removeBottom: true,
                      child: CoachScreen(
                        headerBuilder: _header,
                        onPullDownAtTop: _collapseFromChat,
                        presented: _open,
                        onBackChanged: (back) => _pageBack = back,
                        viewingDay: _viewingDay,
                        viewingSection: _viewingSection,
                      ),
                    ),
                  ),
                )
              : null;
          return AnimatedBuilder(
            animation: _animation,
            child: chat,
            builder: (c, chat) {
              final extent = _extent.value;
              final target = Rect.lerp(compact, full, extent)!;
              final reveal = _surface.value;
              final rect = Rect.lerp(origin, target, reveal)!;
              final radius = BorderRadius.lerp(
                R.rPill,
                BorderRadius.lerp(R.rXxl, BorderRadius.zero, extent),
                reveal,
              )!;
              final shown = _open || _closing;
              final insets = EdgeInsets.fromLTRB(
                media.padding.left * extent,
                media.padding.top * extent,
                media.padding.right * extent,
                media.padding.bottom * extent,
              );
              return Stack(
                key: _hostKey,
                fit: StackFit.expand,
                children: [
                  ExcludeFocus(
                    excluding: shown,
                    child: ExcludeSemantics(
                      excluding: shown,
                      child: IgnorePointer(ignoring: shown, child: child),
                    ),
                  ),
                  if (shown)
                    Opacity(
                      opacity: _surface.value,
                      child: ModalBarrier(
                        color: p.bg.withValues(alpha: .4),
                        dismissible: _open,
                        onDismiss: _close,
                        semanticsLabel:
                            AppLocalizations.of(c)?.coachCloseView ??
                            'Close chat',
                      ),
                    ),
                  if (_built)
                    Positioned.fromRect(
                      rect: rect,
                      child: Offstage(
                        offstage: !shown,
                        child: IgnorePointer(
                          ignoring: !_open || _surface.isAnimating,
                          child: ExcludeSemantics(
                            excluding: !_open,
                            child: FocusScope(
                              node: _chatFocus,
                              canRequestFocus: _open,
                              descendantsAreFocusable: _open,
                              descendantsAreTraversable: _open,
                              child: TickerMode(
                                enabled: _open,
                                child: ClipRRect(
                                  key: const ValueKey('coach-panel-surface'),
                                  borderRadius: radius,
                                  child: Material(
                                    color: Color.lerp(
                                      p.fill(kCoachAccent),
                                      p.card,
                                      Motion.effectsCurve(c).transform(reveal),
                                    ),
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        OverflowBox(
                                          alignment: Alignment.topLeft,
                                          minWidth: target.width,
                                          maxWidth: target.width,
                                          minHeight: target.height,
                                          maxHeight: target.height,
                                          child: Opacity(
                                            opacity: Interval(
                                              .18,
                                              .75,
                                              curve: Motion.effectsCurve(c),
                                            ).transform(reveal),
                                            child: Padding(
                                              key: const ValueKey(
                                                'coach-panel-insets',
                                              ),
                                              padding: insets,
                                              child: chat!,
                                            ),
                                          ),
                                        ),
                                        Positioned(
                                          right: 0,
                                          bottom: 0,
                                          width: origin.width,
                                          height: origin.height,
                                          child: ExcludeSemantics(
                                            child: IgnorePointer(
                                              child: Opacity(
                                                opacity:
                                                    1 -
                                                    Motion.effectsCurve(
                                                      c,
                                                    ).transform(reveal),
                                                child: Padding(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: S.x2,
                                                      ),
                                                  child: _entryContents(
                                                    c,
                                                    _entryLabel,
                                                    _labelSpace,
                                                    _originLabelExtent,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
