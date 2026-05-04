import 'dart:io';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

class AppLauncherService {
  static const MethodChannel _platform = MethodChannel('megan.apps');

  List<Map<String, dynamic>> _installedApps = [];

  final Map<String, String> knownPackages = const {
    'whatsapp': 'com.whatsapp',
    'zap': 'com.whatsapp',
    'wpp': 'com.whatsapp',
    'whatsapp business': 'com.whatsapp.w4b',
    'zap business': 'com.whatsapp.w4b',
    'wpp business': 'com.whatsapp.w4b',
    'business whatsapp': 'com.whatsapp.w4b',
    'telegram': 'org.telegram.messenger',
    'waze': 'com.waze',
    'maps': 'com.google.android.apps.maps',
    'google maps': 'com.google.android.apps.maps',
    'mapa': 'com.google.android.apps.maps',
    'gmail': 'com.google.android.gm',
    'youtube': 'com.google.android.youtube',
    'yt': 'com.google.android.youtube',
    'instagram': 'com.instagram.android',
    'insta': 'com.instagram.android',
    'facebook': 'com.facebook.katana',
    'face': 'com.facebook.katana',
    'chrome': 'com.android.chrome',
    'navegador': 'com.android.chrome',
    'spotify': 'com.spotify.music',
    'uber': 'com.ubercab',
    '99': 'com.taxis99',
    'netflix': 'com.netflix.mediaclient',
    'nubank': 'com.nu.production',
    'nu bank': 'com.nu.production',
    'nubanco': 'com.nu.production',
    'nu': 'com.nu.production',
    'tiktok': 'com.zhiliaoapp.musically',
    'tik tok': 'com.zhiliaoapp.musically',
    'tk tok': 'com.zhiliaoapp.musically',
    'configuracoes': 'com.android.settings',
    'configurações': 'com.android.settings',
    'settings': 'com.android.settings',
    'camera': 'com.android.camera',
    'câmera': 'com.android.camera',
  };

  final Map<String, String> knownSchemes = const {
    'whatsapp': 'whatsapp://send',
    'zap': 'whatsapp://send',
    'wpp': 'whatsapp://send',
    'whatsapp business': 'whatsapp://send',
    'zap business': 'whatsapp://send',
    'wpp business': 'whatsapp://send',
    'business whatsapp': 'whatsapp://send',
    'telegram': 'tg://',
    'waze': 'waze://',
    'maps': 'geo:0,0',
    'google maps': 'geo:0,0',
    'mapa': 'geo:0,0',
    'youtube': 'youtube://',
    'yt': 'youtube://',
    'instagram': 'instagram://app',
    'insta': 'instagram://app',
    'facebook': 'fb://',
    'spotify': 'spotify://',
  };

