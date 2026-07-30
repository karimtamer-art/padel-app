import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../theme/app_spacing.dart';

enum ToastKind { success, error, info, undo }

/// One toast system for every transient confirmation. A pill slides up from the
/// bottom, sits ~3s, then slides out. Stacks multiple toasts vertically.
///
///   AppToast.show(context, 'Match joined');
///   AppToast.show(context, 'Payment failed', kind: ToastKind.error);
///   AppToast.show(context, 'Removed', kind: ToastKind.undo,
///       actionLabel: 'Undo', onAction: () => restore());
class AppToast {
  AppToast._();

  static OverlayEntry? _entry;
  static final GlobalKey<_ToastStackState> _key =
      GlobalKey<_ToastStackState>();

  static void show(
    BuildContext context,
    String message, {
    ToastKind kind = ToastKind.success,
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 3),
  }) {
    final overlay = Overlay.of(context, rootOverlay: true);
    if (_entry == null) {
      _entry = OverlayEntry(builder: (_) => _ToastStack(key: _key));
      overlay.insert(_entry!);
    }
    final data = _ToastData(
      id: DateTime.now().microsecondsSinceEpoch,
      message: message,
      kind: kind,
      actionLabel: actionLabel,
      onAction: onAction,
      duration: duration,
    );
    final state = _key.currentState;
    if (state != null) {
      // Stack already mounted — add now; its setState schedules a frame so the
      // pill shows immediately (don't wait on a post-frame callback, which
      // doesn't schedule a frame on its own and would linger until the next
      // scroll/tap forces one).
      state.add(data);
    } else {
      // First toast this session — the stack mounts next frame; add then, and
      // force that frame so it isn't delayed until some later repaint.
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _key.currentState?.add(data));
      WidgetsBinding.instance.scheduleFrame();
    }
  }
}

class _ToastData {
  final int id;
  final String message;
  final ToastKind kind;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Duration duration;
  _ToastData({
    required this.id,
    required this.message,
    required this.kind,
    required this.duration,
    this.actionLabel,
    this.onAction,
  });
}

class _ToastStack extends StatefulWidget {
  const _ToastStack({super.key});
  @override
  State<_ToastStack> createState() => _ToastStackState();
}

class _ToastStackState extends State<_ToastStack> {
  // At most this many pills are ever on screen at once; older ones are dropped
  // so rapid taps can never bury the screen.
  static const int _maxVisible = 3;

  final List<_ToastData> _items = [];
  final Map<int, Timer> _timers = {};

  void add(_ToastData d) {
    // Coalesce: an identical message already showing just refreshes its timer
    // instead of stacking a duplicate (spamming "Copied" stays a single pill).
    final existing = _items
        .where((e) => e.message == d.message && e.kind == d.kind)
        .toList();
    if (existing.isNotEmpty) {
      for (final e in existing) {
        _timers.remove(e.id)?.cancel();
        _timers[e.id] = Timer(e.duration, () => remove(e.id));
      }
      return;
    }
    setState(() {
      _items.add(d);
      // Cap the stack — drop the oldest pills beyond the limit.
      while (_items.length > _maxVisible) {
        final dropped = _items.removeAt(0);
        _timers.remove(dropped.id)?.cancel();
      }
    });
    _timers[d.id] = Timer(d.duration, () => remove(d.id));
  }

  void remove(int id) {
    _timers.remove(id)?.cancel();
    if (!mounted) return;
    setState(() => _items.removeWhere((e) => e.id == id));
  }

  @override
  void dispose() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom + 34;
    return Positioned(
      left: 0,
      right: 0,
      bottom: bottom,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final d in _items)
            _ToastPill(
              key: ValueKey(d.id),
              data: d,
              onClose: () => remove(d.id),
            ),
        ],
      ),
    );
  }
}

class _ToastPill extends StatefulWidget {
  final _ToastData data;
  final VoidCallback onClose;
  const _ToastPill({super.key, required this.data, required this.onClose});
  @override
  State<_ToastPill> createState() => _ToastPillState();
}

class _ToastPillState extends State<_ToastPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 400))
    ..forward();

  ({Color color, IconData icon}) get _style {
    switch (widget.data.kind) {
      case ToastKind.success:
        return (color: AppColors.success, icon: Icons.check_rounded);
      case ToastKind.error:
        return (color: AppColors.danger, icon: Icons.close_rounded);
      case ToastKind.info:
        return (color: AppColors.accent, icon: Icons.info_outline_rounded);
      case ToastKind.undo:
        return (color: AppColors.warn, icon: Icons.undo_rounded);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _style;
    final curved = CurvedAnimation(parent: _c, curve: Curves.easeOutBack);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: FadeTransition(
        opacity: _c,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.4), end: Offset.zero)
              .animate(curved),
          child: Container(
            constraints: const BoxConstraints(minWidth: 280, maxWidth: 360),
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
            decoration: BoxDecoration(
              color: AppColors.hero,
              borderRadius: BorderRadius.circular(14),
              boxShadow: kPopShadow,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration:
                      BoxDecoration(color: s.color, shape: BoxShape.circle),
                  child: Icon(s.icon, size: 15, color: Colors.white),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(widget.data.message,
                      style: AppText.body(AppColors.heroInk)
                          .copyWith(fontWeight: FontWeight.w600)),
                ),
                if (widget.data.actionLabel != null) ...[
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: () {
                      widget.data.onAction?.call();
                      widget.onClose();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(widget.data.actionLabel!,
                          style: AppText.small(AppColors.heroInk)
                              .copyWith(fontWeight: FontWeight.w800)),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
