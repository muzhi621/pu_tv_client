import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dpad/dpad.dart';
import 'package:pure_live/exports/exports.dart';
import 'package:pure_live/modules/live/movie_playback/vod_detail_page.dart';
import 'package:pure_live/services/remote_config/remote_config.dart';
import 'package:pure_live/services/vod/vod_jar_warmer.dart';

/// 影音板块的点播浏览页。
///
/// 只做「选站点 → 看分类 → 点进去」这一段，四件事刻意不做：
///
///   - 不做站点可用性预探测。配置里几十个站点，进页面前全部探一遍就是几十个
///     并发请求，弱网下等于白屏一分钟。哪个站能用，点进去就知道。
///   - 不做收藏 / 历史。它们要落库、要跟云端设备解耦，属于独立一期（#58 之后）。
///   - 不做解析器。`parse == 1` 的地址照样交给播放器试，真播不了再报错。
///   - 不缓存首页。不同站点的 `class` 差异极大，缓存键要做成 `站点 + 分类 + 页`，
///     收益远小于复杂度。
///
/// 数据全部来自 `RemoteConfigService.vod`：云端已经按设备展开成扁平的
/// sources + sites，这里不再关心资源库与引用关系。
class VodBrowsePage extends StatefulWidget {
  const VodBrowsePage({super.key});

  @override
  State<VodBrowsePage> createState() => _VodBrowsePageState();
}

class _VodBrowsePageState extends State<VodBrowsePage> {
  static const double _pagePadding = 32;

  /// 顶部菜单条两端留白：比正文页边距更靠内，让两端按钮向屏幕中间收。
  static const double _menuInset = 52;

  VodConfig _config = VodConfig.empty;
  VodSiteEngine? _engine;
  VodSite? _site;

  VodHome? _home;
  VodPage? _page;

  /// 当前分类，空串表示「推荐」（首页接口返回的 list）。
  String _tid = '';
  String _keyword = '';
  int _pageNo = 1;

  bool _busy = false;
  String _error = '';

  /// 正在为当前站点准备爬虫包（首次打开 csp_ 站点时会下载 jar）。
  ///
  /// 只用于把「转圈」变成「带解释的转圈」：否则用户看到的就是白屏转圈十几
  /// 秒，以为是卡死。
  bool _preparing = false;

