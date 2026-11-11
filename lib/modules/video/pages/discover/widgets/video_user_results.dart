import 'package:dpad/dpad.dart';
import 'package:pure_live/exports/exports.dart';
import 'package:pure_live/modules/vod/models/models.dart';
import 'package:pure_live/modules/vod/api/bilibili_ugc_api.dart';

/// User results: a list row per UP, opening the shared user-space page.
class VideoUserResults extends ConsumerStatefulWidget {
  const VideoUserResults({super.key, required this.keyword});

  final String keyword;

  @override
  ConsumerState<VideoUserResults> createState() => _VideoUserResultsState();
}

class _VideoUserResultsState extends ConsumerState<VideoUserResults> {
  final ScrollController _scroll = ScrollController();
  final List<SearchUserItem> _users = [];
  bool _loading = false;
  bool _hasMore = true;
  int _page = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.hasClients && _scroll.position.extentAfter < 300) _load();
  }

  Future<void> _load() async {
    if (_loading || !_hasMore) return;
    setState(() => _loading = true);
    try {
      final page = _page + 1;
      final users = await BilibiliUgcApi.instance.searchUsers(widget.keyword, page: page);
      if (!mounted) return;
      setState(() {
        _users.addAll(users);
        _page = page;
        _hasMore = users.length >= 20;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tvTheme = context.tvTheme;
    final accent = tvTheme.focusColor;

    if (_loading && _users.isEmpty) return AppStatusView(type: AppStatusType.loading, title: '', subtitle: '');
    if (_error != null && _users.isEmpty) {
      return AppStatusView(type: AppStatusType.error, title: i18n('load_failed'), subtitle: _error);
    }
    return DpadRegion(
      child: ListView.builder(
        controller: _scroll,
        padding: EdgeInsets.all(24.ts(context)),
        itemCount: _users.length + (_hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= _users.length) {
            return Padding(
              padding: EdgeInsets.all(14.ts(context)),
              child: Center(
                child: SizedBox(
                  width: 26.ts(context),
                  height: 26.ts(context),
                  child: CircularProgressIndicator(strokeWidth: 3.ts(context), color: accent),
                ),
              ),
            );
          }
          final user = _users[index];
          return TvFocusable(
            onTap: () => UgcUserSpaceRoute(user.mid, user.uname).push(context),
            builder: (context, focused, child) => AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              margin: EdgeInsets.only(bottom: 10.sp),
              padding: EdgeInsets.all(14.ts(context)),
              decoration: BoxDecoration(
                color: tvTheme.cardColor,
                borderRadius: BorderRadius.circular(16.ts(context)),
                border: Border.all(color: focused ? accent : Colors.transparent, width: 2.ts(context)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user.uname,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.t18.copyWith(
                            fontWeight: FontWeight.w600,
                            color: tvTheme.primaryTextColor,
                          ),
                        ),
                        if (user.sign.isNotEmpty)
                          Text(
                            user.sign,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTextStyles.t14.copyWith(color: tvTheme.secondaryTextColor),
                          ),
                      ],
                    ),
                  ),
                  Text(
                    '${readableCount(user.fans.toString())} ${i18n('video_followers')}',
                    style: AppTextStyles.t14.copyWith(fontWeight: FontWeight.w500, color: tvTheme.secondaryTextColor),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Movie results: PGC seasons, straight into the season page.
