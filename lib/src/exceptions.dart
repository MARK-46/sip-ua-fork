class ErrorImpl extends Error {
  ErrorImpl(this.code, this.name, this.message, {this.parameter, this.value, this.status});
  int code;
  String name;
  String? parameter;
  dynamic value;
  String? message;
  dynamic status;
}

class InvalidStateError extends ErrorImpl {
  InvalidStateError(dynamic status)
      : super(2, 'INVALID_STATE_ERROR', 'Invalid status: $status',
            status: status);
}

class NotSupportedError extends ErrorImpl {
  NotSupportedError(String message) : super(3, 'NOT_SUPPORTED_ERROR', message);
}

class NotReadyError extends ErrorImpl {
  NotReadyError(String message) : super(4, 'NOT_READY_ERROR', message);
}

class TypeError extends AssertionError {
  TypeError(String message) : super(message);
}
