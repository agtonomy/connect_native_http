import 'package:flutter/material.dart';

/// Host app for the integration tests in integration_test/. It has no behavior of its own.
void main() {
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('connect_native_http integration tests'))),
    ),
  );
}
