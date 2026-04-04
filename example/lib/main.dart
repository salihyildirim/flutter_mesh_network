import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_mesh_network/flutter_mesh_network.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatefulWidget {
  const ExampleApp({super.key});

  @override
  State<ExampleApp> createState() => _ExampleAppState();
}

class _ExampleAppState extends State<ExampleApp> {
  final _mesh = MeshNetwork(
    config: const MeshConfig(serviceName: 'mesh-demo'),
  );

  final _messages = <MeshMessage>[];
  bool _running = false;
  StreamSubscription<MeshMessage>? _messageSub;
  StreamSubscription<MeshNode>? _nodeSub;

  @override
  void initState() {
    super.initState();
    _messageSub = _mesh.onMessage.listen((msg) {
      setState(() => _messages.insert(0, msg));
    });
    _nodeSub = _mesh.onNodeChanged.listen((node) {
      setState(() {}); // refresh online count in app bar
    });
  }

  Future<void> _toggle() async {
    try {
      if (_running) {
        await _mesh.stop();
      } else {
        await _mesh.start(userId: 'demo-user', userName: 'Demo');
      }
      setState(() => _running = _mesh.isRunning);
    } catch (e) {
      _showSnackBar('Mesh ${_running ? 'stop' : 'start'} failed: $e');
    }
  }

  Future<void> _send() async {
    if (!_running) return;
    try {
      await _mesh.sendText('Hello from mesh! ${DateTime.now()}');
      _showSnackBar('Message sent');
    } catch (e) {
      _showSnackBar('Send failed: $e');
    }
  }

  void _showSnackBar(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  void dispose() {
    _messageSub?.cancel();
    _nodeSub?.cancel();
    _mesh.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: Text(
            _running
                ? 'Mesh Online (${_mesh.onlineNodeCount} peers)'
                : 'Mesh Offline',
          ),
          actions: [
            IconButton(
              icon: Icon(_running ? Icons.stop : Icons.play_arrow),
              onPressed: _toggle,
            ),
          ],
        ),
        body: _messages.isEmpty
            ? const Center(child: Text('No messages yet'))
            : ListView.builder(
                itemCount: _messages.length,
                itemBuilder: (_, i) {
                  final msg = _messages[i];
                  return ListTile(
                    leading: Icon(
                      msg.type == MessageType.sos
                          ? Icons.warning
                          : Icons.message,
                      color: msg.type == MessageType.sos
                          ? Colors.red
                          : null,
                    ),
                    title: Text(msg.payload),
                    subtitle: Text(
                        '${msg.senderName} - hop ${msg.hopCount}'),
                  );
                },
              ),
        floatingActionButton: FloatingActionButton(
          onPressed: _running ? _send : null,
          child: const Icon(Icons.send),
        ),
      ),
    );
  }
}
