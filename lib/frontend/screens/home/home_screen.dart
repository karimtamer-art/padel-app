import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/frontend/widgets/screen_bar.dart';
import 'package:padel_clay/frontend/widgets/padel_refresh.dart';
import 'package:padel_clay/frontend/widgets/skeleton.dart';
import 'package:padel_clay/frontend/widgets/app_toast.dart';
import 'package:padel_clay/backend/models/ranking_scale.dart';
import 'package:padel_clay/backend/models/mock_data.dart';
import 'package:padel_clay/backend/services/tournament_service.dart';
import 'package:padel_clay/backend/services/notification_service.dart';
import 'package:padel_clay/backend/services/store_service.dart';
import 'package:padel_clay/backend/services/community_service.dart';
import 'package:padel_clay/backend/services/profile_service.dart';
import 'package:padel_clay/backend/services/match_service.dart';
import 'package:padel_clay/backend/services/dm_service.dart';
import 'package:padel_clay/backend/services/season_service.dart';
import 'package:padel_clay/frontend/feature_flags.dart';
import 'matchmaking_hero.dart';
import '../leaderboard/season_leaderboard_screen.dart';
import '../detail/match_detail_screen.dart';
import '../detail/join_match_sheet.dart';
import '../tournaments/tournament_detail_screen.dart';
import '../profile/notifications_screen.dart';
import '../community/community_hub_screen.dart';
import '../chat/messages_inbox_screen.dart';

class HomeScreen extends StatefulWidget {
  final VoidCallback? onSeeStore;
  final VoidCallback? onSeeTournaments;
  final ValueChanged<Product>? onAddToCart;
  final PlayerProfile profile;
  final String displayName;
  final String initials;
  /// Bumped by the shell to ask Home to refetch WITHOUT recreating its State
  /// (so the unread badge / community card don't flash back to empty).
  final int refreshTick;

