import 'package:flutter/material.dart';
import 'package:padel_clay/backend/models/ranking_scale.dart' show RankingScale;
import 'package:padel_clay/backend/services/match_service.dart';
import 'package:padel_clay/frontend/theme/tournament_tokens.dart';
import 'package:padel_clay/frontend/widgets/tournament_kit.dart';

/// "Pick your partner". Pops with the chosen player's row, or null.
///
/// Picking only fills in the partner on the detail screen, the same as the old
/// inline picker did; `register_for_tournament` is what actually enters the pair.
///
/// Two parts of the design aren't built because the data doesn't exist:
///  * Friends / Looking for partner tabs: there is no friends list or partner
///    pool in the app (web "find a partner" solos live in `web_registrations`,
///    which players can't read). A tab with nothing behind it is a dead end.
///  * Search by phone: `searchPlayers` is @username only, and on purpose. Phone
///    numbers are asked for, never handed out (CLAUDE.md, 2026-08-10); a phone
///    search would let anyone test whose number is whose.
Future<Map<String, dynamic>?> showPartnerSheet(
  BuildContext context, {
  required int feePerPlayer,
  required VoidCallback onShareInvite,
}) =>
    showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: TColors.deepGreen.withValues(alpha: 0.85),
      builder: (_) => _PartnerSheet(
        feePerPlayer: feePerPlayer,
        onShareInvite: onShareInvite,
      ),
    );

class _PartnerSheet extends StatefulWidget {
  final int feePerPlayer;
  final VoidCallback onShareInvite;
  const _PartnerSheet({required this.feePerPlayer, required this.onShareInvite});

  @override
  State<_PartnerSheet> createState() => _PartnerSheetState();
}

class _PartnerSheetState extends State<_PartnerSheet> {
  final _search = TextEditingController();
  List<Map<String, dynamic>> _players = [];
  bool _loading = true;
  int _queryNo = 0;

  @override
  void initState() {
    super.initState();
    _run('');
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _run(String q) async {
    final no = ++_queryNo;
    setState(() => _loading = true);
    final rows = await MatchService.searchPlayers(q);
    // A slow early keystroke must not overwrite a later one's results.
    if (!mounted || no != _queryNo) return;
    setState(() {
      _players = rows;
      _loading = false;
    });
  }

  String _fee() => '${widget.feePerPlayer}';

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: Container(
        height: mq.size.height * 0.84,
        padding: EdgeInsets.fromLTRB(20, 10, 20, 16 + mq.padding.bottom),
        decoration: const BoxDecoration(
          color: TColors.cream,
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(TRadius.sheet)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(
            child: Container(
              width: 40,
              height: 5,
              decoration: BoxDecoration(
                  color: TColors.grabber,
                  borderRadius: BorderRadius.circular(3)),
            ),
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Pick your partner', style: tStyle(24, FontWeight.w800)),
                Text(
                    widget.feePerPlayer > 0
                        ? 'Each player pays EGP ${_fee()} entry'
                        : 'Free entry',
                    style: tStyle(13, FontWeight.w400, color: TColors.muted)),
              ]),
            ),
            TapTarget(
              label: 'Close',
              onTap: () => Navigator.pop(context),
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: TColors.surface,
                  borderRadius: BorderRadius.circular(TRadius.button),
                  border: Border.all(color: TColors.border),
                ),
                child: const Icon(Icons.close_rounded,
                    size: 18, color: TColors.text),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: TColors.surface,
              borderRadius: BorderRadius.circular(TRadius.button),
              border: Border.all(color: TColors.border),
            ),
            child: Row(children: [
              const Icon(Icons.search_rounded, size: 18, color: TColors.muted),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _search,
                  onChanged: _run,
                  autocorrect: false,
                  style: tStyle(15, FontWeight.w400),
                  decoration: InputDecoration(
                    isCollapsed: true,
                    border: InputBorder.none,
                    hintText: 'Search by @username',
                    hintStyle:
                        tStyle(15, FontWeight.w400, color: TColors.muted),
                  ),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          Expanded(child: _list()),
          const SizedBox(height: 16),
          TButton(
            'Share invite link (WhatsApp)',
            full: true,
            height: 52,
            radius: 16,
            icon: Icons.link_rounded,
            style: TButtonStyle.outlineGreen,
            onPressed: widget.onShareInvite,
          ),
        ]),
      ),
    );
  }

  Widget _list() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2.4, color: TColors.accent),
      );
    }
    if (_players.isEmpty) {
      return Center(
        child: Text('No players found. Try another username.',
            textAlign: TextAlign.center,
            style: tStyle(14, FontWeight.w400, color: TColors.muted)),
      );
    }
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: TColors.surface,
        borderRadius: BorderRadius.circular(TRadius.matchCard),
        border: Border.all(color: TColors.border),
      ),
      child: ListView.separated(
        itemCount: _players.length,
        separatorBuilder: (_, __) =>
            const Divider(height: 1, thickness: 1, color: TColors.divider),
        itemBuilder: (_, i) => PlayerRow(
          player: _players[i],
          actionLabel: 'Add as partner',
          onAction: () => Navigator.pop(context, _players[i]),
        ),
      ),
    );
  }
}

/// Avatar, name, level (with @username when set) and an action.
class PlayerRow extends StatelessWidget {
  final Map<String, dynamic> player;
  final String actionLabel;
  final VoidCallback onAction;
  const PlayerRow(
      {super.key,
      required this.player,
      required this.actionLabel,
      required this.onAction});

  /// "Level D Low · @omar". `rating` is null until a player's first rated match;
  /// that means unranked, never level 0.
  static String metaOf(Map<String, dynamic> p) {
    final rating = (p['rating'] as num?)?.toDouble();
    final level = rating == null
        ? 'Unranked'
        : 'Level ${RankingScale.categoryFor(rating)}';
    final username = (p['username'] as String?)?.trim() ?? '';
    return username.isEmpty ? level : '$level · @$username';
  }

  @override
  Widget build(BuildContext context) {
    final name = (player['name'] as String?)?.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(children: [
        Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration:
              const BoxDecoration(color: TColors.avatar, shape: BoxShape.circle),
          child: Text(initialsOf(name),
              style: tStyle(14, FontWeight.w700, color: TColors.text2)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name == null || name.isEmpty ? 'Player' : name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tStyle(15, FontWeight.w600)),
            Text(metaOf(player),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tStyle(13, FontWeight.w400, color: TColors.muted)),
          ]),
        ),
        const SizedBox(width: 8),
        TButton(
          actionLabel,
          height: 36,
          fontSize: 13,
          radius: 12,
          horizontalPadding: 14,
          onPressed: onAction,
        ),
      ]),
    );
  }
}
