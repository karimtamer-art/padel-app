import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../frontend/navigation/push_router.dart';
import 'theme/admin_colors.dart';
import 'widgets/admin_kit.dart';
import 'data/admin_service.dart';
import 'data/roles_model.dart';
import 'screens/admin_team_screen.dart';
import 'screens/organizer_overview_screen.dart';
import 'screens/admin_community_screen.dart';
import 'screens/admin_dashboard_screen.dart';
import 'screens/admin_players_screen.dart';
import 'screens/admin_matches_screen.dart';
import 'screens/admin_inventory_screen.dart';
import 'screens/admin_tournaments_screen.dart';
import 'screens/format_builder_screen.dart';
import 'screens/admin_requests_screen.dart';
import 'screens/admin_courts_screen.dart';
import 'screens/admin_reports_screen.dart';
import 'screens/admin_promotions_screen.dart';
import 'screens/admin_payments_screen.dart';
import 'screens/admin_broadcasts_screen.dart';
import 'screens/admin_leaderboards_screen.dart';

class AdminConsole extends StatefulWidget {
  final VoidCallback? onExit;
  final String displayName;
  final String initials;
  const AdminConsole({
    super.key,
    this.onExit,
    this.displayName = 'Admin',
    this.initials = 'A',
  });
  @override
  State<AdminConsole> createState() => _AdminConsoleState();
}

class _AdminConsoleState extends State<AdminConsole> {
  String _active = 'dashboard';
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  int _adminAlerts = 0; // total unread 'admin_*' notifications
  Map<String, int> _sectionAlerts = {}; // per-section unread (payments/requests/tournaments)
  RealtimeChannel? _notifChannel;

  // RBAC — the signed-in staffer's role + which sections they can open.
  // Defaults to full super-admin access until the profile row loads.
  RoleId _role = RoleId.superAdmin;
  List<Section> _navSections =
      navForStaff(RoleId.superAdmin, _allSectionIds);
  static final List<String> _allSectionIds =
      kSections.map((s) => s.id).toList();

  @override
  void initState() {
    super.initState();
    _loadStaff();
    _loadAlerts();
    _subscribeAlerts();
    // A tapped admin push may have set a target section before this mounted.
    _applyPendingPushRoute();
    PushRouter.adminSection.addListener(_onPushRoute);
  }

  @override
  void dispose() {
    PushRouter.adminSection.removeListener(_onPushRoute);
    if (_notifChannel != null) {
      Supabase.instance.client.removeChannel(_notifChannel!);
    }
    super.dispose();
  }

  /// Cold start: the push tap set a section before the console existed.
  void _applyPendingPushRoute() {
    final section = PushRouter.adminSection.value;
    if (section == null) return;
    PushRouter.adminSection.value = null; // consume
    WidgetsBinding.instance.addPostFrameCallback((_) => _navTo(section));
  }

  /// Warm start: push tapped while the console was already open.
  void _onPushRoute() {
    final section = PushRouter.adminSection.value;
    if (section == null || !mounted) return;
    PushRouter.adminSection.value = null; // consume
    _navTo(section);
  }

  Future<void> _loadAlerts() async {
    final total = await AdminService.adminUnreadCount();
    final sections = await AdminService.adminAlertSectionCounts();
    if (mounted) {
      setState(() {
        _adminAlerts = total;
        _sectionAlerts = sections;
      });
    }
  }

  /// Load the signed-in staffer's role + effective access, then land them on
  /// their home section. A legacy super admin whose backfill hasn't run yet
  /// (admin_role null but is_admin true) is treated as super admin.
  Future<void> _loadStaff() async {
    final row = await AdminService.currentStaff();
    var role = RoleId.superAdmin;
    List<String>? custom;
    if (row != null) {
      role = roleFromString(row['admin_role'] as String?) ??
          (row['is_admin'] == true ? RoleId.superAdmin : RoleId.support);
      custom = (row['admin_access'] as List?)?.map((e) => e.toString()).toList();
    }
    final access = effectiveAccess(role, custom);
    final nav = navForStaff(role, access);
    if (!mounted) return;
    setState(() {
      _role = role;
      _navSections = nav;
      if (!nav.any((s) => s.id == _active)) {
        _active = homeIdForStaff(role, access);
      }
    });
  }

