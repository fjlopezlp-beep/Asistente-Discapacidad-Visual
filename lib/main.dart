// TFM: Asistente para personas con discapacidad visual
// Praeco v2.3.1: ajuste fino conservador sobre v2.3
// Fco Javier López López
// Versión PRO: Corrección híbrida (Levenshtein + Fonética + Contexto)
// Fecha base: 2026-06-08
// Instrumentación de trazabilidad añadida: 2026-10-26 (sin alterar algoritmos)
// Modo aprendizaje/evaluación añadido: 2026-10-27
// Mejora de captura y lectura (v2):
//   - Cámara a máxima resolución, enfoque forzado al centro y linterna automática.
//   - Captura en ráfaga (mejor de N) puntuada con el propio OCR + diccionario.
//   - Preprocesado de la imagen (grises, contraste) con comprobación "solo si ayuda".
//   - Extracción de la zona de ingredientes a partir de los bloques de ML Kit.
//   - Normalización de caracteres OCR y distancia de edición ponderada por confusiones.
//   - Detección de los 14 alérgenos del Reglamento (UE) 1169/2011 tolerante a errores OCR.
// Esta es la version de trabajo final, con corrección avanzada y sistema de evaluación integrado.
// Se han añadido funciones para calcular CER y WER, así como para guardar los resultados de cada experimento en un CSV y JSON.
// Además, se ha implementado un filtro de idioma para mejorar la precisión del OCR en etiquetas que puedan contener texto en inglés.
// La corrección de contexto utiliza n-gramas para identificar patrones comunes en ingredientes alimentarios,
// lo que mejora significativamente la corrección de errores en el texto detectado.

import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:image/image.dart' as img;
//import 'package:path_provider/path_provider.dart';
import 'dart:math';
import 'package:permission_handler/permission_handler.dart';
//import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';

// ==========================================================
// MÉTRICAS DE RENDIMIENTO
// ==========================================================

class MetricasRendimiento {
  static int captura = 0;
  static int ocr = 0;
  static int correccion = 0;
  static int alergenos = 0;
  static int tts = 0;
  static int total = 0;
  static double puntuacionCaptura = 0; // puntuación OCR de la foto elegida
  static int disparos = 0; // fotografías de la ráfaga
  static double puntuacionOCRFinal = 0; // puntuación del OCR usado al final
  static String origenOCR = ''; // 'original' | 'preprocesada'
  static void reset() {
    captura = 0;
    ocr = 0;
    correccion = 0;
    alergenos = 0;
    tts = 0;
    total = 0;
  }
}

// ==========================================================
// PARÁMETROS DE LA MEJORA DE CAPTURA (ajustables en los experimentos)
// ==========================================================

class ConfigCaptura {
  /// Número máximo de fotografías de la ráfaga "mejor de N".
  static const int disparosMaximos = 3;

  /// Si una fotografía alcanza esta puntuación OCR se detiene la ráfaga.
  static const double puntuacionSuficiente = 0.92;

  /// Brillo medio del plano Y por debajo del cual se enciende la linterna.
  static const double brilloParaLinterna = 80.0;

  /// Espera tras fijar el punto de enfoque para que el autofoco converja.
  static const int esperaEnfoqueMs = 400;

  /// Si es true, el texto que se corrige y se lee se limita a la zona
  /// "Ingredientes: ..." cuando ML Kit la localiza. Si no la localiza se
  /// usa todo el texto. Poner a false para evaluar la etiqueta completa.
  static const bool usarZonaIngredientes = true;

  /// Si el OCR de la imagen preprocesada puntúa peor que el de la imagen
  /// sin procesar por más de este margen, se descarta el preprocesado.
  static const double margenPreprocesado = 0.05;
}

// ==========================================================
// LÉXICO COMPARTIDO (se carga una sola vez para ambas pantallas)
// ==========================================================

/// Normalización básica (minúsculas y sin tildes) usada por las funciones
/// globales. Equivale a `normalizar` de ResultScreen.
String normalizarBasico(String t) => t
    .toLowerCase()
    .replaceAll(RegExp(r'[áàäâã]'), 'a')
    .replaceAll(RegExp(r'[éèëê]'), 'e')
    .replaceAll(RegExp(r'[íìïî]'), 'i')
    .replaceAll(RegExp(r'[óòöôõ]'), 'o')
    .replaceAll(RegExp(r'[úùüû]'), 'u');

class LexicoPraeco {
  static final Set<String> palabras = <String>{};
  static bool _cargado = false;

  static Future<void> cargar() async {
    if (_cargado) return;
    try {
      final data = await rootBundle.loadString('assets/diccionario_es.json');
      for (final p in List<String>.from(jsonDecode(data))) {
        final n = normalizarBasico(p).trim();
        if (n.isNotEmpty) palabras.add(n);
      }

      // PRAECO v2.2: el vocabulario alimentario también participa en la
      // puntuación de las capturas. Antes solo se usaba diccionario_es.json.
      try {
        final dataNGramas =
            await rootBundle.loadString('assets/ngramas_alimentos.json');
        final jsonNGramas = jsonDecode(dataNGramas) as Map<String, dynamic>;
        final uni = List<String>.from(jsonNGramas['unigramas'] ?? const []);
        for (final p in uni) {
          final n = normalizarBasico(p).trim();
          if (n.isNotEmpty) palabras.add(n);
        }
      } catch (e) {
        debugPrint('No se pudieron añadir unigramas al léxico compartido: $e');
      }

      _cargado = true;
      debugPrint('Léxico compartido cargado: ${palabras.length} palabras');
    } catch (e) {
      debugPrint('No se pudo cargar el léxico compartido: $e');
    }
  }
}

/// Puntúa un texto OCR en [0,1]: fracción de tokens alfabéticos (>= 3 letras)
/// presentes en el diccionario, ponderada por la cantidad de texto leído.
/// Es un estimador barato del CER que no necesita la transcripción real y
/// permite elegir la mejor fotografía de una ráfaga.
double puntuarTextoOCR(String texto) {
  final tokens = RegExp(r'[a-záéíóúñü]{3,}', caseSensitive: false)
      .allMatches(texto.toLowerCase())
      .map((m) => normalizarBasico(m.group(0)!))
      .toList();
  if (tokens.isEmpty) return 0.0;
  if (LexicoPraeco.palabras.isEmpty) {
    // Sin diccionario: solo se premia la cantidad de texto.
    return (tokens.length / 40).clamp(0.0, 1.0);
  }
  final aciertos = tokens.where(LexicoPraeco.palabras.contains).length;
  final cobertura = (tokens.length / 40).clamp(0.0, 1.0);
  return (aciertos / tokens.length) * (0.5 + 0.5 * cobertura);
}

// ==========================================================
// PREPROCESADO DE IMAGEN PARA OCR
// ==========================================================

/// Escala de grises + estirado de rango + contraste. No se binariza porque
/// ML Kit suele empeorar con imágenes en blanco y negro puro. Si la imagen es
/// pequeña se amplía para que la altura de letra supere ~20 px.
img.Image preprocesarParaOCR(img.Image entrada) {
  var g = img.grayscale(entrada);
  g = img.normalize(g, min: 0, max: 255);
  g = img.adjustColor(g, contrast: 1.35);
  if (g.width < 1600) {
    g = img.copyResize(g, width: 1600, interpolation: img.Interpolation.linear);
  }
  return g;
}

// ==========================================================
// ZONA DE INGREDIENTES A PARTIR DE LOS BLOQUES DE ML KIT
// ==========================================================

final RegExp _reInicioIngredientes = RegExp(
  r'ingred[il1|]ent',
  caseSensitive: false,
);
final RegExp _reFinIngredientes = RegExp(
  r'^(conservar|consumir|cons\.? pref|lote|peso neto|cantidad neta|'
  r'valor(es)? nutricional|informaci[oó]n nutricional|'
  r'fabricado|elaborado|envasado|distribuido|producido)',
  caseSensitive: false,
);

/// Devuelve las líneas desde "Ingredientes" hasta el siguiente encabezado
/// (conservación, lote, información nutricional...). Si no se localiza
/// "ingredientes", devuelve el texto completo.
String extraerZonaIngredientes(RecognizedText rt) {
  final lineas = <TextLine>[];
  for (final b in rt.blocks) {
    lineas.addAll(b.lines);
  }
  lineas.sort((a, b) {
    final dy = a.boundingBox.top.compareTo(b.boundingBox.top);
    return dy != 0 ? dy : a.boundingBox.left.compareTo(b.boundingBox.left);
  });

  var capturando = false;
  final buffer = StringBuffer();
  for (final l in lineas) {
    final t = l.text.trim();
    if (!capturando && _reInicioIngredientes.hasMatch(t)) capturando = true;
    if (capturando) {
      if (buffer.isNotEmpty && _reFinIngredientes.hasMatch(t)) break;
      buffer.writeln(t);
    }
  }
  final zona = buffer.toString().trim();
  if (!capturando || zona.length < 15) return rt.text;
  debugPrint('Zona de ingredientes localizada (${zona.length} caracteres)');
  return zona;
}

// ==========================================================
// NORMALIZACIÓN DE CARACTERES OCR (no quita tildes ni mayúsculas)
// ==========================================================

/// Corrige artefactos típicos de ML Kit: ligaduras, tildes como carácter
/// separado, comillas tipográficas, guiones raros, espacios no separables.
String normalizarOCR(String t) {
  const Map<String, String> equivalencias = {
    'ﬁ': 'fi',
    'ﬂ': 'fl',
    'ﬀ': 'ff',
    'ﬃ': 'ffi',
    'ﬄ': 'ffl',
    '\u00A0': ' ',
    '\u2009': ' ',
    '\u200B': '',
    '‘': "'",
    '’': "'",
    '“': '"',
    '”': '"',
    '´': "'",
    '`': "'",
    '–': '-',
    '—': '-',
    '‐': '-',
    '·': '.',
    '•': '',
    'ı': 'i',
    'ſ': 's',
    'Ø': 'O',
    'ø': 'o',
  };
  var s = t;
  equivalencias.forEach((k, v) => s = s.replaceAll(k, v));
  // Tildes combinantes (U+0300..U+036F) pegadas a una vocal → vocal acentuada.
  s = s
      .replaceAll('a\u0301', 'á')
      .replaceAll('e\u0301', 'é')
      .replaceAll('i\u0301', 'í')
      .replaceAll('o\u0301', 'ó')
      .replaceAll('u\u0301', 'ú')
      .replaceAll('n\u0303', 'ñ')
      .replaceAll('A\u0301', 'Á')
      .replaceAll('E\u0301', 'É')
      .replaceAll('I\u0301', 'Í')
      .replaceAll('O\u0301', 'Ó')
      .replaceAll('U\u0301', 'Ú')
      .replaceAll('N\u0303', 'Ñ')
      .replaceAll('u\u0308', 'ü');
  s = s.replaceAll(RegExp(r'[\u0300-\u036F]'), '');
  // Diacríticos dobles que a veces genera el OCR: "más" -> "mas" solo si
  // la tilde aparece duplicada (más).
  s = s.replaceAllMapped(RegExp(r'([áéíóú])[´\x27]'), (m) => m.group(1)!);
  // Espacios múltiples (sin tocar saltos de línea).
  s = s.replaceAll(RegExp(r'[ \t]+'), ' ');
  return s;
}

// ==========================================================
// DISTANCIA DE EDICIÓN PONDERADA POR CONFUSIONES OCR
// ==========================================================

/// Pares de caracteres que ML Kit confunde con frecuencia. Una sustitución
/// entre ellos cuesta 0,5 en lugar de 1.
const List<Set<String>> _gruposConfusionOCR = [
  {'l', 'i', '1', '|', '!', 'í', 'j'},
  {'o', '0', 'c', 'e', 'a', 'ó'},
  {'n', 'u', 'r', 'ñ', 'h'},
  {'m', 'rn', 'nn'},
  {'s', '5', 'z'},
  {'b', '6', 'h'},
  {'g', '9', 'q'},
  {'t', 'f', '+'},
  {'v', 'y', 'u'},
  {'d', 'cl', 'a'},
  {'é', 'e', 'ë'},
  {'á', 'a'},
  {'ú', 'u', 'ü'},
];

final Map<String, double> _costeSustitucion = () {
  final m = <String, double>{};
  for (final grupo in _gruposConfusionOCR) {
    for (final a in grupo) {
      for (final b in grupo) {
        if (a != b && a.length == 1 && b.length == 1) m['$a$b'] = 0.5;
      }
    }
  }
  return m;
}();

/// Levenshtein con coste de sustitución 0,5 para confusiones habituales de
/// OCR y 1 para el resto; inserción y borrado cuestan 1.
double distPonderada(String a, String b) {
  final n = a.length, m = b.length;
  if (n == 0) return m.toDouble();
  if (m == 0) return n.toDouble();
  var prev = List<double>.generate(m + 1, (j) => j.toDouble());
  var cur = List<double>.filled(m + 1, 0.0);
  for (var i = 1; i <= n; i++) {
    cur[0] = i.toDouble();
    final ca = a[i - 1];
    for (var j = 1; j <= m; j++) {
      final cb = b[j - 1];
      final double coste = ca == cb
          ? 0.0
          : (_costeSustitucion['$ca$cb'] ?? 1.0);
      final s = prev[j - 1] + coste;
      final d = prev[j] + 1.0;
      final ins = cur[j - 1] + 1.0;
      cur[j] = s < d ? (s < ins ? s : ins) : (d < ins ? d : ins);
    }
    final tmp = prev;
    prev = cur;
    cur = tmp;
  }
  return prev[m];
}

