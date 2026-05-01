import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class NavigationService {
  Future<void> openNavigationChoice(BuildContext context, String destination) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(title: Text('Navegar para: $destination')),
        ListTile(leading: const Icon(Icons.map), title: const Text('Google Maps'), onTap: () => Navigator.pop(context, 'maps')),
        ListTile(leading: const Icon(Icons.directions_car), title: const Text('Waze'), onTap: () => Navigator.pop(context, 'waze')),
      ])),
    );
    if (choice == null) return;
    final e = Uri.encodeComponent(destination);
    final uri = choice == 'waze'
      ? Uri.parse('https://waze.com/ul?q=$e&navigate=yes')
      : Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$e&travelmode=driving');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
