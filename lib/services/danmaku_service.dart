import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/danmaku_comment.dart';
import 'api_service.dart';

/// 弹幕来源与结果。
class DanmakuResult {
  const DanmakuResult({
    required this.comments,
    required this.source,
    this.error,
  });

  final List<DanmakuComment> comments;

  /// 人类可读的来源说明，例如「主站 · 腾讯/B站」。
  final String source;

  /// 失败原因（成功时为 null）。
  final String? error;

  bool get isEmpty => comments.isEmpty;
}

/// 一条可手动选择的弹幕匹配结果。
class DanmakuMatch {
  const DanmakuMatch({
    required this.episodeId,
    required this.animeTitle,
    required this.episodeTitle,
  });

  final int episodeId;
  final String animeTitle;
  final String episodeTitle;

  String get label =>
      episodeTitle.isEmpty ? animeTitle : '$animeTitle · $episodeTitle';
}

/// 弹幕服务。
///
/// **优先走用户自己站点的接口**，因为每个人的 LunaTV/MoonTV 后台都可以自定义
/// 弹幕 API（`DanmuApiConfig`），硬编码第三方地址对别人的站点无效：
///   1. `GET {站点}/api/danmu-external?title=&episode=&year=&douban_id=`
///      返回 `{danmu:[{text,time,color,mode}], platforms:[...], total}`
///   2. 手动匹配：`GET {站点}/api/danmu-external/search?keyword=` 拿到候选，
///      再用 `?episode_id=` 精确取弹幕
///   3. 站点接口不可用时，才回退到本地配置的 dandanplay 兼容地址
class DanmakuService {
  static const _providerKey = 'danmaku_provider_url';
  static const _cachePrefix = 'danmaku_cache_v3_';
  static const _timeout = Duration(seconds: 25);

  /// 兜底直连地址（仅当主站接口不可用时使用）。
  static const defaultProviderUrl = 'https://smonedanmu.vercel.app/smonetv';

  /// 最近一次加载使用的来源，播放器面板会展示。
  static String? lastSource;