  const HomeScreen({
    super.key,
    this.onSeeStore,
    this.onSeeTournaments,
    this.onAddToCart,
    this.profile = PlayerProfile.fresh,
    this.displayName = '',
    this.initials = 'P',
    this.refreshTick = 0,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Map<String, dynamic>> _myMatches = [];
  // Open matches from other players I'm allowed to see (mm_candidates) —
  // joinable straight from Home, no radar needed.
  List<Map<String, dynamic>> _joinable = [];
  String? _joining; // match_id currently being joined
  List<Map<String, dynamic>> _tournaments = [];
  List<Map<String, dynamic>> _featured = [];
  Community? _community;
  bool _communityLoaded = false;
  // Live season standings for the "Season Leaderboard" card. Null = no season
  // is published, and the whole section stays hidden.
  SeasonOverview? _season;
  List<MemberLite> _communityMembers = [];
  int _communityEventsWeek = 0;
  int _unread = 0;
  int _dmUnread = 0; // unread direct messages → Messages icon badge
  int _communityUnread = 0; // unread community channel messages → card badge
  // Matches in the player's rating band near them (the "N near you" teaser).
  int _bandCount = 0;
  // Most recent completed-but-unacked match → the "MATCH COMPLETE" hero.
  Map<String, dynamic>? _resultHero;
  bool _loading = true;
  // Local latch so the one-time placement reveal disappears the instant it's
  // dismissed (the persisted flag catches the next launch).
  bool _revealDismissed = false;
  // The player tapped "Find a Match" → the hero morphs into the searching radar.
  bool _searching = false;
  // Chosen day + time-range window for a scheduled search (null = quick/now).
  DateTime? _searchFrom;
  DateTime? _searchTo;
  RealtimeChannel? _notifChannel;

  static SupabaseClient get _db => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _loadData();
    _subscribeNotifications();
    _restoreSearching();
  }

  @override
  void didUpdateWidget(HomeScreen old) {
    super.didUpdateWidget(old);
    // Shell asked for a refresh (tab re-focus / return from a screen). Refetch
    // in place — State is preserved, so nothing flashes back to empty.
    if (widget.refreshTick != old.refreshTick) _loadData(silent: true);
  }

  @override
  void dispose() {
    if (_notifChannel != null) _db.removeChannel(_notifChannel!);
    super.dispose();
  }

  /// Live badge: bump the unread count the moment the orders trigger inserts a
  /// notification for this user. RLS limits the stream to the user's own rows.
  void _subscribeNotifications() {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return;
    _notifChannel = _db
        .channel('home-notifications-$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq, column: 'user_id', value: uid),
          callback: (payload) {
            if (!mounted) return;
            setState(() {
              _unread++;
              if (payload.newRecord['type'] == 'message') _dmUnread++;
            });
          },
        )
        .subscribe();
  }

  Future<void> _loadData({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
    await Future.wait([
      _fetchMatches(),
      _fetchJoinable(),
      _fetchTournaments(),
      _fetchUnread(),
      _fetchDmUnread(),
      _fetchFeatured(),
      if (Features.community) _fetchCommunity(),
      _fetchBandCount(),
      _fetchResultHero(),
      _fetchSeason(),
    ]);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _fetchSeason() async {
    final s = await SeasonService.overview();
    if (mounted) _season = s;
  }

  Future<void> _openLeaderboard(BuildContext c) async {
    await Navigator.of(c).push(MaterialPageRoute(
        builder: (_) => SeasonLeaderboardScreen(initial: _season)));
    await _fetchSeason();
    if (mounted) setState(() {});
  }

  Future<void> _fetchMatches() async {
    try {
      final uid = _db.auth.currentUser?.id;
      if (uid == null) return;

      // Sweep under-filled matches that ran past their grace window so they
      // drop off Home (fallback for when pg_cron isn't running the server job).
      await MatchService.expireStaleMatches();

      // Step 1: match IDs the player is part of
      final joined = await _db
          .from('match_players')
          .select('match_id')
          .eq('player_id', uid);
      final ids = (joined as List).map((r) => r['match_id'] as String).toList();
      if (ids.isEmpty) return;

      // Step 2: my active matches — upcoming plus any still needing action
      // (score submission, confirmation, dispute). No age filter: a match stuck
      // in pending_confirm/disputed must always keep an entry point here (the
      // status filter already excludes completed/cancelled, so the list stays
      // small, and stale 'open' ones are auto-cancelled by the sweep).
      // NOTE: postgrest's .order() defaults to ascending: false, so this pulls
      // the LATEST rows — deliberate, it guarantees upcoming matches survive the
      // limit even when old pending_confirm/disputed ones pile up. The list is
      // re-sorted soonest-first below, which is the order the UI wants.
      final rows = await _db
          .from('matches')
          .select('id, status, match_type, scheduled_at, court_id, '
              'courts(name, venue_name, lat, lng, address), '
              'match_players(player_id, team, profiles(name, avatar_url))')
          .inFilter('id', ids)
          .inFilter('status',
              ['open', 'full', 'in_progress', 'pending_confirm', 'disputed'])
          .order('scheduled_at')
          .limit(20);

      final list = List<Map<String, dynamic>>.from(rows as List)
        ..sort((a, b) {
          final da = DateTime.tryParse(a['scheduled_at'] as String? ?? '');
          final db = DateTime.tryParse(b['scheduled_at'] as String? ?? '');
          if (da == null || db == null) return 0;
          return da.compareTo(db);
        });
      if (mounted) _myMatches = list;
    } catch (_) {}
  }

  /// Open matches hosted by other players that I'm allowed to see. Casual ones
  /// come from anybody (unrated → no band/placement gate); competitive stays
  /// inside my rating band. Server-side rules live in `mm_candidates`.
  Future<void> _fetchJoinable() async {
    final rows = await MatchService.fetchBandCandidates(limit: 10);
    if (mounted) _joinable = rows;
  }

  /// Candidate rows come back flat from the RPC; reshape them into the same
  /// map `_UpcomingMatchCard` reads for my own matches.
  static Map<String, dynamic> _asMatch(Map<String, dynamic> c) => {
        'id': c['match_id'],
        'match_type': c['match_type'],
        'scheduled_at': c['scheduled_at'],
        'courts': {'name': c['court_name'], 'venue_name': c['venue_name']},
      };

  /// Join straight from the card: same solo-or-with-a-partner question the
  /// radar asks, then `mm_accept` (capacity + band re-checked server-side).
  Future<void> _joinCandidate(Map<String, dynamic> c) async {
    final id = c['match_id'] as String?;
    if (id == null || _joining != null) return;
    final seats = 4 - ((c['players'] as num?)?.toInt() ?? 0);
    final choice = await showJoinMatchSheet(context, slotsLeft: seats);
    if (choice == null || !mounted) return;
    setState(() => _joining = id);
    final err = await MatchService.acceptCandidate(id, partnerId: choice.partnerId);
    if (!mounted) return;
    setState(() => _joining = null);
    if (err != null) {
      AppToast.show(context, err, kind: ToastKind.error);
      _loadData(silent: true); // it may have filled up — refresh the row
      return;
    }
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => MatchDetailScreen(matchId: id)));
    if (mounted) _loadData(silent: true);
  }

  Future<void> _fetchTournaments() async {
    final rows = await TournamentService.fetchTournaments();
    final visible = rows.where((t) {
      final entries = ((t['tournament_entries'] as List?) ?? const [])
          .where((e) => e['status'] != 'withdrawn')
          .length;
      final ds = TournamentService.tournamentStatus(t, entries);
      return ds != 'completed' && ds != 'cancelled';
    }).take(5).toList();
    if (mounted) _tournaments = visible;
  }

  // Matchmaking is now the home hero itself (MatchmakingHero), not a screen.
  // The search is ticket-backed so it survives the app closing (background push
  // brings the player back to the resumed radar).
  // Quick auto-match now (no window), or a scheduled search when from/to are set.
  void _startSearch({DateTime? from, DateTime? to}) {
    setState(() {
      _searchFrom = from;
      _searchTo = to;
      _searching = true;
    });
    MatchService.startSearch();
  }

  // "Choose a day & time" → pick a window first, then search scoped to it.
  Future<void> _scheduleSearch() async {
    final w = await showMatchWhenPicker(context, from: _searchFrom, to: _searchTo);
    if (w == null || !mounted) return;
    _startSearch(from: w.from, to: w.to);
  }

  void _stopSearch() {
    setState(() => _searching = false);
    MatchService.cancelSearch();
  }

  Future<void> _onMatchAccepted(String matchId) async {
    setState(() => _searching = false);
    MatchService.cancelSearch();
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => MatchDetailScreen(matchId: matchId)));
    _loadData(silent: true);
  }

  /// On launch, resume the radar if a fresh search ticket exists (e.g. the
  /// player tapped a "Match found" push). Runs once.
  Future<void> _restoreSearching() async {
    if (await MatchService.isSearching()) {
      if (mounted) setState(() => _searching = true);
    }
  }

  String get _searchLevelLabel {
    final r = widget.profile.ranking;
    return r.placed ? 'Div ${RankingScale.divisionFor(r.level).key}' : 'Placement';
  }

  /// Dismiss the one-time placement reveal: hide it now, persist that it's been
  /// seen (best-effort) so it doesn't reappear on the next launch.
  void _dismissReveal() {
    setState(() => _revealDismissed = true);
    ProfileService.markPlacementRevealed();
  }

  /// The match to surface in the hero: the soonest slot still ahead, or — when
  /// the start time has just passed — a match that's still alive.
  ///
  /// That second case matters: an under-filled match stays 'open' and keeps
  /// filling for the server's grace window past scheduled_at (mm_grace(), 30
  /// min) before expire_stale_matches cancels it. `_liveMatch` only covers
  /// 'full'/'in_progress', so without this an open match whose time just passed
  /// fell through every hero branch and Home flipped to "NO MATCH SCHEDULED"
  /// while the player still had a real match.
  Map<String, dynamic>? _nextUpcomingMatch() {
    final now = DateTime.now();
    const grace = Duration(minutes: 30); // mirrors mm_grace()
    Map<String, dynamic>? next;
    DateTime? nextAt;
    Map<String, dynamic>? started;
    DateTime? startedAt;

    for (final m in _myMatches) {
      final status = m['status'] as String?;
      if (status != 'open' && status != 'full' && status != 'in_progress') {
        continue; // pending_confirm / disputed have their own surfaces
      }
      final dt = DateTime.tryParse(m['scheduled_at'] as String? ?? '')?.toLocal();
      if (dt == null) {
        if (status == 'in_progress') return m;
        continue;
      }
      if (dt.isAfter(now)) {
        if (nextAt == null || dt.isBefore(nextAt)) {
          next = m;
          nextAt = dt;
        }
      } else if (status == 'in_progress' || dt.isAfter(now.subtract(grace))) {
        // Already started but not over: keep the one that started most recently.
        if (startedAt == null || dt.isAfter(startedAt)) {
          started = m;
          startedAt = dt;
        }
      }
    }
    // A match happening right now beats one scheduled later.
    return started ?? next;
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

  Future<void> _fetchUnread() async {
    final n = await NotificationService.unreadCount();
    if (mounted) _unread = n;
  }

  Future<void> _fetchDmUnread() async {
    final n = await DmService.unreadCount();
    if (mounted) _dmUnread = n;
  }

  Future<void> _fetchBandCount() async {
    final n = await MatchService.countCandidates();
    if (mounted) _bandCount = n;
  }

  Future<void> _fetchResultHero() async {
    final r = await MatchService.resultHero();
    if (mounted) _resultHero = r;
  }

  /// Ack the result hero and drop back to the booking state.
  Future<void> _ackResult(String matchId) async {
    setState(() => _resultHero = null);
    await MatchService.ackResult(matchId);
    _loadData(silent: true);
  }

  /// A match that's happening now: full, its start time has passed (within the
  /// last few hours), and it hasn't produced a result yet. Nothing sets an
  /// explicit 'in_progress', so "live" is derived from the clock.
  Map<String, dynamic>? _liveMatch() {
    final now = DateTime.now();
    for (final m in _myMatches) {
      final status = m['status'] as String?;
      if (status != 'full' && status != 'in_progress') continue;
      final dt = DateTime.tryParse(m['scheduled_at'] as String? ?? '')?.toLocal();
      if (dt == null) continue;
      if (!dt.isAfter(now) && dt.isAfter(now.subtract(const Duration(hours: 6)))) {
        return m;
      }
    }
    return null;
  }

  Future<void> _fetchFeatured() async {
    final rows = await StoreService.fetchHomeProducts(limit: 1);
    if (mounted) _featured = rows;
  }

  Future<void> _fetchCommunity() async {
    final c = await CommunityService.homeCommunity();
    List<MemberLite> members = [];
    int eventsWeek = 0;
    int unread = 0;
    if (c != null) {
      final results = await Future.wait([
        CommunityService.members(c.id, limit: 5),
        CommunityService.events(c.organizerId),
      ]);
      members = results[0] as List<MemberLite>;
      final events = results[1] as List<CommunityEvent>;
      final now = DateTime.now();
      final from = now.subtract(const Duration(days: 1));
      final to = now.add(const Duration(days: 7));
      eventsWeek = events.where((e) {
        final d = DateTime.tryParse(e.startDate ?? '');
        return d != null && d.isAfter(from) && d.isBefore(to);
      }).length;
      // Unread channel chatter → red badge on the card (members only).
      if (c.isMember) unread = await CommunityService.unreadChannelCount(c.id);
    }
    if (mounted) {
      _community = c;
      _communityMembers = members;
      _communityEventsWeek = eventsWeek;
      _communityUnread = unread;
      _communityLoaded = true;
    }
  }

  Future<void> _openCommunity(BuildContext c) async {
    final community = _community;
    if (community == null) return;
    await Navigator.of(c).push(MaterialPageRoute(
        builder: (_) => CommunityHubScreen(communityId: community.id)));
    _fetchCommunity();
    if (mounted) setState(() {});
  }

  Future<void> _openMessages(BuildContext c) async {
    await Navigator.of(c)
        .push(MaterialPageRoute(builder: (_) => const MessagesInboxScreen()));
    // Reading chats may have marked messages read — refresh the badge.
    await _fetchDmUnread();
    if (mounted) setState(() {});
  }

  Future<void> _openNotifications(BuildContext c) async {
    await Navigator.of(c)
        .push(MaterialPageRoute(builder: (_) => const NotificationsScreen()));
    // Coming back, the inbox may have been marked read — refresh the badge.
    await _fetchUnread();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final liveMatch = _liveMatch();
    final nextMatch = _nextUpcomingMatch();
    return Column(
      children: [
        ScreenBar(
          title: 'Padel Rivals',
          leadingInitials: widget.initials.isNotEmpty ? widget.initials : 'P',
          actions: [
            IconChip(Icons.forum_outlined,
                badge: _dmUnread, onTap: () => _openMessages(context)),
            const SizedBox(width: 10),
            IconChip(Icons.notifications_none_rounded,
                badge: _unread, onTap: () => _openNotifications(context)),
          ],
        ),
        Expanded(
          child: PadelRefresh(
            onRefresh: _loadData,
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.only(bottom: 120),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                _Greeting(
                  displayName: widget.displayName,
                  profile: widget.profile,
                ),
                // The top hero slot is never empty for a placed player: it
                // cycles searching → reveal → result → live → next-match →
                // book-next as their state changes.
                if (_searching)
                  MatchmakingHero(
                    initials: widget.initials.isNotEmpty ? widget.initials : 'P',
                    levelLabel: _searchLevelLabel,
                    onAccepted: _onMatchAccepted,
                    onCancel: _stopSearch,
                    initialFrom: _searchFrom,
                    initialTo: _searchTo,
                  )
                else if (!widget.profile.ranking.placed)
                  _PlacementWelcome(
                    ranking: widget.profile.ranking,
                    onFindMatch: _startSearch,
                  )
                // Just placed and hasn't seen the celebration → one-time reveal.
                else if (!widget.profile.placementRevealed && !_revealDismissed)
                  _PlacementReveal(
                    profile: widget.profile,
                    onNext: _dismissReveal,
                  )
                // A match just finished → one-time result celebration.
                else if (_resultHero != null)
                  _ResultHero(
                    result: _resultHero!,
                    onNext: () => _ackResult(_resultHero!['match_id'] as String),
                  )
                // A match is happening right now → live / check-in.
                else if (liveMatch != null)
                  _LiveHero(
                    match: liveMatch,
                    myId: _db.auth.currentUser?.id,
                    onEnterScore: () =>
                        _openMatch(context, liveMatch['id'] as String),
                  )
                // Has a booked match → surface it as the hero.
                else if (nextMatch != null)
                  _NextMatchHero(
                    match: nextMatch,
                    myId: _db.auth.currentUser?.id,
                    onTap: () => _openMatch(context, nextMatch['id'] as String),
                  )
                // Otherwise nudge them to book their next game (never blank).
                else if (!_loading)
                  _BookNextHero(
                    ranking: widget.profile.ranking,
                    bandCount: _bandCount,
                    onFindMatch: _startSearch,
                    onSchedule: _scheduleSearch,
                  ),
                const SizedBox(height: 24),
                SectionHeader('Recent Form'),
                _recentForm(),
                if (_season != null) ...[
                  const SizedBox(height: 24),
                  SectionHeader('Season Leaderboard',
                      action: 'View',
                      onAction: () => _openLeaderboard(context)),
                  SeasonHomeCard(
                    data: _season!,
                    onTap: () => _openLeaderboard(context),
                  ),
                ],
                // Hidden for launch — see Features.community.
                if (Features.community)
                  if (!_communityLoaded) ...[
                    const SizedBox(height: 24),
                    const SectionHeader('Your Community'),
                    _communitySkeleton(),
                  ] else ...[
                    const SizedBox(height: 24),
                    SectionHeader(
                        _community == null
                            ? 'Community'
                            : (_community!.isMember
                                ? 'Your Community'
                                : 'Discover a Community'),
                        action:
                            (_community?.isMember ?? false) ? 'View' : 'Have a code?',
                        onAction: (_community?.isMember ?? false)
                            ? () => _openCommunity(context)
                            : () => _promptJoinByCode(context)),
                    if (_community != null)
                      _communitySection()
                    else
                      _communityCodePrompt(),
                  ],
                const SizedBox(height: AppSpacing.section),
                SectionHeader('Upcoming Matches',
                    action: 'View All',
                    onAction: _startSearch),
                _upcomingMatches(context),
                const SizedBox(height: AppSpacing.section),
                SectionHeader('Tournaments',
                    action: 'View All', onAction: widget.onSeeTournaments),
                _tournamentsSection(),
                const SizedBox(height: AppSpacing.section),
                SectionHeader('From the Store',
                    action: 'Shop', onAction: widget.onSeeStore),
                _storeSection(),
                const SizedBox(height: AppSpacing.section),
                  ]),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Your Community ───────────────────────────────────────────────────────

  Widget _communitySection() {
    final c = _community!;
    final subtitle = 'Organized by ${c.organizerName}'
        '${(c.city != null && c.city!.isNotEmpty) ? ' · ${c.city}' : ''}';
    return Padding(
      padding: AppSpacing.screenH,
      child: GestureDetector(
        onTap: () => _openCommunity(context),
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topRight,
              end: Alignment.bottomLeft,
              colors: [AppColors.hero, AppColors.hero2],
            ),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Stack(children: [
            // Gold glow, top-right (matches the design's radial overlay).
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0.85, -1.0),
                    radius: 1.1,
                    colors: [AppColors.gold.withValues(alpha: 0.20), Colors.transparent],
                    stops: const [0.0, 0.6],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Stack(clipBehavior: Clip.none, children: [
                    Container(
                      width: 52,
                      height: 52,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                          color: AppColors.gold,
                          borderRadius: BorderRadius.circular(14)),
                      child: const Icon(Icons.groups_2_rounded, size: 26, color: Colors.white),
                    ),
                    // Red badge when the community channels have new messages.
                    if (_communityUnread > 0)
                      Positioned(
                        top: -5,
                        right: -5,
                        child: Container(
                          constraints: const BoxConstraints(minWidth: 20),
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: AppColors.danger,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppColors.hero, width: 2),
                          ),
                          child: Text(_communityUnread > 9 ? '9+' : '$_communityUnread',
                              style: AppText.tag(Colors.white)
                                  .copyWith(fontSize: 10, fontWeight: FontWeight.w800)),
                        ),
                      ),
                  ]),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Flexible(
                            child: Text(c.name,
                                style: AppText.body(AppColors.heroInk).copyWith(
                                    fontSize: 17.5, fontWeight: FontWeight.w800, height: 1.1),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis)),
                        // Communities are auto-verified for now.
                        const SizedBox(width: 6),
                        const Icon(Icons.verified_rounded, size: 16, color: AppColors.gold),
                      ]),
                      const SizedBox(height: 3),
                      Text(subtitle,
                          style: AppText.small(AppColors.heroFaint).copyWith(fontSize: 12.5),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  if (c.isMember)
                    const Icon(Icons.chevron_right_rounded, size: 20, color: AppColors.heroFaint)
                  else
                    const AppTag('Join', color: AppColors.gold, solid: true),
                ]),
                const SizedBox(height: 18),
                Row(children: [
                  if (_communityMembers.isNotEmpty) ...[
                    _memberStack(_communityMembers),
                    const SizedBox(width: 10),
                  ],
                  Text('${c.memberCount} member${c.memberCount == 1 ? '' : 's'}',
                      style: AppText.small(AppColors.heroInk)
                          .copyWith(fontSize: 12, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  if (_communityEventsWeek > 0) _eventsPill(_communityEventsWeek),
                ]),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  // Light chips on the dark card (design: field bg, surface border, ink-soft text).
  // Placeholder for the community hero while the first fetch resolves.
  Widget _communitySkeleton() => Padding(
        padding: AppSpacing.screenH,
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
              color: AppColors.field, borderRadius: BorderRadius.circular(18)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
            Row(children: [
              Skeleton(width: 52, height: 52, radius: 14),
              SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Skeleton(width: 170, height: 15, radius: 5),
                  SizedBox(height: 8),
                  Skeleton(width: 210, height: 11, radius: 5),
                ]),
              ),
            ]),
            SizedBox(height: 20),
            Row(children: [
              Skeleton(width: 96, height: 26, radius: 999),
              SizedBox(width: 12),
              Skeleton(width: 70, height: 12, radius: 5),
            ]),
          ]),
        ),
      );

  Widget _memberStack(List<MemberLite> members) {
    final show = members.take(5).toList();
    const d = 26.0;
    const step = 18.0; // marginLeft -8
    return SizedBox(
      width: d + (show.length - 1) * step,
      height: d,
      child: Stack(
        children: [
          for (int i = 0; i < show.length; i++)
            Positioned(
              left: i * step,
              child: Container(
                width: d,
                height: d,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.field,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.surface, width: 2),
                ),
                child: Text(_memberInitials(show[i].name),
                    style: AppText.small(AppColors.inkSoft).copyWith(
                        fontSize: 9.5, fontWeight: FontWeight.w800)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _eventsPill(int n) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.gold.withValues(alpha: 0.20),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 6, height: 6,
              decoration: const BoxDecoration(color: AppColors.gold, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text('$n event${n == 1 ? '' : 's'} this week',
              style: AppText.small(AppColors.gold)
                  .copyWith(fontSize: 11.5, fontWeight: FontWeight.w700)),
        ]),
      );

  static String _memberInitials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) {
      return parts.first.length >= 2
          ? parts.first.substring(0, 2).toUpperCase()
          : parts.first[0].toUpperCase();
    }
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  // Empty state: no community surfaced — invite the player to enter a code.
  Widget _communityCodePrompt() {
    return Padding(
      padding: AppSpacing.screenH,
      child: AppCard(
        onTap: () => _promptJoinByCode(context),
        child: Row(children: [
          Container(
            width: 46,
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: AppColors.field, borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.key_rounded, size: 22, color: AppColors.inkFaint),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Have a community code?', style: AppText.bodyStrong()),
              const SizedBox(height: 2),
              Text('Enter the code your organizer gave you to join.',
                  style: AppText.small(), maxLines: 2, overflow: TextOverflow.ellipsis),
            ]),
          ),
          const SizedBox(width: 8),
          const AppTag('Enter', color: AppColors.primary, solid: true),
        ]),
      ),
    );
  }

  Future<void> _promptJoinByCode(BuildContext c) async {
    final controller = TextEditingController();
    final id = await showModalBottomSheet<String>(
      context: c,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        bool busy = false;
        return StatefulBuilder(builder: (ctx, setSheet) {
          Future<void> submit() async {
            final code = controller.text.trim();
            if (code.isEmpty || busy) return;
            setSheet(() => busy = true);
            final res = await CommunityService.joinByHandle(code);
            if (!ctx.mounted) return;
            if (res.communityId != null) {
              Navigator.of(ctx).pop(res.communityId);
            } else {
              setSheet(() => busy = false);
              AppToast.show(ctx, res.error ?? 'Could not join.',
                  kind: ToastKind.error);
            }
          }

          return Padding(
            padding: EdgeInsets.only(
                left: AppSpacing.screen,
                right: AppSpacing.screen,
                top: 20,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 24),
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(20)),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('Join a community', style: AppText.cardTitle()),
                const SizedBox(height: 6),
                Text('Enter the code your organizer shared with you.',
                    style: AppText.small(), textAlign: TextAlign.center),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  autofocus: true,
                  textInputAction: TextInputAction.go,
                  textCapitalization: TextCapitalization.none,
                  onSubmitted: (_) => submit(),
                  decoration: const InputDecoration(
                    prefixText: '@',
                    hintText: 'community code',
                  ),
                ),
                const SizedBox(height: 18),
                AppButton(busy ? 'Joining…' : 'Join',
                    full: true,
                    onPressed: busy ? null : submit),
              ]),
            ),
          );
        });
      },
    );
    controller.dispose();
    if (id == null || !mounted) return;
    // Joined — open the hub, then refresh Home so the card flips to "Your Community".
    await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => CommunityHubScreen(communityId: id)));
    await _fetchCommunity();
    if (mounted) setState(() {});
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
              // `recent` is newest-first; render it reversed so the strip reads
              // oldest → newest and each new result lands on the RIGHT.
              for (final m in last.reversed) ...[
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
      return SizedBox(
        height: 224,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: AppSpacing.screenH,
          children: List.generate(
            2,
            (_) => Container(
              width: 262,
              margin: const EdgeInsets.only(right: 12),
              child: const AppCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Skeleton(width: 100, height: 22, radius: 999),
                  SizedBox(height: 14),
                  Skeleton(width: 170, height: 16, radius: 5),
                  SizedBox(height: 9),
                  Skeleton(width: 110, height: 12, radius: 5),
                  SizedBox(height: 16),
                  Skeleton(width: 140, height: 30, radius: 8),
                  SizedBox(height: 16),
                  Skeleton(width: double.infinity, height: 44, radius: 12),
                ]),
              ),
            ),
          ),
        ),
      );
    }
    if (_myMatches.isEmpty && _joinable.isEmpty) {
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
            AppButton('Find', onPressed: _startSearch),
          ]),
        ),
      );
    }
    return SizedBox(
      height: 224,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: AppSpacing.screenH,
        children: [
          // Mine first (open them), then open matches from other players that
          // can be joined right here.
          for (final m in _myMatches)
            _UpcomingMatchCard(m,
                onOpen: () => _openMatch(context, m['id'] as String)),
          for (final c in _joinable)
            _UpcomingMatchCard(
              _asMatch(c),
              onOpen: () => _joinCandidate(c),
              onJoin: () => _joinCandidate(c),
              playersOverride: (c['players'] as num?)?.toInt() ?? 0,
              busy: _joining == c['match_id'],
            ),
        ],
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
    return SizedBox(
      height: 224,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: AppSpacing.screenH,
        children: [
          for (final t in _tournaments)
            _TournamentTile(t,
                onTap: () => _openTournament(context, t['id'] as String)),
        ],
      ),
    );
  }

  // ── Store ────────────────────────────────────────────────────────────────

  static String _normCat(String? raw) {
    switch ((raw ?? '').toLowerCase()) {
      case 'rackets': return 'Rackets';
      case 'shoes': return 'Shoes';
      case 'apparel': return 'Apparel';
      case 'balls': return 'Balls';
      default: return 'Accessories';
    }
  }

  // Featured row → the mock Product the cart uses (mirrors StoreScreen).
  Product _toProduct(Map<String, dynamic> row) {
    final price = (row['price'] as num?)?.toInt() ?? 0;
    final salePrice = (row['sale_price'] as num?)?.toInt();
    final onSale = (row['on_sale'] as bool?) ?? false;
    final discount = (onSale && salePrice != null && price > 0)
        ? ((price - salePrice) / price * 100).round().clamp(1, 99)
        : 0;
    return Product(
      row['brand'] as String? ?? '',
      row['name'] as String? ?? 'Product',
      _normCat(row['category'] as String?),
      price,
      (row['rating'] as num?)?.toDouble() ?? 0.0,
      0,
      discount: discount,
      id: row['id'] as String? ?? '',
    );
  }

  Widget _storeSection() {
    if (_loading) return const _FeaturedHeroSkeleton();
    // Nothing to feature (no products at all) → keep the simple browse card.
    if (_featured.isEmpty) return _StoreCta(onTap: widget.onSeeStore);
    final row = _featured.first;
    final outOfStock = (row['stock_status'] as String?) == 'out';
    return _FeaturedHeroCard(
      row,
      onTap: widget.onSeeStore,
      onAdd: (widget.onAddToCart == null || outOfStock)
          ? null
          : () => widget.onAddToCart!(_toProduct(row)),
    );
  }
}

