import 'package:flutter/material.dart'; // MaterialPageRoute in refreshOnReturn

/// Reloads a screen's data on its own, so pull-to-refresh is the second way to
/// get fresh data rather than the only one.
///
/// Before this there was no `WidgetsBindingObserver` anywhere in the app: you
/// could leave it for an hour, come back, and every screen still showed what it
/// had fetched when you left. That is most of what "you always have to pull to
/// refresh" actually meant.
///
/// Two triggers:
///
///  * **Coming back to the app.** Backgrounded → resumed re-reads.
///  * **Coming back to the screen.** [refreshOnReturn] wraps a `push` and
///    reloads when it pops, for the destinations that change what the caller
///    is showing.
///
/// [autoRefreshGap] stops the two from stacking — a resume immediately after a
/// pop shouldn't fire two identical queries. It does NOT gate an explicit pull,
/// which must always do what it says.
///
/// Usage:
/// ```dart
/// class _FooState extends State<Foo> with AutoRefresh<Foo> {
///   @override
///   Future<void> onAutoRefresh() => _load(silent: true);
/// }
/// ```
mixin AutoRefresh<T extends StatefulWidget> on State<T> {
  AppLifecycleListener? _lifecycle;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  bool _running = false;

  /// Reload this screen's data. Should be SILENT — no spinner takeover — since
  /// the user didn't ask for it and is looking at usable content already.
  Future<void> onAutoRefresh();

  /// Ignore an automatic trigger this soon after the last one.
  Duration get autoRefreshGap => const Duration(seconds: 15);

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: autoRefresh);
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }

  /// Fire a refresh unless one just happened or is still in flight.
  Future<void> autoRefresh() async {
    if (!mounted || _running) return;
    final now = DateTime.now();
    if (now.difference(_last) < autoRefreshGap) return;
    _last = now;
    _running = true;
    try {
      await onAutoRefresh();
    } finally {
      _running = false;
    }
  }

  /// Marks a refresh as having just happened, so an explicit pull doesn't get
  /// immediately followed by an automatic one.
  void markRefreshed() => _last = DateTime.now();

  /// Push [page] and reload when it pops. For destinations that change what
  /// this screen renders — the reason Edit Profile used to return to a stale
  /// header.
  Future<void> refreshOnReturn(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    if (!mounted) return;
    _last = DateTime.fromMillisecondsSinceEpoch(0); // a return always reloads
    await autoRefresh();
  }
}
