// The four-tab shell: Home · Health · Workout · Wellness.
// Each domain owns an accent, so colour tells you where you are before the
// label does. Nutrition remains an internal domain for existing routes and
// saved preferences; [visibleShellDomains] owns what appears in navigation.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../l10n/app_localizations.dart';
import 'grammar.dart';
import 'theme.dart';

/// Stored domain identities. Keep the order stable for saved tab indices.
enum ShellDomain {
  home('Home', LucideIcons.house, C.domHome),
  health('Health', LucideIcons.heartPulse, C.domHealth),
  nutrition('Nutrition', LucideIcons.utensils, C.domFood),
  workout('Workout', LucideIcons.dumbbell, C.domMove),
  wellness('Wellness', LucideIcons.leaf, C.domMind);

  const ShellDomain(this.label, this.icon, this.accent);

  final String label;
  final IconData icon;

  /// [label] in the user's language. Own keys rather than the screen titles:
  /// zh has Health and Wellness both as 健康, two identical tabs.
  String title(BuildContext c) {
    final l = AppLocalizations.of(c);
    return switch (this) {
          ShellDomain.home => l?.tabHome,
          ShellDomain.health => l?.tabHealth,
          ShellDomain.nutrition => l?.tabNutrition,
          ShellDomain.workout => l?.tabWorkout,
          ShellDomain.wellness => l?.tabWellness,
        } ??
        label;
  }

  /// The domain's pigment. Use `P.of(context).on(accent)` for text and
  /// `.fill(accent)` for a filled surface — the raw value is not AA-safe.
  final Color accent;
}

/// The visible destinations, shared by both interfaces and their content stack.
const visibleShellDomains = [
  ShellDomain.home,
  ShellDomain.health,
  ShellDomain.workout,
  ShellDomain.wellness,
];

/// Explicit scroll padding must clear the floating bar, including large text
/// and the system gesture inset. Original keeps its existing page padding.
EdgeInsets shellScrollPadding(BuildContext c, EdgeInsets padding) {
  if (!isExpressive(c)) return padding;
  final bottom = MediaQuery.paddingOf(c).bottom + S.x4;
  return padding.copyWith(
    bottom: bottom > padding.bottom ? bottom : padding.bottom,
  );
}

// There is no `Domain` InheritedWidget. There was one, promising that a screen
// "and anything it pushes" could pick up its accent without threading it — but
// nothing ever read it, and a pushed route could not have: `MaterialApp.home`
// is the gate, so `Navigator.of` pushes above the shell entirely. Screens take
// their accent as a parameter, which is honest about where it comes from.

class AppShell extends StatefulWidget {
  /// Builds the body of one domain. Called lazily — a tab is not built until
  /// it is first selected, then kept alive by the [IndexedStack].
  final Widget Function(BuildContext context, ShellDomain domain) builder;

  /// A hidden legacy destination starts at Home.
  final ShellDomain initial;

  /// Notified on every tab change, including a re-tap of the current tab
  /// (which domains conventionally use to scroll to top).
  final void Function(ShellDomain domain)? onSelect;

  /// Pinned between the domain and the tab bar, above every tab. This is not
  /// a general slot — it exists for state that is RUNNING and is not on
  /// screen, which today means a minimised workout. A domain's own content
  /// belongs inside the domain.
  final Widget? banner;

  /// Coach floats above the real navigation and any running workout.
  final Widget? coachEntry;

  const AppShell({
    super.key,
    required this.builder,
    this.initial = ShellDomain.home,
    this.onSelect,
    this.banner,
    this.coachEntry,
  });

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late ShellDomain _current = visibleShellDomains.contains(widget.initial)
      ? widget.initial
      : ShellDomain.home;
  late final Set<ShellDomain> _built = {_current};

