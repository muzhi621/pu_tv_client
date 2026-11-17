import 'package:pure_live/exports/package_export.dart';
import 'package:pure_live/platforms/sites.dart';
import 'package:pure_live/app/router/app/app_router.dart';
import 'package:pure_live/modules/live/playback/models/live_play_args.dart';
import 'package:pure_live/services/favorites/favorite_room_controller.dart';
import 'package:pure_live/modules/live/playback/widgets/panels/player_room_row.dart';
import 'package:pure_live/modules/live/playback/controllers/live_play_controller.dart';
import 'package:pure_live/modules/live/playback/player_panel_layout.dart';
import 'package:pure_live/modules/live/playback/widgets/panels/player_index_panel.dart';
import 'package:pure_live/modules/live/iptv/epg/epg_model.dart';
import 'package:pure_live/modules/live/iptv/epg/epg_playback_service.dart';

/// Playlist panel shown inside the player, as an index list of room cards.
///
/// See [LivePlayController.channelRooms] for the source: the rooms from the entry
/// page win, otherwise watch history is used. Up/Down walk the list, OK switches
/// channel (a route replace, so the previous session is released), and Left/Right
/// follow or unfollow, exactly like the reference's playlist panel.
///
/// Each row is the mobile app's small-screen room card (avatar, title, streamer,
/// platform and audience) rather than a bare title, so the channel list looks
/// like the room lists elsewhere in the app.
///
/// The list carries no trailing close row: Back closes the panel before it
/// leaves the room, which is the way out the other side panels already use. One
/// row per channel, and the remote's Back is the exit.
class PlaylistPanel extends ConsumerStatefulWidget {
  const PlaylistPanel({super.key, required this.args});

  final LivePlayArgs args;

  @override
  ConsumerState<PlaylistPanel> createState() => _PlaylistPanelState();
}

class _PlaylistPanelState extends ConsumerState<PlaylistPanel> {
  /// The room rows use [PlayerRoomRow]'s large layout, and the panel needs the
  /// same height to keep the highlight on screen. One flag feeds both, so they
  /// cannot disagree.
  static const bool _largeRows = true;

  /// Highlighted row. Opens on the **current** channel (as the 酷9 channel list
  /// does) instead of the first row: in a long IPTV package the viewer would
  /// otherwise have to hunt for the channel that is already playing.
  ///
  /// Null until the viewer moves the highlight, so the row keeps tracking the
  /// current channel while the list is still arriving: the IPTV channel table is
  /// loaded after the page opens (see [LivePlayController.ensureChannelList]),
  /// and pinning the index during initState would freeze it on row 0.
  ///
  /// IPTV 分组列表里它是**分组内**的下标，不是全局下标。
  int? _index;

  /// 当前看的分组。null = 跟随正在播的频道所在分组；用户按 ←→ 之后才固定下来。
  int? _groupIndex;

