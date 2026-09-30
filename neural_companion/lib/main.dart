import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart' hide ChatMessage;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NeuralChatApp());
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

/* ========================================================================== */
/*                PERSISTENT COGNITIVE MEMORY ENGINE                          */
/* ========================================================================== */

class CognitiveMemoryBank {
  String personaOverview = "Helpful personal collaborator.";
  List<LearnedMemoryFact> facts = [];

  Map<String, dynamic> toJson() => {
        'format': 'NeuralMemory_v1',
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
    buffer.write("System: You are an autonomous AI companion. ");
    if (facts.isNotEmpty) {
      buffer.write("Known facts: ");
      for (final f in facts.take(10)) {
        buffer.write("[${f.fact}] ");
      }
    }
    return buffer.toString();
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

  // Native GGUF Controller
  final LlamaController _llama = LlamaController();

  // Voice & Audio
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();
  bool _speechEnabled = false;
  bool _isListening = false;
  bool _voiceResponseEnabled = true;

  // Model & State
  String? _loadedGgufPath;
  String _modelStatus = "No .gguf loaded";
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _initSpeechEngine();
    _initTtsEngine();
    _loadSavedState();
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    _speech.stop();
    _tts.stop();
    _llama.dispose();
    super.dispose();
  }

  Future<void> _loadSavedState() async {
    final prefs = await SharedPreferences.getInstance();
    final savedPath = prefs.getString('saved_gguf_path');
    if (savedPath != null && await File(savedPath).exists()) {
      _bindModel(savedPath);
    }
    await _loadMemoryFromDisk();
  }

  Future<void> _bindModel(String path) async {
    try {
      setState(() => _modelStatus = "Loading model...");
      await _llama.loadModel(
        modelPath: path,
        threads: 2,
        contextSize: 1024,
      );
      setState(() {
        _loadedGgufPath = path;
        _modelStatus = "Ready: ${path.split('/').last}";
      });
    } catch (e) {
      setState(() => _modelStatus = "Load failed: $e");
    }
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
    await _tts.setSpeechRate(0.52);
    await _tts.setVolume(1.0);
  }

  Future<void> _selectGgufModel() async {
    try {
      const typeGroup = XTypeGroup(
        label: 'GGUF Models',
        extensions: ['gguf'],
      );
      final XFile? file = await openFile(
        acceptedTypeGroups: const [typeGroup],
      );

      if (file != null) {
        final path = file.path;
        if (!path.toLowerCase().endsWith('.gguf')) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Please select a valid .gguf file")),
            );
          }
          return;
        }

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('saved_gguf_path', path);

