import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../services/short_drama_service.dart';
import '../services/short_drama_source_service.dart';
import '../utils/font_utils.dart';
import 'player_screen.dart';
import 'short_drama_player_screen.dart';

/// 短剧频道。
///
/// 数据优先走跟电影、剧集完全相同的采集源（`/api/search/resources` 里的苹果 CMS
/// 接口，按 `ac=list` 找到短剧分类后用 `ac=videolist&t=` 拉列表）。因为电影能看、
/// 短剧不能看的根因就是老实现走了主站 `/api/shortdrama/*`，那条链路依赖主站单独
/// 配置的短剧上游源，上游一挂整个频道就报错。
///
/// 采集源里确实找不到短剧时，才回退到主站 `/api/shortdrama/*`。
class ShortDramaScreen extends StatefulWidget {
  const ShortDramaScreen({super.key});

  @override
  State<ShortDramaScreen> createState() => _ShortDramaScreenState();
}

class _ShortDramaScreenState extends State<ShortDramaScreen> {
  /// 采集源链路
  List<ShortDramaSourceCategory> _sourceCategories = const [];
  List<ShortDramaSourceItem> _sourceItems = const [];

  /// 主站回退链路
  List<ShortDramaCategory> _categories = const [];
  List<ShortDramaItem> _items = const [];
  ShortDramaCategory? _category;

  bool _usingSiteFallback = false;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  int _page = 1;
  bool _hasMore = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    // 先试采集源。
    try {
      final categories = await ShortDramaSourceService.categories();
      final items = await ShortDramaSourceService.list(
        categories: categories,
        page: 1,
      );
      if (!mounted) return;
      if (items.isNotEmpty) {
        setState(() {
          _usingSiteFallback = false;
          _sourceCategories = categories;
          _sourceItems = items;
          _page = 1;
          _hasMore = true;
          _loading = false;
          _error = null;
        });
        return;
      }
    } catch (_) {
      // 采集源不可用就走下面的主站回退。
    }

