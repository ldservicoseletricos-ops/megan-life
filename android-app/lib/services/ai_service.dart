import 'dart:convert';
import 'package:http/http.dart' as http;
import 'config.dart';

class AiService {

  Future<String> chat(String message) async {
    try {
      final r = await http.post(
        Uri.parse('${MeganConfig.baseUrl}/api/chat'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'message': message,
          'userId': MeganConfig.defaultUserId,
          'device': 'android-real-device',
        }),
      );

      return _safeParse(r, 'Falha no chat');
    } catch (e) {
      return 'Erro de conexão: $e';
    }
  }

  Future<String> healthSummary(Map<String, dynamic> metrics) async {
    try {
      final r = await http.post(
        Uri.parse('${MeganConfig.baseUrl}/api/health/summary'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'userId': MeganConfig.defaultUserId,
          'metrics': metrics
        }),
      );

      return _safeParse(r, 'Falha na saúde');
    } catch (e) {
      return 'Erro ao analisar saúde: $e';
    }
  }

  Future<String> athleteSummary(Map<String, dynamic> metrics) async {
    try {
      final r = await http.post(
        Uri.parse('${MeganConfig.baseUrl}/api/athlete/summary'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'userId': MeganConfig.defaultUserId,
          'metrics': metrics
        }),
      );

      return _safeParse(r, 'Falha no atleta');
    } catch (e) {
      return 'Erro atleta: $e';
    }
  }

  Future<String> sendFeedback(String feedback) async {
    try {
      final r = await http.post(
        Uri.parse('${MeganConfig.baseUrl}/api/feedback'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'userId': MeganConfig.defaultUserId,
          'feedback': feedback
        }),
      );

      return _safeParse(r, 'Falha ao registrar sugestão');
    } catch (e) {
      return 'Erro sugestão: $e';
    }
  }

  // 🔥 CORAÇÃO DA CORREÇÃO
  String _safeParse(http.Response r, String fallback) {
    try {
      final body = r.body.trim();

      // 🚨 Detecta HTML (erro do backend)
      if (body.startsWith('<!DOCTYPE') || body.startsWith('<html')) {
        return 'Erro no servidor (backend retornou HTML). Verifique o Render.';
      }

      final d = jsonDecode(body);

      if (r.statusCode >= 400 || d['ok'] != true) {
        return d['error'] ?? fallback;
      }

      // padrão do seu backend
      if (d.containsKey('answer')) return d['answer'];
      if (d.containsKey('response')) return d['response'];
      if (d.containsKey('message')) return d['message'];

      return d.toString();
    } catch (e) {
      return '$fallback (${e.toString()})';
    }
  }
}