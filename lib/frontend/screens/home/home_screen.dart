import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/frontend/widgets/screen_bar.dart';
import 'package:padel_clay/backend/models/ranking_scale.dart';
import '../matches/find_match_screen.dart';
import '../detail/match_detail_screen.dart';
import '../tournaments/tournament_detail_screen.dart';
import '../profile/notifications_screen.dart';

class HomeScreen extends StatefulWidget {
  final VoidCallback? onSeeStore;
  final VoidCallback? onSeeTournaments;
  final PlayerProfile profile;
  final String displayName;
  final String initials;

  const HomeScreen({
    super.key,
    this.onSeeStore,
    this.onSeeTournaments,
    this.profile = PlayerProfile.fresh,
    this.displayName = '',
    this.initials = 'P',
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Map<String, dynamic>> _myMatches = [];
  List<Map<String, dynamic>> _tournaments = [];
  bool _loading = true;

  static SupabaseClient get _db => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _loading = true);
    await Future.wait([_fetchMatches(), _fetchTournaments()]);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _fetchMatches() async {
    try {
      final uid = _db.auth.currentUser?.id;
      if (uid == null) return;

      // Step 1: match IDs the player is part of
      final joined = await _db
          .from('match_players')
          .select('match_id')
          .eq('player_id', uid);
      final ids = (joined as List).map((r) => r['match_id'] as String).toList();
      if (ids.isEmpty) return;

      // Step 2: my upcoming matches + recent ones that still need action
      // (score submission, confirmation, or dispute resolution).
      final weekAgo =
          DateTime.now().subtract(const Duration(days: 7)).toIso8601String();
      final rows = await _db
          .from('matches')
          .select('id, status, match_type, scheduled_at, courts(name, venue_name), match_players(player_id)')
          .inFilter('id', ids)
          .inFilter('status',
              ['open', 'full', 'in_progress', 'pending_confirm', 'disputed'])
          .gte('scheduled_at', weekAgo)
          .order('scheduled_at')
          .limit(5);

      if (mounted) _myMatches = List<Map<String, dynamic>>.from(rows as List);
    } catch (_) {}
  }

  Future<void> _fetchTournaments() async {
    try {
      final rows = await _db
          .from('tournaments')
          .select('id, name, venue_name, status, start_date, capacity, entry_fee')
          .inFilter('status', ['open', 'upcoming'])
          .order('start_date')
          .limit(3);
      if (mounted) _tournaments = List<Map<String, dynamic>>.from(rows as List);
    } catch (_) {}
  }

  Future<void> _openFindMatch(BuildContext c) async {
    await Navigator.of(c)
        .push(MaterialPageRoute(builder: (_) => const FindMatchScreen()));
    _loadData();
  }

  Future<void> _openMatch(BuildContext c, String id) async {
    await Navigator.of(c).push(
        MaterialPageRoute(builder: (_) => MatchDetailScreen(matchId: id)));
    _loadData();
  }

  Future<void> _openTournament(BuildContext c, String id) async {
    await Navigator.of(c).push(MaterialPageRoute(
        builder: (_) => TournamentDetailScreen(tournamentId: id)));
    _loadData();
  }

  void _openNotifications(BuildContext c) => Navigator.of(c)
      .push(MaterialPageRoute(builder: (_) => const NotificationsScreen()));

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ScreenBar(
          title: 'Padel Egypt',
          leadingInitials: widget.initials.isNotEmpty ? widget.initials : 'P',
          actions: [
            IconChip(Icons.notifications_none_rounded,
                onTap: () => _openNotifications(context)),
          ],
        ),
        Expanded(
          child: RefreshIndicator(
            color: AppColors.primary,
            onRefresh: _loadData,
            child: ListView(
              padding: const EdgeInsets.only(bottom: 120),
              children: [
                _Greeting(
                  displayName: widget.displayName,
                  profile: widget.profile,
                ),
                if (!widget.profile.ranking.placed)
                  _PlacementWelcome(
                    ranking: widget.profile.ranking,
                    onFindMatch: () => _openFindMatch(context),
                  ),
                const SizedBox(height: 24),
                SectionHeader('Recent Form'),
                _recentForm(),
                const SizedBox(height: AppSpacing.section),
                SectionHeader('Upcoming Matches',
                    action: 'Find a Match',
                    onAction: () => _openFindMatch(context)),
                _upcomingMatches(context),
                const SizedBox(height: AppSpacing.section),
                SectionHeader('Tournaments',
                    action: 'Browse', onAction: widget.onSeeTournaments),
                _tournamentsSection(),
                const SizedBox(height: AppSpacing.section),
                SectionHeader('Store', action: 'Browse', onAction: widget.onSeeStore),
                _StoreCta(onTap: widget.onSeeStore),
                const SizedBox(height: AppSpacing.section),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── Recent Form ──────────────────────────────────────────────────────────

  Widget _recentForm() {
    final recent = widget.profile.recent;
    if (recent.isEmpty) {
      return Padding(
        padding: AppSpacing.screenH,
        child: AppCard(
          child: Row(children: [
            Container(
              width: 38, height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: AppColors.field, borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.history_rounded, size: 19, color: AppColors.inkFaint),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('No matches played yet',
                    style: AppText.bodyStrong().copyWith(fontSize: 13.5)),
                const SizedBox(height: 2),
                Text('Your win/loss form appears here after your first match.',
                    style: AppText.small().copyWith(fontSize: 12, height: 1.4)),
              ]),
            ),
          ]),
        ),
      );
    }

    final last = recent.take(5).toList();
    final wins = last.where((m) => m.won).length;
    return Padding(
      padding: AppSpacing.screenH,
      child: AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('$wins wins in last ${last.length} matches',
                    style: AppText.bodyStrong().copyWith(fontSize: 13.5)),
                const SizedBox(height: 2),
                Text(last.first.date,
                    style: AppText.small().copyWith(fontSize: 12)),
              ]),
            ),
            Row(children: [
              for (final m in last) ...[
                const SizedBox(width: 5),
                Container(
                  width: 28, height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: (m.won ? AppColors.success : AppColors.danger)
                        .withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Text(m.won ? 'W' : 'L',
                      style: AppText.stat(12,
                          m.won ? AppColors.success : AppColors.danger)),
                ),
              ],
            ]),
          ]),
        ]),
      ),
    );
  }

  // ── Upcoming Matches ─────────────────────────────────────────────────────

  Widget _upcomingMatches(BuildContext context) {
    if (_loading) {
      return Padding(
        padding: AppSpacing.screenH,
        child: AppCard(
          child: const Center(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.primary),
            ),
          ),
        ),
      );
    }
    if (_myMatches.isEmpty) {
      return Padding(
        padding: AppSpacing.screenH,
        child: AppCard(
          child: Row(children: [
            Container(
              width: 38, height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: AppColors.field, borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.sports_tennis_rounded,
                  size: 19, color: AppColors.inkFaint),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('No upcoming matches',
                    style: AppText.bodyStrong().copyWith(fontSize: 13.5)),
                const SizedBox(height: 2),
                Text('Find a match and book a court to get started.',
                    style: AppText.small().copyWith(fontSize: 12, height: 1.4)),
              ]),
            ),
            const SizedBox(width: 8),
            AppButton('Find', onPressed: () => _openFindMatch(context)),
          ]),
        ),
      );
    }
    return Padding(
      padding: AppSpacing.screenH,
      child: AppCard(
        padding: EdgeInsets.zero,
        child: Column(children: [
          for (int i = 0; i < _myMatches.length; i++)
            _MatchTile(_myMatches[i], divider: i > 0,
                onTap: () => _openMatch(context, _myMatches[i]['id'] as String)),
        ]),
      ),
    );
  }

  // ── Tournaments ──────────────────────────────────────────────────────────

  Widget _tournamentsSection() {
    if (_loading) {
      return Padding(
        padding: AppSpacing.screenH,
        child: AppCard(
          child: const Center(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.primary),
            ),
          ),
        ),
      );
    }
    if (_tournaments.isEmpty) {
      return Padding(
        padding: AppSpacing.screenH,
        child: AppCard(
          child: Row(children: [
            Container(
              width: 38, height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: AppColors.field, borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.emoji_events_outlined,
                  size: 19, color: AppColors.inkFaint),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('No open tournaments',
                    style: AppText.bodyStrong().copyWith(fontSize: 13.5)),
                const SizedBox(height: 2),
                Text('Check back soon for upcoming events.',
                    style: AppText.small().copyWith(fontSize: 12, height: 1.4)),
              ]),
            ),
          ]),
        ),
      );
    }
    return Padding(
      padding: AppSpacing.screenH,
      child: AppCard(
        padding: EdgeInsets.zero,
        child: Column(children: [
          for (int i = 0; i < _tournaments.length; i++)
            _TournamentTile(_tournaments[i], divider: i > 0,
                onTap: () => _openTournament(context, _tournaments[i]['id'] as String)),
        ]),
      ),
    );
  }
}

