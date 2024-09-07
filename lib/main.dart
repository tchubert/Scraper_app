import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:clipboard/clipboard.dart';
import 'package:html/parser.dart'; // for parsing HTML
import 'package:workmanager/workmanager.dart';

void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    // Führe hier den Code zum Scraping aus und sende Benachrichtigungen, falls neue Inserate gefunden werden
    FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initializationSettings =
        InitializationSettings(android: initializationSettingsAndroid);
    await flutterLocalNotificationsPlugin.initialize(initializationSettings);

    // Beispielbenachrichtigung
    const AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails('your_channel_id', 'your_channel_name',
            channelDescription: 'your_channel_description',
            importance: Importance.max,
            priority: Priority.high);
    const NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);

    await flutterLocalNotificationsPlugin.show(
      0,
      'Neue Anzeige gefunden',
      'Schau jetzt nach und sei unter den Ersten.',
      platformChannelSpecifics,
    );

    // Returniere true, um den Hintergrundtask erfolgreich zu beenden
    return Future.value(true);
  });
}


void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // WorkManager initialisieren
  Workmanager().initialize(callbackDispatcher, isInDebugMode: false);  // <---- Neu

  // Hintergrund-Aufgabe alle 15 Minuten registrieren
  Workmanager().registerPeriodicTask(
    "1",
    "scrapeTask",  // Name des Tasks
    frequency: const Duration(minutes: 15),  // <---- Neu
    inputData: {'city': 'Berlin'},  // Beispiel: Daten an den Task übergeben (optional)
  );

  runApp(const WGGesuchtApp());
}




class WGGesuchtApp extends StatelessWidget {
  const WGGesuchtApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WG Gesucht Tracker',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSwatch().copyWith(
          primary: const Color(0xFF184A1E), // Neues Grün für die Hauptfarbe
          secondary: const Color(0xFFF5F5DC), // Neues Beige für den Karten-Hintergrund
        ),
        scaffoldBackgroundColor: Colors.white,
        textTheme: const TextTheme(
          headlineLarge: TextStyle(
            fontSize: 36, fontWeight: FontWeight.bold, color: Color(0xFF184A1E),
          ),
          titleLarge: TextStyle(
            fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF184A1E),
          ),
          bodyMedium: TextStyle(fontSize: 14, fontFamily: 'Roboto', color: Colors.black),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF184A1E),
            foregroundColor: Colors.white,
            elevation: 8,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF184A1E),
          titleTextStyle: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
        ),
        iconTheme: const IconThemeData(color: Color(0xFF184A1E)),
        cardTheme: CardTheme(
          color: const Color(0xFFF5F5DC),
          elevation: 8,
          margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  final PageController _pageController = PageController(initialPage: 1);
  bool _filtersSet = false;
  bool _isFiltersCollapsed = true; 
  List<Map<String, dynamic>> favorites = [];
  List<dynamic> searchResults = [];
  Timer? _searchTimer;
  int _refreshInterval = 5;
  FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
  Map<String, dynamic>? _activeFilters;
  bool _filtersActive = false;
  final Map<int, bool> _expandedCards = {};
  AnimationController? _animationController;
  int _newListingsCount = 0;
  final bool _viewedListings = false;
  Duration _timeRemaining = const Duration(); // Verbleibende Zeit bis zur Aktualisierung
  Timer? _countdownTimer;

   void _toggleFilterCollapse(bool isCollapsed) {  // NEU: Funktion, um den Zustand zu ändern
    setState(() {
      _isFiltersCollapsed = isCollapsed;
    });
  }

  @override
  void initState() {
    super.initState();
    _initializeNotifications();
    _loadActiveFilters();
    _loadSearchResults();
    _checkFirstTimeUser();

    // Animation Controller für allgemeine Animationen
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
  }

  @override
  void dispose() {
    _animationController?.dispose();
    _searchTimer?.cancel();
    _countdownTimer?.cancel(); // Countdown-Timer stoppen
    super.dispose();
  }


  void _startCountdown() {
    _countdownTimer?.cancel(); // Vorherigen Timer stoppen, wenn vorhanden
    _timeRemaining = Duration(minutes: _refreshInterval); // Setze die verbleibende Zeit auf das Intervall

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        if (_timeRemaining.inSeconds > 0) {
          _timeRemaining -= const Duration(seconds: 1); // Verbleibende Zeit reduzieren
        } else {
          _timeRemaining = Duration(minutes: _refreshInterval); // Timer zurücksetzen, wenn er abgelaufen ist
        }
      });
    });
  }

  void _startSearchTimer() {
    _searchTimer?.cancel();
    if (_filtersActive) {
      _searchTimer = Timer.periodic(Duration(minutes: _refreshInterval), (timer) {
        _repeatSearch();
        _startCountdown(); // Countdown neu starten nach jeder Suche
      });
      _startCountdown(); // Countdown beim Start der Suche starten
    }
  }

  void _initializeNotifications() {
    const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initializationSettings = InitializationSettings(android: initializationSettingsAndroid);
    flutterLocalNotificationsPlugin.initialize(initializationSettings);
  }
  

  Future<void> _checkFirstTimeUser() async {
    final prefs = await SharedPreferences.getInstance();
    bool? isFirstTime = prefs.getBool('is_first_time_user');
    
    if (isFirstTime == null || isFirstTime == true) {
      _showSwipeHintOverlay();
      await prefs.setBool('is_first_time_user', false);
    }
  }

  void _showSwipeHintOverlay() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Tipp: Navigation per Wischen'),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Du kannst nach links wischen, um die Inserate zu sehen und nach rechts, um deine Favoriten zu erreichen.'),
              SizedBox(height: 16),
              Icon(Icons.swipe, size: 50, color: Colors.green),
            ],
          ),
          actions: [
            TextButton(
              child: const Text('Verstanden'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  void _animateAddFavorite() {
    _animationController?.forward().then((_) => _animationController?.reverse());
  }

  Future<void> _showNotification(String title, String body) async {
    const AndroidNotificationDetails androidPlatformChannelSpecifics = AndroidNotificationDetails(
      'your_channel_id', 'your_channel_name',
      channelDescription: 'your_channel_description',
      importance: Importance.max,
      priority: Priority.high,
    );
    const NotificationDetails platformChannelSpecifics = NotificationDetails(android: androidPlatformChannelSpecifics);
    await flutterLocalNotificationsPlugin.show(0, title, body, platformChannelSpecifics, payload: 'New advertisement');
  }

  Future<void> _loadActiveFilters() async {
    final prefs = await SharedPreferences.getInstance();
    final savedFilters = prefs.getString('active_filters');
    if (savedFilters != null) {
      setState(() {
        _activeFilters = json.decode(savedFilters);
        _filtersActive = true;
        _filtersSet = true;
        _startSearchTimer();
      });
    }
  }

  Future<void> _saveActiveFilters(Map<String, dynamic> filters) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('active_filters', json.encode(filters));
  }

  Future<void> _clearActiveFilters() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('active_filters');
    await prefs.remove('search_results');
    setState(() {
      _activeFilters = null;
      _filtersActive = false;
      searchResults.clear();
      _filtersSet = false;
    });
    _searchTimer?.cancel();
  }

  Future<void> _saveSearchResults(List<dynamic> results) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('search_results', json.encode(results));
  }

  Future<void> _loadSearchResults() async {
    final prefs = await SharedPreferences.getInstance();
    final savedResults = prefs.getString('search_results');
    if (savedResults != null) {
      setState(() {
        searchResults = json.decode(savedResults);
      });
    }
  }

