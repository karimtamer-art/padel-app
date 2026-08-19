import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/onboarding_models.dart';
import '../models/ranking_scale.dart';
import '../models/rating_engine_v3f5.dart';
import '../models/mock_data.dart';

/// One completed match in the Recent Form strip / recap.
class FormMatch {
  final bool won;
  /// Opponents, first names joined — "Adel Mansour & Amr Gamal".
  final String opp;
  /// Sets from MY perspective — "6-3, 6-4".
  final String score;
  /// "May 25"
  final String date;
  final String type; // Competitive | Casual
  /// Signed rating change from `ranking_history`; null when nothing settled
  /// (casual, or a pre-v2 row).
  final double? delta;
  const FormMatch(
      this.won, this.opp, this.score, this.date, this.type, this.delta);
}

/// Reads/writes the onboarding fields on the `profiles` table.
///
/// Pass an instance to [AuthGate]. The static methods (getProfile,
/// updateProfile, ensureProfile) are kept for existing screens.
class ProfileService {
  ProfileService([SupabaseClient? client])
      : _sb = client ?? Supabase.instance.client;

  final SupabaseClient _sb;

  /// The signed-in user's photo, for chrome that shows it without owning a
  /// fetch — the Home header avatar in particular.
  ///
  /// A notifier rather than a constructor argument because the header sits four
  /// widgets above anything that knows about profiles (AuthGate → RootScaffold
  /// → HomeScreen → ScreenBar), and Home is kept alive: plumbed down, the photo
  /// would go stale the moment someone changed it from the You tab and stay
  /// stale until Home was rebuilt. [uploadAvatar] writes it too, so the new
  /// picture appears the instant it uploads.
  static final ValueNotifier<String?> currentAvatar = ValueNotifier<String?>(null);

  /// The signed-in player's display name, for exactly the same reason as
  /// [currentAvatar]: it is plumbed AuthGate → RootScaffold → ProfileScreen, so
  /// editing it left every one of those showing the old value until the app was
  /// restarted. That read as "Save didn't work" — the write had in fact
  /// succeeded. Written by whoever reads or changes the name.
  static final ValueNotifier<String?> currentName = ValueNotifier<String?>(null);

  // avatar_url rides along on the startup fetch below so the header has a photo
  // from the first frame without a second round trip. fromJson ignores it.
  // name/username ride along so AuthGate can use the STORED name rather than
  // auth metadata, and so onboarding can tell whether it still has to ask.
  static const _onbCols =
      'name, username, date_of_birth, gender, preferred_hand, '
      'preferred_court_side, phone, is_admin, avatar_url';

  /// Current user's profile, or `null` if the row doesn't exist yet.
  /// Selects the RBAC `admin_role` too, falling back for pre-migration DBs that
  /// don't have that column yet (so sign-in never breaks).
  Future<OnboardingProfile?> fetch(String userId) async {
    Map<String, dynamic>? row;
    try {
      row = await _sb
          .from('profiles')
          .select('$_onbCols, admin_role, must_change_password')
          .eq('id', userId)
          .maybeSingle();
    } catch (_) {
      row = await _sb
          .from('profiles')
          .select(_onbCols)
          .eq('id', userId)
          .maybeSingle();
    }
    if (row == null) return null;
    final url = (row['avatar_url'] as String?)?.trim();
    currentAvatar.value = (url == null || url.isEmpty) ? null : url;
    final stored = row['name'] as String?;
    if (OnboardingProfile.isUsableName(stored)) currentName.value = stored!.trim();
    return OnboardingProfile.fromJson(row);
  }

  /// Persists the four onboarding answers. Upsert is safe even if the
  /// signup trigger hasn't created the row yet.
  Future<void> saveOnboarding(String userId, OnboardingProfile profile, {String? name}) async {
    final payload = profile.toUpsert(userId, fallbackName: name);
    await _sb.from('profiles').upsert(payload, onConflict: 'id');
    final saved = payload['name'] as String?;
    if (saved != null) currentName.value = saved;
  }

  // ── Static interface — legacy screens ────────────────────────────────────

