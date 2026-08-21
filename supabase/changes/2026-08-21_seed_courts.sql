-- ============================================================================
-- 2026-08-21 — seed the courts catalogue (185 venues)
-- ============================================================================
-- One-off DATA delta. No schema changes: it only inserts rows into
-- public.courts. Safe to re-run — every row is guarded by a NOT EXISTS on
-- (venue_name, name), so a second run inserts nothing rather than doubling
-- the catalogue. There is no unique constraint on courts to lean on, which
-- is exactly why the guard is written out by hand.
--
-- Source: the four Courts*.xlsx lists, merged and de-conflicted into one
-- sheet (185 rows: 56 + 51 + 50 + 28).
--
-- What is deliberately NOT set here:
--   lat / lng     — left NULL. No free source had coordinates for these
--                   venues, and a guessed coordinate silently drives players
--                   to the wrong place. `address` is populated instead, which
--                   is enough for the player Directions button: the client
--                   falls back to it when coords are absent
--                   (create_match_sheet.dart `hasLoc`).
--   indoor        — every row false. Nothing in the source lists states it;
--                   it needs a human pass in the console.
--   owner_id      — NULL, i.e. platform-owned rather than organizer-owned,
--                   so `is_public` keeps its default true and every player
--                   sees them.
--   surface,
--   price_per_hour — never referenced. Both are historical columns that may
--                   or may not still exist on live; letting their defaults
--                   apply keeps this delta runnable either way.
--
-- NOTE ON CITY: courts.city is NOT NULL DEFAULT 'Cairo' (migrations/0003).
-- 8 rows arrive with no city because their source area was
-- 'Central Cairo & Giza' — a region spanning two governorates, not a
-- district. They are inserted as 'Cairo' so the NOT NULL holds, and the
-- verify block at the bottom lists exactly those rows so they can be
-- corrected in the console. At least one (PadelHouse - Shooting Club) is
-- almost certainly Giza.
-- ============================================================================

