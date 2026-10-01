import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart' hide ChatMessage;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    _showGlobalErrorDialog(
      "Flutter Runtime Error",
      details.exception.toString(),
      details.stack.toString(),
    );
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    _showGlobalErrorDialog(
      "Async Platform Error",
      error.toString(),
      stack.toString(),
    );
    return true;
  };

  runApp(const NeuralChatApp());
}

void _showGlobalErrorDialog(String title, String error, String stack) {
  final context = navigatorKey.currentContext;
  if (context != null) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF200B0B),
        title: Text(title, style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(error, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13)),
              const Divider(color: Colors.red),
              Text(stack, style: const TextStyle(color: Colors.white70, fontSize: 10, fontFamily: 'monospace')),
            ],
          ),
        ),
        actions: [
          TextButton(
            child: const Text("Copy"),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: "$error\n\n$stack"));
            },
          ),
          ElevatedButton(
            child: const Text("Close"),
            onPressed: () => Navigator.pop(ctx),
          ),
        ],
      ),
    );
  }
}

/* ========================================================================== */
/*                           DATA & MEMORY MODELS                             */
/* ========================================================================== */

class AttachmentItem {
  final String id;
  final String name;
  final String path;
  final int size;
  final String extension;
  final Uint8List? bytes;

  AttachmentItem({
    required this.id,
    required this.name,
    required this.path,
    required this.size,
    required this.extension,
    this.bytes,
  });

  bool get isImage =>
      ['jpg', 'jpeg', 'png', 'webp', 'gif'].contains(extension.toLowerCase());

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'path': path,
        'size': size,
        'extension': extension,
      };

  factory AttachmentItem.fromJson(Map<String, dynamic> json) => AttachmentItem(
        id: json['id'] ?? '',
        name: json['name'] ?? '',
        path: json['path'] ?? '',
        size: json['size'] ?? 0,
        extension: json['extension'] ?? '',
      );
}

class ChatMessage {
  final String id;
  final String text;
  final bool isUser;
  final DateTime timestamp;
  final List<AttachmentItem> attachments;

  ChatMessage({
    required this.id,
    required this.text,
    required this.isUser,
    required this.timestamp,
    this.attachments = const [],
  });

  ChatMessage copyWith({
    String? id,
    String? text,
    bool? isUser,
    DateTime? timestamp,
    List<AttachmentItem>? attachments,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      text: text ?? this.text,
      isUser: isUser ?? this.isUser,
      timestamp: timestamp ?? this.timestamp,
      attachments: attachments ?? this.attachments,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'isUser': isUser,
        'timestamp': timestamp.toIso8601String(),
        'attachments': attachments.map((a) => a.toJson()).toList(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'] ?? '',
        text: json['text'] ?? '',
        isUser: json['isUser'] ?? false,
        timestamp: DateTime.tryParse(json['timestamp'] ?? '') ?? DateTime.now(),
        attachments: (json['attachments'] as List<dynamic>? ?? [])
            .map((a) => AttachmentItem.fromJson(a as Map<String, dynamic>))
            .toList(),
      );
}

class ChatSession {
  final String id;
  String title;
  final DateTime createdAt;
  DateTime lastModified;
  List<ChatMessage> messages;

  ChatSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.lastModified,
    List<ChatMessage>? messages,
  }) : messages = messages ?? [];

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'lastModified': lastModified.toIso8601String(),
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory ChatSession.fromJson(Map<String, dynamic> json) => ChatSession(
        id: json['id'] ?? '',
        title: json['title'] ?? 'New Chat',
        createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
        lastModified:
            DateTime.tryParse(json['lastModified'] ?? '') ?? DateTime.now(),
        messages: (json['messages'] as List<dynamic>? ?? [])
            .map((m) => ChatMessage.fromJson(m as Map<String, dynamic>))
            .toList(),
      );
}

class LearnedMemoryFact {
  final String id;
  final String fact;
  final String reasoning;
  final String importance;
  final String category;
  final DateTime learnedAt;

  LearnedMemoryFact({
    required this.id,
    required this.fact,
    required this.reasoning,
    required this.importance,
    required this.category,
    required this.learnedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'fact': fact,
        'reasoning': reasoning,
        'importance': importance,
        'category': category,
        'learnedAt': learnedAt.toIso8601String(),
      };

  factory LearnedMemoryFact.fromJson(Map<String, dynamic> json) =>
      LearnedMemoryFact(
        id: json['id'] ?? '',
        fact: json['fact'] ?? '',
        reasoning: json['reasoning'] ?? 'Captured interaction',
        importance: json['importance'] ?? 'Medium',
        category: json['category'] ?? 'General',
        learnedAt:
            DateTime.tryParse(json['learnedAt'] ?? '') ?? DateTime.now(),
      );
}

class CognitiveMemoryBank {
  String personaOverview = "Autonomous, ultra-fast personal assistant.";
  List<LearnedMemoryFact> facts = [];

  Map<String, dynamic> toJson() => {
        'format': 'NeuralMemory_v3',
        'exportDate': DateTime.now().toIso8601String(),
        'personaOverview': personaOverview,
        'facts': facts.map((f) => f.toJson()).toList(),
      };

  void importFromJson(Map<String, dynamic> json) {
    personaOverview = json['personaOverview'] ?? personaOverview;
    if (json['facts'] != null) {
      facts = (json['facts'] as List<dynamic>)
          .map((f) => LearnedMemoryFact.fromJson(f as Map<String, dynamic>))
          .toList();
    }
  }

