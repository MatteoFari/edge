import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../coach/coach_store.dart';
import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../ui2.dart';

/// The same quiet Coach identity is used by the panel and its settings routes.
class CoachSurfaceHeader extends StatelessWidget {
  const CoachSurfaceHeader({
    super.key,
    required this.subtitle,
    this.onMenu,
    this.onNew,
    this.onExpand,
    this.onClose,
    this.expanded = false,
  });
  final String subtitle;
  final VoidCallback? onMenu, onNew, onExpand, onClose;
  final bool expanded;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c), l = AppLocalizations.of(c)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(S.x4, S.x2, S.x3, S.x2),
      child: Row(
        children: [
          ExcludeSemantics(
            child: Container(
              width: S.x10,
              height: S.x10,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: p.fill(C.coach),
                shape: BoxShape.circle,
              ),
              child: brandGlyph(kEdgeMarkAsset, size: S.x6)(p.inkOnFill),
            ),
          ),
          const SizedBox(width: S.x3),
          Expanded(
            child: Pressable(
              key: const ValueKey('coach-menu'),
              onTap: onMenu,
              semanticLabel: onMenu == null ? null : l.coachMenuSemantic,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            l.coachNavTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: F.head.copyWith(color: p.ink),
                          ),
                        ),
                        if (onMenu != null) ...[
                          const SizedBox(width: S.x1),
                          Icon(
                            LucideIcons.chevronDown,
                            size: S.x4,
                            color: p.ink3,
                          ),
                        ],
                      ],
                    ),
                    AnimatedSwitcher(
                      key: const ValueKey('coach-active-title'),
                      duration: motion(c, Motion.base),
                      switchInCurve: Motion.effectsCurve(c),
                      switchOutCurve: Motion.effectsCurve(c),
                      layoutBuilder: (current, previous) => Stack(
                        alignment: Alignment.centerLeft,
                        children: [...previous, ?current],
                      ),
                      child: Text(
                        subtitle,
                        key: ValueKey(subtitle),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: F.cap.copyWith(color: p.ink3),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (onNew != null)
            Pressable(
              key: const ValueKey('coach-new-chat'),
              onTap: onNew,
              semanticLabel: l.coachNewChat,
              child: Icon(LucideIcons.squarePen, size: S.x5, color: p.ink2),
            ),
          if (onExpand != null)
            Pressable(
              key: const ValueKey('coach-panel-expand'),
              onTap: onExpand,
              semanticLabel: expanded ? l.coachCollapseView : l.coachExpandView,
              child: AnimatedRotation(
                turns: expanded ? .5 : 0,
                duration: motion(c, Motion.spatial),
                curve: Motion.spatialCurve(c),
                child: Icon(LucideIcons.chevronsUp, size: S.x5, color: p.ink2),
              ),
            ),
          if (onClose != null)
            Pressable(
              key: const ValueKey('coach-panel-close'),
              onTap: onClose,
              semanticLabel: l.coachCloseView,
              child: Icon(LucideIcons.x, size: S.x5, color: p.ink2),
            ),
        ],
      ),
    );
  }
}

