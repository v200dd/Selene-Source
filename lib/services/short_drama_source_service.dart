import 'dart:async';
import 'dart:convert';

import 'package:gbk_codec/gbk_codec.dart';
import 'package:http/http.dart' as http;

import '../models/search_resource.dart';
import 'api_service.dart';
import 'content_filter_service.dart';

/// 采集源里的一条短剧。
///
/// 字段刻意跟 `SearchResult` 对齐（`source` + `id`），这样点开就能直接交给
/// 常规播放页 `PlayerScreen`，跟电影、剧集走同一条播放链路。
class ShortDramaSourceItem {
  const ShortDramaSourceItem({
    required this.source,
    required this.sourceName,
    required this.id,
    required this.title,
    required this.poster,
    required this.episodeCount,
    required this.year,
    this.remarks = '',
  });

  final String source;
  final String sourceName;
  final String id;
  final String title;
  final String poster;
  final int episodeCount;
  final String year;

  /// 采集源给的备注，通常就是「已完结」或「更新至xx集」。
  final String remarks;

  String get episodeLabel {
    if (episodeCount > 1) return '$episodeCount集';
    if (remarks.isNotEmpty) return remarks;
    return '';
  }
}

/// 一个采集源里的短剧分类。
class ShortDramaSourceCategory {
  const ShortDramaSourceCategory({
    required this.sourceKey,
    required this.typeId,
    required this.typeName,
  });

  final String sourceKey;
  final int typeId;
  final String typeName;
}

/// 短剧频道的数据源。
///
/// 之前短剧走主站 `/api/shortdrama/*`，那条链路依赖主站自己配置的短剧上游源，
/// 上游一挂整个频道就报「网络连接失败」。电影和剧集从来不走那里，而是直接查
/// `/api/search/resources` 给出的采集源（苹果 CMS 协议）。所以这里把短剧也搬到
/// 同一套采集源上：先用 `ac=list` 找出名字含「短剧」的分类，再用
/// `ac=videolist&t=分类&pg=页码` 拉列表。
class ShortDramaSourceService {
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

  /// 分类名里出现这些词就当成短剧频道。
  static const _keywords = ['短剧', '微短剧', '竖屏', '小短剧'];

  static List<ShortDramaSourceCategory>? _categoryCache;
  static List<SearchResource>? _resourceCache;

  static void resetCache() {
    _categoryCache = null;
    _resourceCache = null;
  }

  static Future<List<SearchResource>> _resources() async {
    final cached = _resourceCache;
    if (cached != null) return cached;
    final all = await ApiService.getSearchResources();
    final enabled = all
        .where((resource) => !resource.disabled && resource.api.isNotEmpty)
        .toList();
    _resourceCache = enabled;
    return enabled;
  }

  /// 找出所有采集源里的短剧分类。空列表说明这些源都没有单独的短剧分类。
  static Future<List<ShortDramaSourceCategory>> categories() async {
    final cached = _categoryCache;
    if (cached != null) return cached;

    final resources = await _resources();
    if (resources.isEmpty) return const [];

    // 只探前若干个源，避免开页时打满几十个请求。
    final probes = resources.take(12).map(_categoriesOf);
    final results = await Future.wait(probes);
    final merged = results.expand((item) => item).toList();
    _categoryCache = merged;
    return merged;
  }

