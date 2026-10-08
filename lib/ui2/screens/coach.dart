// COACH — the door onto the agentic AI that was already built.
//
// `lib/coach` has had a working tool-calling loop for months: read-only SQL over
// the derived views, figures the app draws natively, and confirmation-gated
// writes. It had no screen, so none of it could run. This is the screen.
//
// Three rules this file keeps:
//
//   1. LOCAL FIRST. The app is zero-egress by design, so the setup screen offers
//      Ollama and LM Studio before it offers anyone's cloud. A cloud key is a
//      deliberate choice, and the screen says what leaving the device means.
//   2. EVERY WRITE IS CONFIRMED. `confirm` is wired to a real dialog carrying
//      the tool's own human-readable summary. There is no path from a tool call
//      to a write that does not pass through it, and a destructive action gets
//      its own wording rather than the same "Confirm" as an add.
//   3. NO SECOND DESIGN SYSTEM. Figures are `CoachFigure` (the app's own
//      painters); everything else is grammar.dart. The one thing that is not is
//      the markdown body, because there is no house widget for prose.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_localizations.dart';
import '../../l10n/coach_action_presentation.dart';
import '../../coach/coach_config.dart';
import '../../coach/coach_engine.dart';
import '../../coach/coach_store.dart';
import '../../data/day_label.dart';
import '../../state/app_state.dart';
import '../ui2.dart';
import 'coach_figures.dart';
import 'coach_personalization.dart';
import 'home_screen.dart' show go, pad, repoOf, prettyDay;
import 'journal_compose.dart' show OsTextField;

/// The coach's accent. Not a domain colour: the coach reads across all five.
const Color kCoachAccent = C.coach;

/// Whether the coach has a model behind it — false when there is no
/// [CoachConfig] above us, which is every golden.
///
/// Home shows its sparkles button only when this is true. An icon that opens a
/// setup form nobody asked for is clutter on a screen built around three rings,
/// and the place to go and set the thing up is Profile, with the other
/// settings. [keyUnreadable] counts as configured: the key IS saved, this
/// process just could not read it through a locked keychain, and hiding the
/// button there would tell a configured user their coach had vanished.
bool coachReady(BuildContext c) {
  try {
    final cfg = c.watch<CoachConfig>();
    return cfg.configured || cfg.keyUnreadable;
  } catch (_) {
    return false;
  }
}

/// [coachReady] for an event handler, which must not listen.
///
/// `watch` outside `build` trips a provider assert, and the catch above turns
/// that into a plain "not configured" — so a tap handler asking [coachReady]
/// sends a fully configured user to the setup form every time.
bool coachReadyNow(BuildContext c) {
  try {
    final cfg = c.read<CoachConfig>();
    return cfg.configured || cfg.keyUnreadable;
  } catch (_) {
    return false;
  }
}

/// What the Profile row should say under "AI coach", or null when there is no
/// [CoachConfig] above this context at all.
///
/// Same try/catch as [coachReady] and for the same reason: the golden harness
/// mounts screens without the app's providers, and a throw there is a red test
/// about the harness rather than about the screen. Null and "Not set up" are
/// deliberately the same sentence to the reader — from the row's point of view
/// an unreadable config and an unset one both mean the setup form is what the
/// tap should open.
String? coachSubtitle(BuildContext c) {
  try {
    final cfg = c.watch<CoachConfig>();
    return cfg.configured
        ? cfg.model
        : (AppLocalizations.of(c)?.coachNotSetUp ?? 'Not set up');
  } catch (_) {
    return null;
  }
}

/// One shell-owned chat avoids creating another engine during a response.
class CoachEntryScope extends InheritedWidget {
  final VoidCallback open;
  final ValueChanged<String> onHomeDay;
  const CoachEntryScope({
    super.key,
    required this.open,
    required this.onHomeDay,
    required super.child,
  });
  static CoachEntryScope? maybeOf(BuildContext c) =>
      c.getInheritedWidgetOfExactType<CoachEntryScope>();
  @override
  bool updateShouldNotify(CoachEntryScope oldWidget) => false;
}

void openCoach(BuildContext c) {
  final entry = CoachEntryScope.maybeOf(c);
  if (isExpressive(c) && entry != null) {
    entry.open();
  } else {
    go(c, const CoachScreen());
  }
}

class CoachScreen extends StatefulWidget {
  /// A message to send the moment the engine is up — visibly, as the user's
  /// own turn, so the model runs its tools on it like any other question
  /// (nothing is injected as trusted prose). [startNewSession] opens a fresh
  /// conversation for it first.
  final String? initialMessage;
  final bool startNewSession;

  /// The host owns an embedded chat's header, keyboard inset and dismissal.
  /// Its State stays mounted through compact/full transitions and closing.
  final Widget Function(
    BuildContext context,
    VoidCallback menu,
    VoidCallback newChat,
    String subtitle,
    bool showNewChat,
  )?
  headerBuilder;

  /// Only an embedded panel contracts when a downward swipe starts at the
  /// transcript's top. Message scrolling and the composer keep their gestures.
  final VoidCallback? onPullDownAtTop;
  final bool presented;
  final ValueChanged<VoidCallback?>? onBackChanged;
  final String? viewingDay, viewingSection;

  const CoachScreen({
    super.key,
    this.initialMessage,
    this.startNewSession = false,
    this.headerBuilder,
    this.onPullDownAtTop,
    this.presented = true,
    this.onBackChanged,
    this.viewingDay,
    this.viewingSection,
  });

  @override
  State<CoachScreen> createState() => _CoachScreenState();
}

enum _CoachPage { chat, chats, preferences }

class _CoachScreenState extends State<CoachScreen> {
  CoachEngine? _engine;
  _CoachPage _page = _CoachPage.chat;
  int _chatMenuRevision = 0, _preferencesRevision = 0;
  String _activeTitle = '';
  VoidCallback? _preferenceBack;
  final List<CoachItem> _items = [];
  final _input = TextEditingController();
  final _inputFocus = FocusNode(debugLabel: 'Coach composer');
  final _scroll = ScrollController();
  double _topDrag = 0;
  bool _pullStartedAtTop = false, _pulledAtTop = false;
  bool _busy = false;
  String? _status;
  String? _initError;
  bool _loadingConversation = true;
  bool _changingChat = false;
  Timer? _draftTimer;
  bool _restoring = false;
  final Map<String, String?> _chatStatuses = {};
  final Set<String> _stopped = {}, _submitting = {}, _cancelledSubmissions = {};

  static List<String> _starters(BuildContext c) {
    final l = AppLocalizations.of(c);
    return [
      l?.coachStarterRecovery ?? 'How recovered am I today, and why?',
      l?.coachStarterHrvChart ?? 'Chart my HRV over the last month',
      l?.coachStarterSleep ?? 'How has my sleep been this week?',
      l?.coachStarterAteYesterday ?? 'What did I eat yesterday?',
      l?.coachStarterLogWater ?? 'Log 500 ml of water for today',
      l?.coachStarterLogRun ?? 'I ran for 40 minutes this morning — log it',
    ];
  }

  @override
  void initState() {
    super.initState();
    _input.addListener(_draftChanged);
    _scroll.addListener(_draftChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _initEngine());
  }

