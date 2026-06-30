import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../frontend/navigation/push_router.dart';
import 'theme/admin_colors.dart';
import 'widgets/admin_kit.dart';
import 'data/admin_service.dart';
import 'screens/admin_dashboard_screen.dart';
import 'screens/admin_players_screen.dart';
import 'screens/admin_matches_screen.dart';
import 'screens/admin_inventory_screen.dart';
import 'screens/admin_tournaments_screen.dart';
import 'screens/admin_requests_screen.dart';
import 'screens/admin_courts_screen.dart';
import 'screens/admin_reports_screen.dart';
import 'screens/admin_promotions_screen.dart';
import 'screens/admin_payments_screen.dart';
import 'screens/admin_broadcasts_screen.dart';

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

class _NavItem {
  final String id, label, group;
  final IconData icon;
  const _NavItem(this.id, this.label, this.icon, this.group);
}

class _AdminConsoleState extends State<AdminConsole> {
  String _active = 'dashboard';
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  int _adminAlerts = 0; // total unread 'admin_*' notifications
  Map<String, int> _sectionAlerts = {}; // per-section unread (payments/requests/tournaments)
  RealtimeChannel? _notifChannel;

  @override
  void initState() {
    super.initState();
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

  /// Switch to a section; if it carries unread alerts, mark them read so its
  /// badge clears (both the sidebar item and the bell total drop).
  Future<void> _navTo(String id) async {
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

  /// Tapping the bell jumps to the screen for the newest unread alert
  /// (Payments / Requests / Tournaments) and clears the badge.
  Future<void> _openAlerts() async {
    final type = await AdminService.newestAdminAlertType();
    final dest = AdminService.sectionForAlertType(type) ?? 'payments';
    setState(() {
      _active = dest;
      _adminAlerts = 0;
      _sectionAlerts = {};
    });
    await AdminService.markAdminNotificationsRead();
  }

  // Nav mirrors the design screenshot exactly
  static const _nav = <_NavItem>[
    // Overview
    _NavItem('dashboard', 'Dashboard', Icons.grid_view_rounded, 'Overview'),
    _NavItem('reports', 'Reports', Icons.bar_chart_rounded, 'Overview'),
    // Operations
    _NavItem('players', 'Players', Icons.groups_outlined, 'Operations'),
    _NavItem('matches', 'Matches', Icons.sports_tennis_rounded, 'Operations'),
    _NavItem('tournaments', 'Tournaments', Icons.emoji_events_outlined, 'Operations'),
    _NavItem('courts', 'Courts', Icons.place_outlined, 'Operations'),
    // Commerce
    _NavItem('store', 'Store & Orders', Icons.shopping_bag_outlined, 'Commerce'),
    _NavItem('promotions', 'Promotions', Icons.local_offer_outlined, 'Commerce'),
    _NavItem('payments', 'Payments', Icons.credit_card_rounded, 'Commerce'),
    // Service
    _NavItem('requests', 'Requests', Icons.build_outlined, 'Service'),
    // Engage
    _NavItem('broadcasts', 'Broadcasts', Icons.notifications_outlined, 'Engage'),
  ];

  static const _meta = <String, List<String>>{
    'dashboard':   ['Dashboard',    'Operations overview'],
    'reports':     ['Reports',      'Analytics & exports'],
    'players':     ['Players',      'Profiles & rankings'],
    'matches':     ['Matches',      'Match history'],
    'tournaments': ['Tournaments',  'Brackets & entries'],
    'courts':      ['Courts',       'Partner clubs'],
    'store':       ['Store & Orders', 'Catalogue & orders'],
    'promotions':  ['Promotions',   'Store banners & sales'],
    'payments':    ['Payments',     'Orders & transactions'],
    'requests':    ['Requests',     'Repairs & trade-ins'],
    'broadcasts':  ['Broadcasts',   'Push notifications'],
  };

  Widget _body() {
    switch (_active) {
      case 'reports':     return const AdminReportsScreen();
      case 'players':     return const AdminPlayersScreen();
      case 'matches':     return const AdminMatchesScreen();
      case 'tournaments': return const AdminTournamentsScreen();
      case 'courts':      return const AdminCourtsScreen();
      case 'store':       return const AdminInventoryScreen();
      case 'promotions':  return const AdminPromotionsScreen();
      case 'payments':    return const AdminPaymentsScreen();
      case 'requests':    return const AdminRequestsScreen();
      case 'broadcasts':  return const AdminBroadcastsScreen();
      default:
        return AdminDashboardScreen(onNavigate: (id) => setState(() => _active = id));
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
  final Map<String, int> sectionAlerts;
  final void Function(String) onNav;
  final VoidCallback? onExit;
  final String displayName;
  final String initials;
  const _Drawer({
    required this.active,
    required this.sectionAlerts,
    required this.onNav,
    required this.displayName,
    required this.initials,
    this.onExit,
  });

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<_NavItem>>{};
    for (final item in _AdminConsoleState._nav) {
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
                Text('Super Admin',
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

  Widget _navItem(_NavItem item) {
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