  @override
  void initState() {
    super.initState();
    // 节目单是全局数据，第一次打开频道列表时预热一次（幂等）：
    // 先用本地缓存同步建索引，过期再后台刷新，数据到达后由 revision 触发重建。
    EpgPlaybackService.instance.ensureLoaded();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(livePlayControllerProvider(widget.args));
    final controller = ref.read(livePlayControllerProvider(widget.args).notifier);
    final List<LiveRoom> rooms = controller.channelRooms;
    final LiveRoom? current = state.room;
    final favorites = ref.watch(favoriteRoomControllerProvider).favoriteRooms;
    // IPTV 的列表就是频道表，叫"频道列表"才对得上用户看到的东西；其他站点
    // 仍然是"播放列表"（那里还有主播房间的概念）。
    final bool iptv = widget.args.platform == Sites.iptvSite || current?.platform == Sites.iptvSite;

    // 两级：分组（云端套餐的一级）→ 该分组下的频道。
    // 直播间列表的 room.nick 是主播名而不是分组名，只有 IPTV 才按它分组。
    final List<_ChannelGroup> groups = iptv
        ? _groupChannels(rooms)
        : <_ChannelGroup>[if (rooms.isNotEmpty) _ChannelGroup(name: '', members: _range(rooms.length))];
    final int currentIndex = controller.channelIndex;
    final int groupIndex = groups.isEmpty
        ? 0
        : (_groupIndex ?? _groupOf(groups, currentIndex)).clamp(0, groups.length - 1);
    final List<int> members = groups.isEmpty ? const <int>[] : groups[groupIndex].members;
    final int rawSelected = _index ?? members.indexOf(currentIndex);
    final int selected = members.isEmpty
        ? 0
        : (rawSelected < 0 ? 0 : rawSelected).clamp(0, members.length - 1);
    final bool grouped = groups.length > 1;

    // 每行副标题显示「正在播什么」：数据由 initState 预热，这里只读目录。
    final EpgPlaybackService epg = EpgPlaybackService.instance;

    return ValueListenableBuilder<int>(
      valueListenable: epg.revision,
      builder: (context, _, _) => PlayerIndexPanel(
        title: iptv ? i18nOr('ui_channel_list', '频道列表') : i18nOr('ui_playlist', 'Playlist'),
        rows: <PlayerPanelRow>[
          for (final int global in members)
            PlayerPanelRow(label: rooms[global].title, subtitle: rooms[global].nick),
        ],
        selectedIndex: selected,
        onSelectionChanged: (i) => setState(() => _index = i),
        emptyHint: i18n('ui_none'),
        onSelect: (i) => _openRoom(rooms[members[i]], rooms),
        // ←→ 在分组列表里切分组；只有一组（或非 IPTV）时仍是关注/取消关注。
        onAdjustLeft: (i) => grouped
            ? _switchGroup(-1, groups.length, groupIndex)
            : _toggleFollow(rooms[members[i]]),
        onAdjustRight: (i) => grouped
            ? _switchGroup(1, groups.length, groupIndex)
            : _toggleFollow(rooms[members[i]]),
        hint: grouped ? i18nOr('ui_panel_keys_group', '↑↓ 选择 · ←→ 切换分组 · OK 播放') : null,
        header: grouped
            ? _GroupBar(
                groups: groups,
                selected: groupIndex,
                onSelect: (i) => _selectGroup(i),
              )
            : null,
        onClose: controller.toggleSidePanel,
        showCloseRow: false,
        rowExtent: PlayerRoomRow.extentOf(context, large: _largeRows),
        rowBuilder: (context, i, isSelected) {
          final LiveRoom room = rooms[members[i]];
          return PlayerRoomRow(
            room: room,
            selected: isSelected,
            large: _largeRows,
            active: current != null && room.hasSameIdentity(current),
            favorite: favorites.any((item) => item.hasSameIdentity(room)),
            // Left/Right 在 IPTV 频道表里仍然关注/取消关注，但不再在行内画「关注」
            // 文字：那个 pill 紧贴频道名，把「CCTV2 高清」这类名字挤成「CCTV2…」，
            // 而电视观看距离下频道名可读性远比一个状态词重要。直播间列表保留该
            // 提示——那里关注的是主播，用户需要看到当前状态。
            showFollowAction: !iptv,
            // IPTV 频道没有观众数，右侧那列「人数待更新」对每行都一样，纯占宽，
            // 传空串让行只留平台名，把宽度还给频道名。
            trailing: iptv ? '' : null,
            // 台号 + 正在播：IPTV 频道表的两个核心信息（换台靠台号，选台靠节目）。
            // 台号用**全局**下标，分组只是展示层级，不改台号，观众按记忆找台不会错位。
            indexLabel: iptv ? members[i] + 1 : null,
            nowPlaying: iptv ? _nowPlaying(epg, room) : null,
          );
        },
      ),
    );
  }

  static List<int> _range(int count) => <int>[for (int i = 0; i < count; i += 1) i];

