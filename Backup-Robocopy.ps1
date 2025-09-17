<#
.SYNOPSIS
  Esegue il backup delle sorgenti definite in configurazione verso UNA O PIÙ destinazioni:
    <Dest>\Daily\YYYY-MM-DD\...
    <Dest>\Monthly\YYYY-MM\...

.PARAMETERS
  -ConfigPath   File JSON di configurazione (obbligatorio)
  -Frequency    Daily | Monthly (obbligatorio)

.NOTE
  Compatibile con PowerShell 5.1 (nessun uso di -Depth in ConvertFrom-Json).
  Invoca robocopy con operatore di chiamata (&) e array argomenti (stabile con /LOG+:).
  Supporta -WhatIf e -Verbose. Exit 0 se tutte le destinazioni completano senza errori gravi.
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
  [Parameter(Mandatory=$true)]
  [ValidateScript({ Test-Path $_ -PathType Leaf })]
  [string]$ConfigPath,

  [Parameter(Mandatory=$true)]
  [ValidateSet('Daily','Monthly')]
  [string]$Frequency
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-Config([string]$path){
  try {
    $text = Get-Content -Path $path -Raw -Encoding UTF8
    # PowerShell 5.1 non supporta -Depth in ConvertFrom-Json
    return $text | ConvertFrom-Json
  }
  catch {
    throw "Errore durante la lettura/parsing della configurazione ($path): $($_.Exception.Message)"
  }
}

function Get-ExitCodeLabel([int]$code){
  switch ($code) {
    0 { "Nessun file copiato." }
    1 { "File copiati correttamente." }
    2 { "File extra o mismatch (non critico)." }
    3 { "Copiati + mismatch (non critico)." }
    5 { "Copia + file extra." }
    6 { "Copia + mismatch + extra." }
    default { "Vedi documentazione robocopy." }
  }
}

function Resolve-Destinations($cfg, [string]$frequency){
  # 1) Override per frequenza
  $freq = $cfg.$frequency
  if ($freq -and $freq.Destinations -and $freq.Destinations.Count -gt 0){
    return $freq.Destinations
  }
  # 2) Globale
  if ($cfg.Destinations -and $cfg.Destinations.Count -gt 0){
    return $cfg.Destinations
  }
  # 3) Legacy singola
  if ($cfg.DestRoot){
    return @($cfg.DestRoot)
  }
  throw "Nessuna destinazione definita: specificare `Destinations` globale o `<Frequency>.Destinations`, oppure `DestRoot` legacy."
}

# --- Lettura configurazione
$cfg = Read-Config $ConfigPath

$logRoot  = if ($cfg.LogRoot) { $cfg.LogRoot } else { Join-Path $env:ProgramData 'Backup' }

$opts     = $cfg.DefaultOptions
$roboArgs = @()
if ($opts -and $opts.RobocopyArgs) { $roboArgs += $opts.RobocopyArgs }

$excludeDirs  = @()
$excludeFiles = @()
if ($opts -and $opts.ExcludeDirs)  { $excludeDirs  = $opts.ExcludeDirs  }
if ($opts -and $opts.ExcludeFiles) { $excludeFiles = $opts.ExcludeFiles }

# --- Sorgenti per la frequenza richiesta
$set = $cfg.$Frequency
if (-not $set -or -not $set.Sources) {
  throw "In configurazione non sono definite sorgenti per '$Frequency'."
}

# --- Risolvi destinazioni
$destinations = Resolve-Destinations -cfg $cfg -frequency $Frequency

# --- Cartella destino datata per la frequenza
$stamp = if ($Frequency -eq 'Daily') { Get-Date -Format 'yyyy-MM-dd' } else { Get-Date -Format 'yyyy-MM' }

# --- Log per run
$logsDir = Join-Path $logRoot "Logs"
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
$logFile = Join-Path $logsDir ("backup-{0}-{1}.log" -f $Frequency, (Get-Date -Format 'yyyyMMdd-HHmmss'))

$overallSuccess = $true

Write-Verbose "Destinazioni: $($destinations -join ', ')"
Write-Verbose "Log file: $logFile"

foreach ($destRoot in $destinations) {
  try {
    Write-Verbose "Destinazione corrente: $destRoot"
    $baseDest = Join-Path (Join-Path $destRoot $Frequency) $stamp
    if (-not (Test-Path $baseDest)) {
      New-Item -ItemType Directory -Force -Path $baseDest | Out-Null
    }

    foreach ($src in $set.Sources) {
      $path = $src.Path
      if (-not (Test-Path $path -PathType Container)) {
        Write-Warning "Sorgente non trovata, salto: $path"
        continue
      }
      $targetName = if ($src.TargetName) { $src.TargetName } else { Split-Path $path -Leaf }
      $dest = Join-Path $baseDest $targetName
      if (-not (Test-Path $dest)) {
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
      }

      if ($PSCmdlet.ShouldProcess("$path -> $dest", "Robocopy ($destRoot)")) {
        # Costruzione argomenti "atomici" per PowerShell 5.1 (niente Start-Process)
        $robo = @()
        # Sorgente e destinazione come primi argomenti (senza virgolette manuali)
        $robo += $path
        $robo += $dest

        # Esclusioni directory
        foreach ($d in $excludeDirs)  { $robo += @("/XD", $d) }
        # Esclusioni file
        foreach ($f in $excludeFiles) { $robo += @("/XF", $f) }
        # Opzioni aggiuntive globali
        if ($roboArgs) { $robo += $roboArgs }

        # Logging Robocopy: singolo token (evita problemi con /LOG+: in 5.1)
        $robo += "/LOG+:$logFile"

        # Traccia comando
        Write-Verbose ("Eseguo: robocopy {0}" -f ($robo -join ' '))

        # Invocazione robusta (restituisce exit code in $LASTEXITCODE)
        & robocopy.exe @robo
        $code = $LASTEXITCODE

        if ($code -gt 7) {
          $overallSuccess = $false
          Write-Warning ("[{0}] Robocopy codice {1} => ERRORE. {2}" -f $destRoot, $code, (Get-ExitCodeLabel $code))
        } else {
          Write-Verbose ("[{0}] Robocopy ok con codice {1} => SUCCESSO. {2}" -f $destRoot, $code, (Get-ExitCodeLabel $code))
        }
      }
    }
  } catch {
    $overallSuccess = $false
    Write-Warning ("Errore in destinazione {0}: {1}" -f $destRoot, $_.Exception.Message)
  }
}

if ($overallSuccess) { exit 0 } else { exit 1 }
