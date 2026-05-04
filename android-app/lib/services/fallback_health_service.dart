class FallbackHealthService {
  Future<Map<String, dynamic>> getSteps() async {
    try {
      return {
        'authorized': false,
        'source': 'fallback_safe',
        'summary': {
          'steps': 0,
          'heartRate': 0,
          'sleepHours': '0.0',
          'calories': 0,
          'distance': 0,
          'spo2': 0,
          'temperature': 0,
          'glucose': 0,
          'weight': 0,
          'bodyFat': 0,
        },
        'alerts': [],
        'guidance': [
          'Conecte o Health Connect e permita acesso aos dados do relógio para análises reais.',
        ],
        'disclaimer': 'Orientação geral. Não substitui avaliação médica.',
        'message': 'Fallback ativo. Conecte Health Connect para dados reais.',
      };
    } catch (e) {
      return {
        'authorized': false,
        'source': 'fallback_safe',
        'error': e.toString(),
      };
    }
  }
}