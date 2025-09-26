// ignore_for_file: constant_identifier_names

import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:get/get.dart' as getx;
import 'package:hive/hive.dart';

import '/models/album.dart';
import '/models/playlist.dart';
import '/services/utils.dart';
import '../utils/helper.dart';
import 'constant.dart';
import 'continuations.dart';
import 'nav_parser.dart';

enum AudioQuality {
  Low,
  High,
}

class MusicServices extends getx.GetxService {
  final Map<String, String> _headers = {
    'user-agent': userAgent,
    'accept': '*/*',
    'accept-encoding': 'gzip, deflate',
    'content-type': 'application/json',
    'content-encoding': 'gzip',
    'origin': domain,
    'cookie': 'CONSENT=YES+1',
  };

  final Map<String, dynamic> _context = {
    'context': {
      'client': {
        "clientName": "WEB_REMIX",
        "clientVersion": "1.20230213.01.00",
      },
      'user': {}
    }
  };

  @override
  void onInit() {
    init();
    super.onInit();
  }

  final dio = Dio();

  /// -------------------- Queue Variables --------------------
  List<dynamic> _queue = []; // Tracks queued songs
  int _queueIndex = 0; // Position in queue

  /// -------------------- Init Method --------------------
  Future<void> init() async {
    final date = DateTime.now();
    _context['context']['client']['clientVersion'] =
        "1.${date.year}${date.month.toString().padLeft(2, '0')}${date.day.toString().padLeft(2, '0')}.01.00";
    final signatureTimestamp = getDatestamp() - 1;
    _context['playbackContext'] = {
      'contentPlaybackContext': {'signatureTimestamp': signatureTimestamp},
    };

    final appPrefsBox = Hive.box('AppPrefs');
    hlCode = appPrefsBox.get('contentLanguage') ?? "en";
    if (appPrefsBox.containsKey('visitorId')) {
      final visitorData = appPrefsBox.get("visitorId");
      if (visitorData != null && !isExpired(epoch: visitorData['exp'])) {
        _headers['X-Goog-Visitor-Id'] = visitorData['id'];
        appPrefsBox.put("visitorId", {
          'id': visitorData['id'],
          'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 2590200
        });
        return;
      }
    }

    final visitorId = await genrateVisitorId();
    _headers['X-Goog-Visitor-Id'] =
        visitorId ?? "CgttN24wcmd5UzNSWSi2lvq2BjIKCgJKUBIEGgAgYQ%3D%3D";
    if (visitorId != null) {
      appPrefsBox.put("visitorId", {
        'id': visitorId,
        'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 2592000
      });
    }
  }

  set hlCode(String code) {
    _context['context']['client']['hl'] = code;
  }

  Future<String?> genrateVisitorId() async {
    try {
      final response =
          await dio.get(domain, options: Options(headers: _headers));
      final reg = RegExp(r'ytcfg\.set\s*\(\s*({.+?})\s*\)\s*;');
      final matches = reg.firstMatch(response.data.toString());
      String? visitorId;
      if (matches != null) {
        final ytcfg = json.decode(matches.group(1).toString());
        visitorId = ytcfg['VISITOR_DATA']?.toString();
      }
      return visitorId;
    } catch (e) {
      return null;
    }
  }

  Future<Response> _sendRequest(String action, Map<dynamic, dynamic> data,
      {additionalParams = ""}) async {
    try {
      final response =
          await dio.post("$baseUrl$action$fixedParms$additionalParams",
              options: Options(
                headers: _headers,
              ),
              data: data);

      if (response.statusCode == 200) {
        return response;
      } else {
        return _sendRequest(action, data, additionalParams: additionalParams);
      }
    } on DioException catch (e) {
      printINFO("Error $e");
      throw NetworkError();
    }
  }

  /// -------------------- QUEUE METHODS --------------------
  dynamic getNextTrack({bool shuffle = false}) {
    if (_queueIndex < _queue.length) {
      return _queue[_queueIndex++];
    }

    if (shuffle && _queue.isNotEmpty) {
      final randomIndex = (DateTime.now().millisecondsSinceEpoch) % _queue.length;
      return _queue[randomIndex];
    }

    return null; // Queue finished
  }

