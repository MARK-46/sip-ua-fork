import 'name_addr_header.dart';
import 'constants.dart' as DartSIP_C;
import 'constants.dart';
import 'event_manager/event_manager.dart';
import 'event_manager/internal_events.dart';
import 'exceptions.dart' as Exceptions;
import 'logger.dart';
import 'request_sender.dart';
import 'sip_message.dart';
import 'sip_client.dart';
import 'uri.dart';
import 'utils.dart' as Utils;

class Options extends EventManager with Applicant {
  Options(this._client);

  final SIP_Client _client;
  dynamic _request;
  bool _closed = false;
  SIP_Direction? _direction;
  NameAddrHeader? _local_identity;
  NameAddrHeader? _remote_identity;
  // Whether an incoming Options has been replied.
  bool _is_replied = false;
  // Custom Options empty object for high level use.
  final Map<String, dynamic> _data = <String, dynamic>{};
  SIP_Direction? get direction => _direction;

  NameAddrHeader? get local_identity => _local_identity;

  NameAddrHeader? get remote_identity => _remote_identity;

  Map<String, dynamic>? get data => _data;

  void send(String target, String body, [Map<String, dynamic>? options]) {
    String originalTarget = target;
    options = options ?? <String, dynamic>{};

    if (target == null) {
      throw Exceptions.TypeError('A target is required for OPTIONS');
    }

    // Check target validity.
    URI normalized = _client.normalizeTarget(target)!;
    if (normalized == null) {
      throw Exceptions.TypeError('Invalid target: $originalTarget');
    }

    // Get call options.
    List<dynamic> extraHeaders = Utils.cloneArray(options['extraHeaders']);
    EventManager eventHandlers = options['eventHandlers'] ?? EventManager();
    String contentType = options['contentType'] ?? 'application/sdp';

    // Set event handlers.
    addAllEventHandlers(eventHandlers);

    extraHeaders.add('Content-Type: $contentType');

    _request =
        OutgoingRequest(SIP_Method.OPTIONS, normalized, _client, null, extraHeaders);
    if (body != null) {
      _request.body = body;
    }

    EventManager handlers = EventManager();
    handlers.on(EventOnRequestTimeout(), (EventOnRequestTimeout value) {
      _onRequestTimeout();
    });
    handlers.on(EventOnTransportError(), (EventOnTransportError value) {
      _onTransportError();
    });
    handlers.on(EventOnReceiveResponse(), (EventOnReceiveResponse event) {
      _receiveResponse(event.response);
    });

    RequestSender request_sender = RequestSender(_client, _request, handlers);

    _newOptions(SIP_Originator.local, _request);

    request_sender.send();
  }

  void init_incoming(IncomingRequest request) {
    _request = request;

    _newOptions(SIP_Originator.remote, request);

    // Reply with a 200 OK if the user didn't reply.
    if (!_is_replied) {
      _is_replied = true;
      request.reply(200);
    }

    close();
  }

  /*
   * Accept the incoming Options
   * Only valid for incoming Options
   */
  void accept(Map<String, dynamic> options) {
    List<dynamic> extraHeaders = Utils.cloneArray(options['extraHeaders']);
    String? body = options['body'];

    if (_direction != SIP_Direction.incoming) {
      throw Exceptions.NotSupportedError(
          '"accept" not supported for outgoing Options');
    }

    if (_is_replied) {
      throw AssertionError('incoming Options already replied');
    }

    _is_replied = true;
    _request.reply(200, null, extraHeaders, body);
  }

  /**
   * Reject the incoming Options
   * Only valid for incoming Optionss
   */
  void reject(Map<String, dynamic> options) {
    int status_code = options['status_code'] ?? 480;
    String? reason_phrase = options['reason_phrase'];
    List<dynamic> extraHeaders = Utils.cloneArray(options['extraHeaders']);
    String? body = options['body'];

    if (_direction != SIP_Direction.incoming) {
      throw Exceptions.NotSupportedError(
          '"reject" not supported for outgoing Options');
    }

    if (_is_replied) {
      throw AssertionError('incoming Options already replied');
    }

    if (status_code < 300 || status_code >= 700) {
      throw Exceptions.TypeError('Invalid status_code: $status_code');
    }

    _is_replied = true;
    _request.reply(status_code, reason_phrase, extraHeaders, body);
  }

  void _receiveResponse(IncomingResponse? response) {
    if (_closed != null) {
      return;
    }
    if (RegExp(r'^1[0-9]{2}$').hasMatch(response!.status_code)) {
      // Ignore provisional responses.
    } else if (RegExp(r'^2[0-9]{2}$').hasMatch(response.status_code)) {
      _succeeded(SIP_Originator.remote, response);
    } else {
      String cause = Utils.sipErrorCause(response.status_code);
      _failed(SIP_Originator.remote, response.status_code, cause, response.reason_phrase);
    }
  }

  void _onRequestTimeout() {
    if (_closed != null) {
      return;
    }
    _failed(
        SIP_Originator.system, 408, DartSIP_C.CausesType.REQUEST_TIMEOUT, 'Request Timeout');
  }

  void _onTransportError() {
    if (_closed != null) {
      return;
    }
    _failed(SIP_Originator.system, 500, DartSIP_C.CausesType.CONNECTION_ERROR,
        'SIP_SocketInterface Error');
  }

  @override
  void close() {
    _closed = true;
    _client.destroyOptions(this);
  }

  /**
   * Internal Callbacks
   */

  void _newOptions(SIP_Originator originator, dynamic request) {
    if (originator == SIP_Originator.remote) {
      _direction = SIP_Direction.incoming;
      _local_identity = request.to;
      _remote_identity = request.from;
    } else if (originator == SIP_Originator.local) {
      _direction = SIP_Direction.outgoing;
      _local_identity = request.from;
      _remote_identity = request.to;
    }

    _client.newOptions(this, originator, request);
  }

  void _failed(SIP_Originator originator, int? status_code, String cause,
      String? reason_phrase) {
    logger.d('OPTIONS failed');
    close();
    logger.d('emit "failed"');
    emit(EventCallFailed(
        originator: originator,
        cause: ErrorCause(
            cause: cause,
            status_code: status_code,
            reason_phrase: reason_phrase)));
  }

  void _succeeded(SIP_Originator originator, IncomingResponse? response) {
    logger.d('OPTIONS succeeded');

    close();

    logger.d('emit "succeeded"');

    emit(EventSucceeded(originator: originator, response: response));
  }
}