        await _bindModel(path);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Model bound: ${file.name}")),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Failed to select file: $e")),
        );
      }
    }
  }

  /* ---------------- Inference Engine (4GB RAM Tuned) ---------------- */

  Future<String> _runGgufInference(
    String userText,
    List<AttachmentItem> attachments,
  ) async {
    if (_loadedGgufPath == null || !File(_loadedGgufPath!).existsSync()) {
      return "No .gguf model selected. Tap the header to select your model file.";
    }

    final StringBuffer promptBuffer = StringBuffer();
    promptBuffer.writeln(_memoryBank.buildSystemContext());

    final recent = _messages.length > 3
        ? _messages.sublist(_messages.length - 3)
        : _messages;
    for (final m in recent) {
      promptBuffer.writeln("${m.isUser ? 'User' : 'Assistant'}: ${m.text}");
    }

    for (final a in attachments) {
      if (a.bytes != null && !a.isImage && a.size < 50000) {
        try {
          final decoded = utf8.decode(a.bytes!);
          final preview =
              decoded.length > 200 ? decoded.substring(0, 200) : decoded;
          promptBuffer.writeln("[Attached Text (${a.name})]: $preview");
        } catch (_) {}
      } else {
        promptBuffer.writeln("[Attached File: ${a.name}]");
      }
    }

    promptBuffer.writeln("User: $userText\nAssistant:");

    final StringBuffer outputBuffer = StringBuffer();
    final completer = Completer<String>();

    try {
      final stream = _llama.generate(
        prompt: promptBuffer.toString(),
        temperature: 0.7,
        maxTokens: 300,
      );

      final subscription = stream.listen(
        (token) {
          outputBuffer.write(token);
        },
        onError: (err) {
          if (!completer.isCompleted) completer.complete("Inference error: $err");
        },
        onDone: () {
          if (!completer.isCompleted) {
            completer.complete(outputBuffer.toString().trim());
          }
        },
      );

      return await completer.future.timeout(
        const Duration(seconds: 45),
        onTimeout: () {
          subscription.cancel();
          return outputBuffer.isNotEmpty
              ? outputBuffer.toString().trim()
              : "Response timed out under current hardware limits.";
        },
      );
    } catch (e) {
      return "Execution halted: $e";
    }
  }

  void _triggerSimultaneousLearning(
    String userPrompt,
    List<AttachmentItem> attachments,
  ) {
    unawaited(() async {
      final lower = userPrompt.toLowerCase();
      if (lower.contains("i like") ||
          lower.contains("i prefer") ||
          lower.contains("my name") ||
          lower.contains("remember")) {
        _memoryBank.facts.insert(
          0,
          LearnedMemoryFact(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            fact: userPrompt,
            category: 'preference',
            learnedAt: DateTime.now(),
          ),
        );
      }

      for (final a in attachments) {
        _memoryBank.facts.insert(
          0,
          LearnedMemoryFact(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            fact: "Processed file: ${a.name}",
            category: 'attachment',
            learnedAt: DateTime.now(),
          ),
        );
      }

      if (_memoryBank.facts.length > 50) {
        _memoryBank.facts = _memoryBank.facts.sublist(0, 50);
      }

      await _saveMemoryToDisk();
      if (mounted) setState(() {});
    }());
  }

  Future<File> _getLocalMemoryFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/autonomous_cognitive_memory.json');
  }

  Future<void> _saveMemoryToDisk() async {
    final file = await _getLocalMemoryFile();
    await file.writeAsString(jsonEncode(_memoryBank.toJson()));
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

  void _toggleListening() async {
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
  }

  Future<void> _handleSendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty && _selectedAttachments.isEmpty) return;

    if (_isListening) {
      await _speech.stop();
      _isListening = false;
    }

    final outgoingAttachments = List<AttachmentItem>.from(_selectedAttachments);
    final userMsg = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      text: text,
      isUser: true,
      timestamp: DateTime.now(),
      attachments: outgoingAttachments,
    );

    setState(() {
      _messages.add(userMsg);
      _textController.clear();
      _selectedAttachments.clear();
      _isProcessing = true;
    });

    _scrollToBottom();

    final replyText = await _runGgufInference(text, outgoingAttachments);

    final aiMsg = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      text: replyText,
      isUser: false,
      timestamp: DateTime.now(),
    );

    setState(() {
      _messages.add(aiMsg);
      _isProcessing = false;
    });

    _scrollToBottom();

    if (_voiceResponseEnabled && replyText.isNotEmpty) {
      await _tts.speak(replyText);
    }

    _triggerSimultaneousLearning(text, outgoingAttachments);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF141721),
        title: GestureDetector(
          onTap: _selectGgufModel,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Local Companion", style: TextStyle(fontSize: 16)),
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
            tooltip: _voiceResponseEnabled ? "TTS: On" : "TTS: Off",
            icon: Icon(
              _voiceResponseEnabled ? Icons.volume_up : Icons.volume_off,
              color: _voiceResponseEnabled ? const Color(0xFF00D2FF) : Colors.grey,
            ),
            onPressed: () {
              setState(() => _voiceResponseEnabled = !_voiceResponseEnabled);
              if (!_voiceResponseEnabled) _tts.stop();
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
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              itemCount: _messages.length,
              itemBuilder: (context, i) {
                final m = _messages[i];
                return Align(
                  alignment: m.isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.all(12),
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.82,
                    ),
                    decoration: BoxDecoration(
                      color: m.isUser ? const Color(0xFF6C63FF) : const Color(0xFF1E2230),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      m.text,
                      style: const TextStyle(fontSize: 14, color: Colors.white),
                    ),
                  ),
                );
              },
            ),
          ),
          if (_isProcessing)
            const LinearProgressIndicator(
              backgroundColor: Color(0xFF141721),
              valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF6C63FF)),
              minHeight: 2,
            ),
          _buildInputBar(),
        ],
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
              onPressed: () async {
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
              onPressed: _toggleListening,
            ),
            Expanded(
              child: TextField(
                controller: _textController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: _isListening ? "Listening..." : "Type instruction...",
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
              icon: const Icon(Icons.send, color: Color(0xFF6C63FF)),
              onPressed: _handleSendMessage,
            ),
          ],
        ),
      ),
    );
  }

  void _showMemoryModal() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1D26),
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Memory Bank (${_memoryBank.facts.length} entries)",
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.upload),
                      label: const Text("Export Memory"),
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
                      icon: const Icon(Icons.download),
                      label: const Text("Import Memory"),
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
                          await _saveMemoryToDisk();
                          if (ctx.mounted) {
                            Navigator.pop(ctx);
                          }
                        }
                      },
                    ),
                  ),
                ],
              ),
              const Divider(height: 24),
              Expanded(
                child: ListView.builder(
                  itemCount: _memoryBank.facts.length,
                  itemBuilder: (_, i) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(_memoryBank.facts[i].fact, style: const TextStyle(fontSize: 13)),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
