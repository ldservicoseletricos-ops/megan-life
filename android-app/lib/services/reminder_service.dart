import 'package:flutter/services.dart';

class ReminderScheduleResult {
  final bool ok;
  final String message;
  final DateTime? scheduledAt;
  final String? title;
  final String? body;

  const ReminderScheduleResult({
    required this.ok,
    required this.message,
    this.scheduledAt,
    this.title,
    this.body,
  });
}

class ReminderService {
  static const MethodChannel _channel = MethodChannel('megan.reminders');

  Future<ReminderScheduleResult> scheduleFromText(String text) async {
    final parsed = _parseReminder(text);

    if (parsed == null) {
      return const ReminderScheduleResult(
        ok: false,
        message: 'Luiz, entendi que você quer um lembrete, mas preciso do horário. Exemplo: "me lembre de tomar remédio às 18:30" ou "me lembre em 10 minutos".',
      );
    }

    if (parsed.scheduledAt.isBefore(DateTime.now().add(const Duration(seconds: 10)))) {
      return const ReminderScheduleResult(
        ok: false,
        message: 'Luiz, esse horário já passou ou está muito próximo. Me diga um horário futuro para eu criar o alerta.',
      );
    }

    try {
      final ok = await _channel.invokeMethod<bool>('scheduleReminder', {
        'id': parsed.id,
        'title': parsed.title,
        'body': parsed.body,
        'triggerMillis': parsed.scheduledAt.millisecondsSinceEpoch,
      });

      if (ok == true) {
        return ReminderScheduleResult(
          ok: true,
          message: 'Pronto, Luiz. Criei o alerta real para ${_formatDateTime(parsed.scheduledAt)}: ${parsed.body}',
          scheduledAt: parsed.scheduledAt,
          title: parsed.title,
          body: parsed.body,
        );
      }

      return const ReminderScheduleResult(
        ok: false,
        message: 'Luiz, não consegui criar o alerta no Android agora.',
      );
    } catch (e) {
      return ReminderScheduleResult(
        ok: false,
        message: 'Luiz, não consegui criar o alerta no Android agora: $e',
      );
    }
  }

  _ParsedReminder? _parseReminder(String originalText) {
    final original = originalText.trim();
    if (original.isEmpty) return null;

    final normalized = _normalize(original);
    final now = DateTime.now();
    DateTime? scheduledAt;

    final relativeMinutes = RegExp(r'(?:daqui\s+|em\s+)(\d{1,4})\s*(?:minuto|minutos|min)\b').firstMatch(normalized);
    if (relativeMinutes != null) {
      final minutes = int.tryParse(relativeMinutes.group(1) ?? '');
      if (minutes != null && minutes > 0) {
        scheduledAt = now.add(Duration(minutes: minutes));
      }
    }

    final relativeHours = RegExp(r'(?:daqui\s+|em\s+)(\d{1,3})\s*(?:hora|horas|h)\b').firstMatch(normalized);
    if (scheduledAt == null && relativeHours != null) {
      final hours = int.tryParse(relativeHours.group(1) ?? '');
      if (hours != null && hours > 0) {
        scheduledAt = now.add(Duration(hours: hours));
      }
    }

    final timeMatches = RegExp(r'(?:as|às|a|para as|para às)\s*(\d{1,2})(?:[:h](\d{2}))?')
        .allMatches(original.toLowerCase())
        .toList();

    if (scheduledAt == null && timeMatches.isNotEmpty) {
      final match = timeMatches.last;
      final hour = int.tryParse(match.group(1) ?? '');
      final minute = int.tryParse(match.group(2) ?? '0') ?? 0;

      if (hour != null && hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59) {
        var day = DateTime(now.year, now.month, now.day);

        if (normalized.contains('amanha') || normalized.contains('amanhã')) {
          day = day.add(const Duration(days: 1));
        }

        scheduledAt = DateTime(day.year, day.month, day.day, hour, minute);

        if (!normalized.contains('amanha') &&
            !normalized.contains('amanhã') &&
            scheduledAt.isBefore(now.add(const Duration(seconds: 10)))) {
          scheduledAt = scheduledAt.add(const Duration(days: 1));
        }
      }
    }

    if (scheduledAt == null) return null;

    final body = _extractReminderBody(original);
    final safeBody = body.isEmpty ? 'Lembrete da Megan Life' : body;

    return _ParsedReminder(
      id: scheduledAt.millisecondsSinceEpoch % 2147483647,
      title: 'Megan Life',
      body: safeBody,
      scheduledAt: scheduledAt,
    );
  }

  String _extractReminderBody(String text) {
    var value = text.trim();

    value = value.replaceFirst(
      RegExp(
        r'^(me\s+lembre\s+de|me\s+lembra\s+de|lembre\s+de|lembra\s+de|crie\s+um\s+lembrete\s+para|criar\s+lembrete\s+para|cria\s+um\s+lembrete\s+para|gerar\s+lembrete\s+para|gere\s+um\s+lembrete\s+para|lembrete\s+para)\s+',
        caseSensitive: false,
      ),
      '',
    );

    value = value.replaceAll(
      RegExp(
        r'\s+(?:daqui\s+\d{1,4}\s*(?:minuto|minutos|min|hora|horas|h)|em\s+\d{1,4}\s*(?:minuto|minutos|min|hora|horas|h)).*$',
        caseSensitive: false,
      ),
      '',
    );

    value = value.replaceAll(
      RegExp(r'\s+(?:hoje\s+|amanhã\s+|amanha\s+)?(?:as|às|a|para as|para às)\s*\d{1,2}(?:[:h]\d{2})?.*$', caseSensitive: false),
      '',
    );

    return value.trim();
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

  String _formatDateTime(DateTime date) {
    final d = date.day.toString().padLeft(2, '0');
    final m = date.month.toString().padLeft(2, '0');
    final h = date.hour.toString().padLeft(2, '0');
    final min = date.minute.toString().padLeft(2, '0');
    return '$d/$m às $h:$min';
  }
}

class _ParsedReminder {
  final int id;
  final String title;
  final String body;
  final DateTime scheduledAt;

  const _ParsedReminder({
    required this.id,
    required this.title,
    required this.body,
    required this.scheduledAt,
  });
}
