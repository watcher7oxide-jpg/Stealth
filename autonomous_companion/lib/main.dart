import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:llama_cpp_dart/llama_cpp_dart.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const OnDeviceAssistantApp());
}

class OnDeviceAssistantApp extends StatelessWidget {
  const OnDeviceAssistantApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Autonomous Local Intelligence',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      home: const ChatScreen(),
    );
  }
}

// ---------------------------------------------------------
// DATA MODELS
// ---------------------------------------------------------
class AttachmentItem {
  final String name;
  final String path;
  final String extension;
  final int size;

  AttachmentItem({
    required this.name,
    required this.path,
    required this.extension,
    required this.size,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'path': path,
        'extension': extension,
        'size': size,
      };

  factory AttachmentItem.fromJson(Map<String, dynamic> json) => AttachmentItem(
        name: json['name'],
        path: json['path'],
        extension: json['extension'],
        size: json['size'],
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
        id: json['id'],
        text: json['text'],
        isUser: json['isUser'],
        timestamp: DateTime.parse(json['timestamp']),
        attachments: (json['attachments'] as List? ?? [])
            .map((a) => AttachmentItem.fromJson(a))
            .toList(),
      );
}

// Portable Persistent Memory Structure
class MemorySnapshot {
  String personaStyle;
  List<String> learnedFacts;
  List<String> userPreferences;
  int interactionCount;
  DateTime lastUpdated;

  MemorySnapshot({
    required this.personaStyle,
    required this.learnedFacts,
    required this.userPreferences,
    required this.interactionCount,
    required this.lastUpdated,
  });

  factory MemorySnapshot.initial() {
    return MemorySnapshot(
      personaStyle: "Concise, precise, edge-optimized companion.",
      learnedFacts: [],
      userPreferences: [],
      interactionCount: 0,
      lastUpdated: DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'personaStyle': personaStyle,
        'learnedFacts': learnedFacts,
        'userPreferences': userPreferences,
        'interactionCount': interactionCount,
        'lastUpdated': lastUpdated.toIso8601String(),
      };

  factory MemorySnapshot.fromJson(Map<String, dynamic> json) => MemorySnapshot(
        personaStyle: json['personaStyle'] ?? '',
        learnedFacts: List<String>.from(json['learnedFacts'] ?? []),
        userPreferences: List<String>.from(json['userPreferences'] ?? []),
        interactionCount: json['interactionCount'] ?? 0,
        lastUpdated: json['lastUpdated'] != null
            ? DateTime.parse(json['lastUpdated'])
            : DateTime.now(),
      );
}

// ---------------------------------------------------------
// MAIN CHAT SCREEN
// ---------------------------------------------------------
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<ChatMessage> _messages = [];
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  // On-Device Local Engine
  Llama? _engine;
  String? _loadedModelPath;
  bool _isModelLoading = false;

  // Voice Modules
  late stt.SpeechToText _speech;
  late FlutterTts _tts;
  bool _isListening = false;
  bool _voiceResponseEnabled = false;

  // Attachments staging
  final List<AttachmentItem> _selectedAttachments = [];

  // Memory & Shaping Engine
  late MemorySnapshot _memory;
  bool _isGenerating = false;

  @override
  void initState() {
    super.initState();
    _speech = stt.SpeechToText();
    _tts = FlutterTts();
    _memory = MemorySnapshot.initial();
    _initVoiceEngine();
    _loadSavedState();
  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    _tts.stop();
    _engine?.dispose();
    super.dispose();
  }

  Future<void> _initVoiceEngine() async {
    await _speech.initialize(
      onError: (val) => debugPrint('STT Error: $val'),
      onStatus: (val) => debugPrint('STT Status: $val'),
    );
    await _tts.setLanguage("en-US");
    await _tts.setSpeechRate(0.5);
    await _tts.setPitch(1.0);
  }

  Future<void> _loadSavedState() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _voiceResponseEnabled = prefs.getBool('voice_response') ?? false;
      _loadedModelPath = prefs.getString('loaded_model_path');