  Future<void> _initEngine() async {
    if (!mounted) return;
    final repo = repoOf(context);
    if (repo == null) {
      setState(() => _loadingConversation = false);
      return;
    }
    final app = context.read<AppState>();
    final cfg = context.read<CoachConfig>();
    final engine = CoachEngine(
      config: cfg,
      api: repo,
      storageKey: (app.user?['id'] ?? 'local').toString(),
    );
    try {
      await engine.restore();
    } catch (e) {
      engine.dispose();
      if (mounted) {
        setState(() {
          _initError = '$e';
          _loadingConversation = false;
        });
      }
      return;
    }
    if (!mounted) {
      engine.dispose();
      return;
    }
    if (widget.startNewSession) engine.newSession();
    setState(() {
      _engine = engine;
      _loadingConversation = false;
      _items
        ..clear()
        ..addAll(engine.transcript);
    });
    _restoreView();
    unawaited(_refreshTitle());
    final first = widget.initialMessage;
    if (first != null && first.trim().isNotEmpty && !_sentInitial) {
      _sentInitial = true;
      await _send(first);
    }
  }

  bool _sentInitial = false;

  @override
  void dispose() {
    _draftTimer?.cancel();
    final engine = _engine;
    if (engine != null) {
      engine.updateDraft(
        _input.text,
        scrollOffset: _scroll.hasClients ? _scroll.offset : null,
      );
      unawaited(engine.persist().catchError((_) {}));
    }
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    // Not `_engine?.dispose()`: a `send` can still be in flight (a local
    // model's first response can take minutes), and closing the shared HTTP
    // client out from under it aborts the request instead of letting it land.
    // `requestDispose` defers the actual close until `send`'s own `finally`
    // sees it — see coach_engine.dart.
    _engine?.requestDispose();
    super.dispose();
  }

  void _draftChanged() {
    if (_restoring || !mounted || _engine == null) return;
    _engine!.updateDraft(
      _input.text,
      scrollOffset: _scroll.hasClients ? _scroll.offset : null,
    );
    _draftTimer?.cancel();
    _draftTimer = Timer(CoachStore.draftSaveDebounce, () => _saveView());
  }

