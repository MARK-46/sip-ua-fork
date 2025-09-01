import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'logger.dart';
import 'config.dart';
import 'constants.dart';
import 'sip_session.dart';
import 'transports/ws_client.dart';
import 'data.dart';
import 'dialog.dart';
import 'message.dart';
import 'options.dart';
import 'parser.dart' as Parser;
import 'sip_registrator.dart';
import 'rtc_session.dart';
import 'sanity_check.dart';
import 'sip_message.dart';
import 'timers.dart';
import 'transactions/invite_client.dart';
import 'transactions/invite_server.dart';
import 'transactions/non_invite_client.dart';
import 'transactions/non_invite_server.dart';
import 'transactions/transactions.dart';
import 'transports/socket_interface.dart';
import 'event_manager/event_manager.dart';
import 'uri.dart';
import 'utils.dart' as Utils;


class Contact {
  Contact(this.uri);

  String? pub_gruu;
  String? temp_gruu;
  bool anonymous = false;
  bool outbound = false;
  URI? uri;

  @override
  String toString() {
    String contact = '<';
    if (anonymous) {
      contact += temp_gruu ?? 'sip:anonymous@anonymous.invalid;transport=ws';
    } else {
      contact += pub_gruu ?? uri.toString();
    }

    if (outbound && (anonymous ? temp_gruu == null : pub_gruu == null)) {
      contact += ';ob';
    }

    contact += '>';
    return contact;
  }
}

/**
 * The User-Agent class.
 * @class DartSIP.SIP_Client
 * @param {Object} configuration Configuration parameters.
 * @throws {TypeError} If no configuration is given.
 */
class SIP_Client extends EventEmitter {
  final SIP_Settings              _settings;
  late final SIP_SocketInterface  _socket;
  final SIP_Sessions              _sessions = <String, SIP_Session>{};
  final Map<String, Dialog>       _dialogs = <String, Dialog>{};
  final Set<Applicant>            _applicants = <Applicant>{};
  final TransactionBag            _transactions = TransactionBag();

  Contact? _contact;
  Registrator? _registrator;
  bool _stopping = false;

  Contact? get contact => _contact;
  SIP_Sessions get sessions => _sessions;
  SIP_Settings get configuration => _settings;
  SIP_SocketInterface? get transport => _socket;
  TransactionBag get transactions => _transactions;
  SIP_StateEnum get state => _registrator?.state ?? SIP_StateEnum.DISCONNECTED;

  SIP_Client(this._settings) {
    // SIP_UASettings.
    _loadSettings();

    // SIP_SocketInterface.
    _initSocket();

    // Registrator.
    _registrator = Registrator(this);
  }

  /**
   * Connect to the server if status = STATUS_INIT.
   * Resume SIP_Client after being closed.
   */
  Future<bool> connect() async {
    logger.d('SIP_Client - connect()');

    if (_socket.isConnected()) {
      logger.d('SIP_Client already connected! State: ${state.name}');
      return Future.value(false);
    }

    // Connecting
    await _socket.connect();
    
    return _socket.isConnected();
  }

  /**
   * Register.
   */
  bool register() {
    logger.d('SIP_Client - register()');

    if (_socket.isConnected() == false) {
      logger.d('SIP_Client is not connected! State: ${state.name}');
      return false;
    }

    _registrator?.register();
    return true;
  }

  /**
   * Unregister.
   */
  bool unregister() {
    logger.d('SIP_Client - unregister()');

    if (_socket.isConnected() == false) {
      logger.d('SIP_Client is not connected! State: ${state.name}');
      return false;
    }

    _registrator?.unregister(true);
    return true;
  }

  /**
   * Gracefully close.
   */
  Future<bool> disconnect() async {
    logger.d('SIP_Client - disconnect()');

    if (_socket.isConnected() == false) {
      logger.d('SIP_Client already closed! State: ${state.name}');
      return false;
    }
    
    // Close registrator.
    _registrator?.close();

    // If there are session wait a bit so CANCEL/BYE can be sent and their responses received.
    int num_sessions = _sessions.length;

    // Run  _terminate_ on every Session.
    terminateSessions({});

    _stopping = true;

    // Run  _close_ on every applicant.
    for (Applicant applicant in _applicants) {
      try {
        applicant.close();
      } catch (error) {}
    }
    
    int num_transactions = _transactions.countTransactions();
    if (num_transactions == 0 && num_sessions == 0) {
      await _socket.disconnect(1000, 'stop sip');
      return !_socket.isConnected();
    } else {
      final completer = Completer<bool>();
      setTimeout(() async {
        logger.i('Closing connection');
        await _socket.disconnect(1000, 'stop sip');
        completer.complete(!_socket.isConnected());
      }, 2000);
      return completer.future;
    }
  }

