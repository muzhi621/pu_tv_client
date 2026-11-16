/// EPG 节目指南页（TV 遥控器适配）。
///
/// 数据源是云端下发的 epgUrl（见 EpgRepository）。左侧选频道、右侧看当天节目，
/// 返回一律回上一页（频道目录）。无 EPG 源 / 拉取失败时展示可读的空态，
/// 而不是白屏或抛异常——TV 上没人看堆栈。
library;

import 'package:dpad/dpad.dart';
// package_export 提供 flutter/riverpod，common_export 提供 core 的
// tvTheme/i18nOr/TvButton 等；两者互补，缺一会导致 ConsumerState 等类型找不到。
import 'package:pure_live/exports/package_export.dart';
import 'package:pure_live/exports/common_export.dart';

import 'epg_model.dart';
import 'epg_repository.dart';

class EpgGuidePage extends ConsumerStatefulWidget {
  const EpgGuidePage({super.key});

  @override
  ConsumerState<EpgGuidePage> createState() => _EpgGuidePageState();
}

class _EpgGuidePageState extends ConsumerState<EpgGuidePage> {
  final _repository = EpgRepository();

  EpgGuide? _guide;
  int _channelIndex = 0;
  bool _loading = true;
  String? _error;
  DateTime _day = DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    // 先展示缓存，避免每次进入都白屏等待。
    final cached = _repository.readCached();
    if (cached != null && !cached.isEmpty) {
      setState(() {
        _guide = cached;
        _loading = false;
      });
    }

    if (!_repository.hasSource) {
      setState(() {
        _loading = false;
        _error = i18nOr('epg_no_source', '云端尚未配置节目单地址');
      });
      return;
    }

    try {
      final fresh = await _repository.fetch();
      if (!mounted) return;
      setState(() {
        _guide = fresh;
        _loading = false;
        _error = null;
        _channelIndex = _channelIndex.clamp(0, fresh.channels.length);
      });
    } catch (error) {
      if (!mounted) return;
      // 有缓存就继续用，只提示刷新失败；没缓存才显示错误态。
      setState(() {
        _loading = false;
        if (_guide == null || _guide!.isEmpty) {
          _error = i18nOr('epg_load_failed', '节目单加载失败，请稍后重试');
        }
      });
      debugPrint('EPG fetch failed: $error');
    }
  }

  void _shiftDay(int delta) {
    setState(() {
      _day = DateTime(_day.year, _day.month, _day.day + delta);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.tvTheme;
    final guide = _guide;
    final channels = guide?.channels ?? const <EpgChannel>[];

    return TvPageScaffold(
      title: i18nOr('epg_guide', '节目指南'),
      appBar: TvAppBar(
        title: i18nOr('epg_guide', '节目指南'),
        actions: <Widget>[
          Builder(builder: (_) {
            final label = _day.month == DateTime.now().month && _day.day == DateTime.now().day
                ? i18nOr('epg_today', '今天')
                : '${_day.month}/${_day.day}';
            return Text(label, style: AppTextStyles.t16.copyWith(color: theme.secondaryTextColor));
          }),
        ],
      ),
      child: SafeArea(
        child: _buildBody(theme, guide, channels),
      ),
    );
  }

  Widget _buildBody(TvThemeData theme, EpgGuide? guide, List<EpgChannel> channels) {
    if (_loading && (guide == null || guide.isEmpty)) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.tv_off_outlined, size: 56, color: theme.secondaryTextColor),
            SizedBox(height: 16.ts(context)),
            Text(_error!, style: AppTextStyles.t18.copyWith(color: theme.primaryTextColor)),
            SizedBox(height: 20.ts(context)),
            TvButton(title: i18nOr('retry', '重试'), onTap: _load, size: TvButtonSize.medium),
          ],
        ),
      );
    }
    if (channels.isEmpty) {
      return Center(child: Text(i18nOr('epg_empty', '暂无节目数据'), style: AppTextStyles.t18));
    }

    final current = channels[_channelIndex.clamp(0, channels.length - 1)];
    final programmes = guide!.programmesOf(current.id, _day);

    return DpadRegion(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 左侧频道列表
          SizedBox(
            width: 320.ts(context),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    TvIconButton(
                      icon: const Icon(Icons.chevron_left),
                      onTap: () => _shiftDay(-1),
                    ),
                    TvIconButton(
                      icon: const Icon(Icons.chevron_right),
                      onTap: () => _shiftDay(1),
                    ),
                    SizedBox(width: 12.ts(context)),
                    Text(i18nOr('epg_channels', '频道'), style: AppTextStyles.t18),
                  ],
                ),
                SizedBox(height: 12.ts(context)),
                Expanded(
                  child: ListView.builder(
                    itemCount: channels.length,
                    itemBuilder: (context, index) {
                      final ch = channels[index];
                      final selected = index == _channelIndex;
                      return ListTile(
                        title: Text(
                          ch.displayName,
                          style: AppTextStyles.t16.copyWith(
                            color: selected ? theme.focusColor : theme.primaryTextColor,
                            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        onTap: () => setState(() => _channelIndex = index),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: 20.ts(context)),
          // 右侧节目单
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  current.displayName,
                  style: AppTextStyles.t22.copyWith(color: theme.primaryTextColor, fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 12.ts(context)),
                Expanded(
                  child: programmes.isEmpty
                      ? Center(child: Text(i18nOr('epg_no_programme', '当天暂无节目'), style: AppTextStyles.t16))
                      : ListView.builder(
                          itemCount: programmes.length,
                          itemBuilder: (context, index) {
                            final p = programmes[index];
                            return Card(
                              child: ListTile(
                                title: Text(
                                  '${_hhmm(p.start)}–${_hhmm(p.end)}  ${p.title}',
                                  style: AppTextStyles.t16,
                                ),
                                subtitle: p.description.isEmpty ? null : Text(p.description, maxLines: 2),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
