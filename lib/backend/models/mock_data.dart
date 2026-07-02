/// Plain data models + mock content. Mirrors app/data.js from the prototype.
/// Swap these for your real models / API responses.
library;

class Player {
  final String initials, name, tier;
  final int elo;
  const Player(this.initials, this.name, this.tier, this.elo);
}

class MatchInfo {
  final String type, court, date, time, by, bi;
  final bool mine;
  final int players, max, minElo;
  const MatchInfo({
    required this.type,
    required this.court,
    required this.date,
    required this.time,
    required this.by,
    required this.bi,
    this.mine = false,
    required this.players,
    required this.max,
    this.minElo = 0,
  });
  bool get full => players >= max;
  bool get competitive => type == 'Competitive';
}

class RankRow {
  final int rank;
  final String name, bi, tier;
  final int elo, trend;
  final bool me;
  const RankRow(this.rank, this.name, this.bi, this.tier, this.elo, this.trend,
      {this.me = false});
}

class Tournament {
  final String name, dates, prize, status;
  final int spots, left;
  final List<String> cats;
  // Enriched detail fields (used by TournamentDetailScreen).
  final String venue, city, format, sets, about, month, day;
  final int entry, minElo;
  final List<String> ranks;
  const Tournament(this.name, this.dates, this.prize, this.spots, this.left,
      this.cats, this.status,
      {this.venue = '',
      this.city = '',
      this.format = 'Doubles · Double Elimination',
      this.sets = 'Best of 3 sets',
      this.about = '',
      this.month = '',
      this.day = '',
      this.entry = 0,
      this.minElo = 0,
      this.ranks = const []});
}

/// A potential doubles partner (search results when creating a match / registering).
class Partner {
  final String bi, name, tier, hand;
  final int elo, mutual;
  const Partner(this.bi, this.name, this.tier, this.elo, this.hand, this.mutual);
}

/// One seeded pair in a knockout bracket preview.
class BracketTeam {
  final String p1, p2, bi;
  final int seed;
  final bool me;
  const BracketTeam(this.p1, this.p2, this.bi, this.seed, {this.me = false});
}

class Product {
  final String brand, name, cat;
  final int price, reviews;
  final double rating;
  final bool featured, isNew;
  final int discount;
  final String id; // DB row id ('' for mock items)
  const Product(this.brand, this.name, this.cat, this.price, this.rating,
      this.reviews,
      {this.featured = false, this.isNew = false, this.discount = 0, this.id = ''});
  int get discounted =>
      discount > 0 ? (price * (100 - discount) / 100).round() : price;
}

class Court {
  final String name, area;
  final double km, x, y; // x/y are % positions on the map preview
  const Court(this.name, this.area, this.km, this.x, this.y);
}

/// A mutable cart line item.
class CartLine {
  final Product product;
  int qty;
  CartLine(this.product, {this.qty = 1});
  int get lineTotal => product.discounted * qty;
}

class RecentMatch {
  final bool won;
  final String opp, score, date, type;
  const RecentMatch(this.won, this.opp, this.score, this.date, this.type);
}

class Achievement {
  final IconKind icon;
  final String label, tier;
  const Achievement(this.icon, this.label, this.tier);
}

enum IconKind { trophy, fire, medal, bolt, crown }

/// ───────────────────────── MOCK DATA ─────────────────────────
class MockData {
  MockData._();

  static const me = Player('KH', 'Karim Hassan', 'Gold', 1847);
  static const String city = 'Cairo, Egypt';
  static const String memberSince = 'Jan 2024';

  // Performance
  static const int rank = 12;
  static const int elo = 1847;
  static const int toNext = 153;
  static const double progress = 1847 / 2000;
  static const int played = 78, wins = 47, losses = 31, streak = 5;
  static const String winRate = '60%';

  static const nextOpp = Player('AM', 'Ahmed', 'Gold', 1820);

  static const eloHistory = <int>[
    1694, 1712, 1688, 1735, 1760, 1748, 1779, 1801, 1788, 1822, 1839, 1847
  ];

  static const matches = <MatchInfo>[
    MatchInfo(type: 'Competitive', court: 'Gezira Club — Court 2', date: 'Today', time: '6:00 PM', by: 'Omar K.', bi: 'OK', players: 3, max: 4, minElo: 1500),
    MatchInfo(type: 'Casual', court: 'New Cairo Padel Club', date: 'Today', time: '8:00 PM', by: 'You', bi: 'KH', mine: true, players: 2, max: 4),
    MatchInfo(type: 'Competitive', court: 'Maadi Club', date: 'Tomorrow', time: '7:00 AM', by: 'Ahmed R.', bi: 'AR', players: 4, max: 4, minElo: 1800),
    MatchInfo(type: 'Casual', court: 'Katameya Heights', date: 'Tomorrow', time: '6:00 PM', by: 'Youssef M.', bi: 'YM', players: 1, max: 4),
    MatchInfo(type: 'Competitive', court: 'Palm Hills — Court 1', date: 'Friday', time: '9:00 PM', by: 'Rami S.', bi: 'RS', players: 3, max: 4, minElo: 1500),
    MatchInfo(type: 'Casual', court: 'Smash Padel — Heliopolis', date: 'Saturday', time: '10:00 AM', by: 'Tarek A.', bi: 'TA', players: 2, max: 4),
  ];