    if (!mounted) return;
    setState(() => _usingSiteFallback = true);
    await _loadSiteCategories();
  }

  Future<void> _loadMoreFromSources() async {
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final items = await ShortDramaSourceService.list(
        categories: _sourceCategories,
        page: next,
      );
      if (!mounted) return;
      final known = _sourceItems.map((item) => item.title).toSet();
      final fresh = items.where((item) => !known.contains(item.title)).toList();
      setState(() {
        _page = next;
        _hasMore = fresh.isNotEmpty;
        _sourceItems = [..._sourceItems, ...fresh];
      });
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _loadSiteCategories() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final categories = await ShortDramaService.getCategories();
      if (!mounted) return;
      setState(() {
        _categories = categories;
        _category = categories.isEmpty ? null : categories.first;
      });
      if (_category != null) {
        await _loadList();
      } else if (mounted) {
        setState(() => _error = '采集源里没有短剧分类，主站也没有配置短剧源');
      }
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadList({bool more = false}) async {
    final category = _category;
    if (category == null) return;
    final targetPage = more ? _page + 1 : 1;
    if (more) setState(() => _loadingMore = true);
    try {
      final result = await ShortDramaService.getList(
        categoryId: category.typeId,
        page: targetPage,
      );
      if (!mounted) return;
      setState(() {
        _page = targetPage;
        _hasMore = result.hasMore && result.items.isNotEmpty;
        _items = more ? [..._items, ...result.items] : result.items;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  String _friendlyError(Object error) {
    if (error is ShortDramaException) return error.friendlyMessage;
    return error.toString().replaceFirst('Exception: ', '');
  }

  void _selectCategory(ShortDramaCategory category) {
    setState(() {
      _category = category;
      _items = const [];
      _page = 1;
      _error = null;
    });
    _loadList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = _usingSiteFallback ? _items.length : _sourceItems.length;
    return RefreshIndicator(
      onRefresh: () async {
        ShortDramaSourceService.resetCache();
        await _load();
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text('短剧',
              style:
                  FontUtils.poppins(fontSize: 24, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(
            _usingSiteFallback
                ? '来自主站短剧接口'
                : '来自与电影、剧集相同的采集源${total > 0 ? ' · $total 部' : ''}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          if (_usingSiteFallback && _categories.isNotEmpty)
            SizedBox(
              height: 42,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _categories.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final category = _categories[index];
                  return ChoiceChip(
                    label: Text(category.typeName),
                    selected: category.typeId == _category?.typeId,
                    onSelected: (_) => _selectCategory(category),
                  );
                },
              ),
            ),
          if (_usingSiteFallback && _categories.isNotEmpty)
            const SizedBox(height: 12),
          if (_loading && total == 0)
            const Padding(
                padding: EdgeInsets.all(48),
                child: Center(child: CircularProgressIndicator()))
          else if (_error != null && total == 0)
            _Message(text: _error!, onRetry: _load)
          else if (total == 0)
            const _Message(text: '暂无短剧内容')
          else
            _buildGrid(),
        ],
      ),
    );
  }

  Widget _buildGrid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth > 900
            ? 6
            : constraints.maxWidth > 600
                ? 4
                : 3;
        final count = _usingSiteFallback ? _items.length : _sourceItems.length;
        return Column(
          children: [
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: count,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: 12,
                mainAxisSpacing: 16,
                childAspectRatio: 1 / 1.82,
              ),
              itemBuilder: (context, index) => _usingSiteFallback
                  ? _ShortDramaCard(item: _items[index])
                  : _SourceDramaCard(item: _sourceItems[index]),
            ),
            if (_hasMore)
              Padding(
                padding: const EdgeInsets.only(top: 20),
                child: OutlinedButton(
                  onPressed: _loadingMore
                      ? null
                      : () => _usingSiteFallback
                          ? _loadList(more: true)
                          : _loadMoreFromSources(),
                  child: Text(_loadingMore ? '加载中...' : '加载更多'),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 采集源短剧卡片。点开直接进常规播放页，跟电影、剧集同一条链路。
class _SourceDramaCard extends StatelessWidget {
  const _SourceDramaCard({required this.item});

  final ShortDramaSourceItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PlayerScreen(
          source: item.source,
          id: item.id,
          title: item.title,
          year: item.year.isEmpty ? null : item.year,
          stype: 'tv',
        ),
      )),
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (item.poster.isEmpty)
                    Container(color: theme.dividerColor.withValues(alpha: 0.3))
                  else
                    CachedNetworkImage(
                      // iOS ATS 默认拒绝明文 http 图片，统一升级为 https。
                      imageUrl: item.poster
                          .replaceFirst(RegExp(r'^http://'), 'https://'),
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Container(
                        color: theme.dividerColor.withValues(alpha: 0.3),
                        child: const Center(
                            child: Icon(Icons.movie_outlined, size: 20)),
                      ),
                    ),
                  if (item.episodeLabel.isNotEmpty)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          item.episodeLabel,
                          style: FontUtils.poppins(
                              fontSize: 10, color: Colors.white),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: FontUtils.poppins(fontSize: 12, fontWeight: FontWeight.w500),
          ),
          Text(
            item.sourceName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(fontSize: 10),
          ),
        ],
      ),
    );
  }
}

class _ShortDramaCard extends StatelessWidget {
  const _ShortDramaCard({required this.item});

  final ShortDramaItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ShortDramaPlayerScreen(item: item),
      )),
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (item.cover.isEmpty)
                    Container(color: theme.dividerColor.withValues(alpha: 0.3))
                  else
                    CachedNetworkImage(
                      // iOS ATS 默认拒绝明文 http 图片，统一升级为 https。
                      imageUrl: item.cover
                          .replaceFirst(RegExp(r'^http://'), 'https://'),
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => Container(
                        color: theme.dividerColor.withValues(alpha: 0.3),
                        child: const Center(
                            child: Icon(Icons.movie_outlined, size: 20)),
                      ),
                    ),
                  if (item.episodeCount > 1)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.65),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '${item.episodeCount}集',
                          style: FontUtils.poppins(
                              fontSize: 10, color: Colors.white),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: FontUtils.poppins(fontSize: 12, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.onRetry});
  final String text;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(48),
        child: Column(children: [
          Text(text, textAlign: TextAlign.center),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('重试'))
        ]),
      );
}
