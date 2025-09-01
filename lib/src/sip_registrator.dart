import 'dart:async';

import 'transactions/transaction_base.dart';
import 'constants.dart';
import 'event_manager/event_manager.dart';
import 'event_manager/internal_events.dart';
import 'logger.dart';
import 'request_sender.dart';
import 'sip_message.dart';
import 'timers.dart';
import 'transports/socket_interface.dart';
import 'sip_client.dart';
import 'uri.dart';
import 'utils.dart' as utils;

const int MIN_REGISTER_EXPIRES = 10; // In seconds.

class UnHandledResponse {
  UnHandledResponse(this.status_code, this.reason_phrase);
  int status_code;
  String reason_phrase;
}

class Registrator {

  Registrator(SIP_Client client, [SIP_SocketInterface? transport]) {
    int reg_id = 1; // Force reg_id to 1.

    _client = client;
    _transport = transport;
    
    _registrar = client.configuration.registrar_server;
    _expires = client.configuration.register_expires;

    // Call-ID and CSeq values RFC3261 10.2.
    _call_id = utils.createRandomToken(22);
    _cseq = 0;

    _to_uri = client.configuration.sip_uri;

    _registrationTimer = null;

    // Ongoing Register request.
    _registering = false;

    // Set status.
    _registered = false;

    // Contact header.
    _contact = _client.contact.toString();

    // Sip.ice media feature tag (RFC 5768).
    _contact += ';+sip.ice';

    // Custom headers for REGISTER and un-REGISTER.
    _extraHeaders = <String>[];

    // Custom Contact header params for REGISTER and un-REGISTER.
    _extraContactParams = '';

    if (reg_id != null) {
      _contact += ';reg-id=$reg_id';
      _contact += ';+sip.instance="<urn:uuid:${_client.configuration.instance_id}>"';
    }
  }

  late SIP_Client _client;
  SIP_SocketInterface? _transport;
  late URI _registrar;
  int? _expires;
  String? _call_id;
  late int _cseq;
  URI? _to_uri;
  Timer? _registrationTimer;
  late bool _registering;
  bool _registered = false;
  late String _contact;
  List<String>? _extraHeaders;
  late String _extraContactParams;
  SIP_StateEnum _state = SIP_StateEnum.UNREGISTERED;

  SIP_StateEnum get state => _state;

  bool get registered => _registered;

  SIP_SocketInterface? get transport => _transport;

  void setExtraHeaders(List<String>? extraHeaders) {
    _extraHeaders = extraHeaders ?? <String>[];
  }

  void setExtraContactParams(Map<String, dynamic>? extraContactParams) {
    extraContactParams ??= <String, dynamic>{};

    // Reset it.
    _extraContactParams = '';

    extraContactParams.forEach((String param_key, dynamic param_value) {
      _extraContactParams += ';$param_key';
      if (param_value != null) {
        _extraContactParams += '=$param_value';
      }
    });
  }

