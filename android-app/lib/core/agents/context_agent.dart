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

    if (memory.isEmpty) return clean;

    final buffer = StringBuffer();

    buffer.writeln('Contexto recente da conversa:');

    for (final item in memory) {
      buffer.writeln('Luiz: ${item.userText}');
      buffer.writeln('Megan: ${item.meganText}');
    }

    buffer.writeln('');
    buffer.writeln('Mensagem atual: $clean');

    if (isFollowUp(clean)) {
      buffer.writeln('');
      buffer.writeln('Use o contexto para continuar a conversa.');
    }

    return buffer.toString().trim();
  }
}