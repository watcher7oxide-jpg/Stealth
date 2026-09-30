import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:fllama/fllama.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
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

  // Optimized compact system context to preserve RAM & token budget
  String buildSystemContext() {
    final buffer = StringBuffer();
    buffer.write("System: You are an autonomous AI companion. ");
    if (facts.isNotEmpty) {
      buffer.write("Known facts: ");
      // Only inject top 10 most recent facts to prevent KV cache blowup on 4GB RAM
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
    super.dispose();
  }

  /* ---------------- Init & State Loading ---------------- */

  Future<void> _loadSavedState() async {
    final prefs = await SharedPreferences.getInstance();
    final savedPath = prefs.getString('saved_gguf_path');
    if (savedPath != null && await File(savedPath).exists()) {
      setState(() {
        _loadedGgufPath = savedPath;
        _modelStatus = "Ready: ${savedPath.split('/').last}";
      });
    }
    await _loadMemoryFromDisk();
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

  /* ---------------- GGUF Model Selector ---------------- */

  Future<void> _selectGgufModel() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );

      if (result != null && result.files.single.path != null) {
        final path = result.files.single.path!;
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

        setState(() {
          _loadedGgufPath = path;
          _modelStatus = "Loaded: ${path.split('/').last}";
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Model bound: ${path.split('/').last}")),
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
      return "No .gguf model selected. Tap the chip in the top bar to locate your downloaded file.";
    }

    // Build context
    final systemPrompt = _memoryBank.buildSystemContext();
    final StringBuffer promptBuffer = StringBuffer();
    promptBuffer.writeln(systemPrompt);

    // Keep context history minimal (last 3 messages) for 4GB RAM phones
    final recent = _messages.length > 3
        ? _messages.sublist(_messages.length - 3)
        : _messages;
    for (final m in recent) {
      promptBuffer.writeln("${m.isUser ? 'User' : 'Assistant'}: ${m.text}");
    }

    // Process attachment text (truncated to 200 chars to avoid memory exhaustion)
    for (final a in attachments) {
      if (a.bytes != null && !a.isImage && a.size < 50000) {
        try {
          final decoded = utf8.decode(a.bytes!);
          final preview = decoded.length > 200 ? decoded.substring(0, 200) : decoded;
          promptBuffer.writeln("[Attached Text (${a.name})]: $preview");
        } catch (_) {}
      } else {
        promptBuffer.writeln("[Attached File: ${a.name}]");
      }
    }

    promptBuffer.writeln("User: $userText\nAssistant:");

    final completer = Completer<String>();
    final StringBuffer responseBuffer = StringBuffer();

    try {
      // 4GB RAM Optimization Settings:
      // contextSize: 1024 (prevents KV cache OOM)
      // threads: 2 (avoids CPU throttling and stack memory spikes)
      await fllama.chat(
        ChatRequest(
          modelPath: _loadedGgufPath!,
          messages: [
            Message(Role.user, promptBuffer.toString()),
          ],
          contextSize: 1024,
          threads: 2,
          numGpuLayers: 0, // Fallback purely to optimized CPU/NEON instructions
          temperature: 0.7,
        ),
        (response, done) {
          responseBuffer.write(response);
          if (done && !completer.isCompleted) {
            completer.complete(responseBuffer.toString().trim());
          }
        },
      );

      return await completer.future.timeout(
        const Duration(seconds: 45),
        onTimeout: () => responseBuffer.isNotEmpty
            ? responseBuffer.toString()
            : "Response timed out on current hardware limits.",
      );
    } catch (e) {
      return "Execution halted: $e. Ensure other background apps are closed to free RAM.";
    }
  }

  /* ---------------- Continuous Memory & Background Induction ---------------- */

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

      // Memory cap of 50 facts to prevent excessive storage or token ingestion
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

  /* ---------------- Voice & Messaging Handlers ---------------- */

  void _toggleListening() async {
    if (!_speechEnabled) return;
    if (_isListening) {
      await _speech.stop();
      setState(() => _isListening = false);
    } else {
      setState(() => _isListening = true);
      await _speech.listen(onResult: (result) {
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

    // Run inference using the selected GGUF file
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

  /* ---------------- UI Construction ---------------- */

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
                final res = await FilePicker.platform.pickFiles(
                  allowMultiple: true,
                  withData: true,
                );
                if (res != null) {
                  setState(() {
                    for (final f in res.files) {
                      _selectedAttachments.add(
                        AttachmentItem(
                          id: DateTime.now().millisecondsSinceEpoch.toString(),
                          name: f.name,
                          path: f.path ?? '',
                          size: f.size,
                          extension: f.extension ?? '',
                          bytes: f.bytes,
                        ),
                      );
                    }
                  });
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
                  hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
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
                        final res = await FilePicker.platform.pickFiles(
                          type: FileType.custom,
                          allowedExtensions: ['json'],
                          withData: true,
                        );
                        if (res != null && res.files.single.bytes != null) {
                          final data = jsonDecode(utf8.decode(res.files.single.bytes!));
                          setState(() => _memoryBank.importFromJson(data));
                          await _saveMemoryToDisk();
                          Navigator.pop(ctx);
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
