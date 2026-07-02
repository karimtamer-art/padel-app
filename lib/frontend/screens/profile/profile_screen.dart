import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_text.dart';
import '../../widgets/common.dart';
import '../../widgets/elo_chart.dart';
import '../../widgets/padel_refresh.dart';
import '../../../backend/models/ranking_scale.dart';
import '../../../backend/services/profile_service.dart';
import '../../../backend/models/mock_data.dart' show CartLine;
import 'division_card.dart';
import 'edit_profile_screen.dart';
import 'my_orders_screen.dart';
import 'my_tournaments_screen.dart';
import 'match_history_screen.dart';
import 'notifications_screen.dart';
import 'privacy_account_screen.dart';
import 'help_support_screen.dart';

class ProfileScreen extends StatefulWidget {
  final PlayerProfile profile;
  final VoidCallback? onFindMatch;
  final Future<void> Function()? onSignOut;
  final void Function(List<CartLine>)? onReorder;
  final String displayName;
  final String initials;
  final String memberSince;

  const ProfileScreen({
    super.key,
    this.profile = PlayerProfile.fresh,
    this.onFindMatch,
    this.onSignOut,
    this.onReorder,
    this.displayName = '',
    this.initials = 'P',
    this.memberSince = '',
  });

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late PlayerProfile _profile;

  @override
  void initState() {
    super.initState();
    _profile = widget.profile;
  }

