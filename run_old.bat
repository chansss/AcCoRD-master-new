@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

set "exe=bin\accord_win_old.exe"
set "configDir=config"
set "resultsDir=results"
set "outDir=matlab_old"

if not exist "%exe%" (
  echo ERROR: %exe% not found.
  echo.
  echo Press any key to exit...
  pause >nul
  exit /b 1
)

if not exist "%configDir%" (
  echo ERROR: %configDir% directory not found.
  echo.
  echo Press any key to exit...
  pause >nul
  exit /b 1
)

if not exist "%resultsDir%" mkdir "%resultsDir%" >nul 2>&1
if not exist "%outDir%" mkdir "%outDir%" >nul 2>&1

set "foundAny=0"
for %%F in ("%configDir%\accord_config_sample*.txt") do (
  set "foundAny=1"
  set "cfgPath=%%~fF"
  set "cfgBase=%%~nF"
  set "logPath=%TEMP%\accord_old_!cfgBase!_!RANDOM!!RANDOM!.log"

  echo === Running OLD: !cfgBase! (SEED=1) ===
  "%exe%" "!cfgPath!" 1 > "!logPath!" 2>&1

  set "outRel="
  for /f "usebackq delims=" %%L in (`findstr /c:"Simulation output will be written to" "!logPath!"`) do (
    if not defined outRel (
      for /f "tokens=2 delims=^"" %%P in ("%%L") do set "outRel=%%P"
    )
  )

  if not defined outRel (
    echo WARNING: Could not find output path in log for !cfgBase!
  ) else (
    set "outRel=!outRel:/=\!"
    if not exist "!outRel!" (
      echo WARNING: Output file not found: !outRel!
    ) else (
      for %%O in ("!outRel!") do set "outName=%%~nxO"
      set "destPath=%outDir%\!cfgBase!__!outName!"
      copy /y "!outRel!" "!destPath!" >nul
      echo Result copied to: !destPath!
    )
  )

  del /q "!logPath!" >nul 2>&1
  echo.
)

if "%foundAny%"=="0" (
  echo ERROR: No accord_config_sample*.txt found under %configDir%.
  echo.
  echo Press any key to exit...
  pause >nul
  exit /b 1
)

echo All OLD runs completed. Results are in "%outDir%".
echo.
echo Press any key to exit...
pause >nul
