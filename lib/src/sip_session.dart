import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'constants.dart';
import 'sip_client.dart';
import 'rtc_session.dart';


class SIP_Session {
  final SIP_Client _sip;
  final RTCSession _session;
  final SIP_Originator _originator;

  SIP_Session(this._sip, this._session, this._originator);

  String get id => _session.id;
  String get target => _session.target;
  String get display_name => _session.display_name;
  String get uri {
    if (_session.remote_identity?.uri != null) {
      return _session.remote_identity!.uri!.toString();
    }
    final uri = _sip.configuration.sip_uri.clone();
    uri.user = target;
    return uri.toString();
  }

  RTCSession get session => _session;
  SIP_Originator get originator => _originator;
  SIP_Direction? get direction => _session.direction;
  RTCPeerConnection? get peer_connection => _session.connection;


  bool get isRemoteMicEnabled => _peerHasMediaLine('audio');
  bool get isRemoteVideoEnabled => _peerHasMediaLine('video');
  
  bool get isLocalMicEnabled => _session.isMicEnabled;
  bool get isLocalVideoEnabled => _session.isVideoEnabled;

  bool get isOnHoldEnabled => _session.isOnHold()[SIP_Originator.local] || _session.isOnHold()[SIP_Originator.remote];
  bool get isRemoteOnHoldEnabled => _session.isOnHold()[SIP_Originator.remote];
  bool get isLocalOnHoldEnabled => _session.isOnHold()[SIP_Originator.local];

  Future<bool> answer([bool voiceOnly = true, MediaStream? mediaStream, List<String>? headers]) async {
    _session.answer(voiceOnly, mediaStream, headers);

    for (var session in _sip.sessions.values) {
      if (session.id != session.id) {
        await session.setHoldEnabled(true);
      }
    }

    return true;
  }

  Future<bool> hangup([Map<String, dynamic>? options]) async {
    _session.terminate(options);
    return true;
  }

  Future<bool> setHoldEnabled(bool enabled) async {
    dynamic options = {}; // 'useUpdate': true
    return enabled ? _session.hold(options) : _session.unhold(options);
  }

  Future<bool> setMicEnabled(bool enabled) async {
    return _session.setMicEnabled(enabled);
  }

  Future<bool> setVideoEnabled(bool enabled) async {
    return _session.setVideoEnabled(enabled);
  }

  Future<bool> setAudioState(SIP_AudioEnum state) async { throw Exception('not inplemented yet'); }

  void sendDTMF(String tones, [Map<String, dynamic>? options]) {
    _session.sendDTMF(tones, options);
  }

  void toggleSpeaker({bool? speakerOn}) {
    // event.stream?.getAudioTracks().firstOrNull?.enableSpeakerphone(false);

    // if (_localStream != null && Platform.isAndroid || Platform.isIOS) {
    //   isSpeakerOn = speakerOn ?? !isSpeakerOn;
    //   _print('SPEAKER enableSpeakerphone(${isSpeakerOn})');
    //   _localStream?.getAudioTracks().firstOrNull?.enableSpeakerphone(isSpeakerOn);
    // }
  }

  void sendMessage(String body, [Map<String, dynamic>? options]) {
    options?.putIfAbsent('body', () => body);
    _session.sendRequest(SIP_Method.MESSAGE, options ?? <String, dynamic>{'body': body});
  }

  bool _peerHasMediaLine(String media) {
    if (_session.request == null) {
      return false;
    }

    bool peerHasMediaLine = false;
    Map<String, dynamic> sdp = _session.request.parseSDP();
    
    // Make sure sdp['media'] is an array, not the case if there is only one media.
    if (sdp['media'] is! List) {
      sdp['media'] = <dynamic>[sdp['media']];
    }

    // Go through all medias in SDP to find offered capabilities to answer with.
    for (Map<String, dynamic> m in sdp['media']) {
      if (media == 'audio' && m['type'] == 'audio') {
        peerHasMediaLine = true;
      }
      if (media == 'video' && m['type'] == 'video') {
        peerHasMediaLine = true;
      }
    }

    return peerHasMediaLine;
  }
}