  void register() {
    if (_registering) {
      logger.d('Register request in progress...');
      return;
    }

    List<String> extraHeaders = List<String>.from(_extraHeaders ?? <String>[]);

    extraHeaders.add('Contact: $_contact;expires=$_expires$_extraContactParams');
    extraHeaders.add('Expires: $_expires');

    logger.w(_contact);

    OutgoingRequest request = OutgoingRequest(
        SIP_Method.REGISTER,
        _registrar,
        _client,
        <String, dynamic>{
          'to_uri': _to_uri,
          'call_id': _call_id,
          'cseq': _cseq += 1
        },
        extraHeaders);

    EventManager handlers = EventManager();
    handlers.on(EventOnRequestTimeout(), (EventOnRequestTimeout value) {
      _registrationFailure(
          UnHandledResponse(408, CausesType.REQUEST_TIMEOUT),
          CausesType.REQUEST_TIMEOUT);
    });
    handlers.on(EventOnTransportError(), (EventOnTransportError value) {
      _registrationFailure(
          UnHandledResponse(500, CausesType.CONNECTION_ERROR),
          CausesType.CONNECTION_ERROR);
    });
    handlers.on(EventOnAuthenticated(), (EventOnAuthenticated value) {
      _cseq += 1;
    });
    handlers.on(EventOnReceiveResponse(), (EventOnReceiveResponse event) {
      {
        // Discard responses to older REGISTER/un-REGISTER requests.
        if (event.response!.cseq != _cseq) {
          return;
        }

        // Clear registration timer.
        if (_registrationTimer != null) {
          clearTimeout(_registrationTimer);
          _registrationTimer = null;
        }

        String status_code = event.response!.status_code.toString();

        if (utils.test1XX(status_code)) {
          // Ignore provisional responses.
        } else if (utils.test2XX(status_code)) {
          _registering = false;

          if (!event.response!.hasHeader('Contact')) {
            logger.d('no Contact header in response to REGISTER, response ignored');
            return;
          }

          List<dynamic> contacts = <dynamic>[];
          event.response!.headers!['Contact'].forEach((dynamic item) {
            contacts.add(item['parsed']);
          });
          // Get the Contact pointing to us and update the expires value accordingly.
          dynamic contact = contacts.firstWhere(
              (dynamic element) => element.uri.user == _client.contact!.uri!.user);

          if (contact == null) {
            logger.d('no Contact header pointing to us, response ignored');
            return;
          }

          dynamic expires = contact.getParam('expires');

          if (expires == null && event.response!.hasHeader('expires')) {
            expires = event.response!.getHeader('expires');
          }

          expires ??= _expires;

          expires = num.tryParse(expires) ?? 0;

          if (expires < MIN_REGISTER_EXPIRES) {
            expires = MIN_REGISTER_EXPIRES;
          }

          // Re-Register or emit an event before the expiration interval has elapsed.
          // For that, decrease the expires value. ie: 3 seconds.
          _registrationTimer = setTimeout(() {
            clearTimeout(_registrationTimer);
            _registrationTimer = null;
            // If there are no listeners for registrationExpiring, reregistration.
            // If there are listeners, var the listening do the register call.
            register();
          }, (expires * 1000) - 5000);

          // Save gruu values.
          if (contact.hasParam('temp-gruu')) {
            _client.contact!.temp_gruu = contact.getParam('temp-gruu').replaceAll('"', '');
          }
          if (contact.hasParam('pub-gruu')) {
            _client.contact!.pub_gruu = contact.getParam('pub-gruu').replaceAll('"', '');
          }

          if (!_registered) {
            _registered = true;
          }
          _notifyOnRegistered(event.response);
        } else {
          // Interval too brief RFC3261 10.2.8.
          if (status_code.contains(RegExp(r'^423$'))) {
            if (event.response!.hasHeader('min-expires')) {
              // Increase our registration interval to the suggested minimum.
              _expires = num.tryParse(event.response!.getHeader('min-expires'))
                      as int? ??
                  0;

              if (_expires! < MIN_REGISTER_EXPIRES)
                _expires = MIN_REGISTER_EXPIRES;

              // Attempt the registration again immediately.
              register();
            } else {
              // This response MUST contain a Min-Expires header field.
              logger
                  .d('423 response received for REGISTER without Min-Expires');

              _registrationFailure(
                  event.response, CausesType.SIP_FAILURE_CODE);
            }
          } else {
            String cause = utils.sipErrorCause(event.response!.status_code);
            _registrationFailure(event.response, cause);
          }
        }
      }
    });

    RequestSender request_sender = RequestSender(_client, request, handlers);

    _registering = true;
    request_sender.send();
  }

  void unregister(bool unregister_all) {
    if (_registered == false) {
      logger.d('already unregistered');

      return;
    }

    _registered = false;

    // Clear the registration timer.
    if (_registrationTimer != null) {
      clearTimeout(_registrationTimer);
      _registrationTimer = null;
    }

    List<dynamic> extraHeaders =
        List<dynamic>.from(_extraHeaders ?? <dynamic>[]);

    if (unregister_all) {
      extraHeaders.add('Contact: *$_extraContactParams');
    } else {
      extraHeaders.add('Contact: $_contact;expires=0$_extraContactParams');
    }

    extraHeaders.add('Expires: 0');

    OutgoingRequest request = OutgoingRequest(
        SIP_Method.REGISTER,
        _registrar,
        _client,
        <String, dynamic>{
          'to_uri': _to_uri,
          'call_id': _call_id,
          'cseq': _cseq += 1
        },
        extraHeaders);

    EventManager handlers = EventManager();
    handlers.on(EventOnRequestTimeout(), (EventOnRequestTimeout value) {
      _unregistered(null, CausesType.REQUEST_TIMEOUT);
    });
    handlers.on(EventOnTransportError(), (EventOnTransportError value) {
      _unregistered(null, CausesType.CONNECTION_ERROR);
    });
    handlers.on(EventOnAuthenticated(), (EventOnAuthenticated response) {
      // Increase the CSeq on authentication.

      _cseq += 1;
    });
    handlers.on(EventOnReceiveResponse(), (EventOnReceiveResponse event) {
      String status_code = event.response!.status_code.toString();
      if (utils.test2XX(status_code)) {
        _unregistered(event.response);
      } else if (utils.test1XX(status_code)) {
        // Ignore provisional responses.
      } else {
        String cause = utils.sipErrorCause(event.response!.status_code);
        _unregistered(event.response, cause);
      }
    });

    RequestSender request_sender = RequestSender(_client, request, handlers);

    request_sender.send();
  }