  static const podium = <RankRow>[
    RankRow(1, 'Ahmed Hassan', 'AH', 'Platinum', 2450, 0),
    RankRow(2, 'Rami Samir', 'RS', 'Platinum', 2280, 0),
    RankRow(3, 'Youssef Khalil', 'YK', 'Gold', 2100, 0),
  ];

  static const leaderboard = <RankRow>[
    RankRow(4, 'Omar Mostafa', 'OM', 'Gold', 2050, -1),
    RankRow(5, 'Tarek Ali', 'TA', 'Gold', 1980, 1),
    RankRow(6, 'Mohamed Nasser', 'MN', 'Gold', 1940, 0),
    RankRow(7, 'Khaled Ibrahim', 'KI', 'Gold', 1920, 1),
    RankRow(8, 'Sherif Youssef', 'SY', 'Silver', 1880, -1),
    RankRow(9, 'Amr Gamal', 'AG', 'Silver', 1870, 0),
    RankRow(10, 'Hassan Fawzy', 'HF', 'Gold', 1860, 1),
    RankRow(11, 'Adel Mansour', 'AM', 'Gold', 1855, -1),
    RankRow(12, 'Karim Hassan', 'KH', 'Gold', 1847, 1, me: true),
    RankRow(13, 'Nader Samy', 'NS', 'Silver', 1820, 0),
    RankRow(14, 'Samir Lotfy', 'SL', 'Silver', 1800, -1),
    RankRow(15, 'Walid Hassan', 'WH', 'Bronze', 1780, 1),
  ];

  static const tournaments = <Tournament>[
    Tournament('Nile Padel Open', 'June 15 – 18', 'EGP 10,000', 32, 12, ["Men's Pro", "Women's Am"], 'Open',
        venue: 'Gezira Sporting Club', city: 'Zamalek, Cairo', entry: 800, month: 'JUN', day: '15', minElo: 1600, ranks: ['Gold', 'Platinum'],
        about: "Cairo's flagship summer open. Double-elimination knockout — every pair is guaranteed at least two matches before they're out. Bring a partner or find one in-app."),
    Tournament('Cairo Championship', 'July 1 – 3', 'EGP 5,000', 16, 3, ["Men's Am"], 'Open',
        venue: 'Wadi Degla Club', city: 'Maadi, Cairo', entry: 500, month: 'JUL', day: '01', minElo: 1200, ranks: ['Silver', 'Gold'],
        about: 'Amateur-friendly championship for rising pairs. A relaxed, social bracket with a competitive edge — perfect for your first registered tournament.'),
    Tournament('Alexandria Open', 'July 20 – 22', 'EGP 7,500', 32, 20, ['Open', 'Mixed'], 'Upcoming',
        venue: 'Smouha Sporting Club', city: 'Smouha, Alexandria', entry: 650, month: 'JUL', day: '20', minElo: 1000, ranks: ['Bronze', 'Silver', 'Gold'],
        about: 'Coastal open welcoming all levels and mixed pairs. Two brackets running in parallel under the Mediterranean breeze.'),
    Tournament('Pyramids Cup', 'Aug 10 – 12', 'EGP 15,000', 32, 0, ["Men's Pro", "Women's Pro"], 'Full',
        venue: 'Palm Hills Sporting', city: '6th October, Giza', entry: 1200, month: 'AUG', day: '10', minElo: 2000, ranks: ['Platinum', 'Diamond'],
        about: 'The premier pro invitational. The biggest purse on the calendar and the deepest field — registration is closed.'),
    Tournament('Sharm Padel Classic', 'Sep 5 – 7', 'EGP 8,000', 24, 24, ['Mixed', "Men's Am"], 'Upcoming',
        venue: 'Soho Square Courts', city: 'Sharm El Sheikh', entry: 700, month: 'SEP', day: '05', minElo: 1200, ranks: ['Silver', 'Gold'],
        about: 'End-of-season getaway tournament on the Red Sea. Play hard, stay for the weekend.'),
  ];