// ==========================================================
// ALÉRGENOS: 14 categorías del Reglamento (UE) 1169/2011, anexo II
// ==========================================================

const Map<String, List<String>> alergenosUE = {
  'gluten': [
    'gluten',
    'trigo',
    'cebada',
    'centeno',
    'avena',
    'espelta',
    'kamut',
    'harina de trigo',
    'semola',
  ],
  'crustáceos': [
    'crustaceos',
    'crustaceo',
    'gamba',
    'gambas',
    'langostino',
    'cangrejo',
    'marisco',
  ],
  'huevo': ['huevo', 'huevos', 'ovoalbumina', 'clara de huevo', 'yema'],
  'pescado': [
    'pescado',
    'merluza',
    'atun',
    'bacalao',
    'anchoa',
    'sardina',
    'salmon',
  ],
  'cacahuetes': ['cacahuete', 'cacahuetes', 'mani', 'cacahuate'],
  'soja': ['soja', 'lecitina de soja', 'soya'],
  'leche': [
    'leche',
    'lactosa',
    'suero lacteo',
    'suero de leche',
    'caseina',
    'caseinato',
    'mantequilla',
    'nata',
    'queso',
    'yogur',
    'lacteo',
    'lacteos',
  ],
  'frutos de cáscara': [
    'almendra',
    'almendras',
    'avellana',
    'avellanas',
    'nuez',
    'nueces',
    'anacardo',
    'anacardos',
    'pistacho',
    'pistachos',
    'pecana',
    'macadamia',
    'frutos secos',
    'frutos de cascara',
  ],
  'apio': ['apio'],
  'mostaza': ['mostaza'],
  'sésamo': ['sesamo', 'ajonjoli'],
  'sulfitos': [
    'sulfitos',
    'sulfito',
    'dioxido de azufre',
    'metabisulfito',
    'anhidrido sulfuroso',
  ],
  'altramuces': ['altramuz', 'altramuces', 'lupino'],
  'moluscos': [
    'moluscos',
    'molusco',
    'mejillon',
    'calamar',
    'almeja',
    'pulpo',
    'sepia',
  ],
};

class ResultadoAlergenos {
  final List<String> contiene;
  final List<String> trazas;
  const ResultadoAlergenos(this.contiene, this.trazas);
  bool get vacio => contiene.isEmpty && trazas.isEmpty;
}

ResultadoAlergenos detectarAlergenosRobusto(String texto) {
  final t = normalizarBasico(texto).replaceAll(RegExp(r'\s+'), ' ');

  // Separar la parte de trazas ("puede contener...", "trazas de...").
  final reTrazas = RegExp(
    r'(puede[n]? contener|trazas de|contiene trazas|elaborado en (una )?(fabrica|instalacion)[^.]*|'
    r'may contain|traces of)[^.\n]*',
  );
  final partesTrazas = reTrazas.allMatches(t).map((m) => m.group(0)!).toList();
  final textoTrazas = partesTrazas.join(' . ');
  final textoPrincipal = t.replaceAll(reTrazas, ' ');

  // Tokenización reutilizable (para ventana de negación).
  final tokensPrincipal = RegExp(
    r'[a-z0-9]+',
  ).allMatches(textoPrincipal).map((m) => m.group(0)!).toList();
  final tokensTrazas = RegExp(
    r'[a-z0-9]+',
  ).allMatches(textoTrazas).map((m) => m.group(0)!).toList();

  bool hayNegacionCercana(List<String> tokens, int idxAlergeno, {int k = 6}) {
    final start = (idxAlergeno - k).clamp(0, tokens.length);
    final prev = tokens.sublist(start, idxAlergeno);

    // Negaciones típicas (normalizadas ya a minúsculas en normalizarBasico).
    final neg1 = {
      'sin',
      'no',
      'libre',
      'exento',
      'ningun',
      'ninguna',
      'ninguno',
      'ningunos',
      'ningunas',
    };
    if (prev.any((tok) => neg1.contains(tok))) return true;

    // Patrones de bigramas
    for (int i = 0; i < prev.length - 1; i++) {
      final a = prev[i];
      final b = prev[i + 1];

      if (a == 'libre' && b == 'de') return true;
      if (a == 'exento' && b == 'de') return true;
      if (a == 'no' && b == 'contiene') return true;
    }

    return false;
  }

  // Busca alérgenos con difuso, pero decide por negación usando posición del token encontrado.
  Set<String> buscarConNegacion(List<String> tokensZona, String zonaOriginal) {
    final encontrados = <String>{};

    alergenosUE.forEach((alergeno, variantes) {
      for (final v in variantes) {
        if (v.contains(' ')) continue;

        // 1) Primero intenta exact match, pero SIN negación global.
        //    Como no tenemos índice del token exacto, NO decidimos aquí.
        //    En su lugar, solo usamos esto como señal para permitir el difuso.
        final tieneExact = RegExp('\\b$v\\b').hasMatch(zonaOriginal);

        // 2) Difuso (decisión por ventana con índice).
        final umbral = v.length <= 4 ? 0.5 : (v.length <= 7 ? 1.0 : 1.5);

        for (int i = 0; i < tokensZona.length; i++) {
          final tok = tokensZona[i];
          if (tok.length < 4) continue;
          if ((tok.length - v.length).abs() > 2) continue;

          // Si no hay exact-match en la zona, igual seguimos buscando difuso.
          // (esto mantiene recall bajo OCR roto).
          if (distPonderada(tok, v) <= umbral) {
            // Prioridad: negación cercana => NO marcar contiene
            if (!hayNegacionCercana(tokensZona, i, k: 4)) {
              encontrados.add(alergeno);
            }
            break; // stop variante de este alérgeno
          }
        }

        // Si había exact-match, ya no hace falta seguir con variantes idénticas
        // (opcional). Puedes dejarlo como está.
        if (tieneExact && encontrados.contains(alergeno)) {
          break;
        }
      }
    });

    return encontrados;
  }

  // 1) contiene en texto principal con negación
  final contiene = buscarConNegacion(tokensPrincipal, textoPrincipal);

  // 2) trazas: normalmente una expresión tipo "trazas de X" NO debería verse afectada por "sin X"
  // si tu OCR separa bien. Aun así, aplicamos la misma lógica para evitar falsos.
  final trazas = buscarConNegacion(tokensTrazas, textoTrazas)
    ..removeAll(contiene);

  return ResultadoAlergenos(contiene.toList(), trazas.toList());
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  await Permission.storage.request(); // PEDIR PERMISO DE ALMACENAMIENTO
  await LexicoPraeco.cargar(); // léxico para puntuar las capturas
  runApp(
    MaterialApp(
      theme: ThemeData.dark(),
      debugShowCheckedModeBanner: false,
      home: CameraScreen(camera: cameras.first),
    ),
  );
}

// =====================================================
// CARPETA DE EXPERIMENTOS TFM
// =====================================================

Future<Directory> obtenerCarpetaTFM() async {
  final carpeta = Directory('/storage/emulated/0/Download/TFM_OCR');
  if (!await carpeta.exists()) {
    await carpeta.create(recursive: true);
  }
  return carpeta;
}

/// ============VARIABLES GLOBALES =====================
// Control del aprendizaje adaptativo de Praeco.
// false = evaluación/ablación: carga los ficheros aprendidos, pero NO los modifica.
// true  = aprendizaje: actualiza errores_ocr.json y diccionario_adaptativo.json.
const bool modoAprendizajePraeco = false;

/// Map<String, String> erroresOCR = {};
Map<String, dynamic> erroresOCR = {};
Set<String> diccionarioAdaptativo =
    {}; // DICIONARIO ADAPTATIVO PARA APRENDIZAJE DE ERRORES

/// ============VARIABLES LOCALES =====================
String textoOCR = "";
String textoCorregido = "";
String ultimoOCRBruto = "";
String ultimoOCROriginal = "";
String ultimoOCRCorregido = "";
List<String> diccionarioUsuario = []; // Variable local para ML

// TRAZABILIDAD: solo observa las salidas de las fases existentes; no decide
// ni modifica ninguna corrección. Se vacía al iniciar cada procesamiento.
final List<Map<String, dynamic>> _trazasPraeco = <Map<String, dynamic>>[];

// PRAECO v2.2: léxico ampliado + vocabulario alimentario integrado en corrección y puntuación OCR.
// PRAECO v2.1 DIAGNÓSTICO: registra también candidatos y motivos de rechazo.
// No modifica los criterios de decisión de corregirPalabra().
// Detalle interno de las decisiones tomadas por corregirPalabra().
// Se usa únicamente para trazabilidad; no modifica la decisión del corrector.
final Map<String, String> _mecanismoCorreccionPorCambio = <String, String>{};
final Map<String, List<String>> _candidatosCorreccionPorCambio =
    <String, List<String>>{};

// Identificador del experimento actualmente procesado. Solo para diagnóstico.
String _experimentoTrazaActual = '';

void _registrarDiagnosticoPalabra({
  required String token,
  required String tokenNormalizado,
  required String decision,
  required String motivo,
  String? salida,
  List<Map<String, dynamic>> ranking = const <Map<String, dynamic>>[],
}) {
  final top = ranking.take(3).map((r) => <String, dynamic>{
        'candidato': r['candidato'],
        'score': r['score'],
        'distancia_ponderada': r['distancia'],
        'distancia_literal': r['distancia_literal'],
        'distancia_fonetica': r['distancia_fonetica'],
      }).toList();

  _trazasPraeco.add({
    'fecha': DateTime.now().toIso8601String(),
    'experimento': _experimentoTrazaActual,
    'modo_aprendizaje': modoAprendizajePraeco,
    'fase': 'correccion_lexica',
    'tipo_evento': 'diagnostico_palabra_v2_1',
    'token_original': token,
    'token_normalizado': tokenNormalizado,
    'decision': decision,
    'motivo': motivo,
    'token_final': salida ?? token,
    'candidatos_evaluados': top,
  });
}

String _claveCambioCorreccion(String original, String finalToken) =>
    '$original\u0000$finalToken';

void registrarDiferenciasEtapa({
  required String experimento,
  required String fase,
  required String entrada,
  required String salida,
}) {
  final antes = entrada
      .split(RegExp(r'\s+'))
      .where((s) => s.isNotEmpty)
      .toList();
  final despues = salida
      .split(RegExp(r'\s+'))
      .where((s) => s.isNotEmpty)
      .toList();
  final ahora = DateTime.now().toIso8601String();
  _trazasPraeco.add({
    'fecha': ahora,
    'experimento': experimento,
    'modo_aprendizaje': modoAprendizajePraeco,
    'fase': fase,
    'tipo_evento': 'resumen_fase',
    'tokens_entrada': antes.length,
    'tokens_salida': despues.length,
    'cambio_aplicado': entrada != salida,
    'texto_entrada': entrada,
    'texto_salida': salida,
  });

  // Si se conserva el número de tokens, cada sustitución queda localizada.
  // Si cambia, se registra el cambio de fase completo para no atribuir
  // erróneamente inserciones/borrados a una palabra concreta.
  if (antes.length == despues.length) {
    for (var i = 0; i < antes.length; i++) {
      if (antes[i] == despues[i]) continue;
      _trazasPraeco.add({
        'fecha': ahora,
        'experimento': experimento,
        'modo_aprendizaje': modoAprendizajePraeco,
        'fase': fase,
        'indice_token': i,
        'token_original': antes[i],
        'token_final': despues[i],
        'mecanismo': fase == 'correccion_lexica'
            ? (_mecanismoCorreccionPorCambio[
                    _claveCambioCorreccion(antes[i], despues[i])] ??
                'CORRECCION_LEXICA_NO_CLASIFICADA')
            : 'NGRAMA_CONTEXTO',
        if (fase == 'correccion_lexica')
          'candidatos_evaluados': _candidatosCorreccionPorCambio[
                  _claveCambioCorreccion(antes[i], despues[i])] ??
              const <String>[],
        'tipo_evento': 'sustitucion_observada',
      });
    }
  } else if (entrada != salida) {
    _trazasPraeco.add({
      'fecha': ahora,
      'experimento': experimento,
      'fase': fase,
      'tipo_evento': 'cambio_estructura_tokens',
      'tokens_entrada': antes.length,
      'tokens_salida': despues.length,
      'texto_entrada': entrada,
      'texto_salida': salida,
      'mecanismo': 'cambio de fase; alineacion palabra a palabra no atribuida',
    });
  }
}

Future<void> guardarTrazabilidadPraeco(String experimento) async {
  if (_trazasPraeco.isEmpty) return;
  final carpeta = await obtenerCarpetaTFM();
  final fichero = File('${carpeta.path}/trazabilidad_correccion.jsonl');
  // JSON Lines: una observacion por linea, apto para anexar experimentos.
  final contenido = _trazasPraeco
      .map((evento) => jsonEncode(evento))
      .join('\n');
  await fichero.writeAsString(
    '$contenido\n',
    mode: FileMode.append,
    flush: true,
  );
}

