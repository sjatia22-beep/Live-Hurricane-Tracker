import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:workmanager/workmanager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

const String severeWeatherTaskKey = "autonomousSevereWeatherCheck";

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lat = prefs.getDouble('user_latitude') ?? 25.7617;
      final lon = prefs.getDouble('user_longitude') ?? -80.1918;

      final url = Uri.parse(
        'https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current=temperature_2m,precipitation,rain,weather_code,wind_speed_10m,wind_direction_10m&hourly=cape'
      );

      final response = await http.get(url).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final current = data['current'] ?? {};
        final precipitation = (current['precipitation'] as num?)?.toDouble() ?? 0.0;
        final weatherCode = (current['weather_code'] as num?)?.toInt() ?? 0;
        final windSpeed = (current['wind_speed_10m'] as num?)?.toDouble() ?? 0.0;

        final hourly = data['hourly'] ?? {};
        final capeList = hourly['cape'] as List<dynamic>? ?? [];
        final double maxCape = capeList.isNotEmpty ? (capeList.first as num?)?.toDouble() ?? 0.0 : 0.0;

        final bool extremeRain = precipitation > 10.0 || const [65, 82, 95, 96, 99].contains(weatherCode);
        final bool highWind = windSpeed > 50.0;
        final bool severeThunder = maxCape > 1000.0 || const [95, 96, 99].contains(weatherCode);

        if (extremeRain || highWind || severeThunder) {
          final flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();
          const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
          const initSettings = InitializationSettings(android: androidInit);
          await flutterLocalNotificationsPlugin.initialize(initSettings);

          const androidDetails = AndroidNotificationDetails(
            'severe_weather_channel',
            'Severe Weather Alerts',
            channelDescription: 'High-priority heads-up emergency severe weather alerts',
            importance: Importance.max,
            priority: Priority.high,
            enableVibration: true,
            playSound: true,
          );
          const notificationDetails = NotificationDetails(android: androidDetails);

          await flutterLocalNotificationsPlugin.show(
            999,
            '⚠️ EXTREME WEATHER WARNING',
            'Severe wind (${windSpeed.toStringAsFixed(1)} km/h) & thunderstorm detected near your coordinates! Take immediate shelter.',
            notificationDetails,
          );
        }
      }
      return Future.value(true);
    } catch (e) {
      return Future.value(true);
    }
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await MobileAds.instance.initialize();
  } catch (_) {}

  try {
    await Workmanager().initialize(
      callbackDispatcher,
      isInDebugMode: false,
    );
    await Workmanager().registerPeriodicTask(
      severeWeatherTaskKey,
      severeWeatherTaskKey,
      frequency: const Duration(minutes: 15),
      existingWorkPolicy: ExistingWorkPolicy.keep,
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
    );
  } catch (_) {}

  runApp(const DopplerRadarApp());
}

class DopplerRadarApp extends StatelessWidget {
  const DopplerRadarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tactical Hurricane & Doppler Radar Engine',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0E14),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00E5FF),
          surface: Color(0xFF121820),
          secondary: Color(0xFFFF3B30),
          tertiary: Color(0xFFFF9500),
        ),
      ),
      home: const RadarHomeScreen(),
    );
  }
}

class RadarFrame {
  final int time;
  final String path;
  final bool isPast;
  final bool isNowcast;
  final String timeLabel;
  final int frameIndex;

  RadarFrame({
    required this.time,
    required this.path,
    required this.isPast,
    required this.isNowcast,
    required this.timeLabel,
    required this.frameIndex,
  });
}

class StormDetail {
  final String name;
  final String category;
  final int windSpeedMph;
  final int windSpeedKmh;
  final int pressureHpa;
  final String movement;
  final String landfallEta;
  final LatLng currentPosition;

  StormDetail({
    required this.name,
    required this.category,
    required this.windSpeedMph,
    required this.windSpeedKmh,
    required this.pressureHpa,
    required this.movement,
    required this.landfallEta,
    required this.currentPosition,
  });
}

class RadarHomeScreen extends StatefulWidget {
  const RadarHomeScreen({super.key});

  @override
  State<RadarHomeScreen> createState() => _RadarHomeScreenState();
}