  String buildSystemContext() {
    final buffer = StringBuffer();
    buffer.write("You are an intelligent, concise personal AI. Answer questions directly without repeating phrases. ");

    if (facts.isNotEmpty) {
      buffer.write("Important facts: ");
      final prioritized = List<LearnedMemoryFact>.from(facts)
        ..sort((a, b) {
          if (a.importance == "High" && b.importance != "High") return -1;
          if (a.importance != "High" && b.importance == "High") return 1;
          return b.learnedAt.compareTo(a.learnedAt);
        });

      for (final f in prioritized.take(7)) {
        buffer.write("[${f.fact}] ");
      }
    }
    return buffer.toString().trim();
  }
}

/* ========================================================================== */
/*                             MAIN UI COMPONENT                              */
/* ========================================================================== */

class NeuralChatApp extends StatelessWidget {
  const NeuralChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Neural Companion',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F1117),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6C63FF),
          secondary: Color(0xFF00D2FF),
          surface: Color(0xFF1A1D26),
        ),
        useMaterial3: true,
      ),
      home: const ChatScreen(),
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  final List<ChatSession> _sessions = [];
  String? _currentSessionId;
  final List<AttachmentItem> _selectedAttachments = [];

  final CognitiveMemoryBank _memoryBank = CognitiveMemoryBank();
  final LlamaController _llama = LlamaController();

  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();
  bool _speechEnabled = false;
  bool _isListening = false;
  bool _voiceResponseEnabled = true; // Default ON
  bool _autoMicSend = true;

  // Unbroken Call Mode
  bool _callModeActive = false;
  bool _isCallModeAsleep = false;
  String _wakeWord = "wake up";
  String _stopWord = "stop";

  Timer? _silenceCheckTimer;
  Timer? _speechPauseTimer;

  // Active audio player tracker
  String? _currentlySpeakingMessageId;
  final List<String> _ttsQueue = [];
  bool _isTtsWorkerRunning = false;
  String _ttsStreamBuffer = "";
  Completer<void>? _ttsSentenceCompleter;

  // Inference state
  String? _loadedGgufPath;
  String _modelStatus = "No .gguf loaded";
  bool _isProcessing = false;
  StreamSubscription<String>? _activeInferenceSubscription;

  static const MethodChannel _nativeChannel =
      MethodChannel('com.example.neural_companion/file_picker');

  ChatSession get _currentSession {
    if (_sessions.isEmpty) {
      final newSession = ChatSession(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: "New Conversation",
        createdAt: DateTime.now(),
        lastModified: DateTime.now(),
      );
      _sessions.add(newSession);
      _currentSessionId = newSession.id;
      return newSession;
    }
    return _sessions.firstWhere(
      (s) => s.id == _currentSessionId,
      orElse: () => _sessions.first,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPreviousNativeCrash();
    _initSpeechEngine();
    _initTtsEngine();
    _loadSavedState();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _setNativeForegroundCallService(false);
    _silenceCheckTimer?.cancel();
    _speechPauseTimer?.cancel();
    _activeInferenceSubscription?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    _speech.stop();
    _tts.stop();
    _llama.dispose();
    super.dispose();
  }

  Future<void> _setNativeForegroundCallService(bool enable) async {
    try {
      await _nativeChannel.invokeMethod('setCallService', {'enable': enable});
    } catch (_) {}
  }

  Future<void> _playNativeTone(String type) async {
    try {
      await _nativeChannel.invokeMethod('playTone', {'type': type});
    } catch (_) {}
  }

  /* ---------------- PERSISTENCE ---------------- */

  Future<File> _getSessionsFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/chat_sessions_v3.json');
  }

  Future<void> _saveSessionsToDisk() async {
    try {
      final file = await _getSessionsFile();
      final List<Map<String, dynamic>> jsonList =
          _sessions.map((s) => s.toJson()).toList();
      await file.writeAsString(jsonEncode(jsonList));
    } catch (_) {}
  }

  Future<void> _loadSessionsFromDisk() async {
    try {
      final file = await _getSessionsFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final List<dynamic> jsonList = jsonDecode(content);
        setState(() {
          _sessions.clear();
          for (final item in jsonList) {
            _sessions.add(ChatSession.fromJson(item as Map<String, dynamic>));
          }
          if (_sessions.isNotEmpty) {
            _currentSessionId = _sessions.first.id;
          }
        });
      }
    } catch (_) {}

    if (_sessions.isEmpty) {
      _createNewSession(showSnackbar: false);
    }
  }

  Future<File> _getLocalMemoryFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/autonomous_cognitive_memory.json');
  }

  Future<void> _saveMemoryToDisk() async {
    try {
      final file = await _getLocalMemoryFile();
      await file.writeAsString(jsonEncode(_memoryBank.toJson()));
    } catch (_) {}
  }

  Future<void> _loadMemoryFromDisk() async {
    try {
      final file = await _getLocalMemoryFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final Map<String, dynamic> data = jsonDecode(content);
        setState(() {
          _memoryBank.importFromJson(data);
        });
      }
    } catch (_) {}
  }

  Future<void> _loadSavedState() async {
    final prefs = await SharedPreferences.getInstance();
    final savedPath = prefs.getString('saved_gguf_path');
    if (savedPath != null && await File(savedPath).exists()) {
      _bindModel(savedPath);
    }
    _wakeWord = prefs.getString('saved_wake_word') ?? "wake up";
    _stopWord = prefs.getString('saved_stop_word') ?? "stop";
    _autoMicSend = prefs.getBool('saved_auto_mic') ?? true;
    _voiceResponseEnabled = prefs.getBool('saved_tts_enabled') ?? true;

    await _loadMemoryFromDisk();
    await _loadSessionsFromDisk();
  }

  Future<void> _checkPreviousNativeCrash() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final crashFile = File('${appDir.parent.path}/files/last_native_crash.txt');

      if (await crashFile.exists()) {
        final content = await crashFile.readAsString();
        await crashFile.delete();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showGlobalErrorDialog(
            "Crash Detected on Previous Run",
            content,
            "Captured by Native Exception Handler (MainActivity)",
          );
        });
      }
    } catch (_) {}
  }

  /* ---------------- SESSIONS ---------------- */

  Future<void> _createNewSession({bool showSnackbar = true}) async {
    await _stopGeneration();

    final newSession = ChatSession(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: "Conversation ${_sessions.length + 1}",
      createdAt: DateTime.now(),
      lastModified: DateTime.now(),
    );

    setState(() {
      _sessions.insert(0, newSession);
      _currentSessionId = newSession.id;
    });

    await _saveSessionsToDisk();

    if (showSnackbar && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Started new chat session"), duration: Duration(seconds: 1)),
      );
    }
  }

  Future<void> _switchSession(String sessionId) async {
    if (_currentSessionId == sessionId) return;

    await _stopGeneration();

    setState(() {
      _currentSessionId = sessionId;
    });

    _scrollToBottom();
  }

  Future<void> _deleteSession(String sessionId) async {
    await _stopGeneration();

    setState(() {
      _sessions.removeWhere((s) => s.id == sessionId);
      if (_currentSessionId == sessionId) {
        _currentSessionId = _sessions.isNotEmpty ? _sessions.first.id : null;
      }
    });

    if (_sessions.isEmpty) {
      _createNewSession(showSnackbar: false);
    }

    await _saveSessionsToDisk();
  }

  /* ---------------- AUDIO & STRICT TTS COMPLETION QUEUE ---------------- */

  Future<void> _initSpeechEngine() async {
    try {
      _speechEnabled = await _speech.initialize(
        onError: (_) {
          if (mounted) setState(() => _isListening = false);
          _handleMicDisconnected();
        },
        onStatus: (val) {
          if (val == 'done' || val == 'notListening') {
            if (mounted) setState(() => _isListening = false);
            _handleMicDisconnected();
          }
        },
      );
      setState(() {});
    } catch (_) {
      _speechEnabled = false;
    }
  }

  Future<void> _initTtsEngine() async {
    await _tts.setLanguage("en-US");
    await _tts.setSpeechRate(0.53);
    await _tts.setVolume(1.0);

    // Synchronize completion with an explicit Completer to completely stop sentence cutting
    _tts.setCompletionHandler(() {
      if (_ttsSentenceCompleter != null && !_ttsSentenceCompleter!.isCompleted) {
        _ttsSentenceCompleter!.complete();
      }
    });

    _tts.setErrorHandler((_) {
      if (_ttsSentenceCompleter != null && !_ttsSentenceCompleter!.isCompleted) {
        _ttsSentenceCompleter!.complete();
      }
    });
  }

  void _enqueueTtsText(String sentence, {String? messageId}) {
    final clean = sentence.trim();
    if (clean.isEmpty) return;

    if (messageId != null && _currentlySpeakingMessageId != messageId) {
      _stopTts();
      _currentlySpeakingMessageId = messageId;
    }

    _ttsQueue.add(clean);
    if (!_isTtsWorkerRunning) {
      _runTtsWorker();
    }
  }

  /// Strictly awaits completion of each sentence before popping the next.
  /// Eliminates sentence cutting and audio refreshes.
  Future<void> _runTtsWorker() async {
    if (_isTtsWorkerRunning) return;
    _isTtsWorkerRunning = true;

    while (_ttsQueue.isNotEmpty) {
      if (!_voiceResponseEnabled && _currentlySpeakingMessageId == null) {
        _ttsQueue.clear();
        break;
      }

      final sentence = _ttsQueue.removeAt(0);
      _ttsSentenceCompleter = Completer<void>();

      try {
        await _tts.speak(sentence);
        // Wait until Android audio finishes speaking before proceeding
        await _ttsSentenceCompleter!.future.timeout(
          const Duration(seconds: 20),
          onTimeout: () {},
        );
      } catch (_) {}
    }

    _isTtsWorkerRunning = false;
    if (_ttsQueue.isEmpty && mounted) {
      setState(() => _currentlySpeakingMessageId = null);

      if (_callModeActive && !_isProcessing) {
        // Give 300ms acoustic grace period so mic doesn't hear the speaker echo
        Future.delayed(const Duration(milliseconds: 300), () {
          if (_callModeActive && !_isProcessing) {
            _startContinuousMic();
          }
        });
      }
    }
  }

  Future<void> _stopTts() async {
    _ttsQueue.clear();
    if (_ttsSentenceCompleter != null && !_ttsSentenceCompleter!.isCompleted) {
      _ttsSentenceCompleter!.complete();
    }
    _isTtsWorkerRunning = false;
    _ttsStreamBuffer = "";
    await _tts.stop();
    if (mounted) {
      setState(() => _currentlySpeakingMessageId = null);
    }
  }

  Future<void> _toggleMessageSpeech(ChatMessage msg) async {
    if (_currentlySpeakingMessageId == msg.id) {
      await _stopTts();
    } else {
      await _stopTts();
      setState(() => _currentlySpeakingMessageId = msg.id);

      final sentences = msg.text
          .split(RegExp(r'(?<=[.?!])\s+|\n+'))
          .where((s) => s.trim().isNotEmpty)
          .toList();

      if (sentences.isEmpty) {
        setState(() => _currentlySpeakingMessageId = null);
        return;
      }

      _ttsQueue.addAll(sentences);
      _runTtsWorker();
    }
  }

  /* ---------------- UNBROKEN CALL MODE ENGINE ---------------- */

  void _toggleCallMode() {
    setState(() {
      _callModeActive = !_callModeActive;
      _isCallModeAsleep = false;
    });

    _setNativeForegroundCallService(_callModeActive);

    if (_callModeActive) {
      _playNativeTone("wake");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Call Mode Active. Runs continuously in background/screen-off."),
          duration: Duration(seconds: 2),
        ),
      );
      _startContinuousMic();
    } else {
      _silenceCheckTimer?.cancel();
      _speechPauseTimer?.cancel();
      _speech.stop();
      _stopTts();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Call Mode Disconnected"), duration: Duration(seconds: 1)),
      );
    }
  }

  void _handleMicDisconnected() {
    if (!_callModeActive) return;

    // Do NOT reconnect in an audio fight while TTS is actively playing
    if (_isTtsWorkerRunning) return;

    // Graceful reconnect avoids the rapid 200ms snapping on/off loop
    Future.delayed(const Duration(milliseconds: 600), () {
      if (_callModeActive && !_isListening && !_isTtsWorkerRunning) {
        _startContinuousMic();
      }
    });
  }

  void _startContinuousMic() async {
    if (!_speechEnabled || !_callModeActive) return;
    if (_isListening) return;

    setState(() => _isListening = true);

    await _speech.listen(
      onResult: (SpeechRecognitionResult result) {
        final rawWords = result.recognizedWords.toLowerCase().trim();

        // -------------------------------------------------------------
        // STATE 1: Model is generating text OR TTS is speaking
        // SEPARATE MIC PROCESSING: ONLY check for Stop Word!
        // -------------------------------------------------------------
        if (_isProcessing || _isTtsWorkerRunning) {
          if (rawWords.contains(_stopWord.toLowerCase())) {
            _playNativeTone("stop");
            _stopGeneration();
            _stopTts();
            _textController.clear();
            _startContinuousMic();
          }
          return; // Ignore other words so prompt words don't trigger stop
        }

        // -------------------------------------------------------------
        // STATE 2: Standby Sleep Mode
        // ONLY check for Wake Word
        // -------------------------------------------------------------
        if (_isCallModeAsleep) {
          if (rawWords.contains(_wakeWord.toLowerCase())) {
            _playNativeTone("wake");
            setState(() => _isCallModeAsleep = false);
            _tts.speak("I'm listening.");
            _resetSilenceWatchdog();
          }
          return;
        }

        // -------------------------------------------------------------
        // STATE 3: Prompt Dictation Mode (Stop/Wake words allowed in text)
        // -------------------------------------------------------------
        _textController.text = result.recognizedWords;
        _resetSilenceWatchdog();

        _speechPauseTimer?.cancel();
        if (_autoMicSend && result.recognizedWords.trim().isNotEmpty) {
          _speechPauseTimer = Timer(const Duration(milliseconds: 1400), () {
            if (_textController.text.trim().isNotEmpty && !_isProcessing) {
              _handleSendMessage();
            }
          });
        }
      },
      listenFor: const Duration(seconds: 60),
      pauseFor: const Duration(seconds: 4),
    );

    _resetSilenceWatchdog();
  }

  void _resetSilenceWatchdog() {
    _silenceCheckTimer?.cancel();
    if (!_callModeActive || _isProcessing || _isCallModeAsleep || _isTtsWorkerRunning) return;

    _silenceCheckTimer = Timer(const Duration(seconds: 10), () async {
      if (!_callModeActive || _isProcessing || _isCallModeAsleep || _isTtsWorkerRunning) return;

      await _tts.speak("Are you still there?");

      _silenceCheckTimer = Timer(const Duration(seconds: 10), () {
        if (!_callModeActive || _isProcessing || _isCallModeAsleep || _isTtsWorkerRunning) return;
        setState(() => _isCallModeAsleep = true);
        _tts.speak("Standby. Say ${_wakeWord} to wake me.");
      });
    });
  }

  /* ---------------- GGUF BINDER ---------------- */

  Future<void> _selectGgufModel() async {
    if (kIsWeb) {
      _showGlobalErrorDialog(
        "Platform Not Supported",
        "GGUF native execution requires ARM64 Android hardware.",
        "Run the release APK on your device.",
      );
      return;
    }

    try {
      setState(() => _modelStatus = "Opening picker...");

      final String? selectedPath =
          await _nativeChannel.invokeMethod<String>('pickGgufFile');

      if (selectedPath == null || selectedPath.isEmpty) {
        setState(() => _modelStatus = _loadedGgufPath != null
            ? "Ready: ${_loadedGgufPath!.split('/').last}"
            : "No .gguf loaded");
        return;
      }

      final file = File(selectedPath);
      if (!await file.exists()) {
        _showGlobalErrorDialog("File Error", "Cannot access: $selectedPath", "Verify permissions.");
        return;
      }

      await _bindModel(selectedPath);
    } catch (e, stack) {
      _showGlobalErrorDialog("Model Selection Error", e.toString(), stack.toString());
    }
  }

  Future<void> _bindModel(String rawPath) async {
    try {
      setState(() => _modelStatus = "Verifying path...");

      final file = File(rawPath);
      if (!await file.exists()) {
        setState(() => _modelStatus = "File not found");
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('saved_gguf_path', rawPath);

      setState(() => _modelStatus = "Binding engine...");

      await _llama.loadModel(
        modelPath: rawPath,
        threads: 4,
        contextSize: 768,
      );

      setState(() {
        _loadedGgufPath = rawPath;
        _modelStatus = "Ready: ${rawPath.split('/').last}";
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Model ready: ${rawPath.split('/').last}")),
        );
      }
    } catch (e, stack) {
      _showGlobalErrorDialog("Model Binding Error", e.toString(), stack.toString());
      if (mounted) {
        setState(() => _modelStatus = "Load error");
      }
    }
  }

  /* ---------------- INFERENCE & BACKGROUND EXECUTION ---------------- */

  Future<void> _stopGeneration() async {
    if (_activeInferenceSubscription != null) {
      await _activeInferenceSubscription!.cancel();
      _activeInferenceSubscription = null;
    }

    try {
      await _llama.stop();
    } catch (_) {}

    await _stopTts();

    if (_isProcessing) {
      setState(() {
        _isProcessing = false;
        final currentMessages = _currentSession.messages;
        if (currentMessages.isNotEmpty && !currentMessages.last.isUser && currentMessages.last.text.isEmpty) {
          currentMessages.last = currentMessages.last.copyWith(text: "(Stopped)");
        }
      });
      await _saveSessionsToDisk();
    }
  }

  Future<void> _handleSendMessage() async {
    if (_isProcessing) return;

    final text = _textController.text.trim();
    if (text.isEmpty && _selectedAttachments.isEmpty) return;

    _speechPauseTimer?.cancel();
    _silenceCheckTimer?.cancel();

    if (_loadedGgufPath == null || !File(_loadedGgufPath!).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please select a .gguf model file first!")),
      );
      return;
    }

    await _stopTts();
    _ttsStreamBuffer = "";

    _playNativeTone("processing");

    final outgoingAttachments = List<AttachmentItem>.from(_selectedAttachments);
    final prompt = _buildCleanContextPrompt(text, outgoingAttachments);

    final userMsg = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      text: text,
      isUser: true,
      timestamp: DateTime.now(),
      attachments: outgoingAttachments,
    );

    final String assistantMsgId =
        (DateTime.now().millisecondsSinceEpoch + 1).toString();
    final assistantMsg = ChatMessage(
      id: assistantMsgId,
      text: "",
      isUser: false,
      timestamp: DateTime.now(),
    );

    setState(() {
      _currentSession.messages.add(userMsg);
      _currentSession.messages.add(assistantMsg);
      _currentSession.lastModified = DateTime.now();

      if (_currentSession.title.startsWith("Conversation") ||
          _currentSession.title == "New Conversation") {
        _currentSession.title = text.length > 24 ? "${text.substring(0, 24)}..." : text;
      }

      _textController.clear();
      _selectedAttachments.clear();
      _isProcessing = true;
    });

    _scrollToBottom();
    await _saveSessionsToDisk();

    try {
      await _llama.clearContext();
    } catch (_) {}

    final StringBuffer streamBuffer = StringBuffer();
    final completer = Completer<void>();

    try {
      final stream = _llama.generate(
        prompt: prompt,
        temperature: 0.6,
        maxTokens: 320,
        repeatPenalty: 1.18,
        repeatLastN: 64,
      );

      _activeInferenceSubscription = stream.listen(
        (token) {
          if (token.contains("<|im_end|>") ||
              token.contains("<|endoftext|>") ||
              token.contains("<|im_start|>") ||
              token.contains("User:") ||
              token.contains("\nUser")) {
            _activeInferenceSubscription?.cancel();
            _activeInferenceSubscription = null;
            _llama.stop();
            if (!completer.isCompleted) completer.complete();
            return;
          }

          streamBuffer.write(token);
          final currentText = streamBuffer.toString();

          if (mounted) {
            setState(() {
              final idx = _currentSession.messages.indexWhere((m) => m.id == assistantMsgId);
              if (idx != -1) {
                _currentSession.messages[idx] =
                    _currentSession.messages[idx].copyWith(text: currentText);
              }
            });
            _scrollToBottom();
          }

          // Smooth sentence-by-sentence TTS streaming (No restarts/cutting)
          if (_voiceResponseEnabled) {
            _ttsStreamBuffer += token;
            if (_ttsStreamBuffer.contains('.') ||
                _ttsStreamBuffer.contains('?') ||
                _ttsStreamBuffer.contains('!') ||
                _ttsStreamBuffer.contains('\n')) {
              final lastDelim = [
                _ttsStreamBuffer.lastIndexOf('.'),
                _ttsStreamBuffer.lastIndexOf('?'),
                _ttsStreamBuffer.lastIndexOf('!'),
                _ttsStreamBuffer.lastIndexOf('\n'),
              ].reduce((curr, next) => curr > next ? curr : next);

              if (lastDelim != -1) {
                final sentence = _ttsStreamBuffer.substring(0, lastDelim + 1);
                _ttsStreamBuffer = _ttsStreamBuffer.substring(lastDelim + 1);
                _enqueueTtsText(sentence, messageId: assistantMsgId);
              }
            }
          }
        },
        onError: (err, stack) {
          if (!completer.isCompleted) completer.complete();
          _showGlobalErrorDialog("Stream Error", err.toString(), stack.toString());
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
      );

      await completer.future.timeout(
        const Duration(seconds: 45),
        onTimeout: () {
          _activeInferenceSubscription?.cancel();
          _activeInferenceSubscription = null;
          _llama.stop();
        },
      );

      if (_voiceResponseEnabled && _ttsStreamBuffer.trim().isNotEmpty) {
        _enqueueTtsText(_ttsStreamBuffer.trim(), messageId: assistantMsgId);
      }

      final finalReply = streamBuffer.toString().trim();

      if (mounted) {
        setState(() {
          final idx = _currentSession.messages.indexWhere((m) => m.id == assistantMsgId);
          if (idx != -1) {
            _currentSession.messages[idx] = _currentSession.messages[idx].copyWith(
              text: finalReply.isNotEmpty ? finalReply : "(No response generated)",
            );
          }
          _isProcessing = false;
        });
        _scrollToBottom();
      } else {
        _isProcessing = false;
      }

      await _saveSessionsToDisk();
      _distillAndStoreMemory(text, finalReply);
    } catch (e, stack) {
      setState(() => _isProcessing = false);
      _showGlobalErrorDialog("Inference Error", e.toString(), stack.toString());
    }
  }

  String _buildCleanContextPrompt(String currentInput, List<AttachmentItem> attachments) {
    final buffer = StringBuffer();

    buffer.writeln("<|im_start|>system");
    buffer.writeln(_memoryBank.buildSystemContext());
    buffer.writeln("<|im_end|>");

    final existing = _currentSession.messages.where((m) => m.text.isNotEmpty).toList();
    final slice = existing.length > 2
        ? existing.sublist(existing.length - 2)
        : existing;

    for (final m in slice) {
      if (m.isUser) {
        buffer.writeln("<|im_start|>user\n${m.text}<|im_end|>");
      } else {
        buffer.writeln("<|im_start|>assistant\n${m.text}<|im_end|>");
      }
    }

    final StringBuffer attachmentText = StringBuffer();
    for (final a in attachments) {
      if (a.bytes != null && !a.isImage && a.size < 50000) {
        try {
          final decoded = utf8.decode(a.bytes!);
          final preview =
              decoded.length > 100 ? decoded.substring(0, 100) : decoded;
          attachmentText.writeln("[File: ${a.name}]: $preview");
        } catch (_) {}
      }
    }

    buffer.writeln("<|im_start|>user");
    if (attachmentText.isNotEmpty) {
      buffer.write(attachmentText.toString());
    }
    buffer.writeln("$currentInput<|im_end|>");
    buffer.writeln("<|im_start|>assistant");

    return buffer.toString();
  }

  /* ---------------- MEMORY REASONING EXTRACTION ---------------- */

  void _distillAndStoreMemory(String prompt, String reply) {
    unawaited(() async {
      final cleanPrompt = prompt.trim();
      final cleanReply = reply.trim();
      if (cleanPrompt.length < 3) return;

      final lower = cleanPrompt.toLowerCase();
      String category = "Discussion";
      String importance = "Medium";
      String reasoning = "General knowledge and context from conversation turn.";
      String distilledFact = cleanPrompt;

      if (lower.contains("my name is") ||
          lower.contains("call me") ||
          lower.startsWith("i am ") ||
          lower.startsWith("i'm ") ||
          lower.contains("i live in") ||
          lower.contains("i work as")) {
        category = "Identity";
        importance = "High";
        reasoning = "Core user identity and biographical declaration.";
        distilledFact = cleanPrompt;
      } else if (lower.contains("i like") ||
          lower.contains("i love") ||
          lower.contains("i prefer") ||
          lower.contains("i hate") ||
          lower.contains("i dislike") ||
          lower.contains("my favorite")) {
        category = "Preference";
        importance = "High";
        reasoning = "User expression of preference to tailor future assistance.";
        distilledFact = cleanPrompt;
      } else if (lower.contains("remember") ||
          lower.contains("don't forget") ||
          lower.contains("always") ||
          lower.contains("never")) {
        category = "Directive";
        importance = "High";
        reasoning = "Explicit instruction by user for permanent retention.";
        distilledFact = cleanPrompt;
      } else if (cleanPrompt.length >= 10 && cleanReply.length >= 10) {
        category = "Discussion";
        importance = "Medium";
        reasoning = "Key exchange regarding topic and context.";
        final shortReply = cleanReply.length > 70 ? "${cleanReply.substring(0, 70)}..." : cleanReply;
        distilledFact = "User asked: \"$cleanPrompt\" | Summary: $shortReply";
      } else {
        return;
      }

      final existingIndex = _memoryBank.facts.indexWhere(
        (f) => f.fact.toLowerCase() == distilledFact.toLowerCase(),
      );

      if (existingIndex != -1) {
        _memoryBank.facts[existingIndex] = LearnedMemoryFact(
          id: _memoryBank.facts[existingIndex].id,
          fact: distilledFact,
          reasoning: reasoning,
          importance: importance,
          category: category,
          learnedAt: DateTime.now(),
        );
      } else {
        _memoryBank.facts.insert(
          0,
          LearnedMemoryFact(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            fact: distilledFact,
            reasoning: reasoning,
            importance: importance,
            category: category,
            learnedAt: DateTime.now(),
          ),
        );
      }

      if (_memoryBank.facts.length > 80) {
        _memoryBank.facts = _memoryBank.facts.sublist(0, 80);
      }

      await _saveMemoryToDisk();
      if (mounted) setState(() {});
    }());
  }

  void _deleteMemory(int index) async {
    setState(() {
      _memoryBank.facts.removeAt(index);
    });
    await _saveMemoryToDisk();
  }

  void _clearAllMemories() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2230),
        title: const Text("Clear All Memories?"),
        content: const Text("This will permanently wipe all evaluated facts and reasoning from the memory bank."),
        actions: [
          TextButton(
            child: const Text("Cancel"),
            onPressed: () => Navigator.pop(ctx, false),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text("Wipe All"),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );

    if (confirm == true) {
      setState(() {
        _memoryBank.facts.clear();
      });
      await _saveMemoryToDisk();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("All memories cleared.")),
        );
      }
    }
  }

  void _scrollToBottom() {
    if (!mounted || !_scrollController.hasClients) return;

    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
    );
  }

  /* ---------------- UI CONSTRUCTION ---------------- */

  @override
  Widget build(BuildContext context) {
    final currentMessages = _currentSession.messages;

    return Scaffold(
      key: _scaffoldKey,
      drawer: _buildSessionsDrawer(),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141721),
        leading: IconButton(
          tooltip: "Chat History",
          icon: const Icon(Icons.forum_outlined, color: Colors.white70),
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        ),
        title: GestureDetector(
          onTap: _isProcessing ? null : _selectGgufModel,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_currentSession.title,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis),
              Text(
                _modelStatus,
                style: const TextStyle(fontSize: 10, color: Color(0xFF00D2FF)),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: _callModeActive ? "Call Mode: Active" : "Call Mode: Disconnected",
            icon: Icon(
              _callModeActive ? Icons.phone_in_talk : Icons.phone_outlined,
              color: _callModeActive ? Colors.greenAccent : Colors.white38,
            ),
            onPressed: _toggleCallMode,
          ),
          IconButton(
            tooltip: "New Chat",
            icon: const Icon(Icons.add_comment_outlined, color: Color(0xFF00D2FF)),
            onPressed: () => _createNewSession(),
          ),
          IconButton(
            tooltip: _voiceResponseEnabled ? "TTS Audio: ON" : "TTS Audio: OFF",
            icon: Icon(
              _voiceResponseEnabled ? Icons.volume_up : Icons.volume_off,
              color: _voiceResponseEnabled ? const Color(0xFF00D2FF) : Colors.grey,
            ),
            onPressed: () async {
              setState(() => _voiceResponseEnabled = !_voiceResponseEnabled);
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('saved_tts_enabled', _voiceResponseEnabled);
              if (!_voiceResponseEnabled) _stopTts();
            },
          ),
          IconButton(
            tooltip: "Memory Bank",
            icon: Badge(
              isLabelVisible: _memoryBank.facts.isNotEmpty,
              label: Text(_memoryBank.facts.length.toString()),
              backgroundColor: const Color(0xFF6C63FF),
              child: const Icon(Icons.psychology, color: Color(0xFF6C63FF)),
            ),
            onPressed: _showMemoryModal,
          ),
          IconButton(
            tooltip: "Settings & Triggers",
            icon: const Icon(Icons.settings_suggest, color: Colors.white70, size: 22),
            onPressed: _showSettingsDialog,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_callModeActive)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 12),
              color: _isCallModeAsleep ? Colors.amber.shade900 : Colors.green.shade900,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(_isCallModeAsleep ? Icons.bedtime : Icons.headset_mic, size: 14, color: Colors.white),
                  const SizedBox(width: 8),
                  Text(
                    _isCallModeAsleep
                        ? "Standby. Say '$_wakeWord' to resume."
                        : "Call Active (Screen-Off/Background). Say '$_stopWord' anytime to stop.",
                    style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          Expanded(
            child: currentMessages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.bolt, size: 48, color: Colors.white.withValues(alpha: 0.2)),
                        const SizedBox(height: 8),
                        Text(
                          "${_currentSession.title}\nReady to chat",
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 13),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemCount: currentMessages.length,
                    itemBuilder: (context, i) {
                      final m = currentMessages[i];
                      return _buildMessageItem(m);
                    },
                  ),
          ),
          if (_isProcessing)
            const LinearProgressIndicator(
              backgroundColor: Color(0xFF141721),
              valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF00D2FF)),
              minHeight: 2,
            ),
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildSessionsDrawer() {
    return Drawer(
      backgroundColor: const Color(0xFF141721),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    "Chat History",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_box_rounded, color: Color(0xFF00D2FF)),
                    onPressed: () {
                      Navigator.pop(context);
                      _createNewSession();
                    },
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Colors.white10),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: _sessions.length,
                separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white10),
                itemBuilder: (context, i) {
                  final s = _sessions[i];
                  final isCurrent = s.id == _currentSessionId;

                  return ListTile(
                    dense: true,
                    selected: isCurrent,
                    selectedTileColor: const Color(0xFF1E2230),
                    leading: Icon(
                      Icons.chat_bubble_outline,
                      size: 18,
                      color: isCurrent ? const Color(0xFF00D2FF) : Colors.white38,
                    ),
                    title: Text(
                      s.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isCurrent ? Colors.white : Colors.white70,
                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    subtitle: Text(
                      "${s.messages.length} messages • ${s.lastModified.hour}:${s.lastModified.minute.toString().padLeft(2, '0')}",
                      style: const TextStyle(fontSize: 10, color: Colors.white38),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 16, color: Colors.white38),
                      onPressed: () => _deleteSession(s.id),
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      _switchSession(s.id);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageItem(ChatMessage m) {
    final isPlaying = _currentlySpeakingMessageId == m.id;

    return Align(
      alignment: m.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.85,
        ),
        child: Column(
          crossAxisAlignment:
              m.isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: m.isUser ? const Color(0xFF6C63FF) : const Color(0xFF1E2230),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                m.text.isEmpty && !m.isUser ? "..." : m.text,
                style: const TextStyle(fontSize: 14, color: Colors.white, height: 1.35),
              ),
            ),
            if (!m.isUser && m.text.isNotEmpty && m.text != "...")
              Padding(
                padding: const EdgeInsets.only(top: 2, left: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => _toggleMessageSpeech(m),
                      child: Padding(
                        padding: const EdgeInsets.all(4.0),
                        child: Icon(
                          isPlaying ? Icons.stop_circle : Icons.volume_up_outlined,
                          size: 18,
                          color: isPlaying ? Colors.redAccent : Colors.white60,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: m.text));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text("Response copied to clipboard"),
                            duration: Duration(seconds: 1),
                          ),
                        );
                      },
                      child: const Padding(
                        padding: EdgeInsets.all(4.0),
                        child: Icon(
                          Icons.copy_rounded,
                          size: 16,
                          color: Colors.white60,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      color: const Color(0xFF141721),
      child: SafeArea(
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.attach_file, color: Colors.white70),
              onPressed: _isProcessing
                  ? null
                  : () async {
                      final List<XFile> files = await openFiles();
                      if (files.isNotEmpty) {
                        for (final f in files) {
                          final bytes = await f.readAsBytes();
                          final size = await f.length();
                          final ext =
                              f.name.contains('.') ? f.name.split('.').last : '';
                          setState(() {
                            _selectedAttachments.add(
                              AttachmentItem(
                                id: DateTime.now().millisecondsSinceEpoch.toString(),
                                name: f.name,
                                path: f.path,
                                size: size,
                                extension: ext,
                                bytes: bytes,
                              ),
                            );
                          });
                        }
                      }
                    },
            ),
            IconButton(
              tooltip: _autoMicSend ? "Auto-Send: ON" : "Manual Mic",
              icon: Stack(
                alignment: Alignment.topRight,
                children: [
                  Icon(
                    _isListening ? Icons.mic : Icons.mic_none,
                    color: _isListening ? Colors.redAccent : Colors.white70,
                  ),
                  if (_autoMicSend)
                    Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        color: Colors.greenAccent,
                        shape: BoxShape.circle,
                      ),
                    ),
                ],
              ),
              onPressed: _isProcessing
                  ? null
                  : () async {
                      if (!_speechEnabled) return;
                      if (_isListening) {
                        _speechPauseTimer?.cancel();
                        await _speech.stop();
                        setState(() => _isListening = false);
                      } else {
                        setState(() => _isListening = true);
                        await _speech.listen(
                          onResult: (SpeechRecognitionResult result) {
                            setState(() => _textController.text = result.recognizedWords);

                            _speechPauseTimer?.cancel();
                            if (_autoMicSend && result.recognizedWords.trim().isNotEmpty) {
                              _speechPauseTimer = Timer(const Duration(milliseconds: 1400), () {
                                if (_textController.text.trim().isNotEmpty && !_isProcessing) {
                                  _handleSendMessage();
                                }
                              });
                            }
                          },
                        );
                      }
                    },
            ),
            Expanded(
              child: TextField(
                controller: _textController,
                enabled: !_isProcessing,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: _isProcessing
                      ? "Generating..."
                      : _isListening
                          ? (_autoMicSend ? "Listening (Auto-Send)..." : "Listening...")
                          : "Message companion...",
                  hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.3)),
                  filled: true,
                  fillColor: const Color(0xFF1E2230),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                ),
                onSubmitted: (_) => _handleSendMessage(),
              ),
            ),
            IconButton(
              icon: Icon(
                _isProcessing ? Icons.stop_circle : Icons.send,
                color: _isProcessing ? Colors.redAccent : const Color(0xFF6C63FF),
                size: _isProcessing ? 28 : 24,
              ),
              onPressed: _isProcessing ? _stopGeneration : _handleSendMessage,
            ),
          ],
        ),
      ),
    );
  }

  /* ---------------- OPTIONS & WAKE/STOP TRIGGER SETTINGS ---------------- */

  void _showSettingsDialog() {
    final wakeCtrl = TextEditingController(text: _wakeWord);
    final stopCtrl = TextEditingController(text: _stopWord);

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E2230),
            title: const Text("Audio & Voice Triggers", style: TextStyle(color: Colors.white, fontSize: 16)),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text("Auto-Send After Speaking", style: TextStyle(fontSize: 13, color: Colors.white)),
                    subtitle: const Text("Submits prompt after 1.4s speech pause", style: TextStyle(fontSize: 11, color: Colors.white38)),
                    value: _autoMicSend,
                    activeColor: const Color(0xFF00D2FF),
                    onChanged: (val) async {
                      setDlgState(() => _autoMicSend = val);
                      setState(() => _autoMicSend = val);
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setBool('saved_auto_mic', val);
                    },
                  ),
                  const Divider(color: Colors.white10),
                  const Text("Barge-In Stop Word:", style: TextStyle(fontSize: 12, color: Colors.white70, fontWeight: FontWeight.bold)),
                  const Text("Stops response & speech while model is talking.", style: TextStyle(fontSize: 10, color: Colors.white38)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: stopCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: "e.g. stop, wait, enough",
                      filled: true,
                      fillColor: const Color(0xFF141721),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text("Ambient Wake-Up Word:", style: TextStyle(fontSize: 12, color: Colors.white70, fontWeight: FontWeight.bold)),
                  const Text("Wakes model from standby after 20s of silence.", style: TextStyle(fontSize: 10, color: Colors.white38)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: wakeCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: "e.g. wake up, hey companion",
                      filled: true,
                      fillColor: const Color(0xFF141721),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                child: const Text("Cancel"),
                onPressed: () => Navigator.pop(ctx),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF6C63FF)),
                child: const Text("Save Triggers"),
                onPressed: () async {
                  setState(() {
                    _stopWord = stopCtrl.text.trim().isNotEmpty ? stopCtrl.text.trim() : "stop";
                    _wakeWord = wakeCtrl.text.trim().isNotEmpty ? wakeCtrl.text.trim() : "wake up";
                  });
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString('saved_stop_word', _stopWord);
                  await prefs.setString('saved_wake_word', _wakeWord);
                  Navigator.pop(ctx);
                },
              ),
            ],
          );
        },
      ),
    );
  }

  /* ---------------- COGNITIVE MEMORY MODAL WITH REASONING ---------------- */

  void _showMemoryModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1D26),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return FractionallySizedBox(
              heightFactor: 0.8,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          "Memory Bank (${_memoryBank.facts.length})",
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                        if (_memoryBank.facts.isNotEmpty)
                          TextButton.icon(
                            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
                            icon: const Icon(Icons.delete_forever, size: 18),
                            label: const Text("Clear All"),
                            onPressed: () {
                              Navigator.pop(ctx);
                              _clearAllMemories();
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.upload, size: 16),
                            label: const Text("Export"),
                            onPressed: () async {
                              final file = await _getLocalMemoryFile();
                              await _saveMemoryToDisk();
                              if (await file.exists()) {
                                await Share.shareXFiles([XFile(file.path)]);
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.download, size: 16),
                            label: const Text("Import"),
                            onPressed: () async {
                              const jsonTypeGroup = XTypeGroup(
                                label: 'JSON Files',
                                extensions: ['json'],
                              );
                              final XFile? file = await openFile(
                                acceptedTypeGroups: const [jsonTypeGroup],
                              );
                              if (file != null) {
                                final bytes = await file.readAsBytes();
                                final data = jsonDecode(utf8.decode(bytes));
                                setState(() => _memoryBank.importFromJson(data));
                                setModalState(() {});
                                await _saveMemoryToDisk();
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const Divider(height: 24),
                    Expanded(
                      child: _memoryBank.facts.isEmpty
                          ? const Center(
                              child: Text(
                                "No memories distilled yet.\nSend prompts to automatically extract evaluated knowledge.",
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.white38, fontSize: 13),
                              ),
                            )
                          : ListView.separated(
                              itemCount: _memoryBank.facts.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1, color: Colors.white10),
                              itemBuilder: (_, i) {
                                final item = _memoryBank.facts[i];
                                final isHigh = item.importance == "High";

                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 6.0),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: isHigh
                                              ? Colors.amberAccent.withValues(alpha: 0.2)
                                              : Colors.blueAccent.withValues(alpha: 0.2),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          item.category,
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            color: isHigh ? Colors.amberAccent : Colors.lightBlueAccent,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              item.fact,
                                              style: const TextStyle(fontSize: 13, color: Colors.white),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              "Reasoning: ${item.reasoning}",
                                              style: const TextStyle(fontSize: 11, color: Colors.white54, fontStyle: FontStyle.italic),
                                            ),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.close, size: 16, color: Colors.redAccent),
                                        onPressed: () {
                                          _deleteMemory(i);
                                          setModalState(() {});
                                        },
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
