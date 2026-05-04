import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
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
import '../core/agents/communication_agent.dart';
import '../core/agents/navigation_agent.dart';
import '../core/agents/app_agent.dart';
import '../core/agents/memory_agent.dart';
import '../core/agents/context_agent.dart';
import '../core/agents/decision_agent.dart';
import '../core/agents/autonomy_agent.dart';
import '../core/agents/adaptive_agent.dart';
import '../core/agents/proactive_agent.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const MethodChannel _presenceChannel = MethodChannel('megan.presence');
  static const MethodChannel _systemChannel = MethodChannel('megan.system');

  final _controller = TextEditingController();
  final _ai = AiService();
  final _files = FileService();
  final _apps = AppLauncherService();
  late final CommunicationAgent _communicationAgent;
  late final NavigationAgent _navigationAgent;
  late final AppAgent _appAgent;
  late final MemoryAgent _memoryAgent;
  late final ContextAgent _contextAgent;
  late final DecisionAgent _decisionAgent;
  late final AutonomyAgent _autonomyAgent;
  late final AdaptiveAgent _adaptiveAgent;
  late final ProactiveAgent _proactiveAgent;
  final _nav = NavigationService();
  final _health = health.MeganHealthService();
  final _fallbackHealth = fallback.FallbackHealthService();
  final _speech = SpeechToText();
  final _tts = FlutterTts();
  final _random = Random();

  Timer? _restartTimer;
  Timer? _commandWindowTimer;
  Timer? _commandDebounceTimer;
  Timer? _ttsResumeTimer;
  Timer? _conversationIdleTimer;
  Timer? _proactiveTimer;

  final List<_Message> _messages = [
    _Message(false, 'Oi Luiz, sou a Megan Life 6.0 Proatividade Total. Diga: ok Megan.'),
  ];

  final List<_MemoryEntry> _shortMemory = [];

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
  bool _ttsSequenceActive = false;
  bool _waitingAutonomyConfirm = false;
  bool _mediaMode = false;
  bool _communicationMode = false;
  bool _presenceActive = false;
  bool _appInForeground = true;
  bool _backgroundWakeSafeMode = false;
  bool _commandsPanelOpen = false;
  bool _mountedSafe = false;
  DateTime? _speechBlockedUntil;
  DateTime? _microphoneRestartBlockedUntil;
  DateTime? _lastTtsFinishedAt;

  String _lastSpokenByMegan = '';


  String _lastVoiceText = '';
  DateTime? _lastVoiceAt;
  String _pendingCommand = '';
  String _voiceStatus = 'Inicializando voz...';
  String _lastCommandText = 'Nenhum comando ainda';
  String _lastSmartIntent = '';
  String _lastSmartTarget = '';
  String? _pendingWhatsAppChoice;
  AutonomyPlan? _pendingAutonomyPlan;
  String _pendingAutonomyCommand = '';
  String _preferredNavigationApp = 'perguntar';
  String _responseStyle = 'equilibrado';

  final List<String> _wakeReplies = const [
    'Estou ouvindo, Luiz. Como posso ajudar?',
    'Oi Luiz, pode falar.',
    'Pronta. O que você precisa?',
    'Estou aqui com você. Qual é o próximo passo?',
    'Pode falar, Luiz.',
    'Sim, Luiz. Como posso ajudar agora?',
    'Te ouvindo. O que vamos fazer?',
    'Estou pronta. Pode me dizer.',
    'Pode mandar, Luiz.',
  ];

  @override
  void initState() {
    super.initState();
    _mountedSafe = true;
    WidgetsBinding.instance.addObserver(this);
    _communicationAgent = CommunicationAgent(_apps);
    _navigationAgent = NavigationAgent(_nav);
    _appAgent = AppAgent(_apps);
    _memoryAgent = MemoryAgent();
    _contextAgent = ContextAgent();
    _autonomyAgent = AutonomyAgent();
    _adaptiveAgent = AdaptiveAgent();
    _proactiveAgent = ProactiveAgent();
    _decisionAgent = DecisionAgent(
      communication: _communicationAgent,
      navigation: _navigationAgent,
      app: _appAgent,
    );
    _apps.loadApps();
    _startProactiveLoop();
    _boot();
    _checkPresenceStatus();
  }

  @override
  void dispose() {
    _mountedSafe = false;
    _restartTimer?.cancel();
    _commandWindowTimer?.cancel();
    _commandDebounceTimer?.cancel();
    _ttsResumeTimer?.cancel();
    _conversationIdleTimer?.cancel();
    _proactiveTimer?.cancel();
    _controller.dispose();
    try {
      _speech.stop();
      _speech.cancel();
    } catch (_) {}
    try {
      _tts.stop();
    } catch (_) {}
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }


  void _safeSetState(VoidCallback fn) {
    if (!_mountedSafe || !mounted) return;
    setState(fn);
  }

  bool get _canUseUi => _mountedSafe && mounted;


  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    final inForeground = state == AppLifecycleState.resumed;

    if (!mounted) return;

    _safeSetState(() {
      _appInForeground = inForeground;
      _backgroundWakeSafeMode = !inForeground && _presenceActive;
    });

    if (!inForeground) {
      // 6.1.3 — Wake word background seguro:
      // não reinicia microfone de forma agressiva quando o app sai da tela.
      // A presença foreground continua viva pelo serviço Android, mas a escuta
      // fica controlada para não interferir em mídia, WhatsApp, Telegram ou apps externos.
      _restartTimer?.cancel();
      _commandWindowTimer?.cancel();
      _commandDebounceTimer?.cancel();
      _ttsResumeTimer?.cancel();

      if (_presenceActive) {
        _setVoiceStatus('Presença ativa em segundo plano. Wake word em modo seguro.');
      }

      try {
        if (_speech.isListening && !_processingVoiceCommand) {
          _speech.stop();
        }
      } catch (_) {}

      return;
    }

    _backgroundWakeSafeMode = false;

    // 6.1.4 FIX — Retorno seguro para a Megan:
    // quando a Megan abre um app externo, ela entra em modo mídia/comunicação
    // para não interferir no áudio. Ao voltar para a tela da Megan, o modo seguro
    // precisa ser encerrado automaticamente; caso contrário o microfone fica preso
    // em "modo mídia" e não volta a ouvir o wake word.
    if (_mediaMode || _communicationMode) {
      _mediaMode = false;
      _communicationMode = false;
      _manualStop = false;
      _pendingCommand = '';
      _commandMode = false;
      _wakeMessageShown = false;

      _safeSetState(() {
        _listening = true;
        _startingListen = false;
        _processingVoiceCommand = false;
      });

      _setVoiceStatus('Microfone reativado. Diga: ok Megan.');
      _scheduleRestart(delayMs: 700);
      return;
    }

    if (_presenceActive && !_manualStop && !_mediaMode && !_communicationMode && _listening) {
      _setVoiceStatus('Presença ativa. Microfone pronto. Diga: ok Megan.');
      _scheduleRestart(delayMs: 600);
    }
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

    _safeSetState(() {
      _voiceReply = prefs.getBool('voiceReply') ?? true;
      _preferredNavigationApp = prefs.getString('preferredNavigationApp') ?? 'perguntar';
      _responseStyle = prefs.getString('responseStyle') ?? 'equilibrado';
    });

    if (_speechReady) {
      _safeSetState(() {
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
    await _tts.setSpeechRate(0.48);
    await _tts.setPitch(1.05);
    await _tts.awaitSpeakCompletion(true);

    try {
      final voices = await _tts.getVoices;

      if (voices != null && voices is List) {
        final ptBrVoices = voices.where((voice) {
          final value = voice.toString().toLowerCase();
          return value.contains('pt') && value.contains('br');
        }).toList();

        if (ptBrVoices.isNotEmpty) {
          final preferredVoice = ptBrVoices.firstWhere(
            (voice) {
              final value = voice.toString().toLowerCase();
              return value.contains('female') ||
                  value.contains('feminina') ||
                  value.contains('google') ||
                  value.contains('brasil');
            },
            orElse: () => ptBrVoices.first,
          );

          if (preferredVoice is Map) {
            await _tts.setVoice(Map<String, String>.from(
              preferredVoice.map(
                (key, value) => MapEntry(key.toString(), value.toString()),
              ),
            ));
          }
        }
      }
    } catch (_) {}

    _tts.setStartHandler(() {
      _ttsSpeaking = true;
      _blockSpeechFor(const Duration(milliseconds: 1200));
    });

    _tts.setCompletionHandler(() {
      if (!_ttsSequenceActive) {
        _ttsSpeaking = false;
        _blockSpeechFor(const Duration(milliseconds: 1200));
        _resumeListeningAfterTts();
      }
    });

    _tts.setCancelHandler(() {
      if (!_ttsSequenceActive) {
        _ttsSpeaking = false;
        _blockSpeechFor(const Duration(milliseconds: 900));
        _resumeListeningAfterTts();
      }
    });

    _tts.setErrorHandler((_) {
      if (!_ttsSequenceActive) {
        _ttsSpeaking = false;
        _blockSpeechFor(const Duration(milliseconds: 900));
        _resumeListeningAfterTts();
      }
    });
  }

  Future<bool> _initializeSpeech() async {
    return _speech.initialize(
      onStatus: (status) {
        if (!mounted) return;

        if (!_processingVoiceCommand && !_isSpeechBlockedByTts()) {
          _setVoiceStatus('Status da voz: $status');
        }

        if (_manualStop ||
            !_listening ||
            _processingVoiceCommand ||
            _startingListen ||
            _isSpeechBlockedByTts()) {
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

        if (_manualStop || !_listening || _processingVoiceCommand || _isSpeechBlockedByTts()) {
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
    _safeSetState(() => _voiceStatus = value);
  }

  Future<void> _checkPresenceStatus() async {
    try {
      final status = await _presenceChannel.invokeMethod<bool>('presenceStatus');
      if (!mounted) return;
      _safeSetState(() => _presenceActive = status ?? false);
    } catch (_) {
      if (!mounted) return;
      _safeSetState(() => _presenceActive = false);
    }
  }

  Future<void> _startPresence() async {
    try {
      if (Platform.isAndroid) {
        await Permission.notification.request();
      }

      final started = await _presenceChannel.invokeMethod<bool>('startPresence');
      if (!mounted) return;

      _safeSetState(() {
        _presenceActive = started == true;
        if (started == true) {
          _backgroundWakeSafeMode = false;
          _manualStop = false;
          _listening = true;
          _commandMode = false;
          _wakeMessageShown = false;
        }
      });

      final answer = started == true
          ? 'Presença segura ativada. Microfone pronto no app. Diga: ok Megan.'
          : 'Não consegui ativar a presença segura agora.';

      _setVoiceStatus(answer);
      _add(false, answer);

      if (started == true && _speechReady && _appInForeground && !_mediaMode && !_communicationMode) {
        _scheduleRestart(delayMs: 700);
      }
    } catch (e) {
      if (!mounted) return;
      final answer = 'Erro ao ativar presença segura: $e';
      _setVoiceStatus(answer);
      _add(false, answer);
    }
  }

  Future<void> _stopPresence() async {
    try {
      await _presenceChannel.invokeMethod<bool>('stopPresence');
      if (!mounted) return;

      _safeSetState(() => _presenceActive = false);

      const answer = 'Presença segura desativada.';
      _setVoiceStatus(answer);
      _add(false, answer);
    } catch (e) {
      if (!mounted) return;
      final answer = 'Erro ao desativar presença segura: $e';
      _setVoiceStatus(answer);
      _add(false, answer);
    }
  }

  Future<void> _togglePresence() async {
    if (_presenceActive) {
      await _stopPresence();
    } else {
      await _startPresence();
    }
  }


  Future<void> _openBatterySettings() async {
    try {
      final opened = await _systemChannel.invokeMethod<bool>('openBatterySettings');
      final answer = opened == true
          ? 'Abrindo configurações de bateria. Procure a Megan Life e deixe sem restrição.'
          : 'Não consegui abrir as configurações de bateria automaticamente.';
      _setVoiceStatus(answer);
      _add(false, answer);
    } catch (e) {
      final answer = 'Erro ao abrir configurações de bateria: $e';
      _setVoiceStatus(answer);
      _add(false, answer);
    }
  }

  Future<void> _openAppSettings() async {
    try {
      final opened = await _systemChannel.invokeMethod<bool>('openAppSettings');
      final answer = opened == true
          ? 'Abrindo configurações da Megan Life. Confira microfone, notificações e permissões.'
          : 'Não consegui abrir as configurações do app automaticamente.';
      _setVoiceStatus(answer);
      _add(false, answer);
    } catch (e) {
      final answer = 'Erro ao abrir configurações do app: $e';
      _setVoiceStatus(answer);
      _add(false, answer);
    }
  }

  Future<void> _openAccessibilitySettings() async {
    try {
      final opened = await _systemChannel.invokeMethod<bool>('openAccessibilitySettings');
      final answer = opened == true
          ? 'Abrindo acessibilidade. Confira se o serviço da Megan está ativado.'
          : 'Não consegui abrir as configurações de acessibilidade automaticamente.';
      _setVoiceStatus(answer);
      _add(false, answer);
    } catch (e) {
      final answer = 'Erro ao abrir acessibilidade: $e';
      _setVoiceStatus(answer);
      _add(false, answer);
    }
  }

  Future<void> _openPermissionsCenter() async {
    // Botão funcional e seguro: abre as configurações do app diretamente,
    // sem BottomSheet/Navigator para evitar erro _dependents.isEmpty.
    await _closeCommandDrawerIfOpen();
    await _openAppSettings();
  }


  Future<void> _bringAppToFront({String reason = 'Retorno inteligente solicitado.'}) async {
    try {
      final opened = await _systemChannel.invokeMethod<bool>('bringToFront');
      final answer = opened == true
          ? 'Voltei para a Megan com segurança. $reason'
          : 'Não consegui trazer a Megan para frente automaticamente.';
      _setVoiceStatus(answer);
      _add(false, answer);
    } catch (e) {
      final answer = 'Erro ao trazer a Megan para frente: $e';
      _setVoiceStatus(answer);
      _add(false, answer);
    }
  }

  Future<void> _bringAppToFrontIfSafe({String reason = 'Retorno inteligente seguro.'}) async {
    // 6.4 — Auto-retorno inteligente:
    // não rouba foco quando a Megan está protegendo mídia ou comunicação.
    if (_mediaMode || _communicationMode) {
      _setVoiceStatus('Auto-retorno adiado para não interferir em mídia ou comunicação.');
      return;
    }

    await _bringAppToFront(reason: reason);
  }


  void _startProactiveLoop() {
    _proactiveTimer?.cancel();

    _proactiveTimer = Timer.periodic(const Duration(seconds: 30), (timer) async {
      if (!mounted) return;

      // 6.5 — Rotina Inteligente segura:
      // verifica sugestões em intervalo maior e deixa o ProactiveAgent controlar
      // horário, tempo mínimo de silêncio e anti-spam. Não interfere em mídia,
      // comunicação, fala, comando em andamento, confirmação de autonomia,
      // conversa ativa, carregamento ou microfone pausado manualmente.
      if (_mediaMode) return;
      if (_communicationMode) return;
      if (_manualStop) return;
      if (!_listening) return;
      if (_loading) return;
      if (_processingVoiceCommand) return;
      if (_startingListen) return;
      if (_ttsSpeaking || _ttsSequenceActive) return;
      if (_isSpeechBlockedByTts()) return;
      if (_waitingAutonomyConfirm) return;
      if (_commandMode) return;

      if (_proactiveAgent.shouldSuggest()) {
        final suggestion = _proactiveAgent.buildSuggestion();

        _add(false, suggestion);
        _rememberConversation('proatividade', suggestion);
        await _say(suggestion);
      }
    });
  }

  bool _isMediaCommand(String text) {
    final command = _normalize(text);

    return command.contains('youtube') ||
        command.contains('yt music') ||
        command.contains('youtube music') ||
        command.contains('spotify') ||
        command.contains('tiktok') ||
        command.contains('tik tok') ||
        command.contains('instagram') ||
        command.contains('reels') ||
        command.contains('netflix') ||
        command.contains('prime video') ||
        command.contains('disney') ||
        command.contains('max') ||
        command.contains('deezer') ||
        command.contains('musica') ||
        command.contains('música') ||
        command.contains('video') ||
        command.contains('vídeo');
  }

  Future<void> _enterMediaMode({String? sourceCommand}) async {
    _mediaMode = true;
    _communicationMode = false;
    _manualStop = true;
    _blockMicrophoneRestart(const Duration(seconds: 2));

    _restartTimer?.cancel();
    _commandWindowTimer?.cancel();
    _commandDebounceTimer?.cancel();
    _ttsResumeTimer?.cancel();
    _conversationIdleTimer?.cancel();

    _pendingCommand = '';
    _commandMode = false;
    _wakeMessageShown = false;

    try {
      if (_speech.isListening) {
        await _speech.stop();
      }
    } catch (_) {}

    if (!mounted) return;

    _safeSetState(() {
      _listening = false;
      _startingListen = false;
      _processingVoiceCommand = false;
    });

    _setVoiceStatus('Modo mídia ativo. Para a Megan não pausar vídeos, toque no microfone para voltar.');
  }

  Future<void> _exitMediaMode() async {
    _mediaMode = false;
    _manualStop = false;

    if (!mounted) return;

    _safeSetState(() {
      _listening = true;
      _commandMode = false;
      _wakeMessageShown = false;
    });

    _setVoiceStatus('Modo mídia desativado. Microfone ativo. Diga: ok Megan.');
    _scheduleRestart(delayMs: 400);
  }

  Future<void> _enterCommunicationMode({String? sourceCommand}) async {
    _communicationMode = true;
    _mediaMode = false;
    _manualStop = true;
    _blockMicrophoneRestart(const Duration(seconds: 2));

    _restartTimer?.cancel();
    _commandWindowTimer?.cancel();
    _commandDebounceTimer?.cancel();
    _ttsResumeTimer?.cancel();
    _conversationIdleTimer?.cancel();

    _pendingCommand = '';
    _commandMode = false;
    _wakeMessageShown = false;

    try {
      if (_speech.isListening) {
        await _speech.stop();
      }
    } catch (_) {}

    try {
      await _tts.stop();
    } catch (_) {}

    if (!mounted) return;

    _safeSetState(() {
      _listening = false;
      _startingListen = false;
      _processingVoiceCommand = false;
    });

    _setVoiceStatus('Modo comunicação ativo. Microfone pausado para não interferir em áudio de mensagens. Toque no microfone para voltar.');
  }

  Future<void> _exitCommunicationMode() async {
    _communicationMode = false;
    _manualStop = false;

    if (!mounted) return;

    _safeSetState(() {
      _listening = true;
      _commandMode = false;
      _wakeMessageShown = false;
    });

    _setVoiceStatus('Modo comunicação desativado. Microfone ativo. Diga: ok Megan.');
    _scheduleRestart(delayMs: 400);
  }


  bool _isExternalAppCommand(String text) {
    final command = text.trim();
    if (command.isEmpty) return false;

    // O modo mídia universal vale para abertura de apps externos feita pelo AppAgent.
    // Fluxos sensíveis e próprios de outros agentes continuam fora daqui para não quebrar:
    // WhatsApp/comunicação, navegação, comandos de sistema e confirmações de autonomia.
    if (_isCommunicationAppCommand(command)) return false;
    if (!_appAgent.isExternalAppCommand(command)) return false;

    final normalized = _normalize(command);

    if (normalized.contains('navegar') ||
        normalized.contains('rota') ||
        normalized.contains('me leva') ||
        normalized.contains('ir para') ||
        normalized.contains('ir pra')) {
      return false;
    }

    return true;
  }

  bool _isCommunicationAppCommand(String text) {
    final command = text.trim();
    if (command.isEmpty) return false;

    final normalized = _normalize(command);

    if (normalized.contains('whatsapp') ||
        normalized.contains('zap') ||
        normalized.contains('wpp') ||
        normalized.contains('telegram') ||
        normalized.contains('gmail') ||
        normalized.contains('email') ||
        normalized.contains('e mail') ||
        normalized.contains('mensagem') ||
        normalized.contains('sms') ||
        normalized.contains('messenger') ||
        normalized.contains('signal')) {
      return true;
    }

    return _appAgent.isCommunicationCommand(command);
  }

  Future<bool> _tryOpenCommunicationAppSafely(String text) async {
    final clean = text.trim();
    if (!_isCommunicationAppCommand(clean)) return false;

    // WhatsApp/mensagem seguem o fluxo próprio para manter escolha Normal/Business
    // e segurança de envio. Aqui tratamos apps de comunicação abertos como app.
    final normalized = _normalize(clean);
    if (normalized.contains('whatsapp') ||
        normalized.contains('zap') ||
        normalized.contains('wpp') ||
        normalized.contains('mensagem') ||
        normalized.contains('mandar') ||
        normalized.contains('enviar')) {
      return false;
    }

    if (!_appAgent.canHandle(clean)) return false;

    final appName = _appAgent.extractAppName(clean);
    if (appName.trim().isEmpty) return false;

    await _enterCommunicationMode(sourceCommand: clean);

    final opened = await _appAgent.handleCommunication(clean);

    if (opened) {
      final answer = 'Abrindo $appName em modo comunicação. Microfone pausado para não interferir em áudios de mensagens.';
      if (mounted) _safeSetState(() => _lastCommandText = clean);
      _add(false, answer);
      _rememberConversation(clean, answer);
      await _rememberSmartIntent('open_app', appName);
      return true;
    }

    await _exitCommunicationMode();

    final answer = 'Luiz, não consegui abrir $appName. Verifique se o app está instalado.';
    _add(false, answer);
    _rememberConversation(clean, answer);
    await _say(answer);
    return true;
  }

  Future<bool> _tryOpenExternalAppSafely(String text) async {
    final clean = text.trim();
    if (!_isExternalAppCommand(clean)) return false;

    final appName = _appAgent.extractAppName(clean);
    if (appName.trim().isEmpty) return false;

    // 6.0.1.2 — Modo mídia universal:
    // qualquer app externo aberto pela Megan pausa microfone/TTS antes de abrir.
    // Isso evita que a escuta contínua interfira em vídeos, música, players e apps que usam áudio.
    await _enterMediaMode(sourceCommand: clean);

    final opened = await _appAgent.handleExternalApp(clean);

    if (opened) {
      final answer = 'Abrindo $appName em modo mídia universal. Microfone pausado para não interferir no app.';
      if (mounted) _safeSetState(() => _lastCommandText = clean);
      _add(false, answer);
      _rememberConversation(clean, answer);
      await _rememberSmartIntent('open_app', appName);
      return true;
    }

    await _exitMediaMode();

    final answer = 'Luiz, não consegui abrir $appName. Verifique se o app está instalado.';
    _add(false, answer);
    _rememberConversation(clean, answer);
    await _say(answer);
    return true;
  }

  List<String> _splitCommandParts(String text) {
    return text
        .split(RegExp(r'\s+(?:e\s+depois|depois|em seguida|e entao|e então|e)\s+', caseSensitive: false))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
  }

  String? _extractFirstMediaCommand(String text) {
    final parts = _splitCommandParts(text);

    if (parts.isEmpty) {
      return _isMediaCommand(text) ? text.trim() : null;
    }

    for (final part in parts) {
      if (_isMediaCommand(part)) {
        if (_appAgent.canHandle(part)) return part;
        return 'abrir $part';
      }
    }

    return _isMediaCommand(text) ? text.trim() : null;
  }

  Future<bool> _tryOpenMediaCommandSafely(String text) async {
    final mediaCommand = _extractFirstMediaCommand(text);
    if (mediaCommand == null || mediaCommand.trim().isEmpty) return false;

    final appCommand = _appAgent.canHandle(mediaCommand)
        ? mediaCommand
        : 'abrir ${mediaCommand.trim()}';

    if (!_appAgent.canHandle(appCommand)) return false;

    final appName = _appAgent.extractAppName(appCommand);
    if (appName.trim().isEmpty) return false;

    // Entra no modo mídia ANTES de abrir o app para impedir que o microfone
    // reinicie em cima do áudio do vídeo/música.
    await _enterMediaMode(sourceCommand: text);

    final opened = await _appAgent.handle(appCommand);

    if (opened) {
      final answer = 'Abrindo $appName em modo mídia. Microfone pausado para não interferir no vídeo ou música.';
      if (mounted) _safeSetState(() => _lastCommandText = text.trim());
      _add(false, answer);
      _rememberConversation(text.trim(), answer);
      await _rememberSmartIntent('open_app', appName);
      return true;
    }

    await _exitMediaMode();

    final answer = 'Luiz, não consegui abrir $appName. Verifique se o app está instalado.';
    _add(false, answer);
    _rememberConversation(text.trim(), answer);
    await _say(answer);
    return true;
  }

  void _scheduleRestart({int delayMs = 800}) {
    _restartTimer?.cancel();

    _restartTimer = Timer(Duration(milliseconds: delayMs), () async {
      if (!mounted ||
          _mediaMode ||
          _communicationMode ||
          _manualStop ||
          !_listening ||
          _processingVoiceCommand ||
          _startingListen ||
          _backgroundWakeSafeMode ||
          !_appInForeground ||
          _isMicrophoneRestartBlocked() ||
          _isSpeechBlockedByTts()) {
        return;
      }

      await _startListening();
    });
  }

  void _blockSpeechFor(Duration duration) {
    _speechBlockedUntil = DateTime.now().add(duration);
  }

  bool _isSpeechBlockedByTts() {
    if (_ttsSpeaking || _ttsSequenceActive) return true;

    final blockedUntil = _speechBlockedUntil;
    if (blockedUntil == null) return false;

    return DateTime.now().isBefore(blockedUntil);
  }

  void _blockMicrophoneRestart(Duration duration) {
    _microphoneRestartBlockedUntil = DateTime.now().add(duration);
  }

  bool _isMicrophoneRestartBlocked() {
    final blockedUntil = _microphoneRestartBlockedUntil;
    if (blockedUntil == null) return false;

    return DateTime.now().isBefore(blockedUntil);
  }

  bool _looksLikeMeganEcho(String text) {
    final heard = _normalize(text);
    final spoken = _normalize(_lastSpokenByMegan);

    if (heard.isEmpty || spoken.isEmpty) return false;

    final lastFinishedAt = _lastTtsFinishedAt;
    if (lastFinishedAt == null) return false;

    final recentlySpoken = DateTime.now().difference(lastFinishedAt).inSeconds <= 8;
    if (!recentlySpoken && !_ttsSpeaking && !_ttsSequenceActive) return false;

    if (spoken.contains(heard) && heard.length >= 10) return true;
    if (heard.contains(spoken) && spoken.length >= 10) return true;

    final heardWords = heard.split(' ').where((word) => word.length > 3).toSet();
    final spokenWords = spoken.split(' ').where((word) => word.length > 3).toSet();

    if (heardWords.isEmpty || spokenWords.isEmpty) return false;

    final intersection = heardWords.intersection(spokenWords).length;
    final smallest = heardWords.length < spokenWords.length ? heardWords.length : spokenWords.length;

    return smallest >= 3 && (intersection / smallest) >= 0.72;
  }

  void _resumeListeningAfterTts() {
    _ttsResumeTimer?.cancel();

    _ttsResumeTimer = Timer(const Duration(milliseconds: 1400), () {
      if (!mounted ||
          _mediaMode ||
          _communicationMode ||
          _manualStop ||
          !_listening ||
          _processingVoiceCommand ||
          _backgroundWakeSafeMode ||
          !_appInForeground) {
        return;
      }

      if (_isMicrophoneRestartBlocked() || _isSpeechBlockedByTts()) {
        _resumeListeningAfterTts();
        return;
      }

      _pendingCommand = '';
      _scheduleRestart(delayMs: 400);
    });
  }

  Future<void> _say(String text) async {
    if (!_voiceReply) return;

    final fullText = _cleanMeganOutput(text).trim();
    if (fullText.isEmpty) return;

    _lastSpokenByMegan = fullText;
    _blockMicrophoneRestart(const Duration(milliseconds: 2600));

    try {
      _ttsSequenceActive = true;
      _ttsSpeaking = true;
      _blockSpeechFor(const Duration(seconds: 2));
      _blockMicrophoneRestart(const Duration(milliseconds: 2600));
      _ttsResumeTimer?.cancel();
      _restartTimer?.cancel();
      _commandDebounceTimer?.cancel();
      _pendingCommand = '';

      if (_speech.isListening) {
        await _speech.stop();
        await Future.delayed(const Duration(milliseconds: 260));
      }

      await _tts.stop();

      final parts = _splitHumanizedText(fullText);

      for (final part in parts) {
        if (!_voiceReply || !mounted) break;

        _ttsSpeaking = true;
        _blockSpeechFor(const Duration(seconds: 2));
        _blockMicrophoneRestart(const Duration(milliseconds: 2600));

        await _tts.speak(part);

        final delay = _getHumanPauseDuration(part);
        _blockSpeechFor(delay + const Duration(milliseconds: 900));
        await Future.delayed(delay);
      }
    } catch (_) {
      try {
        _ttsSpeaking = true;
        _blockSpeechFor(const Duration(seconds: 2));
        await _tts.speak(fullText);
      } catch (_) {}
    } finally {
      _ttsSequenceActive = false;
      _ttsSpeaking = false;
      _lastTtsFinishedAt = DateTime.now();
      _pendingCommand = '';
      _blockSpeechFor(const Duration(milliseconds: 1800));
      _blockMicrophoneRestart(const Duration(milliseconds: 2200));
      if (!_mediaMode) {
        _resumeListeningAfterTts();
      }
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

  List<String> _splitHumanizedText(String text) {
    const maxHumanPartLength = 170;
    const maxEmergencyLength = 135;

    final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty) return [];

    final punctuationParts = clean.split(RegExp(r'(?<=[,.!?])\s+'));
    final result = <String>[];

    for (final rawPart in punctuationParts) {
      final part = rawPart.trim();
      if (part.isEmpty) continue;

      if (part.length <= maxHumanPartLength) {
        result.add(part);
        continue;
      }

      final sentenceParts = part.split(RegExp(r'(?<=[;:])\s+'));

      for (final rawSentencePart in sentenceParts) {
        final sentencePart = rawSentencePart.trim();
        if (sentencePart.isEmpty) continue;

        if (sentencePart.length <= maxHumanPartLength) {
          result.add(sentencePart);
          continue;
        }

        final words = sentencePart.split(' ');
        final buffer = StringBuffer();

        for (final word in words) {
          if ((buffer.length + word.length + 1) > maxEmergencyLength) {
            final current = buffer.toString().trim();
            if (current.isNotEmpty) result.add(current);
            buffer.clear();
          }

          buffer.write('$word ');
        }

        final rest = buffer.toString().trim();
        if (rest.isNotEmpty) result.add(rest);
      }
    }

    return result.where((p) => p.trim().isNotEmpty).toList();
  }

  Duration _getHumanPauseDuration(String text) {
    final value = text.trim();

    if (value.endsWith(',')) {
      return const Duration(milliseconds: 180);
    }

    if (value.endsWith('?') || value.endsWith('!')) {
      return const Duration(milliseconds: 420);
    }

    if (value.endsWith('.')) {
      return const Duration(milliseconds: 320);
    }

    if (value.endsWith(';') || value.endsWith(':')) {
      return const Duration(milliseconds: 260);
    }

    if (value.length > 120) {
      return const Duration(milliseconds: 260);
    }

    return const Duration(milliseconds: 210);
  }

  String _humanizeChatAnswer(String text) {
    final clean = _cleanMeganOutput(text).trim();
    if (clean.isEmpty) return clean;

    final lower = clean.toLowerCase();

    if (_alreadyHasHumanOpening(clean)) {
      return clean;
    }

    if (lower.startsWith('erro:') ||
        lower.startsWith('não consegui') ||
        lower.startsWith('nao consegui')) {
      return _randomFrom([
        'Entendi, Luiz. Tive um problema aqui: $clean',
        'Luiz, encontrei um problema nessa parte: $clean',
        'Calma, Luiz. Vou te mostrar o que aconteceu: $clean',
      ]);
    }

    if (lower.contains('não sei') || lower.contains('nao sei')) {
      return _randomFrom([
        'Vou ser transparente com você, Luiz. $clean',
        'Nesse ponto eu prefiro não inventar. $clean',
        'Para manter segurança, Luiz, vou ser sincera: $clean',
      ]);
    }

    if (_looksLikeActionConfirmation(clean)) {
      return _randomFrom([
        clean,
        'Pronto, Luiz. $clean',
        'Feito. $clean',
      ]);
    }

    if (clean.length < 70) {
      return _randomFrom([
        clean,
        'Certo, Luiz. $clean',
        'Perfeito, Luiz. $clean',
        'Combinado. $clean',
      ]);
    }

    return _randomFrom([
      clean,
      'Certo, Luiz. $clean',
      'Entendi, Luiz. $clean',
      'Vou organizar isso com clareza para você. $clean',
    ]);
  }

  bool _alreadyHasHumanOpening(String text) {
    final value = text.trim().toLowerCase();

    return value.startsWith('luiz') ||
        value.startsWith('certo') ||
        value.startsWith('perfeito') ||
        value.startsWith('entendi') ||
        value.startsWith('combinado') ||
        value.startsWith('pronto') ||
        value.startsWith('feito') ||
        value.startsWith('vou') ||
        value.startsWith('calma');
  }

  bool _looksLikeActionConfirmation(String text) {
    final value = _normalize(text);

    return value.startsWith('abrindo') ||
        value.startsWith('indo') ||
        value.startsWith('voltando') ||
        value.startsWith('preparei') ||
        value.startsWith('pronto') ||
        value.startsWith('feito') ||
        value.contains('navegacao pronta') ||
        value.contains('modo copiloto ativado');
  }

  String _randomFrom(List<String> options) {
    if (options.isEmpty) return '';
    return options[_random.nextInt(options.length)];
  }

  Future<void> _rememberSmartIntent(String intent, String target) async {
    final cleanIntent = intent.trim();
    final cleanTarget = target.trim();

    if (cleanIntent.isEmpty || cleanTarget.isEmpty) return;

    _lastSmartIntent = cleanIntent;
    _lastSmartTarget = cleanTarget;

    try {
      await _memoryAgent.rememberIntent(cleanIntent, cleanTarget);
    } catch (_) {}
  }

  Future<void> _restoreLastSmartContextIfNeeded() async {
    if (_lastSmartIntent.trim().isNotEmpty && _lastSmartTarget.trim().isNotEmpty) {
      return;
    }

    try {
      final memory = await _memoryAgent.getLastContext();
      final intent = (memory['intent'] ?? '').trim();
      final target = (memory['target'] ?? '').trim();

      if (intent.isNotEmpty && target.isNotEmpty) {
        _lastSmartIntent = intent;
        _lastSmartTarget = target;
      }
    } catch (_) {}
  }

  bool _isPreferenceCommand(String text) {
    final command = _normalize(text);

    return command.contains('prefiro waze') ||
        command.contains('usar waze') ||
        command.contains('sempre waze') ||
        command.contains('prefiro maps') ||
        command.contains('prefiro google maps') ||
        command.contains('usar maps') ||
        command.contains('usar google maps') ||
        command.contains('sempre maps') ||
        command.contains('sempre google maps') ||
        command.contains('respostas curtas') ||
        command.contains('resposta curta') ||
        command.contains('seja mais direta') ||
        command.contains('seja direta') ||
        command.contains('respostas detalhadas') ||
        command.contains('resposta detalhada') ||
        command.contains('explique mais') ||
        command.contains('seja mais detalhada') ||
        command.contains('resposta equilibrada') ||
        command.contains('respostas equilibradas');
  }

  Future<String?> _applyPreferenceCommand(String text) async {
    final command = _normalize(text);
    final prefs = await SharedPreferences.getInstance();

    if (command.contains('prefiro waze') ||
        command.contains('usar waze') ||
        command.contains('sempre waze')) {
      await prefs.setString('preferredNavigationApp', 'waze');
      if (mounted) _safeSetState(() => _preferredNavigationApp = 'waze');
      return 'Perfeito, Luiz. Vou lembrar que você prefere usar o Waze para navegação.';
    }

    if (command.contains('prefiro maps') ||
        command.contains('prefiro google maps') ||
        command.contains('usar maps') ||
        command.contains('usar google maps') ||
        command.contains('sempre maps') ||
        command.contains('sempre google maps')) {
      await prefs.setString('preferredNavigationApp', 'maps');
      if (mounted) _safeSetState(() => _preferredNavigationApp = 'maps');
      return 'Combinado, Luiz. Vou lembrar que você prefere usar o Google Maps para navegação.';
    }

    if (command.contains('respostas curtas') ||
        command.contains('resposta curta') ||
        command.contains('seja mais direta') ||
        command.contains('seja direta')) {
      await prefs.setString('responseStyle', 'curto');
      if (mounted) _safeSetState(() => _responseStyle = 'curto');
      return 'Entendido, Luiz. Vou lembrar que você prefere respostas mais diretas.';
    }

    if (command.contains('respostas detalhadas') ||
        command.contains('resposta detalhada') ||
        command.contains('explique mais') ||
        command.contains('seja mais detalhada')) {
      await prefs.setString('responseStyle', 'detalhado');
      if (mounted) _safeSetState(() => _responseStyle = 'detalhado');
      return 'Perfeito, Luiz. Vou lembrar que você prefere respostas mais detalhadas.';
    }

    if (command.contains('resposta equilibrada') ||
        command.contains('respostas equilibradas')) {
      await prefs.setString('responseStyle', 'equilibrado');
      if (mounted) _safeSetState(() => _responseStyle = 'equilibrado');
      return 'Certo, Luiz. Vou manter um estilo equilibrado nas respostas.';
    }

    return null;
  }

  String _applyResponseStyle(String answer) {
    final clean = answer.trim();
    if (clean.isEmpty) return clean;

    if (_responseStyle == 'curto' && clean.length > 520) {
      final parts = clean.split(RegExp(r'(?<=[.!?])\s+'));
      final buffer = StringBuffer();

      for (final part in parts) {
        final item = part.trim();
        if (item.isEmpty) continue;
        if ((buffer.length + item.length) > 420) break;
        buffer.write('$item ');
      }

      final shortAnswer = buffer.toString().trim();
      return shortAnswer.isNotEmpty ? shortAnswer : clean.substring(0, 420).trim();
    }

    if (_responseStyle == 'detalhado' && clean.length < 120) {
      return '$clean Posso continuar detalhando se você quiser seguir por essa direção.';
    }

    return clean;
  }



  bool _isWhatsAppChoiceCommand(String text) {
    final command = _normalize(text);

    return command == 'normal' ||
        command == 'whatsapp normal' ||
        command == 'o normal' ||
        command == 'app normal' ||
        command == 'business' ||
        command == 'whatsapp business' ||
        command == 'comercial' ||
        command == 'empresa' ||
        command == 'o business' ||
        command == 'o comercial' ||
        command == 'da empresa';
  }

  Future<bool> _handlePendingWhatsAppChoice(String text) async {
    if (_pendingWhatsAppChoice == null) return false;

    final command = _normalize(text);

    final useBusiness = command.contains('business') ||
        command.contains('comercial') ||
        command.contains('empresa');

    final useNormal = command.contains('normal') ||
        command == 'whatsapp' ||
        command == 'zap';

    if (!useBusiness && !useNormal) {
      final answer = 'Luiz, preciso que você escolha: WhatsApp normal ou WhatsApp Business?';
      _add(false, answer);
      await _say(answer);
      return true;
    }

    final opened = useBusiness
        ? await _apps.openWhatsAppBusiness()
        : await _apps.openWhatsAppNormal();

    _pendingWhatsAppChoice = null;
    await _rememberSmartIntent('message', useBusiness ? 'whatsapp business' : 'whatsapp');

    final answer = opened
        ? useBusiness
            ? 'Abrindo WhatsApp Business, Luiz.'
            : 'Abrindo WhatsApp normal, Luiz.'
        : useBusiness
            ? 'Luiz, não consegui abrir o WhatsApp Business. Verifique se ele está instalado.'
            : 'Luiz, não consegui abrir o WhatsApp normal. Verifique se ele está instalado.';

    if (mounted) _safeSetState(() => _lastCommandText = text.trim());
    _add(false, answer);
    _rememberConversation(text.trim(), answer);

    if (opened) {
      await _enterCommunicationMode(sourceCommand: text.trim());
    } else {
      await _say(answer);
    }

    return true;
  }

  bool _looksLikeSmartIntent(String text) {
    final command = _normalize(text);

    return command.contains('app do banco') ||
        command.contains('aplicativo do banco') ||
        command.contains('meu banco') ||
        command.contains('abrir banco') ||
        command.contains('abre o banco') ||
        command.contains('manda mensagem') ||
        command.contains('mandar mensagem') ||
        command.contains('enviar mensagem') ||
        command.contains('envia mensagem') ||
        command.contains('whatsapp') ||
        command.contains('zap') ||
        command.contains('me leva pra casa') ||
        command.contains('me leva para casa') ||
        command.contains('ir pra casa') ||
        command.contains('ir para casa') ||
        command.contains('abre ele') ||
        command.contains('abre isso') ||
        command.contains('abrir isso') ||
        command.contains('faz isso') ||
        command.contains('faca isso') ||
        command.startsWith('fala que ') ||
        command.startsWith('diz que ');
  }

  Future<bool> _tryHandleSmartIntent(String text) async {
    final clean = text.trim();
    final command = _normalize(clean);

    if (command.isEmpty) return false;

    if (_pendingWhatsAppChoice != null) {
      return await _handlePendingWhatsAppChoice(clean);
    }

    if (!_looksLikeSmartIntent(clean)) return false;

    if (_appAgent.canHandle(clean)) {
      final appName = _appAgent.extractAppName(clean);
      final handled = await _appAgent.handle(clean);

      if (handled) {
        final answer = 'Abrindo $appName, Luiz.';
        await _rememberSmartIntent('open_app', appName);
        if (mounted) _safeSetState(() => _lastCommandText = clean);
        _add(false, answer);
        _rememberConversation(clean, answer);
        await _say(answer);
        return true;
      }
    }

    if (command.contains('app do banco') ||
        command.contains('aplicativo do banco') ||
        command.contains('meu banco') ||
        command.contains('abrir banco') ||
        command.contains('abre o banco')) {
      final bankCandidates = <String>[
        'nubank',
        'itau',
        'itaú',
        'bradesco',
        'santander',
        'caixa',
        'banco inter',
        'inter',
        'banco do brasil',
        'bb',
        'mercado pago',
        'picpay',
        'c6 bank',
        'banco',
      ];

      for (final candidate in bankCandidates) {
        final opened = await _apps.openKnownApp(candidate);
        if (opened) {
          final answer = 'Pronto, Luiz. Abri o app que parece ser seu banco: $candidate.';
          await _rememberSmartIntent('open_app', candidate);
          if (mounted) _safeSetState(() => _lastCommandText = clean);
          _add(false, answer);
          _rememberConversation(clean, answer);
          await _say(answer);
          return true;
        }
      }

      final answer = 'Luiz, não consegui identificar qual app de banco abrir. Me diga o nome do banco, por exemplo Nubank, Itaú, Bradesco, Santander ou Caixa.';
      await _rememberSmartIntent('open_app', 'banco');
      if (mounted) _safeSetState(() => _lastCommandText = clean);
      _add(false, answer);
      _rememberConversation(clean, answer);
      await _say(answer);
      return true;
    }

    if (_navigationAgent.canHandle(clean)) {
      final destination = _navigationAgent.extractDestination(clean);
      final handled = await _navigationAgent.handle(context, clean);

      if (handled) {
        final answer = _preferredNavigationApp == 'waze'
            ? 'Certo, Luiz. Preparei a navegação para $destination. Como você prefere Waze, escolha Waze na tela.'
            : _preferredNavigationApp == 'maps'
                ? 'Certo, Luiz. Preparei a navegação para $destination. Como você prefere Google Maps, escolha Google Maps na tela.'
                : 'Certo, Luiz. Preparei a navegação para $destination. Escolha Waze ou Google Maps.';
        await _rememberSmartIntent('navigate', destination);
        if (mounted) _safeSetState(() => _lastCommandText = clean);
        _add(false, answer);
        _rememberConversation(clean, answer);
        await _say(answer);
        return true;
      }
    }

    if (command.contains('manda mensagem') ||
        command.contains('mandar mensagem') ||
        command.contains('enviar mensagem') ||
        command.contains('envia mensagem') ||
        command.contains('whatsapp') ||
        command.contains('zap')) {
      final communicationIntent = _communicationAgent.detect(clean);

      final wantsBusiness = communicationIntent.prefersBusiness ||
          command.contains('business') ||
          command.contains('comercial') ||
          command.contains('empresa');

      final wantsNormal = communicationIntent.prefersNormal || command.contains('normal');

      final hasNormal = await _apps.hasWhatsAppNormal();
      final hasBusiness = await _apps.hasWhatsAppBusiness();

      if (hasNormal && hasBusiness && !wantsBusiness && !wantsNormal) {
        _pendingWhatsAppChoice = 'open';
        await _rememberSmartIntent('message', 'whatsapp');

        final answer = 'Luiz, você quer abrir o WhatsApp normal ou o WhatsApp Business?';
        if (mounted) _safeSetState(() => _lastCommandText = clean);
        _add(false, answer);
        _rememberConversation(clean, answer);
        await _say(answer);
        return true;
      }

      final opened = wantsBusiness
          ? await _apps.openWhatsAppBusiness()
          : wantsNormal
              ? await _apps.openWhatsAppNormal()
              : await _apps.openWhatsAppChat();

      final targetName = wantsBusiness ? 'WhatsApp Business' : wantsNormal ? 'WhatsApp normal' : 'WhatsApp';

      final answer = opened
          ? 'Abri o $targetName, Luiz. Por segurança, me diga ou confira na tela o contato e o conteúdo antes de enviar.'
          : 'Luiz, entendi que você quer mandar mensagem, mas não consegui abrir o $targetName. Verifique se ele está instalado.';
      await _rememberSmartIntent('message', wantsBusiness ? 'whatsapp business' : 'whatsapp');
      if (mounted) _safeSetState(() => _lastCommandText = clean);
      _add(false, answer);
      _rememberConversation(clean, answer);

      if (opened) {
        await _enterCommunicationMode(sourceCommand: clean);
      } else {
        await _say(answer);
      }

      return true;
    }

    if ((command.startsWith('fala que ') || command.startsWith('diz que ')) &&
        _lastSmartIntent == 'message') {
      final message = clean.replaceFirst(RegExp(r'^(fala que|diz que)\s+', caseSensitive: false), '').trim();
      final answer = message.isEmpty
          ? 'Luiz, me diga o conteúdo da mensagem com clareza antes de enviar.'
          : 'Entendi, Luiz. A mensagem seria: "$message". Por segurança, confira e envie pelo WhatsApp aberto.';
      if (mounted) _safeSetState(() => _lastCommandText = clean);
      _add(false, answer);
      _rememberConversation(clean, answer);
      await _say(answer);
      return true;
    }

    final isContextFollowUp = command.contains('abre ele') ||
        command.contains('abre isso') ||
        command.contains('abrir isso') ||
        command.contains('faz isso') ||
        command.contains('faca isso');

    if (isContextFollowUp) {
      await _restoreLastSmartContextIfNeeded();
    }

    if (isContextFollowUp && _lastSmartTarget.trim().isNotEmpty) {
      if (_lastSmartIntent == 'open_app' || _lastSmartIntent == 'message') {
        final opened = await _apps.openKnownApp(_lastSmartTarget);
        final answer = opened
            ? 'Pronto, Luiz. Abri $_lastSmartTarget.'
            : 'Luiz, tentei abrir $_lastSmartTarget, mas não consegui. Me diga o nome exato do app.';
        if (mounted) _safeSetState(() => _lastCommandText = clean);
        _add(false, answer);
        _rememberConversation(clean, answer);
        await _say(answer);
        return true;
      }

      if (_lastSmartIntent == 'navigate') {
        await _nav.openNavigationChoice(context, _lastSmartTarget);
        final answer = 'Certo, Luiz. Reabri a navegação para $_lastSmartTarget.';
        if (mounted) _safeSetState(() => _lastCommandText = clean);
        _add(false, answer);
        _rememberConversation(clean, answer);
        await _say(answer);
        return true;
      }
    }

    return false;
  }

  void _rememberConversation(String userText, String meganText) {
    final userClean = userText.trim();
    final meganClean = meganText.trim();

    if (userClean.isEmpty || meganClean.isEmpty) return;

    _shortMemory.add(_MemoryEntry(userClean, meganClean));

    while (_shortMemory.length > 3) {
      _shortMemory.removeAt(0);
    }
  }

  String _buildContextualText(String currentText) {
    final clean = currentText.trim();
    if (clean.isEmpty) return clean;

    final normalized = _normalize(clean);

    final looksLikeFollowUp = normalized == 'e agora' ||
        normalized == 'agora' ||
        normalized == 'continua' ||
        normalized == 'continue' ||
        normalized == 'continuar' ||
        normalized == 'proximo' ||
        normalized == 'qual o proximo' ||
        normalized == 'qual proximo' ||
        normalized == 'faz isso' ||
        normalized == 'faca isso' ||
        normalized == 'pode fazer' ||
        normalized == 'sim' ||
        normalized == 'ok' ||
        normalized == 'certo' ||
        normalized == 'isso' ||
        normalized == 'esse' ||
        normalized == 'essa' ||
        normalized == 'abre esse' ||
        normalized == 'abre isso' ||
        normalized == 'vai nele' ||
        normalized == 'vai nessa' ||
        normalized == 'faz agora' ||
        normalized == 'pode continuar';

    final looksLikeDirectIntent = normalized.contains('abrir ') ||
        normalized.startsWith('abra ') ||
        normalized.startsWith('abre ') ||
        normalized.contains('ir para ') ||
        normalized.contains('navegar para ') ||
        normalized.contains('me leve para ') ||
        normalized.contains('analisar ') ||
        normalized.contains('resumir ') ||
        normalized.contains('explicar ') ||
        normalized.contains('comparar ') ||
        normalized.contains('criar ') ||
        normalized.contains('gerar ') ||
        normalized.contains('enviar ') ||
        normalized.contains('ler ') ||
        normalized.contains('procurar ') ||
        normalized.contains('pesquisar ');

    if (_shortMemory.isEmpty) return clean;

    if (!looksLikeFollowUp && clean.length > 20) {
      return clean;
    }

    final buffer = StringBuffer();
    buffer.writeln('Contexto recente da conversa:');

    for (final item in _shortMemory) {
      buffer.writeln('Luiz: ${item.userText}');
      buffer.writeln('Megan: ${item.meganText}');
    }

    buffer.writeln('');
    buffer.writeln('Mensagem atual do Luiz: $clean');
    buffer.writeln('');

    if (looksLikeDirectIntent) {
      buffer.writeln(
        'A mensagem atual parece conter uma intenção direta. Use o contexto apenas se ajudar a completar referência como "isso", "esse", "essa", "nele" ou "nela". Se a intenção estiver clara, responda ou execute normalmente.',
      );
    } else if (looksLikeFollowUp) {
      buffer.writeln(
        'A mensagem atual parece continuação da conversa. Responda considerando o contexto recente e mantenha continuidade natural.',
      );
    } else {
      buffer.writeln(
        'Use o contexto recente somente se ele ajudar. Se não ajudar, responda apenas à mensagem atual.',
      );
    }

    buffer.writeln(
      'Nunca invente uma ação perigosa. Se faltar informação para executar algo, peça confirmação curta.',
    );

    return buffer.toString().trim();
  }

  bool _needsSafetyCheck(String text) {
    final command = _normalize(text);

    if (command.isEmpty) return false;

    final isSuggestion = command.contains('sugestao') ||
        command.contains('feedback') ||
        command.contains('melhoria');

    if (isSuggestion) return false;

    final dangerousAction = command.contains('apagar') ||
        command.contains('deletar') ||
        command.contains('excluir') ||
        command.contains('remover tudo') ||
        command.contains('limpar tudo') ||
        command.contains('formatar') ||
        command.contains('desinstalar') ||
        command.contains('comprar') ||
        command.contains('pagar') ||
        command.contains('transferir') ||
        command.contains('enviar dinheiro') ||
        command.contains('mandar dinheiro');

    if (dangerousAction) return true;

    final ambiguousReference = command == 'abre isso' ||
        command == 'abrir isso' ||
        command == 'abre esse' ||
        command == 'abre essa' ||
        command == 'vai nele' ||
        command == 'vai nessa' ||
        command == 'manda isso' ||
        command == 'envia isso' ||
        command == 'faz isso' ||
        command == 'faca isso';

    return ambiguousReference && _shortMemory.isEmpty;
  }

  String _buildSafetyQuestion(String text) {
    final command = _normalize(text);

    if (command.contains('apagar') ||
        command.contains('deletar') ||
        command.contains('excluir') ||
        command.contains('remover tudo') ||
        command.contains('limpar tudo') ||
        command.contains('formatar') ||
        command.contains('desinstalar')) {
      return 'Luiz, essa ação pode apagar ou remover algo. Para sua segurança, me diga exatamente o que você quer apagar ou remover antes de eu continuar.';
    }

    if (command.contains('comprar') ||
        command.contains('pagar') ||
        command.contains('transferir') ||
        command.contains('enviar dinheiro') ||
        command.contains('mandar dinheiro')) {
      return 'Luiz, essa ação envolve dinheiro ou compra. Eu não vou executar direto. Confirme os detalhes com clareza antes de continuar.';
    }

    if (command.contains('manda') || command.contains('envia')) {
      return 'Luiz, para enviar algo com segurança, preciso que você confirme o destinatário e o conteúdo exato.';
    }

    return 'Luiz, esse comando ficou ambíguo. Me diga exatamente o que você quer que eu faça para eu executar com segurança.';
  }

  String _cleanMeganOutput(String text) {
    var clean = text;

    // Corrige respostas que chegam com caracteres escapados da IA/API,
    // como "\n\n", "\n" e marcações Markdown aparecendo no chat.
    clean = clean.replaceAll('\\r\\n', '\n');
    clean = clean.replaceAll('\\n', '\n');
    clean = clean.replaceAll('\\t', ' ');
    clean = clean.replaceAll('\r\n', '\n');
    clean = clean.replaceAll('\r', '\n');

    // Remove marcação visual que estava aparecendo crua no chat.
    clean = clean.replaceAll(RegExp(r'\*\*(.*?)\*\*'), r'$1');
    clean = clean.replaceAll(RegExp(r'__(.*?)__'), r'$1');
    clean = clean.replaceAll(RegExp(r'`{1,3}'), '');

    // Normaliza quebras excessivas sem juntar parágrafos importantes.
    clean = clean.replaceAll(RegExp(r'[ \t]+'), ' ');
    clean = clean.replaceAll(RegExp(r'\n[ \t]+'), '\n');
    clean = clean.replaceAll(RegExp(r'[ \t]+\n'), '\n');
    clean = clean.replaceAll(RegExp(r'\n{3,}'), '\n\n');

    return clean.trim();
  }

  void _add(bool user, String text) {
    if (!mounted) return;

    final safeText = user ? text.trim() : _cleanMeganOutput(text);
    if (safeText.isEmpty) return;

    _safeSetState(() => _messages.add(_Message(user, safeText)));
  }

  void _scheduleConversationIdleClose() {
    _conversationIdleTimer?.cancel();

    if (!_commandMode || !_listening || _manualStop) return;

    _conversationIdleTimer = Timer(const Duration(seconds: 20), () async {
      if (!mounted || _manualStop || !_listening || _processingVoiceCommand || _isSpeechBlockedByTts()) return;

      _commandMode = false;
      _wakeMessageShown = false;
      _pendingCommand = '';
      _commandWindowTimer?.cancel();
      _commandDebounceTimer?.cancel();

      final answer = _randomFrom([
        'Vou encerrar por enquanto. É só me chamar de novo.',
        'Certo, Luiz. Vou ficar em espera. Quando precisar, diga ok Megan.',
        'Tudo bem, Luiz. Vou encerrar a conversa agora, mas continuo por aqui quando você chamar.',
      ]);

      _setVoiceStatus('Conversa encerrada. Diga ok Megan quando precisar.');
      _add(false, answer);
      await _say(answer);
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


  bool _isHealthCommand(String text) {
    final command = _normalize(text);

    return command.contains('saude') ||
        command.contains('saúde') ||
        command.contains('health') ||
        command.contains('relogio') ||
        command.contains('relógio') ||
        command.contains('health connect') ||
        command.contains('passos') ||
        command.contains('batimento') ||
        command.contains('frequencia cardiaca') ||
        command.contains('frequência cardíaca') ||
        command.contains('sono') ||
        command.contains('dormi') ||
        command.contains('oxigenacao') ||
        command.contains('oxigenação') ||
        command.contains('calorias') ||
        command.contains('atleta') ||
        command.contains('desempenho');
  }

  Future<bool> _tryHandleHealthCommand(String text) async {
    if (!_isHealthCommand(text)) return false;

    final command = _normalize(text);
    final athleteMode = command.contains('atleta') ||
        command.contains('desempenho') ||
        command.contains('treino') ||
        command.contains('performance');

    final data = await _readHealthWithFallback();
    final answer = _applyResponseStyle(_humanizeChatAnswer(
      _buildHealthGuidance(data, athleteMode: athleteMode),
    ));

    _add(false, answer);
    _rememberConversation(text.trim(), answer);
    await _say(answer);
    return true;
  }

  String _buildHealthGuidance(Map<String, dynamic> data, {required bool athleteMode}) {
    final source = (data['source'] ?? '').toString();
    final authorized = data['authorized'] == true;
    final summaryRaw = data['summary'];
    final summary = summaryRaw is Map ? Map<String, dynamic>.from(summaryRaw) : <String, dynamic>{};
    final categoriesRaw = data['categories'];
    final categories = categoriesRaw is Map ? Map<String, dynamic>.from(categoriesRaw) : <String, dynamic>{};
    final alertsRaw = data['alerts'];
    final alerts = alertsRaw is List ? alertsRaw.map((e) => e.toString()).where((e) => e.trim().isNotEmpty).toList() : <String>[];
    final guidanceRaw = data['guidance'];
    final apiGuidance = guidanceRaw is List ? guidanceRaw.map((e) => e.toString()).where((e) => e.trim().isNotEmpty).toList() : <String>[];
    final availableRaw = data['available'];
    final available = availableRaw is List ? availableRaw.map((e) => e.toString()).where((e) => e.trim().isNotEmpty).toList() : <String>[];
    final unavailableRaw = data['unavailable'];
    final unavailable = unavailableRaw is List ? unavailableRaw.map((e) => e.toString()).where((e) => e.trim().isNotEmpty).toList() : <String>[];
    final message = (data['message'] ?? '').toString().trim();
    final error = (data['error'] ?? '').toString().trim();

    if (!authorized && source != 'fallback_safe') {
      final detail = error.isNotEmpty ? ' Detalhe técnico: $error' : '';
      return 'Luiz, ainda não consegui acessar dados reais do Health Connect. Confira se o Health Connect está instalado, se o relógio está sincronizando e se as permissões de saúde foram liberadas para a Megan.$detail';
    }

    if (source == 'fallback_safe' && !authorized) {
      return message.isNotEmpty
          ? '$message Depois que o Health Connect estiver conectado, eu consigo analisar passos, sono, batimentos e outros dados com mais precisão.'
          : 'Luiz, estou no modo seguro de saúde. Conecte o Health Connect para eu trazer dados reais do relógio.';
    }

    final activity = _healthMap(categories['activity']);
    final body = _healthMap(categories['body']);
    final nutrition = _healthMap(categories['nutrition']);
    final vitals = _healthMap(categories['vitals']);
    final sleepMap = _healthMap(categories['sleep']);

    final steps = _healthNumber(summary['steps']).round();
    final heart = _healthNumber(summary['heartRate']).round();
    final sleep = _healthNumber(summary['sleepHours']);
    final calories = _healthNumber(summary['calories']).round();
    final distanceMeters = _healthNumber(summary['distance']);
    final distanceKm = _healthNumber(summary['distanceKm']) > 0
        ? _healthNumber(summary['distanceKm'])
        : distanceMeters / 1000;
    final spo2 = _healthNumber(summary['spo2']);
    final temperature = _healthNumber(summary['temperature']);
    final glucose = _healthNumber(summary['glucose']);
    final weight = _healthNumber(summary['weight']);
    final height = _healthNumber(summary['height']);
    final bodyFat = _healthNumber(summary['bodyFat']);
    final workouts = _healthNumber(summary['workouts']).round();
    final systolic = _healthNumber(summary['bloodPressureSystolic']).round();
    final diastolic = _healthNumber(summary['bloodPressureDiastolic']).round();

    final power = _healthNumber(activity['power']);
    final speed = _healthNumber(activity['speed']);
    final basal = _healthNumber(body['basalMetabolicRate']);
    final hydration = _healthNumber(nutrition['hydration']);
    final nutritionValue = _healthNumber(nutrition['nutrition']);
    final respiratoryRate = _healthNumber(vitals['respiratoryRate']);
    final sleepFromCategory = _healthNumber(sleepMap['sleepHours']);
    final sleepHours = sleep > 0 ? sleep : sleepFromCategory;

    final parts = <String>[];

    parts.add(athleteMode
        ? 'Luiz, analisei seu desempenho com base nos dados disponíveis do Health Connect.'
        : 'Luiz, analisei seus dados de saúde disponíveis no Health Connect.');

    final metrics = <String>[];
    if (steps > 0) metrics.add('$steps passos');
    if (heart > 0) metrics.add('batimento médio de $heart bpm');
    if (sleepHours > 0) metrics.add('${sleepHours.toStringAsFixed(1)} horas de sono');
    if (calories > 0) metrics.add('$calories calorias ativas');
    if (distanceKm > 0) metrics.add('${distanceKm.toStringAsFixed(2)} km');
    if (workouts > 0) metrics.add('$workouts exercício(s) registrado(s)');
    if (power > 0) metrics.add('potência em ${power.toStringAsFixed(0)}');
    if (speed > 0) metrics.add('velocidade em ${speed.toStringAsFixed(1)}');
    if (weight > 0) metrics.add('peso registrado em ${weight.toStringAsFixed(1)} kg');
    if (height > 0) metrics.add('altura registrada em ${height.toStringAsFixed(2)} m');
    if (bodyFat > 0) metrics.add('gordura corporal em ${bodyFat.toStringAsFixed(1)}%');
    if (basal > 0) metrics.add('metabolismo basal em ${basal.toStringAsFixed(0)} kcal');
    if (hydration > 0) metrics.add('hidratação registrada em ${hydration.toStringAsFixed(0)} ml');
    if (nutritionValue > 0) metrics.add('nutrição registrada');
    if (spo2 > 0) metrics.add('oxigenação em ${spo2.toStringAsFixed(0)}%');
    if (temperature > 0) metrics.add('temperatura em ${temperature.toStringAsFixed(1)}°C');
    if (glucose > 0) metrics.add('glicemia registrada em ${glucose.toStringAsFixed(0)}');
    if (systolic > 0 || diastolic > 0) metrics.add('pressão arterial ${systolic > 0 ? systolic : '--'}/${diastolic > 0 ? diastolic : '--'}');
    if (respiratoryRate > 0) metrics.add('ritmo respiratório em ${respiratoryRate.toStringAsFixed(0)} rpm');

    if (metrics.isEmpty) {
      parts.add('Ainda não encontrei métricas suficientes sincronizadas. Pode levar alguns minutos para o relógio enviar os dados ao Health Connect.');
    } else {
      parts.add('Resumo completo disponível: ${metrics.join(', ')}.');
    }

    if (available.isNotEmpty) {
      parts.add('Dados encontrados: ${available.join(', ')}.');
    }

    if (unavailable.isNotEmpty) {
      parts.add('Dados liberados, mas ainda não retornados pelo Health Connect agora: ${unavailable.join(', ')}. Isso normalmente significa que o relógio, Samsung Health ou Google Fit ainda não registraram esses dados, mesmo com a permissão ativa.');
    }

    final guidance = <String>[];

    if (steps > 0 && steps < 3000) {
      guidance.add('Sua atividade está baixa; uma caminhada leve pode ajudar, se você estiver se sentindo bem.');
    } else if (steps >= 8000) {
      guidance.add('Seu volume de passos está muito bom; mantenha hidratação e recuperação.');
    }

    if (sleepHours > 0 && sleepHours < 5) {
      guidance.add('Seu sono parece curto; vale priorizar descanso hoje.');
    } else if (sleepHours >= 7) {
      guidance.add('Seu sono parece em uma faixa boa para recuperação.');
    }

    if (heart > 100) {
      guidance.add('O batimento médio apareceu elevado. Observe o contexto: treino, estresse, cafeína ou pouco sono podem influenciar.');
    }

    if (spo2 > 0 && spo2 < 92) {
      guidance.add('A oxigenação apareceu baixa. Se isso se repetir ou vier com falta de ar, procure atendimento médico.');
    }

    if (temperature > 37.5) {
      guidance.add('A temperatura apareceu elevada. Se houver sintomas ou persistência, fale com um profissional de saúde.');
    }

    if (systolic >= 140 || diastolic >= 90) {
      guidance.add('A pressão apareceu elevada. Confirme a medição e procure orientação profissional se persistir.');
    }

    if (athleteMode) {
      if (steps > 0 || calories > 0 || distanceMeters > 0 || workouts > 0) {
        guidance.add('Para performance, o ideal agora é equilibrar treino, sono, alimentação e recuperação, não apenas aumentar volume.');
      } else {
        guidance.add('Para análise atlética melhor, preciso que o relógio envie treino, passos, frequência cardíaca e sono ao Health Connect.');
      }
    }

    if (alerts.isNotEmpty) {
      guidance.add('Pontos de atenção detectados: ${alerts.join(', ')}.');
    }

    for (final item in apiGuidance) {
      if (!guidance.contains(item)) guidance.add(item);
    }

    if (guidance.isEmpty) {
      guidance.add('Não vi nenhum alerta forte nos dados disponíveis. Continue acompanhando a tendência, porque um dado isolado não fecha conclusão.');
    }

    parts.add(guidance.join(' '));
    parts.add('Isso é uma orientação geral, não diagnóstico médico. Se algo estiver fora do normal, persistente ou com sintomas, procure um médico.');

    return parts.join(' ');
  }

  Map<String, dynamic> _healthMap(dynamic value) {
    return value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
  }

  double _healthNumber(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString().replaceAll(',', '.')) ?? 0;
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


  bool _isFileGenerationCommand(String text) {
    final command = _normalize(text);
    final hasGenerate = command.contains('gerar') ||
        command.contains('gere') ||
        command.contains('criar') ||
        command.contains('crie') ||
        command.contains('montar') ||
        command.contains('monte');

    final hasFile = command.contains('arquivo') ||
        command.contains('baixar') ||
        command.contains('download') ||
        command.contains('pdf') ||
        command.contains('docx') ||
        command.contains('word') ||
        command.contains('txt') ||
        command.contains('texto') ||
        command.contains('json') ||
        command.contains('csv') ||
        command.contains('zip');

    return hasGenerate && hasFile;
  }

  String _detectGeneratedFileType(String text) {
    final command = _normalize(text);

    if (command.contains('pdf')) return 'pdf';
    if (command.contains('docx') || command.contains('word')) return 'docx';
    if (command.contains('zip')) return 'zip';
    if (command.contains('json')) return 'json';
    if (command.contains('csv') || command.contains('planilha simples')) return 'csv';
    if (command.contains('markdown') || command.contains('md')) return 'md';
    if (command.contains('txt') || command.contains('texto')) return 'txt';

    return 'txt';
  }

  String _buildGeneratedFileTitle(String text, String type) {
    var clean = _cleanMeganOutput(text)
        .replaceAll(RegExp(r'\b(gerar|gere|criar|crie|monte|montar)\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\b(um|uma|arquivo|para baixar|download|em pdf|pdf|docx|word|txt|texto|json|csv|zip)\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    if (clean.length > 70) clean = clean.substring(0, 70).trim();
    if (clean.isEmpty) clean = 'Arquivo Megan Life';

    return clean;
  }

  Future<bool> _tryGenerateDownloadableFile(String text) async {
    if (!_isFileGenerationCommand(text)) return false;

    final type = _detectGeneratedFileType(text);
    final title = _buildGeneratedFileTitle(text, type);

    _setVoiceStatus('Gerando arquivo ${type.toUpperCase()} para baixar...');

    final contentPrompt = '''
Crie o conteúdo completo para um arquivo do tipo $type.
Título sugerido: $title
Pedido original do Luiz: ${text.trim()}

Responda somente com o conteúdo que deve entrar no arquivo, sem explicar o processo.
''';

    final content = await _ai.chat(contentPrompt);
    final result = await _ai.generateFile(
      type: type,
      title: title,
      content: _cleanMeganOutput(content),
      fileName: title,
    );

    if (result['ok'] == true) {
      final url = (result['url'] ?? '').toString();
      final fileName = (result['fileName'] ?? '').toString();
      final answer = url.isNotEmpty
          ? 'Arquivo gerado: $fileName\nLink para baixar:\n$url'
          : 'Arquivo gerado: $fileName';
      _add(false, answer);
      _rememberConversation(text.trim(), answer);
      await _say('Arquivo gerado com sucesso. O link para baixar está na tela.');
      return true;
    }

    final error = (result['message'] ?? 'Não consegui gerar o arquivo agora.').toString();
    _add(false, error);
    _rememberConversation(text.trim(), error);
    await _say(error);
    return true;
  }

  Future<void> _processAndExecute(String text, {required bool fromVoice}) async {
    if (text.trim().isEmpty || _loading) return;

    final cleanText = text.trim();

    // Wake word isolada não pode ser enviada para agentes nem abrir app.
    // Ela apenas inicia/renova o modo conversa da Megan.
    if (_isWakeOnlyCommand(cleanText)) {
      _controller.clear();
      _pendingCommand = '';
      await _enterCommandMode();
      return;
    }

    _proactiveAgent.registerInteraction();

    _conversationIdleTimer?.cancel();
    _add(true, cleanText);

    if (!mounted) return;
    _safeSetState(() => _loading = true);

    try {
      if (_isEndConversationCommand(cleanText)) {
        _commandMode = false;
        _wakeMessageShown = false;
        _pendingCommand = '';
        _commandWindowTimer?.cancel();
        _commandDebounceTimer?.cancel();
        _conversationIdleTimer?.cancel();

        final answer = _randomFrom([
          'Tudo bem, Luiz. Continuo ouvindo quando você chamar.',
          'Perfeito, Luiz. Vou ficar em espera. Quando precisar, é só me chamar.',
          'Combinado, Luiz. Vou encerrar essa conversa por enquanto.',
        ]);

        _add(false, answer);
        await _say(answer);
        return;
      }

      if (_isPreferenceCommand(cleanText)) {
        final preferenceAnswer = await _applyPreferenceCommand(cleanText);
        if (preferenceAnswer != null) {
          final answer = _humanizeChatAnswer(preferenceAnswer);
          _add(false, answer);
          _rememberConversation(cleanText, answer);
          await _say(answer);
          return;
        }
      }

      // 📁 Geração de arquivos para baixar (PDF, DOCX, TXT, JSON, CSV e ZIP).
      // Entra antes dos agentes para não ser confundido com chat comum.
      final handledByFileGeneration = await _tryGenerateDownloadableFile(cleanText);
      if (handledByFileGeneration) return;

      // ❤️ 6.6 — Saúde / Relógio / Health Connect.
      // Trata comandos naturais de saúde antes dos fluxos de apps para evitar
      // que palavras como relógio, passos ou treino sejam confundidas com chat genérico.
      final handledByHealth = await _tryHandleHealthCommand(cleanText);
      if (handledByHealth) return;

      // 💬 6.0.1.3 — Modo comunicação protegida.
      // Apps de comunicação não entram no modo mídia universal para preservar áudio de mensagens.
      final handledByCommunicationMode = await _tryOpenCommunicationAppSafely(cleanText);
      if (handledByCommunicationMode) return;

      // 🎬 6.0.1.2 — Modo mídia universal.
      // Qualquer app externo aberto pela Megan pausa microfone/TTS ANTES de abrir,
      // exceto comunicação, que agora tem fluxo próprio protegido.
      final handledByExternalAppMode = await _tryOpenExternalAppSafely(cleanText);
      if (handledByExternalAppMode) return;

      // 🎬 Backup do modo mídia conhecido, preservado para comandos específicos de mídia.
      final handledByMediaMode = await _tryOpenMediaCommandSafely(cleanText);
      if (handledByMediaMode) return;

      // 🧠 5.0.9 — Inteligência adaptativa segura.
      // Registra padrões de uso e sugere automação sem bloquear o fluxo atual.
      final adaptiveSuggestion = await _adaptiveAgent.registerAndSuggest(cleanText);

      if (adaptiveSuggestion != null && !_waitingAutonomyConfirm) {
        final answer = _adaptiveAgent.buildSuggestionText(adaptiveSuggestion);
        _add(false, answer);
        _rememberConversation(cleanText, answer);
        await _say(answer);
        // Não retorna aqui: a ação normal continua para manter o que já funciona.
      }

      // 🧠 5.0.8 — Autonomia real com confirmação.
      // Esta camada só entra em intenções amplas. Comandos diretos continuam no fluxo 5.0.7/5.0.6.
      if (_waitingAutonomyConfirm) {
        final autonomyDecision = _autonomyAgent.readConfirmation(cleanText);

        if (autonomyDecision == AutonomyConfirmation.yes) {
          final plan = _pendingAutonomyPlan;
          final originalCommand = _pendingAutonomyCommand;

          _waitingAutonomyConfirm = false;
          _pendingAutonomyPlan = null;
          _pendingAutonomyCommand = '';

          if (plan == null || plan.isEmpty) {
            final answer = 'Luiz, não encontrei um plano pendente para executar.';
            _add(false, answer);
            _rememberConversation(cleanText, answer);
            await _say(answer);
            return;
          }

          final commands = _autonomyAgent.buildExecutableCommands(
            plan: plan,
            originalCommand: originalCommand,
          );

          if (commands.isEmpty) {
            final answer = _autonomyAgent.buildMissingInfoText(plan);
            _add(false, answer);
            _rememberConversation(cleanText, answer);
            await _say(answer);
            return;
          }

          final intro = 'Certo, Luiz. Vou executar o plano com segurança.';
          _add(false, intro);
          _rememberConversation(cleanText, intro);
          await _say(intro);

          var executedAnyStep = false;

          for (final stepCommand in commands) {
            final executedStep = await _decisionAgent.executeMulti(
              context: context,
              command: stepCommand,
              preferredNavigationApp: _preferredNavigationApp,
              say: (answer) => _say(answer),
              addAssistantMessage: (answer) {
                _add(false, answer);
                _rememberConversation(stepCommand, answer);
              },
              rememberIntent: (intent, target) => _rememberSmartIntent(intent, target),
              setLastCommand: (value) {
                if (mounted) _safeSetState(() => _lastCommandText = value);
              },
              executeFallback: (part) async {
                final handledBySystem = await _runDirectSystemCommand(part);
                if (handledBySystem) return true;

                final handledBySmartIntent = await _tryHandleSmartIntent(part);
                return handledBySmartIntent;
              },
            );

            if (executedStep) {
              executedAnyStep = true;
              continue;
            }

            final executedSingle = await _decisionAgent.execute(
              context: context,
              command: stepCommand,
              preferredNavigationApp: _preferredNavigationApp,
              say: (answer) => _say(answer),
              addAssistantMessage: (answer) {
                _add(false, answer);
                _rememberConversation(stepCommand, answer);
              },
              rememberIntent: (intent, target) => _rememberSmartIntent(intent, target),
              setLastCommand: (value) {
                if (mounted) _safeSetState(() => _lastCommandText = value);
              },
            );

            if (executedSingle) {
              executedAnyStep = true;
              continue;
            }

            final handledFallback = await _tryHandleSmartIntent(stepCommand);
            if (handledFallback) executedAnyStep = true;
          }

          if (!executedAnyStep) {
            final answer = _autonomyAgent.buildMissingInfoText(plan);
            _add(false, answer);
            _rememberConversation(cleanText, answer);
            await _say(answer);
          }

          return;
        }

        if (autonomyDecision == AutonomyConfirmation.no) {
          _waitingAutonomyConfirm = false;
          _pendingAutonomyPlan = null;
          _pendingAutonomyCommand = '';

          final answer = 'Tudo bem, Luiz. Cancelei esse plano e mantive tudo como está.';
          _add(false, answer);
          _rememberConversation(cleanText, answer);
          await _say(answer);
          return;
        }

        final answer = 'Luiz, quer que eu execute esse plano agora? Responda sim ou cancelar.';
        _add(false, answer);
        _rememberConversation(cleanText, answer);
        await _say(answer);
        return;
      }

      final autonomyPlan = _autonomyAgent.analyze(cleanText);

      if (!autonomyPlan.isEmpty) {
        final planText = _autonomyAgent.buildPlanText(autonomyPlan);

        _pendingAutonomyPlan = autonomyPlan;
        _pendingAutonomyCommand = cleanText;
        _waitingAutonomyConfirm = true;

        _add(false, planText);
        _rememberConversation(cleanText, planText);
        await _say(planText);
        return;
      }

      // 🚀 5.0.7 — Multi-ação segura primeiro.
      // Mantém a execução 5.0.6 e o SmartIntent antigo como fallback.
      final executedMulti = await _decisionAgent.executeMulti(
        context: context,
        command: cleanText,
        preferredNavigationApp: _preferredNavigationApp,
        say: (answer) => _say(answer),
        addAssistantMessage: (answer) {
          _add(false, answer);
          _rememberConversation(cleanText, answer);
        },
        rememberIntent: (intent, target) => _rememberSmartIntent(intent, target),
        setLastCommand: (value) {
          if (mounted) _safeSetState(() => _lastCommandText = value);
        },
        executeFallback: (part) async {
          final handledBySystem = await _runDirectSystemCommand(part);
          if (handledBySystem) return true;

          final handledBySmartIntent = await _tryHandleSmartIntent(part);
          return handledBySmartIntent;
        },
      );

      if (executedMulti) {
        if (_isCommunicationAppCommand(cleanText)) {
          await _enterCommunicationMode(sourceCommand: cleanText);
        } else if (_isMediaCommand(cleanText) || _isExternalAppCommand(cleanText)) {
          await _enterMediaMode(sourceCommand: cleanText);
        }
        return;
      }

      // 🧠 5.0.6 — Execução total segura pelo DecisionAgent.
      // Mantém o SmartIntent antigo como fallback para não quebrar WhatsApp,
      // banco, contexto e qualquer função que já estava funcionando.
      final executedByDecisionAgent = await _decisionAgent.execute(
        context: context,
        command: cleanText,
        preferredNavigationApp: _preferredNavigationApp,
        say: (answer) => _say(answer),
        addAssistantMessage: (answer) {
          _add(false, answer);
          _rememberConversation(cleanText, answer);
        },
        rememberIntent: (intent, target) => _rememberSmartIntent(intent, target),
        setLastCommand: (value) {
          if (mounted) _safeSetState(() => _lastCommandText = value);
        },
      );

      if (executedByDecisionAgent) {
        if (_isCommunicationAppCommand(cleanText)) {
          await _enterCommunicationMode(sourceCommand: cleanText);
        } else if (_isMediaCommand(cleanText) || _isExternalAppCommand(cleanText)) {
          await _enterMediaMode(sourceCommand: cleanText);
        }
        return;
      }

      // 🔒 Fallback antigo preservado: WhatsApp, banco, contexto e demais ações.
      final handledBySmartIntent = await _tryHandleSmartIntent(cleanText);
      if (handledBySmartIntent) {
        if (_isCommunicationAppCommand(cleanText)) {
          await _enterCommunicationMode(sourceCommand: cleanText);
        } else if (_isMediaCommand(cleanText) || _isExternalAppCommand(cleanText)) {
          await _enterMediaMode(sourceCommand: cleanText);
        }
        return;
      }

      if (_needsSafetyCheck(cleanText)) {
        final answer = _buildSafetyQuestion(cleanText);
        _add(false, answer);
        _rememberConversation(cleanText, answer);
        await _say(answer);
        return;
      }

      final handledBySystem = await _runDirectSystemCommand(cleanText);
      if (handledBySystem) return;

      final contextualText = _contextAgent.buildContext(
        currentText: cleanText,
        memory: _shortMemory,
      );
      final result = await _ai.process(contextualText);

      final List<dynamic> actions = result['actions'] is List
          ? List<dynamic>.from(result['actions'])
          : [];

      final String response = (result['response'] ?? '').toString();

      if (actions.isEmpty) {
        final rawAnswer = response.isNotEmpty ? response : await _ai.chat(contextualText);
        final answer = _applyResponseStyle(_humanizeChatAnswer(rawAnswer));
        _add(false, answer);
        _rememberConversation(cleanText, answer);
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
          final rawAnswer = await _ai.chat(contextualText);
          final answer = _applyResponseStyle(_humanizeChatAnswer(rawAnswer));
          _add(false, answer);
          _rememberConversation(cleanText, answer);
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
                ? _randomFrom([
                    'Abrindo $value.',
                    'Certo, abrindo $value.',
                    'Pronto, vou abrir $value.',
                  ])
                : 'Não consegui abrir $value. Verifique se o app está instalado.';

            _add(false, answer);
            _rememberConversation(cleanText, answer);
            await _say(answer);

            await Future.delayed(const Duration(milliseconds: 900));
          } else if (type == 'navigate') {
            if (value.isEmpty) continue;

            await _nav.openNavigationChoice(context, value);

            final answer = _preferredNavigationApp == 'waze'
                ? 'Preparei a navegação para $value. Como você prefere Waze, pode escolher Waze na tela.'
                : _preferredNavigationApp == 'maps'
                    ? 'Preparei a navegação para $value. Como você prefere Google Maps, pode escolher Google Maps na tela.'
                    : _randomFrom([
                        'Preparei a navegação para $value. Escolha Waze ou Google Maps.',
                        'Certo, Luiz. Deixei a navegação pronta para $value. Agora escolha Waze ou Google Maps.',
                        'Pronto. Preparei a rota para $value. Você pode escolher Waze ou Google Maps.',
                      ]);

            _add(false, answer);
            _rememberConversation(cleanText, answer);
            await _say(answer);

            await Future.delayed(const Duration(milliseconds: 900));
          } else if (type == 'health') {
            final answer = _applyResponseStyle(_humanizeChatAnswer(
              _buildHealthGuidance(await _readHealthWithFallback(), athleteMode: false),
            ));
            _add(false, answer);
            _rememberConversation(cleanText, answer);
            await _say(answer);

            await Future.delayed(const Duration(milliseconds: 900));
          } else if (type == 'athlete') {
            final answer = _applyResponseStyle(_humanizeChatAnswer(
              _buildHealthGuidance(await _readHealthWithFallback(), athleteMode: true),
            ));
            _add(false, answer);
            _rememberConversation(cleanText, answer);
            await _say(answer);

            await Future.delayed(const Duration(milliseconds: 900));
          } else if (type == 'feedback') {
            if (value.isEmpty) continue;

            final rawAnswer = await _ai.sendFeedback(value);
            final answer = _applyResponseStyle(_humanizeChatAnswer(rawAnswer));
            _add(false, answer);
            _rememberConversation(cleanText, answer);
            await _say(answer);

            await Future.delayed(const Duration(milliseconds: 900));
          } else if (type == 'copilot_plan') {
            final answer = _ai.buildCopilotPlan(value.isEmpty ? cleanText : value);
            _add(false, answer);
            _rememberConversation(cleanText, answer);
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
        final answer = _applyResponseStyle(_humanizeChatAnswer(response));
        _add(false, answer);
        _rememberConversation(cleanText, answer);
        await _say(answer);
      }
    } catch (e) {
      final answer = 'Erro: $e';
      _add(false, answer);
      await _say(answer);
    } finally {
      if (!mounted) return;
      _safeSetState(() => _loading = false);

      if (fromVoice && !_mediaMode && !_manualStop && _listening) {
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
    _safeSetState(() => _loading = true);

    try {
      final answer = await _files.analyzeFile(file);
      _add(false, answer);
      await _say('Arquivo analisado. Veja o relatório na tela.');
    } catch (e) {
      _add(false, 'Não consegui analisar o arquivo: $e');
    } finally {
      if (!mounted) return;
      _safeSetState(() => _loading = false);
    }
  }

  Future<void> _toggleListen() async {
    if (_mediaMode) {
      await _exitMediaMode();
      return;
    }

    if (_listening) {
      _manualStop = true;
      _restartTimer?.cancel();
      _commandWindowTimer?.cancel();
      _commandDebounceTimer?.cancel();
      _ttsResumeTimer?.cancel();
      _conversationIdleTimer?.cancel();
      await _speech.stop();

      if (!mounted) return;
      _safeSetState(() {
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

    _safeSetState(() {
      _mediaMode = false;
      _listening = true;
      _manualStop = false;
      _commandMode = false;
      _wakeMessageShown = false;
    });

    _setVoiceStatus('Microfone ativo. Diga: ok Megan.');
    _scheduleRestart(delayMs: 400);
  }

  Future<void> _startListening() async {
    if (_mediaMode ||
        _communicationMode ||
        _backgroundWakeSafeMode ||
        !_appInForeground ||
        !_speechReady ||
        !_listening ||
        _manualStop ||
        _processingVoiceCommand ||
        _startingListen ||
        _isMicrophoneRestartBlocked() ||
        _isSpeechBlockedByTts()) {
      return;
    }

    _startingListen = true;

    try {
      if (_speech.isListening) {
        await _speech.stop();
        await Future.delayed(const Duration(milliseconds: 420));
      }

      if (!mounted ||
          !_listening ||
          _manualStop ||
          _isMicrophoneRestartBlocked() ||
          _isSpeechBlockedByTts()) {
        return;
      }

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

      if (mounted && !_mediaMode && !_manualStop) {
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

    if (_mediaMode || _communicationMode || _backgroundWakeSafeMode || !_appInForeground) {
      return;
    }

    if (_processingVoiceCommand ||
        _isMicrophoneRestartBlocked() ||
        _isSpeechBlockedByTts() ||
        _looksLikeMeganEcho(words)) {
      return;
    }

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

    if (!_manualStop && !_mediaMode && !_communicationMode && _appInForeground && !_backgroundWakeSafeMode) {
      _resumeListeningAfterTts();
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
    if (_isWakeOnlyCommand(command)) {
      _enterCommandMode();
      return;
    }

    final cleanCommand = _extractWakeCommand(command).trim();
    if (cleanCommand.length < 3) return;

    _conversationIdleTimer?.cancel();
    _pendingCommand = cleanCommand;
    _controller.text = cleanCommand;
    _setVoiceStatus('Comando capturado: $cleanCommand');
    if (mounted) _safeSetState(() => _lastCommandText = cleanCommand);

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
      if (mounted) _safeSetState(() => _lastCommandText = cleanCommand);

      await _processAndExecute(cleanCommand, fromVoice: true);
    } finally {
      _processingVoiceCommand = false;
      _blockMicrophoneRestart(const Duration(milliseconds: 650));
      if (!_mediaMode &&
          !_communicationMode &&
          !_manualStop &&
          !_backgroundWakeSafeMode &&
          _appInForeground &&
          _listening) {
        _resumeListeningAfterTts();
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

  bool _isWakeOnlyCommand(String text) {
    final normalized = _normalize(text);
    if (normalized.isEmpty) return false;

    final wake = _detectWakeWord(normalized);
    if (!wake.detected) return false;

    final command = wake.command.trim();
    if (command.isNotEmpty) return false;

    final words = normalized.split(' ').where((word) => word.trim().isNotEmpty).toList();

    if (words.length == 1) {
      return words.any((word) => _wordClose(word, 'megan'));
    }

    if (words.length == 2) {
      final first = words[0];
      final second = words[1];
      final firstIsWake = _wordClose(first, 'ok') || _wordClose(first, 'oi') || first == 'ola';
      final secondIsMegan = _wordClose(second, 'megan');
      return firstIsWake && secondIsMegan;
    }

    return false;
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
    _safeSetState(() => _voiceReply = value);

    _add(false, value ? 'Voz ativada.' : 'Voz desativada.');
  }

  String _currentStateLabel() {
    if (_mediaMode) return 'Modo mídia';
    if (_communicationMode) return 'Comunicação';
    if (_isSpeechBlockedByTts()) return 'Falando';
    if (_loading || _processingVoiceCommand) return 'Processando';
    if (_listening && !_manualStop) return _commandMode ? 'Conversa ativa' : 'Ouvindo';
    return 'Em espera';
  }

  IconData _currentStateIcon() {
    if (_mediaMode) return Icons.play_circle;
    if (_communicationMode) return Icons.chat_bubble_outline;
    if (_isSpeechBlockedByTts()) return Icons.record_voice_over;
    if (_loading || _processingVoiceCommand) return Icons.psychology;
    if (_listening && !_manualStop) return _commandMode ? Icons.forum : Icons.hearing;
    return Icons.bedtime;
  }

  Widget _statusChip(String label, String value, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF161A2A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withOpacity(.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 6),
          Text(
            '$label: ',
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withOpacity(.68),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatePanel() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF0B0F1A),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_currentStateIcon(), size: 18),
              const SizedBox(width: 8),
              Text(
                'Painel de estado — ${_currentStateLabel()}',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _statusChip('Presença', _presenceActive ? 'ativa' : 'parada', Icons.shield_moon),
              _statusChip('Microfone', _mediaMode ? 'modo mídia' : _listening && !_manualStop ? 'ativo' : 'pausado', Icons.mic),
              _statusChip('Voz', _voiceReply ? 'ativa' : 'desativada', Icons.volume_up),
              _statusChip('Modo', _mediaMode ? 'mídia universal' : _commandMode ? 'conversa' : 'wake word', Icons.hub),
              _statusChip('IA', _loading ? 'processando' : 'pronta', Icons.psychology),
              _statusChip('Navegação', _preferredNavigationApp, Icons.navigation),
              _statusChip('Resposta', _responseStyle, Icons.tune),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Último comando: $_lastCommandText',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              height: 1.25,
              color: Colors.white.withOpacity(.78),
            ),
          ),
        ],
      ),
    );
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

  Color get _premiumAccent {
    if (_loading) return const Color(0xFF38BDF8);
    if (_commandMode) return const Color(0xFF22C55E);
    if (_mediaMode || _communicationMode) return const Color(0xFFF59E0B);
    if (_listening && !_manualStop) return const Color(0xFF7C3AED);
    return const Color(0xFF64748B);
  }

  String get _premiumStateLabel {
    if (_loading) return 'Processando';
    if (_mediaMode) return 'Modo mídia';
    if (_communicationMode) return 'Modo comunicação';
    if (_commandMode) return 'Em conversa';
    if (_listening && !_manualStop) return 'Ouvindo';
    return 'Em espera';
  }

  IconData get _premiumStateIcon {
    if (_loading) return Icons.auto_awesome;
    if (_mediaMode) return Icons.play_circle_fill;
    if (_communicationMode) return Icons.chat_bubble;
    if (_commandMode) return Icons.record_voice_over;
    if (_listening && !_manualStop) return Icons.mic;
    return Icons.mic_off;
  }

  Widget _premiumTopCard() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF171A2C),
            const Color(0xFF0B1020),
            _premiumAccent.withOpacity(.18),
          ],
        ),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white.withOpacity(.08)),
        boxShadow: [
          BoxShadow(
            color: _premiumAccent.withOpacity(.16),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _premiumAccent.withOpacity(.20),
                  border: Border.all(color: _premiumAccent.withOpacity(.55)),
                ),
                child: Icon(_premiumStateIcon, color: Colors.white, size: 28),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Megan Life',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -.4,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Assistente pessoal, voz, saúde, apps e navegação',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Colors.white.withOpacity(.68),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: _premiumAccent.withOpacity(.18),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: _premiumAccent.withOpacity(.35)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: _premiumAccent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      _premiumStateLabel,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(.20),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withOpacity(.07)),
            ),
            child: Text(
              _voiceStatus,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.35,
                color: Colors.white.withOpacity(.88),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _premiumMiniMetric(
                  icon: Icons.shield_moon,
                  label: 'Presença',
                  value: _presenceActive ? 'Ativa' : 'Parada',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _premiumMiniMetric(
                  icon: Icons.hearing,
                  label: 'Microfone',
                  value: _listening && !_manualStop ? 'Ligado' : 'Pausado',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _premiumMiniMetric(
                  icon: Icons.volume_up,
                  label: 'Voz',
                  value: _voiceReply ? 'Ativa' : 'Off',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _premiumMiniMetric({required IconData icon, required String label, required String value}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.055),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(.07)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: Colors.white.withOpacity(.84)),
          const SizedBox(height: 7),
          Text(label, style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(.55))),
          const SizedBox(height: 2),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }

  Widget _premiumActionButton(String label, IconData icon, VoidCallback onTap, {bool highlighted = false}) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        decoration: BoxDecoration(
          color: highlighted ? _premiumAccent.withOpacity(.20) : const Color(0xFF121625),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: highlighted ? _premiumAccent.withOpacity(.45) : Colors.white.withOpacity(.07),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: highlighted ? Colors.white : Colors.white.withOpacity(.82)),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }

  Widget _moduleActionButton({
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback onTap,
    bool highlighted = false,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 58),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: highlighted ? _premiumAccent.withOpacity(.18) : const Color(0xFF121625),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: highlighted ? _premiumAccent.withOpacity(.48) : Colors.white.withOpacity(.08),
            ),
            boxShadow: [
              BoxShadow(
                color: highlighted ? _premiumAccent.withOpacity(.10) : Colors.black.withOpacity(.10),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: highlighted ? _premiumAccent.withOpacity(.25) : Colors.white.withOpacity(.07),
                ),
                child: Icon(icon, size: 19, color: Colors.white),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10.5, height: 1.1, color: Colors.white.withOpacity(.62)),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, size: 18, color: Colors.white.withOpacity(.42)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: _premiumAccent, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900, letterSpacing: .2),
          ),
        ],
      ),
    );
  }

  Future<void> _closeCommandDrawerIfOpen() async {
    if (!mounted) return;
    if (_commandsPanelOpen) {
      _safeSetState(() => _commandsPanelOpen = false);
      await Future.delayed(const Duration(milliseconds: 180));
    }
  }

  Future<void> _runPanelCommand(String command) async {
    final clean = command.trim();
    if (clean.isEmpty) return;
    await _prepareFullCommandInInput(clean);
  }

  Future<void> _prepareFullCommandInInput(String command) async {
    final clean = command.trim();
    if (clean.isEmpty) return;

    await _closeCommandDrawerIfOpen();
    if (!_canUseUi) return;

    _controller.text = clean;
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: _controller.text.length),
    );
    _setVoiceStatus('Comando preparado no campo. Confira e envie.');
  }

  Future<void> _togglePresencePanelSilent() async {
    await _closeCommandDrawerIfOpen();
    try {
      if (_presenceActive) {
        await _presenceChannel.invokeMethod<bool>('stopPresence');
        if (!_canUseUi) return;
        _safeSetState(() => _presenceActive = false);
        _setVoiceStatus('Presença segura desativada.');
        return;
      }

      if (Platform.isAndroid) {
        await Permission.notification.request();
      }

      final started = await _presenceChannel.invokeMethod<bool>('startPresence');
      if (!_canUseUi) return;
      _safeSetState(() {
        _presenceActive = started == true;
        if (started == true) {
          _backgroundWakeSafeMode = false;
          _manualStop = false;
          _listening = true;
          _commandMode = false;
          _wakeMessageShown = false;
        }
      });

      _setVoiceStatus(started == true
          ? 'Presença segura ativada. Microfone pronto no app. Diga: ok Megan.'
          : 'Não consegui ativar a presença segura agora.');

      if (started == true && _speechReady && _appInForeground && !_mediaMode && !_communicationMode) {
        _scheduleRestart(delayMs: 700);
      }
    } catch (e) {
      _setVoiceStatus('Erro ao alternar presença segura: $e');
    }
  }

  Future<void> _toggleListenPanelSilent() async {
    await _closeCommandDrawerIfOpen();

    if (_mediaMode) {
      await _exitMediaMode();
      return;
    }

    if (_listening) {
      _manualStop = true;
      _restartTimer?.cancel();
      _commandWindowTimer?.cancel();
      _commandDebounceTimer?.cancel();
      _ttsResumeTimer?.cancel();
      _conversationIdleTimer?.cancel();
      try {
        await _speech.stop();
      } catch (_) {}

      if (!_canUseUi) return;
      _safeSetState(() {
        _listening = false;
        _commandMode = false;
        _startingListen = false;
      });
      _setVoiceStatus('Microfone pausado.');
      return;
    }

    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      _setVoiceStatus('Microfone sem permissão.');
      return;
    }

    if (!_speechReady) {
      _speechReady = await _initializeSpeech();
    }

    if (!_speechReady) {
      _setVoiceStatus('Reconhecimento de voz indisponível.');
      return;
    }

    if (!_canUseUi) return;
    _safeSetState(() {
      _mediaMode = false;
      _listening = true;
      _manualStop = false;
      _commandMode = false;
      _wakeMessageShown = false;
    });
    _setVoiceStatus('Microfone ativo. Diga: ok Megan.');
    _scheduleRestart(delayMs: 400);
  }

  Future<void> _toggleVoiceReplyPanelSilent() async {
    await _closeCommandDrawerIfOpen();
    final prefs = await SharedPreferences.getInstance();
    final value = !_voiceReply;
    await prefs.setBool('voiceReply', value);
    if (!_canUseUi) return;
    _safeSetState(() => _voiceReply = value);
    _setVoiceStatus(value ? 'Voz ativada.' : 'Voz desativada.');
  }

  Future<void> _openPermissionsPanelAction() async {
    await _closeCommandDrawerIfOpen();
    try {
      final opened = await _systemChannel.invokeMethod<bool>('openAppSettings');
      _setVoiceStatus(opened == true
          ? 'Abrindo permissões da Megan Life.'
          : 'Não consegui abrir as permissões automaticamente.');
    } catch (e) {
      _setVoiceStatus('Erro ao abrir permissões: $e');
    }
  }

  Future<void> _bringAppToFrontPanelSilent() async {
    await _closeCommandDrawerIfOpen();
    if (_mediaMode || _communicationMode) {
      _setVoiceStatus('Retorno adiado para não interferir em mídia ou comunicação.');
      return;
    }
    try {
      final opened = await _systemChannel.invokeMethod<bool>('bringToFront');
      _setVoiceStatus(opened == true
          ? 'Megan em primeiro plano.'
          : 'Não consegui trazer a Megan para frente automaticamente.');
    } catch (e) {
      _setVoiceStatus('Erro ao trazer a Megan para frente: $e');
    }
  }

  Future<void> _prepareCommandPrefixInInput(String commandPrefix) async {
    final clean = commandPrefix.trimRight();
    if (clean.isEmpty) return;

    await _closeCommandDrawerIfOpen();
    if (!_canUseUi) return;

    final text = '$clean ';
    _controller.text = text;
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: _controller.text.length),
    );

    // Não adiciona mensagem no chat. O botão só prepara o comando no campo,
    // evitando repetição de cards como "Digite o destino...".
    _setVoiceStatus('Complete o comando no campo de mensagem e envie.');
  }

  Future<void> _openNavigationPanelAction() async {
    await _prepareCommandPrefixInInput('ir para');
  }

  Future<void> _openAppPanelAction() async {
    await _prepareCommandPrefixInInput('abrir');
  }

  Future<void> _openSuggestionPanelAction() async {
    await _runPanelCommand('Megan, me dê uma sugestão útil agora considerando minha rotina, saúde, produtividade e o contexto recente.');
  }

  Widget _buildSeparatedActionPanel() {
    final buttons = [
      _moduleActionButton(
        title: _presenceActive ? 'Presença ativa' : 'Ativar presença',
        subtitle: 'Mantém a Megan pronta',
        icon: _presenceActive ? Icons.verified_user : Icons.shield_outlined,
        highlighted: true,
        onTap: _togglePresencePanelSilent,
      ),
      _moduleActionButton(
        title: _listening && !_manualStop ? 'Pausar microfone' : 'Ativar microfone',
        subtitle: 'Controle da escuta',
        icon: _listening && !_manualStop ? Icons.mic : Icons.mic_none,
        highlighted: _listening && !_manualStop,
        onTap: _toggleListenPanelSilent,
      ),
      _moduleActionButton(
        title: _voiceReply ? 'Voz ligada' : 'Voz desligada',
        subtitle: 'Resposta falada da Megan',
        icon: _voiceReply ? Icons.volume_up : Icons.volume_off,
        onTap: _toggleVoiceReplyPanelSilent,
      ),
      _moduleActionButton(
        title: 'Permissões',
        subtitle: 'Microfone, bateria e acesso',
        icon: Icons.admin_panel_settings_outlined,
        onTap: _openPermissionsPanelAction,
      ),
      _moduleActionButton(
        title: 'Saúde',
        subtitle: 'Relógio e Health Connect',
        icon: Icons.favorite,
        onTap: () async {
          await _runPanelCommand('analisar saúde do relógio');
        },
      ),
      _moduleActionButton(
        title: 'Atleta',
        subtitle: 'Performance e treino',
        icon: Icons.directions_run,
        onTap: () async {
          await _runPanelCommand('analisar desempenho de atleta');
        },
      ),
      _moduleActionButton(
        title: 'Arquivos',
        subtitle: 'Analisar PDF, imagem e docs',
        icon: Icons.upload_file,
        onTap: () async {
          await _closeCommandDrawerIfOpen();
          await _pickAndAnalyzeFile();
        },
      ),
      _moduleActionButton(
        title: 'Navegação',
        subtitle: 'Waze ou Google Maps',
        icon: Icons.navigation,
        onTap: _openNavigationPanelAction,
      ),
      _moduleActionButton(
        title: 'WhatsApp',
        subtitle: 'Normal ou Business',
        icon: Icons.chat,
        onTap: () async {
          await _runPanelCommand('abrir whatsapp');
        },
      ),
      _moduleActionButton(
        title: 'Abrir app',
        subtitle: 'Digite o app desejado',
        icon: Icons.apps,
        onTap: _openAppPanelAction,
      ),
      _moduleActionButton(
        title: 'Sugestão',
        subtitle: 'Ideias da Megan',
        icon: Icons.lightbulb,
        onTap: _openSuggestionPanelAction,
      ),
      _moduleActionButton(
        title: 'Retorno',
        subtitle: 'Voltar para Megan',
        icon: Icons.reply_all,
        onTap: _bringAppToFrontPanelSilent,
      ),
    ];

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF0B0F1A),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withOpacity(.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _actionSectionTitle('Ações separadas'),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final crossAxisCount = width < 300 ? 1 : 2;
              final childAspectRatio = crossAxisCount == 1 ? 4.6 : 2.05;

              return GridView.count(
                crossAxisCount: crossAxisCount,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: childAspectRatio,
                children: buttons,
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _premiumMessageBubble(_Message message) {
    final isUser = message.user;

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 740),
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: isUser ? const Color(0xFF7C3AED) : const Color(0xFF141827),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(20),
            topRight: const Radius.circular(20),
            bottomLeft: Radius.circular(isUser ? 20 : 6),
            bottomRight: Radius.circular(isUser ? 6 : 20),
          ),
          border: Border.all(color: Colors.white.withOpacity(.07)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(.18),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isUser ? Icons.person : Icons.auto_awesome,
                  size: 14,
                  color: Colors.white.withOpacity(.74),
                ),
                const SizedBox(width: 6),
                Text(
                  isUser ? 'Luiz' : 'Megan',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: Colors.white.withOpacity(.70),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              message.text,
              style: const TextStyle(fontSize: 15, height: 1.38),
            ),
          ],
        ),
      ),
    );
  }

  Widget _premiumInputBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF080A12).withOpacity(.96),
        border: Border(top: BorderSide(color: Colors.white.withOpacity(.07))),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            IconButton.filledTonal(
              onPressed: _pickAndAnalyzeFile,
              icon: const Icon(Icons.add_rounded),
              tooltip: 'Arquivo',
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _controller,
                minLines: 1,
                maxLines: 5,
                decoration: InputDecoration(
                  hintText: 'Fale ou digite para a Megan...',
                  hintStyle: TextStyle(color: Colors.white.withOpacity(.45)),
                  filled: true,
                  fillColor: const Color(0xFF111522),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide(color: Colors.white.withOpacity(.07)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide(color: _premiumAccent.withOpacity(.65)),
                  ),
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _toggleListen,
              style: IconButton.styleFrom(backgroundColor: _premiumAccent.withOpacity(.92)),
              icon: Icon(_listening && !_manualStop ? Icons.hearing : Icons.mic),
              tooltip: 'Microfone',
            ),
            const SizedBox(width: 6),
            IconButton.filled(
              onPressed: _send,
              style: IconButton.styleFrom(backgroundColor: const Color(0xFF22C55E)),
              icon: const Icon(Icons.arrow_upward_rounded),
              tooltip: 'Enviar',
            ),
          ],
        ),
      ),
    );
  }

  void _openCommandsPanel() {
    if (!mounted) return;
    if (_commandsPanelOpen) return;
    _safeSetState(() => _commandsPanelOpen = true);
  }

  Widget _buildCommandsSidebar(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final panelWidth = screenWidth < 420 ? screenWidth * .88 : 380.0;

    return Align(
      alignment: Alignment.centerLeft,
      child: SafeArea(
        child: Container(
          width: panelWidth,
          height: double.infinity,
          margin: const EdgeInsets.fromLTRB(8, 8, 0, 8),
          decoration: BoxDecoration(
            color: const Color(0xFF080A12),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Colors.white.withOpacity(.10)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(.40),
                blurRadius: 28,
                offset: const Offset(8, 0),
              ),
            ],
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 18),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight - 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          IconButton(
                            tooltip: 'Fechar comandos',
                            onPressed: () => _safeSetState(() => _commandsPanelOpen = false),
                            icon: const Icon(Icons.close_rounded),
                          ),
                          const SizedBox(width: 4),
                          const Expanded(
                            child: Text(
                              'Comandos da Megan',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      _premiumTopCard(),
                      _buildStatePanel(),
                      const SizedBox(height: 8),
                      _buildSeparatedActionPanel(),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080A12),
      appBar: AppBar(
        elevation: 0,
        centerTitle: false,
        backgroundColor: const Color(0xFF080A12),
        leading: IconButton(
          tooltip: 'Abrir comandos',
          onPressed: _openCommandsPanel,
          icon: const Icon(Icons.menu_rounded),
        ),
        titleSpacing: 0,
        title: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [
                    _premiumAccent,
                    const Color(0xFF22C55E).withOpacity(.95),
                  ],
                ),
              ),
              child: const Icon(Icons.auto_awesome_rounded, size: 18, color: Colors.white),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Megan',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    'Chat inteligente',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Colors.white54),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _voiceReply ? 'Desativar voz' : 'Ativar voz',
            onPressed: _toggleVoiceReply,
            icon: Icon(_voiceReply ? Icons.volume_up_rounded : Icons.volume_off_rounded),
          ),
          IconButton(
            tooltip: _listening && !_manualStop ? 'Pausar microfone' : 'Ativar microfone',
            onPressed: _toggleListen,
            icon: Icon(_listening && !_manualStop ? Icons.mic_rounded : Icons.mic_none_rounded),
          ),
        ],
      ),
      body: Stack(
        children: [
          SafeArea(
            top: false,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isCompact = constraints.maxWidth < 420;
                final horizontalPadding = isCompact ? 10.0 : 18.0;
                final maxChatWidth = constraints.maxWidth >= 900 ? 820.0 : double.infinity;

                return Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxChatWidth),
                    child: Column(
                      children: [
                        Container(
                          width: double.infinity,
                          margin: EdgeInsets.fromLTRB(horizontalPadding, 8, horizontalPadding, 0),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF10131F),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: Colors.white.withOpacity(.08)),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                _listening && !_manualStop
                                    ? Icons.graphic_eq_rounded
                                    : Icons.pause_circle_outline_rounded,
                                color: _listening && !_manualStop ? const Color(0xFF22C55E) : Colors.white54,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _voiceStatus,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: isCompact ? 12 : 13,
                                    color: Colors.white.withOpacity(.72),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              InkWell(
                                borderRadius: BorderRadius.circular(999),
                                onTap: _openCommandsPanel,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: _premiumAccent.withOpacity(.16),
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(color: _premiumAccent.withOpacity(.30)),
                                  ),
                                  child: const Text(
                                    'Comandos',
                                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: _messages.isEmpty
                              ? Center(
                                  child: Padding(
                                    padding: EdgeInsets.all(isCompact ? 18 : 28),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Container(
                                          width: 76,
                                          height: 76,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            gradient: LinearGradient(
                                              colors: [
                                                _premiumAccent.withOpacity(.95),
                                                const Color(0xFF22C55E).withOpacity(.85),
                                              ],
                                            ),
                                          ),
                                          child: const Icon(Icons.auto_awesome_rounded, size: 34, color: Colors.white),
                                        ),
                                        const SizedBox(height: 16),
                                        const Text(
                                          'Como posso ajudar?',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          'Use o chat ou abra os comandos laterais.',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(color: Colors.white.withOpacity(.62)),
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                              : ListView.builder(
                                  padding: EdgeInsets.fromLTRB(horizontalPadding, 14, horizontalPadding, 18),
                                  itemCount: _messages.length,
                                  itemBuilder: (context, i) => _premiumMessageBubble(_messages[i]),
                                ),
                        ),
                        if (_loading)
                          LinearProgressIndicator(
                            minHeight: 3,
                            color: _premiumAccent,
                            backgroundColor: Colors.white.withOpacity(.06),
                          ),
                        _premiumInputBar(),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          if (_commandsPanelOpen)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _safeSetState(() => _commandsPanelOpen = false),
                child: Container(color: Colors.black.withOpacity(.55)),
              ),
            ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            top: 0,
            bottom: 0,
            left: _commandsPanelOpen ? 0 : -430,
            child: IgnorePointer(
              ignoring: !_commandsPanelOpen,
              child: _buildCommandsSidebar(context),
            ),
          ),
        ],
      ),
    );
  }

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

class _MemoryEntry {
  final String userText;
  final String meganText;

  const _MemoryEntry(this.userText, this.meganText);
}