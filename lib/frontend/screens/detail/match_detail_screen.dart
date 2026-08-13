import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/frontend/widgets/app_toast.dart';
import 'package:padel_clay/frontend/widgets/auto_refresh.dart';
import 'package:padel_clay/backend/services/match_service.dart';
import 'package:padel_clay/backend/models/ranking_scale.dart' show RankingScale;
import '../chat/dm_chat_screen.dart';
import 'join_match_sheet.dart';

/// Live match detail — lobby + player-submitted result flow, driven by the
/// `matches` row status:
///
///   open / full ──(time passes, player submits)──► pending_confirm
///   pending_confirm ──(other team confirms)──► completed (ELO settles)
///                   └─(other team rejects)──► disputed (re-submit)
///   Casual matches skip confirmation and complete on submit.
class MatchDetailScreen extends StatefulWidget {
  final String matchId;
  const MatchDetailScreen({super.key, required this.matchId});
  @override
  State<MatchDetailScreen> createState() => _MatchDetailScreenState();
}

class _MatchDetailScreenState extends State<MatchDetailScreen> with AutoRefresh<MatchDetailScreen> {
  int _view = 0; // 0 lobby, 1 result
  Map<String, dynamic>? _match;
  Map<String, dynamic>? _myRating; // my ranking_history row for this match
  bool _loading = true;
  bool _busy = false;
  List<Map<String, dynamic>> _invites = const [];
  List<List<int>> _sets = [
    [0, 0],
    [0, 0]
  ];

  String? get _uid => Supabase.instance.client.auth.currentUser?.id;

  StreamSubscription<List<Map<String, dynamic>>>? _roster;

  @override
  void initState() {
    super.initState();
    _load();
    // Someone joining is the one change that happens while you sit and watch.
    // The rows themselves are ignored — see rosterStream — so this just says
    // "something moved, go re-read it". The first emission is the current
    // roster, which arrives right after _load, hence markRefreshed().
    markRefreshed();
    _roster = MatchService.rosterStream(widget.matchId).listen((_) {
      if (mounted) autoRefresh();
    });
  }

  @override
  void dispose() {
    _roster?.cancel();
    super.dispose();
  }

  /// A lobby is the screen most likely to be stale — someone joins or leaves
  /// while you are looking at it.
  @override
  Future<void> onAutoRefresh() => _load();

  Future<void> _load() async {
    final m = await MatchService.fetchMatch(widget.matchId);
    final rating = await _fetchMyRatingChange();
    // Slots held for players who were invited but haven't answered yet. They
    // are NOT match_players, so they carry a name and nothing else.
    final invites = await MatchService.pendingInvites(widget.matchId);
    if (!mounted) return;
    setState(() {
      _match = m;
      _myRating = rating;
      _invites = invites;
      _loading = false;
    });
  }

  /// My settled rating change for this match. Rating v2 writes it to
  /// ranking_history (native 0–7 points); match_players.elo_* is legacy and no
  /// longer populated, so it can't be used to tell "no change" from "not
  /// recorded". Null = nothing settled for me.
  Future<Map<String, dynamic>?> _fetchMyRatingChange() async {
    final uid = _uid;
    if (uid == null) return null;
    try {
      final row = await Supabase.instance.client
          .from('ranking_history')
          .select('rating_before, rating_after, delta')
          .eq('profile_id', uid)
          .eq('match_id', widget.matchId)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
      return row;
    } catch (_) {
      return null; // pre-v2 database
    }
  }

  // ── Derived state ──────────────────────────────────────────────────────

  List<Map<String, dynamic>> get _players =>
      List<Map<String, dynamic>>.from((_match?['match_players'] as List?) ?? const []);

  Map<String, dynamic>? get _me {
    final uid = _uid;
    if (uid == null) return null;
    for (final p in _players) {
      if (p['player_id'] == uid) return p;
    }
    return null;
  }

  bool get _inMatch => _me != null;
  String get _myTeam => (_me?['team'] as String?) ?? 'a';
  bool get _comp => _match?['match_type'] == 'ranked';
  String get _status => (_match?['status'] as String?) ?? 'open';

  DateTime? get _when {
    final iso = _match?['scheduled_at'] as String?;
    return iso == null ? null : DateTime.tryParse(iso)?.toLocal();
  }

  bool get _ended => _when != null && _when!.isBefore(DateTime.now());
  /// Playable means four REAL players — a slot held for an unanswered invite
  /// doesn't make a 2v2.
  bool get _full => _players.length >= 4;

  /// The invite waiting on me for this match, if any.
  Map<String, dynamic>? get _myInvite {
    for (final i in _invites) {
      if (i['is_me'] == true) return i;
    }
    return null;
  }
  bool get _isHost => _uid != null && _match?['created_by'] == _uid;

  bool get _iSubmitted {
    final by = _match?['result_submitted_by'] as String?;
    if (by == null) return false;
    final sub = _players.where((p) => p['player_id'] == by);
    if (sub.isEmpty) return by == _uid;
    return sub.first['team'] == _myTeam;
  }

  /// Sets from MY team's perspective (DB stores team-A perspective).
  List<List<int>> get _storedSets {
    final a = (_match?['score_team_a'] as String?)?.split(',') ?? const [];
    final b = (_match?['score_team_b'] as String?)?.split(',') ?? const [];
    final out = <List<int>>[];
    for (int i = 0; i < a.length && i < b.length; i++) {
      final sa = int.tryParse(a[i].trim()) ?? 0;
      final sb = int.tryParse(b[i].trim()) ?? 0;
      out.add(_myTeam == 'a' ? [sa, sb] : [sb, sa]);
    }
    return out;
  }

