// ============================================================================
// roles_model.dart — role-based access model (RBAC) for the admin console.
//
// One console, filtered per role. A Super Admin grants roles; each role sees
// only the sections it can open (hidden gating). The DB is the real guard —
// only super admins keep `is_admin = true` (see 2026-07-10_rbac_roles.sql).
//
// Section ids here MUST match the ids the console switches on in
// admin_console.dart (`dashboard, reports, players, matches, tournaments,
// courts, store, promotions, payments, requests, broadcasts`) plus `team`.
// ============================================================================
import 'package:flutter/material.dart';
import '../theme/admin_colors.dart';

enum RoleId { superAdmin, organizer, support, analyst }

String roleToString(RoleId r) => switch (r) {
      RoleId.superAdmin => 'super_admin',
      RoleId.organizer => 'organizer',
      RoleId.support => 'support',
      RoleId.analyst => 'analyst',
    };

RoleId? roleFromString(String? s) => switch (s) {
      'super_admin' => RoleId.superAdmin,
      'organizer' => RoleId.organizer,
      'support' => RoleId.support,
      'analyst' => RoleId.analyst,
      _ => null,
    };

/// One grantable console section — the atoms of custom access. Its [id] is the
/// same string the console body switches on.
class Section {
  final String id, label, group, desc;
  final IconData icon;
  const Section(this.id, this.label, this.icon, this.group, this.desc);
}

/// The full catalogue, in display order. Mirrors the console's `_nav` plus the
/// Super-Admin-only Team section.
const List<Section> kSections = [
  Section('dashboard', 'Dashboard', Icons.grid_view_rounded, 'Overview', 'KPIs & activity'),
  Section('reports', 'Reports', Icons.bar_chart_rounded, 'Overview', 'Analytics & exports'),
  Section('players', 'Players', Icons.groups_outlined, 'Operations', 'Profiles & rankings'),
  Section('matches', 'Matches', Icons.sports_tennis_rounded, 'Operations', 'Lobbies & disputes'),
  Section('tournaments', 'Tournaments', Icons.emoji_events_outlined, 'Operations', 'Brackets & entries'),
  Section('formats', 'Format Builder', Icons.auto_awesome_rounded, 'Operations', 'Design tournament formats'),
  Section('courts', 'Courts', Icons.place_outlined, 'Operations', 'Partner clubs'),
  Section('store', 'Store & Orders', Icons.shopping_bag_outlined, 'Commerce', 'Catalogue & orders'),
  Section('promotions', 'Promotions', Icons.local_offer_outlined, 'Commerce', 'Banners & sales'),
  Section('payments', 'Payments', Icons.credit_card_rounded, 'Commerce', 'Orders & transactions'),
  Section('requests', 'Requests', Icons.build_outlined, 'Service', 'Repairs & trade-ins'),
  Section('broadcasts', 'Broadcasts', Icons.notifications_outlined, 'Engage', 'Push & in-app'),
  Section('team', 'Team & Roles', Icons.lock_outline, 'Admin', 'Invite & assign access'),
];

Section sectionById(String id) =>
    kSections.firstWhere((s) => s.id == id, orElse: () => kSections.first);

/// The catalogue grouped for the permission editor (preserves order).
Map<String, List<Section>> sectionsByGroup() {
  final m = <String, List<Section>>{};
  for (final s in kSections) {
    m.putIfAbsent(s.group, () => []).add(s);
  }
  return m;
}

/// A role definition — identity, accent, and starting access.
class RoleDef {
  final RoleId id;
  final String label, tagline;
  final Color color;
  final IconData icon;
  final bool readonly;
  final List<String> defaultAccess; // section ids
  const RoleDef(this.id, this.label, this.icon, this.color, this.tagline,
      this.defaultAccess,
      {this.readonly = false});
}

const List<String> _allIds = [
  'dashboard', 'reports', 'players', 'matches', 'tournaments', 'formats', 'courts',
  'store', 'promotions', 'payments', 'requests', 'broadcasts', 'team',
];