Future<void> _repeatSearch() async {
  if (_activeFilters != null) {
    // Alte Liste der Inserate speichern
    List<dynamic> oldListings = List.from(searchResults);

    // Neue Inserate laden
    await fetchListings();

    // Liste der neuen Inserate
    List<dynamic> newListings = [];

    // Finde nur die neuen Inserate (die nicht in der alten Liste sind)
    for (var listing in searchResults) {
      bool exists = oldListings.any((oldListing) => oldListing['Titel'] == listing['Titel']);
      if (!exists) {
        newListings.add(listing); // Füge das neue Inserat hinzu
      }
    }

    // Wenn es neue Inserate gibt, füge sie oben in der Liste hinzu
    if (newListings.isNotEmpty) {
      setState(() {
        searchResults = [...newListings, ...oldListings]; // Neue Inserate oben anzeigen
        _newListingsCount += newListings.length; // Erhöhe den Zähler für die neuen Inserate
      });

      // Benachrichtigung anzeigen
      _showNotification('Neue Anzeige gefunden', '${newListings.length} neue Anzeige(n) hinzugefügt.');
    }
  }
}



Future<void> fetchListings() async {
  Scraper scraper = Scraper();

  if (_activeFilters == null || _activeFilters?['city'] == null || _activeFilters!['city'].isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Bitte einen Ort angeben.'), backgroundColor: Colors.red),
    );
    return;
  }

  String city = _activeFilters?['city'] ?? '';

  // Definiere eine Map, die Städte den entsprechenden IDs zuordnet
  Map<String, int> cityIds = {
    'Berlin': 8,
    'Muenster': 91,
    'Muenchen': 90,
    'Hamburg': 55,
    'Duesseldorf': 30,
    'Koeln': 73,
    'Stuttgart': 124,
    'Frankfurt-am-Main': 41,
    'Leipzig': 77,   

    // Weitere Städte und deren IDs hinzufügen
  };

  // Hole die City ID basierend auf der ausgewählten Stadt
  int cityId = cityIds[city] ?? 0; // Fallback auf 0, falls Stadt nicht gefunden wird

  if (cityId == 0) {
    // Zeige eine Fehlermeldung an, wenn die Stadt keine gültige ID hat
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Ungültige Stadt ausgewählt.'), backgroundColor: Colors.red),
    );
    return;
  }

  // Führe den Scraper mit der dynamisch bestimmten cityId aus
  List<Map<String, String>> allListings = await scraper.scrapeListings(
    city, 
    cityId, // Dynamisch bestimmte cityId verwenden
    'WG-Zimmer', 
    0, 
    amountListings: 10
  );

  // Preis- und Größenfilter vorbereiten
  double? minPrice = _activeFilters?['priceMin'] != null && _activeFilters!['priceMin'].isNotEmpty
      ? double.tryParse(_activeFilters!['priceMin']) 
      : null;
  
  double? maxPrice = _activeFilters?['priceMax'] != null && _activeFilters!['priceMax'].isNotEmpty
      ? double.tryParse(_activeFilters!['priceMax']) 
      : null;
  
  double? minRoomSize = _activeFilters?['roomSize'] != null && _activeFilters!['roomSize'].isNotEmpty
      ? double.tryParse(_activeFilters!['roomSize']) 
      : null;

  // Filtere die Inserate nach den Kriterien
  List<Map<String, String>> filteredListings = allListings.where((listing) {
    String rawPrice = listing['Price'] ?? '';
    String rawSize = listing['Size'] ?? '';

    // Entferne nicht-numerische Zeichen und konvertiere in Zahlen
    double? price = double.tryParse(rawPrice.replaceAll(RegExp(r'[^0-9.]'), ''));
    double? roomSize = double.tryParse(rawSize.replaceAll(RegExp(r'[^0-9.]'), ''));

    // Überprüfe die Filterkriterien
    bool matchesMinPrice = minPrice == null || (price != null && price >= minPrice);
    bool matchesMaxPrice = maxPrice == null || (price != null && price <= maxPrice);
    bool matchesRoomSize = minRoomSize == null || (roomSize != null && roomSize >= minRoomSize);

    return matchesMinPrice && matchesMaxPrice && matchesRoomSize;
  }).toList();

  // Setze die gefilterten Inserate in den Zustand
  setState(() {
    searchResults = filteredListings;
  });

  // Speicher die gefilterten Inserate
  await _saveSearchResults(filteredListings);
}


  void addFavorite(Map<String, dynamic> listing) {
    setState(() {
      favorites.add(listing);
    });
    _animateAddFavorite();
  }

  void removeFavorite(Map<String, dynamic> listing) {
    setState(() {
      favorites.removeWhere((favorite) => favorite['Titel'] == listing['Titel']);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Favorit entfernt'),
      ),
    );
  }

