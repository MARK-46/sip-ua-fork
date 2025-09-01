import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:sdp_transform/sdp_transform.dart' as sdp_transform;

import 'sip_session.dart';
import 'constants.dart';
import 'dialog.dart';
import 'event_manager/event_manager.dart';
import 'event_manager/internal_events.dart';
import 'exceptions.dart' as Exceptions;
import 'logger.dart';
import 'name_addr_header.dart';
import 'request_sender.dart';
import 'rtc_session/dtmf.dart' as RTCSession_DTMF;
import 'rtc_session/dtmf.dart';
import 'rtc_session/info.dart' as RTCSession_Info;
import 'rtc_session/info.dart';
import 'sip_message.dart';
import 'timers.dart';
import 'transactions/transaction_base.dart';
import 'sip_client.dart';
import 'uri.dart';
import 'utils.dart' as utils;

class C {
  // RTCSession states.
  static const int STATUS_NULL = 0;
  static const int STATUS_INVITE_SENT = 1;
  static const int STATUS_1XX_RECEIVED = 2;
  static const int STATUS_INVITE_RECEIVED = 3;
  static const int STATUS_WAITING_FOR_ANSWER = 4;
  static const int STATUS_ANSWERED = 5;
  static const int STATUS_WAITING_FOR_ACK = 6;
  static const int STATUS_CANCELED = 7;
  static const int STATUS_TERMINATED = 8;
  static const int STATUS_CONFIRMED = 9;
}

/**
 * Local variables.
 */
const List<String?> holdMediaTypes = <String?>['audio', 'video'];

class SIPTimers {
  Timer? ackTimer;
  Timer? expiresTimer;
  Timer? invite2xxTimer;
  Timer? userNoAnswerTimer;
}

class RFC4028Timers {
  RFC4028Timers(this.enabled, this.refreshMethod, this.defaultExpires, this.currentExpires, this.running, this.refresher, this.timer);
  bool enabled;
  SIP_Method refreshMethod;
  int? defaultExpires;
  int? currentExpires;
  bool running;
  bool refresher;
  Timer? timer;
}

class RTCSession implements Owner {
  RTCSession(this._client, this._emitter) {
    // Session Timers (RFC 4028).
    _sessionTimers = RFC4028Timers(_client.configuration.session_timers, _client.configuration.session_refresh, SESSION_EXPIRES, null, false, false, null);
    receiveRequest = _receiveRequest;
  }

  final SIP_Client _client;
  final EventEmitter _emitter;

  String? _id;
  int _status = C.STATUS_NULL;
  Dialog? _dialog;
  final Map<String?, Dialog> _earlyDialogs = <String?, Dialog>{};
  String? _contact;
  String? _from_tag;

  // The RTCPeerConnection instance (public attribute).
  RTCPeerConnection? _connection;

  // Incoming/Outgoing request being currently processed.
  dynamic _request;

  // Cancel state for initial outgoing request.
  bool _is_canceled = false;
  String? _cancel_reason = '';

  // RTCSession confirmation flag.
  bool _is_confirmed = false;

  // Is late SDP being negotiated.
  bool _late_sdp = false;

  // Default rtcOfferConstraints and rtcAnswerConstrainsts (passed in connect() or answer()).
  Map<String, dynamic>? _rtcOfferConstraints;
  Map<String, dynamic>? _rtcAnswerConstraints;

  // Local MediaStream.
  MediaStream? _localMediaStream;
  bool _localMediaStreamLocallyGenerated = false;

  // Flag to indicate PeerConnection ready for actions.
  bool _rtcReady = true;

  // SIP Timers.
  final SIPTimers _timers = SIPTimers();

  // Session info.
  SIP_Direction? _direction;
  NameAddrHeader? _local_identity;
  NameAddrHeader? _remote_identity;
  DateTime? _start_time;
  DateTime? _end_time;

  // Mute/Hold state.
  bool _audioMuted = false;
  bool _videoMuted = false;
  bool _localHold = false;
  bool _remoteHold = false;

  late RFC4028Timers _sessionTimers;

  // Custom session empty object for high level use.
  Map<String, dynamic>? data = <String, dynamic>{};

  RTCIceGatheringState? _iceGatheringState;

  Future<void> dtmfFuture = (Completer<void>()..complete()).future;

  @override
  late Function(IncomingRequest) receiveRequest;

  /**
   * User API
   */

  String get id => _id ?? 'ID_PENDING';
  String get target => remote_identity?.uri?.user ?? 'unknown';
  String get display_name => remote_identity?.display_name ?? 'Unknown';

  dynamic get request => _request;
  String? get contact => _contact;

  RTCPeerConnection? get connection => _connection;
  SIP_Direction? get direction => _direction;

  NameAddrHeader? get local_identity => _local_identity;
  NameAddrHeader? get remote_identity => _remote_identity;

  DateTime? get start_time => _start_time;
  DateTime? get end_time => _end_time;

  bool get isMicEnabled => !_audioMuted;
  bool get isVideoEnabled => !_videoMuted;

  RTCDTMFSender get dtmfSender => _connection!.createDtmfSender(_localMediaStream!.getAudioTracks()[0]);

  @override
  int get TerminatedCode => C.STATUS_TERMINATED;

  @override
  SIP_Client get client => _client;

  @override
  int get status => _status;

  bool isInProgress() {
    switch (_status) {
      case C.STATUS_NULL:
      case C.STATUS_INVITE_SENT:
      case C.STATUS_1XX_RECEIVED:
      case C.STATUS_INVITE_RECEIVED:
      case C.STATUS_WAITING_FOR_ANSWER:
        return true;
      default:
        return false;
    }
  }

  bool isEstablished() {
    switch (_status) {
      case C.STATUS_ANSWERED:
      case C.STATUS_WAITING_FOR_ACK:
      case C.STATUS_CONFIRMED:
        return true;
      default:
        return false;
    }
  }

  bool isEnded() {
    switch (_status) {
      case C.STATUS_CANCELED:
      case C.STATUS_TERMINATED:
        return true;
      default:
        return false;
    }
  }

  Map<SIP_Originator, dynamic> isOnHold() {
    return <SIP_Originator, dynamic>{SIP_Originator.local: _localHold, SIP_Originator.remote: _remoteHold};
  }

  Future<void> connect(dynamic target, [bool voiceOnly = true, MediaStream? mediaStream, List<String>? headers]) async {
    logger.d('connect()');

    Map<String, dynamic> options = _options(voiceOnly);
    dynamic originalTarget = target;
    List<dynamic> extraHeaders = utils.cloneArray(options['extraHeaders']);
    Map<String, dynamic> mediaConstraints = options['mediaConstraints'] ?? <String, dynamic>{'audio': true, 'video': false};
    Map<String, dynamic> pcConfig = options['pcConfig'] ?? <String, dynamic>{'iceServers': <dynamic>[]};
    Map<String, dynamic> rtcConstraints = options['rtcConstraints'] ?? <String, dynamic>{};
    Map<String, dynamic> rtcOfferConstraints = options['rtcOfferConstraints'] ?? <String, dynamic>{};
    _rtcOfferConstraints = rtcOfferConstraints;
    _rtcAnswerConstraints = options['rtcAnswerConstraints'] ?? <String, dynamic>{};
    data = options['data'] ?? data;
    extraHeaders.addAll(headers ?? <String>[]);

    // Check target.
    if (target == null) {
      throw Exceptions.TypeError('Not enough arguments');
    }

    // Check Session Status.
    if (_status != C.STATUS_NULL) {
      throw Exceptions.InvalidStateError(_status);
    }

    // Check target validity.
    target = _client.normalizeTarget(target);
    if (target == null) {
      throw Exceptions.TypeError('Invalid target: $originalTarget');
    }

    // Session Timers.
    if (_sessionTimers.enabled) {
      if (utils.isDecimal(options['sessionTimersExpires'])) {
        if (options['sessionTimersExpires'] >= MIN_SESSION_EXPIRES) {
          _sessionTimers.defaultExpires = options['sessionTimersExpires'];
        } else {
          _sessionTimers.defaultExpires = SESSION_EXPIRES;
        }
      }
    }

    // Session parameter initialization.
    _from_tag = utils.newTag();

    // Set anonymous property.
    bool anonymous = options['anonymous'] ?? false;
    Map<String, dynamic> requestParams = <String, dynamic>{'from_tag': _from_tag};
    _client.contact!.anonymous = anonymous;
    _client.contact!.outbound = true;
    _contact = _client.contact.toString();

    if (anonymous) {
      requestParams['from_display_name'] = 'Anonymous';
      requestParams['from_uri'] = URI('sip', 'anonymous', 'anonymous.invalid');
      extraHeaders.add('P-Preferred-Identity: ${_client.configuration.sip_uri.toString()}');
      extraHeaders.add('Privacy: id');
    }

    extraHeaders.add('Contact: $_contact');
    extraHeaders.add('Content-Type: application/sdp');
    if (_sessionTimers.enabled) {
      extraHeaders.add('Session-Expires: ${_sessionTimers.defaultExpires}');
    }

    _request = InitialOutgoingInviteRequest(target, _client, requestParams, extraHeaders);

    _id = _request.call_id + _from_tag;

    // Create a RTCPeerConnection instance.
    await _createRTCConnection(pcConfig, rtcConstraints);

    // Set internal properties.
    _direction = SIP_Direction.outgoing;
    _local_identity = _request.from;
    _remote_identity = _request.to;

    _notifyOnOutgoing(SIP_Originator.local, request);

    await _sendInitialRequest(pcConfig, mediaConstraints, rtcOfferConstraints, mediaStream ?? options['mediaStream']);
  }

