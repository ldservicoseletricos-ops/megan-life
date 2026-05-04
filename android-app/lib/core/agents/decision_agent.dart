import 'package:flutter/material.dart';

import 'communication_agent.dart';
import 'navigation_agent.dart';
import 'app_agent.dart';

class DecisionAgent {
  final CommunicationAgent communication;
  final NavigationAgent navigation;
  final AppAgent app;

  DecisionAgent({
    required this.communication,
    required this.navigation,
    required this.app,
  });

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

  Future<DecisionResult> decide(String command) async {
    final text = _normalize(command);

    if (text.isEmpty) {
      return DecisionResult(type: DecisionType.ai);
    }

    // 1️⃣ Comunicação fica identificada, mas a execução completa ainda pode
    // cair no fallback antigo para preservar a escolha WhatsApp normal/Business.
    if (text.contains('mensagem') ||
        text.contains('whatsapp') ||
        text.contains('zap')) {
      return DecisionResult(type: DecisionType.communication);
    }

    // 2️⃣ Navegação vem antes de apps para não cair na IA nem tentar abrir app errado.
    if (navigation.canHandle(command) ||
        text.startsWith('ir ') ||
        text.startsWith('vamos ') ||
        text.startsWith('leva ') ||
        text.startsWith('leve ') ||
        text.contains('waze') ||
        text.contains('maps') ||
        text.contains('google maps') ||
        text.contains('rota')) {
      return DecisionResult(type: DecisionType.navigation);
    }

    // 3️⃣ Apps
    if (app.canHandle(command)) {
      return DecisionResult(type: DecisionType.app);
    }

    // 4️⃣ fallback IA
    return DecisionResult(type: DecisionType.ai);
  }

  Future<bool> execute({
    required BuildContext context,
    required String command,
    required String preferredNavigationApp,
    required Future<void> Function(String answer) say,
    required void Function(String answer) addAssistantMessage,
    required Future<void> Function(String intent, String target) rememberIntent,
    required void Function(String command) setLastCommand,
  }) async {
    final clean = command.trim();
    if (clean.isEmpty) return false;

    final decision = await decide(clean);

    // 🚗 Execução real de navegação pelo cérebro central.
    // Mantém a mesma resposta que já estava funcionando no HomeScreen.
    final shouldNavigateDirectly =
        decision.type == DecisionType.navigation || navigation.canHandle(clean);

    if (shouldNavigateDirectly) {
      final destination = navigation.extractDestination(clean);
      if (destination.trim().isEmpty) return false;

      final handled = await navigation.handle(context, clean);

      if (handled) {
        final answer = preferredNavigationApp == 'waze'
            ? 'Certo, Luiz. Preparei a navegação para $destination. Como você prefere Waze, escolha Waze na tela.'
            : preferredNavigationApp == 'maps'
                ? 'Certo, Luiz. Preparei a navegação para $destination. Como você prefere Google Maps, escolha Google Maps na tela.'
                : 'Certo, Luiz. Preparei a navegação para $destination. Escolha Waze ou Google Maps.';

        await rememberIntent('navigate', destination);
        setLastCommand(clean);
        addAssistantMessage(answer);
        await say(answer);
        return true;
      }
    }

    // 📱 Execução real de abertura de apps pelo cérebro central.
    // Se não conseguir abrir, retorna false para o SmartIntent antigo tentar.
    if (decision.type == DecisionType.app) {
      final appName = app.extractAppName(clean);
      if (appName.trim().isEmpty) return false;

      final handled = await app.handle(clean);

      if (handled) {
        final answer = 'Abrindo $appName, Luiz.';
        await rememberIntent('open_app', appName);
        setLastCommand(clean);
        addAssistantMessage(answer);
        await say(answer);
        return true;
      }
    }

    // 💬 Comunicação continua no fallback antigo por segurança,
    // pois lá já existe a lógica estável do WhatsApp normal/Business.
    return false;
  }

  Future<bool> executeMulti({
    required BuildContext context,
    required String command,
    required String preferredNavigationApp,
    required Future<void> Function(String answer) say,
    required void Function(String answer) addAssistantMessage,
    required Future<void> Function(String intent, String target) rememberIntent,
    required void Function(String command) setLastCommand,
    required Future<bool> Function(String command) executeFallback,
  }) async {
    final clean = command.trim();
    if (clean.isEmpty) return false;

    final parts = clean
        .split(RegExp(r'\s+(?:e depois|depois|em seguida|e entao|e então)\s+', caseSensitive: false))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();

    if (parts.length <= 1) return false;

    var executedAny = false;

    for (final part in parts) {
      final executed = await execute(
        context: context,
        command: part,
        preferredNavigationApp: preferredNavigationApp,
        say: say,
        addAssistantMessage: addAssistantMessage,
        rememberIntent: rememberIntent,
        setLastCommand: setLastCommand,
      );

      if (executed) {
        executedAny = true;
        await Future.delayed(const Duration(milliseconds: 700));
        continue;
      }

      final fallbackExecuted = await executeFallback(part);

      if (fallbackExecuted) {
        executedAny = true;
        await Future.delayed(const Duration(milliseconds: 700));
        continue;
      }

      return false;
    }

    return executedAny;
  }

}

enum DecisionType {
  communication,
  navigation,
  app,
  ai,
}

class DecisionResult {
  final DecisionType type;

  DecisionResult({required this.type});
}
