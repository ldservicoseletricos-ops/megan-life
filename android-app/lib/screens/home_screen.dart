import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../services/accessibility_service.dart';
import '../services/ai_service.dart';
import '../services/app_launcher_service.dart';
import '../services/file_service.dart';
import '../services/navigation_service.dart';
import '../services/health_service.dart' as health;
import '../services/fallback_health_service.dart' as fallback;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _controller = TextEditingController();
  final _ai = AiService();
  final _files = FileService();
  final _apps = AppLauncherService();
  final _nav = NavigationService();
  final _health = health.MeganHealthService();
  final _fallbackHealth = fallback.FallbackHealthService();
  final _speech = SpeechToText();
  final _tts = FlutterTts();
  final _random = Random();
  final _audioPlayer = AudioPlayer();

  Timer? _restartTimer;
  Timer? _commandWindowTimer;
  Timer? _commandDebounceTimer;
  Timer? _ttsResumeTimer;
  Timer? _conversationIdleTimer;

  final List<_Message> _messages = [
    _Message(false, 'Oi Luiz, sou a Megan Life 4.8.6 Assistente Real. Diga: ok Megan.'),
  ];

  bool _loading = false;
  bool _listening = false;
  bool _voiceReply = true;
  bool _speechReady = false;
  bool _processingVoiceCommand = false;
  bool _startingListen = false;
  bool _manualStop = false;
  bool _commandMode = false;
  bool _wakeMessageShown = false;
  bool _ttsSpeaking = false;

  String _lastVoiceText = '';
  DateTime? _lastVoiceAt;
  String _pendingCommand = '';
  String _voiceStatus = 'Inicializando voz...';

  final List<String> _wakeReplies = const [
    'Estou ouvindo, Luiz. Como posso ajudar?',
    'Oi Luiz, pode falar.',
    'Pronta. O que você precisa?',
    'Estou aqui. Qual é o comando?',
    'Pode falar, Luiz.',
    'Sim, Luiz. Como posso ajudar agora?',
    'Te ouvindo. O que vamos fazer?',
  ];

  @override
  void initState() {
    super.initState();
    _apps.loadApps();
    _boot();
  }

  @override
  void dispose() {
    _restartTimer?.cancel();
    _commandWindowTimer?.cancel();
    _commandDebounceTimer?.cancel();
    _ttsResumeTimer?.cancel();
    _conversationIdleTimer?.cancel();
    _controller.dispose();
    _speech.stop();
    _tts.stop();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    await _setupTts();

    final micStatus = await Permission.microphone.request();

    if (!micStatus.isGranted) {
      _setVoiceStatus('Microfone sem permissão.');
      _add(false, 'Permissão de microfone negada. Ative nas configurações.');
      return;
    }

    _speechReady = await _initializeSpeech();

    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    setState(() => _voiceReply = prefs.getBool('voiceReply') ?? true);

    if (_speechReady) {
      setState(() {
        _listening = true;
        _manualStop = false;
      });

      _setVoiceStatus('Microfone ativo. Diga: ok Megan.');
      _scheduleRestart(delayMs: 500);
    } else {
      _setVoiceStatus('Reconhecimento de voz indisponível.');
      _add(false, 'Não consegui iniciar o reconhecimento de voz.');
    }
  }

  Future<void> _setupTts() async {
    await _tts.setLanguage('pt-BR');
    await _tts.setSpeechRate(.50);
    await _tts.setPitch(1.02);
    await _tts.awaitSpeakCompletion(true);

    _tts.setStartHandler(() {
      _ttsSpeaking = true;
    });

    _tts.setCompletionHandler(() {
      _ttsSpeaking = false;
      _resumeListeningAfterTts();
    });

    _tts.setCancelHandler(() {
      _ttsSpeaking = false;
      _resumeListeningAfterTts();
    });

    _tts.setErrorHandler((_) {
      _ttsSpeaking = false;
      _resumeListeningAfterTts();
    });
  }

  Future<bool> _initializeSpeech() async {
    return _speech.initialize(
      onStatus: (status) {
        if (!mounted) return;

        if (!_processingVoiceCommand && !_ttsSpeaking) {
          _setVoiceStatus('Status da voz: $status');
        }

        if (_manualStop ||
            !_listening ||
            _processingVoiceCommand ||
            _startingListen ||
            _ttsSpeaking) {
          return;
        }

        if (status == 'done' || status == 'notListening') {
          _scheduleRestart(delayMs: _commandMode ? 350 : 700);
        }
      },
      onError: (error) {
        if (!mounted) return;

        final msg = error.errorMsg;

        if (msg != 'error_no_match' && msg != 'error_speech_timeout') {
          _setVoiceStatus('Erro de voz: $msg');
        }

        if (_manualStop || !_listening || _processingVoiceCommand || _ttsSpeaking) {
          return;
        }

        final delay = msg == 'error_busy'
            ? 1800
            : msg == 'error_no_match'
                ? 600
                : 900;

        _scheduleRestart(delayMs: delay);
      },
    );
  }

  void _setVoiceStatus(String value) {
    if (!mounted) return;
    setState(() => _voiceStatus = value);
  }

  void _scheduleRestart({int delayMs = 800}) {
    _restartTimer?.cancel();

    _restartTimer = Timer(Duration(milliseconds: delayMs), () async {
      if (!mounted ||
          _manualStop ||
          !_listening ||
          _processingVoiceCommand ||
          _startingListen ||
          _ttsSpeaking) {
        return;
      }

      await _startListening();
    });
  }

  void _resumeListeningAfterTts() {
    _ttsResumeTimer?.cancel();

    _ttsResumeTimer = Timer(const Duration(milliseconds: 450), () {
      if (!mounted || _manualStop || !_listening || _processingVoiceCommand) return;
      _scheduleRestart(delayMs: 250);
    });
  }

  Future<bool> _tryCloudTts(String fullText) async {
    try {
      final response = await http
          .post(
            Uri.parse('https://megan-life.onrender.com/api/tts'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'text': fullText}),
          )
          .timeout(const Duration(seconds: 12));

      if (response.statusCode != 200) return false;

      final data = jsonDecode(response.body);
      if (data is! Map || data['ok'] != true || data['audio'] == null) return false;

      final bytes = base64Decode(data['audio'].toString());

      await _audioPlayer.stop();
      await _audioPlayer.play(BytesSource(bytes));

      await _audioPlayer.onPlayerComplete.first.timeout(
        const Duration(seconds: 90),
        onTimeout: () {},
      );

      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _say(String text) async {
    if (!_voiceReply) return;

    final fullText = text.trim();
    if (fullText.isEmpty) return;

    try {
      _ttsSpeaking = true;

      if (_speech.isListening) {
        await _speech.stop();
        await Future.delayed(const Duration(milliseconds: 180));
      }

      await _tts.stop();
      await _audioPlayer.stop();

      final playedCloudVoice = await _tryCloudTts(fullText);

      if (!playedCloudVoice) {
        for (final part in _splitTextForTts(fullText)) {
          if (!_voiceReply || !mounted) break;
          await _tts.speak(part);
          await Future.delayed(const Duration(milliseconds: 250));
        }
      }
    } catch (_) {
      try {
        await _tts.speak(fullText);
      } catch (_) {}
    } finally {
      _ttsSpeaking = false;
      _resumeListeningAfterTts();
    }
  }

  List<String> _splitTextForTts(String text) {
    const maxLength = 350;
    final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();

    if (clean.length <= maxLength) return [clean];

    final sentences = clean.split(RegExp(r'(?<=[.!?])\s+'));
    final parts = <String>[];
    final buffer = StringBuffer();

    for (final sentence in sentences) {
      final item = sentence.trim();
      if (item.isEmpty) continue;

      if ((buffer.length + item.length + 1) > maxLength) {
        if (buffer.isNotEmpty) {
          parts.add(buffer.toString().trim());
          buffer.clear();
        }
      }

      if (item.length > maxLength) {
        for (var i = 0; i < item.length; i += maxLength) {
          final end = (i + maxLength < item.length) ? i + maxLength : item.length;
          parts.add(item.substring(i, end).trim());
        }
      } else {
        buffer.write('$item ');
      }
    }

    if (buffer.isNotEmpty) {
      parts.add(buffer.toString().trim());
    }

    return parts.where((p) => p.isNotEmpty).toList();
  }

  void _add(bool user, String text) {
    if (!mounted) return;
    setState(() => _messages.add(_Message(user, text)));
  }

  void _scheduleConversationIdleClose() {
    _conversationIdleTimer?.cancel();

    if (!_commandMode || !_listening || _manualStop) return;

    _conversationIdleTimer = Timer(const Duration(seconds: 20), () async {
      if (!mounted || _manualStop || !_listening || _processingVoiceCommand || _ttsSpeaking) return;

      _commandMode = false;
      _wakeMessageShown = false;
      _pendingCommand = '';
      _commandWindowTimer?.cancel();
      _commandDebounceTimer?.cancel();

      _setVoiceStatus('Conversa encerrada. Diga ok Megan quando precisar.');
      _add(false, 'Vou encerrar por enquanto. É só me chamar de novo.');
      await _say('Vou encerrar por enquanto. É só me chamar de novo.');
    });
  }

  void _resetConversationIdleClose() {
    _conversationIdleTimer?.cancel();

    if (_commandMode && !_manualStop && _listening) {
      _scheduleConversationIdleClose();
    }
  }

  Future<Map<String, dynamic>> _readHealthWithFallback() async {
    var data = await _health.readAvailableHealthData();

    final bool healthConnectFailed = data['authorized'] == false;
    final bool noData = data['authorized'] == true &&
        data['summary'] == null &&
        data['items'] == null &&
        data['count'] == null;

    if (healthConnectFailed || noData) {
      final fallbackData = await _fallbackHealth.getSteps();

      if (fallbackData['authorized'] == true) {
        fallbackData['healthConnectOriginal'] = data;
        return fallbackData;
      }
    }

    return data;
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _loading) return;

    _controller.clear();
    await _processAndExecute(text, fromVoice: false);
  }

  Future<bool> _runDirectSystemCommand(String text) async {
    final command = _normalize(text);

    if (command == 'voltar' ||
        command.contains('voltar') ||
        command.contains('botao voltar')) {
      await AccessibilityService.back();
      _add(false, 'Voltando.');
      return true;
    }

    if (command == 'home' ||
        command.contains('ir para home') ||
        command.contains('tela inicial') ||
        command.contains('inicio')) {
      await AccessibilityService.home();
      _add(false, 'Indo para a tela inicial.');
      return true;
    }

    if (command.contains('recentes') ||
        command.contains('abrir recentes') ||
        command.contains('apps recentes')) {
      await AccessibilityService.recent();
      _add(false, 'Abrindo apps recentes.');
      return true;
    }

    return false;
  }

  Future<void> _runSystemAction(String value) async {
    final command = _normalize(value);

    if (command.contains('voltar') || command == 'back') {
      await AccessibilityService.back();
      return;
    }

    if (command.contains('home') ||
        command.contains('inicio') ||
        command.contains('tela inicial')) {
      await AccessibilityService.home();
      return;
    }

    if (command.contains('recent')) {
      await AccessibilityService.recent();
      return;
    }
  }

  bool _isEndConversationCommand(String text) {
    final command = _normalize(text);

    return command.contains('pode parar') ||
        command.contains('encerrar') ||
        command.contains('encerrar conversa') ||
        command.contains('finalizar conversa') ||
        command.contains('nao preciso mais') ||
        command.contains('so isso') ||
        command == 'obrigado' ||
        command == 'obrigada' ||
        command == 'valeu';
  }

  Future<void> _processAndExecute(String text, {required bool fromVoice}) async {
    if (text.trim().isEmpty || _loading) return;

    final cleanText = text.trim();

    _conversationIdleTimer?.cancel();
    _add(true, cleanText);

    if (!mounted) return;
    setState(() => _loading = true);

    try {
      if (_isEndConversationCommand(cleanText)) {
        _commandMode = false;
        _wakeMessageShown = false;
        _pendingCommand = '';
        _commandWindowTimer?.cancel();
        _commandDebounceTimer?.cancel();
        _conversationIdleTimer?.cancel();

        final answer = 'Tudo bem, Luiz. Continuo ouvindo quando você chamar.';
        _add(false, answer);
        await _say(answer);
        return;
      }

      final handledBySystem = await _runDirectSystemCommand(cleanText);
      if (handledBySystem) return;

      final result = await _ai.process(cleanText);

      final List<dynamic> actions = result['actions'] is List
          ? List<dynamic>.from(result['actions'])
          : [];

      final String response = (result['response'] ?? '').toString();

      if (actions.isEmpty) {
        final answer = response.isNotEmpty ? response : await _ai.chat(cleanText);
        _add(false, answer);
        await _say(answer);
        return;
      }

      final queue = <Map<String, dynamic>>[];

      for (final rawAction in actions) {
        if (rawAction is Map) {
          queue.add(Map<String, dynamic>.from(rawAction));
        }
      }

      bool executedOnlyChat = true;

      for (final action in queue) {
        final type = (action['type'] ?? '').toString();
        final value = (action['value'] ?? '').toString().trim();

        if (type == 'chat') {
          final answer = await _ai.chat(cleanText);
          _add(false, answer);
          await _say(answer);
          continue;
        }

        executedOnlyChat = false;
        _setVoiceStatus('Executando: $type${value.isNotEmpty ? ' $value' : ''}');

        try {
          if (type == 'system') {
            await _runSystemAction(value);
            await Future.delayed(const Duration(milliseconds: 500));
          } else if (type == 'open_app') {
            if (value.isEmpty) continue;

            final opened = await _apps.openKnownApp(value);

            final answer = opened
                ? 'Abrindo $value.'
                : 'Não consegui abrir $value. Verifique se o app está instalado.';

            _add(false, answer);
            await _say(answer);

            await Future.delayed(const Duration(milliseconds: 900));
          } else if (type == 'navigate') {
            if (value.isEmpty) continue;

            await _nav.openNavigationChoice(context, value);

            final answer = 'Preparei a navegação para $value. Escolha Waze ou Google Maps.';
            _add(false, answer);
            await _say(answer);

            await Future.delayed(const Duration(milliseconds: 900));
          } else if (type == 'health') {
            final answer = await _ai.healthSummary(await _readHealthWithFallback());
            _add(false, answer);
            await _say(answer);

            await Future.delayed(const Duration(milliseconds: 900));
          } else if (type == 'athlete') {
            final answer = await _ai.athleteSummary(await _readHealthWithFallback());
            _add(false, answer);
            await _say(answer);

            await Future.delayed(const Duration(milliseconds: 900));
          } else if (type == 'feedback') {
            if (value.isEmpty) continue;

            final answer = await _ai.sendFeedback(value);
            _add(false, answer);
            await _say(answer);

            await Future.delayed(const Duration(milliseconds: 900));
          } else if (type == 'copilot_plan') {
            final answer = _ai.buildCopilotPlan(value.isEmpty ? cleanText : value);
            _add(false, answer);
            await _say('Modo copiloto ativado. Organizei um plano na tela.');

            await Future.delayed(const Duration(milliseconds: 900));
          }
        } catch (e) {
          final answer = 'Erro ao executar $type: $e';
          _add(false, answer);
          await _say(answer);
        }
      }

      if (executedOnlyChat && queue.isEmpty && response.isNotEmpty) {
        _add(false, response);
        await _say(response);
      }
    } catch (e) {
      final answer = 'Erro: $e';
      _add(false, answer);
      await _say(answer);
    } finally {
      if (!mounted) return;
      setState(() => _loading = false);

      if (fromVoice && !_manualStop && _listening) {
        _commandMode = true;
        _wakeMessageShown = false;
        _scheduleConversationIdleClose();
        _scheduleRestart(delayMs: 700);
      }
    }
  }

  Future<void> _pickAndAnalyzeFile() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    if (result == null || result.files.single.path == null) return;

    final file = File(result.files.single.path!);
    _add(true, 'Analisar arquivo: ${result.files.single.name}');

    if (!mounted) return;
    setState(() => _loading = true);

    try {
      final answer = await _files.analyzeFile(file);
      _add(false, answer);
      await _say('Arquivo analisado. Veja o relatório na tela.');
    } catch (e) {
      _add(false, 'Não consegui analisar o arquivo: $e');
    } finally {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _toggleListen() async {
    if (_listening) {
      _manualStop = true;
      _restartTimer?.cancel();
      _commandWindowTimer?.cancel();
      _commandDebounceTimer?.cancel();
      _ttsResumeTimer?.cancel();
      _conversationIdleTimer?.cancel();
      await _speech.stop();

      if (!mounted) return;
      setState(() {
        _listening = false;
        _commandMode = false;
        _startingListen = false;
      });

      _setVoiceStatus('Microfone pausado.');
      _add(false, 'Microfone pausado.');
      return;
    }

    final micStatus = await Permission.microphone.request();

    if (!micStatus.isGranted) {
      _setVoiceStatus('Microfone sem permissão.');
      _add(false, 'Permissão de microfone negada. Ative nas configurações.');
      return;
    }

    if (!_speechReady) {
      _speechReady = await _initializeSpeech();
    }

    if (!_speechReady) {
      _setVoiceStatus('Reconhecimento indisponível.');
      _add(false, 'Microfone não disponível. Verifique permissões.');
      return;
    }

    if (!mounted) return;

    setState(() {
      _listening = true;
      _manualStop = false;
      _commandMode = false;
      _wakeMessageShown = false;
    });

    _setVoiceStatus('Microfone ativo. Diga: ok Megan.');
    _scheduleRestart(delayMs: 400);
  }

  Future<void> _startListening() async {
    if (!_speechReady ||
        !_listening ||
        _manualStop ||
        _processingVoiceCommand ||
        _startingListen ||
        _ttsSpeaking) {
      return;
    }

    _startingListen = true;

    try {
      if (_speech.isListening) {
        await _speech.stop();
        await Future.delayed(const Duration(milliseconds: 350));
      }

      if (!mounted || !_listening || _manualStop || _ttsSpeaking) return;

      _setVoiceStatus(
        _commandMode ? 'Pode continuar falando...' : 'Ouvindo... diga ok Megan.',
      );

      await _speech.listen(
        localeId: 'pt_BR',
        listenMode: ListenMode.dictation,
        partialResults: true,
        listenFor: _commandMode
            ? const Duration(seconds: 45)
            : const Duration(seconds: 75),
        pauseFor: _commandMode
            ? const Duration(seconds: 8)
            : const Duration(seconds: 6),
        cancelOnError: false,
        onResult: _handleSpeechResult,
      );
    } catch (e) {
      _setVoiceStatus('Falha ao iniciar escuta: $e');

      if (mounted && !_manualStop) {
        _scheduleRestart(delayMs: 1400);
      }
    } finally {
      _startingListen = false;
    }
  }

  void _handleSpeechResult(dynamic result) {
    final words = (result.recognizedWords ?? '').toString().trim();
    if (words.isEmpty) return;

    final bool isFinal = result.finalResult == true;

    if (_processingVoiceCommand || _ttsSpeaking) return;

    _setVoiceStatus('Ouvi: $words');

    if (!_commandMode) {
      final wakeResult = _detectWakeWord(words);
      if (!wakeResult.detected) return;

      final commandAfterWake = wakeResult.command.trim();

      if (commandAfterWake.isNotEmpty && commandAfterWake.length >= 3) {
        _runCommandDebounced(commandAfterWake, fast: true);
        return;
      }

      _enterCommandMode();
      return;
    }

    _resetConversationIdleClose();

    final command = _extractWakeCommand(words).trim();
    if (command.isEmpty || command.length < 3) return;

    _runCommandDebounced(command, fast: isFinal);
  }

  Future<void> _enterCommandMode() async {
    _commandMode = true;
    _pendingCommand = '';

    _commandWindowTimer?.cancel();
    _commandDebounceTimer?.cancel();
    _conversationIdleTimer?.cancel();

    final reply = _wakeReplies[_random.nextInt(_wakeReplies.length)];

    _setVoiceStatus(reply);

    if (!_wakeMessageShown) {
      _wakeMessageShown = true;
      _add(false, reply);
      await _say(reply);
    }

    _scheduleConversationIdleClose();

    _commandWindowTimer = Timer(const Duration(seconds: 35), () {
      if (!mounted || _manualStop || !_listening || _processingVoiceCommand) return;

      _commandMode = false;
      _wakeMessageShown = false;
      _pendingCommand = '';
      _conversationIdleTimer?.cancel();
      _setVoiceStatus('Tempo do comando terminou. Diga ok Megan novamente.');
      _scheduleRestart(delayMs: 500);
    });
  }

  void _runCommandDebounced(String command, {bool fast = false}) {
    final cleanCommand = _extractWakeCommand(command).trim();
    if (cleanCommand.length < 3) return;

    _conversationIdleTimer?.cancel();
    _pendingCommand = cleanCommand;
    _controller.text = cleanCommand;
    _setVoiceStatus('Comando capturado: $cleanCommand');

    _commandDebounceTimer?.cancel();
    _commandDebounceTimer = Timer(
      Duration(milliseconds: fast ? 180 : 900),
      () async {
        if (!mounted || _processingVoiceCommand) return;

        final finalCommand = _pendingCommand.trim();
        if (finalCommand.isEmpty || finalCommand.length < 3) return;

        await _handleVoiceCommand(finalCommand);
      },
    );
  }

  Future<void> _handleVoiceCommand(String command) async {
    if (_processingVoiceCommand) return;

    final cleanCommand = _extractWakeCommand(command).trim();
    if (cleanCommand.isEmpty || cleanCommand.length < 3) return;

    final now = DateTime.now();
    if (cleanCommand == _lastVoiceText &&
        _lastVoiceAt != null &&
        now.difference(_lastVoiceAt!).inSeconds < 4) {
      return;
    }

    _lastVoiceText = cleanCommand;
    _lastVoiceAt = now;
    _processingVoiceCommand = true;

    try {
      _pendingCommand = '';
      _commandDebounceTimer?.cancel();
      _conversationIdleTimer?.cancel();

      if (_speech.isListening) {
        await _speech.stop();
        await Future.delayed(const Duration(milliseconds: 180));
      }

      _controller.clear();
      _setVoiceStatus('Executando comando: $cleanCommand');

      await _processAndExecute(cleanCommand, fromVoice: true);
    } finally {
      _processingVoiceCommand = false;
      if (!_manualStop && _listening) {
        _scheduleRestart(delayMs: 800);
      }
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
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  _WakeResult _detectWakeWord(String text) {
    final normalized = _normalize(text);
    if (normalized.isEmpty) return const _WakeResult(false, '');

    final words = normalized.split(' ').where((w) => w.trim().isNotEmpty).toList();
    if (words.isEmpty) return const _WakeResult(false, '');

    final wakePatterns = <List<String>>[
      ['ok', 'megan'],
      ['okay', 'megan'],
      ['okey', 'megan'],
      ['oi', 'megan'],
      ['ola', 'megan'],
      ['e', 'megan'],
    ];

    for (int i = 0; i < words.length; i++) {
      for (final pattern in wakePatterns) {
        if (i + pattern.length > words.length) continue;

        var score = 0;
        for (int j = 0; j < pattern.length; j++) {
          if (_wordClose(words[i + j], pattern[j])) score++;
        }

        if (score == pattern.length) {
          final command = words.skip(i + pattern.length).join(' ').trim();
          return _WakeResult(true, command);
        }
      }
    }

    if (words.length <= 3 && words.any((w) => _wordClose(w, 'megan'))) {
      return const _WakeResult(true, '');
    }

    return const _WakeResult(false, '');
  }

  bool _wordClose(String a, String b) {
    if (a == b) return true;
    if (a.length < 2 || b.length < 2) return false;

    final distance = _levenshtein(a, b);

    if (b == 'megan') {
      return distance <= 1 || a == 'mega' || a == 'meg' || a == 'meguem' || a == 'megam';
    }

    if (b == 'ok') {
      return a == 'ok' || a == 'okay' || a == 'okey' || a == 'oque' || a == 'oki';
    }

    if (b == 'oi') {
      return a == 'oi' || a == 'ola' || a == 'e';
    }

    return distance <= 1;
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

  String _extractWakeCommand(String text) {
    final normalized = _normalize(text);
    final wake = _detectWakeWord(normalized);

    if (wake.detected && wake.command.isNotEmpty) {
      return wake.command.trim();
    }

    var clean = normalized;

    final patterns = [
      r'\bok\s+megan\b',
      r'\bokay\s+megan\b',
      r'\bokey\s+megan\b',
      r'\boi\s+megan\b',
      r'\bola\s+megan\b',
      r'\be\s+megan\b',
    ];

    for (final pattern in patterns) {
      clean = clean.replaceAll(RegExp(pattern, caseSensitive: false), '');
    }

    return clean.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  Future<void> _toggleVoiceReply() async {
    final prefs = await SharedPreferences.getInstance();
    final value = !_voiceReply;

    await prefs.setBool('voiceReply', value);

    if (!mounted) return;
    setState(() => _voiceReply = value);

    _add(false, value ? 'Voz ativada.' : 'Voz desativada.');
  }

  Widget _quickButton(String label, IconData icon, VoidCallback onTap) {
    return ActionChip(
      avatar: Icon(icon, size: 18),
      label: Text(label),
      onPressed: onTap,
      backgroundColor: const Color(0xFF161A2A),
      side: BorderSide(color: Colors.white.withOpacity(.08)),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Megan Life 4.8.6 Assistente Real'),
          actions: [
            IconButton(
              onPressed: _pickAndAnalyzeFile,
              icon: const Icon(Icons.attach_file),
            ),
            IconButton(
              onPressed: _toggleVoiceReply,
              icon: Icon(_voiceReply ? Icons.volume_up : Icons.volume_off),
            ),
            IconButton(
              onPressed: _toggleListen,
              icon: Icon(_listening ? Icons.mic : Icons.mic_none),
            ),
          ],
        ),
        body: Column(
          children: [
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF10131F),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withOpacity(.08)),
              ),
              child: Text(
                _voiceStatus,
                style: const TextStyle(fontSize: 13, height: 1.3),
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Row(
                children: [
                  _quickButton('Saúde', Icons.favorite, () async {
                    _controller.text = 'analisar saúde do relógio';
                    await _send();
                  }),
                  const SizedBox(width: 8),
                  _quickButton('Atleta', Icons.directions_run, () async {
                    _controller.text = 'analisar desempenho de atleta';
                    await _send();
                  }),
                  const SizedBox(width: 8),
                  _quickButton('Arquivo', Icons.upload_file, _pickAndAnalyzeFile),
                  const SizedBox(width: 8),
                  _quickButton('Waze/Maps', Icons.navigation, () {
                    _controller.text = 'ir para ';
                  }),
                  const SizedBox(width: 8),
                  _quickButton('Sugestão', Icons.lightbulb, () {
                    _controller.text = 'sugestão ';
                  }),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: _messages.length,
                itemBuilder: (context, i) {
                  final m = _messages[i];

                  return Align(
                    alignment: m.user ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 720),
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: m.user ? const Color(0xFF7C3AED) : const Color(0xFF151827),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: Colors.white.withOpacity(.08)),
                      ),
                      child: Text(
                        m.text,
                        style: const TextStyle(fontSize: 15, height: 1.35),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (_loading) const LinearProgressIndicator(),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: _pickAndAnalyzeFile,
                      icon: const Icon(Icons.upload_file),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        minLines: 1,
                        maxLines: 4,
                        decoration: InputDecoration(
                          hintText: 'Fale ou digite para a Megan...',
                          filled: true,
                          fillColor: const Color(0xFF10131F),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                            borderSide: BorderSide.none,
                          ),
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    IconButton(
                      onPressed: _toggleListen,
                      icon: Icon(_listening ? Icons.hearing : Icons.mic),
                    ),
                    IconButton(
                      onPressed: _send,
                      icon: const Icon(Icons.send),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
}

class _WakeResult {
  final bool detected;
  final String command;

  const _WakeResult(this.detected, this.command);
}

class _Message {
  final bool user;
  final String text;

  _Message(this.user, this.text);
}