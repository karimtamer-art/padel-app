# SQL check

Runs the real tournament functions from `supabase/migration_player_app.sql`, plus the
2026-11-02 deltas, in an in-process Postgres (PGlite). It never connects to anything.
Not part of the app, and not in pubspec.

    cd tools/sql_check
    npm install
    node deltas.mjs            # quick
    FULL=1 node deltas.mjs     # every draw size from 2 to 32 pairs

The tables are a STUB of the real schema, so this proves logic, not that a delta fits
the live database. That needs a schema-only dump of live.
