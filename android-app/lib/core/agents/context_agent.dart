class ContextAgent {
  String normalize(String text) {
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

  bool isFollowUp(String text) {
    final cmd = normalize(text);

    return cmd == 'e agora' ||
        cmd == 'agora' ||
        cmd == 'continua' ||
        cmd == 'continue' ||
        cmd == 'proximo' ||
        cmd == 'qual o proximo' ||
        cmd == 'isso' ||
        cmd == 'esse' ||
        cmd == 'essa' ||
        cmd.contains('abre isso') ||
        cmd.contains('faz isso') ||
        cmd.contains('vai nele');
  }

  String buildContext({
    required String currentText,
    required List<dynamic> memory,
  }) {
    final clean = currentText.trim();
    if (clean.isEmpty) return clean;

    // Correção de segurança:
    // O ContextAgent não deve montar blocos com "Contexto recente" para o mesmo
    // fluxo que também pode executar ações da IA. Quando esse bloco era enviado
    // para a IA, ela podia devolver action open_app usando o próprio texto do
    // histórico como alvo, gerando loop como "open_app contexto recente".
    // Mantemos o método e a assinatura para não quebrar o HomeScreen, mas agora
    // ele devolve apenas a fala atual do usuário.
    return clean;
  }
}