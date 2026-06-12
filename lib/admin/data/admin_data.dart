library;

// ── Models ────────────────────────────────────────────────────────

class AdminUser {
  final String name, role, avatar, email;
  const AdminUser(this.name, this.role, this.avatar, this.email);
}

class Kpi {
  final String label, value, foot;
  final double? delta;
  const Kpi(this.label, this.value, {this.foot = '', this.delta});
}

class AdminPlayer {
  final String id, name, email, avatar, division, metal, status, city, lastActive;
  final int elo, rank, played, wins, losses;
  final double level;
  const AdminPlayer({
    required this.id,
    required this.name,
    required this.email,
    required this.avatar,
    required this.division,
    required this.metal,
    required this.status,
    required this.city,
    required this.lastActive,
    required this.elo,
    required this.rank,
    required this.played,
    required this.wins,
    required this.losses,
    required this.level,
  });
  int get winRate => played == 0 ? 0 : ((wins / played) * 100).round();
}

class InventoryItem {
  String id, name, brand, cat, status;
  int price, cost, stock, sold, reorder;
  bool visible;
  InventoryItem({
    required this.id,
    required this.name,
    required this.brand,
    required this.cat,
    required this.price,
    required this.cost,
    required this.stock,
    required this.sold,
    this.reorder = 6,
    this.visible = true,
  }) : status = stock == 0
            ? 'out'
            : stock <= reorder
                ? 'low'
                : 'in';
  int get margin => price - cost;
  void recompute() => status = stock == 0
      ? 'out'
      : stock <= reorder
          ? 'low'
          : 'in';
}

class AdminTournament {
  String id, name, venue, city, dates, month, day, prize, status;
  int entry, spots, filled, minElo;
  AdminTournament({
    required this.id,
    required this.name,
    required this.venue,
    required this.city,
    required this.dates,
    required this.month,
    required this.day,
    required this.prize,
    required this.status,
    required this.entry,
    required this.spots,
    required this.filled,
    required this.minElo,
  });
  int get left => spots - filled;
  int get revenue => filled * entry;
  double get reg => spots == 0 ? 0 : filled / spots;
}

class RepairRequest {
  String id, player, avatar, racket, service, issue, submitted, status, eta;
  int photos;
  int? quote;
  RepairRequest({
    required this.id,
    required this.player,
    required this.avatar,
    required this.racket,
    required this.service,
    required this.issue,
    required this.submitted,
    required this.status,
    this.eta = '',
    this.photos = 1,
    this.quote,
  });
}

class TradeRequest {
  String id, player, avatar, racket, condition, submitted, status, note;
  int askValue, photos;
  int? offer;
  TradeRequest({
    required this.id,
    required this.player,
    required this.avatar,
    required this.racket,
    required this.condition,
    required this.submitted,
    required this.status,
    required this.note,
    required this.askValue,
    this.photos = 2,
    this.offer,
  });
}

class Venue {
  String id, club, area, status;
  int courts, km, pricePerHr, bookings7d;
  double rating;
  bool indoor;
  Venue({
    required this.id,
    required this.club,
    required this.area,
    required this.status,
    required this.courts,
    required this.km,
    required this.pricePerHr,
    required this.bookings7d,
    required this.rating,
    this.indoor = true,
  });
}

class Activity {
  final String icon, text, meta, time, accent;
  const Activity(this.icon, this.text, this.meta, this.time, this.accent);
}

// ── Mock content ──────────────────────────────────────────────────

class AdminData {
  AdminData._();

  static const String adminEmail = 'admin@padelegypt.com';
  static const admin = AdminUser('Mona Saleh', 'Super Admin', 'MS', adminEmail);

  static String egp(int n) {
    final s = n.toString();
    final b = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return 'EGP ${b.toString()}';
  }

  static String egpShort(int n) => n >= 1000
      ? 'EGP ${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}k'
      : 'EGP $n';

