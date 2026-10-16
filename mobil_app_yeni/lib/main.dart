// lib/main.dart - V60.1_FINAL_PERFORMANCE (SMART INVERT + STABLE UI + FIXES)

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DatabaseHelper.initDbIfNeeded();
  runApp(const QrPackingApp());
}

// ---------------------------------------------------------------------------
// PARSER (AYNEN KORUNDU)
// ---------------------------------------------------------------------------
String normalizeCode(String? raw) {
  if (raw == null) return "";
  return raw.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '').trim();
}

String formatForMedula(String rawCode, Map<String, String> info) {
  return rawCode;
}

Map<String, String> parseGS1ForLabel(String code) {
  String gs1 = normalizeCode(code);
  String gtin = "", serial = "", expiryFormatted = "", lot = "", rawDateFound = "";
  String searchScope = gs1;

  if (gs1.startsWith("01") && gs1.length >= 16) {
    gtin = gs1.substring(2, 16);
    searchScope = gs1.substring(16);
  } else if (gs1.length > 14 && gs1.startsWith("08")) {
    gtin = gs1.substring(0, 14);
    searchScope = gs1.substring(14);
  }

  int dateStartIndex = -1, dateEndIndex = -1;
  for (int i = searchScope.length - 8; i >= 0; i--) {
    if (searchScope.substring(i, i + 2) == '17') {
      String potentialDate = searchScope.substring(i + 2, i + 8);
      if (RegExp(r'^\d{6}$').hasMatch(potentialDate)) {
        try {
          int y = int.parse(potentialDate.substring(0, 2));
          int m = int.parse(potentialDate.substring(2, 4));
          int d = int.parse(potentialDate.substring(4, 6));
          bool isValidDate = (m >= 1 && m <= 12) && (d >= 1 && d <= 31);
          if (y < 23) isValidDate = false;
          if (isValidDate) {
            rawDateFound = potentialDate;
            int fullYear = (y > 50) ? 1900 + y : 2000 + y;
            if (d == 0) d = 1;
            expiryFormatted =
                "${d.toString().padLeft(2, '0')}/${m.toString().padLeft(2, '0')}/$fullYear";
            dateStartIndex = i;
            dateEndIndex = i + 8;
            break;
          }
        } catch (_) {}
      }
    }
  }

  if (dateStartIndex != -1) {
    String preDate = searchScope.substring(0, dateStartIndex);
    String postDate = searchScope.substring(dateEndIndex);
    if (preDate.startsWith("21")) {
      serial = preDate.substring(2);
    } else if (preDate.isNotEmpty) {
      serial = preDate;
    }
    if (postDate.startsWith("10")) {
      lot = postDate.substring(2);
    } else if (postDate.startsWith("21")) {
      serial = postDate.substring(2);
    } else {
      lot = postDate;
    }
  } else {
    if (searchScope.startsWith("21")) {
      serial = searchScope.substring(2);
    } else {
      serial = searchScope;
    }
  }
  if (serial.length > 25) serial = serial.substring(0, 25);
  if (lot.length > 20) lot = lot.substring(0, 20);

  return {
    "GTIN": gtin,
    "SN": serial,
    "SKT": expiryFormatted,
    "LOT": lot,
    "RAW_SKT": rawDateFound
  };
}

class Gs1Status {
  final String text;
  final Color color;
  final String date;
  final int days;
  Gs1Status(this.text, this.color, this.date, this.days);
}

Gs1Status analyzeStatus(String rawDate) {
  if (rawDate.length != 6) {
    return Gs1Status("TARİH YOK", Colors.green, "", 9999);
  }
  try {
    int y = int.parse(rawDate.substring(0, 2));
    int m = int.parse(rawDate.substring(2, 4));
    int d = int.parse(rawDate.substring(4, 6));
    int fullYear = (y > 50) ? 1900 + y : 2000 + y;
    DateTime exp =
        (d == 0) ? DateTime(fullYear, m + 1, 0) : DateTime(fullYear, m, d);
    final now = DateTime.now();
    final days =
        exp.difference(DateTime(now.year, now.month, now.day)).inDays;
    String fmt =
        "${exp.day.toString().padLeft(2, '0')}/${exp.month.toString().padLeft(2, '0')}/$fullYear";

    if (days < 0) {
      return Gs1Status("MİADI GEÇMİŞ", Colors.red, fmt, days);
    }
    if (days <= 30) {
      return Gs1Status("<1 AY ($days Gn)", Colors.black, fmt, days);
    }
    if (days <= 60) {
      return Gs1Status("<2 AY ($days Gn)", Colors.blue, fmt, days);
    }
    if (days <= 90) {
      return Gs1Status("<3 AY ($days Gn)", Colors.orange, fmt, days);
    }
    return Gs1Status("GEÇERLİ", Colors.green, fmt, days);
  } catch (e) {
    return Gs1Status("HATALI", Colors.grey, "", 9999);
  }
}

class DatabaseHelper {
  static Database? _db;

  static Future<void> initDbIfNeeded() async {
    if (_db != null) return;
    final documents = await getApplicationDocumentsDirectory();
    final dbPath = p.join(documents.path, 'codes_v60_final.db');
    _db = await openDatabase(dbPath, version: 1,
        onCreate: (db, version) async {
      await db.execute(
          'CREATE TABLE codes (id INTEGER PRIMARY KEY AUTOINCREMENT, barcode TEXT, gtin TEXT, name TEXT, scanned_at TEXT)');
      await db.execute('CREATE INDEX idx_barcode ON codes(barcode)');
    });
  }

  static Future<List<Map<String, dynamic>>> loadAllCodes() async {
    await initDbIfNeeded();
    return await _db!.query('codes');
  }

  static void insertCodeFast(String code, String gtin, String name) {
    if (_db == null) return;
    _db!.insert('codes', {
      'barcode': normalizeCode(code),
      'gtin': gtin,
      'name': name,
      'scanned_at': DateTime.now().toIso8601String()
    }).then((value) {});
  }

  static Future<void> insertBatch(List<String> codes, String defaultName) async {
    await initDbIfNeeded();
    Batch batch = _db!.batch();
    for (String c in codes) {
      String gtin = parseGS1ForLabel(c)['GTIN'] ?? "";
      batch.insert('codes', {
        'barcode': normalizeCode(c),
        'gtin': gtin,
        'name': defaultName,
        'scanned_at': DateTime.now().toIso8601String()
      });
    }
    await batch.commit(noResult: true);
  }

