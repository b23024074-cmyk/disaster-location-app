import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'offline_map_page.dart';

class AdminDashboardPage extends StatefulWidget {
  const AdminDashboardPage({super.key});

  @override
  State<AdminDashboardPage> createState() => _AdminDashboardPageState();
}

class _AdminDashboardPageState extends State<AdminDashboardPage> {
  late Future<List<Map<String, dynamic>>> _usersFuture;
  String _filter = '全員';
  bool _lowBatteryOnly = false;

  @override
  void initState() {
    super.initState();
    _usersFuture = _loadUsers();
  }

  Future<List<Map<String, dynamic>>> _loadUsers() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('ログインが必要です。');

    final adminDoc = await FirebaseFirestore.instance
        .collection('admins')
        .doc(user.uid)
        .get(const GetOptions(source: Source.server));
    if (!adminDoc.exists) {
      throw _NotAdminException(
        uid: user.uid,
        detail: 'このUIDの管理者ドキュメントが見つかりません。',
      );
    }
    if (adminDoc.data()?['enabled'] != true) {
      throw _NotAdminException(
        uid: user.uid,
        detail: 'enabled がBoolean型の true ではありません。',
      );
    }

    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .limit(200)
        .get(const GetOptions(source: Source.server));

    return snapshot.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList()
      ..sort((a, b) {
        final rescueA = a['rescueRequest'] == true;
        final rescueB = b['rescueRequest'] == true;
        if (rescueA != rescueB) return rescueA ? -1 : 1;
        return (a['displayName']?.toString() ?? '').compareTo(
          b['displayName']?.toString() ?? '',
        );
      });
  }

  void _reload() {
    setState(() => _usersFuture = _loadUsers());
  }

  void _openUserOnMap(Map<String, dynamic> user) {
    final latitude = user['latitude'];
    final longitude = user['longitude'];
    final LatLng? location = latitude is num && longitude is num
        ? LatLng(latitude.toDouble(), longitude.toDouble())
        : null;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => OfflineMapPage(
          myUserId: '',
          friendIds: const [],
          relayItems: const [],
          emergencyUsers: const [],
          focusUser: user,
          initialCenter: location,
        ),
      ),
    );

    if (location == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('このユーザーの位置情報はありません。')));
    }
  }

  DateTime? _capturedAt(dynamic value) {
    if (value is Timestamp) return value.toDate();
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  String _ageLabel(dynamic raw) {
    final captured = _capturedAt(raw);
    if (captured == null) return '位置時刻不明';
    final age = DateTime.now().difference(captured.toLocal());
    if (age.isNegative) return '時刻要確認';
    if (age.inMinutes < 1) return '1分以内';
    if (age.inHours < 1) return '${age.inMinutes}分前';
    if (age.inDays < 1) return '${age.inHours}時間前';
    return '${age.inDays}日前';
  }

  bool _matches(Map<String, dynamic> user) {
    final matchesStatus = switch (_filter) {
      '救助要請' => user['rescueRequest'] == true || user['safetyStatus'] == '重傷',
      '未確認' =>
        user['safetyStatus'] != '無事' &&
            user['safetyStatus'] != '軽傷' &&
            user['safetyStatus'] != '重傷',
      _ => true,
    };
    if (!matchesStatus) return false;

    if (_lowBatteryOnly) {
      final battery = user['batteryLevel'];
      if (battery is! num || battery > 20) return false;
    }
    return true;
  }

  Color _statusColor(Map<String, dynamic> user) {
    if (user['rescueRequest'] == true || user['safetyStatus'] == '重傷') {
      return Colors.red;
    }
    if (user['safetyStatus'] == '軽傷') return Colors.orange;
    if (user['safetyStatus'] == '無事') return Colors.green;
    return Colors.blueGrey;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('管理者画面'),
        actions: [
          IconButton(onPressed: _reload, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _usersFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            final error = snapshot.error;
            final notAdmin = error is _NotAdminException;
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  notAdmin
                      ? 'このアカウントには管理者権限がありません。\n\n'
                            '${error.detail}\n'
                            'アプリのFirebase UID:\n${error.uid}\n\n'
                            'Firestoreの admins ドキュメントIDと照合してください。'
                      : '情報を取得できませんでした。通信状態とFirestoreルールを確認してください。\n$error',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          final allUsers = snapshot.data ?? [];
          final users = allUsers.where(_matches).toList();
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 8,
                  children: [
                    ...['全員', '救助要請', '未確認'].map((filter) {
                      return ChoiceChip(
                        label: Text(filter),
                        selected: _filter == filter,
                        onSelected: (_) => setState(() => _filter = filter),
                      );
                    }),
                    FilterChip(
                      avatar: const Icon(
                        Icons.battery_alert,
                        color: Colors.orange,
                        size: 18,
                      ),
                      label: const Text('電池20%以下'),
                      selected: _lowBatteryOnly,
                      onSelected: (selected) =>
                          setState(() => _lowBatteryOnly = selected),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '表示 ${users.length}人 / 取得 ${allUsers.length}人（最大200人）',
                  ),
                ),
              ),
              Expanded(
                child: users.isEmpty
                    ? const Center(child: Text('表示するユーザーはいません。'))
                    : ListView.builder(
                        itemCount: users.length,
                        itemBuilder: (context, index) {
                          final data = users[index];
                          final name =
                              data['displayName']?.toString() ?? '名前なし';
                          final status =
                              data['safetyStatus']?.toString() ?? '未確認';
                          final battery = data['batteryLevel'];
                          final lat = data['latitude'];
                          final lng = data['longitude'];
                          final location = lat is num && lng is num
                              ? '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}'
                              : '位置情報なし';
                          final rescue = data['rescueRequest'] == true;
                          return Card(
                            margin: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 5,
                            ),
                            child: ListTile(
                              leading: Icon(
                                rescue
                                    ? Icons.warning_rounded
                                    : Icons.person_pin_circle,
                                color: _statusColor(data),
                              ),
                              title: Text(name),
                              subtitle: Text(
                                '安否: $status${rescue ? ' / 救助要請あり' : ''}\n'
                                '位置: $location（${_ageLabel(data['locationCapturedAt'])}）\n'
                                '電池: ${battery is num ? '${battery.toInt()}%' : '不明'}',
                              ),
                              isThreeLine: true,
                              trailing: const Icon(Icons.map_outlined),
                              onTap: () => _openUserOnMap(data),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _NotAdminException implements Exception {
  final String uid;
  final String detail;

  const _NotAdminException({required this.uid, required this.detail});
}