  void _select(ShellDomain d) {
    setState(() {
      _current = d;
      _built.add(d);
    });
    widget.onSelect?.call(d);
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    return Scaffold(
      backgroundColor: p.bg,
      extendBody: isExpressive(c),
      floatingActionButton: isExpressive(c) ? widget.coachEntry : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          Expanded(
            child: IndexedStack(
              index: visibleShellDomains.indexOf(_current),
              children: [
                // An unvisited tab is an empty box, not a built screen — the
                // old shell built all forty screens' worth of state on launch.
                for (final d in visibleShellDomains)
                  if (_built.contains(d))
                    widget.builder(c, d)
                  else
                    const SizedBox.shrink(),
              ],
            ),
          ),
          if (widget.banner != null && !isExpressive(c))
            Builder(
              builder: (c) => Padding(
                padding: EdgeInsets.only(
                  bottom: isExpressive(c) ? MediaQuery.paddingOf(c).bottom : 0,
                ),
                child: widget.banner!,
              ),
            ),
        ]),
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isExpressive(c) && widget.banner != null) ...[
            _DockItem(child: widget.banner!),
            const SizedBox(height: S.x1),
          ],
          _TabBar(current: _current, onTap: _select),
        ],
      ),
    );
  }
}

/// Both floating controls use the same width, including accessibility layouts.
class _DockItem extends StatelessWidget {
  final Widget child;
  const _DockItem({required this.child});

  @override
  Widget build(BuildContext c) => Padding(
    padding: EdgeInsets.symmetric(
      horizontal: bigText(c) || MediaQuery.sizeOf(c).width < 360 ? S.x4 : S.x12,
    ),
    child: Align(
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: S.x16 * 5),
        child: child,
      ),
    ),
  );
}

class _TabBar extends StatelessWidget {
  final ShellDomain current;
  final ValueChanged<ShellDomain> onTap;