  static Future<void> clearCodes() async {
    await initDbIfNeeded();
    await _db!.delete('codes');
  }
}

class AppSettings {
  final SharedPreferences prefs;
  AppSettings(this.prefs);

  String get serverIp => prefs.getString('server_ip') ?? '';
  Future<void> setServerIp(String v) async => prefs.setString('server_ip', v);

  bool get invertMode => prefs.getBool('invert_mode') ?? false;
  Future<void> setInvertMode(bool v) async => prefs.setBool('invert_mode', v);

  String get resolution => prefs.getString('cam_res') ?? 'medium';
  Future<void> setResolution(String v) async =>
      prefs.setString('cam_res', v);
}

class QrPackingApp extends StatelessWidget {
  const QrPackingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'M-ONUR PRO',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.black,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
      ),
      home: const MainScannerScreen(),
    );
  }
}

class MainScannerScreen extends StatefulWidget {
  const MainScannerScreen({super.key});

  @override
  State<MainScannerScreen> createState() => _MainScannerScreenState();
}

class _MainScannerScreenState extends State<MainScannerScreen>
    with WidgetsBindingObserver {
  List<CameraDescription> _cameras = [];
  CameraController? _controller;
  final BarcodeScanner _barcodeScanner =
      BarcodeScanner(formats: [BarcodeFormat.all]);

  bool _isProcessing = false;
  DateTime _lastProcessTime = DateTime.now();
  int _processCounter = 0;

  Set<String> scannedCodes = {};
  Set<String> scannedGtins = {};
  Map<String, DateTime> scannedTimestamps = {};

  String _lastScannedCode = "";
  DateTime _lastScanSuccess = DateTime(2000);
  Map<String, int> _gtinCounts = {};
  int _serverCount = 0;

  bool _isSingleMode = true;
  String statusText = 'Hazır';
  Color statusColor = Colors.white;

  String _lastExpDate = "-";
  String _lastDaysLeft = "-";
  String _lastStatus = "";
  String _lastItemName = "...";
  int _lastTotalCount = 0;

  bool busy = false;
  AppSettings? settings;
  bool isConnected = false;
  Timer? _heartbeatTimer;
  bool _invertColors = false;

  List<Barcode> detectedBarcodes = [];
  Size? _cameraImageSize;

  final List<String> _networkBuffer = [];
  Timer? _bufferTimer;
  bool _isSendingBuffer = false;

  bool _dynamicInvert = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    _initEverything();

    _heartbeatTimer = Timer.periodic(const Duration(seconds: 4), (timer) {
      if (settings?.serverIp.isNotEmpty == true) {
        _testServerConnection(settings!.serverIp, silent: true);
      }
    });

    _bufferTimer =
        Timer.periodic(const Duration(milliseconds: 750), (t) {
      _flushNetworkBuffer();
    });
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    _barcodeScanner.close();
    _heartbeatTimer?.cancel();
    _bufferTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    if (_controller == null || !(_controller!.value.isInitialized)) return;

    if (state == AppLifecycleState.inactive) {
      try {
        if (_controller!.value.isStreamingImages) {
          await _controller!.stopImageStream();
        }
      } catch (_) {}
      await _controller!.dispose();
    } else if (state == AppLifecycleState.resumed) {
      await _initializeCamera();
    }
  }

  Future<void> _initEverything() async {
    final prefs = await SharedPreferences.getInstance();
    settings = AppSettings(prefs);
    setState(() {
      _invertColors = settings?.invertMode ?? false;
    });
    await _reloadListFromDb();
    if (settings?.serverIp.isNotEmpty == true) {
      _testServerConnection(settings!.serverIp);
    }
    await _initializeCamera();
    _updateStatusText();
  }

  Future<void> _reloadListFromDb() async {
    final dbRows = await DatabaseHelper.loadAllCodes();
    setState(() {
      scannedCodes.clear();
      scannedGtins.clear();
      _gtinCounts.clear();
      scannedTimestamps.clear();
      for (var row in dbRows) {
        String code = normalizeCode(row['barcode']);
        String gtin = row['gtin'] ?? "";
        scannedCodes.add(code);
        scannedTimestamps[code] =
            DateTime.now().subtract(const Duration(seconds: 10));
        if (gtin.isNotEmpty) {
          scannedGtins.add(gtin);
          _gtinCounts[gtin] = (_gtinCounts[gtin] ?? 0) + 1;
        }
      }
    });
  }

  Future<void> _testServerConnection(String serverIp,
      {bool silent = false}) async {
    try {
      final response = await http
          .get(Uri.parse('http://$serverIp/ping'))
          .timeout(const Duration(seconds: 2));
      if (response.statusCode == 200) {
        if (!isConnected) {
          setState(() {
            isConnected = true;
            if (!silent) {
              _showTemporaryMessage('BAĞLANDI',
                  const Duration(seconds: 2),
                  color: Colors.green);
            }
          });
        }
      } else {
        throw Exception();
      }
    } catch (_) {
      setState(() {
        isConnected = false;
        if (!silent) {
          statusText = "PC YOK";
          statusColor = Colors.red;
        }
      });
    }
  }

  // Kamerayı yeniden başlatmak için yardımcı fonksiyon
  Future<void> _restartCamera() async {
    try {
      if (_controller != null) {
        if (_controller!.value.isStreamingImages) {
          await _controller!.stopImageStream();
        }
        await _controller!.dispose();
      }
    } catch (_) {}
    await _initializeCamera();
  }

  // PERFORMANS AYARI + ÇÖZÜNÜRLÜK SEÇİMİ
  Future<void> _initializeCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isNotEmpty) {
        ResolutionPreset preset = ResolutionPreset.medium;

        // Kullanıcının Ayarlar ekranından seçtiği çözünürlüğü al
        String savedRes = settings?.resolution ?? 'medium';

        if (savedRes == 'low') {
          preset = ResolutionPreset.low;
        } else if (savedRes == 'medium') {
          preset = ResolutionPreset.medium;
        } else if (savedRes == 'high') {
          preset = ResolutionPreset.high;
        } else if (savedRes == 'veryHigh') {
          preset = ResolutionPreset.veryHigh;
        } else if (savedRes == 'ultraHigh') {
          preset = ResolutionPreset.ultraHigh;
        }

        _controller = CameraController(
          _cameras[0],
          preset,
          enableAudio: false,
          imageFormatGroup: Platform.isAndroid
              ? ImageFormatGroup.nv21
              : ImageFormatGroup.bgra8888,
        );
        await _controller!.initialize();
        try {
          await _controller!.setFocusMode(FocusMode.auto);
        } catch (_) {}
        try {
          await _controller!.setExposureMode(ExposureMode.auto);
        } catch (_) {}
        if (!mounted) return;
        _controller!.startImageStream(_scanBarcodes);
        setState(() {});
      }
    } catch (e) {
      if (mounted) {
        setState(() => statusText = 'Kamera Hatası');
      }
    }
  }

  Future<void> _scanBarcodes(CameraImage cameraImage) async {
    if (_isProcessing) return;

    if (DateTime.now()
            .difference(_lastProcessTime)
            .inMilliseconds <
        30) return;

    _isProcessing = true;
    _lastProcessTime = DateTime.now();
    try {
      final WriteBuffer allBytes = WriteBuffer();
      bool applyInvert = false;

      if (_invertColors && Platform.isAndroid) {
        _dynamicInvert = !_dynamicInvert;
        applyInvert = _dynamicInvert;
      }

      for (final Plane plane in cameraImage.planes) {
        if (applyInvert) {
          final bytes = plane.bytes;
          final inverted = Uint8List(bytes.length);
          for (int i = 0; i < bytes.length; i++) {
            inverted[i] = 255 - bytes[i];
          }
          allBytes.putUint8List(inverted);
        } else {
          allBytes.putUint8List(plane.bytes);
        }
      }

      final bytes = allBytes.done().buffer.asUint8List();
      final Size imageSize = Size(
        cameraImage.width.toDouble(),
        cameraImage.height.toDouble(),
      );

      final InputImageRotation rotation =
          InputImageRotationValue.fromRawValue(
                  _cameras[0].sensorOrientation) ??
              InputImageRotation.rotation90deg;

      final InputImageFormat format =
          InputImageFormatValue.fromRawValue(
                  cameraImage.format.raw) ??
              InputImageFormat.nv21;

      final inputImage = InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: imageSize,
          rotation: rotation,
          format: format,
          bytesPerRow: cameraImage.planes[0].bytesPerRow,
        ),
      );

      final List<Barcode> barcodes =
          await _barcodeScanner.processImage(inputImage);

      _cameraImageSize = Size(
        cameraImage.width.toDouble(),
        cameraImage.height.toDouble(),
      );

      if (barcodes.isNotEmpty) {
        for (Barcode barcode in barcodes) {
          if (barcode.rawValue != null) {
            _processFoundCodeFast(barcode.rawValue!);
          }
        }
        if (mounted) {
          setState(() {
            detectedBarcodes = barcodes;
          });
        }
      } else {
        if (!_invertColors || _processCounter % 3 == 0) {
          if (mounted) {
            setState(() => detectedBarcodes = []);
          }
        }
      }
      _processCounter++;
    } catch (e) {
    } finally {
      _isProcessing = false;
    }
  }

  bool _processFoundCodeFast(String rawCode) {
    String code = normalizeCode(rawCode);
    if (code.isEmpty) return false;

    if (code.length < 20 &&
        code.contains('.') &&
        code.contains(':')) {
      if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}:\d+$')
          .hasMatch(code)) {
        if (settings?.serverIp != code) {
          settings?.setServerIp(code);
          _showTemporaryMessage(
              'IP: $code', const Duration(seconds: 3),
              color: Colors.cyanAccent);
          _testServerConnection(code);
        }
        return false;
      }
    }

    if (code.length < 50 && !code.startsWith("01")) {
      if (DateTime.now()
              .difference(_lastScanSuccess)
              .inSeconds >
          2) {
        _tryImportPackageFromServer(code);
      }
      return false;
    }

    Map<String, String> info = parseGS1ForLabel(code);
    String gtin = info['GTIN'] ?? code;
    Gs1Status status = analyzeStatus(info['RAW_SKT'] ?? "");

    if (_isSingleMode) {
      if (_lastScannedCode == code &&
          DateTime.now()
                  .difference(_lastScanSuccess)
                  .inMilliseconds <
              1000) {
        return false;
      }
      _updateInfoDisplay(status, code, 1);
      _sendSingleCodeImmediate(
          formatForMedula(code, info));
      _lastScanSuccess = DateTime.now();
      _lastScannedCode = code;
      return true;
    }

    if (scannedCodes.contains(code)) {
      if (_lastScannedCode != code ||
          DateTime.now()
                  .difference(_lastScanSuccess)
                  .inMilliseconds >
              2000) {
        int count = _gtinCounts[gtin] ?? 0;
        _updateInfoDisplay(status, code, count);
        _playBeep(warning: false);
        _showTemporaryMessage(
            "LİSTEDE VAR", const Duration(seconds: 1),
            color: Colors.orange);
        _lastScanSuccess = DateTime.now();
        _lastScannedCode = code;
      }
      return false;
    }

    if (status.text == "MİADI GEÇMİŞ") {
      if (_lastScannedCode != code) {
        _playBeep(warning: true);
        _showTemporaryMessage(
            "MİADI GEÇMİŞ!", const Duration(seconds: 2),
            color: Colors.red);
        _lastScannedCode = code;
      }
      return false;
    }

    if (!_networkBuffer.contains(code)) {
      _networkBuffer.add(code);
    }
    scannedCodes.add(code);
    if (gtin.isNotEmpty) scannedGtins.add(gtin);
    scannedTimestamps[code] = DateTime.now();
    _gtinCounts[gtin] = (_gtinCounts[gtin] ?? 0) + 1;

    DatabaseHelper.insertCodeFast(
        code, gtin, "İlaç/Ürün");
    _lastScanSuccess = DateTime.now();
    _lastScannedCode = code;
    _updateInfoDisplay(
        status, code, _gtinCounts[gtin] ?? 1);
    bool isCritical = status.text.contains("<");
    _playBeep(warning: isCritical);
    return true;
  }

  Future<void> _flushNetworkBuffer() async {
    if (_networkBuffer.isEmpty || _isSendingBuffer) return;
    final serverIp = settings?.serverIp ?? '';
    if (serverIp.isEmpty) return;

    _isSendingBuffer = true;
    final List<String> toSend =
        List<String>.from(_networkBuffer);

    try {
      final response = await http
          .post(
            Uri.parse('http://$serverIp/append_pool'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'codes': toSend}),
          )
          .timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (mounted) {
          setState(() {
            _serverCount = data['total'] ?? 0;
            _updateStatusText();
          });
        }
        // Başarılı gönderilenleri buffer'dan çıkar
        for (final c in toSend) {
          _networkBuffer.remove(c);
        }
      }
    } catch (e) {
      // Hata olursa buffer olduğu gibi kalsın, karekodlar kaybolmasın
    } finally {
      _isSendingBuffer = false;
    }
  }

  Future<void> _pastePoolToPC() async {
    final serverIp = settings?.serverIp ?? '';
    if (serverIp.isEmpty) return;
    setState(() => busy = true);
    try {
      final res = await http
          .post(Uri.parse('http://$serverIp/paste_pool'));
      if (res.statusCode == 200) {
        _playBeep(warning: false);
        _showTemporaryMessage(
            "PC'YE AKTARILDI", const Duration(seconds: 3),
            color: Colors.green);
      }
    } catch (e) {
      _showTemporaryMessage(
          "HATA", const Duration(seconds: 2),
          color: Colors.red);
    } finally {
      setState(() => busy = false);
    }
  }

  Future<void> _clearPool() async {
    final serverIp = settings?.serverIp ?? '';
    if (serverIp.isEmpty) return;
    try {
      await http.post(Uri.parse('http://$serverIp/clear_pool'));
      setState(() {
        scannedCodes.clear();
        scannedGtins.clear();
        scannedTimestamps.clear();
        _serverCount = 0;
        _gtinCounts.clear();
        _updateStatusText();
      });
      await DatabaseHelper.clearCodes();
      _showTemporaryMessage(
          "LİSTE TEMİZLENDİ",
          const Duration(seconds: 2),
          color: Colors.orange);
    } catch (e) {}
  }

  Future<void> _tryImportPackageFromServer(String pkgName) async {
    final serverIp = settings?.serverIp ?? '';
    if (serverIp.isEmpty) return;
    try {
      final response = await http
          .get(Uri.parse(
              'http://$serverIp/get_package?name=$pkgName'))
          .timeout(const Duration(seconds: 3));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        List<dynamic> items = data['barcodes'] ?? [];
        if (items.isNotEmpty) {
          _playBeep(warning: false);
          _showTemporaryMessage(
              "PAKET YÜKLENİYOR...",
              const Duration(seconds: 1),
              color: Colors.yellow);
          List<String> strItems =
              items.map((e) => e.toString()).toList();
          await DatabaseHelper.insertBatch(strItems, pkgName);
          await _reloadListFromDb();
          _lastScanSuccess = DateTime.now();
          _showTemporaryMessage(
              "${items.length} ÜRÜN EKLENDİ",
              const Duration(seconds: 3),
              color: Colors.green);
        } else {
          _showTemporaryMessage(
              "PAKET BOŞ", const Duration(seconds: 2),
              color: Colors.red);
        }
      }
    } catch (_) {}
  }

  void _updateInfoDisplay(
      Gs1Status status, String code, int totalCount) {
    if (mounted) {
      setState(() {
        _lastExpDate = status.date;
        _lastDaysLeft = "${status.days}";
        _lastStatus = status.text;
        _lastItemName =
            "...${code.substring(code.length > 10 ? code.length - 10 : 0)}";
        _lastTotalCount = totalCount;
      });
    }
  }

  Future<void> _sendSingleCodeImmediate(String code) async {
    final serverIp = settings?.serverIp ?? '';
    if (serverIp.isEmpty) return;
    setState(() {
      statusText = "GÖNDERİLİYOR...";
      statusColor = Colors.yellow;
    });

    http
        .post(
      Uri.parse('http://$serverIp/send'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'barcodes': [code]}),
    )
        .then((response) {
      if (response.statusCode == 200) {
        _playBeep(warning: false);
        if (mounted) {
          setState(() {
            statusText = "AKTARILDI";
            statusColor = Colors.green;
          });
        }
        Future.delayed(
            const Duration(seconds: 1), _updateStatusText);
      } else {
        _playBeep(warning: true);
        if (mounted) {
          setState(() {
            statusText = "PC HATASI";
            statusColor = Colors.red;
          });
        }
      }
    }).catchError((e) {
      _playBeep(warning: true);
      if (mounted) {
        setState(() {
          statusText = "BAĞLANTI HATASI";
          statusColor = Colors.red;
        });
      }
    });
  }

  void _updateStatusText() {
    if (mounted) {
      setState(() {
        String mode = _isSingleMode ? "ANLIK" : "LİSTE";
        statusText =
            "$mode | Kutu: ${scannedCodes.length} (PC: $_serverCount)";
        if (!statusText.contains("HATA") &&
            !statusText.contains("GÖNDERİLİYOR")) {
          statusColor = Colors.white;
        }
      });
    }
  }

  void _showTemporaryMessage(
      String m, Duration d,
      {Color color = Colors.white}) {
    if (mounted) {
      setState(() {
        statusText = m;
        statusColor = color;
      });
    }
    Future.delayed(d, () {
      if (mounted) _updateStatusText();
    });
  }

  Future<void> _playBeep({required bool warning}) async {
    try {
      final player = AudioPlayer();
      await player.play(
        AssetSource(warning
            ? 'default_warn.mp3'
            : 'default_ok.mp3'),
        mode: PlayerMode.lowLatency,
      );
    } catch (_) {}
  }

  Future<void> _uploadImage(ImageSource source) async {
    final serverIp = settings?.serverIp ?? '';
    if (serverIp.isEmpty) {
      _showTemporaryMessage(
          "Önce IP Ayarla!",
          const Duration(seconds: 2),
          color: Colors.red);
      return;
    }
    final picker = ImagePicker();
    if (source == ImageSource.gallery) {
      final List<XFile> images =
          await picker.pickMultiImage(imageQuality: 70);
      if (images.isNotEmpty) {
        setState(() => busy = true);
        try {
          var request = http.MultipartRequest(
              'POST',
              Uri.parse('http://$serverIp/upload'));
          for (var img in images) {
            request.files.add(
              await http.MultipartFile.fromPath(
                  'image', img.path),
            );
          }
          var response = await request.send().timeout(
              const Duration(seconds: 60));
          if (response.statusCode == 200) {
            _showTemporaryMessage(
                "${images.length} FOTO GÖNDERİLDİ",
                const Duration(seconds: 2),
                color: Colors.green);
          } else {
            _showTemporaryMessage(
                "HATA",
                const Duration(seconds: 2),
                color: Colors.red);
          }
        } catch (e) {
          _showTemporaryMessage(
              "BAĞLANTI YOK",
              const Duration(seconds: 2),
              color: Colors.red);
        } finally {
          setState(() => busy = false);
        }
      }
    } else {
      final XFile? image = await picker.pickImage(
          source: source, imageQuality: 70);
      if (image != null) {
        setState(() => busy = true);
        try {
          var request = http.MultipartRequest(
              'POST',
              Uri.parse('http://$serverIp/upload'));
          request.files.add(
            await http.MultipartFile.fromPath(
                'image', image.path),
          );
          var response = await request.send().timeout(
              const Duration(seconds: 30));
          if (response.statusCode == 200) {
            _showTemporaryMessage(
                "GÖNDERİLDİ",
                const Duration(seconds: 2),
                color: Colors.green);
          } else {
            _showTemporaryMessage(
                "HATA",
                const Duration(seconds: 2),
                color: Colors.red);
          }
        } catch (e) {
          _showTemporaryMessage(
              "BAĞLANTI YOK",
              const Duration(seconds: 2),
              color: Colors.red);
        } finally {
          setState(() => busy = false);
        }
      }
    }
  }

  Future<void> _uploadAnyFile() async {
    final serverIp = settings?.serverIp ?? '';
    if (serverIp.isEmpty) {
      _showTemporaryMessage(
          "Önce IP Ayarla!",
          const Duration(seconds: 2),
          color: Colors.red);
      return;
    }
    FilePickerResult? result =
        await FilePicker.platform.pickFiles(
      allowMultiple: true,
    );
    if (result != null && result.files.isNotEmpty) {
      setState(() => busy = true);
      try {
        var request = http.MultipartRequest(
          'POST',
          Uri.parse('http://$serverIp/upload_general'),
        );
        for (var file in result.files) {
          if (file.path != null) {
            request.files.add(
              await http.MultipartFile.fromPath(
                  'file', file.path!),
            );
          }
        }
        var response =
            await request.send().timeout(
                  const Duration(seconds: 120),
                );
        if (response.statusCode == 200) {
          _showTemporaryMessage(
              "${result.files.length} DOSYA GÖNDERİLDİ",
              const Duration(seconds: 2),
              color: Colors.green);
        } else {
          _showTemporaryMessage(
              "SUNUCU HATASI",
              const Duration(seconds: 2),
              color: Colors.red);
        }
      } catch (e) {
        _showTemporaryMessage(
            "BAĞLANTI YOK",
            const Duration(seconds: 2),
            color: Colors.red);
      } finally {
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null ||
        !_controller!.value.isInitialized) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final Size screenSize = MediaQuery.of(context).size;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            IconButton(
                icon: const Icon(Icons.menu,
                    color: Colors.blueAccent),
                onPressed: () => _showMenu(context)),
            const SizedBox(width: 5),
            Icon(
              Icons.circle,
              color: isConnected
                  ? Colors.green
                  : Colors.red,
              size: 14,
            ),
            const SizedBox(width: 8),
            Text(
              isConnected ? 'BAĞLI' : 'KOPUK',
              style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold),
            )
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      SettingsScreen(settings: settings!),
                ),
              );
              setState(() {
                _invertColors =
                    settings?.invertMode ?? false;
              });
              // Çözünürlük / invert değişmiş olabilir, kamerayı yeniden başlat
              await _restartCamera();
            },
          ),
          IconButton(
            icon: const Icon(Icons.power_settings_new,
                color: Colors.red),
            onPressed: () {
              if (Platform.isAndroid) {
                SystemNavigator.pop();
                exit(0);
              } else {
                exit(0);
              }
            },
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(_controller!),
          if (_cameraImageSize != null)
            CustomPaint(
              painter: BarcodeDetectorPainter(
                detectedBarcodes,
                _cameraImageSize!,
                screenSize,
                scannedCodes,
                scannedTimestamps,
              ),
            ),
          Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 2),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius:
                      BorderRadius.circular(8),
                  border: Border.all(
                      color: Colors.white24),
                ),
                child: Column(
                  children: [
                    Text(
                      "$_lastItemName (x$_lastTotalCount)",
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Row(
                      mainAxisAlignment:
                          MainAxisAlignment.spaceAround,
                      children: [
                        Column(
                          children: [
                            const Text(
                              "SKT",
                              style: TextStyle(
                                  color: Colors.grey,
                                  fontSize: 10),
                            ),
                            Text(
                              _lastExpDate,
                              style: const TextStyle(
                                color: Colors.yellow,
                                fontWeight:
                                    FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        Column(
                          children: [
                            const Text(
                              "KALAN",
                              style: TextStyle(
                                  color: Colors.grey,
                                  fontSize: 10),
                            ),
                            Text(
                              _lastDaysLeft,
                              style: const TextStyle(
                                color: Colors.cyan,
                                fontSize: 16,
                                fontWeight:
                                    FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        Column(
                          children: [
                            const Text(
                              "DURUM",
                              style: TextStyle(
                                  color: Colors.grey,
                                  fontSize: 10),
                            ),
                            Text(
                              _lastStatus,
                              style: const TextStyle(
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ],
                    )
                  ],
                ),
              ),
              if (!_isSingleMode)
                Container(
                  margin: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 2),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.indigo.shade900,
                    borderRadius:
                        BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisAlignment:
                        MainAxisAlignment.spaceAround,
                    children: [
                      Text(
                        "ÇEŞİT: ${scannedGtins.length}",
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight:
                              FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        "TOPLAM KUTU: ${scannedCodes.length}",
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight:
                              FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                ),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 5),
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: () => setState(() {
                          _isSingleMode = true;
                          _updateStatusText();
                        }),
                        child: Container(
                          padding:
                              const EdgeInsets.symmetric(
                                  vertical: 12),
                          decoration: BoxDecoration(
                            color: _isSingleMode
                                ? Colors.blueAccent
                                : Colors.black54,
                            borderRadius:
                                BorderRadius.circular(8),
                          ),
                          child: const Center(
                            child: Text(
                              "ANLIK (Gönder)",
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight:
                                    FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: InkWell(
                        onTap: () => setState(() {
                          _isSingleMode = false;
                          _updateStatusText();
                        }),
                        child: Container(
                          padding:
                              const EdgeInsets.symmetric(
                                  vertical: 12),
                          decoration: BoxDecoration(
                            color: !_isSingleMode
                                ? Colors.orange
                                : Colors.black54,
                            borderRadius:
                                BorderRadius.circular(8),
                          ),
                          child: const Center(
                            child: Text(
                              "LİSTE (Biriktir)",
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight:
                                    FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(
                    10, 0, 10, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 40,
                        child: ElevatedButton.icon(
                          icon: const Icon(
                            Icons.camera_alt,
                            size: 18,
                          ),
                          label: const Text(
                            "FOTO",
                            style:
                                TextStyle(fontSize: 12),
                          ),
                          style: ElevatedButton
                              .styleFrom(
                            backgroundColor:
                                Colors.blueGrey,
                          ),
                          onPressed: () =>
                              _uploadImage(
                                  ImageSource.camera),
                        ),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: SizedBox(
                        height: 40,
                        child: ElevatedButton.icon(
                          icon: const Icon(
                            Icons.photo_library,
                            size: 18,
                          ),
                          label: const Text(
                            "GALERİ (Çoklu)",
                            style:
                                TextStyle(fontSize: 12),
                          ),
                          style: ElevatedButton
                              .styleFrom(
                            backgroundColor:
                                Colors.blueGrey,
                          ),
                          onPressed: () =>
                              _uploadImage(
                                  ImageSource.gallery),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (busy)
            Container(
              color: Colors.black54,
              child: const Center(
                child: CircularProgressIndicator(),
              ),
            ),
        ],
      ),
    );
  }

  void _showMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      builder: (c) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading:
                const Icon(Icons.list, color: Colors.blue),
            title: const Text(
              "Listeyi Görüntüle / Düzenle",
              style: TextStyle(color: Colors.white),
            ),
            onTap: () {
              Navigator.pop(c);
              _openDetailListScreen();
            },
          ),
          ListTile(
            leading: const Icon(Icons.qr_code_2,
                color: Colors.orange),
            title: const Text(
              "Paket Oluştur",
              style: TextStyle(color: Colors.white),
            ),
            onTap: () {
              Navigator.pop(c);
              _showNameDialog(context);
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.send,
                color: Colors.green),
            title: const Text(
              "PC'ye Aktar",
              style: TextStyle(color: Colors.white),
            ),
            onTap: () {
              Navigator.pop(c);
              _pastePoolToPC();
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever,
                color: Colors.red),
            title: const Text(
              "Havuzu Temizle",
              style: TextStyle(color: Colors.white),
            ),
            onTap: () {
              Navigator.pop(c);
              _clearPool();
            },
          ),
        ],
      ),
    );
  }

  void _openDetailListScreen() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) => DetailListScreen(
          settings: settings!,
          onClear: () {
            setState(() {
              scannedCodes.clear();
              scannedGtins.clear();
              scannedTimestamps.clear();
              _gtinCounts.clear();
              _updateStatusText();
            });
          },
        ),
      ),
    );
  }

  void _showNameDialog(BuildContext context) {
    if (scannedCodes.isEmpty) return;
    final TextEditingController controller =
        TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Paket Adı'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
              hintText: "Örn: Koli 1"),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("İptal"),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _showPackageQrDialog(context, controller.text);
            },
            child: const Text("DEVAM ET"),
          ),
        ],
      ),
    );
  }

  Future<void> _showPackageQrDialog(
      BuildContext context, String pkgName) async {
    List<String> listToSend = [];
    for (String c in scannedCodes) {
      listToSend.add(
          formatForMedula(c, parseGS1ForLabel(c)));
    }
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: Colors.white,
          title: const Text(
            "Paket Hazır",
            style: TextStyle(color: Colors.black),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                "Paket Karekodu (PC'de Okutun):",
                style: TextStyle(color: Colors.black),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: 250,
                height: 250,
                child: QrImageView(
                  data: pkgName,
                  version: QrVersions.auto,
                  size: 250,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                "${listToSend.length} Kutu",
                style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.black),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("KAPAT"),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
              ),
              onPressed: () {
                Navigator.pop(ctx);
                _sendPackageToServer(pkgName, listToSend);
              },
              child: const Text("PC'ye KAYDET"),
            ),
          ],
        );
      },
    );
  }

  Future<void> _sendPackageToServer(
      String qrName, List<String> listToSend) async {
    if (settings?.serverIp.isEmpty ?? true) return;
    setState(() => busy = true);
    try {
      final payload = {
        'name': qrName,
        'barcodes': listToSend,
      };
      final response = await http
          .post(
            Uri.parse('http://${settings!.serverIp}/package'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 15));
      if (mounted && response.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
                  Text('Paket PC\'ye Kaydedildi!')),
        );
      } else {
        _showTemporaryMessage(
            'Başarısız',
            const Duration(seconds: 2),
            color: Colors.red);
      }
    } catch (e) {
      _showTemporaryMessage(
          'Hata',
          const Duration(seconds: 2),
          color: Colors.red);
    } finally {
      setState(() => busy = false);
    }
  }
}