  void init_incoming(IncomingRequest request, [Function(RTCSession)? initCallback]) {
    logger.d('init_incoming()');

    int? expires;
    String? contentType = request.getHeader('Content-Type');

    // Check body and content type.
    if (request.body != null && (contentType != 'application/sdp')) {
      request.reply(415);
      return;
    }

    // Session parameter initialization.
    _status = C.STATUS_INVITE_RECEIVED;
    _from_tag = request.from_tag;
    _id = request.call_id! + _from_tag!;
    _request = request;
    _contact = _client.contact.toString();

    // Get the Expires header value if exists.
    if (request.hasHeader('expires')) {
      expires = request.getHeader('expires') * 1000;
    }

    /* Set the to_tag before
     * replying a response code that will create a dialog.
     */
    request.to_tag = utils.newTag();

    // An error on dialog creation will fire 'failed' event.
    if (!_createDialog(request, 'UAS', true)) {
      request.reply(500, 'Missing Contact header field');
      return;
    }

    if (request.body != null) {
      _late_sdp = false;
    } else {
      _late_sdp = true;
    }

    _status = C.STATUS_WAITING_FOR_ANSWER;

    // Set userNoAnswerTimer.
    _timers.userNoAnswerTimer = setTimeout(() {
      request.reply(408);
      _notifyOnFailed(SIP_Originator.local, 408, CausesType.NO_ANSWER, 'No Answer');
    }, _client.configuration.no_answer_timeout);

    /* Set expiresTimer
     * RFC3261 13.3.1
     */
    if (expires != null) {
      _timers.expiresTimer = setTimeout(() {
        if (_status == C.STATUS_WAITING_FOR_ANSWER) {
          request.reply(487);
          _notifyOnFailed(SIP_Originator.system, 487, CausesType.EXPIRES, 'Timeout');
        }
      }, expires);
    }

    // Set internal properties.
    _direction = SIP_Direction.incoming;
    _local_identity = request.to;
    _remote_identity = request.from;

    // A init callback was specifically defined.
    if (initCallback != null) {
      initCallback(this);
    }

    // Fire 'newRTCSession' event.
    _notifyOnIncoming(SIP_Originator.remote, request);

    // The user may have rejected the call in the 'newRTCSession' event.
    if (_status == C.STATUS_TERMINATED) {
      return;
    }

    // Reply 180.
    request.reply(180, null, <dynamic>['Contact: $_contact']);

    // Fire 'progress' event.
    // TODO(cloudwebrtc): Document that 'response' field in 'progress' event is null for incoming calls.
    _notifyOnProgress(SIP_Originator.local, null);
  }

  Future<bool> answer([bool voiceOnly = true, MediaStream? mediaStream, List<String>? headers]) async {
    logger.d('connect()');

    Map<String, dynamic> options = _options(voiceOnly);
    logger.d('answer()');

    dynamic request = _request;
    List<dynamic> extraHeaders = utils.cloneArray(options['extraHeaders']);
    extraHeaders.addAll(headers ?? <String>[]);

    Map<String, dynamic> mediaConstraints = options['mediaConstraints'] ?? <String, dynamic>{};
    MediaStream? localMediaStream = mediaStream ?? options['mediaStream'] ?? null;
    Map<String, dynamic> pcConfig = options['pcConfig'] ?? <String, dynamic>{'iceServers': <dynamic>[]};
    Map<String, dynamic> rtcConstraints = options['rtcConstraints'] ?? <String, dynamic>{};
    Map<String, dynamic> rtcAnswerConstraints = options['rtcAnswerConstraints'] ?? <String, dynamic>{};

    List<MediaStreamTrack> tracks;
    bool peerHasAudioLine = false;
    bool peerHasVideoLine = false;
    bool peerOffersFullAudio = false;
    bool peerOffersFullVideo = false;

    // In future versions, unified-plan will be used by default
    String? sdpSemantics = 'unified-plan';
    if (pcConfig['sdpSemantics'] != null) {
      sdpSemantics = pcConfig['sdpSemantics'];
    }

    _rtcAnswerConstraints = rtcAnswerConstraints;
    _rtcOfferConstraints = options['rtcOfferConstraints'] ?? null;

    data = options['data'] ?? data;

    // Check Session SIP_Direction and Status.
    if (_direction != SIP_Direction.incoming) {
      throw Exceptions.NotSupportedError('"answer" not supported for outgoing RTCSession');
    }

    // Check Session status.
    if (_status != C.STATUS_WAITING_FOR_ANSWER) {
      throw Exceptions.InvalidStateError(_status);
    }

    // Session Timers.
    if (_sessionTimers.enabled) {
      if (utils.isDecimal(options['sessionTimersExpires'])) {
        if (options['sessionTimersExpires'] >= MIN_SESSION_EXPIRES) {
          _sessionTimers.defaultExpires = options['sessionTimersExpires'];
        } else {
          _sessionTimers.defaultExpires = SESSION_EXPIRES;
        }
      }
    }

    _status = C.STATUS_ANSWERED;

    // An error on dialog creation will fire 'failed' event.
    if (!_createDialog(request, 'UAS')) {
      request.reply(500, 'Error creating dialog');

      return false;
    }

    clearTimeout(_timers.userNoAnswerTimer);
    extraHeaders.insert(0, 'Contact: $_contact');

    // Determine incoming media from incoming SDP offer (if any).
    Map<String, dynamic> sdp = request.parseSDP();

    // Make sure sdp['media'] is an array, not the case if there is only one media.
    if (sdp['media'] is! List) {
      sdp['media'] = <dynamic>[sdp['media']];
    }

    // Go through all medias in SDP to find offered capabilities to answer with.
    for (Map<String, dynamic> m in sdp['media']) {
      if (m['type'] == 'audio') {
        peerHasAudioLine = true;
        if (m['direction'] == null || m['direction'] == 'sendrecv') {
          peerOffersFullAudio = true;
        }
      }
      if (m['type'] == 'video') {
        peerHasVideoLine = true;
        if (m['direction'] == null || m['direction'] == 'sendrecv') {
          peerOffersFullVideo = true;
        }
      }
    }

    // Remove audio from mediaStream if suggested by mediaConstraints.
    if (localMediaStream != null && mediaConstraints['audio'] == false) {
      tracks = localMediaStream.getAudioTracks();
      for (MediaStreamTrack track in tracks) {
        localMediaStream.removeTrack(track);
      }
    }

    // Remove video from mediaStream if suggested by mediaConstraints.
    if (localMediaStream != null && mediaConstraints['video'] == false) {
      tracks = localMediaStream.getVideoTracks();
      for (MediaStreamTrack track in tracks) {
        localMediaStream.removeTrack(track);
      }
    }

    // Set audio constraints based on incoming stream if not supplied.
    if (localMediaStream == null && mediaConstraints['audio'] == null) {
      mediaConstraints['audio'] = peerOffersFullAudio;
    }

    // Set video constraints based on incoming stream if not supplied.
    if (localMediaStream == null && mediaConstraints['video'] == null) {
      mediaConstraints['video'] = peerOffersFullVideo;
    }

    // Don't ask for audio if the incoming offer has no audio section.
    if (localMediaStream == null && !peerHasAudioLine) {
      mediaConstraints['audio'] = false;
    }

    // Don't ask for video if the incoming offer has no video section.
    if (localMediaStream == null && !peerHasVideoLine) {
      mediaConstraints['video'] = false;
    }

    // Create a RTCPeerConnection instance.
    // TODO(cloudwebrtc): This may throw an error, should react.
    await _createRTCConnection(pcConfig, rtcConstraints);

    MediaStream? stream;
    // A local MediaStream is given, use it.
    if (localMediaStream != null) {
      stream = localMediaStream;
      _notifyOnStream(SIP_Originator.local, stream);
    }
    // Audio and/or video requested, prompt getUserMedia.
    else if (mediaConstraints['audio'] != null || mediaConstraints['video'] != null) {
      _localMediaStreamLocallyGenerated = true;
      try {
        stream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
        _notifyOnStream(SIP_Originator.local, stream);
      } catch (error) {
        if (_status == C.STATUS_TERMINATED) {
          throw Exceptions.InvalidStateError('terminated');
        }
        request.reply(480);
        _notifyOnFailed(SIP_Originator.local, 480, CausesType.USER_DENIED_MEDIA_ACCESS, 'User Denied Media Access');
        logger.e('emit "getusermediafailed" [error:${error.toString()}]');
        throw Exceptions.InvalidStateError('getUserMedia() failed');
      }
    }

    if (_status == C.STATUS_TERMINATED) {
      throw Exceptions.InvalidStateError('terminated');
    }

    // Attach MediaStream to RTCPeerconnection.
    _localMediaStream = stream;

    if (stream != null) {
      switch (sdpSemantics) {
        case 'unified-plan':
          stream.getTracks().forEach((MediaStreamTrack track) {
            _connection!.addTrack(track, stream!);
          });
          break;
        case 'plan-b':
          _connection!.addStream(stream);
          break;
        default:
          logger.e('Unkown sdp semantics $sdpSemantics');
          throw Exceptions.NotReadyError('Unkown sdp semantics $sdpSemantics');
      }
    }

    // Set remote description.
    if (_late_sdp) {
      return false;
    }

    logger.d('emit "sdp"');

    RTCSessionDescription offer = RTCSessionDescription(request.body, 'offer');
    try {
      await _connection!.setRemoteDescription(offer);
    } catch (error) {
      request.reply(488);
      _notifyOnFailed(SIP_Originator.system, 488, CausesType.WEBRTC_ERROR, 'SetRemoteDescription(offer) failed');
      logger.e('emit "peerconnection:setremotedescriptionfailed" [error:${error.toString()}]');
      throw Exceptions.TypeError('peerconnection.setRemoteDescription() failed');
    }

    // Create local description.
    if (_status == C.STATUS_TERMINATED) {
      throw Exceptions.InvalidStateError('terminated');
    }

    // TODO(cloudwebrtc): Is this event already useful?
    _notifyOnConnecting(SIP_Originator.remote, request);

    RTCSessionDescription desc;
    try {
      if (!_late_sdp) {
        desc = await _createLocalDescription('answer', rtcAnswerConstraints);
      } else {
        desc = await _createLocalDescription('offer', _rtcOfferConstraints);
      }
    } catch (e) {
      request.reply(500);
      throw Exceptions.TypeError('_createLocalDescription() failed');
    }

    if (_status == C.STATUS_TERMINATED) {
      throw Exceptions.InvalidStateError('terminated');
    }

    // Send reply.
    try {
      _handleSessionTimersInIncomingRequest(request, extraHeaders);
      request.reply(200, null, extraHeaders, desc.sdp, () {
        _status = C.STATUS_WAITING_FOR_ACK;
        _setInvite2xxTimer(request, desc.sdp);
        _setACKTimer();
        _notifyOnAccepted(SIP_Originator.local);
      }, () {
        _notifyOnFailed(SIP_Originator.system, 500, CausesType.CONNECTION_ERROR, 'SIP_SocketInterface Error');
      });
    } catch (error, s) {
      if (_status == C.STATUS_TERMINATED) {
        return false;
      }
      logger.e('Failed to answer(): ${error.toString()}', error: error, stackTrace: s);
    }
    return true;
  }

