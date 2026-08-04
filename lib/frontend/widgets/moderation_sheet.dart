import 'package:flutter/material.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/backend/services/moderation_service.dart';

/// Block + report, in one place so every surface that carries user content
/// offers the same thing: a DM, a community message, a match-ticket message,
/// a comment, a profile.
///
/// App Store Guideline 1.2 requires both on any app with user-generated
/// content, and a reviewer will go looking for them.
class ModerationSheet {
  ModerationSheet._();

  /// The "…" menu on a piece of content or a person.
  ///
  /// [targetType] is the report bucket; pass null for [targetId] when
  /// reporting a person rather than a specific message.
  static Future<void> show(
    BuildContext context, {
    required String userId,
    required String userName,
    String targetType = 'user',
    String? targetId,
    /// Called after a successful block so the caller can pop the screen or
    /// refresh a list — the blocked person's content is gone by then.
    VoidCallback? onBlocked,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetCtx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
                color: AppColors.line, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(height: 14),
          ListTile(
            leading: const Icon(Icons.flag_outlined, color: AppColors.warn),
            title: Text(targetId == null ? 'Report $userName' : 'Report this message',
                style: AppText.bodyStrong()),
            subtitle: Text('Sends it to our team to review',
                style: AppText.small(AppColors.inkFaint)),
            onTap: () {
              Navigator.pop(sheetCtx);
              _report(context,
                  userId: userId,
                  userName: userName,
                  targetType: targetType,
                  targetId: targetId);
            },
          ),
          ListTile(
            leading: const Icon(Icons.block_rounded, color: AppColors.danger),
            title: Text('Block $userName', style: AppText.bodyStrong(AppColors.danger)),
            subtitle: Text("You won't see each other's messages",
                style: AppText.small(AppColors.inkFaint)),
            onTap: () {
              Navigator.pop(sheetCtx);
              _confirmBlock(context,
                  userId: userId, userName: userName, onBlocked: onBlocked);
            },
          ),
          const SizedBox(height: 10),
        ]),
      ),
    );
  }

  // ── report ──────────────────────────────────────────────────────────────

  static Future<void> _report(
    BuildContext context, {
    required String userId,
    required String userName,
    required String targetType,
    String? targetId,
  }) async {
    ReportReason? picked;
    final noteC = TextEditingController();
    final sent = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheet) => Padding(
          padding:
              EdgeInsets.only(bottom: MediaQuery.of(sheetCtx).viewInsets.bottom),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 26),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(targetId == null ? 'Report $userName' : 'Report this message',
                    style: AppText.cardTitle().copyWith(fontSize: 17)),
                const SizedBox(height: 4),
                Text("Tell us what's wrong. Our team reviews every report.",
                    style: AppText.small()),
                const SizedBox(height: 16),
                for (final r in ReportReason.all)
                  GestureDetector(
                    onTap: () => setSheet(() => picked = r),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(13),
                      decoration: BoxDecoration(
                        color: picked == r
                            ? AppColors.wash(AppColors.primary)
                            : AppColors.field,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: picked == r ? AppColors.primary : AppColors.line,
                            width: 1.5),
                      ),
                      child: Row(children: [
                        Icon(
                            picked == r
                                ? Icons.radio_button_checked_rounded
                                : Icons.radio_button_unchecked_rounded,
                            size: 19,
                            color: picked == r
                                ? AppColors.primary
                                : AppColors.inkFaint),
                        const SizedBox(width: 11),
                        Expanded(
                            child: Text(r.label, style: AppText.bodyStrong())),
                      ]),
                    ),
                  ),
                const SizedBox(height: 6),
                Text('ANYTHING ELSE? (OPTIONAL)', style: AppText.kicker()),
                const SizedBox(height: 7),
                TextField(
                  controller: noteC,
                  maxLines: 3,
                  style: AppText.body(),
                  decoration: InputDecoration(
                    hintText: 'Add any detail that helps us understand…',
                    hintStyle: AppText.body(AppColors.inkFaint).copyWith(fontSize: 13),
                    isDense: true,
                    filled: true,
                    fillColor: AppColors.field,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: AppColors.line)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                            color: AppColors.primary, width: 1.6)),
                  ),
                ),
                const SizedBox(height: 16),
                AppButton('Send report',
                    full: true,
                    height: 50,
                    icon: Icons.flag_outlined,
                    onPressed: picked == null
                        ? null
                        : () => Navigator.pop(sheetCtx, true)),
              ],
            ),
          ),
        ),
      ),
    );

    final reason = picked;
    if (sent != true || reason == null) {
      noteC.dispose();
      return;
    }
    final err = await ModerationService.report(
      targetType: targetType,
      targetId: targetId,
      reason: reason.code,
      note: noteC.text,
      targetUserId: userId,
    );
    noteC.dispose();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: err == null ? AppColors.success : AppColors.danger,
      content: Text(err ??
          "Thanks — our team will review this. You can block $userName too if you'd rather not hear from them."),
    ));
  }

  // ── block ───────────────────────────────────────────────────────────────

  static Future<void> _confirmBlock(
    BuildContext context, {
    required String userId,
    required String userName,
    VoidCallback? onBlocked,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Block $userName?', style: AppText.cardTitle()),
        content: Text(
          "You won't see each other's messages anywhere in the app, and they "
          "can't start a new chat with you. They aren't told.\n\n"
          "If you're already in a match together you'll still see them in the "
          "line-up — you can undo this any time in Privacy settings.",
          style: AppText.body(AppColors.inkSoft).copyWith(height: 1.45),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dCtx, false),
              child: Text('Cancel', style: AppText.bodyStrong(AppColors.inkSoft))),
          TextButton(
              onPressed: () => Navigator.pop(dCtx, true),
              child: Text('Block', style: AppText.bodyStrong(AppColors.danger))),
        ],
      ),
    );
    if (ok != true) return;

    final err = await ModerationService.block(userId);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: err == null ? AppColors.success : AppColors.danger,
      content: Text(err ?? '$userName blocked.'),
    ));
    if (err == null) onBlocked?.call();
  }
}
