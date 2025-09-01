import '../transports/socket_interface.dart';
import '../event_manager/event_manager.dart';
import '../sip_message.dart';
import '../sip_client.dart';

enum TransactionState {
  // Transaction states.
  TRYING,
  PROCEEDING,
  CALLING,
  ACCEPTED,
  COMPLETED,
  TERMINATED,
  CONFIRMED
}

abstract class TransactionBase extends EventManager {
  String? id;
  late SIP_Client client;
  SIP_SocketInterface? transport;
  TransactionState? state;
  IncomingMessage? last_response;
  dynamic request;
  void onTransportError();

  void send();

  void receiveResponse(int status_code, IncomingMessage response,
      [void Function()? onSuccess, void Function()? onFailure]) {
    // default NO_OP implementation
  }
}