class CoachPageTitle extends StatelessWidget {
  const CoachPageTitle(
    this.title, {
    super.key,
    required this.onBack,
    this.trailing,
  });
  final String title;
  final VoidCallback onBack;
  final Widget? trailing;
  @override
  Widget build(BuildContext c) {
    final p = P.of(c), l = AppLocalizations.of(c)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(S.x4, S.x3, S.x4, S.x4),
      child: Row(
        children: [
          Pressable(
            onTap: onBack,
            semanticLabel: l.actionBack,
            child: Icon(LucideIcons.arrowLeft, size: S.x5, color: p.ink3),
          ),
          const SizedBox(width: S.x2),
          Expanded(
            child: Text(
              title,
              style: (bigText(c) ? F.head : F.t2).copyWith(color: p.ink),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _CoachSaveActions extends StatelessWidget {
  const _CoachSaveActions({
    required this.label,
    required this.onSave,
    required this.onCancel,
  });
  final String label;
  final VoidCallback? onSave, onCancel;
  @override
  Widget build(BuildContext c) {
    final p = P.of(c), l = AppLocalizations.of(c)!;
    Widget button(
      String text,
      VoidCallback? tap, {
      bool primary = false,
    }) => Semantics(
      button: true,
      enabled: tap != null,
      child: Pressable(
        onTap: tap,
        semanticLabel: text,
        child: Container(
          constraints: const BoxConstraints(minHeight: S.tap),
          padding: const EdgeInsets.symmetric(horizontal: S.x4, vertical: S.x3),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: primary ? p.fill(C.coach) : p.card2,
            borderRadius: R.rPill,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (primary && !bigText(c)) ...[
                Icon(LucideIcons.check, size: S.x5, color: p.inkOnFill),
                const SizedBox(width: S.x2),
              ],
              Flexible(
                child: Text(
                  text,
                  textAlign: TextAlign.center,
                  style: F.body.copyWith(color: primary ? p.inkOnFill : p.ink),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(S.x4, S.x3, S.x4, S.x4),
      child: bigText(c)
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: double.infinity,
                  child: button(label, onSave, primary: true),
                ),
                const SizedBox(height: S.x2),
                SizedBox(
                  width: double.infinity,
                  child: button(l.actionCancel, onCancel),
                ),
              ],
            )
          : Row(
              children: [
                button(l.actionCancel, onCancel),
                const SizedBox(width: S.x2),
                Expanded(child: button(label, onSave, primary: true)),
              ],
            ),
    );
  }
}

class CoachPersonalization extends StatefulWidget {
  const CoachPersonalization({
    super.key,
    this.embedded = false,
    this.onBack,
    this.onSaved,
    this.onBackChanged,
  });
  final bool embedded;
  final VoidCallback? onBack, onSaved;

  /// Embedded hosts give Android Back to the instruction editor first.
  final ValueChanged<VoidCallback?>? onBackChanged;
  @override
  State<CoachPersonalization> createState() => _CoachPersonalizationState();
}

class _CoachPersonalizationState extends State<CoachPersonalization> {
  CoachStore? _store;
  CoachPreferences? _prefs;
  List<CoachMemory> _memories = [];
  bool _error = false, _saving = false, _editingInstructions = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    final owner = (context.read<AppState>().user?['id'] ?? 'local').toString();
    setState(() => _error = false);
    try {
      final st = await CoachStore.open(owner);
      final prefs = await st.preferences(), memories = await st.memories();
      if (mounted) {
        setState(() {
          _store = st;
          _prefs = prefs;
          _memories = memories;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  void _stage({String? focus, String? length, bool? memory}) {
    final old = _prefs!;
    setState(
      () => _prefs = CoachPreferences(
        focus: focus ?? old.focus,
        replyLength: length ?? old.replyLength,
        memoryEnabled: memory ?? old.memoryEnabled,
        customInstructions: old.customInstructions,
      ),
    );
  }

  Future<void> _save() async {
    if (_saving || _prefs == null) return;
    setState(() => _saving = true);
    try {
      final current = await _store!.preferences(), draft = _prefs!;
      await _store!.savePreferences(
        CoachPreferences(
          focus: draft.focus,
          replyLength: draft.replyLength,
          memoryEnabled: draft.memoryEnabled,
          customInstructions: current.customInstructions,
        ),
      );
      if (mounted) _finish(saved: true);
    } catch (_) {
      if (mounted) _failure();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _finish({bool saved = false}) {
    if (widget.embedded) {
      if (saved) {
        widget.onSaved?.call();
      } else {
        widget.onBack?.call();
      }
    } else {
      Navigator.maybePop(context);
    }
  }

  void _editInstructions(bool editing) {
    setState(() => _editingInstructions = editing);
    widget.onBackChanged?.call(editing ? () => _editInstructions(false) : null);
  }

  void _failure() => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(AppLocalizations.of(context)!.coachStorageError)),
  );

  Future<void> _reloadMemories() async {
    final memories = await _store!.memories();
    if (mounted) setState(() => _memories = memories);
  }

  Future<void> _editMemory([CoachMemory? memory]) async {
    final l = AppLocalizations.of(context)!;
    final input = TextEditingController(text: memory?.text);
    final value = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(memory == null ? l.coachMemoryAdd : l.coachMemoryEdit),
        content: TextField(
          controller: input,
          maxLength: 500,
          minLines: 2,
          maxLines: 5,
          decoration: InputDecoration(hintText: l.coachMemoryHint),
        ),
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
    // Dialog route finishes animating before its controller can be disposed.
    if (value == null || value.isEmpty || !mounted) return;
    try {
      await _store!.saveMemory(value, id: memory?.id);
      await _reloadMemories();
    } catch (_) {
      if (mounted) _failure();
    }
  }

  Future<void> _removeMemory(CoachMemory memory) async {
    final l = AppLocalizations.of(context)!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(l.coachMemoryRemove),
        content: Text(memory.text),
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
    try {
      await _store!.removeMemory(memory.id);
      await _reloadMemories();
    } catch (_) {
      if (mounted) _failure();
    }
  }

  Widget _choices(
    BuildContext c,
    String selected,
    Map<String, String> choices,
    ValueChanged<String> choose,
  ) {
    final p = P.of(c);
    return Wrap(
      spacing: S.x2,
      runSpacing: S.x2,
      children: [
        for (final choice in choices.entries)
          Semantics(
            selected: selected == choice.key,
            child: Pressable(
              key: ValueKey('coach-choice-${choice.key}'),
              onTap: _saving ? null : () => choose(choice.key),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: S.x3,
                  vertical: S.x3,
                ),
                decoration: BoxDecoration(
                  color: selected == choice.key ? p.wash(C.coach) : p.card,
                  borderRadius: R.rPill,
                  border: Border.all(
                    color: selected == choice.key ? p.on(C.coach) : p.line,
                  ),
                ),
                child: Text(
                  choice.value,
                  style: F.body.copyWith(
                    color: selected == choice.key ? p.on(C.coach) : p.ink,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c), l = AppLocalizations.of(c)!, prefs = _prefs;
    if (_editingInstructions && _store != null) {
      return CoachCustomInstructions(
        store: _store!,
        embedded: widget.embedded,
        onBack: () => _editInstructions(false),
      );
    }
    final body = Column(
      children: [
        if (!widget.embedded)
          CoachSurfaceHeader(
            subtitle: l.coachYourPreferences,
            onClose: _saving ? null : () => _finish(),
          ),
        CoachPageTitle(l.coachPersonalization, onBack: () => _finish()),
        Expanded(
          child: _error
              ? Center(
                  child: TextButton(
                    onPressed: _load,
                    child: Text(l.coachRetry),
                  ),
                )
              : prefs == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.fromLTRB(S.x5, S.x4, S.x5, S.x4),
                  children: [
                    Text(l.coachFocus, style: F.head.copyWith(color: p.ink)),
                    const SizedBox(height: S.x2),
                    _choices(c, prefs.focus, {
                      'general': l.coachFocusGeneral,
                      'sleep': l.coachFocusSleep,
                      'training': l.coachFocusTraining,
                      'recovery': l.coachFocusRecovery,
                    }, (v) => _stage(focus: v)),
                    const SizedBox(height: S.x5),
                    Text(
                      l.coachReplyLength,
                      style: F.head.copyWith(color: p.ink),
                    ),
                    const SizedBox(height: S.x2),
                    _choices(c, prefs.replyLength, {
                      'brief': l.coachReplyBrief,
                      'balanced': l.coachReplyBalanced,
                      'detailed': l.coachReplyDetailed,
                    }, (v) => _stage(length: v)),
                    const SizedBox(height: S.x5),
                    Text(l.coachMemory, style: F.head.copyWith(color: p.ink)),
                    const SizedBox(height: S.x2),
                    Container(
                      padding: const EdgeInsets.all(S.x3),
                      decoration: BoxDecoration(
                        color: p.bg,
                        borderRadius: R.rXl,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Checkbox(
                                value: prefs.memoryEnabled,
                                activeColor: p.fill(C.coach),
                                checkColor: p.inkOnFill,
                                onChanged: _saving
                                    ? null
                                    : (v) => _stage(memory: v),
                                semanticLabel: l.coachMemoryEnable,
                              ),
                              Expanded(
                                child: Pressable(
                                  onTap: _saving
                                      ? null
                                      : () => _stage(
                                          memory: !prefs.memoryEnabled,
                                        ),
                                  child: Text(
                                    l.coachMemoryEnable,
                                    style: F.body.copyWith(color: p.ink),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          Padding(
                            padding: const EdgeInsets.only(left: S.x12),
                            child: Text(
                              l.coachMemoryExplanation,
                              style: F.cap.copyWith(color: p.ink3),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: S.x5),
                    Text(l.coachAdvanced, style: F.head.copyWith(color: p.ink)),
                    const SizedBox(height: S.x2),
                    Pressable(
                      onTap: _saving ? null : () => _editInstructions(true),
                      child: Container(
                        padding: const EdgeInsets.all(S.x3),
                        decoration: BoxDecoration(
                          color: p.bg,
                          borderRadius: R.rXl,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    l.coachCustomInstructions,
                                    style: F.body.copyWith(color: p.ink),
                                  ),
                                  Text(
                                    l.coachCustomInstructionsSub,
                                    style: F.cap.copyWith(color: p.ink3),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              LucideIcons.chevronRight,
                              size: S.x5,
                              color: p.ink3,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: S.x5),
                    if (_memories.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: S.x2),
                        child: Text(
                          l.coachMemoryEmpty,
                          style: F.cap.copyWith(color: p.ink3),
                        ),
                      ),
                    for (final memory in _memories)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(memory.text),
                        onTap: () => _editMemory(memory),
                        trailing: IconButton(
                          tooltip: l.coachMemoryRemove,
                          onPressed: () => _removeMemory(memory),
                          icon: const Icon(LucideIcons.trash2),
                        ),
                      ),
                    TextButton.icon(
                      onPressed: () => _editMemory(),
                      icon: const Icon(LucideIcons.plus),
                      label: Text(l.coachMemoryAdd),
                    ),
                  ],
                ),
        ),
        if (prefs != null && !_error)
          _CoachSaveActions(
            label: l.coachSavePreferences,
            onSave: _saving ? null : _save,
            onCancel: _saving ? null : () => _finish(),
          ),
      ],
    );
    if (widget.embedded) return body;
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        backgroundColor: p.card,
        body: SafeArea(child: body),
      ),
    );
  }
}

class CoachCustomInstructions extends StatefulWidget {
  const CoachCustomInstructions({
    super.key,
    required this.store,
    this.embedded = false,
    this.onBack,
  });
  final CoachStore store;
  final bool embedded;
  final VoidCallback? onBack;
  @override
  State<CoachCustomInstructions> createState() =>
      _CoachCustomInstructionsState();
}

class _CoachCustomInstructionsState extends State<CoachCustomInstructions> {
  final _input = TextEditingController();
  CoachPreferences? _prefs;
  bool _saving = false, _error = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await widget.store.preferences();
      if (mounted) {
        setState(() {
          _error = false;
          _prefs = prefs;
          _input.text = prefs.customInstructions;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _back() {
    if (_saving) return;
    if (widget.onBack != null) {
      widget.onBack!();
    } else {
      Navigator.maybePop(context);
    }
  }

  Future<void> _save() async {
    if (_prefs == null || _saving) return;
    final l = AppLocalizations.of(context)!;
    setState(() => _saving = true);
    try {
      // The editor owns only instructions; retain any independently saved fields.
      final prefs = await widget.store.preferences();
      await widget.store.savePreferences(
        CoachPreferences(
          focus: prefs.focus,
          replyLength: prefs.replyLength,
          memoryEnabled: prefs.memoryEnabled,
          customInstructions: _input.text.trim(),
        ),
      );
      if (mounted) {
        if (widget.onBack != null) {
          widget.onBack!();
        } else {
          Navigator.maybePop(context);
        }
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.coachStorageError)));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    final p = P.of(c), l = AppLocalizations.of(c)!;
    final body = Column(
      children: [
        if (!widget.embedded)
          CoachSurfaceHeader(subtitle: l.coachYourPreferences, onClose: _back),
        CoachPageTitle(l.coachCustomInstructions, onBack: _back),
        Expanded(
          child: _error
              ? Center(
                  child: TextButton(
                    onPressed: _load,
                    child: Text(l.coachRetry),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(S.x5, S.x3, S.x5, S.x3),
                  children: [
                    Text(
                      l.coachCustomInstructionsHint,
                      style: F.body.copyWith(color: p.ink3),
                    ),
                    const SizedBox(height: S.x4),
                    Text(
                      l.coachYourInstructions,
                      style: F.body.copyWith(color: p.ink),
                    ),
                    const SizedBox(height: S.x2),
                    TextField(
                      key: const ValueKey('coach-custom-instructions'),
                      controller: _input,
                      maxLength: 2000,
                      maxLengthEnforcement: MaxLengthEnforcement.enforced,
                      minLines: bigText(c) ? 5 : 11,
                      maxLines: bigText(c) ? 8 : 16,
                      enabled: _prefs != null && !_saving,
                      style: F.body.copyWith(color: p.ink, height: 1.6),
                      decoration: InputDecoration(
                        hintText: l.coachCustomInstructionsHint,
                        filled: true,
                        fillColor: p.bg,
                        contentPadding: const EdgeInsets.all(S.x4),
                        border: OutlineInputBorder(
                          borderRadius: R.rXl,
                          borderSide: BorderSide(color: p.line),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: R.rXl,
                          borderSide: BorderSide(color: p.line),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: R.rXl,
                          borderSide: BorderSide(color: p.on(C.green)),
                        ),
                      ),
                    ),
                    const SizedBox(height: S.x3),
                    Text(
                      l.coachCustomInstructionsExplanation,
                      style: F.cap.copyWith(color: p.ink3),
                    ),
                  ],
                ),
        ),
        _CoachSaveActions(
          label: l.coachSaveInstructions,
          onSave: _prefs == null || _saving ? null : _save,
          onCancel: _saving ? null : _back,
        ),
      ],
    );
    if (widget.embedded) return body;
    return PopScope(
      canPop: !_saving && widget.onBack == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_saving) _back();
      },
      child: Scaffold(
        backgroundColor: p.card,
        body: SafeArea(child: body),
      ),
    );
  }
}
