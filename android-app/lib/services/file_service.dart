import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'config.dart';

class FileService {
  Future<String> analyzeFile(File file) async {
    final request = http.MultipartRequest('POST', Uri.parse('${MeganConfig.baseUrl}/api/files/analyze'));
    request.files.add(await http.MultipartFile.fromPath('file', file.path));
    final response = await request.send();
    final body = await response.stream.bytesToString();
    final data = jsonDecode(body);
    if (response.statusCode >= 400 || data['ok'] != true) {
      throw Exception(data['error'] ?? 'Falha ao analisar arquivo');
    }
    return data['answer'] ?? 'Arquivo analisado, mas sem resposta.';
  }
}
