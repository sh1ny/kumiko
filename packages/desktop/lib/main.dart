import 'package:flutter/material.dart';

void main() {
  runApp(const KumikoApp());
}

/// The Kumiko desktop app. The host status window arrives in task 8.2.
class KumikoApp extends StatelessWidget {
  const KumikoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Kumiko',
      home: Scaffold(body: Center(child: Text('Kumiko'))),
    );
  }
}
