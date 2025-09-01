import 'package:sip_fork/src/event_manager/events.dart';

enum SIP_SocketStateEnum {
  CONNECTING,
  CONNECTED,

  RECONNECTING,
  RECONNECTED,

  DISCONNECTING,
  DISCONNECTED;

  static SIP_SocketStateEnum of(String name) => values.firstWhere((e) => e.name == name);
}

enum SIP_SocketProtocolEnum {
  WS,
  TCP,
  UDP;
}

abstract class SIP_SocketInterface extends EventEmitter {
  static final String SC_CONNECTING = 'sc.connecting';
  static final String SC_CONNECT = 'sc.connect';
  static final String SC_DISCONNECT = 'sc.disconnect';
  static final String SC_DATA = 'sc.data';

  String get uri;
  SIP_SocketStateEnum get state;
  SIP_SocketProtocolEnum get protocol;

  bool isConnected();
  bool isConnecting();

  Future<SIP_SocketStateEnum> connect();
  Future disconnect(int? code, String? reason);
  bool send(dynamic message);

  void notifyConnecting(String addr) { emit(SC_CONNECTING, <dynamic>[addr]); }
  void notifyConnect(String addr) { emit(SC_CONNECT, <dynamic>[addr]); }
  void notifyDisconnected(int code, String reason) { emit(SC_DISCONNECT, <dynamic>[code, reason]); }
  void notifyData(dynamic payload) { emit(SC_DATA, <dynamic>[payload]); }
}
