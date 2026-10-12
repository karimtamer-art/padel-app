import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A place a player can go to have their level assessed in person.
/// Display only — `priceEgp` is paid at the center, nothing is charged in-app.
class AssessmentCenter {
  final String id;
  final String name;
  final String? area;
  final String? address;
  final String? mapUrl;
  final String? phone;
  final String? description;
  final num? priceEgp;
  final int sortOrder;

  const AssessmentCenter({
    required this.id,
    required this.name,
    this.area,
    this.address,
    this.mapUrl,
    this.phone,
    this.description,
    this.priceEgp,
    this.sortOrder = 0,
  });

  factory AssessmentCenter.fromRow(Map<String, dynamic> r) => AssessmentCenter(
        id: r['id'] as String,
        name: _clean(r['name']) ?? 'Assessment center',
        area: _clean(r['area']),
        address: _clean(r['address']),
        mapUrl: _clean(r['map_url']),
        phone: _clean(r['phone']),
        description: _clean(r['description']),
        priceEgp: r['price_egp'] as num?,
        sortOrder: (r['sort_order'] as num?)?.toInt() ?? 0,
      );

  static String? _clean(dynamic v) {
    final s = (v as String?)?.trim();
    return (s == null || s.isEmpty) ? null : s;
  }
}

/// One bookable seat. RLS only ever returns a player OPEN future slots plus
/// their own booking, so [isMine] is the only "taken" state a player sees.
class AssessmentSlot {
  final String id;
  final String centerId;
  final DateTime startsAt; // local time
  final int durationMin;
  final bool isMine;

  const AssessmentSlot({
    required this.id,
    required this.centerId,
    required this.startsAt,
    required this.durationMin,
    required this.isMine,
  });

  DateTime get endsAt => startsAt.add(Duration(minutes: durationMin));
}

/// Everything the player screen needs in one load.
class AssessmentOverview {
  final List<AssessmentCenter> centers; // live ones, display order
  final List<AssessmentSlot> openSlots; // future, unbooked, ascending
  final AssessmentSlot? myBooking; // upcoming only
  /// Every center RLS returned, including a hidden one I still hold a booking
  /// at — so my booking card can always name its venue.
  final List<AssessmentCenter> _all;
  const AssessmentOverview(this.centers, this.openSlots, this.myBooking,
      [this._all = const []]);

  static const empty = AssessmentOverview([], [], null);

  AssessmentCenter? centerOf(String id) {
    for (final c in _all) {
      if (c.id == id) return c;
    }
    return null;
  }

  List<AssessmentSlot> slotsFor(String centerId) =>
      openSlots.where((s) => s.centerId == centerId).toList();
}

class AssessmentService {
  AssessmentService._();
  static SupabaseClient get _db => Supabase.instance.client;

  /// Active centers, their open future slots, and the caller's upcoming
  /// booking. Returns [AssessmentOverview.empty] on a database without the
  /// 2026-10-12_assessment_centers delta, so Home just hides the entry.
  static Future<AssessmentOverview> overview() async {
    final uid = _db.auth.currentUser?.id;
    try {
      final results = await Future.wait([
        _db
            .from('assessment_centers')
            .select('id, name, area, address, map_url, phone, description, '
                'price_egp, sort_order, is_active')
            .order('sort_order', ascending: true)
            .order('name', ascending: true),
        _db
            .from('assessment_slots')
            .select('id, center_id, starts_at, duration_min, booked_by')
            .gt('starts_at', DateTime.now().toUtc().toIso8601String())
            .order('starts_at', ascending: true),
      ]);
      final centerRows = List<Map<String, dynamic>>.from(results[0] as List);
      final slotRows = List<Map<String, dynamic>>.from(results[1] as List);

      AssessmentSlot? mine;
      final open = <AssessmentSlot>[];
      for (final r in slotRows) {
        final bookedBy = r['booked_by'] as String?;
        final slot = AssessmentSlot(
          id: r['id'] as String,
          centerId: r['center_id'] as String,
          startsAt: DateTime.parse(r['starts_at'] as String).toLocal(),
          durationMin: (r['duration_min'] as num?)?.toInt() ?? 60,
          isMine: bookedBy != null && bookedBy == uid,
        );
        if (slot.isMine) {
          mine ??= slot;
        } else if (bookedBy == null) {
          open.add(slot);
        }
      }

      // A hidden center can still come back via RLS (I hold a booking there,
      // or I'm staff) — keep it for naming my booking, never list it.
      final all = centerRows.map(AssessmentCenter.fromRow).toList();
      final live = {
        for (final r in centerRows)
          if (r['is_active'] != false) r['id'] as String
      };
      return AssessmentOverview(
        all.where((c) => live.contains(c.id)).toList(),
        open.where((s) => live.contains(s.centerId)).toList(),
        mine,
        all,
      );
    } catch (e) {
      debugPrint('[AssessmentService] overview: $e');
      return AssessmentOverview.empty;
    }
  }

  /// Books [slotId]. Returns null on success, or the server's sentence
  /// ("that slot was just taken", "you already have one booked").
  static Future<String?> book(String slotId) async {
    try {
      await _db.rpc('book_assessment_slot', params: {'p_slot': slotId});
      return null;
    } on PostgrestException catch (e) {
      debugPrint('[AssessmentService] book: ${e.message}');
      return e.message;
    } catch (e) {
      debugPrint('[AssessmentService] book: $e');
      return "Couldn't book that slot. Check your connection and try again.";
    }
  }

  /// Cancels the caller's own booking, which reopens the slot to everyone.
  static Future<String?> cancel(String slotId) async {
    try {
      await _db.rpc('cancel_assessment_booking', params: {'p_slot': slotId});
      return null;
    } on PostgrestException catch (e) {
      debugPrint('[AssessmentService] cancel: ${e.message}');
      return e.message;
    } catch (e) {
      debugPrint('[AssessmentService] cancel: $e');
      return "Couldn't cancel. Check your connection and try again.";
    }
  }
}