  /// 按「云端套餐的一级分组」把频道切开，顺序沿用频道表顺序（= 套餐里的分组顺序）。
  ///
  /// 分组名取 `room.area`（IPTV 站点把它设成 M3U 的 group-title），回退到 `nick`
  /// （播放页用的来源标签）；两者都没有才落到「未分组」，不会出现空标题的分组。
  List<_ChannelGroup> _groupChannels(List<LiveRoom> rooms) {
    final Map<String, List<int>> byName = <String, List<int>>{};
    for (int i = 0; i < rooms.length; i += 1) {
      final LiveRoom room = rooms[i];
      final String fromArea = room.area.trim();
      final String raw = fromArea.isNotEmpty ? fromArea : room.nick.trim();
      final String name = raw.isEmpty ? i18nOr('ui_ungrouped', '未分组') : raw;
      (byName[name] ??= <int>[]).add(i);
    }
    return <_ChannelGroup>[
      for (final MapEntry<String, List<int>> entry in byName.entries)
        _ChannelGroup(name: entry.key, members: entry.value),
    ];
  }

  /// 正在播的频道落在第几个分组；找不到就落在第一组。
  int _groupOf(List<_ChannelGroup> groups, int channelIndex) {
    for (int i = 0; i < groups.length; i += 1) {
      if (groups[i].members.contains(channelIndex)) return i;
    }
    return 0;
  }

  void _selectGroup(int index) {
    setState(() {
      _groupIndex = index;
      _index = 0;
    });
  }

  /// ←→ 循环切换分组：频道一多时分组串会很长，到头回绕比停住更省按键。
  /// [current] 是当前**显示中**的分组（可能还处于「跟随正在播」状态），
  /// 从它开始挪，第一次按键才是相邻的那一组。
  void _switchGroup(int delta, int count, int current) {
    if (count <= 1) return;
    final int next = ((current + delta) % count + count) % count;
    _selectGroup(next);
  }

  /// 该频道正在播的节目名；没有节目单/没匹配到返回 null（行内回退分组名）。
  String? _nowPlaying(EpgPlaybackService epg, LiveRoom room) {
    final EpgProgramme? programme = epg.currentOf(room.title);
    if (programme == null) return null;
    return programme.title.trim().isEmpty ? null : programme.title.trim();
  }

  void _openRoom(LiveRoom room, List<LiveRoom> rooms) {
    final current = ref.read(livePlayControllerProvider(widget.args)).room;
    if (current != null && room.hasSameIdentity(current)) return;
    LivePlayRoute(LivePlayArgs.fromRoom(room, playlist: rooms, showChannelBanner: true)).replace(context);
  }

  void _toggleFollow(LiveRoom room) {
    final fav = ref.read(favoriteRoomControllerProvider.notifier);
    if (fav.isFavorite(room)) {
      fav.removeRoom(room);
    } else {
      fav.addRoom(room);
    }
  }
}

/// 频道列表的一级分组：分组名 + 该组频道在整张频道表里的下标。
///
/// 下标而不是房间对象：`channelRooms` 每次 build 都可能重建列表，
/// 存下标才能在一次会话里稳定地定位到同一批频道。
class _ChannelGroup {
  const _ChannelGroup({required this.name, required this.members});

  final String name;
  final List<int> members;
}

/// 分组条：横向排列的分组名，当前分组用强调色填充。
///
/// 键盘由 [PlayerIndexPanel] 独占（←→ 切分组），这里只负责「现在是第几组」，
/// 不做焦点控件；同时允许直接点按，触屏设备上不必先摸到遥控器。
class _GroupBar extends StatelessWidget {
  const _GroupBar({required this.groups, required this.selected, required this.onSelect});

  final List<_ChannelGroup> groups;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final TvThemeData tvTheme = context.tvTheme;
    final double scale = PlayerPanelLayout.fontSize;

    return SizedBox(
      height: 44.ts(context),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: 20.ts(context), vertical: 2.ts(context)),
        itemCount: groups.length,
        separatorBuilder: (_, __) => SizedBox(width: 8.ts(context)),
        itemBuilder: (context, index) {
          final bool active = index == selected;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onSelect(index),
            child: Container(
              alignment: Alignment.center,
              padding: EdgeInsets.symmetric(horizontal: 14.ts(context)),
              decoration: BoxDecoration(
                color: active ? tvTheme.focusColor : tvTheme.subtleRowFill,
                borderRadius: BorderRadius.circular(8.ts(context)),
              ),
              child: Text(
                groups[index].name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.of(15 * scale).copyWith(
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active ? Colors.white : tvTheme.secondaryTextColor,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
