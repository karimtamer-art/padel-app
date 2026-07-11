// ============================================================================
// admin_team_screen.dart — Team & Roles (Super Admin only).
// • staff directory + the four starting roles
// • invite an existing user (search the user DB) and grant a role
// • granular permission editor — start from a role preset, then fine-tune
// Writes go through AdminService → SECURITY DEFINER RPCs (super-admin-gated).
// ============================================================================
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../backend/models/ranking_scale.dart';
import '../data/admin_service.dart';
import '../data/roles_model.dart';
import '../theme/admin_colors.dart';
import '../widgets/admin_kit.dart';

class AdminTeamScreen extends StatefulWidget {
  const AdminTeamScreen({super.key});
  @override
  State<AdminTeamScreen> createState() => _AdminTeamScreenState();
}

class _AdminTeamScreenState extends State<AdminTeamScreen> {
  List<StaffMember> _staff = [];
  bool _loading = true;
  RoleId? _filter;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final rows = await AdminService.fetchStaff();
    if (!mounted) return;
    setState(() {
      _staff = rows.map(StaffMember.fromRow).toList();
      _loading = false;
    });
  }

  int _count(RoleId r) => _staff.where((s) => s.role == r).length;

  Future<void> _openCreateStaff() async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _CreateStaffSheet(),
    );
    if (created == true) _load();
  }

  Future<void> _openInvite() async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _AccessSheet(),
    );
    if (changed == true) _load();
  }

  Future<void> _openManage(StaffMember m) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _AccessSheet(member: m),
    );
    if (changed == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AdminColors.primary));
    }
    final shown =
        _filter == null ? _staff : _staff.where((s) => s.role == _filter).toList();
    return RefreshIndicator(
      color: AdminColors.primary,
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(AdminUI.screen), children: [
        Text('ACCESS CONTROL', style: AdminText.kicker()),
        const SizedBox(height: 4),
        Text('Team & Roles', style: AdminText.h1()),
        const SizedBox(height: 4),
        Text(
            'Pick a role as a starting point, then fine-tune exactly which '
            'sections each person can open.',
            style: AdminText.small()),
        const SizedBox(height: 14),
        AdminButton('Create teammate',
            icon: Icons.person_add_alt_1,
            variant: AdminBtn.primary,
            onPressed: _openCreateStaff),
        const SizedBox(height: 8),
        AdminButton('Invite an existing user',
            icon: Icons.mail_outline,
            variant: AdminBtn.ghost,
            onPressed: _openInvite),
        const SizedBox(height: 16),
        // filter chips
        Wrap(spacing: 8, runSpacing: 8, children: [
          _chip('Everyone · ${_staff.length}', _filter == null,
              () => setState(() => _filter = null)),
          for (final r in RoleId.values)
            _chip('${kRoles[r]!.label} · ${_count(r)}', _filter == r,
                () => setState(() => _filter = r)),
        ]),
        const SizedBox(height: 16),
        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 30),
            child: Center(child: Text('No teammates in this view.', style: AdminText.small())),
          )
        else
          for (final m in shown) ...[_memberCard(m), const SizedBox(height: 12)],
        const SizedBox(height: 16),
        Text('THE FOUR STARTING ROLES', style: AdminText.kicker()),
        const SizedBox(height: 12),
        Wrap(spacing: 12, runSpacing: 12, children: [
          for (final r in RoleId.values)
            SizedBox(width: 236, child: _roleCard(kRoles[r]!)),
        ]),
      ]),
    );
  }

  Widget _chip(String label, bool on, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          decoration: BoxDecoration(
            color: on ? AdminColors.sidebar : AdminColors.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: on ? AdminColors.sidebar : AdminColors.line),
          ),
          child: Text(label,
              style: AdminText.sans(12.5, FontWeight.w700,
                  on ? AdminColors.sidebarInk : AdminColors.ink)),
        ),
      );

  Widget _memberCard(StaffMember m) {
    final def = kRoles[m.role]!;
    final summary = m.owner
        ? 'Full access · all sections'
        : '${m.access.length} section${m.access.length == 1 ? '' : 's'}';
    return AdminCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 14,
        runSpacing: 12,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            AdminAvatar(m.initials, size: 46, color: def.color),
            const SizedBox(width: 13),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 190),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Flexible(
                          child: Text(m.name,
                              style: AdminText.sans(15, FontWeight.w800, AdminColors.ink),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis)),
                      if (m.owner)
                        const Padding(
                          padding: EdgeInsets.only(left: 6),
                          child: Icon(Icons.workspace_premium,
                              size: 14, color: AdminColors.gold),
                        ),
                    ]),
                    Text(m.email,
                        style: AdminText.mono(11.5, FontWeight.w500, AdminColors.inkFaint),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ]),
            ),
          ]),
          Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  _rolePill(def),
                  if (m.isCustomAccess) ...[const SizedBox(width: 6), _customPill()],
                ]),
                const SizedBox(height: 6),
                Text('$summary${m.scope != null ? ' · ${m.scope}' : ''}',
                    style: AdminText.small()),
              ]),
          AdminButton('Manage',
              variant: AdminBtn.ghost, onPressed: () => _openManage(m)),
        ],
      ),
    );
  }

  Widget _rolePill(RoleDef def) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
        decoration: BoxDecoration(
            color: def.color.withValues(alpha: 0.13),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: def.color.withValues(alpha: 0.3))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(def.icon, size: 13, color: def.color),
          const SizedBox(width: 6),
          Text(def.label, style: AdminText.sans(12.5, FontWeight.w700, def.color)),
        ]),
      );

  Widget _customPill() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
            color: kCustomColor.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.tune, size: 12, color: kCustomColor),
          const SizedBox(width: 5),
          Text('Custom', style: AdminText.sans(11.5, FontWeight.w700, kCustomColor)),
        ]),
      );

  Widget _roleCard(RoleDef r) => AdminCard(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: r.color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(11)),
                child: Icon(r.icon, size: 20, color: r.color)),
            const SizedBox(width: 11),
            Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r.label, style: AdminText.cardTitle()),
              Text('${_count(r.id)} MEMBERS · ${r.defaultAccess.length} SECTIONS',
                  style: AdminText.mono(9.5, FontWeight.w700, AdminColors.inkFaint, ls: 0.4)),
            ])),
          ]),
          const SizedBox(height: 12),
          SizedBox(height: 52, child: Text(r.tagline, style: AdminText.small())),
          const Divider(height: 20, color: AdminColors.line),
          Row(children: [
            Icon(r.readonly ? Icons.visibility_outlined : Icons.check_circle_outline,
                size: 14, color: r.color),
            const SizedBox(width: 6),
            Text(
                r.readonly
                    ? 'View only'
                    : r.id == RoleId.superAdmin
                        ? 'Everything'
                        : 'Editable starting point',
                style: AdminText.sans(12, FontWeight.w700, r.color)),
          ]),
        ]),
      );
}