  void addToQueue(List<dynamic> tracks, {bool addToTop = false}) {
    // Assign dateAdded to each track
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    for (var track in tracks) {
      track['dateAdded'] = timestamp;
    }

    if (addToTop) {
      _queue = [...tracks, ..._queue];
    } else {
      _queue.addAll(tracks);
    }
  }

  void clearQueue() {
    _queue.clear();
    _queueIndex = 0;
  }

  /// -------------------- PLAYLIST / SONG FETCH --------------------
  Future<Map<String, dynamic>> getWatchPlaylist(
      {String videoId = "",
      String? playlistId,
      int limit = 25,
      bool radio = false,
      bool shuffle = false,
      String? additionalParamsNext,
      bool onlyRelated = false}) async {
    final data = Map.from(_context);
    data['enablePersistentPlaylistPanel'] = true;
    data['isAudioOnly'] = true;
    data['tunerSettingValue'] = 'AUTOMIX_SETTING_NORMAL';

    if (videoId == "" && playlistId == null) {
      throw Exception(
          "You must provide either a video id, a playlist id, or both");
    }

    if (videoId != "") {
      data['videoId'] = videoId;
      playlistId ??= "RDAMVM$videoId";

      if (!(radio || shuffle)) {
        data['watchEndpointMusicSupportedConfigs'] = {
          'watchEndpointMusicConfig': {
            'hasPersistentPlaylistPanel': true,
            'musicVideoType': "MUSIC_VIDEO_TYPE_ATV",
          }
        };
      }
    }

    playlistId = validatePlaylistId(playlistId!);
    data['playlistId'] = playlistId;
    final isPlaylist =
        playlistId.startsWith('PL') || playlistId.startsWith('OLA');

    if (shuffle) {
      data['params'] = "wAEB8gECKAE%3D";
    }
    if (radio) {
      data['params'] = "wAEB";
    }

    final List<dynamic> tracks = [];

    if (additionalParamsNext == null) {
      final response = (await _sendRequest("next", data)).data;
      final watchNextRenderer = nav(response, [
        'contents',
        'singleColumnMusicWatchNextResultsRenderer',
        'tabbedRenderer',
        'watchNextTabbedResultsRenderer'
      ]);

      dynamic lyricsBrowseId, relatedBrowseId, playlist;
      lyricsBrowseId = getTabBrowseId(watchNextRenderer, 1);
      relatedBrowseId = getTabBrowseId(watchNextRenderer, 2);
      if (onlyRelated) {
        return {
          'lyrics': lyricsBrowseId,
          'related': relatedBrowseId,
        };
      }

      final results = nav(watchNextRenderer, [
        ...tab_content,
        'musicQueueRenderer',
        'content',
        'playlistPanelRenderer'
      ]);

      playlist = results['contents']
          .map((content) => nav(content,
              ['playlistPanelVideoRenderer', ...navigation_playlist_id]))
          .where((e) => e != null)
          .toList()
          .first;

      final fetchedTracks = parseWatchPlaylist(results['contents']);

      // ------------------- QUEUE ADD -------------------
      if (!shuffle) {
        addToQueue(fetchedTracks, addToTop: false); // Normal order
      } else {
        addToQueue(fetchedTracks, addToTop: true); // Shuffle later
      }

      tracks.addAll(fetchedTracks);
    }

    // ----------- CONTINUATIONS HANDLING -------------
    if (tracks.length < limit) {
      dynamic additionalParamsForNext;
      final x = await getContinuations(
          {}, 'playlistPanelContinuation', limit - tracks.length,
          (additionalParams) async =>
              (await _sendRequest("next", data,
                      additionalParams: additionalParams))
                  .data,
          parseWatchPlaylist,
          isAdditionparamReturnReq: true,
          additionalParams_: additionalParamsNext);

      additionalParamsForNext = x[1];
      tracks.addAll(List<dynamic>.from(x[0]));
    }

    // ------------------- SORT BY DATE ADDED -------------------
    tracks.sort((a, b) {
      final daA = a['dateAdded'] ?? 0;
      final daB = b['dateAdded'] ?? 0;
      return daB.compareTo(daA); // newest first
    });

    return {
      'tracks': tracks,
      'playlistId': playlist,
      'lyrics': null,
      'related': null,
    };
  }

  @override
  void onClose() {
    dio.close();
    super.onClose();
  }
}

class NetworkError extends Error {
  final message = "Network Error !";
}
