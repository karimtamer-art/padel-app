import '../services/region_service.dart' show money;

/// The reasons an organiser can pick. Mirrors reject_tournament_entry in SQL.
const kRejectReasons = [
  "Amount doesn't match",
  'Transfer not received',
  'Screenshot unclear',
  'Other',
];

/// Where a player's paid entry stands. Only [confirmed] may show a tick or
/// "You're in": everything before it is a spot being held.
enum PaymentPhase { free, underReview, split, confirmed, actionNeeded, released }

enum ShareStatus { verified, beingChecked, notPaid }

class PaymentShare {
  final String name;
  final bool isMe;
  final int amount;
  final ShareStatus status;
  const PaymentShare(this.name, this.isMe, this.amount, this.status);
}

/// One player's view of one entry. Pure, so every state has a test.
class EntryPayment {
  final PaymentPhase phase;
  final bool isSplit;

  /// What this player's transfer covers: the pair, or their share.
  final int amount;

  /// The whole pair's entry, for the confirmed card.
  final int total;
  final String coverLabel;
  final List<PaymentShare> shares;
  final DateTime? sentAt;
  final String? sender;
  final DateTime? holdUntil;
  final String? reason;
  final bool resubmitted;

  /// Added by the organiser, so no payment was ever asked for.
  final bool byOrganiser;
  final String? otherFirstName;
  final DateTime now;

  const EntryPayment._({
    required this.phase,
    required this.isSplit,
    required this.amount,
    required this.total,
    required this.coverLabel,
    required this.shares,
    required this.now,
    this.sentAt,
    this.sender,
    this.holdUntil,
    this.reason,
    this.resubmitted = false,
    this.byOrganiser = false,
    this.otherFirstName,
  });

  /// [entry] is a tournament_entries row. [rejection] is its row from
  /// tournament_entry_rejections, which only the pair and organiser can read.
  /// Null when this entry has no payment state to show: withdrawn by choice,
  /// cancelled, or not this player's.
  static EntryPayment? of(
    Map<String, dynamic>? entry, {
    required String? uid,
    required int fee,
    Map<String, dynamic>? rejection,
    DateTime? now,
  }) {
    if (entry == null || uid == null) return null;
    final isRegistrant = entry['player_id'] == uid;
    final isPartner = entry['partner_id'] == uid;
    if (!isRegistrant && !isPartner) return null;

    final at = now ?? DateTime.now();
    final status = entry['status'] as String? ?? '';
    final split = entry['fee_mode'] == 'split';
    final holdUntil = _time(entry['hold_until']);

    final phase = switch (status) {
      'paid' || 'confirmed' => PaymentPhase.confirmed,
      'registered' => fee > 0 ? PaymentPhase.confirmed : PaymentPhase.free,
      'pending' => split ? PaymentPhase.split : PaymentPhase.underReview,
      // A lapsed hold reads as released even before the server has got to it.
      'rejected' => holdUntil != null && !holdUntil.isAfter(at)
          ? PaymentPhase.released
          : PaymentPhase.actionNeeded,
      'withdrawn' when rejection != null => PaymentPhase.released,
      _ => null,
    };
    if (phase == null) return null;

    final playerName = (entry['player_name'] as String?)?.trim();
    final partnerName = (entry['partner_name'] as String?)?.trim();
    final myAmount = split
        ? fee
        : (entry['paid_amount'] as num?)?.toInt() ?? fee * 2;
    final total = split ? fee * 2 : myAmount;

    ShareStatus share(bool paid, String? sender) => paid
        ? ShareStatus.verified
        : (sender ?? '').isNotEmpty
            ? ShareStatus.beingChecked
            : ShareStatus.notPaid;

    final shares = !split
        ? const <PaymentShare>[]
        : [
            PaymentShare(
                playerName ?? 'Player',
                isRegistrant,
                fee,
                // The registrant always pays when registering, so even without
                // reading their handle an unverified share is being checked.
                entry['payer_paid'] == true
                    ? ShareStatus.verified
                    : ShareStatus.beingChecked),
            PaymentShare(
                partnerName ?? 'Partner',
                isPartner,
                fee,
                share(entry['partner_paid'] == true,
                    entry['partner_instapay_sender'] as String?)),
          ];

    final senderField = split && isPartner
        ? entry['partner_instapay_sender']
        : entry['instapay_sender'];
    final other = isRegistrant ? partnerName : playerName;

    return EntryPayment._(
      phase: phase,
      isSplit: split,
      amount: myAmount,
      total: total,
      coverLabel: split ? 'your share' : 'both of you',
      shares: shares,
      now: at,
      sentAt: _time(entry['proof_resubmitted_at']) ?? _time(entry['registered_at']),
      sender: _username(senderField as String?),
      holdUntil: phase == PaymentPhase.actionNeeded ? holdUntil : null,
      reason: _reasonText(rejection),
      resubmitted: entry['proof_resubmitted_at'] != null,
      byOrganiser: status == 'registered' && fee > 0,
      otherFirstName: (other == null || other.isEmpty) ? null : other.split(' ').first,
    );
  }

