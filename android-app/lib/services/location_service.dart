import 'package:geolocator/geolocator.dart';

class MeganPosition {
  final double latitude;
  final double longitude;
  final double? accuracy;

  const MeganPosition({
    required this.latitude,
    required this.longitude,
    this.accuracy,
  });
}

class LocationResult {
  final bool ok;
  final MeganPosition? position;
  final String message;

  const LocationResult({
    required this.ok,
    this.position,
    this.message = '',
  });
}

class LocationService {
  Future<LocationResult> getCurrentLocation() async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();

      if (!enabled) {
        return const LocationResult(
          ok: false,
          message: 'Luiz, o GPS do celular está desligado. A permissão pode estar liberada, mas preciso que a localização do aparelho esteja ativada para identificar onde você está.',
        );
      }

      var permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied) {
        return const LocationResult(
          ok: false,
          message: 'Luiz, a permissão de localização da Megan Life ainda não foi liberada. Ative em Configurações > Apps > Megan Life > Permissões > Localização > Permitir durante o uso.',
        );
      }

      if (permission == LocationPermission.deniedForever) {
        return const LocationResult(
          ok: false,
          message: 'Luiz, a permissão de localização da Megan Life está bloqueada nas configurações do Android. Abra as configurações do app e escolha Permitir durante o uso.',
        );
      }

      Position? position;

      try {
        position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.high,
          timeLimit: const Duration(seconds: 12),
        );
      } catch (_) {
        position = await Geolocator.getLastKnownPosition();
      }

      position ??= await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.medium,
        timeLimit: const Duration(seconds: 15),
      );

      return LocationResult(
        ok: true,
        position: MeganPosition(
          latitude: position.latitude,
          longitude: position.longitude,
          accuracy: position.accuracy,
        ),
      );
    } catch (e) {
      return LocationResult(
        ok: false,
        message: 'Luiz, não consegui acessar a localização agora. Confira se o GPS está ligado e se a Megan Life tem permissão de localização durante o uso. Detalhe técnico: $e',
      );
    }
  }
}