-- One statement, so it is atomic on its own and needs no explicit
-- transaction block (no other delta in this repo opens one). The casts on
-- the first tuple pin the column types — without them Postgres cannot infer
-- a type for a VALUES column whose entries are all bare NULLs.
with seed (venue_name, name, area, city, address) as (
  values
    -- ── List 1 ────────────────────────────────────────────────────
    ('Pro Padel Egypt Maadi Club'::text, 'Court 1'::text, 'Maadi'::text, 'Cairo'::text, 'Pro Padel Egypt Maadi Club, Maadi Sports & Yacht Club (Maadi Club), Maadi, Cairo, Egypt'::text),
    ('Padel Yard', 'Court 1', 'Maadi', 'Cairo', 'Padel Yard, Maadi, Cairo, Egypt'),
    ('Wadi Degla Maadi Padel Courts', 'Court 1', 'Maadi', 'Cairo', 'Wadi Degla Maadi Padel Courts, Maadi, Cairo, Egypt'),
    ('Padel Up', 'Court 1', 'Maadi', 'Cairo', 'Padel Up, Maadi, Cairo, Egypt'),
    ('Padel field maadi', 'Court 1', 'Maadi', 'Cairo', 'Padel field maadi, Maadi, Cairo, Egypt'),
    ('SR Padel Club 7', 'Court 1', 'Maadi', 'Cairo', 'SR Padel Club 7, Club 7, The Field Maadi, Maadi, Cairo, Egypt'),
    ('HPadel-Cairo Stadium', 'Court 1', 'Nasr City', 'Cairo', 'HPadel-Cairo Stadium, Inside Cairo International Stadium, Mamdouh Salem St, Nasr City, Cairo, Egypt'),
    ('Courts Padel', 'Court 1', 'Nasr City', 'Cairo', 'Courts Padel, Nasr City, Cairo, Egypt'),
    ('30 june padel', 'Court 1', 'Nasr City', 'Cairo', '30 june padel, 30 June Stadium, Nasr City, Cairo, Egypt'),
    ('Padel Up Elite', 'Court 1', 'Nasr City', 'Cairo', 'Padel Up Elite, Nasr City, Cairo, Egypt'),
    ('Padel Point Talaaea', 'Court 1', 'Nasr City', 'Cairo', 'Padel Point Talaaea, Talaaea Sporting Club, Nasr City, Cairo, Egypt'),
    ('Four corners padel club', 'Court 1', 'Nasr City', 'Cairo', 'Four corners padel club, Nasr City, Cairo, Egypt'),
    ('Padel Prestige', 'Court 1', 'Nasr City', 'Cairo', 'Padel Prestige, Nasr City, Cairo, Egypt'),
    ('The Match Padel', 'Court 1', 'Nasr City', 'Cairo', 'The Match Padel, Nasr City, Cairo, Egypt'),
    ('Padel plus', 'Court 1', 'Nasr City', 'Cairo', 'Padel plus, Nasr City, Cairo, Egypt'),
    ('Volt sports hub', 'Court 1', 'Nasr City', 'Cairo', 'Volt sports hub, Nasr City, Cairo, Egypt'),
    ('Padelhood Heliopolis', 'Court 1', 'Heliopolis', 'Cairo', 'Padelhood Heliopolis, Heliopolis, Cairo, Egypt'),
    ('Padel Ace Tolip Plaza', 'Court 1', 'Heliopolis', 'Cairo', 'Padel Ace Tolip Plaza, Heliopolis, Cairo, Egypt'),
    ('Mexico Padel', 'Court 1', 'Heliopolis', 'Cairo', 'Mexico Padel, Heliopolis, Cairo, Egypt'),
    ('Padel box', 'Court 1', 'Heliopolis', 'Cairo', 'Padel box, Heliopolis, Cairo, Egypt'),
    ('District ACE Padel', 'Court 1', 'Heliopolis', 'Cairo', 'District ACE Padel, Heliopolis, Cairo, Egypt'),
    ('Heliopolis Club Padel Court', 'Court 1', 'Heliopolis', 'Cairo', 'Heliopolis Club Padel Court, Heliopolis, Cairo, Egypt'),
    ('SH Padel Heliopolis', 'Court 1', 'Heliopolis', 'Cairo', 'SH Padel Heliopolis, Heliopolis, Cairo, Egypt'),
    ('Padel 101 Academy & Community', 'Court 1', 'New Cairo', 'Cairo', 'Padel 101 Academy & Community, New Cairo, Cairo, Egypt'),
    ('Cairo Padel', 'Court 1', 'New Cairo', 'Cairo', 'Cairo Padel, Park Mall New Cairo / Mountain View Hyde Park, New Cairo, Cairo, Egypt'),
    ('Padel point', 'Court 1', 'New Cairo', 'Cairo', 'Padel point, New Cairo, Cairo, Egypt'),
    ('SR Padel Club New Cairo', 'Court 1', 'New Cairo', 'Cairo', 'SR Padel Club New Cairo, New Cairo, Cairo, Egypt'),
    ('Padel Ace Triumph Luxury Hotel', 'Court 1', 'New Cairo', 'Cairo', 'Padel Ace Triumph Luxury Hotel, New Cairo, Cairo, Egypt'),
    ('Xpadel Riviera Heights', 'Court 1', 'New Cairo', 'Cairo', 'Xpadel Riviera Heights, New Cairo, Cairo, Egypt'),
    ('Padel 15', 'Court 1', 'New Cairo', 'Cairo', 'Padel 15, New Cairo, Cairo, Egypt'),
    ('Co Padel', 'Court 1', 'New Cairo', 'Cairo', 'Co Padel, New Cairo, Cairo, Egypt'),
    ('SR Padel El Zohour Club', 'Court 1', 'New Cairo', 'Cairo', 'SR Padel El Zohour Club, New Cairo, Cairo, Egypt'),
    ('Club 7 Kattameya Hills', 'Court 1', 'New Cairo', 'Cairo', 'Club 7 Kattameya Hills, New Cairo, Cairo, Egypt'),
    ('Go!Padel', 'Court 1', 'New Cairo', 'Cairo', 'Go!Padel, Katameya Heights / Madinaty / El Rehab branches, New Cairo, Cairo, Egypt'),
    ('Dragons Padel', 'Court 1', 'New Cairo', 'Cairo', 'Dragons Padel, New Cairo, Cairo, Egypt'),
    ('SD Padel Tagamoa Heights', 'Court 1', 'New Cairo', 'Cairo', 'SD Padel Tagamoa Heights, New Cairo, Cairo, Egypt'),
    ('Pro Padel Egypt Elseginy riding club Zayed', 'Court 1', 'Sheikh Zayed', 'Giza', 'Pro Padel Egypt Elseginy riding club Zayed, El Seginy Riding Club, Sheikh Zayed, Giza, Egypt'),
    ('13 Padel', 'Court 1', 'Sheikh Zayed', 'Giza', '13 Padel, Sheikh Zayed, Giza, Egypt'),
    ('Padelit', 'Court 1', 'Sheikh Zayed', 'Giza', 'Padelit, Arkan Plaza, Sheikh Zayed, Giza, Egypt'),
    ('Padel Tribe', 'Court 1', 'Sheikh Zayed', 'Giza', 'Padel Tribe, Sheikh Zayed, Giza, Egypt'),
    ('The Match Padel tennis', 'Court 1', 'Sheikh Zayed', 'Giza', 'The Match Padel tennis, Sheikh Zayed, Giza, Egypt'),
    ('Just Padel Academy', 'Court 1', '6th of October', 'Giza', 'Just Padel Academy, 6th of October, Giza, Egypt'),
    ('Padel Beats', 'Court 1', '6th of October', 'Giza', 'Padel Beats, Wahat Road, opposite Dreamland, 6th of October, Giza, Egypt'),
    ('Padel street', 'Court 1', '6th of October', 'Giza', 'Padel street, 6th of October, Giza, Egypt'),
    ('Electro Padel', 'Court 1', '6th of October', 'Giza', 'Electro Padel, 6th of October, Giza, Egypt'),
    ('Square padel', 'Court 1', '6th of October', 'Giza', 'Square padel, 6th of October, Giza, Egypt'),
    ('Elite Smash Padel', 'Court 1', '6th of October', 'Giza', 'Elite Smash Padel, 6th of October, Giza, Egypt'),
    ('Roma padel Cairo', 'Court 1', '6th of October', 'Giza', 'Roma padel Cairo, 6th of October, Giza, Egypt'),
    ('PadelHouse - Shooting Club', 'Court 1', 'Central Cairo & Giza', null, 'PadelHouse - Shooting Club, Egypt'),
    ('Padel league', 'Court 1', 'Central Cairo & Giza', null, 'Padel league, Egypt'),
    ('Padel Plus', 'Court 1', 'Central Cairo & Giza', null, 'Padel Plus, Egypt'),
    ('Al Ahly Padel', 'Court 1', 'Central Cairo & Giza', null, 'Al Ahly Padel, Egypt'),
    ('Golden padel', 'Court 1', 'Central Cairo & Giza', null, 'Golden padel, Egypt'),
    ('Mexico padel', 'Court 1', 'Central Cairo & Giza', null, 'Mexico padel, Egypt'),
    ('Padel Yard MILS', 'Court 1', 'Central Cairo & Giza', null, 'Padel Yard MILS, Egypt'),
    ('Padel Yard', 'Court 1', 'Central Cairo & Giza', null, 'Padel Yard, Egypt'),
    -- ── List 2 ────────────────────────────────────────────────────
    ('JPadel Swan Lake', 'Court 1', 'New Cairo', 'Cairo', 'JPadel Swan Lake, Swan Lake Residence, 1st Settlement, New Cairo, Cairo, Egypt'),
    ('Padel House District 5', 'Court 1', 'New Cairo', 'Cairo', 'Padel House District 5, New Cairo, Cairo, Egypt'),
    ('Katameya Residence Padel', 'Court 1', 'New Cairo', 'Cairo', 'Katameya Residence Padel, New Cairo, Cairo, Egypt'),
    ('Platinum Club Padel', 'Court 1', 'New Cairo', 'Cairo', 'Platinum Club Padel, New Cairo, Cairo, Egypt'),
    ('Mivida Padel Court', 'Court 1', 'New Cairo', 'Cairo', 'Mivida Padel Court, New Cairo, Cairo, Egypt'),
    ('The Lake House Padel', 'Court 1', 'New Cairo', 'Cairo', 'The Lake House Padel, New Cairo, Cairo, Egypt'),
    ('Black Ball Padel', 'Court 1', 'New Cairo', 'Cairo', 'Black Ball Padel, New Cairo, Cairo, Egypt'),
    ('O Padel Club', 'Court 1', 'New Cairo', 'Cairo', 'O Padel Club, New Cairo, Cairo, Egypt'),
    ('The Field Padel Tagamoa', 'Court 1', 'New Cairo', 'Cairo', 'The Field Padel Tagamoa, New Cairo, Cairo, Egypt'),
    ('B-Padel New Cairo', 'Court 1', 'New Cairo', 'Cairo', 'B-Padel New Cairo, New Cairo, Cairo, Egypt'),
    ('Padel Arena Waterway', 'Court 1', 'New Cairo', 'Cairo', 'Padel Arena Waterway, New Cairo, Cairo, Egypt'),
    ('T Padel Katameya', 'Court 1', 'New Cairo', 'Cairo', 'T Padel Katameya, New Cairo, Cairo, Egypt'),
    ('Nadi El Sekka Padel', 'Court 1', 'New Cairo', 'Cairo', 'Nadi El Sekka Padel, New Cairo, Cairo, Egypt'),
    ('Padel Pod New Cairo', 'Court 1', 'New Cairo', 'Cairo', 'Padel Pod New Cairo, New Cairo, Cairo, Egypt'),
    ('Padel Station Tagamoa', 'Court 1', 'New Cairo', 'Cairo', 'Padel Station Tagamoa, New Cairo, Cairo, Egypt'),
    ('Padel One The Orb', 'Court 1', 'Mokattam', 'Cairo', 'Padel One The Orb, The Orb Mall, Mokattam, Cairo, Egypt'),
    ('Padel Gear Mokattam', 'Court 1', 'Mokattam', 'Cairo', 'Padel Gear Mokattam, Mokattam, Cairo, Egypt'),
    ('Maadi British International School Padel', 'Court 1', 'Maadi', 'Cairo', 'Maadi British International School Padel, Maadi, Cairo, Egypt'),
    ('The Padel Base Maadi', 'Court 1', 'Maadi', 'Cairo', 'The Padel Base Maadi, Maadi, Cairo, Egypt'),
    ('Victoria College Padel', 'Court 1', 'Maadi', 'Cairo', 'Victoria College Padel, Maadi, Cairo, Egypt'),
    ('Padel Zone Mokattam', 'Court 1', 'Mokattam', 'Cairo', 'Padel Zone Mokattam, Mokattam, Cairo, Egypt'),
    ('Padel Park Maadi', 'Court 1', 'Maadi', 'Cairo', 'Padel Park Maadi, Maadi, Cairo, Egypt'),
    ('Smash Padel Club Maadi', 'Court 1', 'Maadi', 'Cairo', 'Smash Padel Club Maadi, Maadi, Cairo, Egypt'),
    ('Padel House Beverly Hills', 'Court 1', '6th of October', 'Giza', 'Padel House Beverly Hills, 6th of October, Giza, Egypt'),
    ('ZED Park Padel', 'Court 1', 'Sheikh Zayed', 'Giza', 'ZED Park Padel, Sheikh Zayed, Giza, Egypt'),
    ('Green 6 Padel', 'Court 1', 'Sheikh Zayed', 'Giza', 'Green 6 Padel, Sheikh Zayed, Giza, Egypt'),
    ('G21 City Park Padel', 'Court 1', 'Sheikh Zayed', 'Giza', 'G21 City Park Padel, Sheikh Zayed, Giza, Egypt'),
    ('Arkan Plaza Padel It', 'Court 1', 'Sheikh Zayed', 'Giza', 'Arkan Plaza Padel It, Sheikh Zayed, Giza, Egypt'),
    ('U Padel Sheikh Zayed', 'Court 1', 'Sheikh Zayed', 'Giza', 'U Padel Sheikh Zayed, Sheikh Zayed, Giza, Egypt'),
    ('Palm Hills Padel Court', 'Court 1', '6th of October', 'Giza', 'Palm Hills Padel Court, 6th of October, Giza, Egypt'),
    ('New Giza Sports Club Padel', 'Court 1', '6th of October', 'Giza', 'New Giza Sports Club Padel, 6th of October, Giza, Egypt'),
    ('Padel Gear October', 'Court 1', '6th of October', 'Giza', 'Padel Gear October, 6th of October, Giza, Egypt'),
    ('The Padelers Zayed', 'Court 1', 'Sheikh Zayed', 'Giza', 'The Padelers Zayed, Sheikh Zayed, Giza, Egypt'),
    ('Al Karma Club Padel', 'Court 1', 'Sheikh Zayed', 'Giza', 'Al Karma Club Padel, Sheikh Zayed, Giza, Egypt'),
    ('Nadi El Said October Padel', 'Court 1', '6th of October', 'Giza', 'Nadi El Said October Padel, 6th of October, Giza, Egypt'),
    ('O West Padel', 'Court 1', '6th of October', 'Giza', 'O West Padel, 6th of October, Giza, Egypt'),
    ('U Padel Nozha', 'Court 1', 'Heliopolis', 'Cairo', 'U Padel Nozha, Heliopolis, Cairo, Egypt'),
    ('Padel District Sheraton', 'Court 1', 'Sheraton', 'Cairo', 'Padel District Sheraton, Sheraton, Cairo, Egypt'),
    ('Nadi El Shams Padel', 'Court 1', 'Heliopolis', 'Cairo', 'Nadi El Shams Padel, Heliopolis, Cairo, Egypt'),
    ('Smash Padel Nasr City', 'Court 1', 'Nasr City', 'Cairo', 'Smash Padel Nasr City, Nasr City, Cairo, Egypt'),
    ('Sun City Padel', 'Court 1', 'Sheraton', 'Cairo', 'Sun City Padel, Sheraton, Cairo, Egypt'),
    ('Oasis Padel Heliopolis', 'Court 1', 'Heliopolis', 'Cairo', 'Oasis Padel Heliopolis, Heliopolis, Cairo, Egypt'),
    ('Aero Sport Padel', 'Court 1', 'Heliopolis', 'Cairo', 'Aero Sport Padel, Heliopolis, Cairo, Egypt'),
    ('Dar El Eshara Padel', 'Court 1', 'Nasr City', 'Cairo', 'Dar El Eshara Padel, Nasr City, Cairo, Egypt'),
    ('Padel Ground Sheraton', 'Court 1', 'Sheraton', 'Cairo', 'Padel Ground Sheraton, Sheraton, Cairo, Egypt'),
    ('The Padel Court Nasr City', 'Court 1', 'Nasr City', 'Cairo', 'The Padel Court Nasr City, Nasr City, Cairo, Egypt'),
    ('Gezira Sporting Club Padel', 'Court 1', 'Zamalek', 'Cairo', 'Gezira Sporting Club Padel, Zamalek, Cairo, Egypt'),
    ('Zamalek Padel', 'Court 1', 'Zamalek', 'Cairo', 'Zamalek Padel, Zamalek, Cairo, Egypt'),
    ('Shooting Club Dokki Padel', 'Court 1', 'Dokki', 'Giza', 'Shooting Club Dokki Padel, Dokki, Giza, Egypt'),
    ('Cairo University Padel', 'Court 1', 'Giza', 'Giza', 'Cairo University Padel, Giza, Egypt'),
    ('Tersana Padel Club', 'Court 1', 'Mohandessin', 'Giza', 'Tersana Padel Club, Mohandessin, Giza, Egypt'),
    -- ── List 3 ────────────────────────────────────────────────────
    ('New Capital Sports Hall Padel', 'Court 1', 'New Administrative Capital', 'New Capital', 'New Capital Sports Hall Padel, New Administrative Capital, New Capital, Egypt'),
    ('Almasa Capital Padel', 'Court 1', 'New Administrative Capital', 'New Capital', 'Almasa Capital Padel, New Administrative Capital, New Capital, Egypt'),
    ('Celia Padel Court', 'Court 1', 'New Administrative Capital', 'New Capital', 'Celia Padel Court, New Administrative Capital, New Capital, Egypt'),
    ('Midtown Sky Padel', 'Court 1', 'New Administrative Capital', 'New Capital', 'Midtown Sky Padel, New Administrative Capital, New Capital, Egypt'),
    ('Vinci Padel Club', 'Court 1', 'New Administrative Capital', 'New Capital', 'Vinci Padel Club, New Administrative Capital, New Capital, Egypt'),
    ('Il Bosco Padel Court', 'Court 1', 'New Administrative Capital', 'New Capital', 'Il Bosco Padel Court, New Administrative Capital, New Capital, Egypt'),
    ('La Vista City Padel', 'Court 1', 'New Administrative Capital', 'New Capital', 'La Vista City Padel, New Administrative Capital, New Capital, Egypt'),
    ('Oia Padel Club', 'Court 1', 'New Administrative Capital', 'New Capital', 'Oia Padel Club, New Administrative Capital, New Capital, Egypt'),
    ('The City Valley Padel', 'Court 1', 'New Administrative Capital', 'New Capital', 'The City Valley Padel, New Administrative Capital, New Capital, Egypt'),
    ('Pukha Padel Court', 'Court 1', 'New Administrative Capital', 'New Capital', 'Pukha Padel Court, New Administrative Capital, New Capital, Egypt'),
    ('Armonia Padel', 'Court 1', 'New Administrative Capital', 'New Capital', 'Armonia Padel, New Administrative Capital, New Capital, Egypt'),
    ('R7 District Padel', 'Court 1', 'New Administrative Capital', 'New Capital', 'R7 District Padel, New Administrative Capital, New Capital, Egypt'),
    ('Capital Prime Padel', 'Court 1', 'New Administrative Capital', 'New Capital', 'Capital Prime Padel, New Administrative Capital, New Capital, Egypt'),
    ('Talaat Moustafa Group Padel - New Capital', 'Court 1', 'New Administrative Capital', 'New Capital', 'Talaat Moustafa Group Padel - New Capital, New Administrative Capital, New Capital, Egypt'),
    ('Green River Padel Club', 'Court 1', 'New Administrative Capital', 'New Capital', 'Green River Padel Club, New Administrative Capital, New Capital, Egypt'),
    ('Sports City Padel New Capital', 'Court 1', 'New Administrative Capital', 'New Capital', 'Sports City Padel New Capital, New Administrative Capital, New Capital, Egypt'),
    ('SR Padel Elmostakbal City', 'Court 1', 'Mostakbal City', 'Cairo', 'SR Padel Elmostakbal City, Mostakbal City, Cairo, Egypt'),
    ('Vibes Complex Padel', 'Court 1', 'Mostakbal City', 'Cairo', 'Vibes Complex Padel, Mostakbal City, Cairo, Egypt'),
    ('Bloomfields Padel Court', 'Court 1', 'Mostakbal City', 'Cairo', 'Bloomfields Padel Court, Mostakbal City, Cairo, Egypt'),
    ('Neopolis Padel', 'Court 1', 'Mostakbal City', 'Cairo', 'Neopolis Padel, Mostakbal City, Cairo, Egypt'),
    ('Aria Padel Club', 'Court 1', 'Mostakbal City', 'Cairo', 'Aria Padel Club, Mostakbal City, Cairo, Egypt'),
    ('Padel Co El Shorouk', 'Court 1', 'El Shorouk', 'Cairo', 'Padel Co El Shorouk, El Shorouk City, El Shorouk, Cairo, Egypt'),
    ('Green Hills Club Padel', 'Court 1', 'El Shorouk', 'Cairo', 'Green Hills Club Padel, El Shorouk, Cairo, Egypt'),
    ('Heliopolis Sporting Club El Shorouk', 'Court 1', 'El Shorouk', 'Cairo', 'Heliopolis Sporting Club El Shorouk, El Shorouk, Cairo, Egypt'),
    ('Maadi Club El Shorouk Padel', 'Court 1', 'El Shorouk', 'Cairo', 'Maadi Club El Shorouk Padel, El Shorouk, Cairo, Egypt'),
    ('Badr City Sports Club Padel', 'Court 1', 'Badr City', 'Cairo', 'Badr City Sports Club Padel, Badr City, Cairo, Egypt'),
    ('Russian University Padel Badr', 'Court 1', 'Badr City', 'Cairo', 'Russian University Padel Badr, Badr City, Cairo, Egypt'),
    ('Go Padel Madinaty', 'Court 1', 'Madinaty', 'Cairo', 'Go Padel Madinaty, Madinaty, Cairo, Egypt'),
    ('Madinaty Sports Club Padel', 'Court 1', 'Madinaty', 'Cairo', 'Madinaty Sports Club Padel, Madinaty, Cairo, Egypt'),
    ('Go Padel El Rehab', 'Court 1', 'El Rehab', 'Cairo', 'Go Padel El Rehab, El Rehab, Cairo, Egypt'),
    ('El Rehab Sports Club Padel', 'Court 1', 'El Rehab', 'Cairo', 'El Rehab Sports Club Padel, El Rehab, Cairo, Egypt'),
    ('The Yard Padel Rehab', 'Court 1', 'El Rehab', 'Cairo', 'The Yard Padel Rehab, El Rehab, Cairo, Egypt'),
    ('WePadel Complex', 'Court 1', 'Alexandria', 'Alexandria', 'WePadel Complex, Alexandria, Egypt'),
    ('Smouha Club Padel WePadel', 'Court 1', 'Alexandria', 'Alexandria', 'Smouha Club Padel WePadel, Alexandria, Egypt'),
    ('Alex West Club WePadel', 'Court 1', 'Alexandria', 'Alexandria', 'Alex West Club WePadel, Alexandria, Egypt'),
    ('Kings Yard WePadel', 'Court 1', 'Alexandria', 'Alexandria', 'Kings Yard WePadel, Alexandria, Egypt'),
    ('Zohour Club Padel Alex', 'Court 1', 'Alexandria', 'Alexandria', 'Zohour Club Padel Alex, Alexandria, Egypt'),
    ('The Camp Egypt Padel', 'Court 1', 'Alexandria', 'Alexandria', 'The Camp Egypt Padel, Alexandria, Egypt'),
    ('Padel Dose Amwaj', 'Court 1', 'North Coast', 'North Coast', 'Padel Dose Amwaj, North Coast, Egypt'),
    ('Padel Hub La Vista Bay', 'Court 1', 'North Coast', 'North Coast', 'Padel Hub La Vista Bay, North Coast, Egypt'),
    ('The Rush Caesar Sodic', 'Court 1', 'North Coast', 'North Coast', 'The Rush Caesar Sodic, North Coast, Egypt'),
    ('SR Padel Hacienda Bay', 'Court 1', 'North Coast', 'North Coast', 'SR Padel Hacienda Bay, North Coast, Egypt'),
    ('SR Padel Zoya', 'Court 1', 'North Coast', 'North Coast', 'SR Padel Zoya, North Coast, Egypt'),
    ('SR Padel Cali Coast', 'Court 1', 'North Coast', 'North Coast', 'SR Padel Cali Coast, North Coast, Egypt'),
    ('Coral Hills Resort Padel', 'Court 1', 'North Coast', 'North Coast', 'Coral Hills Resort Padel, North Coast, Egypt'),
    ('Dragon Padel (Marwa Resort)', 'Court 1', 'North Coast', 'North Coast', 'Dragon Padel (Marwa Resort), North Coast, Egypt'),
    ('Somabay Padel Arena', 'Court 1', 'Red Sea', 'Red Sea', 'Somabay Padel Arena, Red Sea, Egypt'),
    ('Yalla Padel Regina Resort', 'Court 1', 'Hurghada', 'Red Sea', 'Yalla Padel Regina Resort, Hurghada, Red Sea, Egypt'),
    ('SR Padel Azha Sokhna', 'Court 1', 'Ain Sokhna', 'Ain Sokhna', 'SR Padel Azha Sokhna, Ain Sokhna, Egypt'),
    ('Porto Sokhna Padel', 'Court 1', 'Ain Sokhna', 'Ain Sokhna', 'Porto Sokhna Padel, Ain Sokhna, Egypt'),
    -- ── List 4 ────────────────────────────────────────────────────
    ('Hayah International Academy', 'Court 1', 'New Cairo', 'Cairo', 'Hayah International Academy, New Cairo, Cairo, Egypt'),
    ('Moon Valley', 'Court 1', 'New Cairo', 'Cairo', 'Moon Valley, New Cairo, Cairo, Egypt'),
    ('Chillout Albanafseg', 'Court 1', 'New Cairo', 'Cairo', 'Chillout Albanafseg, New Cairo, Cairo, Egypt'),
    ('Galleria Moon Valley', 'Court 1', 'New Cairo', 'Cairo', 'Galleria Moon Valley, New Cairo, Cairo, Egypt'),
    ('Katameya Heights', 'Court 1', 'New Cairo', 'Cairo', 'Katameya Heights, New Cairo, Cairo, Egypt'),
    ('Tolip Gardens Hotel - Gardenia', 'Court 1', 'New Cairo', 'Cairo', 'Tolip Gardens Hotel - Gardenia, New Cairo, Cairo, Egypt'),
    ('Tayaran Club', 'Court 1', 'New Cairo', 'Cairo', 'Tayaran Club, New Cairo, Cairo, Egypt'),
    ('Xpadel Club (Choueifat New Cairo)', 'Court 1', 'New Cairo', 'Cairo', 'Xpadel Club (Choueifat New Cairo), New Cairo, Cairo, Egypt'),
    ('Metropolitan School', 'Court 1', 'New Cairo', 'Cairo', 'Metropolitan School, New Cairo, Cairo, Egypt'),
    ('Engineering Club', 'Court 1', 'New Cairo', 'Cairo', 'Engineering Club, New Cairo, Cairo, Egypt'),
    ('The Grand Residence Clubhouse', 'Court 1', 'New Cairo', 'Cairo', 'The Grand Residence Clubhouse, New Cairo, Cairo, Egypt'),
    ('Mirage', 'Court 1', 'New Cairo', 'Cairo', 'Mirage, New Cairo, Cairo, Egypt'),
    ('Nile International College', 'Court 1', 'New Cairo', 'Cairo', 'Nile International College, New Cairo, Cairo, Egypt'),
    ('MFIS', 'Court 1', 'New Cairo', 'Cairo', 'MFIS, New Cairo, Cairo, Egypt'),
    ('Stanford Padel', 'Court 1', 'New Cairo', 'Cairo', 'Stanford Padel, New Cairo, Cairo, Egypt'),
    ('The Royal British International School', 'Court 1', 'New Cairo', 'Cairo', 'The Royal British International School, New Cairo, Cairo, Egypt'),
    ('Revolt', 'Court 1', 'New Cairo', 'Cairo', 'Revolt, New Cairo, Cairo, Egypt'),
    ('Tie Break (Santos Club)', 'Court 1', 'New Cairo', 'Cairo', 'Tie Break (Santos Club), New Cairo, Cairo, Egypt'),
    ('PK1 Palm Hills Kattameya', 'Court 1', 'New Cairo', 'Cairo', 'PK1 Palm Hills Kattameya, New Cairo, Cairo, Egypt'),
    ('Befit Complx, Maxim Country Club', 'Court 1', 'New Cairo', 'Cairo', 'Befit Complx, Maxim Country Club, New Cairo, Cairo, Egypt'),
    ('Jewel Inn New Cairo', 'Court 1', 'New Cairo', 'Cairo', 'Jewel Inn New Cairo, New Cairo, Cairo, Egypt'),
    ('Al-Andalus International School', 'Court 1', 'New Cairo', 'Cairo', 'Al-Andalus International School, New Cairo, Cairo, Egypt'),
    ('Katameya Residence', 'Court 1', 'New Cairo', 'Cairo', 'Katameya Residence, New Cairo, Cairo, Egypt'),
    ('Triumph Luxury Hotel', 'Court 1', 'New Cairo', 'Cairo', 'Triumph Luxury Hotel, New Cairo, Cairo, Egypt'),
    ('Zohour Club', 'Court 1', 'New Cairo', 'Cairo', 'Zohour Club, New Cairo, Cairo, Egypt'),
    ('Hyde Out', 'Court 1', 'New Cairo', 'Cairo', 'Hyde Out, New Cairo, Cairo, Egypt'),
    ('Royal Club', 'Court 1', 'New Cairo', 'Cairo', 'Royal Club, New Cairo, Cairo, Egypt'),
    ('SR Padel Club', 'Court 1', 'New Cairo', 'Cairo', 'SR Padel Club, New Cairo, Cairo, Egypt')
)
-- Insert only what isn't already there. Matching is case- and
-- whitespace-insensitive so a court added by hand in the console isn't
-- duplicated by a stray capital letter.
insert into public.courts (venue_name, name, area, city, address, indoor)
select s.venue_name,
       s.name,
       nullif(s.area, ''),
       coalesce(nullif(s.city, ''), 'Cairo'),   -- city is NOT NULL on live
       nullif(s.address, ''),
       false
