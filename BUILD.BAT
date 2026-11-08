@echo off
echo Building NVCRTC 1.0...
tasm /m9 NVCRTC.ASM
if errorlevel 1 goto error
tlink /t NVCRTC.OBJ
if errorlevel 1 goto error

echo Building NVCRTCD 1.0...
tasm /m9 NVCRTCD.ASM
if errorlevel 1 goto error
tlink /t NVCRTCD.OBJ
if errorlevel 1 goto error

echo.
echo Build complete: NVCRTC.COM and NVCRTCD.COM
goto end

:error
echo.
echo Build failed.

:end
