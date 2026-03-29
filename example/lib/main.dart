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

  @override
  void initState() {
    super.initState();
    _mesh.onMessage.listen((msg) {
      setState(() => _messages.insert(0, msg));
    });
  }

  Future<void> _toggle() async {
    if (_running) {
      await _mesh.stop();
    } else {
      await _mesh.start(userId: 'demo-user', userName: 'Demo');
    }
    setState(() => _running = _mesh.isRunning);
  }

  Future<void> _send() async {
    if (!_running) return;
    await _mesh.sendText('Hello from mesh! ${DateTime.now()}');
  }

  @override
  void dispose() {
    _mesh.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Mesh Network Demo'),
          actions: [
            IconButton(
              icon: Icon(_running ? Icons.stop : Icons.play_arrow),
              onPressed: _toggle,
            ),
          ],
        ),
        body: ListView.builder(
          itemCount: _messages.length,
          itemBuilder: (_, i) {
            final msg = _messages[i];
            return ListTile(
              title: Text(msg.payload),
              subtitle: Text(
                  '${msg.senderName} - hop ${msg.hopCount}'),
            );
          },
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: _send,
          child: const Icon(Icons.send),
        ),
      ),
    );
  }
}
