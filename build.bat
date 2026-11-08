@echo off
rem Сборка cube3d
rem Нужен FASM.EXE в папке tools (скачать: https://flatassembler.net)

if not exist tools\FASM.EXE (
    echo.
    echo Нет tools\FASM.EXE
    echo Скачай flat assembler и положи FASM.EXE в папку tools
    echo.
    exit /b 1
)

tools\FASM.EXE cube3d.asm
if errorlevel 1 (
    echo.
    echo Сборка не удалась
    exit /b 1
)

echo.
echo Готово: cube3d.exe
