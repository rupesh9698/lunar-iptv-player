class AppConstants {
  AppConstants._();

  static const String appName = 'Lunar IPTV Player';
  static const String appVersion = '1.0.0';

  // Hive box names
  static const String playlistBox = 'playlists';
  static const String settingsBox = 'settings';
  static const String favoritesBox = 'favorites';
  static const String categoryOrderBox = 'category_order';
  static const String hiddenCategoriesBox = 'hidden_categories';
  static const String watchHistoryBox = 'watch_history';

  // Settings keys
  static const String parentalPinKey = 'parental_pin';
  static const String parentalEnabledKey = 'parental_enabled';
  static const String parentalLockedCatsLiveKey = 'parental_locked_cats_live';
  static const String autoUpdateKey = 'auto_update';
  static const String autoUpdateIntervalKey = 'auto_update_interval';
  static const String defaultPlayerKey = 'default_player';
  static const String activePlaylistKey = 'active_playlist';
  static const String streamFormatKey = 'stream_format'; // ts or m3u8
  static const String showChannelNumberKey = 'show_channel_number';
  static const String rememberPositionKey = 'remember_position';
  static const String subtitleFontSizeKey = 'subtitle_font_size';

  // Stream formats
  static const String formatM3U8 = 'm3u8';
  static const String formatTS = 'ts';

  // API actions
  static const String actionGetLiveCategories = 'get_live_categories';
  static const String actionGetVodCategories = 'get_vod_categories';
  static const String actionGetSeriesCategories = 'get_series_categories';
  static const String actionGetLiveStreams = 'get_live_streams';
  static const String actionGetVodStreams = 'get_vod_streams';
  static const String actionGetSeries = 'get_series';
  static const String actionGetSeriesInfo = 'get_series_info';
  static const String actionGetVodInfo = 'get_vod_info';
  static const String actionGetShortEpg = 'get_short_epg';
  static const String actionGetSimpleDateTable = 'get_simple_date_table';
  static const String recentVodKey = 'recently_viewed_vod';
  static const String recentSeriesKey = 'recently_viewed_series';

  // UI Constants
  static const double cardBorderRadius = 12.0;
  static const double sidebarWidth = 220.0;
  static const double mobileThreshold = 600.0;
  static const double tabletThreshold = 900.0;
}