// ── Match tile ───────────────────────────────────────────────────────────────

class _MatchTile extends StatelessWidget {
  final Map<String, dynamic> match;
  final bool divider;
  final VoidCallback? onTap;
  const _MatchTile(this.match, {this.divider = false, this.onTap});

  static String _fmtTime(String? iso) {
    if (iso == null) return '—';
    try {
      final dt = DateTime.parse(iso).toLocal();
      final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
      final m = dt.minute.toString().padLeft(2, '0');
      final ampm = dt.hour < 12 ? 'AM' : 'PM';
      const months = ['Jan','Feb','Mar','Apr','May','Jun',
                      'Jul','Aug','Sep','Oct','Nov','Dec'];
      return '${months[dt.month - 1]} ${dt.day}  ·  $h:$m $ampm';
    } catch (_) {
      return iso.substring(0, 10);
    }
  }

  @override
  Widget build(BuildContext context) {
    final court = match['courts'] as Map?;
    final courtName = court?['venue_name'] as String? ?? court?['name'] as String? ?? 'TBD';
    final players = (match['match_players'] as List?)?.length ?? 0;
    final isRanked = match['match_type'] == 'ranked';
    final status = match['status'] as String? ?? 'open';
    final statusColor = switch (status) {
      'in_progress' => AppColors.success,
      'full' => AppColors.warn,
      'pending_confirm' => AppColors.gold,
      'disputed' => AppColors.danger,
      _ => AppColors.primary,
    };
    final statusLabel = switch (status) {
      'pending_confirm' => 'Score pending',
      'in_progress' => 'In progress',
      'disputed' => 'Disputed',
      _ => status[0].toUpperCase() + status.substring(1),
    };

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
          border: divider
              ? const Border(top: BorderSide(color: AppColors.line))
              : null),
      child: Row(children: [
        Container(
          width: 40, height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(11),
          ),
          child: const Icon(Icons.sports_tennis_rounded,
              size: 20, color: AppColors.primary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              AppTag(isRanked ? 'Ranked' : 'Casual',
                  color: isRanked ? AppColors.warn : AppColors.primary),
              const SizedBox(width: 6),
              AppTag(statusLabel, color: statusColor),
            ]),
            const SizedBox(height: 4),
            Text(courtName,
                style: AppText.bodyStrong().copyWith(fontSize: 13),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text(_fmtTime(match['scheduled_at'] as String?),
                style: AppText.small().copyWith(fontSize: 11.5)),
          ]),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('$players/4',
              style: AppText.bodyStrong(AppColors.ink).copyWith(fontSize: 13)),
          const SizedBox(height: 2),
          Text('players',
              style: AppText.tag(AppColors.inkFaint).copyWith(fontSize: 10)),
        ]),
      ]),
    ));
  }
}