  void close() {
    if (_registered) {
      unregister(false);
    }
  }

  void onTransportState(SIP_SocketStateEnum state, SIP_StatusLine status) {
    if (state == SIP_SocketStateEnum.CONNECTED || state == SIP_SocketStateEnum.RECONNECTED) {
      _state = state == SIP_SocketStateEnum.RECONNECTED ? SIP_StateEnum.RECONNECTING : SIP_StateEnum.CONNECTED;
      
      unregister(true);
      register();
    } else if (state == SIP_SocketStateEnum.DISCONNECTING) {
      _client.transactions.removeAll().forEach((TransactionBase transaction) {
        transaction.onTransportError();
      });
    } else if (state == SIP_SocketStateEnum.DISCONNECTED) {
      _state = SIP_StateEnum.DISCONNECTED;
      _registering = false;
      
      if (_registrationTimer != null) {
        clearTimeout(_registrationTimer);
        _registrationTimer = null;
      }

      if (_registered) {
        _registered = false;
        _notifyOnUnRegistered();
      }
    }

    _client.emit('sip.state', [_state, status]);

    if (state == SIP_SocketStateEnum.DISCONNECTED) {
      logger.wtf('[SIP_CLIENT] SOCKET_STATE        -> ${state.name} -- ${status.code}, ${status.reason}');
    } else {
      logger.wtf('[SIP_CLIENT] SOCKET_STATE        -> ${state.name}');
    }
  }

  void _registrationFailure(dynamic response, String cause) {
    _registering = false;

    _notifyOnRegistrationFailed(response: response, cause: cause);

    if (_registered) {
      _registered = false;
      _notifyOnUnRegistered(response: response, cause: cause);
    }
  }

  void _unregistered([dynamic response, String? cause]) {
    _registering = false;
    _registered = false;
    _notifyOnUnRegistered(response: response, cause: cause);
  }

  /**
   * Registered
   */
  void _notifyOnRegistered(dynamic response) {
    _state = SIP_StateEnum.REGISTERED;

    SIP_StatusLine status = SIP_StatusLine(response.status_code, response.reason_phrase);
    _client.emit('sip.state', [_state, status]);
    logger.wtf('[SIP_CLIENT] REGISTRATION_STATE  -> ${state.name} -- ${status.code}, ${status.reason}');
  }

  /**
   * Unregistered
   */
  void _notifyOnUnRegistered({dynamic response, String? cause}) {
    _state = SIP_StateEnum.UNREGISTERED;

    SIP_StatusLine status = SIP_StatusLine(response?.status_code ?? 0, response?.reason_phrase ?? '');
    _client.emit('sip.state', [_state, status]);
    logger.wtf('[SIP_CLIENT] REGISTRATION_STATE  -> ${state.name} -- ${status.code}, ${status.reason}');
  }

  /**
   * Registration Failed
   */
  void _notifyOnRegistrationFailed({required dynamic response, String? cause}) {
    _state = SIP_StateEnum.REGISTRATION_FAILED;
    
    SIP_StatusLine status = SIP_StatusLine(response.status_code, '${response.reason_phrase} - ${utils.sipErrorCause(response.status_code)}');
    _client.emit('sip.state', [_state, status]);
    logger.wtf('[SIP_CLIENT] REGISTRATION_STATE  -> ${state.name} -- ${status.code}, ${status.reason}');
  }
}