const Map<RoleId, RoleDef> kRoles = {
  RoleId.superAdmin: RoleDef(
      RoleId.superAdmin,
      'Super Admin',
      Icons.workspace_premium_outlined,
      Color(0xFFC2502A),
      'Full control of the entire platform.',
      _allIds),
  RoleId.organizer: RoleDef(
      RoleId.organizer,
      'Organizer',
      Icons.emoji_events_outlined,
      AdminColors.gold,
      'Runs tournaments and reaches the community — no store or platform payments.',
      // Organizers get a Broadcasts section scoped to their OWN broadcasts
      // (community + event entrants), not the platform-wide feed.
      ['tournaments', 'formats', 'matches', 'courts', 'broadcasts']),
  RoleId.support: RoleDef(
      RoleId.support,
      'Support · Moderator',
      Icons.shield_outlined,
      AdminColors.info,
      'Keeps play fair — players, disputes and service requests.',
      ['players', 'matches', 'requests']),
  RoleId.analyst: RoleDef(
      RoleId.analyst,
      'Analyst',
      Icons.trending_up_rounded,
      AdminColors.green,
      'Read-only. Sees the numbers, changes nothing.',
      ['dashboard', 'reports'],
      readonly: true),
};

/// Neutral accent for a member whose access deviates from any role preset.
const Color kCustomColor = Color(0xFF6E7B69);

List<String> defaultAccessFor(RoleId r) => List.of(kRoles[r]!.defaultAccess);

String _norm(List<String> a) => (List.of(a)..sort()).join(',');

/// Whether [access] differs from [base]'s default set (→ "Custom access").
bool isCustom(RoleId base, List<String> access) =>
    _norm(access) != _norm(defaultAccessFor(base));

/// The effective section access for a staffer: their custom [access] if set,
/// otherwise the role's default. Super admins always get everything.
List<String> effectiveAccess(RoleId role, List<String>? access) {
  if (role == RoleId.superAdmin) return List.of(_allIds);
  if (access != null && access.isNotEmpty) return List.of(access);
  return defaultAccessFor(role);
}

/// Ordered grantable nav sections for [access], preserving [kSections] order.
List<Section> navForAccess(List<String> access) {
  final set = access.toSet();
  return kSections.where((s) => set.contains(s.id)).toList();
}

/// A role's own landing section (e.g. the Organizer Overview), or null. Not a
/// grantable section — it's prepended to the nav and is that role's home.
Section? homeSectionFor(RoleId r) => switch (r) {
      RoleId.organizer => const Section('org-home', 'Overview',
          Icons.grid_view_rounded, 'Overview', 'Your events at a glance'),
      _ => null,
    };

/// Role-specific sections appended after the granted ones (e.g. an organizer's
/// Community). Not part of the grantable catalogue.
List<Section> extraSectionsFor(RoleId r) => switch (r) {
      RoleId.organizer => const [
          Section('community', 'Community', Icons.groups_2_outlined, 'Community',
              'Members & inbox'),
        ],
      _ => const [],
    };

/// Full ordered nav for a staffer: role home (if any), granted sections, then
/// any role-specific extras (Community).
List<Section> navForStaff(RoleId role, List<String> access) {
  final home = homeSectionFor(role);
  return [
    if (home != null) home,
    ...navForAccess(access),
    ...extraSectionsFor(role),
  ];
}

/// The section the staffer lands on. Falls back to dashboard if they have none.
String homeIdForStaff(RoleId role, List<String> access) {
  final nav = navForStaff(role, access);
  return nav.isEmpty ? 'dashboard' : nav.first.id;
}

/// A staff member with console access (backed by the `profiles` row).
class StaffMember {
  final String id;
  String name, email;
  RoleId role;
  List<String> access; // effective section ids
  String? scope, username, avatarUrl;
  double level;
  final bool owner;
  StaffMember({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.access,
    this.scope,
    this.username,
    this.avatarUrl,
    this.level = 0,
    this.owner = false,
  });

  bool get isCustomAccess => !owner && isCustom(role, access);

  String get initials {
    final base = name.trim().isEmpty ? email : name;
    final parts =
        base.trim().split(RegExp(r'[\s@._]+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  factory StaffMember.fromRow(Map<String, dynamic> r) {
    final role = roleFromString(r['admin_role'] as String?) ?? RoleId.support;
    final rawAccess = (r['admin_access'] as List?)?.map((e) => e.toString()).toList();
    return StaffMember(
      id: r['id'] as String,
      name: (r['name'] as String?)?.trim().isNotEmpty == true
          ? r['name'] as String
          : (r['email'] as String? ?? 'Unknown'),
      email: r['email'] as String? ?? '',
      role: role,
      access: effectiveAccess(role, rawAccess),
      scope: r['admin_scope'] as String?,
      username: r['username'] as String?,
      avatarUrl: r['avatar_url'] as String?,
      level: (r['level'] as num?)?.toDouble() ?? 0,
      owner: r['is_owner'] == true,
    );
  }
}
