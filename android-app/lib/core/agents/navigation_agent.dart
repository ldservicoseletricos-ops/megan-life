import 'package:flutter/material.dart';

import '../../services/navigation_service.dart';

class NavigationAgent {
  final NavigationService _nav;

  NavigationAgent(this._nav);

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

  bool canHandle(String command) {
    final text = _normalize(command);

    return text.contains('me leva pra') ||
        text.contains('me leva para') ||
        text.contains('me leva no') ||
        text.contains('me leva ao') ||
        text.contains('me leve pra') ||
        text.contains('me leve para') ||
        text.contains('me leve no') ||
        text.contains('me leve ao') ||
        text.contains('leva pra') ||
        text.contains('leva para') ||
        text.contains('leve pra') ||
        text.contains('leve para') ||
        text.contains('ir pra') ||
        text.contains('ir para') ||
        text.contains('ir pro') ||
        text.contains('ir ao') ||
        text.contains('ir no') ||
        text.contains('vamos pra') ||
        text.contains('vamos para') ||
        text.contains('vamos pro') ||
        text.contains('vamos ao') ||
        text.contains('navegar pra') ||
        text.contains('navegar para') ||
        text.contains('rota pra') ||
        text.contains('rota para') ||
        text.contains('direcao pra') ||
        text.contains('direcao para') ||
        text.contains('direção pra') ||
        text.contains('direção para') ||
        text.contains('waze para') ||
        text.contains('maps para') ||
        text.contains('google maps para');
  }

  String extractDestination(String command) {
    var text = _normalize(command);

    text = text
        .replaceAll('por favor', '')
        .replaceAll('agora', '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    final patterns = <String>[
      'me leva para',
      'me leva pra',
      'me leva no',
      'me leva ao',
      'me leve para',
      'me leve pra',
      'me leve no',
      'me leve ao',
      'leva para',
      'leva pra',
      'leve para',
      'leve pra',
      'navegar para',
      'navegar pra',
      'rota para',
      'rota pra',
      'direcao para',
      'direcao pra',
      'direção para',
      'direção pra',
      'google maps para',
      'maps para',
      'waze para',
      'vamos para',
      'vamos pra',
      'vamos pro',
      'vamos ao',
      'ir para',
      'ir pra',
      'ir pro',
      'ir ao',
      'ir no',
      'ir na',
    ];

    for (final pattern in patterns) {
      if (text.contains(pattern)) {
        final parts = text.split(pattern);
        if (parts.length > 1) {
          final destination = parts.last.trim();
          if (destination.isNotEmpty) return destination;
        }
      }
    }

    return text.trim();
  }

  Future<bool> handle(BuildContext context, String command) async {
    if (!canHandle(command)) return false;

    final destination = extractDestination(command);
    if (destination.isEmpty) return false;

    await _nav.openNavigationChoice(context, destination);
    return true;
  }
}
