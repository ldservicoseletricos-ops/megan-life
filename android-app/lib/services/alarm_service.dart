import 'package:flutter/services.dart';

class AlarmService {
  static const MethodChannel _channel = MethodChannel('megan.alarm');

  Future<bool> setAlarm({
    required int hour,
    required int minute,
    String message = 'Alarme Megan',
    bool skipUi = true,
  }) async {
    try {
      final result = await _channel.invokeMethod('setAlarm', {
        'hour': hour,
        'minute': minute,
        'message': message,
        'skipUi': skipUi,
      });

      return result == true;
    } catch (_) {
      return false;
    }
  }

  Future<String> setFromText(String text) async {
    final parsed = _parseAlarm(text);

    if (parsed == null) {
      return 'Luiz, me diga o horário. Ex: me acorde às 07:00';
    }

    final ok = await setAlarm(
      hour: parsed.hour,
      minute: parsed.minute,
      message: parsed.message,
      skipUi: true,
    );

    final time = '${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}';

    return ok
        ? 'Pronto, Luiz. Ativei o despertador automático para $time.'
        : 'Luiz, não consegui configurar o despertador automático. Tente abrir o app Relógio ou me peça para configurar com tela.';
  }

  Future<String> setFromTextWithScreen(String text) async {
    final parsed = _parseAlarm(text);

    if (parsed == null) {
      return 'Luiz, me diga o horário. Ex: me acorde às 07:00';
    }

    final ok = await setAlarm(
      hour: parsed.hour,
      minute: parsed.minute,
      message: parsed.message,
      skipUi: false,
    );

    final time = '${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}';

    return ok
        ? 'Pronto, Luiz. Abri a tela do despertador para configurar $time.'
        : 'Luiz, não consegui abrir o despertador do celular.';
  }

  _ParsedAlarm? _parseAlarm(String text) {
    final clean = text.trim();
    if (clean.isEmpty) return null;

    final normalized = _normalize(clean);

    final match = RegExp(r'(\d{1,2})[:h](\d{2})').firstMatch(normalized);
    if (match != null) {
      final hour = int.tryParse(match.group(1)!);
      final minute = int.tryParse(match.group(2)!);

      if (hour != null && minute != null && hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59) {
        return _ParsedAlarm(
          hour: hour,
          minute: minute,
          message: _extractAlarmMessage(clean),
        );
      }
    }

    final simple = RegExp(r'(?:as|para|alarme|despertador|acorde|acorda)\s+(\d{1,2})\b').firstMatch(normalized);
    if (simple != null) {
      final hour = int.tryParse(simple.group(1)!);

      if (hour != null && hour >= 0 && hour <= 23) {
        return _ParsedAlarm(
          hour: hour,
          minute: 0,
          message: _extractAlarmMessage(clean),
        );
      }
    }

    return null;
  }

  String _extractAlarmMessage(String text) {
    var value = text.trim();

    value = value.replaceFirst(
      RegExp(
        r'^(me\s+acorde|me\s+acorda|acorde\s+me|acorda\s+me|me\s+desperte|me\s+desperta|definir\s+alarme|defina\s+alarme|criar\s+alarme|crie\s+alarme|ativar\s+despertador|ative\s+despertador|despertador|alarme)\s*',
        caseSensitive: false,
      ),
      '',
    );

    value = value.replaceAll(
      RegExp(r'\s*(?:as|às|para|para as|para às|a)\s*\d{1,2}(?:[:h]\d{2})?.*$', caseSensitive: false),
      '',
    );

    final clean = value.trim();
    return clean.isEmpty ? 'Alarme Megan' : clean;
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
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}

class _ParsedAlarm {
  final int hour;
  final int minute;
  final String message;

  const _ParsedAlarm({
    required this.hour,
    required this.minute,
    required this.message,
  });
}
