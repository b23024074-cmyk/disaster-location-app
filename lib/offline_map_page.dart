import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_vector_tiles/flutter_map_vector_tiles.dart' as vt;
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OfflineMapPage extends StatefulWidget {
  final String myUserId;
  final List<String> friendIds;
  final List<Map<String, dynamic>> relayItems;
  final List<Map<String, dynamic>> emergencyUsers;
  final Map<String, dynamic>? focusUser;
  final LatLng? initialCenter;

  const OfflineMapPage({
    super.key,
    required this.myUserId,
    required this.friendIds,
    required this.relayItems,
    this.emergencyUsers = const [],
    this.focusUser,
    this.initialCenter,
  });

  @override
  State<OfflineMapPage> createState() => _OfflineMapPageState();
}

class _PmTilesAssetClient extends http.BaseClient {
  Future<Uint8List>? _archiveBytes;
  bool _closed = false;

  Future<Uint8List> _loadArchive() async {
    final data = await rootBundle.load('assets/maps/okinawa_north.pmtiles');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw http.ClientException('PMTiles client is closed');
    if (request.method != 'GET') {
      return http.StreamedResponse(const Stream<List<int>>.empty(), 405);
    }

    final bytes = await (_archiveBytes ??= _loadArchive());
    final range = request.headers['range'];
    if (range == null) {
      return http.StreamedResponse(
        Stream<List<int>>.value(bytes),
        200,
        contentLength: bytes.length,
        request: request,
        headers: const {'content-type': 'application/octet-stream'},
      );
    }

    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
    if (match == null) {
      return http.StreamedResponse(
        const Stream<List<int>>.empty(),
        416,
        request: request,
        headers: {'content-range': 'bytes */${bytes.length}'},
      );
    }

    final start = int.parse(match.group(1)!);
    final requestedEnd = match.group(2)!.isEmpty
        ? bytes.length - 1
        : int.parse(match.group(2)!);
    if (start >= bytes.length || requestedEnd < start) {
      return http.StreamedResponse(
        const Stream<List<int>>.empty(),
        416,
        request: request,
        headers: {'content-range': 'bytes */${bytes.length}'},
      );
    }

    final end = requestedEnd.clamp(0, bytes.length - 1).toInt();
    final chunk = Uint8List.sublistView(bytes, start, end + 1);
    return http.StreamedResponse(
      Stream<List<int>>.value(chunk),
      206,
      contentLength: chunk.length,
      request: request,
      headers: {
        'accept-ranges': 'bytes',
        'content-range': 'bytes $start-$end/${bytes.length}',
        'content-type': 'application/octet-stream',
      },
    );
  }

  @override
  void close() {
    _closed = true;
    _archiveBytes = null;
  }
}

class _OfflineMapPageState extends State<OfflineMapPage> {
  final MapController _mapController = MapController();
  late final _PmTilesAssetClient _pmTilesClient;
  late final Future<vt.PmTilesVectorTileProvider> _mapFuture;

  LatLng? _currentLocation;
  double? _locationAccuracy;
  DateTime? _currentLocationCapturedAt;
  bool _gettingLocation = false;

  List<Map<String, dynamic>> _savedFriends = [];
  Map<String, dynamic>? _myUserData;
  bool _loadingFriends = false;
  static const String _friendsCacheKey = 'offline_map_friends_v2';
  static const String _legacyFriendsCacheKey = 'offline_map_friends_v1';

