import 'dart:async';
import 'dart:core';

import 'socket_interface.dart';
import 'package:web_socket_client/web_socket_client.dart';


class WSClient extends SIP_SocketInterface {
  WSClient(this._uri);

  final ConstantBackoff backoff = const ConstantBackoff(Duration(seconds: 3));
  final Duration timeout = const Duration(seconds: 10);
  final Duration pingInterval = const Duration(seconds: 5);
  final String _uri;

  WebSocket? _wsc;
  SIP_SocketStateEnum _state = SIP_SocketStateEnum.DISCONNECTED;

  StreamSubscription<ConnectionState>? _connectionSubscription;
  StreamSubscription<dynamic>? _messagesSubscription;
  
  @override
  String get uri => this._uri;

  @override
  SIP_SocketStateEnum get state => _state;

  @override
  SIP_SocketProtocolEnum get protocol => SIP_SocketProtocolEnum.WS;
  
  @override
  bool isConnected() => _state == SIP_SocketStateEnum.CONNECTED || _state == SIP_SocketStateEnum.RECONNECTED;
  
  @override
  bool isConnecting() => _state == SIP_SocketStateEnum.CONNECTING || _state == SIP_SocketStateEnum.RECONNECTING;
  
  @override
  Future<SIP_SocketStateEnum> connect() async {
    try {
      print('[I] WebSocket --- connect -- $uri');
      if (_state == SIP_SocketStateEnum.CONNECTED || _state == SIP_SocketStateEnum.RECONNECTED) {
        return SIP_SocketStateEnum.CONNECTED;
      }

      if (_state == SIP_SocketStateEnum.CONNECTING || _state == SIP_SocketStateEnum.RECONNECTING) {
        await disconnect(1000, 'reconnect');
      }

      final completer = Completer<SIP_SocketStateEnum>();

      _wsc = WebSocket(
        Uri.parse(uri),
        timeout: timeout,
        backoff: backoff,
        pingInterval: pingInterval,
        protocols: <String>['sip'],
        headers: <String, String>{},
      );

      _connectionSubscription = _wsc?.connection.listen((ConnectionState state) {
        print('[I] WebSocket --- state -- $state');
        if (state is Connecting) {
          _state = SIP_SocketStateEnum.CONNECTING;
        } else if (state is Connected) {
          emit('wsc.connect', <dynamic>[]);
          _state = SIP_SocketStateEnum.CONNECTED;
          notifyConnect(uri);
        } else if (state is Reconnecting) {
          _state = SIP_SocketStateEnum.RECONNECTING;
        } else if (state is Reconnected) {
          emit('wsc.connect', <dynamic>[]);
          _state = SIP_SocketStateEnum.RECONNECTED;
          notifyConnect(uri);
        } else if (state is Disconnecting) {
          _state = SIP_SocketStateEnum.DISCONNECTING;
        } else if (state is Disconnected) {
          int code = state.code ?? -1;
          String reason = _parseReason(code, state.reason);
          _state = SIP_SocketStateEnum.DISCONNECTED;
          notifyDisconnected(code, reason);
        }

        if (completer.isCompleted) { // one-time call
          completer.complete(_state);
        }
      });

      _messagesSubscription = _wsc?.messages.listen((dynamic payload) {
        print('[I] WebSocket --- message -- $payload');
        notifyData(payload);
      });

      return completer.future;
    } catch (ex, s) {
      print('[E] WebSocket --- connect -- $ex, $s');
      return SIP_SocketStateEnum.DISCONNECTED;
    }
  }

  @override
  bool send(dynamic payload) {
    try {
      print('[I] WebSocket --- send -- $payload');
      if (_wsc == null) {
        return false;
      }

      if (_state == SIP_SocketStateEnum.CONNECTED || _state == SIP_SocketStateEnum.RECONNECTED) {
        _wsc?.send(payload.toString());
        return true;
      }

      return false;
    } catch (ex, s) {
      print('[E] WebSocket --- send -- $ex, $s');
      return false;
    }
  }

  @override
  Future disconnect(int? code, String? reason) async {
    try {
      print('[I] WebSocket --- disconnect -- $code, $reason');
      code = code ?? -1;
      reason = reason ?? 'Connection lost';

      _connectionSubscription?.cancel();
      _messagesSubscription?.cancel();
      _wsc?.close(code, reason);
      _wsc = null;

      notifyDisconnected(code, reason);
    } catch (ex, s) {
      print('[E] WebSocket --- disconnect -- $ex, $s');
    }
  }

  String _parseReason(int code, String? reason) {
    if (reason != null && reason.isNotEmpty) {
      return reason;
    }

    switch (code) {
      case 1000:
        return 'Normal Closure';
      case 1001:
        return 'Going Away';
      case 1002:
        return 'Protocol Error';
      case 1003:
        return 'Unsupported Data';
      case 1004:
        return '(For future)';
      case 1005:
        return 'No Status Received';
      case 1006:
        return 'Abnormal Closure';
      case 1007:
        return 'Invalid frame payload data';
      case 1008:
        return 'Policy Violation';
      case 1009:
        return 'Message too big';
      case 1010:
        return 'Missing Extension';
      case 1011:
        return 'Internal Error';
      case 1012:
        return 'Service Restart';
      case 1013:
        return 'Try Again Later';
      case 1014:
        return 'Bad Gateway';
      case 1015:
        return 'TLS Handshake';
      default:
        if (code >= 0 && code <= 999) {
          return '(Unused)';
        } else if (code >= 1016) {
          if (code <= 1999) {
            return '(For WebSocket standard)';
          } else if (code <= 2999) {
            return '(For WebSocket extensions)';
          } else if (code <= 3999) {
            return '(For libraries and frameworks)';
          } else if (code <= 4999) {
            return '(For applications)';
          }
        }
    }

    return 'Connection lost';
  }
}
