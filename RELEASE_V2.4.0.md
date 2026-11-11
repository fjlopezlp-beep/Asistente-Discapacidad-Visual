# Praeco v2.4.0 — registro de publicación

## Contenido integrado

- **Praeco Desarrollo 2.4.0+2:** captura rápida de una fotografía tras evaluación previa, linterna automática con umbral de brillo 150 y estabilización aproximada de 900 ms; CLAHE condicional para contraste inferior a 25 y comparación de variantes para OCR.
- **Praeco Usuario 2.4.0+2:** captura e iluminación adaptadas, sin aprendizaje ni evaluación experimental; uso de recursos lingüísticos incluidos.
- **Praeco Análisis 2.4.0+2:** análisis de CSV experimentales, CER/WER, calidad y tiempos, y exportación JSON.
- **Memoria_TFM/:** PDF, fuentes LaTeX, bibliografía, capítulos, apéndice y figuras.

## Validación

El autor ha confirmado la compilación y el funcionamiento de las tres aplicaciones. La revisión de GitHub confirma que los archivos están en la rama de publicación y que no hay conflictos de fusión con `main`. No se han observado ejecuciones de GitHub Actions asociadas al último commit; las pruebas funcionales son manuales.

## Limitaciones

La versión incorpora cambios de captura y preprocesamiento, pero **no se afirma una mejora demostrada de CER/WER** atribuible a CLAHE sin una comparación experimental específica. La memoria conserva la evaluación correspondiente a su metodología documentada.

## Reproducibilidad

Se recomienda crear una etiqueta Git `v2.4.0` sobre el commit de `main` resultante de la fusión y, opcionalmente, una GitHub Release con las notas de cambios.
