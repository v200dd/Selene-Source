import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'worker_proxy_service.dart';

enum DownloadStatus { queued, running, completed, failed, paused }

/// 一条本地下载记录。
class DownloadTask {
  DownloadTask({
    required this.id,
    required this.title,
    required this.url,
    required this.fileName,
    this.poster = '',
    this.episodeLabel = '',
    this.status = DownloadStatus.queued,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.error,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  final String title;
  final String url;
  final String fileName;
  final String poster;
  final String episodeLabel;
  final DateTime createdAt;

  DownloadStatus status;
  int receivedBytes;
  int totalBytes;
  String? error;

  double get progress =>
      totalBytes <= 0 ? 0 : (receivedBytes / totalBytes).clamp(0.0, 1.0);

  bool get isFinished => status == DownloadStatus.completed;

  String get displayTitle =>
      episodeLabel.isEmpty ? title : '$title · $episodeLabel';

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'url': url,
        'fileName': fileName,
        'poster': poster,
        'episodeLabel': episodeLabel,
        'status': status.name,
        'receivedBytes': receivedBytes,
        'totalBytes': totalBytes,
        'error': error,
        'createdAt': createdAt.toIso8601String(),
      };

  static DownloadTask fromJson(Map<String, dynamic> json) => DownloadTask(
        id: (json['id'] ?? '').toString(),
        title: (json['title'] ?? '').toString(),
        url: (json['url'] ?? '').toString(),
        fileName: (json['fileName'] ?? '').toString(),
        poster: (json['poster'] ?? '').toString(),
        episodeLabel: (json['episodeLabel'] ?? '').toString(),
        status: DownloadStatus.values.firstWhere(
          (item) => item.name == json['status'],
          orElse: () => DownloadStatus.failed,
        ),
        receivedBytes: (json['receivedBytes'] as num?)?.toInt() ?? 0,
        totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
        error: json['error']?.toString(),
        createdAt: DateTime.tryParse((json['createdAt'] ?? '').toString()) ??
            DateTime.now(),
      );
}

/// 本地下载管理。
///
/// 只处理单文件直链（mp4/mkv 等）。HLS(m3u8) 是分片流，需要合并才能离线播放，
/// 这里不做半成品下载，而是明确拒绝并提示原因。
class DownloadService {
  DownloadService._();

  static final DownloadService instance = DownloadService._();

  static const _indexFileName = 'downloads.json';

  final Dio _dio = Dio();
  final Map<String, CancelToken> _cancelTokens = {};
  final ValueNotifier<List<DownloadTask>> tasks =
      ValueNotifier<List<DownloadTask>>(const []);

  Directory? _dir;
  bool _loaded = false;

  Future<Directory> _ensureDir() async {
    final existing = _dir;
    if (existing != null) return existing;
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/downloads');
    if (!await dir.exists()) await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final dir = await _ensureDir();
      final index = File('${dir.path}/$_indexFileName');
      if (!await index.exists()) return;
      final decoded = jsonDecode(await index.readAsString());
      if (decoded is! List) return;
      final restored = decoded
          .whereType<Map>()
          .map((item) => DownloadTask.fromJson(Map<String, dynamic>.from(item)))
          .toList();
      // 上次退出时正在下载的任务恢复成暂停，让用户自己决定是否重下。
      for (final task in restored) {
        if (task.status == DownloadStatus.running ||
            task.status == DownloadStatus.queued) {
          task.status = DownloadStatus.paused;
        }
      }
      tasks.value = restored;
    } catch (error) {
      debugPrint('DownloadService: load failed: $error');
    }
  }

  Future<void> _persist() async {
    try {
      final dir = await _ensureDir();
      final index = File('${dir.path}/$_indexFileName');
      await index.writeAsString(
          jsonEncode(tasks.value.map((task) => task.toJson()).toList()));
    } catch (error) {
      debugPrint('DownloadService: persist failed: $error');
    }
  }

  void _notify() {
    tasks.value = List<DownloadTask>.from(tasks.value);
  }

  /// m3u8 是分片流，直接下载只会拿到一个播放列表文本。
  static bool isStreamPlaylist(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    return path.endsWith('.m3u8') || path.endsWith('.m3u');
  }

  Future<File> fileForTask(DownloadTask task) async {
    final dir = await _ensureDir();
    return File('${dir.path}/${task.fileName}');
  }

  /// 加入下载队列并立即开始。返回失败原因，成功返回 null。
  Future<String?> enqueue({
    required String title,
    required String url,
    String poster = '',
    String episodeLabel = '',
  }) async {
    await load();
    if (url.trim().isEmpty) return '播放地址为空，无法下载';
    if (isStreamPlaylist(url)) {
      return '这一集是 m3u8 分片流，暂不支持离线下载';
    }
    if (tasks.value.any((task) => task.url == url && !task.isFinished)) {
      return '该视频已在下载列表中';
    }

    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final extension = _extensionOf(url);
    final task = DownloadTask(
      id: id,
      title: title,
      url: url,
      poster: poster,
      episodeLabel: episodeLabel,
      fileName: '$id$extension',
    );
    tasks.value = [task, ...tasks.value];
    await _persist();
    unawaited(_run(task));
    return null;
  }

  Future<void> retry(DownloadTask task) async {
    if (task.status == DownloadStatus.running) return;
    task.status = DownloadStatus.queued;
    task.error = null;
    _notify();
    await _run(task);
  }

  Future<void> cancel(DownloadTask task) async {
    _cancelTokens.remove(task.id)?.cancel('cancelled by user');
    task.status = DownloadStatus.paused;
    _notify();
    await _persist();
  }

  /// 删除记录并连带删除已下载的文件。
  Future<void> remove(DownloadTask task) async {
    _cancelTokens.remove(task.id)?.cancel('removed by user');
    try {
      final file = await fileForTask(task);
      if (await file.exists()) await file.delete();
    } catch (error) {
      debugPrint('DownloadService: delete failed: $error');
    }
    tasks.value =
        tasks.value.where((item) => item.id != task.id).toList(growable: false);
    await _persist();
  }

  Future<void> _run(DownloadTask task) async {
    final token = CancelToken();
    _cancelTokens[task.id] = token;
    task.status = DownloadStatus.running;
    task.error = null;
    _notify();

    try {
      final file = await fileForTask(task);
      // 走 Worker 加速（未配置或探测失败会原样返回直连地址）。
      final url = await WorkerProxyService.rewrite(task.url);
      await _dio.download(
        url,
        file.path,
        cancelToken: token,
        onReceiveProgress: (received, total) {
          task.receivedBytes = received;
          if (total > 0) task.totalBytes = total;
          _notify();
        },
      );
      task.status = DownloadStatus.completed;
      if (task.totalBytes <= 0) task.totalBytes = task.receivedBytes;
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) {
        task.status = DownloadStatus.paused;
      } else {
        task.status = DownloadStatus.failed;
        task.error = error.message ?? '下载失败';
      }
    } catch (error) {
      task.status = DownloadStatus.failed;
      task.error = error.toString();
    } finally {
      _cancelTokens.remove(task.id);
      _notify();
      await _persist();
    }
  }

  static String _extensionOf(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    final dot = path.lastIndexOf('.');
    if (dot < 0 || path.length - dot > 6) return '.mp4';
    return path.substring(dot);
  }

  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 10 || unit == 0 ? 0 : 1)} ${units[unit]}';
  }
}
