import { serve } from 'https://deno.land/std@0.177.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// Service-role client — the ONLY writer allowed to mutate level / placement_played.
const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
)

// ── Division bands (mirror of Dart RankingScale) ──────────────────────────────
const BANDS = [
  { key: 'D', min: 0.0, max: 1.9 },
  { key: 'C', min: 2.0, max: 3.4 },
  { key: 'B', min: 3.5, max: 4.9 },
  { key: 'A', min: 5.0, max: 7.0 },
]

function divisionKey(level: number): string {
  for (const b of BANDS) if (level <= b.max) return b.key
  return 'A'
}

// ── Rating formula ────────────────────────────────────────────────────────────
// ELO-style on the 0–7 level scale.
// K-factor (max points exchanged per match) varies by average level tier.
// Tune these values once you have real match data.
function kFactor(avgLevel: number): number {
  if (avgLevel < 2.0) return 0.20 // beginners — faster movement
  if (avgLevel < 3.5) return 0.16
  if (avgLevel < 5.0) return 0.13
  return 0.10                      // elite — smaller swings
}

function computeDeltas(
  winnerAvg: number,
  loserAvg: number,
): [number, number] {
  const k = kFactor((winnerAvg + loserAvg) / 2)
  // Expected win probability for the winner
  const expected = 1 / (1 + Math.pow(10, (loserAvg - winnerAvg) / 2))
  const winDelta  = +( k * (1 - expected)).toFixed(3)
  const loseDelta = +(-k * expected      ).toFixed(3)
  return [winDelta, loseDelta]
}

// ── Edge Function entry point ─────────────────────────────────────────────────
serve(async (req: Request) => {
  try {
    const { match_id } = await req.json()
    if (!match_id) return json({ error: 'missing match_id' }, 400)

    // 1. Load match + players + pending result
    const { data: match, error: mErr } = await supabase
      .from('matches')
      .select(`
        id, type, status,
        match_players ( profile_id, team ),
        match_results ( winner_team, state )
      `)
      .eq('id', match_id)
      .single()

    if (mErr || !match) return json({ error: 'match not found' }, 404)

    // Only competitive matches move ranking
    if (match.type !== 'competitive') {
      await supabase
        .from('match_results')
        .update({ state: 'confirmed' })
        .eq('match_id', match_id)
      await supabase
        .from('matches')
        .update({ status: 'confirmed' })
        .eq('id', match_id)
      return json({ skipped: 'casual match — no ranking change' })
    }

    const result = match.match_results?.[0]
    if (!result || result.state !== 'awaiting') {
      return json({ error: 'result not awaiting confirmation' }, 400)
    }

    // 2. Identify winners and losers
    const winTeam = result.winner_team as number
    const players = match.match_players as { profile_id: string; team: number }[]
    const winners = players.filter(p => p.team === winTeam).map(p => p.profile_id)
    const losers  = players.filter(p => p.team !== winTeam).map(p => p.profile_id)
    const allIds  = [...winners, ...losers]

    // 3. Load current levels
    const { data: profiles } = await supabase
      .from('profiles')
      .select('id, level, placement_played')
      .in('id', allIds)

    const byId = Object.fromEntries((profiles ?? []).map((p: any) => [p.id, p]))

    const avgLevel = (ids: string[]) =>
      ids.reduce((s, id) => s + (byId[id]?.level ?? 0), 0) / ids.length

    const winAvg  = avgLevel(winners)
    const loseAvg = avgLevel(losers)
    const [winΔ, loseΔ] = computeDeltas(winAvg, loseAvg)

    // 4. Update each player atomically
    async function applyDelta(id: string, delta: number) {
      const p = byId[id]
      const before  = (p?.level ?? 0) as number
      const played  = (p?.placement_played ?? 0) as number
      const placing = played < 5

      // During placement, level doesn't change (just increment counter)
      const after   = placing ? before : Math.min(7, Math.max(0, before + delta))
      const newPlayed = Math.min(played + 1, 999)

      await supabase
        .from('profiles')
        .update({ level: after, placement_played: newPlayed })
        .eq('id', id)

      await supabase.from('ranking_history').insert({
        profile_id:   id,
        match_id:     match_id,
        level_before: before,
        level_after:  after,
      })
    }

    await Promise.all([
      ...winners.map(id => applyDelta(id, winΔ)),
      ...losers.map(id  => applyDelta(id, loseΔ)),
    ])

    // 5. Mark confirmed
    await supabase
      .from('match_results')
      .update({ state: 'confirmed' })
      .eq('match_id', match_id)

    await supabase
      .from('matches')
      .update({ status: 'confirmed' })
      .eq('id', match_id)

    return json({ ok: true, winDelta: winΔ, loseDelta: loseΔ })
  } catch (err) {
    return json({ error: String(err) }, 500)
  }
})

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}