// ── Match tile ───────────────────────────────────────────────────────────────

class _UpcomingMatchCard extends StatelessWidget {
  final Map<String, dynamic> match;
  final VoidCallback onOpen;
  /// Set for a match the player is NOT in yet → the action becomes "Join
  /// Match" instead of "View Match".
  final VoidCallback? onJoin;
  /// `mm_candidates` returns a flat seat count instead of the players list.
  final int? playersOverride;
  final bool busy;
  const _UpcomingMatchCard(this.match,
      {required this.onOpen, this.onJoin, this.playersOverride, this.busy = false});

  static const _months = ['Jan','Feb','Mar','Apr','May','Jun',
                          'Jul','Aug','Sep','Oct','Nov','Dec'];

  static String _timeLabel(String? iso) {
    if (iso == null) return 'Time to be set';
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return 'Time to be set';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(dt.year, dt.month, dt.day);
    final diff = day.difference(today).inDays;
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    final time = '$h:$m $ampm';
    final label = diff == 0
        ? 'Today'
        : diff == 1
            ? 'Tomorrow'
            : '${_months[dt.month - 1]} ${dt.day}';
    return '$label,  $time';
  }

  static String _title(Map? court) {
    final venue = (court?['venue_name'] as String?)?.trim();
    final name = (court?['name'] as String?)?.trim();
    if ((venue?.isNotEmpty ?? false) && (name?.isNotEmpty ?? false)) {
      return '$venue — $name';
    }
    if (venue?.isNotEmpty ?? false) return venue!;
    if (name?.isNotEmpty ?? false) return name!;
    return 'Court to be agreed';
  }

