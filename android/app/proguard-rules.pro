# Mantener las clases de ML Kit para evitar errores de R8
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.ml.** { *; }

# Específicamente para los errores de missing classes que te salieron
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**