  bool get _won {
    final w = _match?['winner_team'] as String?;
    return w != null && w == _myTeam;
  }

  int get _mineWon => _sets.where((s) => s[0] > s[1]).length;
  int get _theirsWon => _sets.where((s) => s[1] > s[0]).length;
  bool get _decided => _mineWon != _theirsWon && (_mineWon + _theirsWon) > 0;

  String _name(Map<String, dynamic> p) =>
      ((p['profiles'] as Map?)?['name'] as String?) ?? 'Player';
  String _first(Map<String, dynamic> p) => _name(p).split(' ').first;
  /// A player's photo off the embedded profile, or null. `matchCols` selects
  /// `avatar_url` on the profiles embed — it's a public bucket URL, so unlike
  /// the phone number it's fine to ship to the client.
  String? _avatarOf(Map<String, dynamic> p) =>
      (p['profiles'] as Map?)?['avatar_url'] as String?;

  String _initials(Map<String, dynamic> p) {
    final parts = _name(p).trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return 'P';
    return parts.take(2).map((w) => w[0]).join().toUpperCase();
  }

  String get _oppFirst {
    final opp = _players.where((p) => p['team'] != _myTeam);
    return opp.isEmpty ? 'your opponent' : _first(opp.first);
  }

  // ── Actions ────────────────────────────────────────────────────────────

  void _snack(String msg, {Color? color}) => AppToast.show(context, msg,
      kind: color == AppColors.danger ? ToastKind.error : ToastKind.success);