  static const kpis = <Kpi>[
    Kpi('Total players', '312', delta: 6.4, foot: '+18 new this week'),
    Kpi('Matches / week', '327', delta: 8.1, foot: '184 played today'),
    Kpi('Revenue · June', 'EGP 233k', delta: 14.2, foot: 'store + entries'),
    Kpi('Needs attention', '5', foot: '3 disputes · 2 refunds'),
  ];

  static const revenueTrend = [148, 162, 155, 178, 191, 184, 206, 233];
  static const matchesByDay = [38, 44, 51, 47, 62, 58, 27];
  static const dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  static const divisionSplit = [
    ['A', 'Elite', 'elite', '24'],
    ['B', 'Gold', 'gold', '58'],
    ['C', 'Silver', 'silver', '96'],
    ['D', 'Bronze', 'bronze', '134'],
  ];

  static const activity = <Activity>[
    Activity('shield', 'Match M-4790 disputed', 'Maadi Club · needs review', '8m', 'danger'),
    Activity('cart', 'Order #PE-1840 placed', 'Adidas Adipower · EGP 6,100', '21m', 'primary'),
    Activity('person', 'Yara Selim signed up', 'New player · Alexandria', '34m', 'info'),
    Activity('trophy', 'Cairo Championship — 3 spots left', '13 pairs registered', '1h', 'gold'),
    Activity('swap', 'Refund requested · #PE-1839', 'EGP 3,400 · Nike Court', '2h', 'green'),
    Activity('medal', 'Sayed Roushdy promoted to Division A', 'ELO 2,150 → Elite', '3h', 'primary'),
  ];

  static final players = <AdminPlayer>[
    _p('PL-1001', 'Sayed Roushdy', 'SR', 2210, 1, 'A', 'elite', 'active', 'New Cairo', '2m', 88, 61, 5.6),
    _p('PL-1002', 'Ahmed Hassan', 'AH', 2150, 2, 'A', 'elite', 'active', 'Cairo', '18m', 74, 50, 5.3),
    _p('PL-1003', 'Karim Hassan', 'KH', 2080, 3, 'A', 'elite', 'active', 'Maadi', '1h', 92, 60, 5.1),
    _p('PL-1004', 'Omar Mostafa', 'OM', 1980, 4, 'B', 'gold', 'active', 'Giza', '3h', 67, 41, 4.6),
    _p('PL-1005', 'Tarek Ali', 'TA', 1875, 5, 'B', 'gold', 'flagged', 'Heliopolis', 'Today', 55, 31, 4.2),
    _p('PL-1006', 'Laila Mansour', 'LM', 1760, 6, 'B', 'gold', 'active', 'Alexandria', '2d', 48, 27, 3.9),
    _p('PL-1007', 'Yara Selim', 'YS', 1520, 7, 'C', 'silver', 'unverified', 'Alexandria', '5d', 12, 6, 2.8),
    _p('PL-1008', 'Mostafa Adel', 'MA', 1410, 8, 'C', 'silver', 'active', '6th October', '1h', 33, 18, 2.4),
    _p('PL-1009', 'Dina Fouad', 'DF', 1180, 9, 'D', 'bronze', 'active', 'Sheikh Zayed', 'Yesterday', 21, 9, 1.6),
    _p('PL-1010', 'Ziad Refaat', 'ZR', 980, 10, 'D', 'bronze', 'banned', 'Cairo', '2d', 8, 2, 1.1),
  ];

  static AdminPlayer _p(String id, String name, String av, int elo, int rank,
          String div, String metal, String status, String city, String last,
          int played, int wins, double level) =>
      AdminPlayer(
        id: id,
        name: name,
        email: '${name.toLowerCase().replaceAll(' ', '.')}@gmail.com',
        avatar: av,
        division: 'Division $div',
        metal: metal,
        status: status,
        city: city,
        lastActive: last,
        elo: elo,
        rank: rank,
        played: played,
        wins: wins,
        losses: played - wins,
        level: level,
      );

