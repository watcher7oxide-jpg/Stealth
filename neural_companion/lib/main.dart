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

class LearnedMemoryFact {
  final String id;
  final String fact;
  final String category;
  final DateTime learnedAt;

  LearnedMemoryFact({
    required this.id,
    required this.fact,
    required this.category,
    required this.learnedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'fact': fact,
        'category': category,
        'learnedAt': learnedAt.toIso8601String(),
      };

  factory LearnedMemoryFact.fromJson(Map<String, dynamic> json) =>
      LearnedMemoryFact(
        id: json['id'] ?? '',
        fact: json['fact'] ?? '',
        category: json['category'] ?? 'general',
        learnedAt:
            DateTime.tryParse(json['learnedAt'] ?? '') ?? DateTime.now(),
      );
}

class CognitiveMemoryBank {
  String personaOverview = "Helpful personal companion.";
  List<LearnedMemoryFact> facts = [];

  Map<String, dynamic> toJson() => {
        'format': 'NeuralMemory_v2',
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
      buffer.write("Facts about user: ");
      for (final f in facts.take(6)) {
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

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  final List<ChatMessage> _messages = [];
  final List<AttachmentItem> _selectedAttachments = [];

  final CognitiveMemoryBank _memoryBank = CognitiveMemoryBank();
  final LlamaController _llama = LlamaController();

  // Voice & TTS State
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();
  bool _speechEnabled = false;
  bool _isListening = false;
  bool _voiceResponseEnabled = false;

  // Active audio player state
  String? _currentlySpeakingMessageId;
  final List<String> _ttsQueue = [];
  bool _isTtsProcessingQueue = false;
  String _ttsStreamBuffer = "";

  // Inference state
  String? _loadedGgufPath;
  String _modelStatus = "No .gguf loaded";
  bool _isProcessing = false;
  StreamSubscription<String>? _activeInferenceSubscription;

  static const MethodChannel _pickerChannel =
      MethodChannel('com.example.neural_companion/file_picker');

  @override
  void initState() {
    super.initState();
    _checkPreviousNativeCrash();
    _initSpeechEngine();
    _initTtsEngine();
    _loadSavedState();
  }

  @override
  void dispose() {
    _activeInferenceSubscription?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    _speech.stop();
    _tts.stop();
    _llama.dispose();
    super.dispose();
  }

  /* ---------------- PERSISTENT CHAT & MEMORY STORAGE ---------------- */

  Future<File> _getChatHistoryFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/chat_history_v2.json');
  }

  Future<void> _saveChatHistoryToDisk() async {
    try {
      final file = await _getChatHistoryFile();
      final List<Map<String, dynamic>> jsonList =
          _messages.map((m) => m.toJson()).toList();
      await file.writeAsString(jsonEncode(jsonList));
    } catch (_) {}
  }

  Future<void> _loadChatHistoryFromDisk() async {
    try {
      final file = await _getChatHistoryFile();
      if (await file.exists()) {
        final content = await file.readAsString();
        final List<dynamic> jsonList = jsonDecode(content);
        setState(() {
          _messages.clear();
          for (final item in jsonList) {
            _messages.add(ChatMessage.fromJson(item as Map<String, dynamic>));
          }
        });
        _scrollToBottom();
      }
    } catch (_) {}
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
    await _loadMemoryFromDisk();
    await _loadChatHistoryFromDisk();
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

  Future<void> _initSpeechEngine() async {
    try {
      _speechEnabled = await _speech.initialize(
        onError: (_) => setState(() => _isListening = false),
        onStatus: (val) {
          if (val == 'done' || val == 'notListening') {
            setState(() => _isListening = false);
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
    await _tts.setSpeechRate(0.55);
    await _tts.setVolume(1.0);

    _tts.setCompletionHandler(() {
      _isTtsProcessingQueue = false;
      _processNextTtsQueueItem();
    });

    _tts.setErrorHandler((_) {
      setState(() {
        _isTtsProcessingQueue = false;
        _currentlySpeakingMessageId = null;
      });
    });
  }

  /* ---------------- ROBUST AUDIO TTS CONTROLLER ---------------- */

  void _enqueueTtsText(String sentence, {String? messageId}) {
    final clean = sentence.trim();
    if (clean.isEmpty) return;

    if (messageId != null && _currentlySpeakingMessageId != messageId) {
      _stopTts();
      _currentlySpeakingMessageId = messageId;
    }

    _ttsQueue.add(clean);
    _processNextTtsQueueItem();
  }

  Future<void> _processNextTtsQueueItem() async {
    if (_isTtsProcessingQueue || _ttsQueue.isEmpty) {
      if (_ttsQueue.isEmpty && _currentlySpeakingMessageId != null) {
        setState(() => _currentlySpeakingMessageId = null);
      }
      return;
    }

    _isTtsProcessingQueue = true;
    final nextText = _ttsQueue.removeAt(0);
    await _tts.speak(nextText);
  }

  Future<void> _stopTts() async {
    _ttsQueue.clear();
    _isTtsProcessingQueue = false;
    _ttsStreamBuffer = "";
    await _tts.stop();
    if (mounted) {
      setState(() => _currentlySpeakingMessageId = null);
    }
  }

  /// Plays or halts speech for a single specific message
  Future<void> _toggleMessageSpeech(ChatMessage msg) async {
    if (_currentlySpeakingMessageId == msg.id) {
      // Tapping the playing message stops it immediately
      await _stopTts();
    } else {
      // Tapping a different message stops the previous one and starts the new one
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
      _processNextTtsQueueItem();
    }
  }

  /* ---------------- GGUF SELECTION & LOADING ---------------- */

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
          await _pickerChannel.invokeMethod<String>('pickGgufFile');

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

  /* ---------------- INFERENCE ENGINE & ANTI-HALLUCINATION FIX ---------------- */

  Future<void> _stopGeneration() async {
    if (_activeInferenceSubscription != null) {
      await _activeInferenceSubscription!.cancel();
      _activeInferenceSubscription = null;
    }

    // Force C++ native thread stop
    try {
      await _llama.stop();
    } catch (_) {}

    await _stopTts();

    setState(() {
      _isProcessing = false;
      if (_messages.isNotEmpty && !_messages.last.isUser && _messages.last.text.isEmpty) {
        _messages.last = _messages.last.copyWith(text: "(Stopped)");
      }
    });

    await _saveChatHistoryToDisk();
  }

  Future<void> _handleSendMessage() async {
    if (_isProcessing) return; // Prevent prompt collision

    final text = _textController.text.trim();
    if (text.isEmpty && _selectedAttachments.isEmpty) return;

    if (_isListening) {
      await _speech.stop();
      _isListening = false;
    }

    if (_loadedGgufPath == null || !File(_loadedGgufPath!).existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please select a .gguf model file first!")),
      );
      return;
    }

    await _stopTts();
    _ttsStreamBuffer = "";

    final outgoingAttachments = List<AttachmentItem>.from(_selectedAttachments);

    // 1. Build prompt strictly before adding to state (no duplicate turns)
    final prompt = _buildCleanContextPrompt(text, outgoingAttachments);

    // 2. Add Messages to UI
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
      _messages.add(userMsg);
      _messages.add(assistantMsg);
      _textController.clear();
      _selectedAttachments.clear();
      _isProcessing = true;
    });

    _scrollToBottom();
    await _saveChatHistoryToDisk();

    // 3. Wipe dirty KV cache from previous prompt (PREVENTS COLLISION & DRUNKARD LOOPS)
    try {
      await _llama.clearContext();
    } catch (_) {}

    final StringBuffer streamBuffer = StringBuffer();
    final completer = Completer<void>();

    try {
      // 4. Generate with repetition penalties
      final stream = _llama.generate(
        prompt: prompt,
        temperature: 0.6,
        maxTokens: 300,
        repeatPenalty: 1.18, // Forbids infinite repetition of "Tot Tot" or "()"
        repeatLastN: 64
      );

      _activeInferenceSubscription = stream.listen(
        (token) {
          // Immediately kill stream if stop token arrives
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

          // Live screen update
          setState(() {
            final idx = _messages.indexWhere((m) => m.id == assistantMsgId);
            if (idx != -1) {
              _messages[idx] = _messages[idx].copyWith(text: currentText);
            }
          });
          _scrollToBottom();

          // Sentence-by-sentence streaming speech
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

      // Speak any remaining sentence tail
      if (_voiceResponseEnabled && _ttsStreamBuffer.trim().isNotEmpty) {
        _enqueueTtsText(_ttsStreamBuffer.trim(), messageId: assistantMsgId);
      }

      final finalReply = streamBuffer.toString().trim();

      setState(() {
        final idx = _messages.indexWhere((m) => m.id == assistantMsgId);
        if (idx != -1) {
          _messages[idx] = _messages[idx].copyWith(
            text: finalReply.isNotEmpty ? finalReply : "(No response generated)",
          );
        }
        _isProcessing = false;
      });

      _scrollToBottom();
      await _saveChatHistoryToDisk();

      _autoExtractMemory(text, finalReply);
    } catch (e, stack) {
      setState(() => _isProcessing = false);
      _showGlobalErrorDialog("Inference Error", e.toString(), stack.toString());
    }
  }

  /// Compact ChatML prompt builder avoiding duplicate history
  String _buildCleanContextPrompt(String currentInput, List<AttachmentItem> attachments) {
    final buffer = StringBuffer();

    // 1. System Prompt
    buffer.writeln("<|im_start|>system");
    buffer.writeln(_memoryBank.buildSystemContext());
    buffer.writeln("<|im_end|>");

    // 2. Last 1 turn of history (2 messages max) to keep context pure for SmolLM2
    final existingMessages = _messages.where((m) => m.text.isNotEmpty).toList();
    final slice = existingMessages.length > 2
        ? existingMessages.sublist(existingMessages.length - 2)
        : existingMessages;

    for (final m in slice) {
      if (m.isUser) {
        buffer.writeln("<|im_start|>user\n${m.text}<|im_end|>");
      } else {
        buffer.writeln("<|im_start|>assistant\n${m.text}<|im_end|>");
      }
    }

    // 3. Attachments preview
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

    // 4. Current user prompt
    buffer.writeln("<|im_start|>user");
    if (attachmentText.isNotEmpty) {
      buffer.write(attachmentText.toString());
    }
    buffer.writeln("$currentInput<|im_end|>");
    buffer.writeln("<|im_start|>assistant");

    return buffer.toString();
  }

  /* ---------------- CONTINUOUS DISCUSSION ARCHIVAL ---------------- */

  void _autoExtractMemory(String userText, String assistantReply) {
    unawaited(() async {
      final cleanInput = userText.trim();
      if (cleanInput.length < 4) return;

      final lower = cleanInput.toLowerCase();

      final bool isFact = lower.contains("my name is") ||
          lower.contains("i am") ||
          lower.contains("i'm") ||
          lower.contains("remember") ||
          lower.contains("prefer") ||
          lower.contains("i live") ||
          lower.contains("i work");

      if (isFact) {
        final existing = _memoryBank.facts.any(
          (f) => f.fact.toLowerCase() == cleanInput.toLowerCase(),
        );

        if (!existing) {
          _memoryBank.facts.insert(
            0,
            LearnedMemoryFact(
              id: DateTime.now().millisecondsSinceEpoch.toString(),
              fact: cleanInput,
              category: 'identity',
              learnedAt: DateTime.now(),
            ),
          );
        }
      }

      if (_memoryBank.facts.length > 50) {
        _memoryBank.facts = _memoryBank.facts.sublist(0, 50);
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
        content: const Text("This will permanently remove all stored facts from the cognitive bank."),
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

  void _clearChatHistory() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E2230),
        title: const Text("Clear Chat?"),
        content: const Text("This resets the screen without erasing facts in the Memory Bank."),
        actions: [
          TextButton(
            child: const Text("Cancel"),
            onPressed: () => Navigator.pop(ctx, false),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text("Clear"),
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _stopTts();
      setState(() {
        _messages.clear();
      });
      await _saveChatHistoryToDisk();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /* ---------------- UI CONSTRUCTION ---------------- */

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF141721),
        title: GestureDetector(
          onTap: _isProcessing ? null : _selectGgufModel,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Neural Companion", style: TextStyle(fontSize: 16)),
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
            tooltip: "System Logs",
            icon: const Icon(Icons.terminal, color: Colors.amberAccent),
            onPressed: _showDeviceLogcat,
          ),
          IconButton(
            tooltip: "Clear Screen",
            icon: const Icon(Icons.delete_sweep, color: Colors.white70),
            onPressed: _clearChatHistory,
          ),
          IconButton(
            tooltip: _voiceResponseEnabled ? "TTS Auto: On" : "TTS Auto: Off",
            icon: Icon(
              _voiceResponseEnabled ? Icons.volume_up : Icons.volume_off,
              color: _voiceResponseEnabled ? const Color(0xFF00D2FF) : Colors.grey,
            ),
            onPressed: () {
              setState(() => _voiceResponseEnabled = !_voiceResponseEnabled);
              if (!_voiceResponseEnabled) _stopTts();
            },
          ),
          IconButton(
            tooltip: "Memory Bank",
            icon: const Icon(Icons.psychology, color: Color(0xFF6C63FF)),
            onPressed: _showMemoryModal,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.bolt, size: 48, color: Colors.white.withValues(alpha: 0.2)),
                        const SizedBox(height: 8),
                        Text(
                          "SmolLM Engine Ready\nContext-Protected Memory Active",
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 13),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    itemCount: _messages.length,
                    itemBuilder: (context, i) {
                      final m = _messages[i];
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
            // Per-Response Action Bar (Speaker & Copy)
            if (!m.isUser && m.text.isNotEmpty && m.text != "...")
              Padding(
                padding: const EdgeInsets.only(top: 2, left: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Speaker / Stop Toggle
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
                    // Copy Button
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
              icon: Icon(
                _isListening ? Icons.mic : Icons.mic_none,
                color: _isListening ? Colors.redAccent : Colors.white70,
              ),
              onPressed: _isProcessing
                  ? null
                  : () async {
                      if (!_speechEnabled) return;
                      if (_isListening) {
                        await _speech.stop();
                        setState(() => _isListening = false);
                      } else {
                        setState(() => _isListening = true);
                        await _speech.listen(onResult: (SpeechRecognitionResult result) {
                          setState(() => _textController.text = result.recognizedWords);
                        });
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
                          ? "Listening..."
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
            // Dynamic Stop / Send Button
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

  /* ---------------- MEMORY BANK MODAL (EDIT & DELETE) ---------------- */

  void _showMemoryModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1D26),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return FractionallySizedBox(
              heightFactor: 0.75,
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
                                "No memories stored yet.\nTalk with the model to automatically accumulate knowledge.",
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.white38, fontSize: 13),
                              ),
                            )
                          : ListView.separated(
                              itemCount: _memoryBank.facts.length,
                              separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white10),
                              itemBuilder: (_, i) {
                                final item = _memoryBank.facts[i];
                                return ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(
                                    item.fact,
                                    style: const TextStyle(fontSize: 13, color: Colors.white),
                                  ),
                                  subtitle: Text(
                                    "${item.category} • ${item.learnedAt.hour}:${item.learnedAt.minute.toString().padLeft(2, '0')}",
                                    style: const TextStyle(fontSize: 10, color: Colors.white38),
                                  ),
                                  trailing: IconButton(
                                    icon: const Icon(Icons.close, size: 16, color: Colors.redAccent),
                                    onPressed: () {
                                      _deleteMemory(i);
                                      setModalState(() {});
                                    },
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

  Future<void> _showDeviceLogcat() async {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141721),
        title: const Text("Device System Logs", style: TextStyle(color: Color(0xFF00D2FF), fontSize: 16)),
        content: FutureBuilder<ProcessResult>(
          future: Process.run('logcat', ['-d', '-v', 'brief', '-t', '150']),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const SizedBox(
                height: 120,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final logs = snapshot.data?.stdout?.toString() ?? "No logcat output available";
            return SizedBox(
              width: double.maxFinite,
              height: 400,
              child: SingleChildScrollView(
                child: SelectableText(
                  logs,
                  style: const TextStyle(fontSize: 10, fontFamily: 'monospace', color: Colors.white70),
                ),
              ),
            );
          },
        ),
        actions: [
          TextButton(
            child: const Text("Close"),
            onPressed: () => Navigator.pop(ctx),
          ),
        ],
      ),
    );
  }
}
