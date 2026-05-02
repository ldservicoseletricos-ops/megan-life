import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'config.dart';

class FileService {

  Future<String> analyzeFile(File file) async {
    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('${MeganConfig.baseUrl}/api/files/analyze'),
      );

      request.files.add(await http.MultipartFile.fromPath('file', file.path));

      final response = await request.send();
      final body = await response.stream.bytesToString();

      // 🔥 PROTEÇÃO CONTRA HTML (ERRO RENDER)
      if (body.trim().startsWith('<')) {
        return 'Erro no servidor ao analisar arquivo.';
      }

      final data = jsonDecode(body);

      if (response.statusCode >= 400 || data['ok'] != true) {
        return data['error'] ?? 'Falha ao analisar arquivo';
      }

      final answer = data['answer'] ?? 'Arquivo analisado.';

      // 🔥 DETECÇÃO INTELIGENTE
      final lower = answer.toLowerCase();

      if (_isMedicalContent(lower)) {
        return '''
🧾 Exame detectado

$answer

⚠️ Isso parece um exame médico.
Recomendo validar com um profissional de saúde.
''';
      }

      return answer;

    } catch (e) {
      return 'Erro ao analisar arquivo: $e';
    }
  }

  // 🔥 DETECÇÃO DE EXAMES
  bool _isMedicalContent(String text) {
    return text.contains('exame') ||
        text.contains('hemoglobina') ||
        text.contains('glicose') ||
        text.contains('colesterol') ||
        text.contains('batimento') ||
        text.contains('pressão') ||
        text.contains('diagnóstico');
  }
}