  /// Switch to a section; if it carries unread alerts, mark them read so its
  /// badge clears (both the sidebar item and the bell total drop).
  Future<void> _navTo(String id) async {
    if (!_navSections.any((s) => s.id == id)) return; // guard — out of scope
    if (mounted) setState(() => _active = id);
    if ((_sectionAlerts[id] ?? 0) > 0) {
      await AdminService.markAdminSectionRead(id);
      await _loadAlerts();
    }
  }

  /// Live: bump the badge the instant a trigger inserts any 'admin_*' alert row
  /// for this admin (order/trade/repair/tournament). RLS limits the stream to
  /// own rows.
  void _subscribeAlerts() {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    _notifChannel = Supabase.instance.client
        .channel('admin-alerts-$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'notifications',
          filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq, column: 'user_id', value: uid),
          callback: (payload) {
            final type = payload.newRecord['type'] as String?;
            if (type != null && type.startsWith('admin_') && mounted) {
              final section = AdminService.sectionForAlertType(type);
              setState(() {
                _adminAlerts++;
                if (section != null) {
                  _sectionAlerts = {
                    ..._sectionAlerts,
                    section: (_sectionAlerts[section] ?? 0) + 1,
                  };
                }
              });
            }
          },
        )
        .subscribe();
  }

  /// Tapping the bell opens a list of recent admin alerts (new orders, trade-in
  /// & repair requests, tournament payments). Tapping a row jumps to the section
  /// that handles it. Opening the list marks the alerts read so badges clear.
  Future<void> _openAlerts() async {
    final alerts = await AdminService.recentAdminAlerts();
    if (!mounted) return;
    // Clear the badges as the sheet opens, not after it closes — the counts
    // are stale the moment the list is on screen, and waiting for dismissal
    // left the bell lit while you were reading it.
    setState(() {
      _adminAlerts = 0;
      _sectionAlerts = {};
    });
    // Not awaited here (the sheet should open instantly) but awaited before
    // the re-sync below, so _loadAlerts can't read pre-write counts back.
    final marking = AdminService.markAdminNotificationsRead();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AdminColors.canvas,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _AlertsSheet(
        alerts: alerts,
        onTapItem: (type) {
          Navigator.pop(ctx);
          final dest = AdminService.sectionForAlertType(type);
          if (dest != null) _navTo(dest);
        },
      ),
    );
    // Re-sync on the way out: anything that landed while the sheet was open
    // is genuinely unread and should badge again.
    await marking;
    await _loadAlerts();
  }

  static const _meta = <String, List<String>>{
    'org-home':    ['Organizer',    'Your events & community'],
    'community':   ['Community',     'Members, inbox & announcements'],
    'dashboard':   ['Dashboard',    'Operations overview'],
    'reports':     ['Reports',      'Analytics & exports'],
    'players':     ['Players',      'Profiles & rankings'],
    'matches':     ['Matches',      'Match history'],
    'tournaments': ['Tournaments',  'Brackets & entries'],
    'formats':     ['Format Builder', 'Design tournament formats'],
    'courts':      ['Courts',       'Partner clubs'],
    'store':       ['Store & Orders', 'Catalogue & orders'],
    'promotions':  ['Promotions',   'Store banners & sales'],
    'payments':    ['Payments',     'Orders & transactions'],
    'requests':    ['Requests',     'Repairs & trade-ins'],
    'broadcasts':  ['Broadcasts',   'Push notifications'],
    'leaderboards':['Leaderboards', 'Season standings & rewards'],
    'team':        ['Team & Roles', 'Invite & assign access'],
  };

  Widget _body() {
    final orgId = _role == RoleId.organizer
        ? Supabase.instance.client.auth.currentUser?.id
        : null;
    switch (_active) {
      case 'org-home':    return OrganizerOverviewScreen(
          onOpenTournaments: () => _navTo('tournaments'));
      case 'community':   return const AdminCommunityScreen();
      // Only super admins record expenses; the DB enforces the same (RLS on
      // `expenses` is _is_admin()), this just hides the buttons.
      case 'reports':     return AdminReportsScreen(
          canEdit: _role == RoleId.superAdmin);
      case 'players':     return const AdminPlayersScreen();
      case 'matches':     return AdminMatchesScreen(isOrganizer: _role == RoleId.organizer);
      case 'tournaments': return AdminTournamentsScreen(organizerId: orgId);
      case 'formats':     return FormatBuilderScreen(organizerId: orgId);
      case 'courts':      return AdminCourtsScreen(organizerId: orgId);
      case 'store':       return const AdminInventoryScreen();
      case 'promotions':  return const AdminPromotionsScreen();
      case 'payments':    return const AdminPaymentsScreen();
      case 'requests':    return const AdminRequestsScreen();
      case 'broadcasts':  return AdminBroadcastsScreen(organizerId: orgId);
      case 'leaderboards': return const AdminLeaderboardsScreen();
      case 'team':        return const AdminTeamScreen();
      default:
        return AdminDashboardScreen(onNavigate: _navTo);
    }
  }

  @override
  Widget build(BuildContext context) {
    final meta = _meta[_active] ?? ['Admin', ''];
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: AdminColors.canvas,
      drawer: _Drawer(
        active: _active,
        sections: _navSections,
        role: _role,
        sectionAlerts: _sectionAlerts,
        onNav: (id) {
          Navigator.pop(context);
          _navTo(id);
        },
        onExit: widget.onExit,
        displayName: widget.displayName,
        initials: widget.initials,
      ),
      body: Column(children: [
        Container(
          padding: EdgeInsets.fromLTRB(
              14, MediaQuery.of(context).padding.top + 8, 14, 12),
          decoration: const BoxDecoration(
              color: AdminColors.canvas,
              border: Border(bottom: BorderSide(color: AdminColors.line))),
          child: Row(children: [
            _menuBtn(),
            const SizedBox(width: 12),
            Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(meta[0],
                  style: AdminText.sans(18, FontWeight.w800, AdminColors.ink,
                      ls: -0.3)),
              if (meta[1].isNotEmpty)
                Text(meta[1], style: AdminText.small()),
            ])),
            _bellBtn(),
            const SizedBox(width: 8),
            _squareBtn(Icons.logout_rounded, widget.onExit ?? () {}),
          ]),
        ),
        Expanded(child: _body()),
      ]),
    );
  }

  /// Menu button with a small dot when there are unread alerts — so an admin
  /// knows to open the drawer even when the bell isn't in view.
  Widget _menuBtn() => Stack(clipBehavior: Clip.none, children: [
        _squareBtn(
            Icons.menu_rounded, () => _scaffoldKey.currentState?.openDrawer()),
        if (_adminAlerts > 0)
          Positioned(
            top: -3,
            right: -3,
            child: Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(
                  color: AdminColors.danger,
                  shape: BoxShape.circle,
                  border: Border.all(color: AdminColors.canvas, width: 1.5)),
            ),
          ),
      ]);

  Widget _squareBtn(IconData icon, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
              color: AdminColors.surface,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: AdminColors.line)),
          child: Icon(icon, size: 19, color: AdminColors.ink),
        ),
      );

  /// Order-alert bell with an unread badge. Discreet — it's just a bell in the
  /// admin top bar; only admins ever reach this screen.
  Widget _bellBtn() => GestureDetector(
        onTap: _openAlerts,
        child: Stack(clipBehavior: Clip.none, children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: AdminColors.surface,
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: AdminColors.line)),
            child: Icon(
                _adminAlerts > 0
                    ? Icons.notifications_active_rounded
                    : Icons.notifications_none_rounded,
                size: 19,
                color: _adminAlerts > 0 ? AdminColors.primary : AdminColors.ink),
          ),
          if (_adminAlerts > 0)
            Positioned(
              top: -5,
              right: -5,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                constraints: const BoxConstraints(minWidth: 18),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: AdminColors.danger,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: AdminColors.canvas, width: 1.5)),
                child: Text(_adminAlerts > 99 ? '99+' : '$_adminAlerts',
                    style: AdminText.sans(10, FontWeight.w800, Colors.white)),
              ),
            ),
        ]),
      );
}

