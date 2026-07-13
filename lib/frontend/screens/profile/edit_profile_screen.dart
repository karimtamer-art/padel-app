import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:padel_clay/frontend/theme/app_colors.dart';
import 'package:padel_clay/frontend/theme/app_text.dart';
import 'package:padel_clay/frontend/theme/app_spacing.dart';
import 'package:padel_clay/frontend/widgets/common.dart';
import 'package:padel_clay/frontend/widgets/screen_bar.dart';
import 'package:padel_clay/backend/services/profile_service.dart';
import '../auth/auth_widgets.dart';

class EditProfileScreen extends StatefulWidget {
  /// Pre-loaded profile from ProfileScreen — avoids an extra round-trip.
  final Map<String, dynamic>? profile;
  const EditProfileScreen({super.key, this.profile});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  bool _loading = true;
  bool _saving = false;

  Map<String, dynamic> _original = {};

  late final TextEditingController _nameCtrl;
  late final TextEditingController _usernameCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _bioCtrl;
  late final TextEditingController _cityCtrl;
  late final TextEditingController _dobCtrl;

  String _hand = 'right';
  String _side = 'both';
  String _gender = '';
  DateTime? _dob;

  @override
  void initState() {
    super.initState();
    _nameCtrl  = TextEditingController();
    _usernameCtrl = TextEditingController();
    _emailCtrl = TextEditingController();
    _phoneCtrl = TextEditingController();
    _bioCtrl   = TextEditingController();
    _cityCtrl  = TextEditingController();
    _dobCtrl   = TextEditingController();

    if (widget.profile != null) {
      _fill(widget.profile!);
      _loading = false;
    } else {
      _loadFromSupabase();
    }
  }

  @override
  void dispose() {
    for (final c in [_nameCtrl, _usernameCtrl, _emailCtrl, _phoneCtrl, _bioCtrl, _cityCtrl, _dobCtrl]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadFromSupabase() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) { setState(() => _loading = false); return; }
    final data = await ProfileService.getProfile(uid);
    if (!mounted) return;
    if (data != null) _fill(data);
    setState(() => _loading = false);
  }

  void _fill(Map<String, dynamic> data) {
    _original = Map.from(data);
    _nameCtrl.text  = data['name']  as String? ?? '';
    _usernameCtrl.text = data['username'] as String? ?? '';
    _phoneCtrl.text = data['phone'] as String? ?? '';
    _bioCtrl.text   = data['bio']   as String? ?? '';
    _cityCtrl.text  = data['city']  as String? ?? '';
    _hand   = data['preferred_hand']       as String? ?? 'right';
    _side   = data['preferred_court_side'] as String? ?? 'both';
    _gender = data['gender']               as String? ?? '';

    final dobStr = data['date_of_birth'] as String?;
    if (dobStr != null) {
      _dob = DateTime.tryParse(dobStr);
      if (_dob != null) _dobCtrl.text = _fmtDate(_dob!);
    }

    _emailCtrl.text = Supabase.instance.client.auth.currentUser?.email ?? '';
  }

  Future<void> _pickDob() async {
    DateTime temp = _dob ?? DateTime(DateTime.now().year - 24);
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (_) => Container(
        height: 300,
        decoration: const BoxDecoration(
          color: AppColors.bg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          top: false,
          child: Column(children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 12),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppColors.lineSoft)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Date of Birth',
                      style: AppText.bodyStrong(AppColors.ink).copyWith(fontSize: 14)),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () {
                      setState(() { _dob = temp; _dobCtrl.text = _fmtDate(temp); });
                      Navigator.pop(context);
                    },
                    child: Text('Done',
                        style: AppText.bodyStrong(AppColors.primary).copyWith(fontSize: 14)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: CupertinoDatePicker(
                mode: CupertinoDatePickerMode.date,
                initialDateTime: _dob ?? DateTime(DateTime.now().year - 24),
                maximumDate: DateTime.now(),
                minimumDate: DateTime(1940),
                onDateTimeChanged: (d) => temp = d,
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _save() async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;

    final name = _nameCtrl.text.trim();
    if (name.isEmpty) { _snack('Please enter your name.', error: true); return; }

    final username = _usernameCtrl.text.trim().toLowerCase();
    if (!_usernameRe.hasMatch(username)) {
      _snack('Username must be 3–20 characters: letters, numbers, or _.', error: true);
      return;
    }
    // only spend a round-trip if the handle actually changed
    if (username != (_original['username'] as String?)?.toLowerCase()) {
      setState(() => _saving = true);
      final free = await ProfileService.isUsernameAvailable(username);
      if (!mounted) return;
      if (!free) {
        setState(() => _saving = false);
        _snack('That username is already taken. Try another.', error: true);
        return;
      }
    }

    setState(() => _saving = true);

    final updates = <String, dynamic>{
      'name':       name,
      'username':   username,
      'phone':      _phoneCtrl.text.trim().isEmpty ? null : _phoneCtrl.text.trim(),
      'bio':        _bioCtrl.text.trim(),
      'city':       _cityCtrl.text.trim().isEmpty ? null : _cityCtrl.text.trim(),
      'preferred_hand':       _hand,
      'preferred_court_side': _side,
      'gender':               _gender.isEmpty ? null : _gender,
      'date_of_birth':        _dob?.toIso8601String().split('T').first,
    };

    final err = await ProfileService.updateProfile(uid, updates);
    if (!mounted) return;
    setState(() => _saving = false);

    if (err != null) {
      _snack(err, error: true);
    } else {
      Navigator.of(context).pop({..._original, ...updates});
    }
  }

  void _snack(String msg, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? const Color(0xFFB00020) : AppColors.ink,
      behavior: SnackBarBehavior.floating,
    ));
  }