  Future<void> _saveView() async {
    _draftTimer?.cancel();
    final engine = _engine;
    if (engine == null) return;
    engine.updateDraft(
      _input.text,
      scrollOffset: _scroll.hasClients ? _scroll.offset : null,
    );
    try {
      await engine.persist();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.coachSaveError)),
        );
      }
    }
  }

  void _restoreView() {
    final engine = _engine;
    if (engine == null) return;
    _restoring = true;
    _input.text = engine.draft;
    _restoring = false;
    _items
      ..clear()
      ..addAll(engine.transcript);
    _busy = engine.isSending || _submitting.contains(engine.sessionId);
    _status = _chatStatuses[engine.sessionId];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        _scroll.jumpTo(
          engine.scrollOffset.clamp(0, _scroll.position.maxScrollExtent),
        );
      }
    });
  }

  void _stop() {
    final id = _engine?.sessionId;
    if (id == null) return;
    if (_submitting.contains(id)) _cancelledSubmissions.add(id);
    _engine?.stop();
  }

  Future<void> _send(String text, {bool retry = false}) async {
    final t = text.trim(), engine = _engine;
    if (_changingChat || (t.isEmpty && !retry) || engine == null) return;
    final origin = engine.sessionId;
    if (_submitting.contains(origin) || engine.isSending) return;
    _submitting.add(origin);
    _chatStatuses[origin] = 'preparing';
    _stopped.remove(origin);
    setState(() {
      _busy = true;
      _status = 'preparing';
    });
    final viewedDay = widget.viewingDay, viewedSection = widget.viewingSection;
    final app = context.read<AppState>();
    var wrote = false;
    try {
      await _saveView();
      await engine.reloadPreferences();
      if (_cancelledSubmissions.remove(origin)) {
        _stopped.add(origin);
        return;
      }
      if (mounted && engine.sessionId == origin && !retry) _input.clear();
      await engine.send(
        t,
        retry: retry,
        sessionId: origin,
        viewingDay: viewedDay,
        viewingSection: viewedSection,
        onItem: (it) {
          if (!mounted || engine.sessionId != origin) return;
          setState(() {
            _items
              ..clear()
              ..addAll(engine.transcript);
          });
          _scrollDown();
        },
        onStatus: (status) {
          _chatStatuses[origin] = status;
          if (mounted && engine.sessionId == origin) {
            setState(() => _status = status);
          }
        },
        confirm: (req) async {
          if (engine.sessionId != origin) return false;
          final ok = await _confirm(req);
          if (ok && engine.sessionId == origin) wrote = true;
          return ok && engine.sessionId == origin;
        },
      );
    } on CoachCancelled {
      _stopped.add(origin);
    } catch (_) {
      if (mounted &&
          engine.sessionId == origin &&
          !engine.transcript.any((e) => e.kind == CoachItemKind.error)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.coachSaveError)),
        );
      }
    } finally {
      _submitting.remove(origin);
      _cancelledSubmissions.remove(origin);
      _chatStatuses.remove(origin);
      if (mounted && engine.sessionId == origin) {
        setState(() {
          _busy = engine.isSending;
          _status = null;
          _items
            ..clear()
            ..addAll(engine.transcript);
          if (_input.text.isEmpty && engine.draft.isNotEmpty) {
            _input.text = engine.draft;
          }
        });
        _scrollDown();
      }
      if (mounted) unawaited(_refreshTitle());
      if (wrote) await app.refreshAiReminders();
    }
  }

  /// THE write gate. Every action tool routes through here, and the dialog
  /// carries the tool's own summary rather than a generic "the AI wants to do
  /// something" — a confirmation that does not say what it confirms is a tap
  /// target, not consent.
  Future<bool> _confirm(ActionRequest req) async {
    // Reads may finish while another Coach page is open, but a write proposal
    // belongs to the visible transcript and must not interrupt that page.
    if (!mounted ||
        !widget.presented ||
        _page != _CoachPage.chat ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return false;
    }
    final destructive = req.tool.startsWith('delete_');
    final p = P.of(context);
    final l = AppLocalizations.of(context);
    final copy = localizeCoachAction(req, l);
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: p.card,
        title: Text(
          req.tool == 'remember_preference'
              ? l?.coachMemoryConfirm ?? copy.title
              : copy.title,
          style: F.head.copyWith(color: p.ink),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              copy.summary,
              style: F.body.copyWith(color: p.ink2, height: 1.4),
            ),
            const SizedBox(height: S.x3),
            Text(
              destructive
                  ? (l?.coachDestructiveWarning ??
                        'This removes data from this device and cannot be undone.')
                  : (l?.coachSafeWarning ??
                        'Nothing is written until you tap below.'),
              style: F.cap.copyWith(color: p.ink3),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(d).pop(false),
            child: Text(
              l?.actionCancel ?? 'Cancel',
              style: F.body.copyWith(color: p.ink2),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(d).pop(true),
            child: Text(
              destructive
                  ? (l?.coachDeleteIt ?? 'Delete it')
                  : (l?.coachSaveIt ?? 'Save it'),
              style: F.body.copyWith(
                color: p.on(destructive ? C.red : kCoachAccent),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _refreshTitle() async {
    final engine = _engine;
    if (engine == null) return;
    final id = engine.sessionId;
    try {
      final sessions = await engine.listSessions();
      final title = sessions.where((s) => s.id == id).firstOrNull?.title ?? '';
      if (mounted && engine.sessionId == id) {
        setState(() => _activeTitle = title);
      }
    } catch (_) {
      // A title is decorative. Storage failures retain the existing chat UI.
    }
  }

  void _showPage(_CoachPage page) {
    _inputFocus.unfocus();
    setState(() {
      if (page != _page) {
        if (page == _CoachPage.chats) _chatMenuRevision++;
        if (page == _CoachPage.preferences) _preferencesRevision++;
      }
      _page = page;
      _preferenceBack = null;
    });
    widget.onBackChanged?.call(page == _CoachPage.chat ? null : _backFromPage);
  }

  void _backFromPage() {
    if (_preferenceBack != null) {
      _preferenceBack!();
    } else {
      _showPage(
        _page == _CoachPage.preferences ? _CoachPage.chats : _CoachPage.chat,
      );
    }
  }

  Future<void> _newChat() async {
    if (_changingChat || _engine == null) return;
    final exit = _page == _CoachPage.chat && widget.presented
        ? motion(context, Motion.fast)
        : Duration.zero;
    _inputFocus.unfocus();
    setState(() => _changingChat = true);
    try {
      // Save while the current transcript fades. Do not clear it mid-frame.
      final fadeOut = exit == Duration.zero
          ? Future<void>.value()
          : WidgetsBinding.instance.endOfFrame.then(
              (_) => Future<void>.delayed(exit),
            );
      await Future.wait([_saveView(), fadeOut]);
      if (!mounted) return;
      _engine!.newSession();
      _activeTitle = '';
      setState(_restoreView);
      _showPage(_CoachPage.chat);
    } finally {
      if (mounted) setState(() => _changingChat = false);
    }
  }

  Future<void> _openSession(String id) async {
    if (_changingChat) return;
    await _saveView();
    try {
      await _engine?.openSession(id);
      if (mounted) {
        setState(_restoreView);
        _showPage(_CoachPage.chat);
        await _refreshTitle();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.coachChatsLoadError),
          ),
        );
      }
    }
  }

  void _scrollDown() {
    if (!mounted || !widget.presented) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.presented && _scroll.hasClients) {
        final duration = motion(context, Motion.slow);
        if (duration == Duration.zero) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        } else {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: duration,
            curve: Curves.easeOut,
          );
        }
      }
    });
  }

  Future<void> _menu() async {
    if (_changingChat) return;
    await _saveView();
    if (!mounted) return;
    _showPage(_CoachPage.chats);
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c), l = AppLocalizations.of(c)!;
    final cfg = c.watch<CoachConfig>();
    final selectedDay = widget.viewingDay ?? todayLabel();
    final selectedDate = DateTime.tryParse(selectedDay);
    final dateLabel = selectedDate == null
        ? ''
        : DateFormat.MMMd(l.localeName).format(selectedDate);
    final subtitle = switch (_page) {
      _CoachPage.chats => l.coachSavedConversations,
      _CoachPage.preferences => l.coachYourPreferences,
      _CoachPage.chat =>
        _activeTitle.isEmpty ? l.coachNewChatDraft : _activeTitle,
    };
    final transcript = Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(S.x5, S.x2, S.x5, S.x3),
          child: Row(
            children: [
              Icon(LucideIcons.calendarDays, size: S.x4, color: p.ink3),
              const SizedBox(width: S.x2),
              Expanded(
                child: Text(
                  selectedDay == todayLabel()
                      ? '$dateLabel · ${l.coachChatToday}'
                      : dateLabel,
                  key: const ValueKey('coach-view-context'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: F.cap.copyWith(color: p.ink3),
                ),
              ),
            ],
          ),
        ),
        if ((_engine?.migrationIssues.isNotEmpty ?? false))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: Column(
              children: [
                Text(
                  l.coachLegacyWarning,
                  style: F.cap.copyWith(color: p.ink3),
                ),
                TextButton(
                  onPressed: () async {
                    await _engine?.retryMigration();
                    if (mounted) setState(() {});
                  },
                  child: Text(l.coachLegacyRetry),
                ),
              ],
            ),
          ),
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: widget.onPullDownAtTop == null ? null : _pullDown,
            child: _body(c, p, cfg),
          ),
        ),
        if (!_busy && (_engine?.canRetry ?? false))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: S.x4),
            child: Row(
              children: [
                if (_stopped.contains(_engine!.sessionId))
                  Expanded(
                    child: Text(
                      l.coachStopped,
                      style: F.cap.copyWith(color: p.ink3),
                    ),
                  ),
                TextButton.icon(
                  key: const ValueKey('coach-retry'),
                  onPressed: () => _send('', retry: true),
                  icon: const Icon(LucideIcons.rotateCcw),
                  label: Text(l.coachRetry),
                ),
              ],
            ),
          ),
        if (cfg.configured && _engine != null) _composer(c, p),
      ],
    );
    final body = Column(
      children: [
        if (widget.headerBuilder != null)
          widget.headerBuilder!(
            c,
            _menu,
            _newChat,
            subtitle,
            _page == _CoachPage.chat,
          )
        else
          CoachSurfaceHeader(
            subtitle: subtitle,
            onMenu: _menu,
            onNew: _page == _CoachPage.chat ? _newChat : null,
            onClose: () => Navigator.maybePop(c),
          ),
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              _CoachPagePane(
                key: const ValueKey('coach-page-chat'),
                active: _page == _CoachPage.chat && !_changingChat,
                retain: true,
                quickExit: _changingChat,
                child: transcript,
              ),
              _CoachPagePane(
                key: const ValueKey('coach-page-chats'),
                active: _page == _CoachPage.chats,
                child: _CoachChatMenu(
                  key: ValueKey(_chatMenuRevision),
                  engine: _engine,
                  onBack: _backFromPage,
                  onOpen: _openSession,
                  onNew: _newChat,
                  onDeleted: () {
                    setState(_restoreView);
                    _activeTitle = '';
                    _showPage(_CoachPage.chat);
                  },
                  onRenamed: () => unawaited(_refreshTitle()),
                  onPersonalize: () => _showPage(_CoachPage.preferences),
                ),
              ),
              _CoachPagePane(
                key: const ValueKey('coach-page-preferences'),
                active: _page == _CoachPage.preferences,
                child: CoachPersonalization(
                  key: ValueKey(_preferencesRevision),
                  embedded: true,
                  onBack: _backFromPage,
                  onBackChanged: (back) => _preferenceBack = back,
                  onSaved: () {
                    unawaited(_engine?.reloadPreferences());
                    _showPage(_CoachPage.chats);
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
    if (widget.headerBuilder != null) return body;
    return PopScope(
      canPop: _page == _CoachPage.chat,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _backFromPage();
      },
      child: Scaffold(
        backgroundColor: p.card,
        body: SafeArea(child: body),
      ),
    );
  }

  String _statusText(AppLocalizations? l) => switch (_status) {
    'preparing' => l?.coachPreparing ?? 'Preparing your message…',
    'reading' => l?.coachReading ?? 'Reading your data…',
    'confirmation' =>
      l?.coachAwaitingConfirmation ?? 'Waiting for your confirmation…',
    'writing' => l?.coachWriting ?? 'Saving your confirmed change…',
    'rendering' => l?.coachRendering ?? 'Preparing a figure…',
    _ => l?.coachRequesting ?? 'Waiting for your model…',
  };

  bool _pullDown(ScrollNotification event) {
    if (!widget.presented ||
        event.depth != 0 ||
        event.metrics.axis != Axis.vertical) {
      return false;
    }
    if (event is ScrollStartNotification) {
      _topDrag = 0;
      _pulledAtTop = false;
      _pullStartedAtTop =
          event.dragDetails != null &&
          event.metrics.pixels <= event.metrics.minScrollExtent;
    } else if (event is ScrollEndNotification) {
      _pullStartedAtTop = false;
      _topDrag = 0;
    } else if (_pullStartedAtTop &&
        !_pulledAtTop &&
        (event is ScrollUpdateNotification ||
            event is OverscrollNotification)) {
      final drag = event is ScrollUpdateNotification
          ? event.dragDetails
          : (event as OverscrollNotification).dragDetails;
      final dy = drag?.delta.dy;
      if (dy == null) return false;
      if (dy <= 0 || event.metrics.pixels > event.metrics.minScrollExtent) {
        _topDrag = 0;
      } else {
        _topDrag += dy;
        if (_topDrag >= S.tap) {
          _pulledAtTop = true;
          widget.onPullDownAtTop?.call();
        }
      }
    }
    return false;
  }

  Widget _body(BuildContext c, P p, CoachConfig cfg) {
    final l = AppLocalizations.of(c);
    final bodyPadding = widget.headerBuilder == null
        ? pad
        : const EdgeInsets.fromLTRB(S.x4, S.x2, S.x4, S.x4);
    final physics = widget.onPullDownAtTop == null
        ? null
        : const AlwaysScrollableScrollPhysics();
    // The key IS saved, this process just could not read it. Showing the setup
    // wall here would tell the user their key is gone and invite them to paste
    // it again.
    if (cfg.keyUnreadable) {
      return ListView(
        physics: physics,
        padding: bodyPadding,
        children: [
          const SizedBox(height: S.x4),
          StatusCard(
            l?.coachKeyStillSavedTitle ?? 'Your key is still saved',
            l?.coachKeyStillSavedBody ??
                'It could not be read from the keychain this time, which happens '
                    'when the app is woken while the phone is locked.',
            fix: l?.coachTryAgainFix ?? 'Try again',
            icon: LucideIcons.lock,
            onFix: () async {
              await cfg.refreshKeyOnResume();
              if (mounted) setState(() {});
            },
          ),
        ],
      );
    }
    if (!cfg.configured) {
      return ListView(
        physics: physics,
        padding: bodyPadding,
        children: [
          const SizedBox(height: S.x4),
          StatusCard(
            l?.coachNotSetUpTitle ?? 'The coach is not set up',
            l?.coachNotSetUpBody ??
                'It runs on a model you choose — one on your own machine, or any '
                    'OpenAI-compatible provider with your own key. Nothing goes '
                    'through OpenStrap either way.',
            fix: l?.coachChooseModelFix ?? 'Choose a model',
            icon: LucideIcons.sparkles,
            destination: const CoachSetup(),
          ),
        ],
      );
    }
    if (_initError != null) {
      return ListView(
        physics: physics,
        padding: bodyPadding,
        children: [
          StatusCard(l?.coachInitError ?? 'Could not open Coach', _initError!),
          TextButton(
            onPressed: () {
              setState(() {
                _initError = null;
                _loadingConversation = true;
              });
              _initEngine();
            },
            child: Text(l?.coachRetry ?? 'Retry'),
          ),
        ],
      );
    }
    if (_engine == null) {
      if (_loadingConversation) {
        return ListView(
          physics: physics,
          padding: bodyPadding,
          children: [
            const Center(child: CircularProgressIndicator()),
            Text(l?.coachChatsLoading ?? 'Loading conversations…'),
          ],
        );
      }
      return ListView(
        physics: physics,
        padding: bodyPadding,
        children: [
          const SizedBox(height: S.x4),
          StatusCard(
            l?.coachNoDataTitle ?? 'No data to read yet',
            l?.coachNoDataBody ??
                'The coach answers from your own derived days, and there are none '
                    'on this device yet.',
            icon: LucideIcons.database,
          ),
        ],
      );
    }
    if (_items.isEmpty && _status == null) {
      return ListView(
        physics: physics,
        padding: bodyPadding,
        children: [
          const SizedBox(height: S.x2),
          Surface(
            color: p.wash(kCoachAccent),
            elevation: 0,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      LucideIcons.sparkles,
                      size: 17,
                      color: p.on(kCoachAccent),
                    ),
                    const SizedBox(width: S.x2),
                    Expanded(
                      child: Text(
                        l?.coachYourDataYourModel ?? 'YOUR DATA, YOUR MODEL',
                        style: F.over.copyWith(color: p.on(kCoachAccent)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: S.x3),
                Text(
                  l?.coachIntroBody ??
                      'Ask about anything the app measures, and it can log food, '
                          'water, workouts, doses and how you felt — always asking '
                          'first.',
                  style: F.body.copyWith(color: p.ink, height: 1.45),
                ),
              ],
            ),
          ),
          Section(
            l?.coachTryAsking ?? 'Try asking',
            Surface(
              pad: const EdgeInsets.symmetric(vertical: S.x1),
              child: Column(
                children: [
                  for (final s in _starters(c))
                    Pressable(
                      onTap: () => _send(s),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: S.x4,
                          vertical: S.x3,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                s,
                                style: F.body.copyWith(color: p.ink2),
                              ),
                            ),
                            Icon(
                              LucideIcons.chevronRight,
                              size: 16,
                              color: p.ink3,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      );
    }
    return ListView.builder(
      physics: physics,
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(S.x4, S.x2, S.x4, S.x4),
      itemCount: _items.length + (_status == null ? 0 : 1),
      itemBuilder: (_, i) => i == _items.length
          ? _CoachPendingReply(
              key: const ValueKey('coach-pending-reply'),
              label: _statusText(l),
              active: widget.presented && _page == _CoachPage.chat,
              awaitingConfirmation: _status == 'confirmation',
            )
          : _Bubble(
              item: _items[i],
              onRemember: _items[i].kind == CoachItemKind.user
                  ? () => _remember(_items[i].text ?? '')
                  : null,
            ),
    );
  }

  Future<void> _remember(String text) async {
    final engine = _engine, l = AppLocalizations.of(context)!;
    if (engine == null) return;
    final store = await engine.store;
    final prefs = await store.preferences();
    if (!mounted) return;
    if (!prefs.memoryEnabled) {
      _showPage(_CoachPage.preferences);
      return;
    }
    final ok = await _confirm(
      ActionRequest(
        tool: 'remember_preference',
        title: l.coachMemoryConfirm,
        summary: text,
        args: {'text': text},
      ),
    );
    if (!ok) return;
    try {
      await store.saveMemory(text);
      await engine.reloadPreferences();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.coachStorageError)));
      }
    }
  }

  Widget _composer(BuildContext c, P p) {
    final l = AppLocalizations.of(c)!;
    return Padding(
      // The route Scaffold or embedded host owns the keyboard inset once.
      padding: const EdgeInsets.fromLTRB(S.x4, S.x3, S.x4, S.x4),
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: _input,
        builder: (c, value, _) {
          final canSend =
              !_changingChat &&
              !_busy &&
              widget.presented &&
              _page == _CoachPage.chat &&
              _engine != null &&
              value.text.trim().isNotEmpty;
          final canStop =
              !_changingChat &&
              _busy &&
              widget.presented &&
              _page == _CoachPage.chat;
          return Container(
            key: const ValueKey('coach-composer'),
            padding: const EdgeInsets.fromLTRB(S.x3, S.x1, S.x1, S.x1),
            decoration: BoxDecoration(
              color: p.bg,
              borderRadius: R.rXxl,
              border: Border.all(color: p.line),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Semantics(
                    label: l.coachAskLabel,
                    textField: true,
                    child: TextField(
                      key: const ValueKey('coach-composer-input'),
                      controller: _input,
                      focusNode: _inputFocus,
                      minLines: 1,
                      maxLines: bigText(c) ? 1 : 4,
                      enabled:
                          !_changingChat &&
                          widget.presented &&
                          _page == _CoachPage.chat,
                      style: F.body.copyWith(color: p.ink),
                      textAlignVertical: TextAlignVertical.center,
                      cursorColor: p.on(kCoachAccent),
                      textInputAction: TextInputAction.send,
                      onSubmitted: _busy ? null : _send,
                      decoration: InputDecoration(
                        filled: false,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: S.x1,
                          vertical: S.x3,
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        hintText: l.coachInputHint,
                        hintMaxLines: 1,
                        hintStyle: F.body.copyWith(color: p.ink3),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: S.x1),
                Semantics(
                  button: true,
                  enabled: canSend || canStop,
                  child: Pressable(
                    key: const ValueKey('coach-composer-send'),
                    semanticLabel: _busy ? l.coachStop : l.coachSendLabel,
                    onTap: canStop
                        ? _stop
                        : canSend
                        ? () => _send(_input.text)
                        : null,
                    child: AnimatedContainer(
                      duration: motion(c, Motion.base),
                      curve: Motion.effectsCurve(c),
                      width: S.tap,
                      height: S.tap,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: canSend || canStop
                            ? p.fill(kCoachAccent)
                            : p.card2,
                      ),
                      child: Icon(
                        _busy ? LucideIcons.square : LucideIcons.arrowUp,
                        size: S.x5,
                        color: canSend || canStop ? p.inkOnFill : p.ink3,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Status occupies the next assistant turn, rather than the composer. Only
/// this small subtree animates; it stops when hidden or reduced motion is on.
class _CoachPendingReply extends StatelessWidget {
  const _CoachPendingReply({
    super.key,
    required this.label,
    required this.active,
    required this.awaitingConfirmation,
  });
  final String label;
  final bool active, awaitingConfirmation;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final animated =
        active && Motion.enabled(c) && TickerMode.valuesOf(c).enabled;
    return Semantics(
      container: true,
      liveRegion: true,
      label: label,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.only(bottom: S.x4),
          child: Row(
            children: [
              if (awaitingConfirmation)
                SizedBox.square(
                  dimension: S.x12,
                  child: Icon(
                    LucideIcons.shieldCheck,
                    color: p.on(kCoachAccent),
                  ),
                )
              else if (animated)
                RepeatingAnimationBuilder<double>(
                  animatable: Tween(begin: 0.0, end: 1.0),
                  duration: motion(c, Motion.loadingCycle),
                  builder: (_, phase, _) =>
                      ExpressiveLoadingIndicator(phase: phase),
                )
              else
                const ExpressiveLoadingIndicator(),
              const SizedBox(width: S.x2),
              Expanded(
                child: Text(label, style: F.cap.copyWith(color: p.ink3)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fade through related Coach views inside the existing panel. The transcript
/// stays mounted; temporary forms are released only after their exit finishes.
class _CoachPagePane extends StatefulWidget {
  const _CoachPagePane({
    super.key,
    required this.active,
    required this.child,
    this.retain = false,
    this.quickExit = false,
  });
  final bool active, retain, quickExit;
  final Widget child;

  @override
  State<_CoachPagePane> createState() => _CoachPagePaneState();
}

class _CoachPagePaneState extends State<_CoachPagePane>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _fade, _grow;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      value: widget.active ? 1 : 0,
      duration: Motion.spatialFast,
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.linear);
    _grow = CurvedAnimation(parent: _controller, curve: Curves.linear);
    _scale = Tween<double>(begin: .975, end: 1).animate(_grow);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _configureMotion();
    if (!Motion.enabled(context)) _controller.value = widget.active ? 1 : 0;
  }

  void _configureMotion() {
    _controller.duration = motion(
      context,
      widget.quickExit && !widget.active ? Motion.fast : Motion.spatialFast,
    );
    _fade.curve = Interval(.25, 1, curve: Motion.effectsCurve(context));
    _fade.reverseCurve = widget.quickExit
        ? Motion.effectsCurve(context)
        : Interval(.75, 1, curve: Motion.effectsCurve(context));
    _grow.curve = Motion.spatialCurve(context);
  }

  @override
  void didUpdateWidget(_CoachPagePane oldWidget) {
    super.didUpdateWidget(oldWidget);
    _configureMotion();
    if (oldWidget.active == widget.active) return;
    if (!Motion.enabled(context)) {
      _controller.value = widget.active ? 1 : 0;
    } else if (widget.active) {
      _controller.forward(from: widget.retain ? null : 0);
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _fade.dispose();
    _grow.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) => AnimatedBuilder(
    animation: _controller,
    child: widget.child,
    builder: (c, child) {
      final hidden = !widget.active && _controller.isDismissed;
      if (hidden && !widget.retain) return const SizedBox.shrink();
      return Offstage(
        offstage: hidden,
        child: IgnorePointer(
          ignoring: !widget.active,
          child: ExcludeFocus(
            excluding: !widget.active,
            child: ExcludeSemantics(
              excluding: !widget.active,
              child: TickerMode(
                enabled: widget.active,
                child: FadeTransition(
                  opacity: _fade,
                  child: ScaleTransition(
                    scale: _scale,
                    alignment: Alignment.topCenter,
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// One transcript entry. The user's turn is a soft bubble; the answer is the
/// page (no card chrome — a card around every answer makes a chat read as a
/// feed); figures keep their own frame.
class _Bubble extends StatelessWidget {
  final CoachItem item;
  final VoidCallback? onRemember;
  const _Bubble({required this.item, this.onRemember});
  Future<void> _copy(BuildContext c) async {
    await Clipboard.setData(ClipboardData(text: item.text ?? ''));
    if (c.mounted) {
      ScaffoldMessenger.of(c).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(c)!.coachCopied)),
      );
    }
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    switch (item.kind) {
      case CoachItemKind.user:
        return Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.only(bottom: S.x5, left: S.x8),
            padding: const EdgeInsets.symmetric(
              horizontal: S.x4,
              vertical: S.x3,
            ),
            decoration: BoxDecoration(
              color: p.card2,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(R.xl),
                topRight: Radius.circular(R.xl),
                bottomLeft: Radius.circular(R.xl),
                bottomRight: Radius.circular(R.sm),
              ),
            ),
            child: SelectableText(
              item.text ?? '',
              style: F.body.copyWith(color: p.ink, height: 1.5),
              contextMenuBuilder: (c, editable) =>
                  AdaptiveTextSelectionToolbar.buttonItems(
                    anchors: editable.contextMenuAnchors,
                    buttonItems: [
                      ...editable.contextMenuButtonItems,
                      if (onRemember != null)
                        ContextMenuButtonItem(
                          label: AppLocalizations.of(c)!.coachRememberThis,
                          onPressed: () {
                            editable.hideToolbar();
                            onRemember!();
                          },
                        ),
                    ],
                  ),
            ),
          ),
        );
      case CoachItemKind.assistant:
        return Padding(
          padding: const EdgeInsets.only(bottom: S.x4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GptMarkdown(
                item.text ?? '',
                style: F.body.copyWith(color: p.ink, height: 1.65),
              ),
              const SizedBox(height: S.x2),
              IconButton(
                tooltip: AppLocalizations.of(c)?.coachCopy ?? 'Copy',
                onPressed: () => _copy(c),
                icon: Icon(LucideIcons.copy, size: 16, color: p.ink3),
              ),
            ],
          ),
        );
      case CoachItemKind.chart:
        return Padding(
          padding: const EdgeInsets.only(bottom: S.x4),
          child: CoachFigure(spec: item.chart!.toJson()),
        );
      case CoachItemKind.render:
        return Padding(
          padding: const EdgeInsets.only(bottom: S.x4),
          child: CoachFigure(spec: item.render!),
        );
      case CoachItemKind.error:
        return Padding(
          padding: const EdgeInsets.only(bottom: S.x4),
          child: StatusCard(
            AppLocalizations.of(c)?.coachErrorTitle ??
                'That did not go through',
            item.text ?? '',
            icon: LucideIcons.triangleAlert,
          ),
        );
    }
  }
}

class _CoachChatMenu extends StatefulWidget {
  const _CoachChatMenu({
    super.key,
    required this.engine,
    required this.onOpen,
    required this.onNew,
    required this.onDeleted,
    required this.onPersonalize,
    required this.onBack,
    required this.onRenamed,
  });
  final CoachEngine? engine;
  final Future<void> Function(String) onOpen;
  final Future<void> Function() onNew;
  final VoidCallback onPersonalize, onDeleted, onBack, onRenamed;
  @override
  State<_CoachChatMenu> createState() => _CoachChatMenuState();
}

class _CoachChatMenuState extends State<_CoachChatMenu> {
  final _search = TextEditingController();
  Future<List<CoachSessionMeta>>? _future;
  Timer? _debounce;
  @override
  void initState() {
    super.initState();
    _reload();
    _search.addListener(() {
      _debounce?.cancel();
      _debounce = Timer(CoachStore.searchDebounce, () => setState(_reload));
    });
  }

  void _reload() {
    _future =
        widget.engine?.listSessions(search: _search.text) ?? Future.value([]);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _rename(CoachSessionMeta meta) async {
    final l = AppLocalizations.of(context)!;
    final input = TextEditingController(text: meta.title);
    final title = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(l.coachRenameChat),
        content: TextField(controller: input, maxLength: 120, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: Text(l.actionCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, input.text.trim()),
            child: Text(l.actionSave),
          ),
        ],
      ),
    );
    if (title == null || title.isEmpty) return;
    try {
      await widget.engine!.renameSession(meta.id, title);
      if (mounted) {
        setState(_reload);
        widget.onRenamed();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.coachStorageError)));
      }
    }
  }

  Future<void> _delete(CoachSessionMeta meta) async {
    final l = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(l.coachDeleteChat(meta.title)),
        content: Text(l.coachDeleteChatConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: Text(l.actionCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            child: Text(l.coachDeleteIt),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final open = widget.engine!.sessionId == meta.id;
    try {
      await widget.engine!.deleteSession(meta.id);
      if (mounted) {
        setState(_reload);
        if (open) {
          widget.onDeleted();
        }
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.coachStorageError)));
      }
    }
  }

  String _group(CoachSessionMeta meta, AppLocalizations l) {
    final now = DateTime.now();
    final day = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(meta.updatedAt));
    if (day == todayLabel()) return l.coachChatToday;
    if (day == dayLabelOf(DateTime(now.year, now.month, now.day - 1))) {
      return l.coachChatYesterday;
    }
    return prettyDay(day, l);
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c), l = AppLocalizations.of(c)!;
    return Column(
      children: [
        CoachPageTitle(
          l.coachYourChats,
          onBack: widget.onBack,
          trailing: Pressable(
            onTap: widget.onNew,
            semanticLabel: l.coachNewChat,
            child: Icon(LucideIcons.squarePen, size: S.x5, color: p.ink2),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(S.x5, S.x2, S.x5, S.x4),
          child: TextField(
            key: const ValueKey('coach-chat-search'),
            controller: _search,
            style: F.body.copyWith(color: p.ink),
            decoration: InputDecoration(
              hintText: l.coachSearchChats,
              prefixIcon: Icon(LucideIcons.search, size: S.x5, color: p.ink3),
              filled: true,
              fillColor: p.card2,
              contentPadding: const EdgeInsets.all(S.x4),
              border: const OutlineInputBorder(
                borderRadius: R.rPill,
                borderSide: BorderSide.none,
              ),
              enabledBorder: const OutlineInputBorder(
                borderRadius: R.rPill,
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        Expanded(
          child: FutureBuilder<List<CoachSessionMeta>>(
            future: _future,
            builder: (c, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return Center(child: Text(l.coachChatsLoading));
              }
              if (snap.hasError) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(l.coachChatsLoadError),
                      TextButton(
                        onPressed: () => setState(_reload),
                        child: Text(l.coachRetry),
                      ),
                    ],
                  ),
                );
              }
              final list = snap.data ?? [];
              if (list.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(S.x4),
                    child: Text(
                      _search.text.isEmpty
                          ? l.coachNoChatsYet
                          : l.coachSearchEmpty,
                      style: F.body.copyWith(color: p.ink3),
                    ),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(S.x5, 0, S.x5, S.x4),
                itemCount: list.length,
                itemBuilder: (c, i) {
                  final meta = list[i],
                      current = meta.id == widget.engine?.sessionId;
                  final group = _group(meta, l);
                  final updated = DateTime.fromMillisecondsSinceEpoch(
                    meta.updatedAt,
                  );
                  final time = MaterialLocalizations.of(c).formatTimeOfDay(
                    TimeOfDay.fromDateTime(updated),
                    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(
                      c,
                    ),
                  );
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (i == 0 || group != _group(list[i - 1], l))
                        Padding(
                          padding: const EdgeInsets.only(
                            top: S.x4,
                            bottom: S.x2,
                          ),
                          child: Text(
                            group,
                            style: F.cap.copyWith(
                              color: p.ink3,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      Container(
                        key: ValueKey('coach-chat-${meta.id}'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: S.x2,
                          vertical: S.x2,
                        ),
                        decoration: BoxDecoration(
                          color: current
                              ? Color.alphaBlend(p.wash(C.green), p.card)
                              : null,
                          borderRadius: R.rXl,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Pressable(
                                onTap: () => widget.onOpen(meta.id),
                                child: Row(
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.all(S.x2),
                                      child: Icon(
                                        LucideIcons.messageCircle,
                                        size: S.x5,
                                        color: p.on(C.green),
                                      ),
                                    ),
                                    const SizedBox(width: S.x1),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            meta.title.isEmpty
                                                ? l.coachUntitledChat
                                                : meta.title,
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: F.head.copyWith(
                                              color: p.ink,
                                            ),
                                          ),
                                          const SizedBox(height: S.x1),
                                          Text(
                                            current
                                                ? '$time · ${l.coachCurrentChat}'
                                                : time,
                                            style: F.cap.copyWith(
                                              color: p.ink3,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            PopupMenuButton<String>(
                              tooltip: l.coachMenuSemantic,
                              icon: Icon(
                                LucideIcons.ellipsis,
                                size: S.x5,
                                color: p.ink3,
                              ),
                              onSelected: (v) =>
                                  v == 'rename' ? _rename(meta) : _delete(meta),
                              itemBuilder: (_) => [
                                PopupMenuItem(
                                  value: 'rename',
                                  child: Text(l.coachRenameChat),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text(l.coachDeleteIt),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
        Container(
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: p.line)),
          ),
          padding: const EdgeInsets.all(S.x4),
          child: Pressable(
            onTap: widget.onPersonalize,
            child: Container(
              padding: const EdgeInsets.all(S.x3),
              decoration: BoxDecoration(color: p.bg, borderRadius: R.rXl),
              child: Row(
                children: [
                  Icon(
                    LucideIcons.slidersHorizontal,
                    size: S.x5,
                    color: p.on(C.green),
                  ),
                  const SizedBox(width: S.x3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.coachPersonalization,
                          style: F.head.copyWith(color: p.ink),
                        ),
                        const SizedBox(height: S.x1),
                        Text(
                          l.coachPersonalizationSub,
                          style: F.cap.copyWith(color: p.ink3),
                        ),
                      ],
                    ),
                  ),
                  Icon(LucideIcons.chevronRight, size: S.x5, color: p.ink3),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════ setup ═══════════════════════

/// A provider preset. Local ones come first and carry no key, because a model
/// running on the user's own machine is the only configuration where the health
/// data never leaves their control.
class _Preset {
  final String label, sub, baseUrl;
  final bool local;
  const _Preset(this.label, this.sub, this.baseUrl, {this.local = false});
}

List<_Preset> _presets(BuildContext c) {
  final local =
      AppLocalizations.of(c)?.coachLocalSub ??
      'On this network. Nothing leaves your machine.';
  return <_Preset>[
    _Preset('Ollama', local, 'http://localhost:11434/v1', local: true),
    _Preset('LM Studio', local, 'http://localhost:1234/v1', local: true),
    _Preset('OpenAI', 'api.openai.com', 'https://api.openai.com/v1'),
    _Preset('Anthropic', 'api.anthropic.com', 'https://api.anthropic.com/v1'),
    _Preset('OpenRouter', 'openrouter.ai', 'https://openrouter.ai/api/v1'),
  ];
}

class CoachSetup extends StatefulWidget {
  const CoachSetup({super.key});

  @override
  State<CoachSetup> createState() => _CoachSetupState();
}

class _CoachSetupState extends State<CoachSetup> {
  late final TextEditingController _base;
  late final TextEditingController _key;
  late final TextEditingController _search;
  late final TextEditingController _timeout;
  String _model = '';
  List<String> _models = const [];
  bool _loading = false;
  String? _msg;

  /// The origin whatever key is currently STORED (in the keychain, not just
  /// visible in [_key]) belongs to. Set at init and only ever advanced by
  /// [_onBaseChanged] or a successful [_save] — never by [_key] itself, so
  /// that clearing the field programmatically doesn't erase the record of an
  /// origin change still needing [_pendingKeyDelete] applied.
  late String _keyOrigin;

  /// True once the base URL has moved to a different origin than [_keyOrigin]
  /// and no replacement key has been typed since. [_save] must force-delete
  /// the stored key in this case rather than leaving it untouched — the
  /// field reading empty is NOT proof there is nothing to delete: a key that
  /// exists but could not be read (`CoachConfig.keyUnreadable`) also seeds
  /// [_key] empty, and without this flag that "empty" was indistinguishable
  /// from "no key ever existed", so the old, unreadable key survived the
  /// origin change and was later sent to the new endpoint.
  bool _pendingKeyDelete = false;

  @override
  void initState() {
    super.initState();
    final cfg = context.read<CoachConfig>();
    _base = TextEditingController(text: cfg.baseUrl);
    _key = TextEditingController(text: cfg.apiKey ?? '');
    _search = TextEditingController();
    _timeout = TextEditingController(text: cfg.timeoutSeconds.toString());
    _model = cfg.model;
    _keyOrigin = coachEndpointOrigin(cfg.baseUrl);
    // The base URL decides which preset is lit and whether a key is needed, and
    // the search box filters the list — both are read during build, so both
    // have to rebuild it.
    void redraw() {
      if (mounted) setState(() {});
    }

    _base.addListener(_onBaseChanged);
    // Deliberately NOT tracked via a _key listener: an early attempt cleared
    // _pendingKeyDelete as soon as the user typed a replacement, but typing
    // one and then erasing it left the flag cleared with nothing to show for
    // it — coachApiKeyToSave, called from _save with the CURRENT _key.text,
    // already derives "is there a real replacement right now" correctly by
    // checking the trimmed text itself; _pendingKeyDelete only needs to say
    // whether the endpoint changed, not track the field's history.
    _search.addListener(redraw);
  }

  /// Clears a carried-over key rather than letting Save silently send it to a
  /// DIFFERENT origin than the one it was typed for — switching presets, or
  /// editing the base URL to point somewhere else, must not reuse a cloud key
  /// against a new local/private endpoint (or vice versa) without the user
  /// re-entering it.
  void _onBaseChanged() {
    final origin = coachEndpointOrigin(_base.text);
    if (origin != _keyOrigin) {
      _keyOrigin = origin;
      _pendingKeyDelete = true;
      if (_key.text.isNotEmpty) _key.clear();
      _msg =
          AppLocalizations.of(context)?.coachEndpointKeyCleared ??
          'The API key was cleared because the endpoint changed.';
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _base.dispose();
    _key.dispose();
    _search.dispose();
    _timeout.dispose();
    super.dispose();
  }

  bool get _isLocal => isLocalCoachHost(_base.text.trim());

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _msg = null;
    });
    try {
      final ids = await CoachEngine.fetchModels(_base.text, _key.text);
      if (!mounted) return;
      final l = AppLocalizations.of(context);
      setState(() {
        _models = ids;
        _msg = ids.isEmpty
            ? (l?.coachNoModelsListed ??
                  'That endpoint listed no models. Type one below instead.')
            : (l?.coachModelsFound(ids.length) ??
                  '${ids.length} models. Tap one.');
      });
    } catch (e) {
      if (!mounted) return;
      final l = AppLocalizations.of(context);
      setState(
        () => _msg = e is CoachException
            ? e.message
            : (l?.coachEndpointUnreachable('$e') ??
                  'Could not reach that endpoint: $e'),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    final chosen = _model.isNotEmpty ? _model : _search.text.trim();
    final l = AppLocalizations.of(context);
    if (chosen.isEmpty) {
      setState(
        () => _msg = l?.coachPickModelFirst ?? 'Pick or type a model first.',
      );
      return;
    }
    final cfg = context.read<CoachConfig>();
    final nav = Navigator.of(context);
    // The field is hidden for a cloud endpoint (it has no effect there — see
    // CoachConfig.requestTimeout), so its stale text must not overwrite the
    // saved local timeout. Garbage or blank input for a local endpoint leaves
    // the existing timeout untouched (CoachConfig also rejects <=0) rather
    // than blocking the rest of the save over one bad field.
    final timeoutSeconds = _isLocal ? int.tryParse(_timeout.text.trim()) : null;
    try {
      await cfg.save(
        baseUrl: _base.text,
        apiKey: coachApiKeyToSave(
          keyText: _key.text,
          storedKeyReadable: cfg.apiKey != null,
          pendingKeyDelete: _pendingKeyDelete,
        ),
        model: chosen,
        timeoutSeconds: timeoutSeconds,
      );
    } catch (e) {
      if (mounted) {
        setState(
          () => _msg =
              l?.coachKeychainRefused('$e') ??
              'The keychain refused the key: $e',
        );
      }
      return;
    }
    _pendingKeyDelete = false;
    if (mounted && nav.canPop()) nav.pop();
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final q = _search.text.trim().toLowerCase();
    final shown = q.isEmpty
        ? _models
        : [
            for (final m in _models)
              if (m.toLowerCase().contains(q)) m,
          ];
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: S.x4),
              child: NavBar(
                l?.coachSetupNavTitle ?? 'AI settings',
                sub: l?.coachSetupNavSub ?? 'Bring your own model',
              ),
            ),
            Expanded(
              child: ListView(
                padding: pad,
                children: [
                  Surface(
                    onTap: () => go(c, const CoachPersonalization()),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l?.coachPersonalization ?? 'Personalization',
                                style: F.body.copyWith(color: p.ink),
                              ),
                              Text(
                                l?.coachPersonalizationSub ??
                                    'Focus, replies and what Coach remembers',
                                style: F.cap.copyWith(color: p.ink3),
                              ),
                            ],
                          ),
                        ),
                        Icon(LucideIcons.chevronRight, color: p.ink3),
                      ],
                    ),
                  ),
                  const SizedBox(height: S.x4),
                  Section(
                    l?.coachWhereModelRuns ?? 'Where the model runs',
                    Column(
                      children: [
                        for (final preset in _presets(c))
                          Padding(
                            padding: const EdgeInsets.only(bottom: S.x2),
                            child: Surface(
                              elevation: 0,
                              color: _base.text.trim() == preset.baseUrl
                                  ? p.wash(
                                      preset.local ? C.green : kCoachAccent,
                                    )
                                  : p.card2,
                              onTap: () => setState(() {
                                // BEFORE assigning _base.text: that assignment
                                // fires _onBaseChanged synchronously, which
                                // may set _msg to explain a cleared key —
                                // clearing _msg after it runs would silently
                                // discard that explanation.
                                _msg = null;
                                _base.text = preset.baseUrl;
                                _models = const [];
                                _model = '';
                              }),
                              child: Row(
                                children: [
                                  Icon(
                                    preset.local
                                        ? LucideIcons.house
                                        : LucideIcons.cloud,
                                    size: 17,
                                    color: p.on(
                                      preset.local ? C.green : kCoachAccent,
                                    ),
                                  ),
                                  const SizedBox(width: S.x3),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          preset.label,
                                          style: F.body.copyWith(
                                            color: p.ink,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        Text(
                                          preset.sub,
                                          style: F.cap.copyWith(color: p.ink3),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: S.x2),
                  OsTextField(
                    controller: _base,
                    label: l?.coachBaseUrlLabel ?? 'Base URL',
                    hint: 'http://localhost:11434/v1',
                  ),
                  const SizedBox(height: S.x4),
                  OsTextField(
                    controller: _key,
                    label: _isLocal
                        ? (l?.coachApiKeyLocalLabel ??
                              'API key (not needed locally)')
                        : (l?.coachApiKeyLabel ?? 'API key'),
                    hint: 'sk-…',
                  ),
                  const SizedBox(height: S.x3),
                  // The one sentence that decides whether a cloud key is a
                  // reasonable choice. It is here, next to the field, and not
                  // in a settings page nobody opens.
                  Text(
                    _isLocal
                        ? (l?.coachLocalDataNote ??
                              'Your questions and the rows the coach reads stay on '
                                  'your own machine.')
                        : (l?.coachCloudDataNote ??
                              'Your questions and the rows the coach reads are sent '
                                  'to this endpoint. See exactly what that is on '
                                  '"What was sent".'),
                    style: F.cap.copyWith(color: p.ink3, height: 1.5),
                  ),
                  const SizedBox(height: S.x4),
                  BigButton(
                    _loading
                        ? (l?.coachAsking ?? 'Asking…')
                        : (l?.coachListModels ?? 'List models'),
                    icon: LucideIcons.refreshCw,
                    color: kCoachAccent,
                    soft: true,
                    onTap: _loading ? null : _fetch,
                  ),
                  if (_msg != null) ...[
                    const SizedBox(height: S.x3),
                    Text(_msg!, style: F.cap.copyWith(color: p.ink3)),
                  ],
                  const SizedBox(height: S.x4),
                  OsTextField(
                    controller: _search,
                    label: l?.coachModelLabel ?? 'Model',
                    hint: l?.coachModelHint ?? 'search, or type an id',
                  ),
                  const SizedBox(height: S.x1),
                  Builder(
                    builder: (_) => Padding(
                      padding: const EdgeInsets.only(top: S.x2),
                      child: Column(
                        children: [
                          for (final m in shown.take(60))
                            Pressable(
                              onTap: () => setState(() => _model = m),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: S.x3,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      m == _model
                                          ? LucideIcons.circleCheck
                                          : LucideIcons.circle,
                                      size: 16,
                                      color: m == _model
                                          ? p.on(kCoachAccent)
                                          : p.ink3,
                                    ),
                                    const SizedBox(width: S.x3),
                                    Expanded(
                                      child: Text(
                                        m,
                                        style: F.cap.copyWith(color: p.ink),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (_isLocal) ...[
                    const SizedBox(height: S.x4),
                    OsTextField(
                      controller: _timeout,
                      label:
                          l?.coachRequestTimeoutLabel ??
                          'Request timeout (seconds)',
                      hint: '300',
                      keyboard: TextInputType.number,
                    ),
                    const SizedBox(height: S.x3),
                    Text(
                      l?.coachRequestTimeoutExplanation ??
                          'A local model can take a while to load before its first '
                              'reply. Default is 5 minutes (300s). Cloud providers use '
                              'a fixed 2-minute timeout and are not affected by this.',
                      style: F.cap.copyWith(color: p.ink3, height: 1.5),
                    ),
                  ],
                  const SizedBox(height: S.x4),
                  BigButton(
                    l?.actionSave ?? 'Save',
                    icon: LucideIcons.check,
                    color: kCoachAccent,
                    onTap: _save,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