// ── Tournament tile ──────────────────────────────────────────────────────────

class _TournamentTile extends StatelessWidget {
  final Map<String, dynamic> t;
  final bool divider;
  final VoidCallback? onTap;
  const _TournamentTile(this.t, {this.divider = false, this.onTap});

  static String _fmtDate(String? d) {
    if (d == null) return '—';
    try {
      final dt = DateTime.parse(d);
      const months = ['Jan','Feb','Mar','Apr','May','Jun',
                      'Jul','Aug','Sep','Oct','Nov','Dec'];
      return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
    } catch (_) {
      return d;
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = t['name'] as String? ?? 'Tournament';
    final venue = t['venue_name'] as String? ?? '';
    final status = t['status'] as String? ?? 'upcoming';
    final startDate = _fmtDate(t['start_date'] as String?);
    final fee = (t['entry_fee'] as num?)?.toDouble() ?? 0;
    final feeLabel = fee > 0 ? 'EGP ${fee.toStringAsFixed(0)}' : 'Free';
    final statusColor = status == 'open' ? AppColors.success : AppColors.warn;
    final statusLabel = status[0].toUpperCase() + status.substring(1).replaceAll('_', ' ');

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
          border: divider
              ? const Border(top: BorderSide(color: AppColors.line))
              : null),
      child: Row(children: [
        Container(
          width: 40, height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.warn.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(11),
          ),
          child: const Icon(Icons.emoji_events_outlined,
              size: 20, color: AppColors.warn),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              AppTag(statusLabel, color: statusColor),
              const SizedBox(width: 6),
              AppTag(feeLabel, color: AppColors.inkSoft),
            ]),
            const SizedBox(height: 4),
            Text(name,
                style: AppText.bodyStrong().copyWith(fontSize: 13),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text(venue.isNotEmpty ? '$startDate  ·  $venue' : startDate,
                style: AppText.small().copyWith(fontSize: 11.5),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
        const Icon(Icons.chevron_right_rounded, size: 18, color: AppColors.inkFaint),
      ]),
    ));
  }
}

// ── Greeting ─────────────────────────────────────────────────────────────────

class _Greeting extends StatelessWidget {
  final String displayName;
  final PlayerProfile profile;
  const _Greeting({required this.displayName, required this.profile});