  String get _initials {
    final parts = _nameCtrl.text.trim().split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    if (parts.isNotEmpty) return parts[0][0].toUpperCase();
    return 'P';
  }

  static final _usernameRe = RegExp(r'^[a-z0-9_]{3,20}$');

  static String _fmtDate(DateTime d) {
    const m = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day} ${m[d.month - 1]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: ScreenBar(
        title: 'Edit Profile',
        onBack: () => Navigator.pop(context),
        actions: [
          _saving
              ? const Padding(
                  padding: EdgeInsets.only(right: 16),
                  child: SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                  ),
                )
              : GestureDetector(
                  onTap: _save,
                  child: Text('Save',
                      style: AppText.bodyStrong(AppColors.primary).copyWith(fontSize: 15)),
                ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
          : ListView(
              padding: EdgeInsets.fromLTRB(
                  20, 20, 20, MediaQuery.of(context).padding.bottom + 24),
              children: [
                // ── Avatar ──
                Center(
                  child: SizedBox(
                    width: 104, height: 104,
                    child: Stack(clipBehavior: Clip.none, children: [
                      AppAvatar(_initials, size: 104, ring: 2.5),
                      Positioned(
                        right: 0, bottom: 0,
                        child: Container(
                          width: 34, height: 34,
                          decoration: BoxDecoration(
                            color: AppColors.primary,
                            shape: BoxShape.circle,
                            border: Border.all(color: AppColors.bg, width: 3),
                          ),
                          child: const Icon(Icons.photo_camera_outlined,
                              size: 16, color: AppColors.primaryInk),
                        ),
                      ),
                    ]),
                  ),
                ),
                const SizedBox(height: 24),

                // ── Personal ──
                AuthField(label: 'Full Name', icon: Icons.person_outline_rounded,
                    controller: _nameCtrl, capitalization: TextCapitalization.words),
                const SizedBox(height: 16),
                AuthField(label: 'Username', icon: Icons.alternate_email_rounded,
                    controller: _usernameCtrl,
                    helper: 'How teammates find you. 3–20 chars: letters, numbers, _'),
                const SizedBox(height: 16),
                AuthField(label: 'Email', icon: Icons.mail_outline_rounded,
                    controller: _emailCtrl, keyboard: TextInputType.emailAddress,
                    locked: true,
                    helper: 'Your sign-in email — contact support to change it.'),
                const SizedBox(height: 16),
                AuthField(label: 'Phone Number', icon: Icons.phone_outlined,
                    controller: _phoneCtrl, keyboard: TextInputType.phone),
                const SizedBox(height: 16),
                AuthField(label: 'City / Preferred Club', icon: Icons.place_outlined,
                    controller: _cityCtrl, capitalization: TextCapitalization.words),
                const SizedBox(height: 16),
                AuthField(
                  label: 'Date of Birth',
                  icon: Icons.calendar_today_outlined,
                  hint: 'Select date',
                  controller: _dobCtrl,
                  readOnly: true,
                  onTap: _pickDob,
                  trailing: const Icon(Icons.expand_more_rounded, size: 20, color: AppColors.inkFaint),
                ),
                const SizedBox(height: 16),
                _bioInput(),
                const SizedBox(height: 22),

                // ── Player prefs ──
                SegmentedField(
                  label: 'Gender', columns: 3,
                  value: _gender,
                  onChanged: (v) => setState(() => _gender = v),
                  options: const [
                    SegOption('male', 'Male'),
                    SegOption('female', 'Female'),
                    SegOption('other', 'Other'),
                  ],
                ),
                const SizedBox(height: 22),
                SegmentedField(
                  label: 'Preferred Playing Hand', columns: 2,
                  value: _hand,
                  onChanged: (v) => setState(() => _hand = v),
                  options: const [
                    SegOption('right', 'Right Handed',
                        icon: Icons.back_hand_outlined, flipIcon: true),
                    SegOption('left', 'Left Handed', icon: Icons.back_hand_outlined),
                  ],
                ),
                const SizedBox(height: 22),
                SegmentedField(
                  label: 'Preferred Court Side', columns: 3,
                  value: _side,
                  onChanged: (v) => setState(() => _side = v),
                  options: const [
                    SegOption('left', 'Left', side: CourtSide.left),
                    SegOption('right', 'Right', side: CourtSide.right),
                    SegOption('both', 'Both', side: CourtSide.both),
                  ],
                ),
                const SizedBox(height: 28),

                AppButton('Save Changes', full: true, height: 54,
                    onPressed: _saving ? null : _save),
                const SizedBox(height: 12),
                AppButton('Cancel', full: true, height: 50,
                    variant: AppBtnVariant.ghost,
                    onPressed: () => Navigator.pop(context)),
              ],
            ),
    );
  }

  Widget _bioInput() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 7, left: 1),
          child: Text('Short Bio',
              style: AppText.bodyStrong(AppColors.inkSoft).copyWith(fontSize: 12.5)),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: AppColors.field,
            borderRadius: AppRadius.btnR,
            border: Border.all(color: AppColors.line, width: 1.5),
          ),
          child: TextField(
            controller: _bioCtrl,
            maxLines: 3, maxLength: 140,
            cursorColor: AppColors.primary,
            style: AppText.body().copyWith(fontSize: 15, height: 1.5),
            decoration: const InputDecoration(
              isCollapsed: true, border: InputBorder.none, counterText: ''),
          ),
        ),
      ]);
}
