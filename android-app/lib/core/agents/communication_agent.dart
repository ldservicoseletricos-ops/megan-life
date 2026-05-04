import '../../services/app_launcher_service.dart';

class CommunicationIntent {
  final bool isCommunication;
  final bool isWhatsApp;
  final bool wantsMessage;
  final bool prefersBusiness;
  final bool prefersNormal;

  const CommunicationIntent({
    required this.isCommunication,
    required this.isWhatsApp,
    required this.wantsMessage,
    required this.prefersBusiness,
    required this.prefersNormal,
  });

  static const none = CommunicationIntent(
    isCommunication: false,
    isWhatsApp: false,
    wantsMessage: false,
    prefersBusiness: false,
    prefersNormal: false,
  );
}

class CommunicationAgent {
  final AppLauncherService _apps;

  CommunicationAgent(this._apps);

  CommunicationIntent detect(String command) {
    final text = _normalize(command);

    final isWhatsApp = text.contains('whatsapp') ||
        text.contains('zap') ||
        text.contains('wpp') ||
        text.contains('mensagem') ||
        text.contains('mandar mensagem') ||
        text.contains('manda mensagem') ||
        text.contains('enviar mensagem') ||
        text.contains('envia mensagem');

    if (!isWhatsApp) return CommunicationIntent.none;

    final prefersBusiness = text.contains('business') ||
        text.contains('comercial') ||
        text.contains('empresa');

    final prefersNormal = text.contains('normal') ||
        text.contains('pessoal');

    final wantsMessage = text.contains('mensagem') ||
        text.contains('manda') ||
        text.contains('mandar') ||
        text.contains('envia') ||
        text.contains('enviar');

    return CommunicationIntent(
      isCommunication: true,
      isWhatsApp: true,
      wantsMessage: wantsMessage,
      prefersBusiness: prefersBusiness,
      prefersNormal: prefersNormal,
    );
  }

  Future<bool> openWhatsApp({bool preferBusiness = false}) {
    return _apps.openWhatsAppChat(preferBusiness: preferBusiness);
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
