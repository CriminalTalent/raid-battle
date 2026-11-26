@echo off
chcp 65001 > nul
cd /d "%~dp0"
title 레이드 공유 주소
if not exist cloudflared.exe (
  echo.
  echo  cloudflared.exe 파일이 이 폴더에 없습니다.
  echo  README의 "4. 다른 사람과 같이 하기"를 먼저 해 주세요.
  echo.
  pause
  exit /b
)
echo.
echo  잠시 뒤 아래에 https://....trycloudflare.com 주소가 나옵니다.
echo  그 주소를 관리자 페이지의 "공유 주소" 칸에 넣고 적용을 누르세요.
echo  이 창을 닫으면 공유가 끝납니다.
echo.
cloudflared.exe tunnel --url http://localhost:4567
pause
