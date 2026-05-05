import 'dart:convert';
import 'package:http/http.dart' as http;

class WeatherResult {
  final bool ok;
  final String message;
  final double? temperatureC;
  final double? apparentTemperatureC;
  final double? humidityPercent;
  final double? precipitationMm;
  final double? windSpeedKmh;
  final int? weatherCode;
  final String description;

  // ✅ NOVO
  final String? city;

  const WeatherResult({
    required this.ok,
    this.message = '',
    this.temperatureC,
    this.apparentTemperatureC,
    this.humidityPercent,
    this.precipitationMm,
    this.windSpeedKmh,
    this.weatherCode,
    this.description = '',
    this.city,
  });
}

class WeatherService {
  Future<WeatherResult> getCurrentWeather({
    required double latitude,
    required double longitude,
  }) async {
    try {
      final uri = Uri.https('api.open-meteo.com', '/v1/forecast', {
        'latitude': latitude.toString(),
        'longitude': longitude.toString(),
        'current': 'temperature_2m,relative_humidity_2m,apparent_temperature,precipitation,weather_code,wind_speed_10m',
        'timezone': 'auto',
        'forecast_days': '1',
      });

      final response = await http.get(uri).timeout(const Duration(seconds: 12));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return WeatherResult(
          ok: false,
          message: 'Luiz, o serviço de clima respondeu com erro ${response.statusCode}.',
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        return const WeatherResult(
          ok: false,
          message: 'Luiz, o serviço de clima retornou uma resposta inválida.',
        );
      }

      final currentRaw = decoded['current'];
      if (currentRaw is! Map) {
        return const WeatherResult(
          ok: false,
          message: 'Luiz, não encontrei dados atuais de clima para sua localização.',
        );
      }

      final current = Map<String, dynamic>.from(currentRaw);
      final code = _toInt(current['weather_code']);

      // ✅ NOVO: buscar cidade
      final city = await _getCityName(latitude, longitude);

      return WeatherResult(
        ok: true,
        temperatureC: _toDouble(current['temperature_2m']),
        apparentTemperatureC: _toDouble(current['apparent_temperature']),
        humidityPercent: _toDouble(current['relative_humidity_2m']),
        precipitationMm: _toDouble(current['precipitation']),
        windSpeedKmh: _toDouble(current['wind_speed_10m']),
        weatherCode: code,
        description: code == null ? 'clima atual disponível' : describeWeatherCode(code),
        city: city, // ✅ NOVO
      );
    } catch (e) {
      return WeatherResult(
        ok: false,
        message: 'Luiz, não consegui consultar o clima agora: $e',
      );
    }
  }

  // ✅ NOVO
  Future<String> _getCityName(double lat, double lon) async {
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?lat=$lat&lon=$lon&format=json',
      );

      final res = await http.get(uri, headers: {
        'User-Agent': 'megan-life-app'
      }).timeout(const Duration(seconds: 10));

      if (res.statusCode != 200) return 'sua região';

      final data = jsonDecode(res.body);
      final address = data['address'];

      return address['city'] ??
          address['town'] ??
          address['village'] ??
          address['state'] ??
          'sua região';
    } catch (_) {
      return 'sua região';
    }
  }

  static double? _toDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString().replaceAll(',', '.'));
  }

  static int? _toInt(dynamic value) {
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value.toString());
  }

  static bool isRainCode(int code) {
    return code == 51 ||
        code == 53 ||
        code == 55 ||
        code == 56 ||
        code == 57 ||
        code == 61 ||
        code == 63 ||
        code == 65 ||
        code == 66 ||
        code == 67 ||
        code == 80 ||
        code == 81 ||
        code == 82 ||
        code == 95 ||
        code == 96 ||
        code == 99;
  }

  static String describeWeatherCode(int code) {
    switch (code) {
      case 0:
        return 'céu limpo';
      case 1:
        return 'principalmente limpo';
      case 2:
        return 'parcialmente nublado';
      case 3:
        return 'nublado';
      case 45:
      case 48:
        return 'neblina';
      case 51:
      case 53:
      case 55:
        return 'garoa';
      case 56:
      case 57:
        return 'garoa congelante';
      case 61:
      case 63:
      case 65:
        return 'chuva';
      case 66:
      case 67:
        return 'chuva congelante';
      case 71:
      case 73:
      case 75:
        return 'neve';
      case 77:
        return 'grãos de neve';
      case 80:
      case 81:
      case 82:
        return 'pancadas de chuva';
      case 85:
      case 86:
        return 'pancadas de neve';
      case 95:
        return 'trovoada';
      case 96:
      case 99:
        return 'trovoada com granizo';
      default:
        return 'condição climática atual';
    }
  }
}