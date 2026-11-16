import 'package:pure_live/exports/package_export.dart';
import 'package:pure_live/platforms/sites.dart';
import 'package:pure_live/app/router/app/app_router.dart';
import 'package:pure_live/modules/live/playback/models/live_play_args.dart';
import 'package:pure_live/services/favorites/favorite_room_controller.dart';
import 'package:pure_live/modules/live/playback/widgets/panels/player_room_row.dart';
import 'package:pure_live/modules/live/playback/controllers/live_play_controller.dart';
import 'package:pure_live/modules/live/playback/widgets/panels/player_index_panel.dart';

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
  int? _index;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(livePlayControllerProvider(widget.args));
    final controller = ref.read(livePlayControllerProvider(widget.args).notifier);
    final List<LiveRoom> rooms = controller.channelRooms;
    final LiveRoom? current = state.room;
    final favorites = ref.watch(favoriteRoomControllerProvider).favoriteRooms;
    final int index = rooms.isEmpty ? 0 : (_index ?? controller.channelIndex).clamp(0, rooms.length - 1);

    return PlayerIndexPanel(
      // IPTV 的列表就是频道表，叫"频道列表"才对得上用户看到的东西；其他站点
      // 仍然是"播放列表"（那里还有主播房间的概念）。
      title: widget.args.platform == Sites.iptvSite || current?.platform == Sites.iptvSite
          ? i18nOr('ui_channel_list', '频道列表')
          : i18nOr('ui_playlist', 'Playlist'),
      rows: <PlayerPanelRow>[for (final LiveRoom room in rooms) PlayerPanelRow(label: room.title, subtitle: room.nick)],
      selectedIndex: index,
      onSelectionChanged: (i) => setState(() => _index = i),
      emptyHint: i18n('ui_none'),
      onSelect: (i) => _openRoom(rooms[i], rooms),
      onAdjustLeft: (i) => _toggleFollow(rooms[i]),
      onAdjustRight: (i) => _toggleFollow(rooms[i]),
      onClose: controller.toggleSidePanel,
      showCloseRow: false,
      rowExtent: PlayerRoomRow.extentOf(context, large: _largeRows),
      rowBuilder: (context, i, selected) => PlayerRoomRow(
        room: rooms[i],
        selected: selected,
        large: _largeRows,
        active: current != null && rooms[i].hasSameIdentity(current),
        favorite: favorites.any((item) => item.hasSameIdentity(rooms[i])),
        // Left/Right follow or unfollow on this row, so the row says so.
        showFollowAction: true,
      ),
    );
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