// =====================================================
// CALIDAD DE LA IMAGEN CAPTURADA
// =====================================================
// La calidad se evalúa sobre la imagen recortada que se enviará al OCR.
// No se utiliza un único valor arbitrario: se registran por separado
// nitidez, brillo y contraste para poder analizarlos posteriormente.

class ResultadoCalidadImagen {
  final int ancho;
  final int alto;
  final double nitidez;
  final double brillo;
  final double contraste;
  final bool aceptable;
  final List<String> motivos;

  const ResultadoCalidadImagen({
    required this.ancho,
    required this.alto,
    required this.nitidez,
    required this.brillo,
    required this.contraste,
    required this.aceptable,
    required this.motivos,
  });
}

class AnalizadorCalidadImagen {
  // Umbrales iniciales. Deben poder ajustarse después con los experimentos
  // del TFM para estudiar su relación con CER y WER.
  static const double minNitidez = 100.0;
  static const double minContraste = 20.0;
  static const double minBrillo = 35.0;
  static const double maxBrillo = 225.0;

  static double _luminancia(img.Pixel pixel) {
    return 0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b;
  }

  static ResultadoCalidadImagen analizar(img.Image image) {
    final int ancho = image.width;
    final int alto = image.height;

    // Muestreo para que el cálculo sea rápido incluso en fotografías de
    // alta resolución. El tamaño de muestra máximo es aproximadamente 800 px.
    final int paso = max(1, max(ancho, alto) ~/ 800);

    double suma = 0.0;
    double sumaCuadrados = 0.0;
    int muestras = 0;

    for (int y = 0; y < alto; y += paso) {
      for (int x = 0; x < ancho; x += paso) {
        final double l = _luminancia(image.getPixel(x, y));
        suma += l;
        sumaCuadrados += l * l;
        muestras++;
      }
    }

    final double brillo = muestras > 0 ? suma / muestras : 0.0;
    final double varianzaLuminancia = muestras > 0
        ? max(0.0, (sumaCuadrados / muestras) - (brillo * brillo))
        : 0.0;
    final double contraste = sqrt(varianzaLuminancia);

    // Varianza del operador Laplaciano. Es un indicador clásico de
    // nitidez: valores bajos suelen corresponder a imágenes desenfocadas.
    double sumaLap = 0.0;
    double sumaLapCuadrados = 0.0;
    int muestrasLap = 0;

    if (ancho > 2 * paso && alto > 2 * paso) {
      for (int y = paso; y < alto - paso; y += paso) {
        for (int x = paso; x < ancho - paso; x += paso) {
          final double centro = _luminancia(image.getPixel(x, y));
          final double izquierda = _luminancia(image.getPixel(x - paso, y));
          final double derecha = _luminancia(image.getPixel(x + paso, y));
          final double arriba = _luminancia(image.getPixel(x, y - paso));
          final double abajo = _luminancia(image.getPixel(x, y + paso));

          final double laplaciano =
              (4.0 * centro) - izquierda - derecha - arriba - abajo;

          sumaLap += laplaciano;
          sumaLapCuadrados += laplaciano * laplaciano;
          muestrasLap++;
        }
      }
    }

    final double mediaLap = muestrasLap > 0 ? sumaLap / muestrasLap : 0.0;
    final double nitidez = muestrasLap > 0
        ? max(0.0, (sumaLapCuadrados / muestrasLap) - (mediaLap * mediaLap))
        : 0.0;

    final List<String> motivos = [];

    if (nitidez < minNitidez) {
      motivos.add('imagen poco nítida o desenfocada');
    }
    if (brillo < minBrillo) {
      motivos.add('imagen demasiado oscura');
    } else if (brillo > maxBrillo) {
      motivos.add('imagen demasiado clara');
    }
    if (contraste < minContraste) {
      motivos.add('contraste insuficiente');
    }

    return ResultadoCalidadImagen(
      ancho: ancho,
      alto: alto,
      nitidez: nitidez,
      brillo: brillo,
      contraste: contraste,
      aceptable: motivos.isEmpty,
      motivos: motivos,
    );
  }
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
  final FlutterTts _tts = FlutterTts();
  final Stopwatch swCaptura = Stopwatch();
  int tiempoCaptura = 0;

  bool _buscandoCalidad = false;
  bool _analizandoFotograma = false;
  bool _capturando = false;
  bool _flujoActivo = false;
  int _fotogramasAceptables = 0;
  int _ultimoAnalisisMs = 0;
  String _estado = 'Preparando cámara...';
  ResultadoCalidadImagen? _ultimaCalidad;
  static const int _fotogramasNecesarios = 3;
  static const int _intervaloAnalisisMs = 350;

  @override
  void initState() {
    super.initState();
    _controller = CameraController(
      widget.camera,
      // La letra de la lista de ingredientes es diminuta: se necesita la
      // máxima resolución disponible para que el OCR la resuelva.
      ResolutionPreset.veryHigh,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    _init = _inicializarCamara();
    _tts.setLanguage('es-ES');
    _tts.setSpeechRate(0.5);
  }

  Future<void> _inicializarCamara() async {
    await _controller.initialize();
    try {
      await _controller.setFocusMode(FocusMode.auto);
      await _controller.setExposureMode(ExposureMode.auto);
      await _controller.setFlashMode(FlashMode.off);
    } catch (e) {
      debugPrint('Aviso configurando enfoque/exposición: $e');
    }
    if (!mounted) return;
    await _iniciarBusquedaAutomatica();
  }

  bool _linternaEncendida = false;

  /// Enciende la linterna si el último fotograma analizado era oscuro.
  /// El usuario con discapacidad visual no puede juzgar la iluminación.
  Future<void> _ajustarLinterna() async {
    final brillo = _ultimaCalidad?.brillo;
    final necesaria =
        brillo != null && brillo < ConfigCaptura.brilloParaLinterna;
    if (necesaria == _linternaEncendida) return;
    try {
      await _controller.setFlashMode(
        necesaria ? FlashMode.torch : FlashMode.off,
      );
      _linternaEncendida = necesaria;
      if (necesaria) {
        debugPrint('Linterna activada (brillo=${brillo.toStringAsFixed(0)})');
        await Future.delayed(const Duration(milliseconds: 250));
      }
    } catch (e) {
      debugPrint('No se pudo cambiar la linterna: $e');
    }
  }

  Future<void> _apagarLinterna() async {
    if (!_linternaEncendida) return;
    try {
      await _controller.setFlashMode(FlashMode.off);
    } catch (_) {}
    _linternaEncendida = false;
  }

  /// Fuerza el enfoque en el centro del encuadre y espera a que converja.
  Future<void> _enfocarCentro() async {
    try {
      await _controller.setFocusPoint(const Offset(0.5, 0.5));
      await _controller.setExposurePoint(const Offset(0.5, 0.5));
      await Future.delayed(
        const Duration(milliseconds: ConfigCaptura.esperaEnfoqueMs),
      );
    } catch (e) {
      debugPrint('Aviso al fijar el punto de enfoque: $e');
    }
  }

  /// Captura hasta N fotografías y elige la que mejor puntúa según el OCR
  /// (fracción de palabras reconocidas en el diccionario). El OCR se ejecuta
  /// sobre el fichero original (nativo, rápido) sin decodificar la imagen en
  /// Dart; solo la fotografía elegida se decodifica después.
  Future<({XFile foto, String texto, double puntuacion, int disparos})>
  _capturarMejorDeN() async {
    final reconocedor = TextRecognizer(script: TextRecognitionScript.latin);
    XFile? mejorFoto;
    String mejorTexto = '';
    double mejorPuntuacion = -1;
    int disparos = 0;
    try {
      for (var i = 0; i < ConfigCaptura.disparosMaximos; i++) {
        final foto = await _controller.takePicture();
        disparos++;
        double p = 0;
        String texto = '';
        try {
          final res = await reconocedor.processImage(
            InputImage.fromFilePath(foto.path),
          );
          texto = res.text;
          p = puntuarTextoOCR(texto);
        } catch (e) {
          debugPrint('OCR de selección falló en el disparo $i: $e');
        }
        debugPrint('Disparo $i: puntuación OCR=${p.toStringAsFixed(3)}');
        if (p > mejorPuntuacion) {
          mejorPuntuacion = p;
          mejorFoto = foto;
          mejorTexto = texto;
        }
        if (mounted) {
          setState(
            () => _estado =
                'Capturando ${i + 1}/${ConfigCaptura.disparosMaximos}…',
          );
        }
        if (p >= ConfigCaptura.puntuacionSuficiente) break;
        await Future.delayed(const Duration(milliseconds: 200));
      }
    } finally {
      await reconocedor.close();
    }
    return (
      foto: mejorFoto!,
      texto: mejorTexto,
      puntuacion: mejorPuntuacion < 0 ? 0.0 : mejorPuntuacion,
      disparos: disparos,
    );
  }

  @override
  void dispose() {
    _buscandoCalidad = false;
    if (_controller.value.isStreamingImages) {
      _controller.stopImageStream();
    }
    _controller.dispose();
    _tts.stop();
    super.dispose();
  }

  Future<void> _iniciarBusquedaAutomatica() async {
    if (!mounted || _capturando || _flujoActivo) return;
    try {
      _fotogramasAceptables = 0;
      _ultimoAnalisisMs = 0;
      _buscandoCalidad = true;
      _estado = 'Buscando una imagen nítida…';
      if (mounted) setState(() {});
      await _controller.startImageStream(_analizarFotograma);
      _flujoActivo = true;
    } catch (e) {
      debugPrint('No se pudo iniciar el análisis automático: $e');
      if (mounted) {
        setState(
          () => _estado = 'No se pudo analizar el vídeo. Usa Capturar ahora.',
        );
      }
    }
  }

  /// Analiza la luminancia del fotograma YUV sin convertirlo a RGB.
  /// Así se evita una conversión costosa para cada imagen de la cámara.
  ResultadoCalidadImagen _analizarFotogramaY(CameraImage frame) {
    final plane = frame.planes.first;
    final bytes = plane.bytes;
    final rowStride = plane.bytesPerRow;
    final w = frame.width;
    final h = frame.height;
    final int step = max(1, max(w, h) ~/ 320);

    double sum = 0, sum2 = 0;
    int n = 0;
    for (int y = 0; y < h; y += step) {
      final row = y * rowStride;
      for (int x = 0; x < w; x += step) {
        final v = bytes[row + x].toDouble();
        sum += v;
        sum2 += v * v;
        n++;
      }
    }
    final brillo = n == 0 ? 0.0 : sum / n;
    final contraste = n == 0 ? 0.0 : sqrt(max(0.0, sum2 / n - brillo * brillo));

    // Varianza del Laplaciano sobre muestras de luminancia.
    double lapSum = 0, lapSum2 = 0;
    int lapN = 0;
    // El Laplaciano usa vecinos inmediatos (igual que el analizador de la
    // fotografía final); solo se reduce la frecuencia de muestreo del bucle.
    for (int y = 1; y < h - 1; y += step) {
      final row = y * rowStride;
      final rowUp = (y - 1) * rowStride;
      final rowDown = (y + 1) * rowStride;
      for (int x = 1; x < w - 1; x += step) {
        final c = bytes[row + x].toDouble();
        final l = bytes[row + x - 1].toDouble();
        final r = bytes[row + x + 1].toDouble();
        final u = bytes[rowUp + x].toDouble();
        final d = bytes[rowDown + x].toDouble();
        final lap = 4 * c - l - r - u - d;
        lapSum += lap;
        lapSum2 += lap * lap;
        lapN++;
      }
    }
    final mediaLap = lapN == 0 ? 0.0 : lapSum / lapN;
    final nitidez = lapN == 0
        ? 0.0
        : max(0.0, lapSum2 / lapN - mediaLap * mediaLap);

    final motivos = <String>[];
    if (nitidez < AnalizadorCalidadImagen.minNitidez) {
      motivos.add('imagen poco nítida o desenfocada');
    }
    if (brillo < AnalizadorCalidadImagen.minBrillo) {
      motivos.add('imagen demasiado oscura');
    } else if (brillo > AnalizadorCalidadImagen.maxBrillo) {
      motivos.add('imagen demasiado clara');
    }
    if (contraste < AnalizadorCalidadImagen.minContraste) {
      motivos.add('contraste insuficiente');
    }
    return ResultadoCalidadImagen(
      ancho: w,
      alto: h,
      nitidez: nitidez,
      brillo: brillo,
      contraste: contraste,
      aceptable: motivos.isEmpty,
      motivos: motivos,
    );
  }

  void _analizarFotograma(CameraImage frame) {
    if (!_buscandoCalidad || _capturando || _analizandoFotograma) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _ultimoAnalisisMs < _intervaloAnalisisMs) return;
    _ultimoAnalisisMs = now;
    _analizandoFotograma = true;
    try {
      if (frame.planes.isEmpty ||
          frame.format.group != ImageFormatGroup.yuv420) {
        _fotogramasAceptables = 0;
        return;
      }
      final calidad = _analizarFotogramaY(frame);
      _ultimaCalidad = calidad;
      if (calidad.aceptable) {
        _fotogramasAceptables++;
        _estado =
            'Calidad correcta (${_fotogramasAceptables}/$_fotogramasNecesarios)…';
      } else {
        _fotogramasAceptables = 0;
        _estado = 'Ajusta distancia, luz o enfoque…';
      }
      if (mounted) setState(() {});
      if (_fotogramasAceptables >= _fotogramasNecesarios) {
        _buscandoCalidad = false;
        _estado = 'Calidad estable. Capturando…';
        if (mounted) setState(() {});
        // Se difiere la captura para salir del callback del flujo de imágenes.
        Future<void>.microtask(() => _capturar(automatico: true));
      }
    } catch (e) {
      debugPrint('Error analizando fotograma: $e');
    } finally {
      _analizandoFotograma = false;
    }
  }

