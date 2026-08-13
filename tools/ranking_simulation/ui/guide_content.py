"""The text of the Ranking Lab guide. Edit here, then run make_guide.py."""

from make_guide import (ACCENT, TRUTH, bullet, heading, note, para, step, table)


def content():
    b = []
    A = b.append

    A(para("Ranking Lab", style="Title", space_after=60))
    A(para("How to use every tab, and what to think about while you do  —  "
           "Padel Rivals rating engine bench", style="Subtitle", space_after=200))
    A(note("**Nothing in this tool touches the app.** There is no database, no network and "
           "no connection to real players. Every player, rating and match is invented in "
           "memory and disappears when you close the tab. You cannot break anything."))
    A(para("The lab exists to answer one question before any code changes: **is the proposed "
           "rating engine actually better than the one we run today?** It lets you invent "
           "players whose real strength you know, play matches for them, and watch what each "
           "engine concludes.", space_after=180))

    # ── ideas ───────────────────────────────────────────────────────────────
    A(heading("Four words that must not be confused", 1))
    A(para("Everything in the lab, and every conversation about it, depends on keeping these "
           "apart."))
    A(table(
        ["Term", "What it means"],
        [["True skill",
          "How good the player REALLY is. You choose it. The engines never see it. It exists "
          "so you can mark their homework."],
         ["Engine rating",
          "What an engine currently believes — its guess at the true skill."],
         ["Displayed rating",
          "What the player would actually see on their profile: rounded to the nearest 0.25, "
          "and hidden entirely until the engine is confident enough to commit."],
         ["Sigma",
          "How unsure the engine is. High sigma means big steps, so the rating can move fast. "
          "It falls as the engine sees more matches."]],
        widths=[2100, 7260]))
    A(note("Anywhere you see **ochre / orange-brown**, that is the truth. The coloured lines "
           "and numbers are guesses. If a guess sits on the ochre line, the engine is right.",
           color=TRUTH))

    A(heading("The engines you can switch on", 2))
    A(table(
        ["Chip", "What it is"],
        [["V2", "Today's live engine — an exact copy of what runs in the app right now. "
                "This is the thing being judged. It is locked and cannot be edited, and it "
                "has no placement phase, so the placement controls do not apply to it."],
         ["V3", "The proposal. Four changes to V2: start players at 3.3 instead of 2.0, let "
                "placement move faster, stop discounting new opponents, and cap how much the "
                "score margin counts."],
         ["C", "The study's fully tuned version. Goes further than V3."],
         ["B", "V2 with only the placement phase changed, to isolate that one effect."],
         ["TS / TS-set", "TrueSkill, the system Xbox uses. A comparison, not a proposal."],
         ["G2", "Glicko-2, from chess. Also a comparison."]],
        widths=[1400, 7960]))
    A(para("**Always keep V2 switched on.** Every number is only meaningful next to what we "
           "do today.", space_after=180))

    A(heading("The seed box, top right", 2))
    A(para("Every run is built from that number, so the same seed always produces the same "
           "matches. If you see something strange, press **copy** and send it — the exact "
           "run can be reproduced. Press **new** for a different draw."))
    A(note("One run is an anecdote. Before believing anything, change the seed two or three "
           "times and check the story holds.", color=TRUTH))

    # ── STORY ───────────────────────────────────────────────────────────────
    A(heading("Tab 1  —  Story", 1))
    A(para("**What it is for:** understanding, one match at a time, why a rating moved. Start "
           "here, and come back here whenever a number in another tab looks wrong."))

    A(heading("How to use it", 2))
    A(step(1, "Set **True skill** — how good the player really is. The buttons underneath "
               "are shortcuts, from Beginner 1.5 to Elite 6.5."))
    A(step(2, "Set **Placement length** — how many matches before the engine commits to "
               "a rating. The stages stretch to fit whatever you choose, so a 5-match and a "
               "30-match placement have the same shape: big steps first, gentle steps last. "
               "**This only applies to engines that have a placement phase** — see the note "
               "below."))
    A(step(3, "Press **Start placement**."))
    A(step(4, "Press **Play next match** repeatedly. Or **Force a win** / **Force a loss** to "
               "make an upset happen, or type an exact score such as `6-0,6-0` and press "
               "**Play that score**."))
    A(step(5, "**Finish placement** jumps to the end; **+10** and **+40** carry on past it."))

    A(heading("What to look at", 2))
    A(para("The big coloured number on each card is what that engine believes. Beside it sits "
           "the error against the true skill and a chip reading close / off / far off."))
    A(para("The strip of small boxes underneath is the arithmetic behind the move:"))
    A(table(
        ["Box", "Meaning"],
        [["team / opponents", "What the engine thought each pair was worth."],
         ["expected", "The engine's estimate of your chance of winning."],
         ["K", "The largest step it is allowed to take this match."],
         ["W", "How much this result counts. 1.00 is full weight."],
         ["signal S", "The score turned into a single number between 0 and 1."],
         ["from result / from margin",
          "How much of S came from winning, and how much from winning convincingly."],
         ["delta rating", "The move actually applied."],
         ["sigma", "Uncertainty before and after."]],
        widths=[2400, 6960]))
    A(para("Under the strip is a sentence in plain English. Watch for this one on V2 after a "
           "**win**:", space_after=80))
    A(note("“The games margin moved this by −0.032 — a win that cost rating "
           "because the score was closer than the engine expected.”", color=TRUTH))
    A(para("That is one of the four faults happening in front of you. A strong pair wins about "
           "87% of matches but only about 60% of games; today's engine compares those two "
           "numbers as if they were the same thing, so good players are quietly dragged toward "
           "the middle even when they win.", space_after=180))
    A(para("The two boxes at the bottom of each card are the point of the whole tab: on the "
           "left what you see as the developer, on the right **what the player would actually "
           "see** — either a level and a division, or the reason it is still being withheld."))

    A(heading("V2 has no placement phase — and that is the point", 2))
    A(para("Only V3 shows “placement 4 / 10”. V2 shows “provisional”, "
           "because today's engine has no placement phase to be in. It has two separate "
           "mechanisms that are easy to mistake for one:"))
    A(bullet("**A K boost:** a player's first **5** matches move 1.5× faster. That is all."))
    A(bullet("**A display gate:** the rating is flagged provisional until sigma drops to "
             "0.40 **and** **10** matches are played. Nothing about the maths changes at "
             "that point — only whether the app is willing to show the number."))
    A(para("So the Placement length control does nothing to V2. Lengthening a phase that "
           "does not exist would mean inventing one, at which point it is no longer the "
           "engine we run today. **Bringing those mechanisms together into one honest "
           "placement phase is part of what V3 proposes**, not an incidental detail.",
           space_after=180))
    A(note("**Worth fixing separately:** production disagrees with itself about this "
           "number. The stored `is_provisional` column uses `competitive_matches < 10`, "
           "while `admin_season_player` and one view fallback use `< 5`, and the app shows "
           "the player “placement 3 / 5”. After seven matches the home screen "
           "says placement is finished while the database still says provisional. No rating "
           "is miscalculated by this — `_settle_rating` never reads the flag — but three "
           "surfaces give two answers. The lab mirrors the stored column, since that is the "
           "one that decides.", color=TRUTH))

    A(heading("What to think about", 2))
    A(bullet("Does the rating move toward the truth, or stall short of it?"))
    A(bullet("Is the move **big enough**? A rating that needs forty matches to arrive is wrong "
             "for thirty-nine of them."))
    A(bullet("Does a win ever **cost** rating? It should not."))
    A(bullet("When the player is finally shown a number, is it one they would recognise as "
             "themselves? A genuine 5.5 shown as “Level 3.50, Gold” will not trust "
             "the app again."))
    A(note("**The experiment worth running first:** true skill 6.0, placement 10, play ten "
           "matches. Compare the two cards. That single screen is the whole argument for "
           "changing the engine."))

    A(heading("Starting state and opponents  (the fold-out)", 2))
    A(para("Four things that are true **before** the first match is played. The defaults are "
           "the honest ones; change them to build a specific awkward case."))
    A(table(
        ["Setting", "What it does, and why you would touch it"],
        [["Start rating / Start sigma",
          "Where the engine begins guessing, and how unsure it is. Blank means the normal "
          "starting point — 2.00 for V2, 3.30 for V3. Set them to build a SMURF (a true "
          "5.5 starting at 1.5) or an OVERRATED BEGINNER (a true 1.5 starting at 5.3), and see "
          "how long each engine takes to undo a bad start."],
         ["Everyone else",
          "Who the partner and opponents are. ESTABLISHED means they are already rated "
          "correctly, so the only thing moving is your player — the clean measurement. "
          "BRAND NEW is launch week: nobody is rated, every rating in the match is a guess. "
          "That is the harder and more realistic case, and it is where the "
          "opponent-reliability fault does its damage."],
         ["World",
          "How padel itself behaves — the hidden rules deciding who wins, which no engine "
          "ever sees. The real choice is how decisive a one-level gap is: the default assumes "
          "a level better wins about 87% of matches, the alternatives 78% and 96%. Nobody "
          "knows the true figure. If a conclusion only holds in one world, it is not a "
          "conclusion."],
         ["Onboarding answer",
          "“What's your level?” at sign-up. It moves the starting point only — "
          "sigma stays at maximum, so a dishonest answer is worth a couple of matches rather "
          "than a rank. Set it to disagree with the true skill and watch how fast it gets "
          "undone."]],
        widths=[2100, 7260]))

    # ── COMPARE ─────────────────────────────────────────────────────────────
    A(heading("Tab 2  —  Compare engines", 1))
    A(para("**What it is for:** checking that what you saw in Story was not luck. Same player, "
           "same matches, every engine, repeated across many random seeds."))

    A(heading("How to use it", 2))
    A(step(1, "Set **True skill** and **Matches**, or press one of the grey shortcuts: Test "
               "true 1.5, 2, 3.5, 5, 6."))
    A(step(2, "**Repeat over seeds** is the important control. Leave it at 12 or more — "
               "it runs the whole experiment that many times with different luck and averages "
               "the result."))
    A(step(3, "Press **Run**."))
    A(para("Three preset experiments sit underneath:", space_after=80))
    A(bullet("**Smurf test** — a genuine 5.5 starting from 1.5. Until that corrects they "
             "are not merely mis-numbered, they are ruining beginners' matches."))
    A(bullet("**Overrated test** — a genuine 1.5 starting from 5.3. This is the risk you "
             "take by trusting an onboarding answer."))
    A(bullet("**Everyone new** — nobody in the app is rated yet. This is your launch week."))

    A(heading("What to look at", 2))
    A(para("The four boxes across the top are each engine's final rating and its error. Below "
           "them the chart shows the journey, with the dashed ochre line as the truth — "
           "you want a line that climbs to it and settles. The table gives the rating after 1, "
           "2, 3, 5, 10… matches, and the last column is the final error."))

    A(heading("What to think about", 2))
    A(bullet("**Which engine reaches the ochre line, and how quickly?**"))
    A(bullet("Does any engine overshoot and wobble? Fast is not automatically good."))
    A(bullet("Compare a weak player against a strong one. Raising the starting point helps "
             "strong players — does it hurt beginners? Run Test true 1.5 and check."))
    A(bullet("The **spread** figure beside each result shows how much the answer changes with "
             "luck. A small error with a huge spread is not a reliable engine."))

    # ── POPULATION ──────────────────────────────────────────────────────────
    A(heading("Tab 3  —  Population", 1))
    A(para("**What it is for:** the whole app at once rather than one player. This is where "
           "the problem is easiest to see and hardest to argue with."))

    A(heading("How to use it", 2))
    A(step(1, "Choose **Players** (200 is plenty) and **Matches each** (10 = end of placement)."))
    A(step(2, "Press **Generate and run**."))
    A(step(3, "Drag the slider to replay the league at any number of matches."))

    A(heading("What to look at — in this order", 2))
    A(para("**1. The band table**, headed “Average rating given to each true-level "
           "band”. Read across a row: the numbers should climb in step with the headings.",
           space_after=100))
    A(table(
        ["Engine", "true 1-2", "true 2-3", "true 3-4", "true 4-5", "true 5-6", "true 6-7"],
        [["V2", "1.73", "1.94", "1.99", "2.15", "2.24", "2.59"],
         ["V3", "2.78", "3.16", "3.27", "3.60", "3.79", "4.43"]],
        widths=[1560, 1300, 1300, 1300, 1300, 1300, 1300]))
    A(para("Real skill spans 1.5 to 6.5. V2's row spans 1.73 to 2.59. **That flat row is the "
           "whole problem** — the app hands nearly the same rating to a beginner and a "
           "near-professional.", space_after=180))
    A(para("**2. The six summary boxes** for each engine:", space_after=100))
    A(table(
        ["Number", "How to read it"],
        [["avg error", "How many levels off, on average. Lower is better."],
         ["spread kept",
          "The single most useful number. 100% means the leaderboard is as spread out as real "
          "skill; below 50% it is visibly squashed. V2 scores about 23%."],
         ["5.0+ stuck low", "Share of genuinely strong players still shown under 3.5."],
         ["weak stuck high", "The mirror image — beginners shown above 3.0."],
         ["order",
          "1.00 means the ranking ORDER is perfect. V2 scores well here: it knows who is "
          "better than whom, it just squashes everyone together."],
         ["bias", "How far the whole population has been shifted, as one number."]],
        widths=[1900, 7460]))
    A(para("**3. The scatter plot.** Each dot is a player — real skill across, engine "
           "rating up. You want the dots to hug the diagonal. A flat horizontal smear means "
           "the rating barely responds to real skill.", space_after=120))
    A(para("**4. The histogram.** Filled bars are engine ratings; the dashed ochre outline is "
           "real skill. You want the shapes to match. One tall spike means everyone has been "
           "piled into the same place.", space_after=120))
    A(para("**5. Individual players.** The table at the bottom lists the worst-rated, most "
           "under-rated and most over-rated players. Click any row to open that person's full "
           "history. Averages hide people; this is where you meet them."))

    A(heading("What to think about", 2))
    A(bullet("Drag the slider from 1 to 50. **Does the problem fix itself with time?** For V2 "
             "it does not, and that is the key finding."))
    A(bullet("A good ORDER with a bad SPREAD means the engine understands the players and "
             "reports them badly. That is a far easier problem than getting the order wrong."))
    A(bullet("Check both ends. An engine that fixes strong players by pushing everyone up has "
             "not fixed anything."))

    # ── DOUBLES ─────────────────────────────────────────────────────────────
    A(heading("Tab 4  —  Doubles and boosting", 1))
    A(para("**What it is for:** padel is played in pairs, which creates two problems a singles "
           "rating never has."))

    A(heading("Is an average a fair description of a pair?", 2))
    A(para("A 5.0 with a 2.0 partner and two 3.5s both average 3.5, but they do not win equally "
           "often. Drag the lambda slider and compare the ochre column — what really "
           "happens — against the model columns. The lambda model charges a pair for being "
           "lopsided."))
    A(note("Lambda is **experimental and switched off** in the V3 proposal. It fits the "
           "simulation well, but it should be fitted against real match data before it goes "
           "anywhere near the app.", color=TRUTH))

    A(heading("Boosting: does a strong partner inflate a weak player?", 2))
    A(para("Set the weak player's true skill and a strong partner, then press **Run boost "
           "test**. The same player plays one run always with the strong partner and an "
           "identical run with random partners. The gap between the two ratings is what the "
           "partner bought them."))
    A(bullet("Zero would mean the rating describes the player rather than their company."))
    A(bullet("**Engines that move more also leak more.** Judge inflation next to accuracy, "
             "never on its own — an engine that never moves cannot be boosted, and is "
             "also useless."))
    A(bullet("The **partner gap limit** is here to be disproved. The study found rating-gap "
             "restrictions do not meaningfully stop boosting: as the weak player is carried "
             "upward the gap closes and the rule stops applying. Try 1.5 and see how little "
             "changes."))

    A(heading("Is the rating about the player, or their regular partner?", 2))
    A(para("Three phases of equal length: always with a strong partner, always with a weak one, "
           "then random partners. All three describe the **same player**. The swing column is "
           "how much of their rating is really their partner's."))

    # ── KNOBS ───────────────────────────────────────────────────────────────
    A(heading("Tab 5  —  Knob sweeps", 1))
    A(para("**What it is for:** answering “what if we set this differently?” without "
           "guessing. Each row reruns the same league with one value changed."))

    A(heading("How to use it", 2))
    A(step(1, "Pick a **knob** from the list."))
    A(step(2, "Press **Run sweep**. Every row is the same experiment with only that value "
               "different."))
    A(table(
        ["Knob", "The question it answers"],
        [["Starting prior",
          "Where should a brand-new player begin? This is fault number one: today everyone "
          "starts at 2.0 while the average player is about 3.3."],
         ["Placement K", "How big a step is allowed early on?"],
         ["Opponent reliability",
          "Should results against unrated opponents count for less? At launch nobody is rated, "
          "so today this quietly halves every early result."],
         ["Score margin", "How much should the scoreline matter next to simply winning?"],
         ["Expected-win curve", "How much better is a player one level above another?"],
         ["Team imbalance", "The lambda experiment from the Doubles tab."],
         ["Sigma decay", "How fast the engine becomes confident."]],
        widths=[2100, 7260]))

    A(heading("What to think about", 2))
    A(note("**Do not choose on average error alone.** A setting that flattens everyone toward "
           "the middle improves average error while making the ranking useless. Always read "
           "SPREAD KEPT and CALIBRATION alongside it.", color=TRUTH))
    A(bullet("Look for a **flat region**, not a peak. A value that is good at exactly 3.3 and "
             "bad at 3.2 and 3.4 is luck, not a finding."))
    A(bullet("Change the seed count and rerun. If the best value moves, you are reading noise."))

    A(heading("What is a scoreline worth?", 2))
    A(para("The same four players and the same win at three different margins. The chip tells "
           "you how many levels separate a 7-6 7-6 from a 6-0 6-0. Large means the score is "
           "worth running up; near zero means the margin carries no information at all. "
           "Somewhere small but not zero is right."))

    A(heading("Does asking “what's your level?” help?", 2))
    A(para("Compares a flat starting point against an onboarding question, including "
           "populations where some people lie in each direction. Watch how quickly the lines "
           "converge: the answer helps in the first few matches and then washes out, which is "
           "exactly why sigma must stay at maximum regardless of what anyone claims."))

    # ── CAREER ──────────────────────────────────────────────────────────────
    A(heading("Tab 6  —  Career events", 1))

    A(heading("When a player genuinely changes", 2))
    A(para("A settled player really does get better or worse. Set what they settle at, what "
           "they truly become, and press **Run skill change**."))
    A(para("**Watch the second chart, not the first.** The first shows the rating catching up. "
           "The second shows uncertainty. If sigma keeps FALLING after the change, the engine "
           "is becoming more confident while being repeatedly proven wrong — the clearest "
           "sign a system has stopped listening.", space_after=180))

    A(heading("Coming back after time away", 2))
    A(para("Today the app removes rating for not playing. The alternative is to keep the rating "
           "and widen the uncertainty: the engine says “I am less sure” rather than "
           "“you got worse”."))
    A(bullet("**Lost to decay** is rating taken purely for absence."))
    A(bullet("**Matches to recover** is how long it takes to get back."))
    A(bullet("Set the return skill to unchanged. Anything lost was taken for nothing — "
             "the player did not get worse, they went on holiday."))

    # ── SETTINGS ────────────────────────────────────────────────────────────
    A(heading("Tab 7  —  Settings", 1))
    A(para("Every parameter, live. Changes apply to every other tab immediately. **V2 is "
           "locked** — it is the production baseline, and automated tests pin it in place."))
    A(bullet("**Reset to V3 / Study's tuned / Aggressive** load a complete set of values."))
    A(bullet("**Save scenario** keeps a configuration in this browser; **Export** writes it to "
             "a file you can send to someone else."))

    A(heading("Replay real match history", 2))
    A(para("The most valuable thing this tool will ever do, and it needs no simulation at all. "
           "Everything else has to guess how decisive a level gap really is in padel. Real "
           "matches remove the guess."))
    A(para("Feed it a file of actual anonymised matches — four player ids and a scoreline, "
           "in the order they were played. There is no true skill in real data, so instead of "
           "error the lab measures **prediction**: before each match the engine is asked who "
           "will win and scored against what actually happened, always before it has seen that "
           "match. Lowest Brier score wins.", space_after=180))
    A(note("Once the live app has enough match history, this is the experiment that should "
           "decide the question. Everything else is preparation for it."))

    # ── SESSION ─────────────────────────────────────────────────────────────
    A(heading("A first session, in order", 1))
    A(step(1, "**Story**: true skill 6.0, placement 10, play ten matches. Read both cards and "
               "the player's view."))
    A(step(2, "**Story** again with the fold-out open, Everyone else set to **Brand new**. That "
               "is your launch week."))
    A(step(3, "**Compare engines**: press Test true 1.5, then Test true 5, then Test true 6. "
               "Confirm the pattern holds at both ends."))
    A(step(4, "**Compare engines**: press Smurf test. Count the matches before the player "
               "escapes beginner lobbies."))
    A(step(5, "**Population**: Generate and run, then read only the band table. Drag the slider "
               "to 50 and confirm V2 does not recover."))
    A(step(6, "**Knob sweeps**: sweep the starting prior. It is the cheapest change available "
               "and the sweep shows why."))
    A(step(7, "Change the seed at the top and repeat anything that surprised you."))

    # ── LIMITS ──────────────────────────────────────────────────────────────
    A(heading("What the lab cannot tell you", 1))
    A(para("Being straight about the limits matters more than the numbers."))
    A(bullet("**It does not know real padel.** The biggest unknown is how decisive a one-level "
             "gap truly is. Three worlds bracket it deliberately — a conclusion that only "
             "holds in one of them is not a conclusion."))
    A(bullet("**It cannot tell you where the population really sits.** No engine of this family "
             "can. That comes from the starting point and from hand-calibrated players, never "
             "from results."))
    A(bullet("**Simulated players are better behaved than real ones.** Nobody in here tanks a "
             "match, plays injured, or shares an account."))
    A(bullet("**A settled rating is not a fair rating** if people cannot understand it. The "
             "player's view exists in the Story tab for exactly that reason."))

    A(heading("If something looks wrong", 1))
    A(para("Copy the seed from the top right and note which tab and settings you were using. "
           "Every run is exactly reproducible from that number, so anything you see can be "
           "investigated rather than argued about."))
    A(note("Nothing in the app has been changed. The rating engine, the database and every real "
           "player's rating are exactly as they were. Nothing will change until you have looked "
           "at this and said so."))
    return "".join(b)
