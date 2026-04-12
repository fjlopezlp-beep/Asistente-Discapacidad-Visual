// TFM: Asistente para personas con discapacidad visual
// Fco Javier López López
// Versión: Versión Alpha - Funcionalidad de captura y previsualización

import 'dart:io';
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
  late Future<void> _initializeControllerFuture;

  @override
  void initState() {
    super.initState();
    _controller = CameraController(widget.camera, ResolutionPreset.high);
    _initializeControllerFuture = _controller.initialize();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _capturarYProcesar() async {
    try {
      SystemSound.play(SystemSoundType.click);
      HapticFeedback.heavyImpact();

      await _initializeControllerFuture;
      final XFile rawImage = await _controller.takePicture();

      final bytes = await File(rawImage.path).readAsBytes();
      img.Image? image = img.decodeImage(bytes);

      if (image != null) {
        // --- MODIFICACIÓN: RECORTE DESDE ARRIBA ---
        int cropW = image.width;
        int cropH = (image.height * (2 / 3)).toInt();
        int offsetX = 0;
        int offsetY = 0; // Cambiado de (height-cropH)/2 a 0 para empezar arriba

        img.Image cropped = img.copyCrop(
          image,
          x: offsetX,
          y: offsetY,
          width: cropW,
          height: cropH,
        );

        final dir = await getTemporaryDirectory();
        final String fileName =
            'ocr_${DateTime.now().millisecondsSinceEpoch}.png';
        final path = '${dir.path}/$fileName';

        File(path).writeAsBytesSync(img.encodePng(cropped));

        if (!mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => ResultScreen(imagePath: path),
          ),
        );
      }
    } catch (e) {
      debugPrint("Error: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      body: GestureDetector(
        onTap: _capturarYProcesar,
        child: Stack(
          children: [
            FutureBuilder<void>(
              future: _initializeControllerFuture,
              builder: (context, snapshot) {
                return snapshot.connectionState == ConnectionState.done
                    ? SizedBox.expand(child: CameraPreview(_controller))
                    : const Center(child: CircularProgressIndicator());
              },
            ),
            // --- MODIFICACIÓN: MÁSCARA ALINEADA AL TOP ---
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
                  Align(
                    alignment:
                        Alignment.topCenter, // Cambiado de center a topCenter
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
                      fontSize: 10,
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

// --- CLASE RESULTADO (Se mantiene igual que la anterior) ---
class ResultScreen extends StatefulWidget {
  final String imagePath;
  const ResultScreen({super.key, required this.imagePath});
  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  final FlutterTts _tts = FlutterTts();
  String _resultado = "Analizando...";

  // ================= NORMALIZAR TEXTO =================
  String normalizar(String texto) {
    return texto
        .toLowerCase()
        .replaceAll(RegExp(r'[áàä]'), 'a')
        .replaceAll(RegExp(r'[éèë]'), 'e')
        .replaceAll(RegExp(r'[íìï]'), 'i')
        .replaceAll(RegExp(r'[óòö]'), 'o')
        .replaceAll(RegExp(r'[úùü]'), 'u');
  }

  // ================= BASE DE ALÉRGENOS =================
  final Map<String, List<String>> alergenos = {
    "gluten": ["trigo", "cebada", "centeno", "gluten", "malta"],
    "lácteos": ["leche", "lactosa", "caseina"],
    "huevo": ["huevo", "albumina"],
    "frutos secos": ["almendra", "avellana", "nuez", "pistacho"],
    "cacahuete": ["cacahuete", "mani"],
    "soja": ["soja"],
    "pescado": ["pescado"],
    "marisco": ["marisco"],
  };

  // ================= DETECCIÓN =================
  List<String> detectarAlergenos(String texto) {
    final t = normalizar(texto);
    List<String> encontrados = [];

    alergenos.forEach((categoria, palabras) {
      for (var palabra in palabras) {
        if (t.contains(palabra)) {
          encontrados.add(categoria);
          break;
        }
      }
    });

    return encontrados;
  }

  @override
  void initState() {
    super.initState();
    _configurarYProcesar();
  }

  Future<void> _configurarYProcesar() async {
    await _tts.setLanguage("es-ES");
    await _tts.setSpeechRate(0.5);
    _procesarOCR();
  }

  Future<void> _procesarOCR() async {
    final inputImage = InputImage.fromFilePath(widget.imagePath);
    final textRecognizer = TextRecognizer();

    try {
      final recognizedText = await textRecognizer.processImage(inputImage);

      String textoDetectado = recognizedText.text.isEmpty
          ? "No se detectó texto"
          : recognizedText.text;

      // 🔥 DETECTAR ALÉRGENOS
      final listaAlergenos = detectarAlergenos(textoDetectado);

      String mensajeFinal;

      if (listaAlergenos.isNotEmpty) {
        mensajeFinal =
            "Atención. El producto contiene: ${listaAlergenos.join(", ")}";
      } else {
        mensajeFinal = "No se detectan alérgenos comunes";
      }

      if (mounted) {
        setState(() => _resultado = "$mensajeFinal\n\n$textoDetectado");

        // 🔊 SOLO LEE EL MENSAJE IMPORTANTE
        await _tts.speak(mensajeFinal);
        await _tts.speak(
          _resultado,
        ); // Opcional: leer todo el texto detectado después del mensaje de alérgenos
      }
    } finally {
      textRecognizer.close();
    }
  }

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Resultado")),
      body: Column(
        children: [
          Expanded(
            child: Image.file(
              File(widget.imagePath),
              key: ValueKey(widget.imagePath),
              fit: BoxFit.contain,
            ),
          ),
          Container(
            padding: const EdgeInsets.all(20),
            color: Colors.black87,
            width: double.infinity,
            child: Text(
              _resultado,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
          ),
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
