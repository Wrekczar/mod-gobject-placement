@echo off
rem Usage: run_math_test.cmd <vcvars64.bat> <core source dir> <build dir> <output dir>
rem Example: run_math_test.cmd H:\CoA-Server\Dependencies\VSBuildTools\VC\Auxiliary\Build\vcvars64.bat
rem          I:\gobject-placement-dev\src I:\gobject-placement-dev\build %TEMP%\gp-math
setlocal
if "%~4"=="" (echo usage: %~nx0 vcvars64.bat core-source build-dir out-dir & exit /b 2)
call "%~1" >nul || exit /b 2
if not exist "%~4" mkdir "%~4"
set LIBDIR=%~3\deps\g3dlite\RelWithDebInfo
cl /nologo /std:c++20 /EHsc /O2 /MD /W4 /external:W0 /I"%~dp0..\src" /external:I"%~2\deps\g3dlite\include" ^
   /Fo"%~4\\" /Fe"%~4\math_test.exe" "%~dp0math_test.cpp" ^
   /link /LIBPATH:"%LIBDIR%" /LIBPATH:"%~3\deps\zlib\RelWithDebInfo" g3dlib.lib zlib.lib ^
   user32.lib ole32.lib advapi32.lib || exit /b 1
"%~4\math_test.exe"
