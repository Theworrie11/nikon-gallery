// lib/ptpip.dart
// Minimal PTP/IP client (port 15740) - Nikon Z7 II ke liye.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

class PtpException implements Exception {
  PtpException(this.message);
  final String message;
  @override
  String toString() => message;
}

class PtpResponse {
  PtpResponse(this.code, this.data);
  final int code;
  final Uint8List data;
}

class _Packet {
  _Packet(this.type, this.payload);
  final int type;
  final Uint8List payload;
}

/// Socket se exact-size packets padhne wala helper.
class _PacketReader {
  _PacketReader(Stream<Uint8List> stream) {
    stream.listen(
      (d) {
        _chunks.add(d);
        _avail += d.length;
        _wake();
      },
      onError: (Object e) {
        _error = e;
        _wake();
      },
      onDone: () {
        _done = true;
        _wake();
      },
    );
  }

  final List<Uint8List> _chunks = [];
  int _avail = 0;
  Object? _error;
  bool _done = false;
  Completer<void>? _waiter;

  void _wake() {
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<Uint8List> _read(int n) async {
    while (_avail < n) {
      if (_error != null) throw PtpException('Network error: $_error');
      if (_done) throw PtpException('Camera ne connection band kar diya');
      _waiter = Completer<void>();
      await _waiter!.future;
    }
    final out = Uint8List(n);
    var pos = 0;
    while (pos < n) {
      final c = _chunks.first;
      final take = min(n - pos, c.length);
      out.setRange(pos, pos + take, c);
      if (take == c.length) {
        _chunks.removeAt(0);
      } else {
        _chunks[0] = Uint8List.sublistView(c, take);
      }
      pos += take;
    }
    _avail -= n;
    return out;
  }

  Future<_Packet> packet() async {
    final head = await _read(8);
    final bd = ByteData.sublistView(head);
    final len = bd.getUint32(0, Endian.little);
    final type = bd.getUint32(4, Endian.little);
    if (len < 8) throw PtpException('Kharab PTP/IP packet mila');
    final payload = len > 8 ? await _read(len - 8) : Uint8List(0);
    return _Packet(type, payload);
  }
}

class PtpIpClient {
  static const int port = 15740;
  static const int ok = 0x2001;

  Socket? _cmd;
  Socket? _evt;
  _PacketReader? _reader;
  int _tid = 0;
  Future<void> _lock = Future<void>.value();

  bool get connected => _cmd != null;

  static final Uint8List _guid = Uint8List.fromList(
      [0x46, 0x6c, 0x75, 0x74, 0x74, 0x65, 0x72, 0x4e, 0x69, 0x6b, 0x6f, 0x6e, 0x5a, 0x37, 0x49, 0x49]);