  /// This player's entry among a tournament's rows, ignoring withdrawn ones.
  static EntryPayment? forTournament(List<dynamic>? entries,
      {required String? uid, required int fee, DateTime? now}) {
    if (entries == null || uid == null) return null;
    for (final e in entries) {
      final m = Map<String, dynamic>.from(e as Map);
      if (m['status'] == 'withdrawn') continue;
      if (m['player_id'] == uid || m['partner_id'] == uid) {
        return of(m, uid: uid, fee: fee, now: now);
      }
    }
    return null;
  }

  static DateTime? _time(Object? v) =>
      v is String ? DateTime.tryParse(v)?.toLocal() : null;

  static String? _username(String? handle) {
    final h = handle?.trim();
    if (h == null || h.isEmpty) return null;
    final at = h.indexOf('@');
    return at > 0 ? h.substring(0, at) : h;
  }

  static String? _reasonText(Map<String, dynamic>? r) {
    if (r == null) return null;
    final reason = (r['reason'] as String?)?.trim();
    final note = (r['note'] as String?)?.trim();
    final hasNote = note != null && note.isNotEmpty;
    if (reason == null || reason == 'Other') return hasNote ? note : reason;
    return hasNote ? '$reason. $note' : reason;
  }

  // ── Derived ───────────────────────────────────────────────────────────────

  PaymentShare? get _mine {
    for (final s in shares) {
      if (s.isMe) return s;
    }
    return null;
  }

  PaymentShare? get _others {
    for (final s in shares) {
      if (!s.isMe) return s;
    }
    return null;
  }

  int get verifiedShares =>
      shares.where((s) => s.status == ShareStatus.verified).length;

  bool get _myShareVerified => _mine?.status == ShareStatus.verified;

  /// Only a player whose own money isn't verified has anything to send.
  bool get canSendProof =>
      (phase == PaymentPhase.underReview ||
          phase == PaymentPhase.split ||
          phase == PaymentPhase.actionNeeded) &&
      !_myShareVerified;

  /// True only once an organiser has verified it, or it never needed verifying.
  bool get isSettled =>
      phase == PaymentPhase.confirmed || phase == PaymentPhase.free;

  /// "EGP 1,000 · both of you".
  String get amountLine => '${money(amount)} · $coverLabel';

  /// "2 h ago".
  String? get sentAgo {
    final s = sentAt;
    if (s == null) return null;
    final d = now.difference(s);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  /// "EGP 1,000 · sent 2 h ago from nour.salem".
  String get reviewLine {
    final parts = [
      if (sentAgo != null) 'sent $sentAgo',
      if (sender != null) 'from $sender',
    ];
    return parts.isEmpty ? amountLine : '${money(amount)} · ${parts.join(' ')}';
  }

  String get barTitleWaiting => "Waiting for ${_others?.name.split(' ').first ?? 'your partner'}'s share";

  /// First line of the detail screen's bottom bar. [pair] is "You & Omar".
  String barTitle(String pair) => switch (phase) {
        PaymentPhase.free || PaymentPhase.confirmed => "You're in · $pair",
        PaymentPhase.actionNeeded => 'Action needed',
        PaymentPhase.released => 'Spot released',
        PaymentPhase.underReview => 'Spot held · $pair',
        PaymentPhase.split => _myShareVerified && _others?.status == ShareStatus.notPaid
            ? barTitleWaiting
            : 'Spot held · $pair',
      };

  /// Second line of the bottom bar.
  String get barSub => switch (phase) {
        PaymentPhase.free => 'Free entry',
        PaymentPhase.confirmed =>
          byOrganiser ? 'Registered by the organiser' : 'Paid · confirmed',
        PaymentPhase.actionNeeded || PaymentPhase.released => 'Payment not verified',
        PaymentPhase.underReview => 'Payment under review',
        PaymentPhase.split => _splitSub,
      };

  String get _splitSub {
    final mine = _mine?.status;
    final other = _others?.status;
    final me = money(amount);
    final who = _others?.name.split(' ').first ?? 'Your partner';
    if (mine == ShareStatus.notPaid) return "Your $me share isn't paid yet";
    if (mine == ShareStatus.verified) {
      return other == ShareStatus.beingChecked
          ? "$who's share is being checked"
          : 'Your $me is verified';
    }
    return other == ShareStatus.beingChecked
        ? 'Both shares are being checked'
        : 'Your $me is being checked';
  }

  /// The chip on list and Home cards. Null when there's nothing to say.
  String? get chipLabel => switch (phase) {
        PaymentPhase.free => 'REGISTERED',
        PaymentPhase.confirmed => 'CONFIRMED',
        PaymentPhase.actionNeeded => 'ACTION NEEDED',
        PaymentPhase.underReview || PaymentPhase.split => 'PAYMENT PENDING',
        PaymentPhase.released => null,
      };

  /// The footer line on list cards. [pair] is "You & Omar".
  String cardLine(String pair) => switch (phase) {
        PaymentPhase.free || PaymentPhase.confirmed => "You're in · $pair",
        PaymentPhase.actionNeeded || PaymentPhase.released => 'Payment not verified',
        PaymentPhase.underReview =>
          sentAgo == null ? 'Under review' : 'Under review · sent $sentAgo',
        PaymentPhase.split => _splitSub,
      };

  String get cardLink => phase == PaymentPhase.actionNeeded
      ? 'Fix'
      : (phase == PaymentPhase.split && _mine?.status == ShareStatus.notPaid)
          ? 'Pay'
          : 'View';
}
