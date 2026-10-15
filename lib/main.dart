import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:battery_plus/battery_plus.dart';

import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

@override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '災害位置共有アプリ',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const LoginPage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final displayNameController = TextEditingController(text: '');
  final friendIdController = TextEditingController();

  final Battery battery = Battery();

  String myUserId = '';
  List<String> friendIds = [];

  String locationMessage = '現在地を取得してください';
  double? latitude;
  double? longitude;
  double? accuracy;
  int? batteryLevel;

  String safetyStatus = '未登録';
  bool rescueRequest = false;

  Timer? locationTimer;
  StreamSubscription<List<ConnectivityResult>>? connectivitySubscription;
  bool isNetworkConnected = false;
  bool isUploadingLocation = false;

  List<Map<String, dynamic>> relayedPeople = [];

  @override
  void initState() {
    super.initState();
    initUser();
    startConnectivityMonitoring();

    locationTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => updateLocationSilently(),
    );
  }

  @override
  void dispose() {
    locationTimer?.cancel();
    connectivitySubscription?.cancel();
    displayNameController.dispose();
    friendIdController.dispose();
    super.dispose();
  }


  Future<void> startConnectivityMonitoring() async {
    final initialResults = await Connectivity().checkConnectivity();
    await handleConnectivityChanged(initialResults);
    connectivitySubscription =
        Connectivity().onConnectivityChanged.listen(handleConnectivityChanged);
  }

  Future<void> handleConnectivityChanged(
    List<ConnectivityResult> results,
  ) async {
    final connected =
        results.any((result) => result != ConnectivityResult.none);
    final wasConnected = isNetworkConnected;
    isNetworkConnected = connected;
    if (mounted) setState(() {});
    if (connected && !wasConnected) {
      if (latitude != null && longitude != null) {
        await saveDataToFirebase();
      } else {
        await uploadPendingLocation();
      }
    }
  }

  Future<void> savePendingLocationLocally() async {
    if (latitude == null || longitude == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('pending_latitude', latitude!);
    await prefs.setDouble('pending_longitude', longitude!);
    await prefs.setDouble('pending_accuracy', accuracy ?? 0);
    await prefs.setInt('pending_battery', batteryLevel ?? -1);
    await prefs.setBool('pending_location_upload', true);
  }

  Future<void> uploadPendingLocation() async {
    if (!isNetworkConnected || myUserId.isEmpty || isUploadingLocation) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool('pending_location_upload') ?? false)) return;

    try {
      isUploadingLocation = true;
      final lat = prefs.getDouble('pending_latitude');
      final lng = prefs.getDouble('pending_longitude');
      final acc = prefs.getDouble('pending_accuracy');
      final bat = prefs.getInt('pending_battery');
      if (lat == null || lng == null) return;

      await FirebaseFirestore.instance.collection('users').doc(myUserId).set({
        'userId': myUserId,
        'displayName': displayName,
        'friendIds': friendIds,
        'latitude': lat,
        'longitude': lng,
        'accuracy': acc,
        'batteryLevel': bat != null && bat >= 0 ? bat : null,
        'safetyStatus': safetyStatus,
        'rescueRequest': rescueRequest,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await prefs.remove('pending_latitude');
      await prefs.remove('pending_longitude');
      await prefs.remove('pending_accuracy');
      await prefs.remove('pending_battery');
      await prefs.remove('pending_location_upload');
    } catch (_) {
      // 次回の再接続時に再試行
    } finally {
      isUploadingLocation = false;
    }
  }

  Future<void> initUser() async {
    final prefs = await SharedPreferences.getInstance();

    var savedUserId = prefs.getString('user_id');
    if (savedUserId == null || savedUserId.isEmpty) {
      savedUserId = 'user_${DateTime.now().microsecondsSinceEpoch}';
      await prefs.setString('user_id', savedUserId);
    }

    final savedName = prefs.getString('display_name');
    final savedFriendIds = prefs.getStringList('friend_ids') ?? [];
    final currentBatteryLevel = await getBatteryLevelSafely();
    final savedRelayedPeople = loadRelayedPeopleFromPrefs(prefs);
    // Firestore上にusersドキュメントを初期作成・更新する
    await FirebaseFirestore.instance.collection('users').doc(savedUserId).set({
      'role': 'user',
      'shared_with': savedFriendIds,
    }, SetOptions(merge: true));

    setState(() {
      myUserId = savedUserId!;
      friendIds = savedFriendIds;
      batteryLevel = currentBatteryLevel;
      relayedPeople = savedRelayedPeople;

      if (savedName != null && savedName.isNotEmpty) {
        displayNameController.text = savedName;
      }
    });

    await saveDataToFirebase();
  }

  List<Map<String, dynamic>> loadRelayedPeopleFromPrefs(
    SharedPreferences prefs,
  ) {
    final raw = prefs.getString('relayed_people_json');
    if (raw == null || raw.isEmpty) return [];

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];

      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveRelayedPeopleToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('relayed_people_json', jsonEncode(relayedPeople));
  }

  String get displayName {
    final name = displayNameController.text.trim();
    return name.isEmpty ? '名前なし' : name;
  }

  Future<int?> getBatteryLevelSafely() async {
    try {
      final level = await battery.batteryLevel;

      if (level <= 0 || level > 100) {
        return null;
      }

      return level;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveDisplayName() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('display_name', displayName);
    await saveDataToFirebase();
    setState(() {});
  }

  Future<void> saveDataToFirebase() async {
    if (myUserId.isEmpty) return;

    final currentBatteryLevel = await getBatteryLevelSafely();
    if (mounted) {
      setState(() => batteryLevel = currentBatteryLevel);
    }

    if (!isNetworkConnected) {
      await savePendingLocationLocally();
      return;
    }

    try {
      await FirebaseFirestore.instance.collection('users').doc(myUserId).set({
        'userId': myUserId,
        'displayName': displayName,
        'friendIds': friendIds,
        'latitude': latitude,
        'longitude': longitude,
        'accuracy': accuracy,
        'batteryLevel': currentBatteryLevel,
        'safetyStatus': safetyStatus,
        'rescueRequest': rescueRequest,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {
      await savePendingLocationLocally();
    }
  }

  Future<void> addFriend() async {
    final friendId = friendIdController.text.trim();

    if (friendId.isEmpty) return;

    if (friendId == myUserId) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('自分自身は友達に追加できません')));
      return;
    }

    if (friendIds.contains(friendId)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('すでに登録済みです')));
      return;
    }

    final prefs = await SharedPreferences.getInstance();

    setState(() {
      friendIds.add(friendId);
    });

    await prefs.setStringList('friend_ids', friendIds);
    await saveDataToFirebase();

    friendIdController.clear();
  }

  Future<void> removeFriend(String friendId) async {
    final prefs = await SharedPreferences.getInstance();

    setState(() {
      friendIds.remove(friendId);
    });

    await prefs.setStringList('friend_ids', friendIds);
    await saveDataToFirebase();
  }

  Future<void> saveSafetyStatus(String status) async {
    setState(() {
      safetyStatus = status;
    });
    await saveDataToFirebase();
  }

  Future<void> requestRescue() async {
    setState(() {
      rescueRequest = true;
    });
    await saveDataToFirebase();
  }

  Future<void> cancelRescueRequest() async {
    setState(() {
      rescueRequest = false;
    });
    await saveDataToFirebase();
  }

  Future<void> getCurrentLocation() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();

    if (!serviceEnabled) {
      setState(() {
        locationMessage = '位置情報サービスがOFFです';
      });
      return;
    }

    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.deniedForever ||
        permission == LocationPermission.denied) {
      setState(() {
        locationMessage = '位置情報権限が拒否されています';
      });
      return;
    }

    final position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );

    final currentBatteryLevel = await getBatteryLevelSafely();

    setState(() {
      latitude = position.latitude;
      longitude = position.longitude;
      accuracy = position.accuracy;
      batteryLevel = currentBatteryLevel;

      locationMessage =
          '現在地\n'
          '緯度: ${position.latitude}\n'
          '経度: ${position.longitude}\n'
          '位置精度: ±${position.accuracy.toStringAsFixed(0)}m\n'
          '${accuracyLevelText(position.accuracy)}\n'
          '電池残量: ${batteryText(currentBatteryLevel)}';
    });

    await saveDataToFirebase();
  }

  Future<void> updateLocationSilently() async {
    if (myUserId.isEmpty) return;

    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return;

    final permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return;
    }

    final position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );

    final currentBatteryLevel = await getBatteryLevelSafely();

    if (!mounted) return;

    setState(() {
      latitude = position.latitude;
      longitude = position.longitude;
      accuracy = position.accuracy;
      batteryLevel = currentBatteryLevel;

      locationMessage =
          '現在地\n'
          '緯度: ${position.latitude}\n'
          '経度: ${position.longitude}\n'
          '位置精度: ±${position.accuracy.toStringAsFixed(0)}m\n'
          '${accuracyLevelText(position.accuracy)}\n'
          '電池残量: ${batteryText(currentBatteryLevel)}';
    });

    await saveDataToFirebase();
  }

  Color statusColor(String status) {
    if (status == '無事') return Colors.green;
    if (status == '軽傷') return Colors.orange;
    if (status == '重傷') return Colors.red;
    return Colors.grey;
  }

  String connectionStatus(dynamic updatedAt) {
    if (updatedAt is! Timestamp) return 'unknown';

    final diff = DateTime.now().difference(updatedAt.toDate());

    if (diff.inMinutes < 3) {
      return 'online';
    } else if (diff.inMinutes < 10) {
      return 'delayed';
    } else if (diff.inMinutes < 30) {
      return 'old';
    } else {
      return 'offlineCandidate';
    }
  }

  String connectionStatusLabel(String status) {
    switch (status) {
      case 'online':
        return 'オンライン';
      case 'delayed':
        return '更新遅延';
      case 'old':
        return '位置情報が古い';
      case 'offlineCandidate':
        return '圏外の可能性';
      default:
        return '更新時刻不明';
    }
  }

  Color connectionStatusColor(String status) {
    switch (status) {
      case 'online':
        return Colors.green;
      case 'delayed':
        return Colors.orange;
      case 'old':
        return Colors.deepOrange;
      case 'offlineCandidate':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  IconData connectionStatusIcon(String status) {
    switch (status) {
      case 'online':
        return Icons.wifi;
      case 'delayed':
        return Icons.wifi_tethering_error;
      case 'old':
        return Icons.history;
      case 'offlineCandidate':
        return Icons.signal_wifi_off;
      default:
        return Icons.help_outline;
    }
  }

  String elapsedText(dynamic updatedAt) {
    if (updatedAt is! Timestamp) return '更新時刻不明';

    final diff = DateTime.now().difference(updatedAt.toDate());

    if (diff.inSeconds < 60) return '${diff.inSeconds}秒前';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分前';
    if (diff.inHours < 24) return '${diff.inHours}時間前';
    return '${diff.inDays}日前';
  }

  String elapsedTextFromIso(dynamic isoString) {
    if (isoString is! String || isoString.isEmpty) return '不明';

    try {
      final dt = DateTime.parse(isoString);
      final diff = DateTime.now().difference(dt);

      if (diff.inSeconds < 60) return '${diff.inSeconds}秒前';
      if (diff.inMinutes < 60) return '${diff.inMinutes}分前';
      if (diff.inHours < 24) return '${diff.inHours}時間前';
      return '${diff.inDays}日前';
    } catch (_) {
      return '不明';
    }
  }

  String dateTimeText(dynamic updatedAt) {
    if (updatedAt is! Timestamp) return '不明';

    final dt = updatedAt.toDate();

    return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String dateTimeTextFromIso(dynamic isoString) {
    if (isoString is! String || isoString.isEmpty) return '不明';

    try {
      final dt = DateTime.parse(isoString);

      return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return '不明';
    }
  }

  String accuracyText(dynamic value) {
    if (value is num) {
      return '±${value.toDouble().toStringAsFixed(0)}m';
    }
    return '不明';
  }

  String accuracyLevelText(dynamic value) {
    if (value is! num) return '精度：不明';

    final accuracyValue = value.toDouble();

    if (accuracyValue <= 30) {
      return '精度：良好';
    } else if (accuracyValue <= 100) {
      return '精度：やや不安定';
    } else if (accuracyValue <= 300) {
      return '精度：低い';
    } else {
      return '精度：かなり低い';
    }
  }

  String batteryText(dynamic value) {
    if (value is num) {
      return '${value.toInt()}%';
    }
    return '不明';
  }

  bool isLowBattery(dynamic value) {
    if (value is! num) return false;
    return value.toInt() <= 20;
  }

  Color batteryColor(dynamic value) {
    if (value is! num) return Colors.grey;
    final level = value.toInt();

    if (level <= 20) return Colors.red;
    if (level <= 40) return Colors.orange;
    return Colors.green;
  }

  String batteryWarningText(dynamic value) {
    if (isLowBattery(value)) {
      return '⚠ 電池残量が少ないです\n';
    }
    return '';
  }

  Color cardColorByConnection(String status, dynamic batteryLevelValue) {
    if (isLowBattery(batteryLevelValue)) {
      return Colors.red.shade50;
    }

    switch (status) {
      case 'online':
        return Colors.white;
      case 'delayed':
        return Colors.orange.shade50;
      case 'old':
        return Colors.deepOrange.shade50;
      case 'offlineCandidate':
        return Colors.red.shade50;
      default:
        return Colors.grey.shade100;
    }
  }

  Map<String, dynamic> buildMyDisasterQrPayload() {
    final now = DateTime.now().toIso8601String();

    return {
      'type': 'disaster_user_info',
      'sourceUserId': myUserId,
      'displayName': displayName,
      'safetyStatus': safetyStatus,
      'rescueRequest': rescueRequest,
      'latitude': latitude,
      'longitude': longitude,
      'accuracy': accuracy,
      'batteryLevel': batteryLevel,
      'updatedAt': now,
      'sharedAt': now,
      'hopCount': 0,
    };
  }

  Map<String, dynamic> normalizeDirectPerson(Map<String, dynamic> data) {
    return {
      'type': 'relayed_person_info',
      'sourceUserId': data['sourceUserId'] ?? '',
      'displayName': data['displayName'] ?? '名前なし',
      'safetyStatus': data['safetyStatus'] ?? '未登録',
      'rescueRequest': data['rescueRequest'] == true,
      'latitude': data['latitude'],
      'longitude': data['longitude'],
      'accuracy': data['accuracy'],
      'batteryLevel': data['batteryLevel'],
      'updatedAt': data['updatedAt'],
      'sharedAt': data['sharedAt'],
      'receivedAt': DateTime.now().toIso8601String(),
      'hopCount': 0,
      'receivedFromName': '本人から直接',
      'receivedFromUserId': data['sourceUserId'] ?? '',
    };
  }

  Map<String, dynamic> normalizeRelayedPerson(
    Map<String, dynamic> data, {
    required String relayedByName,
    required String relayedByUserId,
  }) {
    final currentHop = data['hopCount'];
    final hopCount = currentHop is num ? currentHop.toInt() : 0;

    return {
      'type': 'relayed_person_info',
      'sourceUserId': data['sourceUserId'] ?? '',
      'displayName': data['displayName'] ?? '名前なし',
      'safetyStatus': data['safetyStatus'] ?? '未登録',
      'rescueRequest': data['rescueRequest'] == true,
      'latitude': data['latitude'],
      'longitude': data['longitude'],
      'accuracy': data['accuracy'],
      'batteryLevel': data['batteryLevel'],
      'updatedAt': data['updatedAt'],
      'sharedAt': data['sharedAt'],
      'receivedAt': DateTime.now().toIso8601String(),
      'hopCount': hopCount + 1,
      'receivedFromName': relayedByName,
      'receivedFromUserId': relayedByUserId,
    };
  }

  Future<void> saveRelayedPerson(Map<String, dynamic> person) async {
    final sourceUserId = person['sourceUserId'];

    if (sourceUserId == null || sourceUserId.toString().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('QR情報にユーザーIDがありません')));
      return;
    }

    setState(() {
      relayedPeople.removeWhere((p) => p['sourceUserId'] == sourceUserId);
      relayedPeople.insert(0, person);
    });

    await saveRelayedPeopleToPrefs();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${person['displayName']} の情報を保存しました')),
    );
  }

  Future<void> handleQrScannedValue(String value) async {
    try {
      final decoded = jsonDecode(value);

      if (decoded is Map<String, dynamic>) {
        final type = decoded['type'];

        if (type == 'disaster_user_info') {
          final person = normalizeDirectPerson(decoded);
          await saveRelayedPerson(person);
          return;
        }

        if (type == 'disaster_relay_info') {
          final relayedByName = decoded['relayedByName']?.toString() ?? '不明な人';
          final relayedByUserId =
              decoded['relayedByUserId']?.toString() ?? 'unknown';
          final personData = decoded['person'];

          if (personData is! Map) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('リレーQRに人物情報がありません')));
            return;
          }

          final person = normalizeRelayedPerson(
            Map<String, dynamic>.from(personData),
            relayedByName: relayedByName,
            relayedByUserId: relayedByUserId,
          );

          await saveRelayedPerson(person);
          return;
        }
      }
    } catch (_) {
      // JSONでなければ、従来通り「友達ID」として扱う
    }

    friendIdController.text = value;
    await addFriend();
  }

  Map<String, dynamic> buildRelayPayloadForPerson(Map<String, dynamic> person) {
    return {
      'type': 'disaster_relay_info',
      'relayedByUserId': myUserId,
      'relayedByName': displayName,
      'relayedAt': DateTime.now().toIso8601String(),
      'person': {
        'sourceUserId': person['sourceUserId'],
        'displayName': person['displayName'],
        'safetyStatus': person['safetyStatus'],
        'rescueRequest': person['rescueRequest'],
        'latitude': person['latitude'],
        'longitude': person['longitude'],
        'accuracy': person['accuracy'],
        'batteryLevel': person['batteryLevel'],
        'updatedAt': person['updatedAt'],
        'sharedAt': person['sharedAt'],
        'hopCount': person['hopCount'],
      },
    };
  }

  void showMyQrCode() {
    if (myUserId.isEmpty) return;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.white,
          title: const Text('この端末のID QRコード'),
          content: SizedBox(
            width: 300,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                QrImageView(
                  data: myUserId,
                  version: QrVersions.auto,
                  size: 220,
                  backgroundColor: Colors.white,
                ),
                const SizedBox(height: 12),
                SelectableText(myUserId),
                const SizedBox(height: 8),
                Text('表示名: $displayName'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('閉じる'),
            ),
          ],
        );
      },
    );
  }

  void showMyDisasterInfoQr() {
    if (myUserId.isEmpty) return;

    final payload = buildMyDisasterQrPayload();
    final qrData = jsonEncode(payload);

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.white,
          title: const Text('自分の災害情報QR'),
          content: SizedBox(
            width: 320,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  QrImageView(
                    data: qrData,
                    version: QrVersions.auto,
                    size: 240,
                    backgroundColor: Colors.white,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    displayName,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text('状態: $safetyStatus'),
                  Text('救助要請: ${rescueRequest ? 'あり' : 'なし'}'),
                  Text('位置精度: ${accuracyText(accuracy)}'),
                  Text('電池残量: ${batteryText(batteryLevel)}'),
                  const SizedBox(height: 8),
                  const Text(
                    'このQRを相手が読み取ると、あなたの安否・位置・電池情報を相手端末に保存できます。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('閉じる'),
            ),
          ],
        );
      },
    );
  }

  void showRelayQrForPerson(Map<String, dynamic> person) {
    final payload = buildRelayPayloadForPerson(person);
    final qrData = jsonEncode(payload);

    final personName = person['displayName'] ?? '名前なし';

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.white,
          title: Text('$personName の情報を共有'),
          content: SizedBox(
            width: 330,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  QrImageView(
                    data: qrData,
                    version: QrVersions.auto,
                    size: 240,
                    backgroundColor: Colors.white,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '$personName の情報だけを共有します',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Cさんが読み取ると、$personName の情報が保存されます。\n'
                    'Cさん側には「$displayName 経由」と表示されます。\n'
                    'あなた自身の位置・安否・電池情報はこのQRには含まれません。',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('閉じる'),
            ),
          ],
        );
      },
    );
  }

  void openQrScanner() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => QrScannerPage(
          onScanned: (value) async {
            await handleQrScannedValue(value);
          },
        ),
      ),
    );
  }

  void openAllUsersMap() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            AllUsersMapPage(myUserId: myUserId, friendIds: friendIds),
      ),
    );
  }

  Widget buildFriendTile(String friendId) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(friendId)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Card(child: ListTile(title: Text('友達本人の情報を読み込み中...')));
        }

        if (!snapshot.data!.exists) {
          return Card(
            child: ListTile(
              title: Text(friendId),
              subtitle: const Text('友達本人のデータがまだありません'),
              trailing: IconButton(
                icon: const Icon(Icons.delete),
                onPressed: null,
              ),
            ),
          );
        }

        final data = snapshot.data!.data() as Map<String, dynamic>;

        final realName = data['displayName'] ?? '名前なし';
        final status = data['safetyStatus'] ?? '未登録';
        final rescue = data['rescueRequest'] == true;
        final updatedAt = data['updatedAt'];
        final friendAccuracy = data['accuracy'];
        final friendBatteryLevel = data['batteryLevel'];

        final connStatus = connectionStatus(updatedAt);
        final connLabel = connectionStatusLabel(connStatus);
        final connColor = connectionStatusColor(connStatus);
        final connIcon = connectionStatusIcon(connStatus);

        final isOfflineCandidate = connStatus == 'offlineCandidate';
        final lowBattery = isLowBattery(friendBatteryLevel);

        return Card(
          color: cardColorByConnection(connStatus, friendBatteryLevel),
          child: ListTile(
            leading: Icon(
              rescue
                  ? Icons.warning
                  : lowBattery
                  ? Icons.battery_alert
                  : connIcon,
              color: rescue
                  ? Colors.red
                  : lowBattery
                  ? Colors.red
                  : connColor,
            ),
            title: Text(
              realName,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: rescue || lowBattery ? Colors.red : null,
              ),
            ),
            subtitle: Text(
              '友達本人の状態: $status\n'
              '友達本人の救助要請: ${rescue ? 'あり' : 'なし'}\n'
              '通信状態: $connLabel\n'
              '電池残量: ${batteryText(friendBatteryLevel)}\n'
              '${batteryWarningText(friendBatteryLevel)}'
              '位置精度: ${accuracyText(friendAccuracy)}\n'
              '${accuracyLevelText(friendAccuracy)}\n'
              '最終更新: ${dateTimeText(updatedAt)}（${elapsedText(updatedAt)}）\n'
              '${isOfflineCandidate ? '⚠ 現在地ではなく、最後に確認された位置です\n' : ''}'
              'ID: $friendId',
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete),
              onPressed: () => removeFriend(friendId),
            ),
          ),
        );
      },
    );
  }

  Widget buildRelayedPersonTile(Map<String, dynamic> person) {
    final name = person['displayName'] ?? '名前なし';
    final status = person['safetyStatus'] ?? '未登録';
    final rescue = person['rescueRequest'] == true;
    final sourceUserId = person['sourceUserId'] ?? '';
    final hopCount = person['hopCount'] is num
        ? (person['hopCount'] as num).toInt()
        : 0;
    final receivedFromName = person['receivedFromName'] ?? '不明';
    final updatedAt = person['updatedAt'];
    final receivedAt = person['receivedAt'];
    final personAccuracy = person['accuracy'];
    final personBattery = person['batteryLevel'];

    return Card(
      color: rescue ? Colors.red.shade50 : Colors.blueGrey.shade50,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          children: [
            ListTile(
              leading: Icon(
                rescue ? Icons.warning : Icons.qr_code_2,
                color: rescue ? Colors.red : Colors.blueGrey,
              ),
              title: Text(
                name,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: rescue ? Colors.red : null,
                ),
              ),
              subtitle: Text(
                '状態: $status\n'
                '救助要請: ${rescue ? 'あり' : 'なし'}\n'
                '電池残量: ${batteryText(personBattery)}\n'
                '${batteryWarningText(personBattery)}'
                '位置精度: ${accuracyText(personAccuracy)}\n'
                '${accuracyLevelText(personAccuracy)}\n'
                '本人更新: ${dateTimeTextFromIso(updatedAt)}（${elapsedTextFromIso(updatedAt)}）\n'
                '読み取り: ${dateTimeTextFromIso(receivedAt)}（${elapsedTextFromIso(receivedAt)}）\n'
                '取得経路: ${hopCount == 0 ? '本人から直接' : '$receivedFromName 経由'}\n'
                'リレー回数: $hopCount回\n'
                'ID: $sourceUserId\n'
                '※本人から直接取得した最新情報とは限りません',
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => showRelayQrForPerson(person),
                  icon: const Icon(Icons.share),
                  label: Text('$name の情報だけを共有QRにする'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget myProfileCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            ListTile(
              title: const Text('この端末のID'),
              subtitle: SelectableText(myUserId),
            ),
            TextField(
              controller: displayNameController,
              decoration: const InputDecoration(
                labelText: 'この端末の持ち主の表示名',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: saveDisplayName,
              child: const Text('表示名を保存'),
            ),
          ],
        ),
      ),
    );
  }

  Widget myLocationCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(locationMessage, textAlign: TextAlign.center),
            const SizedBox(height: 10),
            Text(
              'この端末の電池残量: ${batteryText(batteryLevel)}',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: batteryColor(batteryLevel),
              ),
            ),
            if (isLowBattery(batteryLevel))
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  '⚠ 電池残量が少ないです',
                  style: TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: getCurrentLocation,
              child: const Text('この端末の現在地を取得'),
            ),
          ],
        ),
      ),
    );
  }

  Widget myStatusCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text(
              'この端末の持ち主の安否状態',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              safetyStatus,
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: statusColor(safetyStatus),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              children: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => saveSafetyStatus('無事'),
                  child: const Text('自分は無事'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => saveSafetyStatus('軽傷'),
                  child: const Text('自分は軽傷'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => saveSafetyStatus('重傷'),
                  child: const Text('自分は重傷'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: rescueRequest ? Colors.grey : Colors.red,
                foregroundColor: Colors.white,
              ),
              onPressed: rescueRequest ? cancelRescueRequest : requestRescue,
              icon: const Icon(Icons.warning),
              label: Text(rescueRequest ? '自分の救助要請を取り消す' : '自分の救助を要請'),
            ),
          ],
        ),
      ),
    );
  }

  Widget friendRegisterCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text(
              '友達を登録する',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              '友達のIDだけを登録します。名前・状態・位置は友達本人のデータから読み取ります。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: friendIdController,
              decoration: const InputDecoration(
                labelText: '友達のID',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            ElevatedButton(onPressed: addFriend, child: const Text('友達を追加')),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              onPressed: openQrScanner,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('QRコードで読み取る'),
            ),
            const SizedBox(height: 10),
            ElevatedButton.icon(
              onPressed: openAllUsersMap,
              icon: const Icon(Icons.map),
              label: const Text('友達全員を地図で見る'),
            ),
          ],
        ),
      ),
    );
  }

  Widget offlineRelayQrCard() {
    return Card(
      color: Colors.lightBlue.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text(
              'オフライン伝言QR',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Aさんの情報をBさんが読み取り、BさんがAさん情報だけをCさんに渡せます。\nCさんには「Bさん経由」と表示されます。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: showMyDisasterInfoQr,
                  icon: const Icon(Icons.qr_code),
                  label: const Text('自分の災害情報QR'),
                ),
                ElevatedButton.icon(
                  onPressed: openQrScanner,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('災害QRを読み取る'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              '※共有QRには、共有対象者の情報だけを入れます。中継者本人の位置・安否・電池情報は入りません。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.black87),
            ),
          ],
        ),
      ),
    );
  }

  Widget relayedPeopleCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text(
              '読み取った災害情報',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'QRで読み取った人の情報です。共有するときは、その人の情報だけをQRにします。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            if (relayedPeople.isEmpty)
              const Text('まだ読み取った災害情報はありません')
            else
              Column(
                children: relayedPeople
                    .map((person) => buildRelayedPersonTile(person))
                    .toList(),
              ),
          ],
        ),
      ),
    );
  }

  Widget friendListCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text(
              '登録済みの友達',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'ここに表示される状態・救助要請・位置は、友達本人の端末から送られた情報です。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            if (friendIds.isEmpty)
              const Text('まだ友達がいません')
            else
              Column(
                children: friendIds.map((id) => buildFriendTile(id)).toList(),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('災害位置共有アプリ'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(icon: const Icon(Icons.qr_code), onPressed: showMyQrCode),
          IconButton(
            icon: const Icon(Icons.groups),
            onPressed: openAllUsersMap,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            myProfileCard(),
            const SizedBox(height: 12),
            myLocationCard(),
            const SizedBox(height: 12),
            myStatusCard(),
            const SizedBox(height: 12),
            offlineRelayQrCard(),
            const SizedBox(height: 12),
            relayedPeopleCard(),
            const SizedBox(height: 12),
            friendRegisterCard(),
            const SizedBox(height: 12),
            friendListCard(),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

class QrScannerPage extends StatefulWidget {
  final Future<void> Function(String value) onScanned;

  const QrScannerPage({super.key, required this.onScanned});

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage> {
  bool isScanned = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('QRコードを読み取る')),
      body: MobileScanner(
        onDetect: (capture) async {
          if (isScanned) return;

          final barcodes = capture.barcodes;
          if (barcodes.isEmpty) return;

          final value = barcodes.first.rawValue;
          if (value == null || value.isEmpty) return;

          setState(() {
            isScanned = true;
          });

          await widget.onScanned(value);

          if (!context.mounted) return;
          Navigator.pop(context);
        },
      ),
    );
  }
}

class AllUsersMapPage extends StatelessWidget {
  final String myUserId;
  final List<String> friendIds;

  const AllUsersMapPage({
    super.key,
    required this.myUserId,
    required this.friendIds,
  });

  String connectionStatus(dynamic updatedAt) {
    if (updatedAt is! Timestamp) return 'unknown';

    final diff = DateTime.now().difference(updatedAt.toDate());

    if (diff.inMinutes < 3) {
      return 'online';
    } else if (diff.inMinutes < 10) {
      return 'delayed';
    } else if (diff.inMinutes < 30) {
      return 'old';
    } else {
      return 'offlineCandidate';
    }
  }

  String connectionStatusLabel(String status) {
    switch (status) {
      case 'online':
        return 'オンライン';
      case 'delayed':
        return '更新遅延';
      case 'old':
        return '位置情報が古い';
      case 'offlineCandidate':
        return '圏外の可能性';
      default:
        return '更新時刻不明';
    }
  }

  Color connectionStatusColor(String status) {
    switch (status) {
      case 'online':
        return Colors.green;
      case 'delayed':
        return Colors.orange;
      case 'old':
        return Colors.deepOrange;
      case 'offlineCandidate':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  IconData connectionStatusIcon(String status) {
    switch (status) {
      case 'online':
        return Icons.wifi;
      case 'delayed':
        return Icons.wifi_tethering_error;
      case 'old':
        return Icons.history;
      case 'offlineCandidate':
        return Icons.signal_wifi_off;
      default:
        return Icons.help_outline;
    }
  }

  String elapsedText(dynamic updatedAt) {
    if (updatedAt is! Timestamp) return '更新時刻不明';

    final diff = DateTime.now().difference(updatedAt.toDate());

    if (diff.inSeconds < 60) return '${diff.inSeconds}秒前';
    if (diff.inMinutes < 60) return '${diff.inMinutes}分前';
    if (diff.inHours < 24) return '${diff.inHours}時間前';
    return '${diff.inDays}日前';
  }

  String dateTimeText(dynamic updatedAt) {
    if (updatedAt is! Timestamp) return '不明';

    final dt = updatedAt.toDate();

    return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String accuracyText(dynamic value) {
    if (value is num) {
      return '±${value.toDouble().toStringAsFixed(0)}m';
    }
    return '不明';
  }

  String accuracyLevelText(dynamic value) {
    if (value is! num) return '精度：不明';

    final accuracyValue = value.toDouble();

    if (accuracyValue <= 30) {
      return '精度：良好';
    } else if (accuracyValue <= 100) {
      return '精度：やや不安定';
    } else if (accuracyValue <= 300) {
      return '精度：低い';
    } else {
      return '精度：かなり低い';
    }
  }

  String batteryText(dynamic value) {
    if (value is num) {
      return '${value.toInt()}%';
    }
    return '不明';
  }

  bool isLowBattery(dynamic value) {
    if (value is! num) return false;
    return value.toInt() <= 20;
  }

  String batteryWarningText(dynamic value) {
    if (isLowBattery(value)) {
      return '⚠ 電池残量が少ないです\n';
    }
    return '';
  }

  String groupKey(double lat, double lng) {
    return '${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}';
  }

  Color accuracyCircleColor(
    bool rescue,
    String connStatus,
    dynamic batteryLevelValue,
  ) {
    if (rescue) {
      return Colors.red.withOpacity(0.18);
    }

    if (isLowBattery(batteryLevelValue)) {
      return Colors.red.withOpacity(0.12);
    }

    if (connStatus == 'offlineCandidate') {
      return Colors.grey.withOpacity(0.18);
    }

    if (connStatus == 'old') {
      return Colors.deepOrange.withOpacity(0.14);
    }

    if (connStatus == 'delayed') {
      return Colors.orange.withOpacity(0.14);
    }

    return Colors.blue.withOpacity(0.14);
  }

  Color accuracyCircleBorderColor(
    bool rescue,
    String connStatus,
    dynamic batteryLevelValue,
  ) {
    if (rescue) {
      return Colors.red.withOpacity(0.65);
    }

    if (isLowBattery(batteryLevelValue)) {
      return Colors.red.withOpacity(0.5);
    }

    if (connStatus == 'offlineCandidate') {
      return Colors.grey.withOpacity(0.65);
    }

    if (connStatus == 'old') {
      return Colors.deepOrange.withOpacity(0.55);
    }

    if (connStatus == 'delayed') {
      return Colors.orange.withOpacity(0.55);
    }

    return Colors.blue.withOpacity(0.45);
  }

  double accuracyRadius(dynamic value) {
    if (value is! num) return 50;

    final accuracyValue = value.toDouble();

    return accuracyValue.clamp(10, 500).toDouble();
  }

  void showGroupDialog(BuildContext context, List<Map<String, dynamic>> users) {
    showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: Text('この場所付近にいる人：${users.length}人'),
          content: SizedBox(
            width: 340,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: users.map((user) {
                final name = user['name'] as String;
                final status = user['status'] as String;
                final rescue = user['rescue'] as bool;
                final userAccuracy = user['accuracy'];
                final updatedAt = user['updatedAt'];
                final connStatus = user['connectionStatus'] as String;
                final userBatteryLevel = user['batteryLevel'];

                final connLabel = connectionStatusLabel(connStatus);
                final connColor = connectionStatusColor(connStatus);
                final connIcon = connectionStatusIcon(connStatus);
                final lowBattery = isLowBattery(userBatteryLevel);

                return ListTile(
                  leading: Icon(
                    rescue
                        ? Icons.warning
                        : lowBattery
                        ? Icons.battery_alert
                        : connIcon,
                    color: rescue
                        ? Colors.red
                        : lowBattery
                        ? Colors.red
                        : connColor,
                  ),
                  title: Text(
                    name,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: rescue || lowBattery ? Colors.red : null,
                    ),
                  ),
                  subtitle: Text(
                    '${rescue ? 'SOS / ' : ''}状態: $status\n'
                    '通信状態: $connLabel\n'
                    '電池残量: ${batteryText(userBatteryLevel)}\n'
                    '${batteryWarningText(userBatteryLevel)}'
                    '最終更新: ${dateTimeText(updatedAt)}（${elapsedText(updatedAt)}）\n'
                    '位置精度: ${accuracyText(userAccuracy)}\n'
                    '${accuracyLevelText(userAccuracy)}\n'
                    '${connStatus == 'offlineCandidate' ? '⚠ 現在地ではなく、最後に確認された位置です' : ''}',
                  ),
                );
              }).toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('閉じる'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('全員の位置')),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: Colors.amber.shade100,
            padding: const EdgeInsets.all(10),
            child: const Text(
              '表示されている位置は、最後に取得できた位置です。\n'
              '精度円の範囲内にいる可能性があります。\n'
              '更新が止まっている場合、圏外・電池切れ・端末停止の可能性があります。',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .snapshots(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final groupedUsers = <String, List<Map<String, dynamic>>>{};
                final accuracyCircles = <CircleMarker>[];

                LatLng center = const LatLng(26.6232, 127.9747);

                final allowedIds = <String>{myUserId, ...friendIds};

                for (final doc in snapshot.data!.docs) {
                  if (!allowedIds.contains(doc.id)) continue;

                  final data = doc.data() as Map<String, dynamic>;

                  final lat = data['latitude'];
                  final lng = data['longitude'];

                  if (lat is! num || lng is! num) continue;

                  final latDouble = lat.toDouble();
                  final lngDouble = lng.toDouble();

                  final key = groupKey(latDouble, lngDouble);

                  final name = data['displayName'] ?? '名前なし';
                  final status = data['safetyStatus'] ?? '未登録';
                  final rescue = data['rescueRequest'] == true;
                  final updatedAt = data['updatedAt'];
                  final userAccuracy = data['accuracy'];
                  final userBatteryLevel = data['batteryLevel'];
                  final connStatus = connectionStatus(updatedAt);

                  center = LatLng(latDouble, lngDouble);

                  groupedUsers.putIfAbsent(key, () => []);

                  groupedUsers[key]!.add({
                    'id': doc.id,
                    'name': name,
                    'status': status,
                    'rescue': rescue,
                    'accuracy': userAccuracy,
                    'batteryLevel': userBatteryLevel,
                    'updatedAt': updatedAt,
                    'connectionStatus': connStatus,
                    'lat': latDouble,
                    'lng': lngDouble,
                  });

                  accuracyCircles.add(
                    CircleMarker(
                      point: LatLng(latDouble, lngDouble),
                      radius: accuracyRadius(userAccuracy),
                      useRadiusInMeter: true,
                      color: accuracyCircleColor(
                        rescue,
                        connStatus,
                        userBatteryLevel,
                      ),
                      borderColor: accuracyCircleBorderColor(
                        rescue,
                        connStatus,
                        userBatteryLevel,
                      ),
                      borderStrokeWidth: rescue ? 3 : 2,
                    ),
                  );
                }

                final markers = <Marker>[];

                groupedUsers.forEach((key, users) {
                  final first = users.first;
                  final lat = first['lat'] as double;
                  final lng = first['lng'] as double;

                  final hasOffline = users.any(
                    (u) => u['connectionStatus'] == 'offlineCandidate',
                  );
                  final hasSos = users.any((u) => u['rescue'] == true);
                  final hasLowBattery = users.any(
                    (u) => isLowBattery(u['batteryLevel']),
                  );
                  final hasHeavy = users.any((u) => u['status'] == '重傷');
                  final hasLight = users.any((u) => u['status'] == '軽傷');
                  final hasOld = users.any(
                    (u) => u['connectionStatus'] == 'old',
                  );
                  final hasDelayed = users.any(
                    (u) => u['connectionStatus'] == 'delayed',
                  );

                  Color color;
                  IconData icon;

                  if (hasSos) {
                    color = Colors.red;
                    icon = Icons.warning;
                  } else if (hasLowBattery) {
                    color = Colors.red;
                    icon = Icons.battery_alert;
                  } else if (hasOffline) {
                    color = Colors.black;
                    icon = Icons.signal_wifi_off;
                  } else if (hasHeavy) {
                    color = Colors.red;
                    icon = Icons.location_pin;
                  } else if (hasLight) {
                    color = Colors.orange;
                    icon = Icons.location_pin;
                  } else if (hasOld) {
                    color = Colors.deepOrange;
                    icon = Icons.history;
                  } else if (hasDelayed) {
                    color = Colors.orange;
                    icon = Icons.wifi_tethering_error;
                  } else {
                    color = Colors.green;
                    icon = Icons.location_pin;
                  }

                  final label = users.length == 1
                      ? '${users.first['name']} ${users.first['status']}'
                      : '${users.length}人';

                  markers.add(
                    Marker(
                      point: LatLng(lat, lng),
                      width: 180,
                      height: 115,
                      child: GestureDetector(
                        onTap: () {
                          showGroupDialog(context, users);
                        },
                        child: Column(
                          children: [
                            Icon(
                              icon,
                              color: color,
                              size: users.length == 1 ? 50 : 58,
                            ),
                            Container(
                              color: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              child: Text(
                                label,
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: color,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                });

                return FlutterMap(
                  options: MapOptions(initialCenter: center, initialZoom: 14),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.example.myapp',
                    ),
                    CircleLayer(circles: accuracyCircles),
                    MarkerLayer(markers: markers),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
// ログイン・新規登録画面
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  bool _isSignUp = false; // false: ログインモード, true: 新規登録モード
  final TextEditingController _inputController = TextEditingController();
  bool _isLoading = false;

  // ログイン処理（IDまたはメールアドレス）
  Future<void> _login() async {
    final input = _inputController.text.trim();
    if (input.isEmpty) {
      _showSnackBar('IDまたはメールアドレスを入力してください');
      return;
    }

    setState(() => _isLoading = true);

    try {
      String? targetUserId;
      Map<String, dynamic>? userData;

      if (input.contains('@')) {
        // ① メールアドレスでの検索
        final query = await FirebaseFirestore.instance
            .collection('users')
            .where('email', isEqualTo: input)
            .limit(1)
            .get();

        if (query.docs.isNotEmpty) {
          targetUserId = query.docs.first.id;
          userData = query.docs.first.data();
        }
      } else {
        // ② ユーザーIDでの検索
        final doc = await FirebaseFirestore.instance.collection('users').doc(input).get();
        if (doc.exists) {
          targetUserId = doc.id;
          userData = doc.data();
        }
      }

      if (!mounted) return;

      if (userData == null || targetUserId == null) {
        _showSnackBar('該当するアカウントが見つかりませんでした');
        return;
      }

      // IDのローカル保存
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_id', targetUserId);

      if (!mounted) return;

      // ロールに応じた画面遷移
      if (userData['role'] == 'host') {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const HostPage()),
        );
      } else {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const MyHomePage()),
        );
      }
    } catch (e) {
      if (!mounted) return;
      _showSnackBar('エラーが発生しました: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // 新規アカウント作成処理
  Future<void> _signUp() async {
    final email = _inputController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      _showSnackBar('有効なメールアドレスを入力してください');
      return;
    }

    setState(() => _isLoading = true);

    try {
      // 既存のメールアドレスチェック
      final existing = await FirebaseFirestore.instance
          .collection('users')
          .where('email', isEqualTo: email)
          .limit(1)
          .get();

      if (existing.docs.isNotEmpty) {
        if (!mounted) return;
        _showSnackBar('このメールアドレスは既に登録されています。ログインしてください。');
        return;
      }

      // 新しいIDを自動割り振る (例: user_タイムスタンプ)
      final generatedId = 'user_${DateTime.now().millisecondsSinceEpoch}';

      // Firestoreに登録
      await FirebaseFirestore.instance.collection('users').doc(generatedId).set({
        'userId': generatedId,
        'email': email,
        'role': 'general',
        'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // IDをローカル保存
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_id', generatedId);

      if (!mounted) return;

      // 割り振られたIDをユーザーにお知らせして画面遷移
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('アカウント作成完了'),
          content: Text('あなた専用のユーザーIDが発行されました:\n\n$generatedId\n\n次回からはこのIDまたはメールアドレスでログインできます。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );

      if (!mounted) return;

      // 一般向け画面へ遷移
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const MyHomePage()),
      );
    } catch (e) {
      if (!mounted) return;
      _showSnackBar('登録エラーが発生しました: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showSnackBar(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isSignUp ? '新規アカウント作成' : 'ログイン'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _isSignUp ? Icons.person_add : Icons.security,
              size: 80,
              color: Colors.indigo,
            ),
            const SizedBox(height: 24),

            // モード切り替え（ログイン / 新規作成）
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ChoiceChip(
                  label: const Text('ログイン'),
                  selected: !_isSignUp,
                  onSelected: (selected) {
                    if (selected) setState(() => _isSignUp = false);
                  },
                ),
                const SizedBox(width: 12),
                ChoiceChip(
                  label: const Text('新規作成'),
                  selected: _isSignUp,
                  onSelected: (selected) {
                    if (selected) setState(() => _isSignUp = true);
                  },
                ),
              ],
            ),
            const SizedBox(height: 24),

            // 入力フィールド
            TextField(
              controller: _inputController,
              decoration: InputDecoration(
                labelText: _isSignUp ? 'メールアドレスを入力' : 'ID または メールアドレスを入力',
                border: const OutlineInputBorder(),
                prefixIcon: Icon(_isSignUp ? Icons.email : Icons.person),
              ),
            ),
            const SizedBox(height: 20),

            // 実行ボタン
            _isLoading
                ? const CircularProgressIndicator()
                : SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: _isSignUp ? _signUp : _login,
                      child: Text(
                        _isSignUp ? 'アカウントを作成してスタート' : 'ログイン',
                        style: const TextStyle(fontSize: 18),
                      ),
                    ),
                  ),
          ],
        ),
      ),
    );
  }
}

// ホスト専用画面（アプリ内マップ表示機能付き）
class HostPage extends StatefulWidget {
  const HostPage({super.key});

  @override
  State<HostPage> createState() => _HostPageState();
}

class _HostPageState extends State<HostPage> {
  String _statusFilter = 'ALL'; // 'ALL', 'RESCUE', 'SAFE'
  bool _lowBatteryOnly = false; // 充電20%以下フィルター

  // ユーザー詳細 & アプリ内マップダイアログの表示
  void _showUserDetailDialog(
    BuildContext context,
    String name,
    String email,
    String userId,
    String safetyStatus,
    int battery,
    dynamic lat,
    dynamic lng,
  ) {
    // 座標値の数値変換
    final double? latitude = lat is num ? lat.toDouble() : double.tryParse(lat?.toString() ?? '');
    final double? longitude = lng is num ? lng.toDouble() : double.tryParse(lng?.toString() ?? '');
    final bool hasLocation = latitude != null && longitude != null;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.person_pin_circle, color: Colors.indigo, size: 28),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$name さんの詳細情報',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
             crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('メールアドレス: $email'),
                Text('ユーザーID: $userId'),
                const Divider(height: 20),
                Text('安否状況: $safetyStatus', style: const TextStyle(fontWeight: FontWeight.bold)),
                Text('バッテリー残量: $battery%'),
                const SizedBox(height: 12),
                
                // 位置情報がある場合：アプリ内で地図を表示
                if (hasLocation) ...[
                  const Text('📍 位置情報マップ:', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      height: 220,
                      width: double.maxFinite,
                      child: FlutterMap(
                        options: MapOptions(
                          initialCenter: LatLng(latitude, longitude),
                          initialZoom: 15.0,
                        ),
                        children: [
                          TileLayer(
                            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName: 'com.example.disaster_location_app',
                          ),
                          MarkerLayer(
                            markers: [
                              Marker(
                                point: LatLng(latitude, longitude),
                                width: 40,
                                height: 40,
                                child: const Icon(
                                  Icons.location_on,
                                  color: Colors.red,
                                  size: 40,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '緯度: $latitude, 経度: $longitude',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ] else ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.location_off, color: Colors.grey),
                        SizedBox(width: 8),
                        Text('位置情報が登録されていません', style: TextStyle(color: Colors.black54)),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('閉じる'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ホスト管理者画面'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'ログアウト',
            onPressed: () {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (context) => const LoginPage()),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // ① 絞り込みフィルター（操作バー）
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.indigo.shade50,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  const Text('表示切替: ', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(width: 8),
                  FilterChip(
                    label: const Text('ALL'),
                    selected: _statusFilter == 'ALL',
                    onSelected: (selected) => setState(() => _statusFilter = 'ALL'),
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    avatar: const Icon(Icons.warning, color: Colors.red, size: 18),
                    label: const Text('要救助 / 重症'),
                    selected: _statusFilter == 'RESCUE',
                    selectedColor: Colors.red.shade100,
                    onSelected: (selected) => setState(() => _statusFilter = 'RESCUE'),
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    avatar: const Icon(Icons.check_circle, color: Colors.green, size: 18),
                    label: const Text('無事'),
                    selected: _statusFilter == 'SAFE',
                    selectedColor: Colors.green.shade100,
                    onSelected: (selected) => setState(() => _statusFilter = 'SAFE'),
                  ),
                  const SizedBox(width: 16),
                  FilterChip(
                    avatar: const Icon(Icons.battery_alert, color: Colors.orange, size: 18),
                    label: const Text('充電20%以下'),
                    selected: _lowBatteryOnly,
                    selectedColor: Colors.orange.shade100,
                    onSelected: (selected) => setState(() => _lowBatteryOnly = selected),
                  ),
                ],
              ),
            ),
          ),

          // ② ユーザーリスト
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance.collection('users').snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(child: Text('エラーが発生しました: ${snapshot.error}'));
                }
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                final docs = snapshot.data?.docs ?? [];

                final filteredUsers = docs.where((doc) {
                  final data = doc.data() as Map<String, dynamic>;

                  final isRescue = data['rescueRequest'] == true ||
                      data['safetyStatus'] == '重症' ||
                      data['safetyStatus'] == '要救助';
                  final isSafe = data['safetyStatus'] == '無事';
                  final battery = (data['batteryLevel'] as num?)?.toInt() ?? 100;

                  if (_statusFilter == 'RESCUE' && !isRescue) return false;
                  if (_statusFilter == 'SAFE' && !isSafe) return false;
                  if (_lowBatteryOnly && battery > 20) return false;

                  return true;
                }).toList();

                if (filteredUsers.isEmpty) {
                  return const Center(
                    child: Text(
                      '指定した条件に該当するユーザーはいません',
                      style: TextStyle(fontSize: 16, color: Colors.grey),
                    ),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: filteredUsers.length,
                  itemBuilder: (context, index) {
                    final data = filteredUsers[index].data() as Map<String, dynamic>;

                    final name = data['displayName'] ?? '名前なし';
                    final email = data['email'] ?? 'メールなし';
                    final userId = data['userId'] ?? filteredUsers[index].id;
                    final safetyStatus = data['safetyStatus'] ?? '未登録';
                    final isRescue = data['rescueRequest'] == true || safetyStatus == '重症';
                    final battery = (data['batteryLevel'] as num?)?.toInt() ?? 0;
                    final lat = data['latitude'];
                    final lng = data['longitude'];

                    return Card(
                      elevation: 3,
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      child: ListTile(
                        onTap: () {
                          _showUserDetailDialog(
                            context,
                            name,
                            email,
                            userId,
                            safetyStatus,
                            battery,
                            lat,
                            lng,
                          );
                        },
                        leading: CircleAvatar(
                          backgroundColor: isRescue ? Colors.red : Colors.green,
                          child: Icon(
                            isRescue ? Icons.warning_amber_rounded : Icons.person,
                            color: Colors.white,
                          ),
                        ),
                        title: Row(
                          children: [
                            Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(width: 8),
                            Text('($email)', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                          ],
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Column(
                           crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('ID: $userId'),
                              Text('安否状況: $safetyStatus'),
                              Text('位置情報: ${lat != null && lng != null ? "$lat, $lng" : "未取得"}'),
                            ],
                          ),
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              battery <= 20 ? Icons.battery_alert : Icons.battery_std,
                              color: battery <= 20 ? Colors.red : Colors.grey,
                            ),
                            Text('$battery%', style: const TextStyle(fontSize: 12)),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}