// ── Create teammate (provision a new account of any role) ───────────────────
class _CreateStaffSheet extends StatefulWidget {
  const _CreateStaffSheet();
  @override
  State<_CreateStaffSheet> createState() => _CreateStaffSheetState();
}

class _CreateStaffSheetState extends State<_CreateStaffSheet> {
  final _name = TextEditingController();
  final _username = TextEditingController();
  final _scope = TextEditingController();
  late final _password =
      TextEditingController(text: AdminService.generateTempPassword());
  RoleId _role = RoleId.organizer;
  bool _busy = false;
  String? _error;
  // Set once the account is created — shows the shareable credentials.
  Map<String, String>? _created;

  @override
  void dispose() {
    _name.dispose();
    _username.dispose();
    _scope.dispose();
    _password.dispose();
    super.dispose();
  }

  String? _validate() {
    if (_name.text.trim().isEmpty) return 'Enter the organizer\'s name.';
    final u = _username.text.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9_]{3,20}$').hasMatch(u)) {
      return 'Username: 3–20 chars, lowercase letters, numbers or underscore.';
    }
    if (_password.text.length < 6) return 'Temp password: at least 6 characters.';
    return null;
  }

  Future<void> _create() async {
    final v = _validate();
    if (v != null) {
      setState(() => _error = v);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final username = _username.text.trim().toLowerCase();
    final err = await AdminService.createStaff(
      name: _name.text.trim(),
      username: username,
      password: _password.text,
      role: roleToString(_role),
      scope: _role == RoleId.organizer && _scope.text.trim().isNotEmpty
          ? _scope.text.trim()
          : null,
    );
    if (!mounted) return;
    if (err != null) {
      setState(() {
        _busy = false;
        _error = err;
      });
      return;
    }
    setState(() {
      _busy = false;
      _created = {'username': username, 'password': _password.text};
    });
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      expand: false,
      builder: (_, scroll) => Container(
        decoration: const BoxDecoration(
            color: AdminColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 12, 12),
            child: Row(children: [
              Expanded(
                  child: Text(_created == null ? 'Create teammate' : 'Account created',
                      style: AdminText.h2())),
              IconButton(
                  icon: const Icon(Icons.close_rounded, color: AdminColors.inkSoft),
                  onPressed: () => Navigator.pop(context, _created != null)),
            ]),
          ),
          const Divider(height: 1, color: AdminColors.lineSoft),
          Expanded(
            child: _created == null
                ? _form(scroll)
                : _createdView(scroll, _created!),
          ),
        ]),
      ),
    );
  }

  Widget _form(ScrollController scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: AdminColors.wash(AdminColors.primary, 0.08),
                borderRadius: AdminUI.cardR),
            child: Text(
                'Creates a console account. They log in with the username and '
                'temp password below, then set their own password on first '
                'sign-in.',
                style: AdminText.small()),
          ),
          const SizedBox(height: 16),
          _label('Role'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final r in RoleId.values)
              GestureDetector(
                onTap: () => setState(() => _role = r),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
                  decoration: BoxDecoration(
                    color: _role == r
                        ? kRoles[r]!.color.withValues(alpha: 0.1)
                        : AdminColors.surface,
                    borderRadius: BorderRadius.circular(11),
                    border: Border.all(
                        color: _role == r ? kRoles[r]!.color : AdminColors.line,
                        width: 1.5),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(kRoles[r]!.icon,
                        size: 15,
                        color: _role == r ? kRoles[r]!.color : AdminColors.ink),
                    const SizedBox(width: 7),
                    Text(kRoles[r]!.label,
                        style: AdminText.sans(13, FontWeight.w700,
                            _role == r ? kRoles[r]!.color : AdminColors.ink)),
                  ]),
                ),
              ),
          ]),
          const SizedBox(height: 6),
          Text(kRoles[_role]!.tagline, style: AdminText.small()),
          const SizedBox(height: 16),
          _label('Full name'),
          _field(_name, 'e.g. Ahmed Hassan'),
          const SizedBox(height: 14),
          _label('Username (login)'),
          _field(_username, 'e.g. ahmedpadel', prefix: Icons.alternate_email),
          const SizedBox(height: 14),
          _label('Temporary password'),
          _field(_password, 'Temp password', trailing: IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 20, color: AdminColors.primary),
            tooltip: 'Generate a new one',
            onPressed: () => setState(
                () => _password.text = AdminService.generateTempPassword()),
          )),
          if (_role == RoleId.organizer) ...[
            const SizedBox(height: 14),
            _label('Region / venue scope (optional)'),
            _field(_scope, 'e.g. Cairo & New Cairo'),
          ],
          if (_error != null) ...[
            const SizedBox(height: 14),
            Row(children: [
              const Icon(Icons.error_outline_rounded, size: 16, color: AdminColors.danger),
              const SizedBox(width: 6),
              Expanded(child: Text(_error!, style: AdminText.small(AdminColors.danger))),
            ]),
          ],
          const SizedBox(height: 20),
          AdminButton(_busy ? 'Creating…' : 'Create ${kRoles[_role]!.label}',
              full: true,
              height: 50,
              icon: Icons.person_add_alt_1,
              variant: AdminBtn.primary,
              onPressed: _busy ? null : _create),
        ],
      );

  Widget _createdView(ScrollController scroll, Map<String, String> creds) {
    final line = 'Username: ${creds['username']}\nTemp password: ${creds['password']}';
    return ListView(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      children: [
        Row(children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: AdminColors.wash(AdminColors.green, 0.15),
                borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.check_circle_outline_rounded,
                size: 24, color: AdminColors.green),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
                'Share these credentials with the organizer. They\'ll be asked to '
                'set a new password on first login.',
                style: AdminText.small()),
          ),
        ]),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: AdminColors.surfaceAlt,
              borderRadius: AdminUI.cardR,
              border: Border.all(color: AdminColors.line)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _credRow('USERNAME', creds['username']!),
            const Divider(height: 20, color: AdminColors.lineSoft),
            _credRow('TEMP PASSWORD', creds['password']!),
          ]),
        ),
        const SizedBox(height: 16),
        AdminButton('Copy credentials',
            full: true,
            height: 48,
            icon: Icons.copy_rounded,
            variant: AdminBtn.ghost,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: line));
              adminToast(context, 'Credentials copied');
            }),
        const SizedBox(height: 8),
        AdminButton('Done',
            full: true,
            height: 50,
            variant: AdminBtn.primary,
            onPressed: () => Navigator.pop(context, true)),
      ],
    );
  }

  Widget _credRow(String label, String value) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: AdminText.kicker()),
        const SizedBox(height: 3),
        SelectableText(value,
            style: AdminText.mono(15, FontWeight.w800, AdminColors.ink)),
      ]);

  Widget _label(String t) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(t, style: AdminText.strong(AdminColors.inkSoft)));

  Widget _field(TextEditingController c, String hint,
          {IconData? prefix, Widget? trailing}) =>
      TextField(
        controller: c,
        style: AdminText.body(),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: AdminText.small(AdminColors.inkFaint),
          prefixIcon: prefix == null
              ? null
              : Icon(prefix, size: 18, color: AdminColors.inkFaint),
          suffixIcon: trailing,
          filled: true,
          fillColor: AdminColors.surfaceAlt,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          border: OutlineInputBorder(
              borderRadius: AdminUI.fieldR,
              borderSide: const BorderSide(color: AdminColors.line)),
          enabledBorder: OutlineInputBorder(
              borderRadius: AdminUI.fieldR,
              borderSide: const BorderSide(color: AdminColors.line)),
          focusedBorder: OutlineInputBorder(
              borderRadius: AdminUI.fieldR,
              borderSide: const BorderSide(color: AdminColors.primary)),
        ),
      );
}

