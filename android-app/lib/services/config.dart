import 'package:shared_preferences/shared_preferences.dart';

class MeganConfig {
  static const String baseUrl = 'https://megan-life.onrender.com';
  static const String appName = 'Megan Life';
  static const String androidPackage = 'com.luiz.meganlife';

  // ID fixo principal para Luiz.
  // Assim a memória no backend continua sendo encontrada mesmo reinstalando o app.
  static const String defaultUserId = 'luiz';

  static Future<String> getUserId() async {
    final prefs = await SharedPreferences.getInstance();

    final saved = prefs.getString('megan_user_id');

    if (saved != null && saved.trim().isNotEmpty) {
      return saved.trim();
    }

    await prefs.setString('megan_user_id', defaultUserId);
    return defaultUserId;
  }
}