  static Future<List<ShortDramaSourceCategory>> _categoriesOf(
    SearchResource resource,
  ) async {
    try {
      final body = await _fetch('${resource.api}?ac=list');
      final decoded = jsonDecode(body);
      if (decoded is! Map) return const [];
      final classes = decoded['class'];
      if (classes is! List) return const [];
      return classes
          .whereType<Map>()
          .map((item) {
            final name = (item['type_name'] ?? '').toString().trim();
            final id = (item['type_id'] as num?)?.toInt() ??
                int.tryParse((item['type_id'] ?? '').toString()) ??
                0;
            return ShortDramaSourceCategory(
              sourceKey: resource.key,
              typeId: id,
              typeName: name,
            );
          })
          .where((item) =>
              item.typeId != 0 &&
              _keywords.any((keyword) => item.typeName.contains(keyword)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 拉一页短剧。`categories` 为空时退化成按关键字搜索，仍然只走采集源。
  static Future<List<ShortDramaSourceItem>> list({
    required List<ShortDramaSourceCategory> categories,
    int page = 1,
  }) async {
    final resources = await _resources();
    if (resources.isEmpty) return const [];
    final byKey = {for (final resource in resources) resource.key: resource};

    final futures = <Future<List<ShortDramaSourceItem>>>[];
    if (categories.isEmpty) {
      for (final resource in resources.take(8)) {
        futures.add(_videoList(
          resource: resource,
          query: '短剧',
          page: page,
        ));
      }
    } else {
      for (final category in categories.take(8)) {
        final resource = byKey[category.sourceKey];
        if (resource == null) continue;
        futures.add(_videoList(
          resource: resource,
          typeId: category.typeId,
          page: page,
        ));
      }
    }

    final results = await Future.wait(futures);

    // 多源合并后按标题去重，保留集数更多的那一条。
    final merged = <String, ShortDramaSourceItem>{};
    for (final group in results) {
      for (final item in group) {
        final key = item.title;
        final existing = merged[key];
        if (existing == null || item.episodeCount > existing.episodeCount) {
          merged[key] = item;
        }
      }
    }
    return merged.values.toList();
  }

  static Future<List<ShortDramaSourceItem>> _videoList({
    required SearchResource resource,
    int? typeId,
    String? query,
    required int page,
  }) async {
    final parameters = <String>[
      'ac=videolist',
      'pg=$page',
      if (typeId != null) 't=$typeId',
      if (query != null && query.isNotEmpty) 'wd=${Uri.encodeComponent(query)}',
    ];
    try {
      final body = await _fetch('${resource.api}?${parameters.join('&')}');
      final decoded = jsonDecode(body);
      if (decoded is! Map) return const [];
      final list = decoded['list'];
      if (list is! List) return const [];
      return list
          .whereType<Map>()
          .map((item) => _parseItem(Map<String, dynamic>.from(item), resource))
          .whereType<ShortDramaSourceItem>()
          .where((item) => !ContentFilterService.shouldFilter(item.remarks))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  static ShortDramaSourceItem? _parseItem(
    Map<String, dynamic> json,
    SearchResource resource,
  ) {
    final id = (json['vod_id'] ?? '').toString();
    final title = (json['vod_name'] ?? '').toString().trim();
    if (id.isEmpty || title.isEmpty) return null;

    final year = RegExp(r'\d{4}')
            .firstMatch((json['vod_year'] ?? '').toString())
            ?.group(0) ??
        '';

    return ShortDramaSourceItem(
      source: resource.key,
      sourceName: resource.name,
      id: id,
      title: title.replaceAll(RegExp(r'\s+'), ' '),
      poster: (json['vod_pic'] ?? '').toString(),
      episodeCount: _episodeCount(json),
      year: year,
      remarks: (json['vod_remarks'] ?? '').toString().trim(),
    );
  }

  /// 集数直接从 `vod_play_url` 数出来，比依赖备注可靠。
  static int _episodeCount(Map<String, dynamic> json) {
    final playUrl = (json['vod_play_url'] ?? '').toString();
    if (playUrl.isNotEmpty) {
      var best = 0;
      for (final group in playUrl.split(r'$$$')) {
        final count =
            group.split('#').where((entry) => entry.contains(r'$')).length;
        if (count > best) best = count;
      }
      if (best > 0) return best;
    }
    final remarks = (json['vod_remarks'] ?? '').toString();
    final match = RegExp(r'(\d+)\s*集').firstMatch(remarks);
    if (match != null) return int.tryParse(match.group(1)!) ?? 1;
    final total = (json['vod_total'] as num?)?.toInt() ??
        int.tryParse((json['vod_total'] ?? '').toString()) ??
        0;
    return total > 0 ? total : 1;
  }

  /// 采集源有 GBK 的，沿用搜索链路那套解码逻辑。
  static Future<String> _fetch(String url) async {
    final response = await http.get(
      Uri.parse(url),
      headers: const {
        'User-Agent': _userAgent,
        'Accept': 'application/json',
      },
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('HTTP ${response.statusCode}');
    }

    final contentType = response.headers['content-type'] ?? '';
    final charset = RegExp(r'charset=([^;]+)')
        .firstMatch(contentType)
        ?.group(1)
        ?.toLowerCase()
        .trim();
    if (charset == 'gbk' || charset == 'gb2312') {
      try {
        return gbk_bytes.decode(response.bodyBytes);
      } catch (_) {
        return utf8.decode(response.bodyBytes, allowMalformed: true);
      }
    }
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }
}
