// THE DATA BOUNDARY — the daily briefing, and exactly what left the device to
// produce it.
//
// `Briefing.inputs` is the compact metric snapshot the prompt was built from,
// stored beside every briefing since the engine was written. Nothing ever read
// it. That map IS the payload — `buildBriefingUserPrompt` writes one `key: value`
// line per entry and adds nothing — so this screen can state, exactly and
// without hedging, what a third party received.
//
// For an app whose whole argument is that the data stays on the phone, this is
// not a nicety. It is the thing that makes choosing a cloud key a decision
// rather than a leap, and it is why the local presets come first in setup.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../ai/briefing.dart';
import '../../ai/briefing_engine.dart';
import '../../coach/coach_config.dart';
import '../../coach/coach_engine.dart' show CoachException;
import '../../data/day_label.dart' show todayLabel;
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../ui2.dart';
import 'coach.dart' show CoachSetup, kCoachAccent;
import 'home_screen.dart' show go, prettyDay, repoOf;

class AiBriefingScreen extends StatefulWidget {
  final BriefingPeriod period;
  final String? day;

  /// The saved-content seam also lets tests exercise a failed or delayed read.
  final FutureOr<Briefing?> Function(BriefingPeriod, {String? day})?
  loadBriefing;

  const AiBriefingScreen({
    super.key,
    required this.period,
    this.day,
    this.loadBriefing,
  });

  @override
  State<AiBriefingScreen> createState() => _AiBriefingScreenState();
}

