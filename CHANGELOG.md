# Registro de cambios

## [2.4.0] — 2026-11-11 (rama de preparación)

### Praeco Desarrollo
- Captura rápida con una fotografía después de evaluar fotogramas de vista previa.
- Activación automática de la linterna si el brillo de vista previa es inferior a 150; espera de estabilización de 900 ms.
- Aplicación condicional de CLAHE si el contraste de la imagen es inferior a 25.
- Comparación de OCR sobre la imagen original y la preprocesada para elegir la variante.
- Se conserva la instrumentación experimental, la corrección OCR y la detección de alérgenos.
- Actualización de `Praeco_Desarrollo/pubspec.yaml` a `2.4.0+2`.

### Validación y alcance
- El autor ha confirmado la compilación y prueba funcional del `main.dart` de esta versión en su dispositivo.
- Las mejoras de precisión OCR por CLAHE no se consideran demostradas sin ensayo comparativo específico.
- `Praeco_Usuario` y `Praeco_Analisis` no se han actualizado en esta rama.
- La memoria del TFM está pendiente de incorporarse a esta rama; no fusionar hasta completar la revisión.
