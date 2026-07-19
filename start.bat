@echo off
echo =======================================
echo    WOLOF TRANSCRIBER - Demarrage
echo =======================================
echo.

echo [1/2] Demarrage du backend Python...
cd /d "%~dp0backend"
start "Wolof Backend" cmd /k "python app.py"

echo [2/2] Demarrage du frontend React...
cd /d "%~dp0frontend"
start "Wolof Frontend" cmd /k "npm run dev"

echo.
echo =======================================
echo   Backend: http://localhost:8000
echo   Frontend: http://localhost:5173
echo =======================================
echo.
echo Les deux serveurs sont lances !
pause
