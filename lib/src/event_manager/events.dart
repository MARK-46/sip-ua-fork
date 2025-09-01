import 'dart:async';

class EventEmitter {
  final Map<String, StreamController<List<dynamic>>> _controllers = {};

  void on(String event, Function listener) {
    _getController(event).stream.listen((args) {
      _callWithParameters(listener, args);
    });
  }

  void once(String event, Function listener) {
    late StreamSubscription subscription;
    subscription = _getController(event).stream.listen((args) {
      _callWithParameters(listener, args);
      subscription.cancel();
    });
  }

  void emit(String event, [List<dynamic> args = const []]) {
    if (_controllers.containsKey(event)) {
      _controllers[event]!.add(args);
    }
  }

  void off(String? event) {
    if (event == null) {
      for (var controller in _controllers.values) {
        controller.close();
      }
      _controllers.clear();
    } else {
      if (_controllers.containsKey(event)) {
        _controllers[event]!.close();
        _controllers.remove(event);
      }
    }
  }

  StreamController<List<dynamic>> _getController(String event) {
    if (!_controllers.containsKey(event)) {
      _controllers[event] = StreamController.broadcast();
    }
    return _controllers[event]!;
  }

  void _callWithParameters(Function function, List<dynamic> args) {
    try {
      Function.apply(function, args);
    } catch (e) {
      
    }
  }
}

class ErrorCause {
  ErrorCause({this.status_code, this.cause, this.reason_phrase});
  @override
  String toString() {
    return 'Code: [$status_code], Cause: $cause, Reason: $reason_phrase';
  }

  int? status_code;
  String? cause;
  String? reason_phrase;
}