  static Future<String> getProviderUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_providerKey) ?? defaultProviderUrl;
  }

  static Future<void> saveProviderUrl(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _providerKey, value.trim().replaceAll(RegExp(r'/+$'), ''));
  }

  static String _cacheKey(String title, int episodeIndex) =>
      '$_cachePrefix${base64Url.encode(utf8.encode('$title|$episodeIndex'))}';

  /// 加载当前视频的弹幕。
  static Future<DanmakuResult> loadForVideo({
    required String url,
    required String title,
    required int episodeIndex,
    String? doubanId,
    String? year,
    bool bypassCache = false,
  }) async {
    if (title.trim().isEmpty && (doubanId == null || doubanId.isEmpty)) {
      return const DanmakuResult(
          comments: [], source: '', error: '缺少标题，无法匹配弹幕');
    }
    final prefs = await SharedPreferences.getInstance();
    final key = _cacheKey(title, episodeIndex);
    if (!bypassCache) {
      final cached = _readCache(prefs.getString(key));
      if (cached != null && cached.comments.isNotEmpty) {
        lastSource = cached.source;
        return cached;
      }
    }

    // 1) 主站接口（用户自己搭建的站点，弹幕源由后台决定）
    final site = await _loadFromSite(
      title: title,
      episodeIndex: episodeIndex,
      doubanId: doubanId,
      year: year,
    );
    if (site.comments.isNotEmpty) {
      await _writeCache(prefs, key, site);
      lastSource = site.source;
      return site;
    }

    // 2) 兜底：本地配置的 dandanplay 兼容服务
    final provider = await getProviderUrl();
    final fallback = await _loadByMatch(
      provider: provider,
      title: title,
      episodeIndex: episodeIndex,
    );
    if (fallback.isNotEmpty) {
      final result = DanmakuResult(comments: fallback, source: '备用弹幕服务');
      await _writeCache(prefs, key, result);
      lastSource = result.source;
      return result;
    }

    lastSource = null;
    return DanmakuResult(
      comments: const [],
      source: '',
      error: site.error ?? '当前视频暂无匹配弹幕',
    );
  }

  /// 手动匹配：搜索候选剧集，交给用户挑选。
  static Future<List<DanmakuMatch>> searchMatches(String keyword) async {
    final response = await ApiService.get<dynamic>(
      '/api/danmu-external/search',
      queryParameters: {'keyword': _searchKeyword(keyword)},
    );
    if (!response.success || response.data is! Map) return const [];
    final animes = (response.data as Map)['animes'];
    if (animes is! List) return const [];
    final matches = <DanmakuMatch>[];
    for (final rawAnime in animes.whereType<Map>()) {
      final anime = Map<String, dynamic>.from(rawAnime);
      final animeTitle = (anime['animeTitle'] ?? '').toString();
      final episodes = anime['episodes'];
      if (episodes is! List) continue;
      for (final rawEpisode in episodes.whereType<Map>()) {
        final episode = Map<String, dynamic>.from(rawEpisode);
        final episodeId = (episode['episodeId'] as num?)?.toInt() ??
            int.tryParse((episode['episodeId'] ?? '').toString());
        if (episodeId == null || episodeId <= 0) continue;
        matches.add(DanmakuMatch(
          episodeId: episodeId,
          animeTitle: animeTitle,
          episodeTitle: (episode['episodeTitle'] ?? '').toString(),
        ));
      }
    }
    return matches;
  }

  /// 手动匹配后按 episodeId 精确取弹幕，并覆盖缓存。
  static Future<DanmakuResult> loadByEpisodeId({
    required int episodeId,
    required String title,
    required int episodeIndex,
  }) async {
    final response = await ApiService.get<dynamic>(
      '/api/danmu-external',
      queryParameters: {'episode_id': '$episodeId'},
    );
    if (!response.success || response.data is! Map) {
      return DanmakuResult(
        comments: const [],
        source: '',
        error: response.message ?? '手动匹配失败',
      );
    }
    final json = Map<String, dynamic>.from(response.data as Map);
    final comments = _parseSiteDanmu(json['danmu']);
    final result = DanmakuResult(
      comments: comments,
      source: comments.isEmpty ? '' : '主站 · 手动匹配',
    );
    if (comments.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await _writeCache(prefs, _cacheKey(title, episodeIndex), result);
      lastSource = result.source;
    }
    return result;
  }

  // ---------------------------------------------------------------- 主站接口

  static Future<DanmakuResult> _loadFromSite({
    required String title,
    required int episodeIndex,
    String? doubanId,
    String? year,
  }) async {
    try {
      final response = await ApiService.get<dynamic>(
        '/api/danmu-external',
        queryParameters: {
          if (title.trim().isNotEmpty) 'title': title.trim(),
          'episode': '${episodeIndex + 1}',
          if (year != null && year.isNotEmpty) 'year': year,
          if (doubanId != null && doubanId.isNotEmpty) 'douban_id': doubanId,
        },
      );
      if (!response.success || response.data is! Map) {
        return DanmakuResult(
          comments: const [],
          source: '',
          error: response.message,
        );
      }
      final json = Map<String, dynamic>.from(response.data as Map);
      final comments = _parseSiteDanmu(json['danmu']);
      return DanmakuResult(
        comments: comments,
        source: comments.isEmpty ? '' : _describePlatforms(json['platforms']),
        error: comments.isEmpty ? (json['error'] ?? '').toString() : null,
      );
    } catch (error) {
      debugPrint('DanmakuService: site request failed: $error');
      return DanmakuResult(comments: const [], source: '', error: '主站弹幕接口不可用');
    }
  }

  static List<DanmakuComment> _parseSiteDanmu(dynamic raw) {
    if (raw is! List) return const [];
    final result = raw
        .whereType<Map>()
        .map((item) => _fromSiteJson(Map<String, dynamic>.from(item)))
        .where((item) => item.text.trim().isNotEmpty)
        .toList();
    result.sort((a, b) => a.time.compareTo(b.time));
    return result;
  }

  /// 主站返回：`time` 是秒，`color` 是 `#RRGGBB`，`mode` 0=滚动 1=顶部 2=底部。
  static DanmakuComment _fromSiteJson(Map<String, dynamic> item) {
    final seconds = (item['time'] as num?)?.toDouble() ??
        double.tryParse((item['time'] ?? '').toString()) ??
        0;
    return DanmakuComment(
      time: Duration(milliseconds: (seconds * 1000).round()),
      text: (item['text'] ?? '').toString(),
      color: _parseHexColor(item['color']),
      mode: _siteModeToLocal(item['mode']),
    );
  }

  static int _parseHexColor(dynamic value) {
    final raw = (value ?? '').toString().trim();
    if (raw.isEmpty) return 0xFFFFFF;
    final hex = raw.startsWith('#') ? raw.substring(1) : raw;
    return int.tryParse(hex, radix: 16) ?? int.tryParse(raw) ?? 0xFFFFFF;
  }

  /// 站点语义（0 滚动 / 1 顶部 / 2 底部）→ 本地/B 站语义（1 滚动 / 5 顶部 / 4 底部）。
  static int _siteModeToLocal(dynamic value) {
    final mode =
        (value as num?)?.toInt() ?? int.tryParse((value ?? '').toString()) ?? 0;
    switch (mode) {
      case 1:
        return 5;
      case 2:
        return 4;
      default:
        return 1;
    }
  }

  static String _describePlatforms(dynamic platforms) {
    if (platforms is! List) return '主站弹幕';
    final names = platforms
        .whereType<Map>()
        .map((item) => (item['source'] ?? item['platform'] ?? '').toString())
        .where((item) => item.isNotEmpty)
        .toSet()
        .toList();
    if (names.isEmpty) return '主站弹幕';
    return '主站 · ${names.join('/')}';
  }

  // ------------------------------------------------------------------ 兜底源

  /// dandanplay 风格：搜索 -> 剧集 -> 弹幕
  static Future<List<DanmakuComment>> _loadByMatch({
    required String provider,
    required String title,
    required int episodeIndex,
  }) async {
    final keyword = _searchKeyword(title);
    if (keyword.isEmpty) return const [];
    try {
      final animes = await _searchAnimes(provider, keyword);
      if (animes.isEmpty) return const [];
      final ranked = _rankAnimes(animes, keyword);
      for (final anime in ranked.take(3)) {
        final animeId = (anime['animeId'] ?? anime['bangumiId'])?.toString();
        if (animeId == null || animeId.isEmpty) continue;
        final episodeId =
            await _resolveEpisodeId(provider, animeId, episodeIndex);
        if (episodeId == null) continue;
        final comments = await _fetchComments(provider, episodeId);
        if (comments.isNotEmpty) return comments;
      }
    } catch (error) {
      debugPrint('DanmakuService: fallback match failed: $error');
    }
    return const [];
  }

  static Future<List<Map<String, dynamic>>> _searchAnimes(
    String provider,
    String keyword,
  ) async {
    final uri = Uri.parse(
        '$provider/api/v2/search/anime?keyword=${Uri.encodeComponent(keyword)}');
    final body = await _getJson(uri);
    final animes = body is Map ? body['animes'] : null;
    if (animes is! List) return const [];
    return animes
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  static Future<String?> _resolveEpisodeId(
    String provider,
    String animeId,
    int episodeIndex,
  ) async {
    final body = await _getJson(Uri.parse('$provider/api/v2/bangumi/$animeId'));
    final bangumi = body is Map ? body['bangumi'] : null;
    final episodes = bangumi is Map ? bangumi['episodes'] : null;
    if (episodes is! List || episodes.isEmpty) return null;
    final list = episodes
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    final wanted = episodeIndex + 1;
    for (final episode in list) {
      final number =
          int.tryParse((episode['episodeNumber'] ?? '').toString().trim());
      if (number != null && number == wanted) {
        return episode['episodeId']?.toString();
      }
    }
    if (episodeIndex >= 0 && episodeIndex < list.length) {
      return list[episodeIndex]['episodeId']?.toString();
    }
    return list.first['episodeId']?.toString();
  }

  static Future<List<DanmakuComment>> _fetchComments(
    String provider,
    String episodeId,
  ) async {
    final response = await _get(Uri.parse(
        '$provider/api/v2/comment/$episodeId?withRelated=true&chConvert=0'));
    if (response == null) return const [];
    return _parseResponse(response);
  }

  static Future<String?> _get(Uri uri) async {
    try {
      final response = await http.get(uri, headers: const {
        'Accept': 'application/json, application/xml, text/xml',
      }).timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      return utf8.decode(response.bodyBytes, allowMalformed: true);
    } catch (error) {
      debugPrint('DanmakuService: request failed ($uri): $error');
      return null;
    }
  }

  static Future<dynamic> _getJson(Uri uri) async {
    final body = await _get(uri);
    if (body == null) return null;
    try {
      return jsonDecode(body);
    } catch (_) {
      return null;
    }
  }

  /// 去掉集数/年份等噪音，提升匹配率。
  static String _searchKeyword(String title) {
    var keyword = title.trim();
    keyword = keyword.replaceAll(RegExp(r'[（(\[【][^）)\]】]*[）)\]】]'), ' ');
    keyword = keyword.replaceAll(RegExp(r'第[0-9一二三四五六七八九十百零]+[集季部话話]'), ' ');
    keyword = keyword.replaceAll(RegExp(r'\b(19|20)\d{2}\b'), ' ');
    keyword = keyword.replaceAll(RegExp(r'\s+'), ' ').trim();
    return keyword.isEmpty ? title.trim() : keyword;
  }

  /// 标题越接近排得越前，避免匹配到同名的其他作品。
  static List<Map<String, dynamic>> _rankAnimes(
    List<Map<String, dynamic>> animes,
    String keyword,
  ) {
    int score(Map<String, dynamic> anime) {
      final raw = (anime['animeTitle'] ?? '').toString();
      final plain = raw.split(RegExp(r'[（(\[【]')).first.trim();
      if (plain == keyword) return 0;
      if (raw.contains(keyword)) return 1;
      if (keyword.contains(plain) && plain.isNotEmpty) return 2;
      final aliases = anime['aliases'];
      if (aliases is List &&
          aliases.any((alias) => alias.toString().contains(keyword))) {
        return 3;
      }
      return 4;
    }

    final sorted = [...animes];
    sorted.sort((a, b) => score(a).compareTo(score(b)));
    return sorted;
  }

  static List<DanmakuComment> _parseResponse(String body) {
    final trimmed = body.trim();
    if (trimmed.startsWith('{')) {
      try {
        final data = jsonDecode(trimmed) as Map<String, dynamic>;
        final comments = data['comments'];
        if (comments is List) {
          final parsed = comments
              .whereType<Map>()
              .map((rawItem) {
                final item = Map<String, dynamic>.from(rawItem);
                final p = (item['p'] ?? '').toString().split(',');
                return DanmakuComment(
                  time: Duration(
                      milliseconds:
                          ((double.tryParse(p.firstOrNull ?? '') ?? 0) * 1000)
                              .round()),
                  text: (item['m'] ?? '').toString(),
                  color: int.tryParse(p.length > 2 ? p[2] : '') ?? 0xFFFFFF,
                  mode: int.tryParse(p.length > 1 ? p[1] : '') ?? 1,
                );
              })
              .where((item) => item.text.trim().isNotEmpty)
              .toList();
          parsed.sort((a, b) => a.time.compareTo(b.time));
          return parsed;
        }
      } catch (_) {}
    }
    final result = <DanmakuComment>[];
    final regex = RegExp(r'<d\s+p="([^"]+)"[^>]*>(.*?)</d>', dotAll: true);
    for (final match in regex.allMatches(trimmed)) {
      final parts = match.group(1)!.split(',');
      final seconds = double.tryParse(parts.first) ?? 0;
      final text = _decodeXml(match.group(2) ?? '').trim();
      if (text.isEmpty) continue;
      result.add(DanmakuComment(
        time: Duration(milliseconds: (seconds * 1000).round()),
        text: text,
        color: int.tryParse(parts.length > 3 ? parts[3] : '') ?? 0xFFFFFF,
        mode: int.tryParse(parts.length > 1 ? parts[1] : '') ?? 1,
      ));
    }
    result.sort((a, b) => a.time.compareTo(b.time));
    return result;
  }

  static String _decodeXml(String value) => value
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");

  // ------------------------------------------------------------------- 缓存

  static Future<void> _writeCache(
    SharedPreferences prefs,
    String key,
    DanmakuResult result,
  ) async {
    await prefs.setString(
      key,
      jsonEncode({
        'source': result.source,
        'items': result.comments.map(_toJson).toList(),
      }),
    );
  }

  static DanmakuResult? _readCache(String? cached) {
    if (cached == null) return null;
    try {
      final decoded = jsonDecode(cached);
      if (decoded is! Map) return null;
      final items = decoded['items'];
      if (items is! List) return null;
      return DanmakuResult(
        comments: items
            .whereType<Map>()
            .map((item) => _fromJson(Map<String, dynamic>.from(item)))
            .toList(),
        source: (decoded['source'] ?? '本地缓存').toString(),
      );
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic> _toJson(DanmakuComment item) => {
        'time': item.time.inMilliseconds,
        'text': item.text,
        'color': item.color,
        'mode': item.mode,
      };

  static DanmakuComment _fromJson(Map<String, dynamic> item) => DanmakuComment(
        time: Duration(milliseconds: (item['time'] as num?)?.toInt() ?? 0),
        text: (item['text'] ?? '').toString(),
        color: (item['color'] as num?)?.toInt() ?? 0xFFFFFF,
        mode: (item['mode'] as num?)?.toInt() ?? 1,
      );
}

extension on List<String> {
  String? get firstOrNull => isEmpty ? null : first;
}