  /// 空态里正在执行「重新获取配置」。
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _config = RemoteConfigService.vod;
    _engine = VodSiteEngine(config: _config);
    // 云端可以指定「默认站点」；没指定时仍是第一个站点（与升级前一致）。
    _site = _config.preferredSite;
    if (_site != null) {
      _loadHome();
    }
    // 其余站点的 jar 在后台预下：切站点时就不用再等下载了。
    unawaited(VodJarWarmer.warm(_config));
    // 后台同步（心跳 / 回前台）拿到新配置时自动重建：否则页面停在启动瞬间
    // 读到的空配置上，用户只能靠杀进程重进——那正是「下发成功但没内容」的体感。
    RemoteConfigService.appliedRevision.addListener(_onRemoteConfigApplied);
  }

  @override
  void dispose() {
    RemoteConfigService.appliedRevision.removeListener(_onRemoteConfigApplied);
    super.dispose();
  }

  void _onRemoteConfigApplied() {
    if (!mounted) return;
    final next = RemoteConfigService.vod;
    if (next.sites.isEmpty) return;
    setState(() {
      _config = next;
      _engine = VodSiteEngine(config: next);
      // 配置刷新时也回到云端默认站点：用户没手动切过站点，就该按最新下发走。
      _site = next.preferredSite;
      _home = null;
      _page = null;
      _error = '';
    });
    unawaited(VodJarWarmer.warm(next));
    _loadHome();
  }

  /// 空态按钮：先向云端强制全量拉一次（忽略 since），再重建引擎。
  Future<void> _resync() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    await RemoteConfigService.forceSync();
    if (!mounted) return;
    final next = RemoteConfigService.vod;
    setState(() {
      _config = next;
      _engine = VodSiteEngine(config: next);
      _site = next.preferredSite;
      _syncing = false;
      _error = '';
    });
    if (_site != null) {
      await _loadHome();
    } else {
      setState(() => _error = '');
    }
  }

  // ------------------------------------------------------------- 数据

  Future<void> _loadHome() async {
    final site = _site;
    final engine = _engine;
    if (site == null || engine == null) return;
    // 首次进这个 csp_ 站点时，jar 可能还没预热完，这一步会在原生侧同步下载。
    // 拿它做「准备中」提示的依据：刷新同一个站点时 _home 已有值，不再提示。
    final preparing = site.requiresSpiderJar && _home == null;
    setState(() {
      _busy = true;
      _preparing = preparing;
      _error = '';
      _tid = '';
      _keyword = '';
      _pageNo = 1;
      _page = null;
    });
    try {
      final home = await engine.home(site);
      if (!mounted) return;
      setState(() {
        _home = home;
        _busy = false;
        _preparing = false;
        if (home.isEmpty) _error = i18n('vod_site_empty');
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _home = null;
        _busy = false;
        _preparing = false;
        _error = _messageOf(error);
      });
    }
  }

  Future<void> _loadCategory(String tid, {int page = 1}) async {
    final site = _site;
    final engine = _engine;
    if (site == null || engine == null) return;
    setState(() {
      _busy = true;
      _error = '';
      _keyword = '';
    });
    try {
      final result = await engine.category(site, tid: tid, page: page);
      if (!mounted) return;
      setState(() {
        _page = result;
        _tid = tid;
        _pageNo = page;
        _busy = false;
        if (result.items.isEmpty) _error = i18n('vod_list_empty');
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _messageOf(error);
      });
    }
  }

  Future<void> _search() async {
    final site = _site;
    final engine = _engine;
    if (site == null || engine == null) return;
    final input = await TvDialogUtils.showInput(
      context: context,
      title: i18n('vod_search'),
      hintText: i18n('vod_search_hint'),
      initialValue: _keyword,
    );
    final key = (input ?? '').trim();
    if (key.isEmpty || !mounted) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final result = await engine.search(site, key);
      if (!mounted) return;
      setState(() {
        _page = result;
        _keyword = key;
        _tid = '';
        _pageNo = 1;
        _busy = false;
        if (result.items.isEmpty) _error = i18n('vod_search_empty');
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _messageOf(error);
      });
    }
  }

  Future<void> _pickSite() async {
    if (_config.sites.isEmpty) return;
    final picked = await TvDialogUtils.showSelect<VodSite>(
      context: context,
      title: i18n('vod_pick_site'),
      selectedValue: _site,
      items: _config.sites
          .map((site) => TvSelectItem<VodSite>(
                title: site.name,
                value: site,
                // 爬虫站点只显示 spider 名：原来那句「需要爬虫 jar」是给开发
                // 者看的，会在用户点之前就让他以为「还得先下载个东西」。
                // jar 现在由 VodJarWarmer 在后台预热，用户不需要知道这件事。
                subtitle: site.requiresSpiderJar ? site.spiderKey : site.api,
              ))
          .toList(),
    );
    if (picked == null || !mounted || picked.id == _site?.id) return;
    // 换站必须释放旧实例：spider 是静态状态，两个站点共用一个 jar 时残留的
    // 分类缓存会串到新站点上。串行 await，避免新站点在自己的 init 之前就
    // 被旧实例的 release 连带清掉。
    final engine = _engine;
    if (engine != null) await engine.release();
    if (!mounted) return;
    setState(() {
      _site = picked;
      _home = null;
      _page = null;
    });
    await _loadHome();
  }

  void _openDetail(VodItem item) {
    final site = _site;
    final engine = _engine;
    if (site == null || engine == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VodDetailPage(site: site, item: item, engine: engine),
      ),
    );
  }

  // ------------------------------------------------------------- 界面

  @override
  Widget build(BuildContext context) {
    final tvTheme = context.tvTheme;
    if (_config.isEmpty) return _buildNoConfig(tvTheme);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeader(tvTheme),
        SizedBox(height: 18.ts(context)),
        Expanded(child: _buildContent(tvTheme)),
      ],
    );
  }

  Widget _buildNoConfig(TvThemeData tvTheme) {
    final endpoint = RemoteConfigStore.endpoint;
    final doc = RemoteConfigStore.readDocument();
    final revision = doc?.revision ?? 0;
    final vod = doc?.section('vod') ?? const <String, dynamic>{};
    final sourceIds = (vod['sourceIds'] is List) ? (vod['sourceIds'] as List).length : 0;
    final sources = (vod['sources'] is List) ? (vod['sources'] as List).length : 0;

    return Padding(
      padding: EdgeInsets.all(_pagePadding.ts(context)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            i18n('vod_no_config'),
            style: AppTextStyles.t22.copyWith(
              color: tvTheme.primaryTextColor,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(height: 12.ts(context)),
          Text(
            i18n('vod_no_config_hint'),
            style: AppTextStyles.t16.copyWith(color: tvTheme.secondaryTextColor, height: 1.6),
          ),
          SizedBox(height: 12.ts(context)),
          // 现场诊断：把「云端地址 / 本地文档版本 / 引用与源的数量」直接摊开，
          // 用户拍一张截图就能定位是没拿到配置还是拿到了空配置。
          Text(
            '配置源 $endpoint · 本地版本 v$revision · 引用源 $sourceIds 个 · 已展开源 $sources 个',
            style: AppTextStyles.t14.copyWith(color: tvTheme.secondaryTextColor, height: 1.6),
          ),
          SizedBox(height: 24.ts(context)),
          TvButton(
            title: i18n('vod_reload'),
            size: TvButtonSize.small,
            isSecondary: true,
            autofocus: true,
            onTap: _syncing ? null : _resync,
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(TvThemeData tvTheme) {
    final site = _site;
    final canPage = _keyword.isNotEmpty || _tid.isNotEmpty;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: _menuInset.ts(context)),
      child: Row(
        children: [
          TvButton(
            title: i18n('vod_pick_site'),
            icon: const Icon(Icons.dns_outlined),
            iconPosition: TvIconPosition.left,
            size: TvButtonSize.medium,
            isSecondary: true,
            autofocus: true,
            onTap: _pickSite,
          ),
          SizedBox(width: 18.ts(context)),
          Expanded(
            child: Text(
              site?.name ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.t24.copyWith(
                fontWeight: FontWeight.w600,
                color: tvTheme.primaryTextColor,
              ),
            ),
          ),
          if (canPage) ...[
            TvButton(
              title: i18n('vod_prev_page'),
              size: TvButtonSize.medium,
              isSecondary: true,
              onTap: _pageNo <= 1 ? null : () => _loadCategory(_tid, page: _pageNo - 1),
            ),
            SizedBox(width: 10.ts(context)),
            Text(
              '$_pageNo / ${_page?.pageCount ?? 1}',
              style: AppTextStyles.t18.copyWith(color: tvTheme.secondaryTextColor),
            ),
            SizedBox(width: 10.ts(context)),
            TvButton(
              title: i18n('vod_next_page'),
              size: TvButtonSize.medium,
              isSecondary: true,
              onTap: (_page?.hasMore ?? false) ? () => _loadCategory(_tid, page: _pageNo + 1) : null,
            ),
            SizedBox(width: 18.ts(context)),
          ],
          TvButton(
            title: i18n('vod_search'),
            icon: const Icon(Icons.search_rounded),
            iconPosition: TvIconPosition.left,
            size: TvButtonSize.medium,
            isSecondary: true,
            onTap: _search,
          ),
          SizedBox(width: 14.ts(context)),
          TvButton(
            title: i18n('vod_refresh'),
            icon: const Icon(Icons.refresh_rounded),
            iconPosition: TvIconPosition.left,
            size: TvButtonSize.medium,
            isSecondary: true,
            onTap: _keyword.isEmpty && _tid.isEmpty ? _loadHome : () => _loadCategory(_tid, page: _pageNo),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(TvThemeData tvTheme) {
    if (_busy) return _buildBusy(tvTheme);
    final items = _visibleItems;
    if (_error.isNotEmpty && items.isEmpty) {
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: _pagePadding.ts(context)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _error,
              style: AppTextStyles.t18.copyWith(color: tvTheme.secondaryTextColor, height: 1.5),
            ),
            SizedBox(height: 18.ts(context)),
            TvButton(
              title: i18n('vod_retry'),
              size: TvButtonSize.small,
              isSecondary: true,
              autofocus: true,
              onTap: _keyword.isNotEmpty || _tid.isNotEmpty
                  ? () => _loadCategory(_tid, page: _pageNo)
                  : _loadHome,
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_keyword.isEmpty) _buildCategories(tvTheme) else _buildSearchHint(tvTheme),
        SizedBox(height: 14.ts(context)),
        Expanded(
          child: GridView.builder(
            padding: EdgeInsets.fromLTRB(
              _pagePadding.ts(context),
              4.ts(context),
              _pagePadding.ts(context),
              24.ts(context),
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 6,
              mainAxisSpacing: 16.ts(context),
              crossAxisSpacing: 16.ts(context),
              childAspectRatio: 0.62,
            ),
            itemCount: items.length,
            itemBuilder: (context, index) => _buildPoster(items[index], tvTheme),
          ),
        ),
      ],
    );
  }

  /// 忙碌态。首次打开需要爬虫包的站点时多给一句解释，否则用户只看到白屏
  /// 转圈，会以为是卡死（jar 在原生侧同步下载，最大可到几十 MB）。
  Widget _buildBusy(TvThemeData tvTheme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          if (_preparing) ...[
            SizedBox(height: 20.ts(context)),
            Text(
              i18n('vod_preparing'),
              style: AppTextStyles.t18.copyWith(
                color: tvTheme.primaryTextColor,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 8.ts(context)),
            Text(
              i18n('vod_preparing_hint'),
              style: AppTextStyles.t16.copyWith(
                color: tvTheme.secondaryTextColor,
                height: 1.5,
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<VodItem> get _visibleItems {
    if (_keyword.isNotEmpty) return _page?.items ?? const <VodItem>[];
    if (_tid.isEmpty) return _home?.items ?? const <VodItem>[];
    return _page?.items ?? const <VodItem>[];
  }

  Widget _buildSearchHint(TvThemeData tvTheme) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: _pagePadding.ts(context)),
      child: Row(
        children: [
          Text(
            i18n('vod_search_result', args: {'key': _keyword}),
            style: AppTextStyles.t16.copyWith(color: tvTheme.secondaryTextColor),
          ),
          SizedBox(width: 14.ts(context)),
          TvButton(
            title: i18n('vod_back_to_home'),
            size: TvButtonSize.mini,
            isSecondary: true,
            onTap: () {
              setState(() {
                _keyword = '';
                _page = null;
                _tid = '';
                _pageNo = 1;
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildCategories(TvThemeData tvTheme) {
    final categories = _home?.categories ?? const <VodCategory>[];
    if (categories.isEmpty) return const SizedBox.shrink();
    final entries = <(String, String)>[('', i18n('vod_recommend'))];
    for (final category in categories) {
      entries.add((category.id, category.name));
    }
    return SizedBox(
      height: 56.ts(context),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: _menuInset.ts(context)),
        itemCount: entries.length,
        separatorBuilder: (_, __) => SizedBox(width: 14.ts(context)),
        itemBuilder: (context, index) {
          final (tid, name) = entries[index];
          final selected = tid == _tid;
          return TvFocusable(
            onTap: () {
              if (tid.isEmpty) {
                _loadHome();
              } else {
                _loadCategory(tid);
              }
            },
            child: Container(
              alignment: Alignment.center,
              padding: EdgeInsets.symmetric(horizontal: 26.ts(context)),
              decoration: BoxDecoration(
                color: selected
                    ? tvTheme.focusColor.withValues(alpha: 0.18)
                    : tvTheme.backgroundColor.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(14.sp),
                border: Border.all(
                  color: selected ? tvTheme.focusColor : Colors.transparent,
                  width: 1.5.sp,
                ),
              ),
              child: Text(
                name,
                style: AppTextStyles.t19.copyWith(
                  color: selected ? tvTheme.focusColor : tvTheme.primaryTextColor,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPoster(VodItem item, TvThemeData tvTheme) {
    final borderRadius = BorderRadius.circular(14.sp);
    return DpadFocusable(
      effects: <DpadEffect>[
        DpadScaleEffect(
          scale: 1.04,
          pressedScale: 0.97,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOutCubic,
        ),
        tvTheme.isLight
            ? DpadGlowEffect(color: tvTheme.focusColor, opacity: 1, spreadRadius: 2.sp, blurRadius: 0)
            : DpadGlowEffect(color: tvTheme.focusColor, opacity: 1, spreadRadius: 1.sp, blurRadius: 12.0.sp),
        DpadCustomEffect((ctx, state, _) {
          final focused = state.focused;
          return AnimatedContainer(
            duration: TvFocusStyle.focusDuration(focused),
            curve: TvFocusStyle.curve,
            padding: EdgeInsets.all(7.ts(context)),
            decoration: BoxDecoration(
              color: tvTheme.backgroundColor,
              borderRadius: borderRadius,
              border: Border.all(
                color: focused ? tvTheme.focusColor : Colors.transparent,
                width: 2.sp,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10.sp),
                    clipBehavior: Clip.antiAlias,
                    child: item.hasPic
                        ? CachedNetworkImage(
                            imageUrl: item.pic,
                            cacheManager: CustomImageCacheManager.instance,
                            memCacheWidth: 360,
                            fit: BoxFit.cover,
                            placeholder: (context, url) => Container(color: Colors.black26),
                            errorWidget: (context, url, error) => Container(
                              color: Colors.black26,
                              child: const Icon(Icons.movie_outlined, size: 32),
                            ),
                          )
                        : Container(
                            color: Colors.black26,
                            child: const Icon(Icons.movie_outlined, size: 32),
                          ),
                  ),
                ),
                SizedBox(height: 6.ts(context)),
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.t15.copyWith(
                    color: tvTheme.primaryTextColor,
                    fontWeight: focused ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
                if (item.remarks.isNotEmpty)
                  Text(
                    item.remarks,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.t12.copyWith(color: tvTheme.secondaryTextColor),
                  ),
              ],
            ),
          );
        }),
      ],
      onSelect: () => _openDetail(item),
      child: const SizedBox(),
    );
  }

  String _messageOf(Object error) {
    if (error is VodEngineException) {
      final step = error.step.isEmpty ? '' : '（${error.step}）';
      return '${error.message}$step';
    }
    return error.toString();
  }
}
