import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'config.dart';
import 'memory_service.dart';

class AiService {
  final MeganMemoryService _localMemory = MeganMemoryService();
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
        .trim();
  }

  List<String> _splitCommands(String text) {
    final normalized = _normalize(text);

    return normalized.split(
      RegExp(r'\s+e\s+|\s+depois\s+|\s+em seguida\s+|\s+ai\s+|\s+entao\s+'),
    );
  }

  List<Map<String, dynamic>> _detectActions(String message) {
    final parts = _splitCommands(message);
    final List<Map<String, dynamic>> actions = [];

    for (final part in parts) {
      final text = part.trim();
      if (text.isEmpty) continue;

      if (text.contains('abrir') || text.contains('abre')) {
        final app = text.replaceAll(RegExp(r'(abrir|abre)'), '').trim();

        if (app.isNotEmpty) {
          actions.add({'type': 'open_app', 'value': app});
        }
        continue;
      }

      if (text.contains('ir para') ||
          text.contains('navegar') ||
          text.contains('rota') ||
          text.contains('levar para')) {
        final dest = text
            .replaceAll(RegExp(r'(ir para|navegar para|rota para|levar para)'), '')
            .trim();

        if (dest.isNotEmpty) {
          actions.add({'type': 'navigate', 'value': dest});
        }
        continue;
      }

      if (text.contains('saude') || text.contains('relogio')) {
        actions.add({'type': 'health', 'value': ''});
        continue;
      }

      if (text.contains('atleta') ||
          text.contains('treino') ||
          text.contains('desempenho')) {
        actions.add({'type': 'athlete', 'value': ''});
        continue;
      }

      if (text.contains('sugestao') || text.contains('sugestão')) {
        actions.add({'type': 'feedback', 'value': message});
        continue;
      }

      if (text.contains('copiloto') ||
          text.contains('organizar') ||
          text.contains('planejar') ||
          text.contains('rotina')) {
        actions.add({
          'type': 'copilot_plan',
          'value': message,
        });
        continue;
      }
    }

    if (actions.isEmpty) {
      actions.add({'type': 'chat', 'value': message});
    }

    return actions;
  }

  Future<Map<String, dynamic>> process(String message) async {
    try {
      final lower = message.toLowerCase();
      final actions = _detectActions(message);
      final userId = await MeganConfig.getUserId();

      if (lower.contains('o que você sabe sobre mim') ||
          lower.contains('o que sabe sobre mim') ||
          lower.contains('meu perfil')) {
        return {
          'ok': true,
          'actions': [
            {'type': 'chat', 'value': message}
          ],
          'response': await getProfile(),
        };
      }

      if (lower.startsWith('esqueça ') ||
          lower.startsWith('esqueca ') ||
          lower.startsWith('apague da memória ') ||
          lower.startsWith('apague da memoria ')) {
        final value = message
            .replaceFirst(RegExp(r'^esqueça\\s+', caseSensitive: false), '')
            .replaceFirst(RegExp(r'^esqueca\\s+', caseSensitive: false), '')
            .replaceFirst(RegExp(r'^apague da memória\\s+', caseSensitive: false), '')
            .replaceFirst(RegExp(r'^apague da memoria\\s+', caseSensitive: false), '')
            .trim();

        await _localMemory.forget(value);

        return {
          'ok': true,
          'actions': [
            {'type': 'chat', 'value': message}
          ],
          'response': 'Certo, Luiz. Apaguei essa memória local quando encontrei algo relacionado.',
        };
      }

      if (lower.startsWith('lembre que ') ||
          lower.startsWith('lembra que ') ||
          lower.startsWith('memorize que ')) {
        final value = message
            .replaceFirst(RegExp(r'^lembre que\\s+', caseSensitive: false), '')
            .replaceFirst(RegExp(r'^lembra que\\s+', caseSensitive: false), '')
            .replaceFirst(RegExp(r'^memorize que\\s+', caseSensitive: false), '')
            .trim();

        return {
          'ok': true,
          'actions': [
            {'type': 'chat', 'value': message}
          ],
          'response': await remember('manual', value),
        };
      }

      if (actions.length == 1 && actions.first['type'] == 'chat') {
        final r = await http.post(
          Uri.parse('${MeganConfig.baseUrl}/api/chat'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'message': message,
            'userId': userId,
            'device': 'android-real-device',
            'mode': 'megan-life-7.1-memory',
            'memoryContext': await _localMemory.buildMemoryContext(),
          }),
        );

        return {
          'ok': true,
          'actions': actions,
          'response': _safeParse(r, 'Falha no chat'),
        };
      }

      return {
        'ok': true,
        'actions': actions,
        'response': _buildExecutionResponse(actions),
      };
    } catch (e) {
      return {
        'ok': false,
        'actions': [],
        'response': 'Erro de conexão: $e',
      };
    }
  }

  String _buildExecutionResponse(List actions) {
    final names = actions.map((a) {
      switch (a['type']) {
        case 'open_app':
          return 'abrir ${a['value']}';
        case 'navigate':
          return 'ir para ${a['value']}';
        case 'health':
          return 'ver saúde';
        case 'athlete':
          return 'analisar desempenho';
        default:
          return a['type'];
      }
    }).toList();

    return 'Executando: ${names.join(' → ')}';
  }

  Future<String> chat(String message) async {
    final result = await process(message);
    return (result['response'] ?? 'Erro').toString();
  }

  Future<String> healthSummary(Map<String, dynamic> metrics) async {
    try {
      final userId = await MeganConfig.getUserId();

      final r = await http.post(
        Uri.parse('${MeganConfig.baseUrl}/api/health/summary'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'userId': userId,
          'metrics': metrics,
        }),
      );

      return _safeParse(r, 'Falha na saúde');
    } catch (e) {
      return 'Erro ao analisar saúde: $e';
    }
  }

  Future<String> athleteSummary(Map<String, dynamic> metrics) async {
    try {
      final userId = await MeganConfig.getUserId();

      final r = await http.post(
        Uri.parse('${MeganConfig.baseUrl}/api/athlete/summary'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'userId': userId,
          'metrics': metrics,
        }),
      );

      return _safeParse(r, 'Falha no atleta');
    } catch (e) {
      return 'Erro atleta: $e';
    }
  }

  Future<String> sendFeedback(String feedback) async {
    try {
      final userId = await MeganConfig.getUserId();

      final r = await http.post(
        Uri.parse('${MeganConfig.baseUrl}/api/feedback'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'userId': userId,
          'feedback': feedback,
        }),
      );

      return _safeParse(r, 'Falha ao registrar sugestão');
    } catch (e) {
      return 'Erro sugestão: $e';
    }
  }

  Future<String> getProfile() async {
    final localProfile = await _localMemory.profileText();

    try {
      final userId = await MeganConfig.getUserId();

      final r = await http.get(
        Uri.parse('${MeganConfig.baseUrl}/api/profile/$userId'),
      );

      final body = r.body.trim();

      if (body.startsWith('<')) {
        return 'Erro ao buscar perfil.';
      }

      final d = jsonDecode(body);

      if (d['ok'] != true) return localProfile;

      final profile = d['profile'] ?? {};

      if (profile is! Map || profile.isEmpty) {
        return localProfile;
      }

      final buffer = StringBuffer();
      buffer.writeln('📊 O que eu sei sobre você:\n');

      profile.forEach((key, value) {
        if (value is Map && value.containsKey('value')) {
          buffer.writeln('• $key: ${value['value']}');
        } else {
          buffer.writeln('• $key: $value');
        }
      });

      return buffer.toString();
    } catch (e) {
      return localProfile;
    }
  }

  Future<String> remember(String key, String value) async {
    await _localMemory.remember(
      key: key,
      value: value,
      type: key == 'manual' ? 'manual' : 'general',
      priority: key == 'manual' ? 5 : 3,
    );

    try {
      final userId = await MeganConfig.getUserId();

      final r = await http.post(
        Uri.parse('${MeganConfig.baseUrl}/api/memory/remember'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'userId': userId,
          'key': key,
          'value': value,
          'category': 'manual',
          'importance': 'high',
        }),
      );

      final d = jsonDecode(r.body);

      if (d['ok'] == true) {
        return 'Memorizado com sucesso.';
      }

      return 'Não consegui salvar isso.';
    } catch (e) {
      return 'Memorizado localmente neste aparelho.';
    }
  }


  Future<Map<String, dynamic>> generateFile({
    required String type,
    required String title,
    required String content,
    String? fileName,
  }) async {
    try {
      final r = await http.post(
        Uri.parse('${MeganConfig.baseUrl}/api/files/generate'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'type': type,
          'title': title,
          'content': content,
          'fileName': fileName ?? title,
        }),
      );

      final d = jsonDecode(r.body);
      if (r.statusCode >= 400 || d['ok'] != true) {
        return {
          'ok': false,
          'message': d['error']?.toString() ?? 'Falha ao gerar arquivo.',
        };
      }

      return {
        'ok': true,
        'message': d['message']?.toString() ?? 'Arquivo gerado.',
        'url': d['url']?.toString() ?? '',
        'fileName': d['fileName']?.toString() ?? '',
        'type': d['type']?.toString() ?? type,
      };
    } catch (e) {
      return {
        'ok': false,
        'message': 'Erro ao gerar arquivo: $e',
      };
    }
  }

  Future<String> analyzeFileDirect(File file, {String question = ''}) async {
    try {
      final userId = await MeganConfig.getUserId();
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('${MeganConfig.baseUrl}/api/files/analyze'),
      );

      request.fields['userId'] = userId;
      if (question.trim().isNotEmpty) {
        request.fields['question'] = question.trim();
      }
      request.files.add(await http.MultipartFile.fromPath('file', file.path));

      final streamed = await request.send();
      final response = await http.Response.fromStream(streamed);
      return _safeParse(response, 'Falha ao analisar arquivo');
    } catch (e) {
      return 'Erro ao analisar arquivo: $e';
    }
  }

  String buildCopilotPlan(String message) {
    return '''
🧠 Copiloto Megan 7.1 com memória ativado

Plano sugerido:
1. Identificar sua prioridade principal.
2. Separar em ações pequenas.
3. Executar primeiro o que depende de app, saúde, navegação ou arquivo.
4. Depois responder com próximos passos.

Comando recebido:
$message
''';
  }

  String _safeParse(http.Response r, String fallback) {
    try {
      final body = r.body.trim();

      if (body.startsWith('<!DOCTYPE') || body.startsWith('<html')) {
        return 'Erro no servidor (backend retornou HTML).';
      }

      final d = jsonDecode(body);

      if (r.statusCode >= 400 || d['ok'] != true) {
        return d['error'] ?? fallback;
      }

      if (d.containsKey('answer')) return d['answer'];
      if (d.containsKey('response')) return d['response'];
      if (d.containsKey('message')) return d['message'];

      return d.toString();
    } catch (e) {
      return '$fallback (${e.toString()})';
    }
  }
}