import 'package:cached_network_image/cached_network_image.dart';
import 'package:pure_live/exports/exports.dart';
import 'package:pure_live/modules/live/movie_playback/vod_play_launcher.dart';

/// 单个影视条目的详情与选集。
///
/// 数据来源是 [VodSiteEngine.detail]，UI 只管三件事：把简介摊开、把多条
/// 线路列出来、把选中那一集交给播放器。真正「哪条线路能播」不做提前探测 ——
/// 探测一次就是一次全量请求，站点多的配置会把进入详情变成十几秒白屏。
class VodDetailPage extends StatefulWidget {
  const VodDetailPage({
    super.key,
    required this.site,
    required this.item,
    required this.engine,
  });

  final VodSite site;
  final VodItem item;

  /// 浏览页已经建好的引擎，带着已加载的 spider 实例 —— 换一个引擎意味着
  /// jar 要重新 DexClassLoader 一次。
  final VodSiteEngine engine;

  @override
  State<VodDetailPage> createState() => _VodDetailPageState();
}

class _VodDetailPageState extends State<VodDetailPage> {
  static const double _pagePadding = 32;

  VodDetail? _detail;
  String _error = '';
  bool _busy = true;
  bool _resolving = false;
  int _lineIndex = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final detail = await widget.engine.detail(widget.site, widget.item.id);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _lineIndex = 0;
        _busy = false;
        if (!detail.playable) {
          _error = i18n('vod_detail_no_episodes');
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _messageOf(error);
      });
    }
  }

  Future<void> _play(VodEpisode episode) async {
    final detail = _detail;
    final line = _currentLine;
    if (detail == null || line == null || _resolving) return;
    setState(() => _resolving = true);
    try {
      final resolved = await widget.engine.resolvePlay(
        widget.site,
        flag: line.flag,
        id: episode.url,
      );
      if (!mounted) return;
      if (resolved.url.isEmpty) {
        ToastUtil.show(i18n('vod_play_url_empty'));
        return;
      }
      if (resolved.parse == 1) {
        // 需要解析器的地址（网页嗅探类）当前没有内置解析器。仍然交给播放器
        // 试一次：不少站点标 1 但地址本身是能直连的，直接拦下反而更差。
        ToastUtil.show(i18n('vod_play_needs_parser'));
      }
      openVodPlayback(
        context,
        title: '${detail.name} ${episode.name}'.trim(),
        url: resolved.url,
        cover: detail.pic,
        headers: resolved.header,
      );
    } catch (error) {
      if (!mounted) return;
      ToastUtil.show(_messageOf(error));
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  VodPlayLine? get _currentLine {
    final lines = _detail?.lines.where((line) => line.episodes.isNotEmpty).toList(growable: false);
    if (lines == null || lines.isEmpty) return null;
    final index = _lineIndex.clamp(0, lines.length - 1);
    return lines[index];
  }

  List<VodPlayLine> get _playableLines =>
      _detail?.lines.where((line) => line.episodes.isNotEmpty).toList(growable: false) ??
      const <VodPlayLine>[];

  @override
  Widget build(BuildContext context) {
    final tvTheme = context.tvTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeader(tvTheme),
        SizedBox(height: 20.ts(context)),
        Expanded(child: _buildBody(tvTheme)),
      ],
    );
  }

  Widget _buildHeader(TvThemeData tvTheme) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: _pagePadding.ts(context)),
      child: Row(
        children: [
          TvButton(
            title: i18n('vod_back'),
            icon: const Icon(Icons.arrow_back_rounded),
            iconPosition: TvIconPosition.left,
            size: TvButtonSize.small,
            isSecondary: true,
            onTap: () => Navigator.of(context).maybePop(),
          ),
          SizedBox(width: 16.ts(context)),
          Expanded(
            child: Text(
              _detail?.name.isNotEmpty == true ? _detail!.name : widget.item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.t26.copyWith(
                fontWeight: FontWeight.w600,
                color: tvTheme.primaryTextColor,
                height: 1,
              ),
            ),
          ),
          if (_resolving)
            Padding(
              padding: EdgeInsets.only(left: 16.ts(context)),
              child: SizedBox(
                width: 22.ts(context),
                height: 22.ts(context),
                child: const CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          SizedBox(width: 16.ts(context)),
          Text(
            widget.site.name,
            style: AppTextStyles.t16.copyWith(color: tvTheme.secondaryTextColor),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(TvThemeData tvTheme) {
    if (_busy) {
      return const Center(child: CircularProgressIndicator());
    }
    final detail = _detail;
    if (detail == null) {
      return Padding(
        padding: EdgeInsets.all(_pagePadding.ts(context)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _error.isEmpty ? i18n('vod_detail_failed') : _error,
              style: AppTextStyles.t18.copyWith(color: tvTheme.secondaryTextColor),
            ),
            SizedBox(height: 20.ts(context)),
            TvButton(
              title: i18n('vod_retry'),
              size: TvButtonSize.small,
              isSecondary: true,
              onTap: _load,
            ),
          ],
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(left: _pagePadding.ts(context)),
          child: _buildPoster(detail),
        ),
        SizedBox(width: 28.ts(context)),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: _pagePadding.ts(context)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildMeta(detail, tvTheme),
                SizedBox(height: 12.ts(context)),
                if (detail.content.isNotEmpty)
                  Text(
                    detail.content,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.t16.copyWith(
                      color: tvTheme.secondaryTextColor,
                      height: 1.5,
                    ),
                  ),
                SizedBox(height: 18.ts(context)),
                if (_playableLines.length > 1) _buildLineTabs(tvTheme),
                if (_playableLines.length > 1) SizedBox(height: 12.ts(context)),
                Expanded(child: _buildEpisodes(tvTheme)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPoster(VodDetail detail) {
    final width = 240.ts(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(16.sp),
      child: SizedBox(
        width: width,
        height: width * 1.45,
        child: detail.pic.isEmpty
            ? Container(color: Colors.black26, child: const Icon(Icons.movie_outlined, size: 48))
            : CachedNetworkImage(
                imageUrl: detail.pic,
                cacheManager: CustomImageCacheManager.instance,
                memCacheWidth: 480,
                fit: BoxFit.cover,
                placeholder: (context, url) => Container(color: Colors.black26),
                errorWidget: (context, url, error) =>
                    Container(color: Colors.black26, child: const Icon(Icons.movie_outlined, size: 48)),
              ),
      ),
    );
  }

  Widget _buildMeta(VodDetail detail, TvThemeData tvTheme) {
    final parts = <String>[
      if (detail.year.isNotEmpty) detail.year,
      if (detail.area.isNotEmpty) detail.area,
      if (detail.remarks.isNotEmpty) detail.remarks,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          parts.join(' · '),
          style: AppTextStyles.t16.copyWith(color: tvTheme.secondaryTextColor),
        ),
        if (detail.actor.isNotEmpty || detail.director.isNotEmpty) ...[
          SizedBox(height: 6.ts(context)),
          Text(
            [
              if (detail.director.isNotEmpty) '${i18n('vod_director')}: ${detail.director}',
              if (detail.actor.isNotEmpty) '${i18n('vod_actor')}: ${detail.actor}',
            ].join('  '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.t16.copyWith(color: tvTheme.secondaryTextColor),
          ),
        ],
      ],
    );
  }

  Widget _buildLineTabs(TvThemeData tvTheme) {
    final lines = _playableLines;
    return SizedBox(
      height: 48.ts(context),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: lines.length,
        separatorBuilder: (_, __) => SizedBox(width: 10.ts(context)),
        itemBuilder: (context, index) {
          final selected = index == _lineIndex;
          return TvFocusable(
            onTap: () => setState(() => _lineIndex = index),
            child: Container(
              alignment: Alignment.center,
              padding: EdgeInsets.symmetric(horizontal: 18.ts(context)),
              decoration: BoxDecoration(
                color: selected
                    ? tvTheme.focusColor.withValues(alpha: 0.18)
                    : tvTheme.backgroundColor.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(12.sp),
                border: Border.all(
                  color: selected ? tvTheme.focusColor : Colors.transparent,
                  width: 1.5.sp,
                ),
              ),
              child: Text(
                _lineLabel(lines[index].flag, index),
                style: AppTextStyles.t16.copyWith(
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

  /// 线路名就是 TVBox 的 flag：常见 `m3u8`、`ckm3u8`、`kuyun`。个别站点的
  /// flag 是 `$$$` 分隔出来的一串乱码，退化成一号线路二号线路更好读。
  String _lineLabel(String flag, int index) {
    final text = flag.trim();
    if (text.isEmpty || text.length > 12) return i18n('vod_line_n', args: {'n': '${index + 1}'});
    return text;
  }

  Widget _buildEpisodes(TvThemeData tvTheme) {
    final line = _currentLine;
    if (line == null) {
      return Align(
        alignment: Alignment.topLeft,
        child: Text(
          _error.isEmpty ? i18n('vod_detail_no_episodes') : _error,
          style: AppTextStyles.t18.copyWith(color: tvTheme.secondaryTextColor),
        ),
      );
    }
    return GridView.builder(
      padding: EdgeInsets.only(bottom: 24.ts(context)),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        mainAxisSpacing: 12.ts(context),
        crossAxisSpacing: 12.ts(context),
        childAspectRatio: 2.2,
      ),
      itemCount: line.episodes.length,
      itemBuilder: (context, index) {
        final episode = line.episodes[index];
        return TvFocusable(
          onTap: () => _play(episode),
          child: Container(
            alignment: Alignment.center,
            padding: EdgeInsets.symmetric(horizontal: 8.ts(context)),
            decoration: BoxDecoration(
              color: tvTheme.backgroundColor.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12.sp),
            ),
            child: Text(
              episode.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.t16.copyWith(color: tvTheme.primaryTextColor),
            ),
          ),
        );
      },
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