class _Drawer extends StatelessWidget {
  final String active;
  final List<Section> sections;
  final RoleId role;
  final Map<String, int> sectionAlerts;
  final void Function(String) onNav;
  final VoidCallback? onExit;
  final String displayName;
  final String initials;
  const _Drawer({
    required this.active,
    required this.sections,
    required this.role,
    required this.sectionAlerts,
    required this.onNav,
    required this.displayName,
    required this.initials,
    this.onExit,
  });

  @override
  Widget build(BuildContext context) {
    final def = kRoles[role]!;
    final accessTag = role == RoleId.superAdmin
        ? 'FULL ACCESS'
        : def.readonly
            ? 'READ-ONLY ACCESS'
            : 'SCOPED ACCESS';
    final groups = <String, List<Section>>{};
    for (final item in sections) {
      groups.putIfAbsent(item.group, () => []).add(item);
    }
    return Drawer(
      width: 264,
      backgroundColor: AdminColors.sidebar,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header
        Container(
          padding: EdgeInsets.fromLTRB(
              20, MediaQuery.of(context).padding.top + 22, 20, 18),
          child: Row(children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: AdminColors.primary,
                  borderRadius: BorderRadius.circular(11),
                  boxShadow: [
                    BoxShadow(
                        color: AdminColors.primary.withValues(alpha: 0.4),
                        blurRadius: 16,
                        offset: const Offset(0, 6))
                  ]),
              child: const Icon(Icons.sports_tennis_rounded,
                  size: 22, color: AdminColors.primaryInk),
            ),
            const SizedBox(width: 11),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('PADEL RIVALS',
                  style: AdminText.sans(15, FontWeight.w900, AdminColors.sidebarInk,
                      ls: 0.4)),
              const SizedBox(height: 3),
              Text('ADMIN CONSOLE',
                  style: AdminText.mono(
                      8.5, FontWeight.w600, AdminColors.sidebarFaint, ls: 1.5)),
            ]),
          ]),
        ),
        // Role chip — current role + access scope
        Container(
          margin: const EdgeInsets.fromLTRB(14, 0, 14, 10),
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: def.color.withValues(alpha: 0.20),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: def.color.withValues(alpha: 0.45)),
          ),
          child: Row(children: [
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: def.color, borderRadius: BorderRadius.circular(8)),
              child: Icon(def.icon, size: 15, color: Colors.white),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(def.label,
                    style: AdminText.sans(
                        12.5, FontWeight.w800, AdminColors.sidebarInk)),
                Text(accessTag,
                    style: AdminText.mono(
                        9, FontWeight.w600, AdminColors.sidebarFaint, ls: 0.6)),
              ]),
            ),
          ]),
        ),
        // Nav groups
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final entry in groups.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
                  child: Text(entry.key.toUpperCase(),
                      style: AdminText.mono(
                          9.5, FontWeight.w700, AdminColors.sidebarFaint,
                          ls: 1.4)),
                ),
                for (final item in entry.value) _navItem(item),
              ],
            ],
          ),
        ),
        // Footer — real user name from AuthGate
        Container(
          padding: const EdgeInsets.all(12),
          decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Color(0x1AF4EFE2)))),
          child: Row(children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: const Color(0x1FF4EFE2),
                  borderRadius: BorderRadius.circular(9)),
              child: Text(initials,
                  style: AdminText.sans(
                      12, FontWeight.w800, AdminColors.sidebarInk)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(displayName,
                    style: AdminText.sans(
                        12.5, FontWeight.w700, AdminColors.sidebarInk),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                Text(def.label,
                    style: AdminText.mono(
                        9.5, FontWeight.w500, AdminColors.sidebarFaint)),
              ]),
            ),
            GestureDetector(
              onTap: onExit,
              child: const Icon(Icons.logout_rounded,
                  size: 17, color: AdminColors.sidebarFaint),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _navItem(Section item) {
    final on = active == item.id;
    final badge = sectionAlerts[item.id] ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: on ? AdminColors.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => onNav(item.id),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              Icon(item.icon,
                  size: 18,
                  color: on
                      ? AdminColors.primaryInk
                      : AdminColors.sidebarFaint),
              const SizedBox(width: 11),
              Expanded(
                  child: Text(item.label,
                      style: AdminText.sans(
                          13.5,
                          FontWeight.w600,
                          on
                              ? AdminColors.primaryInk
                              : AdminColors.sidebarFaint))),
              if (badge > 0)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  constraints: const BoxConstraints(minWidth: 18),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                      color: AdminColors.danger,
                      borderRadius: BorderRadius.circular(999)),
                  child: Text(badge > 99 ? '99+' : '$badge',
                      style:
                          AdminText.sans(10, FontWeight.w800, Colors.white)),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Icon + accent colour for an admin alert type.
(IconData, Color) _alertStyle(String? type) => switch (type) {
      'admin_order' => (Icons.shopping_bag_outlined, AdminColors.primary),
      'admin_trade' => (Icons.swap_horiz_rounded, AdminColors.primary),
      'admin_repair' => (Icons.build_outlined, AdminColors.primary),
      'admin_tournament' => (Icons.emoji_events_outlined, AdminColors.primary),
      _ => (Icons.notifications_none_rounded, AdminColors.ink),
    };

/// Compact "3m ago" / "2h ago" / "5d ago" from an ISO timestamp.
String _relTime(String? iso) {
  if (iso == null) return '';
  final t = DateTime.tryParse(iso);
  if (t == null) return '';
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  return '${(d.inDays / 7).floor()}w ago';
}

/// Bottom sheet the admin bell opens: a list of recent admin alerts. Each row
/// taps through to the section that handles it (via [onTapItem]).
class _AlertsSheet extends StatelessWidget {
  final List<Map<String, dynamic>> alerts;
  final void Function(String? type) onTapItem;
  const _AlertsSheet({required this.alerts, required this.onTapItem});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.72),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 10),
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: AdminColors.line,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
              child: Text('Notifications',
                  style: AdminText.sans(18, FontWeight.w800, AdminColors.ink,
                      ls: -0.3)),
            ),
            if (alerts.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 26, 20, 44),
                child: Center(
                  child: Column(children: [
                    const Icon(Icons.notifications_none_rounded,
                        size: 40, color: AdminColors.line),
                    const SizedBox(height: 10),
                    Text("You're all caught up", style: AdminText.small()),
                  ]),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  itemCount: alerts.length,
                  itemBuilder: (_, i) => _row(alerts[i]),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(Map<String, dynamic> a) {
    final type = a['type'] as String?;
    final unread = a['read'] == false;
    final (icon, color) = _alertStyle(type);
    final body = a['body'] as String?;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => onTapItem(type),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 38,
              height: 38,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, size: 18, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text((a['title'] as String?) ?? 'Notification',
                        style: AdminText.sans(
                            13.5, FontWeight.w700, AdminColors.ink)),
                    if (body != null && body.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(body,
                          style: AdminText.small(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                    ],
                    const SizedBox(height: 4),
                    Text(_relTime(a['created_at'] as String?),
                        style: AdminText.mono(
                            9.5, FontWeight.w500, AdminColors.sidebarFaint)),
                  ]),
            ),
            if (unread)
              Container(
                margin: const EdgeInsets.only(top: 5, left: 6),
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                    color: AdminColors.danger, shape: BoxShape.circle),
              ),
          ]),
        ),
      ),
    );
  }
}