      final memoryString = prefs.getString('companion_memory');
      if (memoryString != null) {
        try {
          _memory = MemorySnapshot.fromJson(jsonDecode(memoryString));
        } catch (e) {
          debugPrint('Error restoring memory: $e');
        }
      }
    });

    if (_loadedModelPath != null && File(_loadedModelPath!).existsSync()) {
      _initializeLocalModel(_loadedModelPath!);
    }
  }

  Future<void> _persistMemoryLocally() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('companion_memory', jsonEncode(_memory.toJson()));
  }

  // ---------------------------------------------------------
  // LOCAL MODEL LOADER (Tuned for 4 GB RAM)
  // ---------------------------------------------------------
  Future<void> _selectAndLoadModelFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
    );

    if (result != null && result.files.single.path != null) {
      final path = result.files.single.path!;
      if (!path.endsWith('.gguf')) {
        _showSnackbar("Please select a valid .gguf model file.");
        return;
      }
      await _initializeLocalModel(path);
    }
  }

  Future<void> _initializeLocalModel(String path) async {
    setState(() {
      _isModelLoading = true;
    });

    try {
      // Free old engine if already loaded
      _engine?.dispose();

      // Ensure dynamic library is bound on Android
      if (Platform.isAndroid && Llama.libraryPath == null) {
        Llama.libraryPath = 'libllama.so';
      }

      // Configure strictly for 4 GB RAM:
      // - nCtx: 1024 tokens (prevents KV cache memory spikes)
      // - nThreads: 4 (balances performance cores without thermal throttling)
      final modelParams = ModelParams()..nGpuLayers = 0;
      final contextParams = ContextParams()
        ..nCtx = 1024
        ..nThreads = 4;
      final samplerParams = SamplerParams()..temp = 0.7;

      final llama = Llama(
        path,
        modelParams,
        contextParams,
        samplerParams,
      );

      setState(() {
        _engine = llama;
        _loadedModelPath = path;
        _isModelLoading = false;
      });

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('loaded_model_path', path);

      _showSnackbar("Local model loaded successfully!");
    } catch (e) {
      setState(() {
        _isModelLoading = false;
      });
      _showSnackbar("Failed to load local model: $e");
    }
  }

  // ---------------------------------------------------------
  // VOICE INPUT / OUTPUT
  // ---------------------------------------------------------
  void _toggleListening() async {
    if (_isListening) {
      await _speech.stop();
      setState(() => _isListening = false);
    } else {
      bool available = await _speech.initialize();
      if (available) {
        setState(() => _isListening = true);
        _speech.listen(
          onResult: (result) {
            setState(() {
              _textController.text = result.recognizedWords;
            });
            if (result.finalResult) {
              setState(() => _isListening = false);
            }
          },
        );
      }
    }
  }

  Future<void> _speakText(String text) async {
    if (!_voiceResponseEnabled) return;
    await _tts.stop();
    await _tts.speak(text);
  }

  // ---------------------------------------------------------
  // ATTACHMENT HANDLER
  // ---------------------------------------------------------
  Future<void> _pickAttachments() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.any,
    );

    if (result != null && result.files.isNotEmpty) {
      setState(() {
        for (var file in result.files) {
          if (file.path != null) {
            _selectedAttachments.add(
              AttachmentItem(
                name: file.name,
                path: file.path!,
                extension: file.extension ?? '',
                size: file.size,
              ),
            );
          }
        }
      });
    }
  }

  // ---------------------------------------------------------
  // ON-DEVICE INFERENCE & CONTINUOUS LEARNING
  // ---------------------------------------------------------
  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty && _selectedAttachments.isEmpty) return;

    if (_engine == null) {
      _showSnackbar("Please load a .gguf model file first!");
      return;
    }

    final userMessage = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      text: text,
      isUser: true,
      timestamp: DateTime.now(),
      attachments: List.from(_selectedAttachments),
    );

    setState(() {
      _messages.add(userMessage);
      _isGenerating = true;
      _textController.clear();
      _selectedAttachments.clear();
    });

    _scrollToBottom();

    try {
      final prompt = _buildContextPrompt(userMessage);

      final responseBuffer = StringBuffer();
      _engine!.setPrompt(prompt);

      // Stream generation loop using Dart Records
      while (true) {
        final (token, done) = _engine!.getNext();
        if (token.isNotEmpty) {
          responseBuffer.write(token);
        }
        if (done) break;
        // Yield to Flutter event loop so UI stays smooth
        await Future.delayed(const Duration(milliseconds: 1));
      }

      final aiResponseText = responseBuffer.toString().trim();

      final aiMessage = ChatMessage(
        id: (DateTime.now().millisecondsSinceEpoch + 1).toString(),
        text: aiResponseText,
        isUser: false,
        timestamp: DateTime.now(),
      );

      setState(() {
        _messages.add(aiMessage);
        _isGenerating = false;
      });

      _scrollToBottom();
      _speakText(aiResponseText);

      // Continuous shaping pass in the background
      _shapeMemoryContinuously(userMessage, aiResponseText);
    } catch (e) {
      setState(() {
        _isGenerating = false;
        _messages.add(
          ChatMessage(
            id: DateTime.now().millisecondsSinceEpoch.toString(),
            text: "On-device runtime execution error: $e",
            isUser: false,
            timestamp: DateTime.now(),
          ),
        );
      });
    }
  }

  String _buildContextPrompt(ChatMessage msg) {
    final memoryContext = [
      if (_memory.learnedFacts.isNotEmpty)
        "Known Facts: ${_memory.learnedFacts.take(5).join('; ')}",
      if (_memory.userPreferences.isNotEmpty)
        "Preferences: ${_memory.userPreferences.take(5).join('; ')}",
      "Persona: ${_memory.personaStyle}"
    ].join("\n");

    String attachmentsInfo = "";
    if (msg.attachments.isNotEmpty) {
      attachmentsInfo = "\n[Attachments: " +
          msg.attachments.map((a) => "${a.name} (${a.extension})").join(", ") +
          "]";
    }

    return "<start_of_turn>system\n$memoryContext<end_of_turn>\n"
        "<start_of_turn>user\n${msg.text}$attachmentsInfo<end_of_turn>\n"
        "<start_of_turn>model\n";
  }

  void _shapeMemoryContinuously(ChatMessage userMsg, String reply) {
    Future.microtask(() {
      bool updated = false;

      final input = userMsg.text.toLowerCase();
      if (input.contains("my name is") ||
          input.contains("i like") ||
          input.contains("i work as")) {
        _memory.learnedFacts.add(userMsg.text);
        updated = true;
      }

      for (var att in userMsg.attachments) {
        final fact = "User referenced file: ${att.name}";
        if (!_memory.learnedFacts.contains(fact)) {
          _memory.learnedFacts.add(fact);
          updated = true;
        }
      }

      if (updated || _memory.interactionCount % 5 == 0) {
        _memory.interactionCount += 1;
        _memory.lastUpdated = DateTime.now();
        _persistMemoryLocally();
      }
    });
  }

  // ---------------------------------------------------------
  // MEMORY IMPORT & EXPORT
  // ---------------------------------------------------------
  Future<void> _exportMemoryFile() async {
    try {
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/companion_memory.json');
      await file.writeAsString(jsonEncode(_memory.toJson()));

      await Share.shareXFiles(
        [XFile(file.path)],
        text: 'Companion Memory Backup',
      );
    } catch (e) {
      _showSnackbar("Export failed: $e");
    }
  }

  Future<void> _importMemoryFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final jsonString = await file.readAsString();
        final Map<String, dynamic> data = jsonDecode(jsonString);

        if (data.containsKey('learnedFacts') &&
            data.containsKey('personaStyle')) {
          setState(() {
            _memory = MemorySnapshot.fromJson(data);
          });
          await _persistMemoryLocally();
          _showSnackbar("Memory successfully imported!");
        } else {
          _showSnackbar("Invalid memory file schema.");
        }
      }
    } catch (e) {
      _showSnackbar("Import failed: $e");
    }
  }

  void _showSnackbar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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

  // ---------------------------------------------------------
  // UI PRESENTATION
  // ---------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text("On-Device AI", style: TextStyle(fontSize: 16)),
            Text(
              _loadedModelPath != null
                  ? _loadedModelPath!.split('/').last
                  : "No model loaded",
              style: const TextStyle(fontSize: 10, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: "Load Local .gguf Model",
            icon: const Icon(Icons.file_open),
            onPressed: _selectAndLoadModelFile,
          ),
          IconButton(
            tooltip: _voiceResponseEnabled ? "TTS Audio: ON" : "TTS Audio: OFF",
            icon: Icon(
              _voiceResponseEnabled ? Icons.volume_up : Icons.volume_off,
              color: _voiceResponseEnabled ? Colors.greenAccent : Colors.grey,
            ),
            onPressed: () async {
              setState(() {
                _voiceResponseEnabled = !_voiceResponseEnabled;
              });
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('voice_response', _voiceResponseEnabled);
              if (!_voiceResponseEnabled) _tts.stop();
            },
          ),
          IconButton(
            tooltip: "Memory Core",
            icon: const Icon(Icons.memory),
            onPressed: _openMemoryDashboard,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_isModelLoading)
            Container(
              color: Colors.amber.withOpacity(0.2),
              padding: const EdgeInsets.all(8),
              child: const Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 10),
                  Text("Allocating model in device RAM...",
                      style: TextStyle(fontSize: 12)),
                ],
              ),
            ),

          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                return _buildMessageBubble(msg);
              },
            ),
          ),

          if (_isGenerating)
            const Padding(
              padding: EdgeInsets.all(8.0),
              child: LinearProgressIndicator(),
            ),

          if (_selectedAttachments.isNotEmpty)
            Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _selectedAttachments.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (ctx, i) {
                  final att = _selectedAttachments[i];
                  return Chip(
                    label: Text(att.name, style: const TextStyle(fontSize: 11)),
                    onDeleted: () {
                      setState(() {
                        _selectedAttachments.removeAt(i);
                      });
                    },
                  );
                },
              ),
            ),

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              border: Border(top: BorderSide(color: Colors.grey[800]!)),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.attach_file),
                  onPressed: _pickAttachments,
                ),
                IconButton(
                  icon: Icon(
                    _isListening ? Icons.mic : Icons.mic_none,
                    color: _isListening ? Colors.redAccent : null,
                  ),
                  onPressed: _toggleListening,
                ),
                Expanded(
                  child: TextField(
                    controller: _textController,
                    maxLines: null,
                    decoration: const InputDecoration(
                      hintText: "Type or speak...",
                      border: InputBorder.none,
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  color: Theme.of(context).colorScheme.primary,
                  onPressed: _sendMessage,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage msg) {
    final isMe = msg.isUser;
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.8,
        ),
        decoration: BoxDecoration(
          color: isMe
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surfaceVariant,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (msg.attachments.isNotEmpty) ...[
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: msg.attachments
                    .map(
                      (a) => Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.black26,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          a.name,
                          style: const TextStyle(fontSize: 10),
                        ),
                      ),
                    )
                    .toList(),
              ),
              const SizedBox(height: 4),
            ],
            SelectableText(
              msg.text,
              style: TextStyle(
                color: isMe
                    ? Theme.of(context).colorScheme.onPrimaryContainer
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openMemoryDashboard() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => DraggableScrollableSheet(
          initialChildSize: 0.65,
          minChildSize: 0.4,
          maxChildSize: 0.9,
          expand: false,
          builder: (_, scrollController) => Padding(
            padding: const EdgeInsets.all(16.0),
            child: ListView(
              controller: scrollController,
              children: [
                const Text(
                  "Learned Memory Core",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Divider(),
                ListTile(
                  title: const Text("Interactions Completed"),
                  subtitle: Text("${_memory.interactionCount}"),
                  leading: const Icon(Icons.insights),
                ),
                ListTile(
                  title: const Text("Current Persona State"),
                  subtitle: Text(_memory.personaStyle),
                  leading: const Icon(Icons.psychology),
                ),
                const SizedBox(height: 10),
                const Text("Permanent Learned Facts:"),
                ..._memory.learnedFacts.map(
                  (f) => ListTile(
                    dense: true,
                    title: Text("• $f"),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete, size: 16),
                      onPressed: () {
                        setState(() {
                          _memory.learnedFacts.remove(f);
                        });
                        setModalState(() {});
                        _persistMemoryLocally();
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.upload_file),
                        label: const Text("Export Memory"),
                        onPressed: _exportMemoryFile,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.download),
                        label: const Text("Import Memory"),
                        onPressed: () async {
                          Navigator.pop(ctx);
                          await _importMemoryFile();
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
