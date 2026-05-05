import '../../services/app_launcher_service.dart';

class AppAgent {
  final AppLauncherService _apps;

  AppAgent(this._apps);

  String _normalize(String value) {
    return value
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

  bool canHandle(String command) {
    final text = _normalize(command);

    if (text.isEmpty) return false;

    // Segurança: nunca tratar contexto/memória como comando de abrir app.
    if (text.contains('contexto recente') || text.contains('mensagem atual')) {
      return false;
    }

    // Não assume fluxos que já pertencem a outros agentes.
    if (text.contains('whatsapp') ||
        text.contains('zap') ||
        text.contains('wpp') ||
        text.contains('mensagem') ||
        text.contains('mandar') ||
        text.contains('enviar')) {
      return false;
    }

    if (text.contains('navegar') ||
        text.contains('rota') ||
        text.contains('me leva') ||
        text.contains('ir para') ||
        text.contains('ir pra')) {
      return false;
    }

    if (text == 'abre ele' ||
        text == 'abre isso' ||
        text == 'abrir isso' ||
        text == 'faz isso' ||
        text == 'faca isso') {
      return false;
    }

    return text.contains('abrir ') ||
        text.startsWith('abre ') ||
        text.contains('abrindo ') ||
        text.contains('iniciar ') ||
        text.contains('executar ') ||
        text.contains('app ') ||
        text.contains('aplicativo ') ||
        text.contains('programa ');
  }

  String extractAppName(String command) {
    var text = _normalize(command);

    if (text.contains('contexto recente') || text.contains('mensagem atual')) {
      return '';
    }

    final patterns = [
      'abrir o aplicativo ',
      'abrir aplicativo ',
      'abrir o app ',
      'abrir app ',
      'abrir ',
      'abre o aplicativo ',
      'abre aplicativo ',
      'abre o app ',
      'abre app ',
      'abre ',
      'abrindo ',
      'iniciar ',
      'executar ',
      'app ',
      'aplicativo ',
      'programa ',
    ];

    for (final pattern in patterns) {
      if (text.contains(pattern)) {
        final parts = text.split(pattern);
        if (parts.length > 1) {
          final candidate = parts.last.trim();
          if (candidate.isNotEmpty) return candidate;
        }
      }
    }

    return text.trim();
  }

  bool isMediaCommand(String command) {
    final appName = extractAppName(command);
    if (appName.isEmpty) return false;

    return _apps.isMediaAppName(appName);
  }

  bool isCommunicationCommand(String command) {
    if (!canHandle(command)) return false;

    final appName = extractAppName(command);
    if (appName.isEmpty) return false;

    return _apps.isCommunicationAppName(appName);
  }

  bool isExternalAppCommand(String command) {
    if (!canHandle(command)) return false;

    final appName = extractAppName(command);
    if (appName.isEmpty) return false;

    if (_apps.isCommunicationAppName(appName)) return false;

    return _apps.canOpenExternalAppName(appName);
  }

  Future<bool> handle(String command) async {
    if (!canHandle(command)) return false;

    final appName = extractAppName(command);

    if (appName.isEmpty) return false;

    return await _apps.openKnownApp(appName);
  }

  Future<bool> handleMedia(String command) async {
    if (!canHandle(command)) return false;

    final appName = extractAppName(command);

    if (appName.isEmpty || !_apps.isMediaAppName(appName)) return false;

    return await _apps.openMediaApp(appName);
  }

  Future<bool> handleCommunication(String command) async {
    if (!canHandle(command)) return false;

    final appName = extractAppName(command);

    if (appName.isEmpty || !_apps.isCommunicationAppName(appName)) return false;

    return await _apps.openCommunicationApp(appName);
  }

  Future<bool> handleExternalApp(String command) async {
    if (!canHandle(command)) return false;

    final appName = extractAppName(command);

    if (appName.isEmpty || _apps.isCommunicationAppName(appName)) return false;
    if (!_apps.canOpenExternalAppName(appName)) return false;

    return await _apps.openExternalApp(appName);
  }
}
