import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../services/ai_service.dart';
import '../services/app_launcher_service.dart';
import '../services/file_service.dart';
import '../services/health_service.dart';
import '../services/navigation_service.dart';

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
  final _health = MeganHealthService();
  final _speech = SpeechToText();
  final _tts = FlutterTts();

  final List<_Message> _messages = [
    _Message(
      false,
      'Oi Luiz, sou a Megan Life 4.2.3 REAL. Agora estou conectada ao Render/Gemini, com base para memória persistente, saúde real, atleta, arquivos/imagens/ZIPs, Waze/Maps, apps e sugestões de melhoria.',
    ),
  ];

  bool _loading = false;
  bool _listening = false;
  bool _voiceReply = true;
  bool _speechReady = false;
  bool _processingVoiceCommand = false;

  String _lastVoiceText = '';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _controller.dispose();
    _speech.stop();
    _tts.stop();
    super.dispose();
  }

  Future<void> _boot() async {
    await _tts.setLanguage('pt-BR');
    await _tts.setSpeechRate(.48);

    _speechReady = await _speech.initialize(
      onStatus: (status) async {
        if (!mounted) return;

        if (_listening &&
            !_processingVoiceCommand &&
            (status == 'done' || status == 'notListening')) {
          await Future.delayed(const Duration(milliseconds: 450));
          if (mounted && _listening && !_processingVoiceCommand) {
            await _startListening();
          }
        }
      },
      onError: (_) {
        if (!mounted) return;
        setState(() => _listening = false);
      },
    );

    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _voiceReply = prefs.getBool('voiceReply') ?? true);
  }

  Future<void> _say(String text) async {
    if (!_voiceReply) return;
    final clean = text.length > 450 ? '${text.substring(0, 450)}...' : text;
    await _tts.speak(clean);
  }

  void _add(bool user, String text) {
    if (!mounted) return;
    setState(() => _messages.add(_Message(user, text)));
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _loading) return;

    _controller.clear();
    _add(true, text);

    if (!mounted) return;
    setState(() => _loading = true);

    try {
      final lower = text.toLowerCase();
      String answer;

      if (lower.startsWith('abrir ')) {
        final app = text.substring(6).trim();
        answer = await _apps.openKnownApp(app)
            ? 'Abrindo $app.'
            : 'Não consegui abrir $app. O app pode não estar instalado ou o Android bloqueou a abertura direta. Verifique se o app está instalado.';
      } else if (lower.startsWith('navegar para ') || lower.startsWith('ir para ')) {
        final dest = text
            .replaceFirst(
              RegExp(r'^(navegar para|ir para)\s+', caseSensitive: false),
              '',
            )
            .trim();

        await _nav.openNavigationChoice(context, dest);
        answer = 'Preparei a navegação para $dest. Escolha Waze ou Google Maps.';
      } else if (lower.contains('atleta') ||
          lower.contains('treino') ||
          lower.contains('desempenho')) {
        answer = await _ai.athleteSummary(
          await _health.readAvailableHealthData(),
        );
      } else if (lower.contains('saúde') ||
          lower.contains('saude') ||
          lower.contains('relógio') ||
          lower.contains('relogio')) {
        answer = await _ai.healthSummary(
          await _health.readAvailableHealthData(),
        );
      } else if (lower.startsWith('sugestão ') ||
          lower.startsWith('sugestao ')) {
        final feedback = text
            .replaceFirst(
              RegExp(r'^sugest(ão|ao)\s+', caseSensitive: false),
              '',
            )
            .trim();

        answer = await _ai.sendFeedback(feedback);
      } else {
        answer = await _ai.chat(text);
      }

      _add(false, answer);
      await _say(answer);
    } catch (e) {
      _add(false, 'Erro: $e');
    } finally {
      if (!mounted) return;
      setState(() => _loading = false);
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
      await _speech.stop();
      if (!mounted) return;
      setState(() => _listening = false);
      return;
    }

    if (!_speechReady) {
      _speechReady = await _speech.initialize();
    }

    if (!_speechReady) {
      _add(false, 'Microfone não disponível. Verifique permissões.');
      return;
    }

    if (!mounted) return;
    setState(() => _listening = true);

    await _startListening();
  }

  Future<void> _startListening() async {
    if (!_speechReady || !_listening || _speech.isListening) return;

    await _speech.listen(
      localeId: 'pt_BR',
      listenMode: ListenMode.dictation,
      partialResults: true,
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 4),
      onResult: (r) async {
        final words = r.recognizedWords.trim();
        if (words.isEmpty) return;

        final lower = words.toLowerCase();

        if (!r.finalResult) {
          if (lower.contains('ok megan') || lower.contains('oi megan')) {
            final command = _extractWakeCommand(words);
            if (command.isNotEmpty) {
              _controller.text = command;
            }
          }
          return;
        }

        if (_processingVoiceCommand) return;

        final command = _extractWakeCommand(words);
        final finalText = command.isNotEmpty ? command : words;

        if (finalText.trim().isEmpty) {
          await _say('Estou ouvindo, Luiz.');
          return;
        }

        if (finalText == _lastVoiceText) return;
        _lastVoiceText = finalText;

        _processingVoiceCommand = true;

        try {
          _controller.text = finalText;
          await _speech.stop();
          await _send();
        } finally {
          _processingVoiceCommand = false;

          if (mounted && _listening) {
            await Future.delayed(const Duration(milliseconds: 700));
            await _startListening();
          }
        }
      },
    );
  }

  String _extractWakeCommand(String text) {
    return text
        .replaceAll(RegExp('ok megan', caseSensitive: false), '')
        .replaceAll(RegExp('oi megan', caseSensitive: false), '')
        .trim();
  }

  Future<void> _toggleVoiceReply() async {
    final prefs = await SharedPreferences.getInstance();
    final value = !_voiceReply;

    await prefs.setBool('voiceReply', value);

    if (!mounted) return;
    setState(() => _voiceReply = value);
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
          title: const Text('Megan Life 4.2.3 REAL'),
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
                    alignment:
                        m.user ? Alignment.centerRight : Alignment.centerLeft,
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 720),
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: m.user
                            ? const Color(0xFF7C3AED)
                            : const Color(0xFF151827),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: Colors.white.withOpacity(.08),
                        ),
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

class _Message {
  final bool user;
  final String text;

  _Message(this.user, this.text);
}