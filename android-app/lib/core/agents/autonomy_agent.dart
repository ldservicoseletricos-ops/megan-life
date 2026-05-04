enum AutonomyConfirmation {
  yes,
  no,
  unknown,
}

class AutonomyPlan {
  final List<String> steps;
  final String kind;
  final String destination;

  AutonomyPlan(
    this.steps, {
    this.kind = '',
    this.destination = '',
  });

  bool get isEmpty => steps.isEmpty;
}

class AutonomyAgent {
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

  bool _looksLikeDirectExecution(String text) {
    final value = _normalize(text);

    return value.startsWith('abre ') ||
        value.startsWith('abrir ') ||
        value.startsWith('abra ') ||
        value.startsWith('ir para ') ||
        value.startsWith('ir pra ') ||
        value.startsWith('ir ao ') ||
        value.startsWith('ir a ') ||
        value.startsWith('navegar para ') ||
        value.startsWith('navegar pra ') ||
        value.startsWith('me leva ') ||
        value.startsWith('manda mensagem') ||
        value.startsWith('mandar mensagem') ||
        value.startsWith('enviar mensagem') ||
        value.contains(' e depois ');
  }

  AutonomyPlan analyze(String command) {
    final text = _normalize(command);

    if (text.isEmpty) return AutonomyPlan(const []);

    // Não intercepta comandos diretos que já funcionam no DecisionAgent/Multi-Ação.
    if (_looksLikeDirectExecution(text)) {
      return AutonomyPlan(const []);
    }

    final steps = <String>[];

    // 🚗 intenção ampla de saída.
    if (text.contains('vou sair') ||
        text.contains('estou saindo') ||
        text.contains('saindo agora') ||
        text.contains('preciso sair')) {
      steps.add('definir destino');
      steps.add('abrir navegação');
      steps.add('avisar alguém pelo WhatsApp se necessário');
      return AutonomyPlan(steps, kind: 'leaving');
    }

    // 🛒 intenção ampla de mercado/compras sem comando direto.
    if (text.contains('preciso comprar') ||
        text.contains('fazer compras') ||
        text.contains('vou ao mercado') ||
        text.contains('vou no mercado') ||
        text.contains('preciso ir ao mercado') ||
        text.contains('preciso ir no mercado')) {
      steps.add('abrir navegação para mercado');
      steps.add('lembrar de conferir lista de compras');
      return AutonomyPlan(steps, kind: 'shopping', destination: 'mercado');
    }

    // 🏃 intenção ampla de treino.
    if (text.contains('vou treinar') ||
        text.contains('começar treino') ||
        text.contains('comecar treino') ||
        text.contains('vou correr') ||
        text.contains('vou para academia') ||
        text.contains('vou pra academia')) {
      steps.add('abrir app de treino se estiver instalado');
      steps.add('acompanhar desempenho');
      steps.add('gerar resumo depois');
      return AutonomyPlan(steps, kind: 'training');
    }

    return AutonomyPlan(const []);
  }

  AutonomyConfirmation readConfirmation(String command) {
    final text = _normalize(command);

    if (text == 'sim' ||
        text == 'ok' ||
        text == 'pode' ||
        text == 'pode executar' ||
        text == 'executa' ||
        text == 'executar' ||
        text == 'confirmo' ||
        text.contains('pode continuar') ||
        text.contains('pode fazer') ||
        text.contains('faça isso') ||
        text.contains('faca isso')) {
      return AutonomyConfirmation.yes;
    }

    if (text == 'nao' ||
        text == 'não' ||
        text == 'cancelar' ||
        text == 'cancela' ||
        text == 'deixa' ||
        text.contains('nao precisa') ||
        text.contains('não precisa') ||
        text.contains('cancela isso')) {
      return AutonomyConfirmation.no;
    }

    return AutonomyConfirmation.unknown;
  }

  List<String> buildExecutableCommands({
    required AutonomyPlan plan,
    required String originalCommand,
  }) {
    if (plan.isEmpty) return const [];

    if (plan.kind == 'shopping') {
      final destination = plan.destination.trim().isNotEmpty ? plan.destination : 'mercado';
      return ['ir para $destination'];
    }

    // Para saída genérica falta destino. Mantemos seguro e pedimos informação.
    if (plan.kind == 'leaving') {
      final text = _normalize(originalCommand);

      if (text.contains('mercado')) return ['ir para mercado'];
      if (text.contains('casa')) return ['ir para casa'];
      if (text.contains('trabalho')) return ['ir para trabalho'];
      if (text.contains('academia')) return ['ir para academia'];

      return const [];
    }

    if (plan.kind == 'training') {
      return ['abrir app de treino'];
    }

    return const [];
  }

  String buildPlanText(AutonomyPlan plan) {
    if (plan.isEmpty) return '';

    final buffer = StringBuffer();
    buffer.writeln('Luiz, posso preparar isso para você com segurança:\n');

    for (final step in plan.steps) {
      buffer.writeln('• $step');
    }

    buffer.writeln('\nPosso executar agora?');

    return buffer.toString().trim();
  }

  String buildMissingInfoText(AutonomyPlan plan) {
    if (plan.kind == 'leaving') {
      return 'Luiz, para executar esse plano com segurança, me diga o destino. Por exemplo: ir para mercado, ir para casa ou ir para trabalho.';
    }

    if (plan.kind == 'training') {
      return 'Luiz, entendi o plano de treino, mas preciso saber qual app de treino você quer abrir ou se quer só acompanhar pelo painel de atleta.';
    }

    return 'Luiz, preciso de mais uma informação para executar esse plano com segurança.';
  }
}