  // ---------- helpers ----------
  static Uint8List _u32(int v) =>
      (Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little));
  static Uint8List _u16(int v) =>
      (Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little));

  static Uint8List _utf16z(String s) {
    final units = s.codeUnits;
    final out = Uint8List((units.length + 1) * 2);
    for (var i = 0; i < units.length; i++) {
      out[i * 2] = units[i] & 0xff;
      out[i * 2 + 1] = (units[i] >> 8) & 0xff;
    }
    return out;
  }

  static Uint8List _packet(int type, List<int> payload) {
    final b = BytesBuilder();
    b.add(_u32(payload.length + 8));
    b.add(_u32(type));
    b.add(payload);
    return b.toBytes();
  }

  void _check(PtpResponse r, String what) {
    if (r.code != ok) {
      throw PtpException('$what fail hua (PTP code 0x${r.code.toRadixString(16)})');
    }
  }

  Future<T> _locked<T>(Future<T> Function() fn) {
    final completer = Completer<T>();
    final prev = _lock;
    _lock = completer.future.then((_) {}, onError: (_) {});
    prev.then((_) async {
      try {
        completer.complete(await fn());
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  void _closeSockets() {
    _cmd?.destroy();
    _evt?.destroy();
    _cmd = null;
    _evt = null;
    _reader = null;
  }

  // ---------- connect / disconnect ----------
  Future<void> connect(String host) async {
    await disconnect();
    try {
      final cmd = await Socket.connect(host, port, timeout: const Duration(seconds: 8));
      cmd.setOption(SocketOption.tcpNoDelay, true);
      final reader = _PacketReader(cmd);
      _cmd = cmd;
      _reader = reader;

      final init = BytesBuilder()
        ..add(_guid)
        ..add(_utf16z('FlutterApp'))
        ..add(_u32(0x00010000));
      cmd.add(_packet(1, init.toBytes()));

      final ack = await reader.packet().timeout(const Duration(seconds: 10));
      if (ack.type == 5) {
        throw PtpException('Camera ne connection reject kiya (Init_Fail). '
            'Camera menu me Wi-Fi connection dobara start karo.');
      }
      if (ack.type != 2 || ack.payload.length < 4) {
        throw PtpException('Camera ka jawab samajh nahi aaya (type ${ack.type})');
      }
      final connNum = ByteData.sublistView(ack.payload).getUint32(0, Endian.little);

      final evt = await Socket.connect(host, port, timeout: const Duration(seconds: 8));
      evt.setOption(SocketOption.tcpNoDelay, true);
      _evt = evt;
      final evtReader = _PacketReader(evt);
      evt.add(_packet(3, _u32(connNum)));
      final eack = await evtReader.packet().timeout(const Duration(seconds: 10));
      if (eack.type != 4) {
        throw PtpException('Event channel open nahi hua (type ${eack.type})');
      }

      // OpenSession (0x1002) - session id 1
      final r = await _transact(0x1002, [1]);
      if (r.code != ok && r.code != 0x201e) {
        // 0x201e = SessionAlreadyOpen (theek hai)
        throw PtpException('OpenSession fail (code 0x${r.code.toRadixString(16)})');
      }
    } on SocketException catch (e) {
      _closeSockets();
      throw PtpException('Camera se connect nahi hua: ${e.message}. '
          'Phone camera ke Wi-Fi par hai? IP sahi hai?');
    } on TimeoutException {
      _closeSockets();
      throw PtpException('Camera ne time par jawab nahi diya');
    } catch (_) {
      _closeSockets();
      rethrow;
    }
  }

  Future<void> disconnect() async {
    if (_cmd != null) {
      try {
        await _transact(0x1003, []).timeout(const Duration(seconds: 2)); // CloseSession
      } catch (_) {}
    }
    _closeSockets();
  }

  // ---------- core transaction ----------
  Future<PtpResponse> _transact(int op, List<int> params, {void Function(Uint8List)? onData}) {
    return _locked(() async {
      final reader = _reader;
      final sock = _cmd;
      if (reader == null || sock == null) {
        throw PtpException('Camera connected nahi hai');
      }
      final tid = ++_tid;
      final p = BytesBuilder()
        ..add(_u32(1)) // data phase: none / data-in
        ..add(_u16(op))
        ..add(_u32(tid));
      for (final x in params) {
        p.add(_u32(x));
      }
      sock.add(_packet(6, p.toBytes()));

      final data = BytesBuilder(copy: false);
      try {
        while (true) {
          final pk = await reader.packet().timeout(const Duration(seconds: 60));
          switch (pk.type) {
            case 10: // Data_Packet
            case 12: // End_Data_Packet
              if (pk.payload.length > 4) {
                final chunk = Uint8List.sublistView(pk.payload, 4);
                if (onData != null) {
                  onData(chunk);
                } else {
                  data.add(chunk);
                }
              }
              break;
            case 7: // Cmd_Response
              final code = ByteData.sublistView(pk.payload).getUint16(0, Endian.little);
              return PtpResponse(code, data.takeBytes());
            case 13: // Ping -> Pong
              sock.add(_packet(14, const []));
              break;
            default:
              break; // Start_Data_Packet etc.
          }
        }
      } on TimeoutException {
        _closeSockets();
        throw PtpException('Camera ne jawab dena band kar diya. Dobara connect karo.');
      }
    });
  }

  // ---------- high level ----------
  static List<int> _parseU32Array(Uint8List d) {
    if (d.length < 4) return [];
    final bd = ByteData.sublistView(d);
    final count = bd.getUint32(0, Endian.little);
    final n = min(count, (d.length - 4) ~/ 4);
    return [for (var i = 0; i < n; i++) bd.getUint32(4 + i * 4, Endian.little)];
  }

  /// Saare JPEG photos ke handles (naye pehle).
  Future<List<int>> listJpegHandles() async {
    // storage 0xFFFFFFFF = sab cards, format 0x3801 = JPEG, parent 0 = sab folders
    final r = await _transact(0x1007, [0xFFFFFFFF, 0x3801, 0]);
    _check(r, 'Photo list');
    return _parseU32Array(r.data).reversed.toList();
  }

  /// Low-res thumbnail (JPEG bytes). shouldRun false ho to skip (scroll se bahar).
  Future<Uint8List?> getThumb(int handle, {bool Function()? shouldRun}) {
    return _locked(() async {
      if (shouldRun != null && !shouldRun()) return null;
      final r = await _transact0(0x100a, [handle]);
      if (r.code != ok || r.data.isEmpty) return null;
      return r.data;
    });
  }

  // _locked ke andar se call karne ke liye (lock dobara nahi leta).
  Future<PtpResponse> _transact0(int op, List<int> params) async {
    // _locked pehle se hold hai, isliye seedha internal transaction chalao.
    final reader = _reader;
    final sock = _cmd;
    if (reader == null || sock == null) throw PtpException('Camera connected nahi hai');
    final tid = ++_tid;
    final p = BytesBuilder()
      ..add(_u32(1))
      ..add(_u16(op))
      ..add(_u32(tid));
    for (final x in params) {
      p.add(_u32(x));
    }
    sock.add(_packet(6, p.toBytes()));
    final data = BytesBuilder(copy: false);
    try {
      while (true) {
        final pk = await reader.packet().timeout(const Duration(seconds: 60));
        if (pk.type == 10 || pk.type == 12) {
          if (pk.payload.length > 4) data.add(Uint8List.sublistView(pk.payload, 4));
        } else if (pk.type == 7) {
          final code = ByteData.sublistView(pk.payload).getUint16(0, Endian.little);
          return PtpResponse(code, data.takeBytes());
        } else if (pk.type == 13) {
          sock.add(_packet(14, const []));
        }
      }
    } on TimeoutException {
      _closeSockets();
      throw PtpException('Camera ne jawab dena band kar diya. Dobara connect karo.');
    }
  }

  /// Original file ka naam (GetObjectInfo se).
  Future<String> getFileName(int handle) async {
    final r = await _transact(0x1008, [handle]);
    _check(r, 'GetObjectInfo');
    final d = r.data;
    var name = 'DSC_$handle.JPG';
    if (d.length > 53) {
      final len = d[52];
      final units = <int>[];
      for (var i = 0; i < len; i++) {
        final o = 53 + i * 2;
        if (o + 1 >= d.length) break;
        final u = d[o] | (d[o + 1] << 8);
        if (u != 0) units.add(u);
      }
      if (units.isNotEmpty) name = String.fromCharCodes(units);
    }
    return name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  }

  /// Poori photo download - data chunks onData me aate hain (file me likho).
  Future<void> downloadObject(int handle, void Function(Uint8List) onData) async {
    final r = await _transact(0x1009, [handle], onData: onData);
    _check(r, 'Photo download');
  }
}
