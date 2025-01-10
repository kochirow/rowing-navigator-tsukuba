import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
/* spellchecker: disable */
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';

// # アプリ概要
// 時刻とその時の位置情報を記録して一覧で確認できるアプリ
// # 画面構成
// - 記録一覧画面
//   - 記録をリスト形式で表示
//   - リストの各要素をタップすると、その記録の詳細画面に遷移
//   - 画面下部：記録開始ボタン
// - 記録詳細画面
//   - 記録の詳細情報をテキスト表示
//   - スクロールして全てを表示できるようにする
//   - 画面下部
//     - 記録削除ボタン
//     - 共有ボタン
// # 記録データ
// - 時刻
// - 緯度経度
// - 速度
// - 方位
// - 安全度
// # 非機能要件
// - データは端末内に保存
// - データはCSV形式で保存
// - データはCSV形式で共有

class RecordListScreen extends HookConsumerWidget {
  const RecordListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final records = useState<List<String>>([]);

    Future<void> loadRecords() async {
      final prefs = await SharedPreferences.getInstance();
      records.value = prefs.getStringList('records') ?? [];
    }

    useEffect(() {
      loadRecords();
      return null;
    }, []);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('記録一覧'),
      ),
      body: records.value.isEmpty
          ? const Center(child: Text('記録がありません'))
          : ListView.builder(
              itemCount: records.value.length,
              itemBuilder: (context, index) {
                final reverseIndex = records.value.length - 1 - index;
                final recordLines = records.value[reverseIndex].split('\n');
                final startTime = recordLines.first.split(',').first.trim();
                final endTime = recordLines.last.split(',')[1].trim();
                return ListTile(
                  title: Text('$startTime - $endTime'),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => RecordDetailScreen(
                            recordId: reverseIndex,
                            recordData: records.value[reverseIndex]),
                      ),
                    ).then((_) => loadRecords());
                  },
                );
              },
            ),
    );
  }
}

class RecordDetailScreen extends HookConsumerWidget {
  final int recordId;
  final String recordData;

  const RecordDetailScreen(
      {super.key, required this.recordId, required this.recordData});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('記録詳細'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Center(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('記録ID: $recordId'),
              const SizedBox(height: 16.0),
              const Text('記録データ:'),
              const SizedBox(height: 8.0),
              Text(recordData.replaceAll('\n', '\n')),
            ],
          ),
        ),
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ElevatedButton(
              onPressed: () async {
                final prefs = await SharedPreferences.getInstance();
                final records = prefs.getStringList('records') ?? [];
                records.removeAt(recordId);
                await prefs.setStringList('records', records);
                Navigator.pop(context);
              },
              child: const Text('記録削除'),
            ),
            ElevatedButton(
              onPressed: () {
                // recordDataをテキストのリストからテキストに変換
                final recordDataText = recordData.replaceAll('\n', '\n');
                // CSV形式に変換
                final shareData =
                    'timestamp,lat,lng,heading,speed,safety_level,boat_type,seat_pos\n$recordDataText';
                // ヘッダーを追加
                Share.share(shareData, subject: '記録データ');
              },
              child: const Text('共有'),
            ),
          ],
        ),
      ),
    );
  }
}