  Future<void> _detenerFlujo() async {
    _buscandoCalidad = false;
    if (_controller.value.isStreamingImages) {
      try {
        await _controller.stopImageStream();
      } catch (e) {
        debugPrint('Aviso al detener flujo de cámara: $e');
      }
    }
    _flujoActivo = false;
  }

  Future<void> _capturar({bool automatico = false}) async {
    if (_capturando) return;
    _capturando = true;
    _buscandoCalidad = false;
    if (mounted) setState(() => _estado = 'Capturando imagen…');
    swCaptura.reset();
    swCaptura.start();

    try {
      await _init;
      await _detenerFlujo();
      // Aviso sonoro: el usuario debe mantener el móvil quieto durante la ráfaga.
      _tts.speak('Capturando. Mantén el móvil quieto.');
      await _ajustarLinterna();
      await _enfocarCentro();
      final seleccion = await _capturarMejorDeN();
      await _apagarLinterna();
      final foto = seleccion.foto;
      swCaptura.stop();
      tiempoCaptura = swCaptura.elapsedMilliseconds;
      MetricasRendimiento.captura = tiempoCaptura;
      MetricasRendimiento.puntuacionCaptura = seleccion.puntuacion;
      MetricasRendimiento.disparos = seleccion.disparos;
      debugPrint(
        'Tiempo captura (ráfaga de ${seleccion.disparos}): $tiempoCaptura ms · '
        'mejor puntuación OCR=${seleccion.puntuacion.toStringAsFixed(3)}',
      );

      final bytes = await File(foto.path).readAsBytes();
      final image = img.decodeImage(bytes);
      if (image == null)
        throw Exception('No se pudo decodificar la fotografía');

      final cropped = img.copyCrop(
        image,
        x: 0,
        y: 0,
        width: image.width,
        height: (image.height * 2 / 3).toInt(),
      );
      final calidad = AnalizadorCalidadImagen.analizar(cropped);
      _ultimaCalidad = calidad;
      debugPrint(
        'Calidad imagen: nitidez=${calidad.nitidez.toStringAsFixed(2)}, '
        'brillo=${calidad.brillo.toStringAsFixed(2)}, '
        'contraste=${calidad.contraste.toStringAsFixed(2)}, aceptable=${calidad.aceptable}',
      );

      String decisionCalidad = 'ACEPTADA';
      if (!calidad.aceptable && automatico) {
        // El fotograma de vídeo puede tener buena calidad y la foto final no.
        // En ese caso no se procesa: se vuelve a buscar una captura válida.
        debugPrint(
          'La foto final no superó los umbrales; reanudando búsqueda automática.',
        );
        _capturando = false;
        if (mounted) {
          setState(
            () =>
                _estado = 'La foto salió borrosa. Mantén la etiqueta quieta…',
          );
        }
        await _iniciarBusquedaAutomatica();
        return;
      }
      if (!calidad.aceptable) {
        HapticFeedback.heavyImpact();
        final motivos = calidad.motivos.join('. ');
        await _tts.speak(
          'La calidad de la imagen es baja. $motivos. Se recomienda repetir la fotografía.',
        );
        if (!mounted) return;
        final continuar = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text('Calidad de imagen baja'),
            content: Text(
              'Se han detectado problemas en la captura:\n'
              '${calidad.motivos.map((m) => '• $m').join('\n')}\n'
              'Se recomienda repetir la fotografía para mejorar el OCR.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Repetir foto'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Continuar'),
              ),
            ],
          ),
        );
        if (continuar != true) {
          _capturando = false;
          await _iniciarBusquedaAutomatica();
          return;
        }
        decisionCalidad = 'CONTINUAR_CALIDAD_BAJA';
        await _tts.speak('Continuando con la captura.');
      }

      final dir = await obtenerCarpetaTFM();
      final idExperimento = DateTime.now().millisecondsSinceEpoch;
      // Se guarda en JPEG (codificar PNG en Dart tarda varios segundos a
      // esta resolución). Se conservan la imagen recortada y la preprocesada
      // para que ResultScreen pueda elegir la que mejor lee el OCR.
      final path = '${dir.path}/img_$idExperimento.jpg';
      final pathPre = '${dir.path}/img_${idExperimento}_pre.jpg';
      HapticFeedback.mediumImpact();
      await File(path).writeAsBytes(img.encodeJpg(cropped, quality: 95));
      try {
        final pre = preprocesarParaOCR(cropped);
        await File(pathPre).writeAsBytes(img.encodeJpg(pre, quality: 95));
      } catch (e) {
        debugPrint('Preprocesado no disponible: $e');
      }
      final preExiste = await File(pathPre).exists();
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ResultScreen(
            imagePath: path,
            imagePathPre: preExiste ? pathPre : null,
            idExperimento: idExperimento,
            tiempoCaptura: tiempoCaptura,
            calidadImagen: calidad,
            decisionCalidad: decisionCalidad,
            puntuacionCaptura: seleccion.puntuacion,
          ),
        ),
      );
    } catch (e) {
      swCaptura.stop();
      await _apagarLinterna();
      debugPrint('Error al capturar: $e');
      if (mounted) setState(() => _estado = 'Error de cámara. Reintentando…');
      _capturando = false;
      await _iniciarBusquedaAutomatica();
      return;
    }
    _capturando = false;
  }

  Future<void> _cancelarBusqueda() async {
    await _detenerFlujo();
    if (!mounted) return;
    setState(() => _estado = 'Búsqueda automática pausada');
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      body: Stack(
        children: [
          FutureBuilder<void>(
            future: _init,
            builder: (_, snap) => snap.connectionState == ConnectionState.done
                ? SizedBox.expand(child: CameraPreview(_controller))
                : const Center(child: CircularProgressIndicator()),
          ),
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
          Align(
            alignment: const Alignment(0, 0.70),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'PRAECO CAPTURA AUTOMÁTICA',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _estado,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 15),
                  ),
                  if (_ultimaCalidad != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Nitidez ${_ultimaCalidad!.nitidez.toStringAsFixed(0)} · '
                      'Brillo ${_ultimaCalidad!.brillo.toStringAsFixed(0)} · '
                      'Contraste ${_ultimaCalidad!.contraste.toStringAsFixed(0)}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 8,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _capturando ? null : () => _capturar(),
                        icon: const Icon(Icons.camera_alt),
                        label: const Text('Capturar ahora'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _buscandoCalidad
                            ? _cancelarBusqueda
                            : _iniciarBusquedaAutomatica,
                        icon: Icon(
                          _buscandoCalidad ? Icons.pause : Icons.autorenew,
                        ),
                        label: Text(_buscandoCalidad ? 'Pausar' : 'Reanudar'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text(
                'TFM: ASISTENTE PARA PERSONAS CON DISCAPACIDAD VISUAL',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  backgroundColor: Colors.black54,
                  color: Colors.white70,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class EvaluacionOCR {
  static Future<void> guardarExperimento({
    required String imagen,
    required String textoReal,
    required String ocr,
    required String corregido,
    required double cerOCR,
    required double cerCorregido,
    required double werOCR,
    required double werCorregido,
    required int tiempoCaptura,
    required int tiempoOCR,
    required int tiempoCorreccion,
    required int tiempoAlergenos,
    required ResultadoCalidadImagen calidadImagen,
    required String decisionCalidad,
    required bool modoAprendizaje,
  }) async {
    final carpeta = await obtenerCarpetaTFM();

    final fichero = File('${carpeta.path}/experimentos.csv');

    print('====================================');
    print('GUARDANDO EXPERIMENTO');
    print('CSV: ${fichero.path}');
    print('Imagen: $imagen');

    // --------------------------------------------------
    // 1. LIMPIAR TEXTOS
    // --------------------------------------------------

    String limpiarTexto(String texto) {
      return texto
          .replaceAll('\n', ' ')
          .replaceAll('\r', ' ')
          .replaceAll('"', '""')
          .trim();
    }

    textoReal = limpiarTexto(textoReal);
    ocr = limpiarTexto(ocr);
    corregido = limpiarTexto(corregido);

    // --------------------------------------------------
    // 2. CABECERA DEL CSV Y VALIDACIÓN DE ESTRUCTURA
    // --------------------------------------------------

    const String cabeceraCSV =
        'fecha,imagen,texto_real,ocr,ocr_corregido,'
        'cer_ocr,cer_corregido,wer_ocr,wer_corregido,'
        'ancho,alto,nitidez,brillo,contraste,calidad_aceptable,decision_calidad,'
        't_captura,t_ocr,t_correccion,t_alergenos,modo_aprendizaje\n';

    const int numeroColumnasEsperadas = 21;

    // Comprueba el número de columnas respetando las comas que puedan existir
    // dentro de campos de texto entre comillas.
    int contarColumnasCSV(String linea) {
      int columnas = 1;
      bool dentroDeComillas = false;

      for (int i = 0; i < linea.length; i++) {
        final caracter = linea[i];

        if (caracter == '"') {
          // Una comilla doble escapada ("") no cambia el estado.
          if (dentroDeComillas && i + 1 < linea.length && linea[i + 1] == '"') {
            i++;
            continue;
          }
          dentroDeComillas = !dentroDeComillas;
        } else if (caracter == ',' && !dentroDeComillas) {
          columnas++;
        }
      }

      return columnas;
    }

    bool csvNecesitaReconstruccion = false;

    if (await fichero.exists()) {
      final contenidoActual = await fichero.readAsString();
      final lineas = contenidoActual
          .split(RegExp(r'\r?\n'))
          .where((linea) => linea.trim().isNotEmpty)
          .toList();

      if (lineas.isEmpty || lineas.first != cabeceraCSV.trim()) {
        csvNecesitaReconstruccion = true;
      } else {
        // También comprobamos las filas existentes. Esto es importante porque
        // una versión anterior de Praeco podía tener la cabecera nueva pero
        // filas antiguas de 13 columnas.
        for (int i = 1; i < lineas.length; i++) {
          if (contarColumnasCSV(lineas[i]) != numeroColumnasEsperadas) {
            csvNecesitaReconstruccion = true;
            break;
          }
        }
      }

      if (csvNecesitaReconstruccion) {
        final marca = DateTime.now().millisecondsSinceEpoch;
        final respaldo = File(
          '${carpeta.path}/experimentos_respaldo_$marca.csv',
        );

        await fichero.rename(respaldo.path);
        await fichero.writeAsString(cabeceraCSV);

        print('CSV anterior incompatible conservado en: ${respaldo.path}');
      }
    } else {
      await fichero.writeAsString(cabeceraCSV);
      print('CSV creado con $numeroColumnasEsperadas columnas');
    }

    // --------------------------------------------------
    // 3. CREAR LA FILA COMPLETA: EXACTAMENTE 21 COLUMNAS
    // --------------------------------------------------

    final linea = <String>[
      DateTime.now().toIso8601String(),
      '"$imagen"',
      '"$textoReal"',
      '"$ocr"',
      '"$corregido"',
      cerOCR.toStringAsFixed(6),
      cerCorregido.toStringAsFixed(6),
      werOCR.toStringAsFixed(6),
      werCorregido.toStringAsFixed(6),
      calidadImagen.ancho.toString(),
      calidadImagen.alto.toString(),
      calidadImagen.nitidez.toStringAsFixed(4),
      calidadImagen.brillo.toStringAsFixed(4),
      calidadImagen.contraste.toStringAsFixed(4),
      calidadImagen.aceptable ? 'true' : 'false',
      decisionCalidad,
      tiempoCaptura.toString(),
      tiempoOCR.toString(),
      tiempoCorreccion.toString(),
      tiempoAlergenos.toString(),
      modoAprendizaje ? 'true' : 'false',
    ].join(',');

    // Verificación interna: nunca escribir una fila que no tenga 21 columnas.
    assert(
      contarColumnasCSV(linea) == numeroColumnasEsperadas,
      'Error: la fila CSV no contiene $numeroColumnasEsperadas columnas.',
    );

    await fichero.writeAsString('$linea\n', mode: FileMode.append);

    print('Fila añadida correctamente');
    print('OCR corregido: $corregido');
    print('====================================');
  }
}
// ================= RESULTADO =================

class ResultScreen extends StatefulWidget {
  final String imagePath;
  final String? imagePathPre; // imagen preprocesada (puede no existir)
  final int idExperimento;
  final int
  tiempoCaptura; // Variable para almacenar el tiempo de captura en milisegundos
  final ResultadoCalidadImagen calidadImagen;
  final String decisionCalidad;
  final double puntuacionCaptura; // puntuación OCR de la ráfaga

  const ResultScreen({
    super.key,
    required this.imagePath,
    this.imagePathPre,
    required this.idExperimento,
    required this.tiempoCaptura,
    required this.calidadImagen,
    required this.decisionCalidad,
    this.puntuacionCaptura = 0.0,
  });

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  final FlutterTts _tts = FlutterTts();
  String _resultado = "Analizando...";
  bool _experimentoGuardado = false;

  // NUEVO
  final TextEditingController realController = TextEditingController();

  List<String> diccionario = [];
  List<String> unigramas = [];
  List<String> bigramas = [];
  List<String> trigramas = [];
  List<String> cuatrigramas = [];

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

  // ===== palabras comunes en etiquetas de alimentos ========
  final palabrasAlimentos = [
    "ingredientes",
    "agua",
    "aceite",
    "sal",
    "azucar",
    "azúcar",
    "huevo",
    "leche",
    "gluten",
    "conservador",
    "estabilizante",
    "aroma",
    "vinagre",
    "maiz",
    "maíz",
    "girasol",
    "trigo",
  ];

  // ================ LISTA DE PALABRAS INGLESAS =======
  final List<String> palabrasIngles = [
    "ingredients",
    "sunflower",
    "weight",
    "best before",
    "vinegar",
    "starch",
    "preservative",
    "sugar",
    "spirit",
    "egg yolk",
    "net weight",
    "make",
    "your",
    "world",
  ];

  // ================= NORMALIZAR =================
  String normalizar(String t) => t
      .toLowerCase()
      .replaceAll(RegExp(r'[áàäâã]'), 'a')
      .replaceAll(RegExp(r'[éèëê]'), 'e')
      .replaceAll(RegExp(r'[íìïî]'), 'i')
      .replaceAll(RegExp(r'[óòöôõ]'), 'o')
      .replaceAll(RegExp(r'[úùüû]'), 'u');

  // ================= NORMALIZAR CER/WER =================
  String normalizarWER(String texto) {
    texto = normalizar(texto);
    texto = texto.replaceAll(RegExp(r'[^\w\s]'), '');

    texto = texto.replaceAll(RegExp(r'\s+'), ' ');

    return texto.trim();
  }

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

  // ================= CARGAR ERRORES OCR =================

  Future<void> cargarErroresOCR() async {
    final carpeta = await obtenerCarpetaTFM();
    final fichero = File('${carpeta.path}/errores_ocr.json');

    if (await fichero.exists()) {
      try {
        final contenido = await fichero.readAsString();
        erroresOCR = Map<String, dynamic>.from(jsonDecode(contenido));
        debugPrint('Errores OCR cargados: ${erroresOCR.length}');
      } catch (e) {
        debugPrint('Error cargando errores_ocr.json: $e');

        erroresOCR = {};
      }
    } else {
      debugPrint('No existe errores_ocr.json. Se inicia vacío.');

      erroresOCR = {};
    }
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

  // ================= PRAECO v2.3.1: TOKENS ALFANUMÉRICOS =================
  // Corrige confusiones OCR letra/dígito únicamente cuando el token completo
  // conduce de forma inequívoca a una palabra ya presente en el léxico.
  // De este modo A9UDAS puede recuperar AYUDAS, pero códigos válidos como
  // B12 o E330 permanecen intactos.
  String _normalizarTokenAlfanumericoOCR(String token) {
    if (token.isEmpty) return token;

    // Porcentajes formados exclusivamente por caracteres visualmente
    // confundibles con 0/1. Ejemplo observado: loo% -> 100%.
    if (token.endsWith('%')) {
      final cuerpo = token.substring(0, token.length - 1);
      if (cuerpo.isNotEmpty && RegExp(r'^[0-9oOlLiI]+$').hasMatch(cuerpo)) {
        final numerico = cuerpo
            .replaceAll(RegExp(r'[oO]'), '0')
            .replaceAll(RegExp(r'[lLiI]'), '1');
        if (RegExp(r'^\d+$').hasMatch(numerico)) {
          final salida = '$numerico%';
          if (salida != token) {
            _registrarDiagnosticoPalabra(
              token: token,
              tokenNormalizado: normalizar(token),
              decision: 'CORREGIR',
              motivo: 'NORMALIZACION_OCR_NUMERICA_CONTEXTO_PORCENTAJE',
              salida: salida,
            );
          }
          return salida;
        }
      }
    }

    // Solo esta rama trata tokens que contienen simultáneamente letras y
    // dígitos. Nunca se corrige un fragmento interno del token.
    if (!RegExp(r'[A-Za-zÁÉÍÓÚáéíóúñÑÜü]').hasMatch(token) ||
        !RegExp(r'\d').hasMatch(token)) {
      return token;
    }

    final lexico = <String>{
      ...diccionario.map((e) => normalizar(limpiar(e))),
      ...unigramas.map((e) => normalizar(limpiar(e))),
      ...diccionarioAdaptativo.map((e) => normalizar(limpiar(e))),
    }..removeWhere((e) => e.isEmpty);

    // Confusiones observables en OCR. Se aceptará una sustitución solo si el
    // resultado completo pertenece al léxico y existe una única solución.
    const mapa = <String, List<String>>{
      '0': <String>['o'],
      '1': <String>['l', 'i'],
      '2': <String>['z'],
      '5': <String>['s'],
      '6': <String>['g'],
      '8': <String>['b'],
      '9': <String>['y', 'g'],
    };

    List<String> variantes = <String>[''];
    for (final rune in token.runes) {
      final ch = String.fromCharCode(rune);
      final opciones = mapa[ch] ?? <String>[ch];
      final nuevas = <String>[];
      for (final prefijo in variantes) {
        for (final opcion in opciones) {
          nuevas.add('$prefijo$opcion');
          if (nuevas.length > 32) break;
        }
        if (nuevas.length > 32) break;
      }
      variantes = nuevas;
    }

    final soluciones = variantes
        .where((v) => lexico.contains(normalizar(limpiar(v))))
        .toSet()
        .toList();

    if (soluciones.length == 1) {
      final salida = _conservarMayusculas(token, soluciones.single);
      _registrarDiagnosticoPalabra(
        token: token,
        tokenNormalizado: normalizar(token),
        decision: 'CORREGIR',
        motivo: 'NORMALIZACION_OCR_ALFANUMERICA_LEXICO_UNIVOCO',
        salida: salida,
      );
      return salida;
    }

    _registrarDiagnosticoPalabra(
      token: token,
      tokenNormalizado: normalizar(token),
      decision: 'CONSERVAR',
      motivo: soluciones.isEmpty
          ? 'ALFANUMERICO_SIN_CANDIDATO_LEXICO'
          : 'ALFANUMERICO_AMBIGUO',
    );
    return token;
  }

  // ================= CORRECCIÓN PRO CONSERVADORA =================
  String corregirPalabra(String palabra) {
    if (palabra.trim().isEmpty) return palabra;

    final original = palabra.trim();
    final palabraNorm = normalizar(original);

    // Preservar números, porcentajes, unidades y formatos mixtos.
    if (esNumero(original) ||
        RegExp(
          r'^\d+(?:[.,]\d+)?[%a-zA-ZáéíóúñÁÉÍÓÚÑ]*$',
        ).hasMatch(original)) {
      return original;
    }

    // No modificar tokens breves ni palabras funcionales.
    if (palabraNorm.length <= 2 || stopWords.contains(palabraNorm)) {
      return original;
    }

    final limpia = limpiar(original);
    if (limpia.isEmpty) return original;
    final norm = normalizar(limpia);
    if (norm.isEmpty) return original;

    // Proteger marcas y nombres propios conocidos.
    const nombresPropiosProtegidos = <String>{
      'simón',
      'simon',
      'nestlé',
      'nestle',
      'nescafé',
      'nescafe',
      'españa',
      'barcelona',
      'société',
      'france',
      'italia',
    };
    if (nombresPropiosProtegidos.contains(norm)) return original;

    // Las palabras inglesas conocidas no se comparan con el léxico español.
    if (palabrasIngles.any((p) => normalizar(p) == norm)) return original;

    // 1) MEMORIA DE ERRORES VALIDADA.
    final info = erroresOCR[norm];
    if (info is Map) {
      final correcta = info['correcta'];
      final frecuencia = info['frecuencia'];
      if (correcta is String &&
          correcta.trim().isNotEmpty &&
          frecuencia is num &&
          frecuencia >= 1 &&
          info['validado'] == true &&
          info['conflicto'] != true) {
        final correctaNorm = normalizar(limpiar(correcta));
        final d = distPonderada(norm, correctaNorm);
        final maxDist = norm.length <= 5 ? 1 : (norm.length <= 8 ? 2 : 3);
        if (correctaNorm.isNotEmpty &&
            d > 0 &&
            d <= maxDist &&
            d / norm.length <= 0.30) {
          final salida = _conservarMayusculas(original, correcta.trim());
          final clave = _claveCambioCorreccion(original, salida);
          _mecanismoCorreccionPorCambio[clave] = 'ERRORES_OCR_VALIDADO';
          _candidatosCorreccionPorCambio[clave] = <String>[correcta.trim()];
          _registrarDiagnosticoPalabra(
            token: original,
            tokenNormalizado: norm,
            decision: 'CORREGIR',
            motivo: 'ERRORES_OCR_VALIDADO',
            salida: salida,
            ranking: <Map<String, dynamic>>[
              <String, dynamic>{
                'candidato': correcta.trim(),
                'score': d,
                'distancia': d,
                'distancia_literal': dist(norm, correctaNorm),
                'distancia_fonetica': dist(fonetizar(norm), fonetizar(correctaNorm)),
              }
            ],
          );
          debugPrint(
            'ERROR APRENDIDO: "$original" → "$correcta" '
            '(frecuencia=$frecuencia, distancia=$d)',
          );
          return salida;
        }
      }
    }

    // 2) PALABRA YA VÁLIDA.
    // La comparación normalizada es insensible a mayúsculas/minúsculas.
    // Así, por ejemplo, "ToMATES" se conserva si "tomates" está en algún
    // léxico, sin intentar transformarlo en otra palabra.
    if (diccionario.any((d) => normalizar(d) == norm) ||
        diccionarioAdaptativo.any((d) => normalizar(d) == norm)) {
      _registrarDiagnosticoPalabra(
        token: original,
        tokenNormalizado: norm,
        decision: 'CONSERVAR',
        motivo: 'TOKEN_YA_VALIDO_EN_LEXICO',
      );
      return original;
    }

    // PRAECO v2.2: candidatos de tres fuentes. Los unigramas aportan
    // vocabulario especializado alimentario (p. ej. marisco, lactosa, gluten)
    // sin convertir bigramas/trigramas completos en candidatos de una palabra.
    final Set<String> candidatos = {
      ...diccionario,
      ...unigramas,
      ...diccionarioAdaptativo,
    };
    final List<Map<String, dynamic>> ranking = <Map<String, dynamic>>[];
    final fon = fonetizar(limpia);

    for (final candidato in candidatos) {
      final candidatoNorm = normalizar(limpiar(candidato));
      if (candidatoNorm.isEmpty || candidatoNorm == norm) continue;

      final diferenciaLongitud = (norm.length - candidatoNorm.length).abs();
      if (diferenciaLongitud > 2) continue;

      // Protección morfológica conservadora: no convertir automáticamente
      // un plural correcto/aparente en singular eliminando únicamente la s.
      // Evita el caso observado "ToMATES" → "Tomate".
      if (norm.endsWith('s') && candidatoNorm == norm.substring(0, norm.length - 1)) {
        continue;
      }

      final distancia = distPonderada(norm, candidatoNorm);
      final distanciaLiteral = dist(norm, candidatoNorm);
      final distanciaMaxima = norm.length <= 5 ? 1 : (norm.length <= 8 ? 2 : 3);
      if (distancia == 0 || distancia > distanciaMaxima) continue;
      if (distancia / norm.length > 0.30) continue;

      final distanciaFon = dist(fon, fonetizar(candidatoNorm));
      double score =
          distancia + distanciaFon.toDouble() * 0.75 + diferenciaLongitud * 0.5;
      if (norm.length >= 8 && distancia >= 3) score += 1.0;

      ranking.add({
        'candidato': candidato,
        'norm': candidatoNorm,
        'score': score,
        'distancia': distancia,
        'distancia_literal': distanciaLiteral,
        'distancia_fonetica': distanciaFon,
      });
    }

    if (ranking.isEmpty) {
      _registrarDiagnosticoPalabra(
        token: original,
        tokenNormalizado: norm,
        decision: 'RECHAZAR_CORRECCION',
        motivo: 'SIN_CANDIDATOS_QUE_SUPEREN_FILTROS',
      );
      return original;
    }
    ranking.sort((a, b) => (a['score'] as double).compareTo(b['score'] as double));

    final mejorDato = ranking.first;
    final String mejor = mejorDato['candidato'] as String;
    final double mejorScore = mejorDato['score'] as double;
    final int mejorDistLiteral = mejorDato['distancia_literal'] as int;
    final double mejorDistPonderada = mejorDato['distancia'] as double;
    final double segundoMejorScore =
        ranking.length > 1 ? ranking[1]['score'] as double : double.infinity;

    if (mejorScore > 2.5) {
      _registrarDiagnosticoPalabra(
        token: original,
        tokenNormalizado: norm,
        decision: 'RECHAZAR_CORRECCION',
        motivo: 'MEJOR_SCORE_SUPERIOR_A_2_5',
        ranking: ranking,
      );
      return original;
    }

    // 3) CORRECCIÓN DE DISTANCIA 1 DE ALTA CONFIANZA.
    // Para tokens de 4 o más caracteres, una única inserción, borrado o
    // sustitución (p. ej. "mnundo" → "mundo") puede aceptarse aunque la
    // diferencia entre los dos mejores scores sea algo menor que antes.
    // Se mantiene un margen mínimo para evitar decisiones ambiguas.
    final bool distanciaUnoAltaConfianza =
        norm.length >= 4 &&
        mejorDistLiteral == 1 &&
        mejorDistPonderada <= 1.0 &&
        (!segundoMejorScore.isFinite || segundoMejorScore - mejorScore >= 0.25);

    final bool candidatoNoAmbiguo =
        !segundoMejorScore.isFinite || (segundoMejorScore - mejorScore) >= 0.50;

    if (!distanciaUnoAltaConfianza && !candidatoNoAmbiguo) {
      _registrarDiagnosticoPalabra(
        token: original,
        tokenNormalizado: norm,
        decision: 'RECHAZAR_CORRECCION',
        motivo: 'CANDIDATOS_AMBIGUOS_MARGEN_INSUFICIENTE',
        ranking: ranking,
      );
      return original;
    }

    final salida = _conservarMayusculas(original, mejor);
    final clave = _claveCambioCorreccion(original, salida);
    _mecanismoCorreccionPorCambio[clave] = distanciaUnoAltaConfianza
        ? 'LEVENSHTEIN_DISTANCIA_1_ALTA_CONFIANZA'
        : (diccionarioAdaptativo.contains(mejor)
            ? 'DICCIONARIO_ADAPTATIVO'
            : 'DICCIONARIO_ES_FONETICA');
    _candidatosCorreccionPorCambio[clave] = ranking
        .take(3)
        .map((r) =>
            '${r['candidato']}|score=${(r['score'] as double).toStringAsFixed(2)}|d=${r['distancia_literal']}')
        .toList();

    _registrarDiagnosticoPalabra(
      token: original,
      tokenNormalizado: norm,
      decision: 'CORREGIR',
      motivo: _mecanismoCorreccionPorCambio[clave] ?? 'CORRECCION_ACEPTADA',
      salida: salida,
      ranking: ranking,
    );

    debugPrint(
      'CORRECCIÓN OCR: "$original" → "$mejor" '
      '(score=${mejorScore.toStringAsFixed(2)}, '
      'distancia=$mejorDistLiteral, '
      'mecanismo=${_mecanismoCorreccionPorCambio[clave]})',
    );
    return salida;
  }

  // Conserva mayúscula inicial si el OCR recibió una palabra capitalizada.
  String _conservarMayusculas(String original, String corregida) {
    if (original.isNotEmpty && original[0] == original[0].toUpperCase()) {
      if (corregida.isEmpty) return corregida;
      return corregida[0].toUpperCase() + corregida.substring(1);
    }
    return corregida;
  }

  // ================= CORRECCIÓN DE TEXTO =================
  String corregirTexto(String texto) {
    // v2.3.1 mantiene el procesamiento del token completo. En v2.2 la expresión exclusivamente
    // alfabética podía extraer "UDAS" del interior de "A9UDAS" y generar
    // sustituciones parciales como A9Unas.
    final resultado = texto.replaceAllMapped(
      RegExp(r'[A-Za-zÁÉÍÓÚáéíóúñÑÜüÀÈÌÒÙàèìòù0-9]+%?'),
      (match) {
        final token = match.group(0)!;

        if (RegExp(r'\d').hasMatch(token) || token.endsWith('%')) {
          final corregido = _normalizarTokenAlfanumericoOCR(token);
          debugPrint('TOKEN OCR: [$token] -> [$corregido]');
          return corregido;
        }

        final corregido = corregirPalabra(token);
        debugPrint('PALABRA: [$token] -> [$corregido]');
        return corregido;
      },
    );

    debugPrint('========== CORRECCIÓN v2.3.1 ==========');
    debugPrint('ENTRADA: [$texto]');
    debugPrint('SALIDA : [$resultado]');

    return resultado;
  }

  // ================= RECONSTRUCCIÓN DE TOKENS =================
  String reconstruirTokensOCR(String texto) {
    if (texto.trim().isEmpty) {
      return texto;
    }

    String resultado = texto;

    // ============================================================
    // 1. TOKENS ALFANUMÉRICOS
    // ============================================================
    //
    // Ejemplos:
    //
    //     1SOBRE  -> 1 SOBRE
    //     2CAJAS  -> 2 CAJAS
    //
    // No modificamos números aislados.
    //

    resultado = resultado.replaceAllMapped(
      RegExp(r'\b(\d+)([A-Za-zÁÉÍÓÚáéíóúñÑÜü]+)\b'),
      (match) {
        final numero = match.group(1)!;
        final palabra = match.group(2)!;

        final palabraNorm = normalizar(palabra);

        // Si la palabra ya es válida, simplemente separamos
        // el número de la palabra.
        final esValida = diccionario.any((d) => normalizar(d) == palabraNorm);

        final esAdaptativa = diccionarioAdaptativo.any(
          (d) => normalizar(d) == palabraNorm,
        );

        if (esValida || esAdaptativa) {
          return '$numero $palabra';
        }

        return match.group(0)!;
      },
    );

    // ============================================================
    // 2. PALABRAS PEGADAS
    // ============================================================
    //
    // Ejemplo:
    //
    //     tazay -> taza y
    //
    // Solo aceptamos una separación si AMBAS palabras existen
    // en alguno de los diccionarios.
    //

    resultado = resultado.replaceAllMapped(
      RegExp(r'\b[A-Za-zÁÉÍÓÚáéíóúñÑÜü]{4,}\b'),
      (match) {
        final palabra = match.group(0)!;

        final normalizada = normalizar(palabra);

        // Si ya es una palabra válida, no la tocamos.
        final esValida = diccionario.any((d) => normalizar(d) == normalizada);

        final esAdaptativa = diccionarioAdaptativo.any(
          (d) => normalizar(d) == normalizada,
        );

        if (esValida || esAdaptativa) {
          return palabra;
        }

        // ----------------------------------------------------------
        // v2.3.1: recuperación conservadora de una conjunción pegada.
        // Caso observado: "sociedady" -> "sociedad y".
        // Solo se acepta si la parte izquierda ya pertenece al léxico y
        // el sufijo es una conjunción de una sola letra (y/o/e).
        // Esto evita relajar la separación general de palabras pegadas.
        // ----------------------------------------------------------
        for (final conjuncion in const <String>['y', 'o', 'e']) {
          if (normalizada.length <= conjuncion.length + 2 ||
              !normalizada.endsWith(conjuncion)) {
            continue;
          }

          final izquierdaNorm =
              normalizada.substring(0, normalizada.length - conjuncion.length);
          final izquierdaValida =
              diccionario.any((d) => normalizar(d) == izquierdaNorm) ||
              unigramas.any((d) => normalizar(d) == izquierdaNorm) ||
              diccionarioAdaptativo.any((d) => normalizar(d) == izquierdaNorm);

          if (izquierdaValida) {
            final izquierdaOriginal =
                palabra.substring(0, palabra.length - conjuncion.length);
            final salida = '$izquierdaOriginal $conjuncion';
            _trazasPraeco.add({
              'fecha': DateTime.now().toIso8601String(),
              'experimento': _experimentoTrazaActual,
              'modo_aprendizaje': modoAprendizajePraeco,
              'fase': 'reconstruccion_tokens',
              'tipo_evento': 'separacion_conjuncion_v2_3_1',
              'token_original': palabra,
              'token_final': salida,
              'mecanismo': 'PALABRA_VALIDA_MAS_CONJUNCION_PEGADA',
            });
            debugPrint('RECONSTRUCCIÓN OCR v2.3.1: "$palabra" → "$salida"');
            return salida;
          }
        }

        // ----------------------------------------------------------
        // Intentamos separar la palabra en dos partes.
        // ----------------------------------------------------------

        for (int i = 2; i <= palabra.length - 2; i++) {
          final izquierda = palabra.substring(0, i);
          final derecha = palabra.substring(i);

          final izquierdaNorm = normalizar(izquierda);
          final derechaNorm = normalizar(derecha);

          if (izquierdaNorm.isEmpty || derechaNorm.isEmpty) {
            continue;
          }

          final izquierdaValida =
              diccionario.any((d) => normalizar(d) == izquierdaNorm) ||
              diccionarioAdaptativo.any((d) => normalizar(d) == izquierdaNorm);

          final derechaValida =
              diccionario.any((d) => normalizar(d) == derechaNorm) ||
              diccionarioAdaptativo.any((d) => normalizar(d) == derechaNorm);

          if (izquierdaValida && derechaValida) {
            debugPrint(
              'RECONSTRUCCIÓN OCR: '
              '"$palabra" → "$izquierda $derecha"',
            );

            return '$izquierda $derecha';
          }
        }

        return palabra;
      },
    );

    // ============================================================
    // 3. PALABRAS SEPARADAS INCORRECTAMENTE
    // ============================================================
    //
    // Ejemplo:
    //
    //     SA BOR -> SABOR
    //
    // Buscamos pares consecutivos de palabras y comprobamos si
    // su concatenación existe en el diccionario.
    //
    // No eliminamos saltos de línea: solo trabajamos dentro de
    // cada línea.
    //

    final lineas = resultado.split('\n');

    final nuevasLineas = <String>[];

    for (final linea in lineas) {
      final tokens = linea.split(RegExp(r'(\s+)'));

      final salida = <String>[];

      int i = 0;

      while (i < tokens.length) {
        final token = tokens[i];

        // Conservamos espacios exactamente.
        if (RegExp(r'^\s+$').hasMatch(token)) {
          salida.add(token);
          i++;
          continue;
        }

        // ----------------------------------------------------------
        // Buscar el siguiente token no espacial.
        // ----------------------------------------------------------

        int siguiente = i + 1;

        while (siguiente < tokens.length &&
            RegExp(r'^\s+$').hasMatch(tokens[siguiente])) {
          siguiente++;
        }

        if (siguiente < tokens.length) {
          final segundo = tokens[siguiente];

          // Solo intentamos unir palabras.
          final primeraLimpia = limpiar(token);
          final segundaLimpia = limpiar(segundo);

          if (primeraLimpia.isNotEmpty &&
              segundaLimpia.isNotEmpty &&
              RegExp(r'^[A-Za-zÁÉÍÓÚáéíóúñÑÜü]+$').hasMatch(primeraLimpia) &&
              RegExp(r'^[A-Za-zÁÉÍÓÚáéíóúñÑÜü]+$').hasMatch(segundaLimpia)) {
            final concatenada =
                '${normalizar(primeraLimpia)}${normalizar(segundaLimpia)}';

            final candidata = diccionario.cast<String?>().firstWhere(
              (d) => d != null && normalizar(d) == concatenada,
              orElse: () => null,
            );

            if (candidata != null) {
              debugPrint(
                'RECONSTRUCCIÓN OCR: '
                '"$token $segundo" → "$candidata"',
              );

              salida.add(
                token +
                    // Conservamos el espacio posterior.
                    (siguiente < tokens.length ? '' : ''),
              );

              // Sustituimos ambos tokens por la palabra.
              salida.removeLast();
              salida.add(candidata);

              i = siguiente + 1;
              continue;
            }
          }
        }

        salida.add(token);
        i++;
      }

      nuevasLineas.add(salida.join());
    }

    resultado = nuevasLineas.join('\n');

    return resultado;
  }

  // ================= CORRECCIÓN DE CONTEXTO =================
  String corregirContexto(String texto) {
    //
    final tokens = texto.split(RegExp(r'(\s+)'));

    // Normaliza una palabra para comparar sin modificar
    // la forma original de los tokens.
    String normalizar(String s) =>
        s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

    bool esProtegido(String token) {
      final t = normalizar(token);

      if (t.isEmpty) return true;
      if (RegExp(r'\d').hasMatch(token)) return true;
      if (token.length <= 2) return true;

      return false;
    }

    // Distancia de Levenshtein.
    int distancia(String a, String b) {
      if (a.isEmpty) return b.length;
      if (b.isEmpty) return a.length;

      var anterior = List<int>.generate(b.length + 1, (i) => i);

      for (int i = 1; i <= a.length; i++) {
        final actual = List<int>.filled(b.length + 1, 0);
        actual[0] = i;

        for (int j = 1; j <= b.length; j++) {
          final coste = a[i - 1] == b[j - 1] ? 0 : 1;

          actual[j] = [
            actual[j - 1] + 1,
            anterior[j] + 1,
            anterior[j - 1] + coste,
          ].reduce((x, y) => x < y ? x : y);
        }

        anterior = actual;
      }

      return anterior[b.length];
    }

    final vocabulario = unigramas
        .map(normalizar)
        .where((s) => s.isNotEmpty)
        .toSet();

    final biSet = bigramas.map((s) => s.toLowerCase()).toSet();
    final triSet = trigramas.map((s) => s.toLowerCase()).toSet();
    final cuatriSet = cuatrigramas.map((s) => s.toLowerCase()).toSet();

    for (int i = 0; i < tokens.length; i++) {
      final original = tokens[i];

      // Conserva los espacios y la puntuación.
      if (original.trim().isEmpty || esProtegido(original)) {
        continue;
      }

      final palabra = normalizar(original);
      if (palabra.isEmpty || vocabulario.contains(palabra)) {
        continue;
      }

      // Solo se consideran candidatos con distancia pequeña.
      final candidatos = vocabulario.where((c) {
        final limite = palabra.length <= 5 ? 1 : 2;
        return (c.length - palabra.length).abs() <= limite &&
            distancia(palabra, c) <= limite;
      }).toList();

      if (candidatos.isEmpty) continue;

      String mejor = palabra;
      double mejorPuntuacion = -1;

      for (final candidato in candidatos) {
        double puntuacion = 0;

        // Evidencia ortográfica.
        final maxLongitud = palabra.length > candidato.length
            ? palabra.length
            : candidato.length;

        puntuacion += maxLongitud == 0
            ? 0
            : 1 - distancia(palabra, candidato) / maxLongitud;

        // Evidencia contextual: se consulta el vocabulario
        // de secuencias que contienen la palabra candidata.
        final izquierda = i > 0 ? normalizar(tokens[i - 1]) : '';
        final derecha = i + 1 < tokens.length ? normalizar(tokens[i + 1]) : '';

        if (izquierda.isNotEmpty && biSet.contains('$izquierda $candidato')) {
          puntuacion += 0.5;
        }

        if (derecha.isNotEmpty && biSet.contains('$candidato $derecha')) {
          puntuacion += 0.5;
        }

        if (i >= 2) {
          final p2 = normalizar(tokens[i - 2]);
          if (p2.isNotEmpty && triSet.contains('$p2 $izquierda $candidato')) {
            puntuacion += 1.0;
          }
        }

        if (i >= 3) {
          final p3 = normalizar(tokens[i - 3]);
          final p2 = normalizar(tokens[i - 2]);

          if (p3.isNotEmpty &&
              p2.isNotEmpty &&
              cuatriSet.contains('$p3 $p2 $izquierda $candidato')) {
            puntuacion += 1.5;
          }
        }

        if (puntuacion > mejorPuntuacion) {
          mejorPuntuacion = puntuacion;
          mejor = candidato;
        }
      }

      // Exige una evidencia contextual mínima antes de sustituir.
      if (mejor != palabra && mejorPuntuacion >= 1.5) {
        tokens[i] = original.replaceFirst(
          RegExp(RegExp.escape(original.trim()), caseSensitive: false),
          mejor,
        );
      }
    }

    return tokens.join(' ');
  }

  // ================ FILTRAR TEXTO OCR =================

  Future<String> filtrarTextoOCR(String texto) async {
    final lineas = texto.split(RegExp(r'\r?\n'));

    final List<String> resultado = [];

    for (String linea in lineas) {
      String s = linea.trim();

      if (s.isEmpty) {
        continue;
      }

      // ---------------------------------------------------------
      // 1. Eliminar URLs
      // ---------------------------------------------------------
      if (RegExp(r'^(https?:\/\/|www\.)', caseSensitive: false).hasMatch(s)) {
        continue;
      }

      // ---------------------------------------------------------
      // 2. Eliminar cadenas que sean solamente números
      //    Ejemplos: 123456, 2026, 012345
      // ---------------------------------------------------------
      if (RegExp(r'^\d+$').hasMatch(s)) {
        continue;
      }

      // ---------------------------------------------------------
      // 3. Eliminar códigos numéricos largos
      //    Pero NO eliminar líneas que contengan letras.
      // ---------------------------------------------------------
      if (RegExp(r'^\d{8,}$').hasMatch(s)) {
        continue;
      }

      // ---------------------------------------------------------
      // 4. Eliminar códigos de barras / lotes evidentes
      // ---------------------------------------------------------
      if (RegExp(
        r'^(lote|lot|batch)[\s:\-]*[A-Z0-9\-]+$',
        caseSensitive: false,
      ).hasMatch(s)) {
        continue;
      }

      // ---------------------------------------------------------
      // 5. Eliminar pesos/cantidades claramente identificados
      //    Ejemplos:
      //      500 g
      //      1 kg
      //      250 ml
      //      1,5 L
      //      20 %
      //
      //    IMPORTANTE:
      //    Solo eliminamos la línea si ES exclusivamente
      //    una cantidad.
      // ---------------------------------------------------------
      if (RegExp(
        r'^\d+(?:[.,]\d+)?\s*(g|kg|mg|ml|cl|dl|l|oz|lb|%|gr)$',
        caseSensitive: false,
      ).hasMatch(s)) {
        continue;
      }

      // ---------------------------------------------------------
      // 6. Eliminar palabras claramente relacionadas con reciclaje
      //    SOLO si la línea contiene exclusivamente esa palabra.
      // ---------------------------------------------------------
      final basura = {
        'recicla',
        'reciclaje',
        'separa',
        'separar',
        'contenedor',
      };

      final normalizada = normalizar(s);

      if (basura.contains(normalizada)) {
        continue;
      }

      // ---------------------------------------------------------
      // 7. NO eliminar palabras cortas.
      //
      //    Esto es MUY IMPORTANTE.
      //
      //    DON
      //    EL
      //    EN
      //    SIMON
      //    LA
      //    DE
      //
      //    pueden formar parte del texto real.
      // ---------------------------------------------------------

      // ---------------------------------------------------------
      // 8. NO eliminar nombres propios.
      // ---------------------------------------------------------

      // ---------------------------------------------------------
      // 9. Mantener cualquier línea que contenga letras.
      // ---------------------------------------------------------
      if (RegExp(r'[A-Za-zÁÉÍÓÚáéíóúñÑÜü]').hasMatch(s)) {
        resultado.add(s);
      }
    }

    return resultado.join('\n');
  }

  // ================= DICCIONARIO =================
  Future<void> cargarDiccionario() async {
    //
    final data = await rootBundle.loadString('assets/diccionario_es.json');
    diccionario = List<String>.from(jsonDecode(data));
  }

  // ==========@====== N-GRAMAS =================
  Future<void> cargarNGramas() async {
    final data = await rootBundle.loadString('assets/ngramas_alimentos.json');
    final jsonData = jsonDecode(data);
    unigramas = List<String>.from(jsonData["unigramas"]);
    bigramas = List<String>.from(jsonData["bigramas"]);
    trigramas = List<String>.from(jsonData["trigramas"]);
    cuatrigramas = List<String>.from(jsonData["cuatrigramas"]);
  }

  // ================= ALÉRGENOS =================
  // Se usa la detección robusta global (14 alérgenos UE, tolerante a OCR).
  // Devuelve "contiene" + "trazas" en una sola lista para mantener la firma.
  ResultadoAlergenos _ultimosAlergenos = const ResultadoAlergenos([], []);

  List<String> detectarAlergenos(String texto) {
    _ultimosAlergenos = detectarAlergenosRobusto(texto);
    return [..._ultimosAlergenos.contiene, ..._ultimosAlergenos.trazas];
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
    await cargarNGramas();
    await cargarErroresOCR();
    await cargarDiccionarioAdaptativo();

    // En modo aprendizaje se incorporan al diccionario adaptativo únicamente
    // las asociaciones previamente aprendidas que ya alcanzan el umbral.
    // En modo evaluación/ablación los ficheros quedan congelados.
    if (modoAprendizajePraeco) {
      await integrarErroresEnDiccionario();
    } else {
      debugPrint('PRAECO: modo evaluación/ablación; aprendizaje congelado.');
    }
    await _procesar();
  }

  Future<void> _procesar() async {
    final sw = Stopwatch();

    // 1. OCR
    sw.start();
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);

    // 1a. OCR sobre la imagen preprocesada (si existe).
    RecognizedText? result;
    double puntuacion = -1;
    String origenOCR = 'original';
    if (widget.imagePathPre != null) {
      try {
        final rPre = await recognizer.processImage(
          InputImage.fromFilePath(widget.imagePathPre!),
        );
        result = rPre;
        puntuacion = puntuarTextoOCR(rPre.text);
        origenOCR = 'preprocesada';
        debugPrint(
          'OCR preprocesada: puntuación=${puntuacion.toStringAsFixed(3)}',
        );
      } catch (e) {
        debugPrint('OCR sobre la imagen preprocesada falló: $e');
      }
    }

    // 1b. Si el preprocesado no ayuda (o no existe), OCR sobre la recortada
    //     original y nos quedamos con el texto que mejor puntúa.
    if (result == null ||
        puntuacion <
            widget.puntuacionCaptura - ConfigCaptura.margenPreprocesado) {
      final rOrig = await recognizer.processImage(
        InputImage.fromFilePath(widget.imagePath),
      );
      final pOrig = puntuarTextoOCR(rOrig.text);
      debugPrint('OCR original: puntuación=${pOrig.toStringAsFixed(3)}');
      if (result == null || pOrig >= puntuacion) {
        result = rOrig;
        puntuacion = pOrig;
        origenOCR = 'original';
      }
    }
    MetricasRendimiento.puntuacionOCRFinal = puntuacion;
    MetricasRendimiento.origenOCR = origenOCR;
    debugPrint('OCR elegido: $origenOCR (${puntuacion.toStringAsFixed(3)})');

    // OCR bruto (texto completo, para trazabilidad y evaluación)
    ultimoOCRBruto = result.text.isEmpty ? "No hay texto" : result.text;
    // Zona de ingredientes (si está activada y se localiza)
    final String textoZona = ConfigCaptura.usarZonaIngredientes
        ? extraerZonaIngredientes(result)
        : result.text;
    // OCR filtrado + normalización de caracteres OCR
    ultimoOCROriginal = normalizarOCR(
      await filtrarTextoOCR(textoZona.isEmpty ? ultimoOCRBruto : textoZona),
    );
    sw.stop();
    MetricasRendimiento.ocr = sw.elapsedMilliseconds;
    sw.reset();

    // 2. CORRECCIÓN
    sw.start();
    _trazasPraeco.clear();
    _mecanismoCorreccionPorCambio.clear();
    _candidatosCorreccionPorCambio.clear();
    _experimentoTrazaActual = widget.idExperimento.toString();
    final String entradaLexica = ultimoOCROriginal;
    // Corrección diccionario (algoritmo original, sin cambios).
    String textoCorregido = corregirTexto(entradaLexica);
    registrarDiferenciasEtapa(
      experimento: widget.idExperimento.toString(),
      fase: 'correccion_lexica',
      entrada: entradaLexica,
      salida: textoCorregido,
    );
    // Corrección por contexto (algoritmo original, sin cambios).
    final String entradaContexto = textoCorregido;
    textoCorregido = corregirContexto(entradaContexto);
    registrarDiferenciasEtapa(
      experimento: widget.idExperimento.toString(),
      fase: 'correccion_contextual',
      entrada: entradaContexto,
      salida: textoCorregido,
    );
    ultimoOCRCorregido = textoCorregido;
    await guardarTrazabilidadPraeco(widget.idExperimento.toString());
    sw.stop();
    MetricasRendimiento.correccion = sw.elapsedMilliseconds;
    sw.reset();

    // 3. ALÉRGENOS
    sw.start();

    final alerg = detectarAlergenos(textoCorregido);

    sw.stop();

    // Medición con mayor resolución.
    // Se redondea hacia arriba para evitar registrar 0 ms.
    MetricasRendimiento.alergenos = (sw.elapsedMicroseconds / 1000).ceil();

    debugPrint(
      'Tiempo detección alérgenos: '
      '${sw.elapsedMicroseconds} µs '
      '(${MetricasRendimiento.alergenos} ms)',
    );

    sw.reset();

    // no lee ---String mensaje = alerg.isNotEmpty
    // no lee ---    ? "Atención contiene ${alerg.join(", ")}"
    // no lee ---    : "No se detectan alérgenos";

    // no lee ---setState(() {
    // no lee ---  _resultado = "$mensaje\n\n$textoCorregido";
    // no lee ---});

    // no lee --- await _tts.speak(mensaje);
    // no lee ---await _tts.speak(textoCorregido);

    String mensaje;
    if (_ultimosAlergenos.vacio) {
      mensaje = "No se detectan alérgenos.";
    } else {
      final partes = <String>[];
      if (_ultimosAlergenos.contiene.isNotEmpty) {
        partes.add("contiene ${_ultimosAlergenos.contiene.join(", ")}");
      }
      if (_ultimosAlergenos.trazas.isNotEmpty) {
        partes.add(
          "puede contener trazas de ${_ultimosAlergenos.trazas.join(", ")}",
        );
      }
      mensaje = "Atención: ${partes.join(". ")}.";
    }
    // alerg se mantiene por compatibilidad (lista completa).
    debugPrint('Alérgenos detectados: $alerg');

    final textoLectura = "$mensaje. $textoCorregido";

    setState(() {
      _resultado = "$mensaje\n\n$textoCorregido";
    });

    await _tts.stop();
    await _tts.speak(textoLectura);

    recognizer.close();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Resultado")),
      body: Column(
        children: [
          SizedBox(
            height: 250,
            child: Image.file(
              File(
                MetricasRendimiento.origenOCR == 'preprocesada' &&
                        widget.imagePathPre != null
                    ? widget.imagePathPre!
                    : widget.imagePath,
              ),
              fit: BoxFit.contain,
            ),
          ),

          Expanded(
            child: Card(
              margin: const EdgeInsets.all(10),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: SelectableText(
                  _resultado,
                  style: const TextStyle(fontSize: 18, height: 1.5),
                ),
              ),
            ),
          ),

          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: realController,
              maxLines: 4,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: "Texto real (Ground Truth)",
              ),
            ),
          ),

          ElevatedButton.icon(
            onPressed: guardarEvaluacion,
            icon: const Icon(Icons.science),
            label: const Text("GUARDAR EXPERIMENTO"),
          ),

          ElevatedButton.icon(
            onPressed: () => _tts.speak(_resultado),
            icon: const Icon(Icons.volume_up),
            label: const Text("REPETIR LECTURA"),
          ),
        ],
      ),
    );
  }

  double calcularCER(String real, String pred) {
    real = normalizarWER(real);
    pred = normalizarWER(pred);
    return dist(real, pred) / max(real.length, 1); // evitar división por cero
  }

  double calcularWER(String real, String pred) {
    real = normalizarWER(real);
    pred = normalizarWER(pred);
    List<String> r = real.split(
      RegExp(r'\s+'),
    ); // dividir en palabras usando espacios como separadores
    List<String> p = pred.split(RegExp(r'\s+'));

    int m = r.length;
    int n = p.length;

    List<List<int>> dp = List.generate(m + 1, (_) => List.filled(n + 1, 0));

    for (int i = 0; i <= m; i++) {
      dp[i][0] = i;
    }

    for (int j = 0; j <= n; j++) {
      dp[0][j] = j;
    }

    for (int i = 1; i <= m; i++) {
      for (int j = 1; j <= n; j++) {
        int cost = r[i - 1] == p[j - 1] ? 0 : 1;

        dp[i][j] = [
          dp[i - 1][j] + 1,
          dp[i][j - 1] + 1,
          dp[i - 1][j - 1] + cost,
        ].reduce(min);
      }
    }

    return dp[m][n] / max(m, 1);
  }

  Future<void> guardarEvaluacion() async {
    if (_experimentoGuardado) {
      return;
    }
    String textoReal = realController.text.trim();

    if (textoReal.isEmpty) {
      return;
    }

    String ocrOriginal = ultimoOCROriginal;
    String ocrCorregido = ultimoOCRCorregido;

    String textoRealNorm = normalizarWER(textoReal);

    String ocrOriginalNorm = normalizarWER(ocrOriginal);

    String ocrCorregidoNorm = normalizarWER(ocrCorregido);

    double cerOCR = calcularCER(textoRealNorm, ocrOriginalNorm);

    double cerCorregido = calcularCER(textoRealNorm, ocrCorregidoNorm);

    double werOCR = calcularWER(textoRealNorm, ocrOriginalNorm);

    double werCorregido = calcularWER(textoRealNorm, ocrCorregidoNorm);

    // final carpeta = await obtenerCarpetaTFM();
    // final nombre = DateTime.now().millisecondsSinceEpoch;

    final carpeta = await obtenerCarpetaTFM();

    final archivoOCR = File('${carpeta.path}/${widget.idExperimento}_ocr.txt');

    final archivoOCRCorregido = File(
      '${carpeta.path}/${widget.idExperimento}_ocr_corregido.txt',
    );

    await archivoOCR.writeAsString(ultimoOCROriginal, mode: FileMode.write);

    await archivoOCRCorregido.writeAsString(
      ultimoOCRCorregido,
      mode: FileMode.write,
    );

    final datos = {
      "fecha": DateTime.now().toIso8601String(),
      "imagen": widget.imagePath,
      "calidad_imagen": {
        "ancho": widget.calidadImagen.ancho,
        "alto": widget.calidadImagen.alto,
        "nitidez": widget.calidadImagen.nitidez,
        "brillo": widget.calidadImagen.brillo,
        "contraste": widget.calidadImagen.contraste,
        "aceptable": widget.calidadImagen.aceptable,
        "motivos": widget.calidadImagen.motivos,
        "decision": widget.decisionCalidad,
      },
      "modo_aprendizaje": modoAprendizajePraeco,
      "texto_real": textoReal, // GUARDAR TEXTO REAL
      "ocr_bruto": ultimoOCRBruto, // GUARDAR TEXTO BRUTO
      "ocr_original": ocrOriginal, // GUARDAR TEXTO ORIGINAL
      "ocr_corregido": ocrCorregido, // GUARDAR TEXTO CORREGIDO
      "cer_ocr": cerOCR, // GUARDAR CER ORIGINAL
      "cer_corregido": cerCorregido, // GUARDAR CER CORREGIDO
      "wer_ocr": werOCR, // GUARDAR WER ORIGINAL
      "wer_corregido": werCorregido, // GUARDAR WER CORREGIDO
      "ocr_disparos_rafaga": MetricasRendimiento.disparos,
      "ocr_puntuacion_captura": MetricasRendimiento.puntuacionCaptura,
      "ocr_puntuacion_final": MetricasRendimiento.puntuacionOCRFinal,
      "ocr_origen_imagen": MetricasRendimiento.origenOCR,
      "alergenos_contiene": _ultimosAlergenos.contiene,
      "alergenos_trazas": _ultimosAlergenos.trazas,
      "tiempo_captura_ms": MetricasRendimiento.captura,
      "tiempo_ocr_ms": MetricasRendimiento.ocr,
      "tiempo_correccion_ms": MetricasRendimiento.correccion,
      "tiempo_alergenos_ms": MetricasRendimiento.alergenos,
      "tiempo_total_ms":
          MetricasRendimiento.captura +
          MetricasRendimiento.ocr +
          MetricasRendimiento.correccion +
          MetricasRendimiento.alergenos,
    };

    final archivoJSON = File('${carpeta.path}/${widget.idExperimento}.json');

    await archivoJSON.writeAsString(
      const JsonEncoder.withIndent('  ').convert(datos),
      mode: FileMode.write,
    );

    await EvaluacionOCR.guardarExperimento(
      imagen: widget.imagePath,
      textoReal: textoReal,
      ocr: ocrOriginal,
      corregido: ocrCorregido,
      cerOCR: cerOCR,
      cerCorregido: cerCorregido,
      werOCR: werOCR,
      werCorregido: werCorregido,
      tiempoCaptura: MetricasRendimiento.captura,
      tiempoOCR: MetricasRendimiento.ocr,
      tiempoCorreccion: MetricasRendimiento.correccion,
      tiempoAlergenos: MetricasRendimiento.alergenos,
      calidadImagen: widget.calidadImagen,
      decisionCalidad: widget.decisionCalidad,
      modoAprendizaje: modoAprendizajePraeco,
    );

    if (!mounted) return;

    // El ground truth solo se usa para aprender cuando este modo está
    // explícitamente activado. En evaluación/ablación no se modifica ningún
    // fichero de aprendizaje, evitando fuga de información entre muestras.
    if (modoAprendizajePraeco) {
      await aprenderErroresOCR(textoReal, ocrOriginal);
      await integrarErroresEnDiccionario();
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text("Experimento guardado")));
    _experimentoGuardado = true;
  }

  // ================ APRENDER ERRORES OCR =================
  // Aprende únicamente pares de palabras alineados por posición mediante
  // programación dinámica. No busca la palabra más parecida en todo el texto,
  // porque eso crea asociaciones falsas entre palabras no relacionadas.
  Future<void> aprenderErroresOCR(String textoReal, String ocr) async {
    List<String> tokens(String texto) => normalizarWER(texto)
        .split(RegExp(r'\s+'))
        .map((p) => limpiar(p))
        .where((p) => p.isNotEmpty)
        .toList();

    final real = tokens(textoReal);
    final detectado = tokens(ocr);
    if (real.isEmpty || detectado.isEmpty) return;

    final n = detectado.length;
    final m = real.length;
    final dp = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
    final paso = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));

    for (var i = 1; i <= n; i++) {
      dp[i][0] = i;
      paso[i][0] = 1; // token OCR extra
    }
    for (var j = 1; j <= m; j++) {
      dp[0][j] = j;
      paso[0][j] = 2; // token real omitido por OCR
    }

    for (var i = 1; i <= n; i++) {
      for (var j = 1; j <= m; j++) {
        final sustitucion =
            dp[i - 1][j - 1] + (detectado[i - 1] == real[j - 1] ? 0 : 1);
        final borrado = dp[i - 1][j] + 1;
        final insercion = dp[i][j - 1] + 1;
        var mejor = sustitucion;
        var accion = 3; // alineación token-token
        if (borrado < mejor) {
          mejor = borrado;
          accion = 1;
        }
        if (insercion < mejor) {
          mejor = insercion;
          accion = 2;
        }
        dp[i][j] = mejor;
        paso[i][j] = accion;
      }
    }

    final pares = <List<String>>[];
    var i = n;
    var j = m;
    while (i > 0 || j > 0) {
      if (i > 0 && j > 0 && paso[i][j] == 3) {
        pares.add([detectado[i - 1], real[j - 1]]);
        i--;
        j--;
      } else if (i > 0 && (j == 0 || paso[i][j] == 1)) {
        i--;
      } else if (j > 0) {
        j--;
      } else {
        break;
      }
    }

    for (final par in pares.reversed) {
      final palabraOCR = par[0];
      final palabraReal = par[1];
      if (palabraOCR == palabraReal ||
          palabraOCR.length < 3 ||
          palabraReal.length < 3)
        continue;
      if (stopWords.contains(palabraOCR) ||
          stopWords.contains(palabraReal) ||
          esNumero(palabraOCR) ||
          esNumero(palabraReal))
        continue;

      // Solo registrar errores cercanos. Se exige también una proporción
      // razonable de cambios para no asociar palabras semánticamente distintas.
      final d = dist(palabraOCR, palabraReal);
      final distanciaMaxima = palabraOCR.length <= 5
          ? 1
          : (palabraOCR.length <= 8 ? 2 : 3);
      if (d == 0 || d > distanciaMaxima || d / palabraOCR.length > 0.30) {
        continue;
      }

      final clave = normalizar(limpiar(palabraOCR));
      final correcta = normalizar(limpiar(palabraReal));
      if (clave.isEmpty || correcta.isEmpty) continue;

      final existente = erroresOCR[clave];
      if (existente is Map) {
        final correctaAnterior = existente['correcta'];
        final correctaAnteriorNorm = correctaAnterior is String
            ? normalizar(limpiar(correctaAnterior))
            : '';
        if (correctaAnteriorNorm == correcta) {
          final frecuencia = existente['frecuencia'];
          existente['frecuencia'] =
              (frecuencia is num ? frecuencia.toInt() : 0) + 1;
          existente['validado'] = true;
        } else {
          // No cambiar automáticamente una asociación ya aprendida con otra
          // palabra: eliminar el conflicto y esperar nueva evidencia consistente.
          existente['conflicto'] = true;
          existente['validado'] = false;
          existente['alternativa'] = correcta;
          existente['frecuencia_alternativa'] =
              ((existente['frecuencia_alternativa'] is num)
                  ? (existente['frecuencia_alternativa'] as num).toInt()
                  : 0) +
              1;
          continue;
        }
      } else {
        erroresOCR[clave] = {
          'correcta': correcta,
          'frecuencia': 1,
          'validado': true,
        };
      }
    }

    await guardarErroresOCR();
  }

  // ================= GUARDAR ERRORES OCR =================

  Future<void> guardarErroresOCR() async {
    final carpeta = await obtenerCarpetaTFM();

    final fichero = File('${carpeta.path}/errores_ocr.json');

    await fichero.writeAsString(
      const JsonEncoder.withIndent(" ").convert(erroresOCR),
    );
  }

  // ================= STOP WORDS =================

  static const Set<String> stopWords = {
    "de",
    "la",
    "el",
    "en",
    "un",
    "una",
    "y",
    "o",
    "es",
    "al",
    "del",
    "los",
    "las",
    "por",
    "con",
    "sin",
    "que",
    "para",
    "se",
    "su",
  };

  // ================= NUMEROS =================

  bool esNumero(String texto) {
    return RegExp(r'^\d+$').hasMatch(texto);
  }

  // CARGAR DICCIONARIO ADAPTATIVO
  Future<void> cargarDiccionarioAdaptativo() async {
    final carpeta = await obtenerCarpetaTFM();

    final fichero = File('${carpeta.path}/diccionario_adaptativo.json');

    if (await fichero.exists()) {
      diccionarioAdaptativo = Set<String>.from(
        jsonDecode(await fichero.readAsString()),
      );
    }
  }

  // GUARDAR DICCIONARIO ADAPTATIVO
  Future<void> guardarDiccionarioAdaptativo() async {
    final carpeta = await obtenerCarpetaTFM();

    final fichero = File('${carpeta.path}/diccionario_adaptativo.json');

    await fichero.writeAsString(
      const JsonEncoder.withIndent(" ").convert(diccionarioAdaptativo.toList()),
    );
  }

  Future<void> integrarErroresEnDiccionario() async {
    if (!modoAprendizajePraeco) return;

    erroresOCR.forEach((error, info) {
      if (info is! Map) return;

      final frecuencia = info["frecuencia"];
      final correcta = info["correcta"];
      final validado = info["validado"];
      final conflicto = info["conflicto"];

      // Solo se integran asociaciones suficientemente repetidas, válidas y
      // sin conflicto. Así se evita contaminar el léxico adaptativo.
      if (frecuencia is num &&
          frecuencia.toInt() >= 3 &&
          correcta is String &&
          correcta.trim().isNotEmpty &&
          validado != false &&
          conflicto != true) {
        diccionarioAdaptativo.add(correcta);
      }
    });

    await guardarDiccionarioAdaptativo();
  }
}