class DetailListScreen extends StatefulWidget {
  final AppSettings settings;
  final VoidCallback onClear;
  const DetailListScreen(
      {super.key,
      required this.settings,
      required this.onClear});

  @override
  State<DetailListScreen> createState() =>
      _DetailListScreenState();
}

class _DetailListScreenState extends State<DetailListScreen> {
  List<Map<String, dynamic>> items = [];
  bool loading = true;
  bool creatingPdf = false;

  @override
  void initState() {
    super.initState();
    _loadItems();
  }

  Future<void> _loadItems() async {
    final rows = await DatabaseHelper.loadAllCodes();
    setState(() {
      items = List.from(rows.reversed);
      loading = false;
    });
  }

  Future<void> _deleteItem(int id) async {
    final db = DatabaseHelper._db;
    await db!.delete(
      'codes',
      where: 'id = ?',
      whereArgs: [id],
    );
    _loadItems();
  }

  Future<void> _updateName(
      int id, String currentName) async {
    TextEditingController tc =
        TextEditingController(text: currentName);
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text("İsim Ver"),
        content: TextField(controller: tc),
        actions: [
          ElevatedButton(
            onPressed: () async {
              final db = DatabaseHelper._db;
              await db!.update(
                'codes',
                {'name': tc.text},
                where: 'id = ?',
                whereArgs: [id],
              );
              Navigator.pop(c);
              _loadItems();
            },
            child: const Text("KAYDET"),
          ),
        ],
      ),
    );
  }

  Future<void> _printLabels() async {
    if (items.isEmpty) return;
    setState(() => creatingPdf = true);
    await Future.delayed(
        const Duration(milliseconds: 100));
    try {
      await Printing.layoutPdf(
        name: 'Barkodlar',
        onLayout: (PdfPageFormat format) async {
          final doc = pw.Document();
          final double labelWidth = 140;
          doc.addPage(
            pw.MultiPage(
              pageFormat: format,
              margin: const pw.EdgeInsets.all(10),
              build: (pw.Context context) {
                return [
                  pw.Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: items.map((item) {
                      String code = item['barcode'];
                      String name =
                          item['name'] ?? "İlaç/Ürün";
                      String gtin =
                          item['gtin'] ?? "";
                      Map<String, String> info =
                          parseGS1ForLabel(code);
                      return pw.Container(
                        width: labelWidth,
                        height: 60,
                        padding:
                            const pw.EdgeInsets.all(3),
                        decoration: pw.BoxDecoration(
                          border: pw.Border.all(
                            color: PdfColors.black,
                            width: 0.5,
                          ),
                        ),
                        child: pw.Row(
                          children: [
                            pw.BarcodeWidget(
                              data: code,
                              barcode:
                                  pw.Barcode.dataMatrix(),
                              width: 54,
                              height: 54,
                              drawText: false,
                            ),
                            pw.SizedBox(width: 4),
                            pw.Expanded(
                              child: pw.Column(
                                crossAxisAlignment:
                                    pw.CrossAxisAlignment
                                        .start,
                                mainAxisAlignment:
                                    pw.MainAxisAlignment
                                        .center,
                                children: [
                                  pw.Text(
                                    name,
                                    style: pw.TextStyle(
                                      fontSize: 7,
                                      fontWeight: pw
                                          .FontWeight
                                          .bold,
                                    ),
                                    maxLines: 2,
                                    overflow: pw
                                        .TextOverflow
                                        .clip,
                                  ),
                                  pw.SizedBox(height: 2),
                                  pw.Text(
                                    "GT: $gtin",
                                    style: const pw
                                        .TextStyle(
                                            fontSize: 6),
                                  ),
                                  pw.Text(
                                    "SN: ${info['SN']}",
                                    style: const pw
                                        .TextStyle(
                                            fontSize: 6),
                                  ),
                                  pw.Text(
                                    "SKT: ${info['SKT']}",
                                    style: pw.TextStyle(
                                      fontSize: 7,
                                      fontWeight: pw
                                          .FontWeight
                                          .bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ];
              },
            ),
          );
          return doc.save();
        },
      );
    } catch (e) {
    } finally {
      if (mounted) {
        setState(() => creatingPdf = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Liste (${items.length})"),
        actions: [
          IconButton(
            icon: const Icon(Icons.print),
            onPressed: (items.isEmpty || creatingPdf)
                ? null
                : _printLabels,
          ),
          IconButton(
            icon: const Icon(Icons.delete_forever,
                color: Colors.red),
            onPressed: () {
              widget.onClear();
              Navigator.pop(context);
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          loading
              ? const Center(
                  child: CircularProgressIndicator(),
                )
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (c, i) {
                    final item = items[i];
                    return Card(
                      margin:
                          const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 2),
                      child: ListTile(
                        dense: true,
                        title: Text(
                          item['name'] ?? "Ürün",
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: Text(
                          item['barcode'],
                          style: const TextStyle(
                            fontSize: 10,
                            fontFamily: "monospace",
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(
                                Icons.edit,
                                color: Colors.blue,
                              ),
                              onPressed: () =>
                                  _updateName(
                                      item['id'],
                                      item['name'] ??
                                          ""),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.delete,
                                color: Colors.red,
                              ),
                              onPressed: () =>
                                  _deleteItem(
                                      item['id']),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
          if (creatingPdf)
            Container(
              color: Colors.black54,
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(
                        color: Colors.white),
                    SizedBox(height: 20),
                    Text(
                      "PDF Hazırlanıyor...",
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class BarcodeDetectorPainter extends CustomPainter {
  final List<Barcode> barcodes;
  final Size absoluteImageSize;
  final Size screenSize;
  final Set<String> scannedCodes;
  final Map<String, DateTime> scannedTimestamps;

  BarcodeDetectorPainter(
    this.barcodes,
    this.absoluteImageSize,
    this.screenSize,
    this.scannedCodes,
    this.scannedTimestamps,
  );

  @override
  void paint(Canvas canvas, Size size) {
    final double scaleX =
        size.width / absoluteImageSize.height;
    final double scaleY =
        size.height / absoluteImageSize.width;
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0;

    final now = DateTime.now();

    for (final Barcode barcode in barcodes) {
      final rawValue = normalizeCode(barcode.rawValue);
      bool isJustScanned = false;
      Color statusColor = Colors.green;

      Map<String, String> info =
          parseGS1ForLabel(rawValue);
      Gs1Status status =
          analyzeStatus(info['RAW_SKT'] ?? "");
      statusColor = status.color;

      if (scannedCodes.contains(rawValue)) {
        paint.color = Colors.yellow;
        if (scannedTimestamps.containsKey(rawValue) &&
            now
                    .difference(
                        scannedTimestamps[rawValue]!)
                    .inMilliseconds <
                1000) {
          isJustScanned = true;
          paint.color = (now
                          .difference(
                              scannedTimestamps[
                                  rawValue]!)
                          .inMilliseconds %
                      200 <
                  100)
              ? Colors.yellow
              : statusColor;
        }
      } else {
        paint.color = statusColor;
      }

      final rect = barcode.boundingBox;
      final double left = rect.left * scaleX;
      final double top = rect.top * scaleY;
      final double right = rect.right * scaleX;
      final double bottom = rect.bottom * scaleY;

      canvas.drawRRect(
        RRect.fromRectXY(
          Rect.fromLTRB(left, top, right, bottom),
          8,
          8,
        ),
        paint,
      );

      String skt = info['SKT'] ?? "";
      if (skt.isNotEmpty) {
        final textSpan = TextSpan(
          text: skt,
          style: TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.bold,
            backgroundColor:
                statusColor.withOpacity(0.7),
          ),
        );
        final textPainter = TextPainter(
          text: textSpan,
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
        );
        textPainter.layout();
        textPainter.paint(
            canvas, Offset(left, bottom + 5));
      }
    }
  }

  @override
  bool shouldRepaint(old) => true;
}

class SettingsScreen extends StatefulWidget {
  final AppSettings settings;
  const SettingsScreen({super.key, required this.settings});

  @override
  State<SettingsScreen> createState() =>
      _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController serverCtrl;
  late bool invertMode;
  late String resolution;

  @override
  void initState() {
    super.initState();
    serverCtrl =
        TextEditingController(text: widget.settings.serverIp);
    invertMode = widget.settings.invertMode;
    resolution = widget.settings.resolution;
  }

  void _save() async {
    await widget.settings
        .setServerIp(serverCtrl.text.trim());
    await widget.settings.setInvertMode(invertMode);
    await widget.settings.setResolution(resolution);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ayarlar Kaydedildi!')),
      );
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ayarlar')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: Colors.grey[900],
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: TextField(
                controller: serverCtrl,
                decoration: const InputDecoration(
                  labelText: 'PC IP',
                  prefixIcon: Icon(Icons.computer),
                  border: InputBorder.none,
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Card(
            color: Colors.grey[900],
            child: SwitchListTile(
              title: const Text(
                  'Siyah Zemin Modu (Ters Karekod)'),
              secondary: const Icon(Icons.invert_colors,
                  color: Colors.yellow),
              value: invertMode,
              onChanged: (v) =>
                  setState(() => invertMode = v),
            ),
          ),
          const SizedBox(height: 10),
          Card(
            color: Colors.grey[900],
            child: ListTile(
              leading: const Icon(Icons.camera,
                  color: Colors.blue),
              title: const Text("Kamera Çözünürlüğü"),
              trailing: DropdownButton<String>(
                value: resolution,
                items: const [
                  DropdownMenuItem(
                    value: 'low',
                    child: Text('Düşük'),
                  ),
                  DropdownMenuItem(
                    value: 'medium',
                    child: Text('Orta (En Hızlı)'),
                  ),
                  DropdownMenuItem(
                    value: 'high',
                    child: Text('Yüksek (Kasar)'),
                  ),
                  DropdownMenuItem(
                    value: 'veryHigh',
                    child: Text('Çok Yüksek'),
                  ),
                  DropdownMenuItem(
                    value: 'ultraHigh',
                    child: Text('Ultra'),
                  ),
                ],
                onChanged: (v) =>
                    setState(() => resolution = v!),
              ),
            ),
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: const Text('KAYDET'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              minimumSize:
                  const Size(double.infinity, 50),
            ),
          ),
          const Divider(),
          ElevatedButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => FileBrowserScreen(
                    serverIp: widget.settings.serverIp,
                    onUpload: () {},
                  ),
                ),
              );
            },
            child:
                const Text("Dosyaları İndir / Yükle"),
          ),
        ],
      ),
    );
  }
}

class FileBrowserScreen extends StatefulWidget {
  final String serverIp;
  final VoidCallback onUpload;
  const FileBrowserScreen(
      {super.key,
      required this.serverIp,
      required this.onUpload});

  @override
  State<FileBrowserScreen> createState() =>
      _FileBrowserScreenState();
}

class _FileBrowserScreenState
    extends State<FileBrowserScreen> {
  List<String> files = [];
  bool loading = true;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    _fetchFiles();
  }

  Future<void> _fetchFiles() async {
    try {
      final res = await http.get(
        Uri.parse('http://${widget.serverIp}/files'),
      );
      if (res.statusCode == 200) {
        setState(() {
          files = List<String>.from(
              jsonDecode(res.body)['files']);
          loading = false;
        });
      } else {
        setState(() {
          loading = false;
        });
      }
    } catch (e) {
      setState(() {
        loading = false;
      });
    }
  }

  Future<void> _uploadHere() async {
    FilePickerResult? result =
        await FilePicker.platform.pickFiles(
      allowMultiple: true,
    );
    if (result != null && result.files.isNotEmpty) {
      setState(() => busy = true);
      try {
        var request = http.MultipartRequest(
          'POST',
          Uri.parse(
              'http://${widget.serverIp}/upload_general'),
        );
        for (var file in result.files) {
          if (file.path != null) {
            request.files.add(
              await http.MultipartFile.fromPath(
                  'file', file.path!),
            );
          }
        }
        var response = await request.send();
        if (response.statusCode == 200) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content:
                    Text('Dosyalar Gönderildi!')),
          );
          _fetchFiles();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Hata')),
          );
        }
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Bağlantı Hatası')),
        );
      } finally {
        setState(() => busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Dosyalar"),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchFiles,
          ),
        ],
      ),
      body: Column(
        children: [
          if (busy) const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: ElevatedButton.icon(
              onPressed: _uploadHere,
              icon: const Icon(Icons.upload_file),
              label: const Text("GENEL DOSYA YÜKLE"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.indigo,
                minimumSize:
                    const Size(double.infinity, 50),
              ),
            ),
          ),
          Expanded(
            child: loading
                ? const Center(
                    child:
                        CircularProgressIndicator(),
                  )
                : ListView.builder(
                    itemCount: files.length,
                    itemBuilder: (c, i) => ListTile(
                      leading:
                          const Icon(Icons.file_present),
                      title: Text(files[i]),
                      onTap: () => launchUrl(
                        Uri.parse(
                            'http://${widget.serverIp}/files/${files[i]}'),
                        mode: LaunchMode
                            .externalApplication,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
