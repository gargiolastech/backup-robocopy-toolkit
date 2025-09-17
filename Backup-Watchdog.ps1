<#
.SYNOPSIS
  Watchdog: esegue più operazioni Daily (lista) e il Monthly secondo configurazione.
  Compatibile PowerShell 5.1. Tollerante a JSON con singoli valori/oggetti e Hashtable.

.PARAMETERS
  -ConfigPath   Percorso file JSON di configurazione (obbligatorio)

.DAILY (lista di operazioni)
  Ogni elemento di Daily.Operations supporta:
    Name            : string (usato per marker/last-run)
    Mode            : "EveryRun" | "OncePerDay" | "IntervalMinutes"
    IntervalMinutes : int (solo per Mode=IntervalMinutes)
    WeekdaysOnly    : bool (opzionale, default false)
    Destinations    : string|string[] (opzionale; altrimenti eredita Destinations globali)
    Sources         : {Path,TargetName} | {…}[]  (singolo oggetto o array)

.MONTHLY
  "FirstOfMonthOnce" (default) | "EveryRun" | "DayOfMonthOnce" (+Days:int[] o singolo int)
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [ValidateScript({ Test-Path $_ -PathType Leaf })]
  [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Helpers
function Get-ScriptRoot {
  if ($PSScriptRoot) { return $PSScriptRoot }
  if ($MyInvocation -and $MyInvocation.MyCommand -and $MyInvocation.MyCommand.Path) {
    return (Split-Path -Parent $MyInvocation.MyCommand.Path)
  }
  throw "Impossibile determinare la cartella dello script."
}

function Read-Config([string]$path){
  try {
    $text = Get-Content -Path $path -Raw -Encoding UTF8
    return $text | ConvertFrom-Json
  } catch {
    throw "Impossibile leggere/parsare la configurazione JSON ($path): $($_.Exception.Message)"
  }
}

# Normalizza qualsiasi valore in array (stringhe, PSCustomObject, Hashtable, null, ecc.)
function To-Array($value) {
  if ($null -eq $value) { return @() }
  if ($value -is [System.Array]) { return $value }
  return ,$value
}

# Verifica esistenza "proprietà" sia su PSCustomObject che su Hashtable
function Has-Prop($obj, [string]$name) {
  if ($null -eq $obj) { return $false }
  if ($obj -is [hashtable]) { return $obj.ContainsKey($name) }
  return ($obj.PSObject.Properties[$name] -ne $null)
}

# Legge in sicurezza una proprietà da PSCustomObject o Hashtable
function Get-Prop($obj, [string]$name) {
  if ($null -eq $obj) { return $null }
  if ($obj -is [hashtable]) {
    if ($obj.ContainsKey($name)) { return $obj[$name] } else { return $null }
  }
  $p = $obj.PSObject.Properties[$name]
  if ($p) { return $p.Value } else { return $null }
}

function Ensure-Dir([string]$path) { if (-not (Test-Path $path)) { New-Item -ItemType Directory -Force -Path $path | Out-Null } }

function New-LogInfra([string]$logRoot){
  $logs  = Join-Path $logRoot "Logs"
  $state = Join-Path $logRoot "State"
  Ensure-Dir $logs; Ensure-Dir $state
  $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
  $file = Join-Path $logs "watchdog-$ts.log"
  return [PSCustomObject]@{ Logs=$logs; State=$state; File=$file }
}

function WLog([string]$m){
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $line = "[$ts][WATCHDOG] $m"
  Write-Host $line
  if ($script:LogFile) { Add-Content -Path $script:LogFile -Value $line }
}

function WErr([string]$m){
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $line = "[$ts][ERROR] $m"
  Write-Warning $m
  if ($script:LogFile) { Add-Content -Path $script:LogFile -Value $line }
}

function Is-Weekday([datetime]$dt){ return ($dt.DayOfWeek -ge [System.DayOfWeek]::Monday -and $dt.DayOfWeek -le [System.DayOfWeek]::Friday) }

function Slug([string]$name){
  if (-not $name) { return "op" }
  $s = ($name -replace '[^a-zA-Z0-9\-_.]+','-')
  return ($s.Trim('.','-','_'))
}

# Crea una config temporanea per l’operazione (merge di globali + override op), con Destinations anche nel blocco Daily/Monthly.
function New-TempConfigForOperation($cfg, $op, $sources, [string]$frequency, [string]$tmpRoot){
  # Destinations: preferisci quelle dell'operazione; se assenti, usa globali; fallback legacy DestRoot.
  $dest = @()
  $opDest  = Get-Prop $op  'Destinations'
  $cfgDest = Get-Prop $cfg 'Destinations'
  $cfgRoot = Get-Prop $cfg 'DestRoot'

  if ($opDest)      { $dest = To-Array $opDest }
  elseif ($cfgDest) { $dest = To-Array $cfgDest }
  elseif ($cfgRoot) { $dest = To-Array $cfgRoot }

  if (@(To-Array $dest).Length -eq 0) {
    $opName = (Get-Prop $op 'Name'); if (-not $opName) { $opName = 'op' }
    throw "Operazione '$opName': nessuna destinazione (né specifica, né globale)."
  }

  $obj = [ordered]@{
    Destinations    = @(To-Array $dest)                     # <-- radice
    LogRoot         = (Get-Prop $cfg 'LogRoot')
    DefaultOptions  = (Get-Prop $cfg 'DefaultOptions')
  }
  $obj[$frequency] = @{
    Destinations = @(To-Array $dest)                        # <-- dentro Daily/Monthly
    Sources      = @(To-Array $sources)
  }

  $json = ($obj | ConvertTo-Json -Depth 10)
  Ensure-Dir $tmpRoot
  $slug = Slug ( (Get-Prop $op 'Name') )
  $tmp  = Join-Path $tmpRoot ("op-{0}-{1}.json" -f $slug, (Get-Date -Format 'yyyyMMdd-HHmmssfff'))
  Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8 -Force

  # Log di diagnostica
  $opName2 = (Get-Prop $op 'Name'); if (-not $opName2) { $opName2 = 'op' }
  WLog ("Config temporanea generata per op '{0}': {1}" -f $opName2, $tmp)

  return $tmp
}
#endregion Helpers

# Transcript di emergenza in ProgramData (sempre presente)
$fallbackTranscriptRoot = Join-Path $env:ProgramData "Backup\Logs"
Ensure-Dir $fallbackTranscriptRoot
$transcriptPath = Join-Path $fallbackTranscriptRoot ("watchdog-transcript-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
try { Start-Transcript -Path $transcriptPath -ErrorAction SilentlyContinue | Out-Null } catch {}

# Mutex
$mutex = New-Object System.Threading.Mutex($false, "Global\Backup-Watchdog-Mutex")

try {
  $hasHandle = $mutex.WaitOne([TimeSpan]::FromSeconds(5))
  if (-not $hasHandle) { Write-Host "Altra istanza in esecuzione. Esco."; return }

  $cfg = Read-Config $ConfigPath
  $logRoot = (Get-Prop $cfg 'LogRoot')
  if (-not $logRoot) { $logRoot = Join-Path $env:ProgramData 'Backup' }
  $infra = New-LogInfra $logRoot
  $script:LogFile = $infra.File

  WLog "Avvio. ConfigPath: $ConfigPath"

  $stateDir  = $infra.State
  $tmpCfgDir = Join-Path $stateDir "tmpcfg"
  Ensure-Dir $tmpCfgDir

  $today    = Get-Date
  $todayKey = $today.ToString('yyyy-MM-dd')
  $monthKey = $today.ToString('yyyy-MM')

  $root = Get-ScriptRoot
  $robocopyScript = Join-Path $root 'Backup-Robocopy.ps1'
  if (-not (Test-Path $robocopyScript -PathType Leaf)) { throw "Backup-Robocopy.ps1 non trovato: $robocopyScript" }

  $overallOk = $true

  # ---------------- DAILY (Operations) ----------------
  $ops = @()
  $cfgDaily = Get-Prop $cfg 'Daily'
  if ($cfgDaily) {
    $dailyOps = Get-Prop $cfgDaily 'Operations'
    if ($dailyOps) {
      $ops = @(To-Array $dailyOps)
    } else {
      $dailySources = Get-Prop $cfgDaily 'Sources'
      if ($dailySources) {
        $dailyDest = Get-Prop $cfgDaily 'Destinations'
        $ops = @(@{
          Name = 'Daily'
          Mode = 'OncePerDay'
          Sources = $dailySources
          Destinations = $dailyDest
        })
      }
    }
  }

  foreach ($op in $ops) {
    $name = (Get-Prop $op 'Name'); if (-not $name) { $name = 'op' }
    $slug = Slug $name

    # Normalizza sorgenti (singolo oggetto o array)
    $srcs = @(To-Array (Get-Prop $op 'Sources'))
    if (@($srcs).Length -eq 0) { WErr "Operazione '$name': nessuna 'Sources'. Salto."; continue }

    $mode         = (Get-Prop $op 'Mode'); if (-not $mode) { $mode = 'OncePerDay' }
    $weekdaysOnly = (Get-Prop $op 'WeekdaysOnly'); if ($null -eq $weekdaysOnly) { $weekdaysOnly = $false }
    $intervalMin  = (Get-Prop $op 'IntervalMinutes'); if ($null -eq $intervalMin) { $intervalMin = 0 }

    $dailyMarker   = Join-Path $stateDir ("daily-{0}-{1}.ok" -f $slug, $todayKey)
    $dailyLastFile = Join-Path $stateDir ("daily-{0}-last.txt" -f $slug)

    $shouldRun = $false
    if ($weekdaysOnly -and -not (Is-Weekday $today)) {
      WLog ("DAILY [{0}]: WeekdaysOnly=true e oggi è weekend. Salto." -f $name)
    } else {
      switch ($mode) {
        'EveryRun'       { $shouldRun = $true; WLog ("DAILY [{0}] Mode=EveryRun: avvio." -f $name) }
        'OncePerDay'     {
          if (-not (Test-Path $dailyMarker)) { $shouldRun = $true; WLog ("DAILY [{0}] Mode=OncePerDay: avvio." -f $name) }
          else { WLog ("DAILY [{0}]: già eseguito oggi (marker presente)." -f $name) }
        }
        'IntervalMinutes' {
          if ([int]$intervalMin -le 0) { WErr ("DAILY [{0}] Mode=IntervalMinutes ma 'IntervalMinutes' <= 0. Salto." -f $name) }
          else {
            $lastRun = $null
            if (Test-Path $dailyLastFile) {
              try { $lastRun = (Get-Content $dailyLastFile -Raw).Trim() | Get-Date } catch {}
            }
            if (-not $lastRun) { $shouldRun = $true; WLog ("DAILY [{0}] Interval: nessun last-run, avvio." -f $name) }
            else {
              $elapsed = New-TimeSpan -Start $lastRun -End $today
              if ($elapsed.TotalMinutes -ge [int]$intervalMin) { $shouldRun = $true; WLog ("DAILY [{0}] Interval: {1:N0} min ≥ {2}. Avvio." -f $name, $elapsed.TotalMinutes, $intervalMin) }
              else { WLog ("DAILY [{0}] Interval: {1:N0} min < {2}. Salto." -f $name, $elapsed.TotalMinutes, $intervalMin) }
            }
          }
        }
        default { WErr ("DAILY [{0}] Mode sconosciuta: {1}. Salto." -f $name, $mode) }
      }
    }

    if ($shouldRun) {
      try {
        $tmpCfg = New-TempConfigForOperation -cfg $cfg -op $op -sources $srcs -frequency 'Daily' -tmpRoot $tmpCfgDir
        & $robocopyScript -ConfigPath $tmpCfg -Frequency Daily | Out-Null
        $code = $LASTEXITCODE
        WLog ("DAILY [{0}] Exit code: {1}" -f $name, $code)
        if ($code -eq 0) {
          if ($mode -eq 'OncePerDay') {
            New-Item -ItemType File -Path $dailyMarker -Force | Out-Null
            WLog ("DAILY [{0}] Marker creato: {1}" -f $name, $dailyMarker)
          }
          if ($mode -eq 'IntervalMinutes') {
            Set-Content -LiteralPath $dailyLastFile -Value (Get-Date).ToString('o') -Encoding ASCII -Force
            WLog ("DAILY [{0}] Last-run aggiornato: {1}" -f $name, $dailyLastFile)
          }
        } else {
          $overallOk = $false
          WErr ("DAILY [{0}] terminato con codice {1}." -f $name, $code)
        }
      } catch {
        $overallOk = $false
        WErr ("DAILY [{0}] eccezione: {1}" -f $name, $_.Exception.Message)
      }
    }
  }

  # ---------------- MONTHLY ----------------
  $monthlyMode = 'FirstOfMonthOnce'
  $monthlyDays = @()
  $cfgMonthly = Get-Prop $cfg 'Monthly'
  if ($cfgMonthly) {
    $mMode = Get-Prop $cfgMonthly 'Mode'
    if ($mMode) { $monthlyMode = [string]$mMode }
    $mDays = Get-Prop $cfgMonthly 'Days'
    if ($mDays) { $monthlyDays = @(To-Array $mDays | ForEach-Object { [int]$_ }) }
  }

  $monthlyMarker    = Join-Path $stateDir ("monthly-{0}.ok" -f $monthKey)
  $monthlyDayMarker = Join-Path $stateDir ("monthlyday-{0}.ok" -f $today.ToString('yyyy-MM-dd'))

  $runMonthly = $false
  switch ($monthlyMode) {
    'EveryRun'           { $runMonthly = $true; WLog "MONTHLY Mode=EveryRun: avvio." }
    'FirstOfMonthOnce'   { if ($today.Day -eq 1 -and -not (Test-Path $monthlyMarker)) { $runMonthly = $true; WLog "MONTHLY FirstOfMonthOnce: avvio." } else { WLog "MONTHLY: non richiesto ora." } }
    'DayOfMonthOnce'     {
      if (@($monthlyDays).Length -gt 0 -and ($monthlyDays -contains $today.Day)) {
        if (-not (Test-Path $monthlyDayMarker)) { $runMonthly = $true; WLog ("MONTHLY DayOfMonthOnce (day={0}): avvio." -f $today.Day) }
        else { WLog "MONTHLY DayOfMonthOnce: marker presente per oggi, salto." }
      } else { WLog "MONTHLY DayOfMonthOnce: oggi non è nei giorni configurati, salto." }
    }
    default { WErr "MONTHLY Mode sconosciuta: $monthlyMode. Salto." }
  }

  if ($runMonthly) {
    try {
      & $robocopyScript -ConfigPath $ConfigPath -Frequency Monthly | Out-Null
      $mcode = $LASTEXITCODE
      WLog "MONTHLY Exit code: $mcode"
      if ($mcode -eq 0) {
        if ($monthlyMode -eq 'FirstOfMonthOnce') {
          New-Item -ItemType File -Path $monthlyMarker -Force | Out-Null
          WLog ("MONTHLY Marker creato: {0}" -f $monthlyMarker)
        }
        if ($monthlyMode -eq 'DayOfMonthOnce') {
          New-Item -ItemType File -Path $monthlyDayMarker -Force | Out-Null
          WLog ("MONTHLY Day marker creato: {0}" -f $monthlyDayMarker)
        }
      } else {
        $overallOk = $false
        WErr "MONTHLY terminato con codice $mcode."
      }
    } catch {
      $overallOk = $false
      WErr ("MONTHLY eccezione: {0}" -f $_.Exception.Message)
    }
  }

  if ($overallOk) { WLog "Completato senza errori." } else { WErr "Completato con avvisi/errori." }
}
catch {
  $msg = $_.Exception.Message
  try { WErr "Eccezione: $msg" } catch { Write-Warning $msg }
}
finally {
  try { $mutex.ReleaseMutex() | Out-Null } catch {}
  try { $mutex.Dispose() } catch {}
  try { Stop-Transcript | Out-Null } catch {}
  exit 0
}