  // BBBikeのベクターデータを表示する簡易スタイル
  static const String _styleJson = '''
  {
    "version": 8,
    "name": "Okinawa Offline",
    "sources": {"okinawa": {"type": "vector"}},
    "layers": [
      {"id": "background", "type": "background", "paint": {"background-color": "#f5f2e9"}},
      {"id": "landcover", "type": "fill", "source": "okinawa", "source-layer": "landcover", "paint": {"fill-color": "#d6e9c6"}},
      {"id": "park", "type": "fill", "source": "okinawa", "source-layer": "park", "paint": {"fill-color": "#abd79e"}},
      {"id": "water", "type": "fill", "source": "okinawa", "source-layer": "water", "paint": {"fill-color": "#91c9ee"}},
      {"id": "buildings", "type": "fill", "source": "okinawa", "source-layer": "building", "minzoom": 12, "paint": {"fill-color": "#c8bba8", "fill-opacity": 0.85}},
      {"id": "roads-outline", "type": "line", "source": "okinawa", "source-layer": "transportation", "paint": {"line-color": "#a99b88", "line-width": 2.6}},
      {"id": "roads", "type": "line", "source": "okinawa", "source-layer": "transportation", "paint": {"line-color": "#ffffff", "line-width": 1.6}},
      {"id": "place-labels", "type": "symbol", "source": "okinawa", "source-layer": "place", "minzoom": 8, "filter": ["match", ["get", "class"], ["city", "town", "village", "hamlet", "suburb", "neighbourhood"], true, false], "layout": {"text-field": "{name:latin}", "text-font": ["Noto Sans JP"], "text-size": 13, "text-max-width": 8, "text-allow-overlap": false}, "paint": {"text-color": "#51483f", "text-halo-color": "#fffdf7", "text-halo-width": 2}},
      {"id": "road-labels", "type": "symbol", "source": "okinawa", "source-layer": "transportation_name", "minzoom": 13, "filter": ["match", ["get", "class"], ["motorway", "trunk", "primary", "secondary", "tertiary", "minor"], true, false], "layout": {"symbol-placement": "line", "text-field": "{name:latin}", "text-font": ["Noto Sans JP"], "text-size": 10, "text-max-angle": 30, "text-keep-upright": true, "text-allow-overlap": false}, "paint": {"text-color": "#665d54", "text-halo-color": "#ffffff", "text-halo-width": 1.5}},
      {"id": "important-poi-labels", "type": "symbol", "source": "okinawa", "source-layer": "poi", "minzoom": 13, "filter": ["match", ["get", "class"], ["hospital", "clinic", "doctors", "fire_station", "police", "shelter", "school", "community_centre", "townhall"], true, false], "layout": {"text-field": "{name:latin}", "text-font": ["Noto Sans JP"], "text-size": 11, "text-max-width": 9, "text-offset": [0, 0.8], "text-anchor": "top", "text-allow-overlap": false}, "paint": {"text-color": "#7a3f36", "text-halo-color": "#fffdf7", "text-halo-width": 2}}
    ]
  }
  ''';

