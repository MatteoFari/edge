// The shared action entry for Workout and Wellness. The count is what the
// destination offers; the optional subline describes a recorded session.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../l10n/app_localizations.dart';
import '../ui2.dart';

class StartCard extends StatelessWidget {
  const StartCard({
    super.key,
    required this.label,
    required this.count,
    required this.noun,
    required this.icon,
    required this.actionLabel,
    required this.accent,
    this.sub,
    this.onTap,
    this.onNavigate,
  });

  final String label;

  /// The options actually available behind the tap, never a progress metric.
  final int count;
  final String noun;
  final IconData icon;
  final String actionLabel;
  final Color accent;
  final String? sub;
  final VoidCallback? onTap;
  final Future<void> Function(DetailOpener)? onNavigate;

  @override
  Widget build(BuildContext c) {
    final p = P.of(c);
    final l = AppLocalizations.of(c);
    final subText = sub ?? (l?.startCardDefaultSub ?? 'Pick one and go');
    return Surface(
      onTap: onTap,
      onNavigate: onNavigate,
      semanticLabel: '$label. $count $noun. $subText. $actionLabel',
      color: p.card2,
      elevation: 0,
      pad: const EdgeInsets.all(S.x5),
      // One card, one accessible action, including its visible button affordance.
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: F.over.copyWith(color: p.on(accent))),
                      const SizedBox(height: S.x2),
                      Text('$count $noun', style: F.t2.copyWith(color: p.ink)),
                    ],
                  ),
                ),
                const SizedBox(width: S.x3),
                Container(
                  width: S.x12,
                  height: S.x12,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: p.wash(accent),
                    borderRadius: R.rXl,
                  ),
                  child: Icon(icon, size: S.x6, color: p.on(accent)),
                ),
              ],
            ),
            const SizedBox(height: S.x2),
            Text(subText, style: F.cap.copyWith(color: p.ink3)),
            const SizedBox(height: S.x4),
            Container(
              constraints: const BoxConstraints(minHeight: S.tap),
              padding: const EdgeInsets.symmetric(
                horizontal: S.x4,
                vertical: S.x3,
              ),
              decoration: BoxDecoration(
                color: p.fill(accent),
                borderRadius: R.rPill,
              ),
              child: Row(
                children: [
                  Icon(LucideIcons.play, size: S.x5, color: p.inkOnFill),
                  const SizedBox(width: S.x2),
                  Expanded(
                    child: Text(
                      actionLabel,
                      style: F.head.copyWith(color: p.inkOnFill),
                    ),
                  ),
                  const SizedBox(width: S.x2),
                  Icon(LucideIcons.arrowRight, size: S.x5, color: p.inkOnFill),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
