import 'package:flutter/services.dart';

class AccessibilityService {
  static const MethodChannel _channel = MethodChannel('megan.accessibility');

  static Future<void> back() async {
    await _channel.invokeMethod('action', {'type': 'back'});
  }

  static Future<void> home() async {
    await _channel.invokeMethod('action', {'type': 'home'});
  }

  static Future<void> recent() async {
    await _channel.invokeMethod('action', {'type': 'recent'});
  }
}