  @override
  Widget build(BuildContext context) {
    final ranked = match['match_type'] == 'ranked';
    final court = match['courts'] as Map?;
    final players =
        playersOverride ?? (match['match_players'] as List?)?.length ?? 0;
    final filled = players.clamp(0, 4);
    final lat = (court?['lat'] as num?)?.toDouble();
    final lng = (court?['lng'] as num?)?.toDouble();
    final address = (court?['address'] as String?)?.trim();
    final hasLoc = (lat != null && lng != null) || (address != null && address.isNotEmpty);

    return Container(
      width: 262,
      margin: const EdgeInsets.only(right: 12),
      child: AppCard(
        onTap: onOpen,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Type pill — COMPETITIVE (green) / CASUAL (neutral).
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
            decoration: BoxDecoration(
              color: ranked
                  ? AppColors.success.withValues(alpha: 0.15)
                  : AppColors.field,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(ranked ? 'COMPETITIVE' : 'CASUAL',
                style: AppText.tag(ranked ? AppColors.success : AppColors.inkSoft)
                    .copyWith(fontSize: 10.5, letterSpacing: 0.5, fontWeight: FontWeight.w800)),
          ),
          const SizedBox(height: 12),
          Text(_title(court),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.cardTitle().copyWith(fontSize: 16.5)),
          const SizedBox(height: 7),
          Row(children: [
            const Icon(Icons.schedule_rounded, size: 14, color: AppColors.inkFaint),
            const SizedBox(width: 6),
            Text(_timeLabel(match['scheduled_at'] as String?),
                style: AppText.small().copyWith(fontSize: 12.5)),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            for (int i = 0; i < 4; i++) _avatarDot(i < filled),
            const Spacer(),
            Text('$players/4',
                style: AppText.bodyStrong().copyWith(fontSize: 13.5)),
          ]),
          const SizedBox(height: 12),
          // Mine → open it. Someone else's open match → join it from here.
          Row(children: [
            Expanded(
                child: AppButton(
                    onJoin == null ? 'View Match' : (busy ? 'Joining…' : 'Join Match'),
                    full: true,
                    height: 44,
                    onPressed: busy ? null : (onJoin ?? onOpen))),
            if (hasLoc) ...[
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => _openDirections(context, lat, lng, address),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: 44, height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.primary.withValues(alpha: 0.30)),
                  ),
                  child: const Icon(Icons.directions_rounded, size: 20, color: AppColors.primary),
                ),
              ),
            ],
          ]),
        ]),
      ),
    );
  }

  Future<void> _openDirections(
      BuildContext context, double? lat, double? lng, String? address) async {
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
      if (context.mounted) {
        AppToast.show(context, "Couldn't open Maps", kind: ToastKind.error);
      }
    }
  }

  Widget _avatarDot(bool filled) => Container(
        width: 30, height: 30,
        margin: const EdgeInsets.only(right: 7),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: filled ? AppColors.primary.withValues(alpha: 0.12) : AppColors.field,
          border: Border.all(
              color: filled ? AppColors.primary : AppColors.line, width: 1.5),
        ),
        child: filled
            ? const Icon(Icons.person_rounded, size: 16, color: AppColors.primary)
            : null,
      );
}