  /**
   * Make an outgoing call.
   */
  Future<bool> call(String target, {bool voiceOnly = true, MediaStream? mediaStream, List<String>? headers}) async {
    logger.d('SIP_Client - call()');
    
    if (state != SIP_StateEnum.REGISTERED) {
      logger.d('SIP_Client is not registered! State: ${state.name}');
      return false;
    }

    if (_sessions.containsKey(target)) {
      logger.e('already exists session with target $target');
      return false;
    }
    
    RTCSession session = RTCSession(this, this);
    session.connect(target, voiceOnly, mediaStream, headers);

    return true;
  }

  Future<bool> answer(String target) async {
    if (!_sessions.containsKey(target)) {
      logger.e('no session with target $target');
      return false;
    }

    return _sessions[target]!.answer();
  }

  Future<bool> hangup(String target) async {
    if (!_sessions.containsKey(target)) {
      logger.e('no session with target $target');
      return false;
    }

    return _sessions[target]!.hangup({});
  }
  
  Future<bool> setMicEnabled(String target, bool enabled) async {
    if (!_sessions.containsKey(target)) {
      logger.e('no session with target $target');
      return false;
    }

    return _sessions[target]!.setMicEnabled(enabled);
  }

  Future<bool> setVideoEnabled(String target, bool enabled) async {
    if (!_sessions.containsKey(target)) {
      logger.e('no session with target $target');
      return false;
    }

    return _sessions[target]!.setVideoEnabled(enabled);
  }

  Future<bool> setHoldEnabled(String target, bool enabled) async {
    if (!_sessions.containsKey(target)) {
      logger.e('no session with target $target');
      return false;
    }

    return _sessions[target]!.setHoldEnabled(enabled);
  }

  Future<bool> setAudioState(String target, SIP_AudioEnum state) async {
    if (!_sessions.containsKey(target)) {
      logger.e('no session with target $target');
      return false;
    }

    return _sessions[target]!.setAudioState(state);
  }

  /**
   * Send a Options.
   *
   * -param {String} target
   * -param {String} body
   * -param {Object} [options]
   *
   * -throws {TypeError}
   */
  Options sendOptions(String target, String body, Map<String, dynamic>? options) {
    logger.d('sendOptions()');
    Options message = Options(this);
    message.send(target, body, options);
    return message;
  }

  /**
   * Terminate ongoing sessions.
   */
  void terminateSessions(Map<String, dynamic> options) {
    logger.d('terminateSessions()');
    _sessions.forEach((_, SIP_Session session) {
      try {
        if (!session.session.isEnded()) {
          session.session.terminate(options);
        }
      } catch (error, s) {
        logger.e(error.toString(), stackTrace: s);
      }
    });
  }

  /**
   * Normalice a string into a valid SIP request URI
   * -param {String} target
   * -returns {DartSIP.URI|null}
   */
  URI? normalizeTarget(String? target) {
    return Utils.normalizeTarget(target, '${_settings.host}:${_settings.port}');
  }

  /**
   * Allow retrieving configuration and autogenerated fields in runtime.
   */
  String? get(String parameter) {
    switch (parameter) {
      case 'realm':
        return _settings.realm;

      case 'ha1':
        return _settings.ha1;

      default:
        logger.e('get() | cannot get "$parameter" parameter in runtime');

        return null;
    }
  }

  /**
   * Allow configuration changes in runtime.
   * Returns true if the parameter could be set.
   */
  bool set(String parameter, dynamic value) {
    switch (parameter) {
      case 'password':
        {
          _settings.password = value.toString();
          break;
        }

      case 'realm':
        {
          _settings.realm = value.toString();
          break;
        }

      case 'ha1':
        {
          _settings.ha1 = value.toString();
          // Delete the plain SIP password.
          _settings.password = null;
          break;
        }

      case 'display_name':
        {
          // _settings.display_name = value;
          break;
        }

      default:
        logger.e('set() | cannot set "$parameter" parameter in runtime');

        return false;
    }

    return true;
  }

