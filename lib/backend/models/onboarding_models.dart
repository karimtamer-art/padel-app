import 'package:flutter/material.dart';

/// ── Onboarding enums ────────────────────────────────────────────────────────
/// `id` is the value persisted in Supabase (`profiles.*`); `label` is shown in
/// the UI. Keep the ids in sync with the CHECK constraints in
/// `supabase/migrations/0002_profiles_onboarding.sql`.

enum Gender {
  male('male', 'Male', Icons.male_rounded),
  female('female', 'Female', Icons.female_rounded);

  const Gender(this.id, this.label, this.icon);
  final String id;
  final String label;
  final IconData icon;

  static Gender? fromId(String? v) {
    for (final g in values) {
      if (g.id == v) return g;
    }
    return null;
  }
}

enum Hand {
  right('right', 'Right Handed', Icons.back_hand_outlined, true),
  left('left', 'Left Handed', Icons.back_hand_outlined, false);

  const Hand(this.id, this.label, this.icon, this.flipIcon);
  final String id;
  final String label;
  final IconData icon;
  final bool flipIcon;

  static Hand? fromId(String? v) {
    for (final h in values) {
      if (h.id == v) return h;
    }
    return null;
  }
}

/// Which half of the court a player likes. `both` is a real answer in padel —
/// plenty of players are happy either side — and it used to be silently
/// rewritten to `right` because profiles_side_chk only permitted left/right.
/// Widening that CHECK is in changes/2026-08-10_court_side_both.sql; the ids
/// here and that constraint must stay in step.
// Declaration order IS the on-screen order — the onboarding row iterates
// CourtSidePref.values. Both sits in the middle because it is the answer
// between the two extremes, not an afterthought tacked on the end.
enum CourtSidePref {
  left('left', 'Left Side'),
  both('both', 'Both Sides'),
  right('right', 'Right Side');

  const CourtSidePref(this.id, this.label);
  final String id;
  final String label;

  static CourtSidePref? fromId(String? v) {
    for (final s in values) {
      if (s.id == v) return s;
    }
    return null;
  }
}

/// Immutable snapshot of the five onboarding answers. Round-trips to/from the
/// `profiles` row and knows whether onboarding is complete.
class OnboardingProfile {
  final DateTime? dateOfBirth;
  final Gender? gender;
  final Hand? hand;
  final CourtSidePref? side;
  final String? phone;
  final bool isAdmin;
  final String? adminRole; // super_admin | organizer | support | analyst | null
  final bool mustChangePassword; // provisioned organizer on a temp password

  const OnboardingProfile({
    this.dateOfBirth,
    this.gender,
    this.hand,
    this.side,
    this.phone,
    this.isAdmin = false,
    this.adminRole,
    this.mustChangePassword = false,
  });

  /// Any console access — a super admin (is_admin) or a granted staff role.
  bool get isStaff => isAdmin || adminRole != null;

  /// Mirrors the server's generated `onboarding_completed` column.
  bool get isComplete =>
      dateOfBirth != null &&
      gender != null &&
      hand != null &&
      side != null &&
      OnboardingValidation.phone(phone) == null;

  OnboardingProfile copyWith({
    DateTime? dateOfBirth,
    Gender? gender,
    Hand? hand,
    CourtSidePref? side,
    String? phone,
    bool? isAdmin,
    String? adminRole,
    bool? mustChangePassword,
  }) =>
      OnboardingProfile(
        dateOfBirth: dateOfBirth ?? this.dateOfBirth,
        gender: gender ?? this.gender,
        hand: hand ?? this.hand,
        side: side ?? this.side,
        phone: phone ?? this.phone,
        isAdmin: isAdmin ?? this.isAdmin,
        adminRole: adminRole ?? this.adminRole,
        mustChangePassword: mustChangePassword ?? this.mustChangePassword,
      );

  factory OnboardingProfile.fromJson(Map<String, dynamic> j) {
    DateTime? dob;
    final raw = j['date_of_birth'];
    if (raw is String && raw.isNotEmpty) dob = DateTime.tryParse(raw);
    if (raw is DateTime) dob = raw;
    return OnboardingProfile(
      dateOfBirth: dob,
      gender: Gender.fromId(j['gender'] as String?),
      hand: Hand.fromId(j['preferred_hand'] as String?),
      side: CourtSidePref.fromId(j['preferred_court_side'] as String?),
      phone: j['phone'] as String?,
      isAdmin: j['is_admin'] as bool? ?? false,
      adminRole: j['admin_role'] as String?,
      mustChangePassword: j['must_change_password'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toUpsert(String userId, {String? name}) => {
        'id': userId,
        'name': (name != null && name.trim().isNotEmpty) ? name.trim() : 'Player',
        'date_of_birth': dateOfBirth == null ? null : _ymd(dateOfBirth!),
        'gender': gender?.id,
        'preferred_hand': hand?.id,
        'preferred_court_side': side?.id,
        'phone': phone,
      };

  static String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// Validation rules. Each returns `null` when valid, or an error message.
class OnboardingValidation {
  OnboardingValidation._();

  static const int minAge = 13;
  static const int maxAge = 100;

  static int ageOn(DateTime dob, [DateTime? on]) {
    final now = on ?? DateTime.now();
    var age = now.year - dob.year;
    if (now.month < dob.month ||
        (now.month == dob.month && now.day < dob.day)) {
      age--;
    }
    return age;
  }

  static String? dateOfBirth(DateTime? d) {
    if (d == null) return 'Select your date of birth';
    if (d.isAfter(DateTime.now())) return 'Date of birth can\'t be in the future';
    final age = ageOn(d);
    if (age < minAge) return 'You must be at least $minAge years old to play';
    if (age > maxAge) return 'Please enter a valid date of birth';
    return null;
  }

  static String? gender(Gender? g) => g == null ? 'Select your gender' : null;
  static String? hand(Hand? h) => h == null ? 'Select your preferred hand' : null;
  static String? side(CourtSidePref? s) =>
      s == null ? 'Select your preferred court side' : null;

  static String? phone(String? p) {
    if (p == null || p.trim().isEmpty) return 'Enter your phone number';
    final digits = p.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < 10 || digits.length > 12) {
      return 'Enter a valid mobile number (e.g. 01001234567)';
    }
    return null;
  }

  /// All-fields gate used before the final submit.
  static bool isValid(OnboardingProfile p) =>
      dateOfBirth(p.dateOfBirth) == null &&
      gender(p.gender) == null &&
      hand(p.hand) == null &&
      side(p.side) == null &&
      phone(p.phone) == null;
}