// ── Tournament tile ──────────────────────────────────────────────────────────

class _TournamentTile extends StatelessWidget {
  final Map<String, dynamic> t;
  final VoidCallback? onTap;
  const _TournamentTile(this.t, {this.onTap});

  static String _fmtRange(String? startIso, String? endIso) {
    final s = startIso == null ? null : DateTime.tryParse(startIso)?.toLocal();
    if (s == null) return 'TBD';
    const months = ['January','February','March','April','May','June',
                    'July','August','September','October','November','December'];
    final e = endIso == null ? null : DateTime.tryParse(endIso)?.toLocal();
    if (e == null || (e.year == s.year && e.month == s.month && e.day == s.day)) {
      return '${months[s.month - 1]} ${s.day}';
    }
    if (e.year == s.year && e.month == s.month) {
      return '${months[s.month - 1]} ${s.day} – ${e.day}';
    }
    return '${months[s.month - 1]} ${s.day} – ${months[e.month - 1]} ${e.day}';
  }

  static String _egp(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return 'EGP $buf';
  }

  @override
  Widget build(BuildContext context) {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    final name = t['name'] as String? ?? 'Tournament';
    final entryList = ((t['tournament_entries'] as List?) ?? const [])
        .where((e) => e['status'] != 'withdrawn')
        .toList();
    final entries = entryList.length;
    final registered =
        TournamentService.isParticipant(t['tournament_entries'] as List?, uid);
    final ds = TournamentService.tournamentStatus(t, entries);
    final cap = (t['capacity'] as num?)?.toInt() ?? 0;
    final remaining = cap > 0 ? (cap - entries).clamp(0, cap) : null;
    final prize = (t['prize_pool'] as num?)?.toInt() ?? 0;
    final fee = (t['entry_fee'] as num?)?.toInt() ?? 0;
    final canRegister = !registered && (ds == 'open' || ds == 'postponed');
    final sc = switch (ds) {
      'open' || 'live' => AppColors.success,
      'full' || 'postponed' || 'upcoming' => AppColors.gold,
      _ => AppColors.inkSoft,
    };
    final statusLabel = switch (ds) {
      'open' => 'Open',
      'live' => 'Live',
      'full' => 'Full',
      'upcoming' => 'Upcoming',
      'postponed' => 'Postponed',
      _ => ds,
    };

    return Container(
      width: 262,
      margin: const EdgeInsets.only(right: 12),
      child: AppCard(
        onTap: onTap,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.emoji_events_rounded, size: 16, color: AppColors.gold),
            const SizedBox(width: 6),
            Expanded(
              child: Text(name,
                  style: AppText.bodyStrong().copyWith(fontSize: 13.5),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            // Show "Registered" only while the tournament is still pre-start;
            // once it's live/full the status (e.g. Live) is the useful label.
            AppTag(
                (registered && (ds == 'open' || ds == 'postponed'))
                    ? 'Registered'
                    : statusLabel,
                color: (registered && (ds == 'open' || ds == 'postponed'))
                    ? AppColors.primary
                    : sc),
          ]),
          const SizedBox(height: 6),
          Text(_fmtRange(t['start_date'] as String?, t['end_date'] as String?),
              style: AppText.small().copyWith(fontSize: 12)),
          const Spacer(),
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(prize > 0 ? _egp(prize) : (fee > 0 ? _egp(fee) : 'Free'),
                    style: AppText.stat(16, AppColors.primary)),
                Text(prize > 0 ? 'Prize Pool' : 'Entry / Pair',
                    style: AppText.small().copyWith(fontSize: 10.5)),
              ]),
            ),
            if (remaining != null)
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('$remaining left', style: AppText.stat(14)),
                Text('of $cap', style: AppText.small().copyWith(fontSize: 10.5)),
              ]),
          ]),
          const SizedBox(height: 12),
          AppButton(canRegister ? 'Register' : 'View',
              full: true, height: 44,
              variant: canRegister ? AppBtnVariant.solid : AppBtnVariant.outline,
              onPressed: onTap),
        ]),
      ),
    );
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
                const AppTag('Welcome to Padel Rivals', color: AppColors.primary, solid: true),
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

// ── Book-next hero (placed player, nothing booked) ───────────────────────────

