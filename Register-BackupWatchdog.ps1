<#
.SYNOPSIS
  Registra (o ricrea) il task "Backup-Watchdog" per eseguire Backup-Watchdog.ps1 a intervalli regolari.

.DESCRIPTION
  Compatibile con PowerShell 5.1:
  - Niente parametri non supportati su New-ScheduledTaskSettingsSet (es. -AllowStartOnDemand).
  - Imposta le proprietà dei settings dopo la creazione (es. .AllowDemandStart).
  - Azione con powershell.exe 64-bit, -ExecutionPolicy Bypass e -File.
  - Trigger ripetuto con durata lunga ma valida (~10 anni).
  - Opzione -RunNow per avvio immediato.

.PARAMETERS
  -ConfigPath         Percorso del file JSON di configurazione (obbligatorio)
  -WatchdogPath       Percorso dello script watchdog (default: <cartella script>\Backup-Watchdog.ps1)
  -TaskName           Nome attività (default: Backup-Watchdog)
  -RepeatMinutes      Intervallo in minuti (default: 20)
  -StartDelayMinutes  Ritardo iniziale in minuti (default: 1)
  -RunAs              SYSTEM (default) | CurrentUser
  -RunNow             Avvia subito il task dopo la registrazione
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(Mandatory = $true)]
  [ValidateScript({ Test-Path $_ -PathType Leaf })]
  [string]$ConfigPath,

  [string]$WatchdogPath = $null,

  [string]$TaskName = 'Backup-Watchdog',

  [ValidateRange(1, 1440)]
  [int]$RepeatMinutes = 20,

  [ValidateRange(0, 1440)]
  [int]$StartDelayMinutes = 1,

  [ValidateSet('SYSTEM','CurrentUser')]
  [string]$RunAs = 'SYSTEM',

  [switch]$RunNow
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

function Write-Info([string]$Message) {
  $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  Write-Host "[$ts][INFO] $Message"
}
#endregion Helpers

try {
  # Percorsi risolti
  $scriptRoot = Get-ScriptRoot

  if (-not $WatchdogPath -or [string]::IsNullOrWhiteSpace($WatchdogPath)) {
    $WatchdogPath = Join-Path $scriptRoot 'Backup-Watchdog.ps1'
  }
  if (-not (Test-Path $WatchdogPath -PathType Leaf)) {
    throw "WatchdogPath non trovato: $WatchdogPath"
  }
  if (-not (Test-Path $ConfigPath -PathType Leaf)) {
    throw "ConfigPath non trovato: $ConfigPath"
  }

  # PowerShell 64-bit esplicita
  $pwsh = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if (-not (Test-Path $pwsh -PathType Leaf)) {
    throw "powershell.exe non trovato: $pwsh"
  }

  # Argomenti puliti
  $arguments = @(
    '-NoProfile',
    '-ExecutionPolicy','Bypass',
    '-File', ('"{0}"' -f $WatchdogPath),
    '-ConfigPath', ('"{0}"' -f $ConfigPath)
  ) -join ' '

  # Azione (WorkingDirectory se supportato)
  $newActionParams = @{ Execute = $pwsh; Argument = $arguments }
  $cmdMeta = Get-Command New-ScheduledTaskAction -ErrorAction SilentlyContinue
  if ($cmdMeta -and $cmdMeta.Parameters.ContainsKey('WorkingDirectory')) {
    $newActionParams['WorkingDirectory'] = $scriptRoot
  }
  $action = New-ScheduledTaskAction @newActionParams

  # Trigger
  $interval = New-TimeSpan -Minutes $RepeatMinutes
  $duration = New-TimeSpan -Days 3650
  $startAt  = (Get-Date).AddMinutes($StartDelayMinutes)

  $trigger = New-ScheduledTaskTrigger -Once -At $startAt `
             -RepetitionInterval $interval -RepetitionDuration $duration

  # Principal
  $principal =
    if ($RunAs -eq 'SYSTEM') {
      New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
    } else {
      New-ScheduledTaskPrincipal -UserId $env:UserName -LogonType S4U -RunLevel Highest
    }

  # Settings compatibili 5.1 (senza -AllowStartOnDemand)
  $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew `
               -ExecutionTimeLimit (New-TimeSpan -Hours 72)

  # Proprietà equivalenti al suo XML
  $settings.DisallowStartIfOnBatteries = $false
  $settings.StopIfGoingOnBatteries     = $true
  $settings.StartWhenAvailable         = $false
  $settings.RunOnlyIfNetworkAvailable  = $false
  $settings.WakeToRun                  = $false
  $settings.Hidden                     = $false
  $settings.RunOnlyIfIdle              = $false
  # Questa è l'equivalente di "AllowStartOnDemand"
  $settings.AllowDemandStart           = $true
  # Opzionale: priorità (7 nel suo XML) non è esposta qui; resta quella di default.

  # (Ri)registrazione
  $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
  if ($existing) {
    if ($PSCmdlet.ShouldProcess($TaskName,'Unregister existing task')) {
      Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
      Write-Info "Task esistente '$TaskName' rimosso."
    }
  }

  if ($PSCmdlet.ShouldProcess($TaskName,'Register scheduled task')) {
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings
    Register-ScheduledTask -TaskName $TaskName -InputObject $task | Out-Null
    Write-Info "Task '$TaskName' registrato."
    Write-Info ("Esecuzione ogni {0} min (inizio {1:yyyy-MM-dd HH:mm}) - RunAs: {2}" -f $RepeatMinutes, $startAt, $RunAs)
  }

  # Avvio immediato opzionale
  if ($RunNow.IsPresent) {
    Start-ScheduledTask -TaskName $TaskName
    Write-Info "Task '$TaskName' avviato immediatamente (-RunNow)."
  }
}
catch {
  Write-Error $_.Exception.Message
  exit 1
}
