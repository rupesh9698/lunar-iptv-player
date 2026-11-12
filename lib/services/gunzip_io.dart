import 'dart:io';
import 'dart:typed_data';

/// Unpacks gzip [bytes].
Future<Uint8List> gunzipBytes(Uint8List bytes) async =>
    Uint8List.fromList(gzip.decode(bytes));
