import 'dart:convert';
import 'package:flutter/services.dart';

class TaurusAiMessage {
  final String role;
  final String content;
  const TaurusAiMessage({required this.role, required this.content});
  Map<String, String> toJson() => {'role': role, 'content': content};

  factory TaurusAiMessage.fromJson(Map<dynamic, dynamic> m) => TaurusAiMessage(
    role: m['role'] as String,
    content: m['content'] as String,
  );
}

class TaurusAiService {
  static const _channel = MethodChannel('com.taurus.shield/taurus_ai');

  static Future<String> chat({
    required List<TaurusAiMessage> messages,
    String context = '',
    String tool = 'il2cpp',
    String gameName = '',
  }) async {
    try {
      final result = await _channel.invokeMethod<String>('taurusAiChat', {
        'messages': jsonEncode(messages.map((m) => m.toJson()).toList()),
        'context':  context,
        'tool':     tool,
        'gameName': gameName,
      });
      return result ?? 'No response received.';
    } on PlatformException catch (e) {
      return 'Error: ${e.message ?? 'Unknown error'}';
    } catch (e) {
      return 'Error: $e';
    }
  }

  static Future<List<TaurusAiMessage>> loadHistory(String tool) async {
    try {
      final raw = await _channel.invokeMethod<String>('loadHistory', {'tool': tool});
      if (raw == null || raw.isEmpty || raw == '[]') return [];
      final list = jsonDecode(raw) as List<dynamic>;
      return list.map((m) => TaurusAiMessage.fromJson(m as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveHistory(String tool, List<TaurusAiMessage> messages) async {
    try {
      await _channel.invokeMethod('saveHistory', {
        'tool':    tool,
        'history': jsonEncode(messages.map((m) => m.toJson()).toList()),
      });
    } catch (_) {}
  }

  static Future<void> clearHistory(String tool) async {
    try {
      await _channel.invokeMethod('clearHistory', {'tool': tool});
    } catch (_) {}
  }

}