class _BookNextHero extends StatelessWidget {
  final Ranking ranking;
  final int bandCount;
  final VoidCallback onFindMatch; // quick auto-match now
  final VoidCallback onSchedule; // pick a day + time range, then search
  const _BookNextHero({
    required this.ranking,
    required this.onFindMatch,
    required this.onSchedule,
    this.bandCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final div = RankingScale.divisionFor(ranking.level);
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
        child: Stack(children: [
          // Warm primary glow, top-right (mirrors the placement/community heroes).
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.85, -1.0),
                  radius: 1.1,
                  colors: [AppColors.primary.withValues(alpha: 0.20), Colors.transparent],
                  stops: const [0.0, 0.6],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.09),
                        borderRadius: BorderRadius.circular(7)),
                    child: Text('NO MATCH SCHEDULED',
                        style: AppText.tag(AppColors.heroFaint).copyWith(fontSize: 10.5, letterSpacing: 0.4)),
                  ),
                  Row(children: [
                    const Icon(Icons.check_circle_rounded, size: 13, color: AppColors.success),
                    const SizedBox(width: 5),
                    Text('Ready to play',
                        style: AppText.tag(AppColors.success).copyWith(fontSize: 11)),
                  ]),
                ],
              ),
              const SizedBox(height: 16),
              Text('Book your next game',
                  style: AppText.stat(22, AppColors.heroInk).copyWith(height: 1.1, letterSpacing: -0.5)),
              const SizedBox(height: 6),
              Text(
                  "You're placed in Division ${div.key}. Keep your ELO climbing — line up your next match.",
                  style: AppText.small(AppColors.heroFaint).copyWith(fontSize: 13, height: 1.5)),
              if (bandCount > 0) ...[
                const SizedBox(height: 14),
                GestureDetector(
                  onTap: onFindMatch,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.07),
                        borderRadius: BorderRadius.circular(12)),
                    child: Row(children: [
                      Container(
                        width: 34, height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                            color: AppColors.primary.withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(9)),
                        child: const Icon(Icons.groups_2_rounded, size: 18, color: AppColors.primaryInk),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Text(
                            '$bandCount match${bandCount == 1 ? '' : 'es'} near your level',
                            style: AppText.bodyStrong(AppColors.heroInk).copyWith(fontSize: 13)),
                      ),
                      const Icon(Icons.arrow_forward_rounded, size: 16, color: AppColors.heroFaint),
                    ]),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              // Two paths: quick auto-match now, or choose a day + time range.
              AppButton('Find a Match',
                  full: true, height: 48, icon: Icons.bolt_rounded, onPressed: onFindMatch),
              const SizedBox(height: 4),
              Center(
                child: Text('Quick match — auto-paired for the next few hours',
                    style: AppText.tag(AppColors.heroFaint).copyWith(fontSize: 10.5)),
              ),
              const SizedBox(height: 10),
              GestureDetector(
                onTap: onSchedule,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.07),
                    borderRadius: AppRadius.btnR,
                    border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
                  ),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.event_rounded, size: 17, color: AppColors.gold),
                    const SizedBox(width: 8),
                    Text('Choose a day & time',
                        style: AppText.bodyStrong(AppColors.heroInk).copyWith(fontSize: 14)),
                  ]),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ── Shared match-hero pieces (next-match + live) ─────────────────────────────
// Both heroes show the same match from a different moment in its life, so the
// lineup, the venue/time panel and the venue footer live here once.

const _heroMonths = ['Jan','Feb','Mar','Apr','May','Jun',
                     'Jul','Aug','Sep','Oct','Nov','Dec'];
const _heroWeekdays = ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];

String _heroClock(DateTime dt) {
  final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
  final m = dt.minute.toString().padLeft(2, '0');
  return '$h:$m ${dt.hour < 12 ? 'AM' : 'PM'}';
}

/// "Today, 6:00 PM" — near dates read as words, anything past this week falls
/// back to the date.
String _heroWhen(DateTime dt) {
  final now = DateTime.now();
  final days = DateTime(dt.year, dt.month, dt.day)
      .difference(DateTime(now.year, now.month, now.day))
      .inDays;
  final day = days == 0
      ? 'Today'
      : days == 1
          ? 'Tomorrow'
          : (days > 1 && days < 7)
              ? _heroWeekdays[dt.weekday - 1]
              : '${_heroMonths[dt.month - 1]} ${dt.day}';
  return '$day, ${_heroClock(dt)}';
}

/// "Gezira Club — Court 2", or whichever half exists.
String _heroVenue(Map<String, dynamic> match) {
  final court = match['courts'] as Map?;
  final venue = (court?['venue_name'] as String?)?.trim() ?? '';
  final name = (court?['name'] as String?)?.trim() ?? '';
  final line = [venue, name].where((s) => s.isNotEmpty).join(' — ');
  return line.isEmpty ? 'Venue to be agreed' : line;
}

String _heroProfName(Map p) =>
    ((p['profiles'] as Map?)?['name'] as String?)?.trim() ?? '';

String _heroFirstName(Map p) {
  final n = _heroProfName(p);
  if (n.isEmpty) return 'Player';
  return n.split(RegExp(r'\s+')).first;
}

String _heroInitials(String name) {
  final parts =
      name.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) {
    final p = parts.first;
    return (p.length >= 2 ? p.substring(0, 2) : p).toUpperCase();
  }
  return (parts[0][0] + parts[1][0]).toUpperCase();
}

/// "Karim & Sara", "Karim & open", "Open team" — the empty half of a team is
/// named, not hidden, because these heroes often show a match still filling.
String _heroSideName(List<Map> players) {
  if (players.isEmpty) return 'Open team';
  if (players.length == 1) return '${_heroFirstName(players.first)} & open';
  return '${_heroFirstName(players[0])} & ${_heroFirstName(players[1])}';
}

/// The lineup split into my team and theirs, me first on my side.
({List<Map> us, List<Map> them}) _heroTeams(
    Map<String, dynamic> match, String? myId) {
  final all =
      ((match['match_players'] as List?) ?? const []).whereType<Map>().toList();
  String teamOf(Map p) => (p['team'] as String? ?? 'a').toLowerCase();
  final myTeam = teamOf(all.firstWhere((p) => p['player_id'] == myId,
      orElse: () => <String, dynamic>{'team': 'a'}));
  final us = all.where((p) => teamOf(p) == myTeam).toList()
    ..sort((a, b) => a['player_id'] == myId
        ? -1
        : b['player_id'] == myId
            ? 1
            : 0);
  return (us: us, them: all.where((p) => teamOf(p) != myTeam).toList());
}

/// One player circle, or a hollow "+" for a seat nobody has taken yet.
class _HeroSeat extends StatelessWidget {
  final Map? player;
  final Color color;
  final double size;
  const _HeroSeat(this.player, {required this.color, this.size = 46});

  @override
  Widget build(BuildContext context) {
    final p = player;
    if (p == null) {
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.hero2,
          border:
              Border.all(color: Colors.white.withValues(alpha: 0.30), width: 1.5),
        ),
        child: Icon(Icons.add_rounded,
            size: size * 0.42, color: Colors.white.withValues(alpha: 0.55)),
      );
    }
    final url = ((p['profiles'] as Map?)?['avatar_url'] as String?)?.trim() ?? '';
    final label = Text(_heroInitials(_heroProfName(p)),
        style: AppText.bodyStrong(color)
            .copyWith(fontSize: size * 0.32, fontWeight: FontWeight.w800));
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.16),
        border: Border.all(color: color, width: 2),
      ),
      child: url.isEmpty
          ? label
          : Image.network(url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              cacheWidth: (size * 3).round(),
              errorBuilder: (_, __, ___) => label),
    );
  }
}

/// A team: two overlapping seats (padel is 2v2) + the pair's name.
class _HeroSide extends StatelessWidget {
  final List<Map> players;
  final Color color;
  const _HeroSide(this.players, {required this.color});

  @override
  Widget build(BuildContext context) {
    const size = 46.0;
    const overlap = 13.0;
    return Column(children: [
      SizedBox(
        width: size * 2 - overlap,
        height: size,
        child: Stack(children: [
          Positioned(
              left: 0,
              child: _HeroSeat(players.isNotEmpty ? players[0] : null,
                  color: color, size: size)),
          Positioned(
              left: size - overlap,
              child: _HeroSeat(players.length > 1 ? players[1] : null,
                  color: color, size: size)),
        ]),
      ),
      const SizedBox(height: 8),
      Text(_heroSideName(players),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: AppText.bodyStrong(AppColors.heroInk).copyWith(fontSize: 12.5)),
    ]);
  }
}

/// Us vs them, with the format pill and ranked/casual caption between.
class _HeroLineup extends StatelessWidget {
  final Map<String, dynamic> match;
  final String? myId;
  const _HeroLineup({required this.match, this.myId});

  @override
  Widget build(BuildContext context) {
    final teams = _heroTeams(match, myId);
    final ranked = match['match_type'] == 'ranked';
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: _HeroSide(teams.us, color: AppColors.primary)),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 6),
          Text('VS',
              style:
                  AppText.stat(19, AppColors.heroInk).copyWith(letterSpacing: 0.5)),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.09),
                borderRadius: BorderRadius.circular(6)),
            child: Text('DOUBLES',
                style: AppText.tag(AppColors.heroFaint)
                    .copyWith(fontSize: 9.5, letterSpacing: 0.8)),
          ),
          const SizedBox(height: 5),
          Text(ranked ? 'Ranked' : 'Casual',
              style: AppText.small(ranked ? AppColors.gold : AppColors.heroFaint)
                  .copyWith(fontSize: 10.5)),
        ]),
      ),
      Expanded(child: _HeroSide(teams.them, color: AppColors.heroFaint)),
    ]);
  }
}

