/// IPTV / TVBox 共用的播放与频道骨架。
///
/// 2026-11-15 起直播平台房间、关注、热门、多平台分区、搜索、历史模块整体下线：
/// 这些目录已从仓库删除，本 barrel 不再导出它们。保留的是
///   - areas/            IPTV 频道目录页（AreasPage(onlySiteId: 'iptv')）
///   - iptv/             IPTV 数据、解析、导入与同步
///   - movie_playback/   TVBox 点播浏览 / 详情 / 诊断 / 播放入口
///   - playback/         IPTV 与 TVBox 共用的 LivePlayPage 播放器
library;

export 'areas/index.dart';
export 'iptv/index.dart';
export 'movie_playback/index.dart';
export 'playback/index.dart';
