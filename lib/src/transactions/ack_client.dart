import '../sip_message.dart';
import '../transports/socket_interface.dart';
import '../event_manager/event_manager.dart';
import '../event_manager/internal_events.dart';
import '../logger.dart';
import '../sip_client.dart';
import '../utils.dart';
import 'transaction_base.dart';

class AckClientTransaction extends TransactionBase {
  AckClientTransaction(SIP_Client client, SIP_SocketInterface transport, OutgoingRequest request,
      EventManager eventHandlers) {
    id = 'z9hG4bK${(Math.random() * 10000000).floor()}';
    this.transport = transport;
    this.request = request;
    _eventHandlers = eventHandlers;

    String via = 'SIP/2.0/${transport.protocol.name}';

    via += ' ${client.configuration.local_ip};branch=$id';

    request.setHeader('via', via);
  }

  late EventManager _eventHandlers;

  @override
  void send() {
    if (!transport!.send(request)) {
      onTransportError();
    }
  }

  @override
  void onTransportError() {
    logger.d('transport error occurred for transaction $id');
    _eventHandlers.emit(EventOnTransportError());
  }
}
