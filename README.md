# Praeco — Asistente accesible para personas con discapacidad visual

Código fuente asociado al Trabajo Fin de Máster **“Diseño de una aplicación mediante visión artificial para el desarrollo de un asistente accesible”**.

Autor: **Fco Javier López López**  
Máster Universitario en Ingeniería de Sistemas y de Control (UNED/UCM).

## Estructura

### `Praeco_Desarrollo/`
Versión utilizada para desarrollo y evaluación experimental. Incluye captura y selección de imagen, OCR mediante Google ML Kit, filtrado y corrección léxica, detección de términos asociados a alérgenos, síntesis de voz, cálculo de CER/WER y mecanismos de aprendizaje adaptativo.

Los ficheros `errores_ocr.json`, `diccionario_adaptativo.json` y `experimentos.csv` que se generan o actualizan durante el aprendizaje son datos de ejecución y no forman parte del código fuente base del proyecto.

### `Praeco_Usuario/`
Versión destinada al uso normal del asistente. Utiliza los recursos lingüísticos previamente obtenidos y congelados, sin introducir *ground truth* ni modificar el aprendizaje durante su utilización.

### `Praeco_Analisis/`
Herramienta independiente para cargar y analizar los resultados experimentales. Permite estudiar CER, WER, comportamiento del corrector, estadísticos de calidad de imagen y tiempos de procesamiento.

## Entorno de desarrollo

Los proyectos fueron desarrollados con Flutter/Dart y están orientados a Android. Cada aplicación conserva su propio `pubspec.yaml` y `pubspec.lock`, de forma que sus dependencias quedan identificadas de manera independiente.

## Compilación

Desde el directorio de cualquiera de las tres aplicaciones:

```bash
flutter pub get
flutter run
```

Para generar un APK de distribución:

```bash
flutter build apk --release
```

## Recursos

Los recursos declarados en cada `pubspec.yaml` se conservan dentro de su correspondiente carpeta `assets/`. No se incluyen cachés de Flutter, resultados de compilación, configuración local del IDE ni corpus experimental generado durante las pruebas.

## Reproducibilidad

La versión asociada a la entrega del TFM debe identificarse mediante una etiqueta (*tag*) o *release* de GitHub para mantener inmutable el código utilizado en la memoria y en los experimentos finales.
