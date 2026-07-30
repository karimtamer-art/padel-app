import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'app_toast.dart';

/// A tap-to-copy control that animates its icon from "copy" to a green check for
/// ~1.6s as instant in-place feedback (and still fires the confirmation toast).
/// [label] null → icon only; set → a small labeled chip ("Copy" → "Copied").
class CopyIcon extends StatefulWidget {
  final String value;
  final String? label;
  final double size;
  final Color color;
  final bool toast;
  const CopyIcon(
    this.value, {
    super.key,
    this.label,
    this.size = 16,
    this.color = AppColors.inkSoft,
    this.toast = true,
  });

  @override
  State<CopyIcon> createState() => _CopyIconState();
}

class _CopyIconState extends State<CopyIcon> {
  bool _copied = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    var ok = true;
    try {
      await Clipboard.setData(ClipboardData(text: widget.value));
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    if (widget.toast) {
      AppToast.show(context, ok ? 'Copied' : "Couldn't copy — try again",
          kind: ok ? ToastKind.success : ToastKind.error);
    }
    if (!ok) return;
    setState(() => _copied = true);
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final icon = AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      transitionBuilder: (child, anim) =>
          ScaleTransition(scale: anim, child: FadeTransition(opacity: anim, child: child)),
      child: Icon(
        _copied ? Icons.check_rounded : Icons.copy_rounded,
        key: ValueKey(_copied),
        size: widget.size,
        color: _copied ? AppColors.success : widget.color,
      ),
    );

    if (widget.label == null) {
      return GestureDetector(
          behavior: HitTestBehavior.opaque, onTap: _copy, child: icon);
    }

    final tint = _copied ? AppColors.success : AppColors.primary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _copy,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
            color: tint.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(9)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          icon,
          const SizedBox(width: 6),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: Text(_copied ? 'Copied' : widget.label!,
                key: ValueKey(_copied),
                style: AppText.bodyStrong(tint).copyWith(fontSize: 12)),
          ),
        ]),
      ),
    );
  }
}
