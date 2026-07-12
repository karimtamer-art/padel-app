import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
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
import '../matches/find_match_screen.dart';
import '../detail/match_detail_screen.dart';
import '../tournaments/tournament_detail_screen.dart';
import '../profile/notifications_screen.dart';
import '../community/community_hub_screen.dart';

class HomeScreen extends StatefulWidget {
  final VoidCallback? onSeeStore;
  final VoidCallback? onSeeTournaments;
  final ValueChanged<Product>? onAddToCart;
  final PlayerProfile profile;
  final String displayName;
  final String initials;

  const HomeScreen({
    super.key,
    this.onSeeStore,
    this.onSeeTournaments,
    this.onAddToCart,
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
  List<Map<String, dynamic>> _featured = [];
  Community? _community;
  List<MemberLite> _communityMembers = [];
  int _communityEventsWeek = 0;
  int _unread = 0;
  bool _loading = true;
  RealtimeChannel? _notifChannel;

  static SupabaseClient get _db => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _loadData();
    _subscribeNotifications();
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
          callback: (_) {
            if (mounted) setState(() => _unread++);
          },
        )
        .subscribe();
  }

  Future<void> _loadData() async {
    setState(() => _loading = true);
    await Future.wait([
      _fetchMatches(),
      _fetchTournaments(),
      _fetchUnread(),
      _fetchFeatured(),
      _fetchCommunity(),
    ]);
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

  Future<void> _fetchUnread() async {
    final n = await NotificationService.unreadCount();
    if (mounted) _unread = n;
  }

  Future<void> _fetchFeatured() async {
    final rows = await StoreService.fetchHomeProducts(limit: 1);
    if (mounted) _featured = rows;
  }

  Future<void> _fetchCommunity() async {
    final c = await CommunityService.homeCommunity();
    List<MemberLite> members = [];
    int eventsWeek = 0;
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
    }
    if (mounted) {
      _community = c;
      _communityMembers = members;
      _communityEventsWeek = eventsWeek;
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

  Future<void> _openNotifications(BuildContext c) async {
    await Navigator.of(c)
        .push(MaterialPageRoute(builder: (_) => const NotificationsScreen()));
    // Coming back, the inbox may have been marked read — refresh the badge.
    await _fetchUnread();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ScreenBar(
          title: 'Padel Rivals',
          leadingInitials: widget.initials.isNotEmpty ? widget.initials : 'P',
          actions: [
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
                if (!widget.profile.ranking.placed)
                  _PlacementWelcome(
                    ranking: widget.profile.ranking,
                    onFindMatch: () => _openFindMatch(context),
                  ),
                const SizedBox(height: 24),
                SectionHeader(
                    _community == null
                        ? 'Community'
                        : (_community!.isMember
                            ? 'Your Community'
                            : 'Discover a Community'),
                    action: (_community?.isMember ?? false) ? 'View' : 'Have a code?',
                    onAction: (_community?.isMember ?? false)
                        ? () => _openCommunity(context)
                        : () => _promptJoinByCode(context)),
                if (_community != null)
                  _communitySection()
                else
                  _communityCodePrompt(),
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
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [AppColors.hero, Color(0xFF243B2F)],
            ),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 46,
                height: 46,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: AppColors.gold,
                    borderRadius: BorderRadius.circular(13)),
                child: const Icon(Icons.groups_2_rounded, size: 24, color: Colors.white),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(
                        child: Text(c.name,
                            style: AppText.bodyStrong(AppColors.heroInk),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis)),
                    if (c.verified) ...[
                      const SizedBox(width: 5),
                      const Icon(Icons.verified_rounded, size: 15, color: AppColors.gold),
                    ],
                  ]),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: AppText.small(AppColors.heroFaint),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ]),
              ),
              const SizedBox(width: 8),
              if (c.isMember)
                const Icon(Icons.chevron_right_rounded, color: AppColors.heroFaint)
              else
                const AppTag('Join', color: AppColors.gold, solid: true),
            ]),
            const SizedBox(height: 14),
            Row(children: [
              if (_communityMembers.isNotEmpty) ...[
                _memberStack(_communityMembers),
                const SizedBox(width: 10),
              ],
              Text('${c.memberCount} member${c.memberCount == 1 ? '' : 's'}',
                  style: AppText.small(AppColors.heroInk)),
              const Spacer(),
              if (_communityEventsWeek > 0) _eventsPill(_communityEventsWeek),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _memberStack(List<MemberLite> members) {
    final show = members.take(5).toList();
    const d = 27.0;
    const step = 19.0; // overlap
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
                  color: const Color(0xFF35543F),
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.hero, width: 2),
                ),
                child: Text(_memberInitials(show[i].name),
                    style: AppText.small(AppColors.heroInk).copyWith(
                        fontSize: 10, fontWeight: FontWeight.w800)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _eventsPill(int n) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.heroInk.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 6, height: 6,
              decoration: const BoxDecoration(color: AppColors.gold, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text('$n event${n == 1 ? '' : 's'} this week',
              style: AppText.small(AppColors.heroInk)
                  .copyWith(fontWeight: FontWeight.w700)),
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
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Column(
            children: List.generate(3, (_) => const SkeletonListRow()),
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
    return SizedBox(
      height: 176,
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
      'full' || 'postponed' => AppColors.gold,
      _ => AppColors.inkSoft,
    };
    final statusLabel = switch (ds) {
      'open' => 'Open',
      'live' => 'Live',
      'full' => 'Full',
      'postponed' => 'Postponed',
      _ => ds,
    };

    return Container(
      width: 250,
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
              full: true, height: 38,
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