  void terminate([Map<String, dynamic>? options]) {
    logger.d('terminate()');

    options = options ?? <String, dynamic>{};

    Object cause = options['cause'] ?? CausesType.BYE;

    List<dynamic> extraHeaders = options['extraHeaders'] != null ? utils.cloneArray(options['extraHeaders']) : <dynamic>[];
    Object? body = options['body'];

    String? cancel_reason;
    int? status_code = options['status_code'] as int?;
    String? reason_phrase = options['reason_phrase'] as String?;

    // Check Session Status.
    if (_status == C.STATUS_TERMINATED) {
      throw Exceptions.InvalidStateError(_status);
    }

    switch (_status) {
      // - UAC -
      case C.STATUS_NULL:
      case C.STATUS_INVITE_SENT:
      case C.STATUS_1XX_RECEIVED:
        logger.d('canceling session');

        if (status_code != null && (status_code < 200 || status_code >= 700)) {
          throw Exceptions.TypeError('Invalid status_code: $status_code');
        } else if (status_code != null) {
          reason_phrase = reason_phrase ?? REASON_PHRASE[status_code];
          cancel_reason = 'SIP ;cause=$status_code ;text="$reason_phrase"';
        }

        // Check Session Status.
        if (_status == C.STATUS_NULL || _status == C.STATUS_INVITE_SENT) {
          _is_canceled = true;
          _cancel_reason = cancel_reason;
        } else if (_status == C.STATUS_1XX_RECEIVED) {
          _request.cancel(cancel_reason ?? '');
        }

        _status = C.STATUS_CANCELED;
        cancel_reason = cancel_reason ?? 'Canceled by local';
        status_code = status_code ?? 100;
        _notifyOnFailed(SIP_Originator.local, status_code, CausesType.CANCELED, cancel_reason);
        break;

      // - UAS -
      case C.STATUS_WAITING_FOR_ANSWER:
      case C.STATUS_ANSWERED:
        logger.d('rejecting session');

        status_code = status_code ?? 480;

        if (status_code < 300 || status_code >= 700) {
          throw Exceptions.InvalidStateError('Invalid status_code: $status_code');
        }

        _request.reply(status_code, reason_phrase, extraHeaders, body);
        _notifyOnFailed(SIP_Originator.local, status_code, CausesType.REJECTED, reason_phrase);
        break;

      case C.STATUS_WAITING_FOR_ACK:
      case C.STATUS_CONFIRMED:
        logger.d('terminating session');

        reason_phrase = options['reason_phrase'] as String? ?? REASON_PHRASE[status_code ?? 0];

        if (status_code != null && (status_code < 200 || status_code >= 700)) {
          throw Exceptions.InvalidStateError('Invalid status_code: $status_code');
        } else if (status_code != null) {
          extraHeaders.add('Reason: SIP ;case=$status_code; text="$reason_phrase"');
        }

        /* RFC 3261 section 15 (Terminating a session):
          *
          * "...the callee's SIP_Client MUST NOT send a BYE on a confirmed dialog
          * until it has received an ACK for its 2xx response or until the server
          * transaction times out."
          */
        if (_status == C.STATUS_WAITING_FOR_ACK && _direction == SIP_Direction.incoming && _request.server_transaction.state != TransactionState.TERMINATED) {
          /// Save the dialog for later restoration.
          Dialog dialog = _dialog!;

          // Send the BYE as soon as the ACK is received...
          receiveRequest = (IncomingMessage request) {
            if (request.method == SIP_Method.ACK) {
              sendRequest(SIP_Method.BYE, <String, dynamic>{'extraHeaders': extraHeaders, 'body': body});
              dialog.terminate();
            }
          };

          // .., or when the INVITE transaction times out
          _request.server_transaction.on(EventStateChanged(), (EventStateChanged state) {
            if (_request.server_transaction.state == TransactionState.TERMINATED) {
              sendRequest(SIP_Method.BYE, <String, dynamic>{'extraHeaders': extraHeaders, 'body': body});
              dialog.terminate();
            }
          });

          _notifyOnEnded(SIP_Originator.local, ErrorCause(cause: cause as String?, status_code: status_code, reason_phrase: reason_phrase));

          // Restore the dialog into 'this' in order to be able to send the in-dialog BYE :-).
          _dialog = dialog;

          // Restore the dialog into 'client' so the ACK can reach 'this' session.
          _client.newDialog(dialog);
        } else {
          sendRequest(SIP_Method.BYE, <String, dynamic>{'extraHeaders': extraHeaders, 'body': body});
          reason_phrase = reason_phrase ?? 'Terminated by local';
          status_code = status_code ?? 200;
          _notifyOnEnded(SIP_Originator.local, ErrorCause(cause: cause as String?, status_code: status_code, reason_phrase: reason_phrase));
        }
    }
  }

  void sendDTMF(dynamic tones, [Map<String, dynamic>? options]) {
    logger.d('sendDTMF() | tones: ${tones.toString()}');

    options = options ?? <String, dynamic>{};

    SIP_DTMFMode mode = _client.configuration.dtmf_mode;

    // sensible defaults
    int duration = options['duration'] ?? RTCSession_DTMF.C.DEFAULT_DURATION;
    int interToneGap = options['interToneGap'] ?? RTCSession_DTMF.C.DEFAULT_INTER_TONE_GAP;

    if (tones == null) {
      throw Exceptions.TypeError('Not enough arguments');
    }

    // Check Session Status.
    if (_status != C.STATUS_CONFIRMED && _status != C.STATUS_WAITING_FOR_ACK) {
      throw Exceptions.InvalidStateError(_status);
    }

    // Convert to string.
    if (tones is num) {
      tones = tones.toString();
    }

    // Check tones.
    if (tones == null || tones is! String || !tones.contains(RegExp(r'^[0-9A-DR#*,]+$', caseSensitive: false))) {
      throw Exceptions.TypeError('Invalid tones: ${tones.toString()}');
    }

    // Check duration.
    if (duration == null) {
      duration = RTCSession_DTMF.C.DEFAULT_DURATION;
    } else if (duration < RTCSession_DTMF.C.MIN_DURATION) {
      logger.d('"duration" value is lower than the minimum allowed, setting it to ${RTCSession_DTMF.C.MIN_DURATION} milliseconds');
      duration = RTCSession_DTMF.C.MIN_DURATION;
    } else if (duration > RTCSession_DTMF.C.MAX_DURATION) {
      logger.d('"duration" value is greater than the maximum allowed, setting it to ${RTCSession_DTMF.C.MAX_DURATION} milliseconds');
      duration = RTCSession_DTMF.C.MAX_DURATION;
    } else {
      duration = duration.abs();
    }
    options['duration'] = duration;

    // Check interToneGap.
    if (interToneGap == null) {
      interToneGap = RTCSession_DTMF.C.DEFAULT_INTER_TONE_GAP;
    } else if (interToneGap < RTCSession_DTMF.C.MIN_INTER_TONE_GAP) {
      logger.d('"interToneGap" value is lower than the minimum allowed, setting it to ${RTCSession_DTMF.C.MIN_INTER_TONE_GAP} milliseconds');
      interToneGap = RTCSession_DTMF.C.MIN_INTER_TONE_GAP;
    } else {
      interToneGap = interToneGap.abs();
    }

    options['interToneGap'] = interToneGap;

    //// ***************** and follows the actual code to queue DTMF tone(s) **********************

    ///using dtmfFuture to queue the playing of the tones

    for (int i = 0; i < tones.length; i++) {
      String tone = tones[i];
      if (tone == ',') {
        // queue the delay
        dtmfFuture = dtmfFuture.then((_) async {
          if (_status == C.STATUS_TERMINATED) {
            return;
          }
          await Future<void>.delayed(Duration(milliseconds: 2000), () {});
        });
      } else {
        // queue playing the tone
        dtmfFuture = dtmfFuture.then((_) async {
          if (_status == C.STATUS_TERMINATED) {
            return;
          }

          RTCSession_DTMF.DTMF dtmf = RTCSession_DTMF.DTMF(this, mode: mode);

          EventManager handlers = EventManager();
          handlers.on(EventCallFailed(), (EventCallFailed event) {
            logger.e('Failed to send DTMF ${event.cause}');
          });

          options!['eventHandlers'] = handlers;

          dtmf.send(tone, options);
          await Future<void>.delayed(Duration(milliseconds: duration + interToneGap), () {});
        });
      }
    }
  }

  void sendInfo(String contentType, String body, Map<String, dynamic> options) {
    logger.d('sendInfo()');

    // Check Session Status.
    if (_status != C.STATUS_CONFIRMED && _status != C.STATUS_WAITING_FOR_ACK) {
      throw Exceptions.InvalidStateError(_status);
    }

    RTCSession_Info.Info info = RTCSession_Info.Info(this);

    info.send(contentType, body, options);
  }

  bool setMicEnabled(bool enabled) {
      logger.d('setMicEnabled($enabled)');
    if ((_localHold || _remoteHold) && enabled) {
      logger.d('setMicEnabled(skip)');
      return false; // skip if in hold
    }

    if (_localMediaStream != null) {
      for (MediaStreamTrack track in _localMediaStream!.getAudioTracks()) {
        track.enabled = enabled;
      }
    }

    _audioMuted = !enabled;
    _notifyOnStream(SIP_Originator.local, _localMediaStream!);
    
    return true;
  }

  bool setVideoEnabled(bool enabled) {
      logger.d('setVideoEnabled($enabled)');
    if ((_localHold || _remoteHold) && enabled) {
      logger.d('setVideoEnabled(skip)');
      return false; // skip if in hold
    }

    if (_localMediaStream != null) {
      for (MediaStreamTrack track in _localMediaStream!.getVideoTracks()) {
        track.enabled = enabled;
      }
    }
    
    _videoMuted = !enabled;
    _notifyOnStream(SIP_Originator.local, _localMediaStream!);
    
    return true;
  }

  /**
   * Hold
   */
  Future<bool> hold([Map<String, dynamic>? options]) async {
    final completer = Completer<bool>();
    logger.d('hold()');

    options = options ?? <String, dynamic>{};

    if (_status != C.STATUS_WAITING_FOR_ACK && _status != C.STATUS_CONFIRMED) {
      return Future.value(false);
    }

    if (_localHold == true) {
      return Future.value(false);
    }

    if (!_isReadyToReOffer()) {
      return Future.value(false);
    }

    _localHold = true;

    EventManager handlers = EventManager();

    handlers.on(EventSucceeded(), (EventSucceeded event) {
      if (completer.isCompleted) {
        completer.complete(true);
      }
    });

    handlers.on(EventCallFailed(), (EventCallFailed event) {
      terminate(<String, dynamic>{'cause': CausesType.WEBRTC_ERROR, 'status_code': 500, 'reason_phrase': event.cause?.cause ?? 'Hold Failed'});
      if (completer.isCompleted) {
        completer.complete(false);
      }
    });

    if (options['useUpdate'] != null) {
      _sendUpdate(<String, dynamic>{'sdpOffer': true, 'eventHandlers': handlers, 'extraHeaders': options['extraHeaders']});
    } else {
      _sendReinvite(<String, dynamic>{'eventHandlers': handlers, 'extraHeaders': options['extraHeaders']});
    }


    if (await completer.future == false) {
      return false;
    }

    _notifyOnHold(SIP_Originator.local);
    return true;
  }

