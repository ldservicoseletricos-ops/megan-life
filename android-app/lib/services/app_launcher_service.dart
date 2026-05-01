import 'dart:io';
import 'package:url_launcher/url_launcher.dart';

class AppLauncherService {
  final Map<String, String> knownPackages = const {
    'whatsapp': 'com.whatsapp',
    'waze': 'com.waze',
    'maps': 'com.google.android.apps.maps',
    'google maps': 'com.google.android.apps.maps',
    'gmail': 'com.google.android.gm',
    'youtube': 'com.google.android.youtube',
    'instagram': 'com.instagram.android',
    'facebook': 'com.facebook.katana',
    'chrome': 'com.android.chrome',
    'spotify': 'com.spotify.music',
  };

  final Map<String, String> knownSchemes = const {
    'whatsapp': 'whatsapp://send',
    'waze': 'waze://',
    'maps': 'geo:0,0',
    'google maps': 'geo:0,0',
    'gmail': 'googlegmail://',
    'youtube': 'youtube://',
    'instagram': 'instagram://app',
    'facebook': 'fb://',
    'chrome': 'googlechrome://',
    'spotify': 'spotify://',
  };

  Future<bool> openKnownApp(String name) async {
    final key = name.toLowerCase().trim();
    final pkg = knownPackages[key];
    final scheme = knownSchemes[key];

    if (pkg == null && scheme == null) return false;

    try {
      if (scheme != null) {
        final openedByScheme = await _tryLaunch(Uri.parse(scheme));
        if (openedByScheme) return true;
      }

      if (Platform.isAndroid && pkg != null) {
        final intentUri = Uri.parse('intent://#Intent;package=$pkg;end');
        final openedByIntent = await _tryLaunch(intentUri);
        if (openedByIntent) return true;

        final marketUri = Uri.parse('market://details?id=$pkg');
        final openedMarket = await _tryLaunch(marketUri);
        if (openedMarket) return true;

        final playStoreUri = Uri.parse(
          'https://play.google.com/store/apps/details?id=$pkg',
        );
        return await _tryLaunch(playStoreUri);
      }

      return false;
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
}