  static final inventory = <InventoryItem>[
    InventoryItem(id: 'SKU-7001', name: 'Bela Pro V3 Padel', brand: 'Nox', cat: 'Rackets', price: 14500, cost: 9200, stock: 1, sold: 38),
    InventoryItem(id: 'SKU-7002', name: 'Blade Pro V3 Padel', brand: 'Nox', cat: 'Rackets', price: 14500, cost: 9200, stock: 0, sold: 41),
    InventoryItem(id: 'SKU-7003', name: 'AT10 Genius 18K', brand: 'Nox', cat: 'Rackets', price: 11900, cost: 7600, stock: 3, sold: 52),
    InventoryItem(id: 'SKU-7004', name: 'Premier Padel 3-Ball Can', brand: 'Wilson', cat: 'Balls', price: 390, cost: 230, stock: 24, sold: 180),
    InventoryItem(id: 'SKU-7005', name: 'Speed 3-Ball Can', brand: 'Wilson', cat: 'Balls', price: 450, cost: 270, stock: 24, sold: 142),
    InventoryItem(id: 'SKU-7006', name: 'Bela Tour Red/Black Sneakers', brand: 'Wilson', cat: 'Shoes', price: 8500, cost: 5400, stock: 4, sold: 27),
    InventoryItem(id: 'SKU-7007', name: 'Adipower Team Shoes', brand: 'Adidas', cat: 'Shoes', price: 6100, cost: 3900, stock: 14, sold: 63),
    InventoryItem(id: 'SKU-7008', name: 'High Profile OverGrip ×12', brand: 'Wilson', cat: 'Accessories', price: 130, cost: 72, stock: 120, sold: 210),
    InventoryItem(id: 'SKU-7009', name: 'Pro Tour Padel Bag', brand: 'Adidas', cat: 'Accessories', price: 3400, cost: 2050, stock: 9, sold: 44),
  ];

  static const productCats = ['All', 'Rackets', 'Shoes', 'Apparel', 'Balls', 'Accessories'];

  static final tournaments = <AdminTournament>[
    AdminTournament(id: 'TR-300', name: 'Nile Padel Open', venue: 'Gezira Sporting Club', city: 'Cairo', dates: 'Jun 15 – 18', month: 'JUN', day: '15', prize: 'EGP 10,000', status: 'Open', entry: 800, spots: 16, filled: 13, minElo: 1800),
    AdminTournament(id: 'TR-301', name: 'Cairo Championship', venue: 'Katameya Heights', city: 'New Cairo', dates: 'Jun 22 – 25', month: 'JUN', day: '22', prize: 'EGP 15,000', status: 'Open', entry: 1000, spots: 24, filled: 21, minElo: 2000),
    AdminTournament(id: 'TR-302', name: 'Maadi Weekend Cup', venue: 'Maadi Club', city: 'Maadi', dates: 'Jun 8 – 9', month: 'JUN', day: '08', prize: 'EGP 5,000', status: 'Full', entry: 500, spots: 16, filled: 16, minElo: 1400),
    AdminTournament(id: 'TR-303', name: 'Alexandria Summer Slam', venue: 'Smouha Club', city: 'Alexandria', dates: 'Jul 2 – 5', month: 'JUL', day: '02', prize: 'EGP 8,000', status: 'Upcoming', entry: 700, spots: 20, filled: 6, minElo: 1600),
    AdminTournament(id: 'TR-304', name: 'Mixed Doubles Night', venue: 'Palm Hills', city: 'Giza', dates: 'May 28', month: 'MAY', day: '28', prize: 'EGP 4,000', status: 'Completed', entry: 400, spots: 16, filled: 16, minElo: 1200),
  ];