from seed s
where not exists (
  select 1 from public.courts c
  where lower(btrim(c.venue_name)) = lower(btrim(s.venue_name))
    and lower(btrim(c.name))       = lower(btrim(s.name))
);

-- ── verify ─────────────────────────────────────────────────────────────────
-- Run this after the delta. It reports what landed and what still needs a
-- human, and writes nothing.
do $$
declare
  v_total   int;
  v_nocoord int;
  v_giza    int;
begin
  select count(*) into v_total   from public.courts;
  select count(*) into v_nocoord from public.courts where lat is null or lng is null;
  select count(*) into v_giza    from public.courts where area = 'Central Cairo & Giza';

  raise notice 'courts total ............ %', v_total;
  raise notice 'without coordinates ..... % (address fallback covers Directions)', v_nocoord;
  raise notice 'area still a region ..... % (listed below, need a district)', v_giza;
end $$;

-- The rows whose city was defaulted because the source area was a region.
-- Fix the area first (Dokki / Zamalek / Mohandessin / …), then the city.
select id, venue_name, area, city
from public.courts
where area = 'Central Cairo & Giza'
order by venue_name;

-- Exact duplicate venue names. Catches a court seeded here that was also
-- added by hand under a different court name, plus the three names that
-- appear twice in the source lists ('Padel Yard', 'Padel plus',
-- 'Mexico Padel' — each once in a district and once under the old
-- 'Central Cairo & Giza' bucket).
select venue_name, count(*) as n_rows, string_agg(coalesce(area, '?'), ' | ') as areas
from public.courts
group by venue_name
having count(*) > 1
order by venue_name;

-- NEAR-duplicates cannot be found in SQL — 'Triumph Luxury Hotel' and
-- 'Padel Ace Triumph Luxury Hotel' are the same place under two names, and
-- no GROUP BY sees that. The merged spreadsheet flags 13 such pairs in its
-- 'Needs your attention' column; that is the list to work from. Everything
-- was inserted rather than dropped, because some of those pairs are
-- genuinely separate branches.