  Future<void> loadApps() async {
    if (!Platform.isAndroid) return;

    try {
      final apps = await _platform.invokeMethod('getInstalledApps');

      if (apps is List) {
        _installedApps = apps
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
      }
    } catch (_) {
      _installedApps = [];
    }
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
        .replaceAll(RegExp(r'\b(abrir|abre|abrindo|iniciar|inicia|rodar|executar|executa)\b'), '')
        .replaceAll(RegExp(r'\b(o|a|app|aplicativo|programa)\b'), '')
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _compact(String text) {
    return _normalize(text).replaceAll(' ', '');
  }

  String _cleanWhatsAppPhone(String phone) {
    var value = phone.replaceAll(RegExp(r'\D'), '');

    if (value.startsWith('00')) {
      value = value.substring(2);
    }

    while (value.startsWith('0') && value.length > 11) {
      value = value.substring(1);
    }

    if (value.length == 10 || value.length == 11) {
      value = '55$value';
    }

    return value;
  }

  bool _isValidWhatsAppPhone(String phone) {
    final clean = _cleanWhatsAppPhone(phone);
    return clean.length >= 12 && clean.length <= 15;
  }

  Future<bool> openWhatsAppChat({
    String? phone,
    String? message,
    bool preferBusiness = false,
  }) async {
    final text = (message ?? '').trim();
    final hasPhone = phone != null && phone.trim().isNotEmpty;

    final packages = preferBusiness
        ? const ['com.whatsapp.w4b', 'com.whatsapp']
        : const ['com.whatsapp', 'com.whatsapp.w4b'];

    if (!hasPhone) {
      for (final packageName in packages) {
        final opened = await _openNativeApp(packageName);
        if (opened) return true;
      }

      final schemeOk = await _tryLaunch(Uri.parse('whatsapp://send'));
      if (schemeOk) return true;

      return await openKnownApp(preferBusiness ? 'whatsapp business' : 'whatsapp');
    }

    final cleanPhone = _cleanWhatsAppPhone(phone);
    if (!_isValidWhatsAppPhone(cleanPhone)) {
      return false;
    }

    final encodedMessage = Uri.encodeComponent(text);

    final deepLink = encodedMessage.isEmpty
        ? Uri.parse('whatsapp://send?phone=$cleanPhone')
        : Uri.parse('whatsapp://send?phone=$cleanPhone&text=$encodedMessage');

    final deepLinkOk = await _tryLaunch(deepLink);
    if (deepLinkOk) return true;

    final webLink = encodedMessage.isEmpty
        ? Uri.parse('https://wa.me/$cleanPhone')
        : Uri.parse('https://wa.me/$cleanPhone?text=$encodedMessage');

    final webOk = await _tryLaunch(webLink);
    if (webOk) return true;

    for (final packageName in packages) {
      final opened = await _openNativeApp(packageName);
      if (opened) return true;
    }

    return false;
  }

  Future<bool> sendWhatsAppMessage({
    required String phone,
    required String message,
    bool preferBusiness = false,
  }) async {
    return openWhatsAppChat(
      phone: phone,
      message: message,
      preferBusiness: preferBusiness,
    );
  }




  Future<bool> hasWhatsAppNormal() async {
    return _isPackageInstalled('com.whatsapp');
  }

  Future<bool> hasWhatsAppBusiness() async {
    return _isPackageInstalled('com.whatsapp.w4b');
  }

  Future<bool> openWhatsAppNormal() async {
    final nativeOk = await _openNativeApp('com.whatsapp');
    if (nativeOk) return true;

    final schemeOk = await _tryLaunch(Uri.parse('whatsapp://send'));
    if (schemeOk) return true;

    return _openPlayStore('com.whatsapp');
  }

  Future<bool> openWhatsAppBusiness() async {
    final nativeOk = await _openNativeApp('com.whatsapp.w4b');
    if (nativeOk) return true;

    // Evita usar whatsapp://send como fallback aqui, porque quando o WhatsApp normal
    // também está instalado o Android pode abrir o app normal em vez do Business.
    return _openPlayStore('com.whatsapp.w4b');
  }

  Future<bool> _isPackageInstalled(String packageName) async {
    if (!Platform.isAndroid || packageName.trim().isEmpty) return false;

    if (_installedApps.isEmpty) {
      await loadApps();
    }

    for (final app in _installedApps) {
      final currentPackage = (app['package'] ?? '').toString();
      if (currentPackage == packageName) return true;
    }

    return false;
  }


  String _fixSpeechAppName(String text) {
    final normalized = _normalize(text);
    final compact = _compact(text);

    if (compact.contains('nubank') ||
        compact.contains('nubak') ||
        compact.contains('nubanc') ||
        compact.contains('nubanco') ||
        compact.contains('nubamk') ||
        compact.contains('nubamc') ||
        compact.contains('nubk') ||
        compact.contains('nubak') ||
        compact.contains('nuba') ||
        compact.contains('nub')) {
      return 'nubank';
    }

    if (compact.contains('tiktok') ||
        compact.contains('tictok') ||
        compact.contains('tiktok') ||
        compact.contains('tktok') ||
        compact.contains('tiktok') ||
        normalized.contains('tk tok') ||
        normalized.contains('tik tok') ||
        normalized.contains('tic tok')) {
      return 'tiktok';
    }

    if (compact.contains('youtube') ||
        compact.contains('yutube') ||
        compact.contains('iutube') ||
        compact.contains('yt')) {
      return 'youtube';
    }

    if ((compact.contains('business') ||
            normalized.contains('comercial') ||
            normalized.contains('empresa')) &&
        (compact.contains('whatsapp') ||
            compact.contains('wattsapp') ||
            compact.contains('whats') ||
            compact.contains('zap') ||
            compact.contains('wpp'))) {
      return 'whatsapp business';
    }

    if (compact.contains('whatsapp') ||
        compact.contains('wattsapp') ||
        compact.contains('whats') ||
        compact.contains('zap') ||
        compact.contains('wpp')) {
      return 'whatsapp';
    }

    if (compact.contains('instagram') ||
        compact.contains('instagran') ||
        compact.contains('insta')) {
      return 'instagram';
    }

    if (compact.contains('telegram')) {
      return 'telegram';
    }

    if (compact.contains('spotify')) {
      return 'spotify';
    }

    return normalized;
  }

  int _levenshtein(String s, String t) {
    if (s == t) return 0;
    if (s.isEmpty) return t.length;
    if (t.isEmpty) return s.length;

    final v0 = List<int>.generate(t.length + 1, (i) => i);
    final v1 = List<int>.filled(t.length + 1, 0);

    for (int i = 0; i < s.length; i++) {
      v1[0] = i + 1;

      for (int j = 0; j < t.length; j++) {
        final cost = s[i] == t[j] ? 0 : 1;
        v1[j + 1] = [
          v1[j] + 1,
          v0[j + 1] + 1,
          v0[j] + cost,
        ].reduce((a, b) => a < b ? a : b);
      }

      for (int j = 0; j < v0.length; j++) {
        v0[j] = v1[j];
      }
    }

    return v1[t.length];
  }

  String? _detectKnownApp(String text) {
    final normalized = _fixSpeechAppName(text);
    final compact = normalized.replaceAll(' ', '');

    if (knownPackages.containsKey(normalized)) {
      return normalized;
    }

    for (final key in knownPackages.keys) {
      final normalizedKey = _normalize(key);
      final compactKey = normalizedKey.replaceAll(' ', '');

      if (normalized == normalizedKey ||
          compact == compactKey ||
          normalized.contains(normalizedKey) ||
          normalizedKey.contains(normalized) ||
          compact.contains(compactKey) ||
          compactKey.contains(compact)) {
        return key;
      }

      final distance = _levenshtein(compact, compactKey);
      final allowedDistance = compact.length <= 5 ? 2 : 3;

      if (distance <= allowedDistance) {
        return key;
      }
    }

    return null;
  }

  Map<String, dynamic>? _detectInstalledApp(String text) {
    final normalized = _fixSpeechAppName(text);
    final compactInput = normalized.replaceAll(' ', '');

    if (normalized.isEmpty || _installedApps.isEmpty) return null;

    Map<String, dynamic>? bestMatch;
    var bestScore = 0;

    for (final app in _installedApps) {
      final name = _normalize((app['name'] ?? '').toString());
      final compactName = name.replaceAll(' ', '');
      final packageName = (app['package'] ?? '').toString();

      if (name.isEmpty || packageName.isEmpty) continue;

      var score = 0;

      if (name == normalized || compactName == compactInput) {
        score = 120;
      } else if (name.contains(normalized) || compactName.contains(compactInput)) {
        score = 95;
      } else if (normalized.contains(name) || compactInput.contains(compactName)) {
        score = 85;
      } else {
        final distance = _levenshtein(compactInput, compactName);
        final maxLen = compactInput.length > compactName.length ? compactInput.length : compactName.length;

        if (distance <= 2) {
          score = 80;
        } else if (distance <= 4 && maxLen >= 6) {
          score = 65;
        }

        final inputWords = normalized.split(' ');
        final appWords = name.split(' ');

        for (final inputWord in inputWords) {
          if (inputWord.length < 2) continue;

          for (final appWord in appWords) {
            if (appWord == inputWord) {
              score += 20;
            } else if (appWord.contains(inputWord) || inputWord.contains(appWord)) {
              score += 10;
            } else if (_levenshtein(inputWord, appWord) <= 2) {
              score += 8;
            }
          }
        }
      }

      if (score > bestScore) {
        bestScore = score;
        bestMatch = app;
      }
    }

    if (bestScore >= 20) {
      return bestMatch;
    }

    return null;
  }

  Future<bool> openKnownApp(String name) async {
    final fixedName = _fixSpeechAppName(name);
    final detectedKnown = _detectKnownApp(fixedName);

    if (detectedKnown == 'whatsapp' || detectedKnown == 'zap' || detectedKnown == 'wpp') {
      final nativeWhatsApp = await _openNativeApp('com.whatsapp');
      if (nativeWhatsApp) return true;

      final nativeBusiness = await _openNativeApp('com.whatsapp.w4b');
      if (nativeBusiness) return true;

      final schemeWhatsApp = await _tryLaunch(Uri.parse('whatsapp://send'));
      if (schemeWhatsApp) return true;
    }

    if (detectedKnown == 'whatsapp business' ||
        detectedKnown == 'zap business' ||
        detectedKnown == 'wpp business' ||
        detectedKnown == 'business whatsapp') {
      final nativeBusiness = await _openNativeApp('com.whatsapp.w4b');
      if (nativeBusiness) return true;

      final nativeWhatsApp = await _openNativeApp('com.whatsapp');
      if (nativeWhatsApp) return true;

      final schemeWhatsApp = await _tryLaunch(Uri.parse('whatsapp://send'));
      if (schemeWhatsApp) return true;
    }

    if (detectedKnown != null) {
      final pkg = knownPackages[detectedKnown];
      final scheme = knownSchemes[detectedKnown];

      final opened = await _openByPackageOrScheme(
        packageName: pkg,
        scheme: scheme,
      );

      if (opened) return true;
    }

    if (_installedApps.isEmpty) {
      await loadApps();
    }

    final installedMatch = _detectInstalledApp(fixedName);

    if (installedMatch != null) {
      final packageName = (installedMatch['package'] ?? '').toString();

      if (packageName.isNotEmpty) {
        final opened = await _openNativeApp(packageName);
        if (opened) return true;
      }
    }

    if (detectedKnown != null) {
      final pkg = knownPackages[detectedKnown];

      if (pkg != null && pkg.isNotEmpty) {
        final storeOpened = await _openPlayStore(pkg);
        if (storeOpened) return true;
      }
    }

    return _openWebSearch(fixedName);
  }

  Future<bool> _openByPackageOrScheme({
    required String? packageName,
    required String? scheme,
  }) async {
    try {
      if (scheme != null && scheme.isNotEmpty) {
        final ok = await _tryLaunch(Uri.parse(scheme));
        if (ok) return true;
      }

      if (Platform.isAndroid && packageName != null && packageName.isNotEmpty) {
        final nativeOk = await _openNativeApp(packageName);
        if (nativeOk) return true;

        final intentUri = Uri.parse('intent://#Intent;package=$packageName;end');
        final intentOk = await _tryLaunch(intentUri);
        if (intentOk) return true;
      }

      return false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _openNativeApp(String packageName) async {
    if (!Platform.isAndroid) return false;

    try {
      final ok = await _platform.invokeMethod('openApp', {
        'package': packageName,
      });

      return ok == true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _openPlayStore(String packageName) async {
    try {
      final marketUri = Uri.parse('market://details?id=$packageName');
      final marketOk = await _tryLaunch(marketUri);
      if (marketOk) return true;

      final webUri = Uri.parse(
        'https://play.google.com/store/apps/details?id=$packageName',
      );

      return await _tryLaunch(webUri);
    } catch (_) {
      return false;
    }
  }

  Future<bool> _openWebSearch(String name) async {
    try {
      final query = Uri.encodeComponent(_normalize(name));
      final url = Uri.parse('https://www.google.com/search?q=$query');

      return await _tryLaunch(url);
    } catch (_) {
      return false;
    }
  }

  Future<bool> _tryLaunch(Uri uri) async {
    try {
      final canOpen = await canLaunchUrl(uri);
      if (!canOpen) return false;

      return await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      return false;
    }
  }


  bool isMediaAppName(String name) {
    final fixed = _fixSpeechAppName(name);
    final normalized = _normalize(fixed);

    return normalized.contains('youtube') ||
        normalized.contains('yt music') ||
        normalized.contains('youtube music') ||
        normalized.contains('spotify') ||
        normalized.contains('tiktok') ||
        normalized.contains('tik tok') ||
        normalized.contains('instagram') ||
        normalized.contains('reels') ||
        normalized.contains('netflix') ||
        normalized.contains('prime video') ||
        normalized.contains('disney') ||
        normalized.contains('max') ||
        normalized.contains('deezer') ||
        normalized.contains('musica') ||
        normalized.contains('música') ||
        normalized.contains('video') ||
        normalized.contains('vídeo');
  }

  Future<bool> openMediaApp(String name) async {
    if (!isMediaAppName(name)) return false;
    return openKnownApp(name);
  }

  bool isCommunicationAppName(String name) {
    final fixed = _fixSpeechAppName(name);
    final normalized = _normalize(fixed);

    return normalized.contains('whatsapp') ||
        normalized.contains('zap') ||
        normalized.contains('wpp') ||
        normalized.contains('telegram') ||
        normalized.contains('gmail') ||
        normalized.contains('email') ||
        normalized.contains('e mail') ||
        normalized.contains('mensagem') ||
        normalized.contains('messages') ||
        normalized.contains('sms') ||
        normalized.contains('messenger') ||
        normalized.contains('signal');
  }

  Future<bool> openCommunicationApp(String name) async {
    if (!isCommunicationAppName(name)) return false;
    return openKnownApp(name);
  }

  bool canOpenExternalAppName(String name) {
    final fixed = _fixSpeechAppName(name);
    final normalized = _normalize(fixed);

    if (normalized.isEmpty) return false;

    // Comunicação continua no fluxo próprio para preservar áudio de mensagens.
    if (isCommunicationAppName(normalized)) {
      return false;
    }

    if (knownPackages.containsKey(normalized)) return true;

    final detectedKnown = _detectKnownApp(normalized);
    if (detectedKnown != null) return true;

    final installed = _detectInstalledApp(normalized);
    return installed != null;
  }

  Future<bool> openExternalApp(String name) async {
    if (!canOpenExternalAppName(name)) return false;
    return openKnownApp(name);
  }

}