  Future<void> _refresh() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    final fresh = await ProfileService.fetchPlayerProfile(uid);
    if (mounted) setState(() => _profile = fresh);
  }

  static void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  void _confirmSignOut(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text('Log out?', style: AppText.cardTitle()),
        content: Text(
          'You can sign back in any time with the same account.',
          style: AppText.body(AppColors.inkSoft).copyWith(height: 1.45),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel', style: AppText.bodyStrong(AppColors.inkSoft)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              widget.onSignOut?.call();
            },
            child: Text('Log Out', style: AppText.bodyStrong(AppColors.danger)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PadelRefresh(
      onRefresh: _refresh,
      slivers: [
        SliverPadding(
          padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top, bottom: 120),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              _hero(context),
              DivisionCard(
                  ranking: _profile.ranking,
                  onPlayPlacement: widget.onFindMatch),
              _statsRow(),
              _eloHistory(),
              _recent(context),
              _menu(context),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _hero(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [AppColors.surfaceAlt, AppColors.bg]),
        ),
        child: Column(children: [
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            _circleBtn(Icons.ios_share_rounded, onTap: () => _shareProfile(context)),
            const SizedBox(width: 8),
            _circleBtn(Icons.settings_outlined, onTap: () => _openSettings(context)),
          ]),
          AppAvatar(widget.initials.isNotEmpty ? widget.initials : 'P', size: 88, ring: 2.5),
          const SizedBox(height: 10),
          Text(widget.displayName.isNotEmpty ? widget.displayName : 'Player',
              style: AppText.stat(22)),
          const SizedBox(height: 8),
          if (widget.memberSince.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.line)),
              child: Text('Member since ${widget.memberSince}',
                  style: AppText.small().copyWith(fontSize: 11)),
            ),
          const SizedBox(height: 14),
          AppButton('Edit Profile',
              onPressed: () => _push(context, const EditProfileScreen())),
        ]),
      );

  Widget _circleBtn(IconData icon, {VoidCallback? onTap}) => GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 34,
          height: 34,
          decoration: const BoxDecoration(
              color: AppColors.surface, shape: BoxShape.circle, boxShadow: kCardShadow),
          child: Icon(icon, size: 18, color: AppColors.inkSoft),
        ),
      );

  /// Share button — opens the native share sheet with a short profile + invite
  /// blurb (share_plus). sharePositionOrigin anchors the iPad popover.
  void _shareProfile(BuildContext context) {
    final name = widget.displayName.isNotEmpty ? widget.displayName : 'A player';
    final r = _profile.ranking;
    final rankLine = r.placed ? 'Level ${r.level.toStringAsFixed(1)}' : 'getting ranked';
    final record = _profile.played > 0
        ? ' · ${_profile.wins}W-${_profile.losses}L (${_profile.winRate})'
        : '';
    final box = context.findRenderObject() as RenderBox?;
    Share.share(
      '$name on Padel Rivals — $rankLine$record.\nJoin me on the court! 🎾',
      subject: 'Padel Rivals',
      sharePositionOrigin:
          box != null ? box.localToGlobal(Offset.zero) & box.size : null,
    );
  }

  /// Settings gear — quick sheet to the account/settings screens (also reachable
  /// from the menu below, but this is the conventional top-of-profile shortcut).
  void _openSettings(BuildContext context) {
    final items = <(IconData, String, Widget)>[
      (Icons.notifications_none_rounded, 'Notifications', const NotificationsScreen()),
      (Icons.shield_outlined, 'Privacy & Account', const PrivacyAccountScreen()),
      (Icons.help_outline_rounded, 'Help & Support', const HelpSupportScreen()),
    ];
    showModalBottomSheet(
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
                  color: AppColors.line, borderRadius: BorderRadius.circular(99))),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
            child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Settings', style: AppText.cardTitle())),
          ),
          for (final it in items)
            ListTile(
              leading: Icon(it.$1, size: 22, color: AppColors.inkSoft),
              title: Text(it.$2,
                  style: AppText.body().copyWith(fontSize: 15, fontWeight: FontWeight.w700)),
              trailing: const Icon(Icons.chevron_right_rounded,
                  size: 18, color: AppColors.inkFaint),
              onTap: () {
                Navigator.pop(sheetCtx);
                _push(context, it.$3);
              },
            ),
          const SizedBox(height: 12),
        ]),
      ),
    );
  }

  Widget _statsRow() {
    final stats = [
      ['${_profile.played}', 'Played'],
      ['${_profile.wins}', 'Wins'],
      ['${_profile.losses}', 'Losses'],
      [_profile.winRate, 'Win Rate'],
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 14, AppSpacing.screen, 0),
      child: AppCard(
        padding: EdgeInsets.zero,
        child: Row(children: [
          for (int i = 0; i < stats.length; i++)
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                    border: i == 0 ? null : const Border(left: BorderSide(color: AppColors.line))),
                child: Column(children: [
                  Text(stats[i][0], style: AppText.stat(18)),
                  const SizedBox(height: 2),
                  Text(stats[i][1], style: AppText.tag().copyWith(fontSize: 10)),
                ]),
              ),
            ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              color: AppColors.primary.withValues(alpha: 0.1),
              child: Column(children: [
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Icon(Icons.local_fire_department_rounded,
                      size: 15, color: AppColors.primary),
                  const SizedBox(width: 2),
                  Text('${_profile.streak}', style: AppText.stat(18, AppColors.primary)),
                ]),
                const SizedBox(height: 2),
                Text('Streak', style: AppText.tag().copyWith(fontSize: 10)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _eloHistory() {
    final data = _profile.eloHistory;
    if (data.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 14, AppSpacing.screen, 0),
        child: AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('ELO HISTORY', style: AppText.kicker()),
            const SizedBox(height: 12),
            Row(children: [
              Container(
                width: 46,
                height: 46,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: AppColors.field, borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.show_chart_rounded, size: 22, color: AppColors.inkFaint),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('No rating yet', style: AppText.bodyStrong().copyWith(fontSize: 13.5)),
                  const SizedBox(height: 2),
                  Text(
                      'Your ELO is seeded after placement — the chart fills in from your first rated match.',
                      style: AppText.small().copyWith(fontSize: 12, height: 1.45)),
                ]),
              ),
            ]),
          ]),
        ),
      );
    }
    final delta = data.last - data.first;
    final up = delta >= 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 14, AppSpacing.screen, 0),
      child: AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('ELO HISTORY', style: AppText.kicker()),
              const SizedBox(height: 1),
              Text('Last ${data.length} rated matches',
                  style: AppText.tag(AppColors.inkFaint).copyWith(fontSize: 11)),
            ]),
            const Spacer(),
            Row(children: [
              Icon(up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
                  size: 14, color: up ? AppColors.success : AppColors.danger),
              Text(' ${up ? '+' : ''}$delta pts',
                  style: AppText.bodyStrong(up ? AppColors.success : AppColors.danger)),
            ]),
          ]),
          const SizedBox(height: 8),
          EloChart(data),
          const SizedBox(height: 6),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            for (final m in ['Feb', 'Mar', 'Apr', 'May'])
              Text(m, style: AppText.tag(AppColors.inkFaint).copyWith(fontSize: 10)),
          ]),
        ]),
      ),
    );
  }

  Widget _recent(BuildContext context) {
    final list = _profile.recent;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 18, AppSpacing.screen, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text('RECENT MATCHES', style: AppText.kicker()),
          const Spacer(),
          if (list.isNotEmpty)
            GestureDetector(
              onTap: () => _push(context, const MatchHistoryScreen()),
              child: Text('See All',
                  style: AppText.bodyStrong(AppColors.primary).copyWith(fontSize: 12)),
            ),
        ]),
        const SizedBox(height: 10),
        if (list.isEmpty)
          AppCard(
            child: Column(children: [
              Container(
                width: 46,
                height: 46,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.primary.withValues(alpha: 0.1)),
                child: const Icon(Icons.history_rounded, size: 22, color: AppColors.primary),
              ),
              const SizedBox(height: 12),
              Text('No matches yet', style: AppText.bodyStrong().copyWith(fontSize: 14)),
              const SizedBox(height: 4),
              Text('Play your placement matches to start building your match history.',
                  textAlign: TextAlign.center,
                  style: AppText.small().copyWith(fontSize: 12.5, height: 1.5)),
              const SizedBox(height: 14),
              AppButton('Find a Match', icon: Icons.search_rounded, onPressed: widget.onFindMatch),
            ]),
          )
        else
          AppCard(
            padding: EdgeInsets.zero,
            child: Column(children: [
              for (int i = 0; i < list.length; i++)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                      border: i == 0
                          ? null
                          : const Border(top: BorderSide(color: AppColors.line))),
                  child: Row(children: [
                    Container(
                      width: 34,
                      height: 34,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                          color: (list[i].won ? AppColors.success : AppColors.danger)
                              .withValues(alpha: 0.13),
                          borderRadius: BorderRadius.circular(8)),
                      child: Text(list[i].won ? 'W' : 'L',
                          style: AppText.stat(
                              13, list[i].won ? AppColors.success : AppColors.danger)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(list[i].opp, style: AppText.bodyStrong()),
                        Text('${list[i].type} · ${list[i].date}',
                            style: AppText.small().copyWith(fontSize: 11)),
                      ]),
                    ),
                    Text(list[i].score, style: AppText.bodyStrong()),
                  ]),
                ),
            ]),
          ),
      ]),
    );
  }

  Widget _menu(BuildContext context) {
    final items = <(IconData, String, Widget)>[
      (Icons.receipt_long_outlined, 'My Orders', MyOrdersScreen(onReorder: widget.onReorder)),
      (Icons.emoji_events_outlined, 'My Tournaments', const MyTournamentsScreen()),
      (Icons.history_rounded, 'Match History', const MatchHistoryScreen()),
      (Icons.notifications_none_rounded, 'Notifications', const NotificationsScreen()),
      (Icons.shield_outlined, 'Privacy & Account', const PrivacyAccountScreen()),
      (Icons.help_outline_rounded, 'Help & Support', const HelpSupportScreen()),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.screen, 18, AppSpacing.screen, 0),
      child: AppCard(
        padding: EdgeInsets.zero,
        child: Column(children: [
          for (int i = 0; i < items.length; i++)
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => _push(context, items[i].$3),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                      border: i == 0
                          ? null
                          : const Border(top: BorderSide(color: AppColors.line))),
                  child: Row(children: [
                    Icon(items[i].$1, size: 21, color: AppColors.inkSoft),
                    const SizedBox(width: 14),
                    Expanded(
                        child: Text(items[i].$2,
                            style: AppText.body().copyWith(fontSize: 15))),
                    const Icon(Icons.chevron_right_rounded,
                        size: 18, color: AppColors.inkFaint),
                  ]),
                ),
              ),
            ),
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => _confirmSignOut(context),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: AppColors.line))),
                child: Row(children: [
                  const Icon(Icons.logout_rounded, size: 21, color: AppColors.danger),
                  const SizedBox(width: 14),
                  Expanded(
                      child: Text('Log Out',
                          style: AppText.bodyStrong(AppColors.danger).copyWith(fontSize: 15))),
                ]),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