  static SupabaseClient get _db => Supabase.instance.client;

  static const _profileCols =
      'id, name, username, phone, bio, date_of_birth, gender, preferred_hand, '
      'preferred_court_side, city, avatar_url, created_at, '
      // ranking state moved to player_ratings (2026-08-15); flattenRatings
      // folds it back up so callers keep reading row['rating'] etc.
      'player_ratings(rating, tier, level, placement_played)';

  /// True when [username] is free (and validly formatted). Backed by the
  /// `username_available` RPC so it works pre-auth during signup. On a network
  /// error returns true — the unique index is the real guard on write.
  static Future<bool> isUsernameAvailable(String username) async {
    try {
      final res = await _db.rpc('username_available',
          params: {'p_username': username.trim().toLowerCase()});
      return res == true;
    } catch (e) {
      debugPrint('[ProfileService] isUsernameAvailable: $e');
      return true;
    }
  }

  /// The signed-in user's profile row, or null if there ISN'T one.
  ///
  /// `maybeSingle`, not `single`: `single` throws on zero rows, which this
  /// method's catch then flattened into the same `null` it returns for a
  /// network error. The caller could not tell "no row" from "no connection",
  /// and Edit Profile rendered a blank form for both — every field empty
  /// including the email, which doesn't even come from this query. Now only a
  /// real failure throws, and a missing row returns null on purpose.
  static Future<Map<String, dynamic>?> getProfile(String uid) async {
    final data = await _db
        .from('profiles')
        .select(_profileCols)
        .eq('id', uid)
        .maybeSingle();
    return data == null ? null : Map<String, dynamic>.from(data);
  }

