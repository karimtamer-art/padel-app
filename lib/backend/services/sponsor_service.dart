import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Sponsorship level, biggest first. Mirrors the `sponsors_tier_chk` CHECK in
/// supabase/migration_player_app.sql — change both.
enum SponsorTier { title, gold, silver, partner }

SponsorTier sponsorTierFrom(String? s) => switch (s) {
      'title' => SponsorTier.title,
      'gold' => SponsorTier.gold,
      'silver' => SponsorTier.silver,
      _ => SponsorTier.partner,
    };

String sponsorTierToString(SponsorTier t) => switch (t) {
      SponsorTier.title => 'title',
      SponsorTier.gold => 'gold',
      SponsorTier.silver => 'silver',
      SponsorTier.partner => 'partner',
    };

/// How each tier is labelled on the player page.
String sponsorTierLabel(SponsorTier t) => switch (t) {
      SponsorTier.title => 'Title Partner',
      SponsorTier.gold => 'Gold Partner',
      SponsorTier.silver => 'Silver Partner',
      SponsorTier.partner => 'Partner',
    };

/// A brand or club backing the platform. Display only — no money lives here
/// (sponsorship payments are recorded in the `income` ledger).
class Sponsor {
  final String id;
  final String name;
  final String? tagline;
  final String? blurb;
  final String? logoUrl;
  final String? websiteUrl;
  final SponsorTier tier;
  final bool isActive;
  final int sortOrder;

  const Sponsor({
    required this.id,
    required this.name,
    this.tagline,
    this.blurb,
    this.logoUrl,
    this.websiteUrl,
    this.tier = SponsorTier.partner,
    this.isActive = true,
    this.sortOrder = 0,
  });

  factory Sponsor.fromRow(Map<String, dynamic> r) => Sponsor(
        id: r['id'] as String,
        name: (r['name'] as String?)?.trim().isNotEmpty == true
            ? (r['name'] as String).trim()
            : 'Partner',
        tagline: _clean(r['tagline']),
        blurb: _clean(r['blurb']),
        logoUrl: _clean(r['logo_url']),
        websiteUrl: _clean(r['website_url']),
        tier: sponsorTierFrom(r['tier'] as String?),
        isActive: r['is_active'] != false,
        sortOrder: (r['sort_order'] as num?)?.toInt() ?? 0,
      );

  static String? _clean(dynamic v) {
    final s = (v as String?)?.trim();
    return (s == null || s.isEmpty) ? null : s;
  }

  /// Fallback for a sponsor with no logo uploaded yet.
  String get initials {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first[0].toUpperCase();
    return (parts.first[0] + parts[1][0]).toUpperCase();
  }
}

class SponsorService {
  SponsorService._();
  static SupabaseClient get _db => Supabase.instance.client;

  /// Active sponsors for the player page, biggest tier first then by the
  /// admin's manual order.
  ///
  /// Returns empty rather than throwing on a database that hasn't had the
  /// 2026-08-06_sponsors delta run yet, so Home just hides the section instead
  /// of breaking (same shape as TournamentService's pre-migration fallback).
  ///
  /// Tier order is applied in Dart: it's an enum ranking, not something
  /// postgrest can sort on, and the list is small.
  static Future<List<Sponsor>> fetchActive({int? limit}) async {
    try {
      final res = await _db
          .from('sponsors')
          .select(
              'id, name, tagline, blurb, logo_url, website_url, tier, is_active, sort_order')
          .eq('is_active', true)
          .order('sort_order', ascending: true);
      final all = List<Map<String, dynamic>>.from(res as List)
          .map(Sponsor.fromRow)
          .toList()
        ..sort((a, b) {
          final byTier = a.tier.index.compareTo(b.tier.index);
          if (byTier != 0) return byTier;
          final byOrder = a.sortOrder.compareTo(b.sortOrder);
          return byOrder != 0 ? byOrder : a.name.compareTo(b.name);
        });
      return (limit != null && all.length > limit)
          ? all.sublist(0, limit)
          : all;
    } catch (e) {
      debugPrint('[SponsorService] fetchActive: $e');
      return [];
    }
  }
}
