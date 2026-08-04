import 'package:flutter/material.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/frontend/widgets/screen_bar.dart';
import 'package:padel_clay/backend/services/moderation_service.dart';

/// Everyone the player has blocked, with a way back out.
///
/// A block has to be undoable and the list has to be findable — otherwise
/// people block someone by accident and have no way to recover it.
class BlockedPlayersScreen extends StatefulWidget {
  const BlockedPlayersScreen({super.key});
  @override
  State<BlockedPlayersScreen> createState() => _BlockedPlayersScreenState();
}

class _BlockedPlayersScreenState extends State<BlockedPlayersScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await ModerationService.blockedUsers();
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  Future<void> _unblock(Map<String, dynamic> r) async {
    final name = _nameOf(r);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Unblock $name?', style: AppText.cardTitle()),
        content: Text(
            "You'll see each other's messages again and they'll be able to "
            'start a new chat with you.',
            style: AppText.body(AppColors.inkSoft).copyWith(height: 1.45)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dCtx, false),
              child: Text('Cancel',
                  style: AppText.bodyStrong(AppColors.inkSoft))),
          TextButton(
              onPressed: () => Navigator.pop(dCtx, true),
              child: Text('Unblock',
                  style: AppText.bodyStrong(AppColors.primary))),
        ],
      ),
    );
    if (ok != true) return;
    final err = await ModerationService.unblock(r['player_id'] as String);
    if (!mounted) return;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.danger,
          content: Text(err)));
      return;
    }
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('$name unblocked.')));
    }
  }

  static String _nameOf(Map<String, dynamic> r) {
    final n = (r['name'] as String?)?.trim();
    return (n == null || n.isEmpty) ? 'Player' : n;
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'))
      ..removeWhere((s) => s.isEmpty);
    if (parts.isEmpty) return 'P';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts[1].substring(0, 1))
        .toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(children: [
        ScreenBar(
            title: 'Blocked Players', onBack: () => Navigator.pop(context)),
        Expanded(
          child: _loading
              ? const Center(
                  child: CircularProgressIndicator(color: AppColors.primary))
              : RefreshIndicator(
                  color: AppColors.primary,
                  onRefresh: _load,
                  child: _rows.isEmpty ? _empty() : _list(),
                ),
        ),
      ]),
    );
  }

  Widget _list() => ListView.separated(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.screen, 14, AppSpacing.screen, 40),
        itemCount: _rows.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) {
          final r = _rows[i];
          final name = _nameOf(r);
          final username = (r['username'] as String?)?.trim() ?? '';
          return AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              AppAvatar(_initials(name), size: 42, color: AppColors.inkFaint),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.bodyStrong().copyWith(fontSize: 14.5)),
                      if (username.isNotEmpty)
                        Text('@$username',
                            style: AppText.small(AppColors.inkFaint)
                                .copyWith(fontSize: 12)),
                    ]),
              ),
              const SizedBox(width: 8),
              AppButton('Unblock',
                  height: 34,
                  variant: AppBtnVariant.outline,
                  onPressed: () => _unblock(r)),
            ]),
          );
        },
      );

  Widget _empty() => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.2),
          Center(
            child: Column(children: [
              const Icon(Icons.block_rounded,
                  size: 44, color: AppColors.inkFaint),
              const SizedBox(height: 14),
              Text("You haven't blocked anyone",
                  style: AppText.bodyStrong(AppColors.inkSoft)),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 44),
                child: Text(
                    'Blocking someone hides their messages from you '
                    'everywhere in the app. You can do it from any chat or '
                    'from their player card.',
                    textAlign: TextAlign.center,
                    style: AppText.small(AppColors.inkFaint)),
              ),
            ]),
          ),
        ],
      );
}
