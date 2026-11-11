# Praeco v2.4.0 — preparación de publicación

Esta rama se ha creado para integrar la nueva versión de Praeco Desarrollo y la memoria del TFM.

## Cambios previstos

- Captura automática de una fotografía tras evaluación previa de fotogramas.
- Linterna automática con umbral de brillo 150, enclavamiento hasta la captura y estabilización aproximada de 900 ms.
- Preprocesamiento condicional de contraste local mediante CLAHE y ajustes de iluminación cuando proceda.
- Comparación visual de imagen original y procesada; selección de imagen para OCR.
- Memoria LaTeX actualizada, con metodología y resultados exploratorios separados de la validación anterior.

## Estado

**Pendiente de integrar en esta rama:** `Praeco_Desarrollo/lib/main.dart` actualizado y carpeta `Memoria_TFM/` del paquete preparado. Esta rama NO debe fusionarse hasta incorporar ambos contenidos, compilar y revisar los cambios.

No se afirma que CLAHE haya mejorado CER/WER sin una evaluación comparativa específica.