// ── Invite (existing user) / manage sheet ──────────────────────────────────
class _AccessSheet extends StatefulWidget {
  final StaffMember? member; // null → invite
  const _AccessSheet({this.member});
  @override
  State<_AccessSheet> createState() => _AccessSheetState();
}

class _AccessSheetState extends State<_AccessSheet> {
  final _search = TextEditingController();
  List<Map<String, dynamic>> _results = [];
  Map<String, dynamic>? _picked; // chosen user row (invite mode)
  bool _searching = false;
  bool _busy = false;

  late RoleId _role;
  late List<String> _access;
  final _scope = TextEditingController();

  bool get _isEdit => widget.member != null;
  bool get _owner => widget.member?.owner ?? false;

  @override
  void initState() {
    super.initState();
    final m = widget.member;
    _role = m?.role ?? RoleId.organizer;
    _access = List.of(m?.access ?? defaultAccessFor(RoleId.organizer));
    _scope.text = m?.scope ?? '';
  }

  @override
  void dispose() {
    _search.dispose();
    _scope.dispose();
    super.dispose();
  }

  bool get _valid {
    if (_isEdit) return true;
    return _picked != null;
  }

  Future<void> _runSearch(String term) async {
    setState(() => _searching = true);
    final res = await AdminService.searchUsers(term);
    if (!mounted) return;
    setState(() {
      _results = res;
      _searching = false;
    });
  }