/// The inset panel: where it is, when it is.
class _HeroDetails extends StatelessWidget {
  final String venueLine;
  final String timeLine;
  const _HeroDetails({required this.venueLine, required this.timeLine});

  static Widget _row(IconData icon, String text) => Row(children: [
        Icon(icon, size: 14, color: AppColors.heroFaint),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.small(AppColors.heroInk).copyWith(fontSize: 12.5)),
        ),
      ]);

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(12)),
        child: Column(children: [
          _row(Icons.place_rounded, venueLine),
          const SizedBox(height: 7),
          _row(Icons.schedule_rounded, timeLine),
        ]),
      );
}

/// "✓ Venue confirmed" once a court is attached, honest about it when not.
Widget _heroVenueStamp(bool hasCourt) => Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(hasCourt ? Icons.check_circle_rounded : Icons.info_outline_rounded,
          size: 14, color: hasCourt ? AppColors.success : AppColors.gold),
      const SizedBox(width: 6),
      Text(hasCourt ? 'Venue confirmed' : 'Court to be agreed',
          style: AppText.tag(hasCourt ? AppColors.success : AppColors.gold)
              .copyWith(fontSize: 11)),
    ]);

// ── Next-match hero (placed player, a match is booked/live) ──────────────────

class _NextMatchHero extends StatelessWidget {
  final Map<String, dynamic> match;
  final String? myId;
  final VoidCallback onTap;
  const _NextMatchHero({required this.match, required this.onTap, this.myId});

  String _countdown(DateTime dt) {
    final diff = dt.difference(DateTime.now());
    if (diff.isNegative) return 'now';
    if (diff.inHours >= 24) return 'in ${diff.inDays}d';
    if (diff.inHours >= 1) return 'in ${diff.inHours}h ${diff.inMinutes % 60}m';
    return 'in ${diff.inMinutes}m';
  }

  @override
  Widget build(BuildContext context) {
    final status = match['status'] as String? ?? 'open';
    final live = status == 'in_progress';
    final hasCourt = match['court_id'] != null;
    final dt = DateTime.tryParse(match['scheduled_at'] as String? ?? '')?.toLocal();

    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 16, AppSpacing.screen, 0),
      child: GestureDetector(
        onTap: onTap,
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
          child: Stack(children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0.85, -1.0),
                    radius: 1.1,
                    colors: [
                      (live ? AppColors.success : AppColors.primary).withValues(alpha: 0.20),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.6],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(18),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    AppTag(live ? 'LIVE NOW' : 'NEXT MATCH',
                        color: live ? AppColors.success : AppColors.primary, solid: true),
                    if (!live && dt != null)
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.schedule_rounded, size: 13, color: AppColors.gold),
                        const SizedBox(width: 5),
                        Text(_countdown(dt),
                            style: AppText.tag(AppColors.gold).copyWith(fontSize: 11)),
                      ]),
                  ],
                ),
                const SizedBox(height: 18),
                // Us vs them — filled seats show the player, empty ones a "+".
                _HeroLineup(match: match, myId: myId),
                const SizedBox(height: 18),
                _HeroDetails(
                  venueLine: _heroVenue(match),
                  timeLine: live
                      ? 'Underway — good luck!'
                      : (dt != null ? _heroWhen(dt) : 'Time to be set'),
                ),
                const SizedBox(height: 14),
                Row(children: [
                  _heroVenueStamp(hasCourt),
                  const Spacer(),
                  Text('View Details →',
                      style: AppText.bodyStrong(AppColors.primary).copyWith(fontSize: 13.5)),
                ]),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

// ── Live hero (match happening now) ──────────────────────────────────────────

class _LiveHero extends StatelessWidget {
  final Map<String, dynamic> match;
  final String? myId;
  final VoidCallback onEnterScore;
  const _LiveHero(
      {required this.match, required this.onEnterScore, this.myId});

  @override
  Widget build(BuildContext context) {
    final players = (match['match_players'] as List?)?.length ?? 0;
    final hasCourt = match['court_id'] != null;
    final dt = DateTime.tryParse(match['scheduled_at'] as String? ?? '')?.toLocal();
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
        child: Stack(children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.85, -1.0),
                  radius: 1.1,
                  colors: [AppColors.success.withValues(alpha: 0.24), Colors.transparent],
                  stops: const [0.0, 0.6],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(width: 8, height: 8,
                    decoration: const BoxDecoration(color: AppColors.success, shape: BoxShape.circle)),
                const SizedBox(width: 7),
                Text('LIVE NOW',
                    style: AppText.tag(AppColors.success).copyWith(fontSize: 11, letterSpacing: 0.8)),
                const Spacer(),
                Text('$players/4 checked in',
                    style: AppText.tag(AppColors.heroFaint).copyWith(fontSize: 11)),
              ]),
              const SizedBox(height: 18),
              _HeroLineup(match: match, myId: myId),
              const SizedBox(height: 18),
              _HeroDetails(
                venueLine: _heroVenue(match),
                timeLine: dt != null
                    ? 'Started ${_heroClock(dt)} — good luck!'
                    : 'Your match is on — good luck!',
              ),
              const SizedBox(height: 12),
              _heroVenueStamp(hasCourt),
              const SizedBox(height: 14),
              AppButton('Enter score when done',
                  full: true, height: 48, icon: Icons.scoreboard_rounded, onPressed: onEnterScore),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ── Result hero (match just finished — one-time) ─────────────────────────────

class _ResultHero extends StatelessWidget {
  final Map<String, dynamic> result;
  final VoidCallback onNext;
  const _ResultHero({required this.result, required this.onNext});

  /// Set chips from MY perspective. Scores are stored per team as
  /// comma-separated games ("6,3,6" vs "4,6,2"); zip them and orient to my team.
  List<String> _sets() {
    final a = ((result['score_team_a'] as String?) ?? '').split(',');
    final b = ((result['score_team_b'] as String?) ?? '').split(',');
    final mine = result['my_team'] == 'a' ? a : b;
    final opp = result['my_team'] == 'a' ? b : a;
    final n = mine.length < opp.length ? mine.length : opp.length;
    final out = <String>[];
    for (int i = 0; i < n; i++) {
      final m = mine[i].trim();
      final o = opp[i].trim();
      if (m.isEmpty || o.isEmpty) continue;
      out.add('$m–$o');
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final won = result['won'] == true;
    final delta = (result['rating_delta'] as num?)?.toDouble();
    final after = (result['rating_after'] as num?)?.toDouble();
    final sets = _sets();
    final accent = won ? AppColors.success : AppColors.inkSoft;

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
        child: Stack(children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0, -1.0),
                  radius: 1.2,
                  colors: [accent.withValues(alpha: 0.22), Colors.transparent],
                  stops: const [0.0, 0.65],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: AppTag('Match Complete', color: AppColors.success, solid: true),
              ),
              const SizedBox(height: 16),
              TweenAnimationBuilder<double>(
                duration: const Duration(milliseconds: 520),
                curve: Curves.elasticOut,
                tween: Tween(begin: 0, end: 1),
                builder: (_, t, child) => Transform.scale(scale: t, child: child),
                child: Container(
                  width: 74, height: 74,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    color: accent.withValues(alpha: 0.18),
                    border: Border.all(color: accent, width: 2),
                  ),
                  child: Text(won ? 'W' : 'L',
                      style: AppText.stat(30, AppColors.heroInk).copyWith(fontWeight: FontWeight.w900)),
                ),
              ),
              const SizedBox(height: 14),
              Text(won ? 'You won!' : 'Good game',
                  style: AppText.stat(23, AppColors.heroInk).copyWith(letterSpacing: -0.5)),
              if (sets.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
                  for (final s in sets)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                      decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.09),
                          borderRadius: BorderRadius.circular(9)),
                      child: Text(s,
                          style: AppText.bodyStrong(AppColors.heroInk).copyWith(fontSize: 14)),
                    ),
                ]),
              ],
              if (delta != null && after != null) ...[
                const SizedBox(height: 14),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(delta >= 0 ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                      size: 16, color: delta >= 0 ? AppColors.success : AppColors.danger),
                  const SizedBox(width: 4),
                  Text('${delta.abs().toStringAsFixed(2)}   ·   Lv ${RankingScale.fmtQuarter(after)}',
                      style: AppText.bodyStrong(
                              delta >= 0 ? AppColors.success : AppColors.danger)
                          .copyWith(fontSize: 15)),
                ]),
                const SizedBox(height: 4),
                Text('${RankingScale.divisionFor(after).name} · ${RankingScale.divisionFor(after).metalName}',
                    style: AppText.small(AppColors.heroFaint).copyWith(fontSize: 12.5)),
              ] else ...[
                const SizedBox(height: 12),
                Text('Casual match · no rating change',
                    style: AppText.small(AppColors.heroFaint).copyWith(fontSize: 12.5)),
              ],
              const SizedBox(height: 18),
              AppButton('Book your next game',
                  full: true, height: 48, icon: Icons.search_rounded, onPressed: onNext),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ── Placement reveal (one-time celebration) ──────────────────────────────────