  // ==================
  // Event Handlers.
  // ==================

  /**
   * Dialog
   */
  void newDialog(Dialog dialog) {
    _dialogs[dialog.id.toString()] = dialog;
  }

  /**
   * Dialog destroyed.
   */
  void destroyDialog(Dialog dialog) {
    _dialogs.remove(dialog.id.toString());
  }

  /**
   *  Options
   */
  void newOptions(Options message, SIP_Originator originator, dynamic request) {
    if (_stopping) {
      return;
    }
    _applicants.add(message);
  }
  
  /**
   *  Options destroyed.
   */
  void destroyOptions(Options message) {
    if (_stopping) {
      return;
    }
    _applicants.remove(message);
  }

  /**
   * Send a message.
   *
   * -param {String} target
   * -param {String} body
   * -param {Object} [options]
   *
   * -throws {TypeError}
   *
   */
  Message sendMessage(String target, String body, Map<String, dynamic>? options, Map<String, dynamic>? params) {
    logger.d('sendMessage()');
    Message message = Message(this);
    message.send(target, body, options, params);
    return message;
  }

  /**
   *  Message
   */
  void newMessage(Message message, SIP_Originator originator, dynamic request) {
    if (_stopping) {
      return;
    }
    _applicants.add(message);
    emit('sip.new_message', [message, originator, request]);
  }

  /**
   *  Message destroyed.
   */
  void destroyMessage(Message message) {
    if (_stopping) {
      return;
    }
    _applicants.remove(message);
  }


  // ============
  // Utils.
  // ============

  void _receiveRequest(IncomingRequest request) {
    SIP_Method? method = request.method;

    // Check that request URI points to us.
    if (request.ruri!.user != _settings.username && request.ruri!.user != _contact!.uri!.user) {
      logger.d('Request-URI does not point to us');
      if (request.method != SIP_Method.ACK) {
        request.reply_sl(404);
      }

      return;
    }

    // Check request URI scheme.
    if (request.ruri!.scheme == SIPS) {
      request.reply_sl(416);

      return;
    }

    // Check transaction.
    if (checkTransaction(_transactions, request)) {
      return;
    }

    // Create the server transaction.
    if (method == SIP_Method.INVITE) {
      /* eslint-disable no-*/
      InviteServerTransaction(this, _socket, request);
      /* eslint-enable no-*/
    } else if (method != SIP_Method.ACK && method != SIP_Method.CANCEL) {
      /* eslint-disable no-*/
      NonInviteServerTransaction(this, _socket, request);
      /* eslint-enable no-*/
    }

    /* RFC3261 12.2.2
     * Requests that do not change in any way the state of a dialog may be
     * received within a dialog (for example, an OPTIONS request).
     * They are processed as if they had been received outside the dialog.
     */
    if (method == SIP_Method.OPTIONS) {
      request.reply(200);
      // Options message = Options(this);
      // message.init_incoming(request);
      return;
    } else if (method == SIP_Method.MESSAGE) {
      // request.reply(405);
      Message message = Message(this);
      message.init_incoming(request);
      return;
    } else if (method == SIP_Method.INVITE) {
      // Initial INVITE.
    } else if (method == SIP_Method.SUBSCRIBE) {
      request.reply(405);
      return;
    }

    Dialog? dialog;
    RTCSession? session;

    // Initial Request.
    if (request.to_tag == null) {
      switch (method) {
        case SIP_Method.INVITE:
          if (request.hasHeader('replaces')) {
            ParsedData replaces = request.replaces;

            dialog = _findDialog(
                replaces.call_id, replaces.from_tag!, replaces.to_tag!);
            if (dialog != null) {
              session = dialog.owner as RTCSession?;
              if (!session!.isEnded()) {
                session.receiveRequest(request);
              } else {
                request.reply(603);
              }
            } else {
              request.reply(481);
            }
          } else {
            session = RTCSession(this, this);
            session.init_incoming(request);
          }
          break;
        case SIP_Method.BYE:
          // Out of dialog BYE received.
          request.reply(481);
          break;
        case SIP_Method.CANCEL:
          session = _findSession(request.call_id!, request.from_tag, request.to_tag);
          if (session != null) {
            session.receiveRequest(request);
          } else {
            logger.d('received CANCEL request for a non existent session');
          }
          break;
        case SIP_Method.ACK:
          /* Absorb it.
           * ACK request without a corresponding Invite Transaction
           * and without To tag.
           */
          break;
        case SIP_Method.NOTIFY:
          // Receive sip event.
          request.reply(200);
          break;
        case SIP_Method.SUBSCRIBE:
          break;
        default:
          request.reply(405);
          break;
      }
    }
    // In-dialog request.
    else {
      dialog = _findDialog(request.call_id!, request.from_tag!, request.to_tag!);

      if (dialog != null) {
        dialog.receiveRequest(request);
      } else if (method == SIP_Method.NOTIFY) {
        logger.d('received NOTIFY request for a non existent subscription');
        request.reply(481, 'Subscription does not exist');
      }

      /* RFC3261 12.2.2
       * Request with to tag, but no matching dialog found.
       * Exception: ACK for an Invite request for which a dialog has not
       * been created.
       */
      else if (method != SIP_Method.ACK) {
        request.reply(481);
      }
    }
  }

