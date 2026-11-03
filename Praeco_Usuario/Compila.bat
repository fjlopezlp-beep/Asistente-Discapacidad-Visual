@echo off
echo ========================================
echo Compilando Praeco Usuario v2.3.1
echo ========================================

call flutter clean
call flutter pub get
call flutter build apk --release

if exist "build\app\outputs\flutter-apk\app-release.apk" (
    ren "build\app\outputs\flutter-apk\app-release.apk" "praeco_usuario_v2.3.1.apk"
    echo.
    echo APK generada correctamente:
    echo build\app\outputs\flutter-apk\praeco_usuario_v2.3.1.apk
) else (
    echo ERROR: No se ha encontrado app-release.apk
)

pause