  @override
  void initState() {
    super.initState();
    _loadMyUserData();
    _pmTilesClient = _PmTilesAssetClient();
    _mapFuture = vt.PmTilesVectorTileProvider.open(
      'asset://maps/okinawa_north.pmtiles',
      client: _pmTilesClient,
    );
    _initializeFriends();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _getCurrentLocation();
    });
  }

  Future<void> _initializeFriends() async {
    // 位置情報リセット前の端末キャッシュを一度だけ破棄する。
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_legacyFriendsCacheKey);
    } catch (e) {
      debugPrint('古い友達位置キャッシュの削除失敗: $e');
    }
    await _loadSavedFriends();
    if (mounted) await _refreshFriends();
  }

  @override
  void dispose() {
    _mapController.dispose();
    _mapFuture.then<void>((provider) {
      provider.dispose();
      _pmTilesClient.close();
    }, onError: (Object _) => _pmTilesClient.close());
    super.dispose();
  }

  Future<void> _loadSavedFriends() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_friendsCacheKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List || !mounted) return;

      setState(() {
        _savedFriends = decoded
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .where(
              (item) => widget.friendIds.contains(item['userId']?.toString()),
            )
            .where(
              (item) => item['latitude'] is num && item['longitude'] is num,
            )
            .toList();
      });
    } catch (e) {
      debugPrint('友達キャッシュの読み込み失敗: $e');
    }
  }

  Future<void> _refreshFriends() async {
    if (_loadingFriends || widget.friendIds.isEmpty || !mounted) return;
    setState(() => _loadingFriends = true);
    try {
      final results = await Future.wait(
        widget.friendIds.map((id) async {
          try {
            final doc = await FirebaseFirestore.instance
                .collection('users')
                .doc(id)
                .get(const GetOptions(source: Source.server))
                .timeout(const Duration(seconds: 5));
            final data = doc.data();
            if (data == null) {
              return <String, dynamic>{
                'userId': id,
                '_removeCachedLocation': true,
              };
            }
            final lat = data['latitude'];
            final lng = data['longitude'];
            if (lat is! num || lng is! num) {
              return <String, dynamic>{
                'userId': id,
                '_removeCachedLocation': true,
              };
            }
            final updatedAt = data['updatedAt'];
            return <String, dynamic>{
              'userId': id,
              'displayName': data['displayName']?.toString() ?? '名前なし',
              'latitude': lat.toDouble(),
              'longitude': lng.toDouble(),
              'accuracy': data['accuracy'],
              'locationCapturedAt': _cacheSafeTime(data['locationCapturedAt']),
              'batteryLevel': data['batteryLevel'],
              'safetyStatus': data['safetyStatus']?.toString() ?? '未登録',
              'rescueRequest': data['rescueRequest'] == true,
              'updatedAt': updatedAt is Timestamp
                  ? updatedAt.toDate().toIso8601String()
                  : null,
            };
          } catch (e) {
            if (e is FirebaseException && e.code == 'permission-denied') {
              // 読めなくなった相手の古いピンは表示し続けない。
              return <String, dynamic>{
                'userId': id,
                '_removeCachedLocation': true,
              };
            }
            debugPrint('友達 $id の取得失敗（保存済み情報を維持）: $e');
            return null;
          }
        }),
      );

      if (!mounted) return;
      final byId = <String, Map<String, dynamic>>{
        for (final item in _savedFriends)
          if (item['userId'] is String) item['userId'] as String: item,
      };
      for (final item in results) {
        if (item == null) continue;
        final key = item['userId'] as String;
        if (item['_removeCachedLocation'] == true) {
          byId.remove(key);
          continue;
        }
        final existing = byId[key];
        // 時刻が不明なデータで既存情報を上書きすることを避ける。
        final nextTime = _parseLocationTime(item['locationCapturedAt']);
        final oldTime = _parseLocationTime(existing?['locationCapturedAt']);

        if (existing == null) {
          byId[key] = item;
          continue;
        }

        // GPS取得時刻が新しい場合だけ、位置情報を更新する
        final useNewLocation =
            nextTime != null && (oldTime == null || nextTime.isAfter(oldTime));

        // 安否情報はFirestoreの更新日時で比較する
        final nextUpdatedAt = DateTime.tryParse(
          item['updatedAt']?.toString() ?? '',
        );
        final oldUpdatedAt = DateTime.tryParse(
          existing['updatedAt']?.toString() ?? '',
        );

        final useNewStatus =
            nextUpdatedAt != null &&
            (oldUpdatedAt == null || nextUpdatedAt.isAfter(oldUpdatedAt));

        // 基本は保存済み情報を維持する
        final merged = Map<String, dynamic>.from(existing);

        // GPS取得時刻が新しい場合だけ位置情報を更新
        if (useNewLocation) {
          for (final field in [
            'latitude',
            'longitude',
            'accuracy',
            'locationCapturedAt',
          ]) {
            merged[field] = item[field];
          }
        }

        // Firestore更新日時が新しい場合だけ安否情報などを更新
        if (useNewStatus) {
          for (final field in [
            'displayName',
            'batteryLevel',
            'safetyStatus',
            'rescueRequest',
            'updatedAt',
          ]) {
            merged[field] = item[field];
          }
        }

        byId[key] = merged;
      }
      final updated = byId.values
          .where(
            (item) => widget.friendIds.contains(item['userId']?.toString()),
          )
          .toList();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_friendsCacheKey, jsonEncode(updated));
      if (!mounted) return;
      setState(() => _savedFriends = updated);
    } catch (e) {
      debugPrint('友達データ保存エラー: $e');
    } finally {
      if (mounted) setState(() => _loadingFriends = false);
    }
  }

  DateTime? _parseLocationTime(dynamic value) {
    DateTime? parsed;

    if (value is Timestamp) {
      parsed = value.toDate();
    } else if (value is String) {
      parsed = DateTime.tryParse(value);
    }

    if (parsed == null) return null;

    // 端末の現在時刻より未来の位置情報は採用しない
    if (parsed.isAfter(DateTime.now().add(const Duration(minutes: 5)))) {
      return null;
    }

    return parsed;
  }

  dynamic _cacheSafeTime(dynamic value) {
    if (value is Timestamp) return value.toDate().toIso8601String();
    if (value is DateTime) return value.toIso8601String();
    return value;
  }

  String _formatDateTime(dynamic value) {
    if (value == null) return '不明';

    DateTime? dateTime;

    if (value is Timestamp) {
      dateTime = value.toDate();
    } else if (value is String) {
      dateTime = DateTime.tryParse(value);
    }

    if (dateTime == null) return '不明';

    final local = dateTime.toLocal();
    final diff = DateTime.now().difference(local);

    final date =
        '${local.year}/${local.month.toString().padLeft(2, '0')}/'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';

    String elapsed;

    if (diff.isNegative) {
      elapsed = '時刻要確認';
    } else if (diff.inSeconds < 60) {
      elapsed = '${diff.inSeconds}秒前';
    } else if (diff.inMinutes < 60) {
      elapsed = '${diff.inMinutes}分前';
    } else if (diff.inHours < 24) {
      elapsed = '${diff.inHours}時間前';
    } else {
      elapsed = '${diff.inDays}日前';
    }

    return '$date（$elapsed）';
  }

  String _connectionStatus(dynamic updatedAt) {
    DateTime? dateTime;

    if (updatedAt is Timestamp) {
      dateTime = updatedAt.toDate();
    } else if (updatedAt is String) {
      dateTime = DateTime.tryParse(updatedAt);
    }

    if (dateTime == null) return 'unknown';

    final diff = DateTime.now().difference(dateTime);

    if (diff.isNegative) return 'unknown';

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

  String _connectionStatusLabel(String status) {
    switch (status) {
      case 'online':
        return '3分以内に更新あり';
      case 'delayed':
        return '3〜10分前に更新';
      case 'old':
        return '10〜30分前に更新';
      case 'offlineCandidate':
        return '30分以上更新なし';
      default:
        return '更新時刻不明';
    }
  }

  Future<void> _loadMyUserData() async {
    if (widget.myUserId.isEmpty) return;
    final userRef = FirebaseFirestore.instance
        .collection('users')
        .doc(widget.myUserId);

    try {
      final doc = await userRef.get(const GetOptions(source: Source.cache));

      if (!mounted) return;

      if (doc.exists) {
        setState(() {
          _myUserData = doc.data();
        });
        debugPrint('自分の情報：キャッシュから取得成功');
      } else {
        debugPrint('自分の情報：キャッシュにデータなし');
      }
    } catch (e) {
      debugPrint('自分の保存済み情報の読み込みエラー: $e');
    }

    try {
      final doc = await userRef
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 5));

      if (!mounted || !doc.exists) return;
      setState(() => _myUserData = doc.data());
    } catch (e) {
      debugPrint('自分の最新情報の取得失敗（保存済み情報を維持）: $e');
    }
  }

  Color _friendColor(Map<String, dynamic> friend) {
    if (friend['rescueRequest'] == true) return Colors.red;
    switch (friend['safetyStatus']) {
      case '無事':
        return Colors.green;
      case '軽傷':
        return Colors.orange;
      case '重傷':
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  List<Marker> _buildFriendMarkers([
    List<Map<String, dynamic>>? sourceFriends,
  ]) {
    return (sourceFriends ?? _savedFriends)
        .where(
          (friend) => friend['latitude'] is num && friend['longitude'] is num,
        )
        .map((friend) {
          final lat = (friend['latitude'] as num).toDouble();
          final lng = (friend['longitude'] as num).toDouble();
          final name = friend['displayName']?.toString() ?? '名前なし';
          final accuracy = friend['accuracy'];
          final locationCapturedAt = friend['locationCapturedAt'];
          final locationAgeStatus = _connectionStatus(locationCapturedAt);
          final isLocationStale =
              locationAgeStatus == 'offlineCandidate' ||
              locationAgeStatus == 'unknown';

          final accuracyText = accuracy is num
              ? '±${accuracy.toStringAsFixed(0)} m'
              : '不明';

          return Marker(
            point: LatLng(lat, lng),
            width: 52,
            height: 52,
            child: IconButton(
              tooltip: '$name さんの最終確認位置',

              icon: Icon(
                friend['rescueRequest'] == true
                    ? Icons.warning_amber_rounded
                    : isLocationStale
                    ? Icons.person_pin_circle_outlined
                    : Icons.person_pin_circle,
                color: _friendColor(friend),
                size: 40,
              ),

              onPressed: () {
                final data = friend;

                final name = data['displayName']?.toString() ?? '名前未登録';
                final status = data['safetyStatus']?.toString() ?? '未確認';
                final rescue = data['rescueRequest'] == true;
                final battery = data['batteryLevel'];

                final batteryText = battery is num
                    ? '${battery.toInt()}%'
                    : '不明';

                final updatedAt = _formatDateTime(data['updatedAt']);

                showDialog<void>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    title: Text(name),
                    content: Text(
                      '安否状態：$status\n'
                      '救助要請：${rescue ? 'あり' : 'なし'}\n'
                      '電池残量：$batteryText\n'
                      '情報の最終更新：$updatedAt\n\n'
                      '【友達の最終確認位置】\n'
                      '緯度：$lat\n'
                      '経度：$lng\n'
                      '位置精度：$accuracyText\n\n'
                      '※保存された位置情報です。現在もこの場所にいるとは限りません。',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('閉じる'),
                      ),
                    ],
                  ),
                );
              },
            ),
          );
        })
        .toList();
  }

  String _relayLocationAgeWarning(Map<String, dynamic> item) {
    final rawTime = item['locationCapturedAt'];

    DateTime? capturedAt;

    if (rawTime is Timestamp) {
      capturedAt = rawTime.toDate();
    } else if (rawTime is String) {
      capturedAt = DateTime.tryParse(rawTime);
    }

    if (capturedAt == null) {
      return '位置情報の取得時刻が不明です';
    }

    final elapsed = DateTime.now().difference(capturedAt);

    if (elapsed.isNegative) {
      return '位置情報の時刻に不整合があります';
    }

    if (elapsed.inHours >= 3) {
      return '注意：3時間以上前の最終確認位置です';
    }

    if (elapsed.inMinutes >= 30) {
      return '注意：30分以上前の最終確認位置です';
    }

    return '30分以内に作成された位置情報です';
  }

  List<Marker> _buildRelayMarkers([List<Map<String, dynamic>>? sourceRelays]) {
    final markers = <Marker>[];

    for (final item in (sourceRelays ?? widget.relayItems)) {
      final lat = item['latitude'];
      final lng = item['longitude'];

      if (lat is! num || lng is! num) continue;
      if (lat.toDouble() < -90 || lat.toDouble() > 90) continue;
      if (lng.toDouble() < -180 || lng.toDouble() > 180) continue;

      final name = item['displayName']?.toString() ?? '名前なし';
      final status = item['confirmedSafetyStatus']?.toString() ?? '未登録';
      final rescue = item['rescueRequest'] == true;

      final color = rescue || status == '重傷'
          ? Colors.red
          : status == '軽傷'
          ? Colors.orange
          : status == '無事'
          ? Colors.green
          : Colors.grey;

      markers.add(
        Marker(
          point: LatLng(lat.toDouble(), lng.toDouble()),
          width: 50,
          height: 50,
          child: IconButton(
            tooltip: '$name さんの最終確認位置',

            icon: Icon(Icons.qr_code_2, color: color, size: 40),

            onPressed: () {
              showDialog(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: Text('$name さんの最終確認情報'),
                  content: Text(
                    '現在の状態：未確認\n'
                    '最後に確認された安否：$status\n'
                    '救助要請：${rescue ? 'あり' : 'なし'}\n'
                    '位置精度：${item['accuracy'] ?? '不明'}m\n'
                    '本人情報の作成時刻：${_formatDateTime(item['sourceUpdatedAt'])}\n'
                    'QR読み取り時刻：${_formatDateTime(item['readAt'])}\n'
                    '位置情報の鮮度：${_relayLocationAgeWarning(item)}\n\n'
                    '※ この位置・安否は現在の状態を保証しません。',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('閉じる'),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );
    }

    return markers;
  }

  String? _personIdFromLocation(Map<String, dynamic> data, String type) {
    final rawId = type == 'QR中継' ? data['sourceUserId'] : data['userId'];

    final id = rawId?.toString().trim();

    if (id == null || id.isEmpty) {
      return null;
    }

    return id;
  }

  void _showMyLocationDetails() {
    final point = _currentLocation;
    if (point == null) return;

    final data = _myUserData;
    final name = data?['displayName']?.toString() ?? '名前未登録';
    final status = data?['safetyStatus']?.toString() ?? '未確認';
    final rescue = data?['rescueRequest'] == true;
    final battery = data?['batteryLevel'];
    final batteryText = battery is num ? '${battery.toInt()}%' : '不明';
    final updatedAt = _formatDateTime(data?['updatedAt']);

    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(name),
        content: Text(
          '安否状態：$status\n'
          '救助要請：${rescue ? 'あり' : 'なし'}\n'
          '電池残量：$batteryText\n'
          '情報の最終更新：$updatedAt\n\n'
          '【現在のGPS位置】\n'
          '緯度：${point.latitude}\n'
          '経度：${point.longitude}\n'
          '位置精度：${_locationAccuracy?.toStringAsFixed(0) ?? '不明'} m',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  List<Map<String, dynamic>> _allLocationCandidates() {
    final candidates = <Map<String, dynamic>>[];

    for (final friend in _savedFriends) {
      candidates.add({...friend, '_locationType': '友達'});
    }

    for (final user in widget.emergencyUsers) {
      candidates.add({...user, '_locationType': '救助要請'});
    }

    if (widget.focusUser != null) {
      candidates.add({...widget.focusUser!, '_locationType': '選択中'});
    }

    for (final relay in widget.relayItems) {
      candidates.add({...relay, '_locationType': 'QR中継'});
    }

    return candidates.where((item) {
      final lat = item['latitude'];
      final lng = item['longitude'];

      return lat is num &&
          lng is num &&
          lat >= -90 &&
          lat <= 90 &&
          lng >= -180 &&
          lng <= 180;
    }).toList();
  }

  List<Map<String, dynamic>> _selectLatestPersonLocations(
    List<Map<String, dynamic>> locations,
  ) {
    final selected = <String, Map<String, dynamic>>{};
    final unidentified = <Map<String, dynamic>>[];

    for (final location in locations) {
      final type = location['_locationType']?.toString() ?? '';
      final personId = _personIdFromLocation(location, type);

      if (personId == null) {
        unidentified.add(location);
        continue;
      }

      final existing = selected[personId];

      if (existing == null) {
        selected[personId] = {
          ...location,
          '_locationHistory': <Map<String, dynamic>>[],
          '_locationConflict': false,
        };
        continue;
      }

      final nextTime = _parseLocationTime(location['locationCapturedAt']);
      final oldTime = _parseLocationTime(existing['locationCapturedAt']);

      final history = <Map<String, dynamic>>[
        ...((existing['_locationHistory'] as List).map(
          (item) => Map<String, dynamic>.from(item as Map),
        )),
      ];

      if (nextTime != null && (oldTime == null || nextTime.isAfter(oldTime))) {
        history.add({...existing}..remove('_locationHistory'));

        selected[personId] = {
          ...location,
          '_locationHistory': history,
          '_locationConflict': existing['_locationConflict'] == true,
        };
      } else {
        history.add(Map<String, dynamic>.from(location));

        final sameTime =
            nextTime != null &&
            oldTime != null &&
            nextTime.isAtSameMomentAs(oldTime);

        final differentLocation =
            existing['latitude'] != location['latitude'] ||
            existing['longitude'] != location['longitude'];

        selected[personId] = {
          ...existing,
          '_locationHistory': history,
          '_locationConflict':
              existing['_locationConflict'] == true ||
              (sameTime && differentLocation),
        };
      }
    }

    return [...selected.values, ...unidentified];
  }

  List<Marker> _buildGroupedMarkers() {
    final candidates = _allLocationCandidates();
    final selectedLocations = _selectLatestPersonLocations(candidates);
    final selectedFriends = selectedLocations
        .where(
          (item) =>
              item['_locationType'] == '友達' ||
              item['_locationType'] == '救助要請' ||
              item['_locationType'] == '選択中',
        )
        .toList();

    final selectedRelays = selectedLocations
        .where((item) => item['_locationType'] == 'QR中継')
        .toList();

    final friends = _buildFriendMarkers(selectedFriends);
    final relays = _buildRelayMarkers(selectedRelays);

    final entries =
        <
          ({
            Marker marker,
            String name,
            String type,
            Map<String, dynamic>? data,
          })
        >[];

    final validFriends = selectedFriends.where((friend) {
      return friend['latitude'] is num && friend['longitude'] is num;
    }).toList();

    for (var i = 0; i < friends.length; i++) {
      final friend = validFriends[i];

      entries.add((
        marker: friends[i],
        name: friend['displayName']?.toString() ?? '友達',
        type: friend['_locationType']?.toString() ?? '友達',
        data: friend,
      ));
    }

    final validRelayItems = selectedRelays.where((item) {
      final lat = item['latitude'];
      final lng = item['longitude'];

      return lat is num &&
          lng is num &&
          lat >= -90 &&
          lat <= 90 &&
          lng >= -180 &&
          lng <= 180;
    }).toList();

    for (var i = 0; i < relays.length; i++) {
      final item = validRelayItems[i];

      entries.add((
        marker: relays[i],
        name: item['displayName']?.toString() ?? '名前なし',
        type: 'QR中継',
        data: item,
      ));
    }

    if (_currentLocation case final point?) {
      final ownData = Map<String, dynamic>.from(_myUserData ?? {})
        ..addAll({
          'userId': widget.myUserId,
          'latitude': point.latitude,
          'longitude': point.longitude,
          'accuracy': _locationAccuracy,
          'locationCapturedAt': _currentLocationCapturedAt?.toIso8601String(),
        });
      final ownName = ownData['displayName']?.toString() ?? '自分';

      entries.add((
        marker: Marker(
          point: point,
          width: 48,
          height: 48,
          child: IconButton(
            tooltip: '自分の現在地',
            icon: Icon(Icons.my_location, color: Colors.blue, size: 38),
            onPressed: _showMyLocationDetails,
          ),
        ),
        name: ownName,
        type: '自分',
        data: ownData,
      ));
    }

    final groups =
        <
          List<
            ({
              Marker marker,
              String name,
              String type,
              Map<String, dynamic>? data,
            })
          >
        >[];

    const distance = Distance();

    for (final entry in entries) {
      List<
        ({Marker marker, String name, String type, Map<String, dynamic>? data})
      >?
      target;

      for (final group in groups) {
        final meters = distance.as(
          LengthUnit.Meter,
          entry.marker.point,
          group.first.marker.point,
        );

        if (meters <= 20) {
          target = group;
          break;
        }
      }

      if (target == null) {
        groups.add([entry]);
      } else {
        target.add(entry);
      }
    }

    return groups.map((group) {
      final personKeys = <String>{};

      for (var i = 0; i < group.length; i++) {
        final entry = group[i];
        final data = entry.data;
        final String? userId;

        if (entry.type == 'QR中継') {
          userId = data?['sourceUserId']?.toString();
        } else {
          userId = data?['userId']?.toString();
        }

        if (userId != null && userId.isNotEmpty) {
          personKeys.add('user:$userId');
        } else {
          personKeys.add('unknown:$i');
        }
      }

      final personCount = personKeys.length;
      final hasSelfAndQr =
          group.any((entry) => entry.type == '自分') &&
          group.any((entry) => entry.type == 'QR中継');

      if (group.length == 1) {
        return group.first.marker;
      }

      return Marker(
        point: group.first.marker.point,
        width: hasSelfAndQr ? 176 : 58,
        height: 54,
        child: GestureDetector(
          onTap: () {
            showDialog<void>(
              context: context,
              builder: (dialogContext) {
                return AlertDialog(
                  title: Text('位置情報：${group.length}件（識別人数：$personCount人）'),

                  content: SizedBox(
                    width: 340,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight:
                            MediaQuery.sizeOf(dialogContext).height * 0.55,
                      ),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: group.length,
                        itemBuilder: (context, index) {
                          final entry = group[index];

                          final data = entry.data;
                          final status = entry.type == 'QR中継'
                              ? (data?['confirmedSafetyStatus']?.toString() ??
                                    '未登録')
                              : (data?['safetyStatus']?.toString() ?? '未確認');

                          final rescue = data?['rescueRequest'] == true;
                          final battery = data?['batteryLevel'];

                          final updatedAt = data?['locationCapturedAt'];
                          final formattedUpdatedAt = _formatDateTime(updatedAt);

                          final formattedReadAt = _formatDateTime(
                            data?['readAt'],
                          );

                          final connStatus = entry.type == 'QR中継'
                              ? 'unknown'
                              : _connectionStatus(data?['updatedAt']);

                          final connLabel = _connectionStatusLabel(connStatus);
                          final batteryText = battery is num
                              ? '${battery.toInt()}%'
                              : '不明';

                          final statusColor = rescue || status == '重傷'
                              ? Colors.red
                              : status == '軽傷'
                              ? Colors.orange
                              : status == '無事'
                              ? Colors.green
                              : Colors.grey;

                          return Card(
                            child: ListTile(
                              leading: Icon(
                                entry.type == 'QR中継'
                                    ? Icons.qr_code
                                    : rescue
                                    ? Icons.warning
                                    : Icons.person_pin_circle,
                                color: entry.type == 'QR中継'
                                    ? Colors.orange
                                    : statusColor,
                                size: 32,
                              ),
                              title: Text(
                                entry.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),

                              subtitle: Text(
                                entry.type != 'QR中継'
                                    ? '安否：$status\n'
                                          '救助要請：${rescue ? 'あり' : 'なし'}\n'
                                          '電池残量：$batteryText\n'
                                          '最終更新：$formattedUpdatedAt\n'
                                          '通信状態:$connLabel'
                                    : '現在の状態：未確認\n'
                                          '最後に確認された安否：$status\n'
                                          '救助要請：${rescue ? 'あり' : 'なし'}\n'
                                          '電池残量：$batteryText\n'
                                          '本人情報の作成：$formattedUpdatedAt\n'
                                          'QR読み取り：$formattedReadAt',
                              ),

                              isThreeLine: true,
                              trailing: const Icon(Icons.chevron_right),

                              onTap: () {
                                showDialog<void>(
                                  context: dialogContext,
                                  builder: (detailContext) => AlertDialog(
                                    title: Text(entry.name),
                                    content: SingleChildScrollView(
                                      child: Text(
                                        '情報の種類：${entry.type}\n'
                                        '安否状態：$status\n'
                                        '救助要請：${rescue ? 'あり' : 'なし'}\n'
                                        '電池残量：$batteryText\n'
                                        '情報の最終更新：$formattedUpdatedAt\n'
                                        '緯度：${entry.marker.point.latitude}\n'
                                        '経度：${entry.marker.point.longitude}',
                                      ),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(detailContext),
                                        child: const Text('閉じる'),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('閉じる'),
                    ),
                  ],
                );
              },
            );
          },
          child: hasSelfAndQr
              ? Container(
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: Colors.indigo, width: 2),
                    boxShadow: const [
                      BoxShadow(color: Colors.black26, blurRadius: 3),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.my_location, color: Colors.blue, size: 20),
                      SizedBox(width: 3),
                      Text('自分', style: TextStyle(fontSize: 11)),
                      SizedBox(width: 6),
                      Icon(Icons.qr_code_2, color: Colors.deepOrange, size: 20),
                      SizedBox(width: 3),
                      Text('QR', style: TextStyle(fontSize: 11)),
                      SizedBox(width: 7),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.indigo,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          '$personCount人',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              : Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.indigo,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '$personCount人',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 17,
                      ),
                    ),
                  ),
                ),
        ),
      );
    }).toList();
  }

  Future<void> _getCurrentLocation() async {
    setState(() => _gettingLocation = true);
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) throw Exception('位置情報サービスがOFFです');
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw Exception('位置情報の使用が許可されていません');
      }
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      if (!mounted) return;
      final point = LatLng(position.latitude, position.longitude);
      setState(() {
        _currentLocation = point;
        _locationAccuracy = position.accuracy;
        _currentLocationCapturedAt = position.timestamp;
      });
      _mapController.move(point, 15);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '現在地を取得しました（精度 ±${position.accuracy.toStringAsFixed(0)}m）',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('位置情報を取得できません: $e')));
    } finally {
      if (mounted) setState(() => _gettingLocation = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('沖縄本島オフラインマップ'),
        actions: [
          IconButton(
            tooltip: _loadingFriends ? '友達を取得中' : '友達の位置を再取得',
            onPressed: _loadingFriends ? null : _refreshFriends,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _gettingLocation ? null : _getCurrentLocation,
        icon: _gettingLocation
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.my_location),
        label: Text(_gettingLocation ? '取得中...' : '現在地を取得'),
      ),
      body: FutureBuilder<vt.PmTilesVectorTileProvider>(
        future: _mapFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Text(
                '地図の読み込みエラー:\n${snapshot.error}',
                textAlign: TextAlign.center,
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: widget.initialCenter ?? const LatLng(26.45, 127.90),
              initialZoom: widget.initialCenter == null ? 9 : 15,
              minZoom: 7,
              maxZoom: 18,
            ),
            children: [
              vt.VectorTileLayer(
                theme: vt.ThemeReader(
                  logger: const vt.Logger.console(),
                ).read(jsonDecode(_styleJson) as Map<String, Object?>),
                tileProviders: vt.TileProviders({'okinawa': snapshot.data!}),
                logger: const vt.Logger.console(),
              ),
              if (_currentLocation != null)
                CircleLayer(
                  circles: <CircleMarker>[
                    CircleMarker(
                      point: _currentLocation!,
                      radius: _locationAccuracy ?? 0,
                      useRadiusInMeter: true,
                      color: Colors.blue.withValues(alpha: 0.15),
                      borderColor: Colors.blue,
                      borderStrokeWidth: 2,
                    ),
                  ],
                ),
              // この位置へ移動する
              MarkerLayer(markers: _buildGroupedMarkers()),

              Positioned(
                left: 12,
                bottom: 42,
                child: Card(
                  elevation: 3,
                  color: Colors.white,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: DefaultTextStyle(
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.black87,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Text(
                            'マーカーの見方',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          SizedBox(height: 6),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.circle, color: Colors.green, size: 12),
                              SizedBox(width: 6),
                              Text('緑：無事'),
                            ],
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.circle,
                                color: Colors.orange,
                                size: 12,
                              ),
                              SizedBox(width: 6),
                              Text('橙：軽傷'),
                            ],
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.circle, color: Colors.red, size: 12),
                              SizedBox(width: 6),
                              Text('赤：重傷・救助要請'),
                            ],
                          ),
                          SizedBox(height: 5),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.my_location,
                                color: Colors.blue,
                                size: 15,
                              ),
                              SizedBox(width: 6),
                              Text('青い現在地：自分が今いる場所'),
                            ],
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.qr_code_2,
                                color: Colors.deepOrange,
                                size: 15,
                              ),
                              SizedBox(width: 6),
                              Text('QR：読み取った位置情報'),
                            ],
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.person_pin_circle_outlined,
                                color: Colors.grey,
                                size: 17,
                              ),
                              SizedBox(width: 6),
                              Text('輪郭型：30分以上更新なし'),
                            ],
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.filter_2,
                                color: Colors.indigo,
                                size: 15,
                              ),
                              SizedBox(width: 6),
                              Text('数字：その場所の人数（タップで詳細）'),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              const SimpleAttributionWidget(
                source: Text('© OpenStreetMap contributors / BBBike'),
              ),
            ],
          );
        },
      ),
    );
  }
}
