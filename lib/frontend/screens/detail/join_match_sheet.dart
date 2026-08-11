import 'package:flutter/material.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/backend/services/match_service.dart';
import 'package:padel_clay/backend/models/ranking_scale.dart' show RankingScale;

/// The outcome of the join-choice sheet. `solo` = pair me with a random player;
/// otherwise [partnerId]/[partnerName] carry the chosen partner.
typedef JoinChoice = ({bool solo, String? partnerId, String? partnerName});

/// Asks the player how they want to join a match: solo (random partner) or with
/// a partner they pick. Returns null if dismissed.
///
/// [slotsLeft] (when known) hides the partner path if there aren't two open
/// seats on one side. Pass null when capacity isn't known — the server rejects a
/// pair with no room and the message is surfaced.
Future<JoinChoice?> showJoinMatchSheet(BuildContext context, {int? slotsLeft}) {
  return showModalBottomSheet<JoinChoice>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _JoinMatchSheet(slotsLeft: slotsLeft),
  );
}

class _JoinMatchSheet extends StatefulWidget {
  final int? slotsLeft;
  const _JoinMatchSheet({this.slotsLeft});
  @override
  State<_JoinMatchSheet> createState() => _JoinMatchSheetState();
}

class _JoinMatchSheetState extends State<_JoinMatchSheet> {
  bool _withPartner = false;
  final _search = TextEditingController();
  List<Map<String, dynamic>> _players = [];
  bool _loading = false;
  Map<String, dynamic>? _partner;

  /// Fewer than two open seats on any side → a pair can't be seated.
  bool get _pairBlocked =>
      widget.slotsLeft != null && widget.slotsLeft! < 2;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _searchPlayers(String q) async {
    setState(() => _loading = true);
    final rows = await MatchService.searchPlayers(q);
    if (!mounted) return;
    setState(() {
      _players = rows;
      _loading = false;
    });
  }

  void _pickPartnerMode() {
    setState(() => _withPartner = true);
    if (_players.isEmpty) _searchPlayers('');
  }

  void _confirm() {
    if (_withPartner) {
      if (_partner == null) return;
      Navigator.pop<JoinChoice>(context, (
        solo: false,
        partnerId: _partner!['id'] as String?,
        partnerName: _partner!['name'] as String?,
      ));
    } else {
      Navigator.pop<JoinChoice>(
          context, (solo: true, partnerId: null, partnerName: null));
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final canConfirm = !_withPartner || _partner != null;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: AppColors.bg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 22),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
                color: AppColors.line, borderRadius: BorderRadius.circular(4)),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('Join this match',
                style: AppText.cardTitle().copyWith(fontSize: 18)),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: Text('Play solo or bring a partner onto your side.',
                style: AppText.small().copyWith(fontSize: 12.5)),
          ),
          const SizedBox(height: 16),
          _optionCard(
            selected: !_withPartner,
            icon: Icons.shuffle_rounded,
            title: 'Join solo',
            sub: "We'll pair you with a random player.",
            onTap: () => setState(() => _withPartner = false),
          ),
          const SizedBox(height: 10),
          _optionCard(
            selected: _withPartner,
            icon: Icons.group_add_rounded,
            title: 'Ask a partner',
            sub: _pairBlocked
                ? 'Only one seat left — join solo instead.'
                : "You take one side together — they'll be asked to accept.",
            onTap: _pairBlocked ? null : _pickPartnerMode,
          ),
          if (_withPartner && !_pairBlocked) ...[
            const SizedBox(height: 14),
            _partnerPicker(),
          ],
          const SizedBox(height: 18),
          AppButton(
            _withPartner
                ? (_partner == null ? 'Pick a partner' : 'Join and send invite')
                : 'Join solo',
            full: true, height: 52,
            icon: Icons.sports_tennis_rounded,
            onPressed: canConfirm ? _confirm : null,
          ),
        ]),
      ),
    );
  }

  Widget _optionCard({
    required bool selected,
    required IconData icon,
    required String title,
    required String sub,
    required VoidCallback? onTap,
  }) {
    final dim = onTap == null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary.withValues(alpha: 0.08) : AppColors.field,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: selected ? AppColors.primary : AppColors.line, width: 1.5),
        ),
        child: Row(children: [
          Icon(icon, size: 22,
              color: dim
                  ? AppColors.inkFaint
                  : (selected ? AppColors.primary : AppColors.inkSoft)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: AppText.bodyStrong().copyWith(
                      fontSize: 14.5,
                      color: dim ? AppColors.inkFaint : AppColors.ink)),
              const SizedBox(height: 2),
              Text(sub, style: AppText.small().copyWith(fontSize: 11.5)),
            ]),
          ),
          Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
              size: 20, color: selected ? AppColors.primary : AppColors.line),
        ]),
      ),
    );
  }

  Widget _partnerPicker() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
            color: AppColors.field,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.line)),
        child: Row(children: [
          const Icon(Icons.search_rounded, size: 18, color: AppColors.inkFaint),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _search,
              onChanged: _searchPlayers,
              decoration: InputDecoration(
                hintText: 'Search players by @username…',
                hintStyle: AppText.body(AppColors.inkFaint).copyWith(fontSize: 13.5),
                border: InputBorder.none,
              ),
              style: AppText.body().copyWith(fontSize: 13.5),
            ),
          ),
        ]),
      ),
      const SizedBox(height: 10),
      if (_partner != null)
        _playerTile(_partner!, selected: true)
      else if (_loading)
        const Center(child: Padding(
          padding: EdgeInsets.all(14),
          child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
        ))
      else if (_players.isEmpty)
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: AppColors.field,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.line)),
          child: Text('No players found. Try another name.',
              style: AppText.small().copyWith(fontSize: 12.5)),
        )
      else
        SizedBox(
          height: 200,
          child: ListView(children: [for (final p in _players) _playerTile(p)]),
        ),
    ]);
  }

  Widget _playerTile(Map<String, dynamic> p, {bool selected = false}) {
    final name = p['name'] as String? ?? 'Player';
    final username = p['username'] as String?;
    final ranked = p['level'] != null || p['elo'] != null;
    final elo = (p['elo'] as num?)?.toInt() ?? 1000;
    final lv = (p['level'] as num?)?.toDouble() ?? RankingScale.levelFromElo(elo);
    final rankTag = ranked ? RankingScale.levelTag(lv) : 'Unranked';
    final initials = name.trim().isEmpty
        ? 'P'
        : name.trim().split(RegExp(r'\s+')).take(2).map((w) => w[0]).join().toUpperCase();
    final subtitle = (username != null && username.isNotEmpty)
        ? '@$username · $rankTag'
        : rankTag;
    return GestureDetector(
      onTap: () => setState(() => _partner = selected ? null : p),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary.withValues(alpha: 0.08) : AppColors.field,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? AppColors.primary : AppColors.line, width: 1.5),
        ),
        child: Row(children: [
          AppAvatar(initials, size: 36, ring: 1.5,
              imageUrl: p['avatar_url'] as String?),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: AppText.bodyStrong().copyWith(fontSize: 13.5)),
              Text(subtitle, style: AppText.small().copyWith(fontSize: 11.5)),
            ]),
          ),
          Icon(selected ? Icons.close_rounded : Icons.add_circle_outline_rounded,
              size: 20, color: selected ? AppColors.inkSoft : AppColors.primary),
        ]),
      ),
    );
  }
}
