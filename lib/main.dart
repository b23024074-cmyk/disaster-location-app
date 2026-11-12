import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:battery_plus/battery_plus.dart';
import 'firebase_options.dart';
import 'account_page.dart';
import 'admin_dashboard_page.dart';
import 'offline_map_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    ).timeout(const Duration(seconds: 10));

    // Firestoreのデータを端末内に永続保存する
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: true,
    );

    debugPrint('Firestoreのオフラインキャッシュを有効化');

    // Firebase匿名認証
    try {
      final auth = FirebaseAuth.instance;

      if (auth.currentUser == null) {
        await auth.signInAnonymously().timeout(const Duration(seconds: 5));
      }

      debugPrint('Firebase匿名認証を確認');
    } catch (e) {
      debugPrint('Firebase匿名認証に失敗（オフライン機能は継続）: $e');
    }
  } catch (e) {
    debugPrint('Firebase初期化またはFirestore設定に失敗: $e');
  }

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
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  static const String _relayLocationCacheResetKey =
      'relay_location_cache_reset_v2';
  static const String _friendRegistrationResetKey =
      'friend_registration_reset_v1';
  static const String _personalDataResetKey = 'personal_data_reset_v1';
  static const String _displayNameOwnerKey = 'display_name_auth_uid';

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
  DateTime? lastLocationCapturedAt;

  String safetyStatus = '未登録';
  bool rescueRequest = false;

  Timer? locationTimer;
  Timer? relaySyncTimer;
  bool _updatingLocationSilently = false;

  List<Map<String, dynamic>> relayQueue = [];
  List<Map<String, dynamic>> cachedCloudRelays = [];
  DateTime? _relayMapCacheCutoff;
  bool isRelaySyncing = false;
  bool _accountMappingReady = true;
  Map<String, dynamic>? _pendingAccountMigration;

  bool get _hasRegisteredEmailAccount {
    final user = FirebaseAuth.instance.currentUser;
    return user != null &&
        !user.isAnonymous &&
        (user.email?.trim().isNotEmpty ?? false);
  }

  @override
  void initState() {
    super.initState();
    _accountMappingReady =
        FirebaseAuth.instance.currentUser?.isAnonymous ?? true;
    initUser();

    locationTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => updateLocationSilently(),
    );

    relaySyncTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => syncPendingRelayQueue(),
    );
  }

  @override
  void dispose() {
    locationTimer?.cancel();
    relaySyncTimer?.cancel();
    displayNameController.dispose();
    friendIdController.dispose();
    super.dispose();
  }

  Future<void> initUser() async {
    final prefs = await SharedPreferences.getInstance();

    // 一度だけ、端末に保存された名前・位置・QR中継データを初期化する。
    if (prefs.getString(_personalDataResetKey) != 'done') {
      await prefs.remove('display_name');
      await prefs.remove('last_location_data');
      await prefs.remove('cached_cloud_relays_json');
      await prefs.setString('relay_queue_json', '[]');
      await prefs.setStringList('friend_ids', []);
      await prefs.setString(_personalDataResetKey, 'done');
    }

    if (prefs.getString(_friendRegistrationResetKey) != 'done') {
      await prefs.setStringList('friend_ids', []);
      await prefs.setString(_friendRegistrationResetKey, 'done');
    }

    // Reset clears relay documents server-side too; discard pre-reset local
    // cloud cache and hide pre-reset local QR reports from the map.
    if (prefs.getString(_relayLocationCacheResetKey) != 'done') {
      await prefs.remove('cached_cloud_relays_json');
      final cutoff = DateTime.now();
      await prefs.setString('relay_map_cache_cutoff', cutoff.toIso8601String());
      await prefs.setString(_relayLocationCacheResetKey, 'done');
    }
    _relayMapCacheCutoff = DateTime.tryParse(
      prefs.getString('relay_map_cache_cutoff') ?? '',
    );

    final authUser = FirebaseAuth.instance.currentUser;
    if (authUser != null && !authUser.isAnonymous) {
      try {
        final accessDoc = await FirebaseFirestore.instance
            .collection('user_access')
            .doc(authUser.uid)
            .get(const GetOptions(source: Source.serverAndCache))
            .timeout(const Duration(seconds: 8));
        final access = accessDoc.data();
        final mappedId = access?['userId']?.toString();
        if (accessDoc.exists && mappedId != null && mappedId.isNotEmpty) {
          await prefs.setString('user_id', mappedId);
          final mappedFriends = access?['friendIds'];
          if (mappedFriends is List) {
            await prefs.setStringList(
              'friend_ids',
              mappedFriends.whereType<String>().toList(),
            );
          }
        } else {
          _accountMappingReady = false;
        }
      } catch (error) {
        debugPrint('ログイン済みアカウントの紐付け確認を保留: $error');
        _accountMappingReady = false;
      }
    }

    // 匿名利用中に残っていた古いGPSキャッシュは読み込まず破棄する。
    if (!_hasRegisteredEmailAccount) {
      await prefs.remove('last_location_data');
    }
    final savedLocationData = _hasRegisteredEmailAccount
        ? prefs.getString('last_location_data')
        : null;

    if (savedLocationData != null) {
      try {
        final decoded = jsonDecode(savedLocationData);

        if (decoded is Map &&
            decoded['latitude'] is num &&
            decoded['longitude'] is num &&
            decoded['accuracy'] is num &&
            decoded['locationCapturedAt'] is String) {
          final savedTime = DateTime.tryParse(
            decoded['locationCapturedAt'] as String,
          );

          if (savedTime != null) {
            latitude = (decoded['latitude'] as num).toDouble();
            longitude = (decoded['longitude'] as num).toDouble();
            accuracy = (decoded['accuracy'] as num).toDouble();
            lastLocationCapturedAt = savedTime;
          }
        }
      } catch (_) {
        // 保存データが不正な場合は復元しない
      }
    }

    var savedUserId = prefs.getString('user_id');

    if (savedUserId == null || savedUserId.isEmpty) {
      savedUserId = 'user_${DateTime.now().microsecondsSinceEpoch}';
      await prefs.setString('user_id', savedUserId);
    }

    Map<String, dynamic>? savedProfile;
    if (authUser != null && _accountMappingReady) {
      try {
        final profile = await FirebaseFirestore.instance
            .collection('users')
            .doc(savedUserId)
            .get(const GetOptions(source: Source.serverAndCache))
            .timeout(const Duration(seconds: 8));
        if (profile.data()?['authUid'] == authUser.uid) {
          savedProfile = profile.data();
        }
      } catch (error) {
        debugPrint('自分のプロフィール復元を保留: $error');
      }
    }

    String? savedName;
    if (authUser != null && !authUser.isAnonymous) {
      final profileName = savedProfile?['displayName']?.toString().trim();
      if (profileName != null && profileName.isNotEmpty) {
        savedName = profileName;
        await prefs.setString('display_name', profileName);
        await prefs.setString(_displayNameOwnerKey, authUser.uid);
      } else if (savedProfile != null) {
        await prefs.remove('display_name');
        await prefs.remove(_displayNameOwnerKey);
      } else if (prefs.getString(_displayNameOwnerKey) == authUser.uid) {
        savedName = prefs.getString('display_name');
      }
    } else {
      savedName =
          prefs.getString('display_name') ??
          savedProfile?['displayName']?.toString();
    }
    final savedFriendIds = prefs.getStringList('friend_ids') ?? [];
    final savedRelayQueue = loadRelayQueueFromPrefs(prefs);
    final rawCloudRelays = prefs.getString('cached_cloud_relays_json');
    List<Map<String, dynamic>> savedCloudRelays = [];

    if (rawCloudRelays != null && rawCloudRelays.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawCloudRelays);

        if (decoded is List) {
          savedCloudRelays = decoded
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .toList();
        }
      } catch (e) {
        debugPrint('保存済み中継情報の読み込み失敗: $e');
      }
    }
    final currentBatteryLevel = await getBatteryLevelSafely();

    setState(() {
      myUserId = savedUserId!;
      friendIds = savedFriendIds;
      relayQueue = savedRelayQueue;
      batteryLevel = currentBatteryLevel;
      cachedCloudRelays = savedCloudRelays;
      if (savedProfile != null) {
        safetyStatus = savedProfile['safetyStatus']?.toString() ?? '未登録';
        rescueRequest = savedProfile['rescueRequest'] == true;
      }

      if (savedName != null && savedName.isNotEmpty) {
        displayNameController.text = savedName;
      }
    });

    if (!_accountMappingReady) {
      debugPrint('アカウント紐付け未確認のため、クラウド保存と中継送信を保留');
      return;
    }

    debugPrint(
      '【クラウド復元診断】保存済み=${savedCloudRelays.length}件 '
      '復元後=${cachedCloudRelays.length}件',
    );

    try {
      await saveDataToFirebase();
    } catch (e) {
      debugPrint('ユーザー情報と友達アクセス設定の初期保存に失敗: $e');
    }

    await cleanupSelfRelayData();
    await syncPendingRelayQueue();
  }

  List<Map<String, dynamic>> loadRelayQueueFromPrefs(SharedPreferences prefs) {
    final raw = prefs.getString('relay_queue_json');
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

  Future<void> saveRelayQueueToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('relay_queue_json', jsonEncode(relayQueue));
  }

  Future<void> saveCachedCloudRelays() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(
      'cached_cloud_relays_json',
      jsonEncode(cachedCloudRelays),
    );
  }

  Future<void> updateCachedCloudRelays(List<QueryDocumentSnapshot> docs) async {
    final newRelays = docs.map((doc) {
      final data = Map<String, dynamic>.from(
        doc.data() as Map<String, dynamic>,
      );

      // FirestoreのTimestampを保存可能な文字列に変換
      data.updateAll((key, value) {
        if (value is Timestamp) {
          return value.toDate().toIso8601String();
        }
        return value;
      });

      data['sourceUserId'] = doc.id;
      return data;
    }).toList();

    if (newRelays.isEmpty) {
      if (cachedCloudRelays.isEmpty) return;
      cachedCloudRelays = [];
      await saveCachedCloudRelays();
      if (mounted) setState(() {});
      return;
    }

    // 保存済みデータと同じなら、書き込みを繰り返さない
    if (jsonEncode(cachedCloudRelays) == jsonEncode(newRelays)) {
      return;
    }

    cachedCloudRelays = newRelays;
    await saveCachedCloudRelays();
  }

  Future<void> cleanupSelfRelayData() async {
    if (myUserId.isEmpty) return;

    bool queueChanged = false;

    relayQueue.removeWhere((item) {
      final sourceUserId = item['sourceUserId']?.toString();
      final relayedByUserId = item['relayedByUserId']?.toString();

      final isSelfRelay =
          sourceUserId == myUserId && relayedByUserId == myUserId;

      if (isSelfRelay) {
        queueChanged = true;
      }

      return isSelfRelay;
    });

    if (queueChanged) {
      if (mounted) {
        setState(() {});
      }
      await saveRelayQueueToPrefs();
    }

    try {
      final latestRef = FirebaseFirestore.instance
          .collection('relay_latest')
          .doc(myUserId);

      final latestDoc = await latestRef.get();

      if (latestDoc.exists) {
        final latestData = latestDoc.data();
        final sourceUserId = latestData?['sourceUserId']?.toString();
        final relayedByUserId = latestData?['relayedByUserId']?.toString();

        if (sourceUserId == myUserId && relayedByUserId == myUserId) {
          await latestRef.delete();
        }
      }
    } catch (_) {
      // 通信できない場合は何もしない
    }

    try {
      final historySnapshot = await FirebaseFirestore.instance
          .collection('relay_history')
          .where('sourceUserId', isEqualTo: myUserId)
          .where('relayedByUserId', isEqualTo: myUserId)
          .get();

      for (final doc in historySnapshot.docs) {
        await doc.reference.delete();
      }
    } catch (_) {
      // 通信できない場合は何もしない
    }
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
    final authUser = FirebaseAuth.instance.currentUser;
    if (authUser != null) {
      await prefs.setString(_displayNameOwnerKey, authUser.uid);
    } else {
      await prefs.remove(_displayNameOwnerKey);
    }
    await saveDataToFirebase();
    setState(() {});
  }

  Future<void> saveDataToFirebase() async {
    if (myUserId.isEmpty || !_accountMappingReady) return;

    final authUser = FirebaseAuth.instance.currentUser;

    if (authUser == null) {
      debugPrint('Firebase未認証のためクラウド保存をスキップ');
      return;
    }

    final currentBatteryLevel = await getBatteryLevelSafely();

    if (mounted) {
      setState(() {
        batteryLevel = currentBatteryLevel;
      });
    }

    final canPersistLocation =
        _hasRegisteredEmailAccount && latitude != null && longitude != null;
    final profileData = <String, dynamic>{
      'userId': myUserId,
      'authUid': authUser.uid,
      'friendIds': friendIds,
      'updatedAt': FieldValue.serverTimestamp(),
      'latitude': canPersistLocation ? latitude : FieldValue.delete(),
      'longitude': canPersistLocation ? longitude : FieldValue.delete(),
      'accuracy': canPersistLocation ? accuracy : FieldValue.delete(),
      'locationCapturedAt': canPersistLocation
          ? lastLocationCapturedAt?.toIso8601String()
          : FieldValue.delete(),
      'batteryLevel': canPersistLocation
          ? currentBatteryLevel
          : FieldValue.delete(),
      'safetyStatus': safetyStatus == '譛ｪ逋ｻ骭ｲ'
          ? FieldValue.delete()
          : safetyStatus,
      'rescueRequest': rescueRequest ? true : FieldValue.delete(),
    };
    final enteredName = displayNameController.text.trim();
    if (enteredName.isNotEmpty) {
      profileData['displayName'] = enteredName;
    } else {
      profileData['displayName'] = FieldValue.delete();
    }

    await FirebaseFirestore.instance
        .collection('users')
        .doc(myUserId)
        .set(profileData, SetOptions(merge: true));

    await FirebaseFirestore.instance
        .collection('user_access')
        .doc(authUser.uid)
        .set({
          'authUid': authUser.uid,
          'userId': myUserId,
          'friendIds': friendIds,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
  }

  Future<void> addFriend() async {
    final friendId = friendIdController.text.trim();

    if (friendId.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('友達のIDを入力してください')));
      return;
    }

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

    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;

      setState(() => friendIds.add(friendId));
      await prefs.setStringList('friend_ids', friendIds);

      Object? cloudSaveError;
      try {
        await saveDataToFirebase();
      } catch (e) {
        cloudSaveError = e;
        debugPrint('友達IDのクラウド保存に失敗: $e');
      }

      if (!mounted) return;
      friendIdController.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            cloudSaveError == null
                ? '友達IDを登録しました。相手もあなたのIDを登録すると位置共有が始まります。'
                : '友達IDはこの端末に保存しましたが、Firestoreへの保存に失敗しました。'
                      'Firebaseのアクセス権限を確認してください。',
          ),
        ),
      );
    } catch (e) {
      debugPrint('友達IDの端末保存に失敗: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('友達IDを端末に保存できませんでした')));
    }
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('救助要請を公開しますか？'),
        content: const Text(
          '救助要請中は、あなたの位置・安否・電池情報がログイン中のアプリ利用者と管理者に共有されます。救助要請を解除すると、全利用者への共有を停止します。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('救助要請して共有'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      rescueRequest = true;
    });
    try {
      await saveDataToFirebase();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('救助要請を共有しました')));
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => rescueRequest = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('救助要請を保存できませんでした: $error')));
    }
  }

  Future<void> cancelRescueRequest() async {
    setState(() {
      rescueRequest = false;
    });
    await saveDataToFirebase();
  }

  Future<void> getCurrentLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();

      if (!serviceEnabled) {
        if (mounted) setState(() => locationMessage = '位置情報サービスがOFFです');
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.deniedForever ||
          permission == LocationPermission.denied) {
        if (mounted) setState(() => locationMessage = '位置情報権限が拒否されています');
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      ).timeout(const Duration(seconds: 15));

      final currentBatteryLevel = await getBatteryLevelSafely();
      if (!mounted) return;

      setState(() {
        latitude = position.latitude;
        longitude = position.longitude;
        accuracy = position.accuracy;
        batteryLevel = currentBatteryLevel;
        lastLocationCapturedAt = position.timestamp;

        locationMessage =
            '現在地\n'
            '緯度: ${position.latitude}\n'
            '経度: ${position.longitude}\n'
            '位置精度: ±${position.accuracy.toStringAsFixed(0)}m\n'
            '${accuracyLevelText(position.accuracy)}\n'
            '電池残量: ${batteryText(currentBatteryLevel)}';
      });

      final prefs = await SharedPreferences.getInstance();
      if (_hasRegisteredEmailAccount) {
        await prefs.setString(
          'last_location_data',
          jsonEncode({
            'latitude': latitude,
            'longitude': longitude,
            'accuracy': accuracy,
            'locationCapturedAt': lastLocationCapturedAt?.toIso8601String(),
          }),
        );
      } else {
        // 未登録時は画面上の一時表示だけにし、端末には保存しない。
        await prefs.remove('last_location_data');
      }

      // 未登録時はプロフィール保存時にFirestore上の位置フィールドも削除する。
      await saveDataToFirebase();
    } catch (e) {
      debugPrint('現在地の取得または保存に失敗: $e');
      if (mounted) {
        setState(() => locationMessage = '現在地の取得または保存に失敗しました: $e');
      }
    }
  }

  Future<void> updateLocationSilently() async {
    if (!_hasRegisteredEmailAccount ||
        lastLocationCapturedAt == null ||
        myUserId.isEmpty ||
        !_accountMappingReady ||
        _updatingLocationSilently) {
      return;
    }
    _updatingLocationSilently = true;

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      ).timeout(const Duration(seconds: 15));
      final currentBatteryLevel = await getBatteryLevelSafely();
      if (!mounted) return;

      setState(() {
        latitude = position.latitude;
        longitude = position.longitude;
        accuracy = position.accuracy;
        batteryLevel = currentBatteryLevel;
        lastLocationCapturedAt = position.timestamp;
        locationMessage =
            '現在地\n'
            '緯度: ${position.latitude}\n'
            '経度: ${position.longitude}\n'
            '位置精度: ±${position.accuracy.toStringAsFixed(0)}m\n'
            '${accuracyLevelText(position.accuracy)}\n'
            '電池残量: ${batteryText(currentBatteryLevel)}';
      });

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'last_location_data',
        jsonEncode({
          'latitude': latitude,
          'longitude': longitude,
          'accuracy': accuracy,
          'locationCapturedAt': lastLocationCapturedAt?.toIso8601String(),
        }),
      );
      await saveDataToFirebase();
    } catch (e) {
      debugPrint('バックグラウンド位置更新に失敗: $e');
    } finally {
      _updatingLocationSilently = false;
    }
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

  DateTime? parseIsoTime(dynamic value) {
    if (value is! String || value.isEmpty) return null;

    try {
      return DateTime.parse(value);
    } catch (_) {
      return null;
    }
  }

  DateTime? relayInfoTime(Map<String, dynamic> data) {
    return parseIsoTime(data['locationCapturedAt']) ??
        parseIsoTime(data['sourceUpdatedAt']) ??
        parseIsoTime(data['qrCreatedAt']);
  }

  bool isSameOrOlderRelayInfo(
    Map<String, dynamic> newData,
    Map<String, dynamic> latestData,
  ) {
    final newTime = relayInfoTime(newData);
    final latestTime = relayInfoTime(latestData);

    if (newTime == null || latestTime == null) {
      return false;
    }

    return newTime.isBefore(latestTime) || newTime.isAtSameMomentAs(latestTime);
  }

  bool isNewerRelayInfo(
    Map<String, dynamic> newData,
    Map<String, dynamic> latestData,
  ) {
    final newTime = relayInfoTime(newData);
    final latestTime = relayInfoTime(latestData);

    if (newTime == null) return false;
    if (latestTime == null) return true;

    return newTime.isAfter(latestTime);
  }

  bool isNewerIsoTime(dynamic newValue, dynamic oldValue) {
    final newTime = parseIsoTime(newValue);
    final oldTime = parseIsoTime(oldValue);

    if (newTime == null) return false;
    if (oldTime == null) return true;

    return newTime.isAfter(oldTime);
  }

  bool isSameOrOlderIsoTime(dynamic newValue, dynamic oldValue) {
    final newTime = parseIsoTime(newValue);
    final oldTime = parseIsoTime(oldValue);

    if (newTime == null || oldTime == null) return false;

    return newTime.isBefore(oldTime) || newTime.isAtSameMomentAs(oldTime);
  }

  String safeDocId(String value) {
    return value.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  }

  String historyDocId(Map<String, dynamic> item) {
    final sourceUserId = safeDocId(
      item['sourceUserId']?.toString() ?? 'unknown',
    );
    final readAt = safeDocId(item['readAt']?.toString() ?? 'unknown');
    final relayedByUserId = safeDocId(
      item['relayedByUserId']?.toString() ?? 'unknown',
    );

    return '${sourceUserId}_${readAt}_$relayedByUserId';
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

  String relaySyncStatusText(dynamic status) {
    if (status == 'sent') {
      return '送信済み';
    }

    if (status == 'rejected_old') {
      return '共有不可：最新情報より古いデータ';
    }

    return '未送信・送信待ち';
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

  String locationText(dynamic lat, dynamic lng) {
    if (lat is num && lng is num) {
      return '緯度 ${lat.toDouble().toStringAsFixed(5)}, 経度 ${lng.toDouble().toStringAsFixed(5)} 付近';
    }
    return '位置情報なし';
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
      'locationCapturedAt': lastLocationCapturedAt?.toIso8601String(),
      'sourceUpdatedAt': now,
      'qrCreatedAt': now,
      'hopCount': 0,
    };
  }

  Map<String, dynamic> normalizeDirectPerson(Map<String, dynamic> data) {
    final now = DateTime.now().toIso8601String();

    return {
      'type': 'relay_queue_item',
      'sourceUserId': data['sourceUserId'] ?? '',
      'displayName': data['displayName'] ?? '名前なし',
      'currentStatus': '未確認',
      'confirmedSafetyStatus': data['safetyStatus'] ?? '未登録',
      'rescueRequest': data['rescueRequest'] == true,
      'latitude': data['latitude'],
      'longitude': data['longitude'],
      'accuracy': data['accuracy'],
      'batteryLevel': data['batteryLevel'],
      'locationCapturedAt': data['locationCapturedAt'],
      'sourceUpdatedAt': data['sourceUpdatedAt'],
      'qrCreatedAt': data['qrCreatedAt'],
      'readAt': now,
      'relayedByUserId': myUserId,
      'relayedByName': displayName,
      'relayDeviceName': '$displayName 端末',
      'hopCount': 0,
      'syncStatus': 'pending',
      'latestSynced': false,
      'historySynced': false,
      'rejectReason': null,
    };
  }

  Map<String, dynamic> normalizeRelayedPerson(
    Map<String, dynamic> data, {
    required String relayedByName,
    required String relayedByUserId,
  }) {
    final now = DateTime.now().toIso8601String();
    final currentHop = data['hopCount'];
    final hopCount = currentHop is num ? currentHop.toInt() : 0;

    return {
      'type': 'relay_queue_item',
      'sourceUserId': data['sourceUserId'] ?? '',
      'displayName': data['displayName'] ?? '名前なし',
      'currentStatus': '未確認',
      'confirmedSafetyStatus':
          data['confirmedSafetyStatus'] ?? data['safetyStatus'] ?? '未登録',
      'rescueRequest': data['rescueRequest'] == true,
      'latitude': data['latitude'],
      'longitude': data['longitude'],
      'accuracy': data['accuracy'],
      'batteryLevel': data['batteryLevel'],
      'locationCapturedAt': data['locationCapturedAt'],
      'sourceUpdatedAt': data['sourceUpdatedAt'],
      'qrCreatedAt': data['qrCreatedAt'],
      'readAt': data['readAt'] ?? now,
      'relayedByUserId': relayedByUserId,
      'relayedByName': relayedByName,
      'relayDeviceName': '$relayedByName 端末',
      'hopCount': hopCount + 1,
      'syncStatus': 'pending',
      'latestSynced': false,
      'historySynced': false,
      'rejectReason': null,
    };
  }

  Future<bool> isOlderThanCloudLatest(Map<String, dynamic> item) async {
    final sourceUserId = item['sourceUserId']?.toString() ?? '';

    if (sourceUserId.isEmpty) {
      return false;
    }

    try {
      final latestDoc = await FirebaseFirestore.instance
          .collection('relay_latest')
          .doc(sourceUserId)
          .get();

      if (!latestDoc.exists) {
        return false;
      }

      final latestData = latestDoc.data();

      if (latestData == null) {
        return false;
      }

      // 新旧判定は「読み取った時刻 readAt」ではなく、
      // Aさん本人の情報が作られた時刻 sourceUpdatedAt / qrCreatedAt で判断する。
      return isSameOrOlderRelayInfo(item, latestData);
    } catch (_) {
      return false;
    }
  }

  bool isOlderThanLocalQueueLatest(Map<String, dynamic> item) {
    final sourceUserId = item['sourceUserId']?.toString() ?? '';

    if (sourceUserId.isEmpty) {
      return false;
    }

    final samePersonItems = relayQueue.where(
      (q) => q['sourceUserId']?.toString() == sourceUserId,
    );

    for (final existing in samePersonItems) {
      final existingStatus = existing['syncStatus'];
      if (existingStatus == 'rejected_old') continue;

      // ローカル比較も readAt ではなく、本人情報の作成時刻で判定する。
      if (isSameOrOlderRelayInfo(item, existing)) {
        return true;
      }
    }

    return false;
  }

  Future<void> saveRelayQueueItem(Map<String, dynamic> item) async {
    final sourceUserId = item['sourceUserId'];

    if (sourceUserId == null || sourceUserId.toString().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('QR情報にユーザーIDがありません')));
      return;
    }

    if (sourceUserId.toString() == myUserId) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('自分のQRは中継データとして保存できません'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 4),
        ),
      );

      return;
    }

    final isOldByLocal = isOlderThanLocalQueueLatest(item);
    if (isOldByLocal) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('このデータは端末内に保存されている最新の情報より古いため共有できません'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 4),
        ),
      );

      return;
    }

    final isOldByCloud = await isOlderThanCloudLatest(item);
    if (isOldByCloud) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('このデータは現在保存されている最新の情報より古いため共有できません'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 4),
        ),
      );

      return;
    }

    setState(() {
      relayQueue.removeWhere((p) => p['sourceUserId'] == sourceUserId);
      relayQueue.insert(0, item);
    });

    await saveRelayQueueToPrefs();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${item['displayName']} の最終確認情報を保存しました')),
    );

    await syncPendingRelayQueue();
  }

  Map<String, dynamic> relayCloudData(Map<String, dynamic> item) {
    return {
      'sourceUserId': item['sourceUserId'],
      'displayName': item['displayName'],
      'currentStatus': '未確認',
      'confirmedSafetyStatus': item['confirmedSafetyStatus'],
      'rescueRequest': item['rescueRequest'] == true,
      'latitude': item['latitude'],
      'longitude': item['longitude'],
      'accuracy': item['accuracy'],
      'batteryLevel': item['batteryLevel'],
      'locationCapturedAt': item['locationCapturedAt'],
      'sourceUpdatedAt': item['sourceUpdatedAt'],
      'qrCreatedAt': item['qrCreatedAt'],
      'readAt': item['readAt'],
      'relayedByUserId': item['relayedByUserId'],
      'relayAuthUid': FirebaseAuth.instance.currentUser?.uid,
      'relayedByName': item['relayedByName'],
      'relayDeviceName': item['relayDeviceName'],
      'hopCount': item['hopCount'],
      'reportNote': 'この情報は現在の状態を保証するものではありません。',
    };
  }

  Future<void> syncPendingRelayQueue() async {
    if (isRelaySyncing ||
        myUserId.isEmpty ||
        !_accountMappingReady ||
        relayQueue.isEmpty) {
      return;
    }

    isRelaySyncing = true;

    try {
      await _syncPendingRelayQueueInternal();
    } finally {
      isRelaySyncing = false;
    }
  }

  Future<void> _syncPendingRelayQueueInternal() async {
    bool changed = false;

    for (int i = 0; i < relayQueue.length; i++) {
      final item = relayQueue[i];

      if (item['syncStatus'] == 'sent') continue;
      if (item['syncStatus'] == 'rejected_old') continue;

      final sourceUserId = item['sourceUserId']?.toString() ?? '';
      if (sourceUserId.isEmpty) continue;

      final relayedByUserId = item['relayedByUserId']?.toString() ?? '';
      if (sourceUserId == myUserId && relayedByUserId == myUserId) {
        relayQueue.removeAt(i);
        i--;
        changed = true;
        continue;
      }

      final latestRef = FirebaseFirestore.instance
          .collection('relay_latest')
          .doc(sourceUserId);

      final historyRef = FirebaseFirestore.instance
          .collection('relay_history')
          .doc(historyDocId(item));

      try {
        final data = relayCloudData(item);

        final latestSnapshot = await latestRef.get(
          const GetOptions(source: Source.server),
        );

        bool shouldUpdateLatest = true;
        bool isOlderThanLatest = false;

        if (latestSnapshot.exists) {
          final latestData = latestSnapshot.data();

          if (latestData != null) {
            // 新旧判定は readAt ではなく、sourceUpdatedAt / qrCreatedAt で行う。
            if (isSameOrOlderRelayInfo(item, latestData)) {
              shouldUpdateLatest = false;
              isOlderThanLatest = true;
            } else if (isNewerRelayInfo(item, latestData)) {
              shouldUpdateLatest = true;
              isOlderThanLatest = false;
            } else {
              // 判定できない場合は、安全側として最新を上書きしない
              shouldUpdateLatest = false;
              isOlderThanLatest = true;
            }
          }
        }

        if (isOlderThanLatest) {
          relayQueue[i]['syncStatus'] = 'rejected_old';
          relayQueue[i]['rejectReason'] = 'このデータは現在保存されている最新の情報より古いため共有できません';
          relayQueue[i]['latestSynced'] = false;
          relayQueue[i]['historySynced'] = false;

          changed = true;
          continue;
        }

        if (shouldUpdateLatest) {
          await latestRef.set({
            ...data,
            'isOlderThanLatest': false,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

          await historyRef.set({
            ...data,
            'historyDocId': historyDocId(item),
            'isOlderThanLatest': false,
            'historyStatus': 'valid_history',
            'createdAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));

          relayQueue[i]['syncStatus'] = 'sent';
          relayQueue[i]['latestSynced'] = true;
          relayQueue[i]['historySynced'] = true;
          relayQueue[i]['rejectReason'] = null;

          changed = true;
        }
      } catch (e) {
        relayQueue[i]['syncStatus'] = 'pending';
        changed = true;
        debugPrint('中継データ送信失敗: $e');
      }
    }

    if (changed) {
      setState(() {});
      await saveRelayQueueToPrefs();
    }
  }

  Future<void> handleQrScannedValue(String value) async {
    try {
      final decoded = jsonDecode(value);

      if (decoded is Map) {
        final data = Map<String, dynamic>.from(decoded);
        final type = data['type'];

        if (type == 'disaster_user_info') {
          final item = normalizeDirectPerson(data);
          await saveRelayQueueItem(item);
          return;
        }

        if (type == 'disaster_relay_info') {
          final relayedByName = data['relayedByName']?.toString() ?? '不明な人';
          final relayedByUserId =
              data['relayedByUserId']?.toString() ?? 'unknown';
          final personData = data['person'];

          if (personData is! Map) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('リレーQRに人物情報がありません')));
            return;
          }

          final item = normalizeRelayedPerson(
            Map<String, dynamic>.from(personData),
            relayedByName: relayedByName,
            relayedByUserId: relayedByUserId,
          );

          await saveRelayQueueItem(item);
          return;
        }
      }
    } catch (_) {
      // JSONでなければ、従来通り「友達ID」として扱う
    }

    friendIdController.text = value;
    await addFriend();
  }

  Map<String, dynamic> buildRelayPayloadForPerson(Map<String, dynamic> item) {
    return {
      'type': 'disaster_relay_info',
      'relayedByUserId': myUserId,
      'relayedByName': displayName,
      'relayedAt': DateTime.now().toIso8601String(),
      'person': {
        'sourceUserId': item['sourceUserId'],
        'displayName': item['displayName'],
        'currentStatus': '未確認',
        'confirmedSafetyStatus': item['confirmedSafetyStatus'],
        'rescueRequest': item['rescueRequest'],
        'latitude': item['latitude'],
        'longitude': item['longitude'],
        'accuracy': item['accuracy'],
        'batteryLevel': item['batteryLevel'],
        'locationCapturedAt': item['locationCapturedAt'],
        'sourceUpdatedAt': item['sourceUpdatedAt'],
        'qrCreatedAt': item['qrCreatedAt'],
        'readAt': item['readAt'],
        'hopCount': item['hopCount'],
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
                  Text('位置: ${locationText(latitude, longitude)}'),
                  Text('位置精度: ${accuracyText(accuracy)}'),
                  Text('電池残量: ${batteryText(batteryLevel)}'),
                  const SizedBox(height: 8),
                  const Text(
                    'このQRを相手が読み取ると、あなたの「最終確認情報」として相手端末に保存されます。',
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

  void showRelayQrForPerson(Map<String, dynamic> item) {
    final syncStatus = item['syncStatus'];

    if (syncStatus == 'rejected_old') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('このデータは現在保存されている最新の情報より古いため共有できません'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 4),
        ),
      );
      return;
    }

    final payload = buildRelayPayloadForPerson(item);
    final qrData = jsonEncode(payload);

    final personName = item['displayName'] ?? '名前なし';

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Colors.white,
          title: Text('$personName の最終確認情報を共有'),
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
                    '読み取った人には「$displayName 経由」と表示されます。\n'
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

  Future<void> showRelayHistoryDialog(
    BuildContext context,
    String sourceUserId,
    String displayName,
  ) async {
    final snapshot = await FirebaseFirestore.instance
        .collection('relay_history')
        .where('sourceUserId', isEqualTo: sourceUserId)
        .get();

    final docs = snapshot.docs.where((doc) {
      final data = doc.data();
      final historySourceUserId = data['sourceUserId']?.toString();
      final historyRelayedByUserId = data['relayedByUserId']?.toString();

      return !(historySourceUserId == myUserId &&
          historyRelayedByUserId == myUserId);
    }).toList();

    docs.sort((a, b) {
      final aData = a.data();
      final bData = b.data();

      final aTime = parseIsoTime(aData['readAt']);
      final bTime = parseIsoTime(bData['readAt']);

      if (aTime == null && bTime == null) return 0;
      if (aTime == null) return 1;
      if (bTime == null) return -1;

      return bTime.compareTo(aTime);
    });

    if (!context.mounted) return;

    showDialog(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: Text('$displayName さんの履歴'),
          content: SizedBox(
            width: 420,
            child: docs.isEmpty
                ? const Text('履歴はありません')
                : SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: docs.map((doc) {
                        final data = doc.data();

                        final confirmedStatus =
                            data['confirmedSafetyStatus'] ?? '未登録';
                        final rescue = data['rescueRequest'] == true;
                        final readAt = data['readAt'];
                        final relayedByName = data['relayedByName'] ?? '不明';
                        final relayDeviceName =
                            data['relayDeviceName'] ?? '不明端末';
                        final accuracyValue = data['accuracy'];
                        final batteryValue = data['batteryLevel'];
                        final hopCount = data['hopCount'] is num
                            ? (data['hopCount'] as num).toInt()
                            : 0;

                        return Card(
                          color: rescue ? Colors.red.shade50 : Colors.white,
                          child: ListTile(
                            title: Text(
                              '${dateTimeTextFromIso(readAt)} の確認情報',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            subtitle: Text(
                              '現在の状態：未確認\n'
                              '安否：$confirmedStatus\n'
                              '救助要請：${rescue ? 'あり' : 'なし'}\n'
                              '電池残量：${batteryText(batteryValue)}\n'
                              '${batteryWarningText(batteryValue)}'
                              '位置精度：${accuracyText(accuracyValue)} / ${accuracyLevelText(accuracyValue)}\n'
                              '確認者：$relayedByName\n'
                              '経由：$relayDeviceName\n'
                              'リレー回数：$hopCount回\n'
                              '注意：この情報は現在の状態を保証するものではありません。',
                            ),
                          ),
                        );
                      }).toList(),
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
    openOfflineMap();
  }

  Future<void> openAccountPage() async {
    final previousUser = FirebaseAuth.instance.currentUser;
    _pendingAccountMigration = null;
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => AccountPage(
          beforeCurrentAccountLink: _captureAnonymousDataForMigration,
          beforeExistingAccountSignIn: _captureAnonymousDataForMigration,
        ),
      ),
    );
    if (changed == true && mounted) {
      final currentUser = FirebaseAuth.instance.currentUser;
      final becameRegisteredFromAnonymous =
          previousUser?.isAnonymous == true &&
          currentUser != null &&
          !currentUser.isAnonymous;
      await restoreFirebaseAccount(
        migrationData: becameRegisteredFromAnonymous
            ? _pendingAccountMigration
            : null,
      );
    }
    _pendingAccountMigration = null;
  }

  Future<void> _captureAnonymousDataForMigration() async {
    final sourceAuth = FirebaseAuth.instance.currentUser;
    if (sourceAuth == null || !sourceAuth.isAnonymous || myUserId.isEmpty) {
      _pendingAccountMigration = null;
      return;
    }

    final migrated = <String, dynamic>{'sourceUserId': myUserId};
    try {
      final sourceDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(myUserId)
          .get(const GetOptions(source: Source.serverAndCache))
          .timeout(const Duration(seconds: 8));
      final sourceData = sourceDoc.data();
      if (sourceData?['authUid'] == sourceAuth.uid) {
        for (final field in [
          'displayName',
          'latitude',
          'longitude',
          'accuracy',
          'locationCapturedAt',
          'batteryLevel',
          'safetyStatus',
          'rescueRequest',
        ]) {
          if (sourceData!.containsKey(field)) {
            migrated[field] = sourceData[field];
          }
        }
      }
    } catch (error) {
      debugPrint('移行元プロフィールの取得失敗: $error');
    }

    final enteredName = displayNameController.text.trim();
    if (enteredName.isNotEmpty) migrated['displayName'] = enteredName;
    if (latitude != null && longitude != null) {
      migrated['latitude'] = latitude;
      migrated['longitude'] = longitude;
      if (accuracy != null) migrated['accuracy'] = accuracy;
      if (lastLocationCapturedAt != null) {
        migrated['locationCapturedAt'] = lastLocationCapturedAt!
            .toIso8601String();
      }
    }
    if (batteryLevel != null) migrated['batteryLevel'] = batteryLevel;
    migrated['safetyStatus'] = safetyStatus;
    migrated['rescueRequest'] = rescueRequest;
    _pendingAccountMigration = migrated;
  }

  DateTime? _migrationLocationTime(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  Future<void> restoreFirebaseAccount({
    Map<String, dynamic>? migrationData,
  }) async {
    final authUser = FirebaseAuth.instance.currentUser;
    if (authUser == null) return;
    _accountMappingReady = false;

    try {
      final accessRef = FirebaseFirestore.instance
          .collection('user_access')
          .doc(authUser.uid);
      final accessDoc = await accessRef
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 8));
      final access = accessDoc.data();
      var mappedUserId = access?['userId']?.toString();
      final hasMappedProfile = mappedUserId != null && mappedUserId.isNotEmpty;
      if (!hasMappedProfile) {
        mappedUserId = 'user_${DateTime.now().microsecondsSinceEpoch}';
      }

      final userRef = FirebaseFirestore.instance
          .collection('users')
          .doc(mappedUserId);
      final userDoc = hasMappedProfile
          ? await userRef
                .get(const GetOptions(source: Source.server))
                .timeout(const Duration(seconds: 8))
          : null;
      final existingData = userDoc?.data();
      if (existingData != null && existingData['authUid'] != authUser.uid) {
        throw StateError('移行先ユーザー情報の所有者を確認できません。');
      }

      final mappedFriends = access?['friendIds'] is List
          ? (access!['friendIds'] as List).whereType<String>().toList()
          : <String>[];
      final merged = <String, dynamic>{
        'userId': mappedUserId,
        'authUid': authUser.uid,
        'friendIds': mappedFriends,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      final targetName = existingData?['displayName']?.toString().trim() ?? '';
      final sourceName = migrationData?['displayName']?.toString().trim() ?? '';
      merged['displayName'] = targetName.isNotEmpty
          ? targetName
          : sourceName.isNotEmpty
          ? sourceName
          : FieldValue.delete();

      final targetLat = existingData?['latitude'];
      final targetLng = existingData?['longitude'];
      final sourceLat = migrationData?['latitude'];
      final sourceLng = migrationData?['longitude'];
      final targetHasLocation = targetLat is num && targetLng is num;
      final sourceHasLocation = sourceLat is num && sourceLng is num;
      final targetTime = _migrationLocationTime(
        existingData?['locationCapturedAt'],
      );
      final sourceTime = _migrationLocationTime(
        migrationData?['locationCapturedAt'],
      );
      final useSourceLocation =
          sourceHasLocation &&
          (!targetHasLocation ||
              (sourceTime != null &&
                  (targetTime == null || sourceTime.isAfter(targetTime))));
      final chosenData = useSourceLocation ? migrationData : existingData;
      final hasLocation = useSourceLocation || targetHasLocation;
      merged['latitude'] = hasLocation
          ? chosenData!['latitude']
          : FieldValue.delete();
      merged['longitude'] = hasLocation
          ? chosenData!['longitude']
          : FieldValue.delete();
      merged['accuracy'] = hasLocation && chosenData!.containsKey('accuracy')
          ? chosenData['accuracy']
          : FieldValue.delete();
      merged['locationCapturedAt'] =
          hasLocation && chosenData!.containsKey('locationCapturedAt')
          ? chosenData['locationCapturedAt']
          : FieldValue.delete();

      final targetBattery = existingData?['batteryLevel'];
      final sourceBattery = migrationData?['batteryLevel'];
      merged['batteryLevel'] = targetBattery is num
          ? targetBattery
          : sourceBattery is num
          ? sourceBattery
          : FieldValue.delete();
      merged['safetyStatus'] = existingData?.containsKey('safetyStatus') == true
          ? existingData!['safetyStatus']
          : migrationData?['safetyStatus'] ?? FieldValue.delete();
      merged['rescueRequest'] =
          existingData?['rescueRequest'] == true ||
              migrationData?['rescueRequest'] == true
          ? true
          : FieldValue.delete();

      await userRef.set(merged, SetOptions(merge: true));
      await accessRef.set({
        'authUid': authUser.uid,
        'userId': mappedUserId,
        'friendIds': mappedFriends,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      final finalDoc = await userRef
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 8));
      final data = finalDoc.data();
      if (data == null || data['authUid'] != authUser.uid) {
        throw StateError('移行後のユーザー情報を確認できませんでした。');
      }

      final prefs = await SharedPreferences.getInstance();
      if (myUserId.isNotEmpty && myUserId != mappedUserId) {
        relayQueue = [];
        cachedCloudRelays = [];
        await prefs.setString('relay_queue_json', '[]');
        await prefs.remove('cached_cloud_relays_json');
      }
      await prefs.setString('user_id', mappedUserId);
      await prefs.setStringList('friend_ids', mappedFriends);
      final name = data['displayName']?.toString() ?? '';
      if (name.isNotEmpty) {
        await prefs.setString('display_name', name);
        await prefs.setString(_displayNameOwnerKey, authUser.uid);
      } else {
        await prefs.remove('display_name');
        await prefs.remove(_displayNameOwnerKey);
      }
      final locationTime = _migrationLocationTime(data['locationCapturedAt']);
      if (data['latitude'] is num && data['longitude'] is num) {
        await prefs.setString(
          'last_location_data',
          jsonEncode({
            'latitude': data['latitude'],
            'longitude': data['longitude'],
            'accuracy': data['accuracy'],
            'locationCapturedAt': locationTime?.toIso8601String(),
          }),
        );
      } else {
        await prefs.remove('last_location_data');
      }

      if (!mounted) return;
      _accountMappingReady = true;
      setState(() {
        myUserId = mappedUserId!;
        friendIds = mappedFriends;
        displayNameController.text = name;
        safetyStatus = data['safetyStatus']?.toString() ?? '譛ｪ逋ｻ骭ｲ';
        rescueRequest = data['rescueRequest'] == true;
        latitude = data['latitude'] is num
            ? (data['latitude'] as num).toDouble()
            : null;
        longitude = data['longitude'] is num
            ? (data['longitude'] as num).toDouble()
            : null;
        accuracy = data['accuracy'] is num
            ? (data['accuracy'] as num).toDouble()
            : null;
        lastLocationCapturedAt = locationTime;
        batteryLevel = data['batteryLevel'] is num
            ? (data['batteryLevel'] as num).toInt()
            : null;
      });

      await saveDataToFirebase();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              migrationData == null
                  ? 'アカウント情報を読み込みました。'
                  : '名前・位置・安否情報を既存アカウントへ引き継ぎました。',
            ),
          ),
        );
      }
    } catch (error) {
      _accountMappingReady = false;
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('データを引き継げませんでした: $error')));
      }
    }
  }

  List<Map<String, dynamic>> mergedRelayItems() {
    final byUserId = <String, Map<String, dynamic>>{};

    final visibleQueuedRelays = relayQueue.where((item) {
      final rawReadAt = item['readAt'];
      final readAt = rawReadAt is Timestamp
          ? rawReadAt.toDate()
          : rawReadAt is String
          ? DateTime.tryParse(rawReadAt)
          : null;
      final cutoff = _relayMapCacheCutoff;
      return readAt != null && (cutoff == null || readAt.isAfter(cutoff));
    });

    final visibleCachedRelays = cachedCloudRelays.where((item) {
      final sourceUserId = item['sourceUserId']?.toString() ?? '';
      return friendIds.contains(sourceUserId);
    });

    for (final item in [...visibleQueuedRelays, ...visibleCachedRelays]) {
      final userId = item['sourceUserId']?.toString() ?? '';

      if (userId.isEmpty) continue;

      final existing = byUserId[userId];

      if (existing == null) {
        byUserId[userId] = item;
        continue;
      }

      final newTime = relayInfoTime(item);
      final oldTime = relayInfoTime(existing);

      if (newTime != null && (oldTime == null || newTime.isAfter(oldTime))) {
        byUserId[userId] = item;
      }
    }

    return byUserId.values
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Future<void> openOfflineMap({Map<String, dynamic>? focusUser}) async {
    var emergencyUsers = <Map<String, dynamic>>[];
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('users')
          .where('rescueRequest', isEqualTo: true)
          .get(const GetOptions(source: Source.serverAndCache));
      emergencyUsers = snapshot.docs
          .map((doc) => <String, dynamic>{'userId': doc.id, ...doc.data()})
          .toList();
    } catch (error) {
      debugPrint('公開中の救助要請を取得できません: $error');
    }
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OfflineMapPage(
          myUserId: myUserId,
          friendIds: List<String>.from(friendIds),
          relayItems: mergedRelayItems(),
          emergencyUsers: emergencyUsers,
          focusUser: focusUser,
          initialCenter: _locationFromUser(focusUser),
        ),
      ),
    );
  }

  LatLng? _locationFromUser(Map<String, dynamic>? user) {
    final latitude = user?['latitude'];
    final longitude = user?['longitude'];
    if (latitude is! num || longitude is! num) return null;
    if (latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      return null;
    }
    return LatLng(latitude.toDouble(), longitude.toDouble());
  }

  Widget buildFriendTile(String friendId) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(friendId)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Card(
            child: ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('友達情報を取得できません'),
              subtitle: Text('通信状態またはアクセス権限を確認してください'),
            ),
          );
        }

        if (!snapshot.hasData) {
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

  Widget buildRelayQueueItemTile(Map<String, dynamic> item) {
    final name = item['displayName'] ?? '名前なし';
    final confirmedStatus = item['confirmedSafetyStatus'] ?? '未登録';
    final rescue = item['rescueRequest'] == true;
    final sourceUserId = item['sourceUserId'] ?? '';
    final readAt = item['readAt'];
    final hopCount = item['hopCount'] is num
        ? (item['hopCount'] as num).toInt()
        : 0;
    final relayedByName = item['relayedByName'] ?? displayName;
    final relayDeviceName = item['relayDeviceName'] ?? '$displayName 端末';
    final syncStatus = item['syncStatus'] ?? 'pending';
    final rejectReason = item['rejectReason'];
    final itemAccuracy = item['accuracy'];
    final itemBattery = item['batteryLevel'];
    final lat = item['latitude'];
    final lng = item['longitude'];

    return Card(
      color: syncStatus == 'sent'
          ? Colors.green.shade50
          : syncStatus == 'rejected_old'
          ? Colors.grey.shade300
          : Colors.orange.shade50,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          children: [
            ListTile(
              leading: Icon(
                syncStatus == 'rejected_old'
                    ? Icons.block
                    : rescue
                    ? Icons.warning
                    : Icons.move_to_inbox,
                color: syncStatus == 'rejected_old'
                    ? Colors.black54
                    : rescue
                    ? Colors.red
                    : Colors.orange,
              ),
              title: Text(
                '$name さんの最終確認情報',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: syncStatus == 'rejected_old'
                      ? Colors.black54
                      : rescue
                      ? Colors.red
                      : null,
                ),
              ),
              subtitle: Text(
                '現在の状態：未確認\n'
                '━━━━━━━━━━━━\n'
                '最後に確認された情報\n'
                '安否：$confirmedStatus\n'
                '救助要請：${rescue ? 'あり' : 'なし'}\n'
                '位置：${locationText(lat, lng)}\n'
                '位置精度：${accuracyText(itemAccuracy)} / ${accuracyLevelText(itemAccuracy)}\n'
                '電池残量：${batteryText(itemBattery)}\n'
                '${batteryWarningText(itemBattery)}'
                'QR作成時刻：${dateTimeTextFromIso(item['sourceUpdatedAt'])}\n'
                '確認者：$relayedByName\n'
                '情報元：$name さんのQR\n'
                '確認時刻：${dateTimeTextFromIso(readAt)}（${elapsedTextFromIso(readAt)}）\n'
                '経由：$relayDeviceName\n'
                'リレー回数：$hopCount回\n'
                '送信状態：${relaySyncStatusText(syncStatus)}\n'
                '${syncStatus == 'rejected_old' ? '⚠ ${rejectReason ?? 'このデータは現在保存されている最新の情報より古いため共有できません'}\n' : ''}'
                'ID：$sourceUserId\n'
                '━━━━━━━━━━━━\n'
                '注意：この情報は現在の状態を保証するものではありません。',
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ElevatedButton.icon(
                    onPressed: syncStatus == 'rejected_old'
                        ? null
                        : () => showRelayQrForPerson(item),
                    icon: const Icon(Icons.qr_code),
                    label: Text('$name さん情報をQRで渡す'),
                  ),
                  ElevatedButton.icon(
                    onPressed: syncPendingRelayQueue,
                    icon: const Icon(Icons.sync),
                    label: const Text('未送信を同期'),
                  ),
                ],
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

  Widget offlineRelayCard() {
    final pendingCount = relayQueue
        .where((item) => item['syncStatus'] == 'pending')
        .length;

    final rejectedCount = relayQueue
        .where((item) => item['syncStatus'] == 'rejected_old')
        .length;

    final hasIssue = pendingCount > 0 || rejectedCount > 0;

    return Card(
      color: hasIssue ? Colors.orange.shade50 : Colors.grey.shade100,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  hasIssue ? Icons.outbox : Icons.check_circle_outline,
                  color: hasIssue ? Colors.orange : Colors.green,
                ),
                const SizedBox(width: 8),
                Text(
                  hasIssue ? '未送信の中継データがあります' : '未送信の中継データ：0件',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: hasIssue ? Colors.orange.shade900 : Colors.green,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '未送信：$pendingCount 件 / 共有不可：$rejectedCount 件',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: hasIssue ? Colors.red : Colors.green,
              ),
            ),

            if (hasIssue) ...[
              const SizedBox(height: 8),
              const Text(
                '通信できるようになったら未送信データを送信します。共有不可データは最新情報より古いため送信されません。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12),
              ),
            ],
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
                if (hasIssue)
                  ElevatedButton.icon(
                    onPressed: syncPendingRelayQueue,
                    icon: const Icon(Icons.sync),
                    label: const Text('未送信を同期'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget relayQueueCard() {
    final visibleQueue = relayQueue
        .where((item) => item['syncStatus'] != 'sent')
        .toList();

    if (visibleQueue.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      color: Colors.orange.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text(
              '端末内の未送信・共有不可データ',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'ここは送信前の一時保管エリアです。通常は「中継で届いた最新の最終確認情報」を見てください。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Column(
              children: visibleQueue
                  .map((item) => buildRelayQueueItemTile(item))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget cloudRelayLatestCard() {
    final visibleFriendIds = friendIds
        .where((id) => id.isNotEmpty)
        .toSet()
        .take(30)
        .toList();
    return Card(
      color: Colors.yellow.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text(
              '中継で届いた最新の最終確認情報',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              '相互登録済みの友達から届いた情報を表示します。古いQRで上書きされることはありません。友達が30人を超える場合、この一覧は先頭30人が対象です。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            if (visibleFriendIds.isEmpty)
              const Text('相互登録済みの友達からの中継情報はありません')
            else
              StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('relay_latest')
                    .where('sourceUserId', whereIn: visibleFriendIds)
                    .snapshots(),

                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        'QR中継情報を取得できません。\n'
                        '通信状態を確認し、友達同士で互いのIDを登録済みか確認してください。',
                      ),
                    );
                  }

                  if (!snapshot.hasData) {
                    return const Padding(
                      padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator(),
                    );
                  }

                  final docs = snapshot.data!.docs.where((doc) {
                    final data = doc.data() as Map<String, dynamic>;
                    final sourceUserId = data['sourceUserId']?.toString();
                    final relayedByUserId = data['relayedByUserId']?.toString();

                    return !(sourceUserId == myUserId &&
                        relayedByUserId == myUserId);
                  }).toList();

                  docs.sort((a, b) {
                    final aData = a.data() as Map<String, dynamic>;
                    final bData = b.data() as Map<String, dynamic>;

                    // 最新一覧の並び順も、読み取った時刻ではなく本人情報の作成時刻で判断する
                    final aTime = relayInfoTime(aData);
                    final bTime = relayInfoTime(bData);

                    if (aTime == null && bTime == null) return 0;
                    if (aTime == null) return 1;
                    if (bTime == null) return -1;

                    return bTime.compareTo(aTime);
                  });

                  if (!snapshot.data!.metadata.hasPendingWrites &&
                      !snapshot.data!.metadata.isFromCache) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        updateCachedCloudRelays(docs);
                      }
                    });
                  }

                  if (docs.isEmpty) {
                    return const Text('まだ中継情報は届いていません');
                  }

                  return Column(
                    children: docs.map((doc) {
                      final data = doc.data() as Map<String, dynamic>;

                      final sourceUserId = data['sourceUserId'] ?? doc.id;
                      final name = data['displayName'] ?? '名前なし';
                      final confirmedStatus =
                          data['confirmedSafetyStatus'] ?? '未登録';
                      final rescue = data['rescueRequest'] == true;
                      final lat = data['latitude'];
                      final lng = data['longitude'];
                      final sourceUpdatedAt = data['sourceUpdatedAt'];
                      final readAt = data['readAt'];
                      final relayedByName = data['relayedByName'] ?? '不明';
                      final relayDeviceName = data['relayDeviceName'] ?? '不明端末';
                      final accuracyValue = data['accuracy'];
                      final batteryValue = data['batteryLevel'];
                      final hopCount = data['hopCount'] is num
                          ? (data['hopCount'] as num).toInt()
                          : 0;

                      return Card(
                        color: rescue ? Colors.red.shade50 : Colors.white,
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Column(
                            children: [
                              ListTile(
                                leading: Icon(
                                  rescue ? Icons.warning : Icons.fact_check,
                                  color: rescue ? Colors.red : Colors.blueGrey,
                                ),
                                title: Text(
                                  '$name さんの最新確認情報',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: rescue ? Colors.red : Colors.black,
                                  ),
                                ),
                                subtitle: Text(
                                  '現在の状態：未確認\n'
                                  '━━━━━━━━━━━━\n'
                                  '最後に確認された情報\n'
                                  '安否：$confirmedStatus\n'
                                  '救助要請：${rescue ? 'あり' : 'なし'}\n'
                                  '位置：${locationText(lat, lng)}\n'
                                  '位置精度：${accuracyText(accuracyValue)} / ${accuracyLevelText(accuracyValue)}\n'
                                  '電池残量：${batteryText(batteryValue)}\n'
                                  '${batteryWarningText(batteryValue)}'
                                  '本人情報の作成：${dateTimeTextFromIso(sourceUpdatedAt)}\n'
                                  '確認者：$relayedByName\n'
                                  '情報元：$name さんのQR\n'
                                  '確認時刻：${dateTimeTextFromIso(readAt)}（${elapsedTextFromIso(readAt)}）\n'
                                  '経由：$relayDeviceName\n'
                                  'リレー回数：$hopCount回\n'
                                  '━━━━━━━━━━━━\n'
                                  '注意：この情報は現在の状態を保証するものではありません。',
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                child: SizedBox(
                                  width: double.infinity,
                                  child: OutlinedButton.icon(
                                    onPressed: () => showRelayHistoryDialog(
                                      context,
                                      sourceUserId.toString(),
                                      name.toString(),
                                    ),
                                    icon: const Icon(Icons.history),
                                    label: const Text('履歴を見る'),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget emergencyRequestsCard() {
    return Card(
      color: Colors.red.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text(
              '公開中の救助要請',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            const Text(
              '本人が救助要請を有効にしている間、ログイン中の利用者に表示されます。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .where('rescueRequest', isEqualTo: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Text('救助要請を取得できません。通信状態を確認してください。');
                }
                if (!snapshot.hasData) {
                  return const CircularProgressIndicator();
                }
                final docs = snapshot.data!.docs;
                if (docs.isEmpty) return const Text('現在、公開中の救助要請はありません。');
                return Column(
                  children: docs.map((doc) {
                    final data = doc.data();
                    final lat = data['latitude'];
                    final lng = data['longitude'];
                    final location = lat is num && lng is num
                        ? '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}'
                        : '位置情報なし';
                    final battery = data['batteryLevel'];
                    return ListTile(
                      leading: const Icon(Icons.warning, color: Colors.red),
                      title: Text(data['displayName']?.toString() ?? '名前なし'),
                      subtitle: Text(
                        '安否: ${data['safetyStatus'] ?? '未登録'} / '
                        '位置: $location / '
                        '電池: ${battery is num ? '${battery.toInt()}%' : '不明'}\n'
                        '最終更新: ${dateTimeText(data['updatedAt'])} '
                        '（${elapsedText(data['updatedAt'])}）',
                      ),
                      isThreeLine: true,
                      trailing: const Icon(Icons.map_outlined),
                      onTap: () => openOfflineMap(
                        focusUser: {'userId': doc.id, ...data},
                      ),
                    );
                  }).toList(),
                );
              },
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
              '友達のIDを登録します。お互いにIDを登録すると、名前・安否・位置を共有できます。',
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

            ElevatedButton.icon(
              onPressed: openOfflineMap,
              icon: const Icon(Icons.map),
              label: const Text('オフライン地図テスト'),
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
              '友達本人もあなたのIDを登録すると共有が有効になります。救助要請中の人は全利用者に公開されます。',
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
    final pendingCount = relayQueue
        .where((item) => item['syncStatus'] == 'pending')
        .length;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          pendingCount > 0 ? '災害位置共有アプリ（未送信$pendingCount件）' : '災害位置共有アプリ',
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(icon: const Icon(Icons.qr_code), onPressed: showMyQrCode),
          IconButton(
            tooltip: 'アカウント',
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: openAccountPage,
          ),
          IconButton(
            tooltip: '管理者画面',
            icon: const Icon(Icons.admin_panel_settings_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AdminDashboardPage()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.groups),
            onPressed: openAllUsersMap,
          ),
          IconButton(
            icon: const Icon(Icons.sync),
            onPressed: syncPendingRelayQueue,
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
            offlineRelayCard(),
            const SizedBox(height: 12),
            relayQueueCard(),
            const SizedBox(height: 12),
            cloudRelayLatestCard(),
            const SizedBox(height: 12),
            emergencyRequestsCard(),
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
      return Colors.red.withValues(alpha: 0.18);
    }

    if (isLowBattery(batteryLevelValue)) {
      return Colors.red.withValues(alpha: 0.12);
    }

    if (connStatus == 'offlineCandidate') {
      return Colors.grey.withValues(alpha: 0.18);
    }

    if (connStatus == 'old') {
      return Colors.deepOrange.withValues(alpha: 0.14);
    }

    if (connStatus == 'delayed') {
      return Colors.orange.withValues(alpha: 0.14);
    }

    return Colors.blue.withValues(alpha: 0.14);
  }

  Color accuracyCircleBorderColor(
    bool rescue,
    String connStatus,
    dynamic batteryLevelValue,
  ) {
    if (rescue) {
      return Colors.red.withValues(alpha: 0.65);
    }

    if (isLowBattery(batteryLevelValue)) {
      return Colors.red.withValues(alpha: 0.5);
    }

    if (connStatus == 'offlineCandidate') {
      return Colors.grey.withValues(alpha: 0.65);
    }

    if (connStatus == 'old') {
      return Colors.deepOrange.withValues(alpha: 0.55);
    }

    if (connStatus == 'delayed') {
      return Colors.orange.withValues(alpha: 0.55);
    }

    return Colors.blue.withValues(alpha: 0.45);
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
    final targetIds = {
      if (myUserId.isNotEmpty) myUserId,
      ...friendIds.where((id) => id.isNotEmpty),
    };
    final queryIds = targetIds.take(30).toList();

    if (queryIds.isEmpty) {
      return const Scaffold(body: Center(child: Text('表示できるユーザーIDがありません')));
    }

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
                  .where(FieldPath.documentId, whereIn: queryIds)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'ユーザーの位置情報を取得できません。\n'
                        '通信状態またはアクセス権限を確認してください。',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }

                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final groupedUsers = <String, List<Map<String, dynamic>>>{};
                final accuracyCircles = <CircleMarker>[];

                LatLng center = const LatLng(26.6232, 127.9747);

                for (final doc in snapshot.data!.docs) {
                  if (!targetIds.contains(doc.id)) continue;

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
                      tileProvider: NetworkTileProvider(),
                      maxNativeZoom: 19,
                      maxZoom: 19,
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
