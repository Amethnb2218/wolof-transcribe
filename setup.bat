@echo off
echo =======================================
echo    WOLOF TRANSCRIBER - Installation
echo =======================================
echo.

echo [1/3] Installation des dependances Python...
cd /d "%~dp0backend"
pip install -r requirements.txt
echo.

echo [2/3] Installation des dependances React...
cd /d "%~dp0frontend"
call npm install
echo.

echo [3/3] Installation de FFmpeg (necessaire pour pydub)...
echo.
echo Si FFmpeg n'est pas installe, telechargez-le:
echo   https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip
echo   Extrayez et ajoutez le dossier bin/ a votre PATH
echo.
echo OU installez avec: winget install FFmpeg
echo.

echo =======================================
echo   Installation terminee !
echo   Lancez start.bat pour demarrer
echo =======================================
pause