  Future<bool> unhold([Map<String, dynamic>? options]) async {
    final completer = Completer<bool>();
    logger.d('unhold()');

    options = options ?? <String, dynamic>{};

    if (_status != C.STATUS_WAITING_FOR_ACK && _status != C.STATUS_CONFIRMED) {
      return Future.value(false);
    }

    if (_localHold == false) {
      return Future.value(false);
    }

    if (!_isReadyToReOffer()) {
      return Future.value(false);
    }

    _localHold = false;

    EventManager handlers = EventManager();
    handlers.on(EventSucceeded(), (EventSucceeded event) {
      if (completer.isCompleted) {
        completer.complete(true);
      }
    });

    handlers.on(EventCallFailed(), (EventCallFailed event) {
      if (completer.isCompleted) {
        completer.complete(false);
      }
      terminate(<String, dynamic>{'cause': CausesType.WEBRTC_ERROR, 'status_code': 500, 'reason_phrase': 'Unhold Failed'});
    });

    if (options['useUpdate'] != null) {
      _sendUpdate(<String, dynamic>{'sdpOffer': true, 'eventHandlers': handlers, 'extraHeaders': options['extraHeaders']});
    } else {
      _sendReinvite(<String, dynamic>{'eventHandlers': handlers, 'extraHeaders': options['extraHeaders']});
    }
    
    if (await completer.future == false) {
      return false;
    }

    _notifyOnUnhold(SIP_Originator.local);
    return true;
  }

  /**
   * Send a generic in-dialog Request
   */
  OutgoingRequest sendRequest(SIP_Method method, [Map<String, dynamic>? options]) {
    logger.d('sendRequest()');

    return _dialog!.sendRequest(method, options);
  }

  Future<bool> _renegotiate(Map<String, dynamic> options) async {
    final completer = Completer<bool>();
    logger.d('renegotiate()');

    Map<String, dynamic>? rtcOfferConstraints = options['rtcOfferConstraints'] ?? _rtcOfferConstraints;

    if (_status != C.STATUS_WAITING_FOR_ACK && _status != C.STATUS_CONFIRMED) {
      return Future.value(false);
    }

    if (!_isReadyToReOffer()) {
      return Future.value(false);
    }

    EventManager handlers = EventManager();
    handlers.on(EventSucceeded(), (EventSucceeded event) {
      if (completer.isCompleted) {
        completer.complete(true);
      }
    });

    handlers.on(EventCallFailed(), (EventCallFailed event) {
      if (completer.isCompleted) {
        completer.complete(false);
      }
      terminate(<String, dynamic>{'cause': CausesType.WEBRTC_ERROR, 'status_code': 500, 'reason_phrase': 'Media Renegotiation Failed'});
    });

    if (options['useUpdate'] != null) {
      _sendUpdate(<String, dynamic>{'sdpOffer': true, 'eventHandlers': handlers, 'rtcOfferConstraints': rtcOfferConstraints, 'extraHeaders': options['extraHeaders']});
    } else {
      _sendReinvite(<String, dynamic>{'eventHandlers': handlers, 'rtcOfferConstraints': rtcOfferConstraints, 'extraHeaders': options['extraHeaders']});
    }

    return completer.future;
  }

  /**
   * In dialog Request Reception
   */
  void _receiveRequest(IncomingRequest request) async {
    logger.d('receiveRequest()');

    if (request.method == SIP_Method.CANCEL) {
      /* RFC3261 15 States that a UAS may have accepted an invitation while a CANCEL
      * was in progress and that the UAC MAY continue with the session established by
      * any 2xx response, or MAY terminate with BYE. DartSIP does continue with the
      * established session. So the CANCEL is processed only if the session is not yet
      * established.
      */

      /*
      * Terminate the whole session in case the user didn't accept (or yet send the answer)
      * nor reject the request opening the session.
      */
      if (_status == C.STATUS_WAITING_FOR_ANSWER || _status == C.STATUS_ANSWERED) {
        _status = C.STATUS_CANCELED;
        _request.reply(487);
        _notifyOnFailed(SIP_Originator.remote, 487, CausesType.CANCELED, request.reason_phrase);
      }
    } else {
      // Requests arriving here are in-dialog requests.
      switch (request.method) {
        case SIP_Method.ACK:
          if (_status != C.STATUS_WAITING_FOR_ACK) {
            return;
          }
          // Update signaling status.
          _status = C.STATUS_CONFIRMED;
          clearTimeout(_timers.ackTimer);
          clearTimeout(_timers.invite2xxTimer);

          if (_late_sdp) {
            if (request.body == null) {
              terminate(<String, dynamic>{'cause': CausesType.MISSING_SDP, 'status_code': 400});
              break;
            }

            logger.d('emit "sdp"');

            RTCSessionDescription answer = RTCSessionDescription(request.body, 'answer');
            try {
              await _connection!.setRemoteDescription(answer);
            } catch (error) {
              terminate(<String, dynamic>{'cause': CausesType.BAD_MEDIA_DESCRIPTION, 'status_code': 488});
              logger.e('emit "peerconnection:setremotedescriptionfailed" [error:${error.toString()}]');
            }
          }
          if (!_is_confirmed) {
            _notifyOnConfirmed(SIP_Originator.remote, request);
          }
          break;
        case SIP_Method.BYE:
          if (_status == C.STATUS_CONFIRMED) {
            request.reply(200);
            _notifyOnEnded(SIP_Originator.remote, ErrorCause(cause: CausesType.BYE, status_code: 200, reason_phrase: 'BYE Received'));
          } else if (_status == C.STATUS_INVITE_RECEIVED) {
            request.reply(200);
            _request.reply(487, 'BYE Received');
            _notifyOnEnded(SIP_Originator.remote, ErrorCause(cause: CausesType.BYE, status_code: request.status_code, reason_phrase: request.reason_phrase));
          } else {
            request.reply(403, 'Wrong Status');
          }
          break;
        case SIP_Method.INVITE:
          if (_status == C.STATUS_CONFIRMED) {
            if (request.hasHeader('replaces')) {
              _receiveReplaces(request);
            } else {
              _receiveReinvite(request);
            }
          } else {
            request.reply(403, 'Wrong Status');
          }
          break;
        case SIP_Method.INFO:
          if (_status == C.STATUS_1XX_RECEIVED || _status == C.STATUS_WAITING_FOR_ANSWER || _status == C.STATUS_ANSWERED || _status == C.STATUS_WAITING_FOR_ACK || _status == C.STATUS_CONFIRMED) {
            String? contentType = request.getHeader('content-type');
            if (contentType != null && contentType.contains(RegExp(r'^application\/dtmf-relay', caseSensitive: false))) {
              RTCSession_DTMF.DTMF(this).init_incoming(request);
            } else if (contentType != null) {
              RTCSession_Info.Info(this).init_incoming(request);
            } else {
              request.reply(415);
            }
          } else {
            request.reply(403, 'Wrong Status');
          }
          break;
        case SIP_Method.UPDATE:
          if (_status == C.STATUS_CONFIRMED) {
            _receiveUpdate(request);
          } else {
            request.reply(403, 'Wrong Status');
          }
          break;
        case SIP_Method.REFER:
          request.reply(420, 'Not Supported');
          break;
        case SIP_Method.NOTIFY:
          if (_status == C.STATUS_CONFIRMED) {
            _receiveNotify(request);
          } else {
            request.reply(403, 'Wrong Status');
          }
          break;
        default:
          request.reply(501);
      }
    }
  }

  /**
   * Session Callbacks
   */
  void onTransportError() {
    logger.e('onTransportError()');
    if (_status != C.STATUS_TERMINATED) {
      terminate(<String, dynamic>{'status_code': 500, 'reason_phrase': CausesType.CONNECTION_ERROR, 'cause': CausesType.CONNECTION_ERROR});
    }
  }

  void onRequestTimeout() {
    logger.e('onRequestTimeout()');

    if (_status != C.STATUS_TERMINATED) {
      terminate(<String, dynamic>{'status_code': 408, 'reason_phrase': CausesType.REQUEST_TIMEOUT, 'cause': CausesType.REQUEST_TIMEOUT});
    }
  }

  void onDialogError() {
    logger.e('onDialogError()');

    if (_status != C.STATUS_TERMINATED) {
      terminate(<String, dynamic>{'status_code': 500, 'reason_phrase': CausesType.DIALOG_ERROR, 'cause': CausesType.DIALOG_ERROR});
    }
  }

  // Called from DTMF handler.
  void newDTMF(SIP_Originator originator, DTMF dtmf, dynamic request) {
    logger.d('newDTMF()');
  }

  // Called from Info handler.
  void newInfo(SIP_Originator originator, Info info, dynamic request) {
    logger.d('newInfo()');
  }

  /**
   * Check if RTCSession is ready for an outgoing re-INVITE or UPDATE with SDP.
   */
  bool _isReadyToReOffer() {
    if (!_rtcReady) {
      logger.d('_isReadyToReOffer() | internal WebRTC status not ready');

      return false;
    }

    // No established yet.
    if (_dialog == null) {
      logger.d('_isReadyToReOffer() | session not established yet');

      return false;
    }

    // Another INVITE transaction is in progress.
    if (_dialog!.uac_pending_reply == true || _dialog!.uas_pending_reply == true) {
      logger.d('_isReadyToReOffer() | there is another INVITE/UPDATE transaction in progress');

      return false;
    }

    return true;
  }

  void _close() async {
    logger.d('close()');
    if (_status == C.STATUS_TERMINATED) {
      return;
    }
    _status = C.STATUS_TERMINATED;
    // Terminate RTC.
    if (_connection != null) {
      try {
        await _connection!.close();
        await _connection!.dispose();
        _connection = null;
      } catch (error) {
        logger.e('close() | error closing the RTCPeerConnection: ${error.toString()}');
      }
    }
    // Close local MediaStream if it was not given by the user.
    if (_localMediaStream != null && _localMediaStreamLocallyGenerated) {
      logger.d('close() | closing local MediaStream');
      await _localMediaStream!.dispose();
      _localMediaStream = null;
    }

    // Terminate signaling.

    // Clear SIP timers.
    clearTimeout(_timers.ackTimer);
    clearTimeout(_timers.expiresTimer);
    clearTimeout(_timers.invite2xxTimer);
    clearTimeout(_timers.userNoAnswerTimer);

    // Clear Session Timers.
    clearTimeout(_sessionTimers.timer);

    // Terminate confirmed dialog.
    if (_dialog != null) {
      _dialog!.terminate();
      _dialog = null;
    }

    // Terminate early dialogs.
    _earlyDialogs.forEach((String? key, _) {
      _earlyDialogs[key]!.terminate();
    });
    _earlyDialogs.clear();
  }