  String get _firstName {
    final parts = displayName.trim().split(' ');
    return parts.isNotEmpty && parts.first.isNotEmpty ? parts.first : 'there';
  }

  String get _greetingWord {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 18) return 'Good afternoon';
    return 'Good evening';
  }

  String get _dateLabel {
    final now = DateTime.now();
    const days = ['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'];
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${days[now.weekday - 1]}, ${now.day} ${months[now.month - 1]}';
  }

  String get _rankLabel {
    if (!profile.ranking.placed) return 'Unranked';
    final div = RankingScale.divisionFor(profile.ranking.level);
    return 'Div ${div.key}';
  }

  Color get _rankColor {
    if (!profile.ranking.placed) return AppColors.inkSoft;
    final div = RankingScale.divisionFor(profile.ranking.level);
    switch (div.metal) {
      case 'elite': return AppColors.primary;
      case 'gold': return AppColors.warn;
      case 'silver': return AppColors.inkSoft;
      default: return AppColors.inkSoft;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 14, AppSpacing.screen, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$_greetingWord, $_firstName',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.cardTitle().copyWith(fontSize: 20)),
                const SizedBox(height: 3),
                Text(_dateLabel, style: AppText.small()),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            decoration: BoxDecoration(
              color: _rankColor.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: _rankColor.withValues(alpha: 0.25)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(
                profile.ranking.placed
                    ? Icons.military_tech_rounded
                    : Icons.lock_outline_rounded,
                size: 12, color: _rankColor),
              const SizedBox(width: 5),
              Text(_rankLabel,
                  style: AppText.bodyStrong(_rankColor).copyWith(fontSize: 12)),
            ]),
          ),
        ],
      ),
    );
  }
}

// ── Placement welcome (new-user hero) ────────────────────────────────────────

class _PlacementWelcome extends StatelessWidget {
  final Ranking ranking;
  final VoidCallback onFindMatch;
  const _PlacementWelcome({required this.ranking, required this.onFindMatch});

  @override
  Widget build(BuildContext context) {
    final total = RankingScale.placementTotal;
    final done = ranking.placement.clamp(0, total);
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 16, AppSpacing.screen, 0),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: AppRadius.cardR,
          gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.hero, AppColors.hero2]),
          boxShadow: kCardShadow,
        ),
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const AppTag('Welcome to Padel', color: AppColors.primary, solid: true),
                Row(children: [
                  const Icon(Icons.emoji_events_outlined,
                      size: 13, color: AppColors.heroFaint),
                  const SizedBox(width: 5),
                  Text('Unranked',
                      style: AppText.tag(AppColors.heroFaint).copyWith(fontSize: 11)),
                ]),
              ],
            ),
            const SizedBox(height: 16),
            Text('Play your first match',
                style: AppText.stat(22, AppColors.heroInk)
                    .copyWith(height: 1.1, letterSpacing: -0.5)),
            const SizedBox(height: 6),
            Text(
                'Complete $total placement matches to unlock your division, rank & ELO.',
                style: AppText.small(AppColors.heroFaint)
                    .copyWith(fontSize: 13, height: 1.5)),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
              decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(12)),
              child: Column(children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Placement progress',
                        style: AppText.small(AppColors.heroFaint)
                            .copyWith(fontSize: 11)),
                    Text('$done / $total',
                        style: AppText.bodyStrong(AppColors.heroInk)
                            .copyWith(fontSize: 11)),
                  ],
                ),
                const SizedBox(height: 8),
                Row(children: [
                  for (int i = 0; i < total; i++) ...[
                    if (i > 0) const SizedBox(width: 5),
                    Expanded(
                      child: Container(
                        height: 6,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(3),
                          color: i < done
                              ? AppColors.primary
                              : Colors.white.withValues(alpha: 0.14),
                        ),
                      ),
                    ),
                  ],
                ]),
              ]),
            ),
            const SizedBox(height: 14),
            AppButton('Find a Match', full: true, height: 48, onPressed: onFindMatch),
          ],
        ),
      ),
    );
  }
}

// ── Store CTA ────────────────────────────────────────────────────────────────

class _StoreCta extends StatelessWidget {
  final VoidCallback? onTap;
  const _StoreCta({this.onTap});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: AppSpacing.screenH,
      child: AppCard(
        onTap: onTap,
        child: Row(children: [
          Container(
            width: 48, height: 48,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.sports_tennis_rounded,
                size: 26, color: AppColors.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Padel Gear', style: AppText.bodyStrong().copyWith(fontSize: 14)),
              const SizedBox(height: 2),
              Text('Rackets, balls, shoes and more.',
                  style: AppText.small().copyWith(fontSize: 12.5)),
            ]),
          ),
          const Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.inkFaint),
        ]),
      ),
    );
  }
}
