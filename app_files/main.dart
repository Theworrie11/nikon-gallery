// lib/main.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

import 'ptpip.dart';

void main() => runApp(const NikonApp());

/// Android ko bolta hai ki traffic camera ke Wi-Fi se hi bheje (mobile data se nahi).
class NetworkBinder {
  static const MethodChannel _ch = MethodChannel('camera/network');
  static Future<void> bindWifi() async {
    try {
      await _ch.invokeMethod('bindWifi');
    } catch (_) {}
  }
}

class NikonApp extends StatelessWidget {
  const NikonApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nikon Z7 II Gallery',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.amber,
        brightness: Brightness.dark,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final PtpIpClient _client = PtpIpClient();
  final TextEditingController _ip = TextEditingController(text: '192.168.1.1');
  final Map<int, Uint8List> _thumbCache = {};
  final Set<int> _selected = {};

  List<int> _handles = [];
  bool _connected = false;
  bool _connecting = false;
  bool _loadingList = false;
  bool _downloading = false;
  int _done = 0;
  int _total = 0;
  String? _error;

  @override
  void dispose() {
    _ip.dispose();
    unawaited(_client.disconnect());
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await NetworkBinder.bindWifi();
      await _client.connect(_ip.text.trim());
      final h = await _client.listJpegHandles();
      if (!mounted) return;
      setState(() {
        _handles = h;
        _connected = true;
        _selected.clear();
      });
    } catch (e) {
      await _client.disconnect();
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _refresh() async {
    setState(() => _loadingList = true);
    try {
      final h = await _client.listJpegHandles();
      if (!mounted) return;
      setState(() => _handles = h);
    } catch (e) {
      _snack(e.toString());
    } finally {
      if (mounted) setState(() => _loadingList = false);
    }
  }

  Future<void> _disconnect() async {
    await _client.disconnect();
    if (!mounted) return;
    setState(() {
      _connected = false;
      _handles = [];
      _selected.clear();
      _thumbCache.clear();
    });
  }

  Future<Uint8List?> _loadThumb(int handle, bool Function() alive) async {
    final cached = _thumbCache[handle];
    if (cached != null) return cached;
    try {
      final bytes = await _client.getThumb(handle, shouldRun: alive);
      if (bytes != null) _thumbCache[handle] = bytes;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<void> _download() async {
    if (_selected.isEmpty || _downloading) return;
    try {
      if (!await Gal.hasAccess()) {
        if (!await Gal.requestAccess()) {
          _snack('Gallery me save karne ki permission chahiye');
          return;
        }
      }
    } catch (e) {
      _snack('Permission error: $e');
      return;
    }

    final list = _handles.where(_selected.contains).toList();
    setState(() {
      _downloading = true;
      _done = 0;
      _total = list.length;
    });

    final tmp = await getTemporaryDirectory();
    var failed = 0;
    String? lastErr;

    for (final h in list) {
      File? file;
      try {
        final name = await _client.getFileName(h);
        file = File('${tmp.path}/$name');
        final sink = file.openWrite();
        try {
          await _client.downloadObject(h, sink.add);
        } finally {
          await sink.close();
        }
        await Gal.putImage(file.path, album: 'Nikon Z7II');
      } catch (e) {
        failed++;
        lastErr = e.toString();
      } finally {
        try {
          if (file != null && await file.exists()) await file.delete();
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() => _done++);
    }

    if (!mounted) return;
    setState(() {
      _downloading = false;
      if (failed == 0) _selected.clear();
    });
    _snack(failed == 0
        ? '${list.length} photo(s) gallery me save ho gayi'
        : '${list.length - failed} save hui, $failed fail ($lastErr)');
  }

  @override
  Widget build(BuildContext context) {
    return _connected ? _buildGallery() : _buildConnect();
  }

  Widget _buildConnect() {
    return Scaffold(
      appBar: AppBar(title: const Text('Nikon Z7 II')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: ListView(
          children: [
            const Text(
              '1. Camera me Wi-Fi start karo (Connect to smart device).\n'
              '2. Phone ke Wi-Fi settings me camera ka network join karo '
              '("keep connection / no internet" par YES).\n'
              '3. Neeche Connect dabao.',
              style: TextStyle(height: 1.5),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _ip,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Camera IP',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _connecting ? null : _connect,
              icon: _connecting
                  ? const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.wifi),
              label: Text(_connecting ? 'Connecting...' : 'Connect'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildGallery() {
    return Scaffold(
      appBar: AppBar(
        title: Text(_selected.isEmpty
            ? '${_handles.length} photos'
            : '${_selected.length} selected'),
        actions: [
          IconButton(
            tooltip: 'Sab select karo',
            icon: const Icon(Icons.select_all),
            onPressed: () => setState(() => _selected.addAll(_handles)),
          ),
          IconButton(
            tooltip: 'Selection hatao',
            icon: const Icon(Icons.deselect),
            onPressed: () => setState(_selected.clear),
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loadingList || _downloading ? null : _refresh,
          ),
          IconButton(
            tooltip: 'Disconnect',
            icon: const Icon(Icons.link_off),
            onPressed: _downloading ? null : _disconnect,
          ),
        ],
      ),
      body: _handles.isEmpty
          ? const Center(child: Text('Card me koi JPEG photo nahi mili'))
          : GridView.builder(
              padding: const EdgeInsets.all(2),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 2,
                crossAxisSpacing: 2,
              ),
              itemCount: _handles.length,
              itemBuilder: (context, i) {
                final h = _handles[i];
                return _ThumbTile(
                  key: ValueKey(h),
                  handle: h,
                  selected: _selected.contains(h),
                  loader: _loadThumb,
                  onTap: () => setState(() {
                    if (!_selected.remove(h)) _selected.add(h);
                  }),
                );
              },
            ),
      floatingActionButton: (_selected.isNotEmpty && !_downloading)
          ? FloatingActionButton.extended(
              onPressed: _download,
              icon: const Icon(Icons.download),
              label: Text('Download (${_selected.length})'),
            )
          : null,
      bottomNavigationBar: _downloading
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Downloading $_done / $_total'),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: _total == 0 ? null : _done / _total),
                ],
              ),
            )
          : null,
    );
  }
}

class _ThumbTile extends StatefulWidget {
  const _ThumbTile({
    super.key,
    required this.handle,
    required this.selected,
    required this.loader,
    required this.onTap,
  });

  final int handle;
  final bool selected;
  final Future<Uint8List?> Function(int handle, bool Function() alive) loader;
  final VoidCallback onTap;

  @override
  State<_ThumbTile> createState() => _ThumbTileState();
}

class _ThumbTileState extends State<_ThumbTile> {
  bool _disposed = false;
  late final Future<Uint8List?> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.loader(widget.handle, () => !_disposed);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<Uint8List?>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const ColoredBox(color: Color(0xFF2A2A2A));
              }
              final bytes = snap.data;
              if (bytes == null) {
                return const ColoredBox(
                  color: Color(0xFF2A2A2A),
                  child: Icon(Icons.broken_image, color: Colors.white38),
                );
              }
              return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
            },
          ),
          if (widget.selected) ...[
            ColoredBox(color: Colors.amber.withValues(alpha: 0.35)),
            const Positioned(
              top: 4,
              right: 4,
              child: Icon(Icons.check_circle, color: Colors.amber),
            ),
          ],
        ],
      ),
    );
  }
}