  /**
   * Private API.
   */

  /**
   * RFC3261 13.3.1.4
   * Response retransmissions cannot be accomplished by transaction layer
   *  since it is destroyed when receiving the first 2xx answer
   */
  void _setInvite2xxTimer(dynamic request, String? body) {
    int timeout = Timers.T1;

    void invite2xxRetransmission() {
      if (_status != C.STATUS_WAITING_FOR_ACK) {
        return;
      }
      request.reply(200, null, <String>['Contact: $_contact'], body);
      if (timeout < Timers.T2) {
        timeout = timeout * 2;
        if (timeout > Timers.T2) {
          timeout = Timers.T2;
        }
      }
      _timers.invite2xxTimer = setTimeout(invite2xxRetransmission, timeout);
    }

    _timers.invite2xxTimer = setTimeout(invite2xxRetransmission, timeout);
  }

  /**
   * RFC3261 14.2
   * If a UAS generates a 2xx response and never receives an ACK,
   *  it SHOULD generate a BYE to terminate the dialog.
   */
  void _setACKTimer() {
    _timers.ackTimer = setTimeout(() {
      if (_status == C.STATUS_WAITING_FOR_ACK) {
        logger.d('no ACK received, terminating the session');

        clearTimeout(_timers.invite2xxTimer);
        sendRequest(SIP_Method.BYE);
        _notifyOnEnded(
            SIP_Originator.remote,
            ErrorCause(
                cause: CausesType.NO_ACK,
                status_code: 408, // Request Timeout
                reason_phrase: 'no ACK received, terminating the session'));
      }
    }, Timers.TIMER_H);
  }

  void _iceRestart() async {
    Map<String, dynamic> offerConstraints = _rtcOfferConstraints ?? <String, dynamic>{
      'mandatory': <String, dynamic>{},
      'optional': <dynamic>[],
    };
    offerConstraints['mandatory']['IceRestart'] = true;
    _renegotiate(offerConstraints);
  }

  Future<void> _createRTCConnection(Map<String, dynamic> pcConfig, Map<String, dynamic> rtcConstraints) async {
    _connection = await createPeerConnection(pcConfig, rtcConstraints);
    _connection!.onIceConnectionState = (RTCIceConnectionState state) {
      // TODO(cloudwebrtc): Do more with different states.
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        terminate(<String, dynamic>{'cause': CausesType.RTP_TIMEOUT, 'status_code': 408, 'reason_phrase': CausesType.RTP_TIMEOUT});
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        _iceRestart();
      }
    };

    // In future versions, unified-plan will be used by default
    String? sdpSemantics = 'unified-plan';
    if (pcConfig['sdpSemantics'] != null) {
      sdpSemantics = pcConfig['sdpSemantics'];
    }

    switch (sdpSemantics) {
      case 'unified-plan':
        _connection!.onTrack = (RTCTrackEvent event) {
          if (event.streams.isNotEmpty) {
            _notifyOnStream(SIP_Originator.remote, event.streams[0]);
          }
        };
        break;
      case 'plan-b':
        _connection!.onAddStream = (MediaStream stream) {
          _notifyOnStream(SIP_Originator.remote, stream);
        };
        break;
    }