  const _TabBar({required this.current, required this.onTap});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    if (isExpressive(c)) {
      return _ExpressiveTabBar(current: current, onTap: onTap);
    }
    return Container(
      decoration: BoxDecoration(
        color: p.card,
        border: Border(top: BorderSide(color: p.line)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 60,
          child: Row(
            children: [
              for (final d in visibleShellDomains)
                Expanded(
                  child: _Tab(
                    domain: d,
                    on: d == current,
                    onTap: () => onTap(d),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A single inner capsule moves between destinations. The selected caption
/// fits its icon and measured caption; idle icons share the remaining space.
class _ExpressiveTabBar extends StatelessWidget {
  final ShellDomain current;
  final ValueChanged<ShellDomain> onTap;

  const _ExpressiveTabBar({required this.current, required this.onTap});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final captionHeight =
        MediaQuery.textScalerOf(c).scale(F.over.fontSize!) * F.over.height!;
    final height = (captionHeight + S.x4).clamp(S.x12, double.infinity);
    final captionStyle = DefaultTextStyle.of(
      c,
    ).style.merge(F.over.copyWith(fontWeight: FontWeight.w500));
    final captionWidths = <double>[];
    for (final d in visibleShellDomains) {
      final text = TextPainter(
        text: TextSpan(text: d.title(c), style: captionStyle),
        textDirection: Directionality.of(c),
        textScaler: MediaQuery.textScalerOf(c),
        locale: Localizations.maybeLocaleOf(c),
        maxLines: 1,
      )..layout();
      captionWidths.add(text.width.ceilToDouble());
      text.dispose();
    }
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: S.x2),
        child: _DockItem(
            child: Container(
              key: const ValueKey('expressive-navigation'),
              padding: const EdgeInsets.all(S.x1),
              decoration: BoxDecoration(
                color: p.card,
                borderRadius: R.rPill,
                boxShadow: p.el(2),
              ),
              child: SizedBox(
                height: height,
                child: LayoutBuilder(
                  builder: (c, box) {
                    final count = visibleShellDomains.length;
                    final layouts = <List<double>>[];
                    for (var selected = 0; selected < count; selected++) {
                      final activeWidth =
                          (captionWidths[selected] + S.navIcon + S.x1 + S.x4)
                              .clamp(S.tap, box.maxWidth - S.tap * (count - 1));
                      final idleWidth =
                          (box.maxWidth - activeWidth) / (count - 1);
                      layouts.add([
                        for (var i = 0; i < count; i++)
                          i == selected ? activeWidth : idleWidth,
                      ]);
                    }
                    return TweenAnimationBuilder<List<double>>(
                      tween: _SelectionTween(current),
                      duration: motion(c, Motion.spatial),
                      curve: Motion.spatialCurve(c),
                      builder: (c, values, _) {
                        // A bounded convex mixture of complete layouts keeps all
                        // targets at least S.tap and total width constant, even if
                        // a spring overshoots or is interrupted by another press.
                        final weights = [
                          for (final value in values) value.clamp(0.0, 1.0),
                        ];
                        final total = weights.fold(0.0, (a, b) => a + b);
                        final widths = List.generate(count, (i) {
                          var width = 0.0;
                          for (var selected = 0; selected < count; selected++) {
                            width +=
                                layouts[selected][i] *
                                weights[selected] /
                                total;
                          }
                          return width;
                        });
                        var start = 0.0;
                        var capsuleStart = 0.0;
                        var capsuleWidth = 0.0;
                        for (var i = 0; i < widths.length; i++) {
                          capsuleStart += start * weights[i] / total;
                          capsuleWidth += widths[i] * weights[i] / total;
                          start += widths[i];
                        }
                        return Stack(
                          children: [
                            PositionedDirectional(
                              start: capsuleStart,
                              top: 0,
                              width: capsuleWidth,
                              height: height,
                              child: AnimatedContainer(
                                key: const ValueKey(
                                  'expressive-selected-capsule',
                                ),
                                duration: motion(c, Motion.base),
                                curve: Motion.effectsCurve(c),
                                decoration: BoxDecoration(
                                  color: p.wash(current.accent),
                                  borderRadius: R.rPill,
                                ),
                              ),
                            ),
                            Row(
                              children: [
                                for (
                                  var i = 0;
                                  i < visibleShellDomains.length;
                                  i++
                                )
                                  SizedBox(
                                    width: widths[i],
                                    child: _ExpressiveTab(
                                      domain: visibleShellDomains[i],
                                      on: visibleShellDomains[i] == current,
                                      onTap: () =>
                                          onTap(visibleShellDomains[i]),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
            ),
        ),
      ),
    );
  }
}

/// One tween keeps the four destination widths in step through rapid presses.
class _SelectionTween extends Tween<List<double>> {
  // Reuse target identity so unrelated rebuilds do not restart the spring.
  static final _targets = {
    for (final selected in visibleShellDomains)
      selected: List<double>.unmodifiable([
        for (final d in visibleShellDomains) d == selected ? 1.0 : 0.0,
      ]),
  };

  _SelectionTween(ShellDomain selected)
    : super(begin: _targets[selected], end: _targets[selected]);

  @override
  List<double> lerp(double t) => [
    for (var i = 0; i < end!.length; i++) begin![i] + (end![i] - begin![i]) * t,
  ];
}

class _ExpressiveTab extends StatelessWidget {
  final ShellDomain domain;
  final bool on;
  final VoidCallback onTap;

  const _ExpressiveTab({
    required this.domain,
    required this.on,
    required this.onTap,
  });

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final ink = on ? p.on(domain.accent) : p.ink3;
    final label = domain.title(c);
    return Semantics(
      selected: on,
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: Pressable(
          onTap: onTap,
          semanticLabel: label,
          child: ExcludeSemantics(
            child: Container(
              key: ValueKey('expressive-tab-${domain.name}'),
              width: double.infinity,
              height: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: S.x1),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(domain.icon, size: on ? S.navIcon : S.x6, color: ink),
                  if (on) ...[
                    const SizedBox(width: S.x1),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: F.over.copyWith(
                          color: ink,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  final ShellDomain domain;
  final bool on;
  final VoidCallback onTap;

  const _Tab({required this.domain, required this.on, required this.onTap});

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final ink = on ? p.on(domain.accent) : p.ink3;
    final label = domain.title(c);
    return Semantics(
      selected: on,
      child: Pressable(
        onTap: onTap,
        semanticLabel: label,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: motion(c, Motion.base),
              padding: EdgeInsets.symmetric(
                  horizontal: on ? S.x3 : 0, vertical: S.x1),
              decoration: BoxDecoration(
                color: on ? p.wash(domain.accent) : const Color(0x00000000),
                borderRadius: R.rPill,
              ),
              child: Icon(domain.icon, size: 20, color: ink),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: F.over.copyWith(
                color: ink,
                fontWeight: on ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
