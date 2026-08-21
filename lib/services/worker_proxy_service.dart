import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'user_data_service.dart';

/// Cloudflare Worker 代理加速。
///
/// 用途：把视频源 API 与 m3u8/视频流经 Cloudflare 全球 CDN 转发，绕开线路慢或
/// 被墙的源站。行为与网页端一致：
///
/// - 自动转发所有 API 参数（`ac=list`、`ac=detail` 等）；
/// - 为每个源生成唯一路径，提升兼容性；
/// - 播放 m3u8/视频时自动经 Worker 转发，加速播放流；
/// - Worker 不可用时自动降级为直连，不影响正常播放；
/// - Emby 源需要自定义鉴权头，始终直连。
class WorkerProxyService {
  static const _probeTimeout = Duration(seconds: 6);

  /// 探测结果缓存，避免每次换集都去 ping 一次 Worker。
  static final Map<String, bool> _healthCache = {};

  static Future<String> getProxyBase() => UserDataService.getWorkerProxyUrl();

  static Future<bool> get isEnabled async =>
      (await getProxyBase()).trim().isNotEmpty;

  /// Emby 源依赖自定义鉴权头，代理会破坏鉴权，因此永远直连。
  static bool shouldBypass(String url) {
    final lower = url.toLowerCase();
    if (lower.isEmpty) return true;
    if (!lower.startsWith('http')) return true;
    return lower.contains('/emby/') ||
        lower.contains('embyserver') ||
        lower.contains('x-emby-token') ||
        lower.contains('api_key=');
  }

  /// 为每个源生成唯一路径：同一个源站始终走同一条 Worker 子路径，
  /// 便于 Worker 侧做缓存与兼容处理。
  static String sourcePath(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.isEmpty) return 'src';
    var hash = 0;
    for (final unit in host.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return 's${hash.toRadixString(36)}';
  }

  /// 把一个直连地址改写为经 Worker 转发的地址。原始 query 会完整保留。
  static Future<String> rewrite(String url) async {
    final base = (await getProxyBase()).trim();
    if (base.isEmpty || shouldBypass(url)) return url;
    if (url.startsWith(base)) return url;
    if (!await _isHealthy(base)) return url;
    return _buildProxyUrl(base, url);
  }

  @visibleForTesting
  static String buildProxyUrl(String base, String url) =>
      _buildProxyUrl(base, url);

  static String _buildProxyUrl(String base, String url) {
    final cleanBase = base.replaceAll(RegExp(r'/+$'), '');
    return '$cleanBase/${sourcePath(url)}?url=${Uri.encodeComponent(url)}';
  }

  /// Worker 挂了就降级直连，不让用户卡在加载中。
  static Future<bool> _isHealthy(String base) async {
    final cached = _healthCache[base];
    if (cached != null) return cached;
    var healthy = false;
    try {
      final response = await http.head(Uri.parse(base)).timeout(_probeTimeout);
      healthy = response.statusCode < 500;
    } catch (error) {
      debugPrint('WorkerProxyService: probe failed ($base): $error');
      healthy = false;
    }
    _healthCache[base] = healthy;
    return healthy;
  }

  /// 用户改了地址后清掉探测缓存。
  static void resetHealthCache() => _healthCache.clear();
}