  Future<void> _run(Future<String?> Function() op, {String? ok}) async {
    setState(() => _busy = true);
    final err = await op();
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      _snack(err, color: AppColors.danger);
    } else {
      if (ok != null) _snack(ok);
      await _load();
    }
  }

  Future<void> _answerInvite(bool accept) async {
    final id = _myInvite?['invite_id'] as String?;
    if (id == null) return;
    if (!accept) {
      final sure = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text('Decline this invite?', style: AppText.bodyStrong()),
          content: Text(
              'The spot opens up for anyone else. You can still join later if it '
              'is still free.',
              style: AppText.small().copyWith(height: 1.45)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: Text('Keep it', style: AppText.bodyStrong())),
            TextButton(
                onPressed: () => Navigator.pop(c, true),
                child: Text('Decline',
                    style: AppText.bodyStrong(AppColors.danger))),
          ],
        ),
      );
      if (sure != true || !mounted) return;
    }
    await _run(() => MatchService.respondToInvite(id, accept: accept),
        ok: accept
            ? "You're in! See you on court."
            : 'Declined — the spot is open again.');
  }

  Future<void> _join() async {
    // Held slots aren't free slots — offering them would let someone pick a
    // partner for a seat the server will refuse.
    final choice = await showJoinMatchSheet(context,
        slotsLeft: (4 - _players.length - _invites.length).clamp(0, 4));
    if (choice == null || !mounted) return;
    await _run(
        () => MatchService.joinMatch(widget.matchId, partnerId: choice.partnerId),
        ok: choice.solo
            ? "You're in! See you on court."
            : "You're in — we've asked your partner and we're holding their spot.");
  }

  Future<void> _leave() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Leave this match?', style: AppText.cardTitle().copyWith(fontSize: 17)),
        content: Text('Your spot opens up for another player.',
            style: AppText.body(AppColors.inkSoft).copyWith(fontSize: 14)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Stay')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Leave')),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => _busy = true);
    final err = await MatchService.leaveMatch(widget.matchId);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      _snack(err, color: AppColors.danger);
    } else {
      Navigator.pop(context, true);
    }
  }

  Future<void> _cancel() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('Cancel this match?', style: AppText.cardTitle().copyWith(fontSize: 17)),
        content: Text('Everyone who joined is notified and the match is called off.',
            style: AppText.body(AppColors.inkSoft).copyWith(fontSize: 14)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep it')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Cancel match')),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    setState(() => _busy = true);
    final err = await MatchService.cancelMatch(widget.matchId);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      _snack(err, color: AppColors.danger);
    } else {
      _snack('Match cancelled');
      Navigator.pop(context, true);
    }
  }

  Future<void> _submit() {
    // convert my-team perspective → team A perspective for the DB
    final aSets =
        _myTeam == 'a' ? _sets : _sets.map((s) => [s[1], s[0]]).toList();
    return _run(() => MatchService.submitResult(widget.matchId, aSets),
        ok: _comp ? 'Score submitted — awaiting confirmation.' : 'Saved to your history.');
  }

  Future<void> _confirm(bool yes) =>
      _run(() => MatchService.confirmResult(widget.matchId, yes),
          ok: yes ? 'Result confirmed — rankings updated.' : 'Result rejected.');

  void _copyInvite() {
    final code = _match?['invite_code'] as String? ?? '';
    if (code.isEmpty) return;
    Clipboard.setData(ClipboardData(text: code));
    _snack('Invite code copied');
  }

  void _share() {
    final code = (_match?['invite_code'] as String? ?? '').trim();
    final when = _fmtWhen();
    // A public match has no code, and promising one that isn't there sends the
    // reader looking for something that doesn't exist.
    Clipboard.setData(ClipboardData(
        text: code.isEmpty
            ? 'Join my padel match on Padel Rivals — $when.'
            : 'Join my padel match on Padel Rivals — $when. Invite code: $code'));
    _snack('Match details copied — paste anywhere to share');
  }

  String _fmtWhen() {
    final dt = _when;
    if (dt == null) return 'TBD';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(dt.year, dt.month, dt.day);
    final diff = day.difference(today).inDays;
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final d = diff == 0 ? 'Today' : diff == 1 ? 'Tomorrow' : '${months[dt.month - 1]} ${dt.day}';
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$d, $h:$mm ${dt.hour < 12 ? 'AM' : 'PM'}';
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: AppColors.bg,
        body: Center(child: CircularProgressIndicator(strokeWidth: 2.4, color: AppColors.primary)),
      );
    }
    if (_match == null) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        body: SafeArea(
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('Match not found', style: AppText.cardTitle()),
              const SizedBox(height: 8),
              Text('It may have been cancelled.', style: AppText.small()),
              const SizedBox(height: 18),
              AppButton('Back', onPressed: () => Navigator.pop(context)),
            ]),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Column(children: [
        _header(),
        Expanded(
          // The Lobby/Submit tab overhangs 26px below the hero (Transform in
          // _header). Keep that clearance OUTSIDE the scroll viewport so the
          // viewport starts below the tab — otherwise scrolled content paints
          // over the tab (it's painted after the hero) and garbles the seam.
          child: Padding(
            padding: const EdgeInsets.only(top: 26),
            child: RefreshIndicator(
              color: AppColors.primary,
              onRefresh: _load,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 24),
                child: _view == 0 ? _lobby() : _resultView(),
              ),
            ),
          ),
        ),
        _footer(),
      ]),
    );
  }

  String get _tabLabel {
    switch (_status) {
      case 'completed':
        return 'Result';
      case 'disputed':
        return 'Disputed';
      case 'pending_confirm':
        return _iSubmitted ? 'Pending' : 'Confirm';
      default:
        return 'Submit Score';
    }
  }

  Widget _header() {
    final teamA = _players.where((p) => p['team'] == 'a').toList();
    final teamB = _players.where((p) => p['team'] == 'b').toList();
    return Container(
      padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 6),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [AppColors.hero, AppColors.hero2]),
      ),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(children: [
            _glassBtn(Icons.close_rounded, () => Navigator.pop(context)),
            const SizedBox(width: 12),
            Text('${_comp ? 'COMPETITIVE' : 'CASUAL'} · DOUBLES',
                style: AppText.tag(AppColors.heroFaint).copyWith(fontSize: 11)),
            const Spacer(),
            _glassBtn(Icons.ios_share_rounded, _share),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
          // Each side takes half of whatever is left after "VS", instead of a
          // fixed 110 — a doubles team is two names joined by "&", which never
          // fitted and always ellipsised ("Mohamed & …").
          child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _teamSide(teamA, 'Team A')),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text('VS',
                      style: AppText.stat(26, AppColors.heroInk)
                          .copyWith(letterSpacing: 2)),
                ),
                Expanded(child: _teamSide(teamB, 'Team B')),
              ]),
        ),
        Transform.translate(
          offset: const Offset(0, 26),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.line),
                  boxShadow: kCardShadow),
              child: Row(children: [
                _seg('Lobby', 0),
                _seg(_tabLabel, 1),
              ]),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _teamSide(List<Map<String, dynamic>> team, String fallback) {
    final mine = team.isNotEmpty && team.any((p) => p['player_id'] == _uid);
    final label = team.isEmpty
        ? 'Open'
        : team.map(_first).join(' & ');
    final firstP = team.isNotEmpty ? team.first : null;

    // One entry per player. An unranked player has no level, so it must NOT be
    // prefixed with "Lv" — that produced the nonsense "Lv Unranked".
    final levels = team.map((p) {
      final prof = p['profiles'] as Map?;
      if (prof?['rating'] == null && prof?['level'] == null) return null;
      final lv = (prof?['rating'] as num?)?.toDouble() ??
          (prof?['level'] as num?)?.toDouble() ?? 0.0;
      return RankingScale.fmtLevel(lv);
    }).toList();

    // All ranked → one "Lv" in front of the list ("Lv 2.0 · 2.5"). Any unranked
    // → label each entry, so the mix reads honestly ("Lv 2.0 · Unranked").
    final String sub;
    if (firstP == null) {
      sub = fallback;
    } else if (levels.every((l) => l != null)) {
      sub = 'Lv ${levels.join(' · ')}';
    } else {
      sub = levels.map((l) => l == null ? 'Unranked' : 'Lv $l').join(' · ');
    }

    return Column(children: [
      AppAvatar(firstP == null ? '?' : _initials(firstP),
          size: 64,
          color: mine ? AppColors.primary : AppColors.heroFaint,
          ring: 2.5,
          imageUrl: firstP == null ? null : _avatarOf(firstP)),
      const SizedBox(height: 8),
      Text(label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: AppText.bodyStrong(AppColors.heroInk)),
      Text(sub,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: AppText.tag(AppColors.heroFaint).copyWith(fontSize: 11)),
    ]);
  }

  Widget _seg(String label, int i) => Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _view = i),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: _view == i ? AppColors.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(9)),
            child: Text(label,
                style: AppText.bodyStrong(_view == i ? AppColors.primaryInk : AppColors.inkSoft).copyWith(fontSize: 13)),
          ),
        ),
      );

  Widget _glassBtn(IconData icon, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 34, height: 34,
          decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, size: 18, color: AppColors.heroInk),
        ),
      );

  // ── Lobby ──────────────────────────────────────────────────────────────

  Widget _lobby() {
    final court = _match?['courts'] as Map?;
    final courtName = court?['venue_name'] as String? ??
        court?['name'] as String? ?? 'To be agreed';
    // Empty for a public match — public matches carry no code at all now.
    final code = (_match?['invite_code'] as String? ?? '').trim();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Column(children: [
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('PLAYERS', style: AppText.kicker()),
              const Spacer(),
              // Counts who has JOINED, not who has readied up — there is no
              // ready flag. "3/4 ready" beside an empty slot read as though the
              // match were about to start. Pending invites keep their own
              // wording, since a held slot is neither joined nor free.
              AppTag(
                  _invites.isNotEmpty
                      ? '${_players.length}/4 · ${_invites.length} invited'
                      : _players.length == 4
                          ? 'Full · 4/4'
                          : '${_players.length}/4 joined',
                  color: _players.length == 4
                      ? AppColors.success
                      : AppColors.accent),
            ]),
            for (int i = 0; i < _players.length; i++) ...[
              if (i > 0) const Divider(color: AppColors.line),
              _playerRow(_players[i]),
            ],
            // Invited but not yet in: held slots sit between the real players
            // and the open ones, so the card reads top-to-bottom as
            // confirmed → waiting → free.
            for (int i = 0; i < _invites.length; i++) ...[
              if (_players.isNotEmpty || i > 0) const Divider(color: AppColors.line),
              _invitedSlot(_invites[i]),
            ],
            for (int i = _players.length + _invites.length; i < 4; i++) ...[
              if (i > 0) const Divider(color: AppColors.line),
              _emptySlot(),
            ],
          ]),
        ),
        const SizedBox(height: 12),
        AppCard(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(children: [
            _infoRow(Icons.place_outlined, 'Court', courtName, trailing: _directionsBtn()),
            const Divider(color: AppColors.line),
            _infoRow(Icons.schedule_rounded, 'When', _fmtWhen()),
            const Divider(color: AppColors.line),
            _infoRow(Icons.emoji_events_outlined, 'Format',
                '${_comp ? 'Competitive' : 'Casual'} · Doubles'),
            if (_comp && ((_match?['min_rating'] as num?)?.toDouble() ?? 0) > 0) ...[
              const Divider(color: AppColors.line),
              _infoRow(Icons.shield_outlined, 'Minimum level',
                  'Lv ${RankingScale.fmtLevel((_match?['min_rating'] as num).toDouble())}+'),
            ],
          ]),
        ),
        // Only a private match has a code, and it is the ONLY way in — so it
        // gets the gold treatment and says what it's for. A public match used
        // to show a code here that did nothing at all.
        if (_inMatch && code.isNotEmpty) ...[
          const SizedBox(height: 12),
          AppCard(
            color: AppColors.gold.withValues(alpha: 0.08),
            child: Row(children: [
              const Icon(Icons.vpn_key_outlined, size: 20, color: AppColors.gold),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Invite code', style: AppText.bodyStrong().copyWith(fontSize: 13)),
                  Text(code,
                      style: AppText.bodyStrong(AppColors.ink)
                          .copyWith(fontSize: 15, letterSpacing: 2)),
                  const SizedBox(height: 2),
                  Text('Private match — share this and they can join',
                      style: AppText.small(AppColors.inkFaint).copyWith(fontSize: 11)),
                ]),
              ),
              AppButton('Copy', height: 32, variant: AppBtnVariant.ghost, onPressed: _copyInvite),
            ]),
          ),
        ],
      ]),
    );
  }

  Widget _playerRow(Map<String, dynamic> p) {
    final isMe = p['player_id'] == _uid;
    final isHost = p['player_id'] == _match?['created_by'];
    final prof = p['profiles'] as Map?;
    final ranked = prof?['rating'] != null || prof?['level'] != null;
    final lv = (prof?['rating'] as num?)?.toDouble() ??
        (prof?['level'] as num?)?.toDouble() ?? 0.0;
    final rankTag = ranked ? RankingScale.levelTag(lv) : 'Unranked';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(children: [
        AppAvatar(_initials(p), size: 38,
            color: isMe ? AppColors.primary : AppColors.gold, ring: 1.5,
            imageUrl: _avatarOf(p)),
        const SizedBox(width: 11),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(isMe ? 'You' : _name(p), style: AppText.bodyStrong()),
            Text('$rankTag · Team ${(p['team'] as String? ?? 'a').toUpperCase()}',
                style: AppText.small().copyWith(fontSize: 11)),
          ]),
        ),
        // My own row keeps the status badge; co-players get a contact button —
        // but only when I'm in the match (browsers don't get tap-to-call).
        if (isMe && isHost)
          const AppTag('Host', color: AppColors.primary)
        else if (isMe || !_inMatch)
          const Icon(Icons.check_circle_rounded, size: 20, color: AppColors.success)
        else
          _contactBtn(p),
      ]),
    );
  }

  Widget _contactBtn(Map<String, dynamic> p) => Semantics(
        label: 'Contact ${_name(p)}',
        button: true,
        child: GestureDetector(
          onTap: () => _showContactSheet(p),
          child: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.chat_bubble_outline_rounded,
                size: 18, color: AppColors.primary),
          ),
        ),
      );

  /// Bottom sheet to reach a co-player: in-app message, plus their phone number
  /// (copy + native call) IF they've shared it.
  ///
  /// The number is fetched per-tap from `player_phone`, not read off the match
  /// payload — being in a match together is no longer enough to see it, and the
  /// only place that decides is Postgres.
  Future<void> _showContactSheet(Map<String, dynamic> p) async {
    final prof = p['profiles'] as Map?;
    final phone =
        await MatchService.playerPhone(p['player_id'] as String) ?? '';
    if (!mounted) return;
    final username = (prof?['username'] as String?)?.trim() ?? '';
    final elo = (prof?['elo'] as num?)?.toInt() ?? 1000;

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                        color: AppColors.line,
                        borderRadius: BorderRadius.circular(2))),
              ),
              Row(children: [
                AppAvatar(_initials(p), size: 48, color: AppColors.gold, ring: 2,
                    imageUrl: _avatarOf(p)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_name(p),
                        style: AppText.bodyStrong().copyWith(fontSize: 16),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 1),
                    Text(
                        '${username.isNotEmpty ? '@$username · ' : ''}$elo ELO',
                        style: AppText.small().copyWith(fontSize: 12)),
                  ]),
                ),
              ]),
              const SizedBox(height: 18),
              // Primary: in-app chat (no number shared).
              GestureDetector(
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => DMChatScreen(
                      otherId: p['player_id'] as String,
                      name: _name(p),
                      initials: _initials(p),
                      username: username.isEmpty ? null : username,
                      matchId: widget.matchId,
                      avatarUrl: _avatarOf(p),
                    ),
                  ));
                },
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(12)),
                  child: Row(children: [
                    Container(
                      width: 40,
                      height: 40,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(11)),
                      child: const Icon(Icons.chat_bubble_outline_rounded,
                          size: 20, color: AppColors.primaryInk),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Message in app',
                            style: AppText.bodyStrong(AppColors.primaryInk).copyWith(fontSize: 15)),
                        const SizedBox(height: 1),
                        Text('Chat without sharing your number',
                            style: AppText.small(AppColors.primaryInk).copyWith(fontSize: 12)),
                      ]),
                    ),
                    const Icon(Icons.chevron_right_rounded,
                        size: 18, color: AppColors.primaryInk),
                  ]),
                ),
              ),
              const SizedBox(height: 12),
              if (phone.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                      color: AppColors.field,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.line)),
                  child: Text(
                      'No number here. Open the match ticket and ask for it — '
                      'if they accept, you\'ll both have each other\'s.',
                      style: AppText.body(AppColors.inkSoft)
                          .copyWith(fontSize: 13, height: 1.4)),
                )
              else
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                      color: AppColors.field,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppColors.line)),
                  child: Row(children: [
                    Container(
                      width: 40,
                      height: 40,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                          color: AppColors.accent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(11)),
                      child: const Icon(Icons.phone_outlined,
                          size: 20, color: AppColors.accent),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Phone number',
                            style: AppText.small(AppColors.inkSoft).copyWith(fontSize: 11)),
                        const SizedBox(height: 2),
                        Text(phone,
                            style: AppText.bodyStrong()
                                .copyWith(fontSize: 15, letterSpacing: 0.3)),
                      ]),
                    ),
                    const SizedBox(width: 10),
                    Tooltip(
                      message: 'Copy number',
                      child: GestureDetector(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: phone));
                          _toast('Number copied');
                        },
                        child: Container(
                          width: 36,
                          height: 36,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                              color: AppColors.surface,
                              borderRadius: BorderRadius.circular(10)),
                          child: const Icon(Icons.copy_rounded,
                              size: 16, color: AppColors.inkSoft),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () => _call(phone),
                      child: Container(
                        height: 36,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                            color: AppColors.accent,
                            borderRadius: BorderRadius.circular(10)),
                        child: Text('Call',
                            style: AppText.bodyStrong(Colors.white).copyWith(fontSize: 13)),
                      ),
                    ),
                  ]),
                ),
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text('Cancel',
                      style: AppText.bodyStrong(AppColors.inkSoft).copyWith(fontSize: 14)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _call(String phone) async {
    final digits = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    final ok = await launchUrl(Uri.parse('tel:$digits'),
        mode: LaunchMode.externalApplication);
    if (!ok) _toast('Could not open the dialer.');
  }

  void _toast(String msg) {
    if (!mounted) return;
    AppToast.show(context, msg);
  }

  /// A slot held for someone who was invited and hasn't answered. Name and
  /// team only — no rank, no contact button, no phone. They haven't agreed to
  /// be here yet, so nothing of theirs is on offer.
  Widget _invitedSlot(Map<String, dynamic> inv) {
    final mine = inv['is_me'] == true;
    final name = (inv['invitee_name'] as String?)?.trim();
    final label = mine ? 'You' : (name?.isNotEmpty == true ? name! : 'A player');
    final initials = _initialsOf(name);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(children: [
        Opacity(
          opacity: 0.55,
          child: AppAvatar(initials, size: 38, color: AppColors.inkFaint, ring: 1.5),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: AppText.bodyStrong(AppColors.inkSoft)),
            Text('Invited · Team ${(inv['team'] as String? ?? 'a').toUpperCase()}',
                style: AppText.small().copyWith(fontSize: 11)),
          ]),
        ),
        const AppTag('Waiting', color: AppColors.gold),
      ]),
    );
  }

  static String _initialsOf(String? name) {
    final t = (name ?? '').trim();
    if (t.isEmpty) return '?';
    return t
        .split(RegExp(r'\s+'))
        .take(2)
        .map((w) => w.isEmpty ? '' : w[0])
        .join()
        .toUpperCase();
  }

  Widget _emptySlot() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.line, width: 1.5)),
            child: const Icon(Icons.person_add_alt_rounded, size: 17, color: AppColors.inkFaint),
          ),
          const SizedBox(width: 11),
          Text('Open spot', style: AppText.body(AppColors.inkFaint).copyWith(fontSize: 13.5)),
        ]),
      );

  Widget _infoRow(IconData icon, String label, String value, {Widget? trailing}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 13),
        child: Row(children: [
          Container(
            width: 34, height: 34,
            decoration: BoxDecoration(color: AppColors.field, borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 17, color: AppColors.inkSoft),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: AppText.small().copyWith(fontSize: 11)),
              Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.bodyStrong()),
            ]),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing],
        ]),
      );

  Future<void> _openDirections(double? lat, double? lng, String? address) async {
    final dest = (lat != null && lng != null)
        ? '$lat,$lng'
        : (address != null && address.trim().isNotEmpty
            ? Uri.encodeComponent(address.trim())
            : null);
    if (dest == null) return;
    try {
      await launchUrl(Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$dest'),
          mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) _snack("Couldn't open Maps", color: AppColors.danger);
    }
  }

  Widget? _directionsBtn() {
    final court = _match?['courts'] as Map?;
    final lat = (court?['lat'] as num?)?.toDouble();
    final lng = (court?['lng'] as num?)?.toDouble();
    final address = (court?['address'] as String?)?.trim();
    final hasLoc = (lat != null && lng != null) || (address != null && address.isNotEmpty);
    if (!hasLoc) return null;
    return GestureDetector(
      onTap: () => _openDirections(lat, lng, address),
      behavior: HitTestBehavior.opaque,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.directions_rounded, size: 18, color: AppColors.primary),
        const SizedBox(width: 4),
        Text('Directions', style: AppText.tag(AppColors.primary).copyWith(fontSize: 11)),
      ]),
    );
  }

  // ── Result tab ─────────────────────────────────────────────────────────

  Widget _resultView() {
    if (!_inMatch) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: _banner('primary', Icons.info_outline_rounded, 'Players only',
            'Join the match to take part in score submission.'),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_status == 'open' || _status == 'full' || _status == 'in_progress')
          (!_ended)
              ? _lockedCard()
              // Score entry only makes sense for a full 2v2. An under-filled
              // match that ran out of time couldn't be played — show that
              // instead (it auto-cancels shortly).
              : (_full ? _scoreEntry() : _didNotFillCard()),

        if (_status == 'disputed') ...[
          _banner('danger', Icons.info_outline_rounded, 'Result disputed',
              'The submitted score was rejected. Agree on the correct score together and re-submit below.'),
          const SizedBox(height: 12),
          _scoreEntry(),
        ],

        if (_status == 'pending_confirm') ...[
          if (_iSubmitted)
            _banner('gold', Icons.schedule_rounded, "Awaiting confirmation",
                'Your score is submitted. Ranking updates only once a player on the other team confirms it.')
          else
            _banner('primary', Icons.info_outline_rounded, '$_oppFirst\'s team submitted a score',
                "Review the score below, then confirm it or reject it if it's wrong."),
          const SizedBox(height: 12),
          _scoreboard(_storedSets, outcome: null),
          const SizedBox(height: 12),
          _rankingImpact('provisional'),
        ],

        if (_status == 'completed') ...[
          _comp
              ? _banner('success', Icons.check_circle_rounded, 'Result confirmed',
                  'Both teams agreed. Ranking has been updated.')
              : _banner('success', Icons.check_circle_rounded, 'Saved to your history',
                  "Casual matches are logged for your record but don't affect ranking."),
          const SizedBox(height: 12),
          _scoreboard(_storedSets, outcome: _won ? 'win' : 'loss'),
          const SizedBox(height: 12),
          _rankingImpact(_comp ? 'applied' : 'casual'),
        ],
      ]),
    );
  }

  Widget _lockedCard() => AppCard(
        child: Column(children: [
          Container(
            width: 52, height: 52,
            decoration: BoxDecoration(color: AppColors.field, borderRadius: BorderRadius.circular(14)),
            child: const Icon(Icons.lock_outline_rounded, size: 24, color: AppColors.inkSoft),
          ),
          const SizedBox(height: 14),
          Text('Score entry opens after the match', style: AppText.cardTitle().copyWith(fontSize: 15)),
          const SizedBox(height: 6),
          Text("You'll be able to submit the final score once ${_fmtWhen()} has passed.",
              textAlign: TextAlign.center, style: AppText.small().copyWith(fontSize: 12.5, height: 1.5)),
        ]),
      );

  // Past-time but never reached 4 players — it couldn't be played and will be
  // auto-cancelled (within the grace window sweep).
  Widget _didNotFillCard() => AppCard(
        child: Column(children: [
          Container(
            width: 52, height: 52,
            decoration: BoxDecoration(color: AppColors.field, borderRadius: BorderRadius.circular(14)),
            child: const Icon(Icons.group_off_rounded, size: 24, color: AppColors.inkSoft),
          ),
          const SizedBox(height: 14),
          Text("This match didn't fill up", style: AppText.cardTitle().copyWith(fontSize: 15)),
          const SizedBox(height: 6),
          Text('Only ${_players.length}/4 players joined by the start time, so it can’t be '
              'played. It’ll be cancelled automatically${_isHost ? ' — or cancel it now below' : ''}.',
              textAlign: TextAlign.center, style: AppText.small().copyWith(fontSize: 12.5, height: 1.5)),
        ]),
      );

  Widget _scoreEntry() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AppCard(
          color: AppColors.field,
          child: Row(children: [
            Container(
              width: 34, height: 34,
              decoration: BoxDecoration(color: AppColors.primary.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.edit_outlined, size: 17, color: AppColors.primary),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Enter the final score', style: AppText.bodyStrong().copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(_comp
                        ? "Game's over — tap in each set. The other team confirms after."
                        : "Game's over — tap in each set. Casual matches save right away.",
                    style: AppText.small().copyWith(fontSize: 11.5)),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        Row(children: [
          const SizedBox(width: 44),
          Expanded(child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            _scoreHead('Us', AppColors.primary),
            _scoreHead('Them', AppColors.gold),
          ])),
          const SizedBox(width: 30),
        ]),
        const SizedBox(height: 6),
        AppCard(
          padding: EdgeInsets.zero,
          child: Column(children: [
            for (int i = 0; i < _sets.length; i++) _setRow(i),
            if (_sets.length < 3)
              GestureDetector(
                onTap: () => setState(() => _sets = [..._sets, [0, 0]]),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: const BoxDecoration(border: Border(top: BorderSide(color: AppColors.line))),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.add_rounded, size: 15, color: AppColors.primary),
                    const SizedBox(width: 5),
                    Text('Add set', style: AppText.bodyStrong(AppColors.primary).copyWith(fontSize: 13)),
                  ]),
                ),
              ),
          ]),
        ),
        if (!_decided)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text('Enter the sets — there must be a winner before you can submit.',
                textAlign: TextAlign.center,
                style: AppText.small().copyWith(fontSize: 12)),
          ),
      ]);

  Widget _scoreHead(String label, Color color) => Row(children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Text(label, style: AppText.bodyStrong().copyWith(fontSize: 12)),
      ]);

  Widget _setRow(int i) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: i > 0
            ? const BoxDecoration(border: Border(top: BorderSide(color: AppColors.line)))
            : null,
        child: Row(children: [
          SizedBox(width: 44, child: Text('Set ${i + 1}', style: AppText.small().copyWith(fontSize: 12))),
          Expanded(
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
              _scoreStepper(i, 0),
              _scoreStepper(i, 1),
            ]),
          ),
          SizedBox(
            width: 30,
            child: _sets.length > 1
                ? GestureDetector(
                    onTap: () => setState(() {
                      final next = [..._sets]..removeAt(i);
                      _sets = next;
                    }),
                    child: const Icon(Icons.remove_circle_outline_rounded, size: 18, color: AppColors.inkFaint),
                  )
                : const SizedBox.shrink(),
          ),
        ]),
      );

  Widget _scoreStepper(int set, int side) {
    final v = _sets[set][side];
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _stepBtn(Icons.remove_rounded, v > 0, () => setState(() => _sets[set][side] = v - 1)),
      Container(
        width: 36, alignment: Alignment.center,
        child: Text('$v', style: AppText.stat(20)),
      ),
      _stepBtn(Icons.add_rounded, v < 7, () => setState(() => _sets[set][side] = v + 1)),
    ]);
  }

  Widget _stepBtn(IconData icon, bool enabled, VoidCallback onTap) => GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          width: 28, height: 28,
          decoration: BoxDecoration(
              color: AppColors.field,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.line)),
          child: Icon(icon, size: 16, color: enabled ? AppColors.ink : AppColors.inkFaint),
        ),
      );

  Widget _scoreboard(List<List<int>> sets, {String? outcome}) {
    final mine = sets.where((s) => s[0] > s[1]).length;
    final theirs = sets.where((s) => s[1] > s[0]).length;
    return AppCard(
      child: Column(children: [
        if (outcome != null) ...[
          AppTag(outcome == 'win' ? 'VICTORY' : 'DEFEAT',
              color: outcome == 'win' ? AppColors.success : AppColors.danger, solid: true),
          const SizedBox(height: 12),
        ],
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text('$mine', style: AppText.stat(44, mine > theirs ? AppColors.success : AppColors.ink)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('—', style: AppText.stat(30, AppColors.inkFaint)),
          ),
          Text('$theirs', style: AppText.stat(44, theirs > mine ? AppColors.success : AppColors.ink)),
        ]),
        const SizedBox(height: 4),
        Text('sets (us — them)', style: AppText.small().copyWith(fontSize: 11.5)),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          for (int i = 0; i < sets.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                  color: AppColors.field,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.line)),
              child: Text('${sets[i][0]}–${sets[i][1]}',
                  style: AppText.bodyStrong().copyWith(fontSize: 13)),
            ),
          ],
        ]),
      ]),
    );
  }

  Widget _rankingImpact(String kind) {
    if (!_comp || kind == 'casual') {
      return AppCard(
        color: AppColors.field,
        child: Row(children: [
          const Icon(Icons.history_rounded, size: 20, color: AppColors.inkSoft),
          const SizedBox(width: 12),
          Expanded(
            child: Text('Casual match — no ranking change.',
                style: AppText.small().copyWith(fontSize: 12.5)),
          ),
        ]),
      );
    }
    if (kind == 'provisional') {
      return AppCard(
        color: AppColors.field,
        child: Row(children: [
          const Icon(Icons.hourglass_top_rounded, size: 20, color: AppColors.gold),
          const SizedBox(width: 12),
          Expanded(
            child: Text('Ranking impact is applied once the result is confirmed.',
                style: AppText.small().copyWith(fontSize: 12.5)),
          ),
        ]),
      );
    }
    // Applied — rating v2 keeps my change in ranking_history. Fall back to the
    // legacy match_players.elo_* pair only for rows settled before v2.
    final rBefore = (_myRating?['rating_before'] as num?)?.toDouble();
    final rAfter = (_myRating?['rating_after'] as num?)?.toDouble();
    final rDelta = (_myRating?['delta'] as num?)?.toDouble() ??
        ((rBefore != null && rAfter != null) ? rAfter - rBefore : null);
    // ranking_history is the only source now; match_players.elo_before/after
    // were dropped with the v1 layer (they stopped being written at rating v2).
    final lvBefore = rBefore;
    final lvAfter = rAfter;
    final lvDelta =
        rDelta ?? ((lvBefore != null && lvAfter != null) ? lvAfter - lvBefore : null);
    final delta = lvDelta;
    // Unknown change reads neutral — a red down-arrow for "not recorded" would
    // tell the player they lost rating when nothing says they did.
    final tint = delta == null
        ? AppColors.inkSoft
        : (delta >= 0 ? AppColors.success : AppColors.danger);
    return AppCard(
      child: Row(children: [
        Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(11)),
          child: Icon(
              delta == null
                  ? Icons.trending_flat_rounded
                  : (delta >= 0
                      ? Icons.trending_up_rounded
                      : Icons.trending_down_rounded),
              size: 19,
              color: tint),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Your level', style: AppText.small().copyWith(fontSize: 11.5)),
            Text(
                lvBefore != null && lvAfter != null
                    ? '${RankingScale.fmtLevel(lvBefore)} → ${RankingScale.fmtLevel(lvAfter)}'
                      '  (${lvDelta! >= 0 ? '+' : '−'}${lvDelta.abs().toStringAsFixed(2)})'
                    : 'Updated',
                style: AppText.bodyStrong().copyWith(fontSize: 14)),
            // Only when the headline couldn't show before → after, so the
            // number isn't printed twice.
            if (delta != null && (lvBefore == null || lvAfter == null))
              Text(
                  'Rating ${delta >= 0 ? '+' : '−'}${delta.abs().toStringAsFixed(2)}',
                  style: AppText.small().copyWith(fontSize: 11)),
          ]),
        ),
      ]),
    );
  }

  Widget _banner(String kind, IconData icon, String title, String body) {
    final c = switch (kind) {
      'success' => AppColors.success,
      'danger' => AppColors.danger,
      'gold' => AppColors.gold,
      _ => AppColors.primary,
    };
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.withValues(alpha: 0.3)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 20, color: c),
        const SizedBox(width: 11),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: AppText.bodyStrong().copyWith(fontSize: 13.5)),
            const SizedBox(height: 3),
            Text(body, style: AppText.small().copyWith(fontSize: 12, height: 1.45)),
          ]),
        ),
      ]),
    );
  }

  // ── Footer ─────────────────────────────────────────────────────────────

  Widget _footer() {
    Widget? content;

    if (!_inMatch && _myInvite != null && _status == 'open') {
      // I was asked to partner up. Answering is the only thing to do here —
      // accepting is what actually puts me in the match.
      content = Row(children: [
        Expanded(
          child: AppButton(_busy ? '…' : 'Decline',
              full: true, height: 52, variant: AppBtnVariant.ghost,
              onPressed: _busy ? null : () => _answerInvite(false)),
        ),
        const SizedBox(width: 10),
        Expanded(
          flex: 2,
          child: AppButton(_busy ? 'Joining…' : 'Accept invite',
              full: true, height: 52, icon: Icons.check_rounded,
              onPressed: _busy ? null : () => _answerInvite(true)),
        ),
      ]);
    } else if (!_inMatch && _status == 'open') {
      final noSeats = _players.length + _invites.length >= 4;
      content = AppButton(
          _busy
              ? 'Joining…'
              : (noSeats ? 'Every spot is taken' : 'Join Match'),
          full: true, height: 52, icon: Icons.sports_tennis_rounded,
          onPressed: (_busy || noSeats) ? null : _join);
    } else if (_view == 1 && _inMatch && _full) {
      // Score/confirm only for a full 2v2.
      if ((_status == 'open' || _status == 'full' || _status == 'in_progress') && _ended) {
        content = AppButton(_busy ? 'Submitting…' : 'Submit Score',
            full: true, height: 52, icon: Icons.check_rounded,
            onPressed: (_decided && !_busy) ? _submit : null);
      } else if (_status == 'disputed') {
        content = AppButton(_busy ? 'Submitting…' : 'Re-submit Score',
            full: true, height: 52, icon: Icons.check_rounded,
            onPressed: (_decided && !_busy) ? _submit : null);
      } else if (_status == 'pending_confirm' && !_iSubmitted) {
        content = Row(children: [
          Expanded(
              child: AppButton('Reject', full: true, height: 52,
                  variant: AppBtnVariant.ghost,
                  onPressed: _busy ? null : () => _confirm(false))),
          const SizedBox(width: 10),
          Expanded(
              child: AppButton(_busy ? '…' : 'Confirm Result',
                  full: true, height: 52, icon: Icons.check_rounded,
                  onPressed: _busy ? null : () => _confirm(true))),
        ]);
      } else if (_status == 'pending_confirm' && _iSubmitted) {
        content = AppButton('Awaiting $_oppFirst', full: true, height: 52,
            icon: Icons.schedule_rounded, onPressed: null);
      }
    } else if (_isHost &&
        (_status == 'open' || _status == 'full') &&
        (!_ended || !_full)) {
      // Host can call off their own match — before the start, or after the
      // start if it never filled. (A full, started match goes to scoring.)
      content = AppButton(_busy ? 'Cancelling…' : 'Cancel match',
          full: true, height: 52, variant: AppBtnVariant.ghost,
          icon: Icons.close_rounded, onPressed: _busy ? null : _cancel);
    } else if (_inMatch &&
        (_status == 'open' || _status == 'full') &&
        !_ended) {
      content = AppButton(_busy ? 'Leaving…' : 'Leave Match',
          full: true, height: 52, variant: AppBtnVariant.ghost,
          onPressed: _busy ? null : _leave);
    }

    if (content == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 26),
      decoration: const BoxDecoration(
          color: AppColors.bg,
          border: Border(top: BorderSide(color: AppColors.lineSoft))),
      child: content,
    );
  }
}
