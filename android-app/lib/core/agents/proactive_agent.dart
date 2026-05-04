class ProactiveAgent {
  DateTime? _lastInteraction;
  DateTime? _lastSuggestion;
  int _idleSuggestionCount = 0;
  int _sessionSuggestionCount = 0;

  static const Duration _minimumIdleBeforeSuggestion = Duration(seconds: 75);
  static const Duration _minimumTimeBetweenSuggestions = Duration(minutes: 8);
  static const int _maxSuggestionsPerIdleCycle = 2;
  static const int _maxSuggestionsPerSession = 6;

  void registerInteraction() {
    _lastInteraction = DateTime.now();
    _idleSuggestionCount = 0;
  }

  bool shouldSuggest() {
    final now = DateTime.now();
    final lastInteraction = _lastInteraction;

    if (lastInteraction == null) return false;
    if (_sessionSuggestionCount >= _maxSuggestionsPerSession) return false;

    final idleTime = now.difference(lastInteraction);
    if (idleTime < _minimumIdleBeforeSuggestion) return false;

    final lastSuggestion = _lastSuggestion;
    if (lastSuggestion != null && now.difference(lastSuggestion) < _minimumTimeBetweenSuggestions) {
      return false;
    }

    if (_idleSuggestionCount >= _maxSuggestionsPerIdleCycle) return false;

    _idleSuggestionCount++;
    _sessionSuggestionCount++;
    _lastSuggestion = now;
    return true;
  }

  String buildSuggestion() {
    final now = DateTime.now();
    final hour = now.hour;
    final weekday = now.weekday;

    final suggestions = _suggestionsForTime(hour: hour, weekday: weekday);
    if (suggestions.isEmpty) {
      return 'Luiz, estou por aqui. Quer que eu te ajude com alguma coisa agora?';
    }

    final index = (_idleSuggestionCount + _sessionSuggestionCount) % suggestions.length;
    return suggestions[index];
  }

  List<String> _suggestionsForTime({required int hour, required int weekday}) {
    final isWeekend = weekday == DateTime.saturday || weekday == DateTime.sunday;

    // 6.9 — Assistente Contínua Premium:
    // sugestões mais úteis, incluindo rotina e saúde, mas ainda controladas
    // por anti-spam e respeitando o bloqueio do HomeScreen para mídia/comunicação.
    if (hour >= 5 && hour < 11) {
      return [
        'Bom dia, Luiz. Quer que eu organize suas prioridades de hoje?',
        'Luiz, quer que eu veja seu resumo de saúde e atividade para começar o dia?',
        'Posso te ajudar a montar um plano rápido para esta manhã.',
        'Quer que eu confira seus passos, sono ou algum dado de saúde disponível?',
      ];
    }

    if (hour >= 11 && hour < 14) {
      return [
        'Luiz, quer revisar o que ainda falta resolver hoje?',
        'Posso te ajudar a abrir um app, organizar uma tarefa ou continuar o próximo passo.',
        'Quer que eu confira seu nível de atividade até agora?',
        isWeekend
            ? 'Quer que eu te ajude a planejar algo para hoje sem atrapalhar seu descanso?'
            : 'Quer que eu te ajude a manter o foco para o resto do dia?',
      ];
    }

    if (hour >= 14 && hour < 18) {
      return [
        'Luiz, quer que eu te ajude a retomar alguma tarefa importante agora?',
        'Posso organizar um próximo passo para o projeto Megan Life.',
        'Quer que eu abra algum app ou prepare alguma ação para você?',
        'Se quiser, posso verificar sua atividade de hoje e sugerir um próximo passo leve.',
      ];
    }

    if (hour >= 18 && hour < 22) {
      return [
        'Luiz, quer fazer um resumo rápido do dia ou preparar o próximo passo?',
        'Posso te ajudar a revisar o que ficou pendente hoje.',
        'Quer que eu deixe alguma coisa organizada para amanhã?',
        'Quer que eu veja seu resumo de saúde do dia e destaque apenas o mais importante?',
      ];
    }

    return [
      'Luiz, já está mais tarde. Quer que eu mantenha tudo em modo silencioso e só responda quando você chamar?',
      'Posso ficar em espera para não atrapalhar seu descanso.',
      'Quer que eu ajude só com algo rápido antes de encerrar?',
      'Se preferir, posso evitar sugestões agora para não atrapalhar seu descanso.',
    ];
  }
}
