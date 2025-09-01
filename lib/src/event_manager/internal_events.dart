import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../constants.dart';
import '../event_manager/event_manager.dart';
import '../rtc_session.dart' show RTCSession;
import '../sip_message.dart';

class EventStateChanged extends EventType {}

class EventOnAuthenticated extends EventType {
  EventOnAuthenticated({this.request});
  OutgoingRequest? request;
}

class EventSucceeded extends EventType {
  EventSucceeded({this.response, this.originator});
  SIP_Originator? originator;
  IncomingMessage? response;
}

class EventOnTransportError extends EventType {
  EventOnTransportError() : super();
}

class EventOnRequestTimeout extends EventType {
  EventOnRequestTimeout({this.request});
  IncomingMessage? request;
}

class EventOnReceiveResponse extends EventType {
  EventOnReceiveResponse({this.response});
  IncomingResponse? response;

  @override
  void sanityCheck() {
    assert(response != null);
  }
}

class EventOnDialogError extends EventType {
  EventOnDialogError({this.response});
  IncomingMessage? response;
}

class EventOnSuccessResponse extends EventType {
  EventOnSuccessResponse({this.response});
  IncomingMessage? response;
}

class EventOnErrorResponse extends EventType {
  EventOnErrorResponse({this.response});
  IncomingMessage? response;
}

class EventCallFailed extends EventType {
  EventCallFailed(
      {this.session,
      String? state,
      this.response,
      this.originator,
      MediaStream? stream,
      this.cause,
      this.request,
      this.status_line});
  RTCSession? session;
  String? get id => session!.id;
  dynamic response;
  SIP_Originator? originator;
  ErrorCause? cause;
  dynamic request;
  String? status_line;
}