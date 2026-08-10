import 'package:flutter/material.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/frontend/widgets/screen_bar.dart';
import 'package:padel_clay/backend/services/profile_service.dart';

/// Everyone the player has swapped numbers with, and a way back out.
///
/// A swap is one row for the pair, so stopping it cuts both ways — you lose
/// their number as well. That's the honest shape of it, and the dialog says so
/// rather than implying you can quietly take yours back.
class SharedNumbersScreen extends StatefulWidget {
  const SharedNumbersScreen({super.key});
  @override
  State<SharedNumbersScreen> createState() => _SharedNumbersScreenState();
}

class _SharedNumbersScreenState extends State<SharedNumbersScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await ProfileService.myContactShares();
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _loading = false;
    });
  }

  Future<void> _revoke(Map<String, dynamic> r) async {
    final name = _nameOf(r);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Stop sharing with $name?', style: AppText.cardTitle()),
        content: Text(
            "They won't see your number any more, and you won't see theirs. "
            'Either of you can ask again in a future match.',
            style: AppText.body(AppColors.inkSoft).copyWith(height: 1.45)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dCtx, false),
              child:
                  Text('Cancel', style: AppText.bodyStrong(AppColors.inkSoft))),
          TextButton(
              onPressed: () => Navigator.pop(dCtx, true),
              child: Text('Stop sharing',
                  style: AppText.bodyStrong(AppColors.danger))),
        ],
      ),
    );
    if (ok != true) return;
    final err = await ProfileService.revokeContactShare(r['player_id'] as String);
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
          content: Text('No longer sharing with $name.')));
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
        ScreenBar(title: 'Shared with', onBack: () => Navigator.pop(context)),
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
              AppAvatar(_initials(name), size: 42, color: AppColors.gold),
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
              AppButton('Stop',
                  height: 34,
                  variant: AppBtnVariant.outline,
                  onPressed: () => _revoke(r)),
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
              const Icon(Icons.contact_phone_outlined,
                  size: 44, color: AppColors.inkFaint),
              const SizedBox(height: 14),
              Text("You haven't shared your number",
                  style: AppText.bodyStrong(AppColors.inkSoft)),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 44),
                child: Text(
                    'In a match ticket you can ask a player for their number. '
                    'If they accept, you both get each other\'s — and they show '
                    'up here.',
                    textAlign: TextAlign.center,
                    style: AppText.small(AppColors.inkFaint)),
              ),
            ]),
          ),
        ],
      );
}
