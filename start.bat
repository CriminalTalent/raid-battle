@echo off
chcp 65001 > nul
cd /d "%~dp0"
title 레이드 전투
where ruby > nul 2> nul
if errorlevel 1 (
  echo.
  echo  Ruby가 설치되어 있지 않습니다.
  echo  README의 "1. Ruby 설치"를 먼저 해 주세요.
  echo.
  pause
  exit /b
)
start "" cmd /c "timeout /t 3 > nul & start http://localhost:4567/admin"
ruby app\run.rb
echo.
echo  레이드 전투가 꺼졌습니다.
pause
