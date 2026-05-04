import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class MeganMemoryItem {
  final String id;
  final String type;
  final String key;
  final String value;
  final int priority;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? expiresAt;

  const MeganMemoryItem({
    required this.id,
    required this.type,
    required this.key,
    required this.value,
    required this.priority,
    required this.createdAt,
    required this.updatedAt,
    this.expiresAt,
  });

  bool get isExpired {
    final expires = expiresAt;
    if (expires == null) return false;
    return DateTime.now().isAfter(expires);
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type,
      'key': key,
      'value': value,
      'priority': priority,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'expiresAt': expiresAt?.toIso8601String(),
    };
  }

  factory MeganMemoryItem.fromJson(Map<String, dynamic> json) {
    return MeganMemoryItem(
      id: (json['id'] ?? '').toString(),
      type: (json['type'] ?? 'general').toString(),
      key: (json['key'] ?? '').toString(),
      value: (json['value'] ?? '').toString(),
      priority: int.tryParse((json['priority'] ?? 1).toString()) ?? 1,
      createdAt: DateTime.tryParse((json['createdAt'] ?? '').toString()) ?? DateTime.now(),
      updatedAt: DateTime.tryParse((json['updatedAt'] ?? '').toString()) ?? DateTime.now(),
      expiresAt: json['expiresAt'] == null ? null : DateTime.tryParse(json['expiresAt'].toString()),
    );
  }
}

class MeganMemoryService {
  static const String _storageKey = 'megan_memory_items_v71';
  static const int _maxItems = 80;

  Future<List<MeganMemoryItem>> getAll({bool includeExpired = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_storageKey) ?? [];

    final items = raw
        .map((entry) {
          try {
            final decoded = jsonDecode(entry);
            if (decoded is Map<String, dynamic>) {
              return MeganMemoryItem.fromJson(decoded);
            }
            if (decoded is Map) {
              return MeganMemoryItem.fromJson(Map<String, dynamic>.from(decoded));
            }
          } catch (_) {}
          return null;
        })
        .whereType<MeganMemoryItem>()
        .where((item) => includeExpired || !item.isExpired)
        .toList();

    items.sort((a, b) {
      final priority = b.priority.compareTo(a.priority);
      if (priority != 0) return priority;
      return b.updatedAt.compareTo(a.updatedAt);
    });

    if (!includeExpired && items.length != raw.length) {
      await _save(items);
    }

    return items;
  }

  Future<void> remember({
    required String key,
    required String value,
    String type = 'general',
    int priority = 2,
    Duration? ttl,
  }) async {
    final cleanKey = _normalizeKey(key);
    final cleanValue = value.trim();

    if (cleanKey.isEmpty || cleanValue.isEmpty) return;

    final now = DateTime.now();
    final items = await getAll();
    final index = items.indexWhere((item) => item.key == cleanKey && item.type == type);

    final item = MeganMemoryItem(
      id: index >= 0 ? items[index].id : '${now.microsecondsSinceEpoch}_$cleanKey',
      type: type,
      key: cleanKey,
      value: cleanValue,
      priority: priority.clamp(1, 5),
      createdAt: index >= 0 ? items[index].createdAt : now,
      updatedAt: now,
      expiresAt: ttl == null ? null : now.add(ttl),
    );

    if (index >= 0) {
      items[index] = item;
    } else {
      items.add(item);
    }

    await _save(_trim(items));
  }

  Future<void> rememberUserPreference(String value) async {
    final text = value.trim();
    if (text.isEmpty) return;

    await remember(
      key: _guessKey(text),
      value: text,
      type: 'preference',
      priority: 4,
    );
  }

  Future<void> rememberContext(String userText, String meganText) async {
    final user = userText.trim();
    final megan = meganText.trim();

    if (user.isEmpty || megan.isEmpty) return;

    await remember(
      key: 'ultimo_contexto',
      value: 'Luiz: $user\nMegan: $megan',
      type: 'context',
      priority: 2,
      ttl: const Duration(days: 7),
    );
  }

  Future<void> rememberUsagePattern(String command) async {
    final normalized = _normalizeKey(command);
    if (normalized.isEmpty || normalized.length < 3) return;

    await remember(
      key: 'padrao_$normalized',
      value: command.trim(),
      type: 'usage',
      priority: 2,
      ttl: const Duration(days: 30),
    );
  }

  Future<String> buildMemoryContext({int limit = 12}) async {
    final items = await getAll();

    if (items.isEmpty) {
      return 'Memória local da Megan: ainda não há memórias salvas.';
    }

    final buffer = StringBuffer();
    buffer.writeln('Memória local relevante da Megan:');

    for (final item in items.take(limit)) {
      buffer.writeln('- [${item.type}/P${item.priority}] ${item.key}: ${item.value}');
    }

    return buffer.toString().trim();
  }

  Future<String> profileText() async {
    final items = await getAll();

    if (items.isEmpty) {
      return 'Ainda não tenho memórias locais salvas sobre você neste aparelho.';
    }

    final grouped = <String, List<MeganMemoryItem>>{};

    for (final item in items) {
      grouped.putIfAbsent(item.type, () => []).add(item);
    }

    final buffer = StringBuffer();
    buffer.writeln('📊 O que eu lembro sobre você neste aparelho:\n');

    for (final entry in grouped.entries) {
      buffer.writeln('### ${_typeLabel(entry.key)}');
      for (final item in entry.value.take(8)) {
        buffer.writeln('• ${item.value}');
      }
      buffer.writeln('');
    }

    return buffer.toString().trim();
  }

  Future<void> forget(String query) async {
    final q = _normalizeKey(query);
    if (q.isEmpty) return;

    final items = await getAll();
    items.removeWhere((item) {
      return item.key.contains(q) ||
          _normalizeKey(item.value).contains(q) ||
          _normalizeKey(item.type).contains(q);
    });

    await _save(items);
  }

  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_storageKey);
  }

  List<MeganMemoryItem> _trim(List<MeganMemoryItem> items) {
    items.removeWhere((item) => item.isExpired);

    items.sort((a, b) {
      final priority = b.priority.compareTo(a.priority);
      if (priority != 0) return priority;
      return b.updatedAt.compareTo(a.updatedAt);
    });

    if (items.length <= _maxItems) return items;
    return items.take(_maxItems).toList();
  }

  Future<void> _save(List<MeganMemoryItem> items) async {
    final prefs = await SharedPreferences.getInstance();
    final payload = _trim(items).map((item) => jsonEncode(item.toJson())).toList();
    await prefs.setStringList(_storageKey, payload);
  }

  String _guessKey(String text) {
    final normalized = _normalizeKey(text);

    if (normalized.contains('prefiro')) return 'preferencia';
    if (normalized.contains('gosto')) return 'gosto';
    if (normalized.contains('meu_peso')) return 'peso';
    if (normalized.contains('minha_rotina')) return 'rotina';
    if (normalized.contains('meu_horario')) return 'horario';

    final words = normalized.split('_').where((word) => word.length > 2).take(4);
    final key = words.join('_');

    return key.isEmpty ? 'memoria_manual' : key;
  }

  String _typeLabel(String type) {
    switch (type) {
      case 'preference':
        return 'Preferências';
      case 'context':
        return 'Contexto recente';
      case 'usage':
        return 'Padrões de uso';
      case 'manual':
        return 'Memórias manuais';
      default:
        return 'Geral';
    }
  }

  String _normalizeKey(String text) {
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
        .trim()
        .replaceAll(' ', '_');
  }
}
