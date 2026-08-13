/// dart2js entry point for the Ranking Lab.
///
/// Publishes exactly one global, `rankLab(jsonString) -> jsonString`. Keeping
/// the boundary to a single string-in/string-out function means the UI never
/// depends on how Dart objects happen to be represented in JS, and the same
/// [handleRequest] can be driven from a plain Dart test on the VM.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'lab_kernel.dart';

void main() {
  globalContext['rankLab'] = ((JSString req) => handleRequest(req.toDart).toJS).toJS;
  globalContext['rankLabReady'] = true.toJS;
}
