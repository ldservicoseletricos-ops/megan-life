import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class NavigationService {
  Future<void> openNavigationChoice(
    BuildContext context,
    String destination,
  ) async {
    final cleanDestination = destination.trim();

    if (cleanDestination.isEmpty) return;

    if (!context.mounted) return;

    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF10131F),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Escolha o app de navegação',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  cleanDestination,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.white.withOpacity(.75),
                  ),
                ),
                const SizedBox(height: 18),
                ListTile(
                  leading: const Icon(Icons.navigation),
                  title: const Text('Abrir no Waze'),
                  onTap: () async {
                    Navigator.pop(context);
                    await openWaze(cleanDestination);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.map),
                  title: const Text('Abrir no Google Maps'),
                  onTap: () async {
                    Navigator.pop(context);
                    await openGoogleMaps(cleanDestination);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<bool> openWaze(String destination) async {
    final encoded = Uri.encodeComponent(destination);

    final appUri = Uri.parse('waze://?q=$encoded&navigate=yes');
    final webUri = Uri.parse('https://waze.com/ul?q=$encoded&navigate=yes');

    if (Platform.isAndroid || Platform.isIOS) {
      final openedApp = await _tryLaunch(appUri);
      if (openedApp) return true;
    }

    return _tryLaunch(webUri);
  }

  Future<bool> openGoogleMaps(String destination) async {
    final encoded = Uri.encodeComponent(destination);

    final uri = Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=$encoded',
    );

    return _tryLaunch(uri);
  }

  Future<bool> _tryLaunch(Uri uri) async {
    try {
      return await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      return false;
    }
  }
}