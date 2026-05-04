import 'package:shared_preferences/shared_preferences.dart';

class MemoryAgent {
  static const _keyLastIntent = 'megan_last_intent';
  static const _keyLastTarget = 'megan_last_target';

  Future<void> rememberIntent(String intent, String target) async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(_keyLastIntent, intent);
    await prefs.setString(_keyLastTarget, target);
  }

  Future<Map<String, String>> getLastContext() async {
    final prefs = await SharedPreferences.getInstance();

    final intent = prefs.getString(_keyLastIntent) ?? '';
    final target = prefs.getString(_keyLastTarget) ?? '';

    return {
      'intent': intent,
      'target': target,
    };
  }

  Future<void> clearMemory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyLastIntent);
    await prefs.remove(_keyLastTarget);
  }
}