    logger.d('emit "peerconnection"');
    return;
  }

  Future<RTCSessionDescription> _createLocalDescription(String type, Map<String, dynamic>? constraints) async {
    logger.d('createLocalDescription()');
    _iceGatheringState ??= RTCIceGatheringState.RTCIceGatheringStateNew;
    Completer<RTCSessionDescription> completer = Completer<RTCSessionDescription>();

    constraints = constraints ??
        <String, dynamic>{
          'mandatory': <String, dynamic>{},
          'optional': <dynamic>[],
        };

    List<Future<RTCSessionDescription> Function(RTCSessionDescription)> modifiers = constraints['offerModifiers'] ?? <Future<RTCSessionDescription> Function(RTCSessionDescription)>[];

    constraints['offerModifiers'] = null;

    if (type != 'offer' && type != 'answer') {
      completer.completeError(Exceptions.TypeError('createLocalDescription() | invalid type "$type"'));
    }

    _rtcReady = false;
    late RTCSessionDescription desc;
    if (type == 'offer') {
      try {
        desc = await _connection!.createOffer(constraints);
      } catch (error) {
        logger.e('emit "peerconnection:createofferfailed" [error:${error.toString()}]');
        completer.completeError(error);
      }
    } else {
      try {
        desc = await _connection!.createAnswer(constraints);
      } catch (error) {
        logger.e('emit "peerconnection:createanswerfailed" [error:${error.toString()}]');
        completer.completeError(error);
      }
    }

    // Add 'pc.onicencandidate' event handler to resolve on last candidate.
    bool finished = false;

    for (Future<RTCSessionDescription> Function(RTCSessionDescription) modifier in modifiers) {
      desc = await modifier(desc);
    }

    Future<void> ready() async {
      if (!finished && _status != C.STATUS_TERMINATED) {
        finished = true;
        _connection!.onIceCandidate = null;
        _connection!.onIceGatheringState = null;
        _iceGatheringState = RTCIceGatheringState.RTCIceGatheringStateComplete;
        _rtcReady = true;
        RTCSessionDescription? desc = await _connection!.getLocalDescription();
        logger.d('emit "sdp"');
        completer.complete(desc);
      }
    }

    _connection!.onIceGatheringState = (RTCIceGatheringState state) {
      _iceGatheringState = state;
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        ready();
      }
    };

    bool hasCandidate = false;
    _connection!.onIceCandidate = (RTCIceCandidate candidate) {
      if (candidate != null) {
        if (!hasCandidate) {
          hasCandidate = true;
          /**
           *  Just wait for 0.5 seconds. In the case of multiple network connections,
           *  the RTCIceGatheringStateComplete event needs to wait for 10 ~ 30 seconds.
           *  Because trickle ICE is not defined in the sip protocol, the delay of
           * initiating a call to answer the call waiting will be unacceptable.
           */
          if (client.configuration.ice_gathering_timeout != 0) {
            setTimeout(() => ready(), client.configuration.ice_gathering_timeout);
          }
        }
      }
    };

    try {
      await _connection!.setLocalDescription(desc);
    } catch (error) {
      _rtcReady = true;
      logger.e('emit "peerconnection:setlocaldescriptionfailed" [error:${error.toString()}]');
      completer.completeError(error);
    }

    // Resolve right away if 'pc.iceGatheringState' is 'complete'.
    if (_iceGatheringState == RTCIceGatheringState.RTCIceGatheringStateComplete) {
      _rtcReady = true;
      RTCSessionDescription? desc = await _connection!.getLocalDescription();
      logger.d('emit "sdp"');
      return Future.value(desc);
    }

    return completer.future;
  }

  /**
   * Dialog Management
   */
  bool _createDialog(dynamic message, String type, [bool early = false]) {
    String? local_tag = (type == 'UAS') ? message.to_tag : message.from_tag;
    String? remote_tag = (type == 'UAS') ? message.from_tag : message.to_tag;
    String? id = message.call_id + local_tag + remote_tag;
    Dialog? early_dialog = _earlyDialogs[id];

    // Early Dialog.
    if (early) {
      if (early_dialog != null) {
        return true;
      } else {
        try {
          early_dialog = Dialog(this, message, type, DialogStatus.STATUS_EARLY);
        } catch (error) {
          logger.d('$error');
          _notifyOnFailed(SIP_Originator.remote, 500, CausesType.INTERNAL_ERROR, 'Can\'t create Early Dialog');
          return false;
        }
        // Dialog has been successfully created.
        _earlyDialogs[id] = early_dialog;
        return true;
      }
    } else {
      // Confirmed Dialog.
      _from_tag = message.from_tag;

      // In case the dialog is in _early_ state, update it.
      if (early_dialog != null) {
        early_dialog.update(message, type);
        _dialog = early_dialog;
        _earlyDialogs.remove(id);
        return true;
      }

      try {
        // Otherwise, create a _confirmed_ dialog.
        _dialog = Dialog(this, message, type);
        return true;
      } catch (error) {
        logger.d(error.toString());
        _notifyOnFailed(SIP_Originator.remote, 500, CausesType.INTERNAL_ERROR, 'Can\'t create Confirmed Dialog');
        return false;
      }
    }
  }

  /// In dialog INVITE Reception
  void _receiveReinvite(IncomingRequest request) async {
    logger.d('receiveReinvite()');

    String? contentType = request.getHeader('Content-Type');
    // bool rejected = false;

    // bool reject(dynamic options) {
    //   rejected = true;

    //   int status_code = options['status_code'] ?? 403;
    //   String reason_phrase = options['reason_phrase'] ?? '';
    //   List<dynamic> extraHeaders = utils.cloneArray(options['extraHeaders']);

    //   if (_status != C.STATUS_CONFIRMED) {
    //     return false;
    //   }

    //   if (status_code < 300 || status_code >= 700) {
    //     throw Exceptions.TypeError('Invalid status_code: $status_code');
    //   }

    //   request.reply(status_code, reason_phrase, extraHeaders);
    //   return true;
    // }

    // if (rejected) {
    //   return;
    // }

    _late_sdp = false;

    void sendAnswer(String? sdp) async {
      List<String> extraHeaders = <String>['Contact: $_contact'];

      _handleSessionTimersInIncomingRequest(request, extraHeaders);

      if (_late_sdp) {
        sdp = _mangleOffer(sdp);
      }

      request.reply(200, null, extraHeaders, sdp, () {
        _status = C.STATUS_WAITING_FOR_ACK;
        _setInvite2xxTimer(request, sdp);
        _setACKTimer();
      });

      // If callback is given execute it.
      if (data!['callback'] is Function) {
        data!['callback']();
      }
    }

    // Request without SDP.
    if (request.body == null) {
      _late_sdp = true;

      try {
        RTCSessionDescription desc = await _createLocalDescription('offer', _rtcOfferConstraints);
        sendAnswer(desc.sdp);
      } catch (_) {
        request.reply(500);
      }
      return;
    }

    // Request with SDP.
    if (contentType != 'application/sdp') {
      logger.d('invalid Content-Type');
      request.reply(415);
      return;
    }

    try {
      RTCSessionDescription desc = await _processInDialogSdpOffer(request);
      // Send answer.
      if (_status == C.STATUS_TERMINATED) {
        return;
      }
      sendAnswer(desc.sdp);
    } catch (error) {
      logger.e('Got anerror on re-INVITE: ${error.toString()}');
    }
  }

  /**
   * In dialog UPDATE Reception
   */
  void _receiveUpdate(IncomingRequest request) async {
    logger.d('receiveUpdate()');

    // bool rejected = false;

    // bool reject(Map<String, dynamic> options) {
    //   rejected = true;

    //   int status_code = options['status_code'] ?? 403;
    //   String reason_phrase = options['reason_phrase'] ?? '';
    //   List<dynamic> extraHeaders = utils.cloneArray(options['extraHeaders']);

    //   if (_status != C.STATUS_CONFIRMED) {
    //     return false;
    //   }

    //   if (status_code < 300 || status_code >= 700) {
    //     throw Exceptions.TypeError('Invalid status_code: $status_code');
    //   }

    //   request.reply(status_code, reason_phrase, extraHeaders);
    //   return true;
    // }

    String? contentType = request.getHeader('Content-Type');

    void sendAnswer(String? sdp) {
      List<String> extraHeaders = <String>['Contact: $_contact'];
      _handleSessionTimersInIncomingRequest(request, extraHeaders);
      request.reply(200, null, extraHeaders, sdp);
    }

    // if (rejected) {
    //   return;
    // }

    if (request.body == null || request.body!.isEmpty) {
      sendAnswer(null);
      return;
    }

    if (contentType != 'application/sdp') {
      logger.d('invalid Content-Type');

      request.reply(415);

      return;
    }

    try {
      RTCSessionDescription desc = await _processInDialogSdpOffer(request);
      if (_status == C.STATUS_TERMINATED) return;
      // Send answer.
      sendAnswer(desc.sdp);
    } catch (error) {
      logger.e('Got error on UPDATE: ${error.toString()}');
    }
  }

  Future<RTCSessionDescription> _processInDialogSdpOffer(dynamic request) async {
    logger.d('_processInDialogSdpOffer()');

    Map<String, dynamic> sdp = request.parseSDP();

    bool hold = false;

    for (Map<String, dynamic> m in sdp['media']) {
      if (holdMediaTypes.indexOf(m['type']) == -1) {
        continue;
      }

      String direction = m['direction'] ?? sdp['direction'] ?? 'sendrecv';

      if (direction == 'sendonly' || direction == 'inactive') {
        hold = true;
      }
      // If at least one of the streams is active don't emit 'hold'.
      else {
        hold = false;
        break;
      }
    }

    logger.d('emit "sdp"');

    RTCSessionDescription offer = RTCSessionDescription(request.body, 'offer');

    if (_status == C.STATUS_TERMINATED) {
      throw Exceptions.InvalidStateError('terminated');
    }
    try {
      await _connection!.setRemoteDescription(offer);
    } catch (error) {
      request.reply(488);
      logger.e('emit "peerconnection:setremotedescriptionfailed" [error:${error.toString()}]');

      throw Exceptions.TypeError('peerconnection.setRemoteDescription() failed');
    }

    if (_status == C.STATUS_TERMINATED) {
      throw Exceptions.InvalidStateError('terminated');
    }

    if (_remoteHold == true && hold == false) {
      _remoteHold = false;
      _notifyOnUnhold(SIP_Originator.remote);
    } else if (_remoteHold == false && hold == true) {
      _remoteHold = true;
      _notifyOnHold(SIP_Originator.remote);
    }

    // Create local description.

    if (_status == C.STATUS_TERMINATED) {
      throw Exceptions.InvalidStateError('terminated');
    }

    try {
      return await _createLocalDescription('answer', _rtcAnswerConstraints);
    } catch (_) {
      request.reply(500);
      throw Exceptions.TypeError('_createLocalDescription() failed');
    }
  }

  /**
   * In dialog Notify Reception
   */
  void _receiveNotify(IncomingRequest request) {
    logger.d('receiveNotify()');
    request.reply(420, 'Not Supported');
  }

  /**
   * INVITE with Replaces Reception
   */
  void _receiveReplaces(IncomingRequest request) {
    logger.d('receiveReplaces()');
    request.reply(420, 'Not Supported');
  }

  /**
   * Initial Request Sender
   */
  Future<void> _sendInitialRequest(Map<String, dynamic> pcConfig, Map<String, dynamic> mediaConstraints, Map<String, dynamic> rtcOfferConstraints, MediaStream? mediaStream) async {
    EventManager handlers = EventManager();
    handlers.on(EventOnRequestTimeout(), (EventOnRequestTimeout value) {
      onRequestTimeout();
    });
    handlers.on(EventOnTransportError(), (EventOnTransportError value) {
      onTransportError();
    });
    handlers.on(EventOnAuthenticated(), (EventOnAuthenticated event) {
      _request = event.request;
    });
    handlers.on(EventOnReceiveResponse(), (EventOnReceiveResponse event) {
      _receiveInviteResponse(event.response);
    });

    RequestSender request_sender = RequestSender(_client, _request, handlers);

    // In future versions, unified-plan will be used by default
    String? sdpSemantics = 'unified-plan';
    if (pcConfig['sdpSemantics'] != null) {
      sdpSemantics = pcConfig['sdpSemantics'];
    }

    // This Promise is resolved within the next iteration, so the app has now
    // a chance to set events such as 'peerconnection' and 'connecting'.
    MediaStream? stream;
    // A stream is given, var the app set events such as 'peerconnection' and 'connecting'.
    if (mediaStream != null) {
      stream = mediaStream;
      _notifyOnStream(SIP_Originator.local, stream);
    } // Request for user media access.
    else if (mediaConstraints['audio'] != null || mediaConstraints['video'] != null) {
      _localMediaStreamLocallyGenerated = true;
      try {
        stream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
        _notifyOnStream(SIP_Originator.local, stream);
      } catch (error) {
        if (_status == C.STATUS_TERMINATED) {
          throw Exceptions.InvalidStateError('terminated');
        }
        _notifyOnFailed(SIP_Originator.local, 500, CausesType.USER_DENIED_MEDIA_ACCESS, 'User Denied Media Access');
        logger.e('emit "getusermediafailed" [error:${error.toString()}]');
        throw error;
      }
    }

    if (_status == C.STATUS_TERMINATED) {
      throw Exceptions.InvalidStateError('terminated');
    }

    _localMediaStream = stream;

    if (stream != null) {
      switch (sdpSemantics) {
        case 'unified-plan':
          stream.getTracks().forEach((MediaStreamTrack track) {
            _connection!.addTrack(track, stream!);
          });
          break;
        case 'plan-b':
          _connection!.addStream(stream);
          break;
        default:
          logger.e('Unkown sdp semantics $sdpSemantics');
          throw Exceptions.NotReadyError('Unkown sdp semantics $sdpSemantics');
      }
    }

    // TODO(cloudwebrtc): should this be triggered here?
    _notifyOnConnecting(SIP_Originator.local, _request);

    try {
      RTCSessionDescription desc = await _createLocalDescription('offer', rtcOfferConstraints);
      if (_is_canceled || _status == C.STATUS_TERMINATED) {
        throw Exceptions.InvalidStateError('terminated');
      }

      _request.body = desc.sdp;
      _status = C.STATUS_INVITE_SENT;

      logger.d('emit "sending" [request]');

      request_sender.send();
    } catch (error, s) {
      logger.e(error.toString(), stackTrace: s);
      _notifyOnFailed(SIP_Originator.local, 500, CausesType.WEBRTC_ERROR, 'Can\'t create local SDP');
      if (_status == C.STATUS_TERMINATED) {
        return;
      }
      logger.e('Failed to _sendInitialRequest: ${error.toString()}');
      throw error;
    }
  }

  /// Reception of Response for Initial INVITE
  void _receiveInviteResponse(IncomingResponse? response) async {
    logger.d('receiveInviteResponse()');

    /// Handle 2XX retransmissions and responses from forked requests.
    if (_dialog != null && (response!.status_code >= 200 && response.status_code <= 299)) {
      ///
      /// If it is a retransmission from the endpoint that established
      /// the dialog, send an ACK
      ///
      if (_dialog!.id!.call_id == response.call_id && _dialog!.id!.local_tag == response.from_tag && _dialog!.id!.remote_tag == response.to_tag) {
        sendRequest(SIP_Method.ACK);
        return;
      } else {
        // If not, send an ACK  and terminate.
        try {
          // ignore: unused_local_variable
          Dialog dialog = Dialog(this, response, 'UAC');
        } catch (error) {
          logger.d(error.toString());
          return;
        }
        sendRequest(SIP_Method.ACK);
        sendRequest(SIP_Method.BYE);
        return;
      }
    }

    // Proceed to cancellation if the user requested.
    if (_is_canceled) {
      if (response!.status_code >= 100 && response.status_code < 200) {
        _request.cancel(_cancel_reason);
      } else if (response.status_code >= 200 && response.status_code < 299) {
        _acceptAndTerminate(response);
      }
      return;
    }

    if (_status != C.STATUS_INVITE_SENT && _status != C.STATUS_1XX_RECEIVED) {
      return;
    }

    String status_code = response!.status_code.toString();

    if (utils.test100(status_code)) {
      // 100 trying
      _status = C.STATUS_1XX_RECEIVED;
    } else if (utils.test1XX(status_code)) {
      // 1XX
      // Do nothing with 1xx responses without To tag.
      if (response.to_tag == null) {
        logger.d('1xx response received without to tag');
        return;
      }

      // Create Early Dialog if 1XX comes with contact.
      if (response.hasHeader('contact')) {
        // An error on dialog creation will fire 'failed' event.
        if (!_createDialog(response, 'UAC', true)) {
          return;
        }
      }

      _status = C.STATUS_1XX_RECEIVED;
      _notifyOnProgress(SIP_Originator.remote, response);

      if (response.body == null || response.body!.isEmpty) {
        return;
      }

      logger.d('emit "sdp"');

      RTCSessionDescription answer = RTCSessionDescription(response.body, 'answer');

      try {
        await _connection!.setRemoteDescription(answer);
      } catch (error) {
        logger.e('emit "peerconnection:setremotedescriptionfailed" [error:${error.toString()}]');
      }
    } else if (utils.test2XX(status_code)) {
      // 2XX
      _status = C.STATUS_CONFIRMED;

      if (response.body == null || response.body!.isEmpty) {
        _acceptAndTerminate(response, 400, CausesType.MISSING_SDP);
        _notifyOnFailed(SIP_Originator.remote, 400, CausesType.BAD_MEDIA_DESCRIPTION, 'Missing SDP');
        return;
      }

      // An error on dialog creation will fire 'failed' event.
      if (_createDialog(response, 'UAC') == null) {
        return;
      }

      logger.d('emit "sdp"');

      RTCSessionDescription answer = RTCSessionDescription(response.body, 'answer');

      // Be ready for 200 with SDP after a 180/183 with SDP.
      // We created a SDP 'answer' for it, so check the current signaling state.
      if (_connection!.signalingState == RTCSignalingState.RTCSignalingStateStable || _connection!.signalingState == RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
        try {
          RTCSessionDescription offer = await _connection!.createOffer(_rtcOfferConstraints!);
          await _connection!.setLocalDescription(offer);
        } catch (error) {
          _acceptAndTerminate(response, 500, error.toString());
          _notifyOnFailed(SIP_Originator.local, 500, CausesType.WEBRTC_ERROR, 'Can\'t create offer ${error.toString()}');
        }
      }

      try {
        await _connection!.setRemoteDescription(answer);
        // Handle Session Timers.
        _handleSessionTimersInIncomingResponse(response);
        _notifyOnAccepted(SIP_Originator.remote, response);
        OutgoingRequest ack = sendRequest(SIP_Method.ACK);
        _notifyOnConfirmed(SIP_Originator.local, ack);
      } catch (error) {
        _acceptAndTerminate(response, 488, 'Not Acceptable Here');
        _notifyOnFailed(SIP_Originator.remote, 488, CausesType.BAD_MEDIA_DESCRIPTION, 'Not Acceptable Here');
        logger.e('emit "peerconnection:setremotedescriptionfailed" [error:${error.toString()}]');
      }
    } else {
      String cause = utils.sipErrorCause(response.status_code);
      _notifyOnFailed(SIP_Originator.remote, response.status_code, cause, response.reason_phrase);
    }
  }

  /**
   * Send Re-INVITE
   */
  void _sendReinvite([Map<String, dynamic>? options]) async {
    logger.d('sendReinvite()');

    options = options ?? <String, dynamic>{};

    List<dynamic> extraHeaders = options['extraHeaders'] != null ? utils.cloneArray(options['extraHeaders']) : <dynamic>[];
    EventManager eventHandlers = options['eventHandlers'] ?? EventManager();
    Map<String, dynamic>? rtcOfferConstraints = options['rtcOfferConstraints'] ?? _rtcOfferConstraints;

    bool succeeded = false;

    extraHeaders.add('Contact: $_contact');
    extraHeaders.add('Content-Type: application/sdp');

    // Session Timers.
    if (_sessionTimers.running) {
      extraHeaders.add('Session-Expires: ${_sessionTimers.currentExpires};refresher=${_sessionTimers.refresher ? 'uac' : 'uas'}');
    }

    void onFailed([dynamic response]) {
      eventHandlers.emit(EventCallFailed(session: this, response: response));
    }

    void onSucceeded(IncomingResponse? response) async {
      if (_status == C.STATUS_TERMINATED) {
        return;
      }

      sendRequest(SIP_Method.ACK);

      // If it is a 2XX retransmission exit now.
      if (succeeded != null) {
        return;
      }

      // Handle Session Timers.
      _handleSessionTimersInIncomingResponse(response);

      // Must have SDP answer.
      if (response!.body == null || response.body!.isEmpty) {
        onFailed();
        return;
      } else if (response.getHeader('Content-Type') != 'application/sdp') {
        onFailed();
        return;
      }

      logger.d('emit "sdp"');

      RTCSessionDescription answer = RTCSessionDescription(response.body, 'answer');

      try {
        await _connection!.setRemoteDescription(answer);
        eventHandlers.emit(EventSucceeded(response: response));
      } catch (error) {
        onFailed();
        logger.e('emit "peerconnection:setremotedescriptionfailed" [error:${error.toString()}]');
      }
    }

    try {
      RTCSessionDescription desc = await _createLocalDescription('offer', rtcOfferConstraints);
      String? sdp = _mangleOffer(desc.sdp);
      logger.d('emit "sdp"');

      EventManager handlers = EventManager();
      handlers.on(EventOnSuccessResponse(), (EventOnSuccessResponse event) {
        onSucceeded(event.response as IncomingResponse?);
        succeeded = true;
      });
      handlers.on(EventOnErrorResponse(), (EventOnErrorResponse event) {
        onFailed(event.response);
      });
      handlers.on(EventOnTransportError(), (EventOnTransportError event) {
        onTransportError(); // Do nothing because session ends.
      });
      handlers.on(EventOnRequestTimeout(), (EventOnRequestTimeout event) {
        onRequestTimeout(); // Do nothing because session ends.
      });
      handlers.on(EventOnDialogError(), (EventOnDialogError event) {
        onDialogError(); // Do nothing because session ends.
      });

      sendRequest(SIP_Method.INVITE, <String, dynamic>{'extraHeaders': extraHeaders, 'body': sdp, 'eventHandlers': handlers});
    } catch (e, s) {
      logger.e(e.toString(), stackTrace: s);
      onFailed();
    }
  }

  /**
   * Send UPDATE
   */
  void _sendUpdate([Map<String, dynamic>? options]) async {
    logger.d('sendUpdate()');

    options = options ?? <String, dynamic>{};

    List<dynamic> extraHeaders = utils.cloneArray(options['extraHeaders'] ?? <dynamic>[]);
    EventManager eventHandlers = options['eventHandlers'] ?? EventManager();
    Map<String, dynamic> rtcOfferConstraints = options['rtcOfferConstraints'] ?? _rtcOfferConstraints ?? <String, dynamic>{};
    bool sdpOffer = options['sdpOffer'] ?? false;

    bool succeeded = false;

    extraHeaders.add('Contact: $_contact');

    // Session Timers.
    if (_sessionTimers.running) {
      extraHeaders.add('Session-Expires: ${_sessionTimers.currentExpires};refresher=${_sessionTimers.refresher ? 'uac' : 'uas'}');
    }

    void onFailed([dynamic response]) {
      eventHandlers.emit(EventCallFailed(session: this, response: response));
    }

    void onSucceeded(IncomingResponse? response) async {
      if (_status == C.STATUS_TERMINATED) {
        return;
      }

      // Handle Session Timers.
      _handleSessionTimersInIncomingResponse(response);

      // If it is a 2XX retransmission exit now.
      if (succeeded != null) {
        return;
      }

      // Must have SDP answer.
      if (sdpOffer) {
        if (response!.body != null && response.body!.trim().isNotEmpty) {
          onFailed();
          return;
        } else if (response.getHeader('Content-Type') != 'application/sdp') {
          onFailed();
          return;
        }

        logger.d('emit "sdp"');

        RTCSessionDescription answer = RTCSessionDescription(response.body, 'answer');

        try {
          await _connection!.setRemoteDescription(answer);
          eventHandlers.emit(EventSucceeded(response: response));
        } catch (error) {
          onFailed(error);
          logger.e('emit "peerconnection:setremotedescriptionfailed" [error:${error.toString()}]');
        }
      }
      // No SDP answer.
      else {
        eventHandlers.emit(EventSucceeded(response: response));
      }
    }

    if (sdpOffer) {
      extraHeaders.add('Content-Type: application/sdp');
      try {
        RTCSessionDescription desc = await _createLocalDescription('offer', rtcOfferConstraints);
        String? sdp = _mangleOffer(desc.sdp);

        logger.d('emit "sdp"');

        EventManager handlers = EventManager();
        handlers.on(EventOnSuccessResponse(), (EventOnSuccessResponse event) {
          onSucceeded(event.response as IncomingResponse?);
          succeeded = true;
        });
        handlers.on(EventOnErrorResponse(), (EventOnErrorResponse event) {
          onFailed(event.response);
        });
        handlers.on(EventOnTransportError(), (EventOnTransportError event) {
          onTransportError(); // Do nothing because session ends.
        });
        handlers.on(EventOnRequestTimeout(), (EventOnRequestTimeout event) {
          onRequestTimeout(); // Do nothing because session ends.
        });
        handlers.on(EventOnDialogError(), (EventOnDialogError event) {
          onDialogError(); // Do nothing because session ends.
        });

        sendRequest(SIP_Method.UPDATE, <String, dynamic>{'extraHeaders': extraHeaders, 'body': sdp, 'eventHandlers': handlers});
      } catch (error) {
        onFailed(error);
      }
    } else {
      // No SDP.

      EventManager handlers = EventManager();
      handlers.on(EventOnSuccessResponse(), (EventOnSuccessResponse event) {
        onSucceeded(event.response as IncomingResponse?);
      });
      handlers.on(EventOnErrorResponse(), (EventOnErrorResponse event) {
        onFailed(event.response);
      });
      handlers.on(EventOnTransportError(), (EventOnTransportError event) {
        onTransportError(); // Do nothing because session ends.
      });
      handlers.on(EventOnRequestTimeout(), (EventOnRequestTimeout event) {
        onRequestTimeout(); // Do nothing because session ends.
      });
      handlers.on(EventOnDialogError(), (EventOnDialogError event) {
        onDialogError(); // Do nothing because session ends.
      });

      sendRequest(SIP_Method.UPDATE, <String, dynamic>{'extraHeaders': extraHeaders, 'eventHandlers': handlers});
    }
  }

  void _acceptAndTerminate(IncomingResponse? response, [int? status_code, String? reason_phrase]) async {
    logger.d('acceptAndTerminate()');

    List<dynamic> extraHeaders = <dynamic>[];

    if (status_code != null) {
      reason_phrase = reason_phrase ?? REASON_PHRASE[status_code] ?? '';
      extraHeaders.add('Reason: SIP ;cause=$status_code; text="$reason_phrase"');
    }

    // An error on dialog creation will fire 'failed' event.
    if (_dialog != null || _createDialog(response, 'UAC')) {
      sendRequest(SIP_Method.ACK);
      sendRequest(SIP_Method.BYE, <String, dynamic>{'extraHeaders': extraHeaders});
    }

    // Update session status.
    _status = C.STATUS_TERMINATED;
  }

  /**
   * Correctly set the SDP direction attributes if the call is on local hold
   */
  String? _mangleOffer(String? sdpInput) {
    logger.wtf('>>> sdpInput $sdpInput');
    if (!_localHold && !_remoteHold) {
      return sdpInput;
    }

    Map<String, dynamic> sdp = sdp_transform.parse(sdpInput!);
    logger.wtf('>>> sdp $sdp');

    // Local hold.
    if (_localHold && !_remoteHold) {
      logger.d('mangleOffer() | me on hold, mangling offer');
      for (Map<String, dynamic> m in sdp['media']) {
        if (holdMediaTypes.indexOf(m['type']) == -1) {
          continue;
        }
        if (m['direction'] == null) {
          m['direction'] = 'sendonly';
        } else if (m['direction'] == 'sendrecv') {
          m['direction'] = 'sendonly';
        } else if (m['direction'] == 'recvonly') {
          m['direction'] = 'inactive';
        }
      }
    }
    // Local and remote hold.
    else if (_localHold && _remoteHold) {
      logger.d('mangleOffer() | both on hold, mangling offer');
      for (Map<String, dynamic> m in sdp['media']) {
        if (holdMediaTypes.indexOf(m['type']) == -1) {
          continue;
        }
        m['direction'] = 'inactive';
      }
    }
    // Remote hold.
    else if (_remoteHold) {
      logger.d('mangleOffer() | remote on hold, mangling offer');
      for (Map<String, dynamic> m in sdp['media']) {
        if (holdMediaTypes.indexOf(m['type']) == -1) {
          continue;
        }
        if (m['direction'] == null) {
          m['direction'] = 'recvonly';
        } else if (m['direction'] == 'sendrecv') {
          m['direction'] = 'recvonly';
        } else if (m['direction'] == 'recvonly') {
          m['direction'] = 'inactive';
        }
      }
    }

    return sdp_transform.write(sdp, null);
  }

  /**
   * Handle SessionTimers for an incoming INVITE or UPDATE.
   * @param  {IncomingRequest} request
   * @param  {Array} responseExtraHeaders  Extra headers for the 200 response.
   */
  void _handleSessionTimersInIncomingRequest(IncomingRequest request, List<dynamic> responseExtraHeaders) {
    if (!_sessionTimers.enabled) {
      return;
    }

    String session_expires_refresher;

    if (request.session_expires != null && request.session_expires! > 0 && request.session_expires! >= MIN_SESSION_EXPIRES) {
      _sessionTimers.currentExpires = request.session_expires;
      session_expires_refresher = request.session_expires_refresher ?? 'uas';
    } else {
      _sessionTimers.currentExpires = _sessionTimers.defaultExpires;
      session_expires_refresher = 'uas';
    }

    responseExtraHeaders.add('Session-Expires: ${_sessionTimers.currentExpires};refresher=$session_expires_refresher');

    _sessionTimers.refresher = session_expires_refresher == 'uas';
    _runSessionTimer();
  }

  /**
   * Handle SessionTimers for an incoming response to INVITE or UPDATE.
   * @param  {IncomingResponse} response
   */
  void _handleSessionTimersInIncomingResponse(dynamic response) {
    if (!_sessionTimers.enabled) {
      return;
    }

    String session_expires_refresher;

    if (response.session_expires != null && response.session_expires != 0 && response.session_expires >= MIN_SESSION_EXPIRES) {
      _sessionTimers.currentExpires = response.session_expires;
      session_expires_refresher = response.session_expires_refresher ?? 'uac';
    } else {
      _sessionTimers.currentExpires = _sessionTimers.defaultExpires;
      session_expires_refresher = 'uac';
    }

    _sessionTimers.refresher = session_expires_refresher == 'uac';
    _runSessionTimer();
  }

  void _runSessionTimer() {
    int? expires = _sessionTimers.currentExpires;

    _sessionTimers.running = true;

    clearTimeout(_sessionTimers.timer);

    // I'm the refresher.
    if (_sessionTimers.refresher) {
      _sessionTimers.timer = setTimeout(() {
        if (_status == C.STATUS_TERMINATED) {
          return;
        }

        logger.d('runSessionTimer() | sending session refresh request');

        if (_sessionTimers.refreshMethod == SIP_Method.UPDATE) {
          _sendUpdate();
        } else {
          _sendReinvite();
        }
      }, expires! * 500); // Half the given interval (as the RFC states).
    }
    // I'm not the refresher.
    else {
      _sessionTimers.timer = setTimeout(() {
        if (_status == C.STATUS_TERMINATED) {
          return;
        }

        logger.e('runSessionTimer() | timer expired, terminating the session');

        terminate(<String, dynamic>{'cause': CausesType.REQUEST_TIMEOUT, 'status_code': 408, 'reason_phrase': 'Session Timer Expired'});
      }, expires! * 1100);
    }
  }

  void _notifyOnIncoming(SIP_Originator originator, dynamic request) {
    logger.d('session incoming');
    final session = SIP_Session(_client, this, originator);

    _client.sessions[session.target] = session;

    _emitter.emit('sip.session.incoming', [session]);
    logger.wtf('[SIP_CLIENT] INCOMING            -> ${session.id} -- ${session.target} -- ${originator.name}');
  }

  void _notifyOnOutgoing(SIP_Originator originator, dynamic request) {
    logger.d('session outgoing');
    final session = SIP_Session(_client, this, originator);

    _client.sessions[session.target] = session;

    _emitter.emit('sip.session.outgoing', [session]);
    logger.wtf('[SIP_CLIENT] OUTGOING            -> ${session.id} -- ${session.target} -- ${originator.name}');
  }

  void _notifyOnConnecting(SIP_Originator originator, dynamic request) {
    logger.d('session connecting');
    final session = SIP_Session(_client, this, originator);

    _client.sessions[session.target] = session;

    _emitter.emit('sip.session.connecting', [session]);
    logger.wtf('[SIP_CLIENT] CONNECTING          -> ${session.id} -- ${session.target} -- ${originator.name}');
  }

  void _notifyOnProgress(SIP_Originator originator, dynamic response) {
    logger.d('session progress');
    final session = SIP_Session(_client, this, originator);

    _client.sessions[session.target] = session;

    _emitter.emit('sip.session.progress', [session]);
    logger.wtf('[SIP_CLIENT] PROGRESS            -> ${session.id} -- ${session.target} -- ${originator.name}');
  }

  void _notifyOnAccepted(SIP_Originator originator, [dynamic message]) {
    logger.d('session accepted');
    final session = SIP_Session(_client, this, originator);

    _client.sessions[session.target] = session;
    _start_time = DateTime.now();

    _emitter.emit('sip.session.confirmed', [session]);
    logger.wtf('[SIP_CLIENT] CONFIRMED           -> ${session.id} -- ${session.target} -- ${originator.name}');
  }

  void _notifyOnConfirmed(SIP_Originator originator, dynamic ack) {
    logger.d('session confirmed');
    final session = SIP_Session(_client, this, originator);

    _client.sessions[session.target] = session;
    _is_confirmed = true;

    _emitter.emit('sip.session.confirmed', [session]);
    logger.wtf('[SIP_CLIENT] CONFIRMED           -> ${session.id} -- ${session.target} -- ${originator.name}');
  }

  void _notifyOnEnded(SIP_Originator originator, ErrorCause cause) {
    logger.d('session ended - ${cause.status_code}, ${cause.cause}, ${cause.reason_phrase}');
    final session = SIP_Session(_client, this, originator);
    final status = SIP_StatusLine(cause.status_code ?? 0, cause.cause ?? cause.reason_phrase ?? '');

    _client.sessions.remove(session.target);
    _end_time = DateTime.now();
    _close();

    _emitter.emit('sip.session.terminated', [session, status]);
    logger.wtf('[SIP_CLIENT] TERMINATED          -> ${session.id} -- ${session.target} -- ${originator.name}');
  }

  void _notifyOnFailed(SIP_Originator originator, int? status_code, String cause, String? reason_phrase) {
    logger.d('session failed - $status_code, $cause, $reason_phrase');
    final session = SIP_Session(_client, this, originator);
    final status = SIP_StatusLine(status_code ?? 0, cause);

    _client.sessions.remove(session.target);
    _end_time = DateTime.now();
    _close();

    _emitter.emit('sip.session.terminated', [session, status]);
    logger.wtf('[SIP_CLIENT] TERMINATED          -> ${session.id} -- ${session.target} -- ${originator.name} (Code: ${status.code}, Reason: ${status.reason})');
  }

  void _notifyOnStream(SIP_Originator originator, MediaStream s) {
    logger.d('session stream');
    final session = SIP_Session(_client, this, originator);
    final stream = SIP_MediaStream(s, _audioMuted, _videoMuted);

    _client.sessions[session.target] = session;

    _emitter.emit('sip.session.stream', [session, stream]);
    logger.wtf('[SIP_CLIENT] STREAM              -> ${session.id} -- ${session.target} -- ${originator.name} (AudioMuted: $_audioMuted, VideoMuted: $_videoMuted)');
  }

  void _notifyOnHold(SIP_Originator originator) {
    logger.d('session onhold');
    final session = SIP_Session(_client, this, originator);

    _client.sessions[session.target] = session;

    _emitter.emit('sip.session.hold', [session]);
    logger.wtf('[SIP_CLIENT] HOLD                -> ${session.id} -- ${session.target} -- ${originator.name}');
  }

  void _notifyOnUnhold(SIP_Originator originator) {
    logger.d('session onunhold');
    final session = SIP_Session(_client, this, originator);
    
    _client.sessions[session.target] = session;

    _emitter.emit('sip.session.unhold', [session]);
    logger.wtf('[SIP_CLIENT] UNHOLD              -> ${session.id} -- ${session.target} -- ${originator.name}');
  }

  Map<String, dynamic> _options([bool voiceOnly = true]) {
    return <String, dynamic>{
      'sessionTimersExpires': 120,
      'extraHeaders': <dynamic>[],
      'pcConfig': <String, dynamic>{
        'sdpSemantics': 'unified-plan', 
        'iceServers': _client.configuration.ice_servers
      },
      'mediaConstraints': <String, dynamic>{
        'audio': true,
        'video': voiceOnly ? false : <String, dynamic>{
          'mandatory': <String, dynamic>{
            'minWidth': '640',
            'minHeight': '480',
            'minFrameRate': '30',
          },
          'facingMode': 'user',
          'optional': <dynamic>[],
        }
      },
      'rtcOfferConstraints': <String, dynamic>{
        'mandatory': <String, dynamic>{
          'OfferToReceiveAudio': true,
          'OfferToReceiveVideo': !voiceOnly,
        },
        'optional': <dynamic>[],
      },
      'rtcAnswerConstraints': <String, dynamic>{
        'mandatory': <String, dynamic>{
          'OfferToReceiveAudio': true,
          'OfferToReceiveVideo': !voiceOnly,
        },
        'optional': <dynamic>[],
      },
      'rtcConstraints': <String, dynamic>{
        'mandatory': <dynamic, dynamic>{},
        'optional': <Map<String, dynamic>>[
          <String, dynamic>{'DtlsSrtpKeyAgreement': true},
        ],
      }
    };
  }
}