class _RadarHomeScreenState extends State<RadarHomeScreen>
    with SingleTickerProviderStateMixin {
  // AdMob Rewarded Ad
  RewardedAd? _rewardedAd;
  bool _isAdLoaded = false;
  final String _adUnitId = 'ca-app-pub-3940256099942544/5224354917';

  // RainViewer Data
  String _host = 'https://tilecache.rainviewer.com';
  List<RadarFrame> _frames = [];
  int _pastCount = 0;
  bool _isLoading = true;
  String? _errorMessage;

  // Frame Control State
  int _currentFrameIndex = 0;
  int _unlockedMaxIndex = 0;
  bool _isPlaying = false;
  Timer? _loopTimer;

  // Cooldown State
  int _cooldownSeconds = 0;
  Timer? _cooldownTimer;

  // Basemap URLs List (100% Free & Open - No API keys or watermarks)
  final Map<String, String> basemapLayers = const {
    'Satellite Imagery': 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
    'Standard Street': 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    'Topographic Terrain': 'https://tile.opentopomap.org/{z}/{x}/{y}.png',
  };

  String _currentBasemap = 'Satellite Imagery';

  // Layer Visibility Toggles
  bool _showRainRadar = true;
  bool _showStormTrack = true;
  bool _showLightning = true;
  bool _showBorders = true;

  // Map Controller
  final MapController _mapController = MapController();
  final LatLng _initialCenter = const LatLng(25.7617, -80.1918); // Miami / Hurricane Center

  // Hurricane Helene Spec
  final StormDetail _stormHelene = StormDetail(
    name: 'HURRICANE HELENE',
    category: 'CAT-4 MAJOR',
    windSpeedMph: 140,
    windSpeedKmh: 225,
    pressureHpa: 938,
    movement: 'NW at 14 mph (22 km/h)',
    landfallEta: '11 HRS 30 MINS',
    currentPosition: const LatLng(25.7617, -80.1918),
  );

  // Storm Historical Track Coordinates
  final List<LatLng> _historicalTrack = const [
    LatLng(19.8, -69.5),
    LatLng(21.2, -72.8),
    LatLng(22.6, -75.4),
    LatLng(24.1, -77.8),
    LatLng(25.7617, -80.1918), // Current Position
  ];

  // Storm Forecast Trajectory
  final List<LatLng> _forecastTrack = const [
    LatLng(25.7617, -80.1918),
    LatLng(27.4, -82.1),
    LatLng(29.1, -83.7),
    LatLng(30.6, -84.6), // Landfall zone
    LatLng(32.8, -85.2),
  ];

  // High-Resolution Cone of Uncertainty Polygon
  final List<LatLng> _forecastCone = const [
    LatLng(25.7617, -80.1918),
    LatLng(27.0, -83.5),
    LatLng(29.0, -85.8),
    LatLng(31.2, -86.5),
    LatLng(33.0, -86.2),
    LatLng(33.2, -83.8),
    LatLng(31.8, -82.2),
    LatLng(29.6, -81.2),
    LatLng(27.5, -80.5),
    LatLng(25.7617, -80.1918),
  ];

  // Tactical Geography Vectors (Coastlines & Country/State Borders)
  // Florida Peninsula & Gulf Coast
  final List<LatLng> _floridaCoast = const [
    LatLng(30.7, -81.5),
    LatLng(30.3, -81.4),
    LatLng(29.0, -80.9),
    LatLng(28.4, -80.5),
    LatLng(26.8, -80.0),
    LatLng(25.8, -80.1), // Miami
    LatLng(25.1, -80.4),
    LatLng(24.5, -81.8), // Key West
    LatLng(25.1, -81.1),
    LatLng(26.1, -81.8), // Naples
    LatLng(27.9, -82.8), // Tampa
    LatLng(29.7, -83.5),
    LatLng(30.0, -84.2), // Apalachee Bay
    LatLng(29.9, -85.4),
    LatLng(30.4, -86.5), // Destin
    LatLng(30.4, -87.2), // Pensacola
    LatLng(30.3, -88.9), // Biloxi
    LatLng(29.9, -90.0), // New Orleans
    LatLng(29.3, -89.4), // Delta
    LatLng(29.7, -93.8),
    LatLng(29.3, -94.8), // Galveston
    LatLng(27.8, -97.4), // Corpus Christi
    LatLng(25.9, -97.1), // Brownsville / Mexico border
  ];

  // Cuba Coastline
  final List<LatLng> _cubaCoast = const [
    LatLng(21.9, -84.9),
    LatLng(22.8, -83.8),
    LatLng(23.1, -82.4), // Havana
    LatLng(23.2, -81.0), // Matanzas
    LatLng(22.5, -79.0),
    LatLng(21.4, -77.0),
    LatLng(20.3, -74.2),
    LatLng(19.9, -75.8),
    LatLng(20.5, -77.2),
    LatLng(21.8, -80.0),
    LatLng(22.1, -83.5),
    LatLng(21.9, -84.9),
  ];

  // US East Coast (Georgia, Carolinas)
  final List<LatLng> _eastCoast = const [
    LatLng(30.7, -81.5),
    LatLng(31.2, -81.4),
    LatLng(32.0, -80.9), // Savannah
    LatLng(32.8, -79.9), // Charleston
    LatLng(34.2, -77.9), // Wilmington
    LatLng(35.2, -75.5), // Cape Hatteras
    LatLng(36.9, -76.0), // Virginia Beach
  ];

  // Latitude / Longitude Nautical Grid Lines
  final List<List<LatLng>> _gridLines = const [
    // Parallels
    [LatLng(20.0, -100.0), LatLng(20.0, -65.0)],
    [LatLng(25.0, -100.0), LatLng(25.0, -65.0)],
    [LatLng(30.0, -100.0), LatLng(30.0, -65.0)],
    [LatLng(35.0, -100.0), LatLng(35.0, -65.0)],
    // Meridians
    [LatLng(15.0, -70.0), LatLng(40.0, -70.0)],
    [LatLng(15.0, -75.0), LatLng(40.0, -75.0)],
    [LatLng(15.0, -80.0), LatLng(40.0, -80.0)],
    [LatLng(15.0, -85.0), LatLng(40.0, -85.0)],
    [LatLng(15.0, -90.0), LatLng(40.0, -90.0)],
    [LatLng(15.0, -95.0), LatLng(40.0, -95.0)],
  ];

  // Key Strategic City Points
  final List<Map<String, dynamic>> _tacticalCities = const [
    {'name': 'MIAMI', 'pos': LatLng(25.76, -80.19), 'alert': true},
    {'name': 'TAMPA', 'pos': LatLng(27.95, -82.45), 'alert': true},
    {'name': 'TALLAHASSEE', 'pos': LatLng(30.44, -84.28), 'alert': true},
    {'name': 'ORLANDO', 'pos': LatLng(28.54, -81.38), 'alert': false},
    {'name': 'JACKSONVILLE', 'pos': LatLng(30.33, -81.65), 'alert': false},
    {'name': 'NEW ORLEANS', 'pos': LatLng(29.95, -90.07), 'alert': false},
    {'name': 'HAVANA', 'pos': LatLng(23.11, -82.37), 'alert': false},
    {'name': 'NASSAU', 'pos': LatLng(25.03, -77.39), 'alert': false},
    {'name': 'KEY WEST', 'pos': LatLng(24.55, -81.78), 'alert': true},
  ];

  // Simulated Lightning Strikes
  final List<LatLng> _lightningStrikes = const [
    LatLng(26.4, -80.7),
    LatLng(25.2, -79.5),
    LatLng(26.9, -81.3),
    LatLng(24.7, -80.3),
    LatLng(27.3, -82.2),
    LatLng(25.8, -78.8),
    LatLng(28.1, -83.1),
    LatLng(24.9, -81.6),
  ];

  // 24-Hour Autonomous Severe Weather Engine & Telemetry State
  final LatLng _userLocation = const LatLng(25.7617, -80.1918); // Miami Tactical Station
  double _liveTemperature = 28.4;
  double _liveWindSpeed = 36.5;
  double _liveWindDirection = 130.0;
  double _livePrecipitation = 2.4;
  double _liveCape = 420.0;
  bool _isDangerCondition = false;
  bool _isAutonomousGuardActive = true;
  Timer? _weatherPollTimer;
  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();

  String _getWindCardinal(double degrees) {
    const directions = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    final idx = (((degrees + 22.5) % 360) / 45).floor();
    return directions[idx % 8];
  }

  Future<void> _saveUserLocation() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('user_latitude', _userLocation.latitude);
      await prefs.setDouble('user_longitude', _userLocation.longitude);
    } catch (_) {}
  }

  Future<void> _initNotifications() async {
    try {
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const initSettings = InitializationSettings(android: androidInit);
      await _notificationsPlugin.initialize(initSettings);

      final androidPlatform = _notificationsPlugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await androidPlatform?.requestNotificationsPermission();
    } catch (_) {}
  }

  Future<void> _triggerSevereWeatherAlert({
    required double windSpeed,
    required double precipitation,
    bool isSimulation = false,
  }) async {
    try {
      const androidDetails = AndroidNotificationDetails(
        'severe_weather_channel',
        'Severe Weather Alerts',
        channelDescription: 'High-priority heads-up emergency severe weather alerts',
        importance: Importance.max,
        priority: Priority.high,
        enableVibration: true,
        playSound: true,
      );
      const notificationDetails = NotificationDetails(android: androidDetails);

      await _notificationsPlugin.show(
        999,
        isSimulation ? '⚠️ [TEST] EXTREME WEATHER WARNING' : '⚠️ EXTREME WEATHER WARNING',
        'Severe wind (${windSpeed.toStringAsFixed(1)} km/h) & thunderstorm detected near your coordinates! Precipitation: ${precipitation.toStringAsFixed(1)} mm. Take immediate shelter.',
        notificationDetails,
      );
    } catch (_) {}
  }

  Future<void> _fetchOpenMeteoWeather() async {
    try {
      final url = Uri.parse(
        'https://api.open-meteo.com/v1/forecast?latitude=${_userLocation.latitude}&longitude=${_userLocation.longitude}&current=temperature_2m,precipitation,rain,weather_code,wind_speed_10m,wind_direction_10m&hourly=cape'
      );
      final response = await http.get(url).timeout(const Duration(seconds: 12));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final current = data['current'] ?? {};
        final temp = (current['temperature_2m'] as num?)?.toDouble() ?? _liveTemperature;
        final wind = (current['wind_speed_10m'] as num?)?.toDouble() ?? _liveWindSpeed;
        final windDir = (current['wind_direction_10m'] as num?)?.toDouble() ?? _liveWindDirection;
        final precip = (current['precipitation'] as num?)?.toDouble() ?? _livePrecipitation;
        final wCode = (current['weather_code'] as num?)?.toInt() ?? 0;

        final hourly = data['hourly'] ?? {};
        final capeList = hourly['cape'] as List<dynamic>? ?? [];
        final double maxCape = capeList.isNotEmpty ? (capeList.first as num?)?.toDouble() ?? 0.0 : 0.0;

        final bool extremeRain = precip > 10.0 || const [65, 82, 95, 96, 99].contains(wCode);
        final bool highWind = wind > 50.0;
        final bool severeThunder = maxCape > 1000.0 || const [95, 96, 99].contains(wCode);
        final bool danger = extremeRain || highWind || severeThunder;

        if (mounted) {
          setState(() {
            _liveTemperature = temp;
            _liveWindSpeed = wind;
            _liveWindDirection = windDir;
            _livePrecipitation = precip;
            _liveCape = maxCape;
            _isDangerCondition = danger;
          });
        }

        if (danger) {
          _triggerSevereWeatherAlert(windSpeed: wind, precipitation: precip);
        }
      }
    } catch (_) {}
  }

  late AnimationController _rotationController;

  @override
  void initState() {
    super.initState();
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();

    _loadRewardedAd();
    _fetchRadarData();
    _saveUserLocation();
    _initNotifications();
    _fetchOpenMeteoWeather();
    _weatherPollTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _fetchOpenMeteoWeather();
    });
  }

  @override
  void dispose() {
    _weatherPollTimer?.cancel();
    _rotationController.dispose();
    _loopTimer?.cancel();
    _cooldownTimer?.cancel();
    _rewardedAd?.dispose();
    super.dispose();
  }

  void _loadRewardedAd() {
    RewardedAd.load(
      adUnitId: _adUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          setState(() {
            _rewardedAd = ad;
            _isAdLoaded = true;
          });
        },
        onAdFailedToLoad: (error) {
          setState(() {
            _rewardedAd = null;
            _isAdLoaded = false;
          });
        },
      ),
    );
  }

  void _showRewardedAd(VoidCallback onRewardEarned) {
    if (_rewardedAd != null) {
      _rewardedAd!.fullScreenContentCallback = FullScreenContentCallback(
        onAdDismissedFullScreenContent: (ad) {
          ad.dispose();
          _loadRewardedAd();
        },
        onAdFailedToShowFullScreenContent: (ad, error) {
          ad.dispose();
          _loadRewardedAd();
          onRewardEarned();
        },
      );

      _rewardedAd!.show(
        onUserEarnedReward: (ad, reward) {
          onRewardEarned();
        },
      );
      _rewardedAd = null;
      setState(() {
        _isAdLoaded = false;
      });
    } else {
      onRewardEarned();
      _loadRewardedAd();
    }
  }

  void _startCooldown() {
    setState(() {
      _cooldownSeconds = 45;
    });
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_cooldownSeconds > 1) {
        setState(() {
          _cooldownSeconds--;
        });
      } else {
        timer.cancel();
        setState(() {
          _cooldownSeconds = 0;
        });
      }
    });
  }

  Future<void> _fetchRadarData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final response = await http
          .get(Uri.parse('https://api.rainviewer.com/public/weather-maps.json'))
          .timeout(const Duration(seconds: 12));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final hostStr = data['host'] ?? 'https://tilecache.rainviewer.com';
        final radar = data['radar'];
        final pastList = radar['past'] as List;
        final nowcastList = radar['nowcast'] as List;

        final List<RadarFrame> parsedFrames = [];
        int idx = 0;

        for (var item in pastList) {
          final time = item['time'] as int;
          final path = item['path'] as String;
          final dt = DateTime.fromMillisecondsSinceEpoch(time * 1000);
          final label =
              '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

          parsedFrames.add(RadarFrame(
            time: time,
            path: path,
            isPast: true,
            isNowcast: false,
            timeLabel: label,
            frameIndex: idx,
          ));
          idx++;
        }

        for (var item in nowcastList) {
          final time = item['time'] as int;
          final path = item['path'] as String;
          final dt = DateTime.fromMillisecondsSinceEpoch(time * 1000);
          final label =
              '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')} (FCST)';

          parsedFrames.add(RadarFrame(
            time: time,
            path: path,
            isPast: false,
            isNowcast: true,
            timeLabel: label,
            frameIndex: idx,
          ));
          idx++;
        }

        setState(() {
          _host = hostStr;
          _frames = parsedFrames;
          _pastCount = pastList.length;
          _unlockedMaxIndex =
              (_pastCount < parsedFrames.length) ? _pastCount : parsedFrames.length - 1;
          _currentFrameIndex = (_pastCount - 1).clamp(0, parsedFrames.length - 1);
          _isLoading = false;
        });
      } else {
        throw Exception('Server returned status ${response.statusCode}');
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to load Doppler network: $e';
        _isLoading = false;
      });
    }
  }

  void _togglePlayPause() {
    setState(() {
      _isPlaying = !_isPlaying;
    });

    if (_isPlaying) {
      _loopTimer?.cancel();
      _loopTimer = Timer.periodic(const Duration(milliseconds: 700), (timer) {
        if (_frames.isEmpty) return;
        setState(() {
          if (_currentFrameIndex >= _unlockedMaxIndex) {
            _currentFrameIndex = 0;
          } else {
            _currentFrameIndex++;
          }
        });
      });
    } else {
      _loopTimer?.cancel();
    }
  }

  void _promptUnlockAd(int targetIndex) {
    final targetFrame = _frames[targetIndex];
    final forecastMins = (targetIndex - _pastCount + 1) * 15;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF121820),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF2C384A), width: 1.5),
        ),
        icon: const Icon(Icons.lock, color: Color(0xFF00E5FF), size: 38),
        title: Text(
          'UNLOCK +$forecastMins MIN PREDICTION',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontFamily: 'Monospace',
            fontWeight: FontWeight.bold,
            fontSize: 15,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Watch a short video to unlock the next 15-minute Doppler radar prediction frame (${targetFrame.timeLabel}).',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey, fontSize: 13),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF1E2632),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF2C384A)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.ondemand_video, color: Color(0xFFFF9500), size: 22),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'AdMob Rewarded Unit Ready',
                      style: TextStyle(
                        color: Color(0xFFFF9500),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'Monospace',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CANCEL', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00E5FF),
              foregroundColor: Colors.black,
            ),
            onPressed: _cooldownSeconds > 0
                ? null
                : () {
                    Navigator.pop(ctx);
                    _showRewardedAd(() {
                      setState(() {
                        if (_unlockedMaxIndex < _frames.length - 1) {
                          _unlockedMaxIndex++;
                          _currentFrameIndex = _unlockedMaxIndex;
                        }
                      });
                      _startCooldown();
                    });
                  },
            child: const Text('WATCH VIDEO', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showBasemapPicker() => _showMapLayerSwitcher();

  void _showMapLayerSwitcher() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setSheetState) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
          decoration: BoxDecoration(
            color: const Color(0xFF121820).withOpacity(0.97),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.5), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.8),
                blurRadius: 24,
                spreadRadius: 4,
              ),
            ],
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Modal Header
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0xFF00E5FF).withOpacity(0.15),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.6)),
                          ),
                          child: const Icon(Icons.layers, color: Color(0xFF00E5FF), size: 20),
                        ),
                        const SizedBox(width: 12),
                        const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'MAP LAYER SWITCHER',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'Monospace',
                                letterSpacing: 0.8,
                              ),
                            ),
                            Text(
                              'Multi-Basemap Engine & Live Overlays',
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 11,
                                fontFamily: 'Monospace',
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.grey),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const Divider(color: Color(0xFF2C384A), height: 26),

                // SECTION 1: MULTI-BASEMAP SELECTION
                const Row(
                  children: [
                    Icon(Icons.public, color: Color(0xFF00E5FF), size: 16),
                    SizedBox(width: 8),
                    Text(
                      'BASEMAP STYLES (100% Free, No API Keys)',
                      style: TextStyle(
                        color: Color(0xFF00E5FF),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'Monospace',
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                GridView.count(
                  crossAxisCount: 2,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollExceptionScrollPhysics(),
                  childAspectRatio: 2.2,
                  children: basemapLayers.keys.map((name) {
                    final isSelected = _currentBasemap == name;
                    final IconData iconData;
                    final String desc;
                    switch (name) {
                      case 'Satellite Imagery':
                        iconData = Icons.satellite_alt;
                        desc = 'ArcGIS Global Imagery';
                        break;
                      case 'Standard Street':
                        iconData = Icons.map_outlined;
                        desc = 'OpenStreetMap Streets';
                        break;
                      case 'Topographic Terrain':
                        iconData = Icons.terrain;
                        desc = 'OpenTopoMap Relief';
                        break;
                      default:
                        iconData = Icons.dark_mode;
                        desc = 'CartoDB Dark Tactical';
                    }

                    return InkWell(
                      onTap: () {
                        setSheetState(() {
                          _currentBasemap = name;
                        });
                        setState(() {
                          _currentBasemap = name;
                        });
                      },
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? const Color(0xFF00E5FF).withOpacity(0.18)
                              : const Color(0xFF1E2632),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: isSelected
                                ? const Color(0xFF00E5FF)
                                : const Color(0xFF2C384A),
                            width: isSelected ? 1.5 : 1.0,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              iconData,
                              color: isSelected ? const Color(0xFF00E5FF) : Colors.grey,
                              size: 22,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: isSelected ? const Color(0xFF00E5FF) : Colors.white,
                                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                      fontFamily: 'Monospace',
                                      fontSize: 11,
                                    ),
                                  ),
                                  Text(
                                    desc,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: isSelected ? const Color(0xFF00E5FF).withOpacity(0.8) : Colors.grey,
                                      fontSize: 9,
                                      fontFamily: 'Monospace',
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (isSelected)
                              const Icon(Icons.check_circle, color: Color(0xFF00E5FF), size: 16),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
                ),

                const Divider(color: Color(0xFF2C384A), height: 26),

                // SECTION 2: OVERLAY LAYERS TOGGLE
                const Row(
                  children: [
                    Icon(Icons.tune, color: Color(0xFF00E5FF), size: 16),
                    SizedBox(width: 8),
                    Text(
                      'OVERLAY LAYERS TOGGLE',
                      style: TextStyle(
                        color: Color(0xFF00E5FF),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'Monospace',
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // 1. Doppler Rain Radar
                _buildOverlayToggleTile(
                  title: 'Doppler Rain Radar',
                  subtitle: 'RainViewer Real-Time & Forecast Tiles',
                  icon: Icons.water_drop,
                  iconColor: const Color(0xFF00E5FF),
                  value: _showRainRadar,
                  onChanged: (val) {
                    setSheetState(() {
                      _showRainRadar = val;
                    });
                    setState(() {
                      _showRainRadar = val;
                    });
                  },
                ),

                // 2. Hurricane Helene Track & Cone
                _buildOverlayToggleTile(
                  title: 'Hurricane Helene Track',
                  subtitle: 'Red Trajectory + Cyan Cone of Uncertainty + Storm Marker',
                  icon: Icons.cyclone,
                  iconColor: const Color(0xFFFF3B30),
                  value: _showStormTrack,
                  onChanged: (val) {
                    setSheetState(() {
                      _showStormTrack = val;
                    });
                    setState(() {
                      _showStormTrack = val;
                    });
                  },
                ),

                // 3. Live Lightning Pulse Sparks
                _buildOverlayToggleTile(
                  title: 'Live Lightning Pulse Sparks',
                  subtitle: 'High-frequency convective discharge cluster markers',
                  icon: Icons.flash_on,
                  iconColor: const Color(0xFFFFD600),
                  value: _showLightning,
                  onChanged: (val) {
                    setSheetState(() {
                      _showLightning = val;
                    });
                    setState(() {
                      _showLightning = val;
                    });
                  },
                ),

                // 4. Geographic Boundaries & Coastlines
                _buildOverlayToggleTile(
                  title: 'Coastlines & Country Borders',
                  subtitle: 'High-contrast nautical lat/lon grid & city nodes',
                  icon: Icons.map,
                  iconColor: const Color(0xFF34C759),
                  value: _showBorders,
                  onChanged: (val) {
                    setSheetState(() {
                      _showBorders = val;
                    });
                    setState(() {
                      _showBorders = val;
                    });
                  },
                ),

                const SizedBox(height: 16),
                const Divider(color: Color(0xFF2C384A), thickness: 1),
                const SizedBox(height: 12),

                // SECTION 3: 24-HOUR AUTONOMOUS SEVERE WEATHER GUARD
                Row(
                  children: [
                    const Icon(Icons.security, color: Color(0xFF34C759), size: 18),
                    const SizedBox(width: 8),
                    const Text(
                      '24H AUTONOMOUS SEVERE WEATHER GUARD',
                      style: TextStyle(
                        color: Color(0xFF34C759),
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'Monospace',
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF16202C),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF2C384A)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.schedule, color: Color(0xFF00E5FF), size: 16),
                              SizedBox(width: 6),
                              Text(
                                'Background Worker (15m Interval)',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  fontFamily: 'Monospace',
                                ),
                              ),
                            ],
                          ),
                          Switch(
                            value: _isAutonomousGuardActive,
                            activeColor: const Color(0xFF34C759),
                            onChanged: (val) {
                              setSheetState(() {
                                _isAutonomousGuardActive = val;
                              });
                              setState(() {
                                _isAutonomousGuardActive = val;
                              });
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Autonomous offline-first WorkManager periodically samples Open-Meteo API for precipitation (>10mm), wind speed (>50km/h), and CAPE index (>1000 J/kg) without cloud dependencies.',
                        style: TextStyle(color: Colors.grey, fontSize: 10),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'TEMP: ${_liveTemperature.toStringAsFixed(1)}°C',
                            style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 11, fontFamily: 'Monospace'),
                          ),
                          Text(
                            'WIND: ${_liveWindSpeed.toStringAsFixed(1)} km/h',
                            style: const TextStyle(color: Color(0xFFFF9500), fontSize: 11, fontFamily: 'Monospace'),
                          ),
                          Text(
                            'RAIN: ${_livePrecipitation.toStringAsFixed(1)} mm',
                            style: const TextStyle(color: Color(0xFF34C759), fontSize: 11, fontFamily: 'Monospace'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () {
                            setSheetState(() {
                              _isDangerCondition = !_isDangerCondition;
                            });
                            setState(() {
                              _isDangerCondition = _isDangerCondition;
                            });
                            _triggerSevereWeatherAlert(
                              windSpeed: 68.4,
                              precipitation: 14.8,
                              isSimulation: true,
                            );
                            Navigator.pop(context);
                          },
                          icon: const Icon(Icons.notification_important, color: Colors.white, size: 16),
                          label: Text(
                            _isDangerCondition ? 'RESET SEVERE ALERT SIMULATION' : 'TEST HEADS-UP ALERT & DANGER CIRCLE',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'Monospace',
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _isDangerCondition ? const Color(0xFF34C759) : const Color(0xFFFF3B30),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            shape: RoundedCornerShape(8),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOverlayToggleTile({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color iconColor,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1E2632),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: value ? iconColor.withOpacity(0.5) : const Color(0xFF2C384A),
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.18),
                shape: BoxShape.circle,
                border: Border.all(color: iconColor.withOpacity(0.5)),
              ),
              child: Icon(icon, color: iconColor, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      fontFamily: 'Monospace',
                    ),
                  ),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: Colors.grey,
                      fontSize: 10,
                      fontFamily: 'Monospace',
                    ),
                  ),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeColor: iconColor,
              activeTrackColor: iconColor.withOpacity(0.3),
              inactiveThumbColor: Colors.grey,
              inactiveTrackColor: const Color(0xFF0A0E14),
            ),
          ],
        ),
      ),
    );
  }

  void _showStormDetailSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0xFF121820).withOpacity(0.96),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: const Color(0xFFFF3B30).withOpacity(0.5), width: 1.5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF3B30).withOpacity(0.2),
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFFFF3B30)),
                      ),
                      child: const Icon(Icons.cyclone, color: Color(0xFFFF3B30), size: 24),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _stormHelene.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.black,
                            fontFamily: 'Monospace',
                          ),
                        ),
                        Text(
                          _stormHelene.category,
                          style: const TextStyle(
                            color: Color(0xFFFF3B30),
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'Monospace',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.grey),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ],
            ),
            const Divider(color: Color(0xFF2C384A), height: 24),
            Row(
              children: [
                Expanded(
                  child: _buildTelemetryMetricCard(
                    icon: Icons.air,
                    label: 'MAX SUSTAINED WIND',
                    value: '${_stormHelene.windSpeedMph} MPH',
                    subValue: '${_stormHelene.windSpeedKmh} KM/H (CATEGORY 4)',
                    color: const Color(0xFFFF3B30),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _buildTelemetryMetricCard(
                    icon: Icons.compress,
                    label: 'CENTRAL PRESSURE',
                    value: '${_stormHelene.pressureHpa} hPa',
                    subValue: 'RAPID DEEPENING',
                    color: const Color(0xFF00E5FF),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _buildTelemetryMetricCard(
                    icon: Icons.explore,
                    label: 'MOVEMENT SPEED',
                    value: _stormHelene.movement,
                    subValue: 'HEADING NORTHWEST',
                    color: const Color(0xFFFF9500),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _buildTelemetryMetricCard(
                    icon: Icons.timer,
                    label: 'LANDFALL ETA',
                    value: _stormHelene.landfallEta,
                    subValue: 'FLORIDA BIG BEND',
                    color: const Color(0xFF34C759),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF3B30),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () {
                  Navigator.pop(ctx);
                  _mapController.move(_stormHelene.currentPosition, 6.5);
                },
                icon: const Icon(Icons.my_location),
                label: const Text(
                  'CENTER EYE ON RADAR',
                  style: TextStyle(fontWeight: FontWeight.bold, fontFamily: 'Monospace'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTelemetryMetricCard({
    required IconData icon,
    required String label,
    required String value,
    required String subValue,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A222D),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.grey,
                    fontSize: 8.5,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'Monospace',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              fontFamily: 'Monospace',
            ),
          ),
          Text(
            subValue,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.grey,
              fontSize: 8.5,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(65),
        child: Container(
          color: const Color(0xFF121820),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: SafeArea(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                        color: Color(0xFF34C759),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text(
                          'TACTICAL RADAR v5.0',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'Monospace',
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          _frames.isNotEmpty
                              ? 'FRAME: ${_frames[_currentFrameIndex].timeLabel}'
                              : 'ONLINE LINK',
                          style: const TextStyle(
                            color: Color(0xFF00E5FF),
                            fontFamily: 'Monospace',
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                Row(
                  children: [
                    GestureDetector(
                      onTap: _showStormDetailSheet,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF3B30).withOpacity(0.2),
                          border: Border.all(color: const Color(0xFFFF3B30)),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.cyclone, color: Color(0xFFFF3B30), size: 14),
                            SizedBox(width: 5),
                            Text(
                              'CAT-4 HELENE',
                              style: TextStyle(
                                color: Color(0xFFFF3B30),
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'Monospace',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    IconButton(
                      icon: const Icon(Icons.refresh, color: Color(0xFF00E5FF)),
                      onPressed: _fetchRadarData,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      body: _isLoading
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Color(0xFF00E5FF)),
                  SizedBox(height: 16),
                  Text(
                    'DOWNLINKING DOPPLER SATELLITE TILES...',
                    style: TextStyle(color: Color(0xFF00E5FF), fontFamily: 'Monospace'),
                  ),
                ],
              ),
            )
          : _errorMessage != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.cloud_off, color: Color(0xFFFF3B30), size: 64),
                      const SizedBox(height: 16),
                      Text(_errorMessage!, style: const TextStyle(color: Colors.white)),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: _fetchRadarData,
                        child: const Text('RETRY CONNECTION'),
                      ),
                    ],
                  ),
                )
              : Stack(
                  children: [
                    // Main FlutterMap with multi-layer geospatial engine
                    FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(
                        initialCenter: _initialCenter,
                        initialZoom: 5.2,
                        minZoom: 3.0,
                        maxZoom: 10.0,
                      ),
                      children: [
                        // 1. Dynamic Base Map (Dark Tactical, Real Satellite, Standard Map, Terrain)
                        TileLayer(
                          key: ValueKey(_currentBasemap),
                          urlTemplate: basemapLayers[_currentBasemap]!,
                          userAgentPackageName: 'com.live.hurricanetracker',
                        ),

                        // 2. High-Contrast Tactical Geography Overlay (Borders, Coastlines & Grids)
                        if (_showBorders) ...[
                          // Latitude & Longitude Nautical Grid
                          PolylineLayer(
                            polylines: _gridLines
                                .map(
                                  (line) => Polyline(
                                    points: line,
                                    color: const Color(0xFF2C384A).withOpacity(0.5),
                                    strokeWidth: 1.0,
                                  ),
                                )
                                .toList(),
                          ),

                          // Coastlines & Country Outlines (Ensures crystal-clear geographic visibility)
                          PolylineLayer(
                            polylines: [
                              Polyline(
                                points: _floridaCoast,
                                color: const Color(0xFF00E5FF).withOpacity(0.85),
                                strokeWidth: 2.2,
                              ),
                              Polyline(
                                points: _cubaCoast,
                                color: const Color(0xFF00E5FF).withOpacity(0.85),
                                strokeWidth: 2.2,
                              ),
                              Polyline(
                                points: _eastCoast,
                                color: const Color(0xFF00E5FF).withOpacity(0.75),
                                strokeWidth: 1.8,
                              ),
                            ],
                          ),

                          // City Markers & Tactical Base Labels
                          MarkerLayer(
                            markers: _tacticalCities.map((city) {
                              final isAlert = city['alert'] as bool;
                              return Marker(
                                point: city['pos'] as LatLng,
                                width: 90,
                                height: 28,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 6,
                                      height: 6,
                                      decoration: BoxDecoration(
                                        color: isAlert
                                            ? const Color(0xFFFF3B30)
                                            : const Color(0xFF00E5FF),
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      city['name'] as String,
                                      style: TextStyle(
                                        color: isAlert
                                            ? const Color(0xFFFF3B30)
                                            : Colors.white.withOpacity(0.85),
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                        fontFamily: 'Monospace',
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }).toList(),
                          ),
                        ],

                        // 3. RainViewer Real-Time Doppler Radar Tile Layer
                        if (_showRainRadar && _frames.isNotEmpty)
                          TileLayer(
                            urlTemplate:
                                '$_host${_frames[_currentFrameIndex].path}/256/{z}/{x}/{y}/2/1_1.png',
                            opacity: 0.85,
                          ),

                        // 4. Hurricane Forecast Cone (Cone of Uncertainty) Polygon
                        if (_showStormTrack)
                          PolygonLayer(
                            polygons: [
                              Polygon(
                                points: _forecastCone,
                                color: const Color(0xFF00E5FF).withOpacity(0.22),
                                borderColor: const Color(0xFF00E5FF).withOpacity(0.8),
                                borderStrokeWidth: 2.0,
                              ),
                            ],
                          ),

                        // 5. Hurricane Historical & Forecast Path Lines
                        if (_showStormTrack)
                          PolylineLayer(
                            polylines: [
                              // Historical Dotted Red Path
                              Polyline(
                                points: _historicalTrack,
                                color: const Color(0xFFFF3B30),
                                strokeWidth: 3.5,
                                isDotted: true,
                              ),
                              // Forecast Projected Trajectory
                              Polyline(
                                points: _forecastTrack,
                                color: const Color(0xFF00E5FF),
                                strokeWidth: 3.0,
                              ),
                            ],
                          ),

                        // 6. Lightning Strike Sparks Layer
                        if (_showLightning)
                          MarkerLayer(
                            markers: _lightningStrikes.map((pt) {
                              return Marker(
                                point: pt,
                                width: 26,
                                height: 26,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFFD600).withOpacity(0.25),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: const Color(0xFFFFD600).withOpacity(0.8),
                                      width: 1,
                                    ),
                                  ),
                                  child: const Center(
                                    child: Icon(
                                      Icons.flash_on,
                                      color: Color(0xFFFFD600),
                                      size: 16,
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),

                        // 7. Hurricane Helene Dynamic Eye & Category Badge Marker
                        if (_showStormTrack)
                          MarkerLayer(
                            markers: [
                              // Landfall Forecast Point Marker
                              const Marker(
                                point: LatLng(30.6, -84.6),
                                width: 140,
                                height: 40,
                                child: Column(
                                  children: [
                                    Icon(Icons.warning, color: Color(0xFFFF3B30), size: 16),
                                    Text(
                                      'LANDFALL TARGET',
                                      style: TextStyle(
                                        color: Color(0xFFFF3B30),
                                        fontSize: 8,
                                        fontWeight: FontWeight.black,
                                        fontFamily: 'Monospace',
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // Storm Eye Active Marker
                              Marker(
                                point: _stormHelene.currentPosition,
                                width: 150,
                                height: 75,
                                child: GestureDetector(
                                  onTap: _showStormDetailSheet,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFFF3B30),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: const Text(
                                          'CAT-4 HELENE',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 9,
                                            fontWeight: FontWeight.black,
                                            fontFamily: 'Monospace',
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      RotationTransition(
                                        turns: _rotationController,
                                        child: Stack(
                                          alignment: Alignment.center,
                                          children: [
                                            Container(
                                              width: 44,
                                              height: 44,
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: const Color(0xFFFF3B30).withOpacity(0.3),
                                                border: Border.all(
                                                  color: const Color(0xFFFF3B30),
                                                  width: 2.5,
                                                ),
                                              ),
                                            ),
                                            const Icon(
                                              Icons.cyclone,
                                              color: Color(0xFFFF3B30),
                                              size: 28,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),

                        // 8. 24-Hour Autonomous Severe Weather Danger Circle Layer
                        if (_isDangerCondition)
                          CircleLayer(
                            circles: [
                              CircleMarker(
                                point: _userLocation,
                                radius: 60.0,
                                useRadiusInMeter: false,
                                color: const Color(0xFFFF3B30).withOpacity(0.35),
                                borderColor: const Color(0xFFFF3B30),
                                borderStrokeWidth: 2.5,
                              ),
                              CircleMarker(
                                point: _userLocation,
                                radius: 100.0,
                                useRadiusInMeter: false,
                                color: const Color(0xFFFF3B30).withOpacity(0.18),
                                borderColor: const Color(0xFFFF3B30).withOpacity(0.6),
                                borderStrokeWidth: 1.5,
                              ),
                            ],
                          ),

                        // 9. Local Ground Station / User Location Marker
                        MarkerLayer(
                          markers: [
                            Marker(
                              point: _userLocation,
                              width: 100,
                              height: 52,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: _isDangerCondition ? const Color(0xFFFF3B30) : const Color(0xFF00E5FF),
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: (_isDangerCondition ? const Color(0xFFFF3B30) : const Color(0xFF00E5FF)).withOpacity(0.65),
                                          blurRadius: 10,
                                          spreadRadius: 2,
                                        ),
                                      ],
                                    ),
                                    child: const Icon(Icons.my_location, color: Colors.white, size: 14),
                                  ),
                                  const SizedBox(height: 2),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF0A0E14).withOpacity(0.9),
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(
                                        color: _isDangerCondition ? const Color(0xFFFF3B30) : const Color(0xFF00E5FF),
                                        width: 1,
                                      ),
                                    ),
                                    child: Text(
                                      _isDangerCondition ? '⚠️ DANGER RADIUS' : 'LOCAL STATION',
                                      style: TextStyle(
                                        color: _isDangerCondition ? const Color(0xFFFF3B30) : const Color(0xFF00E5FF),
                                        fontSize: 7.5,
                                        fontWeight: FontWeight.bold,
                                        fontFamily: 'Monospace',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),

                    // 24-Hour Autonomous Severe Weather Guard Status Banner
                    Positioned(
                      top: 12,
                      left: 175,
                      right: 125,
                      child: Center(
                        child: GestureDetector(
                          onTap: _showMapLayerSwitcher,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                            decoration: BoxDecoration(
                              color: const Color(0xFF121820).withOpacity(0.95),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: _isDangerCondition ? const Color(0xFFFF3B30) : const Color(0xFF34C759),
                                width: 1.4,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: (_isDangerCondition ? const Color(0xFFFF3B30) : const Color(0xFF34C759)).withOpacity(0.35),
                                  blurRadius: 8,
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: _isDangerCondition ? const Color(0xFFFF3B30) : const Color(0xFF34C759),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Icon(
                                  _isDangerCondition ? Icons.warning : Icons.shield,
                                  color: _isDangerCondition ? const Color(0xFFFF3B30) : const Color(0xFF34C759),
                                  size: 14,
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    _isDangerCondition
                                        ? '⚠️ SEVERE ALERT ACTIVE'
                                        : '🛡️ 24h Autonomous Guard Active (Background alerts enabled without cloud)',
                                    style: TextStyle(
                                      color: _isDangerCondition ? const Color(0xFFFF3B30) : const Color(0xFF34C759),
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.bold,
                                      fontFamily: 'Monospace',
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),

                    // Top Left Telemetry Grid
                    Positioned(
                      top: 12,
                      left: 12,
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF121820).withOpacity(0.92),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF2C384A)),
                        ),
                        child: const Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'GRID: 25.76°N, 80.19°W',
                              style: TextStyle(
                                color: Color(0xFF00E5FF),
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'Monospace',
                              ),
                            ),
                            Text(
                              'RADAR: GULF-DOPPLER #04',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontFamily: 'Monospace',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // Tactical Live Weather Sensors: Wind Direction Gauge & Live Temperature Pill
                    Positioned(
                      top: 114,
                      left: 12,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Live Temperature Pill
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                            decoration: BoxDecoration(
                              color: const Color(0xFF121820).withOpacity(0.92),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.6), width: 1.2),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.thermostat, color: Color(0xFF00E5FF), size: 14),
                                const SizedBox(width: 4),
                                Text(
                                  '${_liveTemperature.toStringAsFixed(1)}°C',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    fontFamily: 'Monospace',
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 6),

                          // Wind Direction Rotating Compass Needle Gauge
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            decoration: BoxDecoration(
                              color: const Color(0xFF121820).withOpacity(0.92),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: _isDangerCondition ? const Color(0xFFFF3B30) : const Color(0xFFFF9500).withOpacity(0.6),
                                width: 1.2,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    Container(
                                      width: 32,
                                      height: 32,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.4), width: 1),
                                        color: const Color(0xFF16202C),
                                      ),
                                      child: const Align(
                                        alignment: Alignment.topCenter,
                                        child: Text(
                                          'N',
                                          style: TextStyle(
                                            color: Color(0xFF00E5FF),
                                            fontSize: 7,
                                            fontWeight: FontWeight.bold,
                                            fontFamily: 'Monospace',
                                          ),
                                        ),
                                      ),
                                    ),
                                    Transform.rotate(
                                      angle: (_liveWindDirection * math.pi / 180),
                                      child: const Icon(
                                        Icons.navigation,
                                        color: Color(0xFFFF9500),
                                        size: 17,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(width: 7),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      'WIND: ${_liveWindSpeed.toStringAsFixed(1)} km/h',
                                      style: TextStyle(
                                        color: _isDangerCondition ? const Color(0xFFFF3B30) : const Color(0xFFFF9500),
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.bold,
                                        fontFamily: 'Monospace',
                                      ),
                                    ),
                                    Text(
                                      'DIR: ${_liveWindDirection.toStringAsFixed(0)}° ${_getWindCardinal(_liveWindDirection)}',
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 8.5,
                                        fontFamily: 'Monospace',
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Floating Top-Right "LAYERS" Button
                    Positioned(
                      top: 12,
                      right: 12,
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: _showMapLayerSwitcher,
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                            decoration: BoxDecoration(
                              color: const Color(0xFF121820).withOpacity(0.95),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: const Color(0xFF00E5FF), width: 1.5),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF00E5FF).withOpacity(0.35),
                                  blurRadius: 10,
                                  spreadRadius: 1,
                                ),
                              ],
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.layers, color: Color(0xFF00E5FF), size: 18),
                                SizedBox(width: 8),
                                Text(
                                  'LAYERS',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    fontFamily: 'Monospace',
                                    letterSpacing: 1.1,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),

                    // dBZ Intensity Legend (positioned beneath Top-Left Telemetry)
                    Positioned(
                      top: 68,
                      left: 12,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF121820).withOpacity(0.92),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF2C384A)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'dBZ INTENSITY',
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 8,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'Monospace',
                              ),
                            ),
                            const SizedBox(height: 3),
                            Container(
                              width: 90,
                              height: 5,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(3),
                                gradient: const LinearGradient(
                                  colors: [
                                    Color(0xFF34C759),
                                    Color(0xFFFF9500),
                                    Color(0xFFFF3B30),
                                    Color(0xFFA200FF),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // Floating Tactical Layer Switcher (Right Side FABs)
                    Positioned(
                      right: 12,
                      top: 62,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF121820).withOpacity(0.92),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: const Color(0xFF2C384A)),
                        ),
                        child: Column(
                          children: [
                            _buildLayerFab(
                              icon: Icons.layers,
                              label: 'LAYERS',
                              isActive: true,
                              activeColor: const Color(0xFF00E5FF),
                              onTap: _showMapLayerSwitcher,
                            ),
                            const SizedBox(height: 8),
                            _buildLayerFab(
                              icon: Icons.water_drop,
                              label: 'RADAR',
                              isActive: _showRainRadar,
                              activeColor: const Color(0xFF00E5FF),
                              onTap: () {
                                setState(() {
                                  _showRainRadar = !_showRainRadar;
                                });
                              },
                            ),
                            const SizedBox(height: 8),
                            _buildLayerFab(
                              icon: Icons.cyclone,
                              label: 'STORM',
                              isActive: _showStormTrack,
                              activeColor: const Color(0xFFFF3B30),
                              onTap: () {
                                setState(() {
                                  _showStormTrack = !_showStormTrack;
                                });
                              },
                            ),
                            const SizedBox(height: 8),
                            _buildLayerFab(
                              icon: Icons.flash_on,
                              label: 'LIGHTNING',
                              isActive: _showLightning,
                              activeColor: const Color(0xFFFFD600),
                              onTap: () {
                                setState(() {
                                  _showLightning = !_showLightning;
                                });
                              },
                            ),
                            const SizedBox(height: 8),
                            _buildLayerFab(
                              icon: Icons.map,
                              label: 'BORDERS',
                              isActive: _showBorders,
                              activeColor: const Color(0xFF34C759),
                              onTap: () {
                                setState(() {
                                  _showBorders = !_showBorders;
                                });
                              },
                            ),
                            const SizedBox(height: 8),
                            IconButton(
                              style: IconButton.styleFrom(
                                backgroundColor: const Color(0xFF1E2632),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              icon: const Icon(Icons.my_location,
                                  color: Color(0xFF00E5FF), size: 18),
                              onPressed: () {
                                _mapController.move(_initialCenter, 5.2);
                              },
                            ),
                          ],
                        ),
                      ),
                    ),

                    // Bottom Control Timeline HUD
                    Positioned(
                      bottom: 16,
                      left: 12,
                      right: 12,
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFF121820),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: const Color(0xFF2C384A)),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.6),
                              blurRadius: 12,
                            )
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      _frames[_currentFrameIndex].isNowcast
                                          ? Icons.trending_up
                                          : Icons.history,
                                      size: 16,
                                      color: _frames[_currentFrameIndex].isNowcast
                                          ? const Color(0xFFFF9500)
                                          : const Color(0xFF00E5FF),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      'FRAME: ${_frames[_currentFrameIndex].timeLabel}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontFamily: 'Monospace',
                                      ),
                                    ),
                                  ],
                                ),
                                Text(
                                  '${_currentFrameIndex + 1} / ${_frames.length} FRAMES',
                                  style: const TextStyle(
                                    color: Colors.grey,
                                    fontSize: 11,
                                    fontFamily: 'Monospace',
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                IconButton(
                                  style: IconButton.styleFrom(
                                    backgroundColor: const Color(0xFF00E5FF),
                                    foregroundColor: Colors.black,
                                  ),
                                  icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                                  onPressed: _togglePlayPause,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Row(
                                    children: List.generate(_frames.length, (idx) {
                                      final isUnlocked = idx <= _unlockedMaxIndex;
                                      final isCurrent = idx == _currentFrameIndex;
                                      final color = isCurrent
                                          ? Colors.white
                                          : isUnlocked
                                              ? const Color(0xFF00E5FF)
                                              : const Color(0xFFFF3B30).withOpacity(0.4);

                                      return Expanded(
                                        child: GestureDetector(
                                          onTap: () {
                                            if (idx <= _unlockedMaxIndex) {
                                              setState(() {
                                                _currentFrameIndex = idx;
                                              });
                                            } else {
                                              _promptUnlockAd(idx);
                                            }
                                          },
                                          child: Container(
                                            height: isCurrent ? 24 : 16,
                                            margin: const EdgeInsets.symmetric(horizontal: 1.5),
                                            decoration: BoxDecoration(
                                              color: color,
                                              borderRadius: BorderRadius.circular(3),
                                            ),
                                            child: (!isUnlocked && idx == _unlockedMaxIndex + 1)
                                                ? const Icon(Icons.lock,
                                                    size: 10, color: Colors.white)
                                                : null,
                                          ),
                                        ),
                                      );
                                    }),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            if (_unlockedMaxIndex < _frames.length - 1)
                              SizedBox(
                                width: double.infinity,
                                height: 42,
                                child: ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF00E5FF),
                                    foregroundColor: Colors.black,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                  ),
                                  onPressed: _cooldownSeconds > 0
                                      ? null
                                      : () => _promptUnlockAd(_unlockedMaxIndex + 1),
                                  icon: Container(
                                    padding:
                                        const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFF9500),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text(
                                      'AD',
                                      style: TextStyle(
                                        color: Colors.black,
                                        fontSize: 9,
                                        fontWeight: FontWeight.black,
                                      ),
                                    ),
                                  ),
                                  label: Text(
                                    _cooldownSeconds > 0
                                        ? 'ANTI-SPAM COOLDOWN (${_cooldownSeconds}s)'
                                        : 'UNLOCK NEXT +15 MINS FORECAST',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontFamily: 'Monospace',
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              )
                            else
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF34C759).withOpacity(0.15),
                                  border: Border.all(color: const Color(0xFF34C759)),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Center(
                                  child: Text(
                                    'ALL 15-MIN RADAR FORECASTS UNLOCKED',
                                    style: TextStyle(
                                      color: Color(0xFF34C759),
                                      fontWeight: FontWeight.bold,
                                      fontSize: 11,
                                      fontFamily: 'Monospace',
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _buildLayerFab({
    required IconData icon,
    required String label,
    required bool isActive,
    required Color activeColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: isActive ? activeColor.withOpacity(0.2) : const Color(0xFF1E2632),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isActive ? activeColor : const Color(0xFF2C384A),
            width: isActive ? 1.5 : 1.0,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 18,
              color: isActive ? activeColor : Colors.grey,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                color: isActive ? activeColor : Colors.grey,
                fontSize: 7,
                fontWeight: FontWeight.bold,
                fontFamily: 'Monospace',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
