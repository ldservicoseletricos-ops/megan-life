import 'package:shared_preferences/shared_preferences.dart';

class AdaptiveSuggestion {
  final String command;
  final int count;
  final String timeBucket;

  const AdaptiveSuggestion({
    required this.command,
    required this.count,
    this.timeBucket = 'geral',
  });
}

class AdaptiveAgent {
  static const String _usagePrefix = 'megan_adaptive_usage_';
  static const String _timeUsagePrefix = 'megan_adaptive_time_usage_';
  static const String _lastSuggestionPrefix = 'megan_adaptive_last_suggestion_';
  static const int _suggestEvery = 3;

  Future<AdaptiveSuggestion?> registerAndSuggest(String command) async {
    final key = _normalize(command);

    if (key.isEmpty) return null;
    if (_shouldIgnore(key)) return null;

    final prefs = await SharedPreferences.getInstance();
    final usageKey = '$_usagePrefix$key';
    final suggestionKey = '$_lastSuggestionPrefix$key';
    final bucket = _currentTimeBucket();
    final timeUsageKey = '$_timeUsagePrefix${bucket}_$key';

    final count = (prefs.getInt(usageKey) ?? 0) + 1;
    await prefs.setInt(usageKey, count);

    final timeCount = (prefs.getInt(timeUsageKey) ?? 0) + 1;
    await prefs.setInt(timeUsageKey, timeCount);

    final lastSuggestedAt = prefs.getInt(suggestionKey) ?? 0;

    // 6.9 — Assistente Contínua Premium:
    // mantém sugestão controlada, sem spam, mas passa a entender melhor
    // comandos de rotina, saúde, navegação e apps por período do dia.
    final shouldSuggest = count == _suggestEvery ||
        (count > _suggestEvery && count % _suggestEvery == 0 && count != lastSuggestedAt);

    if (!shouldSuggest) return null;

    await prefs.setInt(suggestionKey, count);

    return AdaptiveSuggestion(
      command: command.trim(),
      count: count,
      timeBucket: bucket,
    );
  }

  Future<void> register(String command) async {
    await registerAndSuggest(command);
  }

  Future<int> usageCount(String command) async {
    final key = _normalize(command);
    if (key.isEmpty) return 0;

    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('$_usagePrefix$key') ?? 0;
  }

  Future<int> usageCountForCurrentPeriod(String command) async {
    final key = _normalize(command);
    if (key.isEmpty) return 0;

    final prefs = await SharedPreferences.getInstance();
    final bucket = _currentTimeBucket();
    return prefs.getInt('$_timeUsagePrefix${bucket}_$key') ?? 0;
  }

  Future<void> clearCommand(String command) async {
    final key = _normalize(command);
    if (key.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_usagePrefix$key');
    await prefs.remove('$_lastSuggestionPrefix$key');

    for (final bucket in const ['manha', 'almoco', 'tarde', 'noite', 'madrugada']) {
      await prefs.remove('$_timeUsagePrefix${bucket}_$key');
    }
  }

  String buildSuggestionText(AdaptiveSuggestion suggestion) {
    final command = suggestion.command.trim();
    final periodText = _periodText(suggestion.timeBucket);
    final normalized = _normalize(command);

    if (command.isEmpty) {
      return 'Luiz, percebi alguns padrões de uso $periodText. Vou usar isso com cuidado para sugerir ações mais úteis, sem interromper você.';
    }

    if (_looksLikeHealthCommand(normalized)) {
      return 'Luiz, percebi que você tem usado comandos de saúde $periodText. Posso te ajudar a acompanhar seus dados com cuidado, sem substituir orientação médica.';
    }

    if (_looksLikeNavigationCommand(normalized)) {
      return 'Luiz, percebi que você costuma usar navegação $periodText. Vou lembrar desse padrão para te ajudar mais rápido quando pedir rotas.';
    }

    if (_looksLikeAppCommand(normalized)) {
      return 'Luiz, percebi que você costuma abrir apps $periodText: "$command". Vou usar isso com cuidado para agilizar quando você pedir.';
    }

    return 'Luiz, percebi que você já pediu algumas vezes $periodText: "$command". Vou usar esse padrão com cuidado para te ajudar mais rápido nas próximas vezes.';
  }

  bool _looksLikeHealthCommand(String key) {
    return key.contains('saude') ||
        key.contains('passos') ||
        key.contains('sono') ||
        key.contains('batimento') ||
        key.contains('frequencia cardiaca') ||
        key.contains('relatorio') ||
        key.contains('desempenho') ||
        key.contains('atleta');
  }

  bool _looksLikeNavigationCommand(String key) {
    return key.contains('navegar') ||
        key.contains('rota') ||
        key.contains('waze') ||
        key.contains('maps') ||
        key.contains('me leva') ||
        key.contains('ir para') ||
        key.contains('ir pra');
  }

  bool _looksLikeAppCommand(String key) {
    return key.contains('abrir') ||
        key.contains('abre') ||
        key.contains('youtube') ||
        key.contains('whatsapp') ||
        key.contains('telegram') ||
        key.contains('gmail') ||
        key.contains('spotify');
  }

  bool _shouldIgnore(String key) {
    if (key.length < 3) return true;

    final ignored = <String>{
      'sim',
      'ok',
      'certo',
      'nao',
      'não',
      'cancelar',
      'obrigado',
      'obrigada',
      'valeu',
    };

    if (ignored.contains(key)) return true;

    return key.contains('apagar') ||
        key.contains('deletar') ||
        key.contains('excluir') ||
        key.contains('pagar') ||
        key.contains('comprar') ||
        key.contains('transferir') ||
        key.contains('enviar dinheiro') ||
        key.contains('mandar dinheiro');
  }

  String _currentTimeBucket() {
    final hour = DateTime.now().hour;

    if (hour >= 5 && hour < 11) return 'manha';
    if (hour >= 11 && hour < 14) return 'almoco';
    if (hour >= 14 && hour < 18) return 'tarde';
    if (hour >= 18 && hour < 23) return 'noite';
    return 'madrugada';
  }

  String _periodText(String bucket) {
    switch (bucket) {
      case 'manha':
        return 'pela manhã';
      case 'almoco':
        return 'perto do almoço';
      case 'tarde':
        return 'à tarde';
      case 'noite':
        return 'à noite';
      case 'madrugada':
        return 'mais tarde';
      default:
        return 'nesse período';
    }
  }

  String _normalize(String text) {
    return text
        .toLowerCase()
        .replaceAll('á', 'a')
        .replaceAll('à', 'a')
        .replaceAll('ã', 'a')
        .replaceAll('â', 'a')
        .replaceAll('é', 'e')
        .replaceAll('ê', 'e')
        .replaceAll('í', 'i')
        .replaceAll('ó', 'o')
        .replaceAll('õ', 'o')
        .replaceAll('ô', 'o')
        .replaceAll('ú', 'u')
        .replaceAll('ç', 'c')
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
