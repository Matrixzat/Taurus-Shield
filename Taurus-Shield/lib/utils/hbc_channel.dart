import 'package:flutter/services.dart';

class HbcChannel {
  static const _channel    = MethodChannel('com.taurus.shield/hbc');
  static const _logChannel = EventChannel('com.taurus.shield/log_stream');

  static Stream<String> get logStream =>
      _logChannel.receiveBroadcastStream().map((e) => e.toString());

  static Future<void> startProcessing({
    required String filePath,
    required String fileName,
    required String mode,
    required String outputDir,
  }) async {
    await _channel.invokeMethod('startProcessing', {
      'filePath': filePath,
      'fileName': fileName,
      'mode': mode,
      'outputDir': outputDir,
    });
  }

  static Future<Map<String, dynamic>> getProcessingState() async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'getProcessingState',
    );
    return result ?? {'running': false};
  }

  static Future<Map<String, dynamic>> disassemble({
    required String hbcFilePath,
    required String outputDir,
  }) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'disassemble',
      {'hbcFilePath': hbcFilePath, 'outputDir': outputDir},
    );
    return result ?? {'status': 'error', 'log': 'No response from native layer'};
  }

  static Future<Map<String, dynamic>> assemble({
    required String hasmFilePath,
    required String outputDir,
  }) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'assemble',
      {'hasmFilePath': hasmFilePath, 'outputDir': outputDir},
    );
    return result ?? {'status': 'error', 'log': 'No response from native layer'};
  }

  static Future<Map<String, dynamic>> blutterAnalyze({
    required String filePath,
    required String fileName,
    required String outputDir,
    String? manualDartVersion,
  }) async {
    final args = <String, dynamic>{
      'filePath':  filePath,
      'fileName':  fileName,
      'outputDir': outputDir,
    };
    if (manualDartVersion != null && manualDartVersion.isNotEmpty) {
      args['manualDartVersion'] = manualDartVersion;
    }
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'blutter_analyze',
      args,
    );
    return result ?? {'success': false, 'output': 'No response from native layer'};
  }

  static Future<Map<String, dynamic>> blutterCloudState() async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'blutter_cloud_state',
    );
    return result ?? {'running': false};
  }

  static Future<void> blutterClearState() async {
    await _channel.invokeMethod('blutter_clear_state');
  }

  static Future<void> blutterCancel() async {
    await _channel.invokeMethod('blutter_cancel');
  }

  static Future<Map<String, dynamic>> dex2cAnalyze({
    required String filePath,
    required String fileName,
    required String outputDir,
    bool signApk = true,
  }) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'dex2c_analyze',
      {
        'filePath':  filePath,
        'fileName':  fileName,
        'outputDir': outputDir,
        'signApk':   signApk,
      },
    );
    return result ?? {'success': false, 'output': 'No response from native layer'};
  }

  static Future<Map<String, dynamic>> dex2cCloudState() async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'dex2c_cloud_state',
    );
    return result ?? {'running': false};
  }

  static Future<void> dex2cClearState() async {
    await _channel.invokeMethod('dex2c_clear_state');
  }

  static Future<void> dex2cCancel() async {
    await _channel.invokeMethod('dex2c_cancel');
  }

  static Future<Map<String, dynamic>> dptShellAnalyze({
    required String filePath,
    required String fileName,
    required String outputDir,
    bool signApk = true,
  }) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'dptshell_analyze',
      {
        'filePath':  filePath,
        'fileName':  fileName,
        'outputDir': outputDir,
        'signApk':   signApk,
      },
    );
    return result ?? {'success': false, 'output': 'No response from native layer'};
  }

  static Future<Map<String, dynamic>> dptShellCloudState() async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'dptshell_cloud_state',
    );
    return result ?? {'running': false};
  }

  static Future<void> dptShellClearState() async {
    await _channel.invokeMethod('dptshell_clear_state');
  }

  static Future<void> dptShellCancel() async {
    await _channel.invokeMethod('dptshell_cancel');
  }

  static Future<Map<String, dynamic>> apkToolAnalyze({
    required String filePath,
    required String fileName,
    required String outputDir,
    required String mode,
    bool signApk = false,
  }) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'apktool_analyze',
      {
        'filePath':  filePath,
        'fileName':  fileName,
        'outputDir': outputDir,
        'mode':      mode,
        'signApk':   signApk,
      },
    );
    return result ?? {'success': false, 'output': 'No response from native layer'};
  }

  static Future<Map<String, dynamic>> apkToolCloudState() async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'apktool_cloud_state',
    );
    return result ?? {'running': false};
  }

  static Future<void> apkToolClearState() async {
    await _channel.invokeMethod('apktool_clear_state');
  }

  static Future<void> apkToolCancel() async {
    await _channel.invokeMethod('apktool_cancel');
  }

  static Future<Map<String, dynamic>> androidIdSpoofAnalyze({
    required String filePath,
    required String fileName,
    required String outputDir,
    required String androidId,
    bool signApk = true,
  }) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'androidIdSpoof_analyze',
      {
        'filePath':  filePath,
        'fileName':  fileName,
        'outputDir': outputDir,
        'androidId': androidId,
        'signApk':   signApk,
      },
    );
    return result ?? {'success': false, 'output': 'No response from native layer'};
  }

  static Future<Map<String, dynamic>> androidIdSpoofCloudState() async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'androidIdSpoof_cloud_state',
    );
    return result ?? {'running': false};
  }

  static Future<void> androidIdSpoofClearState() async {
    await _channel.invokeMethod('androidIdSpoof_clear_state');
  }

  static Future<void> androidIdSpoofCancel() async {
    await _channel.invokeMethod('androidIdSpoof_cancel');
  }

  static Future<Map<Object?, Object?>> invokeMethod(
      String method, Map<String, dynamic> args) async {
    final result =
        await _channel.invokeMapMethod<Object?, Object?>(method, args);
    return result ?? {};
  }

  static Future<Map<String, dynamic>> jsEncryptorAnalyze({
    required String filePath,
    required String fileName,
    required String outputDir,
    required String method,
    String? subzeroKey,
  }) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'jsEncryptor_analyze',
      {
        'filePath':    filePath,
        'fileName':    fileName,
        'outputDir':   outputDir,
        'method':      method,
        if (subzeroKey != null) 'subzeroKey': subzeroKey,
      },
    );
    return result ?? {'success': false, 'output': 'No response from native layer'};
  }

  static Future<Map<String, dynamic>> jsEncryptorState() async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'jsEncryptor_state',
    );
    return result ?? {'running': false};
  }

  static Future<void> jsEncryptorClearState() async {
    await _channel.invokeMethod('jsEncryptor_clear_state');
  }

  static Future<void> jsEncryptorCancel() async {
    await _channel.invokeMethod('jsEncryptor_cancel');
  }

  static Future<Map<String, dynamic>> adsPatchAnalyze({
    required String filePath,
    required String fileName,
    required String outputDir,
    required String patchLevel,
    bool signApk = true,
  }) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'adsPatch_analyze',
      {
        'filePath':   filePath,
        'fileName':   fileName,
        'outputDir':  outputDir,
        'patchLevel': patchLevel,
        'signApk':    signApk,
      },
    );
    return result ?? {'success': false, 'output': 'No response from native layer'};
  }

  static Future<Map<String, dynamic>> adsPatchCloudState() async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'adsPatch_cloud_state',
    );
    return result ?? {'running': false};
  }

  static Future<void> adsPatchClearState() async {
    await _channel.invokeMethod('adsPatch_clear_state');
  }

  static Future<void> adsPatchCancel() async {
    await _channel.invokeMethod('adsPatch_cancel');
  }

  static Future<Map<String, dynamic>> antiKillerAnalyze({
    required String filePath,
    required String fileName,
    required String outputDir,
    String mainActivity = '',
  }) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'antiKiller_analyze',
      {
        'filePath':     filePath,
        'fileName':     fileName,
        'outputDir':    outputDir,
        'mainActivity': mainActivity,
      },
    );
    return result ?? {'success': false, 'output': 'No response from native layer'};
  }

  static Future<Map<String, dynamic>> antiKillerCloudState() async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'antiKiller_cloud_state',
    );
    return result ?? {'running': false};
  }

  static Future<void> antiKillerClearState() async {
    await _channel.invokeMethod('antiKiller_clear_state');
  }

  static Future<void> antiKillerCancel() async {
    await _channel.invokeMethod('antiKiller_cancel');
  }

}