void setFilters(Map<String, dynamic> filters) {
  setState(() {
    _activeFilters = {
      'city': filters['city'], // Stadt ist immer notwendig
      if (filters['priceMin'] != null && filters['priceMin'].isNotEmpty) 'priceMin': filters['priceMin'],
      if (filters['priceMax'] != null && filters['priceMax'].isNotEmpty) 'priceMax': filters['priceMax'],
      if (filters['roomSize'] != null && filters['roomSize'].isNotEmpty) 'roomSize': filters['roomSize'],
    };
    _filtersActive = true;
    _filtersSet = true;
  });

  _saveActiveFilters(_activeFilters!);
  fetchListings();
  _startSearchTimer();
}

  void toggleCardExpansion(int index) {
    setState(() {
      _expandedCards[index] = !_expandedCards.containsKey(index) ? true : !_expandedCards[index]!;
    });
  }

  bool isCardExpanded(int index) {
    return _expandedCards[index] ?? false;
  }

  bool isFavorite(Map<String, dynamic> listing) {
    return favorites.any((fav) => fav['Titel'] == listing['Titel']);
  }

 void _markListingsAsViewed() {
  setState(() {
    _newListingsCount = 0; // Zähler für neue Inserate zurücksetzen
  });
}


  @override
  Widget build(BuildContext context) {
    return PageView(
      controller: _pageController,
      onPageChanged: (int page) {
        if (page == 0) { // Linke Seite mit den Inseraten
        _markListingsAsViewed();
        }
      },
      children: [
       Scaffold(
      backgroundColor: Colors.white,  // Hintergrundfarbe auf Weiß setzen
      body: _filtersSet
          ? FilterScreen(
              onAddFavorite: addFavorite,
              onRemoveFavorite: removeFavorite,
              onSetFilters: setFilters,
              searchResults: searchResults,
              favorites: favorites,
              onToggleExpand: toggleCardExpansion,
              isCardExpanded: isCardExpanded,
              isFavorite: isFavorite,
              onViewedListings: _markListingsAsViewed,
              isFiltersCollapsed: _isFiltersCollapsed,  // NEU: Übergabe des Zustands
              onFilterCollapseChanged: _toggleFilterCollapse, 
            )
            : Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton(
                      onPressed: () {
                        setState(() {
                          _filtersSet = true;
                        });
                      },
                      child: const Text('Scrape WG-Gesucht.de'),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () {},
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.grey,
                      ),
                      child: const Text('Coming Soon'),
                    ),
                  ],
                ),
              ),
       ),
                // Home-Seite
        Scaffold(
          appBar: AppBar(
            title: const Text('Scraper'),
            actions: [
              IconButton(
                icon: const Icon(Icons.settings, color: Colors.white),
                onPressed: () {
                  _showSettingsDialog();
                },
              )
            ],
          ),
          body: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Card(
                      color: Colors.white,
                      elevation: 4,
                      margin: const EdgeInsets.all(16),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          children: [
                            Text(
                              '>>Scraper',
                              style: Theme.of(context).textTheme.headlineLarge,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 20),
                            Text(
                              'Unsere smarte App durchsucht automatisch Websites und informiert dich in Echtzeit über neue Inserate. Sei der Erste, der die Anbieter kontaktiert und erhöhe deine Chancen auf eine Zusage! Keine verpassten Gelegenheiten mehr – mit uns bist du immer einen Schritt voraus.',
                              style: Theme.of(context).textTheme.bodyMedium,
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Derzeit unterstützt:',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 10),

                     // **Neu: Anzeige des Countdowns, wenn Filter aktiv sind**
                    //if (_filtersActive)
                      //Text(
                        //'Nächste Aktualisierung in: ${_timeRemaining.inMinutes}:${(_timeRemaining.inSeconds % 60).toString().padLeft(2, '0')}',
                        //style: TextStyle(
                          //fontSize: 18,
                          //fontWeight: FontWeight.bold,
                          //color: const Color.fromARGB(255, 163, 43, 127),
                        //),
                      //),
                      
                    // "Besuche WG-Gesucht"-Button
                    SizedBox(
                      width: MediaQuery.of(context).size.width * 0.8,
                      child: ElevatedButton(
                        onPressed: () async {
                          const url = 'https://www.wg-gesucht.de';
                          if (await canLaunch(url)) {
                            await launch(url);
                          } else {
                            throw 'Konnte WG-Gesucht nicht öffnen';
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFFA500),
                          padding: const EdgeInsets.symmetric(vertical: 30),
                          textStyle: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child: const Text('WG-Gesucht.de'),
                      ),
                    ),
                    // Aktive Filter-Kästchen
                    if (_filtersActive && _activeFilters != null)
                      SizedBox(
                        width: MediaQuery.of(context).size.width * 0.8, // Gleiche Breite wie "Besuche WG-Gesucht"
                        child: Stack(
                          children: [
                            Card(
                              color: const Color.fromARGB(255, 255, 230, 200),
                              margin: const EdgeInsets.only(top: 0), // Lückenlos anschließen
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(16.0),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Aktive Filter:',
                                      style: TextStyle(
                                        color: Color.fromARGB(255, 22, 59, 23),
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Text('Stadt: ${_activeFilters?['city'] ?? ''}'),
                                    Text('Min Preis: ${_activeFilters?['priceMin'] ?? ''}'),
                                    Text('Max Preis: ${_activeFilters?['priceMax'] ?? ''}'),
                                    Text('Zimmergröße: ${_activeFilters?['roomSize'] ?? ''} m²'),
                                    Row(
                                      children: [
                                        DropdownButton<int>(
                                          value: _refreshInterval,
                                          items: <int>[1, 2, 5, 15, 30].map((int value) {
                                            return DropdownMenuItem<int>(
                                              value: value,
                                              child: Text('$value Minuten'),
                                            );
                                          }).toList(),
                                          onChanged: (int? newValue) {
                                            if (newValue != null) {
                                              setState(() {
                                                _refreshInterval = newValue;
                                                _startSearchTimer();
                                              });

                                              // Zeige SnackBar bei Änderung des Intervalls
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                SnackBar(
                                                  content: Text('Aktualisierungsintervall auf $newValue Minuten gesetzt.'),
                                                  duration: const Duration(seconds: 2),
                                                ),
                                              );
                                            }
                                          },
                                        ),
                                        const Spacer(), // Schiebt die Mülltonne nach rechts
                                        IconButton(
                                          icon: const Icon(Icons.delete, color: Colors.red),
                                          onPressed: () {
                                            _clearActiveFilters();
                                          },
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (_newListingsCount > 0)
                              Positioned(
                                right: 10,
                                top: 10,
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: const BoxDecoration(
                                    color: Colors.red,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Text(
                                    '$_newListingsCount',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              // Banner am unteren Bildschirmrand
              Container(
                width: double.infinity,
                color: const Color(0xFFF5F5DC),
                padding: const EdgeInsets.all(16.0),
                child: Center(
                  child: SizedBox(
                    width: MediaQuery.of(context).size.width * 0.5,
                    child: ElevatedButton(
                      onPressed: () async {
                        const url = 'https://www.buymeacoffee.com/YourProfile';
                        if (await canLaunch(url)) {
                          await launch(url);
                        } else {
                          throw 'Konnte BuyMeACoffee-Link nicht öffnen';
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        textStyle: const TextStyle(fontSize: 16),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.coffee, color: Colors.white),
                          SizedBox(width: 8),
                          Text('Gönn mir nen Kaffee :)'),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),


        // Favoriten-Seite
        Scaffold(
          appBar: AppBar(
            title: const Text('Favoriten'),
          ),
          body: favorites.isEmpty
              ? const Center(child: Text('Noch keine Favoriten gespeichert.'))
              : ListView.builder(
                  itemCount: favorites.length,
                  itemBuilder: (context, index) {
                    final listing = favorites[index];
                    return AnimatedOpacity(
                      duration: const Duration(milliseconds: 500),
                      opacity: isCardExpanded(index) ? 1.0 : 0.8,
                      child: Card(
                        elevation: 4,
                        margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                        child: Column(
                          children: [
                            ListTile(
                              title: Text(listing['Titel'] ?? 'Titel nicht verfügbar'),
                              subtitle: Text('Preis: ${listing['Price'] ?? 'Preis nicht verfügbar'} | Größe: ${listing['Size'] ?? 'Größe nicht verfügbar'}'),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete),
                                color: Colors.red,
                                onPressed: () {
                                  removeFavorite(listing);
                                },
                              ),
                              onTap: () {
                                toggleCardExpansion(index);
                              },
                            ),
                           if (isCardExpanded(index))
                            Padding(
                              padding: const EdgeInsets.all(16.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Kopier-Symbol
                                  Row(
                                    children: [
                                      IconButton(
                                        icon: const Icon(Icons.content_copy, size: 20),  // Verwende das Material Design Kopier-Symbol
                                        onPressed: () async {
                                          final prefs = await SharedPreferences.getInstance();
                                          final savedText = prefs.getString('anschreiben_text') ?? '';
                                          
                                          if (savedText.isNotEmpty) {
                                            FlutterClipboard.copy(savedText).then((value) {
                                              ScaffoldMessenger.of(context).showSnackBar(
                                                const SnackBar(content: Text('Text in die Zwischenablage kopiert!')),
                                              );
                                            });
                                          } else {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              const SnackBar(content: Text('Kein gespeicherter Text vorhanden!')),
                                            );
                                          }
                                        },
                                      ),
                                    ],
                                  ),
                                  // Link
                                  GestureDetector(
                                    onTap: () async {
                                      final url = listing['Link'] ?? '';
                                      if (await canLaunch(url)) {
                                        await launch(url);
                                      } else {
                                        throw 'Konnte Link nicht öffnen';
                                      }
                                    },
                                    child: Text(
                                      listing['Link'] ?? 'Kein Link verfügbar',
                                      style: const TextStyle(
                                        color: Colors.blue,
                                        decoration: TextDecoration.underline,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),


                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _showSettingsDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Einstellungen'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('Info'),
                onTap: () {
                  Navigator.of(context).pop();
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const InfoScreen()),
                  );
                },
              ),
            ListTile(
              title: const Text('Copy & Paste'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const AnschreibenScreen()),
                );
              },
            ),
            ],
          ),
        );
      },
    );
  }
}

// Hier ist die FilterScreen-Definition
class FilterScreen extends StatefulWidget {
  final Function(Map<String, dynamic>) onAddFavorite;
  final Function(Map<String, dynamic>) onRemoveFavorite;
  final Function(Map<String, dynamic>) onSetFilters;
  final List<dynamic> searchResults;
  final List<Map<String, dynamic>> favorites;
  final Function(int) onToggleExpand;
  final bool Function(int) isCardExpanded;
  final bool Function(Map<String, dynamic>) isFavorite;
  final VoidCallback onViewedListings;
  final bool isFiltersCollapsed;  // NEU: Zustand, ob die Filter eingeklappt sind
  final Function(bool) onFilterCollapseChanged;

  const FilterScreen({super.key, 
    required this.onAddFavorite,
    required this.onRemoveFavorite,
    required this.onSetFilters,
    required this.searchResults,
    required this.favorites,
    required this.onToggleExpand,
    required this.isCardExpanded,
    required this.isFavorite,
    required this.onViewedListings,
    required this.isFiltersCollapsed,  // NEU: Zustand übergeben
    required this.onFilterCollapseChanged, 
  });

  @override
  _FilterScreenState createState() => _FilterScreenState();
}

class _FilterScreenState extends State<FilterScreen> {
  final TextEditingController _minPriceController = TextEditingController();
  final TextEditingController _maxPriceController = TextEditingController();
  final TextEditingController _roomSizeController = TextEditingController();
  bool _isLoading = false; 
  String _cityController = 'Berlin';  // Standardwert für die Stadt

  void _toggleFilters() {
    setState(() {
      widget.onFilterCollapseChanged(!widget.isFiltersCollapsed);
    });
  }

  @override
  Widget build(BuildContext context) {
    bool isCollapsed = widget.isFiltersCollapsed;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Filter'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (context) => const HomePage()), // Ersetze "HomePage" durch deine Startseite
            );
          },
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // AnimatedContainer für das Filter-Kästchen inklusive Button
            AnimatedContainer(
              duration: const Duration(milliseconds: 500), // Sanfte Einfahr-Animation
              curve: Curves.easeInOut, // Verwendet einen sanften Übergang
              height: isCollapsed ? 50 : null, // Höhe basierend auf dem Zustand
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black12,
                    blurRadius: 4.0,
                    spreadRadius: 1.0,
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0), // Nur horizontaler Padding
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center, // Zentriert den Inhalt vertikal
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween, // Links Text, Rechts Pfeil
                      children: [
                        const Text('Filter', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        IconButton(
                          icon: Icon(isCollapsed ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up),
                          onPressed: _toggleFilters,
                        ),
                      ],
                    ),
                    if (!isCollapsed) ...[
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        value: _cityController,
                        decoration: const InputDecoration(
                          labelText: 'Stadt',
                          border: OutlineInputBorder(),
                        ),
                        items: ['Berlin', 'Muenster'].map((String city) {
                          return DropdownMenuItem<String>(
                            value: city,
                            child: Text(city),
                          );
                        }).toList(),
                        onChanged: (String? newCity) {
                          setState(() {
                            _cityController = newCity!;
                          });
                        },
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _minPriceController,
                        decoration: const InputDecoration(
                          labelText: 'Min Preis',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _maxPriceController,
                        decoration: const InputDecoration(
                          labelText: 'Max Preis',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _roomSizeController,
                        decoration: const InputDecoration(
                          labelText: 'Min Zimmergröße (m²)',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.number,
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: () async {
                          setState(() {
                            _isLoading = true;  // Ladebalken anzeigen
                          });

                          final filters = {
                            'city': _cityController,
                            'priceMin': _minPriceController.text,
                            'priceMax': _maxPriceController.text,
                            'roomSize': _roomSizeController.text,
                          };

                          try {
                            // Warte, bis die Filter gesetzt und die Suche abgeschlossen ist
                            await widget.onSetFilters(filters);

                            // Ergebnisse laden und erst dann auf Leerheit prüfen
                            await Future.delayed(const Duration(milliseconds: 2000));  // Kurze Verzögerung, um sicherzustellen, dass die UI aktualisiert wird

                            // Prüfe erst nach dem Laden, ob es Ergebnisse gibt
                            setState(() {
                              if (widget.searchResults.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Keine Ergebnisse gefunden.')),
                                );
                              }
                            });
                          } catch (error) {
                            setState(() {
                              _isLoading = false;  // Ladebalken ausblenden
                            });
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Fehler beim Laden der Anzeigen: $error')),
                            );
                          } finally {
                            setState(() {
                              _isLoading = false;  // Ladebalken ausblenden
                              widget.onFilterCollapseChanged(true);  // Filter nach der Suche einklappen
                            });
                          }
                        },
                        child: const Text('Suche starten und Filter anwenden'),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // Ladebalken anzeigen, wenn _isLoading true ist
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: CircularProgressIndicator(),
              ),

            const SizedBox(height: 16),
            widget.searchResults.isEmpty
                ? const Text('Keine Suchergebnisse gefunden.')
                : Expanded(
                    child: ListView.builder(
                      itemCount: widget.searchResults.length,
                      itemBuilder: (context, index) {
                        final listing = widget.searchResults[index];
                        return Card(
                          elevation: 4,
                          margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                          child: Column(
                            children: [
                              ListTile(
                                title: Text(listing['Titel'] ?? 'Titel nicht verfügbar'),
                                subtitle: Text('Preis: ${listing['Price'] ?? 'Preis nicht verfügbar'} | Größe: ${listing['Size'] ?? 'Größe nicht verfügbar'}'),
                                trailing: IconButton(
                                  icon: Icon(
                                    widget.isFavorite(listing) ? Icons.favorite : Icons.favorite_border,
                                    color: widget.isFavorite(listing) ? Colors.red : null,
                                  ),
                                  onPressed: () {
                                    if (widget.isFavorite(listing)) {
                                      widget.onRemoveFavorite(listing);
                                    } else {
                                      widget.onAddFavorite(listing);
                                    }
                                  },
                                ),
                                onTap: () {
                                  widget.onToggleExpand(index);
                                  widget.onViewedListings();
                                },
                              ),

                              if (widget.isCardExpanded(index))
                                Padding(
                                  padding: const EdgeInsets.all(16.0),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      // Kopier-Symbol
                                      Row(
                                        children: [
                                          IconButton(
                                            icon: const Icon(Icons.content_copy, size: 20),  // Verwende das Material Design Kopier-Symbol
                                            onPressed: () async {
                                              final prefs = await SharedPreferences.getInstance();
                                              final savedText = prefs.getString('anschreiben_text') ?? '';

                                              if (savedText.isNotEmpty) {
                                                FlutterClipboard.copy(savedText).then((value) {
                                                  ScaffoldMessenger.of(context).showSnackBar(
                                                    const SnackBar(content: Text('Text in die Zwischenablage kopiert!')),
                                                  );
                                                });
                                              } else {
                                                ScaffoldMessenger.of(context).showSnackBar(
                                                  const SnackBar(content: Text('Kein gespeicherter Text vorhanden!')),
                                                );
                                              }
                                            },
                                          ),
                                        ],
                                      ),
                                      // Link
                                      GestureDetector(
                                        onTap: () async {
                                          final url = listing['Link'] ?? '';
                                          if (await canLaunch(url)) {
                                            await launch(url);
                                          } else {
                                            throw 'Konnte Link nicht öffnen';
                                          }
                                        },
                                        child: Text(
                                          listing['Link'] ?? 'Kein Link verfügbar',
                                          style: const TextStyle(
                                            color: Colors.blue,
                                            decoration: TextDecoration.underline,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
          ],
        ),
      ),
    );
  }
}




//Infoseite
class InfoScreen extends StatelessWidget {
  const InfoScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Info', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                // Strecke das Kästchen auf die gesamte Breite
                Card(
                  elevation: 4,
                  color: const Color.fromARGB(255, 255, 255, 255),
                  margin: const EdgeInsets.only(bottom: 20),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Container(
                    width: double.infinity, // Nutze die gesamte Breite
                    padding: const EdgeInsets.all(16.0),
                    child: const Column(
                      children: [
                        Text(
                          'Hey du! \nIch bin Stefan und trinke gerne Kaffee. \n Sag doch mal hi :)',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w500,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),
                // Instagram-Button
                Card(
                  elevation: 4,
                  color: const Color(0xFFF5F5DC),
                  margin: const EdgeInsets.only(bottom: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ListTile(
                    leading: const Icon(Icons.camera_alt, color: Color(0xFF184A1E)),
                    title: const Text('Instagram'),
                    trailing: const Icon(Icons.arrow_forward_ios, color: Color(0xFF184A1E)),
                    onTap: () async {
                      final Uri instagramUri = Uri.parse('https://www.instagram.com/tchubertus');
                      if (await canLaunchUrl(instagramUri)) {
                        await launchUrl(instagramUri, mode: LaunchMode.externalApplication);
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Konnte Instagram nicht öffnen')),
                        );
                      }
                    },
                  ),
                ),

                // LinkedIn-Button
                Card(
                  elevation: 4,
                  color: const Color(0xFFF5F5DC),
                  margin: const EdgeInsets.only(bottom: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ListTile(
                    leading: const Icon(Icons.business, color: Color(0xFF184A1E)),
                    title: const Text('LinkedIn'),
                    trailing: const Icon(Icons.arrow_forward_ios, color: Color(0xFF184A1E)),
                    onTap: () async {
                      final Uri linkedInUri = Uri.parse('https://www.linkedin.com/in/stefan-chudalla-9a95b0236');
                      if (await canLaunchUrl(linkedInUri)) {
                        await launchUrl(linkedInUri);
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Konnte LinkedIn nicht öffnen')),
                        );
                      }
                    },
                  ),
                ),
                // E-Mail anzeigen
                Card(
                  elevation: 4,
                  color: const Color(0xFFF5F5DC),
                  margin: const EdgeInsets.only(bottom: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ListTile(
                    leading: const Icon(Icons.email, color: Color(0xFF184A1E)),
                    title: const Text('Email'),
                    trailing: const Icon(Icons.arrow_forward_ios, color: Color(0xFF184A1E)),
                    onTap: () {
                      showDialog(
                        context: context,
                        builder: (BuildContext context) {
                          return AlertDialog(
                            title: const Text('Meine E-Mail'),
                            content: const Text('StChudalla@gmail.com'),
                            actions: [
                              TextButton(
                                child: const Text('Schließen'),
                                onPressed: () {
                                  Navigator.of(context).pop();
                                },
                              ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          // Copyright-Hinweis unten
          const Padding(
            padding: EdgeInsets.all(8.0),
            child: Text(
              '© 2024 Stefan Chudalla. Alle Rechte vorbehalten.',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}


class AnschreibenScreen extends StatefulWidget {
  const AnschreibenScreen({super.key});

  @override
  _AnschreibenScreenState createState() => _AnschreibenScreenState();
}

class _AnschreibenScreenState extends State<AnschreibenScreen> {
  final TextEditingController _textController = TextEditingController();
  String savedText = "";

  @override
  void initState() {
    super.initState();
    _loadSavedText(); // Lade den gespeicherten Text beim Start
  }

  Future<void> _loadSavedText() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      savedText = prefs.getString('anschreiben_text') ?? ''; // Lade den Text aus SharedPreferences
      _textController.text = savedText;
    });
  }

  Future<void> _saveText() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('anschreiben_text', _textController.text); // Speichere den Text
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Text gespeichert!')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Copy & Paste'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Setze den erklärenden Text in ein Kästchen (Card)
            Card(
              color: Colors.white,
              elevation: 4,
              margin: const EdgeInsets.all(16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  'Mit unserer App sparst du wertvolle Zeit! Du kannst direkt ein vorformuliertes Anschreiben erstellen und speichern, um dich noch schneller bei Anbietern zu melden. Sobald du deinen Text gespeichert hast, reicht ein Klick auf das Copy-Symbol neben den Inseraten, und der Text wird automatisch in die Zwischenablage kopiert. Kein lästiges Tippen mehr – so bist du der Erste, der sich auf das perfekte Angebot bewirbt!',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _textController,
              maxLines: 10,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Vorformulierter Text'
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _saveText, // Text speichern
              child: const Text('Speichern'),
            ),
          ],
        ),
      ),
    );
  }
}


class Scraper {
  Future<List<Map<String, String>>> scrapeListings(
      String cityName, int cityId, String roomCategory, int roomCategoryNo,
      {int amountListings = 10}) async {
    List<Map<String, String>> announcementList = [];

    if (cityName.isEmpty) {
      print("Fehler: Der Stadtname darf nicht leer sein.");
      return announcementList;
    }

    String baseUrl =
        "https://www.wg-gesucht.de/${roomCategory.toLowerCase()}-in-$cityName.$cityId.$roomCategoryNo.1.0.html";

    try {
      http.Response response = await http.get(Uri.parse(baseUrl));

      if (response.statusCode == 200) {
        var document = parse(response.body);

        var wohnungen =
            document.getElementsByClassName('wgg_card offer_list_item');

        for (var wohnung in wohnungen.take(amountListings)) {
          // Prüfe, ob es sich um Anzeigen von Unternehmen handelt
          var verifiedLabel = wohnung
              .querySelector('.campaign_click.label_verified.ml5');
          if (verifiedLabel != null) {
            continue; // Überspringe Anzeigen von Unternehmen
          }

          String title = wohnung
                  .querySelector('.truncate_title.noprint')
                  ?.text
                  .trim() ??
              'Kein Titel verfügbar';

          String rawInfo = wohnung.querySelector('.col-xs-11')?.text.trim() ??
              'Unbekannte Informationen';
          List<String> infoParts = rawInfo.split('|');
          String type = infoParts.isNotEmpty ? infoParts[0].trim() : 'Unbekannter Typ';
          String district =
              infoParts.length > 1 ? infoParts[1].trim() : 'Unbekannter Bezirk';
          String address =
              infoParts.length > 2 ? infoParts[2].trim() : 'Unbekannte Adresse';

          String linkElement = wohnung
                  .querySelector('.col-sm-12.flex_space_between a')
                  ?.attributes['href'] ??
              '';
          String link = 'https://wg-gesucht.de$linkElement';

          String size =
              wohnung.querySelector('.col-xs-3.text-right')?.text.trim() ??
                  'Größe nicht verfügbar';

          String available = wohnung
                  .querySelector('.col-xs-5.text-center')?.text.trim() ??
              'Verfügbarkeit nicht verfügbar';

          String price =
              wohnung.querySelector('.col-xs-3')?.text.trim() ??
                  'Preis nicht verfügbar';

          Map<String, String> announcementInfo = {
            'Titel': title,
            'Link': link,
            'Type': type,
            'District': district,
            'Address': address,
            'Size': size,
            'Available': available,
            'Price': price,
          };

          announcementList.add(announcementInfo);
        }
      } else {
        print('Fehler beim Abrufen der Seite: Statuscode ${response.statusCode}');
      
      }
    } catch (e) {
      print('Fehler beim HTTP-Request: $e');
    }

    return announcementList;
  }
}