  // Doubles pairs seeding the knockout bracket preview.
  static const bracketTeams = <BracketTeam>[
    BracketTeam('A. Hassan', 'R. Samir', 'AH', 1),
    BracketTeam('O. Mostafa', 'T. Ali', 'OM', 8),
    BracketTeam('M. Nasser', 'K. Ibrahim', 'MN', 4),
    BracketTeam('S. Youssef', 'A. Gamal', 'SY', 5),
    BracketTeam('H. Fawzy', 'A. Mansour', 'HF', 3),
    BracketTeam('You', '—', 'KH', 6, me: true),
    BracketTeam('N. Samy', 'S. Lotfy', 'NS', 2),
    BracketTeam('W. Hassan', 'Y. Khalil', 'WH', 7),
  ];

  // Potential doubles partners (search to team up).
  static const partners = <Partner>[
    Partner('OA', 'Omar Adel', 'Gold', 1654, 'Right · Backhand', 4),
    Partner('SR', 'Sayed Roushdy', 'Platinum', 2150, 'Left · Aggressive', 2),
    Partner('HM', 'Hassan Maher', 'Gold', 1780, 'Right · All-court', 7),
    Partner('MH', 'Mohamed Helmy', 'Silver', 1320, 'Right · Defensive', 1),
    Partner('TA', 'Tarek Ali', 'Gold', 1980, 'Right · Net play', 5),
    Partner('AG', 'Amr Gamal', 'Silver', 1870, 'Left · Counter', 3),
    Partner('KI', 'Khaled Ibrahim', 'Gold', 1920, 'Right · Power', 6),
  ];

  static const productCats = <String>['All', 'Rackets', 'Shoes', 'Apparel', 'Accessories', 'Balls'];

  static const products = <Product>[
    Product('Adidas', 'Adipower Ctrl 3.2', 'Rackets', 6100, 4.9, 128, featured: true, discount: 15),
    Product('Babolat', 'Viper Carbon', 'Rackets', 4500, 4.8, 94),
    Product('Head', 'Gravity Motion', 'Rackets', 3800, 4.6, 67),
    Product('Nox', 'ML10 Pro Cup', 'Rackets', 4800, 4.8, 112, isNew: true),
    Product('Bullpadel', 'Vertex 03', 'Rackets', 3600, 4.6, 45),
    Product('Wilson', 'Bela Pro V2', 'Rackets', 4100, 4.7, 83),
    Product('Asics', 'Gel-Padel Pro 5', 'Shoes', 2400, 4.5, 56, discount: 10),
    Product('Nike', 'Court Air Max Volley', 'Shoes', 3400, 4.4, 38),
    Product('Adidas', 'Barricade Padel', 'Shoes', 2800, 4.6, 71, isNew: true),
    Product('Tecnifibre', 'Squadra Tee', 'Apparel', 1800, 4.3, 22),
    Product('Head', 'Performance Shorts Set', 'Apparel', 3000, 4.5, 31, discount: 20),
    Product('Wilson', 'Padel Balls × 3', 'Balls', 180, 4.7, 203),
    Product('Babolat', 'Gold Padel Balls × 3', 'Balls', 220, 4.8, 156),
    Product('Babolat', 'Tour Backpack', 'Accessories', 950, 4.5, 44),
    Product('Adidas', 'Padel Overgrip × 3', 'Accessories', 120, 4.6, 89),
  ];

  static const courts = <Court>[
    Court('Gezira Club — Court 2', 'Zamalek', 2.1, 38, 46),
    Court('Gezira Club — Court 1', 'Zamalek', 2.2, 36, 44),
    Court('Maadi Club', 'Maadi', 7.4, 52, 78),
    Court('New Cairo Padel Club', 'New Cairo', 12.6, 80, 40),
    Court('Katameya Heights', 'New Cairo', 15.2, 86, 56),
    Court('Palm Hills — Court 1', '6th October', 21.0, 12, 60),
    Court('Smash Padel — Heliopolis', 'Heliopolis', 9.8, 64, 22),
    Court('Wadi Degla Club', 'Maadi', 8.3, 56, 80),
    Court('Zed Park Padel', 'Sheikh Zayed', 18.5, 8, 48),
    Court('Nile Padel — Zamalek', 'Zamalek', 2.6, 34, 50),
  ];

  static const recent = <RecentMatch>[
    RecentMatch(true, 'Ahmed M.', '6-3, 6-4', 'May 25', 'Competitive'),
    RecentMatch(false, 'Rami K.', '5-7, 4-6', 'May 22', 'Competitive'),
    RecentMatch(true, 'Youssef S.', '7-5, 6-3', 'May 18', 'Casual'),
  ];

  static const achievements = <Achievement>[
    Achievement(IconKind.trophy, 'First Win', 'gold'),
    Achievement(IconKind.fire, '5 Streak', 'accent'),
    Achievement(IconKind.medal, 'Top 15', 'primary'),
    Achievement(IconKind.bolt, 'Rising Star', 'platinum'),
    Achievement(IconKind.crown, 'Finalist', 'diamond'),
  ];

  static String egp(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return 'EGP $buf';
  }
}
