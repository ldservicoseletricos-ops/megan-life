import 'package:health/health.dart';
import 'package:permission_handler/permission_handler.dart';

class MeganHealthService {
  final Health _health = Health();

  Future<Map<String, dynamic>> readAvailableHealthData() async {
    try {
      final now = DateTime.now();
      final start = now.subtract(const Duration(days: 7));

      final types = <HealthDataType>[
        HealthDataType.STEPS,
        HealthDataType.HEART_RATE,
        HealthDataType.ACTIVE_ENERGY_BURNED,
        HealthDataType.DISTANCE_DELTA,
        HealthDataType.SLEEP_ASLEEP,
        HealthDataType.BODY_TEMPERATURE,
        HealthDataType.BLOOD_OXYGEN,
        HealthDataType.BLOOD_PRESSURE_SYSTOLIC,
        HealthDataType.BLOOD_PRESSURE_DIASTOLIC,
        HealthDataType.BLOOD_GLUCOSE,
        HealthDataType.BODY_FAT_PERCENTAGE,
        HealthDataType.WEIGHT,
        HealthDataType.HEIGHT,
        HealthDataType.WORKOUT,
      ];

      final permissions = types.map((_) => HealthDataAccess.READ).toList();

      await Permission.activityRecognition.request();
      await Permission.locationWhenInUse.request();

      bool authorized = false;

      try {
        authorized = await _health.requestAuthorization(
          types,
          permissions: permissions,
        );
      } catch (_) {
        authorized = false;
      }

      final hasPermissions = await _health.hasPermissions(types);

      if (hasPermissions == true) {
        authorized = true;
      }

      if (!authorized) {
        return {
          'authorized': false,
          'message': 'Permissões não autorizadas no Health Connect',
        };
      }

      final data = await _health.getHealthDataFromTypes(
        types: types,
        startTime: start,
        endTime: now,
      );

      if (data.isEmpty) {
        return {
          'authorized': true,
          'message': 'Nenhum dado encontrado. Aguardando sincronização.',
        };
      }

      double steps = 0;
      double heart = 0;
      int heartCount = 0;
      double sleep = 0;
      double calories = 0;
      double distance = 0;
      double spo2 = 0;
      double temp = 0;
      double glucose = 0;
      double weight = 0;
      double bodyFat = 0;

      for (final item in data) {
        final value = double.tryParse(item.value.toString()) ?? 0;

        switch (item.type) {
          case HealthDataType.STEPS:
            steps += value;
            break;
          case HealthDataType.HEART_RATE:
            heart += value;
            heartCount++;
            break;
          case HealthDataType.SLEEP_ASLEEP:
            sleep += value / 60;
            break;
          case HealthDataType.ACTIVE_ENERGY_BURNED:
            calories += value;
            break;
          case HealthDataType.DISTANCE_DELTA:
            distance += value;
            break;
          case HealthDataType.BLOOD_OXYGEN:
            spo2 = value;
            break;
          case HealthDataType.BODY_TEMPERATURE:
            temp = value;
            break;
          case HealthDataType.BLOOD_GLUCOSE:
            glucose = value;
            break;
          case HealthDataType.WEIGHT:
            weight = value;
            break;
          case HealthDataType.BODY_FAT_PERCENTAGE:
            bodyFat = value;
            break;
          default:
            break;
        }
      }

      if (heartCount > 0) {
        heart = heart / heartCount;
      }

      final alerts = <String>[];

      if (steps < 3000) alerts.add('Baixa atividade');
      if (heart > 100) alerts.add('Frequência cardíaca elevada');
      if (sleep < 5) alerts.add('Sono insuficiente');
      if (spo2 > 0 && spo2 < 92) alerts.add('Oxigenação baixa');
      if (temp > 37.5) alerts.add('Temperatura elevada');

      return {
        'authorized': true,
        'source': 'health_connect',
        'summary': {
          'steps': steps.round(),
          'heartRate': heart.round(),
          'sleepHours': sleep.toStringAsFixed(1),
          'calories': calories.round(),
          'distance': distance.round(),
          'spo2': spo2,
          'temperature': temp,
          'glucose': glucose,
          'weight': weight,
          'bodyFat': bodyFat,
        },
        'alerts': alerts,
        'period': {
          'from': start.toIso8601String(),
          'to': now.toIso8601String(),
        },
      };
    } catch (e) {
      return {
        'authorized': false,
        'source': 'health_connect',
        'error': e.toString(),
      };
    }
  }
}