param(
    [int]$MaxConfigs = 0
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

$exeNew = Join-Path $root 'bin\accord_win.exe'
$exeOld = Join-Path $root 'bin\accord_win_old.exe'

if (!(Test-Path $exeNew)) { throw "accord_win.exe not found: $exeNew" }
if (!(Test-Path $exeOld)) { throw "accord_win_old.exe not found: $exeOld" }

$configDir = Join-Path $root 'config'
$resultsDir = Join-Path $root 'results'
$matlabNewDir = Join-Path $root 'matlab_new'
$matlabOldDir = Join-Path $root 'matlab_old'

$configFiles = Get-ChildItem -Path $configDir -Filter 'accord_config_sample*.txt' | Sort-Object Name
if ($configFiles.Count -eq 0) { throw "No accord_config_sample*.txt found under config directory." }
if ($MaxConfigs -gt 0) { $configFiles = $configFiles | Select-Object -First $MaxConfigs }

New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
New-Item -ItemType Directory -Path $matlabNewDir -Force | Out-Null
New-Item -ItemType Directory -Path $matlabOldDir -Force | Out-Null

$summaryPath = Join-Path $root 'benchmark_summary.txt'
[System.IO.File]::WriteAllText($summaryPath, "[RUNNING]`n", [System.Text.Encoding]::UTF8)

$runResults = @()

function Run-One {
    param(
        [string]$ExePath,
        [string]$ConfigPath,
        [string]$Which
    )

    $configName = [System.IO.Path]::GetFileNameWithoutExtension($ConfigPath)
    $exeName = [System.IO.Path]::GetFileName($ExePath)

    Write-Host "=== RUNNING $exeName with $configName (SEED=1) ==="

    $tempLog = Join-Path $env:TEMP ("accord_run_{0}_{1}_{2}.log" -f $Which, $configName, [Guid]::NewGuid().ToString('N'))
    & $ExePath $ConfigPath 1 *> $tempLog

    $timeLine = (Select-String -Path $tempLog -Pattern '^Simulation ran in ' -List | Select-Object -First 1).Line
    $time = $null
    if ($timeLine) {
        $parts = $timeLine.Split(' ')
        if ($parts.Count -ge 4) {
            $time = [double]$parts[3]
            Write-Host "  Time = $time s"
        } else {
            Write-Warning "Failed to parse time line: $timeLine"
        }
    } else {
        Write-Warning "No timing line found for $exeName $configName"
    }

    $outPathLine = (Select-String -Path $tempLog -Pattern '^Simulation output will be written to ' -List | Select-Object -First 1).Line
    $outputFile = $null
    if ($outPathLine) {
        $matches = [regex]::Matches($outPathLine, '"([^"]+)"')
        if ($matches.Count -gt 0) {
            $relPath = $matches[0].Groups[1].Value
            $outputFile = Join-Path $root $relPath
        }
    } else {
        Write-Warning "No output path line found for $exeName $configName"
    }

    Remove-Item $tempLog -Force -ErrorAction SilentlyContinue

    $copiedPath = $null
    if ($outputFile -and (Test-Path $outputFile)) {
        $destFileName = "$configName`_SEED1.txt"
        if ($Which -eq 'new') {
            $destPath = Join-Path $matlabNewDir $destFileName
        } else {
            $destPath = Join-Path $matlabOldDir $destFileName
        }
        Copy-Item $outputFile $destPath -Force
        $copiedPath = $destPath
        Write-Host "  Result copied to: $copiedPath"
    } else {
        Write-Warning "Output file not found: $outputFile"
    }

    return [pscustomobject]@{
        Config     = $configName
        Exe        = $exeName
        Which      = $Which
        Time       = $time
        ResultPath = $copiedPath
    }
}

Write-Host "======= Running all samples (new and old executables) ======="

foreach ($cfg in $configFiles) {
    $cfgPath = $cfg.FullName
    $runResults += Run-One -ExePath $exeNew -ConfigPath $cfgPath -Which 'new'
    $runResults += Run-One -ExePath $exeOld -ConfigPath $cfgPath -Which 'old'
}

Write-Host ""
Write-Host "======= Collecting speed and result accuracy statistics ======="

$speedSummary = @()
foreach ($group in $runResults | Group-Object Config) {
    $cfgName = $group.Name
    $new = $group.Group | Where-Object { $_.Which -eq 'new' } | Select-Object -First 1
    $old = $group.Group | Where-Object { $_.Which -eq 'old' } | Select-Object -First 1
    if (-not $new -or -not $old) { continue }

    $speedupFactor = $null
    $fasterPercent = $null
    if ($new.Time -ne $null -and $old.Time -ne $null -and $old.Time -gt 0 -and $new.Time -gt 0) {
        $speedupFactor = $old.Time / $new.Time
        $fasterPercent = ($old.Time - $new.Time) / $old.Time * 100.0
    }

    $speedSummary += [pscustomobject]@{
        Config        = $cfgName
        NewTime       = $new.Time
        OldTime       = $old.Time
        SpeedupFactor = $speedupFactor
        FasterPercent = $fasterPercent
    }
}

function Is-Close {
    param(
        [double]$A,
        [double]$B,
        [double]$AbsTol,
        [double]$RelTol
    )

    $diff = [Math]::Abs($A - $B)
    if ($diff -le $AbsTol) { return $true }
    $scale = [Math]::Max([Math]::Abs($A), [Math]::Abs($B))
    if ($scale -eq 0.0) { return $true }
    return ($diff -le ($RelTol * $scale))
}

function Parse-ResultFile {
    param([string]$Path)

    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $countSeries = @{}
    $positionSeries = @{}

    $curRealization = $null
    $curActorType = $null
    $curActorIndex = $null
    $curMolId = $null

    $mode = 'none'
    $currentKey = $null

    $lines = Get-Content $Path

    foreach ($line in $lines) {
        $trim = $line.Trim()

        $mReal = [regex]::Match($trim, '^Realization\s+(\d+):$')
        if ($mReal.Success) {
            $curRealization = $mReal.Groups[1].Value
            $curActorType = $null
            $curActorIndex = $null
            $curMolId = $null
            $mode = 'none'
            $currentKey = $null
            continue
        }

        $mActive = [regex]::Match($trim, '^ActiveActor\s+(\d+):$')
        if ($mActive.Success) {
            $curActorType = 'ActiveActor'
            $curActorIndex = $mActive.Groups[1].Value
            $curMolId = $null
            $mode = 'none'
            $currentKey = $null
            continue
        }

        $mPassive = [regex]::Match($trim, '^PassiveActor\s+(\d+):$')
        if ($mPassive.Success) {
            $curActorType = 'PassiveActor'
            $curActorIndex = $mPassive.Groups[1].Value
            $curMolId = $null
            $mode = 'none'
            $currentKey = $null
            continue
        }

        $mMol = [regex]::Match($trim, '^MolID\s+(\d+):$')
        if ($mMol.Success) {
            $curMolId = $mMol.Groups[1].Value
            $mode = 'none'
            $currentKey = $null
            continue
        }

        if ($trim -eq 'Count:') {
            $mode = 'count'
            $r = if ($curRealization -ne $null) { $curRealization } else { '-' }
            $aType = if ($curActorType -ne $null) { $curActorType } else { '-' }
            $aIdx = if ($curActorIndex -ne $null) { $curActorIndex } else { '-' }
            $mId = if ($curMolId -ne $null) { $curMolId } else { '-' }
            $currentKey = "R=$r|$aType=$aIdx|MolID=$mId"
            if (-not $countSeries.ContainsKey($currentKey)) {
                $countSeries[$currentKey] = (New-Object System.Collections.Generic.List[int])
            }
            continue
        }

        if ($trim -eq 'Position:') {
            $mode = 'position'
            $r = if ($curRealization -ne $null) { $curRealization } else { '-' }
            $aType = if ($curActorType -ne $null) { $curActorType } else { '-' }
            $aIdx = if ($curActorIndex -ne $null) { $curActorIndex } else { '-' }
            $mId = if ($curMolId -ne $null) { $curMolId } else { '-' }
            $currentKey = "R=$r|$aType=$aIdx|MolID=$mId"
            if (-not $positionSeries.ContainsKey($currentKey)) {
                $positionSeries[$currentKey] = (New-Object System.Collections.Generic.List[object])
            }
            continue
        }

        if ($mode -eq 'count' -and $currentKey) {
            $intMatches = [regex]::Matches($trim, '-?\d+')
            foreach ($m in $intMatches) {
                $countSeries[$currentKey].Add([int]$m.Value)
            }
            continue
        }

        if ($mode -eq 'position' -and $currentKey) {
            if (-not $trim.StartsWith('(')) { continue }
            $tupleMatches = [regex]::Matches($trim, '\(\s*([-+]?\d*\.?\d+(?:[eE][-+]?\d+)?)\s*,\s*([-+]?\d*\.?\d+(?:[eE][-+]?\d+)?)\s*,\s*([-+]?\d*\.?\d+(?:[eE][-+]?\d+)?)\s*\)')
            if ($tupleMatches.Count -eq 0) { continue }

            $tupleList = New-Object System.Collections.Generic.List[object]
            foreach ($tm in $tupleMatches) {
                $x = [double]::Parse($tm.Groups[1].Value, $inv)
                $y = [double]::Parse($tm.Groups[2].Value, $inv)
                $z = [double]::Parse($tm.Groups[3].Value, $inv)
                $tupleList.Add([pscustomobject]@{ X = $x; Y = $y; Z = $z })
            }

            $positionSeries[$currentKey].Add($tupleList.ToArray())
            continue
        }
    }

    return [pscustomobject]@{
        CountSeries = $countSeries
        PositionSeries = $positionSeries
    }
}

function Compare-ResultFiles {
    param(
        [string]$NewPath,
        [string]$OldPath,
        [double]$AbsTol = 0.0,
        [double]$RelTol = 0.0
    )

    $newData = Parse-ResultFile -Path $NewPath
    $oldData = Parse-ResultFile -Path $OldPath

    function To-IntArray {
        param($Value)
        if ($null -eq $Value) { return @() }
        if ($Value -is [System.Collections.Generic.List[int]]) { return $Value.ToArray() }
        if ($Value -is [int[]]) { return $Value }
        if ($Value -is [int]) { return @([int]$Value) }
        return @()
    }

    $countMatches = 0
    $countTotal = 0

    $countKeys = @($newData.CountSeries.Keys + $oldData.CountSeries.Keys | Select-Object -Unique)
    foreach ($key in $countKeys) {
        $newArr = if ($newData.CountSeries.ContainsKey($key)) { To-IntArray $newData.CountSeries[$key] } else { @() }
        $oldArr = if ($oldData.CountSeries.ContainsKey($key)) { To-IntArray $oldData.CountSeries[$key] } else { @() }

        $lenMax = [Math]::Max($newArr.Length, $oldArr.Length)
        $lenMin = [Math]::Min($newArr.Length, $oldArr.Length)
        $countTotal += $lenMax

        for ($i = 0; $i -lt $lenMin; $i++) {
            if ($newArr[$i] -eq $oldArr[$i]) { $countMatches++ }
        }
    }

    $posTotal = 0
    $posMatches = 0

    $posKeys = @($newData.PositionSeries.Keys + $oldData.PositionSeries.Keys | Select-Object -Unique)
    foreach ($key in $posKeys) {
        $newFrames = if ($newData.PositionSeries.ContainsKey($key)) { $newData.PositionSeries[$key].ToArray() } else { @() }
        $oldFrames = if ($oldData.PositionSeries.ContainsKey($key)) { $oldData.PositionSeries[$key].ToArray() } else { @() }

        $frameMin = [Math]::Min($newFrames.Length, $oldFrames.Length)

        for ($fi = 0; $fi -lt $frameMin; $fi++) {
            $newFrame = $newFrames[$fi]
            $oldFrame = $oldFrames[$fi]

            $newMap = @{}
            for ($i = 0; $i -lt $newFrame.Length; $i++) {
                $k = ('{0:R},{1:R},{2:R}' -f [double]$newFrame[$i].X, [double]$newFrame[$i].Y, [double]$newFrame[$i].Z)
                if ($newMap.ContainsKey($k)) { $newMap[$k] = $newMap[$k] + 1 } else { $newMap[$k] = 1 }
            }

            $oldMap = @{}
            for ($i = 0; $i -lt $oldFrame.Length; $i++) {
                $k = ('{0:R},{1:R},{2:R}' -f [double]$oldFrame[$i].X, [double]$oldFrame[$i].Y, [double]$oldFrame[$i].Z)
                if ($oldMap.ContainsKey($k)) { $oldMap[$k] = $oldMap[$k] + 1 } else { $oldMap[$k] = 1 }
            }

            $seen = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($k in $newMap.Keys) {
                $a = [int]$newMap[$k]
                $b = 0
                if ($oldMap.ContainsKey($k)) { $b = [int]$oldMap[$k] }
                $posMatches += [Math]::Min($a, $b)
                $posTotal += [Math]::Max($a, $b)
                $seen.Add($k) | Out-Null
            }

            foreach ($k in $oldMap.Keys) {
                if ($seen.Contains($k)) { continue }
                $posTotal += [int]$oldMap[$k]
            }
        }

        for ($fi = $frameMin; $fi -lt $newFrames.Length; $fi++) { $posTotal += $newFrames[$fi].Length }
        for ($fi = $frameMin; $fi -lt $oldFrames.Length; $fi++) { $posTotal += $oldFrames[$fi].Length }
    }

    $overallTotal = $countTotal + $posTotal
    $overallMatches = $countMatches + $posMatches
    return [pscustomobject]@{
        Matches = $overallMatches
        Total   = $overallTotal
    }
}

$validSpeeds = $speedSummary | Where-Object { $_.SpeedupFactor -ne $null -and $_.SpeedupFactor -lt [double]::PositiveInfinity }
$avgNew    = ($validSpeeds | Measure-Object NewTime       -Average).Average
$avgOld    = ($validSpeeds | Measure-Object OldTime       -Average).Average
$avgSpeed  = ($validSpeeds | Measure-Object SpeedupFactor -Average).Average
$avgFaster = ($validSpeeds | Measure-Object FasterPercent -Average).Average

$accuracyRows = @()
$finalMatches = [int64]0
$finalTotal = [int64]0

foreach ($group in ($runResults | Group-Object Config | Sort-Object Name)) {
    $cfgName = $group.Name
    $new = $group.Group | Where-Object { $_.Which -eq 'new' } | Select-Object -First 1
    $old = $group.Group | Where-Object { $_.Which -eq 'old' } | Select-Object -First 1

    if (-not $new -or -not $old -or -not $new.ResultPath -or -not $old.ResultPath) {
        $accuracyRows += [pscustomobject]@{ Config = $cfgName; AccuracyPercent = $null }
        continue
    }
    if (-not (Test-Path $new.ResultPath) -or -not (Test-Path $old.ResultPath)) {
        $accuracyRows += [pscustomobject]@{ Config = $cfgName; AccuracyPercent = $null }
        continue
    }

    $cmp = Compare-ResultFiles -NewPath $new.ResultPath -OldPath $old.ResultPath -AbsTol 0.0 -RelTol 0.0
    $matches = [int64]$cmp.Matches
    $total = [int64]$cmp.Total

    $acc = if ($total -eq 0) { 100.0 } else { $matches / $total * 100.0 }
    $accuracyRows += [pscustomobject]@{ Config = $cfgName; AccuracyPercent = $acc }

    $finalMatches += $matches
    $finalTotal += $total
}

$finalAccuracy = if ($finalTotal -eq 0) { 100.0 } else { $finalMatches / $finalTotal * 100.0 }

$sb = New-Object System.Text.StringBuilder

$null = $sb.AppendLine('[SPEED_COMPARISON]')
$null = $sb.AppendLine('Config,NewTime(s),OldTime(s),SpeedupFactor,NewFasterPercent')

foreach ($row in $speedSummary | Sort-Object Config) {
    $newTimeStr = if ($row.NewTime -ne $null) { ('{0:0.######}' -f $row.NewTime) } else { 'NA' }
    $oldTimeStr = if ($row.OldTime -ne $null) { ('{0:0.######}' -f $row.OldTime) } else { 'NA' }
    $speedStr   = if ($row.SpeedupFactor -ne $null) { ('{0:0.####}'   -f $row.SpeedupFactor) } else { 'NA' }
    $fastStr    = if ($row.FasterPercent -ne $null) { ('{0:0.##}'     -f $row.FasterPercent) } else { 'NA' }

    $line = '{0},{1},{2},{3},{4}' -f $row.Config, $newTimeStr, $oldTimeStr, $speedStr, $fastStr
    $null = $sb.AppendLine($line)
}

$null = $sb.AppendLine()
$null = $sb.AppendLine('[RESULT_ACCURACY]')
$null = $sb.AppendLine('Config,AccuracyPercent')
foreach ($row in $accuracyRows) {
    $accStr = if ($row.AccuracyPercent -ne $null) { ('{0:0.####}' -f $row.AccuracyPercent) } else { 'NA' }
    $null = $sb.AppendLine(('{0},{1}' -f $row.Config, $accStr))
}

$null = $sb.AppendLine()
$null = $sb.AppendLine('[OVERALL]')
$null = $sb.AppendLine(('AverageNewTime(s)={0:0.######}'          -f $avgNew))
$null = $sb.AppendLine(('AverageOldTime(s)={0:0.######}'          -f $avgOld))
$null = $sb.AppendLine(('AverageSpeedupFactor={0:0.####}'         -f $avgSpeed))
$null = $sb.AppendLine(('AverageNewFasterPercent={0:0.##}'        -f $avgFaster))
$null = $sb.AppendLine(('FinalAccuracyPercent={0:0.####}'         -f $finalAccuracy))

[System.IO.File]::WriteAllText($summaryPath, $sb.ToString(), [System.Text.Encoding]::UTF8)

Write-Host ""
Write-Host "Benchmark finished."
Write-Host "Summary written to: $summaryPath"
Write-Host "New results under: $matlabNewDir"
Write-Host "Old results under: $matlabOldDir"
