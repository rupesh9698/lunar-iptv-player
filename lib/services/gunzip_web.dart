import 'dart:js_interop';
import 'dart:typed_data';

// The browser's own gzip support (DecompressionStream): fast, native code,
// no Dart gzip on the web.

@JS('Blob')
extension type _Blob._(JSObject _) implements JSObject {
  external factory _Blob(JSArray<JSAny> parts);
  external _Stream stream();
}

@JS('ReadableStream')
extension type _Stream._(JSObject _) implements JSObject {
  external _Stream pipeThrough(JSObject transform);
}

@JS('DecompressionStream')
extension type _Decompression._(JSObject _) implements JSObject {
  external factory _Decompression(String format);
}

@JS('Response')
extension type _Response._(JSObject _) implements JSObject {
  external factory _Response(JSObject body);
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

/// Unpacks gzip [bytes].
Future<Uint8List> gunzipBytes(Uint8List bytes) async {
  final blob = _Blob(<JSAny>[bytes.toJS].toJS);
  final unpacked = blob.stream().pipeThrough(_Decompression('gzip'));
  final buf = await _Response(unpacked).arrayBuffer().toDart;
  return buf.toDart.asUint8List();
}
