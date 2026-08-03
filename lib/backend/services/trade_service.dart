import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Racket trade-ins. A player submits the racket they want to trade, with
/// photos, and the admin console (Requests → Trade-ins) prices it and makes an
/// offer in store credit.
///
/// Photos live in the private `trade-photos` bucket. What is stored on the row
/// is the storage PATH, not a URL — the console signs each path to view it,
/// the same arrangement payment proofs use.
class TradeService {
  TradeService._();
  static SupabaseClient get _db => Supabase.instance.client;

  static const _bucket = 'trade-photos';

  /// Most rackets need a couple of angles (face + edge guard is the usual
  /// tell for wear); more than this and the sheet stops being a quick form.
  static const maxPhotos = 4;

  /// Uploads one racket photo. Returns `(path: ..., error: null)` on success,
  /// or `(path: null, error: <reason>)` so the sheet can say WHY rather than
  /// showing a generic failure.
  static Future<({String? path, String? error})> uploadPhoto(
      Uint8List bytes, String ext) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) {
      return (
        path: null,
        error: 'You appear to be signed out. Sign in and try again.'
      );
    }
    final safeExt = ext.toLowerCase() == 'jpeg'
        ? 'jpg'
        : (ext.isEmpty ? 'jpg' : ext.toLowerCase());
    // <uid>/… — the storage policy checks the first folder segment.
    final path =
        '$uid/${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(99999)}.$safeExt';
    try {
      await _db.storage.from(_bucket).uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(
                contentType: 'image/${safeExt == 'jpg' ? 'jpeg' : safeExt}'),
          ).timeout(const Duration(seconds: 25));
      return (path: path, error: null);
    } on StorageException catch (e) {
      debugPrint('[TradeService] uploadPhoto storage error: '
          '${e.statusCode} ${e.error} ${e.message}');
      final m = e.message.toLowerCase();
      final reason = (m.contains('not found') || m.contains('bucket'))
          ? "Photo uploads aren't set up on the server yet. Please contact support."
          : (e.statusCode == '403' ||
                  m.contains('policy') ||
                  m.contains('unauthorized'))
              ? 'Not allowed to upload right now. Please sign out and back in.'
              : 'Upload failed: ${e.message}';
      return (path: null, error: reason);
    } on TimeoutException catch (e) {
      debugPrint('[TradeService] uploadPhoto timed out: $e');
      return (
        path: null,
        error: 'Upload timed out. Try again on a stronger connection.'
      );
    } on SocketException catch (e) {
      debugPrint('[TradeService] uploadPhoto network error: $e');
      return (path: null, error: 'No connection. Check your internet and retry.');
    } catch (e) {
      debugPrint('[TradeService] uploadPhoto: $e');
      return (path: null, error: 'Upload failed. Please try again.');
    }
  }

  /// Creates the trade-in request. Returns `(id: ..., error: null)` with the
  /// new row id, or the reason it failed.
  ///
  /// No asking price — the credit is set by the team after inspection.
  static Future<({String? id, String? error})> submit({
    required String racketDesc,
    required String condition,
    required String note,
    required List<String> photoPaths,
  }) async {
    final uid = _db.auth.currentUser?.id;
    if (uid == null) {
      return (
        id: null,
        error: 'You appear to be signed out. Sign in and try again.'
      );
    }
    try {
      final row = await _db
          .from('trade_requests')
          .insert({
            'player_id': uid,
            'racket_desc':
                racketDesc.trim().isEmpty ? 'Racket trade-in' : racketDesc.trim(),
            'condition': condition,
            'note': note,
            'photos': photoPaths,
            'status': 'pending',
          })
          .select('id')
          .single();
      return (id: row['id'] as String?, error: null);
    } on PostgrestException catch (e) {
      debugPrint('[TradeService] submit: ${e.code} ${e.message}');
      // The photos column is the newest part of this flow — if the delta
      // hasn't been run on this database yet, say so plainly instead of
      // "try again", which would never work.
      final m = e.message.toLowerCase();
      if (m.contains('photos') && m.contains('column')) {
        return (
          id: null,
          error: "Trade-in photos aren't set up on the server yet. "
              'Please contact support.'
        );
      }
      return (id: null, error: "Couldn't submit the trade-in. Try again.");
    } catch (e) {
      debugPrint('[TradeService] submit: $e');
      return (id: null, error: "Couldn't submit the trade-in. Try again.");
    }
  }
}
