// TFM: Asistente para personas con discapacidad visual
// Fco Javier López López
// Fecha base: 2026-10-22


import 'dart:convert';
import 'dart:math' as math;

import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const PraecoAnalisisApp());
}

class PraecoAnalisisApp extends StatelessWidget {
  const PraecoAnalisisApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PraecoAnalisis',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
      ),
      home: const AnalisisPage(),
    );
  }
}

class CsvAnalysis {
  CsvAnalysis({
    required this.fileName,
    required this.columns,
    required this.rows,
    required this.summary,
    required this.generatedAt,
  });

  final String fileName;
  final List<String> columns;
  final List<Map<String, String>> rows;
  final Map<String, dynamic> summary;
  final String generatedAt;

  Map<String, dynamic> toJson() {
    return {
      'aplicacion': 'PraecoAnalisis',
      'version': '2.3.1',
      'fecha_analisis': generatedAt,
      'archivo_csv': fileName,
      'estructura': {
        'n_columnas': columns.length,
        'columnas': columns,
        'n_registros': rows.length,
      },
      'resumen': summary,
      'registros': rows,
    };
  }
}

class _PreparedCsv {
  _PreparedCsv(this.columns, this.rows);

  final List<String> columns;
  final List<Map<String, String>> rows;
}

class AnalisisPage extends StatefulWidget {
  const AnalisisPage({super.key});

  @override
  State<AnalisisPage> createState() => _AnalisisPageState();
}

class _AnalisisPageState extends State<AnalisisPage> {
  CsvAnalysis? analysis;
  bool busy = false;
  int selectedTab = 0;
  String status = 'Selecciona el CSV de experimentos de Praeco.';
  String? error;

