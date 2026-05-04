import 'package:health/health.dart';
import 'package:permission_handler/permission_handler.dart';

class MeganHealthService {
  final Health _health = Health();

  Future<Map<String, dynamic>> readAvailableHealthData() async {
    try {
      final now = DateTime.now();

      // 6.8 — Diagnóstico Inteligente REAL:
      // Mantém a leitura que já funcionou e adiciona uma camada de interpretação
      // mais útil: risco geral, diagnóstico por categoria, relatório premium e
      // recomendações seguras. Não substitui avaliação médica.
      final todayStart = DateTime(now.year, now.month, now.day);
      final sevenDaysStart = now.subtract(const Duration(days: 7));

      final essentialTypes = <HealthDataType>[
        HealthDataType.STEPS,
        HealthDataType.HEART_RATE,
        HealthDataType.ACTIVE_ENERGY_BURNED,
        HealthDataType.DISTANCE_DELTA,
        HealthDataType.SLEEP_ASLEEP,
      ];

      final advancedTypes = <HealthDataType>[
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

      final allTypes = <HealthDataType>[
        ...essentialTypes,
        ...advancedTypes,
      ];

      await Permission.activityRecognition.request();

      bool authorized = false;

      try {
        authorized = await _health.requestAuthorization(
          allTypes,
          permissions: allTypes.map((_) => HealthDataAccess.READ).toList(),
        );
      } catch (_) {
        try {
          authorized = await _health.requestAuthorization(
            essentialTypes,
            permissions: essentialTypes.map((_) => HealthDataAccess.READ).toList(),
          );
        } catch (_) {
          authorized = false;
        }
      }

      try {
        final hasEssentialPermissions = await _health.hasPermissions(essentialTypes);
        if (hasEssentialPermissions == true) {
          authorized = true;
        }
      } catch (_) {}

      if (!authorized) {
        return {
          'authorized': false,
          'source': 'health_connect',
          'message': 'Permissões não autorizadas no Health Connect',
        };
      }

      var essentialDataToday = await _safeReadHealthData(
        types: essentialTypes,
        startTime: todayStart,
        endTime: now,
      );

      if (essentialDataToday.isEmpty) {
        essentialDataToday = await _safeReadHealthData(
          types: essentialTypes,
          startTime: sevenDaysStart,
          endTime: now,
        );
      }

      final advancedData = await _safeReadHealthData(
        types: advancedTypes,
        startTime: sevenDaysStart,
        endTime: now,
      );

      final mergedData = _removeDuplicates([
        ...essentialDataToday,
        ...advancedData,
      ]);

      double steps = 0;
      double heart = 0;
      int heartCount = 0;
      double sleep = 0;
      double calories = 0;
      double distance = 0;
      double spo2 = 0;
      double temp = 0;
      double systolic = 0;
      double diastolic = 0;
      double glucose = 0;
      double weight = 0;
      double height = 0;
      double bodyFat = 0;
      int workouts = 0;

      final available = <String>{};
      final unavailable = <String>{};

      for (final item in mergedData) {
        final value = _extractNumericValue(item.value);
        if (value <= 0) continue;

        switch (item.type) {
          case HealthDataType.STEPS:
            steps += value;
            available.add('passos');
            break;

          case HealthDataType.HEART_RATE:
            heart += value;
            heartCount++;
            available.add('frequência cardíaca');
            break;

          case HealthDataType.SLEEP_ASLEEP:
            sleep += value > 24 * 60 ? value / 3600 : value / 60;
            available.add('sono');
            break;

          case HealthDataType.ACTIVE_ENERGY_BURNED:
            calories += value;
            available.add('calorias ativas');
            break;

          case HealthDataType.DISTANCE_DELTA:
            distance += value;
            available.add('distância');
            break;

          case HealthDataType.BLOOD_OXYGEN:
            spo2 = value;
            available.add('saturação de oxigênio');
            break;

          case HealthDataType.BODY_TEMPERATURE:
            temp = value;
            available.add('temperatura corporal');
            break;

          case HealthDataType.BLOOD_PRESSURE_SYSTOLIC:
            systolic = value;
            available.add('pressão arterial');
            break;

          case HealthDataType.BLOOD_PRESSURE_DIASTOLIC:
            diastolic = value;
            available.add('pressão arterial');
            break;

          case HealthDataType.BLOOD_GLUCOSE:
            glucose = value;
            available.add('glicemia');
            break;

          case HealthDataType.WEIGHT:
            weight = value;
            available.add('peso');
            break;

          case HealthDataType.HEIGHT:
            height = value;
            available.add('altura');
            break;

          case HealthDataType.BODY_FAT_PERCENTAGE:
            bodyFat = value;
            available.add('gordura corporal');
            break;

          case HealthDataType.WORKOUT:
            workouts++;
            available.add('exercícios');
            break;

          default:
            break;
        }
      }

      if (heartCount > 0) {
        heart = heart / heartCount;
      }

      final hasRealData = steps > 0 ||
          heart > 0 ||
          sleep > 0 ||
          calories > 0 ||
          distance > 0 ||
          spo2 > 0 ||
          temp > 0 ||
          systolic > 0 ||
          diastolic > 0 ||
          glucose > 0 ||
          weight > 0 ||
          height > 0 ||
          bodyFat > 0 ||
          workouts > 0;

      final expectedMetrics = <String>[
        'passos',
        'distância',
        'calorias ativas',
        'exercícios',
        'frequência cardíaca',
        'sono',
        'peso',
        'altura',
        'gordura corporal',
        'saturação de oxigênio',
        'temperatura corporal',
        'pressão arterial',
        'glicemia',
      ];

      for (final metric in expectedMetrics) {
        if (!available.contains(metric)) {
          unavailable.add(metric);
        }
      }

      final summary = _buildSummary(
        steps: hasRealData ? steps : 0,
        heart: hasRealData ? heart : 0,
        sleep: hasRealData ? sleep : 0,
        calories: hasRealData ? calories : 0,
        distance: hasRealData ? distance : 0,
        spo2: hasRealData ? spo2 : 0,
        temp: hasRealData ? temp : 0,
        systolic: hasRealData ? systolic : 0,
        diastolic: hasRealData ? diastolic : 0,
        glucose: hasRealData ? glucose : 0,
        weight: hasRealData ? weight : 0,
        height: hasRealData ? height : 0,
        bodyFat: hasRealData ? bodyFat : 0,
        workouts: hasRealData ? workouts : 0,
      );

      final categories = _buildCategories(
        steps: hasRealData ? steps : 0,
        heart: hasRealData ? heart : 0,
        sleep: hasRealData ? sleep : 0,
        calories: hasRealData ? calories : 0,
        distance: hasRealData ? distance : 0,
        spo2: hasRealData ? spo2 : 0,
        temp: hasRealData ? temp : 0,
        systolic: hasRealData ? systolic : 0,
        diastolic: hasRealData ? diastolic : 0,
        glucose: hasRealData ? glucose : 0,
        weight: hasRealData ? weight : 0,
        height: hasRealData ? height : 0,
        bodyFat: hasRealData ? bodyFat : 0,
        workouts: hasRealData ? workouts : 0,
      );

      if (!hasRealData) {
        return {
          'authorized': true,
          'source': 'health_connect',
          'message': 'Nenhum dado real foi retornado pelo Health Connect ainda. Confira se Samsung Health, Google Fit ou relógio já sincronizaram.',
          'summary': summary,
          'categories': categories,
          'available': available.toList()..sort(),
          'unavailable': unavailable.toList()..sort(),
          'alerts': [],
          'guidance': [
            'O acesso está autorizado, mas o Health Connect não devolveu dados para a Megan neste momento.',
          ],
          'diagnosis': {
            'riskLevel': 'indefinido',
            'status': 'sem_dados',
            'headline': 'Ainda não há dados suficientes para análise real.',
            'activity': 'Sem dados de atividade retornados agora.',
            'vitals': 'Sem sinais vitais retornados agora.',
            'sleep': 'Sem dados de sono retornados agora.',
            'body': 'Sem dados corporais retornados agora.',
          },
          'report': [
            'O Health Connect autorizou o acesso, mas não retornou métricas utilizáveis neste momento.',
            'Confira se Samsung Health, Google Fit ou relógio já sincronizaram os dados.',
          ],
          'disclaimer': 'Orientação geral. Não substitui avaliação médica.',
          'period': {
            'from': sevenDaysStart.toIso8601String(),
            'to': now.toIso8601String(),
          },
        };
      }

      final alerts = <String>[];
      final guidance = <String>[];

      if (steps > 0 && steps < 3000) {
        alerts.add('Baixa atividade');
        guidance.add('Atividade baixa: uma caminhada leve pode ajudar, se você estiver bem.');
      }
      if (heart > 100) {
        alerts.add('Frequência cardíaca elevada');
        guidance.add('Frequência cardíaca elevada: observe se houve treino, estresse, cafeína ou sintomas.');
      }
      if (sleep > 0 && sleep < 5) {
        alerts.add('Sono insuficiente');
        guidance.add('Sono curto: priorize descanso e recuperação.');
      }
      if (spo2 > 0 && spo2 < 92) {
        alerts.add('Oxigenação baixa');
        guidance.add('Oxigenação baixa: se repetir ou houver falta de ar, procure atendimento médico.');
      }
      if (temp > 37.5) {
        alerts.add('Temperatura elevada');
        guidance.add('Temperatura elevada: se houver sintomas ou persistência, fale com um profissional de saúde.');
      }
      if (systolic > 0 && systolic >= 140) {
        alerts.add('Pressão sistólica elevada');
        guidance.add('Pressão sistólica elevada: confirme a medição e procure orientação profissional se persistir.');
      }
      if (diastolic > 0 && diastolic >= 90) {
        alerts.add('Pressão diastólica elevada');
        guidance.add('Pressão diastólica elevada: confirme a medição e procure orientação profissional se persistir.');
      }

      final diagnosis = _buildDiagnosis(
        steps: steps,
        heart: heart,
        sleep: sleep,
        calories: calories,
        distance: distance,
        spo2: spo2,
        temp: temp,
        systolic: systolic,
        diastolic: diastolic,
        glucose: glucose,
        weight: weight,
        height: height,
        bodyFat: bodyFat,
        workouts: workouts,
        available: available,
        unavailable: unavailable,
        alerts: alerts,
      );

      final report = _buildReport(
        steps: steps,
        heart: heart,
        sleep: sleep,
        calories: calories,
        distance: distance,
        spo2: spo2,
        temp: temp,
        systolic: systolic,
        diastolic: diastolic,
        glucose: glucose,
        weight: weight,
        height: height,
        bodyFat: bodyFat,
        workouts: workouts,
        available: available,
        unavailable: unavailable,
        diagnosis: diagnosis,
      );

      final extraGuidance = diagnosis['guidance'];
      if (extraGuidance is List) {
        for (final item in extraGuidance) {
          final text = item.toString().trim();
          if (text.isNotEmpty && !guidance.contains(text)) {
            guidance.add(text);
          }
        }
      }

      if (guidance.isEmpty) {
        guidance.add('Nenhum alerta forte foi detectado nos dados disponíveis. Continue acompanhando tendências.');
      }

      return {
        'authorized': true,
        'source': 'health_connect',
        'summary': summary,
        'categories': categories,
        'available': available.toList()..sort(),
        'unavailable': unavailable.toList()..sort(),
        'alerts': alerts,
        'guidance': guidance,
        'diagnosis': diagnosis,
        'report': report,
        'riskLevel': diagnosis['riskLevel'],
        'disclaimer': 'Orientação geral. Não substitui avaliação médica.',
        'period': {
          'from': sevenDaysStart.toIso8601String(),
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

  Map<String, dynamic> _buildSummary({
    required double steps,
    required double heart,
    required double sleep,
    required double calories,
    required double distance,
    required double spo2,
    required double temp,
    required double systolic,
    required double diastolic,
    required double glucose,
    required double weight,
    required double height,
    required double bodyFat,
    required int workouts,
  }) {
    return {
      'steps': steps.round(),
      'heartRate': heart.round(),
      'sleepHours': sleep.toStringAsFixed(1),
      'calories': calories.round(),
      'distance': distance.round(),
      'distanceKm': (distance / 1000).toStringAsFixed(2),
      'spo2': spo2,
      'temperature': temp,
      'bloodPressureSystolic': systolic.round(),
      'bloodPressureDiastolic': diastolic.round(),
      'glucose': glucose,
      'weight': weight,
      'height': height,
      'bodyFat': bodyFat,
      'workouts': workouts,
    };
  }

  Map<String, dynamic> _buildCategories({
    required double steps,
    required double heart,
    required double sleep,
    required double calories,
    required double distance,
    required double spo2,
    required double temp,
    required double systolic,
    required double diastolic,
    required double glucose,
    required double weight,
    required double height,
    required double bodyFat,
    required int workouts,
  }) {
    return {
      'activity': {
        'steps': steps.round(),
        'activeCalories': calories.round(),
        'distanceMeters': distance.round(),
        'distanceKm': (distance / 1000).toStringAsFixed(2),
        'workouts': workouts,
        'power': 0,
        'speed': 0,
      },
      'body': {
        'weight': weight,
        'height': height,
        'bodyFat': bodyFat,
        'basalMetabolicRate': 0,
      },
      'nutrition': {
        'hydration': 0,
        'nutrition': 0,
      },
      'vitals': {
        'heartRate': heart.round(),
        'bloodGlucose': glucose,
        'bloodPressureSystolic': systolic.round(),
        'bloodPressureDiastolic': diastolic.round(),
        'respiratoryRate': 0,
        'spo2': spo2,
        'temperature': temp,
      },
      'sleep': {
        'sleepHours': sleep.toStringAsFixed(1),
      },
    };
  }

  Map<String, dynamic> _buildDiagnosis({
    required double steps,
    required double heart,
    required double sleep,
    required double calories,
    required double distance,
    required double spo2,
    required double temp,
    required double systolic,
    required double diastolic,
    required double glucose,
    required double weight,
    required double height,
    required double bodyFat,
    required int workouts,
    required Set<String> available,
    required Set<String> unavailable,
    required List<String> alerts,
  }) {
    var score = 0;
    final guidance = <String>[];

    if (steps > 0 && steps < 3000) score += 1;
    if (sleep > 0 && sleep < 5) score += 1;
    if (heart > 100) score += 1;
    if (spo2 > 0 && spo2 < 92) score += 2;
    if (temp > 37.5) score += 1;
    if (systolic >= 140 || diastolic >= 90) score += 1;

    String riskLevel;
    String status;
    String headline;

    if (score >= 3) {
      riskLevel = 'alerta';
      status = 'atenção_alta';
      headline = 'Há pontos que merecem atenção nos dados disponíveis.';
    } else if (score >= 1) {
      riskLevel = 'atenção';
      status = 'atenção_moderada';
      headline = 'Há alguns sinais para acompanhar hoje.';
    } else {
      riskLevel = 'normal';
      status = 'estável';
      headline = 'Os dados disponíveis não mostram alerta forte agora.';
    }

    String activity;
    if (steps <= 0 && calories <= 0 && distance <= 0 && workouts <= 0) {
      activity = 'Sem dados de atividade retornados agora.';
      guidance.add('Para análise de atividade, mantenha Samsung Health, Google Fit ou relógio sincronizados.');
    } else if (steps < 3000 && steps > 0) {
      activity = 'Atividade baixa para o período analisado.';
      guidance.add('Uma caminhada leve pode ajudar a subir o nível de atividade, se você estiver se sentindo bem.');
    } else if (steps >= 8000) {
      activity = 'Atividade muito boa no período analisado.';
      guidance.add('Mantenha hidratação, alimentação e recuperação para sustentar esse nível.');
    } else {
      activity = 'Atividade registrada em nível intermediário.';
      guidance.add('Acompanhar a tendência dos próximos dias vai mostrar melhor seu padrão.');
    }

    String vitals;
    if (heart <= 0 && spo2 <= 0 && temp <= 0 && systolic <= 0 && diastolic <= 0 && glucose <= 0) {
      vitals = 'Sem sinais vitais retornados agora.';
      guidance.add('Alguns dados como pressão, glicemia, temperatura e oxigenação dependem de aparelho ou registro específico.');
    } else if (heart > 100 || (spo2 > 0 && spo2 < 92) || temp > 37.5 || systolic >= 140 || diastolic >= 90) {
      vitals = 'Há sinais vitais que merecem observação.';
      guidance.add('Se algum valor fora do comum persistir ou vier com sintomas, procure orientação médica.');
    } else {
      vitals = 'Sinais vitais disponíveis sem alerta forte agora.';
    }

    String sleepText;
    if (sleep <= 0) {
      sleepText = 'Sem sono retornado agora.';
      guidance.add('Para avaliar recuperação, o ideal é sincronizar sono do relógio com Health Connect.');
    } else if (sleep < 5) {
      sleepText = 'Sono curto no período analisado.';
      guidance.add('Priorize recuperação e descanso; sono curto pode impactar energia, foco e treino.');
    } else if (sleep >= 7) {
      sleepText = 'Sono em faixa boa para recuperação.';
    } else {
      sleepText = 'Sono registrado em faixa intermediária.';
    }

    String body;
    if (weight <= 0 && height <= 0 && bodyFat <= 0) {
      body = 'Sem dados corporais retornados agora.';
    } else {
      body = 'Dados corporais disponíveis para acompanhamento de tendência.';
    }

    return {
      'riskLevel': riskLevel,
      'status': status,
      'headline': headline,
      'activity': activity,
      'vitals': vitals,
      'sleep': sleepText,
      'body': body,
      'alertsCount': alerts.length,
      'availableCount': available.length,
      'unavailableCount': unavailable.length,
      'guidance': guidance,
    };
  }

  List<String> _buildReport({
    required double steps,
    required double heart,
    required double sleep,
    required double calories,
    required double distance,
    required double spo2,
    required double temp,
    required double systolic,
    required double diastolic,
    required double glucose,
    required double weight,
    required double height,
    required double bodyFat,
    required int workouts,
    required Set<String> available,
    required Set<String> unavailable,
    required Map<String, dynamic> diagnosis,
  }) {
    final report = <String>[];

    report.add('Nível geral: ${diagnosis['riskLevel']}. ${diagnosis['headline']}');
    report.add('Atividade: ${diagnosis['activity']}');
    report.add('Sinais vitais: ${diagnosis['vitals']}');
    report.add('Sono: ${diagnosis['sleep']}');
    report.add('Corpo: ${diagnosis['body']}');

    final highlights = <String>[];
    if (steps > 0) highlights.add('${steps.round()} passos');
    if (distance > 0) highlights.add('${(distance / 1000).toStringAsFixed(2)} km');
    if (calories > 0) highlights.add('${calories.round()} calorias ativas');
    if (heart > 0) highlights.add('${heart.round()} bpm médio');
    if (sleep > 0) highlights.add('${sleep.toStringAsFixed(1)} h de sono');
    if (weight > 0) highlights.add('${weight.toStringAsFixed(1)} kg');
    if (spo2 > 0) highlights.add('${spo2.toStringAsFixed(0)}% SpO2');
    if (temp > 0) highlights.add('${temp.toStringAsFixed(1)}°C');
    if (systolic > 0 || diastolic > 0) {
      highlights.add('${systolic > 0 ? systolic.round().toString() : '--'}/${diastolic > 0 ? diastolic.round().toString() : '--'} mmHg');
    }
    if (glucose > 0) highlights.add('glicemia ${glucose.toStringAsFixed(0)}');

    if (highlights.isNotEmpty) {
      report.add('Destaques disponíveis: ${highlights.join(', ')}.');
    }

    if (unavailable.isNotEmpty) {
      report.add('Dados liberados, mas ainda não retornados: ${unavailable.join(', ')}.');
    }

    report.add('Use esse relatório como orientação geral e acompanhe a tendência, não apenas um valor isolado.');

    return report;
  }

  Future<List<HealthDataPoint>> _safeReadHealthData({
    required List<HealthDataType> types,
    required DateTime startTime,
    required DateTime endTime,
  }) async {
    final result = <HealthDataPoint>[];

    for (final type in types) {
      try {
        final data = await _health.getHealthDataFromTypes(
          types: [type],
          startTime: startTime,
          endTime: endTime,
        );

        result.addAll(data);
      } catch (_) {
        // Mantém leitura dos demais tipos mesmo se um tipo não estiver disponível.
      }
    }

    return result;
  }

  List<HealthDataPoint> _removeDuplicates(List<HealthDataPoint> data) {
    final seen = <String>{};
    final result = <HealthDataPoint>[];

    for (final item in data) {
      final key = '${item.type}_${item.dateFrom.toIso8601String()}_${item.dateTo.toIso8601String()}_${item.value}';
      if (seen.add(key)) {
        result.add(item);
      }
    }

    return result;
  }

  double _extractNumericValue(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();

    try {
      final dynamic dynamicValue = value;
      final numericValue = dynamicValue.numericValue;
      if (numericValue is num) return numericValue.toDouble();
    } catch (_) {}

    try {
      final dynamic dynamicValue = value;
      final valueValue = dynamicValue.value;
      if (valueValue is num) return valueValue.toDouble();
    } catch (_) {}

    final text = value.toString().replaceAll(',', '.');
    final match = RegExp(r'-?\d+(?:\.\d+)?').firstMatch(text);
    if (match == null) return 0;

    return double.tryParse(match.group(0) ?? '') ?? 0;
  }
}