  /// Permanently deletes the signed-in user's account and data via the
  /// `delete_account_self` RPC (SECURITY DEFINER — removes the auth user and
  /// everything that cascades from the profile). Returns null on success, else
  /// an error message. The caller should sign out afterwards.
  static Future<String?> deleteAccount() async {
    try {
      await _db.rpc('delete_account_self');
      return null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Marks the one-time "placement complete" reveal as shown for the signed-in
  /// user, so it never fires again. Display-only (never rating math).
  ///
  /// Goes through an RPC rather than a direct write: placement_revealed lives
  /// in the ranking block, and no client may write ANY ranking column — a
  /// far easier invariant to hold than "none except this one". The direct
  /// write it replaced had no column grant and always failed, so the reveal
  /// re-fired on every launch instead of once.
  static Future<void> markPlacementRevealed() async {
    if (_db.auth.currentUser?.id == null) return;
    try {
      await _db.rpc('mark_placement_revealed');
    } catch (e) {
      debugPrint('[ProfileService] markPlacementRevealed: $e');
    }
  }

  /// Writes [fields] to the signed-in user's row. Returns an error message, or
  /// null on success.
  ///
  /// `.select()` is not decoration: PostgREST answers 204 whether an UPDATE
  /// changed a row or matched NONE, so without it "saved" and "there is no row
  /// to save to" are the same response. That is how a signup whose profiles row
  /// was never created reported success on every save and changed nothing —
  /// the screen even pops with the new values, so it looks right until the next
  /// cold start. Asking for the row back makes the difference visible.
  static Future<String?> updateProfile(String uid, Map<String, dynamic> fields) async {
    try {
      final rows =
          await _db.from('profiles').update(fields).eq('id', uid).select('id');
      if ((rows as List).isEmpty) {
        return "Your profile couldn't be found, so nothing was saved. "
            'Please sign out and sign in again — if it keeps happening, '
            'contact help@padel-rivals.com.';
      }
      // Keep the plumbed-down copies honest — see [currentName].
      final name = fields['name'] as String?;
      if (OnboardingProfile.isUsableName(name)) currentName.value = name!.trim();
      return null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Fetches the full [PlayerProfile] for the Profile screen — ranking,
  /// career stats, ELO history and recent matches — all from live Supabase data.
  static Future<PlayerProfile> fetchPlayerProfile(String userId) async {
    try {
      // Rating v2 adds sigma/reliability/is_provisional; fall back for
      // pre-migration databases that don't have those columns yet.
      dynamic profileRow;
      try {
        profileRow = flattenRatings(Map<String, dynamic>.from(await _db
            .from('profiles')
            .select('player_ratings(rating, tier, level, placement_played, '
                'reliability, is_provisional, placement_revealed, '
                'competitive_matches)')
            .eq('id', userId)
            .single() as Map));
      } catch (_) {
        profileRow = flattenRatings(Map<String, dynamic>.from(await _db
            .from('profiles')
            .select('player_ratings(rating, tier, level, placement_played)')
            .eq('id', userId)
            .single() as Map));
      }

      // Try with creator profile join; fall back without it if FK hint missing.
      List rawMatches;
      try {
        rawMatches = await _db
            .from('match_players')
            .select('''
              team,
              matches!inner(
                id, status, match_type, scheduled_at, winner_team,
                score_team_a, score_team_b, created_by,
                profiles!matches_created_by_fkey(name)
              )
            ''')
            .eq('player_id', userId)
            .order('created_at', ascending: false)
            .limit(50);
      } catch (_) {
        rawMatches = await _db
            .from('match_players')
            .select('''
              team,
              matches!inner(
                id, status, match_type, scheduled_at, winner_team,
                score_team_a, score_team_b, created_by
              )
            ''')
            .eq('player_id', userId)
            .order('created_at', ascending: false)
            .limit(50);
      }

      final rows = List<Map<String, dynamic>>.from(rawMatches);
      final completed = rows.where((r) {
        final m = r['matches'] as Map?;
        return m?['status'] == 'completed' && m?['winner_team'] != null;
      }).toList();

      int wins = 0, losses = 0;
      for (final r in completed) {
        final m = r['matches'] as Map;
        if ((r['team'] as String?) == (m['winner_team'] as String?)) {
          wins++;
        } else {
          losses++;
        }
      }
      final played = wins + losses;
      final winRate = played > 0 ? '${(wins / played * 100).round()}%' : '—';

      int streak = 0;
      for (final r in completed) {
        final m = r['matches'] as Map;
        if ((r['team'] as String?) == (m['winner_team'] as String?)) {
          streak++;
        } else {
          break;
        }
      }

      // Rating history — built from ranking_history below (the rating-engine-v2
      // per-match trail). The legacy match_players.elo_after column is no longer
      // written by the v2 settle, so it can't feed the chart.
      List<double> ratingPoints = [];

      // Recent 5 completed matches
      final recent = <RecentMatch>[];
      for (final r in completed.take(5)) {
        final m = r['matches'] as Map;
        final myTeam = r['team'] as String?;
        final won = myTeam != null && myTeam == (m['winner_team'] as String?);
        final scoreA = m['score_team_a'] as String?;
        final scoreB = m['score_team_b'] as String?;
        final score = (scoreA != null && scoreB != null)
            ? (myTeam == 'a' ? '$scoreA / $scoreB' : '$scoreB / $scoreA')
            : '—';
        final creatorId = m['created_by'] as String?;
        final creatorName = (m['profiles'] as Map?)?['name'] as String?;
        final opp = (creatorId != null && creatorId != userId && creatorName != null)
            ? creatorName
            : 'Opponent';
        final dtStr = m['scheduled_at'] as String?;
        final dt = dtStr != null ? DateTime.tryParse(dtStr)?.toLocal() : null;
        const months = ['Jan','Feb','Mar','Apr','May','Jun',
                        'Jul','Aug','Sep','Oct','Nov','Dec'];
        final date = dt != null ? '${months[dt.month - 1]} ${dt.day}' : '—';
        final type = m['match_type'] == 'ranked' ? 'Ranked' : 'Casual';
        recent.add(RecentMatch(won, opp, score, date, type));
      }

      final level = (profileRow['level'] as num?)?.toDouble() ?? 0.0;
      final placementPlayed = (profileRow['placement_played'] as num?)?.toInt() ?? 0;
      final reliability =
          (profileRow['reliability'] as num?)?.toDouble() ?? 100.0;
      final provisional = profileRow['is_provisional'] == true;

      // Rating-move breakdown + weekly delta from the player's OWN
      // ranking_history rows (RLS read-own). Skipped on pre-migration DBs.
      double weeklyDelta = 0;
      LastRankedMatch? lastMatch;
      try {
        final weekAgo = DateTime.now()
            .subtract(const Duration(days: 7))
            .toIso8601String();
        final week = await _db
            .from('ranking_history')
            .select('delta')
            .eq('profile_id', userId)
            .gte('created_at', weekAgo);
        for (final row in (week as List)) {
          weeklyDelta += (row['delta'] as num?)?.toDouble() ?? 0;
        }

        // Rating trail for the chart: rating_before of the first match, then
        // each rating_after. Plotted as-is now — this used to be mapped onto a
        // fake ELO axis (800 + rating*200) purely to keep the old chart.
        final histRows = await _db
            .from('ranking_history')
            .select('rating_before, rating_after')
            .eq('profile_id', userId)
            .not('match_id', 'is', null)
            .order('created_at', ascending: true)
            .limit(20);
        final hist = histRows as List;
        if (hist.isNotEmpty) {
          ratingPoints = [
            ((hist.first['rating_before'] as num?) ?? RatingEngineV3F5.prior)
                .toDouble(),
            for (final r in hist)
              if (r['rating_after'] != null) (r['rating_after'] as num).toDouble(),
          ];
        }
        final lastRows = await _db
            .from('ranking_history')
            .select('delta, opp_avg_rating, games_for, games_against, won')
            .eq('profile_id', userId)
            .not('match_id', 'is', null)
            .order('created_at', ascending: false)
            .limit(1);
        if ((lastRows as List).isNotEmpty) {
          final lr = lastRows.first as Map;
          lastMatch = LastRankedMatch(
            won: lr['won'] == true,
            vsLevel: (lr['opp_avg_rating'] as num?)?.toDouble() ?? level,
            delta: (lr['delta'] as num?)?.toDouble() ?? 0,
            gamesFor: (lr['games_for'] as num?)?.toInt() ?? 0,
            gamesAgainst: (lr['games_against'] as num?)?.toInt() ?? 0,
          );
        }
      } catch (_) {/* pre-migration: no breakdown available */}

      final compMatches =
          (profileRow['competitive_matches'] as num?)?.toInt() ?? 0;
      final ranking = placementPlayed < RankingScale.placementTotal
          ? Ranking.placement(placementPlayed)
          : Ranking.placed(
              level: level,
              reliability: reliability,
              provisional: provisional,
              weeklyDelta: weeklyDelta,
              lastMatch: lastMatch,
              competitiveMatches: compMatches,
            );

      return PlayerProfile(
        isNew: played == 0,
        ranking: ranking,
        played: played,
        wins: wins,
        losses: losses,
        streak: streak,
        winRate: winRate,
        ratingHistory: ratingPoints,
        recent: recent,
        // Absent on pre-migration DBs → false (reveal simply won't fire).
        placementRevealed: profileRow['placement_revealed'] == true,
      );
    } catch (e) {
      debugPrint('[ProfileService] fetchPlayerProfile error: $e');
      return PlayerProfile.fresh;
    }
  }

  /// The bits of the profile header that [fetchPlayerProfile] does not carry —
  /// PlayerProfile is a stats model with no photo and no bio, so both were
  /// written by Edit Profile and then never shown anywhere.
  static Future<({String? avatarUrl, String? bio})> fetchHeaderBits(
      String userId) async {
    String? clean(Object? v) {
      final s = (v as String?)?.trim();
      return (s == null || s.isEmpty) ? null : s;
    }

    try {
      final row = await _db
          .from('profiles')
          .select('avatar_url, bio')
          .eq('id', userId)
          .maybeSingle();
      final avatar = clean(row?['avatar_url']);
      // Keep the header in step with the profile header it was fetched for.
      if (userId == _db.auth.currentUser?.id) currentAvatar.value = avatar;
      return (avatarUrl: avatar, bio: clean(row?['bio']));
    } catch (e) {
      debugPrint('[ProfileService] fetchHeaderBits: $e');
      return (avatarUrl: null, bio: null);
    }
  }

  /// Uploads a new avatar to the public `avatars` bucket (overwriting the
  /// user's slot) and saves the URL to profiles.avatar_url. Returns the new URL
  /// (with a cache-busting suffix so the changed image actually refreshes), or
  /// null on failure.
  static Future<String?> uploadAvatar(Uint8List bytes, String ext) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) return null;
    try {
      final e = ext.toLowerCase() == 'jpeg' ? 'jpg' : (ext.isEmpty ? 'jpg' : ext.toLowerCase());
      final path = '$uid/avatar.$e';
      await _db.storage.from('avatars').uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(
                upsert: true, contentType: 'image/${e == 'jpg' ? 'jpeg' : e}'),
          );
      final base = _db.storage.from('avatars').getPublicUrl(path);
      final url = '$base?v=${DateTime.now().millisecondsSinceEpoch}';
      await _db.from('profiles').update({'avatar_url': url}).eq('id', uid);
      // Every surface reading currentAvatar repaints now, rather than showing
      // the old initials until the next cold start.
      currentAvatar.value = url;
      return url;
    } catch (e) {
      debugPrint('[ProfileService] uploadAvatar: $e');
      return null;
    }
  }

  /// Guarantees the signed-in user HAS a profiles row, creating a minimal one
  /// when the signup trigger didn't.
  ///
  /// `handle_new_user()` catches its own exceptions and only `raise warning`s —
  /// deliberately, so a profile insert can never block a signup — but the cost
  /// is that its failure is INVISIBLE. The account exists and sign-in works,
  /// while the person has no profile, no `player_ratings` row, and every write
  /// they make afterwards matches zero rows. Apple signups are where it shows
  /// up, because they are the ones that arrive with no name in the ID token.
  ///
  /// `ignoreDuplicates` makes this ON CONFLICT DO NOTHING, so it can never
  /// overwrite a real profile. Returns false if the row still couldn't be made,
  /// which means the cause is server-side and the caller cannot repair it.
  static Future<bool> ensureProfile(User user) async {
    final meta = user.userMetadata ?? {};
    final name = ((meta['name'] as String?) ?? (meta['full_name'] as String?) ?? '').trim();
    final avatar = (meta['avatar_url'] as String?)?.trim();
    try {
      // Start UNRANKED. No ranking columns are written here at all: they moved
      // to player_ratings on 2026-08-15, and this call used to send
      // placement_played, which made the whole insert 400 — swallowed by the
      // catch below, so the repair silently never happened. The row's own
      // trg_player_ratings_row creates the player_ratings row from this insert.
      await _db.from('profiles').upsert(
        {
          'id': user.id,
          // Omitted rather than blanked when there is nothing usable, so the
          // row keeps a NULL name and onboarding still knows to ASK.
          if (OnboardingProfile.isUsableName(name)) 'name': name,
          if (avatar != null && avatar.isNotEmpty) 'avatar_url': avatar,
          // No preferred_hand / preferred_court_side defaults. Onboarding ASKS
          // both questions and treats a stored value as already answered, so
          // pre-filling them made the playing-style step skip itself — which is
          // why "Both" sometimes never appeared. Leave them null and let the
          // player choose.
        },
        onConflict: 'id',
        ignoreDuplicates: true,
      );
      return true;
    } catch (e) {
      debugPrint('[ProfileService] ensureProfile error: $e');
      return false;
    }
  }

  /// The last [limit] completed matches, newest first — opponents, score from
  /// my side, and the settled rating change. Feeds the Home form strip and its
  /// recap. Rating deltas come from `ranking_history` (v2); the legacy
  /// match_players.elo_* columns are no longer written, so a 0 there would mean
  /// "not recorded", not "no change".
  static Future<List<FormMatch>> recentForm({int limit = 6}) async {
    final db = Supabase.instance.client;
    final uid = db.auth.currentUser?.id;
    if (uid == null) return const [];
    try {
      final deltas = <String, double>{};
      try {
        final hist = await db
            .from('ranking_history')
            .select('match_id, delta')
            .eq('profile_id', uid)
            .not('match_id', 'is', null)
            .limit(200);
        for (final h in List<Map<String, dynamic>>.from(hist as List)) {
          final mid = h['match_id'] as String?;
          final d = (h['delta'] as num?)?.toDouble();
          if (mid != null && d != null) deltas[mid] = d;
        }
      } catch (_) {
        // pre-v2 database (no delta column) — the recap just shows no change
      }

      final rows = await db
          .from('match_players')
          .select('''
            team,
            matches!inner(
              id, status, match_type, scheduled_at, winner_team,
              score_team_a, score_team_b,
              match_players(player_id, team, profiles(name))
            )
          ''')
          .eq('player_id', uid)
          .order('created_at', ascending: false)
          .limit(60);

      const months = ['Jan','Feb','Mar','Apr','May','Jun',
                      'Jul','Aug','Sep','Oct','Nov','Dec'];
      final out = <FormMatch>[];
      for (final r in List<Map<String, dynamic>>.from(rows as List)) {
        if (out.length >= limit) break;
        final m = r['matches'] as Map?;
        if (m == null || m['status'] != 'completed' || m['winner_team'] == null) {
          continue;
        }
        final myTeam = r['team'] as String?;
        final won = myTeam != null && myTeam == m['winner_team'];

        final mps = (m['match_players'] as List?) ?? const [];
        final opps = mps
            .where((p) => p['team'] != myTeam && p['player_id'] != uid)
            .map((p) =>
                ((p['profiles'] as Map?)?['name'] as String? ?? 'Opponent')
                    .split(' ')
                    .first)
            .toList();

        final sa = m['score_team_a'] as String?;
        final sb = m['score_team_b'] as String?;
        String score = '—';
        if (sa != null && sb != null) {
          final a = sa.split(',');
          final b = sb.split(',');
          final mine = myTeam == 'a' ? a : b;
          final theirs = myTeam == 'a' ? b : a;
          score = [
            for (int i = 0; i < mine.length && i < theirs.length; i++)
              '${mine[i].trim()}-${theirs[i].trim()}'
          ].join(', ');
        }

        final dt = DateTime.tryParse(m['scheduled_at'] as String? ?? '')?.toLocal();
        out.add(FormMatch(
          won,
          opps.isEmpty ? 'Opponents' : opps.join(' & '),
          score,
          dt == null ? '—' : '${months[dt.month - 1]} ${dt.day}',
          m['match_type'] == 'ranked' ? 'Competitive' : 'Casual',
          deltas[m['id'] as String? ?? ''],
        ));
      }
      return out;
    } catch (e) {
      debugPrint('[ProfileService] recentForm: $e');
      return const [];
    }
  }

  // ── Phone privacy ──────────────────────────────────────────────────────────
  //
  // Whether a number is visible is decided in Postgres (`_can_see_phone`), not
  // here — these just drive the privacy screen.

  /// Toggle `profiles.phone_public`. Off (the default) means players in your
  /// matches have to ask before they see your number; it never blocks the ask
  /// itself. Returns an error message or null.
  static Future<String?> setPhonePublic(bool on) async {
    try {
      await _db.rpc('set_phone_public', params: {'p_on': on});
      return null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  /// Everyone I've swapped numbers with.
  static Future<List<Map<String, dynamic>>> myContactShares() async {
    try {
      final rows = await _db.rpc('my_contact_shares');
      return List<Map<String, dynamic>>.from(rows as List);
    } catch (e) {
      debugPrint('[ProfileService] myContactShares: $e');
      return [];
    }
  }

  /// Undo a swap. Cuts both ways — one row covers the pair.
  static Future<String?> revokeContactShare(String otherId) async {
    try {
      final res =
          await _db.rpc('revoke_contact_share', params: {'p_other': otherId});
      return res as String?;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }
}
