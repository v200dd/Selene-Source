import 'api_service.dart';
import 'user_data_service.dart';

/// 短剧分类，对应 `GET /api/shortdrama/categories`
/// 返回结构：`[{type_id, type_name}]`
class ShortDramaCategory {
  const ShortDramaCategory({required this.typeId, required this.typeName});

  final int typeId;
  final String typeName;

  factory ShortDramaCategory.fromJson(Map<String, dynamic> json) =>
      ShortDramaCategory(
        typeId: (json['type_id'] as num?)?.toInt() ??
            int.tryParse((json['type_id'] ?? '').toString()) ??
            0,
        typeName: (json['type_name'] ?? '短剧').toString(),
      );
}

/// 短剧条目，对应 `GET /api/shortdrama/list` 的 `list` 元素
class ShortDramaItem {
  const ShortDramaItem({
    required this.id,
    required this.name,
    required this.cover,
    required this.episodeCount,
    this.score = 0,
    this.description = '',
  });

  final int id;
  final String name;
  final String cover;
  final int episodeCount;
  final double score;
  final String description;

  factory ShortDramaItem.fromJson(Map<String, dynamic> json) => ShortDramaItem(
        id: (json['id'] as num?)?.toInt() ??
            int.tryParse((json['id'] ?? '').toString()) ??
            0,
        name: (json['name'] ?? json['vod_name'] ?? '').toString(),
        cover: (json['cover'] ?? json['vod_pic'] ?? '').toString(),
        episodeCount: (json['episode_count'] as num?)?.toInt() ??
            int.tryParse((json['episode_count'] ?? '').toString()) ??
            1,
        score: (json['score'] as num?)?.toDouble() ??
            double.tryParse((json['score'] ?? '').toString()) ??
            0,
        description: (json['description'] ?? '').toString(),
      );
}

class ShortDramaPage {
  const ShortDramaPage({required this.items, required this.hasMore});

  final List<ShortDramaItem> items;
  final bool hasMore;
}

/// 短剧接口错误，带上真实的 HTTP 状态与路径，方便在页面上定位问题。
class ShortDramaException implements Exception {
  const ShortDramaException(this.message, {this.statusCode, this.endpoint});

  final String message;
  final int? statusCode;
  final String? endpoint;

  /// 面向用户的说明，区分「没登录」「主站没这个接口」「源解析失败」。
  String get friendlyMessage {
    switch (statusCode) {
      case 401:
        return '登录已过期，请重新登录后再看短剧';
      case 404:
        return '你的主站没有短剧接口（$endpoint）\n请升级 LunaTV/MoonTV 或在后台启用短剧';
      case 400:
        return '主站短剧源返回失败：$message';
      case 500:
        return '主站短剧接口报错（500），通常是后台没有配置短剧采集源';
      default:
        return statusCode == null ? message : '$message（HTTP $statusCode）';
    }
  }

  @override
  String toString() => friendlyMessage;
}

/// 单集解析结果，对应 `GET /api/shortdrama/parse`
class ShortDramaEpisode {
  const ShortDramaEpisode({
    required this.url,
    required this.title,
    required this.episode,
    required this.totalEpisodes,
  });

  final String url;
  final String title;
  final int episode;
  final int totalEpisodes;
}

/// 短剧数据服务。
///
/// 接口与网页端保持一致（LunaTV / MoonTVPlus 系列）：
/// `/api/shortdrama/categories`、`/api/shortdrama/list`、
/// `/api/shortdrama/search`、`/api/shortdrama/parse`。
class ShortDramaService {
  static Future<List<ShortDramaCategory>> getCategories() async {
    final response = await ApiService.get<dynamic>(
      '/api/shortdrama/categories',
    );
    if (!response.success) {
      throw ShortDramaException(
        response.message ?? '获取短剧分类失败',
        statusCode: response.statusCode,
        endpoint: '/api/shortdrama/categories',
      );
    }
    final data = response.data;
    if (data is! List) return const [];
    return data
        .whereType<Map>()
        .map((item) =>
            ShortDramaCategory.fromJson(Map<String, dynamic>.from(item)))
        .where((item) => item.typeName.isNotEmpty)
        .toList();
  }

  static Future<ShortDramaPage> getList({
    required int categoryId,
    int page = 1,
    int size = 20,
  }) async {
    final response = await ApiService.get<dynamic>(
      '/api/shortdrama/list',
      queryParameters: {
        'categoryId': '$categoryId',
        'page': '$page',
        'size': '$size',
      },
    );
    if (!response.success) {
      throw ShortDramaException(
        response.message ?? '获取短剧列表失败',
        statusCode: response.statusCode,
        endpoint: '/api/shortdrama/list',
      );
    }
    return _parsePage(response.data, page: page);
  }

  static Future<ShortDramaPage> search(
    String query, {
    int page = 1,
    int size = 20,
  }) async {
    final response = await ApiService.get<dynamic>(
      '/api/shortdrama/search',
      queryParameters: {
        'query': query,
        'page': '$page',
        'size': '$size',
      },
    );
    if (!response.success) {
      throw ShortDramaException(
        response.message ?? '搜索短剧失败',
        statusCode: response.statusCode,
        endpoint: '/api/shortdrama/search',
      );
    }
    return _parsePage(response.data, page: page);
  }

  /// 解析某一集的播放地址。`episode` 从 1 开始。
  static Future<ShortDramaEpisode> parseEpisode({
    required int id,
    required int episode,
    String? name,
  }) async {
    final response = await ApiService.get<dynamic>(
      '/api/shortdrama/parse',
      queryParameters: {
        'id': '$id',
        'episode': '$episode',
        'proxy': 'true',
        if (name != null && name.isNotEmpty) 'name': name,
        '_t': '${DateTime.now().millisecondsSinceEpoch}',
      },
    );
    if (!response.success || response.data is! Map) {
      throw ShortDramaException(
        response.message ?? '该集暂时无法播放',
        statusCode: response.statusCode,
        endpoint: '/api/shortdrama/parse',
      );
    }
    final json = Map<String, dynamic>.from(response.data! as Map);
    final rawUrl =
        (json['url'] ?? json['proxyUrl'] ?? json['originalUrl'] ?? '')
            .toString();
    if (rawUrl.isEmpty) {
      throw ShortDramaException(
        '该集暂时无法播放',
        statusCode: response.statusCode,
        endpoint: '/api/shortdrama/parse',
      );
    }
    return ShortDramaEpisode(
      url: await _absoluteUrl(rawUrl),
      title: (json['title'] ?? '').toString(),
      episode: (json['episode'] as num?)?.toInt() ?? episode,
      totalEpisodes: (json['totalEpisodes'] as num?)?.toInt() ?? 1,
    );
  }

  static ShortDramaPage _parsePage(dynamic data, {required int page}) {
    if (data is! Map) return const ShortDramaPage(items: [], hasMore: false);
    final json = Map<String, dynamic>.from(data);
    final rawList = json['list'] is List ? json['list'] as List : const [];
    return ShortDramaPage(
      items: rawList
          .whereType<Map>()
          .map((item) =>
              ShortDramaItem.fromJson(Map<String, dynamic>.from(item)))
          .where((item) => item.id != 0)
          .toList(),
      hasMore: json['hasMore'] == true,
    );
  }

  /// 服务端返回的代理地址是相对路径，需要补全为完整地址。
  static Future<String> _absoluteUrl(String url) async {
    if (!url.startsWith('/')) return url;
    final base = await UserDataService.getServerUrl();
    if (base == null || base.isEmpty) return url;
    final cleanBase =
        base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    return '$cleanBase$url';
  }
}