class _AiBriefingScreenState extends State<AiBriefingScreen> {
  Briefing? _b;
  bool _busy = false;
  bool _loading = true;
  bool _loadFailed = false;
  String? _error;
  String? _scheduledReadId;
  Animation<double>? _openingAnimation;
  int _loadRequest = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(AiBriefingScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.period != widget.period || oldWidget.day != widget.day) {
      _load();
    }
  }

  @override
  void dispose() {
    _openingAnimation?.removeStatusListener(_openingStatus);
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++_loadRequest;
    setState(() {
      _loading = true;
      _loadFailed = false;
      _error = null;
      _b = null;
      _scheduledReadId = null;
    });
    try {
      final loader = widget.loadBriefing ?? BriefingStore.read;
      final b = await loader(widget.period, day: widget.day);
      if (!mounted || request != _loadRequest) return;
      setState(() {
        _b = b;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || request != _loadRequest) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  bool _hasContent(Briefing b) =>
      b.oneLiner.trim().isNotEmpty || b.breakdownMd.trim().isNotEmpty;

  void _openingStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && mounted) setState(() {});
  }

  void _acknowledgeOpened(Briefing b) {
    final route = ModalRoute.of(context);
    if (!_hasContent(b) ||
        BriefingStore.isRead(b) ||
        route?.isCurrent == false) {
      return;
    }
    final animation = route?.animation;
    if (animation != null && animation.status != AnimationStatus.completed) {
      if (!identical(animation, _openingAnimation)) {
        _openingAnimation?.removeStatusListener(_openingStatus);
        _openingAnimation = animation..addStatusListener(_openingStatus);
      }
      return;
    }
    if (_scheduledReadId == b.id) return;
    _scheduledReadId = b.id;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted ||
          _loading ||
          _loadFailed ||
          _b?.id != b.id ||
          route?.isCurrent == false) {
        _scheduledReadId = null;
        return;
      }
      // The content has painted and its route has finished opening. Neither
      // Home appearing nor generation/caching alone can acknowledge a read.
      AppState? app;
      try {
        app = context.read<AppState>();
      } catch (_) {
        // The screen also renders in isolated widget tests and the gallery.
      }
      final saved = await BriefingStore.markRead(b);
      if (saved) app?.briefingUpdated();
    });
  }

  Future<void> _generate() async {
    if (_busy) return;
    final repo = repoOf(context);
    if (repo == null) return;
    final config = context.read<CoachConfig>();
    AppState? app;
    try {
      app = context.read<AppState>();
    } catch (_) {
      // The generator can be exercised with a repository-only fixture.
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final b = await BriefingEngine(
        config: config,
        repo: repo,
      ).generate(widget.period);
      if (mounted) {
        setState(() => _b = b);
        app?.briefingUpdated();
      }
    } catch (e) {
      if (mounted) {
        final l = AppLocalizations.of(context);
        setState(
          () => _error = e is CoachException
              ? e.message
              : (l?.aiBriefingFailedGeneric('$e') ?? 'It failed: $e'),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final cfg = c.watch<CoachConfig>();
    final b = _b;
    final past = widget.day != null && widget.day != todayLabel();
    final content = b != null && _hasContent(b);
    if (!_loading && !_loadFailed && content) {
      _acknowledgeOpened(b);
    }
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: S.x4),
              child: NavBar(
                widget.period == BriefingPeriod.morning
                    ? (l?.aiBriefingMorningTitle ?? 'Morning briefing')
                    : (l?.aiBriefingEveningTitle ?? 'Nightly sweep'),
                sub: b == null
                    ? ''
                    : (l?.aiBriefingForDay(prettyDay(b.day, l)) ??
                          'FOR ${b.day}'),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x8),
                children: [
                  const SizedBox(height: S.x2),
                  if (_loading)
                    StatusCard(
                      l?.aiBriefingLoading ?? 'Opening briefing…',
                      '',
                      icon: LucideIcons.sparkles,
                    )
                  else if (_loadFailed)
                    StatusCard(
                      l?.aiBriefingFailedTitle ?? 'That did not go through',
                      l?.aiBriefingLoadFailedBody ??
                          'The saved briefing could not be opened. Try again.',
                      fix: l?.homeTryAgain ?? 'Try again',
                      icon: LucideIcons.triangleAlert,
                      onFix: _load,
                    )
                  else if (!content && !cfg.configured)
                    StatusCard(
                      l?.aiBriefingNoModelTitle ?? 'No model is set up',
                      l?.aiBriefingNoModelBody ??
                          'A briefing is written by a model you choose. Until you '
                              'pick one there is nothing to generate and nothing '
                              'has been sent anywhere.',
                      fix: l?.aiBriefingChooseModel ?? 'Choose a model',
                      icon: LucideIcons.sparkles,
                      destination: const CoachSetup(),
                    )
                  else if (!content && past)
                    StatusCard(
                      l?.aiBriefingPastEmptyTitle ?? 'No briefing for this day',
                      l?.aiBriefingPastEmptyBody ??
                          'A briefing has not been saved for this day.',
                      icon: LucideIcons.calendar,
                    )
                  else if (!content)
                    StatusCard(
                      l?.aiBriefingNothingTitle ?? 'Nothing written for today',
                      l?.aiBriefingNothingBody ??
                          'Briefings are generated on a schedule, or on demand '
                              'here.',
                      fix: _busy
                          ? (l?.aiBriefingWriting ?? 'Writing…')
                          : (l?.aiBriefingWriteNow ?? 'Write one now'),
                      icon: LucideIcons.sun,
                      onFix: _busy ? null : _generate,
                    )
                  else ...[
                    Surface(
                      color: Color.alphaBlend(p.wash(kCoachAccent), p.card),
                      elevation: 0,
                      child: Semantics(
                        header: true,
                        child: Text(
                          b.calledModel
                              ? b.oneLiner
                              : (l?.aiBriefingNothingStoodOut ?? b.oneLiner),
                          style: F.head.copyWith(color: p.ink, height: 1.5),
                        ),
                      ),
                    ),
                    if (b.breakdownMd.isNotEmpty) ...[
                      const SizedBox(height: S.x5),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: S.x1),
                        child: GptMarkdownTheme(
                          gptThemeData: GptMarkdownTheme.of(c).copyWith(
                            h1: F.t2.copyWith(color: p.ink),
                            h2: F.head.copyWith(color: p.ink),
                            h3: F.head.copyWith(color: p.ink),
                            h4: F.head.copyWith(color: p.ink),
                            h5: F.head.copyWith(color: p.ink),
                            h6: F.head.copyWith(color: p.ink),
                            autoAddDividerLineAfterH1: false,
                          ),
                          child: GptMarkdown(
                            b.breakdownMd,
                            style: F.body.copyWith(color: p.ink, height: 1.65),
                            // Saved model prose must not trigger image downloads.
                            imageBuilder: (_, url, width, height) =>
                                Text(url, style: F.cap.copyWith(color: p.ink2)),
                          ),
                        ),
                      ),
                    ],
                    if (!past) ...[
                      const SizedBox(height: S.x3),
                      if (cfg.configured)
                        _action(
                          c,
                          label: _busy
                              ? (l?.aiBriefingWriting ?? 'Writing…')
                              : (l?.aiBriefingWriteAgain ?? 'Write it again'),
                          icon: LucideIcons.refreshCw,
                          onTap: _busy ? null : _generate,
                        ),
                      if (!cfg.configured)
                        _action(
                          c,
                          label: l?.aiBriefingChooseModel ?? 'Choose a model',
                          icon: LucideIcons.sparkles,
                          onTap: () => go(c, const CoachSetup()),
                        ),
                    ],
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: S.x3),
                    StatusCard(
                      l?.aiBriefingFailedTitle ?? 'That did not go through',
                      _error!,
                      icon: LucideIcons.triangleAlert,
                    ),
                  ],
                  if (!_loading && !_loadFailed && content) ...[
                    const SizedBox(height: S.x5),
                    SentPayload(
                      key: ValueKey('briefing-payload-${b.id}'),
                      inputs: b.inputs,
                      config: cfg,
                      asked: b.calledModel,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _action(
    BuildContext c, {
    required String label,
    required IconData icon,
    VoidCallback? onTap,
  }) {
    final p = P.of(c);
    return Align(
      alignment: Alignment.centerRight,
      child: Semantics(
        enabled: onTap != null,
        child: Pressable(
          key: const ValueKey('briefing-action'),
          semanticLabel: label,
          onTap: onTap,
          child: ExcludeSemantics(
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: S.x3,
                vertical: S.x2,
              ),
              constraints: const BoxConstraints(minHeight: S.tap),
              decoration: BoxDecoration(
                color: p.card2,
                borderRadius: R.controlOf(c),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: S.x4, color: p.on(kCoachAccent)),
                  const SizedBox(width: S.x2),
                  Flexible(
                    child: Text(
                      label,
                      style: F.cap.copyWith(color: p.ink, height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What was sent, in full. Not a summary of it — the same map, every key.
///
/// A screen that showed "12 metrics" would be worse than nothing: it asks to be
/// trusted about the exact question it exists to answer.
class SentPayload extends StatefulWidget {
  final Map<String, dynamic> inputs;
  final CoachConfig config;

  /// Whether a model was called at all — [Briefing.calledModel]. False for a
  /// nightly sweep that found nothing: there was no request, so the banner may
  /// not describe one.
  final bool asked;

  const SentPayload({
    super.key,
    required this.inputs,
    required this.config,
    this.asked = true,
  });

  /// True when the endpoint is on this machine, in which case nothing left it.
  static bool isLocal(String base) {
    final h = Uri.tryParse(base)?.host.toLowerCase() ?? '';
    return h == 'localhost' || h == '127.0.0.1' || h == '::1';
  }

  static String _label(String key) {
    final s = key.replaceAll('_', ' ');
    return s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
  }

  /// Verbatim, because this is a preview of a payload and not a metric card.
  /// [buildBriefingUserPrompt] writes `$v` for every entry, so a null reaches
  /// the model as the word `null` and this has to say the same — an em dash
  /// here would read as "withheld" for a value that was in fact sent, empty.
  /// (`_put` drops absent metrics before they get this far, so this is the
  /// belt and not the trousers.)
  static String _value(dynamic v) => v is List ? v.join(', ') : '$v';

  @override
  State<SentPayload> createState() => _SentPayloadState();
}

class _SentPayloadState extends State<SentPayload> {
  bool _expanded = false;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final config = widget.config;
    final host = Uri.tryParse(config.apiBase)?.host ?? config.apiBase;
    final local = SentPayload.isLocal(config.apiBase);
    final keys = widget.inputs.keys.toList()..sort();
    // An empty payload is not "we sent an empty payload". The nightly sweep
    // calls no model at all on a day with no finding, so the banner must not go
    // on describing a request that never happened.
    final none = !widget.asked;
    final title = none || !local
        ? (l?.aiBriefingSentSection ?? 'What was sent')
        : (l?.aiBriefingReadSection ?? 'What was read');
    return Surface(
      elevation: 0,
      pad: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            expanded: _expanded,
            child: Pressable(
              key: const ValueKey('briefing-payload-toggle'),
              semanticLabel: title,
              onTap: () => setState(() => _expanded = !_expanded),
              child: ExcludeSemantics(
                child: Padding(
                  padding: const EdgeInsets.all(S.x4),
                  child: Row(
                    children: [
                      Icon(LucideIcons.database, size: S.x5, color: p.ink2),
                      const SizedBox(width: S.x3),
                      Expanded(
                        child: Text(
                          title,
                          style: F.body.copyWith(color: p.ink),
                        ),
                      ),
                      const SizedBox(width: S.x2),
                      AnimatedRotation(
                        turns: _expanded ? .5 : 0,
                        duration: motion(c, Motion.base),
                        curve: Motion.effectsCurve(c),
                        child: Icon(
                          LucideIcons.chevronDown,
                          size: S.x5,
                          color: p.ink2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          _reveal(
            c,
            child: _expanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(S.x4, 0, S.x4, S.x4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Surface(
                          elevation: 0,
                          color: p.wash(none || local ? C.green : C.orange),
                          child: Row(
                            children: [
                              Icon(
                                none || local
                                    ? LucideIcons.house
                                    : LucideIcons.cloudUpload,
                                size: S.x5,
                                color: p.on(none || local ? C.green : C.orange),
                              ),
                              const SizedBox(width: S.x3),
                              Expanded(
                                child: Text(
                                  none
                                      ? (l?.aiBriefingNoneBody ??
                                            'Nothing. There was no request — the note above was '
                                                'written on this phone.')
                                      : local
                                      ? (l?.aiBriefingLocalBody(host) ??
                                            'These numbers went to $host, on this machine. '
                                                'Nothing left it.')
                                      : (l?.aiBriefingCloudBody(
                                              host,
                                              config.model,
                                            ) ??
                                            'These numbers, and nothing else, were sent to '
                                                '$host as ${config.model}. No raw '
                                                'recordings, no name, no identifier.'),
                                  style: F.cap.copyWith(
                                    color: p.ink,
                                    height: 1.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: S.x3),
                        if (none)
                          StatusCard(
                            l?.aiBriefingNoneCardTitle ??
                                'Nothing stood out, so nothing was asked',
                            l?.aiBriefingNoneCardBody ??
                                'The sweep runs on this phone. It only calls a model when it has '
                                    'a finding to hand it, and today it had none.',
                            icon: LucideIcons.circleSlash,
                          )
                        else if (keys.isEmpty)
                          StatusCard(
                            l?.aiBriefingEmptyCardTitle ??
                                'Nothing was available to send',
                            l?.aiBriefingEmptyCardBody ??
                                'No metric had a value when this was written, so the prompt '
                                    'carried none.',
                            icon: LucideIcons.circleSlash,
                          )
                        else
                          Surface(
                            elevation: 0,
                            pad: const EdgeInsets.symmetric(
                              horizontal: S.x4,
                              vertical: S.x2,
                            ),
                            child: Column(
                              children: [
                                for (final k in keys)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: S.x2,
                                    ),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: Text(
                                            SentPayload._label(k),
                                            style: F.cap.copyWith(
                                              color: p.ink3,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: S.x3),
                                        Flexible(
                                          child: Text(
                                            SentPayload._value(
                                              widget.inputs[k],
                                            ),
                                            textAlign: TextAlign.right,
                                            style: F.cap.copyWith(color: p.ink),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  Widget _reveal(BuildContext c, {required Widget child}) => Motion.enabled(c)
      ? AnimatedSize(
          alignment: Alignment.topCenter,
          duration: motion(c, Motion.base),
          curve: Motion.spatialCurve(c),
          child: child,
        )
      : child;
}