  static final repairs = <RepairRequest>[
    RepairRequest(id: 'RR-2041', player: 'Karim Hassan', avatar: 'KH', racket: 'Adidas Metalbone 3.3', service: 'Frame crack repair', issue: 'Hairline crack at 2 o’clock, started after a smash. Still playable but spreading.', submitted: '2h ago', status: 'new', photos: 2),
    RepairRequest(id: 'RR-2039', player: 'Laila Mansour', avatar: 'LM', racket: 'Nox AT10 Genius', service: 'Grommet + bumper replace', issue: 'Bumper guard worn through, two grommets missing on the head.', submitted: '6h ago', status: 'new', photos: 3),
    RepairRequest(id: 'RR-2034', player: 'Omar Mostafa', avatar: 'OM', racket: 'Bullpadel Vertex 03', service: 'Regrip + balance', issue: 'Wants an overgrip refresh and 2g of weight added to the head.', submitted: '1d ago', status: 'quoted', quote: 450, eta: '2 days'),
    RepairRequest(id: 'RR-2030', player: 'Sayed Roushdy', avatar: 'SR', racket: 'Head Delta Pro', service: 'Core foam repair', issue: 'Dead spot near the throat, suspect EVA core compression.', submitted: '2d ago', status: 'in_repair', quote: 820, eta: 'Tomorrow'),
    RepairRequest(id: 'RR-2028', player: 'Yara Selim', avatar: 'YS', racket: 'Wilson Bela Pro', service: 'Frame crack repair', issue: 'Crack along the bottom bridge after a court collision.', submitted: '3d ago', status: 'ready', quote: 690, eta: 'Ready'),
  ];

  static final trades = <TradeRequest>[
    TradeRequest(id: 'TD-559', player: 'Omar Mostafa', avatar: 'OM', racket: 'Head Delta Pro 2023', condition: 'Good', askValue: 3500, submitted: '4h ago', status: 'new', note: 'Light wear, original grip, no cracks.', photos: 3),
    TradeRequest(id: 'TD-557', player: 'Marwan Tawfik', avatar: 'MT', racket: 'Adidas Metalbone', condition: 'Fair', askValue: 2800, submitted: '1d ago', status: 'new', note: 'Some scuffs on the frame, plays fine.', photos: 2),
    TradeRequest(id: 'TD-552', player: 'Hana Ezz', avatar: 'HE', racket: 'Nox ML10 Pro Cup', condition: 'Good', askValue: 4200, submitted: '2d ago', status: 'offered', offer: 3600, note: 'Barely used, boxed.', photos: 4),
    TradeRequest(id: 'TD-548', player: 'Ziad Refaat', avatar: 'ZR', racket: 'Bullpadel Vertex', condition: 'Worn', askValue: 1500, submitted: '4d ago', status: 'accepted', offer: 1200, note: 'Heavy use, trading toward a Nox.', photos: 2),
  ];

  static final venues = <Venue>[
    Venue(id: 'CT-200', club: 'Gezira Sporting Club', area: 'Zamalek', status: 'active', courts: 4, km: 3, pricePerHr: 280, bookings7d: 142, rating: 4.8),
    Venue(id: 'CT-201', club: 'Katameya Heights', area: 'New Cairo', status: 'active', courts: 6, km: 12, pricePerHr: 320, bookings7d: 168, rating: 4.7, indoor: false),
    Venue(id: 'CT-202', club: 'Maadi Club', area: 'Maadi', status: 'maintenance', courts: 3, km: 8, pricePerHr: 240, bookings7d: 40, rating: 4.4),
    Venue(id: 'CT-203', club: 'Palm Hills', area: 'Giza', status: 'active', courts: 5, km: 18, pricePerHr: 260, bookings7d: 96, rating: 4.5, indoor: false),
    Venue(id: 'CT-204', club: 'Smouha Club', area: 'Alexandria', status: 'active', courts: 4, km: 220, pricePerHr: 220, bookings7d: 78, rating: 4.6),
  ];
}