  Future<void> seleccionarCsv() async {
    setState(() {
      busy = true;
      error = null;
      status = 'Seleccionando CSV...';
    });

    try {
      final PlatformFile? file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['csv'],
      );

      if (file == null) {
        setState(() {
          busy = false;
          status = 'Selección cancelada.';
        });
        return;
      }

      status = 'Leyendo ${file.name}...';
      if (mounted) setState(() {});

      final bytes = await file.readAsBytes();
      final text = _decodeBytes(bytes);
      final decodedRows = csv.decode(text);

      if (decodedRows.isEmpty) {
        throw Exception('El CSV está vacío.');
      }

      final prepared = _prepareRows(decodedRows);
      if (prepared.columns.isEmpty || prepared.rows.isEmpty) {
        throw Exception(
          'No se ha encontrado una cabecera y al menos un registro válido.',
        );
      }

      final summary = _calculateSummary(
        prepared.columns,
        prepared.rows,
      );

      final created = CsvAnalysis(
        fileName: file.name,
        columns: prepared.columns,
        rows: prepared.rows,
        summary: summary,
        generatedAt: DateTime.now().toIso8601String(),
      );

      setState(() {
        analysis = created;
        selectedTab = 0;
        busy = false;
        status =
            'CSV cargado: ${created.rows.length} registros, '
            '${created.columns.length} columnas.';
      });
    } catch (e) {
      setState(() {
        busy = false;
        error = e.toString();
        status = 'No se ha podido leer el CSV.';
      });
    }
  }

  Future<void> generarJson() async {
    final current = analysis;
    if (current == null) return;

    try {
      final jsonText = const JsonEncoder.withIndent('  ').convert(
        current.toJson(),
      );
      final outputName =
          '${_withoutExtension(current.fileName)}_analisis.json';

      final output = await FilePicker.saveFile(
        dialogTitle: 'Guardar resultados JSON',
        fileName: outputName,
        mimeType: 'application/json',
        bytes: utf8.encode(jsonText),
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (!mounted) return;
      if (output == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Guardado cancelado.')),
        );
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('JSON generado en: $output')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error al generar el JSON: $e')),
      );
    }
  }

  String _decodeBytes(List<int> bytes) {
    var data = bytes;
    if (data.length >= 3 &&
        data[0] == 0xEF &&
        data[1] == 0xBB &&
        data[2] == 0xBF) {
      data = data.sublist(3);
    }

    try {
      return utf8.decode(data);
    } catch (_) {
      return latin1.decode(data, allowInvalid: true);
    }
  }

  _PreparedCsv _prepareRows(List<List<dynamic>> decoded) {
    final rawHeader = decoded.first
        .map((value) => _cleanCell(value.toString()))
        .toList();

    final columns = <String>[];
    final counts = <String, int>{};

    for (var i = 0; i < rawHeader.length; i++) {
      var name = rawHeader[i].trim();
      if (name.isEmpty) name = 'columna_${i + 1}';

      final currentCount = counts[name] ?? 0;
      counts[name] = currentCount + 1;
      if (currentCount > 0) name = '${name}_$currentCount';
      columns.add(name);
    }

    final rows = <Map<String, String>>[];
    for (var rowIndex = 1; rowIndex < decoded.length; rowIndex++) {
      final source = decoded[rowIndex];
      final isEmpty = source.every((cell) => cell.toString().trim().isEmpty);
      if (isEmpty) continue;

      final row = <String, String>{};
      for (var i = 0; i < columns.length; i++) {
        final value = i < source.length ? source[i].toString() : '';
        row[columns[i]] = _cleanCell(value);
      }
      rows.add(row);
    }

    return _PreparedCsv(columns, rows);
  }

  String _cleanCell(String value) {
    var text = value.trim();
    text = _repairMojibake(text);
    return text;
  }

  String _repairMojibake(String value) {
    // El CSV mostrado contiene texto UTF-8 que en algún momento se interpretó
    // como Windows-1252/Latin-1, de ahí secuencias como "cafÃ©".
    var fixed = value;
    const replacements = <String, String>{
      'Ã¡': 'á',
      'Ã©': 'é',
      'Ã­': 'í',
      'Ã³': 'ó',
      'Ãº': 'ú',
      'Ã±': 'ñ',
      'Ã': 'Á',
      'Ã‰': 'É',
      'Ã': 'Í',
      'Ã“': 'Ó',
      'Ãš': 'Ú',
      'Ã‘': 'Ñ',
      'Ãœ': 'Ü',
      'Ã¼': 'ü',
      'Ã—': '×',
      'Â¿': '¿',
      'Â¡': '¡',
      'Â©': '©',
      'Â®': '®',
      'Â°': '°',
      'Â·': '·',
      'Â': '',
      'â€œ': '“',
      'â€': '”',
      'â€™': '’',
      'â€“': '–',
      'â€”': '—',
      'â€¦': '…',
      'â‚¬': '€',
    };

    for (final entry in replacements.entries) {
      fixed = fixed.replaceAll(entry.key, entry.value);
    }

    // Segundo intento para secuencias UTF-8 mal decodificadas en Latin-1.
    if (RegExp(r'[ÃÂ]').hasMatch(fixed)) {
      try {
        final candidate = utf8.decode(latin1.encode(fixed));
        if (candidate != fixed) fixed = candidate;
      } catch (_) {
        // Se conserva el texto ya parcialmente reparado.
      }
    }

    return fixed;
  }

  Map<String, dynamic> _calculateSummary(
    List<String> columns,
    List<Map<String, String>> rows,
  ) {
    final numericStats = <String, dynamic>{};
    for (final column in columns) {
      final values = <double>[];
      for (final row in rows) {
        final value = _toDouble(row[column] ?? '');
        if (value != null && value.isFinite) values.add(value);
      }
      if (values.isNotEmpty) numericStats[column] = _statistics(values);
    }

    final cerOcr = _findColumn(columns, 'cer_ocr');
    final cerCorrected = _findColumn(columns, 'cer_corregido');
    final werOcr = _findColumn(columns, 'wer_ocr');
    final werCorrected = _findColumn(columns, 'wer_corregido');
    final modoAprendizaje = _findColumn(columns, 'modo_aprendizaje');
    final reconocimientoValidado = _findColumn(columns, 'reconocimiento_validado');
    final calidadAceptable = _findColumn(columns, 'calidad_aceptable');
    final decisionCalidad = _findColumn(columns, 'decision_calidad');
    final nitidez = _findColumn(columns, 'nitidez');
    final brillo = _findColumn(columns, 'brillo');
    final contraste = _findColumn(columns, 'contraste');
    final imagen = _findColumn(columns, 'imagen');
    final textoReal = _findColumn(columns, 'texto_real');
    final producto = _findColumn(columns, 'producto');

    final timeColumns = <String>[];
    for (final column in columns) {
      if (RegExp(r'^(t_|tiempo|time|latencia|duracion|duración)', caseSensitive: false)
          .hasMatch(column)) {
        timeColumns.add(column);
      }
    }

    final cerComparison = _compareError(rows, cerOcr, cerCorrected, imagen);
    final werComparison = _compareError(rows, werOcr, werCorrected, imagen);
    final totalTimes = _calculateTotalTimes(rows, columns, timeColumns);

    final validationRows = modoAprendizaje == null
        ? <Map<String, String>>[]
        : rows.where((r) => !_isTruthy(r[modoAprendizaje] ?? '')).toList();
    final learningRows = modoAprendizaje == null
        ? <Map<String, String>>[]
        : rows.where((r) => _isTruthy(r[modoAprendizaje] ?? '')).toList();

    final qualityCorrelations = <String, dynamic>{};
    for (final q in [nitidez, brillo, contraste]) {
      if (q == null) continue;
      qualityCorrelations[q] = {
        if (cerOcr != null) 'cer_ocr': _correlation(rows, q, cerOcr),
        if (cerCorrected != null) 'cer_corregido': _correlation(rows, q, cerCorrected),
        if (werOcr != null) 'wer_ocr': _correlation(rows, q, werOcr),
        if (werCorrected != null) 'wer_corregido': _correlation(rows, q, werCorrected),
      };
    }

    final groups = _groupByProduct(rows, producto, textoReal);
    final productAnalysis = <Map<String, dynamic>>[];
    for (final entry in groups.entries) {
      productAnalysis.add({
        'producto': entry.key,
        'n': entry.value.length,
        'cer': _compareError(entry.value, cerOcr, cerCorrected, imagen),
        'wer': _compareError(entry.value, werOcr, werCorrected, imagen),
        'tiempo_total_ms': _calculateTotalTimes(entry.value, columns, timeColumns),
      });
    }

    return {
      'n_registros': rows.length,
      'n_columnas': columns.length,
      'columnas': columns,
      'columnas_cer': [if (cerOcr != null) cerOcr, if (cerCorrected != null) cerCorrected],
      'columnas_wer': [if (werOcr != null) werOcr, if (werCorrected != null) werCorrected],
      'columnas_tiempo': timeColumns,
      'columna_modo_aprendizaje': modoAprendizaje,
      'columna_reconocimiento_validado': reconocimientoValidado,
      'modo_aprendizaje': _categoricalSummary(rows, modoAprendizaje),
      'reconocimiento_validado': _categoricalSummary(rows, reconocimientoValidado),
      'calidad_aceptable': _categoricalSummary(rows, calidadAceptable),
      'decision_calidad': _categoricalSummary(rows, decisionCalidad),
      'estadisticas_numericas': numericStats,
      'comparacion_cer': cerComparison,
      'comparacion_wer': werComparison,
      'tiempo_total_ms': totalTimes,
      'tiempos_por_etapa': _timeStageSummary(rows, timeColumns),
      'correlaciones_calidad_error': qualityCorrelations,
      'analisis_por_producto': productAnalysis,
      'criterio_agrupacion_producto': producto != null
          ? producto
          : (textoReal != null ? 'texto_real (agrupación automática por etiqueta)' : 'no disponible'),
      'subconjuntos': {
        'aprendizaje': _subsetSummary(learningRows, cerOcr, cerCorrected, werOcr, werCorrected, imagen),
        'validacion_congelada': _subsetSummary(validationRows, cerOcr, cerCorrected, werOcr, werCorrected, imagen),
      },
    };
  }

  Map<String, dynamic> _subsetSummary(
    List<Map<String, String>> rows,
    String? cerOcr,
    String? cerCorrected,
    String? werOcr,
    String? werCorrected,
    String? imagen,
  ) {
    return {
      'n': rows.length,
      'cer': _compareError(rows, cerOcr, cerCorrected, imagen),
      'wer': _compareError(rows, werOcr, werCorrected, imagen),
    };
  }

  Map<String, List<Map<String, String>>> _groupByProduct(
    List<Map<String, String>> rows,
    String? productColumn,
    String? textColumn,
  ) {
    final result = <String, List<Map<String, String>>>{};
    for (final row in rows) {
      String key;
      if (productColumn != null && (row[productColumn] ?? '').trim().isNotEmpty) {
        key = row[productColumn]!.trim();
      } else if (textColumn != null && (row[textColumn] ?? '').trim().isNotEmpty) {
        final text = row[textColumn]!.replaceAll(RegExp(r'\s+'), ' ').trim();
        final words = text.split(' ');
        key = words.take(math.min(6, words.length)).join(' ');
        if (text.length > key.length) key += '…';
      } else {
        key = 'Sin identificar';
      }
      result.putIfAbsent(key, () => []).add(row);
    }
    return result;
  }

  Map<String, dynamic>? _calculateTotalTimes(
    List<Map<String, String>> rows,
    List<String> columns,
    List<String> timeColumns,
  ) {
    final values = <double>[];
    final totalColumn = _findColumn(columns, 't_total');
    for (final row in rows) {
      if (totalColumn != null) {
        final v = _toDouble(row[totalColumn] ?? '');
        if (v != null) values.add(v);
        continue;
      }
      var total = 0.0;
      var found = false;
      for (final c in timeColumns) {
        if (c.toLowerCase() == 't_total') continue;
        final v = _toDouble(row[c] ?? '');
        if (v != null) { total += v; found = true; }
      }
      if (found) values.add(total);
    }
    return values.isEmpty ? null : _statistics(values);
  }

  Map<String, dynamic> _timeStageSummary(
      List<Map<String, String>> rows, List<String> timeColumns) {
    final result = <String, dynamic>{};
    for (final c in timeColumns) {
      final values = rows.map((r) => _toDouble(r[c] ?? '')).whereType<double>().toList();
      if (values.isNotEmpty) result[c] = _statistics(values);
    }
    return result;
  }

  double? _correlation(List<Map<String, String>> rows, String xCol, String yCol) {
    final pairs = <List<double>>[];
    for (final r in rows) {
      final x = _toDouble(r[xCol] ?? '');
      final y = _toDouble(r[yCol] ?? '');
      if (x != null && y != null) pairs.add([x, y]);
    }
    if (pairs.length < 3) return null;
    final mx = pairs.map((p) => p[0]).reduce((a,b)=>a+b) / pairs.length;
    final my = pairs.map((p) => p[1]).reduce((a,b)=>a+b) / pairs.length;
    var num=0.0; var dx=0.0; var dy=0.0;
    for (final p in pairs) {
      final a=p[0]-mx, b=p[1]-my;
      num += a*b; dx += a*a; dy += b*b;
    }
    if (dx == 0 || dy == 0) return null;
    return num / math.sqrt(dx*dy);
  }

  bool _isTruthy(String value) {
    final v=value.trim().toLowerCase();
    return v=='true' || v=='1' || v=='si' || v=='sí' || v=='yes';
  }

  Map<String, dynamic> _categoricalSummary(
    List<Map<String, String>> rows,
    String? column,
  ) {
    if (column == null) return {'disponible': false};
    final counts = <String, int>{};
    for (final row in rows) {
      final raw = (row[column] ?? '').trim();
      if (raw.isEmpty) continue;
      final key = raw.toLowerCase();
      counts[key] = (counts[key] ?? 0) + 1;
    }
    return {'disponible': counts.isNotEmpty, 'columna': column,
      'n': counts.values.fold<int>(0, (a,b)=>a+b), 'valores': counts};
  }

  Map<String, dynamic> _statistics(List<double> input) {
    final values = [...input]..sort();
    final mean = values.reduce((a,b)=>a+b)/values.length;
    final sumSquared = values.map((v)=>math.pow(v-mean,2).toDouble()).fold<double>(0,(a,b)=>a+b);
    final popVar=sumSquared/values.length;
    final sampleVar=values.length>1 ? sumSquared/(values.length-1) : 0.0;
    return {
      'n': values.length,
      'media': mean,
      'mediana': _percentile(values, 50),
      'p25': _percentile(values,25),
      'p75': _percentile(values,75),
      'p95': _percentile(values,95),
      'desviacion_estandar_poblacional': math.sqrt(popVar),
      'desviacion_estandar_muestral': math.sqrt(sampleVar),
      'min': values.first,
      'max': values.last,
    };
  }

  double _percentile(List<double> sorted, double p) {
    if (sorted.length == 1) return sorted.first;
    final pos=(p/100)*(sorted.length-1);
    final lo=pos.floor(), hi=pos.ceil();
    if (lo==hi) return sorted[lo];
    final f=pos-lo;
    return sorted[lo]*(1-f)+sorted[hi]*f;
  }

  Map<String, dynamic> _compareError(
    List<Map<String, String>> rows,
    String? originalColumn,
    String? correctedColumn,
    String? imageColumn,
  ) {
    if (originalColumn == null || correctedColumn == null) {
      return {'disponible': false, 'columna_original': originalColumn, 'columna_corregida': correctedColumn};
    }
    final relative = <double>[];
    final absolute = <double>[];
    final detail = <Map<String,dynamic>>[];
    var improves=0, worsens=0, unchanged=0, perfectPreserved=0, perfectWorsened=0;
    Map<String,dynamic>? best, worst;
    for (var i=0;i<rows.length;i++) {
      final original=_toDouble(rows[i][originalColumn] ?? '');
      final corrected=_toDouble(rows[i][correctedColumn] ?? '');
      if (original==null || corrected==null) continue;
      final delta=original-corrected;
      absolute.add(delta);
      double? improvement;
      if (original != 0) { improvement=(delta/original)*100; relative.add(improvement); }
      if (delta>1e-12) improves++;
      else if (delta < -1e-12) worsens++;
      else unchanged++;
      if (original==0 && corrected==0) perfectPreserved++;
      if (original==0 && corrected>0) perfectWorsened++;
      final item=<String,dynamic>{
        'registro': i+1,
        'imagen': imageColumn==null ? '' : (rows[i][imageColumn] ?? ''),
        'valor_original': original,
        'valor_corregido': corrected,
        'mejora_absoluta': delta,
        'mejora_porcentual': improvement,
      };
      detail.add(item);
      if (best==null || delta>(best['mejora_absoluta'] as double)) best=item;
      if (worst==null || delta<(worst['mejora_absoluta'] as double)) worst=item;
    }
    if (absolute.isEmpty) return {'disponible': false};
    return {
      'disponible': true,
      'columna_original': originalColumn,
      'columna_corregida': correctedColumn,
      'n_comparaciones': absolute.length,
      'mejora_media_absoluta': _statistics(absolute)['media'],
      'mejora_media_porcentual': relative.isEmpty ? null : _statistics(relative)['media'],
      'desviacion_estandar_poblacional': relative.isEmpty ? null : _statistics(relative)['desviacion_estandar_poblacional'],
      'casos_mejora': improves,
      'casos_empeora': worsens,
      'casos_sin_cambio': unchanged,
      'ocr_perfecto_conservado': perfectPreserved,
      'ocr_perfecto_empeorado': perfectWorsened,
      'mejor_caso': best,
      'peor_caso': worst,
      'detalle': detail,
    };
  }

  String? _findColumn(List<String> columns, String expected) {
    final normalizedExpected = expected.toLowerCase().replaceAll(' ', '_');
    for (final column in columns) {
      final normalized = column.toLowerCase().replaceAll(' ', '_');
      if (normalized == normalizedExpected) return column;
    }
    return null;
  }

  double? _toDouble(String value) {
    var text = value.trim().replaceAll('%', '');
    if (text.isEmpty) return null;
    if (text.contains(',') && !text.contains('.')) {
      text = text.replaceAll(',', '.');
    }
    text = text.replaceAll(RegExp(r'[^0-9eE+\-.]'), '');
    return double.tryParse(text);
  }

  double _minDouble(double a, double b) => math.min(a, b).toDouble();
  double _maxDouble(double a, double b) => math.max(a, b).toDouble();

  String _fmt(dynamic value, {int decimals = 4}) {
    if (value == null) return '-';
    if (value is num) return value.toStringAsFixed(decimals);
    return value.toString();
  }

  String _withoutExtension(String name) {
    final position = name.lastIndexOf('.');
    return position > 0 ? name.substring(0, position) : name;
  }

  @override
  Widget build(BuildContext context) {
    final hasAnalysis = analysis != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('PraecoAnalisis'),
        actions: [
          IconButton(
            tooltip: 'Abrir CSV',
            onPressed: busy ? null : seleccionarCsv,
            icon: const Icon(Icons.folder_open),
          ),
          IconButton(
            tooltip: 'Generar JSON',
            onPressed: hasAnalysis && !busy ? generarJson : null,
            icon: const Icon(Icons.data_object),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildStatusBar(),
          if (busy) const LinearProgressIndicator(minHeight: 3),
          if (error != null) _buildError(),
          Expanded(
            child: hasAnalysis ? _buildContent() : _buildEmpty(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: busy ? null : seleccionarCsv,
        icon: const Icon(Icons.upload_file),
        label: const Text('Abrir CSV'),
      ),
    );
  }

  Widget _buildStatusBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          const Icon(Icons.analytics_outlined),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              status,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (analysis != null)
            FilledButton.icon(
              onPressed: busy ? null : generarJson,
              icon: const Icon(Icons.save_alt),
              label: const Text('Generar JSON'),
            ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.withValues(alpha: 0.30)),
      ),
      child: Text(
        error!,
        style: const TextStyle(color: Colors.red),
      ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 650),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.table_chart_outlined, size: 72),
                const SizedBox(height: 18),
                const Text(
                  'Analizador de experimentos OCR',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Lee automáticamente el CSV de Praeco 2.3.1, calcula CER, WER, tiempos (incluidos TTS y total cuando están presentes), estadísticas y resume el modo de aprendizaje y la validación OCR. También permite generar un JSON consolidado.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Compatible con el esquema Praeco 2.3.1: métricas OCR/corregidas, calidad de imagen, tiempos de captura/OCR/corrección/alérgenos/TTS/total y, cuando existen, modo_aprendizaje y reconocimiento_validado.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 22),
                FilledButton.icon(
                  onPressed: seleccionarCsv,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Seleccionar CSV'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    return Column(
      children: [
        NavigationBar(
          selectedIndex: selectedTab,
          onDestinationSelected: (value) {
            setState(() => selectedTab = value);
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.summarize_outlined),
              selectedIcon: Icon(Icons.summarize),
              label: 'Resultados',
            ),
            NavigationDestination(
              icon: Icon(Icons.table_rows_outlined),
              selectedIcon: Icon(Icons.table_rows),
              label: 'Datos',
            ),
            NavigationDestination(
              icon: Icon(Icons.info_outline),
              selectedIcon: Icon(Icons.info),
              label: 'Estructura',
            ),
          ],
        ),
        Expanded(
          child: IndexedStack(
            index: selectedTab,
            children: [
              _buildResults(),
              _buildDataTable(),
              _buildStructure(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildResults() {
    final current = analysis!;
    final summary = current.summary;
    final cer = (summary['comparacion_cer'] as Map).cast<String, dynamic>();
    final wer = (summary['comparacion_wer'] as Map).cast<String, dynamic>();
    final numeric =
        (summary['estadisticas_numericas'] as Map).cast<String, dynamic>();
    final times = (summary['tiempo_total_ms'] as Map?)?.cast<String, dynamic>();
    final learning =
        (summary['modo_aprendizaje'] as Map).cast<String, dynamic>();
    final validation =
        (summary['reconocimiento_validado'] as Map).cast<String, dynamic>();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          current.fileName,
          style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _metricCard(
              'Registros',
              '${summary['n_registros']}',
              Icons.dataset,
            ),
            _metricCard(
              'Columnas',
              '${summary['n_columnas']}',
              Icons.view_column,
            ),
            _metricCard(
              'Mejora CER',
              cer['disponible'] == true
                  ? '${_fmt(cer['mejora_media_porcentual'], decimals: 3)} %'
                  : 'N/D',
              Icons.spellcheck,
            ),
            _metricCard(
              'Mejora WER',
              wer['disponible'] == true
                  ? '${_fmt(wer['mejora_media_porcentual'], decimals: 3)} %'
                  : 'N/D',
              Icons.text_fields,
            ),
          ],
        ),
        const SizedBox(height: 18),
        _comparisonCard('Comparación CER', cer),
        const SizedBox(height: 14),
        _comparisonCard('Comparación WER', wer),
        const SizedBox(height: 14),
        _timeCard(times),
        const SizedBox(height: 14),
        _categoricalCard('Modo de aprendizaje (Praeco 2.3.1)', learning),
        const SizedBox(height: 14),
        _categoricalCard('Reconocimiento validado', validation),
        const SizedBox(height: 14),
        _advancedAnalysisCard(summary),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Estadísticas de columnas numéricas',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                if (numeric.isEmpty)
                  const Text('No se han detectado columnas numéricas.')
                else
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      columns: const [
                        DataColumn(label: Text('Variable')),
                        DataColumn(label: Text('N')),
                        DataColumn(label: Text('Media')),
                        DataColumn(label: Text('Mediana')),
                        DataColumn(label: Text('P25')),
                        DataColumn(label: Text('P75')),
                        DataColumn(label: Text('P95')),
                        DataColumn(label: Text('DE pobl.')),
                        DataColumn(label: Text('DE muestra')),
                        DataColumn(label: Text('Mín.')),
                        DataColumn(label: Text('Máx.')),
                      ],
                      rows: numeric.entries.map((entry) {
                        final stat =
                            (entry.value as Map).cast<String, dynamic>();
                        return DataRow(
                          cells: [
                            DataCell(Text(entry.key)),
                            DataCell(Text('${stat['n']}')),
                            DataCell(Text(_fmt(stat['media']))),
                            DataCell(Text(_fmt(stat['mediana']))),
                            DataCell(Text(_fmt(stat['p25']))),
                            DataCell(Text(_fmt(stat['p75']))),
                            DataCell(Text(_fmt(stat['p95']))),
                            DataCell(Text(
                              _fmt(stat['desviacion_estandar_poblacional']),
                            )),
                            DataCell(Text(
                              _fmt(stat['desviacion_estandar_muestral']),
                            )),
                            DataCell(Text(_fmt(stat['min']))),
                            DataCell(Text(_fmt(stat['max']))),
                          ],
                        );
                      }).toList(),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _advancedAnalysisCard(Map<String, dynamic> summary) {
    final stages=(summary['tiempos_por_etapa'] as Map).cast<String,dynamic>();
    final corr=(summary['correlaciones_calidad_error'] as Map).cast<String,dynamic>();
    final products=(summary['analisis_por_producto'] as List).cast<Map<String,dynamic>>();
    final subsets=(summary['subconjuntos'] as Map).cast<String,dynamic>();
    final quality=(summary['calidad_aceptable'] as Map).cast<String,dynamic>();
    return Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Análisis avanzado para el TFM', style: TextStyle(fontSize:18,fontWeight:FontWeight.bold)),
      const SizedBox(height:10),
      Text('Agrupación por producto: ${summary['criterio_agrupacion_producto']}'),
      Text('Grupos/productos detectados: ${products.length}'),
      Text('Etapas temporales analizadas: ${stages.keys.join(', ')}'),
      Text('Variables de calidad correlacionadas: ${corr.keys.join(', ')}'),
      if (quality['disponible']==true) Text('Calidad aceptable: ${quality['valores']}'),
      const Divider(),
      Text('Aprendizaje: ${(subsets['aprendizaje'] as Map)['n']} registros'),
      Text('Validación congelada: ${(subsets['validacion_congelada'] as Map)['n']} registros'),
      const SizedBox(height:8),
      const Text('El JSON exportado incluye: análisis por producto/etiqueta, correlaciones calidad-error, tiempos por etapa, percentiles, mejor/peor caso y separación aprendizaje-validación.', style: TextStyle(fontSize:12)),
    ])));
  }

  Widget _metricCard(String title, String value, IconData icon) {
    return SizedBox(
      width: 215,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(icon),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 12)),
                    const SizedBox(height: 4),
                    Text(
                      value,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _comparisonCard(String title, Map<String, dynamic> comparison) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            if (comparison['disponible'] == true) ...[
              _infoRow(
                'Columna original',
                '${comparison['columna_original']}',
              ),
              _infoRow(
                'Columna corregida',
                '${comparison['columna_corregida']}',
              ),
              _infoRow(
                'Comparaciones',
                '${comparison['n_comparaciones']}',
              ),
              _infoRow(
                'Mejora media',
                '${_fmt(comparison['mejora_media_porcentual'], decimals: 3)} %',
              ),
              _infoRow(
                'Mejora absoluta media',
                _fmt(comparison['mejora_media_absoluta'], decimals: 4),
              ),
              _infoRow(
                'Desviación estándar poblacional',
                '${_fmt(comparison['desviacion_estandar_poblacional'], decimals: 3)} %',
              ),
              _infoRow(
                'Casos que mejoran',
                '${comparison['casos_mejora']}',
              ),
              _infoRow(
                'Casos que empeoran',
                '${comparison['casos_empeora']}',
              ),
              _infoRow(
                'Casos sin cambio',
                '${comparison['casos_sin_cambio']}',
              ),
              _infoRow('OCR perfecto conservado', '${comparison['ocr_perfecto_conservado']}'),
              _infoRow('OCR perfecto empeorado', '${comparison['ocr_perfecto_empeorado']}'),
              if (comparison['mejor_caso'] != null)
                _infoRow('Mejor caso (registro)', '${comparison['mejor_caso']['registro']} · Δ=${_fmt(comparison['mejor_caso']['mejora_absoluta'])}'),
              if (comparison['peor_caso'] != null)
                _infoRow('Peor caso (registro)', '${comparison['peor_caso']['registro']} · Δ=${_fmt(comparison['peor_caso']['mejora_absoluta'])}'),
            ] else
              const Text(
                'No se puede calcular la comparación: faltan columnas válidas.',
              ),
          ],
        ),
      ),
    );
  }

  Widget _timeCard(Map<String, dynamic>? times) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Coste temporal',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            if (times == null)
              const Text('No hay suficientes datos temporales.')
            else ...[
              _infoRow('N', '${times['n']}'),
              _infoRow('Media total', '${_fmt(times['media'])} ms'),
              _infoRow(
                'DE poblacional',
                '${_fmt(times['desviacion_estandar_poblacional'])} ms',
              ),
              _infoRow('Mínimo', '${_fmt(times['min'])} ms'),
              _infoRow('Máximo', '${_fmt(times['max'])} ms'),
              const SizedBox(height: 8),
              const Text(
                'Si existe t_total, PraecoAnalisis usa ese valor directamente. En CSV anteriores, calcula el total sumando los componentes disponibles (t_captura, t_ocr, t_correccion, t_alergenos y t_tts).',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _categoricalCard(String title, Map<String, dynamic> data) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            if (data['disponible'] != true)
              const Text('No disponible en este CSV.')
            else ...[
              _infoRow('Columna', '${data['columna']}'),
              _infoRow('Registros', '${data['n']}'),
              ...((data['valores'] as Map).entries.map(
                    (entry) => _infoRow('${entry.key}', '${entry.value}'),
                  )),
            ],
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _buildDataTable() {
    final current = analysis!;

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Scrollbar(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SingleChildScrollView(
              scrollDirection: Axis.vertical,
              child: DataTable(
                headingRowColor: WidgetStatePropertyAll(
                  Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
                columns: current.columns
                    .map((column) => DataColumn(label: Text(column)))
                    .toList(),
                rows: current.rows.map((row) {
                  return DataRow(
                    cells: current.columns.map((column) {
                      return DataCell(
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 280),
                          child: Text(
                            row[column] ?? '',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      );
                    }).toList(),
                  );
                }).toList(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStructure() {
    final current = analysis!;
    final summary = current.summary;
    final cerColumns = (summary['columnas_cer'] as List).cast<String>();
    final werColumns = (summary['columnas_wer'] as List).cast<String>();
    final timeColumns = (summary['columnas_tiempo'] as List).cast<String>();
    final learningColumn = summary['columna_modo_aprendizaje'] as String?;
    final validationColumn = summary['columna_reconocimiento_validado'] as String?;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('Archivo cargado'),
            subtitle: Text(current.fileName),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Columnas detectadas',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: current.columns
                      .map((column) => Chip(label: Text(column)))
                      .toList(),
                ),
              ],
            ),
          ),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _structureRow('CER', cerColumns),
                _structureRow('WER', werColumns),
                _structureRow('Tiempos', timeColumns),
                _structureRow('Aprendizaje', [if (learningColumn != null) learningColumn]),
                _structureRow('Validación', [if (validationColumn != null) validationColumn]),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _structureRow(String title, List<String> values) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: Text(values.isEmpty ? 'No detectado' : values.join(', ')),
          ),
        ],
      ),
    );
  }
}