  Future<void> _save() async {
    if (_owner) return Navigator.pop(context, false);
    setState(() => _busy = true);
    final custom = isCustom(_role, _access) ? _access : null;
    final scope = _role == RoleId.organizer ? _scope.text.trim() : null;
    final userId = _isEdit ? widget.member!.id : _picked!['id'] as String;
    final err = await AdminService.grantRole(userId,
        role: roleToString(_role), access: custom, scope: scope);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      adminToast(context, err, ok: false);
      return;
    }
    Navigator.pop(context, true);
  }

  Future<void> _remove() async {
    setState(() => _busy = true);
    final err = await AdminService.revokeRole(widget.member!.id);
    if (!mounted) return;
    setState(() => _busy = false);
    if (err != null) {
      adminToast(context, err, ok: false);
      return;
    }
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final def = kRoles[_role]!;
    final title = _isEdit ? widget.member!.name : 'Invite a teammate';
    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      expand: false,
      builder: (_, scroll) => Container(
        decoration: const BoxDecoration(
            color: AdminColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 12, 12),
            child: Row(children: [
              Expanded(child: Text(title, style: AdminText.h2())),
              IconButton(
                  icon: const Icon(Icons.close_rounded, color: AdminColors.inkSoft),
                  onPressed: () => Navigator.pop(context, false)),
            ]),
          ),
          const Divider(height: 1, color: AdminColors.lineSoft),
          Expanded(
            child: _owner
                ? _ownerNote()
                : ListView(
                    controller: scroll,
                    padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
                    children: [
                      if (!_isEdit) ...[
                        _label('Find an existing player or user'),
                        if (_picked == null) _picker() else _pickedCard(),
                        const SizedBox(height: 16),
                      ],
                      _permissionEditor(def),
                    ],
                  ),
          ),
          _footer(),
        ]),
      ),
    );
  }

  Widget _ownerNote() => Padding(
        padding: const EdgeInsets.all(18),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: AdminColors.surfaceAlt, borderRadius: AdminUI.cardR),
          child: Text(
              "The owner always has full access and can't be limited or removed. "
              'Transfer ownership from account settings.',
              style: AdminText.body(AdminColors.inkSoft)),
        ),
      );

  Widget _picker() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _field(_search, 'Search by name or email…',
          prefix: Icons.search, onChanged: _runSearch),
      const SizedBox(height: 10),
      if (_searching)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Center(
              child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AdminColors.primary))),
        )
      else if (_search.text.trim().length >= 2 && _results.isEmpty)
        Text('No user matches "${_search.text.trim()}".', style: AdminText.small())
      else
        for (final u in _results)
          InkWell(
            onTap: () => setState(() => _picked = u),
            child: Container(
              margin: const EdgeInsets.only(bottom: 7),
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                  color: AdminColors.surface,
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: AdminColors.line)),
              child: Row(children: [
                AdminAvatar(_initialsOf(u), size: 34),
                const SizedBox(width: 11),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text((u['name'] as String?) ?? 'Player',
                          style: AdminText.strong()),
                      Text((u['email'] as String?) ?? '',
                          style: AdminText.mono(11.5, FontWeight.w500, AdminColors.inkFaint)),
                    ])),
                const Icon(Icons.add_circle_outline, size: 20, color: AdminColors.primary),
              ]),
            ),
          ),
    ]);
  }

  Widget _pickedCard() {
    final p = _picked!;
    final level = (p['level'] as num?)?.toDouble() ?? 0;
    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
          color: AdminColors.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AdminColors.success.withValues(alpha: 0.3))),
      child: Row(children: [
        AdminAvatar(_initialsOf(p), size: 40, color: AdminColors.green),
        const SizedBox(width: 12),
        Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Flexible(child: Text((p['name'] as String?) ?? 'Player', style: AdminText.strong())),
            const SizedBox(width: 6),
            const StatusBadge('active'),
          ]),
          Text('${p['email']} · ${RankingScale.divisionFor(level).name}',
              style: AdminText.mono(11.5, FontWeight.w500, AdminColors.inkFaint),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ])),
        AdminButton('Change',
            variant: AdminBtn.ghost,
            onPressed: () => setState(() {
                  _picked = null;
                  _results = [];
                  _search.clear();
                })),
      ]),
    );
  }

  Widget _permissionEditor(RoleDef def) {
    final custom = isCustom(_role, _access);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _label('Start from a role'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final r in RoleId.values)
          GestureDetector(
            onTap: () => setState(() {
              _role = r;
              _access = defaultAccessFor(r);
            }),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
              decoration: BoxDecoration(
                color: _role == r
                    ? kRoles[r]!.color.withValues(alpha: 0.1)
                    : AdminColors.surface,
                borderRadius: BorderRadius.circular(11),
                border: Border.all(
                    color: _role == r ? kRoles[r]!.color : AdminColors.line, width: 1.5),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(kRoles[r]!.icon,
                    size: 15, color: _role == r ? kRoles[r]!.color : AdminColors.ink),
                const SizedBox(width: 7),
                Text(kRoles[r]!.label,
                    style: AdminText.sans(13, FontWeight.w700,
                        _role == r ? kRoles[r]!.color : AdminColors.ink)),
              ]),
            ),
          ),
      ]),
      const SizedBox(height: 12),
      // live summary
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: (custom ? kCustomColor : def.color).withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: (custom ? kCustomColor : def.color).withValues(alpha: 0.28)),
        ),
        child: Row(children: [
          Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: custom ? kCustomColor : def.color,
                  borderRadius: BorderRadius.circular(9)),
              child: Icon(custom ? Icons.tune : def.icon, size: 17, color: Colors.white)),
          const SizedBox(width: 10),
          Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(custom ? 'Custom access · based on ${def.label}' : def.label,
                style: AdminText.strong()),
            Text('${_access.length} section${_access.length == 1 ? '' : 's'} enabled',
                style: AdminText.small()),
          ])),
          if (custom)
            AdminButton('Reset',
                variant: AdminBtn.ghost,
                onPressed: () => setState(() => _access = defaultAccessFor(_role))),
        ]),
      ),
      if (_role == RoleId.organizer) ...[
        const SizedBox(height: 14),
        _label('Region / venue scope (optional)'),
        _field(_scope, 'e.g. Cairo & New Cairo'),
      ],
      const SizedBox(height: 14),
      _label('Sections this person can open'),
      for (final entry in sectionsByGroup().entries) ...[
        Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 8),
            child: Text(entry.key.toUpperCase(), style: AdminText.kicker())),
        for (final g in entry.value) _grantRow(g, def.color),
      ],
    ]);
  }

  Widget _grantRow(Section g, Color color) {
    final on = _access.contains(g.id);
    return GestureDetector(
      onTap: () => setState(() => on ? _access.remove(g.id) : _access.add(g.id)),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: on ? color.withValues(alpha: 0.07) : AdminColors.surfaceAlt,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: on ? color.withValues(alpha: 0.22) : AdminColors.lineSoft),
        ),
        child: Row(children: [
          Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: on ? color.withValues(alpha: 0.15) : AdminColors.surface3,
                  borderRadius: BorderRadius.circular(9)),
              child: Icon(g.icon, size: 17, color: on ? color : AdminColors.inkFaint)),
          const SizedBox(width: 12),
          Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(g.label, style: AdminText.strong()),
            Text(g.desc, style: AdminText.small()),
          ])),
          IgnorePointer(
              child: Switch(value: on, onChanged: (_) {}, activeThumbColor: color)),
        ]),
      ),
    );
  }

  Widget _footer() => Container(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 22),
        decoration: const BoxDecoration(
            color: AdminColors.surfaceAlt,
            border: Border(top: BorderSide(color: AdminColors.lineSoft))),
        child: Row(children: [
          if (_isEdit && !_owner)
            AdminButton('Remove',
                icon: Icons.delete_outline,
                variant: AdminBtn.danger,
                onPressed: _busy ? null : _remove),
          const Spacer(),
          AdminButton('Cancel',
              variant: AdminBtn.ghost,
              onPressed: () => Navigator.pop(context, false)),
          const SizedBox(width: 8),
          AdminButton(_isEdit ? 'Save access' : 'Grant access',
              icon: _isEdit ? Icons.check : Icons.mail_outline,
              variant: AdminBtn.primary,
              onPressed: (_valid && !_busy) ? _save : null),
        ]),
      );

  // helpers
  String _initialsOf(Map<String, dynamic> u) {
    final base = ((u['name'] as String?)?.trim().isNotEmpty == true
        ? u['name'] as String
        : (u['email'] as String? ?? '?'));
    final parts =
        base.trim().split(RegExp(r'[\s@._]+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  Widget _label(String t) => Padding(
      padding: const EdgeInsets.only(bottom: 6, top: 4),
      child: Text(t, style: AdminText.strong(AdminColors.inkSoft)));

  Widget _field(TextEditingController c, String hint,
          {IconData? prefix, ValueChanged<String>? onChanged}) =>
      TextField(
        controller: c,
        onChanged: onChanged,
        style: AdminText.body(),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: AdminText.small(AdminColors.inkFaint),
          prefixIcon: prefix == null
              ? null
              : Icon(prefix, size: 18, color: AdminColors.inkFaint),
          filled: true,
          fillColor: AdminColors.surfaceAlt,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          border: OutlineInputBorder(
              borderRadius: AdminUI.fieldR,
              borderSide: const BorderSide(color: AdminColors.line)),
          enabledBorder: OutlineInputBorder(
              borderRadius: AdminUI.fieldR,
              borderSide: const BorderSide(color: AdminColors.line)),
          focusedBorder: OutlineInputBorder(
              borderRadius: AdminUI.fieldR,
              borderSide: const BorderSide(color: AdminColors.primary)),
        ),
      );
}
