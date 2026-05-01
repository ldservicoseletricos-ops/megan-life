import 'package:health/health.dart';
import 'package:permission_handler/permission_handler.dart';

class MeganHealthService {
  final Health _health = Health();

  Future<Map<String, dynamic>> readAvailableHealthData() async {
    final now = DateTime.now();
    final start = now.subtract(const Duration(days: 7));

    final types = <HealthDataType>[
      HealthDataType.STEPS,
      HealthDataType.HEART_RATE,
      HealthDataType.ACTIVE_ENERGY_BURNED,
      HealthDataType.DISTANCE_DELTA,
      HealthDataType.SLEEP_ASLEEP,
      HealthDataType.WORKOUT,
    ];

    final permissions = types.map((_) => HealthDataAccess.READ).toList();

    await Permission.activityRecognition.request();
    await Permission.locationWhenInUse.request();

    final authorized = await _health.requestAuthorization(types, permissions: permissions);
    if (!authorized) {
      return {
        'authorized': false,
        'message': 'Permissão de saúde não autorizada. Abra o Health Connect/Google Fit e permita acesso para a Megan Life.'
      };
    }

    final data = await _health.getHealthDataFromTypes(types: types, startTime: start, endTime: now);
    final clean = data.map((item) => {
      'type': item.typeString,
      'value': item.value.toString(),
      'unit': item.unitString,
      'dateFrom': item.dateFrom.toIso8601String(),
      'dateTo': item.dateTo.toIso8601String(),
      'source': item.sourceName,
    }).toList();

    return {
      'authorized': true,
      'from': start.toIso8601String(),
      'to': now.toIso8601String(),
      'count': clean.length,
      'items': clean.take(200).toList(),
    };
  }
}