class _PlacementReveal extends StatelessWidget {
  final PlayerProfile profile;
  final VoidCallback onNext;
  const _PlacementReveal({required this.profile, required this.onNext});

  static Color _metalColor(String metal) => switch (metal) {
        'elite' => AppColors.primary,
        'gold' => AppColors.warn,
        'silver' => AppColors.inkSoft,
        _ => const Color(0xFFB0754A), // bronze
      };

  @override
  Widget build(BuildContext context) {
    final level = profile.ranking.level;
    final div = RankingScale.divisionFor(level);
    final metal = _metalColor(div.metal);
    final record = '${profile.wins}–${profile.losses}';

    Widget stat(String value, String label) => Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 6),
            decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(12)),
            child: Column(children: [
              Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.stat(19, AppColors.heroInk)),
              const SizedBox(height: 3),
              Text(label,
                  textAlign: TextAlign.center,
                  style: AppText.tag(AppColors.heroFaint).copyWith(fontSize: 9.5, letterSpacing: 0.3)),
            ]),
          ),
        );

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
        child: Stack(children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.0, -1.0),
                  radius: 1.2,
                  colors: [AppColors.gold.withValues(alpha: 0.22), Colors.transparent],
                  stops: const [0.0, 0.65],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(18),
            child: Column(children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: AppTag('Placement Complete', color: AppColors.gold, solid: true),
              ),
              const SizedBox(height: 18),
              // Pop-in division badge.
              TweenAnimationBuilder<double>(
                duration: const Duration(milliseconds: 520),
                curve: Curves.elasticOut,
                tween: Tween(begin: 0, end: 1),
                builder: (_, t, child) => Transform.scale(scale: t, child: child),
                child: Container(
                  width: 88, height: 88,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color.lerp(metal, Colors.white, 0.35)!, metal],
                    ),
                    boxShadow: [
                      BoxShadow(color: metal.withValues(alpha: 0.4), blurRadius: 20, offset: const Offset(0, 6)),
                    ],
                  ),
                  child: Text(div.key,
                      style: AppText.stat(38, Colors.white).copyWith(fontWeight: FontWeight.w900)),
                ),
              ),
              const SizedBox(height: 14),
              Text("You're in ${div.name}",
                  style: AppText.stat(23, AppColors.heroInk).copyWith(letterSpacing: -0.5)),
              const SizedBox(height: 4),
              Text('${div.metalName} · ${div.league}',
                  style: AppText.small(AppColors.heroFaint).copyWith(fontSize: 13)),
              const SizedBox(height: 18),
              Row(children: [
                stat('Lv ${RankingScale.fmtQuarter(level)}', 'STARTING LEVEL'),
                stat(div.metalName, 'TIER'),
                stat(record, 'RECORD'),
              ]),
              const SizedBox(height: 18),
              AppButton('See what\'s next',
                  full: true, height: 48, icon: Icons.arrow_forward_rounded, onPressed: onNext),
            ]),
          ),
        ]),
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

// ── Featured product hero card (Home "From the Store") ───────────────────────

class _FeaturedHeroCard extends StatelessWidget {
  final Map<String, dynamic> p;
  final VoidCallback? onTap;
  final VoidCallback? onAdd;
  const _FeaturedHeroCard(this.p, {this.onTap, this.onAdd});

  static const _catIcons = <String, IconData>{
    'rackets': Icons.sports_tennis_rounded,
    'shoes': Icons.directions_run_rounded,
    'apparel': Icons.checkroom_rounded,
    'balls': Icons.sports_baseball_rounded,
    'accessories': Icons.backpack_rounded,
  };
  static const _catColors = <String, Color>{
    'rackets': AppColors.primary,
    'shoes': AppColors.accent,
    'apparel': AppColors.diamond,
    'balls': AppColors.success,
    'accessories': AppColors.platinum,
  };
  static const _catLabels = <String, String>{
    'rackets': 'Padel Racket',
    'shoes': 'Court Shoes',
    'apparel': 'Apparel',
    'balls': 'Padel Balls',
    'accessories': 'Accessory',
  };

  @override
  Widget build(BuildContext context) {
    final cat = (p['category'] as String? ?? 'accessories').toLowerCase();
    final color = _catColors[cat] ?? AppColors.primary;
    final icon = _catIcons[cat] ?? Icons.sports_tennis_rounded;
    final name = p['name'] as String? ?? 'Product';
    final desc = (p['description'] as String?)?.trim();
    final subtitle = (desc != null && desc.isNotEmpty)
        ? desc
        : (_catLabels[cat] ?? 'Padel Gear');
    final price = (p['price'] as num?)?.toInt() ?? 0;
    final salePrice = (p['sale_price'] as num?)?.toInt();
    final onSale = (p['on_sale'] as bool?) ?? false;
    final displayPrice = (onSale && salePrice != null) ? salePrice : price;
    final imageUrl = p['image_url'] as String?;
    final outOfStock = (p['stock_status'] as String?) == 'out';

    final tagLabel =
        (p['source'] as String?) == 'featured' ? 'FEATURED' : 'NEW IN';

    final radius = BorderRadius.circular(14);
    final image = (imageUrl != null && imageUrl.isNotEmpty)
        ? ClipRRect(
            borderRadius: radius,
            child: Image.network(
              imageUrl,
              width: 80, height: 80,
              fit: BoxFit.cover,
              cacheWidth: 240,
              loadingBuilder: (_, child, progress) => progress == null
                  ? child
                  : Container(width: 80, height: 80, color: AppColors.field),
              errorBuilder: (_, __, ___) => SizedBox(
                width: 80,
                child: StripedPlaceholder(
                    height: 80, icon: icon, color: color, radius: radius),
              ),
            ),
          )
        : SizedBox(
            width: 80,
            child: StripedPlaceholder(
                height: 80, icon: icon, color: color, radius: radius),
          );

    return Padding(
      padding: AppSpacing.screenH,
      child: AppCard(
        onTap: onTap,
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          image,
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              AppTag(tagLabel, color: AppColors.primary),
              const SizedBox(height: 6),
              Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.bodyStrong().copyWith(fontSize: 14.5)),
              const SizedBox(height: 2),
              Text(subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.small().copyWith(fontSize: 12.5)),
              const SizedBox(height: 10),
              Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (onSale && salePrice != null)
                        Text(MockData.egp(price),
                            style: AppText.tag(AppColors.inkFaint).copyWith(
                                fontSize: 10,
                                decoration: TextDecoration.lineThrough)),
                      Text(MockData.egp(displayPrice),
                          style: AppText.stat(18, AppColors.primary)),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                AppButton(outOfStock ? 'Sold Out' : 'Add to Cart',
                    height: 38, onPressed: onAdd),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _FeaturedHeroSkeleton extends StatelessWidget {
  const _FeaturedHeroSkeleton();
  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: AppSpacing.screenH,
      child: AppCard(
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Skeleton(width: 80, height: 80, radius: 14),
          SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Skeleton(width: 64, height: 10, radius: 4),
              SizedBox(height: 8),
              Skeleton(width: double.infinity, height: 12, radius: 4),
              SizedBox(height: 6),
              Skeleton(width: 120, height: 10, radius: 4),
              SizedBox(height: 12),
              Skeleton(width: double.infinity, height: 24, radius: 6),
            ]),
          ),
        ]),
      ),
    );
  }
}
