// lib/main.dart - V61.0 (2026-10-16): ilaç adı (TİTCK), BİLGİ modu, sayım özeti, PC senkronu, yeni etiket, otomatik güncelleme, PIN

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

// V60.3: Paket adı QR'da, sunucu dosya adında ve okutunca aynı kalsın diye
// Türkçe harfler sadeleştirilir, harf/rakam dışı her şey atılır; boşsa otomatik ad
String paketAdiDuzelt(String ad) {
  const tr = {
    'ç': 'c', 'Ç': 'C', 'ğ': 'g', 'Ğ': 'G', 'ı': 'i', 'İ': 'I',
    'ö': 'o', 'Ö': 'O', 'ş': 's', 'Ş': 'S', 'ü': 'u', 'Ü': 'U'
  };
  String s = ad.trim().split('').map((c) => tr[c] ?? c).join();
  s = s.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '');
  if (s.startsWith('01')) s = 'P$s';
  if (s.isEmpty) {
    s = 'Paket${DateTime.now().millisecondsSinceEpoch ~/ 1000}';
  }
  return s;
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
          // V60.3: gün 00 = ay sonu (GS1). Yıl bugünden ±12 yıl içinde olmalı
          // (eskiden y<23 reddediliyordu: 2022 ve öncesi miadı geçmişler "geçerli" görünüyordu)
          int fullYear = 2000 + y;
          int nowY = DateTime.now().year;
          bool isValidDate = (m >= 1 && m <= 12) &&
              (d >= 0 && d <= 31) &&
              fullYear >= nowY - 12 &&
              fullYear <= nowY + 12;
          if (isValidDate) {
            rawDateFound = potentialDate;
            if (d == 0) d = DateTime(fullYear, m + 1, 0).day;
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
      return Gs1Status("<1 AY ($days Gn)", Colors.purpleAccent, fmt, days);
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

// ---------------------------------------------------------------------------
// V61: Sunucu adresi (+ isteğe bağlı PIN) ve derleme numarası
// ---------------------------------------------------------------------------
String gSunucuPin = '';
Uri sunucuUri(String ip, String yol) {
  final u = Uri.parse('http://$ip$yol');
  if (gSunucuPin.isEmpty) return u;
  return u.replace(queryParameters: {...u.queryParameters, 'pin': gSunucuPin});
}

const int kDerlemeNo = int.fromEnvironment('BUILD_NUMBER', defaultValue: 0);

Map<String, dynamic> jsonCozIsolate(String s) =>
    jsonDecode(s) as Map<String, dynamic>;

// ---------------------------------------------------------------------------
// V61: TİTCK SKRS ilaç listesi (sunucudan indirilir, telefonda SQLite'ta durur)
// ---------------------------------------------------------------------------
class IlacBilgi {
  final String ad, atc, etken, receteTuru, durum;
  IlacBilgi(this.ad, this.atc, this.etken, this.receteTuru, this.durum);
  bool get pasif => durum == 'P';
  String get rozet {
    final r = receteTuru.trim();
    if (pasif) return r.isNotEmpty && r != 'Normal' ? 'PASİF • ${r.toUpperCase()}' : 'PASİF ÜRÜN';
    if (r.isEmpty || r == 'Normal') return '';
    return '${r.toUpperCase()} REÇETE';
  }

  Color get rozetRengi {
    if (pasif) return Colors.grey;
    switch (receteTuru.trim()) {
      case 'Kırmızı':
        return Colors.red;
      case 'Yeşil':
        return Colors.green;
      case 'Mor':
        return Colors.purple;
      case 'Turuncu':
        return Colors.orange;
    }
    return Colors.blueGrey;
  }
}

class IlacListesi {
  static final Map<String, IlacBilgi> _m = {};
  static String surum = '';
  static int get adet => _m.length;

  static IlacBilgi? bul(String gtin) {
    if (gtin.isEmpty) return null;
    return _m[gtin.padLeft(14, '0')];
  }

  static Future<void> yukle() async {
    try {
      await DatabaseHelper.initDbIfNeeded();
      final rows = await DatabaseHelper.db.query('ilaclar');
      _m.clear();
      for (final r in rows) {
        _m[r['gtin'] as String] = IlacBilgi(
            (r['ad'] ?? '') as String,
            (r['atc'] ?? '') as String,
            (r['etken'] ?? '') as String,
            (r['rt'] ?? '') as String,
            (r['durum'] ?? 'A') as String);
      }
      surum = (await SharedPreferences.getInstance()).getString('ilac_surum') ?? '';
    } catch (_) {}
  }

  static Future<int> kaydet(Map<String, dynamic> veri) async {
    final il = (veri['ilaclar'] as Map).cast<String, dynamic>();
    final db = DatabaseHelper.db;
    await db.transaction((txn) async {
      await txn.delete('ilaclar');
      final b = txn.batch();
      il.forEach((g, v) {
        final l = (v as List).map((e) => (e ?? '').toString()).toList();
        b.insert('ilaclar', {
          'gtin': g,
          'ad': l[0],
          'atc': l.length > 1 ? l[1] : '',
          'etken': l.length > 2 ? l[2] : '',
          'rt': l.length > 3 ? l[3] : '',
          'durum': l.length > 4 ? l[4] : 'A'
        });
      });
      await b.commit(noResult: true);
    });
    surum = (veri['surum'] ?? '').toString();
    await (await SharedPreferences.getInstance()).setString('ilac_surum', surum);
    await yukle();
    return _m.length;
  }
}

class DatabaseHelper {
  static Database? _db;
  static Database get db => _db!;

  static Future<void> initDbIfNeeded() async {
    if (_db != null) return;
    final documents = await getApplicationDocumentsDirectory();
    final dbPath = p.join(documents.path, 'codes_v60_final.db');
    _db = await openDatabase(dbPath, version: 1,
        onCreate: (db, version) async {
      await db.execute(
          'CREATE TABLE codes (id INTEGER PRIMARY KEY AUTOINCREMENT, barcode TEXT, gtin TEXT, name TEXT, scanned_at TEXT)');
      await db.execute('CREATE INDEX idx_barcode ON codes(barcode)');
    }, onOpen: (db) async {
      // V61: ilaç listesi tablosu (eski kurulumlarda da açılışta oluşturulur)
      await db.execute(
          'CREATE TABLE IF NOT EXISTS ilaclar (gtin TEXT PRIMARY KEY, ad TEXT, atc TEXT, etken TEXT, rt TEXT, durum TEXT)');
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
        'name': IlacListesi.bul(gtin)?.ad ?? defaultName,
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

  // V61: sunucu PIN'i (sunucuda PIN açıksa)
  String get pin => prefs.getString('server_pin') ?? '';
  Future<void> setPin(String v) async {
    gSunucuPin = v;
    await prefs.setString('server_pin', v);
  }
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
      BarcodeScanner(formats: [BarcodeFormat.dataMatrix, BarcodeFormat.qrCode]);

  bool _isProcessing = false;
  DateTime _lastProcessTime = DateTime.now();
  int _processCounter = 0;

  Set<String> scannedCodes = {};
  Set<String> scannedGtins = {};
  Map<String, DateTime> scannedTimestamps = {};

  String _lastScannedCode = "";
  DateTime _lastScanSuccess = DateTime(2000);
  // V60.3: ANLIK modda her kodun en son kadrajda görüldüğü an
  final Map<String, DateTime> _anlikSonGorulme = {};
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

  // V61
  final AudioPlayer _okPlayer = AudioPlayer();
  final AudioPlayer _warnPlayer = AudioPlayer();
  bool _bilgiModu = false;
  bool _bilgiAcik = false;
  bool _kameraAciliyor = false;
  bool _sunucuKontrolYapildi = false;
  String _lastRozet = "";
  Color _lastRozetRenk = Colors.blueGrey;

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
    _okPlayer.dispose();
    _warnPlayer.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) async {
    // V61: kamera önce ekrandan ayrılır, sonra kapatılır (kapanmış kamerayla çizim hatası olmaz)
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      final c = _controller;
      if (c == null) return;
      _controller = null;
      if (mounted) setState(() {});
      try {
        if (c.value.isStreamingImages) await c.stopImageStream();
      } catch (_) {}
      try {
        await c.dispose();
      } catch (_) {}
    } else if (state == AppLifecycleState.resumed) {
      if (_controller == null) await _initializeCamera();
    }
  }

  Future<void> _initEverything() async {
    final prefs = await SharedPreferences.getInstance();
    settings = AppSettings(prefs);
    gSunucuPin = settings!.pin;
    await IlacListesi.yukle();
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
          .get(sunucuUri(serverIp, '/ping'))
          .timeout(const Duration(seconds: 2));
      if (response.statusCode == 401) {
        // V61: sunucuda PIN açık, telefondaki PIN yanlış/eksik
        setState(() {
          isConnected = false;
          statusText = "PIN HATALI";
          statusColor = Colors.red;
        });
        return;
      }
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
          if (!_sunucuKontrolYapildi) {
            _sunucuKontrolYapildi = true;
            _sunucuSonrasiKontroller(serverIp);
          }
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
    final c = _controller;
    _controller = null;
    if (mounted) setState(() {});
    try {
      if (c != null) {
        if (c.value.isStreamingImages) await c.stopImageStream();
        await c.dispose();
      }
    } catch (_) {}
    await _initializeCamera();
  }

  // PERFORMANS AYARI + ÇÖZÜNÜRLÜK SEÇİMİ
  Future<void> _initializeCamera() async {
    if (_kameraAciliyor) return; // V61: aynı anda iki kez açılmaz
    _kameraAciliyor = true;
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
    } finally {
      _kameraAciliyor = false;
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
    // V60.2: Sunucu IP karekodu normalizeCode'dan ÖNCE ham metinden kontrol edilir
    // (normalizeCode nokta ve iki noktayı sildiği için IP hiç tanınmıyordu)
    final String rawTrim = rawCode.trim();
    final ipEs = RegExp(r'^(\d{1,3}(?:\.\d{1,3}){3}:\d+)(?:#(\d{4}))?$')
        .firstMatch(rawTrim);
    if (ipEs != null) {
      final ip = ipEs.group(1)!;
      final pin = ipEs.group(2) ?? '';
      if (settings?.serverIp != ip || settings?.pin != pin) {
        settings?.setServerIp(ip);
        settings?.setPin(pin);
        _sunucuKontrolYapildi = false;
        isConnected = false;
        _showTemporaryMessage(
            'IP: $ip${pin.isNotEmpty ? " (PIN)" : ""}', const Duration(seconds: 3),
            color: Colors.cyanAccent);
        _testServerConnection(ip);
      }
      return false;
    }

    String code = normalizeCode(rawCode);
    if (code.isEmpty) return false;

    // V61: BİLGİ modu – hiçbir şey kaydedilmez/gönderilmez, sadece ilaç kartı açılır
    if (_bilgiModu) {
      if (code.startsWith("01") && code.length >= 16) _bilgiGoster(code);
      return false;
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
      // V60.3: kutu kadrajda durdukça tekrar gönderilmez (eskiden her 1 sn'de
      // yeniden yapıştırılıyordu); kadrajdan çıkıp 4 sn geçince yeniden okunabilir
      final DateTime simdi = DateTime.now();
      final DateTime? sonGorulme = _anlikSonGorulme[code];
      _anlikSonGorulme[code] = simdi;
      if (_anlikSonGorulme.length > 500) {
        _anlikSonGorulme.removeWhere(
            (k, v) => simdi.difference(v).inSeconds > 60);
      }
      if (sonGorulme != null &&
          simdi.difference(sonGorulme).inMilliseconds < 4000) {
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
        code, gtin, IlacListesi.bul(gtin)?.ad ?? "İlaç/Ürün");
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
            sunucuUri(serverIp, '/append_pool'),
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
    if (serverIp.isEmpty) {
      _showTemporaryMessage("Önce IP Ayarla!", const Duration(seconds: 2),
          color: Colors.red);
      return;
    }
    setState(() => busy = true);
    int adet = 0;
    bool basarili = false;
    try {
      // V61: telefonun tam listesi gönderilir (PC yeniden başlamış olsa bile eksik yapıştırılmaz)
      final res = await http
          .post(sunucuUri(serverIp, '/paste_pool'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'codes': scannedCodes.toList()}))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode == 200) {
        final d = jsonDecode(utf8.decode(res.bodyBytes));
        adet = (d['count'] ?? 0) as int;
        basarili = adet > 0;
        _networkBuffer.clear();
        _playBeep(warning: false);
        _showTemporaryMessage(
            "PC'YE AKTARILDI ($adet)", const Duration(seconds: 3),
            color: Colors.green);
      } else {
        _showTemporaryMessage("PC HATASI", const Duration(seconds: 2),
            color: Colors.red);
      }
    } catch (e) {
      _showTemporaryMessage(
          "PC'YE ULAŞILAMADI", const Duration(seconds: 2),
          color: Colors.red);
    } finally {
      if (mounted) setState(() => busy = false);
    }
    if (basarili && mounted) {
      final temizle = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text("PC'ye aktarıldı"),
          content: Text("$adet kutu Medula/PC'ye yapıştırıldı.\nListe temizlensin mi?"),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text("SAKLA")),
            ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(c, true),
                child: const Text("TEMİZLE")),
          ],
        ),
      );
      if (temizle == true) await _clearPool();
    }
  }

  Future<void> _clearPool() async {
    // V61: telefon listesi + veritabanı her durumda temizlenir; PC havuzu ulaşılabilirse temizlenir
    final serverIp = settings?.serverIp ?? '';
    bool pcTamam = serverIp.isEmpty;
    if (serverIp.isNotEmpty) {
      try {
        final r = await http
            .post(sunucuUri(serverIp, '/clear_pool'))
            .timeout(const Duration(seconds: 4));
        pcTamam = r.statusCode == 200;
      } catch (_) {}
    }
    await DatabaseHelper.clearCodes();
    _networkBuffer.clear();
    if (!mounted) return;
    setState(() {
      scannedCodes.clear();
      scannedGtins.clear();
      scannedTimestamps.clear();
      _serverCount = 0;
      _gtinCounts.clear();
      _updateStatusText();
    });
    _showTemporaryMessage(
        pcTamam ? "LİSTE TEMİZLENDİ" : "TELEFON TEMİZLENDİ (PC'ye ulaşılamadı)",
        const Duration(seconds: 3),
        color: Colors.orange);
  }

  // V61: listeden tek kayıt silinince ana ekran sayaçları ve PC havuzu da güncellenir
  Future<void> _kayitSilindi(String barcode) async {
    final code = normalizeCode(barcode);
    final kalan = await DatabaseHelper.loadAllCodes();
    final halaVar = kalan.any((r) => normalizeCode(r['barcode']) == code);
    if (!halaVar) {
      _networkBuffer.remove(code);
      final serverIp = settings?.serverIp ?? '';
      if (serverIp.isNotEmpty) {
        try {
          await http
              .post(sunucuUri(serverIp, '/remove_pool'),
                  headers: {'Content-Type': 'application/json'},
                  body: jsonEncode({'codes': [code]}))
              .timeout(const Duration(seconds: 4));
        } catch (_) {}
      }
    }
    await _reloadListFromDb();
    _updateStatusText();
  }

  Future<void> _tryImportPackageFromServer(String pkgName) async {
    final serverIp = settings?.serverIp ?? '';
    if (serverIp.isEmpty) return;
    try {
      final response = await http
          .get(sunucuUri(serverIp,
              '/get_package?name=${Uri.encodeQueryComponent(pkgName)}'))
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
        final ilac = IlacListesi.bul(parseGS1ForLabel(code)['GTIN'] ?? '');
        _lastItemName = ilac?.ad ??
            "...${code.substring(code.length > 10 ? code.length - 10 : 0)}";
        _lastRozet = ilac?.rozet ?? "";
        _lastRozetRenk = ilac?.rozetRengi ?? Colors.blueGrey;
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
      sunucuUri(serverIp, '/send'),
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
        String mode = _bilgiModu ? "BİLGİ" : (_isSingleMode ? "ANLIK" : "LİSTE");
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
      // V61: iki kalıcı oynatıcı (eskiden her bipte yeni oynatıcı açılıp kapatılmıyordu)
      final player = warning ? _warnPlayer : _okPlayer;
      await player.stop();
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
              sunucuUri(serverIp, '/upload'));
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
              sunucuUri(serverIp, '/upload'));
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
          sunucuUri(serverIp, '/upload_general'),
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
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    if (_lastRozet.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(top: 4),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                            color: _lastRozetRenk,
                            borderRadius: BorderRadius.circular(6)),
                        child: Text(_lastRozet,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.bold)),
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
              if (!_isSingleMode && !_bilgiModu)
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
                    _modDugmesi("ANLIK (Gönder)", Colors.blueAccent,
                        _isSingleMode && !_bilgiModu, () {
                      _isSingleMode = true;
                      _bilgiModu = false;
                    }),
                    const SizedBox(width: 6),
                    _modDugmesi("LİSTE (Biriktir)", Colors.orange,
                        !_isSingleMode && !_bilgiModu, () {
                      _isSingleMode = false;
                      _bilgiModu = false;
                    }),
                    const SizedBox(width: 6),
                    _modDugmesi("BİLGİ", Colors.teal, _bilgiModu, () {
                      _bilgiModu = true;
                    }),
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

  // V61: mod düğmesi
  Widget _modDugmesi(String yazi, Color renk, bool secili, VoidCallback sec) {
    return Expanded(
      child: InkWell(
        onTap: () => setState(() {
          sec();
          _updateStatusText();
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: secili ? renk : Colors.black54,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Text(
              yazi,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ),
    );
  }

  // V61: BİLGİ modunda okunan kutunun kartı
  void _bilgiGoster(String code) {
    final simdi = DateTime.now();
    final son = _anlikSonGorulme[code];
    _anlikSonGorulme[code] = simdi;
    if (_bilgiAcik) return;
    if (son != null && simdi.difference(son).inMilliseconds < 3000) return;
    _bilgiAcik = true;
    _playBeep(warning: false);
    final gtin = parseGS1ForLabel(code)['GTIN'] ?? '';
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      builder: (c) => ilacKarti(code, _gtinCounts[gtin] ?? 0),
    ).whenComplete(() {
      _bilgiAcik = false;
      _anlikSonGorulme[code] = DateTime.now();
    });
  }

  // V61: sunucuya ilk bağlanınca ilaç listesi ve uygulama güncellemesi kontrol edilir
  Future<void> _sunucuSonrasiKontroller(String ip) async {
    await _ilacListesiGuncelle(ip, sessiz: true);
    await _guncellemeKontrol(ip, sessiz: true);
  }

  Future<void> _ilacListesiGuncelle(String ip,
      {bool sessiz = false, bool zorla = false}) async {
    try {
      final r = await http
          .get(sunucuUri(ip, '/ilac_listesi_surum'))
          .timeout(const Duration(seconds: 5));
      if (r.statusCode != 200) return;
      final d = jsonDecode(utf8.decode(r.bodyBytes));
      final surum = (d['surum'] ?? '').toString();
      final adet = (d['adet'] ?? 0) as num;
      if (surum.isEmpty || adet == 0) {
        if (!sessiz) {
          _showTemporaryMessage("PC'de ilaç listesi yok",
              const Duration(seconds: 3),
              color: Colors.orange);
        }
        return;
      }
      if (!zorla && surum == IlacListesi.surum && IlacListesi.adet > 0) {
        if (!sessiz) {
          _showTemporaryMessage("İlaç listesi güncel (${IlacListesi.adet})",
              const Duration(seconds: 2),
              color: Colors.green);
        }
        return;
      }
      _showTemporaryMessage("İLAÇ LİSTESİ İNDİRİLİYOR...",
          const Duration(seconds: 4),
          color: Colors.yellow);
      final r2 = await http
          .get(sunucuUri(ip, '/ilac_listesi'))
          .timeout(const Duration(seconds: 90));
      if (r2.statusCode != 200) return;
      final veri = await compute(jsonCozIsolate, utf8.decode(r2.bodyBytes));
      final n = await IlacListesi.kaydet(veri);
      _showTemporaryMessage("İLAÇ LİSTESİ: $n ürün",
          const Duration(seconds: 3),
          color: Colors.green);
    } catch (_) {
      if (!sessiz) {
        _showTemporaryMessage("İlaç listesi alınamadı",
            const Duration(seconds: 3),
            color: Colors.red);
      }
    }
  }

  Future<void> _guncellemeKontrol(String ip, {bool sessiz = false}) async {
    try {
      final r = await http
          .get(sunucuUri(ip, '/surum'))
          .timeout(const Duration(seconds: 5));
      if (r.statusCode != 200) return;
      final d = jsonDecode(utf8.decode(r.bodyBytes));
      final apk = d['apk'];
      final int build = (d['build'] ?? 0) as int;
      if (apk == null || build <= kDerlemeNo) {
        if (!sessiz) {
          _showTemporaryMessage("Uygulama güncel", const Duration(seconds: 2),
              color: Colors.green);
        }
        return;
      }
      if (!mounted) return;
      final indir = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text("Yeni sürüm hazır"),
          content: Text(
              "Sürüm ${d['version']} (derleme $build) PC'de hazır.\n\nİndirdikten sonra dosyayı açıp GÜNCELLE deyin. Listeniz ve ayarlarınız korunur."),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text("SONRA")),
            ElevatedButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text("İNDİR")),
          ],
        ),
      );
      if (indir == true) {
        await launchUrl(sunucuUri(ip, '/guncelleme/$apk'),
            mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      if (!sessiz) {
        _showTemporaryMessage("PC'ye ulaşılamadı", const Duration(seconds: 2),
            color: Colors.red);
      }
    }
  }

  void _showMenu(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.grey[900],
      builder: (c) => SafeArea(
          child: SingleChildScrollView(
              child: Column(
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
          ListTile(
            leading: const Icon(Icons.summarize, color: Colors.tealAccent),
            title: const Text(
              "Sayım Özeti / Miad Raporu",
              style: TextStyle(color: Colors.white),
            ),
            onTap: () {
              Navigator.pop(c);
              _sayimOzetiAc();
            },
          ),
          ListTile(
            leading: const Icon(Icons.medication, color: Colors.purpleAccent),
            title: Text(
              "İlaç Listesini Güncelle (${IlacListesi.adet})",
              style: const TextStyle(color: Colors.white),
            ),
            onTap: () {
              Navigator.pop(c);
              final ip = settings?.serverIp ?? '';
              if (ip.isNotEmpty) _ilacListesiGuncelle(ip, zorla: true);
            },
          ),
          ListTile(
            leading: const Icon(Icons.system_update, color: Colors.lightBlueAccent),
            title: Text(
              "Uygulama Güncellemesi (derleme $kDerlemeNo)",
              style: const TextStyle(color: Colors.white),
            ),
            onTap: () {
              Navigator.pop(c);
              final ip = settings?.serverIp ?? '';
              if (ip.isNotEmpty) _guncellemeKontrol(ip);
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
      ))),
    );
  }

  void _openDetailListScreen() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) => DetailListScreen(
          settings: settings!,
          onClear: _clearPool,
          onDelete: _kayitSilindi,
        ),
      ),
    ).then((_) => _reloadListFromDb());
  }

  void _sayimOzetiAc() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) => SayimOzetiScreen(settings: settings!),
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
              _showPackageQrDialog(
                  context, paketAdiDuzelt(controller.text));
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
                pkgName,
                style: const TextStyle(color: Colors.black),
              ),
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
            sunucuUri(settings!.serverIp, '/package'),
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
  final Future<void> Function() onClear;
  final Future<void> Function(String barcode) onDelete;
  const DetailListScreen(
      {super.key,
      required this.settings,
      required this.onClear,
      required this.onDelete});

  @override
  State<DetailListScreen> createState() => _DetailListScreenState();
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
    if (!mounted) return;
    setState(() {
      items = List.from(rows.reversed);
      loading = false;
    });
  }

  // V61: silinen kayıt ana ekran sayacından ve PC havuzundan da düşer
  Future<void> _deleteItem(Map<String, dynamic> item) async {
    await DatabaseHelper.db
        .delete('codes', where: 'id = ?', whereArgs: [item['id']]);
    await widget.onDelete((item['barcode'] ?? '').toString());
    _loadItems();
  }

  // V61: tümünü sil onay ister; telefon, veritabanı ve PC havuzu birlikte temizlenir
  Future<void> _tumunuSil() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text("Tüm liste silinsin mi?"),
        content: Text(
            "Telefondaki ${items.length} kayıt ve PC havuzu temizlenecek."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text("VAZGEÇ")),
          ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(c, true),
              child: const Text("SİL")),
        ],
      ),
    );
    if (ok != true) return;
    await widget.onClear();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _updateName(int id, String currentName) async {
    TextEditingController tc = TextEditingController(text: currentName);
    showDialog(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text("İsim Ver"),
        content: TextField(controller: tc),
        actions: [
          ElevatedButton(
            onPressed: () async {
              await DatabaseHelper.db.update(
                'codes',
                {'name': tc.text},
                where: 'id = ?',
                whereArgs: [id],
              );
              if (c.mounted) Navigator.pop(c);
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
    await Future.delayed(const Duration(milliseconds: 100));
    try {
      await etiketYazdir(items.reversed.toList());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Etiket hatası: $e')));
      }
    } finally {
      if (mounted) setState(() => creatingPdf = false);
    }
  }

  String _ad(Map<String, dynamic> item) {
    final n = (item['name'] ?? '').toString();
    if (n.isNotEmpty && n != 'İlaç/Ürün') return n;
    return IlacListesi.bul((item['gtin'] ?? '').toString())?.ad ?? 'İlaç/Ürün';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Liste (${items.length})"),
        actions: [
          IconButton(
            icon: const Icon(Icons.print),
            onPressed: (items.isEmpty || creatingPdf) ? null : _printLabels,
          ),
          IconButton(
            icon: const Icon(Icons.delete_forever, color: Colors.red),
            onPressed: items.isEmpty ? null : _tumunuSil,
          ),
        ],
      ),
      body: Stack(
        children: [
          loading
              ? const Center(child: CircularProgressIndicator())
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (c, i) {
                    final item = items[i];
                    final code = (item['barcode'] ?? '').toString();
                    final info = parseGS1ForLabel(code);
                    final st = analyzeStatus(info['RAW_SKT'] ?? '');
                    final ilac =
                        IlacListesi.bul((item['gtin'] ?? '').toString());
                    final gtin = (item['gtin'] ?? '').toString();
                    return Card(
                      margin: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 2),
                      child: ListTile(
                        dense: true,
                        onTap: () => showModalBottomSheet(
                          context: context,
                          backgroundColor: Colors.grey[900],
                          builder: (_) => ilacKarti(
                              code,
                              items
                                  .where((e) => (e['gtin'] ?? '') == gtin)
                                  .length),
                        ),
                        title: Text(
                          _ad(item),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              code,
                              style: const TextStyle(
                                  fontSize: 10, fontFamily: "monospace"),
                            ),
                            Row(
                              children: [
                                Text(
                                  "SKT: ${st.date.isEmpty ? '-' : st.date}  ${st.text}",
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: st.color),
                                ),
                                if (ilac != null && ilac.rozet.isNotEmpty)
                                  Container(
                                    margin: const EdgeInsets.only(left: 6),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 5, vertical: 1),
                                    decoration: BoxDecoration(
                                        color: ilac.rozetRengi,
                                        borderRadius:
                                            BorderRadius.circular(4)),
                                    child: Text(ilac.rozet,
                                        style: const TextStyle(
                                            fontSize: 9,
                                            color: Colors.white)),
                                  ),
                              ],
                            ),
                          ],
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit, color: Colors.blue),
                              onPressed: () =>
                                  _updateName(item['id'], _ad(item)),
                            ),
                            IconButton(
                              icon:
                                  const Icon(Icons.delete, color: Colors.red),
                              onPressed: () => _deleteItem(item),
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
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 20),
                    Text(
                      "PDF Hazırlanıyor...",
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold),
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
  late TextEditingController pinCtrl;
  late bool invertMode;
  late String resolution;

  @override
  void initState() {
    super.initState();
    serverCtrl =
        TextEditingController(text: widget.settings.serverIp);
    pinCtrl = TextEditingController(text: widget.settings.pin);
    invertMode = widget.settings.invertMode;
    resolution = widget.settings.resolution;
  }

  void _save() async {
    // V60.2: "http://" yazılırsa temizlenir, port yazılmazsa :5000 eklenir
    String ip = serverCtrl.text.trim()
        .replaceAll(RegExp(r'^https?://'), '')
        .replaceAll(RegExp(r'/+$'), '');
    if (ip.isNotEmpty && !ip.contains(':')) ip = '$ip:5000';
    await widget.settings.setServerIp(ip);
    await widget.settings.setPin(pinCtrl.text.trim());
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
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: TextField(
                controller: pinCtrl,
                keyboardType: TextInputType.number,
                maxLength: 4,
                decoration: const InputDecoration(
                  labelText: 'PIN (sunucuda PIN açıksa; yoksa boş bırakın)',
                  prefixIcon: Icon(Icons.lock),
                  border: InputBorder.none,
                  counterText: '',
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
      final res = await http
          .get(sunucuUri(widget.serverIp, '/files'))
          .timeout(const Duration(seconds: 5));
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
          sunucuUri(widget.serverIp, '/upload_general'),
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
                        sunucuUri(widget.serverIp, '/files/${Uri.encodeComponent(files[i])}'),
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

// ---------------------------------------------------------------------------
// V61: İlaç kartı (BİLGİ modu ve liste satırına dokununca)
// ---------------------------------------------------------------------------
Widget ilacKarti(String code, int sayimAdet) {
  final info = parseGS1ForLabel(code);
  final st = analyzeStatus(info['RAW_SKT'] ?? '');
  final ilac = IlacListesi.bul(info['GTIN'] ?? '');

  Widget satir(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 95,
                child: Text(k,
                    style: const TextStyle(color: Colors.grey, fontSize: 13))),
            Expanded(
                child: Text(v.isEmpty ? '-' : v,
                    style:
                        const TextStyle(color: Colors.white, fontSize: 14))),
          ],
        ),
      );

  return SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ilac?.ad ??
                (IlacListesi.adet == 0
                    ? 'İlaç listesi henüz yüklenmedi'
                    : 'İlaç listesinde bulunamadı'),
            style: const TextStyle(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
          ),
          if (ilac != null && ilac.rozet.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                  color: ilac.rozetRengi,
                  borderRadius: BorderRadius.circular(6)),
              child: Text(ilac.rozet,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: st.color.withOpacity(0.25),
              border: Border.all(color: st.color, width: 2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              st.date.isEmpty
                  ? st.text
                  : "${st.text}   •   SKT ${st.date}   •   ${st.days} gün",
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 15),
            ),
          ),
          const SizedBox(height: 10),
          satir('Etkin madde', ilac?.etken ?? ''),
          satir('ATC', ilac?.atc ?? ''),
          satir('Reçete türü', ilac?.receteTuru ?? ''),
          satir('Durum', ilac == null ? '' : (ilac.pasif ? 'PASİF' : 'Aktif')),
          const Divider(color: Colors.white24),
          satir('GTIN', info['GTIN'] ?? ''),
          satir('Seri No', info['SN'] ?? ''),
          satir('LOT', info['LOT'] ?? ''),
          satir('Sayımda', '$sayimAdet kutu'),
          if (IlacListesi.surum.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text("TİTCK listesi: ${IlacListesi.surum}",
                  style: const TextStyle(color: Colors.grey, fontSize: 11)),
            ),
        ],
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// V61: Etiket (karekod üstte, bilgiler altında, Türkçe font)
// ---------------------------------------------------------------------------
Future<void> etiketYazdir(List<Map<String, dynamic>> items,
    {String ad = 'Etiketler'}) async {
  if (items.isEmpty) return;
  final font = pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans.ttf'));
  final fontB =
      pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans-Bold.ttf'));
  await Printing.layoutPdf(
    name: ad,
    onLayout: (PdfPageFormat format) async {
      final doc =
          pw.Document(theme: pw.ThemeData.withFont(base: font, bold: fontB));
      const double w = 108, h = 140;
      doc.addPage(
        pw.MultiPage(
          pageFormat: format,
          margin: const pw.EdgeInsets.all(10),
          build: (pw.Context context) => [
            pw.Wrap(
              spacing: 4,
              runSpacing: 4,
              children: items.map((item) {
                final code = (item['barcode'] ?? '').toString();
                final info = parseGS1ForLabel(code);
                final gtin = (info['GTIN'] ?? '').isNotEmpty
                    ? info['GTIN']!
                    : (item['gtin'] ?? '').toString();
                final ilac = IlacListesi.bul(gtin);
                final kayitAdi = (item['name'] ?? '').toString();
                final ad = ilac?.ad ??
                    (kayitAdi.isNotEmpty ? kayitAdi : 'İlaç/Ürün');
                return pw.Container(
                  width: w,
                  height: h,
                  padding: const pw.EdgeInsets.all(4),
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(color: PdfColors.black, width: 0.5),
                  ),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.center,
                    children: [
                      pw.BarcodeWidget(
                        data: code,
                        barcode: pw.Barcode.dataMatrix(),
                        width: 62,
                        height: 62,
                        drawText: false,
                      ),
                      pw.SizedBox(height: 3),
                      pw.Text(ad,
                          maxLines: 2,
                          textAlign: pw.TextAlign.center,
                          style: pw.TextStyle(
                              fontSize: 6.5, fontWeight: pw.FontWeight.bold)),
                      pw.SizedBox(height: 2),
                      pw.Text('GTIN $gtin',
                          style: const pw.TextStyle(fontSize: 5.5)),
                      pw.Text('SN ${info['SN'] ?? ''}',
                          maxLines: 1, style: const pw.TextStyle(fontSize: 5.5)),
                      pw.Text(
                          'LOT ${info['LOT'] ?? ''}   SKT ${info['SKT'] ?? ''}',
                          maxLines: 1,
                          style: pw.TextStyle(
                              fontSize: 6, fontWeight: pw.FontWeight.bold)),
                    ],
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      );
      return doc.save();
    },
  );
}

// ---------------------------------------------------------------------------
// V61: Sayım Özeti / Miad Raporu (ilaç bazında) + CSV'yi PC'ye gönder
// ---------------------------------------------------------------------------
class _OzetSatir {
  final String gtin;
  String ad = '';
  IlacBilgi? ilac;
  int adet = 0;
  Gs1Status? durum;
  final List<Map<String, dynamic>> kayitlar = [];
  _OzetSatir(this.gtin);
}

class SayimOzetiScreen extends StatefulWidget {
  final AppSettings settings;
  const SayimOzetiScreen({super.key, required this.settings});

  @override
  State<SayimOzetiScreen> createState() => _SayimOzetiScreenState();
}

class _SayimOzetiScreenState extends State<SayimOzetiScreen> {
  List<_OzetSatir> satirlar = [];
  bool loading = true;
  bool gonderiliyor = false;
  String filtre = 'tumu';

  @override
  void initState() {
    super.initState();
    _yukle();
  }

  Future<void> _yukle() async {
    final rows = await DatabaseHelper.loadAllCodes();
    final m = <String, _OzetSatir>{};
    for (final r in rows) {
      final code = normalizeCode(r['barcode']);
      final info = parseGS1ForLabel(code);
      final g = (info['GTIN'] ?? '').isNotEmpty
          ? info['GTIN']!
          : (r['gtin'] ?? '').toString();
      final s = m.putIfAbsent(g, () => _OzetSatir(g));
      s.adet++;
      s.kayitlar.add(Map<String, dynamic>.from(r));
      final st = analyzeStatus(info['RAW_SKT'] ?? '');
      if (st.date.isNotEmpty && (s.durum == null || st.days < s.durum!.days)) {
        s.durum = st;
      }
    }
    for (final s in m.values) {
      s.ilac = IlacListesi.bul(s.gtin);
      final kayitAdi = (s.kayitlar.first['name'] ?? '').toString();
      s.ad = s.ilac?.ad ??
          (kayitAdi.isNotEmpty && kayitAdi != 'İlaç/Ürün' ? kayitAdi : s.gtin);
    }
    final l = m.values.toList()..sort((a, b) => a.ad.compareTo(b.ad));
    if (!mounted) return;
    setState(() {
      satirlar = l;
      loading = false;
    });
  }

  List<_OzetSatir> get _gorunen {
    switch (filtre) {
      case 'miad3':
        return satirlar
            .where((s) => s.durum != null && s.durum!.days <= 90)
            .toList();
      case 'gecmis':
        return satirlar
            .where((s) => s.durum != null && s.durum!.days < 0)
            .toList();
      case 'kontrollu':
        return satirlar
            .where((s) =>
                s.ilac != null &&
                s.ilac!.receteTuru.isNotEmpty &&
                s.ilac!.receteTuru != 'Normal')
            .toList();
      case 'pasif':
        return satirlar.where((s) => s.ilac?.pasif == true).toList();
    }
    return satirlar;
  }

  String _csvAlan(String v) => '"${v.replaceAll('"', '""')}"';

  Future<void> _pcyeGonder() async {
    final ip = widget.settings.serverIp;
    if (ip.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Önce PC IP ayarlayın')));
      return;
    }
    setState(() => gonderiliyor = true);
    try {
      final ozet = StringBuffer(
          'GTIN;İlaç Adı;Etkin Madde;ATC;Reçete Türü;Durum;Adet;En Yakın SKT;Kalan Gün\n');
      final detay = StringBuffer(
          'GTIN;İlaç Adı;Etkin Madde;Reçete Türü;Seri No;LOT;SKT;Kalan Gün;Karekod;Okunma\n');
      for (final s in satirlar) {
        final i = s.ilac;
        ozet.writeln([
          s.gtin,
          s.ad,
          i?.etken ?? '',
          i?.atc ?? '',
          i?.receteTuru ?? '',
          i == null ? '' : (i.pasif ? 'Pasif' : 'Aktif'),
          '${s.adet}',
          s.durum?.date ?? '',
          s.durum == null ? '' : '${s.durum!.days}'
        ].map(_csvAlan).join(';'));
        for (final k in s.kayitlar) {
          final code = (k['barcode'] ?? '').toString();
          final info = parseGS1ForLabel(code);
          final st = analyzeStatus(info['RAW_SKT'] ?? '');
          detay.writeln([
            s.gtin,
            s.ad,
            i?.etken ?? '',
            i?.receteTuru ?? '',
            info['SN'] ?? '',
            info['LOT'] ?? '',
            st.date,
            st.date.isEmpty ? '' : '${st.days}',
            code,
            (k['scanned_at'] ?? '').toString()
          ].map(_csvAlan).join(';'));
        }
      }
      final t = DateTime.now();
      final ek =
          '${t.year}${t.month.toString().padLeft(2, '0')}${t.day.toString().padLeft(2, '0')}_${t.hour.toString().padLeft(2, '0')}${t.minute.toString().padLeft(2, '0')}';
      final req =
          http.MultipartRequest('POST', sunucuUri(ip, '/upload_general'));
      req.files.add(http.MultipartFile.fromBytes(
          'file', utf8.encode('﻿$ozet'),
          filename: 'sayim_ozet_$ek.csv'));
      req.files.add(http.MultipartFile.fromBytes(
          'file', utf8.encode('﻿$detay'),
          filename: 'sayim_detay_$ek.csv'));
      final res = await req.send().timeout(const Duration(seconds: 60));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(res.statusCode == 200
              ? "Sayım PC'ye gönderildi (M_ONUR_PAYLASIM klasörü)"
              : 'PC hatası')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("PC'ye ulaşılamadı")));
      }
    } finally {
      if (mounted) setState(() => gonderiliyor = false);
    }
  }

  Widget _cip(String id, String yazi) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ChoiceChip(
          label: Text(yazi),
          selected: filtre == id,
          onSelected: (_) => setState(() => filtre = id),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final kutu = satirlar.fold<int>(0, (a, s) => a + s.adet);
    final miad3 = satirlar
        .where((s) => s.durum != null && s.durum!.days <= 90 && s.durum!.days >= 0)
        .length;
    final gecmis =
        satirlar.where((s) => s.durum != null && s.durum!.days < 0).length;
    final liste = _gorunen;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sayım Özeti'),
        actions: [
          IconButton(
            tooltip: "CSV olarak PC'ye gönder",
            icon: gonderiliyor
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.upload_file),
            onPressed: (gonderiliyor || satirlar.isEmpty) ? null : _pcyeGonder,
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Container(
                  margin: const EdgeInsets.all(8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                      color: Colors.indigo.shade900,
                      borderRadius: BorderRadius.circular(8)),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      Text("ÇEŞİT: ${satirlar.length}",
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text("KUTU: $kutu",
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      Text("≤3 AY: $miad3",
                          style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.orangeAccent)),
                      Text("GEÇMİŞ: $gecmis",
                          style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.redAccent)),
                    ],
                  ),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(children: [
                    _cip('tumu', 'Tümü'),
                    _cip('miad3', 'Miadı ≤3 ay'),
                    _cip('gecmis', 'Miadı geçmiş'),
                    _cip('kontrollu', 'Kırmızı/Yeşil/Mor/Turuncu'),
                    _cip('pasif', 'Pasif'),
                  ]),
                ),
                if (IlacListesi.adet == 0)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text(
                        "İlaç listesi yüklü değil: menü → İlaç Listesini Güncelle",
                        style: TextStyle(color: Colors.orangeAccent)),
                  ),
                Expanded(
                  child: ListView.builder(
                    itemCount: liste.length,
                    itemBuilder: (c, i) {
                      final s = liste[i];
                      final d = s.durum;
                      return Card(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        child: ListTile(
                          dense: true,
                          leading: CircleAvatar(
                            backgroundColor: d?.color ?? Colors.grey,
                            child: Text('${s.adet}',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold)),
                          ),
                          title: Text(s.ad,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Text(
                              "${s.ilac?.etken ?? ''}${(s.ilac?.etken ?? '').isEmpty ? '' : '  •  '}En yakın SKT: ${d?.date ?? '-'}${d == null ? '' : ' (${d.days} gün)'}"),
                          trailing: (s.ilac != null && s.ilac!.rozet.isNotEmpty)
                              ? Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 5, vertical: 2),
                                  decoration: BoxDecoration(
                                      color: s.ilac!.rozetRengi,
                                      borderRadius: BorderRadius.circular(4)),
                                  child: Text(s.ilac!.rozet,
                                      style: const TextStyle(
                                          fontSize: 9, color: Colors.white)),
                                )
                              : null,
                          onTap: () => showModalBottomSheet(
                            context: context,
                            backgroundColor: Colors.grey[900],
                            builder: (bc) => SafeArea(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ListTile(
                                    title: Text(s.ad,
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold)),
                                    subtitle: Text("${s.adet} kutu",
                                        style: const TextStyle(
                                            color: Colors.grey)),
                                  ),
                                  ListTile(
                                    leading: const Icon(Icons.print,
                                        color: Colors.white),
                                    title: Text(
                                        "Bu ilacın etiketlerini bas (${s.adet})",
                                        style: const TextStyle(
                                            color: Colors.white)),
                                    onTap: () {
                                      Navigator.pop(bc);
                                      etiketYazdir(s.kayitlar, ad: s.ad);
                                    },
                                  ),
                                  ListTile(
                                    leading: const Icon(Icons.info_outline,
                                        color: Colors.white),
                                    title: const Text("İlaç kartı",
                                        style: TextStyle(color: Colors.white)),
                                    onTap: () {
                                      Navigator.pop(bc);
                                      showModalBottomSheet(
                                        context: context,
                                        backgroundColor: Colors.grey[900],
                                        builder: (_) => ilacKarti(
                                            normalizeCode(
                                                s.kayitlar.first['barcode']),
                                            s.adet),
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}