  RTCSession? _findSession(String call_id, String? from_tag, String? to_tag) {
    String sessionIDa = call_id + (from_tag ?? '');
    String sessionIDb = call_id + (to_tag ?? '');
    return _sessions.values.firstWhereOrNull((SIP_Session session) => 
      session.session.id == sessionIDa || session.session.id == sessionIDb
    )?.session;
  }

  Dialog? _findDialog(String call_id, String from_tag, String to_tag) {
    String id = call_id + from_tag + to_tag;
    Dialog? dialog = _dialogs[id];

    if (dialog != null) {
      return dialog;
    } else {
      id = call_id + to_tag + from_tag;
      dialog = _dialogs[id];
      if (dialog != null) {
        return dialog;
      } else {
        return null;
      }
    }
  }

  void _initSocket() {
    if (_settings.socket_uri == null) {
      throw Exception('Socket URL cannot be null');
    }

    switch (_settings.socket_type) {
      case SIP_SocketType.WS:
        _socket = WSClient(_settings.socket_uri);
        break;
      case SIP_SocketType.TCP:
      case SIP_SocketType.UDP:
        throw Exception('${_settings.socket_type.name} not supported yet.');
    }

    // SIP_SocketInterface Events.
    _socket.on(SIP_SocketInterface.SC_CONNECTING, (String adrr) => _onTransportConnectionChanged(state: _socket.state));
    _socket.on(SIP_SocketInterface.SC_CONNECT, (String adrr) => _onTransportConnectionChanged(state: _socket.state));
    _socket.on(SIP_SocketInterface.SC_DISCONNECT, (int code, String reason) => _onTransportConnectionChanged(state: _socket.state, code: code, reason: reason));
    _socket.on(SIP_SocketInterface.SC_DATA, (dynamic data) => _onTransportData(data));
  }

  void _loadSettings() {
    // Contact URI.
    _contact = Contact(_settings.contact_uri);
  }

  void _onTransportConnectionChanged({required SIP_SocketStateEnum state, int? code, String? reason}) {
    SIP_StatusLine status = SIP_StatusLine(code ?? 0, reason ?? '');
    emit('sip.socket.state', [state, status]);
    _registrator?.onTransportState(state, status);
  }

  void _onTransportData(String messageData) {
    emit('sip.socket.message', [messageData]);
    IncomingMessage? message = Parser.parseMessage(messageData, this);

    if (message == null) {
      return;
    }

    // Do some sanity check.
    if (!sanityCheck(message, this, _socket)) {
      return;
    }

    if (message is IncomingRequest) {
      message.transport = transport;
      _receiveRequest(message);
    } else if (message is IncomingResponse) {
      /* 
       * Unike stated in 18.1.2, if a response does not match
       * any transaction, it is discarded here and no passed to the core
       * in order to be discarded there.
       */
      switch (message.method) {
        case SIP_Method.INVITE:
          InviteClientTransaction? transaction = _transactions.getTransaction(InviteClientTransaction, message.via_branch!);
          if (transaction != null) {
            transaction.receiveResponse(message.status_code, message);
          }
          break;
        case SIP_Method.ACK:
          // Just in case ;-).
          break;
        default:
          NonInviteClientTransaction? transaction = _transactions.getTransaction(NonInviteClientTransaction, message.via_branch!);
          if (transaction != null) {
            transaction.receiveResponse(message.status_code, message);
          }
          break;
      }
    }
  }
}

mixin Applicant {
  void close();
}
