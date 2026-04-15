// TFM: Asistente para personas con discapacidad visual
// Fco Javier López López
// Versión PRO: Corrección híbrida (Levenshtein + Fonética + Contexto)

import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  runApp(
    MaterialApp(
      theme: ThemeData.dark(),
      debugShowCheckedModeBanner: false,
      home: CameraScreen(camera: cameras.first),
    ),
  );
}

class CameraScreen extends StatefulWidget {
  final CameraDescription camera;
  const CameraScreen({super.key, required this.camera});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  late CameraController _controller;
  late Future<void> _init;

  @override
  void initState() {
    super.initState();
    _controller = CameraController(widget.camera, ResolutionPreset.high);
    _init = _controller.initialize();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _capturar() async {
    await _init;
    final foto = await _controller.takePicture();

    final bytes = await File(foto.path).readAsBytes();
    img.Image? image = img.decodeImage(bytes);

    if (image != null) {
      img.Image cropped = img.copyCrop(
        image,
        x: 0,
        y: 0,
        width: image.width,
        height: (image.height * 2 / 3).toInt(),
      );

      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/ocr_${DateTime.now().millisecondsSinceEpoch}.png';

      File(path).writeAsBytesSync(img.encodePng(cropped));

      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => ResultScreen(imagePath: path)),
      );
    }
  }

  /*  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GestureDetector(
        onTap: _capturar,
        child: FutureBuilder(
          future: _init,
          builder: (_, snap) {
            return snap.connectionState == ConnectionState.done
                ? CameraPreview(_controller)
                : const Center(child: CircularProgressIndicator());
          },
        ),
      ),
    );
  }*/

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      body: GestureDetector(
        onTap: _capturar,
        child: Stack(
          children: [
            // Cámara
            FutureBuilder(
              future: _init,
              builder: (_, snap) {
                return snap.connectionState == ConnectionState.done
                    ? SizedBox.expand(child: CameraPreview(_controller))
                    : const Center(child: CircularProgressIndicator());
              },
            ),

            // MÁSCARA OSCURA
            ColorFiltered(
              colorFilter: const ColorFilter.mode(
                Colors.black54,
                BlendMode.srcOut,
              ),
              child: Stack(
                children: [
                  Container(
                    decoration: const BoxDecoration(
                      color: Colors.black,
                      backgroundBlendMode: BlendMode.dstOut,
                    ),
                  ),

                  // ZONA VISIBLE (OCR)
                  Align(
                    alignment: Alignment.topCenter,
                    child: Container(
                      width: size.width,
                      height: size.height * (2 / 3),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border.all(color: Colors.redAccent, width: 2),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // esto es una prueba para dos lineas de texto
            const Align(
              alignment: Alignment(0, 0.85),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    "TOCA LA PANTALLA Y CAPTURA",
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      backgroundColor: Colors.black54,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    "TFM: ASISTENTE PARA PERSONAS CON DISCAPACIDAD VISUAL",
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      backgroundColor: Colors.black54,
                      color: Colors.white70,
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
}
// ================= LINEAS DE TEXTO INFORMATIVAS =================

// ================= RESULTADO =================

class ResultScreen extends StatefulWidget {
  final String imagePath;
  const ResultScreen({super.key, required this.imagePath});

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  final FlutterTts _tts = FlutterTts();
  String _resultado = "Analizando...";

  List<String> diccionario = [];

  final Set<String> palabrasClave = {
    "arroz",
    "pollo",
    "lactosa",
    "gluten",
    "trigo",
    "leche",
    "cebada",
    "centeno",
    "huevo",
    "soja",
    "pescado",
    "marisco",
  };

  // ================= NORMALIZAR =================
  String normalizar(String t) => t
      .toLowerCase()
      .replaceAll(RegExp(r'[áàä]'), 'a')
      .replaceAll(RegExp(r'[éèë]'), 'e')
      .replaceAll(RegExp(r'[íìï]'), 'i')
      .replaceAll(RegExp(r'[óòö]'), 'o')
      .replaceAll(RegExp(r'[úùü]'), 'u');

  // ================= FONÉTICA =================
  String fonetizar(String palabra) {
    return normalizar(palabra)
        .replaceAll(RegExp(r'[bv]'), 'b')
        .replaceAll(RegExp(r'[ckq]'), 'k')
        .replaceAll('z', 's')
        .replaceAll('ll', 'y')
        .replaceAll('h', '')
        .replaceAll(RegExp(r'[^a-z]'), '');
  }

  // ================= LIMPIEZA OCR =================
  String limpiar(String p) =>
      p.toLowerCase().replaceAll(RegExp(r'[^a-záéíóúüñ]'), '');

  // ================= LEVENSHTEIN =================
  int dist(String a, String b) {
    final dp = List.generate(a.length + 1, (_) => List.filled(b.length + 1, 0));

    for (int i = 0; i <= a.length; i++) dp[i][0] = i;
    for (int j = 0; j <= b.length; j++) dp[0][j] = j;

    for (int i = 1; i <= a.length; i++) {
      for (int j = 1; j <= b.length; j++) {
        int cost = a[i - 1] == b[j - 1] ? 0 : 1;
        dp[i][j] = [
          dp[i - 1][j] + 1,
          dp[i][j - 1] + 1,
          dp[i - 1][j - 1] + cost,
        ].reduce((x, y) => x < y ? x : y);
      }
    }
    return dp[a.length][b.length];
  }

  // ================= CORRECCIÓN PRO =================
  String corregirPalabra(String palabra) {
    String limpia = limpiar(palabra);
    if (limpia.isEmpty) return palabra;

    String norm = normalizar(limpia);
    String fon = fonetizar(limpia);

    String mejor = palabra;
    int mejorScore = 999;

    List<String> candidatos = [...palabrasClave, ...diccionario];

    for (var d in candidatos) {
      String dNorm = normalizar(d);
      String dFon = fonetizar(d);

      int score = dist(norm, dNorm) + dist(fon, dFon) * 2;
      score += (palabra.length - d.length).abs();

      if (score < mejorScore && score <= 4) {
        mejorScore = score;
        mejor = d;
      }
    }

    return mejor;
  }

  String corregirTexto(String texto) =>
      texto.split(RegExp(r'\s+')).map(corregirPalabra).join(" ");

  // ================= DICCIONARIO =================
  Future<void> cargarDiccionario() async {
    final data = await rootBundle.loadString('assets/diccionario_es.json');
    diccionario = List<String>.from(jsonDecode(data));

    //print("Diccionario cargado: ${diccionario.length} palabras");
    //print("Ejemplo: ${diccionario.take(10).toList()}");
  }

  // ================= ALÉRGENOS =================
  final Map<String, List<String>> alergenos = {
    "gluten": ["trigo", "cebada", "centeno", "gluten"],
    "lácteos": ["leche", "lactosa"],
    "huevo": ["huevo"],
    "frutos secos": ["almendra", "avellana", "nuez"],
    "cacahuete": ["cacahuete", "mani"],
    "soja": ["soja"],
    "pescado": ["pescado"],
    "marisco": ["marisco"],
  };

  List<String> detectarAlergenos(String texto) {
    final t = normalizar(texto);
    List<String> res = [];

    alergenos.forEach((k, v) {
      if (v.any((p) => t.contains(p))) res.add(k);
    });

    return res;
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _tts.setLanguage("es-ES");
    await _tts.setSpeechRate(0.5);
    await cargarDiccionario();
    await _procesar();
  }

  Future<void> _procesar() async {
    final input = InputImage.fromFilePath(widget.imagePath);
    final recognizer = TextRecognizer();

    final result = await recognizer.processImage(input);
    recognizer.close();

    String texto = result.text.isEmpty ? "No hay texto" : result.text;

    texto = corregirTexto(texto); // 🔥 AQUÍ LA MAGIA

    final alerg = detectarAlergenos(texto);

    String mensaje = alerg.isNotEmpty
        ? "Atención contiene ${alerg.join(", ")}"
        : "No se detectan alérgenos";

    setState(() => _resultado = "$mensaje\n\n$texto");

    await _tts.speak(mensaje);
    await _tts.speak(
      _resultado,
    ); // Opcional: leer todo el texto detectado después del mensaje de alérgenos
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Resultado")),
      body: Column(
        children: [
          Expanded(child: Image.file(File(widget.imagePath))),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _resultado,
              style: const TextStyle(fontSize: 22),
              textAlign: TextAlign.center,
            ),
          ),
          //ElevatedButton(
          //onPressed: () => _tts.speak(_resultado),
          //child: const Text("Repetir"),
          //),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(100),
              backgroundColor: Colors.green,
            ),
            onPressed: () => _tts.speak(_resultado),
            icon: const Icon(Icons.volume_up, size: 50),
            label: const Text(
              "REPETIR LECTURA",
              style: TextStyle(fontSize: 26),
            ),
          ),
        ],
      ),
    );
  }
}
