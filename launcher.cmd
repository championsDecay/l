@echo off
setlocal
set "LAUNCHER_FLOW_FILE=%~f0"
set "LAUNCHER_FLOW_MODE=ui"
if exist "%~dp0launcher.exe" (
    if /I "%~1"=="--console" (
        "%~dp0launcher.exe" --console
    ) else (
        start "" "%~dp0launcher.exe"
    )
    exit /b 0
)
if /I "%~1"=="--console" goto console
set "flowWindow=-WindowStyle Hidden"
goto launch
:console
set "LAUNCHER_FLOW_MODE=console"
set "flowWindow="
:launch
powershell.exe -NoProfile -STA -NonInteractive %flowWindow% -Command "$content = [IO.File]::ReadAllText($env:LAUNCHER_FLOW_FILE); $marker = ':LAUNCHER_POWERSHELL'; $script = $content.Substring($content.LastIndexOf($marker) + $marker.Length); & ([scriptblock]::Create($script))"
set "flowExit=%ERRORLEVEL%"
if not "%flowExit%"=="0" pause
exit /b %flowExit%
:LAUNCHER_POWERSHELL
$ErrorActionPreference = 'Stop'
$CloudflarePackage = 'com.cloudflare.onedotonedotonedotone'
$UiDumpPath = '/sdcard/launcher-flow.xml'

function Get-LauncherPowerShellPath {
    
    
    $current=[Diagnostics.Process]::GetCurrentProcess()
    try{
        $runningPath=$current.MainModule.FileName
        if([IO.Path]::GetFileName($runningPath) -in @('powershell.exe','pwsh.exe') -and [IO.File]::Exists($runningPath)){return $runningPath}
    }catch{}finally{$current.Dispose()}
    if($env:LAUNCHER_FLOW_POWERSHELL_EXE -and
        [IO.Path]::GetFileName($env:LAUNCHER_FLOW_POWERSHELL_EXE) -in @('powershell.exe','pwsh.exe') -and
        (Test-Path -LiteralPath $env:LAUNCHER_FLOW_POWERSHELL_EXE -PathType Leaf)){
        return $env:LAUNCHER_FLOW_POWERSHELL_EXE
    }
    foreach($name in @('pwsh.exe','powershell.exe')){
        $path=Join-Path $PSHOME $name
        if(Test-Path -LiteralPath $path -PathType Leaf){return $path}
    }
    throw 'PowerShell runtime is unavailable. Open launcher.exe to install it automatically.'
}

function Start-LauncherProcess {
    param($Process,[string]$Label='Program')
    try{return $Process.Start()}
    catch{
        $cause=$_.Exception
        while($cause.InnerException){$cause=$cause.InnerException}
        $code=if($cause -is [ComponentModel.Win32Exception]){' Windows error '+$cause.NativeErrorCode+'.'}else{''}
        $message="Could not start $Label at '$($Process.StartInfo.FileName)'.$code $($cause.Message)"
        throw [InvalidOperationException]::new($message,$cause)
    }
}

function ConvertTo-LauncherConfigKey {
    param([string]$Name)
    if($Name -ieq 'MaxRestoringInstances'){return 'MaxReplacingInstances'}
    if($Name -match '^(?!(?:Launcher|Game|Cloudflare|LdPlayer))[A-Za-z]+(Package|OpenTimeout|RelaunchDelay)$'){return ('Launcher'+$Matches[1])}
    return $Name
}

function Read-FlowConfig {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Config file not found: $Path" }
    $values = @{
        ExcludedLdPlayerIds = ''; LdPlayerInstallPath = 'C:\LDPlayer\LDPlayer9'; LdConsolePath = ''; LogSnapshotLdPlayerId = ''
        GamePackages = ''; GamePackage = 'local.deltalite.a'; LauncherPackage = ''; ServerLink = ''; EmulatorsPerServerLink = '5'
        LdPlayerOpenTimeout = '120'; CloudflareOpenTimeout = '60'
        CloudflareConnectTimeout = '20'; LauncherOpenTimeout = '60'; GameJoinTimeout = '120'; GameHomeTimeout = '60'; GameReadyLogMarker = ''
        CommandTimeout = '30'; PollInterval = '1'; MinCheckDelay = '1'; RetryDelay = '2'
        InstanceLaunchDelay = '5'; InstanceRelaunchDelay = '10'
        MaxLoadingInstances = '5'; InstancesPerRow = '5'; LoadingInstanceThreshold = '10'; MaxLoadingInstancesAboveThreshold = '3'
        MaxLoadingApps = '2'
        AutoRestartHours = '0'; PostSyncDelay = '20'
        AuthUserAgent = ''
        OverwriteExistingCookies = '0'; SkipRepairNextStart = '0'
        CloudflareTimeoutLimit = '2'; InstanceOpenTimeoutLimit = '2'; GameOpenTimeoutLimit = '2'; AppCrashLimit = '2'
        PackageCheckFailuresBeforeRestart = '2'; PackageCheckRecoveryCyclesBeforeRestore = '2'; PackageCheckRetryDelay = '10'; CookieAuthenticationInterval = '0'
        MaxReplacingInstances = '1'; RestoreBackupFile = ''; RecoveryMode = 'Backup'; RecoveryTemplateId = '0'; ResetInstanceCount = '20'
        MaxInstanceLaunchAttempts = '3'; MaxCloudflareAttempts = '0'
        LauncherRelaunchDelay = '3'; MaxServerLinkAttempts = '0'
        MonitorGame = '1'; GameCheckInterval = '5'
        CloudflarePollInterval = '1'; CloudflareRetryDelay = '1'
    }
    $seen = @{}
    $numberedLinks = @{}
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith('#') -or $line.StartsWith(';')) { continue }
        $parts = $line -split '=', 2
        if ($parts.Count -ne 2) { throw "Invalid config line: $line" }
        $key = ConvertTo-LauncherConfigKey $parts[0].Trim()
        if ($key -eq 'LdPlayerIds') { throw 'Replace LdPlayerIds with ExcludedLdPlayerIds. The script discovers all other instances automatically.' }
        $isNumberedLink=$key -match '^ServerLink\.([1-9][0-9]*)$'
        $linkNumber=0
        if ($isNumberedLink -and -not [int]::TryParse($Matches[1],[ref]$linkNumber)) { throw "Invalid server-link number: $key" }
        if (-not $values.ContainsKey($key) -and -not $isNumberedLink) { throw "Unknown config setting: $key. Use numbered ServerLink.1, ServerLink.2 entries for server links." }
        if ($seen.ContainsKey($key)) { throw "Duplicate config setting: $key" }
        $seen[$key] = $true
        if ($isNumberedLink) { $numberedLinks[$linkNumber]=$parts[1].Trim() }
        else { $values[$key] = $parts[1].Trim() }
    }
    
    if (-not $seen.ContainsKey('GamePackage') -and $seen.ContainsKey('LauncherPackage')) {
        $values.GamePackage = $values.LauncherPackage
    }
    $packageText=$values.GamePackage
    if ($seen.ContainsKey('GamePackages')) { $packageText=$values.GamePackages }
    $packages=New-Object 'System.Collections.Generic.List[string]'
    foreach ($package in $packageText.Split(',')) {
        $package=$package.Trim()
        if ($package -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$') {
            throw 'GamePackages must contain Android package names separated by commas.'
        }
        if (-not $packages.Contains($package)) { $packages.Add($package) }
    }
    $values.GamePackages=$packages.ToArray()
    $values.GamePackage=$packages[0]
    $values.LauncherPackage=$packages[0]
    if ($values.GameReadyLogMarker -and $values.GameReadyLogMarker -notmatch '^[A-Za-z][A-Za-z0-9_]{0,79}$') {
        throw 'GameReadyLogMarker must be a single log word (letters, numbers, underscore), or blank.'
    }
    if ($values.AuthUserAgent.Length -gt 1024 -or $values.AuthUserAgent -cmatch '[^\x20-\x7e]') {
        throw 'AuthUserAgent must be a single ASCII header value without line breaks.'
    }
    $ids = New-Object 'System.Collections.Generic.List[int]'
    foreach ($value in $values.ExcludedLdPlayerIds.Split(',')) {
        if (-not $values.ExcludedLdPlayerIds) { break }
        $number = 0
        if ($value.Trim() -notmatch '^\d+$' -or -not [int]::TryParse($value.Trim(), [ref]$number)) {
            throw 'ExcludedLdPlayerIds must be blank or contain nonnegative IDs separated by commas, such as 0,1,2.'
        }
        if (-not $ids.Contains($number)) { $ids.Add($number) }
    }
    if($values.RecoveryMode -notin @('Template','Backup')){throw 'RecoveryMode must be Template or Backup.'}
    $templateId=0
    if(-not [int]::TryParse($values.RecoveryTemplateId,[ref]$templateId) -or $templateId -lt 0){throw 'RecoveryTemplateId must be a nonnegative instance ID.'}
    $values.RecoveryTemplateId=0
    if(-not $ids.Contains(0)){$ids.Add(0)}
    $values.ExcludedLdPlayerIds = $ids.ToArray()
    $snapshotId=-1
    if ($values.LogSnapshotLdPlayerId -ne '' -and ($values.LogSnapshotLdPlayerId -notmatch '^\d+$' -or -not [int]::TryParse($values.LogSnapshotLdPlayerId,[ref]$snapshotId))) {
        throw 'LogSnapshotLdPlayerId must be blank (disabled) or a nonnegative LDPlayer index.'
    }
    $values.LogSnapshotLdPlayerId=$snapshotId
    $values.LogSnapshotDirectory=Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))) 'logs'
    foreach ($key in @('MaxLoadingInstances', 'EmulatorsPerServerLink', 'LdPlayerOpenTimeout', 'CloudflareOpenTimeout', 'CloudflareConnectTimeout', 'LauncherOpenTimeout', 'GameJoinTimeout', 'GameHomeTimeout', 'CommandTimeout', 'PollInterval', 'MinCheckDelay', 'RetryDelay', 'InstanceLaunchDelay', 'InstanceRelaunchDelay', 'PostSyncDelay', 'MaxInstanceLaunchAttempts', 'MaxCloudflareAttempts', 'LauncherRelaunchDelay', 'MaxServerLinkAttempts', 'MonitorGame', 'GameCheckInterval', 'CloudflarePollInterval', 'CloudflareRetryDelay','OverwriteExistingCookies','SkipRepairNextStart','PackageCheckRetryDelay','CookieAuthenticationInterval')) {
        $number = 0
        $minimum = 1
        if ($key -in @('RetryDelay', 'InstanceLaunchDelay', 'InstanceRelaunchDelay', 'PostSyncDelay', 'MaxInstanceLaunchAttempts', 'MaxCloudflareAttempts', 'LauncherRelaunchDelay', 'MaxServerLinkAttempts', 'MonitorGame','OverwriteExistingCookies','SkipRepairNextStart','CookieAuthenticationInterval')) { $minimum = 0 }
        if (-not [int]::TryParse($values[$key], [ref]$number) -or $number -lt $minimum -or $number -gt 86400) {
            throw "$key must be a whole number from $minimum to 86400."
        }
        $values[$key] = $number
    }
    
    $values.Remove('MaxLoadingApps')
    foreach($key in @('LoadingInstanceThreshold','MaxLoadingInstancesAboveThreshold')){
        if($key -eq 'MaxLoadingInstancesAboveThreshold' -and -not $values[$key]){$values[$key]=[string]$values.MaxLoadingInstances}
        $number=0;$minimum=if($key -eq 'LoadingInstanceThreshold'){0}else{1}
        if(-not [int]::TryParse([string]$values[$key],[ref]$number) -or $number -lt $minimum -or $number -gt 1000){throw "$key must be a whole number from $minimum to 1000."}
        $values[$key]=$number
    }
    $restartHours=0.0
    if (-not [double]::TryParse($values.AutoRestartHours,[Globalization.NumberStyles]::AllowDecimalPoint,[Globalization.CultureInfo]::InvariantCulture,[ref]$restartHours) -or [double]::IsNaN($restartHours) -or [double]::IsInfinity($restartHours) -or $restartHours -lt 0 -or $restartHours -gt 87600) { throw 'AutoRestartHours must be 0 (disabled) or a positive number of hours, such as 6 or 1.5.' }
    $values.AutoRestartHours=$restartHours
    if ($values.MonitorGame -gt 1) { throw 'MonitorGame must be 0 (off) or 1 (on).' }
    if ($values.OverwriteExistingCookies -gt 1) { throw 'OverwriteExistingCookies must be 0 (off) or 1 (on).' }
    if ($values.SkipRepairNextStart -gt 1) { throw 'SkipRepairNextStart must be 0 (off) or 1 (on).' }
    foreach($key in @('CloudflareTimeoutLimit','InstanceOpenTimeoutLimit','GameOpenTimeoutLimit','AppCrashLimit','MaxReplacingInstances','PackageCheckFailuresBeforeRestart','PackageCheckRecoveryCyclesBeforeRestore')){
        $number=0
        if(-not [int]::TryParse($values[$key],[ref]$number) -or $number -lt 1 -or $number -gt 1000){throw "$key must be a whole number from 1 to 1000."}
        $values[$key]=$number
    }
    $resetCount=0
    if(-not [int]::TryParse([string]$values.ResetInstanceCount,[ref]$resetCount) -or $resetCount -lt 0 -or $resetCount -gt 1000){throw 'ResetInstanceCount must be a whole number from 0 to 1000, excluding template 0.'}
    $values.ResetInstanceCount=$resetCount
    $columns=0
    if(-not [int]::TryParse([string]$values.InstancesPerRow,[ref]$columns) -or $columns -lt 1 -or $columns -gt 50){throw 'InstancesPerRow must be a whole number from 1 to 50.'}
    $values.InstancesPerRow=$columns
    $values.ConfigFilePath=[IO.Path]::GetFullPath($Path)
    
    if ($seen.ContainsKey('LdConsolePath') -and -not $seen.ContainsKey('LdPlayerInstallPath')) {
        $values.LdPlayerInstallPath = [IO.Path]::GetDirectoryName($values.LdConsolePath)
    }
    $installFolder = [Environment]::ExpandEnvironmentVariables($values.LdPlayerInstallPath.Trim('"'))
    if (-not (Test-Path -LiteralPath $installFolder -PathType Container)) {
        throw "LDPlayer install folder was not found: $installFolder"
    }
    $values.LdPlayerInstallPath = $installFolder
    $values.LdConsolePath = ''
    foreach ($toolName in @('ldconsole.exe', 'dnconsole.exe')) {
        $toolPath = Join-Path $installFolder $toolName
        if (Test-Path -LiteralPath $toolPath -PathType Leaf) {
            $values.LdConsolePath = $toolPath
            break
        }
    }
    if (-not $values.LdConsolePath) {
        throw "Neither ldconsole.exe nor dnconsole.exe was found in $installFolder."
    }
    if ($values.GamePackage -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$') {
        throw 'GamePackage must be an Android package name, such as com.roblox.client.'
    }
    $links=New-Object 'System.Collections.Generic.List[string]'
    $entries=@($numberedLinks.Keys | Sort-Object | ForEach-Object {$numberedLinks[$_]})
    if ($numberedLinks.Count -eq 0) { $entries=@($values.ServerLink) }
    foreach ($link in $entries) {
        if (-not $link) { continue }
        $uri=$null
        if (-not [Uri]::TryCreate($link,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https') { throw 'Each ServerLink entry must be a complete https link.' }
        if ($links.Contains($link)) { throw 'Duplicate server link. Add a different server link for each group of emulators.' }
        $links.Add($link)
    }
    if ($links.Count -eq 0) { throw 'Add at least one server link using ServerLink.1=https://...' }
    $values.ServerLinks=$links.ToArray()
    $values.ServerLink=$links[0]
    $values.CookieStorePath=Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))) 'cookies.json'
    $hash=[Security.Cryptography.SHA256]::Create()
    try { $digest=[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($values.CookieStorePath.ToLowerInvariant()))).Replace('-','') } finally { $hash.Dispose() }
    $values.CookieStoreMutexName='Local\CodexCookieStore-'+$digest.Substring(0,24)
    $hash=[Security.Cryptography.SHA256]::Create()
    try{$installDigest=[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($values.LdPlayerInstallPath).ToLowerInvariant()))).Replace('-','')}finally{$hash.Dispose()}
    $values.RestoreMutexName='Local\CodexJoinerRestore-'+$installDigest.Substring(0,24)
    $values.RestoreStateDirectory=Initialize-LauncherRecoveryStateDirectory $values
    return $values
}

function Initialize-LauncherRecoveryStateDirectory {
    param($Settings,[string]$LegacyDirectory='')
    $configPath=if($Settings.ConfigFilePath){$Settings.ConfigFilePath}else{$Settings.CookieStorePath}
    $directory=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($configPath))
    if($Settings.RestoreMutexName -notmatch '-([A-Fa-f0-9]{24})$'){throw 'The recovery-state installation identity is unavailable.'}
    $digest=$Matches[1].ToUpperInvariant();$root=Join-Path $directory 'restore';$target=Join-Path $root $digest
    if(-not $LegacyDirectory){$LegacyDirectory=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('CodexJoiner\restore\'+$digest)}
    $legacy=[IO.Path]::GetFullPath($LegacyDirectory);$legacyParent=[IO.Path]::GetDirectoryName($legacy)
    Assert-InstanceReplacementDirectory $root $directory;Assert-InstanceReplacementDirectory $target $root
    Assert-InstanceReplacementDirectory $legacy $legacyParent
    if($legacy -ieq $target){throw 'The legacy and local recovery-state folders must be different.'}
    $mutex=New-Object Threading.Mutex $false,$Settings.RestoreMutexName
    $commit=New-Object Threading.Mutex $false,($Settings.RestoreMutexName+'-NewInstance');$held=$false;$commitHeld=$false
    try{
        try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
        if($held){try{$commitHeld=$commit.WaitOne(0)}catch [Threading.AbandonedMutexException]{$commitHeld=$true}}
        if(-not $held -or -not $commitHeld){throw 'Recovery state is in use. Wait for the active replacement before moving its state.'}
        $null=[IO.Directory]::CreateDirectory($target)
        if(-not [IO.Directory]::Exists($legacy)){return $target}
        $directories=New-Object 'System.Collections.Generic.List[string]';$directories.Add($legacy)
        $files=New-Object 'System.Collections.Generic.List[object]'
        for($index=0;$index -lt $directories.Count;$index++){
            foreach($item in @(Get-ChildItem -LiteralPath $directories[$index] -Force)){
                Assert-InstanceReplacementDirectory $item.FullName $legacy
                if($item.PSIsContainer){$directories.Add($item.FullName);continue}
                if($item.Name -match '^restore-\d+-[a-f0-9]{32}[.]json$'){
                    $record=ConvertFrom-Json ([IO.File]::ReadAllText($item.FullName))
                    if((Test-RestoreProcessAlive $record.WorkerPid $record.WorkerStartTicks) -or (Test-RestoreProcessAlive $record.NativePid $record.NativeStartTicks)){throw 'An existing worker still owns legacy recovery state. Stop that tool before migrating its files.'}
                }
                $relative=$item.FullName.Substring($legacy.TrimEnd('\').Length+1);$destination=Join-Path $target $relative
                Assert-InstanceReplacementDirectory $destination $target
                $hash=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
                if([IO.File]::Exists($destination) -and (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -cne $hash){throw 'Local and legacy recovery-state files differ. Both versions were kept; migration did not overwrite either file.'}
                $files.Add(@{Source=$item.FullName;Target=$destination;Hash=$hash})
            }
        }
        
        
        foreach($file in $files){
            $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file.Target))
            if(-not [IO.File]::Exists($file.Target)){
                $temp=$file.Target+'.migration-'+[guid]::NewGuid().ToString('N')+'.tmp'
                try{
                    [IO.File]::Copy($file.Source,$temp,$false);Flush-ReplacementFile $temp
                    if((Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash -cne $file.Hash){throw 'Recovery-state copy verification failed. Legacy files were kept.'}
                    [IO.File]::Move($temp,$file.Target)
                }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
            }
            if((Get-FileHash -LiteralPath $file.Target -Algorithm SHA256).Hash -cne $file.Hash){throw 'Local recovery-state verification failed. Legacy files were kept.'}
        }
        foreach($file in $files){
            if((Get-FileHash -LiteralPath $file.Source -Algorithm SHA256).Hash -cne $file.Hash){throw 'Legacy recovery state changed during migration. The remaining files were kept.'}
            [IO.File]::Delete($file.Source)
        }
        foreach($path in @($directories|Sort-Object Length -Descending)){if([IO.Directory]::Exists($path) -and [IO.Directory]::GetFileSystemEntries($path).Length -eq 0){[IO.Directory]::Delete($path,$false)}}
        return $target
    }finally{if($commitHeld){$commit.ReleaseMutex()};$commit.Dispose();if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
}

function Get-SelectedLdPlayerIds {
    param($Settings)
    $Config=$Settings
    $listing=Invoke-Ld -Arguments @('list2')
    $selected=New-Object 'System.Collections.Generic.List[int]'
    foreach($line in ($listing -split '\r?\n')){
        $fields=$line.Split(',')
        if($fields.Count -lt 7 -or $fields[0] -notmatch '^\d+$'){continue}
        $id=0
        if(-not [int]::TryParse($fields[0],[ref]$id)){continue}
        if($Settings.ExcludedLdPlayerIds -notcontains $id -and -not $selected.Contains($id)){$selected.Add($id)}
    }
    $pending=@(Get-PendingInstanceReplacements $Settings)
    $reserved=@($pending|ForEach-Object{[int]$_.NewId})
    foreach($entry in $pending){if(-not $selected.Contains([int]$entry.OldId)){$selected.Add([int]$entry.OldId)}}
    return ($selected.ToArray()|Where-Object{$reserved -notcontains $_}|Sort-Object)
}

function Get-EmulatorServerAssignments {
    param($Settings)
    $position=0
    $history=Read-InstanceReplacementHistory $Settings
    $positions=@{}
    $assigned=New-Object 'System.Collections.Generic.List[object]'
    foreach ($id in ($Settings.LdPlayerIds | Sort-Object -Unique | Sort-Object {Get-InstanceReplacementOrigin ([int]$_) $history})) {
        $origin=Get-InstanceReplacementOrigin ([int]$id) $history
        if(-not $positions.ContainsKey($origin)){$positions[$origin]=$position;$position++}
        $linkIndex=[int][math]::Floor($positions[$origin] / $Settings.EmulatorsPerServerLink)
        if ($linkIndex -ge $Settings.ServerLinks.Count) {
            Write-Host "Skipping LDPlayer $id : no server link remains within the $($Settings.EmulatorsPerServerLink)-emulator limit. Add another ServerLink entry."
        }
        else {
            $assigned.Add([pscustomobject]@{InstanceId=$id;ServerLink=$Settings.ServerLinks[$linkIndex];LinkNumber=($linkIndex+1)})
        }
    }
    return @($assigned.ToArray()|Sort-Object InstanceId)
}

function ConvertTo-NativeArgument {
    param([string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Test-StatusCheckCommand {
    param([string[]]$Arguments)
    if ($Arguments[0] -eq 'list2') { return $true }
    if ($Arguments[0] -ne 'adb') { return $false }
    $commandIndex = [array]::IndexOf($Arguments, '--command')
    if ($commandIndex -lt 0 -or $commandIndex + 1 -ge $Arguments.Count) { return $false }
    $command = $Arguments[$commandIndex + 1]
    return ($command -notmatch '^shell\s+(input|am|monkey|settings|rm)\b')
}

function Wait-StatusCheckSlot {
    param([int]$TimeoutSeconds)
    $minimum = [math]::Max(1, [int]$Config.MinCheckDelay)
    if ($script:LastStatusCheckFinishedTicks -gt 0) {
        $elapsed = ([Diagnostics.Stopwatch]::GetTimestamp() - $script:LastStatusCheckFinishedTicks) / [double][Diagnostics.Stopwatch]::Frequency
        $delay = $minimum - $elapsed
        if ($delay -gt 0) {
            if ($delay -ge $TimeoutSeconds) { throw [TimeoutException]::new('The check deadline expired while waiting for the minimum check interval.') }
            Start-Sleep -Milliseconds ([int][math]::Ceiling($delay * 1000))
        }
    }
}

function Clear-ProcessCheckCache {
    $script:ProcessCheckCacheTicks = 0
    $script:ProcessCheckCache = $null
    $script:AppCrashWindowCacheTicks=0
    $script:AppWindowSnapshotTicks=0
}

function Invoke-Ld {
    param([string[]]$Arguments, [int]$TimeoutSeconds = $Config.CommandTimeout)
    $TimeoutSeconds=[math]::Max(10,$TimeoutSeconds)
    if($Arguments[0] -eq 'runapp' -and $Arguments[-1] -ceq $Config.GamePackage){
        Enter-EmulatorLoadingSlot
        Prepare-GameAppDataForOpening -Package $Config.GamePackage
        Clear-PendingCrashedAppCache -Package $Config.GamePackage
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $isCheck = Test-StatusCheckCommand -Arguments $Arguments
    if ($isCheck) { Wait-StatusCheckSlot -TimeoutSeconds $TimeoutSeconds }
    else { Clear-ProcessCheckCache }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Config.LdConsolePath
    $info.Arguments = (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    $started = $false
    try {
        $remaining = [int](($TimeoutSeconds * 1000) - $timer.ElapsedMilliseconds)
        if ($remaining -le 0) { throw [TimeoutException]::new('The command deadline expired before execution.') }
        if (-not (Start-LauncherProcess $process 'LDPlayer command')) { throw 'LDPlayer command could not be started.' }
        $started = $true
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($remaining)) {
            try { $process.Kill() } catch {}
            if($Arguments[0] -eq 'runapp' -and $Arguments[-1] -ceq $Config.GamePackage){Register-FlowStageTimeout -Stage Game}
            throw (New-LdCommandTimeoutError "LDPlayer command exceeded $TimeoutSeconds seconds: $($Arguments -join ' ')")
        }
        $remaining = [int][math]::Max(1, ($TimeoutSeconds * 1000) - $timer.ElapsedMilliseconds)
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), $remaining)) {
            if($Arguments[0] -eq 'runapp' -and $Arguments[-1] -ceq $Config.GamePackage){Register-FlowStageTimeout -Stage Game}
            throw (New-LdCommandTimeoutError "Timed out reading LDPlayer command result after $TimeoutSeconds seconds: $($Arguments -join ' ')")
        }
        $output = $stdout.Result + "`n" + $stderr.Result
        if ($process.ExitCode -ne 0) {
            $details=$output.Trim()
            if (-not $details) { $details="exit code $($process.ExitCode), no output" }
            throw ('LDPlayer command failed: ' + $details)
        }
        return $output.Trim()
    }
    finally {
        $process.Dispose()
        if ($isCheck -and $started) { $script:LastStatusCheckFinishedTicks = [Diagnostics.Stopwatch]::GetTimestamp() }
    }
}

function New-LdCommandTimeoutError {
    param([string]$Message)
    
    
    if($script:PoolRole -and $InstanceIndex -ge 0 -and -not $script:ReplacementFileTransaction){
        $script:PendingEmulatorRestore=$Message
        Write-FlowStatus ($Message+'. Instance replacement queued for only this emulator through the loading/replacement limits.')
        $signal=[OperationCanceledException]::new($Message)
        $signal.Data['PoolNeedsSetup']=$true
        $signal.Data['RestoreRequired']=$true
        $signal.Data['LdCommandTimedOut']=$true
        return $signal
    }
    return [TimeoutException]::new($Message)
}

function Get-CommandBudget {
    param([datetime]$Deadline)
    $remaining = [int][math]::Ceiling(($Deadline - [datetime]::UtcNow).TotalSeconds)
    if ($remaining -le 0) { throw [TimeoutException]::new('The waiting period expired.') }
    return [math]::Min($Config.CommandTimeout, $remaining)
}

function Invoke-Android {
    param([string]$Command, [int]$TimeoutSeconds = $Config.CommandTimeout)
    Invoke-Ld -Arguments @('adb', '--index', "$InstanceIndex", '--command', $Command) -TimeoutSeconds $TimeoutSeconds
}

function Get-InstanceInfo {
    param([int]$Id, [int]$TimeoutSeconds = $Config.CommandTimeout)
    $instances = Invoke-Ld -Arguments @('list2') -TimeoutSeconds $TimeoutSeconds
    foreach ($line in ($instances -split '\r?\n')) {
        $fields = $line.Split(',')
        if ($fields.Count -ge 7 -and $fields[0] -ceq "$Id") {
            return [pscustomobject]@{ Id = $Id; AndroidStarted = ($fields[4] -eq '1'); ProcessId = [int]$fields[5] }
        }
    }
    return $null
}

function Write-FlowStatus {
    param([string]$Message)
    $prefix="[LDPlayer $InstanceIndex]"
    if ($Config.GamePackages.Count -gt 1) { $prefix+="[$($Config.GamePackage)]" }
    Write-Host "$prefix $Message"
}

function Write-WorkerRetryStatus {
    param([Exception]$Failure,[int]$RetrySeconds,[switch]$ReplacementActive)
    
    
    $Config=$Config.Clone()
    $package=[string]$Failure.Data['GamePackage']
    if(-not $package){$package=[string]$script:PoolActivePackage}
    if($package -and @($Config.GamePackages) -ccontains $package){$Config.GamePackage=$package}
    $delay=[math]::Max(1,$RetrySeconds)
    $reason=$Failure.Message.TrimEnd([char[]]' .')
    if($ReplacementActive){$label='Instance replacement attempt failed'}
    elseif($Failure.Data['AppCacheCleanupFailed']){$label='Crash cache cleanup incomplete'}
    elseif($Failure.Data['InstanceInventoryUnavailable']){$label='Emulator inventory check incomplete'}
    elseif($Failure.Data['GameStatusReadFailed']){$label='Game-status check incomplete'}
    elseif($Failure.Data['PackageCheckUnavailable']){$label='Installed-package check incomplete'}
    elseif($Failure.Data['RestoreRequired'] -or $Failure.Data['LdCommandTimedOut']){$label='Emulator recovery requested'}
    elseif($script:RecoveryScope -eq 'VPN'){$label='VPN check failed'}
    elseif($script:RecoveryScope -in @('Startup','Packages')){$label='Emulator setup check failed'}
    elseif($script:RecoveryScope -eq 'Game'){$label='App check failed'}
    else{$label='Worker check failed'}
    Write-FlowStatus "$label. Retrying in $delay seconds. Reason: $reason."
}

function Set-BootRequestPhase {
    param([string]$Phase)
    if ($null -eq $script:BootRequestRecord) { return }
    $updated=$script:BootRequestRecord.Clone()
    $updated.Phase=$Phase
    [IO.File]::WriteAllText($script:BootRequestPath,($updated|ConvertTo-Json -Compress))
    $script:BootRequestRecord=$updated
}

function Get-LoadingLimitPolicy {
    param($Settings,$Inventory=$null)
    $low=[math]::Max(1,[int]$Settings.MaxLoadingInstances);$high=$low;$threshold=0
    if($Settings.MaxLoadingInstancesAboveThreshold){$high=[math]::Max(1,[int]$Settings.MaxLoadingInstancesAboveThreshold)}
    if($Settings.LoadingInstanceThreshold){$threshold=[math]::Max(0,[int]$Settings.LoadingInstanceThreshold)}
    $dynamic=$threshold -gt 0 -and $low -ne $high
    $running=0;if($null -ne $Inventory){$running=@($Inventory.Values|Where-Object{$_.ProcessId -gt 0 -or $_.AndroidStarted}).Count}
    $limit=if($dynamic -and $running -gt $threshold){$high}else{$low}
    return @{Limit=$limit;RunningCount=$running;Threshold=$threshold;LowLimit=$low;HighLimit=$high;WorkerCapacity=[math]::Max($low,$high);Dynamic=$dynamic}
}

function New-BootScheduler {
    param($Settings,[string]$StateFile)
    
    
    $Settings.LdPlayerIds=@($Settings.LdPlayerIds|ForEach-Object{[int]$_}|Sort-Object -Unique)
    $policy=Get-LoadingLimitPolicy $Settings
    return @{Settings=$Settings;Directory=[IO.Path]::GetDirectoryName($StateFile);Active=@{};InitialPending=@($Settings.LdPlayerIds);LastPollTicks=0;ReadFailureReported=$false;CurrentLimit=$(if($policy.Dynamic){$null}else{$policy.LowLimit});RunningCount=$null}
}

function Read-DynamicLaunchGate {
    param([string]$Directory)
    $path=Join-Path $Directory 'boot-launch-gate.json'
    if(-not [IO.File]::Exists($path)){return $null}
    $gate=ConvertFrom-Json ([IO.File]::ReadAllText($path))
    if($gate.Version -ne 1 -or $gate.Owner -notmatch '^[a-f0-9]{32}$' -or $gate.Id -lt 0 -or [long]$gate.CreatedTicks -le 0){throw 'The pending emulator launch reservation is invalid.'}
    return $gate
}

function Update-DynamicLaunchGate {
    param($Scheduler,[object[]]$Records,$ReserveRecord=$null)
    $mutex=New-Object Threading.Mutex $false,$Scheduler.Settings.PoolLaunchMutexName;$held=$false
    try{
        try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not $held){return @{Busy=$true;Owner=''}}
        $gate=Read-DynamicLaunchGate $Scheduler.Directory
        if($gate){
            
            $owner=@($Records|Where-Object{$_.LaunchOwner -ceq $gate.Owner})|Select-Object -First 1
            $fresh=[long]$Scheduler.InventoryTicks -ge [long]$gate.CreatedTicks
            $row=if($owner -and $Scheduler.Inventory){$Scheduler.Inventory[[int]$owner.Id]}else{$null}
            $opened=$fresh -and $row -and $row.ProcessId -gt 0 -and ($owner.Id -ne $gate.Id -or $row.ProcessId -ne $gate.PreviousProcessId)
            if(-not $owner -or $opened -or ($fresh -and -not $owner.BusyRole -and $owner.Status -ne 'NeedsSetup')){
                [IO.File]::Delete((Join-Path $Scheduler.Directory 'boot-launch-gate.json'));$gate=$null
            }
        }
        if(-not $gate -and $ReserveRecord){
            if(-not $ReserveRecord.LaunchOwner){$ReserveRecord.LaunchOwner=[guid]::NewGuid().ToString('N')}
            $gate=@{Version=1;Owner=$ReserveRecord.LaunchOwner;Id=[int]$ReserveRecord.Id;PreviousProcessId=0;CreatedTicks=[datetime]::UtcNow.Ticks}
            Write-TemplateStageManifest (Join-Path $Scheduler.Directory 'boot-launch-gate.json') $gate
        }
        $Scheduler.LaunchOwnerId=if($gate){$logical=@($Records|Where-Object{$_.LaunchOwner -ceq $gate.Owner})|Select-Object -First 1;if($logical){[int]$logical.Id}else{[int]$gate.Id}}else{$null}
        return @{Busy=$false;Owner=$(if($gate){$gate.Owner}else{''});Id=$(if($gate){$gate.Id}else{$null})}
    }finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
}

function Reserve-DynamicEmulatorLaunch {
    param($Current)
    if(-not $LaunchStateFile -or -not (Get-LoadingLimitPolicy $Config).Dynamic){return}
    
    
    $inventory=Get-BootInventory $Config;$policy=Get-LoadingLimitPolicy $Config $inventory
    $directory=[IO.Path]::GetDirectoryName($LaunchStateFile)
    $published=ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $directory 'loading-policy.json')))
    $allowed=@($published.Allowed|Sort-Object {[int]$_.Id}|Select-Object -First $policy.Limit|Where-Object{$_.Id -eq $InstanceIndex -and $_.Token -ceq $script:BootRequestRecord.Token})
    $gate=Read-DynamicLaunchGate $directory
    $control=if($PoolWorkerControl){$PoolWorkerControl}else{$script:BootRequestRecord}
    if(-not $control.LaunchOwner){$control.LaunchOwner=[guid]::NewGuid().ToString('N')}
    $otherLoads=[math]::Max(0,[int]$published.ActiveCount-1)
    if(Test-ThresholdLaunchWait $Config $inventory $InstanceIndex $otherLoads){
        
        
        if($gate -and $gate.Owner -ceq $control.LaunchOwner){[IO.File]::Delete((Join-Path $directory 'boot-launch-gate.json'))}
        $signal=[OperationCanceledException]::new('Waiting for the current loading group to finish before starting an emulator that would reduce the loading limit.')
        $signal.Data['PoolNeedsSetup']=$true;$signal.Data['DynamicLaunchDeferred']=$true;throw $signal
    }
    if(-not $published.Available -or -not $allowed.Count -or ($gate -and $gate.Owner -cne $control.LaunchOwner)){
        $signal=[OperationCanceledException]::new('Waiting for the preceding emulator to open and the running-count limit to allow another start.')
        $signal.Data['PoolNeedsSetup']=$true;$signal.Data['DynamicLaunchDeferred']=$true;throw $signal
    }
    if(-not $gate -or $gate.Id -ne $InstanceIndex){
        $gate=@{Version=1;Owner=$control.LaunchOwner;Id=$InstanceIndex;PreviousProcessId=$(if($Current){[int]$Current.ProcessId}else{0});CreatedTicks=[datetime]::UtcNow.Ticks}
        Write-TemplateStageManifest (Join-Path $directory 'boot-launch-gate.json') $gate
    }
}

function Test-ThresholdLaunchWait {
    param($Settings,$Inventory,[int]$Id,[int]$OtherLoads)
    $policy=Get-LoadingLimitPolicy $Settings $Inventory
    if(-not $policy.Dynamic -or $policy.HighLimit -ge $policy.LowLimit -or $policy.RunningCount -ne $policy.Threshold -or $OtherLoads -le 0){return $false}
    $row=$Inventory[$Id]
    
    return (-not $row -or ($row.ProcessId -le 0 -and -not $row.AndroidStarted))
}

function Publish-LoadingActionPolicy {
    param($Scheduler,$Policy,[bool]$Available=$true)
    
    
    $allowed=@(if($Available){foreach($id in @($Scheduler.Active.Keys|ForEach-Object{[int]$_}|Sort-Object|Select-Object -First $Policy.Limit)){
        @{Id=$id;Token=$Scheduler.Active[$id].Token}
    }})
    $record=@{Version=1;Available=$Available;RunningCount=$Policy.RunningCount;Limit=$Policy.Limit;Threshold=$Policy.Threshold;Dynamic=$Policy.Dynamic;ActiveCount=$Scheduler.Active.Count;Allowed=$allowed}
    $fingerprint=$record|ConvertTo-Json -Depth 5 -Compress
    if($Scheduler.ActionPolicyFingerprint -ceq $fingerprint){return}
    Write-TemplateStageManifest -Path (Join-Path $Scheduler.Directory 'loading-policy.json') -Manifest $record
    $Scheduler.ActionPolicyFingerprint=$fingerprint
}

function Test-LoadingActionPermission {
    if(-not $LaunchStateFile -or -not (Get-LoadingLimitPolicy $Config).Dynamic){return $true}
    try{
        $policy=ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path ([IO.Path]::GetDirectoryName($LaunchStateFile)) 'loading-policy.json')))
        if($policy.Version -ne 1 -or -not $policy.Available){return $false}
        return @($policy.Allowed|Where-Object{[int]$_.Id -eq $InstanceIndex -and $_.Token -ceq $script:BootRequestRecord.Token}).Count -eq 1
    }catch{return $false}
}

function Wait-LoadingActionPermission {
    $reported=$false
    Assert-PoolSetupTurn
    while(-not (Test-LoadingActionPermission)){
        Assert-PoolSetupTurn
        if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Stopped while waiting for the current loading limit.')}
        if(-not $reported){Write-FlowStatus 'Waiting before the next loading action: the current running-count limit must allow this slot. Existing games remain open.';$reported=$true}
        Start-Sleep -Milliseconds 500
    }
    if($reported){Write-FlowStatus 'The current loading limit allows this slot. Continuing setup.'}
}

function Get-BootInventory {
    param($Settings,[switch]$AllowUnavailable)
    $Config=$Settings
    $inventory=@{}
    if($AllowUnavailable){
        
        
        try{$listing=[string]({param($ProbeSettings)$Config=$ProbeSettings;Invoke-Ld -Arguments @('list2')}.InvokeReturnAsIs($Settings))}
        catch [System.Management.Automation.PipelineStoppedException]{throw}
        catch{return $null}
    }else{$listing=Invoke-Ld -Arguments @('list2')}
    foreach($line in ($listing -split '\r?\n')){
        $fields=$line.Split(',')
        if($fields.Count -lt 7 -or $fields[0] -notmatch '^\d+$'){continue}
        $id=0;$uiPid=0;$vmPid=0
        if(-not [int]::TryParse($fields[0],[ref]$id) -or -not [int]::TryParse($fields[5],[ref]$uiPid) -or -not [int]::TryParse($fields[6],[ref]$vmPid)){continue}
        $inventory[$id]=[pscustomobject]@{Id=$id;ProcessId=[math]::Max($uiPid,$vmPid);UiProcessId=$uiPid;VmProcessId=$vmPid;AndroidStarted=($fields[4] -eq '1')}
    }
    if($inventory.Count -eq 0){if($AllowUnavailable){return $null};throw 'LDPlayer returned no usable boot-status records.'}
    return $inventory
}

function Update-BootScheduler {
    param($Scheduler,[int[]]$AliveIds)
    $settings=$Scheduler.Settings
    $now=[datetime]::UtcNow
    if ($Scheduler.LastPollTicks -gt 0 -and ($now.Ticks-$Scheduler.LastPollTicks)/[double][TimeSpan]::TicksPerSecond -lt [math]::Max(1,$settings.PollInterval)) { return }
    $Scheduler.LastPollTicks=$now.Ticks
    $requests=@{}
    foreach ($id in $settings.LdPlayerIds) {
        $file=Join-Path $Scheduler.Directory ("boot-request-$id.json")
        if (-not [IO.File]::Exists($file)) { continue }
        try {
            $request=[IO.File]::ReadAllText($file)|ConvertFrom-Json
            if ([int]$request.Id -eq $id -and $request.Token -match '^[a-f0-9]{32}$') { $requests[$id]=$request }
        } catch { } 
    }
    foreach ($id in @($Scheduler.Active.Keys)) {
        $active=$Scheduler.Active[$id]
        $request=$requests[$id]
        if ($AliveIds -notcontains $id -or ($request -and ($request.Token -ne $active.Token -or $request.Phase -in @('Finished','Failed','WaitingForCookie')))) {
            $Scheduler.Active.Remove($id)
        } elseif ($request.Phase -eq 'Waiting' -and [long]$active.ExpiresTicks -le $now.Ticks) {
            $Scheduler.Active.Remove($id)
        }
    }
    $Scheduler.InitialPending=@($Scheduler.InitialPending|Where-Object{$AliveIds -contains $_ -and -not $requests.ContainsKey($_)})
    $waiting=@($requests.Keys|Where-Object{$AliveIds -contains $_ -and $requests[$_].Phase -eq 'Waiting' -and -not $Scheduler.Active.ContainsKey($_)})
    $policy=Get-LoadingLimitPolicy $settings
    if(-not $policy.Dynamic){
        $Scheduler.CurrentLimit=$policy.LowLimit
        if($waiting.Count -eq 0 -or $Scheduler.Active.Count -ge $policy.LowLimit){return}
        foreach($id in $Scheduler.Active.Keys){if(-not $requests.ContainsKey($id) -or $requests[$id].Phase -eq 'Waiting'){return}}
    }
    $inventory=$null
    try { $inventory=Get-BootInventory -Settings $settings -AllowUnavailable }
    catch [System.Management.Automation.PipelineStoppedException] { throw }
    catch [OperationCanceledException] { throw }
    catch {$inventory=$null}
    if($null -eq $inventory -or $inventory.Count -eq 0){
        if (-not $Scheduler.ReadFailureReported) { Write-Host 'LDPlayer inventory is temporarily unavailable (empty, invalid or failed response). New loading slots are paused; active workers and games remain running. Retrying the inventory read.' }
        $Scheduler.ReadFailureReported=$true
        if($policy.Dynamic){$Scheduler.CurrentLimit=0;Publish-LoadingActionPolicy $Scheduler $policy $false}
        return 
    }
    if($Scheduler.ReadFailureReported){Write-Host 'LDPlayer inventory is available again. Resuming the loading queue with the current running count.'}
    $Scheduler.ReadFailureReported=$false
    $policy=Get-LoadingLimitPolicy $settings $inventory
    if($policy.Dynamic -and $Scheduler.CurrentLimit -ne $policy.Limit){
        Write-Host "Loading limit is now $($policy.Limit): $($policy.RunningCount) emulators running (threshold $($policy.Threshold); $($policy.LowLimit) at/below, $($policy.HighLimit) above). Excess workers return their emulators to the queue before their next setup action; current joins may finish."
    }
    $Scheduler.CurrentLimit=$policy.Limit;$Scheduler.RunningCount=$policy.RunningCount
    $Scheduler.Inventory=$inventory;$Scheduler.InventoryTicks=[datetime]::UtcNow.Ticks
    Publish-LoadingActionPolicy $Scheduler $policy
    if($waiting.Count -eq 0){return}
    
    
    
    foreach($id in @($waiting|Where-Object{-not $inventory.ContainsKey([int]$_)})){
        $paths=Get-InstanceReplacementPaths $settings
        if(-not $paths){continue}
        $path=Join-Path $paths.State "replacement-$id.json"
        if(-not [IO.File]::Exists($path)){continue}
        $pending=ConvertFrom-Json ([IO.File]::ReadAllText($path))
        if($pending.Kind -ceq 'InstanceReplacement' -and $pending.OldId -eq $id -and $pending.NewId -gt $id -and (Test-InstanceReplacementPending $pending)){
            $inventory[[int]$id]=@{Id=[int]$id;ProcessId=0;AndroidStarted=$false;ReplacementOnly=$true}
        }
    }
    
    
    foreach($id in $Scheduler.Active.Keys){if(-not $requests.ContainsKey($id) -or $requests[$id].Phase -eq 'Waiting'){return}}
    if($Scheduler.Active.Count -ge $policy.Limit){return}
    $Scheduler.InitialPending=@($Scheduler.InitialPending|Where-Object{$inventory.ContainsKey($_)})
    $loading=New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($row in $inventory.Values) { if ($row.ProcessId -gt 0 -and -not $row.AndroidStarted) { $null=$loading.Add([int]$row.Id) } }
    foreach ($id in $Scheduler.Active.Keys) { $null=$loading.Add([int]$id) }
    
    $candidates=@($waiting|Where-Object{$inventory.ContainsKey($_) -and ($loading.Count -lt $policy.Limit -or $loading.Contains([int]$_))})
    $pendingEligible=@($Scheduler.InitialPending|Where-Object{$loading.Count -lt $policy.Limit -or $loading.Contains([int]$_)})
    $priority=@(@($candidates)+@($pendingEligible)|ForEach-Object{[int]$_}|Sort-Object -Unique)
    
    
    if($null -ne $Scheduler.LaunchOwnerId -and $candidates -contains [int]$Scheduler.LaunchOwnerId){$priority=@([int]$Scheduler.LaunchOwnerId)}
    if ($priority.Count -eq 0 -or $candidates -notcontains $priority[0]) { return }
    $id=[int]$priority[0]
    $leaseSeconds=[math]::Max(60,[math]::Max($settings.InstanceLaunchDelay,$settings.InstanceRelaunchDelay)+$settings.CommandTimeout+$settings.LdPlayerOpenTimeout+60)
    if ($requests[$id].RestartRunning) { $leaseSeconds += 4*$settings.CommandTimeout+$settings.LdPlayerOpenTimeout+$settings.InstanceRelaunchDelay }
    $grant=@{Token=$requests[$id].Token;ExpiresTicks=$now.AddSeconds($leaseSeconds).Ticks.ToString()}
    $Scheduler.Active[$id]=@{Token=$grant.Token;ExpiresTicks=$grant.ExpiresTicks}
    try{
        Publish-LoadingActionPolicy $Scheduler $policy
        [IO.File]::WriteAllText((Join-Path $Scheduler.Directory ("boot-grant-$id.json")),($grant|ConvertTo-Json -Compress))
    }catch{
        $Scheduler.Active.Remove($id)
        Publish-LoadingActionPolicy $Scheduler $policy
        throw
    }
    $null=$loading.Add($id)
    Write-Host "LDPlayer $id received a setup slot ($($loading.Count)/$($policy.Limit)). The slot stays occupied until all game apps join, or a login app waits for a missing cookie."
}

function Request-EmulatorLoadingSlot {
    param([switch]$RestartRunning)
    Assert-PoolSetupTurn
    if ($script:BootRequestRecord.Phase -eq 'SettingUp') { Wait-LoadingActionPermission;return }
    $directory=[IO.Path]::GetDirectoryName($LaunchStateFile)
    $script:BootRequestPath=Join-Path $directory ("boot-request-$InstanceIndex.json")
    $script:BootRequestRecord=@{Id=$InstanceIndex;Token=[guid]::NewGuid().ToString('N');Phase='Waiting';RestartRunning=[bool]$RestartRunning}
    Set-BootRequestPhase -Phase Waiting
    $grantPath=Join-Path $directory ("boot-grant-$InstanceIndex.json")
    $policy=Get-LoadingLimitPolicy $Config
    $limitText=if($policy.Dynamic){"$($policy.LowLimit) slots at/below $($policy.Threshold) running, $($policy.HighLimit) above"}else{"maximum $($policy.LowLimit)"}
    Write-FlowStatus "Waiting for an emulator setup slot ($limitText; lower IDs have priority)..."
    while ($true) {
        Assert-PoolSetupTurn
        try {
            $grant=[IO.File]::ReadAllText($grantPath)|ConvertFrom-Json
            if ($grant.Token -eq $script:BootRequestRecord.Token -and [long]$grant.ExpiresTicks -gt [datetime]::UtcNow.Ticks) { return $grant }
        } catch { }
        Start-Sleep -Seconds ([math]::Max(1,$Config.PollInterval))
    }
}

function Enter-EmulatorLoadingSlot {
    if (-not $LaunchStateFile) { return }
    if($script:BootRequestRecord.Phase -ne 'SettingUp'){
        $null=Request-EmulatorLoadingSlot
        Set-BootRequestPhase SettingUp
    }
    Wait-LoadingActionPermission
}

function Invoke-SpacedEmulatorLaunch {
    param([switch]$Relaunch,[switch]$RestartRunning)
    $grant=Request-EmulatorLoadingSlot -RestartRunning:$RestartRunning
    try {
        Invoke-ReservedEmulatorLaunch -Relaunch:$Relaunch -RestartRunning:$RestartRunning -Grant $grant
    }
    catch {
        if ($script:BootRequestRecord.Phase -eq 'Waiting') { Set-BootRequestPhase Failed }
        throw
    }
}

function Invoke-ReservedEmulatorLaunch {
    param([switch]$Relaunch,[switch]$RestartRunning,$Grant)
    if($Grant -and $script:BootRequestRecord.Phase -ne 'SettingUp' -and [long]$Grant.ExpiresTicks -le [datetime]::UtcNow.Ticks){throw [TimeoutException]::new('Setup slot expired before acknowledgement. Retrying through the queue.')}
    
    
    Set-BootRequestPhase SettingUp
    while($true){
    
    Wait-LoadingActionPermission
    $mutex = New-Object Threading.Mutex $false, $LaunchMutexName
    $held = $false
    try {
        while (-not $held) {
            try { $held = $mutex.WaitOne(1000) }
            catch [Threading.AbandonedMutexException] { $held = $true }
        }
        $spacing = $Config.InstanceLaunchDelay
        if ($Relaunch) { $spacing = $Config.InstanceRelaunchDelay }
        if (Test-Path -LiteralPath $LaunchStateFile) {
            $lastTicks = [long]([IO.File]::ReadAllText($LaunchStateFile))
            $last = [datetime]::new($lastTicks, [DateTimeKind]::Utc)
            $delay = $spacing - ([datetime]::UtcNow - $last).TotalSeconds
            if ($delay -gt 0) {
                Write-FlowStatus ('Waiting ' + [math]::Ceiling($delay) + ' seconds for the next launch slot...')
                Start-Sleep -Milliseconds ([int][math]::Ceiling($delay * 1000))
            }
        }
        if(-not (Test-LoadingActionPermission)){continue}
        $current=Get-InstanceInfo -Id $InstanceIndex
        if($null -eq $current -or $current.ProcessId -le 0 -or $RestartRunning){Reserve-DynamicEmulatorLaunch $current}
        if ($null -ne $current -and $current.ProcessId -gt 0) {
            if (-not $RestartRunning) { return }
            Write-FlowStatus 'Scheduled restart slot and delay are available. Closing running user apps first...'
            Set-EmulatorLiveObservation -EmulatorState Restarting -ResetApps
            Close-AppsBeforeEmulatorRestart
            Invoke-Ld -Arguments @('quit','--index',"$InstanceIndex") | Out-Null
            $closeDeadline=[datetime]::UtcNow.AddSeconds($Config.LdPlayerOpenTimeout)
            do {
                $current=Get-InstanceInfo -Id $InstanceIndex -TimeoutSeconds (Get-CommandBudget $closeDeadline)
                if ($null -eq $current -or $current.ProcessId -le 0) { break }
                Start-Sleep -Seconds ([math]::Max(1,$Config.PollInterval))
            } while ([datetime]::UtcNow -lt $closeDeadline)
            if ($null -ne $current -and $current.ProcessId -gt 0) { throw [TimeoutException]::new('LDPlayer did not close for its scheduled restart.') }
            Start-Sleep -Seconds $Config.InstanceRelaunchDelay
        }
        if(-not (Test-LoadingActionPermission)){continue}
        Assert-PoolSetupTurn
        Write-FlowStatus 'Starting emulator...'
        Set-EmulatorLiveObservation -EmulatorState Starting -ResetApps
        $script:GameLinkSentAt=@{}
        $script:CloudflareUidCache=$null
        $script:CloudflareUidCacheTicks=0
        try { Invoke-Ld -Arguments @('launch', '--index', "$InstanceIndex") | Out-Null }
        catch [TimeoutException] {Register-FlowStageTimeout -Stage Instance;throw}
        finally { [IO.File]::WriteAllText($LaunchStateFile, ([datetime]::UtcNow.Ticks).ToString()) }
        return
    }
    finally {
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
    }
}

function Close-AppsBeforeEmulatorRestart {
    
    
    $installed=Invoke-Android 'shell pm list packages -3'
    $packages=@($Config.GamePackages)+@($CloudflarePackage)
    foreach ($line in ($installed -split '\r?\n')) {
        if ($line -match '^package:([A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+)\s*$') { $packages+= $Matches[1] }
    }
    $packages=@($packages|Where-Object{$_ -match '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$'}|Sort-Object -Unique)
    $command='shell for p in '+($packages -join ' ')+'; do if pidof $p >/dev/null 2>&1; then if ! am force-stop $p; then echo APP_CLOSE_FAILED:$p; exit 1; fi; if pidof $p >/dev/null 2>&1; then echo APP_CLOSE_FAILED:$p; exit 1; fi; fi; done'
    $result=Invoke-Android $command
    if ($result -match 'APP_CLOSE_FAILED:') { throw 'A running app did not close yet. Emulator restart will retry before closing LDPlayer.' }
    Invoke-Android 'shell sync' | Out-Null
    if ($Config.PostSyncDelay -gt 0) {
        Write-FlowStatus "Sync finished. Waiting $($Config.PostSyncDelay) seconds before closing LDPlayer..."
        Start-Sleep -Seconds $Config.PostSyncDelay
    }
    Start-Sleep -Seconds ([math]::Max(1,$Config.LauncherRelaunchDelay))
}

function Invoke-ScheduledEmulatorRestart {
    param($InstanceInfo)
    if (-not $Config.AutoRestartHours -or $null -eq $InstanceInfo -or $InstanceInfo.ProcessId -le 0) { return $false }
    if ($script:EmulatorUptimeProcessId -ne $InstanceInfo.ProcessId) {
        $script:EmulatorUptimeProcessId=$InstanceInfo.ProcessId
        $script:EmulatorUptimeSince=[datetime]::UtcNow
        try { $script:EmulatorUptimeSince=(Get-Process -Id $InstanceInfo.ProcessId -ErrorAction Stop).StartTime.ToUniversalTime() } catch { }
    }
    if (([datetime]::UtcNow-$script:EmulatorUptimeSince).TotalHours -lt $Config.AutoRestartHours) { return $false }
    if ($Config.CookieStorePath -and -not (Save-LoadedEmulatorAppData -BootIdentity $InstanceInfo.ProcessId -Force)) {
        Write-FlowStatus 'Scheduled restart is waiting for the initial cookie capture to finish. Retrying at the next game check.'
        return $false
    }
    Write-FlowStatus "Auto restart is due after $($Config.AutoRestartHours) hours. Keeping the emulator open until its restart slot and delay are available..."
    Invoke-SpacedEmulatorLaunch -Relaunch -RestartRunning
    Start-SelectedEmulator
    $script:EmulatorUptimeProcessId=0
    Clear-ProcessCheckCache
    return $true
}

function Wait-FlowPause {
    param([int]$Seconds)
    for($remaining=$Seconds;$remaining -gt 0;$remaining--){
        if($script:PoolRole -eq 'Setup'){Assert-PoolSetupTurn}
        if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Tool stopped.')}
        Start-Sleep -Seconds 1
    }
}

function Ensure-SessionVpn {
    param([switch]$Force)
    if(-not $Force -and $script:CookieBootIdentity -gt 0 -and $script:VpnVerifiedBoot -eq $script:CookieBootIdentity){return}
    $script:RecoveryScope='VPN'
    Ensure-CloudflareConnected
    $script:RecoveryScope='Game';$script:VpnVerifiedBoot=$script:CookieBootIdentity
}



function Start-SelectedEmulator {
    param($InstanceInfo=$null)
    Assert-PoolSetupTurn
    if($script:PendingInstanceReplacement){throw (New-PackageCheckRestartError)}
    if($script:PendingEmulatorRestore){Invoke-PendingEmulatorRestore;$InstanceInfo=$null}
    if($script:PackageCheckRestartPending){throw (New-PackageCheckRestartError)}
    $instance=$InstanceInfo
    if($null -eq $instance){$instance=Get-InstanceInfo -Id $InstanceIndex}
    if($null -eq $instance){throw "LDPlayer ID $InstanceIndex does not exist."}
    Enter-EmulatorLoadingSlot
    $script:RecoveryScope='Startup'
    if($instance.ProcessId -le 0 -or -not $instance.AndroidStarted){Set-EmulatorLiveObservation -EmulatorState Starting -ResetApps}
    if(-not $instance.AndroidStarted){$script:RequiredAppsCheckedKey=$null;$script:VpnVerifiedBoot=0;$script:LoadedCookieCaptures=@{};$script:LoadedAppDataCaptures=@{};$script:WaitingAppDataCookies=@{};$script:CookieAdbSerial=$null;$script:InitialCookieBoot=0;$script:InitialCookieChecks=@{};$script:CookieAuthenticationCache=@{};$script:CookieSlotPause=$null}
    $limit=2;if($Config.InstanceOpenTimeoutLimit){$limit=$Config.InstanceOpenTimeoutLimit}
    while($true){
        if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Stopped during emulator startup.')}
        if($instance.ProcessId -gt 0 -and $instance.AndroidStarted){
            Set-EmulatorLiveObservation -EmulatorState Running
            $script:CurrentEmulatorInstance=$instance;$script:CookieBootIdentity=$instance.ProcessId
            Request-EmulatorWindowLayout -BootIdentity $instance.ProcessId
            $script:StartupFailureCount=0;$script:RecoveryScope='Packages'
            Confirm-RequiredEmulatorApps -BootIdentity $instance.ProcessId
            $null=Save-LoadedEmulatorAppData -BootIdentity $instance.ProcessId
            $script:StartupFailureCount=0
            return
        }
        $attempt=1+[int]$script:StartupFailureCount
        $startupError=$null
        try{
            if($instance.ProcessId -le 0){Invoke-SpacedEmulatorLaunch -Relaunch:([bool]$script:RecoveringEmulator)}
            $deadline=[datetime]::UtcNow.AddSeconds($Config.LdPlayerOpenTimeout)
            Write-FlowStatus "Waiting up to $($Config.LdPlayerOpenTimeout) seconds for Android (startup $attempt/$limit)..."
            while([datetime]::UtcNow -lt $deadline){
                if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Stopped during emulator startup.')}
                $instance=Get-InstanceInfo -Id $InstanceIndex -TimeoutSeconds (Get-CommandBudget $deadline)
                if($null -ne $instance -and $instance.ProcessId -gt 0 -and $instance.AndroidStarted){break}
                Wait-FlowPause ([math]::Max(1,$Config.PollInterval))
            }
            if($null -ne $instance -and $instance.ProcessId -gt 0 -and $instance.AndroidStarted){continue}
            $startupError='Android startup timed out.'
        }catch [System.Management.Automation.PipelineStoppedException]{throw}
        catch [OperationCanceledException]{throw}
        catch{$startupError=$_.Exception.Message}
        $script:StartupFailureCount=1+[int]$script:StartupFailureCount
        Write-FlowStatus "Startup failed ($($script:StartupFailureCount)/$limit): $startupError"
        if($script:StartupFailureCount -ge $limit){Set-EmulatorRestoreRequired -Reason "Emulator startup failed $limit times."}
        Write-FlowStatus 'Closing and reopening this emulator before the next startup attempt.'
        $null=Invoke-Ld -Arguments @('quit','--index',"$InstanceIndex")
        $script:RecoveringEmulator=$true;$script:CurrentEmulatorInstance=$null;$script:VpnVerifiedBoot=0
        Wait-FlowPause ([math]::Max(1,$Config.InstanceRelaunchDelay))
        $instance=Get-InstanceInfo -Id $InstanceIndex
        if($null -eq $instance){throw "LDPlayer ID $InstanceIndex is missing after closing."}
        
        if($instance.ProcessId -gt 0){throw 'The emulator has not finished closing. Startup will retry without opening apps.'}
    }
}

function Initialize-EmulatorWindowLayoutNative {
    if('LauncherEmulatorWindowLayout' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LauncherEmulatorWindowLayout {
 [StructLayout(LayoutKind.Sequential)] public struct Rect {public int Left,Top,Right,Bottom;}
 public sealed class Geometry {public int Width,Height,ChromeWidth,ChromeHeight;}
 [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
 [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
 [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
 [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll",SetLastError=true)] static extern bool SystemParametersInfo(uint a,uint p,out Rect r,uint f);
 [DllImport("user32.dll",SetLastError=true)] static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int hgt,uint flags);
 public static Rect WorkArea() {
  Rect r;if(!SystemParametersInfo(0x30,0,out r,0) || r.Right<=r.Left || r.Bottom<=r.Top)throw new InvalidOperationException("The usable screen area is unavailable.");return r;
 }
 public static Geometry Measure(long handle,long renderer,int pid) {
  var h=new IntPtr(handle);uint owner;Rect outer;
  if(!IsWindow(h) || IsIconic(h) || GetWindowThreadProcessId(h,out owner)==0 || owner!=(uint)pid || !GetWindowRect(h,out outer))return null;
  int width=outer.Right-outer.Left,height=outer.Bottom-outer.Top;if(width<=0 || height<=0)return null;
  var g=new Geometry {Width=width,Height=height,ChromeWidth=32,ChromeHeight=36};
  Rect inner;
  if(renderer!=0 && renderer!=handle && IsWindow(new IntPtr(renderer)) && GetWindowRect(new IntPtr(renderer),out inner)) {
   int w=inner.Right-inner.Left,hgt=inner.Bottom-inner.Top;
   if(w>0 && hgt>0 && w<=width && hgt<=height){g.ChromeWidth=width-w;g.ChromeHeight=height-hgt;}
  }
  return g;
 }
 public static bool Move(long handle,int pid,int x,int y,int width,int height) {
  var h=new IntPtr(handle);uint owner;
  if(!IsWindow(h) || IsIconic(h) || GetWindowThreadProcessId(h,out owner)==0 || owner!=(uint)pid)return false;
  return SetWindowPos(h,IntPtr.Zero,x,y,width,height,0x4000|0x0010|0x0004|0x0200);
 }
}
'@
}

function Request-EmulatorWindowLayout {
    param([int]$BootIdentity)
    if(-not $Config.WindowLayoutDirectory -or $BootIdentity -le 0){return}
    $key="$InstanceIndex|$BootIdentity"
    if($script:WindowLayoutRequestedBoot -ceq $key){return}
    try{
        $file=Join-Path $Config.WindowLayoutDirectory ("loaded-$InstanceIndex-$BootIdentity-"+[guid]::NewGuid().ToString('N')+'.json')
        Write-TemplateStageManifest $file @{Id=[int]$InstanceIndex;ProcessId=$BootIdentity;CreatedTicks=[datetime]::UtcNow.Ticks}
        $script:WindowLayoutRequestedBoot=$key
    }catch{Write-FlowStatus 'Window arrangement request was unavailable; emulator setup will continue.'}
}

function Get-EmulatorWindowInventory {
    param([string]$Listing,[int[]]$IncludedIds)
    foreach($line in ($Listing -split '\r?\n')){
        if($line -notmatch '^(\d+),(.*?),(-?\d+),(-?\d+),([01]),(-?\d+),(-?\d+)(?:,(\d+),(\d+),(\d+))?$'){continue}
        $id=[int]$Matches[1];$owner=[int]$Matches[6];$handle=[long]$Matches[3]
        if($IncludedIds -notcontains $id -or $owner -le 0 -or $handle -le 0){continue}
        $w=480;$h=270
        if($Matches[8] -and [int]$Matches[8] -gt 0){$w=[int]$Matches[8]}
        if($Matches[9] -and [int]$Matches[9] -gt 0){$h=[int]$Matches[9]}
        [pscustomobject]@{Id=$id;Handle=$handle;Renderer=[long]$Matches[4];ProcessId=$owner;AndroidStarted=($Matches[5] -eq '1');ResolutionWidth=$w;ResolutionHeight=$h}
    }
}

function Get-EmulatorHostWindowGeometry {
    param($Entry)
    return [LauncherEmulatorWindowLayout]::Measure($Entry.Handle,$Entry.Renderer,$Entry.ProcessId)
}

function Get-EmulatorWindowWorkArea {
    $rect=[LauncherEmulatorWindowLayout]::WorkArea()
    return @{Left=$rect.Left;Top=$rect.Top;Width=($rect.Right-$rect.Left);Height=($rect.Bottom-$rect.Top)}
}

function Get-EmulatorWindowLayoutPlan {
    param([object[]]$Windows,[int]$Columns,$WorkArea)
    if($Columns -lt 1 -or $Columns -gt 50){throw 'InstancesPerRow must be a whole number from 1 to 50.'}
    if(-not $Windows.Count){return @()}
    $ordered=@($Windows|Sort-Object {[int]$_.Id});$gap=2
    $width=[int][math]::Floor(($WorkArea.Width-($Columns-1)*$gap)/[double]$Columns)
    $minimum=1
    foreach($window in $ordered){$minimum=[math]::Max($minimum,[int]$window.ChromeWidth+1)}
    if($width -lt $minimum){throw 'Too many instances per row for the usable screen width.'}
    $rows=[int][math]::Ceiling($ordered.Count/[double]$Columns)
    $rowSpace=[int][math]::Floor(($WorkArea.Height-($rows-1)*$gap)/[double]$rows)
    $heightWidth=$width
    foreach($window in $ordered){
        $ratio=[double]$window.ResolutionHeight/[double]$window.ResolutionWidth
        if($ratio -le 0){throw 'An emulator resolution is unavailable for window arrangement.'}
        $heightWidth=[math]::Min($heightWidth,[int][math]::Floor(($rowSpace-$window.ChromeHeight)/$ratio+$window.ChromeWidth))
    }
    
    
    if($heightWidth -ge $minimum){$width=$heightWidth}
    $y=[int]$WorkArea.Top
    for($row=0;$row -lt $rows;$row++){
        $rowHeight=0
        for($column=0;$column -lt $Columns;$column++){
            $index=$row*$Columns+$column;if($index -ge $ordered.Count){break}
            $window=$ordered[$index]
            $height=[int][math]::Ceiling(($width-$window.ChromeWidth)*([double]$window.ResolutionHeight/$window.ResolutionWidth))+$window.ChromeHeight
            $rowHeight=[math]::Max($rowHeight,$height)
            [pscustomobject]@{Id=[int]$window.Id;Handle=$window.Handle;ProcessId=$window.ProcessId;X=([int]$WorkArea.Left+$column*($width+$gap));Y=$y;Width=$width;Height=$height}
        }
        $y+=$rowHeight+$gap
    }
}

function Set-EmulatorHostWindowPlacement {
    param($Placement)
    return [LauncherEmulatorWindowLayout]::Move($Placement.Handle,$Placement.ProcessId,$Placement.X,$Placement.Y,$Placement.Width,$Placement.Height)
}

function Update-EmulatorWindowLayout {
    param($Settings,$State,[switch]$Force)
    if(-not $Force -and -not $Settings.WindowLayoutDirectory){return}
    $files=@(if($Settings.WindowLayoutDirectory){Get-ChildItem -LiteralPath $Settings.WindowLayoutDirectory -Filter 'loaded-*.json' -File})
    if(-not $Force -and (-not $files.Count -or [datetime]::UtcNow -lt $State.NextAttempt)){return}
    $directory=if($Settings.ConfigFilePath){[IO.Path]::GetDirectoryName($Settings.ConfigFilePath)}else{$Settings.WindowLayoutDirectory}
    $mutex=New-Object Threading.Mutex $false,((Get-LauncherRunPaths $directory).MutexName+'-Windows');$held=$false
    try{
    try{$held=$mutex.WaitOne($(if($Force){10000}else{0}))}catch [Threading.AbandonedMutexException]{$held=$true}
    if(-not $held){if($Force){throw 'Windows are already being arranged. Try again shortly.'};return}
    $State.NextAttempt=[datetime]::UtcNow.AddSeconds(5)
    $records=@()
    foreach($file in $files){
        $record=ConvertFrom-Json ([IO.File]::ReadAllText($file.FullName))
        if($file.Name -notmatch '^loaded-\d+-\d+-[a-f0-9]{32}[.]json$' -or $record.Id -lt 0 -or $record.ProcessId -le 0){throw 'An emulator window-load notification is invalid.'}
        if($Settings.LdPlayerIds -notcontains [int]$record.Id -or [datetime]::UtcNow.Ticks-[long]$record.CreatedTicks -gt [TimeSpan]::FromMinutes(2).Ticks){[IO.File]::Delete($file.FullName);continue}
        $records+=@{File=$file.FullName;Record=$record}
    }
    if(-not $Force -and -not $records.Count){return}
    $Config=$Settings
    $listing=Invoke-Ld -Arguments @('list2') -TimeoutSeconds ([math]::Min(10,$Settings.CommandTimeout))
    $included=$Settings.LdPlayerIds
    if($Force){$included=@(foreach($line in ($listing -split '\r?\n')){if($line -match '^(\d+),'){$id=[int]$Matches[1];if($Settings.ExcludedLdPlayerIds -notcontains $id){$id}}})}
    $entries=@(Get-EmulatorWindowInventory $listing $included)
    if(-not $entries.Count){if($Force){return 0};return}
    Initialize-EmulatorWindowLayoutNative
    $windows=@()
    foreach($entry in $entries){
        $geometry=Get-EmulatorHostWindowGeometry $entry
        if(-not $geometry){continue}
        $windows+=@{Id=$entry.Id;Handle=$entry.Handle;ProcessId=$entry.ProcessId;ChromeWidth=$geometry.ChromeWidth;ChromeHeight=$geometry.ChromeHeight;ResolutionWidth=$entry.ResolutionWidth;ResolutionHeight=$entry.ResolutionHeight}
    }
    $ready=@($records|Where-Object{
        $event=$_.Record
        @($entries|Where-Object{$_.Id -eq $event.Id -and $_.ProcessId -eq $event.ProcessId -and $_.AndroidStarted}).Count -and
        @($windows|Where-Object{$_.Id -eq $event.Id -and $_.ProcessId -eq $event.ProcessId}).Count
    })
    if(-not $Force -and -not $ready.Count){return}
    $columns=5;if($Settings.InstancesPerRow){$columns=[int]$Settings.InstancesPerRow}
    $plan=@(Get-EmulatorWindowLayoutPlan $windows $columns (Get-EmulatorWindowWorkArea))
    foreach($placement in $plan){if(-not (Set-EmulatorHostWindowPlacement $placement)){throw "LDPlayer $($placement.Id) window could not be arranged; the layout will retry."}}
    foreach($record in $records){
        $event=$record.Record
        $current=@($entries|Where-Object{$_.Id -eq $event.Id})|Select-Object -First 1
        if($ready -contains $record -or ($current -and $current.ProcessId -ne $event.ProcessId)){[IO.File]::Delete($record.File)}
    }
    Write-Host "Arranged $($plan.Count) emulator windows in ascending ID order, $columns per row."
    if($Force){return $plan.Count}
    }finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
}


function Get-ScreenXml {
    param([datetime]$Deadline,[switch]$SkipAnr)
    $dump = Invoke-Android "shell uiautomator dump $UiDumpPath" -TimeoutSeconds (Get-CommandBudget $Deadline)
    if ($dump -notmatch 'dumped to:') { return $null }
    $raw = Invoke-Android "shell cat $UiDumpPath" -TimeoutSeconds (Get-CommandBudget $Deadline)
    try { $screen=[xml]$raw } catch { return $null }
    if (-not $SkipAnr -and $screen.SelectSingleNode('//node[@package="android" and @resource-id="android:id/aerr_wait"]')) {
        $null=Invoke-AndroidAnrWait -Screen $screen -Deadline $Deadline
        return $null
    }
    return ,$screen
}

function Wait-CloudflareState {
    param([string[]]$States, [int]$Seconds)
    $deadline = [datetime]::UtcNow.AddSeconds($Seconds)
    while ([datetime]::UtcNow -lt $deadline) {
        if($script:PoolRole -eq 'Setup'){Assert-PoolSetupTurn}
        try { $screen = Get-ScreenXml -Deadline $deadline }
        catch [TimeoutException] { return '' }
        if ($null -ne $screen) {
            foreach ($node in $screen.SelectNodes('//node')) {
                if ($node.GetAttribute('resource-id') -eq ($CloudflarePackage + ':id/connectionStateTv')) {
                    $state = $node.GetAttribute('text')
                    if ($States -ccontains $state) { return $state }
                }
            }
        }
        Start-Sleep -Seconds $Config.CloudflarePollInterval
    }
    return ''
}

function Tap-ScreenCenter {
    $sizeOutput = Invoke-Android 'shell wm size'
    $sizes = [regex]::Matches($sizeOutput, '(\d+)x(\d+)')
    if ($sizes.Count -eq 0) { throw 'Cannot read the emulator screen size.' }
    $size = $sizes[$sizes.Count - 1]
    $x = [int][math]::Floor([int]$size.Groups[1].Value / 2)
    $y = [int][math]::Floor([int]$size.Groups[2].Value / 2)
    Write-FlowStatus "Tapping screen center: $x, $y"
    Invoke-Android "shell input tap $x $y" | Out-Null
}

function Wait-AppForeground {
    param([string]$Package, [int]$Seconds)
    $deadline = [datetime]::UtcNow.AddSeconds($Seconds)
    $samples = 0
    $pattern = '(?m)(?:mResumedActivity|ResumedActivity|topResumedActivity)\s*[:=][^\r\n]*\s' + [regex]::Escape($Package) + '/'
    while ([datetime]::UtcNow -lt $deadline) {
        if($script:PoolRole -eq 'Setup'){Assert-PoolSetupTurn}
        try { $activities = Invoke-Android 'shell dumpsys -t 5 activity activities' -TimeoutSeconds (Get-CommandBudget $deadline) }
        catch [TimeoutException] { return $false }
        if ($activities -match 'DUMP TIMEOUT') { return $false }
        if ($activities -match $pattern) {
            $samples++
            if ($samples -ge 2) { return $true }
        } else { $samples = 0 }
        Start-Sleep -Seconds $Config.PollInterval
    }
    return $false
}

function Test-AppForeground {
    param([string]$Package)
    $activities = Invoke-Android 'shell dumpsys -t 5 activity activities'
    if ($activities -match 'DUMP TIMEOUT') { throw 'Android activity service is not responding.' }
    $pattern = '(?m)(?:mResumedActivity|ResumedActivity|topResumedActivity)\s*[:=][^\r\n]*\s' + [regex]::Escape($Package) + '/'
    return ($activities -match $pattern)
}

function Convert-AppWindowsToPresentation {
    param([string]$Windows,[string]$Package)
    $result=[pscustomobject]@{State='Unknown';BubbleX=$null;BubbleY=$null}
    if($Windows -notmatch 'WINDOW MANAGER WINDOWS|mCurrentFocus=' -or $Windows -match 'DUMP TIMEOUT'){return $result}
    $owner='\bpackage='+[regex]::Escape($Package)+'(?:\s|$)'
    $blocks=[regex]::Matches($Windows,'(?ms)^\s*Window #\d+\s+Window\{[^\r\n]*\}:(?<body>.*?)(?=^\s*Window #\d+\s+Window\{|^\s*mGlobalConfiguration=|\z)')
    $visible=$false;$hidden=$false;$overlay=$null
    $screen=[regex]::Match($Windows,'\bmScreenRect=\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]')
    foreach($block in $blocks){
        $body=$block.Groups['body'].Value
        if($body -cnotmatch $owner){continue}
        $shown=$body -match '\bmHasSurface=true\b' -and $body -match '(?m)^\s*isVisible=true\s*$'
        if($body -match '\bty=(?:APPLICATION_OVERLAY|SYSTEM_ALERT)\b'){
            if($shown -and $screen.Success -and $body -match '\bmObscured=false\b' -and $body -match '(?m)^\s*isOnScreen=true\s*$'){
                $frame=[regex]::Match($body,'\bmFrame=\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]')
                if($frame.Success){
                    $left=[int]$frame.Groups[1].Value;$top=[int]$frame.Groups[2].Value;$right=[int]$frame.Groups[3].Value;$bottom=[int]$frame.Groups[4].Value
                    $sl=[int]$screen.Groups[1].Value;$st=[int]$screen.Groups[2].Value;$sr=[int]$screen.Groups[3].Value;$sb=[int]$screen.Groups[4].Value
                    $area=($right-$left)*($bottom-$top);$screenArea=($sr-$sl)*($sb-$st)
                    if($left -ge $sl -and $top -ge $st -and $right -le $sr -and $bottom -le $sb -and $right -gt $left -and $bottom -gt $top -and $area -le $screenArea*0.08){
                        $overlay=@{X=[int][math]::Floor(($left+$right)/2);Y=[int][math]::Floor(($top+$bottom)/2)}
                    }
                }
            }
            continue
        }
        if($shown){$visible=$true}
        elseif($body -match '\bty=(?:BASE_APPLICATION|APPLICATION)\b' -and
               $body -match '(?m)^\s*isVisible=false\s*$' -and $body -match '\bmViewVisibility=0x[48]\b'){$hidden=$true}
    }
    if($visible){$result.State='Visible'}
    elseif($hidden){
        $result.State='Background'
        if($overlay){$result.State='Minimized';$result.BubbleX=$overlay.X;$result.BubbleY=$overlay.Y}
    }
    return $result
}

function Get-GameAppPresentation {
    param([datetime]$Deadline,[switch]$Fresh,[switch]$CachedOnly,[int]$MaxAgeSeconds=0)
    $windows=$null
    if(-not $Fresh -and $script:AppWindowSnapshotInstance -eq $InstanceIndex -and $script:AppWindowSnapshotTicks -gt 0){
        $age=([Diagnostics.Stopwatch]::GetTimestamp()-$script:AppWindowSnapshotTicks)/[double][Diagnostics.Stopwatch]::Frequency
        $ttl=[math]::Max(1,$Config.GameCheckInterval)
        if($MaxAgeSeconds -gt 0){$ttl=[math]::Min($ttl,$MaxAgeSeconds)}
        if($CachedOnly){$ttl=[math]::Max($ttl,$Config.CommandTimeout*2)}
        if($age -lt $ttl){$windows=$script:AppWindowSnapshot}
    }
    if(-not $windows -and -not $CachedOnly){
        try{
            $windows=Invoke-GameStatusCommand -Command 'shell dumpsys -t 5 window windows' -Description 'read the game window visibility' -Deadline $Deadline
            if($windows -notmatch 'WINDOW MANAGER WINDOWS|mCurrentFocus=' -or $windows -match 'DUMP TIMEOUT'){throw (New-GameStatusReadError 'Android window visibility is unavailable.')}
            $script:AppWindowSnapshot=$windows;$script:AppWindowSnapshotInstance=$InstanceIndex;$script:AppWindowSnapshotTicks=[Diagnostics.Stopwatch]::GetTimestamp()
        }
        catch [System.Management.Automation.PipelineStoppedException]{throw}
        catch [OperationCanceledException]{throw}
        catch{return [pscustomobject]@{State='Unknown';BubbleX=$null;BubbleY=$null}}
    }
    return (Convert-AppWindowsToPresentation -Windows $windows -Package $Config.GamePackage)
}

function Assert-MonitoredAppVisible {
    param([datetime]$Deadline=[datetime]::UtcNow.AddSeconds($Config.CommandTimeout))
    
    
    $crashed=@(Get-VisibleAppCrashPackages -Deadline $Deadline)
    if($crashed -ccontains $Config.GamePackage){return}
    if($script:AppWindowSnapshotInstance -ne $InstanceIndex -or $script:AppWindowSnapshotTicks -le 0){return}
    $age=([Diagnostics.Stopwatch]::GetTimestamp()-$script:AppWindowSnapshotTicks)/[double][Diagnostics.Stopwatch]::Frequency
    if($age -gt [math]::Max(1,$Config.GameCheckInterval)){return}
    $presentation=Convert-AppWindowsToPresentation -Windows $script:AppWindowSnapshot -Package $Config.GamePackage
    if($presentation.State -notin @('Minimized','Background')){return}
    
    
    $confirmed=Get-GameAppPresentation -Deadline $Deadline -Fresh
    if($confirmed.State -notin @('Minimized','Background')){return}
    Set-EmulatorLiveObservation -AppState Hidden -Package $Config.GamePackage
    $failure=[InvalidOperationException]::new("The floating app $($Config.GamePackage) is not visible ($($confirmed.State)). Restarting the affected app if Android responds.")
    $failure.Data['AppWindowNotVisible']=$true
    throw $failure
}

function Get-LauncherStateWithPresentation {
    param([string]$State,[datetime]$Deadline,[switch]$CachedOnly)
    if($State -notin @('Home','Joining','Unknown')){return $State}
    $maxAge=0;if($State -eq 'Home'){$maxAge=5}
    $presentation=Get-GameAppPresentation -Deadline $Deadline -MaxAgeSeconds $maxAge -CachedOnly:$CachedOnly
    if($null -eq $script:GameAppPresentation){$script:GameAppPresentation=@{}}
    $script:GameAppPresentation[$Config.GamePackage]=@{LogicalState=$State;WindowState=$presentation.State}
    if($presentation.State -in @('Minimized','Background')){return 'Minimized'}
    if($State -eq 'Home' -and $presentation.State -eq 'Unknown'){throw (New-GameStatusReadError 'Home was logged, but its window visibility could not be confirmed. No server link was sent.')}
    return $State
}

function Restore-GameAppWindow {
    param([datetime]$Deadline)
    
    Enter-EmulatorLoadingSlot
    $presentation=Get-GameAppPresentation -Deadline $Deadline -Fresh
    if($presentation.State -eq 'Visible'){return}
    if($presentation.State -notin @('Minimized','Background')){throw (New-GameStatusReadError 'The app window could not be verified before restoring it. The app was left untouched.')}
    Write-FlowStatus 'Game app is minimized or in the background. Bringing its existing window back without closing it...'
    if($null -ne $presentation.BubbleX -and $null -ne $presentation.BubbleY){
        Invoke-Android ('shell input tap '+$presentation.BubbleX+' '+$presentation.BubbleY) | Out-Null
    }else{Invoke-Ld -Arguments @('runapp','--index',"$InstanceIndex",'--packagename',$Config.GamePackage) | Out-Null}
    $samples=0;$lastState='Unknown'
    while([datetime]::UtcNow -lt $Deadline){
        Start-Sleep -Seconds ([math]::Max(1,$Config.PollInterval))
        $presentation=Get-GameAppPresentation -Deadline $Deadline -Fresh;$lastState=$presentation.State
        if($lastState -eq 'Visible'){$samples++}else{$samples=0}
        if($samples -ge 2){Write-FlowStatus 'Existing app window is visible. Checking Home/game state again.';return}
    }
    if($lastState -eq 'Unknown'){throw (New-GameStatusReadError 'App window visibility could not be read after restoring it. Retrying without assuming a game failure.')}
    Register-FlowStageTimeout -Stage Game
    throw [TimeoutException]::new('The minimized app did not become visible within its opening timeout.')
}

function Get-AndroidProcesses {
    param([int]$TimeoutSeconds = $Config.CommandTimeout)
    if ($script:ProcessCheckCacheTicks -gt 0) {
        $cacheAge = ([Diagnostics.Stopwatch]::GetTimestamp() - $script:ProcessCheckCacheTicks) / [double][Diagnostics.Stopwatch]::Frequency
        if ($cacheAge -lt 1) { return $script:ProcessCheckCache }
    }
    $processes = Invoke-Android 'shell ps -A -o STAT,UID,NAME' -TimeoutSeconds $TimeoutSeconds
    $entries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in ($processes -split '\r?\n')) {
        $match = [regex]::Match($line, '^\s*(\S+)\s+(\d+)\s+(\S+)\s*$')
        if ($match.Success) {
            $entries.Add([pscustomobject]@{ State=$match.Groups[1].Value; Uid=[int]$match.Groups[2].Value; Name=$match.Groups[3].Value })
        }
    }
    $script:ProcessCheckCache = $entries.ToArray()
    $script:ProcessCheckCacheTicks = [Diagnostics.Stopwatch]::GetTimestamp()
    return $script:ProcessCheckCache
}

function New-GameStatusReadError {
    param([string]$Message,[Exception]$Cause)
    $failure=[InvalidOperationException]::new($Message,$Cause)
    $failure.Data['GameStatusReadFailed']=$true
    $failure.Data['GamePackage']=[string]$Config.GamePackage
    return $failure
}

function Get-GameStatusCommandBudget {
    param([datetime]$Deadline)
    $remaining=[math]::Ceiling(($Deadline-[datetime]::UtcNow).TotalSeconds)
    
    
    $minimum=[math]::Max(10,([double]$Config.MinCheckDelay+2))
    if ($remaining -lt $minimum) {
        $available=[math]::Max(0,$remaining)
        $failure=New-GameStatusReadError "Only $available seconds remained; the next status command requires at least $minimum seconds. No command was started."
        $failure.Data['GameStatusDeadlineApproaching']=$true
        throw $failure
    }
    return [int][math]::Max(10,[math]::Min($Config.CommandTimeout,$remaining))
}

function Invoke-GameStatusCommand {
    param([string]$Command,[string]$Description,[datetime]$Deadline)
    $budget=Get-GameStatusCommandBudget -Deadline $Deadline
    try {
        $response=Invoke-Android $Command -TimeoutSeconds $budget
        return $response
    }
    catch [System.Management.Automation.PipelineStoppedException] { throw }
    catch [OperationCanceledException] { throw }
    catch {
        throw (New-GameStatusReadError "Could not $Description. $($_.Exception.Message)" $_.Exception)
    }
}

function New-AppPresenceReadError {
    param([string]$Message)
    $failure=New-GameStatusReadError $Message
    $failure.Data['AppPresenceUnavailable']=$true
    return $failure
}

function Get-GameAppPids {
    param([string]$Package,[datetime]$Deadline)
    if($Package -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$'){throw 'Invalid game package.'}
    try{
        $reply=(Invoke-GameStatusCommand -Command "shell pidof $Package" -Description 'read the game process ID' -Deadline $Deadline).Trim()
        if($reply -match '^\d+(?:\s+\d+)*$'){return $reply}
    }catch [InvalidOperationException]{
        if($_.Exception.Data['GameStatusDeadlineApproaching']){throw}
    }
    
    
    $command='shell sh -c ''echo LAUNCHER_PROC_BEGIN; ps -A -o PID,NAME; r=$?; echo LAUNCHER_PROC_STATUS:$r; echo LAUNCHER_PROC_END'''
    try{$raw=Invoke-GameStatusCommand -Command $command -Description 'confirm whether the game process exists' -Deadline $Deadline}
    catch [InvalidOperationException]{$_.Exception.Data['AppPresenceUnavailable']=$true;throw}
    $lines=@($raw -split '\r?\n'|ForEach-Object{$_.Trim()}|Where-Object{$_})
    if($lines.Count -lt 5 -or $lines[0] -cne 'LAUNCHER_PROC_BEGIN' -or $lines[-1] -cne 'LAUNCHER_PROC_END' -or $lines[-2] -cne 'LAUNCHER_PROC_STATUS:0'){
        throw (New-AppPresenceReadError 'Android process inventory was incomplete; the app was not assumed closed.')
    }
    $pids=New-Object 'System.Collections.Generic.List[string]';$systemSeen=$false
    foreach($line in $lines[1..($lines.Count-3)]){
        if($line -match '^PID\s+NAME$'){continue}
        if($line -notmatch '^(\d+)\s+(.+?)\s*$'){throw (New-AppPresenceReadError 'Android process inventory was malformed; the app was not assumed closed.')}
        if($Matches[2] -ceq 'system_server'){$systemSeen=$true}
        if($Matches[2] -ceq $Package){$pids.Add($Matches[1])}
    }
    if(-not $systemSeen){throw (New-AppPresenceReadError 'Android process inventory did not confirm system_server; the app was not assumed closed.')}
    return $pids.ToArray() -join ' '
}

function Test-AppRunning {
    param([string]$Package)
    $pids = Get-GameAppPids -Package $Package -Deadline ([datetime]::UtcNow.AddSeconds($Config.CommandTimeout))
    return ($pids -match '^\d+(?:\s+\d+)*$')
}

function Get-AppUid {
    param([string]$Package)
    $owner = Invoke-Android "shell stat -c %u /data/user/0/$Package"
    if ($owner.Trim() -match '^\d+$') { return [int]$owner.Trim() }
    $app = Get-AndroidProcesses | Where-Object { $_.Name -ceq $Package -and $_.State -notmatch '^[ZX]' } | Select-Object -First 1
    if ($null -ne $app) { return $app.Uid }
    return $null
}

function Test-CloudflareVpnConnected {
    
    $uid=$null
    if ($script:CloudflareUidCacheTicks -gt 0 -and $script:CloudflareUidCacheInstance -eq $InstanceIndex) {
        $age=([Diagnostics.Stopwatch]::GetTimestamp()-$script:CloudflareUidCacheTicks)/[double][Diagnostics.Stopwatch]::Frequency
        if ($age -lt 60) { $uid=$script:CloudflareUidCache }
    }
    if ($null -eq $uid) {
        $uid=Get-AppUid -Package $CloudflarePackage
        if ($null -ne $uid) {
            $script:CloudflareUidCache=$uid
            $script:CloudflareUidCacheInstance=$InstanceIndex
            $script:CloudflareUidCacheTicks=[Diagnostics.Stopwatch]::GetTimestamp()
        }
    }
    if ($null -eq $uid) { return $false }
    $uidPattern = '\b(?:EstablishingAppUid|OwnerUid|mOwnerUID)\s*[:=]\s*' + $uid + '\b'
    $connectivity = Invoke-Android 'shell dumpsys -t 5 connectivity'
    if ($connectivity -match 'DUMP TIMEOUT') { throw 'Android VPN service is not responding.' }
    
    foreach ($agent in [regex]::Matches($connectivity, '(?m)^\s*NetworkAgentInfo\{[^\r\n]*')) {
        if ($agent.Value -match '\btype:\s*VPN\[' -and
            $agent.Value -match '\bstate:\s*CONNECTED/CONNECTED\b' -and
            $agent.Value -match $uidPattern) {
            return $true
        }
    }
    return $false
}

function Test-LauncherError273Event {
    param([string]$Line)
    if($Line -notmatch '\[(?:F|DF)Log::(?:Network|NetworkClient|RbxTransportRnaExpConnection)\]'){return $false}
    return ($Line -match '(?i)\b(?:Sending\s+disconnect\s+with\s+reason|Disconnection\s+Notification[.]?\s*Reason)\s*:\s*273\b' -or
            $Line -match '(?i)\b(?:game joined from|same account launched experience from)\s+(?:a\s+)?(?:another|different)\s+device\b')
}

function Convert-LauncherEventsToState {
    param([string]$Events, [string]$ReadyMarker, [ref]$AwaitingJoinResponse)
    $state = 'Unknown'
    $stage = ''
    $connectionPending=$false
    $waitingForJoinResponse=$false
    $readyMarkerPattern = if ($ReadyMarker) { '\b'+[regex]::Escape($ReadyMarker)+'\b' }
    foreach ($line in ($Events -split '\r?\n')) {
        if ($line -match '\[(?:F|DF)Log::HttpTraceError\]\s+HttpResponse\(') {
            if ($waitingForJoinResponse -and
                $line -match '\burl:\s*\{\s*"https://gamejoin\.roblox\.com/v1/join-private-game(?=[?"\s])' -and
                $line -match '\b(?:message:HttpError:\s*(?:Timedout|InactivityTimeout|SslConnectFail)|status:\s*529)\b') {
                $state = 'JoinHttpFailed'
                $waitingForJoinResponse=$false
            }
            continue
        }
        if ($readyMarkerPattern -and $line -match '\[FLog::CreatorOutput\]' -and $line -match $readyMarkerPattern) {
            $waitingForJoinResponse=$false
            if ($state -eq 'JoinHttpFailed' -and $stage -eq 'UGCGame') { $state='InGame' }
            continue
        }
        if ($line -match '\[(?:F|DF)Log::(?:Network|NetworkClient|RbxTransportRnaExpConnection)\]') {
            if (Test-LauncherError273Event $line) {
                $state='Disconnected';$waitingForJoinResponse=$false;$connectionPending=$false
            }
            elseif ($line -match '\bSending disconnect with reason:\s*(\d+)') {
                $waitingForJoinResponse=$false
                if ([int]$Matches[1] -in @(264,268,403,524,600)) { $state = 'Blocked' }
                else { $state = 'Disconnected' }
            }
            elseif ($line -match '(?i)\bFailed to connect to server\b.*\bno response\b') { $state = 'Disconnected' }
            elseif ($line -match '\bNetworkClient:Create\b') { $state = 'Joining'; $connectionPending=$true; $waitingForJoinResponse=$false }
            elseif ($line -match '(?i)\bConnection accepted from\b') {
                $connectionPending=$false
                $waitingForJoinResponse=$false
                if ($stage -eq 'UGCGame') { $state='InGame' }
            }
            elseif ($line -match '(?i)(Client has been disconnected|Connection lost|ID_CONNECTION_LOST)' -and $state -ne 'Blocked') { $state = 'Disconnected' }
            elseif ($line -match '(?i)Handshake complete' -and -not $connectionPending -and $stage -eq 'UGCGame' -and $state -ne 'Blocked') { $state = 'InGame' }
            continue
        }
        if ($line -notmatch '\[FLog::SingleSurfaceApp\]') { continue }
        if ($line -match '\bsetStage:\s*\(stage:([A-Za-z0-9_]+)\)') {
            $stage = $Matches[1]
            if ($stage -notin @('InitializedUGCGame','UGCGame')) { $waitingForJoinResponse=$false }
            switch ($Matches[1]) {
                'LuaApp' { $state = 'Home' }
                'UGCGame' { $state = 'InGame'; $connectionPending=$false }
                'InitializedUGCGame' { $state = 'Joining' }
                default { $state = 'Loading' }
            }
        }
        elseif ($line -match '\blaunchUGCGame:') { $state = 'Joining'; $waitingForJoinResponse=$true }
        elseif ($line -match '\b(leaveUGCGame|returnToLuaAppInternal):') { $state = 'Loading'; $waitingForJoinResponse=$false }
    }
    if ($null -ne $AwaitingJoinResponse) { $AwaitingJoinResponse.Value=$waitingForJoinResponse }
    if ($state -eq 'JoinHttpFailed') { return 'Disconnected' }
    return $state
}

function Test-LauncherReadyEvents {
    param([string]$Events, [string]$Marker)
    $ready=$false
    $joinId=''
    foreach ($line in ($Events -split '\r?\n')) {
        if(Test-LauncherError273Event $line){$ready=$false;$joinId=''}
        if ($line -match '\[(?:F|DF)Log::(?:Network|NetworkClient|RbxTransportRnaExpConnection)\]' -and
            $line -match '(?i)(\bNetworkClient:Create\b|\bSending disconnect with reason:|\bFailed to connect to server\b.*\bno response\b|Client has been disconnected|Connection lost|ID_CONNECTION_LOST)') {
            $ready=$false; $joinId=''
        }
        if ($line -match '\[FLog::SingleSurfaceApp\]') {
            if($line -match '\b(launchUGCGame:|leaveUGCGame:|returnToLuaAppInternal:)'){$ready=$false;$joinId=''}
            elseif($line -match '\bsetStage:\s*\(stage:([A-Za-z0-9_]+)\)' -and $Matches[1] -ne 'UGCGame'){$ready=$false;$joinId=''}
        }
        if ($line -notmatch '\[FLog::CreatorOutput\]') { continue }
        if ($line -match '\[JoinLoad client ([^\]]+)\]\s+Start\b') {
            $joinId=$Matches[1]; $ready=$false
        }
        if ($line -match ('\b'+[regex]::Escape($Marker)+'\b')) {
            if ($line -match '\[JoinLoad client ([^\]]+)\]' -and $joinId -and $Matches[1] -ne $joinId) { continue }
            $ready=$true
        }
    }
    return $ready
}

function Save-StartupLogSnapshot {
    if ($Config.LogSnapshotLdPlayerId -lt 0 -or $InstanceIndex -ne $Config.LogSnapshotLdPlayerId -or $script:StartupLogSnapshotDone) { return }
    
    $script:StartupLogSnapshotDone=$true
    try {
        $name='LDPlayer-'+$InstanceIndex+'-'+[datetime]::Now.ToString('yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
        $directory=Join-Path $Config.LogSnapshotDirectory $name
        $null=New-Item -ItemType Directory -Path $directory -Force
        $summary=Join-Path $directory 'summary.txt'
        [IO.File]::WriteAllText($summary,"Startup log snapshot for LDPlayer $InstanceIndex`r`nCaptured: $([datetime]::Now.ToString('o'))`r`nRead only: no apps opened, closed or rejoined by this snapshot.`r`n",[Text.Encoding]::UTF8)
        Write-FlowStatus 'Saving the configured one-time startup log snapshot before the VPN/game flow...'
        foreach ($package in $Config.GamePackages) {
            try {
                $reply=(Invoke-Android "shell pidof $package").Trim()
                if ($reply -notmatch '^\d+(?:\s+\d+)*$') {
                    if ($reply) { throw 'Android did not return valid process IDs; its connection may be unavailable.' }
                    [IO.File]::AppendAllText($summary,"$package : no running process was available. No log captured.`r`n",[Text.Encoding]::UTF8)
                    continue
                }
                $saved=0
                foreach ($appProcessId in ($reply -split '\s+')) {
                    $descriptors=Invoke-Android "shell su -c 'ls -l /proc/$appProcessId/fd'"
                    $pattern='(?m)^\S+[^\r\n]*?\s(?<fd>\d+)\s+->\s+(?<log>/data/(?:data|user/0)/'+[regex]::Escape($package)+'/files/appData/logs/[^\r\n]*_Player_[^\r\n]*\.log)\s*(?:\(deleted\))?\s*$'
                    $handle=[regex]::Matches($descriptors,$pattern) | Sort-Object {$_.Groups['log'].Value} -Descending | Select-Object -First 1
                    if (-not $handle) { continue }
                    $fd=$handle.Groups['fd'].Value
                    $raw=Invoke-Android "shell su -c 'cat /proc/$appProcessId/fd/$fd'"
                    if ($raw -match '(?m)^(?:cat:|su:).*?(?:Permission denied|No such file|not found)') { throw 'The current player log could not be read.' }
                    $fileName=$package+'-'+$appProcessId+'.log'
                    [IO.File]::WriteAllText((Join-Path $directory $fileName),$raw,[Text.Encoding]::UTF8)
                    [IO.File]::AppendAllText($summary,"$package : saved $fileName (live PID $appProcessId, descriptor $fd).`r`n",[Text.Encoding]::UTF8)
                    $saved++
                }
                if ($saved -eq 0) { [IO.File]::AppendAllText($summary,"$package : running, but no readable current Player log handle was found. Check Android root access.`r`n",[Text.Encoding]::UTF8) }
            }
            catch [System.Management.Automation.PipelineStoppedException] { throw }
            catch [OperationCanceledException] { throw }
            catch { [IO.File]::AppendAllText($summary,"$package : capture failed: $($_.Exception.Message)`r`n",[Text.Encoding]::UTF8) }
        }
        Write-FlowStatus "Startup log snapshot saved in $directory . Continuing the normal flow."
    }
    catch [System.Management.Automation.PipelineStoppedException] { throw }
    catch [OperationCanceledException] { throw }
    catch { Write-FlowStatus 'The one-time log snapshot could not be saved. Continuing the normal flow without retrying the snapshot.' }
}

function Get-AppCrashPackagesFromWindows {
    param([string]$Windows, [string[]]$Packages)
    $found=New-Object 'System.Collections.Generic.List[string]'
    $focus=[regex]::Match($Windows,'(?m)^\s*mCurrentFocus=Window\{[^\r\n]*?Application Error:\s*(?<package>[A-Za-z][A-Za-z0-9_.]*)(?:[\s}:]|$)')
    if ($focus.Success -and $Packages -ccontains $focus.Groups['package'].Value) { $found.Add($focus.Groups['package'].Value) }
    $blocks=[regex]::Matches($Windows,'(?ms)^\s*Window #\d+\s+Window\{[^\r\n]*?Application Error:\s*(?<package>[A-Za-z][A-Za-z0-9_.]*)(?:[\s}:]|$)(?<body>.*?)(?=^\s*Window #\d+\s+Window\{|^\s*mGlobalConfiguration=|\z)')
    foreach ($block in $blocks) {
        $package=$block.Groups['package'].Value
        $body=$block.Groups['body'].Value
        if ($Packages -ccontains $package -and $body -match '\bmHasSurface=true\b' -and $body -match '(?m)^\s*isVisible=true\s*$' -and -not $found.Contains($package)) { $found.Add($package) }
    }
    return $found.ToArray()
}

function Get-FocusedAppCrashPackage {
    param([string]$Windows, [string[]]$Packages)
    $focus=[regex]::Match($Windows,'(?m)^\s*mCurrentFocus=Window\{[^\r\n]*?Application Error:\s*(?<package>[A-Za-z][A-Za-z0-9_.]*)(?:[\s}:]|$)')
    if ($focus.Success -and $Packages -ccontains $focus.Groups['package'].Value) { return $focus.Groups['package'].Value }
    return ''
}

function Dismiss-AndroidAppCrashDialog {
    param([string]$Package)
    $deadline=[datetime]::UtcNow.AddSeconds($Config.CommandTimeout)
    $attempts=[math]::Max(3,$Config.GamePackages.Count+1)
    for ($attempt=0; $attempt -lt $attempts; $attempt++) {
        $windows=Invoke-Android 'shell dumpsys -t 5 window windows' -TimeoutSeconds (Get-CommandBudget $deadline)
        if ($windows -notmatch 'WINDOW MANAGER WINDOWS|mCurrentFocus=' -or $windows -match 'DUMP TIMEOUT') { throw 'Cannot verify Android crash-dialog state yet.' }
        if (@(Get-AppCrashPackagesFromWindows -Windows $windows -Packages @($Package)) -cnotcontains $Package) {
            if($script:AppCrashVisible){$script:AppCrashVisible.Remove($Package)}
            Clear-ProcessCheckCache
            Write-FlowStatus "Android crash dialog for $Package is closed."
            return
        }
        $owner=Get-FocusedAppCrashPackage -Windows $windows -Packages $Config.GamePackages
        if (-not $owner) { throw "The crash dialog for $Package is visible but not focused. Waiting before trying Close app." }
        $screen=Get-ScreenXml -Deadline $deadline
        if ($null -eq $screen) { throw 'Cannot read Android crash-dialog controls yet.' }
        $button=$screen.SelectNodes('//node') | Where-Object {
            $_.GetAttribute('package') -eq 'android' -and $_.GetAttribute('resource-id') -eq 'android:id/aerr_close' -and $_.GetAttribute('enabled') -eq 'true'
        } | Select-Object -First 1
        if ($null -eq $button) { throw 'Android Close app control is not available yet.' }
        $bounds=[regex]::Match($button.GetAttribute('bounds'),'^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$')
        if (-not $bounds.Success) { throw 'Android Close app control has no usable bounds.' }
        $left=[int]$bounds.Groups[1].Value; $top=[int]$bounds.Groups[2].Value
        $right=[int]$bounds.Groups[3].Value; $bottom=[int]$bounds.Groups[4].Value
        if ($right -le $left -or $bottom -le $top) { throw 'Android Close app control is not visible yet.' }
        
        
        $current=Invoke-Android 'shell dumpsys -t 5 window windows' -TimeoutSeconds (Get-CommandBudget $deadline)
        if ((Get-FocusedAppCrashPackage -Windows $current -Packages $Config.GamePackages) -cne $owner) { continue }
        $x=[int][math]::Floor(($left+$right)/2)
        $y=[int][math]::Floor(($top+$bottom)/2)
        Write-FlowStatus "Pressing Android Close app for $owner..."
        Invoke-Android "shell input tap $x $y" -TimeoutSeconds (Get-CommandBudget $deadline) | Out-Null
        Start-Sleep -Seconds 1
    }
    throw "Android crash dialog for $Package has not closed yet. Recovery will retry before reopening any app."
}

function Get-FocusedAndroidAnrOwner {
    param([string]$Windows)
    $focus=[regex]::Match($Windows,'(?m)^\s*mCurrentFocus=Window\{[^\r\n]*?Application Not Responding:\s*(?<owner>[^}\r\n]+)\}')
    if ($focus.Success) { return $focus.Groups['owner'].Value.Trim() }
    return ''
}

function Invoke-AndroidAnrWait {
    param($Screen=$null,[string]$Windows='',[datetime]$Deadline=[datetime]::UtcNow.AddSeconds($Config.CommandTimeout))
    if (-not $Windows) { $Windows=Invoke-Android 'shell dumpsys -t 5 window windows' -TimeoutSeconds (Get-CommandBudget $Deadline) }
    $owner=Get-FocusedAndroidAnrOwner -Windows $Windows
    if (-not $owner) { return $false }
    if ($null -eq $Screen) { $Screen=Get-ScreenXml -Deadline $Deadline -SkipAnr }
    if ($null -eq $Screen) { return $false }
    $button=$Screen.SelectNodes('//node')|Where-Object {
        $_.GetAttribute('package') -eq 'android' -and $_.GetAttribute('resource-id') -eq 'android:id/aerr_wait' -and $_.GetAttribute('enabled') -eq 'true'
    }|Select-Object -First 1
    if ($null -eq $button) { return $false }
    $bounds=[regex]::Match($button.GetAttribute('bounds'),'^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$')
    if (-not $bounds.Success) { return $false }
    $left=[int]$bounds.Groups[1].Value;$top=[int]$bounds.Groups[2].Value;$right=[int]$bounds.Groups[3].Value;$bottom=[int]$bounds.Groups[4].Value
    if ($right -le $left -or $bottom -le $top) { return $false }
    $current=Invoke-Android 'shell dumpsys -t 5 window windows' -TimeoutSeconds (Get-CommandBudget $Deadline)
    if ((Get-FocusedAndroidAnrOwner -Windows $current) -cne $owner) { return $false }
    $x=[int][math]::Floor(($left+$right)/2);$y=[int][math]::Floor(($top+$bottom)/2)
    Write-FlowStatus "Android says $owner isn't responding. Pressing Wait..."
    Invoke-Android "shell input tap $x $y" -TimeoutSeconds (Get-CommandBudget $Deadline)|Out-Null
    Start-Sleep -Seconds 1
    return $true
}

function Reset-AppCrashTracking {
    $script:AppCrashBoot=0;$script:AppCrashCounts=@{};$script:AppCrashVisible=@{};$script:AppCrashRestartPending=$null
    $script:AppCrashWindowCacheTicks=0;$script:AppCrashWindowCache=@()
}

function Sync-AppCrashBoot {
    param([long]$BootIdentity)
    if($BootIdentity -gt 0 -and $script:AppCrashBoot -ne $BootIdentity){Reset-AppCrashTracking;$script:AppCrashBoot=$BootIdentity}
}

function Reset-JoinedAppCrashCount {
    param([string]$Package=$Config.GamePackage)
    if(-not $script:AppCrashCounts -or [int]$script:AppCrashCounts[$Package] -le 0){return}
    $previous=[int]$script:AppCrashCounts[$Package]
    $script:AppCrashCounts.Remove($Package)
    if($script:AppCrashVisible){$script:AppCrashVisible.Remove($Package)}
    if($script:AppCrashRestartPending -ceq $Package){$script:AppCrashRestartPending=$null}
    $Config=$Config.Clone();$Config.GamePackage=$Package
    Write-FlowStatus "Game join confirmed for $Package. Reset its crash count from $previous to 0."
}

function Update-AppCrashObservations {
    param([string[]]$Packages)
    $Config=$Config.Clone()
    if(-not $script:AppCrashCounts){$script:AppCrashCounts=@{}}
    if(-not $script:AppCrashVisible){$script:AppCrashVisible=@{}}
    $limit=2;if($Config.AppCrashLimit){$limit=[int]$Config.AppCrashLimit}
    foreach($package in $Config.GamePackages){
        if($Packages -cnotcontains $package){$script:AppCrashVisible.Remove($package);continue}
        if(-not $script:AppCrashVisible[$package]){
            $script:AppCrashVisible[$package]=$true
            $count=1+[int]$script:AppCrashCounts[$package];$script:AppCrashCounts[$package]=$count
            Set-CrashedAppCachePending -Package $package
            $Config.GamePackage=$package
            Write-FlowStatus "Android keeps-stopping dialog for ${package}: crash count $count/$limit."
            if($count -ge $limit){$script:AppCrashRestartPending=$package}
        }
    }
}

function New-AppCrashError {
    param([string]$Package)
    if($script:AppCrashRestartPending){$Package=[string]$script:AppCrashRestartPending}
    Set-EmulatorLiveObservation -AppState Crashed -Package $Package
    Set-CrashedAppCachePending -Package $Package
    $failure=[InvalidOperationException]::new("Android crash dialog is visible for $Package.")
    $failure.Data['GamePackage']=$Package;$failure.Data['AppCrashDialog']=$true
    if($script:AppCrashRestartPending){$failure.Data['AppCrashRestartRequired']=$true}
    return $failure
}

function Set-CrashedAppCachePending {
    param([string]$Package)
    if($Config.GamePackages -cnotcontains $Package){return}
    if(-not $script:AppCrashCachePending){$script:AppCrashCachePending=@{}}
    $script:AppCrashCachePending[$Package]=$true
}

function Get-CrashedAppCacheScript {
    param([string]$Package)
    if($Package -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$' -or $Config.GamePackages -cnotcontains $Package){throw 'Cache cleanup requires a configured game app package.'}
    return @'
set -u
pkg='__PACKAGE__'
fail() { echo "LAUNCHER_CACHE_FAILED:$1"; exit 0; }
test "$(id -u)" = 0 || fail ROOT_REQUIRED
am force-stop "$pkg" || fail APP_STOP_FAILED
attempt=0
while pidof "$pkg" >/dev/null 2>&1; do
  attempt=$((attempt+1)); test "$attempt" -lt 12 || fail APP_STILL_RUNNING
  sleep 0.25
done
for target in "/data/data/$pkg/cache" "/data/data/$pkg/code_cache" "/sdcard/Android/data/$pkg/cache"; do
  test ! -L "$target" || fail CACHE_IS_SYMLINK
  if test ! -e "$target"; then continue; fi
  test -d "$target" || fail CACHE_NOT_DIRECTORY
  resolved=$(readlink -f "$target") || fail CACHE_PATH_UNAVAILABLE
  case "$resolved" in
    "/data/data/$pkg/cache"|"/data/data/$pkg/code_cache"|"/data/user/0/$pkg/cache"|"/data/user/0/$pkg/code_cache"|"/storage/emulated/0/Android/data/$pkg/cache"|"/storage/emulated/legacy/Android/data/$pkg/cache"|"/data/media/0/Android/data/$pkg/cache") ;;
    *) fail UNSUPPORTED_CACHE_PATH ;;
  esac
  find "$resolved" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + || fail CACHE_DELETE_FAILED
  remaining=$(find "$resolved" -mindepth 1 -maxdepth 1 -print) || fail CACHE_VERIFY_FAILED
  test -z "$remaining" || fail CACHE_NOT_EMPTY
done
echo "LAUNCHER_CACHE_CLEARED:$pkg"
'@.Replace('__PACKAGE__',$Package)
}

function Clear-PendingCrashedAppCache {
    param([string]$Package=$Config.GamePackage)
    if(-not $script:AppCrashCachePending -or -not $script:AppCrashCachePending[$Package]){return}
    $scriptText=Get-CrashedAppCacheScript -Package $Package
    Assert-PoolSetupTurn;Enter-EmulatorLoadingSlot
    $Config=$Config.Clone();$Config.GamePackage=$Package
    Write-FlowStatus "Clearing only $Package cache after its crash, before reopening..."
    try{
        $result=Invoke-GameAppDataAdb -Arguments @('shell','su -c sh') -InputText $scriptText -TimeoutSeconds $Config.CommandTimeout
        if($result -notmatch ('(?m)^LAUNCHER_CACHE_CLEARED:'+ [regex]::Escape($Package)+'\s*$')){
            $reason='Android did not confirm cache cleanup.'
            if($result -match '(?m)^LAUNCHER_CACHE_FAILED:([A-Z_]+)\s*$'){$reason='Android cache cleanup failed: '+$Matches[1]+'.'}
            throw $reason
        }
    }catch [System.Management.Automation.PipelineStoppedException]{throw}
    catch [OperationCanceledException]{throw}
    catch{
        $failure=New-GameStatusReadError "Cache cleanup for $Package is pending. The app remains closed for retry. $($_.Exception.Message)"
        $failure.Data['AppCacheCleanupFailed']=$true;throw $failure
    }
    $script:AppCrashCachePending.Remove($Package)
    if($script:AppCrashVisible){$script:AppCrashVisible.Remove($Package)}
    Clear-ProcessCheckCache
    Write-FlowStatus "Cleared $Package cache. Opening the app next; login databases, preferences and saved files were kept."
}

function Get-VisibleAppCrashPackages {
    param([datetime]$Deadline=[datetime]::UtcNow.AddSeconds($Config.CommandTimeout))
    Sync-AppCrashBoot -BootIdentity ([long]$script:CurrentEmulatorInstance.ProcessId)
    $ttl=[math]::Max(1,[int]$Config.GameCheckInterval)
    if ($script:AppCrashWindowCacheTicks -gt 0 -and $script:AppCrashWindowCacheInstance -eq $InstanceIndex) {
        $age=([Diagnostics.Stopwatch]::GetTimestamp()-$script:AppCrashWindowCacheTicks)/[double][Diagnostics.Stopwatch]::Frequency
        if ($age -lt $ttl) { return $script:AppCrashWindowCache }
    }
    $packages=@()
    try {
        $windows=Invoke-Android 'shell dumpsys -t 5 window windows' -TimeoutSeconds ([math]::Min(6,(Get-CommandBudget $Deadline)))
        if ($windows -notmatch 'WINDOW MANAGER WINDOWS|mCurrentFocus=' -or $windows -match 'DUMP TIMEOUT') { throw 'Android window state is unavailable.' }
        $script:AppWindowSnapshot=$windows;$script:AppWindowSnapshotInstance=$InstanceIndex;$script:AppWindowSnapshotTicks=[Diagnostics.Stopwatch]::GetTimestamp()
        if (Get-FocusedAndroidAnrOwner -Windows $windows) { $null=Invoke-AndroidAnrWait -Windows $windows -Deadline $Deadline }
        $packages=@(Get-AppCrashPackagesFromWindows -Windows $windows -Packages $Config.GamePackages)
        Update-AppCrashObservations -Packages $packages
        $script:AppCrashProbeUnavailable=$false
    }
    catch [System.Management.Automation.PipelineStoppedException] { throw }
    catch [OperationCanceledException] { throw }
    catch {
        if (-not $script:AppCrashProbeUnavailable) { Write-FlowStatus 'Android crash-window check is temporarily unavailable. Continuing with game logs.' }
        $script:AppCrashProbeUnavailable=$true
    }
    $script:AppCrashWindowCache=$packages
    $script:AppCrashWindowCacheInstance=$InstanceIndex
    $script:AppCrashWindowCacheTicks=[Diagnostics.Stopwatch]::GetTimestamp()
    return $packages
}

function Test-LauncherStartupConnectionFailure {
    param([string]$Events)
    $atHome=$false
    $joinObserved=$false
    $homeSince=[datetime]::MinValue
    $failures=@{}
    $dateStyle=[Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    $culture=[Globalization.CultureInfo]::InvariantCulture
    $dateFormat='yyyy-MM-ddTHH:mm:ss.fffZ'
    foreach ($line in ($Events -split '\r?\n')) {
        if ($line -match '\[FLog::SingleSurfaceApp\].*\bsetStage:\s*\(stage:([A-Za-z0-9_]+)\)') {
            $stage=$Matches[1]
            if ($stage -in @('InitializedUGCGame','UGCGame')) { $joinObserved=$true }
            $atHome=$false
            $failures.Clear()
            
            
            if ($stage -eq 'LuaApp' -and -not $joinObserved) {
                $fields=$line -split ',',3
                $uptime=0.0
                $atHome=$fields.Count -ge 3 -and
                    [double]::TryParse($fields[1],[Globalization.NumberStyles]::Float,$culture,[ref]$uptime) -and
                    $uptime -ge 0 -and $uptime -le 60 -and
                    [datetime]::TryParseExact($fields[0],$dateFormat,$culture,$dateStyle,[ref]$homeSince)
            }
            continue
        }
        if ($line -match '\[FLog::SingleSurfaceApp\].*\b(?:launchUGCGame|leaveUGCGame):' -or
            $line -match '\[(?:F|DF)Log::Network(?:Client)?\].*\b(?:NetworkClient:Create|Connection accepted from)\b') {
            $joinObserved=$true
            $atHome=$false
        }
        elseif ($line -match '\[FLog::SingleSurfaceApp\].*\breturnToLuaAppInternal:') {
            $atHome=$false
        }
        if (-not $atHome -or $line -notmatch '\[(?:F|DF)Log::HttpTraceError\]\s+HttpResponse\(') { continue }
        $endpoint=[regex]::Match($line,'\burl:\s*\{\s*"(?<url>https://[^?"\s]+)(?:\?[^"\r\n]*)?"')
        if (-not $endpoint.Success) { continue }
        $service=switch -Regex ($endpoint.Groups['url'].Value) {
            '^https://apis\.roblox\.com/guac-v2/v1/bundles/app-policy$' { 'Policy'; break }
            '^https://users\.roblox\.com/v1/users/authenticated/app-launch-info$' { 'Launch'; break }
            '^https://apis\.roblox\.com/user-heartbeats-api/(?:pulse|action-report)$' { 'Heartbeat'; break }
        }
        if (-not $service) { continue }
        if ($line -match '\bstatus:\s*2\d\d\b') { $failures.Remove($service); continue }
        if ($line -notmatch '\bmessage:HttpError:\s*(?:Timedout|InactivityTimeout)\b') { continue }
        $when=[datetime]::MinValue
        $dateText=($line -split ',',2)[0]
        if (-not [datetime]::TryParseExact($dateText,$dateFormat,$culture,$dateStyle,[ref]$when)) { continue }
        if ($when -ge $homeSince -and $when -le $homeSince.AddMinutes(1)) { $failures[$service]=$when }
    }
    if (-not $atHome -or $failures.Count -ne 3) { return $false }
    $times=@($failures.Values | Sort-Object)
    return (($times[-1]-$times[0]).TotalSeconds -le 30)
}

function Get-LauncherSessionState {
    param([datetime]$Deadline = [datetime]::UtcNow.AddSeconds($Config.CommandTimeout), [switch]$RequireReady=$true, [switch]$CheckStartupConnection)
    $null=Get-GameStatusCommandBudget -Deadline $Deadline
    $crashed=@(Get-VisibleAppCrashPackages -Deadline $Deadline)
    if($script:AppCrashRestartPending){throw (New-AppCrashError $script:AppCrashRestartPending)}
    if ($crashed -ccontains $Config.GamePackage) { return (Publish-GameAppObservation 'Crashed') }
    
    
    $pidText = Get-GameAppPids -Package $Config.GamePackage -Deadline $Deadline
    if (-not $pidText) { return (Publish-GameAppObservation 'Closed') }
    if ($pidText -notmatch '^\d+$') { return (Publish-GameAppObservation 'Unknown') }
    $launcherProcessId = $pidText
    $descriptors = Invoke-GameStatusCommand -Command "shell su -c 'ls -l /proc/$launcherProcessId/fd'" -Description 'find the current game log' -Deadline $Deadline
    $logPattern = '(?m)^\S+[^\r\n]*?\s(?<fd>\d+)\s+->\s+(?<log>/data/(?:data|user/0)/' + [regex]::Escape($Config.GamePackage) + '/files/appData/logs/[^\r\n]*_Player_[^\r\n]*\.log)\s*(?:\(deleted\))?\s*$'
    $logs = @([regex]::Matches($descriptors, $logPattern) | Sort-Object { $_.Groups['log'].Value } -Descending)
    if ($logs.Count -eq 0) { return (Publish-GameAppObservation (Get-LauncherStateWithPresentation -State Unknown -Deadline $Deadline)) }
    $descriptor = $logs[0].Groups['fd'].Value
    
    
    $readyPatterns='';$readyCategory=''
    if ($RequireReady -and $Config.GameReadyLogMarker) {
        $readyPatterns=" -e JoinLoad -e $($Config.GameReadyLogMarker)"
        $readyCategory=' -e Log::CreatorOutput]'
    }
    
    
    
    
    
    $logCommand="shell su -c 'grep -ai -e reason: -e Disconnection.Notification -e another.device -e different.device -e no.response -e Client:Create -e accepted.from -e disconnected -e connection.lost -e setStage -e shake.complete -e UGCGame -e returnToLua$readyPatterns /proc/$launcherProcessId/fd/$descriptor | grep -a -e SingleSurfaceApp -e Log::Network] -e Log::NetworkClient] -e Log::RbxTransportRnaExpConnection]$readyCategory | tail -n 100'"
    $events = Invoke-GameStatusCommand -Command $logCommand -Description 'read the current game log' -Deadline $Deadline
    $awaitingJoinResponse=$false
    $state=Convert-LauncherEventsToState -Events $events -ReadyMarker $Config.GameReadyLogMarker -AwaitingJoinResponse ([ref]$awaitingJoinResponse)
    if ($RequireReady -and $Config.GameReadyLogMarker -and $state -eq 'InGame' -and -not (Test-LauncherReadyEvents -Events $events -Marker $Config.GameReadyLogMarker)) {
        $state='Joining'
    }
    if ($state -eq 'Joining' -and $awaitingJoinResponse) {
        $httpCommand="shell su -c 'grep -ai gamejoin[.]roblox[.]com/v1/join-private-game /proc/$launcherProcessId/fd/$descriptor | grep -a -e Log::HttpTraceError] | tail -n 10'"
        try { $httpEvents=Invoke-GameStatusCommand -Command $httpCommand -Description 'check for a private-server join failure' -Deadline $Deadline }
        catch [InvalidOperationException] {
            if (-not $_.Exception.Data['GameStatusReadFailed']) { throw }
            return (Publish-GameAppObservation $state)
        }
        if ($httpEvents) {
            
            $orderedEvents=(($events+[Environment]::NewLine+$httpEvents) -split '\r?\n' | Sort-Object) -join [Environment]::NewLine
            if ((Convert-LauncherEventsToState -Events $orderedEvents -ReadyMarker $Config.GameReadyLogMarker) -eq 'Disconnected') { return (Publish-GameAppObservation 'Disconnected') }
        }
    }
    $state=Get-LauncherStateWithPresentation -State $state -Deadline $Deadline
    if($state -eq 'Minimized'){return (Publish-GameAppObservation $state)}
    if ($state -eq 'Home' -and $CheckStartupConnection) {
        if ($null -eq $script:NextStartupConnectionProbe) { $script:NextStartupConnectionProbe=@{} }
        $lastProbe=$script:NextStartupConnectionProbe[$Config.GamePackage]
        $now=[datetime]::UtcNow
        if ($lastProbe.ProcessId -ne $launcherProcessId -or $now -ge $lastProbe.NextCheck) {
            $script:NextStartupConnectionProbe[$Config.GamePackage]=@{
                ProcessId=$launcherProcessId
                NextCheck=$now.AddSeconds([math]::Max(1,$Config.GameCheckInterval))
            }
            
            
            $startupCommand="shell su -c 'grep -a -e app-policy -e app-launch-info -e user-heartbeats-api -e setStage: -e launchUGCGame: -e NetworkClient:Create -e accepted -e leaveUGCGame: -e returnToLuaAppInternal: /proc/$launcherProcessId/fd/$descriptor | tail -n 40'"
            try { $startupEvents=Invoke-GameStatusCommand -Command $startupCommand -Description 'check the Home startup connection' -Deadline $Deadline }
            catch [InvalidOperationException] {
                if (-not $_.Exception.Data['GameStatusReadFailed']) { throw }
                return (Publish-GameAppObservation $state)
            }
            if (Test-LauncherStartupConnectionFailure -Events $startupEvents) { return (Publish-GameAppObservation 'StartupConnectionFailed') }
        }
    }
    if($RequireReady -and $state -eq 'InGame'){Reset-JoinedAppCrashCount}
    return (Publish-GameAppObservation $state)
}

function Test-GameConnectionErrorDialog {
    param([datetime]$Deadline)
    $now=[datetime]::UtcNow
    $package=$Config.GamePackage
    
    
    if ($null -eq $script:NextGameConnectionDialogProbe) { $script:NextGameConnectionDialogProbe=@{} }
    if ($now -lt $script:NextGameConnectionDialogProbe[$package]) { return $false }
    $probeDeadline=$now.AddSeconds([math]::Min(12,$Config.CommandTimeout))
    if ($probeDeadline -gt $Deadline) { $probeDeadline=$Deadline }
    if (($probeDeadline-$now).TotalSeconds -lt 3) { return $false }
    $script:NextGameConnectionDialogProbe[$package]=$now.AddSeconds([math]::Max(1,$Config.GameCheckInterval))
    try { $screen=Get-ScreenXml -Deadline $probeDeadline -SkipAnr }
    catch [System.Management.Automation.PipelineStoppedException] { throw }
    catch [OperationCanceledException] { throw }
    catch { return $false }
    if ($null -eq $screen) { return $false }

    $labels=foreach ($node in $screen.SelectNodes('//node')) {
        if ($node.GetAttribute('package') -cne $package -or $node.GetAttribute('visible-to-user') -eq 'false') { continue }
        $label=$node.GetAttribute('text')
        $description=$node.GetAttribute('content-desc')
        if ($label) { $label }
        if ($description -and $description -cne $label) { $description }
    }
    $dialogText=($labels -join ' ') -replace '\s+',' '
    return ($dialogText -match '\bConnection Error\b' -and
            $dialogText -match '\bthere was a problem reaching our servers\b' -and
            $dialogText -match '\bRetry\b')
}

function Clear-GameHomeLinkTimer {
    if ($null -ne $script:GameLinkSentAt) { $script:GameLinkSentAt.Remove($Config.GamePackage) }
}

function Get-LauncherSetupSessionState {
    param([datetime]$Deadline)
    $state='Unknown'
    $readError=$null
    try { $state=Get-LauncherSessionState -Deadline $Deadline -RequireReady -CheckStartupConnection }
    catch [InvalidOperationException] {
        if (-not $_.Exception.Data['GameStatusReadFailed']) { throw }
        $readError=$_
        if((Get-LauncherStateWithPresentation -State Unknown -Deadline $Deadline -CachedOnly) -eq 'Minimized'){$state='Minimized';$readError=$null}
    }
    if ($state -eq 'InGame') { Clear-GameHomeLinkTimer }
    $minimizedHome=$state -eq 'Minimized' -and $null -ne $script:GameAppPresentation -and $script:GameAppPresentation.ContainsKey($Config.GamePackage) -and $script:GameAppPresentation[$Config.GamePackage].LogicalState -eq 'Home'
    $atHome=$state -eq 'Home' -or $minimizedHome
    if ($atHome -and $null -ne $script:GameLinkSentAt -and $script:GameLinkSentAt.ContainsKey($Config.GamePackage)) {
        $homeTimeout=60
        if ($Config.GameHomeTimeout) { $homeTimeout=$Config.GameHomeTimeout }
        if (([datetime]::UtcNow-$script:GameLinkSentAt[$Config.GamePackage]).TotalSeconds -ge $homeTimeout) {
            $failure=[TimeoutException]::new("Game app is still on Home $homeTimeout seconds after sending the server link. Restarting the affected app through the normal recovery flow.")
            $failure.Data['GameHomeTimeout']=$true
            Register-FlowStageTimeout -Stage Game
            throw $failure
        }
    }
    if($state -eq 'Minimized'){return $state}
    if ($state -notin @('InGame','Disconnected','Blocked','Crashed') -and (Test-GameConnectionErrorDialog -Deadline $Deadline)) {
        throw 'Roblox Connection Error dialog confirmed. Restarting the affected app.'
    }
    if ($state -eq 'StartupConnectionFailed') {
        throw 'Roblox startup requests timed out while the app stayed on Home. Restarting the affected app.'
    }
    if ($readError) { throw $readError }
    return $state
}

function Wait-LauncherSessionState {
    param([int]$Seconds)
    $deadline = [datetime]::UtcNow.AddSeconds($Seconds)
    $state = 'Unknown'
    $readWarning=$false
    while ([datetime]::UtcNow -lt $deadline) {
        if($script:PoolRole -eq 'Setup'){Assert-PoolSetupTurn}
        try { $state = Get-LauncherSetupSessionState -Deadline $deadline }
        catch [InvalidOperationException] {
            if(-not $_.Exception.Data['GameStatusReadFailed']){throw}
            if(-not $readWarning){
                Write-FlowStatus "App-state read incomplete. Retrying within the original ${Seconds}-second wait. $($_.Exception.Message)"
                $readWarning=$true
            }
            $remaining=($deadline-[datetime]::UtcNow).TotalSeconds
            if($remaining -gt 0){Wait-FlowPause ([int][math]::Min([math]::Max(1,$Config.PollInterval),[math]::Ceiling($remaining)))}
            continue
        }
        catch [TimeoutException] {
            if ($_.Exception.Data['GameHomeTimeout']) { throw }
            return $state
        }
        if($state -eq 'Minimized'){Restore-GameAppWindow -Deadline $deadline;continue}
        if ($state -in @('Home', 'InGame', 'Joining', 'Disconnected', 'Blocked', 'Crashed','Minimized')) { return $state }
        Start-Sleep -Seconds $Config.PollInterval
    }
    return $state
}

function Open-ServerLinkWithRetry {
    $androidLink = $Config.ServerLink.Replace("'", '%27')
    $attempt = 0
    while ($true) {
        Enter-EmulatorLoadingSlot
        $attempt++
        Write-FlowStatus "Sending the server link (attempt $attempt)..."
        
        
        if ($null -ne $script:NextGameConnectionDialogProbe) {
            $script:NextGameConnectionDialogProbe.Remove($Config.GamePackage)
        }
        $commandTimedOut = $false
        try {
            
            if ($null -eq $script:GameLinkSentAt) { $script:GameLinkSentAt=@{} }
            $script:GameLinkSentAt[$Config.GamePackage]=[datetime]::UtcNow
            $result = Invoke-Android "shell am start -W -a android.intent.action.VIEW -c android.intent.category.BROWSABLE -d '$androidLink' -p $($Config.GamePackage)"
        }
        catch [TimeoutException] {
            $commandTimedOut = $true
            $result = $_.Exception.Message
        }
        if (-not $commandTimedOut -and $result -match '(?im)^\s*Status:\s*ok\s*$' -and $result -notmatch '(?i)(Error:|Error type|Exception|unable to resolve)') {
            Write-FlowStatus 'Server link opened.'
            return 'LinkOpened'
        }
        if (-not $commandTimedOut -and $result -notmatch '(?im)^\s*Status:\s*timeout\s*$') {
            throw ('Android did not confirm that the server link opened: ' + $result)
        }
        $session = Wait-LauncherSessionState -Seconds $Config.LauncherOpenTimeout
        if ($session -eq 'InGame') {
            Write-FlowStatus 'Android timed out, but launcher is already in a game. Preserving the session.'
            return 'AlreadyInGame'
        }
        if ($session -eq 'Joining') {
            Write-FlowStatus 'Android timed out, but launcher is already joining a game. Skipping a duplicate link.'
            return 'AlreadyJoining'
        }
        if ($session -eq 'Blocked') { throw 'Launcher reported an account/access/kick error. Automatic rejoining was stopped.' }
        if ($session -notin @('Home','Disconnected')) { throw 'Launcher game state could not be read after the timeout. The app was left open to avoid interrupting a possible game.' }
        Register-FlowStageTimeout -Stage Game
        if ($Config.MaxServerLinkAttempts -gt 0 -and $attempt -ge $Config.MaxServerLinkAttempts) {
            throw "Server link timed out after $attempt attempts."
        }
        Write-FlowStatus 'Server link timed out. Confirming the VPN before reopening the game app...'
        Ensure-SessionVpn
        Write-FlowStatus "VPN connected. Closing $($Config.GamePackage), then reopening and retrying..."
        Invoke-Ld -Arguments @('killapp', '--index', "$InstanceIndex", '--packagename', $Config.GamePackage) | Out-Null
        Start-Sleep -Seconds $Config.LauncherRelaunchDelay
        Clear-GameHomeLinkTimer
        Invoke-Ld -Arguments @('runapp', '--index', "$InstanceIndex", '--packagename', $Config.GamePackage) | Out-Null
        if (-not (Wait-AppForeground -Package $Config.GamePackage -Seconds $Config.LauncherOpenTimeout)) {
            Register-FlowStageTimeout -Stage Game
            throw "$($Config.GamePackage) did not reopen within $($Config.LauncherOpenTimeout) seconds after the server-link timeout."
        }
        $session = Wait-LauncherSessionState -Seconds $Config.LauncherOpenTimeout
        if ($session -eq 'InGame') {
            Write-FlowStatus 'Launcher reopened into a game. Skipping another server link.'
            return 'AlreadyInGame'
        }
        if ($session -eq 'Joining') {
            Write-FlowStatus 'Launcher is already joining after reopening. Skipping another server link.'
            return 'AlreadyJoining'
        }
        if ($session -ne 'Home') { throw 'Launcher reopened, but its Home/game state could not be confirmed. No duplicate link was sent.' }
    }
}

function Restart-DisconnectedLauncher {
    param([string]$Reason = 'Network disconnect confirmed')
    Ensure-SessionVpn
    Write-FlowStatus "$Reason. Closing and reopening $($Config.GamePackage)..."
    Invoke-Ld -Arguments @('killapp','--index',"$InstanceIndex",'--packagename',$Config.GamePackage) | Out-Null
    Start-Sleep -Seconds $Config.LauncherRelaunchDelay
    Clear-GameHomeLinkTimer
    Invoke-Ld -Arguments @('runapp','--index',"$InstanceIndex",'--packagename',$Config.GamePackage) | Out-Null
    if (-not (Wait-AppForeground -Package $Config.GamePackage -Seconds $Config.LauncherOpenTimeout)) {
        Register-FlowStageTimeout -Stage Game
        throw 'Launcher did not reopen within the configured opening timeout.'
    }
    $state = Wait-LauncherSessionState -Seconds $Config.LauncherOpenTimeout
    if ($state -eq 'InGame') { return 'AlreadyInGame' }
    if ($state -eq 'Joining') { return 'AlreadyJoining' }
    if ($state -eq 'Blocked') { throw 'Launcher reported an account/access/kick error. Automatic rejoining was stopped.' }
    if ($state -notin @('Home','Disconnected')) { throw 'Launcher reopened, but its game state could not be read. No link was sent.' }
    return (Open-ServerLinkWithRetry)
}

function Test-EmulatorResponsive {
    param($InstanceInfo = $null,[int]$TimeoutSeconds=10)
    try {
        if ($null -eq $InstanceInfo) { $InstanceInfo = Get-InstanceInfo -Id $InstanceIndex }
        if ($null -eq $InstanceInfo) { Set-EmulatorLiveObservation -EmulatorState Unknown;return $false }
        if ($InstanceInfo.ProcessId -le 0) { Set-EmulatorLiveObservation -EmulatorState Offline;return $false }
        $timeout = [math]::Max(10,[math]::Min($TimeoutSeconds,$Config.CommandTimeout))
        $reply = Invoke-Android 'shell dumpsys -t 3 activity activities' -TimeoutSeconds $timeout
        $responsive=$reply -notmatch '(?i)(DUMP TIMEOUT|device.*not found|device offline|cannot connect|error: closed)' -and $reply -match 'ACTIVITY MANAGER ACTIVITIES|mResumedActivity:|ResumedActivity:'
        Set-EmulatorLiveObservation -EmulatorState $(if($responsive){'Running'}else{'Unresponsive'})
        return $responsive
    }
    catch [System.Management.Automation.PipelineStoppedException] { throw }
    catch [OperationCanceledException] { throw }
    catch { Set-EmulatorLiveObservation -EmulatorState Unresponsive;return $false }
}

function Restart-AfterUnexpectedError {
    param([switch]$EmulatorOnly)
    if($script:PendingEmulatorRestore){Invoke-PendingEmulatorRestore;return 'EmulatorReopened'}
    $instance=Get-InstanceInfo -Id $InstanceIndex
    Sync-AppCrashBoot -BootIdentity ([long]$instance.ProcessId)
    $responsive=Test-EmulatorResponsive -InstanceInfo $instance
    $crashed=@();if($responsive){$crashed=@(Get-VisibleAppCrashPackages)}
    if($script:AppCrashRestartPending){
        Assert-PoolSetupTurn;Enter-EmulatorLoadingSlot
        $package=[string]$script:AppCrashRestartPending;$limit=2;if($Config.AppCrashLimit){$limit=[int]$Config.AppCrashLimit}
        $Config=$Config.Clone();$Config.GamePackage=$package;$Config.LauncherPackage=$package
        Write-FlowStatus "$package reached the crash limit ($limit). Closing all user apps before restarting this emulator."
        if($responsive){Close-AppsBeforeEmulatorRestart}
        else{Write-FlowStatus 'Android is not responding; app cleanup is unavailable. Closing this emulator.'}
        $EmulatorOnly=$true
    }
    if(-not $EmulatorOnly -and $responsive){
        if($crashed -ccontains $Config.GamePackage){Dismiss-AndroidAppCrashDialog -Package $Config.GamePackage}
        Write-FlowStatus "Android is responding. Closing only $($Config.GamePackage); its next turn will reopen and rejoin."
        $null=Invoke-Ld -Arguments @('killapp','--index',"$InstanceIndex",'--packagename',$Config.GamePackage)
        Clear-GameHomeLinkTimer;Clear-ProcessCheckCache
        return 'GameClosed'
    }
    Write-FlowStatus 'Restarting this emulator. The full package, cookie, VPN and game flow will run after it loads.'
    Set-EmulatorLiveObservation -EmulatorState Restarting -ResetApps
    if($null -ne $instance -and $instance.ProcessId -gt 0){$null=Invoke-Ld -Arguments @('quit','--index',"$InstanceIndex")}
    Reset-AppCrashTracking
    $script:CurrentEmulatorInstance=$null;$script:VpnVerifiedBoot=0;$script:RequiredAppsCheckedKey=$null
    Clear-ProcessCheckCache
    Wait-FlowPause ([math]::Max(1,$Config.InstanceRelaunchDelay))
    $script:RecoveringEmulator=$true
    
    
    return 'EmulatorReopened'
}

function Ensure-CloudflareConnected {
    $attempt=0
    while ($true) {
        $attempt++
        $connectionTimedOut=$false
        Write-FlowStatus "Checking Cloudflare VPN (attempt $attempt). The game app will wait until Connected."
        try {
            $connected=$false
            try { $connected=Test-CloudflareVpnConnected }
            catch [System.Management.Automation.PipelineStoppedException] { throw }
            catch [OperationCanceledException] { throw }
            catch { Write-FlowStatus ('Background VPN status is unavailable: '+$_.Exception.Message+'. Checking Cloudflare itself.') }
            if ($connected) {
                Reset-FlowStageTimeout -Stage Cloudflare
                Write-FlowStatus 'Cloudflare VPN is connected. Continuing to the game app.'
                return
            }
            if (Test-AppForeground -Package $CloudflarePackage) {
                Write-FlowStatus 'Cloudflare is already on screen. Skipping its opening step.'
            }
            else {
                Write-FlowStatus "Bringing Cloudflare to the screen (attempt $attempt)..."
                Invoke-Ld -Arguments @('killapp', '--index', "$InstanceIndex", '--packagename', $CloudflarePackage) | Out-Null
                Start-Sleep -Seconds $Config.CloudflareRetryDelay
                Invoke-Ld -Arguments @('runapp', '--index', "$InstanceIndex", '--packagename', $CloudflarePackage) | Out-Null
            }
            $state = Wait-CloudflareState -States @('Disconnected', 'Connected') -Seconds $Config.CloudflareOpenTimeout
            if ($state -ceq 'Connected') { Reset-FlowStageTimeout -Stage Cloudflare;Write-FlowStatus 'Cloudflare is Connected. Continuing to the game app.'; return }
            if ($state -ceq 'Disconnected') {
                Tap-ScreenCenter
                Write-FlowStatus "Waiting up to $($Config.CloudflareConnectTimeout) seconds for Connected..."
                $state = Wait-CloudflareState -States @('Connected') -Seconds $Config.CloudflareConnectTimeout
                if ($state -ceq 'Connected') { Reset-FlowStageTimeout -Stage Cloudflare;Write-FlowStatus 'Cloudflare is Connected. Continuing to the game app.'; return }
            }
            $connectionTimedOut=$true
        }
        catch [System.Management.Automation.PipelineStoppedException] { throw }
        catch [OperationCanceledException] { throw }
        catch [TimeoutException] {$connectionTimedOut=$true;Write-FlowStatus 'Cloudflare check timed out. Rechecking the background connection before recovery.'}
        catch { Write-FlowStatus ('Cloudflare check failed: '+$_.Exception.Message+'. Retrying Cloudflare; the game app stays untouched.') }

        
        try {
            if (Test-CloudflareVpnConnected) { Reset-FlowStageTimeout -Stage Cloudflare;Write-FlowStatus 'Cloudflare VPN is connected. Continuing to the game app.'; return }
        }
        catch [System.Management.Automation.PipelineStoppedException] { throw }
        catch [OperationCanceledException] { throw }
        catch { }
        if($connectionTimedOut){Register-FlowStageTimeout -Stage Cloudflare}
        if (-not (Test-EmulatorResponsive)) { throw [TimeoutException]::new('Emulator stopped responding during Cloudflare setup.') }
        try {
            Invoke-Ld -Arguments @('killapp', '--index', "$InstanceIndex", '--packagename', $CloudflarePackage) | Out-Null
        }
        catch [System.Management.Automation.PipelineStoppedException] { throw }
        catch [OperationCanceledException] { throw }
        catch { Write-FlowStatus ('Could not close Cloudflare yet: '+$_.Exception.Message) }
        if ($Config.MaxCloudflareAttempts -gt 0 -and $attempt -ge $Config.MaxCloudflareAttempts) { throw "Cloudflare did not connect after $attempt attempts. The game app was left untouched." }
        Write-FlowStatus 'Cloudflare is not connected. Reopening Cloudflare before proceeding.'
        Start-Sleep -Seconds $Config.CloudflareRetryDelay
    }
}

function Invoke-EmulatorFlow {
    param([switch]$DisconnectConfirmed)
    Enter-EmulatorLoadingSlot
    Start-SelectedEmulator -InstanceInfo $script:CurrentEmulatorInstance
    $script:RecoveryScope='Game'
    if ($Config.CookieStorePath -and -not (Save-LoadedEmulatorAppData -BootIdentity $script:CookieBootIdentity)) {
        if (-not (Test-EmulatorResponsive)) { throw [TimeoutException]::new('Emulator stopped responding during initial game-data capture.') }
        throw (New-GameStatusReadError 'Initial game-data save/restore is incomplete. The app remains closed for retry.')
    }
    if ($Config.AutoRestartHours -gt 0 -and $Config.GamePackages.Count -le 1) { $null=Invoke-ScheduledEmulatorRestart -InstanceInfo (Get-InstanceInfo -Id $InstanceIndex) }
    if($Config.GamePackages.Count -eq 1){Complete-InitialCookieChecks -Results @((Get-SetupGameAppData))}
    if (@(Get-VisibleAppCrashPackages) -ccontains $Config.GamePackage) { throw (New-AppCrashError $Config.GamePackage) }
    Ensure-SessionVpn
    Write-FlowStatus "Checking whether $($Config.GamePackage) is running..."
    if (Test-AppRunning -Package $Config.GamePackage) {
        Write-FlowStatus 'Game app is running. Reading its current Home/game state...'
    }
    else {
        if ($null -eq (Get-AppUid -Package $Config.GamePackage)) { throw "$($Config.GamePackage) could not be found. Confirm it is installed in this emulator." }
        Write-FlowStatus "Opening $($Config.GamePackage) and confirming it is on screen..."
        if (-not $DisconnectConfirmed) {
            Invoke-Ld -Arguments @('killapp', '--index', "$InstanceIndex", '--packagename', $Config.GamePackage) | Out-Null
        }
        Start-Sleep -Seconds $Config.LauncherRelaunchDelay
        Clear-GameHomeLinkTimer
        Invoke-Ld -Arguments @('runapp', '--index', "$InstanceIndex", '--packagename', $Config.GamePackage) | Out-Null

    }
    $session = Wait-LauncherSessionState -Seconds $Config.LauncherOpenTimeout
    if($session -eq 'Minimized'){
        Restore-GameAppWindow -Deadline ([datetime]::UtcNow.AddSeconds($Config.LauncherOpenTimeout))
        $session=Wait-LauncherSessionState -Seconds $Config.LauncherOpenTimeout
    }
    if ($session -eq 'Disconnected' -and -not $DisconnectConfirmed) {
        Write-FlowStatus 'A network disconnect was logged. Checking again before restarting...'
        Start-Sleep -Seconds $Config.GameCheckInterval
        $session = Wait-LauncherSessionState -Seconds $Config.LauncherOpenTimeout
    }
    if ($session -eq 'Disconnected') { throw 'Game disconnect confirmed; restarting the affected app.' }
    if ($session -eq 'Blocked') { throw 'Launcher reported an account/access/kick error. Automatic rejoining was stopped.' }
    if ($session -eq 'InGame') {
        Write-FlowStatus 'Game app is already in a game. Skipping the server link to preserve the session.'
        return 'AlreadyInGame'
    }
    if ($session -eq 'Joining') {
        Write-FlowStatus 'Game app is already joining a game. Skipping a duplicate server link.'
        return 'AlreadyJoining'
    }
    if ($session -in @('Unknown','Minimized','Closed')) {
        throw [TimeoutException]::new('App opening timed out before Home or a game could be confirmed.')
    }
    if ($session -ne 'Home') {
        throw 'Could not distinguish Home from an active game using the current launcher log. No link was sent. Check that LDPlayer root access is enabled.'
    }
    Write-FlowStatus 'Game app is on the Roblox app screen, outside a game. Sending the server link...'
    return (Open-ServerLinkWithRetry)
}

function ConvertTo-GameCookieValue {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '' }
    $valueText=$Value.Trim()
    if ($valueText.StartsWith('.ROBLOSECURITY=')) { $valueText=$valueText.Substring(15) }
    if ($valueText -and ($valueText.Length -lt 64 -or $valueText -cmatch '[\x00-\x20\x7f-\uffff;]')) {
        throw 'A cookie entry is not a complete cookie value. Correct cookies.json; values are not printed.'
    }
    return $valueText
}

function Read-GameCookieStore {
    if (-not (Test-Path -LiteralPath $Config.CookieStorePath -PathType Leaf)) { throw 'cookies.json is missing; waiting for the cookie file.' }
    try {
        $json=[IO.File]::ReadAllText($Config.CookieStorePath)
        if (-not $json.Trim()) { return @{} }
        $document=ConvertFrom-Json -InputObject $json -ErrorAction Stop
        if ($null -eq $document -or $document -isnot [pscustomobject]) { throw 'Invalid document' }
        $entries=@{}
        foreach ($instance in $document.PSObject.Properties) {
            if ($instance.Name -notmatch '^\d+$' -or $instance.Value -isnot [pscustomobject]) { throw 'Invalid instance entry' }
            $apps=@{}
            foreach ($app in $instance.Value.PSObject.Properties) {
                if ($app.Name -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$' -or ($null -ne $app.Value -and $app.Value -isnot [string])) { throw 'Invalid package entry' }
                $apps[$app.Name]=[string]$app.Value
            }
            $entries[$instance.Name]=$apps
        }
        return $entries
    } catch { throw 'cookies.json could not be read as an emulator/package cookie map. Fix the file; apps are not changed.' }
}

function Protect-GameCookieFile {
    param([string]$Path)
    $file=[IO.FileInfo]::new($Path)
    $section=[Security.AccessControl.AccessControlSections]::Access
    if($PSVersionTable.PSVersion.Major -ge 6){$security=[IO.FileSystemAclExtensions]::GetAccessControl($file,$section)}
    else{$security=$file.GetAccessControl($section)}
    $user=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $security.SetSecurityDescriptorSddlForm("D:P(A;;FA;;;$user)(A;;FA;;;SY)(A;;FA;;;BA)",$section)
    
    if($PSVersionTable.PSVersion.Major -ge 6){[IO.FileSystemAclExtensions]::SetAccessControl($file,$security)}
    else{$file.SetAccessControl($security)}
}

function Update-GameCookieStore {
    param([int[]]$InitializeIds=@(),[string]$Package='',[AllowNull()][string]$Cookie=$null,[switch]$Capture,[switch]$Clear,[AllowNull()][string]$ExpectedCookie=$null,[switch]$Replace,[switch]$PreferApp,[switch]$ClearAll,[int]$MoveFromId=-1,[int]$MoveToId=-1)
    $mutex=New-Object Threading.Mutex $false,$Config.CookieStoreMutexName
    $held=$false; $temporary=$null
    try {
        try { $held=$mutex.WaitOne([math]::Max(1000,$Config.CommandTimeout*1000)) }
        catch [Threading.AbandonedMutexException] { $held=$true }
        if (-not $held) { throw 'Cookie file is busy; retrying at the next game check.' }
        $exists=Test-Path -LiteralPath $Config.CookieStorePath -PathType Leaf
        $entries=@{}
        if ($exists) { $entries=Read-GameCookieStore }
        $changed=-not $exists
        foreach ($id in $InitializeIds) {
            $key=[string]$id
            if (-not $entries.ContainsKey($key)) { $entries[$key]=@{}; $changed=$true }
            foreach ($app in $Config.GamePackages) {
                if (-not $entries[$key].ContainsKey($app)) { $entries[$key][$app]=''; $changed=$true }
            }
        }
        if($MoveFromId -ge 0 -or $MoveToId -ge 0){
            if($MoveFromId -le 0 -or $MoveToId -le $MoveFromId){throw 'Cookie ID migration requires distinct old and newer instance IDs.'}
            $oldKey=[string]$MoveFromId;$newKey=[string]$MoveToId
            if($entries.ContainsKey($oldKey)){
                if(-not $entries.ContainsKey($newKey)){$entries[$newKey]=@{}}
                foreach($app in $entries[$oldKey].Keys){
                    $oldValue=[string]$entries[$oldKey][$app];$newValue=[string]$entries[$newKey][$app]
                    if($oldValue -and $newValue -and $oldValue -cne $newValue){throw 'The new instance ID already has a different saved cookie. Both accounts were preserved; resolve this conflict before retrying.'}
                    if($oldValue -or -not $entries[$newKey].ContainsKey($app)){$entries[$newKey][$app]=$oldValue}
                }
                $entries.Remove($oldKey);$changed=$true
            }
        }
        if($ClearAll){
            if(Test-LauncherRunning -Directory ([IO.Path]::GetDirectoryName($Config.CookieStorePath))){throw 'Stop the tool before clearing saved cookies.'}
            foreach($id in @($entries.Keys)){
                foreach($app in @($entries[$id].Keys)){
                    if($entries[$id][$app] -cne ''){$entries[$id][$app]='';$changed=$true}
                }
            }
        }
        if ($Package) {
            $key=[string]$InstanceIndex
            if (-not $entries.ContainsKey($key)) { $entries[$key]=@{}; $changed=$true }
            if (-not $entries[$key].ContainsKey($Package)) { $entries[$key][$Package]=''; $changed=$true }
            $current=''
            if (-not $Replace -and -not $PreferApp) {$current=ConvertTo-GameCookieValue $entries[$key][$Package]}
            if ($Capture -and -not $current) { $entries[$key][$Package]=$Cookie; $changed=$true }
            if ($Clear -and $current -ceq $ExpectedCookie) { $entries[$key][$Package]=''; $changed=$true }
            if ($PreferApp -and $entries[$key][$Package] -cne $Cookie) {$entries[$key][$Package]=$Cookie;$changed=$true}
            if ($Replace) {
                if (Test-LauncherRunning -Directory ([IO.Path]::GetDirectoryName($Config.CookieStorePath))) {throw 'Stop the tool before editing a saved cookie.'}
                $entries[$key][$Package]=$Cookie; $changed=$true
            }
        }
        if ($changed) {
            $ordered=[ordered]@{}
            foreach ($key in @($entries.Keys | Sort-Object {[int]$_})) {
                $ordered[$key]=[ordered]@{}
                foreach ($app in @($entries[$key].Keys | Sort-Object)) { $ordered[$key][$app]=$entries[$key][$app] }
            }
            $temporary=$Config.CookieStorePath+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
            [IO.File]::WriteAllText($temporary,'')
            Protect-GameCookieFile -Path $temporary
            $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($ordered | ConvertTo-Json -Depth 5)+"`r`n")
            $stream=[IO.File]::Open($temporary,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
            if ($exists) {
                Protect-GameCookieFile -Path $Config.CookieStorePath
                [IO.File]::Replace($temporary,$Config.CookieStorePath,[NullString]::Value)
            } else { [IO.File]::Move($temporary,$Config.CookieStorePath) }
            $temporary=$null
            Protect-GameCookieFile -Path $Config.CookieStorePath
        }
        return $entries
    }
    finally {
        if ($temporary -and (Test-Path -LiteralPath $temporary)) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-GameAppDataRoot {
    param($Settings=$Config)
    $base=if($Settings.ConfigFilePath){[IO.Path]::GetDirectoryName($Settings.ConfigFilePath)}else{[IO.Path]::GetDirectoryName($Settings.CookieStorePath)}
    if(-not $base){throw 'The app-data storage folder is unavailable.'}
    return (Join-Path $base 'app-data')
}

function Get-GameAppDataPaths {
    param([int]$Id=$InstanceIndex,[string]$Package=$Config.GamePackage,$Settings=$Config)
    if($Id -lt 0 -or $Package -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$'){throw 'Invalid app-data identity.'}
    $root=Get-GameAppDataRoot $Settings;$directory=Join-Path (Join-Path $root "$Id") $Package
    Assert-InstanceReplacementDirectory $directory $root
    return @{Root=$root;Directory=$directory;Manifest=(Join-Path $directory 'manifest.json');Cookie=(Join-Path $directory '.ROBLOSECURITY')}
}

function Initialize-GameAppDataStore {
    $root=Get-GameAppDataRoot
    $null=[IO.Directory]::CreateDirectory($root)
    Assert-InstanceReplacementDirectory (Join-Path $root '0') ([IO.Path]::GetDirectoryName($root))
    $directory=[IO.DirectoryInfo]::new($root);$section=[Security.AccessControl.AccessControlSections]::Access
    if($PSVersionTable.PSVersion.Major -ge 6){$security=[IO.FileSystemAclExtensions]::GetAccessControl($directory,$section)}else{$security=$directory.GetAccessControl($section)}
    $user=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $security.SetSecurityDescriptorSddlForm("D:P(A;OICI;FA;;;$user)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)",$section)
    if($PSVersionTable.PSVersion.Major -ge 6){[IO.FileSystemAclExtensions]::SetAccessControl($directory,$security)}else{$directory.SetAccessControl($security)}
    Write-Host 'Game-data storage ready: app-data (one private snapshot per emulator ID and app package). Cookie validation is disabled.'
}

function Invoke-GameAppDataAdb {
    param([string[]]$Arguments,[string]$InputText='',[int]$TimeoutSeconds=0)
    if(-not $script:CookieAdbSerial){
        $serial=(Invoke-Ld -Arguments @('adb','--index',"$InstanceIndex",'--command','get-serialno')).Trim()
        if($serial -notmatch '^(emulator-\d+|(?:127\.0\.0\.1|localhost):\d+)$'){throw 'The emulator ADB identity is unavailable for game data.'}
        $script:CookieAdbSerial=$serial
    }
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=Join-Path $Config.LdPlayerInstallPath 'adb.exe'
    $info.Arguments=(@('-s',$script:CookieAdbSerial)+$Arguments|ForEach-Object{ConvertTo-NativeArgument $_}) -join ' '
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process;$process.StartInfo=$info
    try{
        $null=$process.Start();$output=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
        if($InputText.Length){
            $write=$process.StandardInput.WriteAsync(($InputText -replace "`r`n","`n").TrimEnd([char[]]"`r`n")+"`n")
            if(-not $write.Wait(10000)){throw 'Game-data input timed out.'}
        }
        $process.StandardInput.Close()
        $watch=[Diagnostics.Stopwatch]::StartNew();$timeout=if($TimeoutSeconds -gt 0){[math]::Max(10,$TimeoutSeconds)}else{[math]::Max(600,$Config.CommandTimeout)}
        while(-not $process.WaitForExit(500)){
            if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Stopped during game-data transfer; the saved snapshot is preserved.')}
            if($watch.Elapsed.TotalSeconds -ge $timeout){throw 'Game-data transfer timed out. The previous snapshot is preserved.'}
        }
        if(-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($output,$errors),2000) -or $process.ExitCode -ne 0){throw 'Game-data transfer did not complete. Saved snapshots were preserved.'}
        return $output.Result.Trim()
    }finally{try{if(-not $process.HasExited){$process.Kill()}}catch{};$process.Dispose()}
}

function Read-GameAppDataManifest {
    param($Paths)
    if(-not [IO.File]::Exists($Paths.Manifest)){return $null}
    $entry=ConvertFrom-Json ([IO.File]::ReadAllText($Paths.Manifest))
    if($entry.Version -ne 1 -or $entry.Package -cne [IO.Path]::GetFileName($Paths.Directory) -or $entry.Archive -notmatch '^snapshot-[a-f0-9]{32}[.]tar$' -or $entry.Sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or $entry.Length -le 0){throw 'The saved game-data manifest is invalid. No app data was changed.'}
    $archive=Join-Path $Paths.Directory $entry.Archive;Assert-InstanceReplacementDirectory $archive $Paths.Root
    if(-not [IO.File]::Exists($archive) -or ([IO.FileInfo]$archive).Length -ne $entry.Length){throw 'The saved game-data archive is missing or incomplete. No app data was changed.'}
    return $entry
}

function Initialize-GameAppCookieArchiveNative {
    if('LauncherGameCookieTar' -as [type]){return}
    $gate=[string]::Intern('Launcher.GameCookieTar');[Threading.Monitor]::Enter($gate)
    try{
    if('LauncherGameCookieTar' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
public static class LauncherGameCookieTar {
    static void Exact(Stream s, byte[] b) { int n=0,r; while(n<b.Length) {r=s.Read(b,n,b.Length-n);if(r==0)throw new IOException("Incomplete snapshot header.");n+=r;} }
    static string Text(byte[] b,int o,int n) {int e=o;while(e<o+n && b[e]!=0)e++;return Encoding.UTF8.GetString(b,o,e-o);}
    static long Number(byte[] b,int o,int n) {
        long v=0;checked {if((b[o]&128)!=0) {if((b[o]&64)!=0)throw new IOException("Negative snapshot size.");v=b[o]&127;for(int i=1;i<n;i++)v=v*256+b[o+i];}
        else {string t=Text(b,o,n).Trim();foreach(char c in t){if(c<'0'||c>'7')throw new IOException("Invalid snapshot size.");v=v*8+c-'0';}}} return v;
    }
    static void Copy(Stream src,Stream dst,long n,string stop,byte[] b) {
        while(n>0){if(!String.IsNullOrEmpty(stop)&&File.Exists(stop))throw new OperationCanceledException("Stopped during saved-cookie update.");int r=src.Read(b,0,(int)Math.Min(n,b.Length));if(r==0)throw new IOException("Incomplete snapshot contents.");dst.Write(b,0,r);n-=r;}
    }
    static Dictionary<string,string> Pax(byte[] b) {
        var d=new Dictionary<string,string>();int p=0;while(p<b.Length){int space=Array.IndexOf(b,(byte)32,p);if(space<0)throw new IOException("Invalid snapshot metadata.");int n;if(!Int32.TryParse(Encoding.ASCII.GetString(b,p,space-p),out n)||n<=space-p+2||n>b.Length-p)throw new IOException("Invalid snapshot metadata.");string t=Encoding.UTF8.GetString(b,space+1,p+n-space-2);int eq=t.IndexOf('=');if(eq>0)d[t.Substring(0,eq)]=t.Substring(eq+1);p+=n;}return d;
    }
    public static bool Extract(string input,string package,string stage,string stop) {return Walk(input,null,package,stage,null,stop);}
    public static void Rewrite(string input,string output,string package,string database,string stop) {if(!Walk(input,output,package,null,database,stop))throw new IOException("Snapshot cookie database is missing.");}
    static bool Walk(string input,string output,string package,string stage,string database,string stop) {
        string cookie="data/data/"+package+"/app_webview/Default/Cookies";
        bool found=false;var seen=new HashSet<string>();var pending=new MemoryStream();string pathOverride=null;long? sizeOverride=null;byte[] buffer=new byte[1048576];
        using(var src=new FileStream(input,FileMode.Open,FileAccess.Read,FileShare.Read))
        using(var dst=output==null?null:new FileStream(output,FileMode.CreateNew,FileAccess.Write,FileShare.None)) {
            while(src.Position<src.Length) {
                if(!String.IsNullOrEmpty(stop)&&File.Exists(stop))throw new OperationCanceledException("Stopped during saved-cookie update.");
                byte[] h=new byte[512];Exact(src,h);bool zero=true;foreach(byte b in h)if(b!=0){zero=false;break;}
                if(zero){if(pending.Length!=0)throw new IOException("Unfinished snapshot metadata.");byte[] tail=new byte[1048576];int r;while((r=src.Read(tail,0,tail.Length))>0)for(int i=0;i<r;i++)if(tail[i]!=0)throw new IOException("Unexpected data after snapshot end.");if(dst!=null)dst.Write(new byte[1024],0,1024);return found;}
                long sum=0;for(int i=0;i<512;i++)sum+=(i>=148&&i<156)?32:h[i];if(sum!=Number(h,148,8))throw new IOException("Snapshot header failed verification.");
                string name=Text(h,0,100),prefix=Text(h,345,155);if(prefix.Length>0&&Text(h,257,6).StartsWith("ustar"))name=prefix+"/"+name;
                long size=Number(h,124,12);char type=(char)h[156];
                if(type=='x'||type=='L'||type=='K'||type=='g'){
                    if(size>1048576||pending.Length>4194304)throw new IOException("Oversized snapshot metadata.");
                    byte[] data=new byte[(int)size];Exact(src,data);int padding=(int)((512-size%512)%512);byte[] pad=new byte[padding];Exact(src,pad);
                    if(type=='g'){var global=Pax(data);if(global.ContainsKey("path")||global.ContainsKey("size"))throw new IOException("Unsupported global snapshot path/size metadata.");if(dst!=null){dst.Write(h,0,512);dst.Write(data,0,data.Length);dst.Write(pad,0,pad.Length);}continue;}
                    pending.Write(h,0,512);pending.Write(data,0,data.Length);pending.Write(pad,0,pad.Length);
                    if(type=='L')pathOverride=Encoding.UTF8.GetString(data).TrimEnd('\0','\n');
                    if(type=='x'){var meta=Pax(data);if(meta.ContainsKey("path"))pathOverride=meta["path"];if(meta.ContainsKey("size")){long s;if(!Int64.TryParse(meta["size"],out s)||s<0)throw new IOException("Invalid snapshot metadata size.");sizeOverride=s;}}
                    continue;
                }
                if(pathOverride!=null)name=pathOverride;
                long actual=sizeOverride??size;long padded=checked(actual+(512-actual%512)%512);if(padded>src.Length-src.Position)throw new IOException("Incomplete snapshot contents.");
                while(name.StartsWith("./"))name=name.Substring(2);
                bool target=name==cookie||name==cookie+"-wal"||name==cookie+"-shm";
                if(target){if(type!='0'&&type!='\0')throw new IOException("Snapshot cookie database is not a regular file.");if(!seen.Add(name))throw new IOException("Duplicate snapshot cookie database entry.");if(sizeOverride.HasValue)throw new IOException("Unsupported cookie database size metadata.");}
                if(stage!=null&&target&&name!=cookie+"-shm"){
                    if(actual>268435456)throw new IOException("Snapshot cookie database exceeds its supported size.");
                    using(var file=new FileStream(Path.Combine(stage,name==cookie?"Cookies":"Cookies-wal"),FileMode.CreateNew))Copy(src,file,actual,stop,buffer);
                    src.Seek(padded-actual,SeekOrigin.Current);
                }else if(dst!=null&&target){
                    if(name==cookie){
                        using(var db=new FileStream(database,FileMode.Open,FileAccess.Read,FileShare.Read)){
                            string oct=Convert.ToString(db.Length,8);if(oct.Length>11)throw new IOException("Cookie database is too large.");Array.Clear(h,124,12);Encoding.ASCII.GetBytes(oct.PadLeft(11,'0')).CopyTo(h,124);
                            for(int i=148;i<156;i++)h[i]=32;sum=0;foreach(byte b in h)sum+=b;Encoding.ASCII.GetBytes(Convert.ToString(sum,8).PadLeft(6,'0')).CopyTo(h,148);h[154]=0;h[155]=32;
                            pending.Position=0;pending.CopyTo(dst);dst.Write(h,0,512);Copy(db,dst,db.Length,stop,buffer);int padding=(int)((512-db.Length%512)%512);dst.Write(new byte[padding],0,padding);
                        }
                    }
                    src.Seek(padded,SeekOrigin.Current);
                }else if(dst!=null){pending.Position=0;pending.CopyTo(dst);dst.Write(h,0,512);Copy(src,dst,padded,stop,buffer);}else src.Seek(padded,SeekOrigin.Current);
                if(name==cookie)found=true;pending.SetLength(0);pending.Position=0;pathOverride=null;sizeOverride=null;
            }
            throw new IOException("Snapshot end marker is missing.");
        }
    }
}
'@
    }finally{[Threading.Monitor]::Exit($gate)}
}

function Read-SavedGameAppCookie {
    param($Paths)
    if(-not [IO.File]::Exists($Paths.Cookie)){return ''}
    Assert-InstanceReplacementDirectory $Paths.Cookie $Paths.Root
    $value=[IO.File]::ReadAllText($Paths.Cookie).Trim()
    if($value.Length -gt 32768 -or $value -cmatch '[\x00-\x20\x7f-\uffff]'){throw 'The saved app-data cookie value is invalid. Its contents were withheld.'}
    return $value
}

function Write-SavedGameAppCookie {
    param($Paths,[string]$Value)
    if(-not $Value -or $Value.Length -gt 32768 -or $Value -cmatch '[\x00-\x20\x7f-\uffff]'){throw 'The app-data cookie value is unavailable or invalid. Its contents were withheld.'}
    $temp=Join-Path $Paths.Directory ('.cookie-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try{
        [IO.File]::WriteAllText($temp,$Value,[Text.UTF8Encoding]::new($false));Protect-GameCookieFile $temp
        if([IO.File]::Exists($Paths.Cookie)){[IO.File]::Replace($temp,$Paths.Cookie,[NullString]::Value)}else{[IO.File]::Move($temp,$Paths.Cookie)}
        Protect-GameCookieFile $Paths.Cookie
        if((Read-SavedGameAppCookie $Paths) -cne $Value){throw 'The local app-data cookie value could not be verified.'}
    }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}

function Read-GameAppCookieValue {
    param([string]$Package=$Config.GamePackage,[string]$Database='')
    if($Package -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$'){throw 'Invalid cookie package.'}
    if(-not $Database){$Database='/data/data/'+$Package+'/app_webview/Default/Cookies'}
    if($Database -notmatch '^/data/(?:data/[A-Za-z0-9_.]+/app_webview/Default/Cookies|local/tmp/launcher-cookie-[a-f0-9]{32}/Cookies)$'){throw 'Invalid cookie database path.'}
    $sql=".bail on`n.timeout 5000`nPRAGMA query_only=ON;`nSELECT 'COOKIE|'||hex(value)||'|'||length(encrypted_value) FROM cookies WHERE name='.ROBLOSECURITY' AND host_key IN ('.roblox.com','roblox.com') AND path='/';"
    try{
        $reply=Invoke-GameCookieAdb -Command ("su -c 'if test -f $Database; then sqlite3 $Database; else echo LAUNCHER_COOKIE_EMPTY; fi'") -InputText $sql
        return (ConvertFrom-GameAppCookieResponse $reply)
    }catch [System.Management.Automation.PipelineStoppedException]{throw}
    catch [OperationCanceledException]{throw}
    catch{throw (New-GameStatusReadError 'The app-data cookie value could not be read safely. Saved data was preserved; diagnostic contents were withheld.')}
}

function ConvertFrom-GameAppCookieResponse {
    param([string]$Reply)
    if($Reply -ceq 'LAUNCHER_COOKIE_EMPTY'){return @{Present=$false;Value=''}}
    $values=@();$present=$false
    foreach($line in ($Reply -split '\r?\n')){
        if(-not $line.Trim()){continue}
        if($line -notmatch '^COOKIE\|((?:[0-9a-fA-F]{2})*)\|(\d+)$'){throw 'Cookie response is unavailable.'}
        $hex=$Matches[1];$encrypted=[int]$Matches[2]
        if($hex.Length -gt 65536){throw 'Cookie value exceeds its supported size.'}
        if($hex -or $encrypted){$present=$true}
        if($hex){$bytes=New-Object byte[] ($hex.Length/2);for($i=0;$i -lt $bytes.Length;$i++){$bytes[$i]=[Convert]::ToByte($hex.Substring($i*2,2),16)};$value=[Text.UTF8Encoding]::new($false,$true).GetString($bytes);if($value -cmatch '[\x00-\x20\x7f-\uffff]'){throw 'Cookie value is unsupported.'};$values+=@($value)}
    }
    $unique=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($value in $values){$null=$unique.Add($value)};$distinct=@($unique)
    if($distinct.Count -gt 1){throw 'Cookie rows are ambiguous.'}
    return @{Present=$present;Value=$(if($distinct.Count){[string]$distinct[0]}else{''})}
}

function Read-GameAppCookieValues {
    param([string[]]$Packages=$Config.GamePackages)
    $results=@{};$requested=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($package in $Packages){
        if($package -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$' -or -not $requested.Add($package)){throw 'Invalid cookie batch package list.'}
        $results[$package]=@{Known=$false;Present=$false;Value=''}
    }
    if(-not $requested.Count){return $results}
    $scriptText=@'
for pkg in __PACKAGES__; do
  printf 'COOKIE_BEGIN|%s\n' "$pkg"
  db="/data/data/$pkg/app_webview/Default/Cookies"
  if test -f "$db"; then
    if sqlite3 "$db" <<'LAUNCHER_COOKIE_SQL'
.bail on
.timeout 5000
PRAGMA query_only=ON;
SELECT 'COOKIE|'||hex(value)||'|'||length(encrypted_value) FROM cookies WHERE name='.ROBLOSECURITY' AND host_key IN ('.roblox.com','roblox.com') AND path='/';
LAUNCHER_COOKIE_SQL
    then echo 'COOKIE_STATUS|OK'; else echo 'COOKIE_STATUS|FAILED'; fi
  else
    echo LAUNCHER_COOKIE_EMPTY
    echo 'COOKIE_STATUS|OK'
  fi
  printf 'COOKIE_END|%s\n' "$pkg"
done
'@.Replace('__PACKAGES__',($Packages -join ' '))
    try{
        
        
        $reply=Invoke-GameCookieAdb -Command 'su -c sh' -InputText $scriptText
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $current='';$status='';$lines=New-Object 'System.Collections.Generic.List[string]'
        foreach($line in ($reply -split '\r?\n')){
            if(-not $line){continue}
            if($line -cmatch '^COOKIE_BEGIN\|(.+)$'){
                $package=$Matches[1]
                if($current -or -not $requested.Contains($package) -or -not $seen.Add($package)){throw 'Invalid cookie batch framing.'}
                $current=$package;$status='';$lines.Clear();continue
            }
            if($line -cmatch '^COOKIE_END\|(.+)$'){
                if(-not $current -or $Matches[1] -cne $current -or -not $status){throw 'Incomplete cookie batch result.'}
                if($status -ceq 'OK'){
                    try{$value=ConvertFrom-GameAppCookieResponse ($lines -join "`n");$value.Known=$true;$results[$current]=$value}
                    catch{$results[$current]=@{Known=$false;Present=$false;Value=''}}
                }
                $current='';continue
            }
            if(-not $current -or $status){throw 'Unexpected cookie batch response.'}
            if($line -cmatch '^COOKIE_STATUS\|(OK|FAILED)$'){$status=$Matches[1];continue}
            $lines.Add($line)
        }
        if($current -or $seen.Count -ne $requested.Count){throw 'The cookie batch response did not finish.'}
        return $results
    }catch [System.Management.Automation.PipelineStoppedException]{throw}
    catch [OperationCanceledException]{throw}
    catch{
        foreach($package in $Packages){$results[$package]=@{Known=$false;Present=$false;Value=''}}
        return $results
    }
}

function Update-StagedGameAppCookieDatabase {
    param([string]$Stage,[string]$Package,[string]$Cookie)
    $remote='/data/local/tmp/launcher-cookie-'+[guid]::NewGuid().ToString('N');$database=$remote+'/Cookies'
    try{
        $null=Invoke-GameAppDataAdb @('shell',"mkdir -m 700 $remote")
        foreach($name in @('Cookies','Cookies-wal')){if([IO.File]::Exists((Join-Path $Stage $name))){$null=Invoke-GameAppDataAdb @('push',(Join-Path $Stage $name),($remote+'/'+$name))}}
        $before=Read-GameAppCookieValue -Package $Package -Database $database
        if($before.Value -ceq $Cookie){return $false}
        $hex=[BitConverter]::ToString([Text.Encoding]::UTF8.GetBytes($Cookie)).Replace('-','')
        $sql=".bail on`n.timeout 5000`nBEGIN IMMEDIATE;`nUPDATE cookies SET value=CAST(X'$hex' AS TEXT),encrypted_value=X'' WHERE name='.ROBLOSECURITY' AND host_key IN ('.roblox.com','roblox.com') AND path='/';`nCOMMIT;`nPRAGMA wal_checkpoint(TRUNCATE);`nPRAGMA journal_mode=DELETE;`nPRAGMA quick_check;"
        $reply=Invoke-GameCookieAdb -Command ("su -c 'sqlite3 $database'") -InputText $sql
        if($reply -notmatch '(?m)^ok\s*$' -or (Read-GameAppCookieValue -Package $Package -Database $database).Value -cne $Cookie){throw 'The staged cookie database update was not verified.'}
        $remoteHash=Invoke-GameAppDataAdb @('shell',"su -c 'sha256sum $database'")
        if($remoteHash -notmatch '^([A-Fa-f0-9]{64})\s'){throw 'The staged cookie database hash is unavailable.'};$expected=$Matches[1]
        $local=Join-Path $Stage 'Cookies.updated';$null=Invoke-GameAppDataAdb @('pull',$database,$local)
        if((Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash -ine $expected){throw 'The updated cookie database transfer failed verification.'}
        return $true
    }finally{try{$null=Invoke-GameAppDataAdb @('shell',"su -c 'rm -rf $remote'")}catch{}}
}

function Initialize-LocalCookieDatabaseNative {
    if('LauncherLocalCookieDatabase' -as [type]){return}
    $gate=[string]::Intern('Launcher.LocalCookieDatabase');[Threading.Monitor]::Enter($gate)
    try{
    if('LauncherLocalCookieDatabase' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class LauncherLocalCookieDatabase {
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Row(IntPtr p,int n,IntPtr values,IntPtr names);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl,EntryPoint="sqlite3_open_v2")] static extern int Open(IntPtr path,out IntPtr db,int flags,IntPtr vfs);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl,EntryPoint="sqlite3_close")] static extern int Close(IntPtr db);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl,EntryPoint="sqlite3_exec")] static extern int Exec(IntPtr db,[MarshalAs(UnmanagedType.LPStr)]string sql,Row row,IntPtr p,out IntPtr error);
    [DllImport("winsqlite3.dll",CallingConvention=CallingConvention.Cdecl,EntryPoint="sqlite3_free")] static extern void Free(IntPtr p);
    static List<string> Query(IntPtr db,string sql) {
        var result=new List<string>();Row callback=delegate(IntPtr p,int n,IntPtr values,IntPtr names){var fields=new string[n];for(int i=0;i<n;i++)fields[i]=Marshal.PtrToStringAnsi(Marshal.ReadIntPtr(values,i*IntPtr.Size))??"";result.Add(String.Join("|",fields));return 0;};
        IntPtr error;int rc=Exec(db,sql,callback,IntPtr.Zero,out error);if(error!=IntPtr.Zero)Free(error);if(rc!=0)throw new IOException("The local snapshot cookie database operation failed.");return result;
    }
    const string Where=" WHERE name='.ROBLOSECURITY' AND host_key IN ('.roblox.com','roblox.com') AND path='/'";
    static bool Matches(IntPtr db,string hex) {
        var rows=Query(db,"SELECT hex(value),length(encrypted_value) FROM cookies"+Where+";");
        if(rows.Count==0)throw new IOException("The snapshot cookie row is missing.");
        foreach(string row in rows)if(row!=hex+"|0")return false;return true;
    }
    public static bool Update(string stage,string cookie) {
        if(String.IsNullOrEmpty(cookie)||cookie.Length>32768)throw new IOException("The captured cookie is invalid.");
        foreach(char c in cookie)if(c<=32||c>=127)throw new IOException("The captured cookie is invalid.");
        string path=Path.Combine(stage,"Cookies");byte[] utf8=Encoding.UTF8.GetBytes(path+"\0");IntPtr memory=Marshal.AllocHGlobal(utf8.Length),db=IntPtr.Zero;
        string hex=BitConverter.ToString(Encoding.UTF8.GetBytes(cookie)).Replace("-","");
        try {
            Marshal.Copy(utf8,0,memory,utf8.Length);if(Open(memory,out db,2,IntPtr.Zero)!=0)throw new IOException("The local snapshot cookie database could not be opened.");
            Query(db,"PRAGMA busy_timeout=5000;");if(Matches(db,hex))return false;
            Query(db,"BEGIN IMMEDIATE;UPDATE cookies SET value=CAST(X'"+hex+"' AS TEXT),encrypted_value=X''"+Where+";COMMIT;");
            var checkpoint=Query(db,"PRAGMA wal_checkpoint(TRUNCATE);");if(checkpoint.Count>0&&!checkpoint[0].StartsWith("0|"))throw new IOException("Snapshot cookie checkpoint did not finish.");
            Query(db,"PRAGMA journal_mode=DELETE;");var check=Query(db,"PRAGMA quick_check;");if(check.Count!=1||check[0]!="ok"||!Matches(db,hex))throw new IOException("The local snapshot cookie update failed verification.");
        } finally {if(db!=IntPtr.Zero)Close(db);Marshal.FreeHGlobal(memory);}
        File.Copy(path,Path.Combine(stage,"Cookies.updated"),false);return true;
    }
}
'@
    }finally{[Threading.Monitor]::Exit($gate)}
}

function Get-PendingGameAppCookiePath {
    param($Paths)
    $path=Join-Path ([IO.Path]::GetDirectoryName($Paths.Directory)) ('.cookie-update-'+[IO.Path]::GetFileName($Paths.Directory)+'.json')
    Assert-InstanceReplacementDirectory $path $Paths.Root
    return $path
}

function Read-PendingGameAppCookieUpdate {
    param($Paths)
    $path=Get-PendingGameAppCookiePath $Paths
    if(-not [IO.File]::Exists($path)){return $null}
    Assert-InstanceReplacementDirectory $path $Paths.Root
    $pending=ConvertFrom-Json ([IO.File]::ReadAllText($path))
    if($pending.Version -ne 1 -or $pending.Package -cne [IO.Path]::GetFileName($Paths.Directory) -or $pending.Token -notmatch '^[a-f0-9]{32}$' -or -not $pending.Cookie -or $pending.Cookie.Length -gt 32768 -or $pending.Cookie -cmatch '[\x00-\x20\x7f-\uffff]'){throw 'The pending cookie update is invalid. Saved data was preserved.'}
    return $pending
}

function Save-PendingGameAppCookieUpdate {
    param($Paths,[string]$Cookie)
    if(-not $Cookie -or $Cookie.Length -gt 32768 -or $Cookie -cmatch '[\x00-\x20\x7f-\uffff]'){throw 'The captured cookie is invalid.'}
    $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Paths.Directory))
    $path=Get-PendingGameAppCookiePath $Paths;$temp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllText($temp,'',[Text.UTF8Encoding]::new($false));Protect-GameCookieFile $temp
        Write-TemplateStageManifest $temp @{Version=1;Package=[IO.Path]::GetFileName($Paths.Directory);Token=[guid]::NewGuid().ToString('N');Cookie=$Cookie}
        Protect-GameCookieFile $temp
        if([IO.File]::Exists($path)){[IO.File]::Replace($temp,$path,[NullString]::Value)}else{[IO.File]::Move($temp,$path)}
        Protect-GameCookieFile $path
        if((Read-PendingGameAppCookieUpdate $Paths).Cookie -cne $Cookie){throw 'The pending cookie could not be verified.'}
    }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}

function Invoke-PendingGameAppCookieUpdates {
    if(-not $Config.CookieStorePath){return $true}
    foreach($package in $Config.GamePackages){
        $paths=Get-GameAppDataPaths -Package $package
        try{
            $pending=Read-PendingGameAppCookieUpdate $paths
            if(-not $pending){continue}
            Assert-PoolSetupTurn;Enter-EmulatorLoadingSlot
            $result=Sync-GameAppSnapshotCookie -Package $package -ReportResult -UseCapturedCookie -CapturedCookie $pending.Cookie
            if($result -notin @('Updated','Matched')){throw 'The saved snapshot is unavailable for the captured cookie update.'}
            
            
            $current=Read-PendingGameAppCookieUpdate $paths
            if($current -and $current.Token -ceq $pending.Token){[IO.File]::Delete((Get-PendingGameAppCookiePath $paths))}
            Write-FlowStatus "Saved $package snapshot cookie and standalone .ROBLOSECURITY updated from the monitor capture. No live ADB read was needed."
        }catch [System.Management.Automation.PipelineStoppedException]{throw}
        catch [OperationCanceledException]{throw}
        catch{
            Write-FlowStatus 'Captured cookie update did not finish. Kept the protected pending value and saved data for another loading slot.'
            return $false
        }
    }
    return $true
}

function Complete-GameAppCookieArchiveCleanup {
    param($Paths,$Entry)
    $retired=@($Entry.CookieRetiredArchives|Where-Object{$_})
    foreach($name in $retired){
        if($name -notmatch '^snapshot-[a-f0-9]{32}[.]tar$' -or $name -ceq $Entry.Archive){throw 'The saved-cookie archive cleanup record is invalid.'}
        $old=Join-Path $Paths.Directory $name;Assert-InstanceReplacementDirectory $old $Paths.Root
        if([IO.File]::Exists($old)){[IO.File]::Delete($old)}
    }
    if($retired.Count){$Entry.PSObject.Properties.Remove('CookieRetiredArchives');Write-TemplateStageManifest $Paths.Manifest $Entry}
}

function Clear-GameAppCookieSyncStage {
    param($Paths)
    $stage=Join-Path $Paths.Directory '.cookie-sync';Assert-InstanceReplacementDirectory $stage $Paths.Root
    if(-not [IO.Directory]::Exists($stage)){return}
    $pending=Join-Path $stage 'pending.json'
    if([IO.File]::Exists($pending)){
        $name=[string](ConvertFrom-Json ([IO.File]::ReadAllText($pending))).Archive
        if($name -notmatch '^snapshot-[a-f0-9]{32}[.]tar$'){throw 'The pending cookie snapshot record is invalid. Saved files were preserved.'}
        $current=Read-GameAppDataManifest $Paths
        if(-not $current){throw 'The pending cookie update has no readable snapshot manifest. Saved files were preserved.'}
        if($name -cne $current.Archive){$orphan=Join-Path $Paths.Directory $name;Assert-InstanceReplacementDirectory $orphan $Paths.Root;if([IO.File]::Exists($orphan)){[IO.File]::Delete($orphan)}}
    }
    foreach($child in @(Get-ChildItem -LiteralPath $stage -Force -Recurse)){Assert-InstanceReplacementDirectory $child.FullName $Paths.Root}
    [IO.Directory]::Delete($stage,$true)
}

function Sync-GameAppSnapshotCookie {
    param([string]$Package,[switch]$ReportResult,[switch]$UseCapturedCookie,[string]$CapturedCookie='')
    $paths=Get-GameAppDataPaths -Package $Package
    
    $local=Read-SavedGameAppCookie $paths
    $live=if($UseCapturedCookie){@{Value=$CapturedCookie}}else{Read-GameAppCookieValue -Package $Package}
    if(-not $live.Value){if($ReportResult){return 'NoLiveCookie'};return}
    $entry=Read-GameAppDataManifest $paths;if(-not $entry){if($ReportResult){return 'NoSnapshot'};return}
    Clear-GameAppCookieSyncStage $paths
    $hash=[Security.Cryptography.SHA256]::Create()
    try{$cookieHash=[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($live.Value))).Replace('-','')}finally{$hash.Dispose()}
    if($local -ceq $live.Value -and $entry.CookieSha256 -ceq $cookieHash){Complete-GameAppCookieArchiveCleanup $paths $entry;if($ReportResult){return 'Matched'};return}
    $archive=Join-Path $paths.Directory $entry.Archive
    if((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $entry.Sha256){throw 'Saved app-data verification failed before cookie synchronization. No saved cookie was changed.'}
    Initialize-GameAppCookieArchiveNative
    $stage=Join-Path $paths.Directory '.cookie-sync';Assert-InstanceReplacementDirectory $stage $paths.Root
    $stop=if($Config.StopFilePath){$Config.StopFilePath}else{$env:LAUNCHER_FLOW_STOP_FILE}
    $candidate=$null
    try{
        $null=[IO.Directory]::CreateDirectory($stage)
        if(-not [LauncherGameCookieTar]::Extract($archive,$Package,$stage,$stop)){throw 'The saved app-data archive has no cookie database. Saved files were kept.'}
        if($UseCapturedCookie){Initialize-LocalCookieDatabaseNative;$changed=[LauncherLocalCookieDatabase]::Update($stage,$live.Value)}
        else{$changed=Update-StagedGameAppCookieDatabase $stage $Package $live.Value}
        if($changed){
            $candidate=Join-Path $stage ('snapshot-'+[guid]::NewGuid().ToString('N')+'.tar')
            [LauncherGameCookieTar]::Rewrite($archive,$candidate,$Package,(Join-Path $stage 'Cookies.updated'),$stop)
            $verify=Join-Path $stage 'verify';$null=[IO.Directory]::CreateDirectory($verify)
            if(-not [LauncherGameCookieTar]::Extract($candidate,$Package,$verify,$stop) -or (Get-FileHash -LiteralPath (Join-Path $verify 'Cookies')).Hash -cne (Get-FileHash -LiteralPath (Join-Path $stage 'Cookies.updated')).Hash -or [IO.File]::Exists((Join-Path $verify 'Cookies-wal'))){throw 'The updated archive cookie database failed verification.'}
            $newName=[IO.Path]::GetFileName($candidate);$newArchive=Join-Path $paths.Directory $newName
            $retired=@(@($entry.CookieRetiredArchives|Where-Object{$_})+@($entry.Archive)|Select-Object -Unique)
            $entry.Archive=$newName;$entry.Length=([IO.FileInfo]$candidate).Length;$entry.Sha256=(Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
            $entry|Add-Member NoteProperty CookieRetiredArchives $retired -Force
            Write-TemplateStageManifest (Join-Path $stage 'pending.json') @{Archive=$newName}
            Protect-GameCookieFile $candidate;[IO.File]::Move($candidate,$newArchive);$candidate=$null
        }
        $entry|Add-Member NoteProperty CookieSha256 $cookieHash -Force
        
        
        Write-TemplateStageManifest $paths.Manifest $entry
        $published=Read-GameAppDataManifest $paths
        if($published.Sha256 -cne $entry.Sha256 -or $published.CookieSha256 -cne $cookieHash){throw 'The updated snapshot manifest could not be verified.'}
        Write-SavedGameAppCookie $paths $live.Value
        Complete-GameAppCookieArchiveCleanup $paths $published
        Write-FlowStatus "Verified saved $Package archive cookie and updated its local .ROBLOSECURITY value. Cookie contents are not logged."
        if($ReportResult){return 'Updated'}
    }finally{Clear-GameAppCookieSyncStage $paths}
}

function Invoke-RegularGameAppCookieTurn {
    param([ref]$Batch)
    if(-not $Config.CookieStorePath -or $script:PoolRole -ne 'Monitor'){return 'Continue'}
    try{
        $paths=Get-GameAppDataPaths -Package $Config.GamePackage
        $pending=Read-PendingGameAppCookieUpdate $paths
        if(-not $pending){
            
            
            $local=Read-SavedGameAppCookie $paths
            if($null -eq $Batch.Value){$Batch.Value=Read-GameAppCookieValues -Packages $Config.GamePackages}
            $live=$Batch.Value[$Config.GamePackage]
            if(-not $live.Known){Write-FlowStatus 'Regular cookie comparison is unavailable for this app. Saved data was kept; checking again next monitor turn.';return 'Continue'}
            if(-not $live.Value -or $live.Value -ceq $local){return 'Continue'}
            Save-PendingGameAppCookieUpdate $paths $live.Value
            Write-FlowStatus 'Live cookie differs from the standalone saved cookie. Saved a protected pending cookie; snapshot and standalone updates are queued for a setup loading slot.'
        }
    }catch [System.Management.Automation.PipelineStoppedException]{throw}
    catch [OperationCanceledException]{throw}
    catch{
        Write-FlowStatus 'Regular cookie comparison/capture is unavailable. Saved data and the running app were left unchanged; checking again next monitor turn.'
        return 'Continue'
    }
    Assert-PoolSetupTurn
}

function Save-GameAppDataSnapshot {
    param([string]$Package)
    $paths=Get-GameAppDataPaths -Package $Package;$previous=Read-GameAppDataManifest $paths
    if($previous){Write-FlowStatus "Saved $Package game data already exists. Keeping it without stopping the app.";return $true}
    $token=[guid]::NewGuid().ToString('N');$name="snapshot-$token.tar"
    $stage=Join-Path ([IO.Path]::GetDirectoryName($paths.Directory)) ('.capture-'+$token)
    Assert-InstanceReplacementDirectory $stage $paths.Root
    $local=Join-Path $stage $name
    $remote="/data/local/tmp/launcher-data-$token.tar"
    $scriptText=@'
set -eu
pkg='__PACKAGE__'
archive='__REMOTE__'
if test ! -d "/data/data/$pkg"; then echo LAUNCHER_DATA_EMPTY; exit 0; fi
am force-stop "$pkg"
attempt=0
while pidof "$pkg" >/dev/null 2>&1; do
  attempt=$((attempt+1)); test "$attempt" -lt 10 || exit 66
  sleep 0.5
done
set -- "data/data/$pkg"
for area in data obb media; do
  test ! -d "/sdcard/Android/$area/$pkg" || set -- "$@" "sdcard/Android/$area/$pkg"
done
tar --exclude="data/data/$pkg/lib" -cpf "$archive" -C / "$@"
chown 2000:2000 "$archive"
chmod 600 "$archive"
echo LAUNCHER_DATA_SAVED
'@.Replace('__PACKAGE__',$Package).Replace('__REMOTE__',$remote)
    try{
        $null=[IO.Directory]::CreateDirectory($stage)
        Write-FlowStatus "Saving $Package game data. The app is stopped briefly for a consistent snapshot..."
        $result=Invoke-GameAppDataAdb @('shell','su -c sh') $scriptText
        Clear-ProcessCheckCache
        if($result -match '(?m)^LAUNCHER_DATA_EMPTY\s*$'){Write-FlowStatus "No existing $Package game data yet. The app will open normally.";return $false}
        if($result -notmatch '(?m)^LAUNCHER_DATA_SAVED\s*$'){throw 'Android did not confirm the game-data snapshot.'}
        $null=Invoke-GameAppDataAdb @('pull',$remote,$local)
        if(-not [IO.File]::Exists($local) -or ([IO.FileInfo]$local).Length -lt 1024){throw 'The game-data snapshot is incomplete.'}
        Protect-GameCookieFile -Path $local
        $manifest=@{Version=1;Package=$Package;Archive=$name;Length=([IO.FileInfo]$local).Length;Sha256=(Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash;SavedUtc=[datetime]::UtcNow.ToString('o');RestoreRequired=$false}
        Write-TemplateStageManifest (Join-Path $stage 'manifest.json') $manifest
        try{
            
            
            if([IO.Directory]::Exists($paths.Directory) -and [IO.Directory]::GetFileSystemEntries($paths.Directory).Length -eq 0){
                Assert-InstanceReplacementDirectory $paths.Directory $paths.Root
                [IO.Directory]::Delete($paths.Directory,$false)
            }
            [IO.Directory]::Move($stage,$paths.Directory)
        }catch [IO.IOException]{
            if(-not (Read-GameAppDataManifest $paths)){throw}
            Write-FlowStatus "Saved $Package game data appeared during capture. Keeping the existing snapshot."
            return $true
        }
        Write-FlowStatus "Saved $Package game data for LDPlayer $InstanceIndex. Archive and manifest verified and published together."
        return $true
    }finally{
        if([IO.Directory]::Exists($stage)){
            Assert-InstanceReplacementDirectory $stage $paths.Root
            foreach($child in @(Get-ChildItem -LiteralPath $stage -Force -Recurse)){Assert-InstanceReplacementDirectory $child.FullName $paths.Root}
            [IO.Directory]::Delete($stage,$true)
        }
        try{$null=Invoke-GameAppDataAdb @('shell',"su -c 'rm -f $remote'")}catch{}
    }
}

function Restore-GameAppDataSnapshot {
    param([string]$Package,[switch]$ForMissingCookie)
    $paths=Get-GameAppDataPaths -Package $Package;$entry=Read-GameAppDataManifest $paths
    if(-not $entry -or (-not $entry.RestoreRequired -and -not $ForMissingCookie)){return $false}
    $archive=Join-Path $paths.Directory $entry.Archive
    if((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $entry.Sha256){throw 'The saved game-data archive failed verification. The app remains closed.'}
    $remote='/data/local/tmp/launcher-data-'+[guid]::NewGuid().ToString('N')+'.tar'
    $scriptText=@'
set -eu
pkg='__PACKAGE__'
archive='__REMOTE__'
uid=$(dumpsys package "$pkg" | sed -n 's/^[[:space:]]*userId=\([0-9]*\).*$/\1/p' | head -n 1)
case "$uid" in ''|*[!0-9]*) exit 62;; esac
tar -tf "$archive" > "$archive.list"
while IFS= read -r item; do
  case "$item" in /*|*../*|../*|*/..|..) exit 63;; esac
  case "$item" in "data/data/$pkg"|"data/data/$pkg/"*|"sdcard/Android/data/$pkg"|"sdcard/Android/data/$pkg/"*|"sdcard/Android/obb/$pkg"|"sdcard/Android/obb/$pkg/"*|"sdcard/Android/media/$pkg"|"sdcard/Android/media/$pkg/"*) ;; *) exit 64;; esac
done < "$archive.list"
grep -q "^data/data/$pkg/" "$archive.list" || exit 65
am force-stop "$pkg"
pm clear "$pkg" | grep -q Success
for area in data obb media; do rm -rf "/sdcard/Android/$area/$pkg"; done
tar -xof "$archive" -C /
chown -R "$uid:$uid" "/data/data/$pkg"
chmod 700 "/data/data/$pkg"
restorecon -RF "/data/data/$pkg"
rm -f "$archive.list"
echo LAUNCHER_DATA_RESTORED
'@.Replace('__PACKAGE__',$Package).Replace('__REMOTE__',$remote)
    try{
        Write-FlowStatus "Restoring saved $Package game data before opening the app..."
        $null=Invoke-GameAppDataAdb @('push',$archive,$remote)
        $result=Invoke-GameAppDataAdb @('shell','su -c sh') $scriptText
        if($result -notmatch '(?m)^LAUNCHER_DATA_RESTORED\s*$'){throw 'Android did not confirm game-data restoration. The app remains closed for retry.'}
        Clear-ProcessCheckCache
        $entry.RestoreRequired=$false;Write-TemplateStageManifest $paths.Manifest $entry
        Write-FlowStatus "Restored $Package game data."
        return $true
    }finally{try{$null=Invoke-GameAppDataAdb @('shell',"su -c 'rm -f $remote $remote.list'")}catch{}}
}

function Get-GameAppDataTransferInventory {
    param($Settings,[int]$Id,[object[]]$VerifiedSnapshots=@())
    foreach($package in $Settings.GamePackages){
        $paths=Get-GameAppDataPaths -Id $Id -Package $package -Settings $Settings
        $entry=Read-GameAppDataManifest $paths
        if(-not $entry){
            if([IO.Directory]::Exists($paths.Directory)){throw "Saved game data for LDPlayer $Id, $package is incomplete: its folder has no manifest/snapshot. The old emulator files were kept."}
            continue
        }
        $archive=Join-Path $paths.Directory $entry.Archive;$stamp=(Get-Item -LiteralPath $archive).LastWriteTimeUtc.Ticks
        $verified=@($VerifiedSnapshots|Where-Object{$_.Package -ceq $package -and $_.Archive -ceq $entry.Archive -and $_.Length -eq $entry.Length -and $_.Sha256 -ceq $entry.Sha256 -and $_.WriteTicks -eq $stamp}).Count -eq 1
        if(-not $verified -and (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -cne $entry.Sha256){throw "Saved game data for LDPlayer $Id, $package failed verification. The old emulator files were kept."}
        @{Package=$package;Archive=$entry.Archive;Length=$entry.Length;Sha256=$entry.Sha256;WriteTicks=$stamp}
    }
}

function Move-GameAppDataIdentity {
    param($Settings,$Journal)
    $root=Get-GameAppDataRoot $Settings;$old=Join-Path $root "$($Journal.OldId)";$new=Join-Path $root "$($Journal.NewId)"
    foreach($path in @($old,$new)){Assert-InstanceReplacementDirectory $path $root}
    $marker=Join-Path $new 'handoff.json'
    $receipt=$null
    if([IO.Directory]::Exists($new)){
        if(-not [IO.File]::Exists($marker) -or (ConvertFrom-Json ([IO.File]::ReadAllText($marker))).Token -cne $Journal.Token){throw 'Another saved app-data identity owns this replacement ID.'}
        $receipt=ConvertFrom-Json ([IO.File]::ReadAllText($marker))
    }elseif([IO.Directory]::Exists($old)){
        $snapshots=@(Get-GameAppDataTransferInventory $Settings $Journal.OldId)
        $receipt=@{Token=$Journal.Token;OldId=$Journal.OldId;NewId=$Journal.NewId;Snapshots=$snapshots}
        Write-TemplateStageManifest (Join-Path $old 'handoff.json') $receipt
        [IO.Directory]::Move($old,$new)
    }else{Write-FlowStatus "No saved app-data folder exists for LDPlayer $($Journal.OldId). No saved account data was transferred to $($Journal.NewId).";return}
    $received=@(Get-GameAppDataTransferInventory $Settings $Journal.NewId -VerifiedSnapshots @($receipt.Snapshots))
    foreach($expected in @($receipt.Snapshots)){
        if(-not $expected){continue}
        if(@($received|Where-Object{$_.Package -ceq $expected.Package -and $_.Archive -ceq $expected.Archive -and $_.Length -eq $expected.Length -and $_.Sha256 -ceq $expected.Sha256}).Count -ne 1){throw 'A saved app-data archive disappeared during ID transfer. The old emulator files were kept.'}
    }
    foreach($snapshot in $received){
        $paths=Get-GameAppDataPaths -Id $Journal.NewId -Package $snapshot.Package -Settings $Settings;$entry=Read-GameAppDataManifest $paths
        $entry.RestoreRequired=$true;Write-TemplateStageManifest $paths.Manifest $entry
    }
    if($receipt -is [Collections.IDictionary]){$receipt.Snapshots=$received}else{$receipt|Add-Member NoteProperty Snapshots $received -Force}
    Write-TemplateStageManifest $marker $receipt
    Write-FlowStatus "Renamed app-data $($Journal.OldId) -> $($Journal.NewId). Verified $($received.Count) saved app snapshot(s); restoration is pending before opening apps."
}

function Test-GameAppCookiePresent {
    param([string]$Package=$Config.GamePackage)
    if($Package -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$'){throw 'Invalid game-data package.'}
    if(-not $script:CookieAdbSerial){
        $serial=(Invoke-Ld -Arguments @('adb','--index',"$InstanceIndex",'--command','get-serialno')).Trim()
        if($serial -notmatch '^(emulator-\d+|(?:127\.0\.0\.1|localhost):\d+)$'){throw (New-GameStatusReadError 'Cookie presence is unavailable; no empty cookie was assumed.')}
        $script:CookieAdbSerial=$serial
    }
    $database='/data/data/'+$Package+'/app_webview/Default/Cookies'
    $command="su -c 'if test -f $database; then sqlite3 $database; else echo LAUNCHER_COOKIE_EMPTY; fi'"
    $schema=".bail on`n.timeout 5000`nPRAGMA query_only=ON;`nSELECT CASE WHEN EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='cookies') THEN 'LAUNCHER_COOKIE_TABLE' ELSE 'LAUNCHER_COOKIE_EMPTY' END;"
    try{
        $reply=Invoke-GameCookieAdb -Command $command -InputText $schema
        if($reply -ceq 'LAUNCHER_COOKIE_EMPTY'){return $false}
        if($reply -cne 'LAUNCHER_COOKIE_TABLE'){throw 'Cookie schema presence could not be confirmed.'}
        $sql=".bail on`n.timeout 5000`nPRAGMA query_only=ON;`nSELECT CASE WHEN EXISTS(SELECT 1 FROM cookies WHERE name='.ROBLOSECURITY' AND host_key IN ('.roblox.com','roblox.com') AND (length(value)>0 OR length(encrypted_value)>0)) THEN 'LAUNCHER_COOKIE_PRESENT' ELSE 'LAUNCHER_COOKIE_EMPTY' END;"
        $reply=Invoke-GameCookieAdb -Command $command -InputText $sql
        if($reply -ceq 'LAUNCHER_COOKIE_PRESENT'){return $true}
        if($reply -ceq 'LAUNCHER_COOKIE_EMPTY'){return $false}
        throw 'Cookie presence could not be confirmed.'
    }catch [System.Management.Automation.PipelineStoppedException]{throw}
    catch [OperationCanceledException]{throw}
    catch{throw (New-GameStatusReadError 'Could not read cookie presence inside Android. No cookie value was exposed and no empty cookie was assumed.')}
}

function Save-LoadedEmulatorAppData {
    param([int]$BootIdentity,[switch]$Force)
    if($null -eq $script:LoadedAppDataCaptures){$script:LoadedAppDataCaptures=@{}}
    if($null -eq $script:WaitingAppDataCookies){$script:WaitingAppDataCookies=@{}}
    try{
        if($script:CookieAdbBoot -ne $BootIdentity){$script:CookieAdbSerial=$null;$script:CookieAdbBoot=$BootIdentity}
        Reset-CopiedTemplateAccounts -BootIdentity $BootIdentity
        foreach($package in $Config.GamePackages){
            $key="$InstanceIndex|$BootIdentity|$package"
            if($script:LoadedAppDataCaptures[$key]){continue}
            $null=Read-SavedGameAppCookie (Get-GameAppDataPaths -Package $package)
            $present=Test-GameAppCookiePresent -Package $package
            $saved=Read-GameAppDataManifest (Get-GameAppDataPaths -Package $package)
            if(-not $present -and $saved){
                $null=Restore-GameAppDataSnapshot -Package $package -ForMissingCookie
                $present=Test-GameAppCookiePresent -Package $package
                if(-not $present){Write-FlowStatus "Restored $package data has no cookie yet. Keeping the saved snapshot and waiting for a login."}
            }elseif($present -and -not $saved){
                $captured=Save-GameAppDataSnapshot -Package $package
                if(-not $captured){throw 'The cookie was present but app data disappeared before it could be saved.'}
                if(-not (Read-GameAppDataManifest (Get-GameAppDataPaths -Package $package))){throw 'Cookie appeared but the game-data snapshot did not finish.'}
            }
            if(-not $present){
                if(-not $saved){Write-FlowStatus "No usable saved $package snapshot exists at app-data\$InstanceIndex\$package. An empty folder cannot restore an account."}
                $script:WaitingAppDataCookies[$key]=@{NextCheckAt=[datetime]::UtcNow.AddSeconds([math]::Max(1,$Config.GameCheckInterval));CaptureRequested=$false}
                Write-FlowStatus "$package has no cookie. Opening the app for login; cookie presence will be checked during regular game checks."
            }else{Sync-GameAppSnapshotCookie -Package $package;$script:WaitingAppDataCookies.Remove($key)}
            $script:LoadedAppDataCaptures[$key]=$true
        }
        return $true
    }catch [System.Management.Automation.PipelineStoppedException]{throw}
    catch [OperationCanceledException]{throw}
    catch{Write-FlowStatus ('Initial cookie-presence/game-data check will retry before opening apps. '+$_.Exception.Message);return $false}
}

function Invoke-WaitingGameAppDataTurn {
    $key="$InstanceIndex|$script:CookieBootIdentity|$($Config.GamePackage)"
    if(-not $script:WaitingAppDataCookies -or -not $script:WaitingAppDataCookies.ContainsKey($key)){return 'Continue'}
    $waiting=$script:WaitingAppDataCookies[$key]
    if($waiting.CaptureRequested -or [datetime]::UtcNow -ge $waiting.NextCheckAt){
        $waiting.NextCheckAt=[datetime]::UtcNow.AddSeconds([math]::Max(1,$Config.GameCheckInterval))
        $waiting.CaptureRequested=Test-GameAppCookiePresent
    }
    if($waiting.CaptureRequested){
        
        
        Assert-PoolSetupTurn
        Enter-EmulatorLoadingSlot
        $saved=Read-GameAppDataManifest (Get-GameAppDataPaths)
        $captured=if($saved){$true}else{Save-GameAppDataSnapshot -Package $Config.GamePackage}
        if(-not $captured){throw (New-GameStatusReadError 'The logged-in app data disappeared before it could be saved. Its saved snapshot is unchanged.')}
        if(-not (Read-GameAppDataManifest (Get-GameAppDataPaths))){throw (New-GameStatusReadError 'The newly logged-in app could not be saved. Keeping it in the capture queue.')}
        try{Sync-GameAppSnapshotCookie -Package $Config.GamePackage}
        catch [System.Management.Automation.PipelineStoppedException]{throw}
        catch [OperationCanceledException]{throw}
        catch{throw (New-GameStatusReadError 'Saved app-data cookie synchronization did not finish. It remains queued; cookie contents were withheld.')}
        $script:WaitingAppDataCookies.Remove($key)
        Write-FlowStatus 'Cookie appeared and saved game data is ready. Continuing the normal app opening and joining flow.'
        return 'Captured'
    }
    if($script:PoolRole -eq 'Monitor'){
        if(-not (Test-AppRunning -Package $Config.GamePackage)){Assert-PoolSetupTurn}
        Assert-MonitoredAppVisible
        if(@(Get-VisibleAppCrashPackages) -ccontains $Config.GamePackage){throw (New-AppCrashError $Config.GamePackage)}
    }else{
        Enter-EmulatorLoadingSlot
        if(-not (Test-AppRunning -Package $Config.GamePackage)){
            Write-FlowStatus 'Opening this app for login while waiting for a cookie. No game link will be sent yet.'
            $null=Invoke-Ld -Arguments @('runapp','--index',"$InstanceIndex",'--packagename',$Config.GamePackage)
            $deadline=[datetime]::UtcNow.AddSeconds($Config.LauncherOpenTimeout)
            do{
                if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Stopped while opening the login app.')}
                if(Test-AppRunning -Package $Config.GamePackage){break}
                Wait-FlowPause ([math]::Max(1,$Config.PollInterval))
            }while([datetime]::UtcNow -lt $deadline)
            if(-not (Test-AppRunning -Package $Config.GamePackage)){throw [TimeoutException]::new('The login app did not open within its configured timeout.')}
        }
    }
    return 'Waiting'
}


function Get-SetupGameAppData {
    
    $key="$InstanceIndex|$script:CookieBootIdentity|$($Config.GamePackage)"
    $ready=[bool]($script:LoadedAppDataCaptures -and $script:LoadedAppDataCaptures[$key])
    return [pscustomobject]@{Ready=$ready;Changed=$false;NeedsLogin=$false;Unavailable=(-not $ready);Mismatch=$false;ProfilePending=$false;Cookie='';Message='Game-data snapshot';AuthenticationChecked=$true;AppCookiePresent=$false;LocalCookiePresent=$false}
}

function Prepare-GameAppDataForOpening {
    param([string]$Package)
    if($Config.GamePackages -notcontains $Package){return}
    $key="$InstanceIndex|$script:CookieBootIdentity|$Package"
    if(-not ($script:LoadedAppDataCaptures -and $script:LoadedAppDataCaptures[$key])){throw (New-GameStatusReadError 'Initial game-data save/restore must finish before opening the app.')}
}

function Reset-CopiedTemplateAccounts {
    param([int]$BootIdentity)
    if(-not $Config.RestoreStateDirectory){return}
    $path=Get-TemplateAccountResetPath
    if(-not [IO.File]::Exists($path)){return}
    $pending=ConvertFrom-Json ([IO.File]::ReadAllText($path))
    if($pending.TargetIndex -ne $InstanceIndex -or $pending.SourceIndex -eq $InstanceIndex){throw 'Template data cleanup marker does not match this emulator.'}
    foreach($package in @($pending.Packages)){
        if(@($pending.Cleared) -contains $package){continue}
        if($Config.GamePackages -notcontains $package){throw 'Template data cleanup contains an unexpected app package.'}
        $reply=Invoke-GameAppDataAdb @('shell',"pm clear $package")
        if($reply -notmatch '(?m)^Success\s*$'){throw 'Copied template app data could not be cleared.'}
        $pending.Cleared=@($pending.Cleared)+@($package);Write-TemplateStageManifest $path $pending
    }
    [IO.File]::Delete($path)
    Write-FlowStatus 'Template app data cleared. Restoring saved game data before opening apps.'
}


function Invoke-GameCookieAdb {
    param([string]$Command,[string]$InputText='')
    
    $timeout=[math]::Max(1,$Config.CommandTimeout)
    $watch=[Diagnostics.Stopwatch]::StartNew()
    Wait-StatusCheckSlot -TimeoutSeconds $timeout
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=Join-Path $Config.LdPlayerInstallPath 'adb.exe'
    $info.Arguments=(@('-s',$script:CookieAdbSerial,'shell',$Command) | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardInput=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process; $process.StartInfo=$info
    try {
        $null=$process.Start()
        $output=$process.StandardOutput.ReadToEndAsync(); $errors=$process.StandardError.ReadToEndAsync()
        $write=$process.StandardInput.WriteLineAsync($InputText)
        $budget=[int][math]::Max(1,$timeout*1000-$watch.ElapsedMilliseconds)
        if (-not $write.Wait($budget)) { try {$process.Kill()}catch{}; throw 'Cookie command input timed out.' }
        $process.StandardInput.Close()
        $budget=[int][math]::Max(1,$timeout*1000-$watch.ElapsedMilliseconds)
        if (-not $process.WaitForExit($budget)) { try {$process.Kill()}catch{}; throw 'Cookie command timed out.' }
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($output,$errors),1000)) { throw 'Cookie command result timed out.' }
        if($process.ExitCode -ne 0){throw 'Cookie command unavailable.'}
        return $output.Result.Trim()
    } catch [System.Management.Automation.PipelineStoppedException] { throw }
    catch [OperationCanceledException] { throw }
    catch {
        $failure=[InvalidOperationException]::new('The emulator cookie operation could not finish. Retrying; diagnostic contents were withheld.')
        $kind=switch -Exact ($_.Exception.Message){'Cookie command input timed out.'{'InputTimeout'}'Cookie command timed out.'{'ProcessTimeout'}'Cookie command result timed out.'{'ResultTimeout'}default{'CommandUnavailable'}}
        $failure.Data['CookieOperationKind']=$kind
        
        
        if($Command -match '^curl\s' -and $errors -and $errors.IsCompleted -and -not $errors.IsFaulted){
            $match=[regex]::Match([string]$errors.Result,'(?m)^curl:\s*\((\d{1,3})\)')
            if($match.Success){$failure.Data['CurlExitCode']=$match.Groups[1].Value}
        }
        throw $failure
    }
    finally { $process.Dispose(); $script:LastStatusCheckFinishedTicks=[Diagnostics.Stopwatch]::GetTimestamp() }
}

function ConvertTo-GameAccountProfile {
    param($Value)
    $id=0L
    if($Value){$null=[long]::TryParse([string]$Value.id,[ref]$id)}
    if($id -lt 0){$id=0L}
    $name='';$display=''
    if($Value){$name=[string]$Value.name;$display=[string]$Value.displayName}
    if($name.Length -gt 100 -or $display.Length -gt 200 -or $name -match '[\x00-\x1f]' -or $display -match '[\x00-\x1f]'){throw 'Account profile fields are invalid; values were withheld.'}
    return @{id=$(if($id -gt 0){$id}else{$null});name=$name;displayName=$display}
}

function Test-GameAccountProfileComplete {
    param($Profile)
    return [bool]($Profile -and [long]$Profile.id -gt 0 -and $Profile.name -and $Profile.displayName)
}

function ConvertFrom-GamePrefsXml {
    param([string]$Text)
    if(-not $Text.Trim()){$Text='<?xml version="1.0" encoding="utf-8"?><map />'}
    $settings=[Xml.XmlReaderSettings]::new();$settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$settings.XmlResolver=$null
    $input=[IO.StringReader]::new($Text);$reader=[Xml.XmlReader]::Create($input,$settings)
    try{$document=[Xml.XmlDocument]::new();$document.XmlResolver=$null;$document.Load($reader)}finally{$reader.Dispose();$input.Dispose()}
    if($document.DocumentElement.Name -ne 'map'){throw 'The app preferences have an unsupported format; no account was changed.'}
    return ,$document
}

function Get-GameAccountPrefsSnapshot {
    param([string]$Package=$Config.GamePackage)
    if($Package -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$'){throw 'Invalid account package.'}
    $file='/data/data/'+$Package+'/shared_prefs/prefs.xml'
    $raw=Invoke-GameCookieAdb -Command ("su -c 'if test -f $file; then cat $file; else echo LAUNCHER_PREFS_MISSING; fi'")
    $exists=$raw -ne 'LAUNCHER_PREFS_MISSING'
    try{
        $xml=if($exists){$raw}else{''};$document=ConvertFrom-GamePrefsXml $xml
        $data=@{id=$null;name='';displayName=''}
        foreach($pair in @(@('userid_long','id'),@('username','name'),@('displayName','displayName'))){
            $node=$document.SelectSingleNode('/map/*[@name="'+$pair[0]+'"]')
            if($node){$value=if($node.HasAttribute('value')){$node.GetAttribute('value')}else{$node.InnerText};$data[$pair[1]]=$value}
        }
        return [pscustomobject]@{Exists=$exists;Xml=$xml;Profile=(ConvertTo-GameAccountProfile $data)}
    }catch{throw 'The app preferences could not be read safely. Profile values were withheld; no account was changed.'}
    finally{$raw=$null;$xml=$null;$document=$null}
}

function Set-GameAccountPrefsSnapshot {
    param([string]$Package,$Snapshot,$Profile,[switch]$Restore,[switch]$Clear)
    $file='/data/data/'+$Package+'/shared_prefs/prefs.xml'
    if($Package -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$'){throw 'Invalid account package.'}
    $xml=$Snapshot.Xml
    if($Clear){
        $document=ConvertFrom-GamePrefsXml $Snapshot.Xml
        foreach($key in @('userid_long','username','displayName')){foreach($old in @($document.SelectNodes('/map/*[@name="'+$key+'"]'))){$null=$old.ParentNode.RemoveChild($old)}}
        $xml=$document.OuterXml
    }elseif(-not $Restore){
        $profileData=ConvertTo-GameAccountProfile $Profile
        if(-not (Test-GameAccountProfileComplete $profileData)){throw 'A complete account ID, username and display name are required before initializing app preferences.'}
        $document=ConvertFrom-GamePrefsXml $Snapshot.Xml
        foreach($pair in @(@('userid_long','id'),@('username','name'),@('displayName','displayName'))){
            foreach($old in @($document.SelectNodes('/map/*[@name="'+$pair[0]+'"]'))){$null=$old.ParentNode.RemoveChild($old)}
            $kind=if($pair[1] -eq 'id'){'long'}else{'string'}
            $node=$document.CreateElement($kind);$node.SetAttribute('name',$pair[0])
            if($kind -eq 'long'){$node.SetAttribute('value',[string]$profileData.id)}else{$node.InnerText=[string]$profileData[$pair[1]]}
            $null=$document.DocumentElement.AppendChild($node)
        }
        $xml=$document.OuterXml
    }
    $token=[guid]::NewGuid().ToString('N')
    if($Restore -and -not $Snapshot.Exists){
        $scriptText="set -e`nrm -f '$file'`necho LAUNCHER_PREFS_OK"
    }else{
        $encoded=[Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($xml))
        $dir='/data/data/'+$Package+'/shared_prefs';$temp=$file+'.launcher-'+$token
        $scriptText=@"
set -e
mkdir -p '$dir'
owner=`$(stat -c %u /data/data/$Package)
group=`$(stat -c %g /data/data/$Package)
if test -f '$file'; then cp -p '$file' '$temp'; else touch '$temp'; chown "`$owner:`$group" '$temp'; chmod 660 '$temp'; fi
trap 'rm -f "$temp"' EXIT
printf '%s' '$encoded' | base64 -d > '$temp'
mv -f '$temp' '$file'
chown "`$owner:`$group" '$dir'
echo LAUNCHER_PREFS_OK
"@
    }
    $reply=Invoke-GameCookieAdb -Command 'su -c sh' -InputText $scriptText
    if($reply -ne 'LAUNCHER_PREFS_OK'){throw 'App profile update could not be confirmed.'}
}

function Set-GameAccountPair {
    param([string]$Package,[string]$Cookie,$CookieSnapshot,$PrefsSnapshot,$Profile)
    if(-not (Test-GameAccountProfileComplete $Profile)){throw 'Account profile is incomplete. The app cookie was not assigned.'}
    if(Test-AppRunning -Package $Package){throw 'The app must be closed before updating its account files.'}
    
    
    $profileWritten=$false
    try{
        $profileWritten=$true
        Set-GameAccountPrefsSnapshot -Package $Package -Snapshot $PrefsSnapshot -Profile $Profile
        $check=Get-GameAccountPrefsSnapshot -Package $Package
        if(-not (Test-GameAccountProfilesEqual $check.Profile $Profile)){throw 'Profile read-back did not match the selected account.'}
        Set-GameCookieDatabase -Package $Package -Cookie $Cookie -Snapshot $CookieSnapshot
        $verified=Get-GameCookieSnapshot -Package $Package
        if($verified.Value -cne $Cookie -or $verified.Encrypted){throw 'Cookie read-back did not match the selected account.'}
        $check=Get-GameAccountPrefsSnapshot -Package $Package
        if(-not (Test-GameAccountProfilesEqual $check.Profile $Profile)){throw 'Account profile changed during the cookie update.'}
    }catch{
        $failure=$_
        if($profileWritten){
            try{
                Restore-GameCookieSnapshot -Package $Package -Snapshot $CookieSnapshot
                Set-GameAccountPrefsSnapshot -Package $Package -Snapshot $PrefsSnapshot -Restore
            }catch{throw 'Account update and rollback could not both be confirmed. The app remains closed; recovery will retry before opening.'}
        }
        throw 'Account files could not be updated together. Previous data was restored where possible; the app remains closed for retry.'
    }
}

function Test-GameAccountProfilesEqual {
    param($Left,$Right)
    return [bool]((Test-GameAccountProfileComplete $Left) -and (Test-GameAccountProfileComplete $Right) -and [long]$Left.id -eq [long]$Right.id -and [string]$Left.name -ceq [string]$Right.name -and [string]$Left.displayName -ceq [string]$Right.displayName)
}




function Get-GameCookieSnapshot {
    param([string]$Package)
    $database='/data/data/'+$Package+'/app_webview/Default/Cookies'
    $command="su -c 'if test -f $database; then sqlite3 $database; else echo LAUNCHER_COOKIE_DB_MISSING; fi'"
    $sql=".bail on`n.timeout 5000`nPRAGMA query_only=ON;`nPRAGMA table_info(cookies);`nSELECT 'COOKIE|'||hex(value)||'|'||length(encrypted_value)||'|'||expires_utc||'|'||hex(encrypted_value) FROM cookies WHERE name='.ROBLOSECURITY' AND host_key='.roblox.com' AND path='/';"
    $raw=Invoke-GameCookieAdb -Command $command -InputText $sql
    if ($raw -eq 'LAUNCHER_COOKIE_DB_MISSING') { return [pscustomobject]@{Exists=$false;Columns=@();Count=0;Value='';Encrypted=$false;Expires=0} }
    $columns=@(); $rows=@()
    foreach ($line in ($raw -split '\r?\n')) {
        if ($line -match '^\d+\|([A-Za-z_]+)\|([^|]*)\|([01])\|([^|]*)\|\d+$') {
            $columns+=[pscustomobject]@{Name=$Matches[1];Type=$Matches[2];Required=($Matches[3] -eq '1');Default=$Matches[4]}
        } elseif ($line -match '^COOKIE\|([0-9A-Fa-f]*)\|(\d+)\|(\d+)(?:\|([0-9A-Fa-f]*))?$') {
            $hex=$Matches[1]; $encrypted=[int]$Matches[2]; $expiry=[long]$Matches[3]
            $encryptedHex=$Matches[4]
            $bytes=New-Object byte[] ($hex.Length/2)
            for ($i=0;$i -lt $bytes.Length;$i++) { $bytes[$i]=[Convert]::ToByte($hex.Substring($i*2,2),16) }
            $rows+=[pscustomobject]@{Value=[Text.Encoding]::UTF8.GetString($bytes);Encrypted=($encrypted -gt 0);EncryptedHex=$encryptedHex;Expires=$expiry}
        } elseif ($line.Trim()) { throw 'The cookie database returned an unsupported response; no cookie was changed.' }
    }
    if ($columns.Count -eq 0 -or $rows.Count -gt 1) { throw 'The cookie schema or number of cookie records is unsupported; waiting without guessing.' }
    $value=''; $encrypted=$false; $expiry=0;$encryptedHex=''
    if ($rows.Count -eq 1) { $value=$rows[0].Value; $encrypted=$rows[0].Encrypted;$encryptedHex=$rows[0].EncryptedHex; $expiry=$rows[0].Expires }
    return [pscustomobject]@{Exists=$true;Columns=$columns;Count=$rows.Count;Value=$value;Encrypted=$encrypted;EncryptedHex=$encryptedHex;Expires=$expiry}
}

function Restore-GameCookieSnapshot {
    param([string]$Package,$Snapshot)
    $db='/data/data/'+$Package+'/app_webview/Default/Cookies'
    $where="name='.ROBLOSECURITY' AND host_key='.roblox.com' AND path='/'"
    if($Snapshot.Count -eq 0){$sql="DELETE FROM cookies WHERE $where;"}
    else{
        $hex=[string]$Snapshot.EncryptedHex
        if($hex -notmatch '^(?:[0-9a-fA-F]{2})*$' -or ($Snapshot.Encrypted -and -not $hex)){throw 'Original encrypted cookie is unavailable for rollback.'}
        $value=([string]$Snapshot.Value).Replace("'","''")
        $sql="UPDATE cookies SET value='$value',encrypted_value=X'$hex',expires_utc=$([long]$Snapshot.Expires) WHERE $where;"
    }
    $null=Invoke-GameCookieAdb -Command ("su -c 'sqlite3 $db'") -InputText (".bail on`n.timeout 5000`nBEGIN IMMEDIATE;`n"+$sql+"`nCOMMIT;")
}

function Set-GameCookieDatabase {
    param([string]$Package,[string]$Cookie,$Snapshot,[switch]$Clear,[string]$ExpectedCookie='')
    $database='/data/data/'+$Package+'/app_webview/Default/Cookies'
    $predicate="name='.ROBLOSECURITY' AND host_key='.roblox.com' AND path='/'"
    $escaped=$Cookie.Replace("'","''")
    $now=[long]([datetime]::UtcNow.ToFileTimeUtc()/10)
    $expiry=[long]([datetime]::UtcNow.AddDays(30).ToFileTimeUtc()/10)
    $values=@{creation_utc="$now";host_key="'.roblox.com'";top_frame_site_key="''";name="'.ROBLOSECURITY'";value="'$escaped'";encrypted_value="X''";path="'/'";expires_utc="$expiry";is_secure='1';is_httponly='1';last_access_utc="$now";has_expires='1';is_persistent='1';priority='1';samesite='-1';source_scheme='2';source_port='443';last_update_utc="$now"}
    if ($Clear) {
        $sql="UPDATE cookies SET value='',encrypted_value=X'' WHERE $predicate AND value='"+$ExpectedCookie.Replace("'","''")+"';"
    } elseif ($Snapshot.Count -eq 1) {
        $assignments=@($Snapshot.Columns | Where-Object {$_.Name -in @('value','encrypted_value','expires_utc','last_access_utc','last_update_utc','has_expires','is_persistent')} | ForEach-Object {$_.Name+'='+$values[$_.Name]})
        $sql='UPDATE cookies SET '+($assignments -join ',')+" WHERE $predicate;"
    } else {
        $names=@(); $literals=@()
        foreach ($column in $Snapshot.Columns) {
            if ($values.ContainsKey($column.Name)) { $names+=$column.Name; $literals+=$values[$column.Name] }
            elseif ($column.Required -and -not $column.Default) { throw 'This cookie schema has an unsupported required column; no session was changed.' }
        }
        $sql='INSERT INTO cookies ('+($names -join ',')+') VALUES ('+($literals -join ',')+');'
    }
    $command="su -c 'test -f $database && sqlite3 $database'"
    $null=Invoke-GameCookieAdb -Command $command -InputText (".bail on`n.timeout 5000`nBEGIN IMMEDIATE;`n"+$sql+"`nCOMMIT;")
}



function Get-InstanceReplacementPaths {
    param($Settings)
    $directory=''
    if($Settings.ConfigFilePath){$directory=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Settings.ConfigFilePath))}
    elseif($Settings.CookieStorePath){$directory=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Settings.CookieStorePath))}
    if(-not $directory){return $null}
    $state=if($Settings.RestoreStateDirectory){Join-Path $Settings.RestoreStateDirectory 'instance-replacements'}else{Join-Path $directory '.instance-replacement-state'}
    return @{History=(Join-Path $directory 'instance-replacements.json');State=$state}
}

function Read-InstanceReplacementHistory {
    param($Settings)
    $paths=Get-InstanceReplacementPaths $Settings;$map=@{}
    if(-not $paths -or -not [IO.File]::Exists($paths.History)){return $map}
    $document=ConvertFrom-Json ([IO.File]::ReadAllText($paths.History))
    if($document.Version -ne 1 -or -not $document.Origins){throw 'Instance replacement history is invalid. Server assignments were left unchanged.'}
    foreach($entry in $document.Origins.PSObject.Properties){
        $old=0
        if($entry.Name -notmatch '^\d+$' -or -not [int]::TryParse([string]$entry.Value,[ref]$old) -or $old -lt 0 -or [int]$entry.Name -le $old){throw 'Instance replacement history contains an invalid ID mapping.'}
        $map[$entry.Name]=$old
    }
    return $map
}

function Get-InstanceReplacementOrigin {
    param([int]$Id,[hashtable]$History)
    $current=$Id
    while($History.ContainsKey([string]$current)){$current=[int]$History[[string]$current]}
    return $current
}

function Get-PendingInstanceReplacements {
    param($Settings)
    $paths=Get-InstanceReplacementPaths $Settings
    if(-not $paths -or -not [IO.Directory]::Exists($paths.State)){return @()}
    foreach($file in @(Get-ChildItem -LiteralPath $paths.State -Filter 'replacement-*.json' -File)){
        $entry=ConvertFrom-Json ([IO.File]::ReadAllText($file.FullName))
        if($entry.Kind -cne 'InstanceReplacement' -or $entry.OldId -le 0 -or $entry.NewId -le $entry.OldId -or $file.Name -cne "replacement-$($entry.OldId).json"){throw 'An instance replacement journal is invalid; replacement was postponed.'}
        if(Test-InstanceReplacementPending $entry){$entry}
    }
}

function New-InstanceReplacementSuccessorIndex {
    param($History)
    $index=@{}
    foreach($key in $History.Keys){$old=[int]$History[$key];if(-not $index.ContainsKey($old)){$index[$old]=@()};$index[$old]+=[int]$key}
    return $index
}

function Get-InstanceReplacementSuccessor {
    param($Settings,$Journal,$History=$null,$Successors=$null)
    if($null -eq $History){$History=Read-InstanceReplacementHistory $Settings}
    if($null -eq $Successors){$Successors=New-InstanceReplacementSuccessorIndex $History}
    $chain=New-Object 'System.Collections.Generic.List[int]';$chain.Add([int]$Journal.OldId);$chain.Add([int]$Journal.NewId)
    $current=[int]$Journal.NewId
    while($true){
        $next=if($Successors.ContainsKey($current)){@($Successors[$current])}else{@()}
        if(-not $next.Count){break}
        $paths=Get-InstanceReplacementPaths $Settings;$path=Join-Path $paths.State "replacement-$current.json"
        if([IO.File]::Exists($path)){
            $successor=ConvertFrom-Json ([IO.File]::ReadAllText($path))
            if($successor.OldId -eq $current -and $next -contains [int]$successor.NewId){$next=@([int]$successor.NewId)}
        }
        if($next.Count -ne 1 -or $next[0] -le $current -or $chain.Contains($next[0])){throw 'Replacement history has an ambiguous successor. Surviving instances were left untouched.'}
        $current=$next[0];$chain.Add($current)
    }
    return @{CurrentId=$current;Chain=$chain.ToArray();Superseded=($current -ne [int]$Journal.NewId)}
}

function Complete-SupersededInstanceReplacement {
    param($Settings,$Journal,[string]$JournalPath,$Successor)
    $history=Read-InstanceReplacementHistory $Settings
    if(-not $history.ContainsKey([string]$Journal.NewId) -or $history[[string]$Journal.NewId] -ne $Journal.OldId){throw 'The older replacement was not recorded as installed. Its source was kept.'}
    $current=Get-RestoreTargetInfo -Id $Successor.CurrentId
    if($current.Name -cne "LDPlayer-$($Successor.CurrentId)"){throw 'The current successor does not match replacement history. Source cleanup will retry.'}
    $vms=Join-Path $Settings.LdPlayerInstallPath 'vms';$currentRoot=Join-Path $vms "leidian$($Successor.CurrentId)"
    foreach($path in @((Join-Path $currentRoot 'data.vmdk'),(Join-Path $currentRoot 'sdcard.vmdk'),(Join-Path $vms "config\leidian$($Successor.CurrentId).config"))){Assert-InstanceReplacementDirectory $path $vms;if(-not [IO.File]::Exists($path) -or (Get-Item -LiteralPath $path).Length -le 0){throw 'The newest replacement files are unavailable. Older source cleanup will retry without recreating intermediate IDs.'}}
    $ownerPath=Join-Path $currentRoot '.joiner-replacement-owner.json'
    if([IO.File]::Exists($ownerPath)){
        $owner=ConvertFrom-Json ([IO.File]::ReadAllText($ownerPath))
        if($owner.NewId -ne $Successor.CurrentId -or $owner.OldId -ne $Successor.Chain[-2]){throw 'The current successor ownership does not match its replacement chain.'}
    }
    Assert-MovedInstanceSourceClosed $Settings $Journal.OldId
    Set-InstanceReplacementStep $Journal $JournalPath "Removing old ID $($Journal.OldId) files; current replacement is ID $($Successor.CurrentId)"
    $old=Join-Path $vms "leidian$($Journal.OldId)";$oldConfig=Join-Path $vms "config\leidian$($Journal.OldId).config"
    foreach($path in @($old,$oldConfig)){Assert-InstanceReplacementDirectory $path $vms}
    Remove-ReplacedInstanceNative $Settings $Journal $JournalPath
    $values=Read-LauncherUiConfig $Settings.ConfigFilePath
    $excluded=@(@($values.ExcludedLdPlayerIds -split ','|Where-Object{$_ -match '^\d+$'}|ForEach-Object{[int]$_})+@([int]$Journal.OldId)|Sort-Object -Unique)
    Set-LauncherConfigValues $Settings.ConfigFilePath @{ExcludedLdPlayerIds=($excluded -join ',')} -Automatic
    $Journal|Add-Member NoteProperty SourceDeleted $true -Force;$Journal|Add-Member NoteProperty OldDataDeleted $true -Force
    $Journal|Add-Member NoteProperty SupersededBy ([int]$Successor.CurrentId) -Force;$Journal|Add-Member NoteProperty DeferredSourceCleanup $null -Force
    $Journal|Add-Member NoteProperty LastError $null -Force;$Journal|Add-Member NoteProperty Version 2 -Force
    $Journal.Phase='Completed';$Journal|Add-Member NoteProperty Step 'Completed; continued under a newer replacement ID' -Force
    Write-TemplateStageManifest $JournalPath $Journal
    Write-FlowStatus "Older replacement $($Successor.Chain -join ' -> ') finalized. Only old ID $($Journal.OldId) files/worker were removed; the current emulator was left running."
}

function Test-InstanceReplacementPending {
    param($Journal)
    if($Journal.Phase -eq 'Completed'){return $false}
    if($Journal.Phase -eq 'Ready'){return ([int]$Journal.Version -ge 2 -or [bool]$Journal.DeferredSourceCleanup)}
    return $true
}

function Set-InstanceReplacementStep {
    param($Journal,[string]$JournalPath,[string]$Step)
    if($Journal.Step -ceq $Step -and -not $Journal.LastError){return}
    $Journal|Add-Member NoteProperty Step $Step -Force
    $Journal|Add-Member NoteProperty LastError $null -Force
    Write-TemplateStageManifest $JournalPath $Journal
    Write-FlowStatus "Replacement $($Journal.OldId) -> $($Journal.NewId): $Step."
}

function Write-ReplacementTextFile {
    param([string]$Path,[string]$Text,[string]$Parent)
    Assert-InstanceReplacementDirectory $Path $Parent
    if([IO.File]::Exists($Path) -and [IO.File]::ReadAllText($Path) -ceq $Text){return}
    $temp=$Path+'.write.tmp';Assert-InstanceReplacementDirectory $temp $Parent
    try{
        [IO.File]::WriteAllText($temp,$Text,[Text.UTF8Encoding]::new($false))
        Flush-ReplacementFile $temp
        if([IO.File]::Exists($Path)){[IO.File]::Replace($temp,$Path,[NullString]::Value)}else{[IO.File]::Move($temp,$Path)}
        if([IO.File]::ReadAllText($Path) -cne $Text){throw 'Replacement text file verification failed.'}
    }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}

function Flush-ReplacementFile {
    param([string]$Path)
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$stream.Flush($true)}finally{$stream.Dispose()}
}

function Test-ReplacementDiskFile {
    param([string]$Path,[long]$Length,[string[]]$Uuids)
    try{return ([IO.File]::Exists($Path) -and (Get-Item -LiteralPath $Path).Length -eq $Length -and (Get-TemplateDiskDescriptor $Path).Uuid -in $Uuids)}catch{return $false}
}

function Copy-ReplacementDiskFile {
    param([string]$Source,[string]$Target,[long]$Length,[string]$SourceUuid,[string]$TargetUuid,[string]$Parent)
    foreach($path in @($Source,$Target)){Assert-InstanceReplacementDirectory $path $Parent}
    
    
    if(Test-ReplacementDiskFile $Target $Length @($SourceUuid,$TargetUuid)){return}
    if(-not (Test-ReplacementDiskFile $Source $Length @($SourceUuid))){throw "Replacement source disk is missing or changed: $Source. Retrying this step with the same ID; surviving files were kept."}
    $temporary=$Target+'.copy.tmp';Assert-InstanceReplacementDirectory $temporary $Parent
    $sourceLock=[IO.File]::Open($Source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}
        [IO.File]::Copy($Source,$temporary,$false)
        if(-not (Test-ReplacementDiskFile $temporary $Length @($SourceUuid))){throw 'Replacement disk copy did not verify. Its source was kept.'}
        Flush-ReplacementFile $temporary
        if([IO.File]::Exists($Target)){[IO.File]::Replace($temporary,$Target,[NullString]::Value)}else{[IO.File]::Move($temporary,$Target)}
    }finally{$sourceLock.Dispose()}
}

function Get-NextInstanceReplacementId {
    param($Settings)
    $Config=$Settings
    $inventory=Get-BootInventory $Settings
    $highest=[int](($inventory.Keys|Measure-Object -Maximum).Maximum)
    $vms=Join-Path $Settings.LdPlayerInstallPath 'vms'
    foreach($item in @(Get-ChildItem -LiteralPath $vms -Directory)){
        if($item.Name -match '^(?:leidian|\.codex-template-|\.joiner-replacement-)(\d+)(?:-|$)'){$highest=[math]::Max($highest,[int]$Matches[1])}
    }
    foreach($item in @(Get-ChildItem -LiteralPath (Join-Path $vms 'config') -Filter 'leidian*.config' -File)){
        if($item.Name -match '^leidian(\d+)\.config$'){$highest=[math]::Max($highest,[int]$Matches[1])}
    }
    foreach($pending in @(Get-PendingInstanceReplacements $Settings)){$highest=[math]::Max($highest,[int]$pending.NewId)}
    foreach($id in @($Settings.LdPlayerIds)+@((Read-InstanceReplacementHistory $Settings).Keys)){$highest=[math]::Max($highest,[int]$id)}
    
    
    $appDataRoot=Get-GameAppDataRoot $Settings
    if([IO.Directory]::Exists($appDataRoot)){
        foreach($entry in @(Get-ChildItem -LiteralPath $appDataRoot -Directory)){
            if($entry.Name -match '^\d+$'){$highest=[math]::Max($highest,[int]$entry.Name)}
        }
    }
    if($highest -ge [int]::MaxValue){throw 'No further emulator index can be allocated.'}
    return $highest+1
}

function Assert-InstanceReplacementDirectory {
    param([string]$Path,[string]$Parent)
    $full=[IO.Path]::GetFullPath($Path);$root=[IO.Path]::GetFullPath($Parent).TrimEnd('\')+'\'
    if(-not $full.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){throw 'Replacement path is outside its expected directory.'}
    $current=$full
    while($current -and ($current.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or $current -ieq $root.TrimEnd('\'))){
        if((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Instance replacement does not follow redirected directories or files.'}
        $current=[IO.Path]::GetDirectoryName($current)
    }
}

function Restore-ReassignedCookieMigration {
    param($Settings,$Journal,[int]$PreviousId)
    $root=Get-GameAppDataRoot $Settings;$from=Join-Path $root "$PreviousId";$to=Join-Path $root "$($Journal.OldId)"
    foreach($path in @($from,$to)){Assert-InstanceReplacementDirectory $path $root}
    $marker=Join-Path $from 'handoff.json'
    if([IO.File]::Exists($marker) -and (ConvertFrom-Json ([IO.File]::ReadAllText($marker))).Token -ceq $Journal.Token){
        if([IO.Directory]::Exists($to)){throw 'Both source and reassigned app-data folders exist. Neither was overwritten.'}
        [IO.Directory]::Move($from,$to)
    }
}

function Resolve-InstanceReplacementIdConflict {
    param($Settings,$Journal,[string]$JournalPath)
    $Config=$Settings;$history=Read-InstanceReplacementHistory $Settings
    $conflict=$history.ContainsKey([string]$Journal.NewId) -and [int]$history[[string]$Journal.NewId] -ne [int]$Journal.OldId
    $savedRoot=Get-GameAppDataRoot $Settings;$savedTarget=Join-Path $savedRoot "$($Journal.NewId)"
    if([IO.Directory]::Exists($savedTarget)){
        $marker=Join-Path $savedTarget 'handoff.json'
        if(-not [IO.File]::Exists($marker) -or (ConvertFrom-Json ([IO.File]::ReadAllText($marker))).Token -cne $Journal.Token){
            $recordedOwner=$history.ContainsKey([string]$Journal.NewId) -and $history[[string]$Journal.NewId] -eq $Journal.OldId -and $Journal.Phase -in @('Installed','Ready','Completed')
            if($recordedOwner -and -not [IO.File]::Exists($marker)){
                $savedOld=Join-Path $savedRoot "$($Journal.OldId)"
                if([IO.Directory]::Exists($savedOld)){throw 'Saved app data exists under both IDs of an already installed replacement. Both were kept; the running emulator will not be reassigned.'}
                $snapshots=@(Get-GameAppDataTransferInventory $Settings $Journal.NewId)
                Write-TemplateStageManifest $marker @{Token=$Journal.Token;OldId=$Journal.OldId;NewId=$Journal.NewId;Snapshots=$snapshots}
            }else{$conflict=$true}
        }
    }
    $rehome=$Journal.IdReassignment
    if($rehome -and $rehome.Phase -eq 'Completed'){$rehome=$null}
    if(-not $conflict -and -not $rehome -and $Settings.LdPlayerIds -notcontains [int]$Journal.NewId){return}
    $vms=Join-Path $Settings.LdPlayerInstallPath 'vms'
    if(-not $rehome){
        $from=[int]$Journal.NewId;$to=Get-NextInstanceReplacementId $Settings
        $fromRoot=Join-Path $vms "leidian$from";$fromStage=$Journal.Stage
        $expected=Join-Path $vms ".joiner-replacement-$from-$($Journal.Token)"
        if([IO.Path]::GetFullPath($fromStage) -ine [IO.Path]::GetFullPath($expected)){throw 'The conflicted staging directory does not match its transaction.'}
        $dataTo='';$sdTo='';$vmText='';$configText=''
        if($Journal.DataUuid){$dataTo=Get-TemplateTargetUuid $Journal.DataUuid $from $to}
        if($Journal.SdUuid){$sdTo=Get-TemplateTargetUuid $Journal.SdUuid $from $to}
        $vmText=[string]$Journal.PreparedVmText;$configText=[string]$Journal.PreparedConfigText
        if(-not $vmText -and [IO.File]::Exists((Join-Path $fromRoot 'leidian.vbox'))){$vmText=[IO.File]::ReadAllText((Join-Path $fromRoot 'leidian.vbox'))}
        if(-not $vmText -and [IO.File]::Exists((Join-Path $fromStage 'payload\leidian.vbox'))){$vmText=[IO.File]::ReadAllText((Join-Path $fromStage 'payload\leidian.vbox'))}
        if(-not $configText -and [IO.File]::Exists((Join-Path $vms "config\leidian$from.config"))){$configText=[IO.File]::ReadAllText((Join-Path $vms "config\leidian$from.config"))}
        if(-not $configText -and [IO.File]::Exists((Join-Path $fromStage 'leidian.config'))){$configText=[IO.File]::ReadAllText((Join-Path $fromStage 'leidian.config'))}
        if($vmText){
            $xml=[xml]::new();$xml.XmlResolver=$null;$xml.PreserveWhitespace=$true;$xml.LoadXml($vmText)
            $machine=$xml.SelectSingleNode('//*[local-name()="Machine"]');$data=$xml.SelectSingleNode('//*[local-name()="HardDisk" and @location="data.vmdk"]')
            if(-not $machine -or $machine.name -cne "leidian$from" -or -not $data -or $data.uuid.Trim('{}') -ine $Journal.DataUuid){throw 'The conflicted VM does not belong to this replacement transaction. Existing files were preserved.'}
            $machine.SetAttribute('name',"leidian$to");$machine.SetAttribute('uuid',('{'+(Get-TemplateTargetUuid $machine.uuid.Trim('{}') $from $to)+'}'))
            $data.SetAttribute('uuid',"{$dataTo}")
            foreach($image in $xml.SelectNodes('//*[local-name()="Image"]')){if($image.uuid.Trim('{}') -ieq $Journal.DataUuid){$image.SetAttribute('uuid',"{$dataTo}")}}
            $vmText=$xml.OuterXml
        }
        if($configText){$configuration=ConvertFrom-Json $configText;$configuration|Add-Member NoteProperty 'statusSettings.playerName' "LDPlayer-$to" -Force;$configuration|Add-Member NoteProperty 'basicSettings.autoRun' $false -Force;$configText=$configuration|ConvertTo-Json -Depth 30}
        $rehome=[pscustomobject]@{FromId=$from;ToId=$to;Phase='Allocated';FromStage=$fromStage;ToStage=(Join-Path $vms ".joiner-replacement-$to-$($Journal.Token)");DataUuidFrom=$Journal.DataUuid;SdUuidFrom=$Journal.SdUuid;DataUuidTo=$dataTo;SdUuidTo=$sdTo;VmText=$vmText;ConfigText=$configText}
        $Journal|Add-Member NoteProperty IdReassignment $rehome -Force
        Write-TemplateStageManifest $JournalPath $Journal
    }
    $from=[int]$rehome.FromId;$to=[int]$rehome.ToId
    if($from -ne [int]$Journal.NewId -or $to -le $from -or $history.ContainsKey([string]$to) -or $Settings.LdPlayerIds -contains $to){throw 'The recorded fresh replacement ID is no longer available. No files were overwritten.'}
    if([IO.Path]::GetFullPath($rehome.FromStage) -ine [IO.Path]::GetFullPath((Join-Path $vms ".joiner-replacement-$from-$($Journal.Token)")) -or [IO.Path]::GetFullPath($rehome.ToStage) -ine [IO.Path]::GetFullPath((Join-Path $vms ".joiner-replacement-$to-$($Journal.Token)"))){throw 'The reassignment staging paths do not match this transaction.'}
    $fromRoot=Join-Path $vms "leidian$from";$toRoot=Join-Path $vms "leidian$to"
    $fromConfig=Join-Path $vms "config\leidian$from.config";$toConfig=Join-Path $vms "config\leidian$to.config"
    foreach($path in @($fromRoot,$toRoot,$fromConfig,$toConfig,$rehome.FromStage,$rehome.ToStage)){Assert-InstanceReplacementDirectory $path $vms}
    foreach($pair in @(@($rehome.FromStage,$rehome.ToStage),@($fromRoot,$toRoot),@($fromConfig,$toConfig))){
        if((Test-Path -LiteralPath $pair[0]) -and (Test-Path -LiteralPath $pair[1])){throw 'Both old and fresh replacement paths exist. Neither was overwritten.'}
    }
    $inventory=Get-BootInventory $Settings
    foreach($id in @([int]$Journal.OldId,$from,$to)){if($inventory.ContainsKey($id) -and ($inventory[$id].ProcessId -gt 0 -or $inventory[$id].AndroidStarted)){throw 'A conflicted replacement instance is running. Close it before its files can move to the fresh ID.'}}
    if([IO.Directory]::Exists($fromRoot)){
        if($Settings.LdPlayerIds -contains $from){throw 'Another active assignment owns the installed conflicting ID. Its files were left untouched.'}
        foreach($disk in @(@('data.vmdk',$rehome.DataUuidFrom,$rehome.DataUuidTo),@('sdcard.vmdk',$rehome.SdUuidFrom,$rehome.SdUuidTo))){
            $path=Join-Path $fromRoot $disk[0];Assert-InstanceReplacementDirectory $path $vms
            if(-not [IO.File]::Exists($path) -or (Get-TemplateDiskDescriptor $path).Uuid -ine $disk[1]){throw 'Installed files could not be proven to belong to the conflicted transaction. They were preserved.'}
        }
    }
    if([IO.Directory]::Exists($rehome.FromStage)){[IO.Directory]::Move($rehome.FromStage,$rehome.ToStage)}
    if([IO.Directory]::Exists($fromRoot)){[IO.Directory]::Move($fromRoot,$toRoot)}
    if([IO.File]::Exists($fromConfig)){[IO.File]::Move($fromConfig,$toConfig)}
    foreach($root in @((Join-Path $rehome.ToStage 'payload'),$toRoot)){
        if(-not [IO.Directory]::Exists($root)){continue}
        $ownerPath=Join-Path $root '.joiner-replacement-owner.json'
        if([IO.File]::Exists($ownerPath)){
            $owner=ConvertFrom-Json ([IO.File]::ReadAllText($ownerPath))
            if($owner.Token -cne $Journal.Token -or $owner.OldId -ne $Journal.OldId -or $owner.NewId -notin @($from,$to)){throw 'The moved replacement ownership record belongs to another transaction.'}
            $owner.NewId=$to;Write-TemplateStageManifest $ownerPath $owner
        }
        foreach($disk in @(@('data.vmdk',$rehome.DataUuidFrom,$rehome.DataUuidTo,$Journal.SourceDataUuid),@('sdcard.vmdk',$rehome.SdUuidFrom,$rehome.SdUuidTo,$Journal.SourceSdUuid))){
            $path=Join-Path $root $disk[0]
            if(-not [IO.File]::Exists($path)){continue}
            Assert-InstanceReplacementDirectory $path $vms;$uuid=(Get-TemplateDiskDescriptor $path).Uuid
            if($uuid -ine $disk[1] -and $uuid -ine $disk[2] -and $uuid -ine $disk[3]){throw 'A conflicted disk identity changed during reassignment. Its surviving file was kept.'}
            Set-TemplateDiskHostUuid $path $disk[2]
        }
        if($rehome.VmText -and [IO.File]::Exists((Join-Path $root 'leidian.vbox'))){[IO.File]::WriteAllText((Join-Path $root 'leidian.vbox'),$rehome.VmText,[Text.UTF8Encoding]::new($false))}
    }
    foreach($path in @((Join-Path $rehome.ToStage 'leidian.config'),$toConfig)){if($rehome.ConfigText -and [IO.File]::Exists($path)){[IO.File]::WriteAllText($path,$rehome.ConfigText,[Text.UTF8Encoding]::new($false))}}
    if($Settings.RestoreStateDirectory){
        $oldMarker=Join-Path $Settings.RestoreStateDirectory "template-accounts-$from.json"
        $newMarker=Join-Path $Settings.RestoreStateDirectory "template-accounts-$to.json"
        if([IO.File]::Exists($oldMarker)){
            $marker=ConvertFrom-Json ([IO.File]::ReadAllText($oldMarker))
            if($marker.Token -ceq $Journal.Token -and $marker.TargetIndex -eq $from){
                if([IO.File]::Exists($newMarker)){
                    $other=ConvertFrom-Json ([IO.File]::ReadAllText($newMarker))
                    if($other.Token -cne $Journal.Token -or $other.TargetIndex -ne $to){throw 'The fresh ID has a different pending account-cleanup record. Both records were preserved.'}
                }
                $marker.TargetIndex=$to;Write-TemplateStageManifest $newMarker $marker
                [IO.File]::Delete($oldMarker)
            }
        }
    }
    Restore-ReassignedCookieMigration $Settings $Journal $from
    $Journal.NewId=$to;$Journal.Stage=$rehome.ToStage;$Journal.DataUuid=$rehome.DataUuidTo;$Journal.SdUuid=$rehome.SdUuidTo
    if($Journal.PreparedVmText){$Journal.PreparedVmText=$rehome.VmText};if($Journal.PreparedConfigText){$Journal.PreparedConfigText=$rehome.ConfigText}
    if($Journal.Phase -eq 'Ready'){$Journal.Phase='Installed'}
    $rehome.Phase='Completed';Write-TemplateStageManifest $JournalPath $Journal
    Write-FlowStatus "The previous replacement ID $from was already reserved. Reassigned this transaction to fresh ID $to without changing conflicting history or saved accounts."
}

function Get-ClosedInstanceVmSource {
    param($Settings,[int]$Id,[switch]$TemplateData)
    $vms=Join-Path $Settings.LdPlayerInstallPath 'vms';$old=Join-Path $vms "leidian$Id"
    foreach($name in @('leidian.vbox','leidian.vbox-prev','.joiner-recovered.vbox')){
        $path=Join-Path $old $name;Assert-InstanceReplacementDirectory $path $vms
        if([IO.File]::Exists($path)){return $path}
    }
    
    
    
    Assert-MovedInstanceSourceClosed $Settings $Id
    if($Id -eq 0){throw 'LDPlayer 0 has no VM registration file in its installation folder. Open LDPlayer 0 once to let LDPlayer generate it, then close it before using it as the template.'}
    $template=Get-LauncherTemplateFiles $Settings
    $xml=[xml]::new();$xml.XmlResolver=$null;$xml.PreserveWhitespace=$true;$xml.Load($template.VmFile)
    $machine=$xml.SelectSingleNode('//*[local-name()="Machine"]');$data=$xml.SelectSingleNode('//*[local-name()="HardDisk" and @location="data.vmdk"]')
    if(-not $machine -or $machine.name -cne 'leidian0' -or -not $data -or $data.type -cne 'Normal'){throw 'The fallback VM registration template is unsupported.'}
    $configPath=Join-Path $vms "config\leidian$Id.config";Assert-InstanceReplacementDirectory $configPath $vms
    $configuration=ConvertFrom-Json ([IO.File]::ReadAllText($configPath))
    $fromUuid=$data.uuid.Trim('{}')
    $dataUuid=if($TemplateData){Get-TemplateTargetUuid $fromUuid 0 $Id}else{(Get-TemplateDiskDescriptor (Join-Path $old 'data.vmdk')).Uuid}
    if($dataUuid -notmatch '^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'){throw 'The affected data disk has no valid host UUID; registration was not guessed.'}
    $machine.SetAttribute('name',"leidian$Id");$machine.SetAttribute('uuid',('{'+(Get-TemplateTargetUuid $machine.uuid.Trim('{}') 0 $Id)+'}'))
    $data.SetAttribute('uuid',"{$dataUuid}")
    foreach($image in $xml.SelectNodes('//*[local-name()="Image"]')){if($image.uuid.Trim('{}') -ieq $fromUuid){$image.SetAttribute('uuid',"{$dataUuid}")}}
    foreach($field in @(@('advancedSettings.cpuCount','CPU','count',1,128),@('advancedSettings.memorySize','Memory','RAMSize',64,131072))){
        $number=0;$node=$machine.SelectSingleNode('.//*[local-name()="'+$field[1]+'"]')
        if($node -and [int]::TryParse([string]$configuration.($field[0]),[ref]$number) -and $number -ge $field[3] -and $number -le $field[4]){$node.SetAttribute($field[2],[string]$number)}
    }
    $mac=([string]$configuration.'propertySettings.macAddress') -replace '[:-]',''
    $adapter=$machine.SelectSingleNode('.//*[local-name()="Adapter" and @slot="0"]')
    if($adapter -and $mac -match '^[a-fA-F0-9]{12}$'){$adapter.SetAttribute('MACAddress',$mac.ToUpperInvariant())}
    $path=Join-Path $old '.joiner-recovered.vbox';$temporary=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllText($temporary,$xml.OuterXml,[Text.UTF8Encoding]::new($false))
        Assert-MovedInstanceSourceClosed $Settings $Id
        [IO.File]::Move($temporary,$path)
    }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
    Write-FlowStatus "Runtime VM registration was absent after shutdown. Rebuilt metadata for instance $Id; its app data and original configuration were kept."
    return $path
}

function New-InstanceReplacementPlan {
    param($Settings,[int]$OldId,[int]$NewId,[switch]$TemplateData)
    if($OldId -le 0 -or $NewId -le $OldId){throw 'The template cannot replace itself, and a replacement ID must be newer.'}
    $install=[IO.Path]::GetFullPath($Settings.LdPlayerInstallPath);$vms=Join-Path $install 'vms'
    Assert-InstanceReplacementDirectory $vms $install
    $old=Join-Path $vms "leidian$OldId";$target=Join-Path $vms "leidian$NewId"
    foreach($path in @($old,$target,(Join-Path $vms 'config'))){Assert-InstanceReplacementDirectory $path $vms}
    $targetConfig=Join-Path $vms "config\leidian$NewId.config"
    if((Test-Path -LiteralPath $target) -or (Test-Path -LiteralPath $targetConfig)){throw 'The allocated replacement ID already has files; no existing instance will be overwritten.'}
    $sourceConfig=Join-Path $vms "config\leidian$OldId.config"
    $sourceVm=Get-ClosedInstanceVmSource $Settings $OldId -TemplateData:$TemplateData
    $oldData=Join-Path $old 'data.vmdk';$sd=Join-Path $old 'sdcard.vmdk'
    $missing=New-Object 'System.Collections.Generic.List[string]'
    $copyData=if($TemplateData){(Get-LauncherTemplateFiles $Settings).DataFile}else{$oldData}
    if($TemplateData){$null=Resolve-LauncherRecoverySource -Settings $Settings -CheckClosed}
    foreach($file in @($sourceConfig,$sourceVm,$copyData,$sd)){
        if(-not ($TemplateData -and $file -ceq $copyData)){Assert-InstanceReplacementDirectory $file $vms}
        if(-not [IO.File]::Exists($file)){$missing.Add($file)}
    }
    if($missing.Count){throw ('Replacement source file missing or inaccessible: '+($missing.ToArray() -join '; ')+'. No replacement files were copied; the original instance and saved cookies were kept.')}
    $configuration=ConvertFrom-Json ([IO.File]::ReadAllText($sourceConfig))
    if($configuration.'basicSettings.standaloneSysVmdk'){throw 'This replacement supports the verified shared-system instance layout only.'}
    $xml=[xml]::new();$xml.XmlResolver=$null;$xml.PreserveWhitespace=$true;$xml.Load($sourceVm)
    $machine=$xml.SelectSingleNode('//*[local-name()="Machine"]')
    $data=$xml.SelectSingleNode('//*[local-name()="HardDisk" and @location="data.vmdk"]')
    if(-not $machine -or $machine.name -cne "leidian$OldId" -or -not $data -or $data.type -cne 'Normal'){throw 'The affected emulator VM registration is unsupported.'}
    $machineUuid=Get-TemplateTargetUuid $machine.uuid.Trim('{}') $OldId $NewId
    $sourceDataUuid=$data.uuid.Trim('{}');$dataUuid=Get-TemplateTargetUuid $sourceDataUuid $OldId $NewId
    $sdUuid=Get-TemplateTargetUuid (Get-TemplateDiskDescriptor $sd).Uuid $OldId $NewId
    if(-not $TemplateData -and (Get-TemplateDiskDescriptor $oldData).Uuid -ine $sourceDataUuid){throw 'The affected emulator data disk does not match its VM registration. Its files were preserved.'}
    foreach($disk in $xml.SelectNodes('//*[local-name()="HardDisk"]')){
        if($disk -eq $data){continue}
        if($disk.type -cne 'Readonly' -or [IO.Path]::GetFullPath($disk.location) -ine (Join-Path $install 'system.vmdk')){throw 'The affected emulator references an unsupported system disk.'}
    }
    $machine.SetAttribute('name',"leidian$NewId");$machine.SetAttribute('uuid',"{$machineUuid}")
    $data.SetAttribute('uuid',"{$dataUuid}")
    foreach($image in $xml.SelectNodes('//*[local-name()="Image"]')){if($image.uuid.Trim('{}') -ieq $sourceDataUuid){$image.SetAttribute('uuid',"{$dataUuid}")}}
    $configuration|Add-Member NoteProperty 'statusSettings.playerName' "LDPlayer-$NewId" -Force
    $configuration|Add-Member NoteProperty 'basicSettings.autoRun' $false -Force
    return @{OldId=$OldId;NewId=$NewId;OldDirectory=$old;TargetDirectory=$target;TargetConfig=$targetConfig;SourceConfig=$sourceConfig;SourceVm=$sourceVm;OldData=$oldData;CopyData=$copyData;SourceSd=$sd;DataUuid=$dataUuid;SdUuid=$sdUuid;VmText=$xml.OuterXml;ConfigText=($configuration|ConvertTo-Json -Depth 30)}
}

function Prepare-InstanceReplacementFiles {
    param($Settings,$Journal,[string]$JournalPath)
    if($Journal.TransferMode -in @('Move','CopyDelete')){Prepare-MovedInstanceReplacementFiles $Settings $Journal $JournalPath;return}
    $plan=New-InstanceReplacementPlan $Settings $Journal.OldId $Journal.NewId
    $stage=$Journal.Stage;$vms=Join-Path $Settings.LdPlayerInstallPath 'vms'
    Assert-InstanceReplacementDirectory $stage $vms
    if([IO.Directory]::Exists($stage)){throw 'An unfinished staging directory needs verification before copying can continue.'}
    $locks=New-Object 'System.Collections.Generic.List[object]'
    try{
        
        
        foreach($file in @($plan.OldData,$plan.SourceSd,$plan.SourceVm,$plan.SourceConfig)){$locks.Add([IO.File]::Open($file,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))}
        $null=[IO.Directory]::CreateDirectory((Join-Path $stage 'payload'))
        [IO.File]::Copy($plan.OldData,(Join-Path $stage 'payload\data.vmdk'),$false)
        [IO.File]::Copy($plan.SourceSd,(Join-Path $stage 'payload\sdcard.vmdk'),$false)
        if((Get-Item -LiteralPath $plan.OldData).Length -ne (Get-Item -LiteralPath (Join-Path $stage 'payload\data.vmdk')).Length){throw 'The copied data disk length could not be verified.'}
        if((Get-Item -LiteralPath $plan.SourceSd).Length -ne (Get-Item -LiteralPath (Join-Path $stage 'payload\sdcard.vmdk')).Length){throw 'The copied SD-card disk length could not be verified.'}
        Set-TemplateDiskHostUuid (Join-Path $stage 'payload\data.vmdk') $plan.DataUuid
        Set-TemplateDiskHostUuid (Join-Path $stage 'payload\sdcard.vmdk') $plan.SdUuid
        [IO.File]::WriteAllText((Join-Path $stage 'payload\leidian.vbox'),$plan.VmText,[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $stage 'leidian.config'),$plan.ConfigText,[Text.UTF8Encoding]::new($false))
        $Journal|Add-Member NoteProperty SourceKind 'AffectedInstance' -Force
        $Journal.DataUuid=$plan.DataUuid;$Journal.SdUuid=$plan.SdUuid;$Journal.Phase='Prepared'
        Write-TemplateStageManifest $JournalPath $Journal
    }finally{foreach($lock in $locks){$lock.Dispose()}}
}

function Assert-MovedInstanceSourceClosed {
    param($Settings,[int]$OldId)
    
    
    $inventory=Get-BootInventory $Settings
    if($inventory.ContainsKey($OldId) -and ($inventory[$OldId].ProcessId -gt 0 -or $inventory[$OldId].AndroidStarted)){throw 'The source emulator is running. Moving and installation were postponed.'}
}

function Prepare-MovedInstanceReplacementFiles {
    param($Settings,$Journal,[string]$JournalPath)
    $copying=$Journal.TransferMode -eq 'CopyDelete'
    $vms=Join-Path $Settings.LdPlayerInstallPath 'vms'
    $old=Join-Path $vms "leidian$($Journal.OldId)";$stage=$Journal.Stage
    $expected=Join-Path $vms ".joiner-replacement-$($Journal.NewId)-$($Journal.Token)"
    if($Journal.OldId -le 0 -or $Journal.NewId -le $Journal.OldId -or $Journal.Token -notmatch '^[a-f0-9]{32}$' -or [IO.Path]::GetFullPath($stage) -ine [IO.Path]::GetFullPath($expected)){throw 'Move journal does not match the exact source, target and staging paths.'}
    foreach($path in @($old,$stage,(Join-Path $stage 'payload'))){Assert-InstanceReplacementDirectory $path $vms}
    if($Journal.Phase -eq 'Preparing'){
        $plan=New-InstanceReplacementPlan $Settings $Journal.OldId $Journal.NewId -TemplateData:($Journal.DataSource -eq 'Template0')
        
        foreach($entry in @{
            SourceKind='AffectedInstance';SourceDataUuid=(Get-TemplateDiskDescriptor $plan.CopyData).Uuid;SourceSdUuid=(Get-TemplateDiskDescriptor $plan.SourceSd).Uuid
            DataLength=(Get-Item -LiteralPath $plan.CopyData).Length;SdLength=(Get-Item -LiteralPath $plan.SourceSd).Length
            PreparedVmText=$plan.VmText;PreparedConfigText=$plan.ConfigText;VmSourcePath=$plan.SourceVm
        }.GetEnumerator()){$Journal|Add-Member NoteProperty $entry.Key $entry.Value -Force}
        if($Journal.DataSource -eq 'Template0'){
            $Journal|Add-Member NoteProperty TemplateDataPath $plan.CopyData -Force
            $Journal|Add-Member NoteProperty TemplateDataWriteTicks (Get-Item -LiteralPath $plan.CopyData).LastWriteTimeUtc.Ticks -Force
            $oldFile=Get-Item -LiteralPath $plan.OldData -ErrorAction SilentlyContinue
            $Journal|Add-Member NoteProperty OldDataLength $(if($oldFile){$oldFile.Length}else{-1}) -Force
            $Journal|Add-Member NoteProperty OldDataWriteTicks $(if($oldFile){$oldFile.LastWriteTimeUtc.Ticks}else{0}) -Force
        }
        if($copying){
            $sourceFiles=foreach($path in @($plan.OldData,$plan.SourceSd,$plan.SourceVm,$plan.SourceConfig)){
                if([IO.File]::Exists($path)){$item=Get-Item -LiteralPath $path;@{Path=$path;Length=$item.Length;Ticks=$item.LastWriteTimeUtc.Ticks}}
            }
            $Journal|Add-Member NoteProperty SourceFiles @($sourceFiles) -Force
        }
        $Journal.DataUuid=$plan.DataUuid;$Journal.SdUuid=$plan.SdUuid;$Journal.Phase=$(if($copying){'Copying'}else{'Moving'})
        Write-TemplateStageManifest $JournalPath $Journal
    }
    if($Journal.Phase -notin @('Moving','Copying') -or -not $Journal.PreparedVmText -or -not $Journal.PreparedConfigText -or $Journal.DataLength -le 0 -or $Journal.SdLength -le 0){throw 'The replacement progress record is incomplete. Surviving files were left untouched.'}
    Assert-MovedInstanceSourceClosed $Settings $Journal.OldId
    $null=[IO.Directory]::CreateDirectory((Join-Path $stage 'payload'))
    $files=@()
    if($Journal.DataSource -eq 'Template0'){Copy-ReplacementTemplateData $Settings $Journal}
    else{$files+=@{Source=(Join-Path $old 'data.vmdk');Target=(Join-Path $stage 'payload\data.vmdk');Length=$Journal.DataLength;OldUuid=$Journal.SourceDataUuid;NewUuid=$Journal.DataUuid}}
    $files+=@(
        @{Source=(Join-Path $old 'sdcard.vmdk');Target=(Join-Path $stage 'payload\sdcard.vmdk');Length=$Journal.SdLength;OldUuid=$Journal.SourceSdUuid;NewUuid=$Journal.SdUuid},
        @{Source=$(if($Journal.VmSourcePath){$Journal.VmSourcePath}else{Join-Path $old 'leidian.vbox'});Target=(Join-Path $stage 'payload\leidian.vbox');Text=$Journal.PreparedVmText},
        @{Source=(Join-Path $vms "config\leidian$($Journal.OldId).config");Target=(Join-Path $stage 'leidian.config');Text=$Journal.PreparedConfigText}
    )
    foreach($file in $files){
        foreach($path in @($file.Source,$file.Target)){Assert-InstanceReplacementDirectory $path $vms}
        if($copying){
            if($file.ContainsKey('Length')){
                Copy-ReplacementDiskFile $file.Source $file.Target $file.Length $file.OldUuid $file.NewUuid $vms
            }else{
                Write-ReplacementTextFile $file.Target $file.Text $vms
            }
            continue
        }
        $sourceExists=[IO.File]::Exists($file.Source);$targetExists=[IO.File]::Exists($file.Target)
        if($sourceExists -and $targetExists){throw 'Both source and staged files exist for a move. Neither was overwritten.'}
        if(-not $sourceExists -and -not $targetExists){throw 'A replacement file is missing from both its source and staging path. Recovery was postponed.'}
        $current=if($sourceExists){$file.Source}else{$file.Target}
        if($file.ContainsKey('Length')){
            $uuid=(Get-TemplateDiskDescriptor $current).Uuid
            if((Get-Item -LiteralPath $current).Length -ne $file.Length -or ($uuid -ine $file.OldUuid -and ($sourceExists -or $uuid -ine $file.NewUuid))){throw 'A disk does not match its recorded length or identity. No file was overwritten.'}
        }
        if($sourceExists){
            Assert-MovedInstanceSourceClosed $Settings $Journal.OldId
            
            
            [IO.File]::Move($file.Source,$file.Target)
        }
    }
    Set-TemplateDiskHostUuid (Join-Path $stage 'payload\data.vmdk') $Journal.DataUuid
    Set-TemplateDiskHostUuid (Join-Path $stage 'payload\sdcard.vmdk') $Journal.SdUuid
    Write-ReplacementTextFile (Join-Path $stage 'payload\leidian.vbox') $Journal.PreparedVmText $vms
    Write-ReplacementTextFile (Join-Path $stage 'leidian.config') $Journal.PreparedConfigText $vms
    $Journal.Phase='Prepared';Write-TemplateStageManifest $JournalPath $Journal
}

function Copy-ReplacementTemplateData {
    param($Settings,$Journal)
    $vms=Join-Path $Settings.LdPlayerInstallPath 'vms'
    $source=if($Journal.TemplateDataPath){[string]$Journal.TemplateDataPath}else{Join-Path $vms 'leidian0\data.vmdk'};$target=Join-Path $Journal.Stage 'payload\data.vmdk'
    $temporary=Join-Path $Journal.Stage ('data-copy-'+$Journal.Token+'.tmp')
    foreach($path in @($target,$temporary)){Assert-InstanceReplacementDirectory $path $vms}
    if(Test-ReplacementDiskFile $target $Journal.DataLength @($Journal.SourceDataUuid,$Journal.DataUuid)){return}
    $template=Get-LauncherTemplateFiles $Settings
    if([IO.Path]::GetFullPath($source) -ine [IO.Path]::GetFullPath($template.DataFile)){throw 'The recorded template data path does not match installed LDPlayer 0. The recovery journal and emulator files were kept.'}
    $null=Resolve-LauncherRecoverySource -Settings $Settings -CheckClosed
    $sourceLock=[IO.File]::Open($source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        $sourceFile=Get-Item -LiteralPath $source
        if($sourceFile.Length -ne $Journal.DataLength -or $sourceFile.LastWriteTimeUtc.Ticks -ne $Journal.TemplateDataWriteTicks -or (Get-TemplateDiskDescriptor $source).Uuid -ine $Journal.SourceDataUuid){throw 'Template 0 data changed during recovery. Its disk and the old emulator data were kept.'}
        
        
        if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}
        [IO.File]::Copy($source,$temporary,$false)
        if((Get-Item -LiteralPath $temporary).Length -ne $Journal.DataLength -or (Get-TemplateDiskDescriptor $temporary).Uuid -ine $Journal.SourceDataUuid){throw 'The copied template data disk could not be verified. The old data was kept.'}
        Flush-ReplacementFile $temporary
        $null=Resolve-LauncherRecoverySource -Settings $Settings -CheckClosed
        if([IO.File]::Exists($target)){[IO.File]::Replace($temporary,$target,[NullString]::Value)}else{[IO.File]::Move($temporary,$target)}
    }finally{$sourceLock.Dispose()}
}

function Complete-TemplateDataReplacementCleanup {
    param($Settings,$Journal,[string]$JournalPath)
    $vms=Join-Path $Settings.LdPlayerInstallPath 'vms'
    if($Journal.DataSource -cne 'Template0' -or $Journal.OldId -le 0 -or $Journal.NewId -le $Journal.OldId -or $Journal.Phase -ne 'Installed'){throw 'Fresh-data cleanup does not match an installed replacement.'}
    $oldData=Join-Path $vms "leidian$($Journal.OldId)\data.vmdk"
    $newData=Join-Path $vms "leidian$($Journal.NewId)\data.vmdk"
    foreach($path in @($oldData,$newData)){Assert-InstanceReplacementDirectory $path $vms}
    Assert-MovedInstanceSourceClosed $Settings $Journal.OldId
    $target=Get-RestoreTargetInfo -Id $Journal.NewId
    if($target.Name -cne "LDPlayer-$($Journal.NewId)" -or -not [IO.File]::Exists($newData) -or ($target.Running -and -not $Journal.TargetRunningVerified)){throw 'The new emulator data disk was not confirmed. The old data was not deleted.'}
    if(-not $target.Running -and ((Get-Item -LiteralPath $newData).Length -ne $Journal.DataLength -or (Get-TemplateDiskDescriptor $newData).Uuid -ine $Journal.DataUuid)){throw 'The new emulator data disk was not confirmed. The old data was not deleted.'}
    
    
    $marker=Join-Path $Settings.RestoreStateDirectory "template-accounts-$($Journal.NewId).json"
    if([IO.File]::Exists($marker)){
        $pending=ConvertFrom-Json ([IO.File]::ReadAllText($marker))
        if($pending.Token -cne $Journal.Token -or $pending.TargetIndex -ne $Journal.NewId){throw 'A different copied-account cleanup already owns the new ID.'}
    }elseif(-not $target.Running){Write-TemplateStageManifest $marker @{TargetIndex=$Journal.NewId;SourceIndex=0;Token=$Journal.Token;Packages=@($Settings.GamePackages);Cleared=@()}}
    
    
    $Journal|Add-Member NoteProperty OldDataDeleted (-not [IO.File]::Exists($oldData)) -Force
    Write-TemplateStageManifest $JournalPath $Journal
}

function Remove-ReplacedInstanceNative {
    param($Settings,$Journal,[string]$JournalPath)
    $Config=$Settings;$oldId=[int]$Journal.OldId
    if($oldId -le 0 -or [int]$Journal.NewId -le $oldId -or $Journal.Token -notmatch '^[a-f0-9]{32}$' -or $Journal.Phase -notin @('Installed','Ready','Completed')){throw 'Native deletion has no valid installed replacement identity. No emulator was deleted.'}
    $vms=Join-Path $Settings.LdPlayerInstallPath 'vms';$old=Join-Path $vms "leidian$oldId";$oldConfig=Join-Path $vms "config\leidian$oldId.config"
    foreach($path in @($old,$oldConfig)){Assert-InstanceReplacementDirectory $path $vms}
    Wait-InstanceReplacementSourcesClosed -OldId $oldId -Settings $Settings -Journal $Journal -JournalPath $JournalPath
    
    
    if([IO.Directory]::Exists($old)){foreach($item in @(Get-ChildItem -LiteralPath $old -Force -Recurse)){Assert-InstanceReplacementDirectory $item.FullName $vms}}
    $inventory=Get-BootInventory $Settings
    if($null -eq $inventory -or $inventory.Count -eq 0){throw 'Native deletion is waiting for a usable LDPlayer inventory.'}
    if($inventory.ContainsKey($oldId) -and ($inventory[$oldId].ProcessId -gt 0 -or $inventory[$oldId].AndroidStarted)){throw "LDPlayer $oldId is still running. Its built-in delete command was postponed."}
    if($inventory.ContainsKey($oldId) -or [IO.Directory]::Exists($old) -or [IO.File]::Exists($oldConfig)){
        if(Test-FlowStopRequested){throw 'Stop requested before native instance deletion. The same replacement remains pending.'}
        $Journal|Add-Member NoteProperty SourceCleanupStarted $true -Force
        Write-TemplateStageManifest $JournalPath $Journal
        Write-FlowStatus "Replacement $oldId -> $($Journal.NewId): deleting only old LDPlayer $oldId using LDPlayer's built-in delete command..."
        $nativeFailure=$null
        try{$null=Invoke-Ld -Arguments @('remove','--index',"$oldId") -TimeoutSeconds ([math]::Max(10,[int]$Settings.CommandTimeout))}
        catch{$nativeFailure=$_.Exception.Message}
        $deadline=[datetime]::UtcNow.AddSeconds(10)
        do{
            
            
            $inventory=Get-BootInventory $Settings
            if($null -eq $inventory -or $inventory.Count -eq 0){throw 'Native deletion could not be confirmed because LDPlayer inventory is unavailable. The replacement remains pending.'}
            $registered=$inventory.ContainsKey($oldId)
            $filesRemain=[IO.Directory]::Exists($old) -or [IO.File]::Exists($oldConfig)
            if(-not $registered -and -not $filesRemain){break}
            if($registered -and ($inventory[$oldId].ProcessId -gt 0 -or $inventory[$oldId].AndroidStarted)){throw "LDPlayer $oldId started during native deletion. The replacement remains pending."}
            if($nativeFailure -or [datetime]::UtcNow -ge $deadline){
                $details=if($nativeFailure){$nativeFailure}else{'LDPlayer has not finished deleting the old instance.'}
                throw "Built-in delete for LDPlayer $oldId is incomplete (registration present: $registered; old files present: $filesRemain). $details The same replacement $oldId -> $($Journal.NewId) will retry."
            }
            if(Test-FlowStopRequested){throw 'Stop requested while waiting for native deletion. The same replacement remains pending.'}
            Start-Sleep -Milliseconds 1000
        }while($true)
        Write-FlowStatus "LDPlayer deleted old instance $oldId. Its registration and old emulator files are gone."
    }
    $Journal|Add-Member NoteProperty SourceDeleted $true -Force
    $Journal|Add-Member NoteProperty OldDataDeleted $true -Force
    Write-TemplateStageManifest $JournalPath $Journal
}

function Complete-CopiedInstanceSourceCleanup {
    param($Settings,$Journal,[string]$JournalPath)
    $vms=Join-Path $Settings.LdPlayerInstallPath 'vms'
    $old=Join-Path $vms "leidian$($Journal.OldId)";$target=Join-Path $vms "leidian$($Journal.NewId)"
    $oldConfig=Join-Path $vms "config\leidian$($Journal.OldId).config"
    if($Journal.OldId -le 0 -or $Journal.NewId -le $Journal.OldId){throw 'Source cleanup has no verified replacement ownership record.'}
    foreach($path in @($old,$target,$oldConfig)){Assert-InstanceReplacementDirectory $path $vms}
    Assert-MovedInstanceSourceClosed $Settings $Journal.OldId
    $current=Get-RestoreTargetInfo -Id $Journal.NewId
    if($current.Name -cne "LDPlayer-$($Journal.NewId)" -or ($current.Running -and -not $Journal.TargetRunningVerified)){throw 'The replacement ownership must be verified before source cleanup.'}
    if(-not $current.Running){
    $vm=Join-Path $target 'leidian.vbox';$newConfig=Join-Path $vms "config\leidian$($Journal.NewId).config"
    foreach($path in @($vm,$newConfig)){Assert-InstanceReplacementDirectory $path $vms}
    if(-not [IO.File]::Exists($vm) -or -not [IO.File]::Exists($newConfig) -or [IO.File]::ReadAllText($vm) -cne $Journal.PreparedVmText -or [IO.File]::ReadAllText($newConfig) -cne $Journal.PreparedConfigText){throw 'The replacement VM/config could not be verified. The old emulator was kept.'}
    foreach($disk in @(@('data.vmdk',$Journal.DataLength,$Journal.DataUuid),@('sdcard.vmdk',$Journal.SdLength,$Journal.SdUuid))){
        $path=Join-Path $target $disk[0]
        if(-not [IO.File]::Exists($path) -or (Get-Item -LiteralPath $path).Length -ne $disk[1] -or (Get-TemplateDiskDescriptor $path).Uuid -ine $disk[2]){throw 'The replacement disk could not be verified. The old emulator was kept.'}
    }
    $xml=[xml]::new();$xml.XmlResolver=$null;$xml.Load((Join-Path $target 'leidian.vbox'))
    if($xml.SelectSingleNode('//*[local-name()="Machine"]').name -cne "leidian$($Journal.NewId)" -or -not [IO.File]::Exists((Join-Path $vms "config\leidian$($Journal.NewId).config"))){throw 'The replacement registration is incomplete. The old emulator was kept.'}
    }
    Remove-ReplacedInstanceNative $Settings $Journal $JournalPath
}

function Install-InstanceReplacementFiles {
    param($Settings,$Journal,[string]$JournalPath)
    $vms=Join-Path $Settings.LdPlayerInstallPath 'vms';$target=Join-Path $vms "leidian$($Journal.NewId)";$targetConfig=Join-Path $vms "config\leidian$($Journal.NewId).config"
    $stage=$Journal.Stage
    foreach($path in @($target,$targetConfig,$stage)){Assert-InstanceReplacementDirectory $path $vms}
    $inventory=Get-BootInventory $Settings
    if($inventory.ContainsKey([int]$Journal.NewId) -and ($inventory[[int]$Journal.NewId].ProcessId -gt 0 -or $inventory[[int]$Journal.NewId].AndroidStarted)){throw 'The replacement is running. File publication will retry after it is closed.'}
    $payload=Join-Path $stage 'payload'
    Assert-InstanceReplacementDirectory $payload $vms
    $ownerName='.joiner-replacement-owner.json'
    $ownership=@{OldId=$Journal.OldId;NewId=$Journal.NewId;Token=$Journal.Token}
    if([IO.Directory]::Exists($payload)){
        if([IO.Directory]::Exists($target)){throw 'Replacement files already exist at the selected ID. Nothing was overwritten.'}
        if((Get-TemplateDiskDescriptor (Join-Path $payload 'data.vmdk')).Uuid -ine $Journal.DataUuid -or (Get-TemplateDiskDescriptor (Join-Path $payload 'sdcard.vmdk')).Uuid -ine $Journal.SdUuid){throw 'Prepared disk identities do not match the replacement journal.'}
        Write-TemplateStageManifest (Join-Path $payload $ownerName) $ownership
        $Journal.Phase='Installing';Write-TemplateStageManifest $JournalPath $Journal
        [IO.Directory]::Move($payload,$target)
    }
    if(-not [IO.Directory]::Exists($target)){throw 'Replacement publication is unfinished. Its recorded files and ID were kept for retry.'}
    $ownerPath=Join-Path $target $ownerName;Assert-InstanceReplacementDirectory $ownerPath $vms
    if([IO.File]::Exists($ownerPath)){
        $owner=ConvertFrom-Json ([IO.File]::ReadAllText($ownerPath))
        if($owner.Token -cne $Journal.Token -or $owner.OldId -ne $Journal.OldId -or $owner.NewId -ne $Journal.NewId){throw 'Another transaction owns the installed replacement. Its files were kept.'}
    }else{
        
        
        if(-not (Test-ReplacementDiskFile (Join-Path $target 'data.vmdk') $Journal.DataLength @($Journal.DataUuid)) -or -not (Test-ReplacementDiskFile (Join-Path $target 'sdcard.vmdk') $Journal.SdLength @($Journal.SdUuid)) -or [IO.File]::ReadAllText((Join-Path $target 'leidian.vbox')) -cne $Journal.PreparedVmText){throw 'The partial installation does not match its recorded owner. Existing files were kept.'}
        Write-TemplateStageManifest $ownerPath $ownership
    }
    foreach($disk in @(@('data.vmdk',$Journal.DataLength,$Journal.SourceDataUuid,$Journal.DataUuid),@('sdcard.vmdk',$Journal.SdLength,$Journal.SourceSdUuid,$Journal.SdUuid))){
        $installed=Join-Path $target $disk[0]
        if(-not (Test-ReplacementDiskFile $installed $disk[1] @($disk[3]))){
            $source=Join-Path $vms "leidian$($Journal.OldId)\$($disk[0])"
            if($disk[0] -eq 'data.vmdk' -and $Journal.DataSource -eq 'Template0'){$source=(Get-LauncherTemplateFiles $Settings).DataFile;$null=Resolve-LauncherRecoverySource $Settings -CheckClosed}
            Copy-ReplacementDiskFile $source $installed $disk[1] $disk[2] $disk[3] $vms
            Set-TemplateDiskHostUuid $installed $disk[3]
        }
    }
    Write-ReplacementTextFile (Join-Path $target 'leidian.vbox') $Journal.PreparedVmText $vms
    $stagedConfig=Join-Path $stage 'leidian.config'
    if([IO.File]::Exists($stagedConfig)){
        if([IO.File]::ReadAllText($stagedConfig) -cne $Journal.PreparedConfigText){Write-ReplacementTextFile $stagedConfig $Journal.PreparedConfigText $vms}
        if(-not [IO.File]::Exists($targetConfig)){[IO.File]::Move($stagedConfig,$targetConfig)}
    }
    Write-ReplacementTextFile $targetConfig $Journal.PreparedConfigText $vms
    Assert-InstalledInstanceReplacement $Settings $Journal
    $Journal.Phase='Installed';Write-TemplateStageManifest $JournalPath $Journal
}

function Assert-InstalledInstanceReplacement {
    param($Settings,$Journal,[switch]$AllowRunning)
    $vms=Join-Path $Settings.LdPlayerInstallPath 'vms';$target=Join-Path $vms "leidian$($Journal.NewId)"
    if($Journal.OldId -le 0 -or $Journal.NewId -le $Journal.OldId){throw 'Replacement identity is invalid.'}
    $current=Get-RestoreTargetInfo -Id $Journal.NewId
    if(($current.Running -and -not $AllowRunning) -or $current.Name -cne "LDPlayer-$($Journal.NewId)"){throw 'The installed replacement does not match the expected closed instance.'}
    if($current.Running){
        $ownerPath=Join-Path $target '.joiner-replacement-owner.json';Assert-InstanceReplacementDirectory $ownerPath $vms
        $owned=$false
        if([IO.File]::Exists($ownerPath)){
            $owner=ConvertFrom-Json ([IO.File]::ReadAllText($ownerPath))
            if($owner.Token -cne $Journal.Token -or $owner.OldId -ne $Journal.OldId -or $owner.NewId -ne $Journal.NewId){throw 'The running replacement belongs to another transaction. It was left untouched.'}
            $owned=$true
        }else{
            $history=Read-InstanceReplacementHistory $Settings
            $owned=$history.ContainsKey([string]$Journal.NewId) -and $history[[string]$Journal.NewId] -eq $Journal.OldId
        }
        if(-not $owned -or $Journal.Phase -notin @('Installed','Ready','Completed')){throw 'The running instance cannot be proven to be this completed file replacement. It was left untouched.'}
    }
    foreach($disk in @(@('data.vmdk',$Journal.DataUuid,$Journal.DataLength),@('sdcard.vmdk',$Journal.SdUuid,$Journal.SdLength))){
        $path=Join-Path $target $disk[0];Assert-InstanceReplacementDirectory $path $vms
        if($current.Running){
            if(-not [IO.File]::Exists($path) -or (Get-Item -LiteralPath $path).Length -le 0){throw 'A running replacement disk is missing. The emulator was left untouched.'}
        }elseif(-not (Test-ReplacementDiskFile $path $disk[2] @($disk[1]))){throw 'Installed replacement disk verification failed. Handoff was postponed.'}
    }
    $vm=Join-Path $target 'leidian.vbox';$registration=Join-Path $vms "config\leidian$($Journal.NewId).config"
    if(-not [IO.File]::Exists($vm) -and [IO.File]::Exists($vm+'-prev')){$vm+='-prev'}
    foreach($path in @($vm,$registration)){Assert-InstanceReplacementDirectory $path $vms;if(-not [IO.File]::Exists($path)){throw 'Installed replacement registration is missing. Handoff was postponed.'}}
    $xml=[xml]::new();$xml.XmlResolver=$null;$xml.Load($vm)
    $machine=$xml.SelectSingleNode('//*[local-name()="Machine"]');$data=$xml.SelectSingleNode('//*[local-name()="HardDisk" and @location="data.vmdk"]')
    if(-not $machine -or $machine.name -cne "leidian$($Journal.NewId)" -or -not $data -or $data.uuid.Trim('{}') -ine $Journal.DataUuid){throw 'Installed replacement VM identity does not match its disks.'}
    $Journal|Add-Member NoteProperty TargetRunningVerified ([bool]$current.Running) -Force
}

function Complete-InstanceReplacementMetadata {
    param($Settings,$Journal,[string]$JournalPath)
    $Config=$Settings
    if($Journal.Phase -eq 'Completed'){return}
    if($Journal.Phase -eq 'Ready' -and [int]$Journal.Version -ge 2 -and -not $Journal.DeferredSourceCleanup){
        Assert-InstalledInstanceReplacement $Settings $Journal -AllowRunning
        $old=Join-Path $Settings.LdPlayerInstallPath "vms\leidian$($Journal.OldId)";$oldConfig=Join-Path $Settings.LdPlayerInstallPath "vms\config\leidian$($Journal.OldId).config"
        if(-not [IO.Directory]::Exists($old) -and -not [IO.File]::Exists($oldConfig)){Remove-ReplacedInstanceNative $Settings $Journal $JournalPath;return}
        $Journal.Phase='Installed';Write-TemplateStageManifest $JournalPath $Journal
    }
    $paths=Get-InstanceReplacementPaths $Settings;$history=Read-InstanceReplacementHistory $Settings
    $newKey=[string]$Journal.NewId
    if($history.ContainsKey($newKey) -and $history[$newKey] -ne $Journal.OldId){throw 'Replacement ID history conflicts with a different old instance.'}
    $Journal|Add-Member NoteProperty Version 2 -Force
    Set-InstanceReplacementStep $Journal $JournalPath 'Verifying installed files'
    Assert-InstalledInstanceReplacement $Settings $Journal -AllowRunning
    Set-InstanceReplacementStep $Journal $JournalPath 'Verifying and renaming saved app data'
    Move-GameAppDataIdentity $Settings $Journal
    $history[$newKey]=[int]$Journal.OldId
    Write-TemplateStageManifest $paths.History @{Version=1;Origins=$history}
    $values=Read-LauncherUiConfig $Settings.ConfigFilePath
    $excluded=@($values.ExcludedLdPlayerIds -split ','|Where-Object{$_ -match '^\d+$'}|ForEach-Object{[int]$_})
    $excluded=@(@($excluded)+@([int]$Journal.OldId)|Where-Object{$_ -ne $Journal.NewId}|Sort-Object -Unique)
    Set-InstanceReplacementStep $Journal $JournalPath 'Removing verified old emulator files'
    if($Journal.DataSource -eq 'Template0' -and -not $Journal.TargetRunningVerified){Initialize-ReplacementTemplateAccountCleanup $Settings $Journal}
    if($Journal.DataSource -eq 'Template0'){Complete-TemplateDataReplacementCleanup $Settings $Journal $JournalPath}
    if($Journal.TransferMode -eq 'CopyDelete'){Complete-CopiedInstanceSourceCleanup $Settings $Journal $JournalPath}
    if($Journal.TransferMode -ne 'CopyDelete'){
        Remove-ReplacedInstanceNative $Settings $Journal $JournalPath
    }
    $Journal|Add-Member NoteProperty DeferredSourceCleanup $null -Force
    Set-InstanceReplacementStep $Journal $JournalPath 'Saving and verifying excluded IDs'
    Set-LauncherConfigValues -Path $Settings.ConfigFilePath -Values @{ExcludedLdPlayerIds=($excluded -join ',')} -Automatic
    $saved=Read-LauncherUiConfig $Settings.ConfigFilePath
    $savedExcluded=@($saved.ExcludedLdPlayerIds -split ','|Where-Object{$_ -match '^\d+$'}|ForEach-Object{[int]$_})
    if($savedExcluded -notcontains [int]$Journal.OldId -or $savedExcluded -contains [int]$Journal.NewId){throw 'Replacement exclusions are not saved yet. Metadata will retry.'}
    $Journal.Phase='Ready';$Journal|Add-Member NoteProperty Step 'Waiting for worker handoff' -Force
    Write-TemplateStageManifest $JournalPath $Journal
}

function Initialize-ReplacementTemplateAccountCleanup {
    param($Settings,$Journal)
    $marker=Join-Path $Settings.RestoreStateDirectory "template-accounts-$($Journal.NewId).json"
    if([IO.File]::Exists($marker)){
        $pending=ConvertFrom-Json ([IO.File]::ReadAllText($marker))
        if($pending.Token -cne $Journal.Token -or $pending.TargetIndex -ne $Journal.NewId){throw 'A different copied-account cleanup already owns the new ID.'}
    }else{Write-TemplateStageManifest $marker @{TargetIndex=$Journal.NewId;SourceIndex=0;Token=$Journal.Token;Packages=@($Settings.GamePackages);Cleared=@()}}
}

function Get-ReplacementSourceHostProcesses {
    param($Settings,[int]$OldId,$Previous=@(),$Inventory=$null)
    if($OldId -le 0){throw 'Template 0 cannot be closed by instance replacement.'}
    $install=[IO.Path]::GetFullPath($Settings.LdPlayerInstallPath).TrimEnd('\')+'\'
    if($null -eq $Inventory){$Inventory=Get-BootInventory $Settings}
    $nativeIds=@()
    if($Inventory.ContainsKey($OldId)){$row=$Inventory[$OldId];$nativeIds=@($row.ProcessId,$row.UiProcessId,$row.VmProcessId)|Where-Object{$_ -gt 0}}
    $foreignIds=@(foreach($id in $Inventory.Keys){if([int]$id -ne $OldId){$row=$Inventory[$id];@($row.ProcessId,$row.UiProcessId,$row.VmProcessId)|Where-Object{$_ -gt 0}}})
    $uuid='';$root=Join-Path $Settings.LdPlayerInstallPath "vms\leidian$OldId"
    foreach($name in @('leidian.vbox','leidian.vbox-prev','.joiner-recovered.vbox')){
        $path=Join-Path $root $name
        if([IO.File]::Exists($path)){
            try{$xml=[xml]::new();$xml.XmlResolver=$null;$xml.Load($path);$machine=$xml.SelectSingleNode('//*[local-name()="Machine"]');if($machine.name -ceq "leidian$OldId"){$uuid=$machine.uuid.Trim('{}');break}}catch{}
        }
    }
    $names=@('dnplayer.exe','ldplayer.exe','Ld9BoxHeadless.exe','LdVBoxHeadless.exe','VBoxHeadless.exe')
    $filter=($names|ForEach-Object{"Name='$_'"}) -join ' OR '
    try{$processes=@(Get-CimInstance -ClassName Win32_Process -Filter $filter -OperationTimeoutSec 5 -ErrorAction Stop)}
    catch{
        
        
        if(-not $script:ReplacementHostQueryWarning){Write-FlowStatus 'Windows process command lines are unavailable. Using only this instance''s native or previously verified process IDs.';$script:ReplacementHostQueryWarning=$true}
        $processes=@(foreach($knownId in @(@($nativeIds)+@($Previous|Where-Object{$_.SourceId -eq $OldId}|ForEach-Object{$_.ProcessId})|Where-Object{$_ -gt 0}|Sort-Object -Unique)){
            $known=Get-Process -Id $knownId -ErrorAction SilentlyContinue
            if($known){try{[pscustomobject]@{ProcessId=$knownId;Name=([IO.Path]::GetFileName($known.Path));ExecutablePath=$known.Path;CreationDate=$known.StartTime;CommandLine=''}}finally{$known.Dispose()}}
        })
    }
    foreach($process in $processes){
        $exe=[string]$process.ExecutablePath
        if(-not $exe -or $process.Name -notin $names -or -not [IO.Path]::GetFullPath($exe).StartsWith($install,[StringComparison]::OrdinalIgnoreCase) -or -not $process.CreationDate){continue}
        $processId=[int]$process.ProcessId;$command=[string]$process.CommandLine
        if($foreignIds -contains $processId){continue}
        if($command -match '(?i)(?:^|\s)--comment\s+"?leidian(\d+)"?(?=\s|$)' -and [int]$Matches[1] -ne $OldId){continue}
        if($process.Name -in @('dnplayer.exe','ldplayer.exe') -and $command -match '(?i)(?:^|\s)(?:--index[=\s]+|index=)"?(\d+)"?(?=\s|$)' -and [int]$Matches[1] -ne $OldId){continue}
        $live=Get-Process -Id $processId -ErrorAction SilentlyContinue
        if(-not $live){continue}
        try{
            $ticks=$live.StartTime.ToUniversalTime().Ticks
            if($live.Path -ine $exe -or [math]::Abs($ticks-$process.CreationDate.ToUniversalTime().Ticks) -gt 10000){continue}
        }finally{$live.Dispose()}
        $remembered=@($Previous|Where-Object{$_.SourceId -eq $OldId -and $_.ProcessId -eq $processId -and $_.StartTicks -eq $ticks -and $_.ExecutablePath -ieq $exe}).Count -gt 0
        $matchesName=$command -match ('(?i)(?:^|\s)--comment\s+"?leidian'+$OldId+'"?(?=\s|$)')
        $matchesIndex=$process.Name -in @('dnplayer.exe','ldplayer.exe') -and $command -match ('(?i)(?:^|\s)(?:--index[=\s]+|index=)"?'+$OldId+'"?(?=\s|$)')
        $matchesUuid=$uuid -match '^[a-f0-9-]{36}$' -and $command -match ('(?i)(?:^|\s)--startvm\s+"?\{?'+[regex]::Escape($uuid)+'\}?"?(?=\s|$)')
        if($nativeIds -contains $processId -or $remembered -or $matchesName -or $matchesIndex -or $matchesUuid){
            [pscustomobject]@{SourceId=$OldId;ProcessId=$processId;StartTicks=$ticks;ExecutablePath=$exe}
        }
    }
}

function Stop-ReplacementSourceHostProcess {
    param($Settings,[int]$OldId,$Record)
    if($OldId -le 0 -or $Record.SourceId -ne $OldId -or $Record.ProcessId -le 0){throw 'The lingering process does not belong to this old instance.'}
    $install=[IO.Path]::GetFullPath($Settings.LdPlayerInstallPath).TrimEnd('\')+'\'
    if(-not ([IO.Path]::GetFullPath($Record.ExecutablePath)).StartsWith($install,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($Record.ExecutablePath) -notin @('dnplayer.exe','ldplayer.exe','Ld9BoxHeadless.exe','LdVBoxHeadless.exe','VBoxHeadless.exe')){throw 'The lingering process is outside this LDPlayer installation.'}
    $process=Get-Process -Id $Record.ProcessId -ErrorAction SilentlyContinue
    if(-not $process){return}
    try{
        
        
        if($process.StartTime.ToUniversalTime().Ticks -ne $Record.StartTicks -or $process.Path -ine $Record.ExecutablePath){return}
        Write-FlowStatus "Stopping lingering LDPlayer $OldId process $($Record.ProcessId) before old-file cleanup..."
        $process.Kill();$null=$process.WaitForExit(1000)
    }finally{$process.Dispose()}
}

function Wait-InstanceReplacementSourcesClosed {
    param([int]$OldId,$Settings=$Config,$Journal=$null,[string]$JournalPath='')
    if($OldId -le 0){throw 'Template 0 cannot be closed by instance replacement.'}
    $Config=$Settings;$InstanceIndex=$OldId
    $inventory=Get-BootInventory $Settings
    if($null -eq $inventory -or $inventory.Count -eq 0){throw 'Source shutdown is waiting for a usable LDPlayer inventory.'}
    $previous=if($Journal){@($Journal.SourceHostProcesses)}else{@()}
    $owned=@(Get-ReplacementSourceHostProcesses $Settings $OldId $previous $inventory)
    $running=$inventory.ContainsKey($OldId) -and ($inventory[$OldId].ProcessId -gt 0 -or $inventory[$OldId].AndroidStarted)
    if(-not $running -and $owned.Count -eq 0){return}
    if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Stopped before closing the replacement source.')}
    if($Journal -and $JournalPath){$Journal|Add-Member NoteProperty SourceHostProcesses $owned -Force;Write-TemplateStageManifest $JournalPath $Journal}
    Write-FlowStatus "Closing LDPlayer $OldId apps before closing the old replacement source..."
    if($running){
        try{Close-AppsBeforeEmulatorRestart}
        catch [System.Management.Automation.PipelineStoppedException]{throw}
        catch{
            if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Stopped during replacement-source app shutdown.')}
            Write-FlowStatus ('Android app shutdown could not finish: '+$_.Exception.Message+'. Closing only the old emulator through LDPlayer.')
        }
    }else{Write-FlowStatus 'Android is already closed; waiting for its remaining host processes.'}
    if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Stopped before closing the old emulator.')}
    $quitError=''
    try{$null=Invoke-Ld -Arguments @('quit','--index',"$OldId")}
    catch{$quitError=$_.Exception.Message}
    $grace=[datetime]::UtcNow.AddSeconds(10);$deadline=$grace.AddSeconds(10);$forced=$false;$stopped=0
    while($stopped -lt 2){
        if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Stopped while waiting for the old emulator processes to exit.')}
        $inventory=Get-BootInventory $Settings
        if($null -eq $inventory -or $inventory.Count -eq 0){throw 'Source shutdown could not be confirmed because LDPlayer inventory is unavailable.'}
        $owned=@(Get-ReplacementSourceHostProcesses $Settings $OldId $owned $inventory)
        $running=$inventory.ContainsKey($OldId) -and ($inventory[$OldId].ProcessId -gt 0 -or $inventory[$OldId].AndroidStarted)
        if(-not $running -and $owned.Count -eq 0){$stopped++}else{$stopped=0}
        if($stopped -ge 2){break}
        if(-not $forced -and [datetime]::UtcNow -ge $grace){
            foreach($record in $owned){Stop-ReplacementSourceHostProcess $Settings $OldId $record}
            $forced=$true
        }
        if([datetime]::UtcNow -ge $deadline){throw "Old LDPlayer $OldId processes have not fully exited. No files were copied or deleted; this replacement will retry. $quitError"}
        Start-Sleep -Milliseconds 1000
    }
    Write-FlowStatus "Old LDPlayer $OldId is closed and its instance processes have exited. Continuing the same replacement."
}

function Invoke-InstanceReplacement {
    param([switch]$FreshData)
    $oldId=[int]$InstanceIndex
    if($oldId -le 0){throw 'Template 0 cannot be replaced by package-check recovery.'}
    $paths=Get-InstanceReplacementPaths $Config
    $null=[IO.Directory]::CreateDirectory($paths.State)
    $journalPath=Join-Path $paths.State "replacement-$oldId.json"
    Enter-EmulatorLoadingSlot
    $mutex=New-Object Threading.Mutex $false,($Config.RestoreMutexName+'-NewInstance');$held=$false
    $instanceMutex=New-Object Threading.Mutex $false,($Config.RestoreMutexName+'-Instance-'+$oldId);$instanceHeld=$false
    $journal=$null
    try{
        while(-not $instanceHeld){
            Assert-PoolSetupTurn
            try{$instanceHeld=$instanceMutex.WaitOne(1000)}catch [Threading.AbandonedMutexException]{$instanceHeld=$true}
        }
        Enter-EmulatorRestoreSlot
        Set-EmulatorLiveObservation -EmulatorState Replacing
        $script:RestoreQueueRecord.Phase='Restoring';Write-RestoreQueueRecord $script:RestoreQueuePath $script:RestoreQueueRecord
        Write-FlowStatus 'Checking the reserved replacement ID and saved progress...'
        while(-not $held){
            if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Stopped while waiting for instance replacement.')}
            try{$held=$mutex.WaitOne(1000)}catch [Threading.AbandonedMutexException]{$held=$true}
        }
        $script:ReplacementFileTransaction=$true
        $journal=$null
        if([IO.File]::Exists($journalPath)){$journal=ConvertFrom-Json ([IO.File]::ReadAllText($journalPath))}
        
        
        
        if($journal -and -not (Test-InstanceReplacementPending $journal) -and $script:ActiveInstanceReplacementToken -cne $journal.Token){$journal=$null}
        if(-not $journal){
            $newId=Get-NextInstanceReplacementId $Config;$token=[guid]::NewGuid().ToString('N')
            $dataSource=if($FreshData -or $script:PendingEmulatorRestore){'Template0'}else{'AffectedInstance'}
            $journal=[pscustomobject]@{Version=2;Kind='InstanceReplacement';OldId=$oldId;NewId=$newId;Token=$token;Phase='Preparing';TransferMode='CopyDelete';DataSource=$dataSource;Stage=(Join-Path $Config.LdPlayerInstallPath "vms\.joiner-replacement-$newId-$token");DataUuid='';SdUuid=''}
            Write-TemplateStageManifest $journalPath $journal
        }
        if($journal.OldId -ne $oldId -or $journal.Kind -cne 'InstanceReplacement' -or $journal.NewId -le $oldId -or $journal.Token -notmatch '^[a-f0-9]{32}$' -or $journal.Phase -notin @('Preparing','Copying','Moving','Prepared','Installing','Installed','Ready','Completed')){throw 'Replacement journal does not match the affected instance.'}
        if($journal.Phase -eq 'Ready' -and $journal.DeferredSourceCleanup){$journal.Phase='Installed';Write-TemplateStageManifest $journalPath $journal}
        $expectedStage=Join-Path $Config.LdPlayerInstallPath "vms\.joiner-replacement-$($journal.NewId)-$($journal.Token)"
        if([IO.Path]::GetFullPath($journal.Stage) -ine [IO.Path]::GetFullPath($expectedStage)){throw 'Replacement staging path does not match its journal.'}
        $successor=Get-InstanceReplacementSuccessor $Config $journal
        if($successor.Superseded){
            Wait-InstanceReplacementSourcesClosed -OldId $oldId -Settings $Config -Journal $journal -JournalPath $journalPath
            Complete-SupersededInstanceReplacement $Config $journal $journalPath $successor
            $signal=[OperationCanceledException]::new('An older replacement was finalized; its obsolete worker is retired.')
            $signal.Data['InstanceReplacementRetired']=$true;throw $signal
        }
        Resolve-InstanceReplacementIdConflict $Config $journal $journalPath
        if($Config.LdPlayerIds -contains [int]$journal.NewId){throw 'The replacement ID is already assigned in this run. Existing instances were left unchanged.'}
        $script:ActiveInstanceReplacementToken=[string]$journal.Token
        
        
        if($journal.Phase -notin @('Ready','Completed')){$mutex.ReleaseMutex();$held=$false}
        if($journal.Phase -notin @('Ready','Completed')){
            $closeStep=if($journal.Phase -eq 'Preparing'){'Confirming the affected emulator is closed'}else{'Resuming saved '+$journal.Phase.ToLowerInvariant()+' progress'}
            Set-InstanceReplacementStep $journal $journalPath $closeStep
            Wait-InstanceReplacementSourcesClosed -OldId $oldId -Settings $Config -Journal $journal -JournalPath $journalPath
        }
        
        
        if($journal.Phase -in @('Preparing','Prepared','Installing') -and ($journal.SourceKind -cne 'AffectedInstance' -or $journal.TransferMode -notin @('Move','CopyDelete')) -and -not [IO.Directory]::Exists((Join-Path $Config.LdPlayerInstallPath "vms\leidian$($journal.NewId)"))){
            $journal.Phase='Preparing';Write-TemplateStageManifest $journalPath $journal
        }
        if($journal.Phase -eq 'Preparing'){
            if([IO.Directory]::Exists($journal.Stage)){
                $expected=Join-Path $Config.LdPlayerInstallPath "vms\.joiner-replacement-$($journal.NewId)-$($journal.Token)"
                if([IO.Path]::GetFullPath($journal.Stage) -ine [IO.Path]::GetFullPath($expected)){throw 'Partial staging path does not match its journal.'}
                Assert-InstanceReplacementDirectory $journal.Stage (Join-Path $Config.LdPlayerInstallPath 'vms')
                [IO.Directory]::Delete($journal.Stage,$true)
            }
            
            $journal|Add-Member NoteProperty TransferMode 'CopyDelete' -Force
            Write-FlowStatus "Creating LDPlayer $($journal.NewId): copying and verifying the replacement files before deleting closed instance $oldId. Data source: $($journal.DataSource)."
        }
        if($journal.Phase -in @('Preparing','Moving','Copying')){
            Set-InstanceReplacementStep $journal $journalPath 'Copying missing replacement files'
            Prepare-InstanceReplacementFiles $Config $journal $journalPath
        }
        if($journal.Phase -in @('Prepared','Installing')){
            Set-InstanceReplacementStep $journal $journalPath 'Publishing replacement disks and registration'
            if($journal.TransferMode -in @('Move','CopyDelete')){Assert-MovedInstanceSourceClosed $Config $oldId}
            elseif((Get-RestoreTargetInfo -Id $oldId).Running){throw 'The source restarted during preparation. Installation was postponed.'}
            Install-InstanceReplacementFiles $Config $journal $journalPath
        }
        if($journal.Phase -eq 'Installed'){
            while(-not $held){
                if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Stopped before replacement metadata.')}
                try{$held=$mutex.WaitOne(1000)}catch [Threading.AbandonedMutexException]{$held=$true}
            }
            $target=Get-RestoreTargetInfo -Id $journal.NewId
            Set-InstanceReplacementStep $journal $journalPath 'Finalizing the existing replacement'
            if($target.Name -cne "LDPlayer-$($journal.NewId)"){throw 'The replacement name does not match the journal.'}
            try{Assert-InstalledInstanceReplacement $Config $journal -AllowRunning}
            catch{
                if($target.Running){throw}
                $journal.Phase='Installing';Write-TemplateStageManifest $journalPath $journal
                Install-InstanceReplacementFiles $Config $journal $journalPath
            }
            Complete-InstanceReplacementMetadata $Config $journal $journalPath
        }
        if($journal.Phase -notin @('Ready','Completed')){throw 'The replacement transaction is incomplete.'}
        if($journal.Phase -eq 'Ready'){
            Wait-InstanceReplacementSourcesClosed -OldId $oldId -Settings $Config -Journal $journal -JournalPath $journalPath
            Assert-InstalledInstanceReplacement $Config $journal -AllowRunning
            $oldRoot=Join-Path $Config.LdPlayerInstallPath "vms\leidian$oldId";$oldConfig=Join-Path $Config.LdPlayerInstallPath "vms\config\leidian$oldId.config"
            if([IO.Directory]::Exists($oldRoot) -or [IO.File]::Exists($oldConfig)){$journal.Phase='Installed';Write-TemplateStageManifest $journalPath $journal;throw 'Old files remain. Cleanup will resume before handoff.'}
        }
        if([IO.Directory]::Exists($journal.Stage)){
            Set-InstanceReplacementStep $journal $journalPath 'Removing completed staging files'
            Assert-InstanceReplacementDirectory $journal.Stage (Join-Path $Config.LdPlayerInstallPath 'vms')
            foreach($item in @(Get-ChildItem -LiteralPath $journal.Stage -Force -Recurse)){Assert-InstanceReplacementDirectory $item.FullName (Join-Path $Config.LdPlayerInstallPath 'vms')}
            [IO.Directory]::Delete($journal.Stage,$true)
        }
        Set-InstanceReplacementStep $journal $journalPath 'Waiting for worker handoff'
        $event=@{OldId=$oldId;NewId=[int]$journal.NewId;Token=$journal.Token}
        Write-TemplateStageManifest (Join-Path $Config.ReplacementHandoffDirectory "handoff-$oldId.json") $event
    }catch{
        if($journal -and $instanceHeld -and -not $_.Exception.Data['InstanceReplacementRetired']){
            try{
                $journal|Add-Member NoteProperty LastError ([string]$_.Exception.Message) -Force
                $journal|Add-Member NoteProperty RetryCount (1+[int]$journal.RetryCount) -Force
                Write-TemplateStageManifest $journalPath $journal
            }catch{}
        }
        throw
    }finally{
        $script:ReplacementFileTransaction=$false;Exit-EmulatorRestoreSlot
        if($held){$mutex.ReleaseMutex()};$mutex.Dispose()
        if($instanceHeld){$instanceMutex.ReleaseMutex()};$instanceMutex.Dispose()
    }
    Write-FlowStatus "Replacement $($journal.NewId) is ready. Waiting for its current-run worker/loading-slot handoff..."
    $ackPath=Join-Path $Config.ReplacementHandoffDirectory "ack-$oldId.json"
    while($true){
        if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Stopped after replacement registration.')}
        
        
        $durable=ConvertFrom-Json ([IO.File]::ReadAllText($journalPath))
        if($durable.Phase -eq 'Completed' -and $durable.Token -ceq $journal.Token -and $durable.HandoffSession -ceq $Config.ReplacementHandoffDirectory){
            $signal=[OperationCanceledException]::new('The instance was replaced; switching this worker to the new ID.')
            $signal.Data['InstanceReplacementId']=[int]$journal.NewId;$signal.Data['ReplacementBoot']=$durable.HandoffBoot
            throw $signal
        }
        if([IO.File]::Exists($ackPath)){
            $ack=ConvertFrom-Json ([IO.File]::ReadAllText($ackPath))
            if($ack.Token -ceq $journal.Token -and $ack.NewId -eq $journal.NewId){
                $signal=[OperationCanceledException]::new('The instance was replaced; switching this worker to the new ID.')
                $signal.Data['InstanceReplacementId']=[int]$journal.NewId;$signal.Data['ReplacementBoot']=$ack.Boot
                throw $signal
            }
        }
        Start-Sleep -Seconds 1
    }
}

function Invoke-WorkerWithInstanceReplacement {
    $Config=$Config.Clone();$InstanceIndex=[int]$InstanceIndex
    while($true){
        $paths=Get-InstanceReplacementPaths $Config
        if($paths -and [IO.File]::Exists((Join-Path $paths.State "replacement-$InstanceIndex.json"))){
            $savedReplacement=ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $paths.State "replacement-$InstanceIndex.json")))
            if((Test-InstanceReplacementPending $savedReplacement) -or ($script:ActiveInstanceReplacementToken -and $script:ActiveInstanceReplacementToken -ceq $savedReplacement.Token)){$script:PendingInstanceReplacement=$true}
        }
        try{
            if($script:PendingInstanceReplacement){Invoke-InstanceReplacement}
            $action=Invoke-ResilientEmulatorFlow
            if($script:PoolRole){return $action}
            return
        }catch [OperationCanceledException]{
            if($_.Exception.Data['InstanceReplacementRetired']){
                if($script:BootRequestRecord.Phase -in @('SettingUp','Waiting')){Set-BootRequestPhase Finished}
                return 'Retired'
            }
            if(-not $_.Exception.Data['InstanceReplacementId']){throw}
            $oldId=$InstanceIndex;$InstanceIndex=[int]$_.Exception.Data['InstanceReplacementId']
            if($script:PoolRole){$script:PoolAppState=$null;$script:PoolReplacementConfig=$Config}
            $boot=$_.Exception.Data['ReplacementBoot'];$script:BootRequestRecord=$null
            if($boot){$script:BootRequestRecord=@{Id=$InstanceIndex;Token=[string]$boot.Token;Phase=[string]$boot.Phase;RestartRunning=$false}}
            $script:BootRequestPath=Join-Path ([IO.Path]::GetDirectoryName($LaunchStateFile)) "boot-request-$InstanceIndex.json"
            $Config.LdPlayerIds=@($Config.LdPlayerIds|ForEach-Object{if($_ -eq $oldId){$InstanceIndex}else{$_}}|Sort-Object -Unique)
            $script:PendingInstanceReplacement=$false;$script:ActiveInstanceReplacementToken=$null;$script:PendingEmulatorRestore=$null
            Reset-AppCrashTracking
            $script:PackageCheckRestartPending=$false;Reset-PackageCheckRecovery
            $script:CurrentEmulatorInstance=$null;$script:RequiredAppsCheckedKey=$null;$script:InitialCookieBoot=0;$script:CookieBootIdentity=0;$script:CookieAdbSerial=$null
            $script:InitialCookieChecks=@{};$script:LoadedCookieCaptures=@{};$script:LoadedAppDataCaptures=@{};$script:WaitingAppDataCookies=@{};$script:GameCookiePassResults=@{};$script:CookieAuthenticationCache=@{};$script:CookieSlotPause=$null
            $script:VpnVerifiedBoot=0;$script:CloudflareUidCache=$null;$script:EmulatorUptimeProcessId=0;$script:StartupFailureCount=0;$script:GameLinkSentAt=@{}
            Clear-ProcessCheckCache
            Write-FlowStatus "This worker now handles replacement $InstanceIndex. Continuing the normal VPN, account and game flow."
        }catch{
            if($script:PoolRole){
                $package=[string]$_.Exception.Data['GamePackage'];if(-not $package){$package=$script:PoolActivePackage}
                if(-not $package){$package=$Config.GamePackage}
                $healthOnly=[bool]$_.Exception.Data['GameStatusReadFailed']
                if($script:PoolRole -eq 'Monitor'){
                    if(Request-MonitorQuickRecovery -Package $package -Failure $_.Exception -HealthOnly:$healthOnly -EmulatorOnly:($script:RecoveryScope -in @('Startup','Packages','VPN'))){Assert-PoolSetupTurn}
                    return 'Monitoring'
                }
                $script:PoolPendingRecovery=@{Package=$package;HealthOnly=$healthOnly;EmulatorOnly=($script:RecoveryScope -in @('Startup','Packages','VPN'))}
                if($script:PoolAppState -and -not $healthOnly){foreach($app in $script:PoolAppState.Apps){if($app.Config.GamePackage -ceq $package){$app.Ready=$false}}}
                if($script:PoolRole -eq 'Monitor'){Assert-PoolSetupTurn}
            }
            Write-WorkerRetryStatus -Failure $_.Exception -RetrySeconds $Config.RetryDelay -ReplacementActive:([bool]$script:PendingInstanceReplacement)
            Wait-FlowPause ([math]::Max(1,$Config.RetryDelay))
        }
    }
}

function Update-InstanceReplacementHandoffs {
    param($Settings,$Jobs,$Scheduler)
    foreach($file in @(Get-ChildItem -LiteralPath $Settings.ReplacementHandoffDirectory -Filter 'handoff-*.json' -File)){
        $event=ConvertFrom-Json ([IO.File]::ReadAllText($file.FullName))
        $oldId=[int]$event.OldId;$newId=[int]$event.NewId
        if($oldId -le 0 -or $newId -le $oldId -or $event.Token -notmatch '^[a-f0-9]{32}$'){throw 'A replacement worker handoff is invalid.'}
        $commitMutex=New-Object Threading.Mutex $false,($Settings.RestoreMutexName+'-NewInstance');$commitHeld=$false
        try{
        try{$commitHeld=$commitMutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$commitHeld=$true}
        if(-not $commitHeld){continue}
        $replacementPaths=Get-InstanceReplacementPaths $Settings;$journalPath=Join-Path $replacementPaths.State "replacement-$oldId.json"
        if([IO.File]::Exists($journalPath)){
            $preflight=ConvertFrom-Json ([IO.File]::ReadAllText($journalPath))
            if([int]$preflight.Version -ge 2 -and ($preflight.Token -cne $event.Token -or $preflight.NewId -ne $newId -or $preflight.Phase -notin @('Ready','Completed'))){throw 'Replacement file work is unfinished. Its handoff will wait without changing workers or slots.'}
        }
        $job=@($Jobs|Where-Object{$_.Name -ceq "LDPlayer-$oldId"})|Select-Object -First 1
        $newJob=@($Jobs|Where-Object{$_.Name -ceq "LDPlayer-$newId"})|Select-Object -First 1
        if($job -and $newJob){
            
            
            if(-not $event.ConflictReported){
                $event|Add-Member NoteProperty ConflictReported $true -Force
                Write-TemplateStageManifest $file.FullName $event
                Write-Host "Replacement handoff $oldId -> $newId is paused: ID $newId already has a worker. Existing assignments and loading slots were kept; other emulators can continue."
            }
            continue
        }
        
        
        if(-not $job){$job=$newJob}
        if(-not $job){continue}
        $boot=$null;$oldRequest=Join-Path $Scheduler.Directory "boot-request-$oldId.json"
        if([IO.File]::Exists($oldRequest)){
            $request=ConvertFrom-Json ([IO.File]::ReadAllText($oldRequest))
            if($Scheduler.Active.ContainsKey($oldId)){
                $active=$Scheduler.Active[$oldId]
                if($active.Token -cne $request.Token){throw 'The old loading reservation changed before handoff.'}
                $boot=@{Id=$newId;Token=$active.Token;Phase='SettingUp';RestartRunning=$false}
                $Scheduler.Active[$newId]=$active;$Scheduler.Active.Remove($oldId)
                Write-RestoreQueueRecord (Join-Path $Scheduler.Directory "boot-request-$newId.json") $boot
                Write-RestoreQueueRecord (Join-Path $Scheduler.Directory "boot-grant-$newId.json") $active
            }
        }
        if(-not $boot -and $Scheduler.Active.ContainsKey($newId)){
            $active=$Scheduler.Active[$newId]
            $boot=@{Id=$newId;Token=$active.Token;Phase='SettingUp';RestartRunning=$false}
            Write-RestoreQueueRecord (Join-Path $Scheduler.Directory "boot-request-$newId.json") $boot
            Write-RestoreQueueRecord (Join-Path $Scheduler.Directory "boot-grant-$newId.json") $active
        }
        $Settings.LdPlayerIds=@($Settings.LdPlayerIds|ForEach-Object{if($_ -eq $oldId){$newId}else{$_}}|Sort-Object -Unique)
        $Settings.ExcludedLdPlayerIds=@(@($Settings.ExcludedLdPlayerIds)+@($oldId)|Where-Object{$_ -ne $newId}|Sort-Object -Unique)
        $Scheduler.InitialPending=@($Scheduler.InitialPending|ForEach-Object{if($_ -eq $oldId){$newId}else{$_}}|Sort-Object -Unique)
        $job.Name="LDPlayer-$newId"
        
        $values=Read-LauncherUiConfig $Settings.ConfigFilePath
        $excluded=@($values.ExcludedLdPlayerIds -split ','|Where-Object{$_ -match '^\d+$'}|ForEach-Object{[int]$_})
        $excluded=@(@($excluded)+@($oldId)|Where-Object{$_ -ne $newId}|Sort-Object -Unique)
        if(($excluded -join ',') -cne [string]$values.ExcludedLdPlayerIds){Set-LauncherConfigValues -Path $Settings.ConfigFilePath -Values @{ExcludedLdPlayerIds=($excluded -join ',')} -Automatic}
        foreach($path in @($oldRequest,(Join-Path $Scheduler.Directory "boot-grant-$oldId.json"))){if([IO.File]::Exists($path)){[IO.File]::Delete($path)}}
        $replacementPaths=Get-InstanceReplacementPaths $Settings;$journalPath=Join-Path $replacementPaths.State "replacement-$oldId.json"
        if([IO.File]::Exists($journalPath)){
            $journal=ConvertFrom-Json ([IO.File]::ReadAllText($journalPath))
            if([int]$journal.Version -ge 2){
                if($journal.Token -cne $event.Token -or $journal.NewId -ne $newId -or $journal.Phase -notin @('Ready','Completed')){throw 'The replacement handoff does not match a finished file transaction.'}
                $journal.Phase='Completed';$journal|Add-Member NoteProperty Step 'Completed' -Force
                $journal|Add-Member NoteProperty HandoffSession $Settings.ReplacementHandoffDirectory -Force
                $journal|Add-Member NoteProperty HandoffBoot $boot -Force
                Write-TemplateStageManifest $journalPath $journal
            }
        }
        Write-TemplateStageManifest (Join-Path $Settings.ReplacementHandoffDirectory "ack-$oldId.json") @{Token=$event.Token;NewId=$newId;Boot=$boot}
        [IO.File]::Delete($file.FullName)
        Write-Host "LDPlayer $oldId was excluded and replaced by $newId. Its worker, server assignment and loading reservation now use the new ID."
        }finally{if($commitHeld){$commitMutex.ReleaseMutex()};$commitMutex.Dispose()}
    }
}

function Get-TemplateDiskDescriptor {
    param([string]$Path)
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try{
        $reader=[IO.BinaryReader]::new($stream)
        if([Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) -cne 'KDMV'){throw 'Template disk is not a supported sparse VMDK.'}
        $stream.Position=28;$offset=$reader.ReadUInt64();$sectors=$reader.ReadUInt64()
        if($offset -gt 32768 -or $sectors -lt 1 -or $sectors -gt 256){throw 'Template disk descriptor bounds are unsupported.'}
        $stream.Position=[long]$offset*512;$raw=$reader.ReadBytes([int]$sectors*512)
        $text=[Text.Encoding]::ASCII.GetString($raw)
        if($text -notmatch '(?m)^createType="monolithicSparse"\s*$' -or $text -notmatch '(?m)^parentCID=ffffffff\s*$'){throw 'Differencing or multi-file disks cannot be used as the closed template.'}
        $image=[regex]::Matches($text,'(?m)^ddb\.uuid\.image\s*=\s*"(?<uuid>[^"\r\n]*)"')
        if($image.Count -gt 1){throw 'The disk contains duplicate image UUID entries.'}
        $uuid='';$kind='Unassigned'
        if($image.Count -eq 1 -and $image[0].Groups['uuid'].Value){
            $uuid=$image[0].Groups['uuid'].Value
            if($uuid -notmatch '^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'){throw 'The disk image UUID is malformed.'}
            $kind='VirtualBox'
        }else{
            $legacy=[regex]::Match($text,'(?m)^ddb\.uuid\s*=\s*"(?<uuid>[0-9a-fA-F -]+)"')
            if($legacy.Success){
                $hex=$legacy.Groups['uuid'].Value -replace '[ -]',''
                if($hex -notmatch '^[0-9a-fA-F]{32}$'){throw 'The VMware disk UUID is malformed.'}
                
                
                $uuid=$hex.Substring(0,8)+'-'+$hex.Substring(8,4)+'-'+$hex.Substring(12,4)+'-'+$hex.Substring(16,4)+'-'+$hex.Substring(20,12)
                $kind='VMware'
            }
        }
        return [pscustomobject]@{Offset=[long]$offset*512;Bytes=$raw;Text=$text;Uuid=$uuid;UuidKind=$kind}
    }finally{$stream.Dispose()}
}

function Get-TemplateTargetUuid {
    param([string]$SourceUuid,[int]$SourceIndex,[int]$TargetIndex)
    $value=$SourceUuid.Trim('{}')
    $sourceTail='0000'+$SourceIndex.ToString('x8')
    if($SourceIndex -lt 0 -or $TargetIndex -lt 0 -or $value -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'){throw 'The VM/disk host UUID is invalid.'}
    if($value.Substring(24) -ine $sourceTail){
        
        
        $hash=[Security.Cryptography.SHA256]::Create()
        try{$hex=[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($value.ToLowerInvariant()+'|'+$SourceIndex))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
        $value=$hex.Substring(0,8)+'-'+$hex.Substring(8,4)+'-'+$hex.Substring(12,4)+'-'+$hex.Substring(16,4)+'-'+$sourceTail
    }
    return $value.Substring(0,24)+'0000'+$TargetIndex.ToString('x8')
}

function Set-TemplateDiskHostUuid {
    param([string]$Path,[string]$Uuid)
    if($Uuid -notmatch '^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'){throw 'The new disk host UUID is invalid.'}
    $descriptor=Get-TemplateDiskDescriptor -Path $Path
    if($descriptor.UuidKind -eq 'VirtualBox' -and $descriptor.Uuid -ieq $Uuid){return}
    $text=$descriptor.Text.TrimEnd([char]0)
    $pattern='(?m)(^ddb\.uuid\.image\s*=\s*")[^"\r\n]*("[^\r\n]*)'
    $count=[regex]::Matches($text,$pattern).Count
    if($count -gt 1){throw 'The disk has duplicate host image UUID entries.'}
    $replacement=if($count -eq 1){[regex]::Replace($text,$pattern,('${1}'+$Uuid+'${2}'))}else{$text.TrimEnd([char[]]"`r`n")+"`n"+'ddb.uuid.image = "'+$Uuid+'"'+"`n"}
    $encoded=[Text.Encoding]::ASCII.GetBytes($replacement)
    if($encoded.Length -gt $descriptor.Bytes.Length){throw 'There is insufficient reserved descriptor space to assign a host UUID. The disk was not changed.'}
    $bytes=New-Object byte[] $descriptor.Bytes.Length;$encoded.CopyTo($bytes,0)
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Position=$descriptor.Offset;$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    if((Get-TemplateDiskDescriptor -Path $Path).Uuid -ine $Uuid){throw 'Copied disk UUID could not be verified.'}
}



function Write-TemplateStageManifest {
    param([string]$Path,$Manifest)
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        $stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Manifest|ConvertTo-Json -Depth 8));$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temporary,$Path,[NullString]::Value)}else{[IO.File]::Move($temporary,$Path)}
    }finally{if(Test-Path -LiteralPath $temporary){[IO.File]::Delete($temporary)}}
}





function Remove-TemplateStageDirectory {
    param([string]$Path,[string]$TargetDirectory)
    $full=[IO.Path]::GetFullPath($Path);$parent=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($TargetDirectory)).TrimEnd('\')+'\'
    $index=[IO.Path]::GetFileName($TargetDirectory) -replace '^leidian',''
    if(-not $full.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetDirectoryName($full).TrimEnd('\') -ine $parent.TrimEnd('\') -or [IO.Path]::GetFileName($full) -notmatch ('^\.codex-template-'+[regex]::Escape($index)+'-[0-9a-f]{32}$')){throw 'Refusing cleanup outside the exact template staging directory.'}
    if(Test-Path -LiteralPath $full){if((Get-Item -LiteralPath $full).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Refusing redirected staging-directory cleanup.'};[IO.Directory]::Delete($full,$true)}
}


function Get-TemplateDiskPlan {
    param([string]$InstallPath,[int]$SourceIndex,[int]$TargetIndex,[string]$TargetName)
    if($SourceIndex -lt 0 -or $TargetIndex -lt 0 -or $SourceIndex -eq $TargetIndex){throw 'The template cannot replace its own data disk.'}
    $vms=Join-Path ([IO.Path]::GetFullPath($InstallPath)) 'vms'
    $source=Join-Path $vms ('leidian'+$SourceIndex);$target=Join-Path $vms ('leidian'+$TargetIndex)
    foreach($path in @($vms,$source,$target)){
        if(-not (Test-Path -LiteralPath $path -PathType Container) -or ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'An expected instance directory is missing or redirected. No disk was replaced.'}
    }
    $sourceDisk=Join-Path $source 'data.vmdk';$targetDisk=Join-Path $target 'data.vmdk'
    $descriptor=Get-TemplateDiskDescriptor $sourceDisk
    $targetUuid='';$vmPath=Join-Path $target 'leidian.vbox'
    if(Test-Path -LiteralPath $vmPath){
        $vm=[xml]::new();$vm.Load($vmPath)
        $disk=$vm.SelectSingleNode('//*[local-name()="HardDisk" and @location="data.vmdk"]')
        if(-not $disk -or $disk.type -cne 'Normal'){throw 'Target data-disk registration is unsupported; its settings were kept unchanged.'}
        $targetUuid=$disk.uuid.Trim('{}')
    }elseif(Test-Path -LiteralPath $targetDisk){
        try{$targetUuid=(Get-TemplateDiskDescriptor $targetDisk).Uuid}catch{}
    }
    if(-not $targetUuid){$targetUuid=Get-TemplateTargetUuid $descriptor.Uuid $SourceIndex $TargetIndex}
    if($targetUuid -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'){throw 'Target disk identity could not be verified.'}
    foreach($path in @($sourceDisk,$targetDisk)){
        if((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Data-disk replacement does not follow redirected files.'}
    }
    return [pscustomobject]@{SourceIndex=$SourceIndex;TargetIndex=$TargetIndex;SourceDirectory=$source;TargetDirectory=$target;SourceDisk=$sourceDisk;TargetDisk=$targetDisk;TargetConfig=(Join-Path $vms ('config\leidian'+$TargetIndex+'.config'));TargetName=$TargetName;DataUuid=$targetUuid}
}

function New-TemplateDiskStage {
    param($Plan)
    $token=[guid]::NewGuid().ToString('N')
    $stage=Join-Path ([IO.Path]::GetDirectoryName($Plan.TargetDirectory)) ('.codex-template-'+$Plan.TargetIndex+'-'+$token)
    $ready=$false;$sourceLock=$null
    try{
        $sourceLock=[IO.File]::Open($Plan.SourceDisk,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $null=New-Item -ItemType Directory -Path $stage
        $stagedDisk=Join-Path $stage 'data.vmdk'
        [IO.File]::Copy($Plan.SourceDisk,$stagedDisk,$false)
        if((Get-Item -LiteralPath $stagedDisk).Length -ne $sourceLock.Length){throw 'Prepared data-disk length differs from the template.'}
        
        Set-TemplateDiskHostUuid $stagedDisk $Plan.DataUuid
        $manifest=[ordered]@{Kind='DataDisk';SourceIndex=$Plan.SourceIndex;TargetIndex=$Plan.TargetIndex;TargetName=$Plan.TargetName;Token=$token;Phase='Prepared';SourceDirectory=$Plan.SourceDirectory;TargetDirectory=$Plan.TargetDirectory;TargetConfig=$Plan.TargetConfig;SourceDataWriteTicks=(Get-Item -LiteralPath $Plan.SourceDisk).LastWriteTimeUtc.Ticks;DataLength=$sourceLock.Length;DataUuid=$Plan.DataUuid;DiskHash=(Get-FileHash -LiteralPath $stagedDisk -Algorithm SHA256).Hash}
        Write-TemplateStageManifest (Join-Path $stage 'transaction.json') $manifest
        $ready=$true
        return [pscustomobject]@{Directory=$stage;Manifest=$manifest}
    }finally{
        if($sourceLock){$sourceLock.Dispose()}
        if(-not $ready){Remove-TemplateStageDirectory $stage $Plan.TargetDirectory}
    }
}

function Complete-TemplateDiskStage {
    param($Stage,[scriptblock]$BeforeCommit,[scriptblock]$MarkAccountsPending)
    $manifest=$Stage.Manifest
    $targetRoot=[IO.Path]::GetFullPath($manifest.TargetDirectory)
    $vms=[IO.Path]::GetDirectoryName($targetRoot)
    $stageRoot=[IO.Path]::GetFullPath($Stage.Directory)
    if($manifest.Kind -cne 'DataDisk' -or $manifest.SourceIndex -eq $manifest.TargetIndex -or
       $targetRoot -ine (Join-Path $vms ('leidian'+$manifest.TargetIndex)) -or
       [IO.Path]::GetFullPath($manifest.SourceDirectory) -ine (Join-Path $vms ('leidian'+$manifest.SourceIndex)) -or
       [IO.Path]::GetDirectoryName($stageRoot) -ine $vms -or $manifest.Token -notmatch '^[0-9a-f]{32}$' -or
       [IO.Path]::GetFileName($stageRoot) -cne ('.codex-template-'+$manifest.TargetIndex+'-'+$manifest.Token)){
        throw 'Data-disk transaction paths do not match the exact source and target.'
    }
    foreach($path in @($vms,$stageRoot,$targetRoot,$manifest.SourceDirectory)){
        if(-not (Test-Path -LiteralPath $path -PathType Container) -or ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'A data-disk transaction directory is missing or redirected.'}
    }
    $targetDisk=Join-Path $targetRoot 'data.vmdk';$stagedDisk=Join-Path $stageRoot 'data.vmdk';$journal=Join-Path $stageRoot 'transaction.json'
    foreach($path in @($targetDisk,$stagedDisk)){
        if((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Data-disk replacement does not follow redirected files.'}
    }
    $null=& $BeforeCommit $manifest
    if(-not (Test-Path -LiteralPath $stagedDisk)){
        
        
        if($manifest.Phase -notin @('Replacing','Completed') -or -not (Test-Path -LiteralPath $targetDisk) -or
           (Get-FileHash -LiteralPath $targetDisk -Algorithm SHA256).Hash -cne $manifest.DiskHash){throw 'The prepared disk is missing and its completed replacement could not be verified.'}
    }else{
        if($manifest.Phase -notin @('Prepared','Replacing') -or (Get-Item -LiteralPath $stagedDisk).Length -ne $manifest.DataLength -or
           (Get-TemplateDiskDescriptor $stagedDisk).Uuid -ine $manifest.DataUuid){throw 'The prepared data disk could not be verified.'}
        $null=& $MarkAccountsPending $manifest
        $manifest.Phase='Replacing';Write-TemplateStageManifest $journal $manifest
        if(Test-Path -LiteralPath $targetDisk){[IO.File]::Replace($stagedDisk,$targetDisk,[NullString]::Value)}
        else{[IO.File]::Move($stagedDisk,$targetDisk)}
    }
    if((Get-Item -LiteralPath $targetDisk).Length -ne $manifest.DataLength -or (Get-TemplateDiskDescriptor $targetDisk).Uuid -ine $manifest.DataUuid){throw 'The replacement data disk could not be verified.'}
    $manifest.Phase='Completed';Write-TemplateStageManifest $journal $manifest
}

function Resolve-LauncherRecoverySource {
    param($Settings,[string]$Directory,[switch]$CheckClosed)
    $template=Get-LauncherTemplateFiles $Settings
    if($CheckClosed){
        $inventory=Get-BootInventory $Settings
        if(-not $inventory.ContainsKey(0) -or $inventory[0].ProcessId -gt 0 -or $inventory[0].AndroidStarted){throw 'LDPlayer 0 must be present and closed before using it as the template.'}
    }
    return $template.Root
}

function Get-LauncherTemplateFiles {
    param($Settings,[string]$Directory)
    $install=[string]$Settings.LdPlayerInstallPath
    if(-not $install -and $Settings.LdConsolePath){$install=[IO.Path]::GetDirectoryName([string]$Settings.LdConsolePath)}
    if(-not $install){$install='C:\LDPlayer\LDPlayer9'}
    $install=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($install.Trim('"')))
    $vms=Join-Path $install 'vms';$vm=Join-Path $vms 'leidian0';$config=Join-Path $vms 'config\leidian0.config'
    Assert-InstanceReplacementDirectory $vms $install
    $registration=$null
    foreach($name in @('leidian.vbox','leidian.vbox-prev','.joiner-recovered.vbox')){
        $candidate=Join-Path $vm $name;Assert-InstanceReplacementDirectory $candidate $vms
        if([IO.File]::Exists($candidate) -and (Get-Item -LiteralPath $candidate).Length -gt 0){$registration=$candidate;break}
    }
    if(-not $registration){throw 'LDPlayer 0 has no VM registration file in its installation folder. Open LDPlayer 0 once to let LDPlayer generate it, then close it before using it as the template.'}
    $files=@((Join-Path $vm 'data.vmdk'),(Join-Path $vm 'sdcard.vmdk'),$registration,$config)
    foreach($path in $files){
        Assert-InstanceReplacementDirectory $path $vms
        if(-not [IO.File]::Exists($path) -or (Get-Item -LiteralPath $path).Length -le 0){throw "Installed LDPlayer 0 is missing a required template file: $path"}
    }
    return @{Root=$vm;VmDirectory=$vm;ConfigFile=$config;Files=$files;DataFile=$files[0];SdFile=$files[1];VmFile=$files[2]}
}

function Get-PendingTemplateStage {
    $vms=Join-Path ([IO.Path]::GetFullPath($Config.LdPlayerInstallPath)) 'vms'
    $stages=@(Get-ChildItem -LiteralPath $vms -Directory -Filter ('.codex-template-'+$InstanceIndex+'-*'))
    if($stages.Count -gt 1){throw 'Multiple unfinished disk copies exist for this target. Waiting without replacing anything.'}
    if(-not $stages.Count){return $null}
    $stagePath=$stages[0].FullName;$journal=Join-Path $stagePath 'transaction.json'
    if(-not (Test-Path -LiteralPath $journal)){throw 'An unfinished disk preparation needs inspection. The target disk was kept unchanged.'}
    $manifest=ConvertFrom-Json ([IO.File]::ReadAllText($journal))
    if($manifest.Kind -cne 'DataDisk'){throw 'An unfinished whole-instance replacement belongs to the earlier version. Disk-only recovery will not execute it.'}
    if($manifest.SourceIndex -ne $Config.RecoveryTemplateId -or $manifest.TargetIndex -ne $InstanceIndex -or $manifest.SourceIndex -eq $manifest.TargetIndex -or
       [IO.Path]::GetFullPath($manifest.SourceDirectory) -ine (Join-Path $vms ('leidian'+$Config.RecoveryTemplateId)) -or
       [IO.Path]::GetFullPath($manifest.TargetDirectory) -ine (Join-Path $vms ('leidian'+$InstanceIndex)) -or
       [IO.Path]::GetFullPath($manifest.TargetConfig) -ine (Join-Path $vms ('config\leidian'+$InstanceIndex+'.config')) -or
       $manifest.Token -notmatch '^[0-9a-f]{32}$' -or $stages[0].Name -cne ('.codex-template-'+$InstanceIndex+'-'+$manifest.Token) -or
       $manifest.DiskHash -notmatch '^[0-9a-fA-F]{64}$' -or $manifest.Phase -notin @('Prepared','Replacing','Completed')){throw 'Prepared disk transaction does not match this exact target. Nothing was replaced.'}
    foreach($path in @($stagePath,$manifest.SourceDirectory,$manifest.TargetDirectory)){
        if((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Redirected disk transaction directories are unsupported.'}
    }
    return [pscustomobject]@{Directory=$stagePath;Manifest=$manifest}
}

function Get-TemplateAccountResetPath {
    return Join-Path $Config.RestoreStateDirectory ('template-accounts-'+$InstanceIndex+'.json')
}





function Invoke-TemplateEmulatorRecovery {
    if($InstanceIndex -eq $Config.RecoveryTemplateId){throw 'The reserved template cannot be a recovery target.'}
    $null=Resolve-LauncherRecoverySource -Settings $Config -CheckClosed
    $stage=Get-PendingTemplateStage
    $target=Get-RestoreTargetInfo -Id $InstanceIndex
    if($target.Running){
        if(Test-EmulatorResponsive){
            try{$null=Save-LoadedEmulatorAppData -BootIdentity $script:CookieBootIdentity -Force}catch{}
            try{Close-AppsBeforeEmulatorRestart}catch{Write-FlowStatus 'App cleanup was unavailable; closing only the affected emulator.'}
        }
        $null=Invoke-Ld -Arguments @('quit','--index',"$InstanceIndex")
    }
    $deadline=[datetime]::UtcNow.AddSeconds([math]::Max(120,$Config.LdPlayerOpenTimeout));$stopped=0
    while($stopped -lt 2){
        if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Stopped before data-disk recovery.')}
        $current=Get-RestoreTargetInfo -Id $InstanceIndex
        if($current.Name -cne $target.Name){throw 'Target identity changed; disk replacement postponed.'}
        if($current.Running){$stopped=0}else{$stopped++}
        if([datetime]::UtcNow -gt $deadline){throw 'The affected emulator did not finish closing. Its disk was not replaced.'}
        if($stopped -lt 2){Start-Sleep -Seconds 1}
    }
    Enter-EmulatorLoadingSlot
    try{
        Enter-EmulatorRestoreSlot
        $script:RestoreQueueRecord.Phase='Restoring'
        Write-RestoreQueueRecord $script:RestoreQueuePath $script:RestoreQueueRecord
        if(-not $stage){
            Write-FlowStatus ('Preparing only data.vmdk from closed template '+$Config.RecoveryTemplateId+'...')
            $plan=Get-TemplateDiskPlan $Config.LdPlayerInstallPath $Config.RecoveryTemplateId $InstanceIndex $target.Name
            $stage=New-TemplateDiskStage $plan
        }
        $before={param($manifest)
            if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Stopped before disk replacement. The prepared disk was preserved.')}
            if((Get-RestoreTargetInfo -Id $Config.RecoveryTemplateId).Running){throw 'Template was opened. Close it before disk recovery can continue.'}
            $current=Get-RestoreTargetInfo -Id $InstanceIndex
            if($current.Running -or $current.Name -cne $manifest.TargetName){throw 'Target started or changed. Disk replacement postponed.'}
            $currentPlan=Get-TemplateDiskPlan $Config.LdPlayerInstallPath $Config.RecoveryTemplateId $InstanceIndex $current.Name
            if($currentPlan.DataUuid -ine $manifest.DataUuid){throw 'Target disk registration changed. Its settings were left untouched.'}
            if($manifest.Phase -eq 'Prepared' -and (Get-Item -LiteralPath (Join-Path $manifest.SourceDirectory 'data.vmdk')).LastWriteTimeUtc.Ticks -ne $manifest.SourceDataWriteTicks){throw 'Template changed after disk preparation. The target was kept unchanged.'}
        }
        $mark={param($manifest)
            $path=Get-TemplateAccountResetPath
            if(Test-Path -LiteralPath $path){
                $existing=ConvertFrom-Json ([IO.File]::ReadAllText($path))
                if($existing.Token -eq $manifest.Token){return}
            }
            Write-TemplateStageManifest $path @{TargetIndex=$InstanceIndex;SourceIndex=$Config.RecoveryTemplateId;Token=$manifest.Token;Packages=@($Config.GamePackages);Cleared=@()}
        }
        Write-FlowStatus 'Replacing only data.vmdk. Keeping this instance and all its other files and settings.'
        Complete-TemplateDiskStage -Stage $stage -BeforeCommit $before -MarkAccountsPending $mark
        Remove-TemplateStageDirectory $stage.Directory $stage.Manifest.TargetDirectory
        $script:PendingEmulatorRestore=$null;$script:FlowTimeoutCounts=@{};$script:RequiredAppsCheckedKey=$null;$script:StartupFailureCount=0;$script:VpnVerifiedBoot=0;$script:CurrentEmulatorInstance=$null;$script:InitialCookieBoot=0;$script:InitialCookieChecks=@{};$script:CookieAuthenticationCache=@{};$script:CookieSlotPause=$null
        Reset-PackageCheckRecovery
        $script:LoadedCookieCaptures=@{};$script:LoadedAppDataCaptures=@{};$script:WaitingAppDataCookies=@{};$script:GameCookiePassResults=@{};$script:CookieAdbSerial=$null
        Write-FlowStatus 'Data-disk replacement completed. Restarting the full cookie, VPN and game flow.'
    }finally{Exit-EmulatorRestoreSlot}
    if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Stopped after data-disk replacement finished.')}
    Start-Sleep -Seconds ([math]::Max(1,$Config.InstanceRelaunchDelay))
    $script:RecoveringEmulator=$true
    Invoke-SpacedEmulatorLaunch -Relaunch
}

function Resolve-LauncherRestoreBackup {
    param($Settings,[string]$Directory)
    $directory=[IO.Path]::GetFullPath($Directory)
    $files=@(Get-ChildItem -LiteralPath $directory -Filter '*.ldbk' -File | Sort-Object Name)
    if($Settings.RestoreBackupFile){
        $name=[string]$Settings.RestoreBackupFile
        if([IO.Path]::GetFileName($name) -cne $name -or [IO.Path]::GetExtension($name) -ine '.ldbk'){throw 'RestoreBackupFile must be the name of an .ldbk file beside this tool.'}
        $files=@($files|Where-Object{$_.Name -ieq $name})
    }
    if($files.Count -eq 0){throw 'No restore backup found. Put a nonempty .ldbk file beside the tool before starting.'}
    if($files.Count -gt 1){throw 'Several .ldbk backups were found. Select RestoreBackupFile in Settings before starting.'}
    if($files[0].Length -le 0){throw 'The selected .ldbk backup is empty.'}
    return $files[0].FullName
}

function Set-EmulatorRestoreRequired {
    param([string]$Reason)
    $script:PendingEmulatorRestore=$Reason
    $failure=[InvalidOperationException]::new($Reason+' The affected emulator will be closed and recovered using the configured source.')
    $failure.Data['RestoreRequired']=$true
    throw $failure
}

function Register-FlowStageTimeout {
    param([ValidateSet('Cloudflare','Instance','Game')][string]$Stage)
    
    if($Stage -in @('Game','Instance')){return}
    if(-not $Config.RestoreBackupPath){return}
    if($null -eq $script:FlowTimeoutCounts){$script:FlowTimeoutCounts=@{}}
    $key=$Stage
    if($Stage -eq 'Game'){$key+='|'+$Config.GamePackage}
    $limit=switch($Stage){'Cloudflare'{$Config.CloudflareTimeoutLimit};'Instance'{$Config.InstanceOpenTimeoutLimit};'Game'{$Config.GameOpenTimeoutLimit}}
    if(-not $limit){return}
    $script:FlowTimeoutCounts[$key]=1+[int]$script:FlowTimeoutCounts[$key]
    Write-FlowStatus ("$Stage timeout $($script:FlowTimeoutCounts[$key])/$limit.")
    if($script:FlowTimeoutCounts[$key] -ge $limit){Set-EmulatorRestoreRequired -Reason ("$Stage reached its timeout limit ($limit).")}
}

function Reset-FlowStageTimeout {
    param([string]$Stage)
    if($null -eq $script:FlowTimeoutCounts){return}
    $key=$Stage;if($Stage -eq 'Game'){$key+='|'+$Config.GamePackage}
    $script:FlowTimeoutCounts.Remove($key)
}

function Get-AndroidPackageInventory {
    param([datetime]$Deadline)
    $command='shell sh -c ''echo LAUNCHER_PM_BEGIN; echo LAUNCHER_PM_BOOT:$(getprop sys.boot_completed); pm list packages; r=$?; echo LAUNCHER_PM_STATUS:$r; echo LAUNCHER_PM_END'''
    $reply=(Invoke-Android $command -TimeoutSeconds (Get-CommandBudget $Deadline)) -join "`n"
    $lines=@($reply -split '\r?\n'|ForEach-Object{$_.Trim()}|Where-Object{$_})
    $begin=@($lines|Where-Object{$_ -ceq 'LAUNCHER_PM_BEGIN'});$end=@($lines|Where-Object{$_ -ceq 'LAUNCHER_PM_END'})
    if($begin.Count -ne 1 -or $end.Count -ne 1){return $null}
    $first=[array]::IndexOf($lines,'LAUNCHER_PM_BEGIN');$last=[array]::IndexOf($lines,'LAUNCHER_PM_END')
    if($last -le $first+3){return $null}
    $body=@($lines[($first+1)..($last-1)])
    if($body[0] -cne 'LAUNCHER_PM_BOOT:1' -or $body[-1] -cne 'LAUNCHER_PM_STATUS:0'){return $null}
    $installed=[Collections.Hashtable]::new([StringComparer]::Ordinal)
    foreach($line in $body[1..($body.Count-2)]){
        if($line -cmatch '^package:([A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)*)$'){$installed[$Matches[1]]=$true}
        else{return $null}
    }
    if(-not $installed.Count){return $null}
    return [pscustomobject]@{Installed=$installed}
}

function Get-RequiredPackagePathsBatch {
    param([string[]]$Packages,[datetime]$Deadline)
    $parts=@('echo LAUNCHER_PATH_BEGIN','echo LAUNCHER_PATH_BOOT:$(getprop sys.boot_completed)')
    foreach($package in $Packages){
        if($package -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$'){throw 'Invalid required package name.'}
    }
    
    
    $parts+='for p in '+($Packages -join ' ')+'; do echo LAUNCHER_APP_BEGIN:$p; pm path $p; r=$?; echo LAUNCHER_APP_END:$p:$r; done'
    $parts+='echo LAUNCHER_PATH_END'
    $command="shell sh -c '"+($parts -join '; ')+"'"
    $reply=(Invoke-Android $command -TimeoutSeconds (Get-CommandBudget $Deadline)) -join "`n"
    $lines=@($reply -split '\r?\n'|ForEach-Object{$_.Trim()}|Where-Object{$_})
    $script:LastPackageReplySummary='lines='+$lines.Count+'; begin='+@($lines|Where-Object{$_ -ceq 'LAUNCHER_PATH_BEGIN'}).Count+'; end='+@($lines|Where-Object{$_ -ceq 'LAUNCHER_PATH_END'}).Count+'; boot='+(@($lines|Where-Object{$_ -like 'LAUNCHER_PATH_BOOT:*'}) -join ',')
    if(@($lines|Where-Object{$_ -ceq 'LAUNCHER_PATH_BEGIN'}).Count -ne 1 -or @($lines|Where-Object{$_ -ceq 'LAUNCHER_PATH_END'}).Count -ne 1){return $null}
    $first=[array]::IndexOf($lines,'LAUNCHER_PATH_BEGIN');$last=[array]::IndexOf($lines,'LAUNCHER_PATH_END')
    if($last -le $first+1 -or $lines[$first+1] -cnotmatch '^LAUNCHER_PATH_BOOT:(?:0|1)?$'){return $null}
    $bootReady=$lines[$first+1] -ceq 'LAUNCHER_PATH_BOOT:1'
    $cursor=$first+2;$missing=New-Object 'System.Collections.Generic.List[string]'
    foreach($package in $Packages){
        if($cursor -ge $last -or $lines[$cursor] -cne ('LAUNCHER_APP_BEGIN:'+$package)){return $null}
        $cursor++;$pathCount=0
        while($cursor -lt $last -and $lines[$cursor] -cmatch '^package:/.*\.apk$'){$pathCount++;$cursor++}
        $endPattern='^LAUNCHER_APP_END:'+ [regex]::Escape($package) + ':([01])$'
        if($cursor -ge $last -or $lines[$cursor] -cnotmatch $endPattern){return $null}
        $exitCode=[int]$Matches[1]
        if($pathCount -gt 0 -and $exitCode -ne 0){return $null}
        if($pathCount -eq 0){$missing.Add($package)}
        $cursor++
    }
    if($cursor -ne $last){return $null}
    
    
    if($missing.Count -gt 0 -and -not $bootReady){return $null}
    return [pscustomobject]@{Missing=$missing.ToArray();BootCompleted=$bootReady}
}

function Get-RequiredPackagePaths {
    param([string[]]$Packages,[datetime]$Deadline)
    $script:LastPackageCheckDetail=''
    $result=Get-RequiredPackagePathsBatch -Packages $Packages -Deadline $Deadline
    if($null -ne $result){return $result}
    Write-FlowStatus ('Incomplete batch package reply ('+$script:LastPackageReplySummary+'). Checking each required APK path directly; no missing app was assumed.')
    foreach($package in $Packages){
        if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Stopped during package verification.')}
        try{
            $reply=(Invoke-Android ('shell pm path '+$package) -TimeoutSeconds (Get-CommandBudget $Deadline)) -join "`n"
            $lines=@($reply -split '\r?\n'|ForEach-Object{$_.Trim()}|Where-Object{$_})
            if(-not $lines.Count -or @($lines|Where-Object{$_ -cnotmatch '^package:/[^\r\n]+[.]apk$'}).Count){
                $script:LastPackageCheckDetail="Direct APK-path query for $package did not return a complete positive response. No missing app was assumed."
                return $null
            }
        }catch [System.Management.Automation.PipelineStoppedException]{throw}
        catch [OperationCanceledException]{throw}
        catch{$script:LastPackageCheckDetail='Direct package response unavailable: '+$_.Exception.Message;return $null}
    }
    Write-FlowStatus 'All required apps were confirmed by their direct APK paths.'
    return [pscustomobject]@{Missing=@();BootCompleted=$null}
}

function Reset-PackageCheckRecovery {
    $script:PackageCheckFailureCount=0
    $script:PackageCheckRecoveryCount=0
    $script:PackageCheckRestartPending=$false
}

function New-PackageCheckRestartError {
    $failure=[InvalidOperationException]::new('Package checks reached their failure limit. A new-instance replacement is pending.')
    $failure.Data['PackageCheckUnavailable']=$true
    $failure.Data['InstanceReplacementRequired']=$true
    return $failure
}

function Register-PackageCheckFailure {
    $limit=2;if($Config.PackageCheckFailuresBeforeRestart){$limit=[int]$Config.PackageCheckFailuresBeforeRestart}
    $script:PackageCheckFailureCount=1+[int]$script:PackageCheckFailureCount
    Write-FlowStatus "Installed-package verification did not pass ($($script:PackageCheckFailureCount)/$limit)."
    if($script:PackageCheckFailureCount -lt $limit){return}
    $script:PackageCheckFailureCount=0
    $script:RequiredAppsCheckedKey=$null
    $script:PackageCheckRestartPending=$false;$script:PendingInstanceReplacement=$true
    Write-FlowStatus 'Package checks reached their limit. Creating a new instance from the affected emulator disks, VM registration and config.'
    throw (New-PackageCheckRestartError)
}

function Confirm-RequiredEmulatorApps {
    param([int]$BootIdentity)
    if(-not $Config.RestoreBackupPath){return}
    if($script:PendingInstanceReplacement -or $script:PackageCheckRestartPending){throw (New-PackageCheckRestartError)}
    $required=@($CloudflarePackage)+@($Config.GamePackages)
    $key="$BootIdentity|$($required -join ',')"
    if($script:RequiredAppsCheckedKey -ceq $key){return}
    $limit=2;if($Config.PackageCheckFailuresBeforeRestart){$limit=$Config.PackageCheckFailuresBeforeRestart}
    $delay=10;if($Config.PackageCheckRetryDelay){$delay=$Config.PackageCheckRetryDelay}
    while($true){
        if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Stopped during package verification.')}
        $attempt=1+[int]$script:PackageCheckFailureCount
        Write-FlowStatus "Checking installed app packages ($attempt/$limit for this load): $($required -join ', ')"
        $found=$false;$detail='Android did not return a complete package response; no missing app was assumed.'
        $deadline=[datetime]::UtcNow.AddSeconds($Config.CommandTimeout)
        try{
            
            
            $paths=Get-RequiredPackagePaths -Packages $required -Deadline $deadline
            if($null -ne $paths){
                $found=$paths.Missing.Count -eq 0
                if(-not $found){$detail='Required packages were not found: '+($paths.Missing -join ', ')}
            }elseif($script:LastPackageCheckDetail){$detail=$script:LastPackageCheckDetail}
        }catch [System.Management.Automation.PipelineStoppedException]{throw}
        catch [OperationCanceledException]{throw}
        catch{$detail='Package response unavailable: '+$_.Exception.Message}
        if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Stopped after reading package status; no recovery was queued.')}
        if($found){
            Reset-PackageCheckRecovery
            $script:RequiredAppsCheckedKey=$key
            Write-FlowStatus 'All required app packages are installed. This load will not be checked again.'
            return
        }
        Write-FlowStatus $detail
        
        Register-PackageCheckFailure
        Write-FlowStatus "Waiting $delay seconds before the next package check..."
        Wait-FlowPause $delay
    }
}

function Invoke-PackageCheckRecovery {
    param($Failure)
    Write-FlowStatus ('Package check unavailable: '+$Failure.Message)
    try{
        if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Stopped before package-check recovery.')}
        $script:PendingInstanceReplacement=$true
        Invoke-InstanceReplacement
    }
    catch [System.Management.Automation.PipelineStoppedException]{throw}
    catch [OperationCanceledException]{throw}
    catch{if($_.Exception.Data['RestoreRequired']){throw};Write-FlowStatus ('Package-check recovery will retry without opening game apps: '+$_.Exception.Message)}
    Write-FlowStatus 'Waiting for Android package verification. No game app will be opened or restarted during this wait.'
    return 'WaitingForPackages'
}

function Get-RestoreTargetInfo {
    param([int]$Id,[switch]$AllowMissing)
    $listing=Invoke-Ld -Arguments @('list2')
    foreach($line in ($listing -split '\r?\n')){
        if($line.Trim() -match '^(\d+),(.*?),(-?\d+),(-?\d+),([01]),(-?\d+),(-?\d+)(?:,(\d+),(\d+),(\d+))?$' -and [int]$Matches[1] -eq $Id){
            return [pscustomobject]@{Id=$Id;Name=$Matches[2];Running=($Matches[5] -eq '1' -or [long]$Matches[3] -gt 0 -or [long]$Matches[4] -gt 0 -or [int]$Matches[6] -gt 0 -or [int]$Matches[7] -gt 0)}
        }
    }
    if($AllowMissing){
        
        foreach($line in ($listing -split '\r?\n')){
            if($line.Trim() -match '^(\d+),(.*?),(-?\d+),(-?\d+),([01]),(-?\d+),(-?\d+)(?:,(\d+),(\d+),(\d+))?$' -and [int]$Matches[1] -eq $Config.RecoveryTemplateId){return $null}
        }
        throw 'Instance inventory could not confirm the template. No target was assumed missing.'
    }
    throw "LDPlayer $Id is missing from the instance inventory. No other instance will be replaced."
}

function Test-RestoreProcessAlive {
    param([int]$ProcessId,[long]$StartTicks=0)
    if($ProcessId -le 0){return $false}
    try{$process=Get-Process -Id $ProcessId -ErrorAction Stop;if($StartTicks -gt 0){return ($process.StartTime.ToUniversalTime().Ticks -eq $StartTicks)};return $true}catch{return $false}
}

function Get-RestoreQueueRecords {
    if(-not $Config.RestoreStateDirectory -or -not (Test-Path -LiteralPath $Config.RestoreStateDirectory)){return @()}
    $records=@()
    foreach($file in @(Get-ChildItem -LiteralPath $Config.RestoreStateDirectory -Filter 'restore-*.json' -File)){
        try{
            $record=ConvertFrom-Json ([IO.File]::ReadAllText($file.FullName))
            $record|Add-Member NoteProperty StatePath $file.FullName -Force
            $ownerAlive=Test-RestoreProcessAlive -ProcessId $record.WorkerPid -StartTicks $record.WorkerStartTicks
            $nativeAlive=Test-RestoreProcessAlive -ProcessId $record.NativePid -StartTicks $record.NativeStartTicks
            if($record.Phase -eq 'Restoring' -and $record.NativePid -gt 0 -and -not $nativeAlive -and -not $ownerAlive){Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue;continue}
            if(-not $ownerAlive -and -not $nativeAlive){
                if($record.Phase -eq 'Restoring' -and -not $record.NativePid){
                    
                    
                    try{
                        $possible=@(Get-CimInstance Win32_Process -ErrorAction Stop|Where-Object{$_.ExecutablePath -ieq $Config.LdConsolePath -and $_.CommandLine -match '(?i)\b(restore|remove)\b'})
                        if($possible.Count){$records+=$record;continue}
                    }catch{$records+=$record;continue}
                }
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
                continue
            }
            $records+=$record
        }catch{
            
            throw 'Instance replacement queue could not be verified. Waiting without starting another replacement.'
        }
    }
    return $records
}

function Write-RestoreQueueRecord {
    param([string]$Path,$Record)
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try{
        [IO.File]::WriteAllText($temporary,($Record|ConvertTo-Json -Compress))
        if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temporary,$Path,[NullString]::Value)}else{[IO.File]::Move($temporary,$Path)}
    }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}}
}

function Enter-EmulatorRestoreSlot {
    if(-not (Test-Path -LiteralPath $Config.RestoreStateDirectory)){$null=New-Item -ItemType Directory -Path $Config.RestoreStateDirectory -Force}
    $token=[guid]::NewGuid().ToString('N')
    $path=Join-Path $Config.RestoreStateDirectory ("restore-$InstanceIndex-$token.json")
    $owner=Get-Process -Id $PID
    $record=@{InstanceId=$InstanceIndex;WorkerPid=$PID;WorkerStartTicks=$owner.StartTime.ToUniversalTime().Ticks;NativePid=0;NativeStartTicks=0;Phase='Waiting';RequestedTicks=[datetime]::UtcNow.Ticks}
    Write-RestoreQueueRecord -Path $path -Record $record
    $script:RestoreQueuePath=$path;$script:RestoreQueueRecord=$record
    $mutex=New-Object Threading.Mutex $false,$Config.RestoreMutexName
    try{
        while($true){
            if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Stopped before instance replacement.')}
            $held=$false
            try{
                try{$held=$mutex.WaitOne(1000)}catch [Threading.AbandonedMutexException]{$held=$true}
                if($held){
                    $all=@(Get-RestoreQueueRecords)
                    $active=@($all|Where-Object{$_.Phase -in @('Granted','Restoring')})
                    $activeIds=@($active|ForEach-Object{[int]$_.InstanceId})
                    $waiting=@($all|Where-Object{$_.Phase -eq 'Waiting' -and [int]$_.InstanceId -notin $activeIds}|Sort-Object InstanceId,RequestedTicks)
                    $limit=Get-InstanceReplacementLimit $Config
                    $free=[math]::Max(0,$limit-$active.Count)
                    $eligible=@($waiting|Select-Object -First $free)
                    if(@($eligible|Where-Object{$_.StatePath -ceq $path}).Count -gt 0){
                        $record.Phase='Granted';Write-RestoreQueueRecord -Path $path -Record $record
                        Write-FlowStatus "Received an instance replacement slot ($($active.Count+1)/$limit)."
                        return
                    }
                }
            }finally{if($held){$mutex.ReleaseMutex()}}
            Start-Sleep -Seconds 1
        }
    }finally{$mutex.Dispose()}
}

function Get-InstanceReplacementLimit {
    param($Settings=$Config)
    $value=$Settings.MaxReplacingInstances
    if(-not $value){$value=$Settings.MaxRestoringInstances}
    if(-not $value){$value=1}
    return [math]::Max(1,[int]$value)
}

function Exit-EmulatorRestoreSlot {
    if($script:RestoreQueueRecord -and (Test-RestoreProcessAlive -ProcessId $script:RestoreQueueRecord.NativePid -StartTicks $script:RestoreQueueRecord.NativeStartTicks)){return}
    if($script:RestoreQueuePath -and (Test-Path -LiteralPath $script:RestoreQueuePath)){Remove-Item -LiteralPath $script:RestoreQueuePath -Force -ErrorAction SilentlyContinue}
    $script:RestoreQueuePath=$null;$script:RestoreQueueRecord=$null
}

function Invoke-LdPlayerRestoreCommand {
    param([string]$BackupPath)
    $sourceLock=[IO.File]::Open($BackupPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $process=$null
    try{
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=$Config.LdConsolePath
        $info.Arguments=(@('restore','--index',"$InstanceIndex",'--file',$BackupPath)|ForEach-Object{ConvertTo-NativeArgument $_}) -join ' '
        $info.WorkingDirectory=$Config.LdPlayerInstallPath;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $script:RestoreQueueRecord.Phase='Restoring'
        Write-RestoreQueueRecord -Path $script:RestoreQueuePath -Record $script:RestoreQueueRecord
        $process=New-Object Diagnostics.Process;$process.StartInfo=$info
        if(-not $process.Start()){throw 'The LDPlayer restore command did not start.'}
        $script:RestoreQueueRecord.NativePid=$process.Id;$script:RestoreQueueRecord.NativeStartTicks=$process.StartTime.ToUniversalTime().Ticks
        Write-RestoreQueueRecord -Path $script:RestoreQueuePath -Record $script:RestoreQueueRecord
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        
        while(-not $process.WaitForExit(1000)){}
        $output=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult()
        if($output.Trim()){Write-FlowStatus ($output.Trim())}
        if($process.ExitCode -ne 0 -or $errorText.Trim() -or ($output+"`n"+$errorText) -match '(?im)^\s*(error\b|failed\b|failure\b|fatal\b|exception\b|invalid\b|cannot\b|can\x27t\b|not supported\b|restore\s+(failed|error)\b|(-1|-2)\s*$|错误|失败|失敗)'){
            throw 'LDPlayer reported a restore failure. The instance will stay in the recovery loop.'
        }
    }finally{if($process){$process.Dispose()};$sourceLock.Dispose()}
}

function Invoke-PendingEmulatorRestore {
    if(-not $script:PendingEmulatorRestore){return}
    Assert-PoolSetupTurn
    Write-FlowStatus ('Recovery queued with template 0 data and a new emulator ID: '+$script:PendingEmulatorRestore)
    $script:PendingInstanceReplacement=$true
    Invoke-InstanceReplacement -FreshData
}
function Get-ActiveRestoreInstanceIds {
    return @((Get-RestoreQueueRecords)|Where-Object{$_.Phase -in @('Granted','Restoring')}|ForEach-Object{[int]$_.InstanceId})
}


function Get-LauncherRunPaths {
    param([string]$Directory)
    $directory=[IO.Path]::GetFullPath($Directory)
    $hash=[Security.Cryptography.SHA256]::Create()
    try {$digest=[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($directory.ToLowerInvariant()))).Replace('-','')} finally {$hash.Dispose()}
    return @{MutexName=('Local\CodexJoinerRun-'+$digest.Substring(0,24));RecordPath=(Join-Path $directory 'launcher-running.json')}
}

function Test-LauncherRunning {
    param([string]$Directory)
    $paths=Get-LauncherRunPaths $Directory
    $mutex=$null; $held=$false
    try {
        try {$mutex=[Threading.Mutex]::OpenExisting($paths.MutexName)} catch [Threading.WaitHandleCannotBeOpenedException] {return $false}
        try {$held=$mutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$held=$true}
        return (-not $held)
    } finally {if($held){$mutex.ReleaseMutex()};if($mutex){$mutex.Dispose()}}
}

function Read-LauncherRunRecord {
    param([string]$Directory)
    $paths=Get-LauncherRunPaths $Directory
    try {
        $record=ConvertFrom-Json ([IO.File]::ReadAllText($paths.RecordPath))
        $runPath=[IO.Path]::GetFullPath([string]$record.RunDirectory)
        $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $runPath.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($runPath) -notmatch '^launcher-[0-9a-f]{32}$') {return $null}
        return [pscustomobject]@{RunDirectory=$runPath;StopFile=(Join-Path $runPath 'stop.request');ProcessId=[int]$record.ProcessId}
    } catch {return $null}
}

function Set-LauncherConfigValues {
    param([string]$Path,[hashtable]$Values,[switch]$Automatic,[switch]$ReplaceServerLinks)
    $hash=[Security.Cryptography.SHA256]::Create()
    try{$key=[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Path).ToLowerInvariant()))).Replace('-','').Substring(0,24)}finally{$hash.Dispose()}
    $mutex=New-Object Threading.Mutex $false,('Local\LauncherSettings-'+$key);$held=$false
    try{
        try{$held=$mutex.WaitOne(30000)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not $held){throw 'Settings are busy; the automatic update will retry.'}
        Write-LauncherConfigValues -Path $Path -Values $Values -Automatic:$Automatic -ReplaceServerLinks:$ReplaceServerLinks
    }finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
}

function Write-LauncherConfigValues {
    param([string]$Path,[hashtable]$Values,[switch]$Automatic,[switch]$ReplaceServerLinks)
    if (-not $Automatic -and (Test-LauncherRunning -Directory ([IO.Path]::GetDirectoryName($Path)))) {throw 'Stop the tool before changing settings.'}
    $seen=@{}; $lines=New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\s*([^#;=]+)=(.*)$') {
            $name=ConvertTo-LauncherConfigKey $Matches[1].Trim()
            if ($ReplaceServerLinks -and ($name -eq 'ServerLink' -or $name -match '^ServerLink\.[1-9][0-9]*$')) {continue}
            if ($Values.ContainsKey($name)) {
                $value=[string]$Values[$name]
                if ($value -match '[\r\n]') {throw 'Settings must have one value per line.'}
                $lines.Add($name+'='+$value); $seen[$name]=$true; continue
            }
        }
        $lines.Add($line)
    }
    foreach ($name in $Values.Keys) {if(-not $seen.ContainsKey($name)){$value=[string]$Values[$name];if($value -match '[\r\n]'){throw 'Settings must have one value per line.'};$lines.Add($name+'='+$value)}}
    $temporary=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        [IO.File]::WriteAllText($temporary,($lines -join "`r`n")+"`r`n",[Text.UTF8Encoding]::new($false))
        [IO.File]::Replace($temporary,$Path,[NullString]::Value)
    } finally {if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}}
}

function Test-GameCookieOverwriteEnabled {
    if ($Config.CookieOverwriteStatePath) {return (Test-Path -LiteralPath $Config.CookieOverwriteStatePath -PathType Leaf)}
    return ($Config.OverwriteExistingCookies -eq 1)
}

function Initialize-CookieCheckTracking {
    param($Settings,[string]$Directory)
    $Settings.CookieCheckStateDirectory=$Directory
    $Settings.CookieUiStateDirectory=$Directory
    $Settings.CookieOverwriteStatePath=Join-Path $Directory 'cookie-overwrite.enabled'
    if ($Settings.OverwriteExistingCookies -eq 1) {[IO.File]::WriteAllText($Settings.CookieOverwriteStatePath,'1')}
}

function Complete-InitialCookieChecks {
    param([object[]]$Results)
    if (-not $Config.CookieCheckStateDirectory -or $Results.Count -ne $Config.GamePackages.Count) {return}
    if (@($Results|Where-Object{$null -eq $_ -or $_.Unavailable}).Count -gt 0) {return}
    $path=Join-Path $Config.CookieCheckStateDirectory ("cookie-checked-$InstanceIndex.json")
    if (-not (Test-Path -LiteralPath $path)) {
        [IO.File]::WriteAllText($path,(@{InstanceId=$InstanceIndex;Packages=$Config.GamePackages;CheckedUtc=[datetime]::UtcNow.ToString('o')}|ConvertTo-Json -Compress))
    }
}

function Update-CookieOverwriteTracking {
    param($Settings)
    if(-not $Settings.CookieCheckStateDirectory){return}
    $checked=0
    foreach($id in $Settings.LdPlayerIds){if(Test-Path -LiteralPath (Join-Path $Settings.CookieCheckStateDirectory "cookie-checked-$id.json")){$checked++}}
    $path=Join-Path $Settings.CookieCheckStateDirectory 'cookie-check-progress.json'
    $state=@{Checked=$checked;Total=$Settings.LdPlayerIds.Count;OverwriteEnabled=$false}|ConvertTo-Json -Compress
    $current='';try{$current=[IO.File]::ReadAllText($path)}catch{}
    if($current -cne $state){[IO.File]::WriteAllText($path,$state)}
}

function Publish-GameCookieUiState {
    param($Result)
    if (-not $Config.CookieUiStateDirectory) {return}
    try {
        $state='Checked'
        if($Result.Mismatch){$state='Cookie mismatch'}
        elseif($Result.Unavailable){$state='Check unavailable'}
        elseif($Result.NeedsLogin){$state='Waiting for cookie'}
        elseif($Result.Ready){$state='Cookies match'}
        $appCookie='Unknown'; if($null -ne $Result.AppCookiePresent){$appCookie=if($Result.AppCookiePresent){'Saved'}else{'Blank'}}
        $payload=@{InstanceId=$InstanceIndex;Package=$Config.GamePackage;Status=$state;AppCookie=$appCookie;Message=$Result.Message;Utc=[datetime]::UtcNow.ToString('o')}
        $path=Join-Path $Config.CookieUiStateDirectory ("ui-cookie-$InstanceIndex-$($Config.GamePackage).json")
        [IO.File]::WriteAllText($path,($payload|ConvertTo-Json -Compress))
    } catch { }
}

function Test-FlowStopRequested {
    $path=$env:LAUNCHER_FLOW_STOP_FILE
    if ($Config -and $Config.StopFilePath) {$path=$Config.StopFilePath}
    return ($path -and (Test-Path -LiteralPath $path -PathType Leaf))
}






function Start-GameCookieCheckPass {
    $script:GameCookiePassId=1+[long]$script:GameCookiePassId
}







function Stop-GameAppForAccountUpdate {
    param([string]$Package)
    if(-not (Test-AppRunning -Package $Package)){return}
    if(-not (Test-EmulatorResponsive)){
        $failure=[TimeoutException]::new('Android is not responding during account initialization. Restarting the emulator before retrying.')
        $failure.Data['CookieEmulatorRestartRequired']=$true;throw $failure
    }
    $null=Invoke-Ld -Arguments @('killapp','--index',"$InstanceIndex",'--packagename',$Package)
    if(Test-AppRunning -Package $Package){throw 'Waiting for the app to close before updating its cookie and profile.'}
    Clear-GameHomeLinkTimer
}




function Get-WaitingCookiePresence {
    param([string]$Package,$InstanceInfo=$null)
    $entries=$null;$snapshot=$null
    try{
        $entries=Read-GameCookieStore
        $localPresent=$entries.ContainsKey([string]$InstanceIndex) -and $entries[[string]$InstanceIndex].ContainsKey($Package) -and
            [bool](ConvertTo-GameCookieValue $entries[[string]$InstanceIndex][$Package])
        if($localPresent){return [pscustomobject]@{Known=$true;Available=$true;BothMissing=$false;Reason=''}}
        if($null -eq $InstanceInfo){$InstanceInfo=Get-InstanceInfo -Id $InstanceIndex}
        if($null -eq $InstanceInfo -or $InstanceInfo.ProcessId -le 0 -or -not $InstanceInfo.AndroidStarted){
            return [pscustomobject]@{Known=$false;Available=$false;BothMissing=$false;Reason='The emulator is not ready; waiting for a saved cookie or a manual start.'}
        }
        if(-not $script:CookieAdbSerial -or $script:CookieAdbBoot -ne $InstanceInfo.ProcessId){
            $serial=(Invoke-Ld -Arguments @('adb','--index',"$InstanceIndex",'--command','get-serialno')).Trim()
            if($serial -notmatch '^(emulator-\d+|(?:127\.0\.0\.1|localhost):\d+)$'){throw 'The emulator ADB identity is unavailable.'}
            $script:CookieAdbSerial=$serial;$script:CookieAdbBoot=$InstanceInfo.ProcessId
        }
        $snapshot=Get-GameCookieSnapshot -Package $Package
        $appPresent=[bool]($snapshot.Value -or $snapshot.Encrypted)
        return [pscustomobject]@{Known=$true;Available=$appPresent;BothMissing=(-not $appPresent);Reason=''}
    }catch [System.Management.Automation.PipelineStoppedException]{throw}
    catch [OperationCanceledException]{throw}
    catch{return [pscustomobject]@{Known=$false;Available=$false;BothMissing=$false;Reason=$_.Exception.Message}}
    finally{$entries=$null;$snapshot=$null}
}

function Suspend-SetupSlotForCookie {
    param([string]$Package)
    if($script:CookieSlotPause){return}
    $script:CookieSlotPause=[pscustomobject]@{Package=$Package;NextCheckAt=[datetime]::UtcNow.AddSeconds([math]::Max(1,$Config.GameCheckInterval));LastMessage=''}
    Set-BootRequestPhase WaitingForCookie
    Write-FlowStatus "Both cookie locations are empty for $Package. Released the emulator setup slot; keeping the app open at login. Checking for a cookie at $($Config.GameCheckInterval)-second intervals."
}

function Suspend-SetupSlotForUnresolvedMismatch {
    param([string]$Package)
    if($script:CookieSlotPause){return}
    $script:CookieSlotPause=[pscustomobject]@{Package=$Package;Kind='Mismatch';NextCheckAt=[datetime]::UtcNow;LastMessage=''}
    Set-BootRequestPhase WaitingForCookie
    Write-FlowStatus "The cookie for $Package is encrypted and cannot be copied while overwrite is OFF. Released the loading slot; rechecking at the normal game-check interval."
}

function Resume-SetupSlotWhenCookieAppears {
    param($InstanceInfo=$null)
    $script:CookieSlotPause=$null
    return $true
}




function Wait-NextGameCheck {
    param([long]$PreviousPassStarted)
    $delay = [double]$Config.GameCheckInterval
    if ($PreviousPassStarted -gt 0) {
        $elapsed = ([Diagnostics.Stopwatch]::GetTimestamp() - $PreviousPassStarted) / [double][Diagnostics.Stopwatch]::Frequency
        $delay = [math]::Max(1, $Config.GameCheckInterval - $elapsed)
    }
    Start-Sleep -Milliseconds ([int][math]::Ceiling($delay * 1000))
    return [Diagnostics.Stopwatch]::GetTimestamp()
}

function Watch-LauncherSession {
    Write-FlowStatus "Watching game status at $($Config.GameCheckInterval)-second intervals. Ctrl+C stops the script."
    $disconnectReads=0; $homeReads=0; $unknownReads=0
    $previousState=''; $passStarted=0
    while ($true) {
        $passStarted=Wait-NextGameCheck -PreviousPassStarted $passStarted
        Start-GameCookieCheckPass
        try {
            $instance=Get-InstanceInfo -Id $InstanceIndex
            if ($null -eq $instance -or $instance.ProcessId -le 0) { return 'EmulatorClosed' }
            if (Invoke-ScheduledEmulatorRestart -InstanceInfo $instance) { return 'ScheduledRestart' }
            if (-not (Test-EmulatorResponsive -InstanceInfo $instance)) { return 'EmulatorNotResponding' }
            $script:CookieBootIdentity=$instance.ProcessId
            Confirm-RequiredEmulatorApps -BootIdentity $instance.ProcessId
            Assert-MonitoredAppVisible
            $state=Get-LauncherSessionState
            if($state -eq 'Minimized'){return 'AppMinimized'}
            if ($state -eq 'Crashed') { return 'AppCrashed' }
            if ($state -eq 'Unknown' -and -not (Test-AppRunning -Package $Config.GamePackage)) { return 'LauncherClosed' }
        }
        catch [System.Management.Automation.PipelineStoppedException] { throw }
        catch [OperationCanceledException] { throw }
        catch {
            if ($_.Exception.Data['PackageCheckUnavailable']) {
                if((Invoke-PackageCheckRecovery -Failure $_.Exception) -eq 'EmulatorReopened'){return 'PackageCheckRetry'}
                continue
            }
            if ($_.Exception.Data['GameStatusReadFailed']) {
                Write-FlowStatus ('Game status unavailable. Keeping the app open and retrying. '+$_.Exception.Message)
                $disconnectReads=0; $homeReads=0
                continue
            }
            Write-FlowStatus ('Status check failed: '+$_.Exception.Message)
            return 'UnexpectedError'
        }
        if ($state -eq 'Blocked') {
            if ($previousState -ne 'Blocked') { Write-FlowStatus 'Waiting for the account/access/kick error to clear.' }
            $disconnectReads=0; $homeReads=0; $unknownReads=0; $previousState=$state
            continue
        }
        if ($state -eq 'Disconnected') { $disconnectReads++ } else { $disconnectReads=0 }
        if ($disconnectReads -ge 2) { return 'Disconnected' }
        if ($state -eq 'Home') { $homeReads++ } else { $homeReads=0 }
        if ($homeReads -ge 2) { return 'Home' }
        if ($state -eq 'Unknown') {
            $unknownReads++
            if ($unknownReads -eq 1) { Write-FlowStatus 'Status is unavailable, but the app is still running. Leaving its session untouched.' }
        } else { $unknownReads=0 }
        if ($state -ne $previousState) { Write-FlowStatus "Game status: $state" }
        $previousState=$state
    }
}

function Invoke-ContinuousEmulatorFlow {
    $script:RecoveringEmulator=$false
    $disconnectConfirmed=$false
    while ($true) {
        Start-GameCookieCheckPass
        $reason='UnexpectedError'
        try {
            if ($disconnectConfirmed) {
                Invoke-Ld -Arguments @('killapp','--index',"$InstanceIndex",'--packagename',$Config.GamePackage) | Out-Null
            }
            $action=Invoke-EmulatorFlow -DisconnectConfirmed:$disconnectConfirmed
            if ($action -eq 'WaitingForCookie') { Start-Sleep -Seconds $Config.GameCheckInterval; continue }
            if ($script:BootRequestRecord.Phase -eq 'SettingUp') {
                Wait-LauncherInGame
                Set-BootRequestPhase Finished
                Write-FlowStatus 'Game app is fully in game. Released the emulator setup slot.'
            }
            $script:RecoveringEmulator=$false
            $disconnectConfirmed=$false
            if ($Config.MonitorGame -eq 0) { return $action }
            $reason=Watch-LauncherSession
        }
        catch [System.Management.Automation.PipelineStoppedException] { throw }
        catch [OperationCanceledException] { throw }
        catch {
            if ($Config.MonitorGame -eq 0) { throw }
            if ($_.Exception.Data['PackageCheckUnavailable']) {
                $null=Invoke-PackageCheckRecovery -Failure $_.Exception
                Start-Sleep -Seconds ([math]::Max(1,$Config.GameCheckInterval))
                continue
            }
            if ($_.Exception.Data['GameStatusReadFailed']) {
                Write-FlowStatus ('Game status unavailable. Keeping the app open and retrying. '+$_.Exception.Message)
                $disconnectConfirmed=$false
                Start-Sleep -Seconds ([math]::Max(1,$Config.GameCheckInterval))
                continue
            }
            Write-FlowStatus ('Unexpected error: '+$_.Exception.Message)
        }
        if ($reason -eq 'Disconnected') {
            $disconnectConfirmed=$true
        }
        elseif ($reason -notin @('Home','LauncherClosed','ScheduledRestart','CookieChanged','PackageCheckRetry','AppMinimized')) {
            try { $null=Restart-AfterUnexpectedError }
            catch [System.Management.Automation.PipelineStoppedException] { throw }
            catch [OperationCanceledException] { throw }
            catch { Write-FlowStatus ('Recovery will retry: '+$_.Exception.Message) }
        }
        Clear-ProcessCheckCache
        Start-Sleep -Seconds ([math]::Max(1,$Config.RetryDelay))
    }
}

function Wait-LauncherInGame {
    Write-FlowStatus "Waiting up to $($Config.GameJoinTimeout) seconds to enter the game before continuing..."
    $deadline=[datetime]::UtcNow.AddSeconds($Config.GameJoinTimeout);$disconnectReads=0;$readWarning=$false
    while([datetime]::UtcNow -lt $deadline){
        try{$state=Get-LauncherSetupSessionState -Deadline $deadline}
        catch [System.Management.Automation.PipelineStoppedException]{throw}
        catch [OperationCanceledException]{throw}
        catch{
            if(-not $_.Exception.Data['GameStatusReadFailed']){throw}
            if(-not $readWarning){Write-FlowStatus 'Waiting for readable game status within the existing join timeout.';$readWarning=$true}
            $remaining=($deadline-[datetime]::UtcNow).TotalSeconds
            if($remaining -gt 0){Wait-FlowPause ([int][math]::Min([math]::Max(1,$Config.PollInterval),[math]::Ceiling($remaining)))}
            continue
        }
        if($state -eq 'InGame'){Reset-FlowStageTimeout -Stage Game;Reset-JoinedAppCrashCount;Write-FlowStatus 'Game readiness confirmed, including the configured loading-completion marker.';return}
        if($state -eq 'Minimized'){Restore-GameAppWindow -Deadline $deadline;continue}
        if($state -eq 'Crashed'){throw (New-AppCrashError $Config.GamePackage)}
        if($state -eq 'Closed'){throw 'Android confirmed the game app closed while joining.'}
        if($state -eq 'Blocked'){throw 'The game reported an account/access/kick error.'}
        if($state -eq 'Disconnected'){$disconnectReads++}else{$disconnectReads=0}
        if($disconnectReads -ge 2){throw 'The game disconnected while joining.'}
        Wait-FlowPause ([math]::Max(1,$Config.PollInterval))
    }
    throw [TimeoutException]::new("Game entry was not confirmed within $($Config.GameJoinTimeout) seconds. Restarting the affected app if Android responds.")
}

function Request-MonitorQuickRecovery {
    param([string]$Package=$Config.GamePackage,$Failure,[switch]$HealthOnly,[switch]$EmulatorOnly,[switch]$EmulatorUnresponsive)
    if($script:PoolRole -ne 'Monitor'){throw 'Quick monitor recovery belongs only to the monitor worker.'}
    if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Tool stopped before monitor cleanup.')}
    if($Failure -and $Failure.Data['InstanceInventoryUnavailable']){return $false}
    if($Failure -and $Failure.Data['GamePackage']){$Package=[string]$Failure.Data['GamePackage']}
    if($Config.GamePackages -cnotcontains $Package){$Package=$Config.GamePackage}
    $responsive=$false
    if(-not $EmulatorUnresponsive){$responsive=Test-EmulatorResponsive -InstanceInfo $script:CurrentEmulatorInstance}
    if($HealthOnly -and $responsive){
        $script:PoolPendingRecovery=$null
        Write-FlowStatus 'Android is responding. Keeping the app open after the unavailable status read; the monitor will check again normally.'
        return $false
    }
    $kind=if(-not $responsive){'Emulator'}elseif(-not $EmulatorOnly){'App'}else{''}
    $script:PoolPendingRecovery=@{Package=$Package;EmulatorOnly=([bool]$EmulatorOnly -or -not $responsive);HealthOnly=$false;CloseRequested=$kind}
    if($script:PoolAppState){
        foreach($app in $script:PoolAppState.Apps){
            if($kind -eq 'Emulator' -or $app.Config.GamePackage -ceq $Package){$app.Ready=$false;if($kind -eq 'Emulator'){$app.Confirmed=$false}}
        }
    }
    if(-not $kind){return $true}
    if($kind -eq 'App' -and $Failure -and $Failure.Data['AppAlreadyClosed']){
        Write-FlowStatus 'The app was already observed closed. Queuing its next setup turn without another close command.'
        return $true
    }
    try{
        if($kind -eq 'Emulator'){
            Set-EmulatorLiveObservation -EmulatorState CloseRequested
            Write-FlowStatus 'Monitor: Android/ADB is not responding. Sending LDPlayer close; startup and recovery will wait for a setup worker.'
            $reply=Invoke-Ld -Arguments @('quit','--index',"$InstanceIndex")
        }else{
            Set-EmulatorLiveObservation -AppState CloseRequested -Package $Package
            Write-FlowStatus "Monitor: closing $Package now. Reopening and rejoining will wait for a setup worker."
            $reply=Invoke-Ld -Arguments @('killapp','--index',"$InstanceIndex",'--packagename',$Package)
            if($reply -match '(?i)(device.*not found|device offline|cannot connect|error: closed|no devices/emulators found)'){throw [TimeoutException]::new('ADB is unavailable during the monitor close command.')}
        }
        
        
    }catch [System.Management.Automation.PipelineStoppedException]{throw}
    catch{
        if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Tool stopped during monitor cleanup.')}
        $adbUnavailable=$_.Exception.Data['LdCommandTimedOut'] -or $_.Exception -is [TimeoutException] -or $_.Exception.Message -match '(?i)(device.*not found|device offline|cannot connect|error: closed|no devices/emulators found)'
        if($kind -eq 'App' -and $adbUnavailable){
            $null=Request-MonitorQuickRecovery -Package $Package -EmulatorUnresponsive
        }else{Write-FlowStatus 'The monitor close command could not finish. The emulator remains queued; its setup worker will inspect the current state.'}
    }
    return $true
}

function Invoke-MultipleGameApps {
    $baseConfig=$Config
    $apps=New-Object 'System.Collections.Generic.List[object]'
    foreach ($package in $baseConfig.GamePackages) {
        $appConfig=$baseConfig.Clone()
        $appConfig.GamePackage=$package
        $appConfig.LauncherPackage=$package
        $appConfig.ServerLink=$baseConfig.ServerLink
        
        if ($appConfig.MaxServerLinkAttempts -eq 0) { $appConfig.MaxServerLinkAttempts=1 }
        $apps.Add([pscustomobject]@{Config=$appConfig;Ready=$false;Disconnected=0;Home=0;Unknown=0;Confirmed=$false;LastState='';CookieResult=$null})
    }
    $lastProcessId=0
    $passStarted=0
    $watchAnnounced=$false
    if($script:PoolRole -and $script:PoolAppState){
        $apps=$script:PoolAppState.Apps
        $lastProcessId=$script:PoolAppState.LastProcessId
        $watchAnnounced=$script:PoolAppState.WatchAnnounced
        foreach($app in $apps){$app.Config.LdPlayerIds=@($baseConfig.LdPlayerIds)}
    }
    $poolPassRan=$false
    try {
        while ($true) {
            if($script:PoolRole -eq 'Monitor' -and $poolPassRan){return 'Monitoring'}
            if($script:PoolRole -eq 'Setup' -and $poolPassRan -and $script:CookieSlotPause){return 'WaitingForCookie'}
            $poolPassRan=$true
            if ($script:PoolRole -ne 'Monitor' -and $passStarted -gt 0 -and -not $script:ImmediateFlowRetry) { $passStarted=Wait-NextGameCheck -PreviousPassStarted $passStarted }
            else { $passStarted=[Diagnostics.Stopwatch]::GetTimestamp() }
            $script:ImmediateFlowRetry=$false
            Start-GameCookieCheckPass
            $monitorCookieBatch=$null
            $Config=$apps[0].Config
            $activeApp=$apps[0]
            try {
                if($script:PoolRole -eq 'Setup' -and $script:PoolPendingRecovery){
                    $pending=$script:PoolPendingRecovery
                    $activeApp=@($apps|Where-Object{$_.Config.GamePackage -ceq $pending.Package})|Select-Object -First 1
                    if(-not $activeApp){$activeApp=$apps[0]}
                    $Config=$activeApp.Config
                    $needsRecovery=$true
                    if($pending.CloseRequested -and -not $script:AppCrashRestartPending){
                        
                        
                        $needsRecovery=$false;$activeApp.Ready=$false
                        if($pending.CloseRequested -eq 'Emulator'){
                            $current=Get-InstanceInfo -Id $InstanceIndex
                            if($current -and $current.ProcessId -gt 0 -and -not (Test-EmulatorResponsive -InstanceInfo $current)){$needsRecovery=$true}
                            foreach($item in $apps){$item.Ready=$false;$item.Confirmed=$false};$lastProcessId=0
                        }
                    }
                    if($needsRecovery -and (-not $pending.HealthOnly -or -not (Test-EmulatorResponsive))){
                        $recovery=Restart-AfterUnexpectedError -EmulatorOnly:($pending.EmulatorOnly -or $pending.HealthOnly)
                        $activeApp.Ready=$false
                        if($recovery -eq 'EmulatorReopened'){foreach($item in $apps){$item.Ready=$false;$item.Confirmed=$false};$lastProcessId=0}
                    }elseif($pending.HealthOnly -and @($apps|Where-Object{-not $_.Ready}).Count -eq 0){
                        $script:PoolPendingRecovery=$null;Set-BootRequestPhase Finished
                        return 'Monitoring'
                    }
                    $script:PoolPendingRecovery=$null
                    $Config=$apps[0].Config;$activeApp=$apps[0]
                }
                if($script:PoolRole -ne 'Monitor' -and $Config.RecoveryMode -eq 'Template' -and -not $script:PendingEmulatorRestore){
                    if(Get-PendingTemplateStage){$script:PendingEmulatorRestore='Resuming the recorded data-disk replacement.'}
                }
                if($script:PendingEmulatorRestore){Assert-PoolSetupTurn;Invoke-PendingEmulatorRestore;foreach($app in $apps){$app.Ready=$false;$app.Confirmed=$false};$lastProcessId=0}
                $script:RecoveryScope='Startup'
                $instance=Get-InstanceInfo -Id $InstanceIndex
                $script:CurrentEmulatorInstance=$instance
                if ($null -eq $instance) {
                    Set-EmulatorLiveObservation -EmulatorState Unknown
                    $failure=New-GameStatusReadError "LDPlayer $InstanceIndex inventory was unavailable. Existing apps were left open."
                    $failure.Data['InstanceInventoryUnavailable']=$true
                    throw $failure
                }
                $displayBoot=if($instance.ProcessId -le 0){'Offline'}elseif(-not $instance.AndroidStarted){'Starting'}else{'Running'}
                Set-EmulatorLiveObservation -EmulatorState $displayBoot -ResetApps:($lastProcessId -gt 0 -and $instance.ProcessId -ne $lastProcessId)
                $cookieSlotStillPaused=$false
                if($script:CookieSlotPause){
                    $cookieSlotStillPaused=-not (Resume-SetupSlotWhenCookieAppears -InstanceInfo $instance)
                    if($cookieSlotStillPaused -and ($instance.ProcessId -le 0 -or -not $instance.AndroidStarted)){continue}
                }
                if (-not $cookieSlotStillPaused -and $baseConfig.CookieStorePath -and $instance.ProcessId -gt 0 -and $instance.AndroidStarted -and $script:InitialCookieBoot -ne $instance.ProcessId) {
                    Assert-PoolSetupTurn
                    $script:CookieBootIdentity=$instance.ProcessId
                    Confirm-RequiredEmulatorApps -BootIdentity $instance.ProcessId
                    if (-not (Save-LoadedEmulatorAppData -BootIdentity $instance.ProcessId)) {
                        if (-not (Test-EmulatorResponsive -InstanceInfo $instance)) { throw [TimeoutException]::new('Emulator stopped responding during initial game-data capture.') }
                        continue
                    }
                }
                if(-not $cookieSlotStillPaused -and $script:PoolRole -eq 'Monitor' -and (Test-PoolScheduledRestartDue $instance)){Assert-PoolSetupTurn}
                if (-not $cookieSlotStillPaused -and $script:PoolRole -ne 'Monitor' -and (Invoke-ScheduledEmulatorRestart -InstanceInfo $instance)) {
                    foreach ($app in $apps) { $app.Ready=$false;$app.Confirmed=$false }
                    $lastProcessId=0
                    $instance=Get-InstanceInfo -Id $InstanceIndex
                }
                if ($instance.ProcessId -le 0) {
                    foreach ($app in $apps) { $app.Ready=$false; $app.Confirmed=$false }
                    Start-SelectedEmulator
                    $instance=Get-InstanceInfo -Id $InstanceIndex
                }
                if ($lastProcessId -gt 0 -and $instance.ProcessId -ne $lastProcessId) {
                    foreach ($app in $apps) { $app.Ready=$false; $app.Confirmed=$false }
                }
                $lastProcessId=$instance.ProcessId

                if (-not $cookieSlotStillPaused -and $baseConfig.CookieStorePath -and ($script:InitialCookieBoot -ne $instance.ProcessId -or -not $instance.AndroidStarted)) {
                    Assert-PoolSetupTurn
                    if (-not $instance.AndroidStarted) { Start-SelectedEmulator; $instance=Get-InstanceInfo -Id $InstanceIndex }
                    $script:CookieBootIdentity=$instance.ProcessId
                    Enter-EmulatorLoadingSlot
                    Ensure-SessionVpn
                    
                    foreach ($app in $apps) {
                        $activeApp=$app;$Config=$app.Config
                        $app.CookieResult=Get-SetupGameAppData
                        if ($app.CookieResult.Changed -or $app.CookieResult.NeedsLogin) { $app.Ready=$false; $app.Confirmed=$false }
                    }
                    Complete-InitialCookieChecks -Results @($apps | ForEach-Object {$_.CookieResult})
                    $script:InitialCookieBoot=$instance.ProcessId
                }
                $script:RecoveryScope='Game'
                
                foreach ($app in $apps) {
                    $activeApp=$app; $Config=$app.Config
                    if($script:PoolRole){$script:PoolActivePackage=$Config.GamePackage}

                    $dataTurn=Invoke-WaitingGameAppDataTurn
                    $app|Add-Member NoteProperty DataLoginWaiting ($dataTurn -eq 'Waiting') -Force
                    if($dataTurn -eq 'Waiting'){Set-EmulatorLiveObservation -AppState Login -Package $Config.GamePackage;$app.Ready=$true;$app.Confirmed=$false;continue}
                    if($dataTurn -eq 'Captured'){$app.Ready=$false;$app.Confirmed=$false}

                    if ($app.Ready) {
                        Assert-MonitoredAppVisible
                        $state=Get-LauncherSessionState
                        if ($state -eq 'Crashed') { throw (New-AppCrashError $Config.GamePackage) }
                        if ($state -ne $app.LastState) { Write-FlowStatus "Game status: $state"; $app.LastState=$state }
                        if ($state -eq 'Blocked') { throw 'The game reported an account/access/kick error.' }
                        if ($state -eq 'Disconnected') {$app.Disconnected++} else {$app.Disconnected=0}
                        if ($state -eq 'Home') {$app.Home++} else {$app.Home=0}
                        if ($state -in @('Minimized','Closed')) {
                            
                            
                            
                            $failure=[InvalidOperationException]::new("Android confirmed $($Config.GamePackage) is $($state.ToLowerInvariant()). Checking Android before app/emulator recovery.")
                            if($state -eq 'Closed'){$failure.Data['AppAlreadyClosed']=$true}
                            throw $failure
                        }
                        if ($state -eq 'Unknown') {
                            $app.Unknown++
                            if ($app.Unknown -eq 1) {Write-FlowStatus 'Game status is unavailable. Keeping this app open and checking again later.'}
                        } else {$app.Unknown=0}
                        if($script:PoolRole -and $state -in @('Joining','Loading')){
                            if(-not $app.MonitorLoadingSince){$app|Add-Member NoteProperty MonitorLoadingSince ([datetime]::UtcNow) -Force}
                            if(([datetime]::UtcNow-$app.MonitorLoadingSince).TotalSeconds -ge $Config.GameJoinTimeout){throw [TimeoutException]::new('The game remained loading past the configured join timeout. Queuing the affected app for recovery.')}
                        }elseif($script:PoolRole){$app|Add-Member NoteProperty MonitorLoadingSince $null -Force}
                        if ($app.Disconnected -ge 2) {
                            if($script:PoolRole -eq 'Monitor'){
                                $app.Ready=$false;$app.Confirmed=$true
                                $null=Request-MonitorQuickRecovery -Package $Config.GamePackage
                                Assert-PoolSetupTurn
                            }
                            if(-not (Test-EmulatorResponsive)){
                                $failure=[InvalidOperationException]::new('Game disconnect confirmed and Android is not responding. Restarting this emulator.')
                                $failure.Data['DisconnectedEmulatorUnresponsive']=$true
                                throw $failure
                            }
                            $app.Ready=$false
                            $app.Confirmed=$true
                            Write-FlowStatus 'Network disconnect confirmed. Closing the game app before queuing its recovery.'
                            Invoke-Ld -Arguments @('killapp','--index',"$InstanceIndex",'--packagename',$Config.GamePackage) | Out-Null
                        }
                        if ($app.Home -ge 2) {
                            $app.Ready=$false
                            if($script:PoolRole -eq 'Monitor'){$null=Request-MonitorQuickRecovery -Package $Config.GamePackage;Assert-PoolSetupTurn}
                        }
                    }
                    $null=Invoke-RegularGameAppCookieTurn -Batch ([ref]$monitorCookieBatch)
                    if (-not $app.Ready) {
                        if($script:CookieSlotPause){continue}
                        Assert-PoolSetupTurn
                        $action=Invoke-EmulatorFlow -DisconnectConfirmed:$app.Confirmed
                        if ($action -eq 'WaitingForCookie') { break }
                        
                        
                        Wait-LauncherInGame
                        $app.Ready=$true;$app.Confirmed=$false
                        $app.Disconnected=0;$app.Home=0;$app.Unknown=0;$app.LastState=''
                        Write-FlowStatus "Setup completed: $action"
                    }
                }
                if ($script:BootRequestRecord.Phase -eq 'SettingUp') {
                    
                    
                    $allJoined=$true
                    foreach ($app in $apps) {
                        $Config=$app.Config
                        $activeApp=$app
                        if($script:PoolRole){$script:PoolActivePackage=$Config.GamePackage}
                        if($app.DataLoginWaiting){continue}
                        if (-not $app.Ready -or (Get-LauncherSessionState -RequireReady) -ne 'InGame') {
                            $allJoined=$false
                            break
                        }
                    }
                    if (-not $allJoined) { continue }
                    Set-BootRequestPhase Finished
                    if(@($apps|Where-Object{$_.DataLoginWaiting}).Count){Write-FlowStatus 'Active game apps are joined; apps without cookies are open for login. Released the emulator setup slot while waiting for cookies.'}
                    else{Write-FlowStatus 'All game apps are fully in game. Released the emulator setup slot.'}
                }
                if ($baseConfig.MonitorGame -eq 0) { if($script:CookieSlotPause){return 'WaitingForCookie'};return 'AppsReady' }
                if($script:PoolRole -eq 'Setup'){
                    if($script:CookieSlotPause){return 'WaitingForCookie'}
                    if(@($apps|Where-Object{-not $_.Ready}).Count -eq 0 -and $script:BootRequestRecord.Phase -eq 'Finished'){return 'Monitoring'}
                }
                if (-not $watchAnnounced) {
                    Write-FlowStatus "Watching $($apps.Count) game app(s) at $($baseConfig.GameCheckInterval)-second intervals. Ctrl+C stops the script."
                    $watchAnnounced=$true
                }
            }
            catch [System.Management.Automation.PipelineStoppedException] { throw }
            catch [OperationCanceledException] { throw }
            catch {
                if(-not $_.Exception.Data['GamePackage']){$_.Exception.Data['GamePackage']=[string]$Config.GamePackage}
                if ($baseConfig.MonitorGame -eq 0) { throw }
                if ($_.Exception.Data['PackageCheckUnavailable']) {
                    $script:ImmediateFlowRetry=$true
                    if((Invoke-PackageCheckRecovery -Failure $_.Exception) -eq 'EmulatorReopened'){
                        foreach($app in $apps){$app.Ready=$false;$app.Confirmed=$false}
                        $lastProcessId=0
                    }
                    continue
                }
                if ($_.Exception.Data['GameStatusReadFailed']) {
                    Set-EmulatorLiveObservation -AppState Unknown -Package $Config.GamePackage
                    if($script:PoolRole -eq 'Monitor'){
                        if($_.Exception.Data['AppCacheCleanupFailed']){Write-FlowStatus $_.Exception.Message}
                        else{Write-FlowStatus ('Game status unavailable. Keeping the app open and retrying. '+$_.Exception.Message)}
                        $activeApp.Disconnected=0;$activeApp.Home=0
                        if($_.Exception.Data['InstanceInventoryUnavailable']){continue}
                        if(Request-MonitorQuickRecovery -Package $Config.GamePackage -Failure $_.Exception -HealthOnly){Assert-PoolSetupTurn}
                        continue
                    }
                    if(-not $_.Exception.Data['InstanceInventoryUnavailable'] -and -not (Test-EmulatorResponsive)){
                        Write-FlowStatus 'Game status failed and Android is not responding. Restarting this emulator.'
                        $null=Restart-AfterUnexpectedError -EmulatorOnly
                        foreach($item in $apps){$item.Ready=$false;$item.Confirmed=$false}
                        $lastProcessId=0;$script:ImmediateFlowRetry=$true
                        if($script:PoolRole -eq 'Monitor'){Assert-PoolSetupTurn}
                    }else{
                        if($_.Exception.Data['AppCacheCleanupFailed']){
                            Write-FlowStatus $_.Exception.Message
                        }elseif($_.Exception.Data['AppPresenceUnavailable']){
                            Write-FlowStatus ('App presence could not be confirmed. Retrying the presence check before opening or changing this app. '+$_.Exception.Message)
                        }else{
                            Write-FlowStatus ('Game status unavailable. Keeping the app open and retrying. '+$_.Exception.Message)
                        }
                    }
                    $activeApp.Disconnected=0;$activeApp.Home=0
                    continue
                }
                $message=$_.Exception.Message
                Write-FlowStatus ('App check failed: '+$message)

                $activeApp.Ready=$false
                $script:ImmediateFlowRetry=$true
                if($script:PoolRole -eq 'Monitor'){
                    $null=Request-MonitorQuickRecovery -Package $Config.GamePackage -Failure $_.Exception -EmulatorOnly:($script:RecoveryScope -in @('Startup','Packages','VPN') -or [bool]$_.Exception.Data['CookieEmulatorRestartRequired'])
                    Assert-PoolSetupTurn
                }
                try {
                    if($script:RecoveryScope -eq 'VPN' -and -not $script:PendingEmulatorRestore -and (Test-EmulatorResponsive)){
                        Write-FlowStatus 'VPN setup will retry. The game apps were left untouched.'
                        continue
                    }
                    $recovery=Restart-AfterUnexpectedError -EmulatorOnly:($script:RecoveryScope -in @('Startup','Packages','VPN') -or $_.Exception.Data['CookieEmulatorRestartRequired'] -or $_.Exception.Data['DisconnectedEmulatorUnresponsive'])
                    if ($recovery -eq 'EmulatorReopened') {
                        foreach ($item in $apps) {$item.Ready=$false;$item.Confirmed=$false}
                        $lastProcessId=0
                    }
                }
                catch [System.Management.Automation.PipelineStoppedException] { throw }
                catch [OperationCanceledException] { throw }
                catch { Write-FlowStatus ('Recovery will retry: '+$_.Exception.Message) }
                if($script:PoolRole -eq 'Monitor'){Assert-PoolSetupTurn}
                Start-Sleep -Seconds ([math]::Max(1,$baseConfig.RetryDelay))
            }
        }
    }
    finally {
        if($script:PoolRole){$script:PoolAppState=@{Apps=$apps;LastProcessId=$lastProcessId;WatchAnnounced=$watchAnnounced}}
        $Config=$baseConfig
    }
}

function Invoke-ResilientEmulatorFlow {
    $Config.MonitorGame=1
    while ($true) {
        try {
            if($script:PoolRole -ne 'Monitor' -and $Config.RecoveryMode -eq 'Template' -and -not $script:PendingEmulatorRestore){
                if(Get-PendingTemplateStage){$script:PendingEmulatorRestore='Resuming the recorded data-disk replacement.'}
            }
            if($script:PendingEmulatorRestore){Assert-PoolSetupTurn;Invoke-PendingEmulatorRestore}
            if($script:PoolRole -ne 'Monitor'){Save-StartupLogSnapshot}
            $action=Invoke-MultipleGameApps
            if($script:PoolRole){return $action}
            
            Start-Sleep -Seconds ([math]::Max(1,$Config.RetryDelay))
        }
        catch [System.Management.Automation.PipelineStoppedException] { throw }
        catch [OperationCanceledException] { throw }
        catch {
            if ($_.Exception.Data['PackageCheckUnavailable']) {
                $null=Invoke-PackageCheckRecovery -Failure $_.Exception
                Start-Sleep -Seconds ([math]::Max(1,$Config.RetryDelay))
                continue
            }
            
            
            if($script:PoolRole -eq 'Monitor'){
                $package=[string]$_.Exception.Data['GamePackage'];if(-not $package){$package=$script:PoolActivePackage};if(-not $package){$package=$Config.GamePackage}
                $healthOnly=[bool]$_.Exception.Data['GameStatusReadFailed']
                if(Request-MonitorQuickRecovery -Package $package -Failure $_.Exception -HealthOnly:$healthOnly -EmulatorOnly:($script:RecoveryScope -in @('Startup','Packages','VPN'))){Assert-PoolSetupTurn}
                return 'Monitoring'
            }
            Write-WorkerRetryStatus -Failure $_.Exception -RetrySeconds $Config.RetryDelay -ReplacementActive:([bool]$script:PendingInstanceReplacement)
            $recoveryConfig=$Config
            try {
                if($_.Exception.Data['AppCrashDialog']){
                    $package=[string]$_.Exception.Data['GamePackage']
                    if($package -and $Config.GamePackages -ccontains $package){
                        $Config=$Config.Clone();$Config.GamePackage=$package;$Config.LauncherPackage=$package
                        if($script:PoolAppState){foreach($app in $script:PoolAppState.Apps){if($app.Config.GamePackage -ceq $package){$app.Ready=$false}}}
                    }
                }
                $recovery=Restart-AfterUnexpectedError
                if($recovery -eq 'EmulatorReopened' -and $script:PoolAppState){
                    foreach($app in $script:PoolAppState.Apps){$app.Ready=$false;$app.Confirmed=$false};$script:PoolAppState.LastProcessId=0
                }
            }
            catch [System.Management.Automation.PipelineStoppedException] { throw }
            catch [OperationCanceledException] { throw }
            catch { Write-FlowStatus ('Recovery attempt failed: '+$_.Exception.Message+'. Retrying the full VPN/game flow.') }
            finally {$Config=$recoveryConfig}
            Clear-ProcessCheckCache
            Start-Sleep -Seconds ([math]::Max(1,$Config.RetryDelay))
        }
    }
}

function Initialize-RepairNotificationReader {
    if (-not ('LauncherLdRepairUi' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public sealed class LauncherLdRepairWindow {
    public IntPtr Handle;
    public int ProcessId;
    public string Title;
    public string Text;
    public string ClassName;
}
public static class LauncherLdRepairUi {
    private delegate bool EnumProc(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr data);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, StringBuilder text, int size);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder text, int size);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr size, StringBuilder text, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll", SetLastError=true)] private static extern bool PostMessage(IntPtr window, uint message, IntPtr a, IntPtr b);
    public static LauncherLdRepairWindow[] Find(int processId) {
        var found = new List<LauncherLdRepairWindow>();
        EnumWindows(delegate(IntPtr window, IntPtr unused) {
            uint pid; GetWindowThreadProcessId(window, out pid);
            if ((processId > 0 && pid != processId) || !IsWindowVisible(window)) return true;
            var title = new StringBuilder(512); GetWindowText(window, title, title.Capacity);
            if (!String.Equals(title.ToString().Trim(), "LDRepairer", StringComparison.OrdinalIgnoreCase)) return true;
            var labels = new List<string>();
            EnumChildWindows(window, delegate(IntPtr child, IntPtr ignored) {
                var label = new StringBuilder(4096); IntPtr result;
                SendMessageTimeout(child, 0x000D, new IntPtr(label.Capacity), label, 0x0002, 150, out result);
                if (label.Length > 0) labels.Add(label.ToString());
                return true;
            }, IntPtr.Zero);
            var className = new StringBuilder(512); GetClassName(window, className, className.Capacity);
            found.Add(new LauncherLdRepairWindow { Handle=window, ProcessId=(int)pid, Title=title.ToString(), Text=String.Join(" ", labels.ToArray()), ClassName=className.ToString() });
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }
    public static bool Close(IntPtr window, int expectedProcessId) {
        uint pid; GetWindowThreadProcessId(window, out pid);
        var title = new StringBuilder(512); GetWindowText(window, title, title.Capacity);
        if (pid != expectedProcessId || !String.Equals(title.ToString().Trim(), "LDRepairer", StringComparison.OrdinalIgnoreCase)) return false;
        bool posted = PostMessage(window, 0x0112, new IntPtr(0xF060), IntPtr.Zero);
        GetWindowThreadProcessId(window, out pid);
        if (pid == expectedProcessId) posted = PostMessage(window, 0x0010, IntPtr.Zero, IntPtr.Zero) || posted;
        return posted;
    }
    public static bool StillOpen(IntPtr window, int expectedProcessId) {
        uint pid; GetWindowThreadProcessId(window, out pid);
        return pid == expectedProcessId && IsWindowVisible(window);
    }
}
'@
    }
}

function Get-RepairCompletionMessage {
    param([string]$Text)
    $textLine=$Text -replace '\s+',' '
    if ($textLine -match '(?i)\bThe fix was complete(?:[.,]?\s*please try again[.]?)?(?:\s*Contact us if the fix failed[.]?)?') { return $Matches[0] }
    return ''
}

function Get-RepairCandidateWindows {
    param([int]$RepairerProcessId)
    return [LauncherLdRepairUi]::Find($RepairerProcessId)
}

function Get-RepairNotificationOwners {
    param([string]$FilePath)
    $directory=[IO.Path]::GetDirectoryName($FilePath)
    foreach ($window in @(Get-RepairCandidateWindows -RepairerProcessId 0)) {
        try {
            $owner=Get-Process -Id $window.ProcessId -ErrorAction Stop
            
            if ([IO.Path]::GetDirectoryName($owner.Path) -ieq $directory -and
                [IO.Path]::GetFileName($owner.Path) -in @('dnrepairer.exe','dnplayer.exe','ldplayer.exe','ldmultiplayer.exe','dnmultiplayer.exe','dnmultiplayerex.exe')) { $owner }
        } catch { }
    }
}

function Get-RepairNotificationWindows {
    param([int]$RepairerProcessId)
    if ($null -eq $script:RepairNotificationFirstSeen) { $script:RepairNotificationFirstSeen=@{} }
    foreach ($window in @(Get-RepairCandidateWindows -RepairerProcessId $RepairerProcessId)) {
        $message=Get-RepairCompletionMessage -Text $window.Text
        if (-not $message) {
            
            
            $unrecognized=$window.Text -replace '(?i)\b(LDRepairer|Restart|Close)\b|[x\u00d7\u2715\u2716]',''
            if ($unrecognized.Trim()) { continue }
            $key="$($window.ProcessId):$($window.Handle)"
            if (-not $script:RepairNotificationFirstSeen.ContainsKey($key)) {
                $script:RepairNotificationFirstSeen[$key]=[datetime]::UtcNow
                continue
            }
            if (([datetime]::UtcNow-$script:RepairNotificationFirstSeen[$key]).TotalSeconds -lt 0.5) { continue }
            $message="LDRepairer notification detected (body text is unavailable; window class: $($window.ClassName)). Closing the notification."
        }
        if ($message) { [pscustomobject]@{Handle=$window.Handle;ProcessId=$RepairerProcessId;Message=$message} }
    }
}

function Close-RepairNotificationWindow {
    param($Window)
    if (-not [LauncherLdRepairUi]::Close($Window.Handle,$Window.ProcessId)) { throw 'The repair completion window could not be closed yet.' }
}

function Test-RepairNotificationWindowOpen {
    param($Window)
    return [LauncherLdRepairUi]::StillOpen($Window.Handle,$Window.ProcessId)
}

function Get-RunningLdRepairers {
    param([string]$FilePath)
    foreach ($item in @(Get-Process -Name 'dnrepairer' -ErrorAction SilentlyContinue)) {
        try { if ($item.Path -ieq $FilePath) { $item } } catch { }
    }
}

function Invoke-RepairNotificationWorker {
    param([string]$FilePath,[int]$Id,[string]$LogPath,[bool]$WaitOnly)
    Initialize-RepairNotificationReader
    $process=$null
    $announced=@{}
    $closeRequested=@{}
    $closeAttempts=@{}
    $script:RepairNotificationFirstSeen=@{}
    $idleSince=$null
    try {
        if (-not $WaitOnly) {
            
            
            $info=New-Object Diagnostics.ProcessStartInfo
            $info.FileName=$FilePath
            $info.Arguments="cmd=fixError|playerid=$Id|errorcode=10|subcode=0|reportid={$([guid]::NewGuid())}|vtstate=2"
            $info.WorkingDirectory=[IO.Path]::GetDirectoryName($FilePath)
            $info.UseShellExecute=$false
            $info.CreateNoWindow=$true
            $info.EnvironmentVariables['QT_ACCESSIBILITY']='1'
            $process=New-Object Diagnostics.Process
            $process.StartInfo=$info
            if (-not $process.Start()) { throw "LDPlayer repair could not start for instance $Id." }
        }
        do {
            $running=@(@(Get-RunningLdRepairers -FilePath $FilePath)+@(Get-RepairNotificationOwners -FilePath $FilePath) | Sort-Object Id -Unique)
            foreach ($repairer in $running) {
                foreach ($window in @(Get-RepairNotificationWindows -RepairerProcessId $repairer.Id)) {
                    $key="$($window.ProcessId):$($window.Handle)"
                    if (-not $announced.ContainsKey($key)) {
                        [IO.File]::AppendAllText($LogPath,"LDRepairer: $($window.Message)`r`n",[Text.Encoding]::UTF8)
                        $announced[$key]=$true
                    }
                    
                    $closeRequested[$key]=$window
                    $closeAttempts[$key]=1+[int]$closeAttempts[$key]
                    try { Close-RepairNotificationWindow -Window $window }
                    catch {
                        if (-not $announced.ContainsKey('error:'+$key)) {
                            [IO.File]::AppendAllText($LogPath,"LDRepairer: Could not close the notification yet. Retrying. $($_.Exception.Message)`r`n",[Text.Encoding]::UTF8)
                            $announced['error:'+$key]=$true
                        }
                    }
                    if ($closeAttempts[$key] -eq 5 -and (Test-RepairNotificationWindowOpen -Window $window)) {
                        [IO.File]::AppendAllText($LogPath,"LDRepairer: Notification is still visible after five Close requests. Retrying; PID $($window.ProcessId), window $($window.Handle).`r`n",[Text.Encoding]::UTF8)
                    }
                }
            }
            foreach ($key in @($closeRequested.Keys)) {
                if (-not (Test-RepairNotificationWindowOpen -Window $closeRequested[$key])) {
                    [IO.File]::AppendAllText($LogPath,"LDRepairer: Notification closed.`r`n",[Text.Encoding]::UTF8)
                    $closeRequested.Remove($key)
                }
            }
            if (($process -and -not $process.HasExited) -or $running.Count -gt 0) { $idleSince=$null }
            elseif ($null -eq $idleSince) { $idleSince=[datetime]::UtcNow }
            if ($process -and -not $process.HasExited) { $null=$process.WaitForExit(500) }
            else { Start-Sleep -Milliseconds 500 }
        } while ($null -eq $idleSince -or ([datetime]::UtcNow-$idleSince).TotalSeconds -lt 0.5)
        if ($process -and $process.ExitCode -ne 0) { throw "LDPlayer repair for instance $Id exited with code $($process.ExitCode)." }
    }
    finally { if ($process) { $process.Dispose() } }
}

function Write-RepairWorkerMessages {
    param([string]$LogPath,[ref]$PrintedLines)
    try { $contents=[IO.File]::ReadAllText($LogPath) } catch { return }
    
    $lines=@($contents -split '\r?\n')
    for ($i=$PrintedLines.Value; $i -lt $lines.Count-1; $i++) {
        Write-Host $lines[$i]
        $PrintedLines.Value=$i+1
    }
}

function Invoke-NativeLdPlayerRepair {
    param([string]$FilePath,[int]$Id,[switch]$WaitOnly)
    $directory=Join-Path ([IO.Path]::GetTempPath()) ('launcher-ldrepair-'+[guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $directory
    $helperPath=Join-Path $directory 'repair-worker.ps1'
    $logPath=Join-Path $directory 'notification.txt'
    $names=@('Initialize-RepairNotificationReader','Get-RepairCompletionMessage','Get-RepairCandidateWindows','Get-RepairNotificationOwners','Get-RepairNotificationWindows','Close-RepairNotificationWindow','Test-RepairNotificationWindowOpen','Get-RunningLdRepairers','Invoke-RepairNotificationWorker')
    $definitions=foreach ($name in $names) { 'function '+$name+" {`r`n"+(Get-Command $name -CommandType Function).Definition+"`r`n}" }
    $settings=@{FilePath=$FilePath;Id=$Id;LogPath=$logPath;WaitOnly=[bool]$WaitOnly} | ConvertTo-Json -Compress
    $helper='$ErrorActionPreference=''Stop'''+"`r`n"+($definitions -join "`r`n")+"`r`n"+'$settings=ConvertFrom-Json '+"'"+$settings.Replace("'","''")+"'`r`n"
    $helper+=@'
try {
    Invoke-RepairNotificationWorker -FilePath $settings.FilePath -Id $settings.Id -LogPath $settings.LogPath -WaitOnly $settings.WaitOnly
    exit 0
} catch {
    [IO.File]::AppendAllText($settings.LogPath,('Repair stopped: '+$_.Exception.Message+"`r`n"),[Text.Encoding]::UTF8)
    exit 1
}
'@
    [IO.File]::WriteAllText($helperPath,$helper,[Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($logPath,'',[Text.Encoding]::UTF8)
    $command="& ([scriptblock]::Create([IO.File]::ReadAllText('"+$helperPath.Replace("'","''")+"')))"
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=Get-LauncherPowerShellPath
    $info.Arguments='-NoProfile -STA -WindowStyle Hidden -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $info.WorkingDirectory=[IO.Path]::GetDirectoryName($FilePath)
    
    $info.UseShellExecute=$true
    $info.Verb='runas'
    $info.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$info
    $started=$false
    $printed=0
    try {
        try { $started=$process.Start() }
        catch { throw [InvalidOperationException]::new("Allow the Windows administrator prompt for LDPlayer repair. The main loop has not started. $($_.Exception.Message)",$_.Exception) }
        if (-not $started) { throw 'LDPlayer repair worker could not start. The main loop has not started.' }
        while (-not $process.WaitForExit(1000)) { Write-RepairWorkerMessages -LogPath $logPath -PrintedLines ([ref]$printed) }
        Write-RepairWorkerMessages -LogPath $logPath -PrintedLines ([ref]$printed)
        if ($process.ExitCode -ne 0) { throw 'LDPlayer repair did not finish successfully. The main loop has not started. See the repair message above.' }
    }
    finally {
        if (-not $started -or $process.HasExited) {
            Remove-Item -LiteralPath $helperPath,$logPath -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $directory -ErrorAction SilentlyContinue
        }
        $process.Dispose()
    }
}

function Wait-ForLdPlayerRepairers {
    if (Get-Process -Name 'dnrepairer' -ErrorAction SilentlyContinue) {
        Write-Host 'Waiting for the existing LDPlayer repairer and closing its completion notification...'
        Invoke-NativeLdPlayerRepair -FilePath (Join-Path $Config.LdPlayerInstallPath 'dnrepairer.exe') -Id -1 -WaitOnly
    }
}


function Invoke-StartupRepairPolicy {
    if($Config.SkipRepairNextStart -eq 1){
        
        
        Set-LauncherConfigValues -Path $Config.ConfigFilePath -Values @{SkipRepairNextStart='0'} -Automatic
        $Config.SkipRepairNextStart=0
        Write-Host 'Repair all skipped for this Start. The one-use skip toggle is now OFF.'
        return
    }
    Repair-AllInstancesBeforeMainLoop
}

function Repair-AllInstancesBeforeMainLoop {
    if(@(Get-PendingInstanceReplacements $Config).Count){Write-Host 'An instance replacement is pending. Skipping startup repair until its registration is completed.';return}
    $inventory=Get-BootInventory -Settings $Config
    if (@($inventory.Values | Where-Object {$_.ProcessId -gt 0}).Count -gt 0) {
        Write-Host 'An LDPlayer instance is already running. Skipping startup repair and continuing to the main loop.'
        return
    }
    $ids=@($inventory.Keys | Where-Object {$Config.ExcludedLdPlayerIds -notcontains [int]$_} | Sort-Object)
    if($Config.RecoveryMode -eq 'Template'){
        $ids=@($ids|Where-Object{
            $InstanceIndex=[int]$_
            -not (Get-PendingTemplateStage)
        })
    }
    if ($ids.Count -eq 0) { Write-Host 'No included LDPlayer instances need startup repair.'; return }
    $repairPath=Join-Path $Config.LdPlayerInstallPath 'dnrepairer.exe'
    if (-not (Test-Path -LiteralPath $repairPath -PathType Leaf)) { throw "LDPlayer repair tool is missing: $repairPath" }
    $repairFile=Get-Item -LiteralPath $repairPath
    if ($repairFile.VersionInfo.FileVersion -ne '9.5.19.0') { throw 'The recorded repair command is verified for LDPlayer 9.5.19.0. The installed repair tool is another version.' }
    if ((Get-AuthenticodeSignature -LiteralPath $repairPath).Status -ne 'Valid') { throw 'The LDPlayer repair tool signature could not be verified.' }
    Write-Host "Startup repair will process $($ids.Count) included instances in ID order."
    Wait-ForLdPlayerRepairers
    foreach ($id in $ids) {
        if (Test-FlowStopRequested) {Write-Host 'Stop requested. Skipping the remaining startup repairs.';return}
        
        
        $inventory=Get-BootInventory -Settings $Config
        if (@($inventory.Values | Where-Object {$_.ProcessId -gt 0}).Count -gt 0) {
            Write-Host 'An LDPlayer instance started during preflight. Skipping the remaining startup repairs.'
            return
        }
        Write-Host "Running LDPlayer repair for instance $id..."
        Invoke-NativeLdPlayerRepair -FilePath $repairPath -Id $id
        
        
        Start-Sleep -Seconds ([math]::Max(1,$Config.InstanceRelaunchDelay))
        Invoke-Ld -Arguments @('quit','--index',"$id") | Out-Null
        $deadline=[datetime]::UtcNow.AddSeconds($Config.LdPlayerOpenTimeout)
        do {
            $inventory=Get-BootInventory -Settings $Config
            if (-not $inventory.ContainsKey([int]$id) -or $inventory[[int]$id].ProcessId -le 0) { break }
            Start-Sleep -Seconds ([math]::Max(1,$Config.PollInterval))
        } while ([datetime]::UtcNow -lt $deadline)
        if ($inventory.ContainsKey([int]$id) -and $inventory[[int]$id].ProcessId -gt 0) { throw "LDPlayer $id did not finish closing after repair. The main loop has not started." }
        Write-Host "LDPlayer repair process finished for instance $id."
    }
    Wait-ForLdPlayerRepairers
    Write-Host 'Startup repair processes have all finished. Starting the main loop.'
}

function Assert-PoolSetupTurn {
    if($script:PoolRole -and (Test-FlowStopRequested)){throw [OperationCanceledException]::new('Tool stopped before the next setup operation.')}
    if($script:PoolRole -eq 'Setup' -and $PoolWorkerControl -and $PoolWorkerControl.RetireRequested){
        $signal=[OperationCanceledException]::new('Setup worker stopped for the running-count limit. This emulator remains queued for its next turn.')
        $signal.Data['PoolNeedsSetup']=$true;$signal.Data['PoolWorkerRetired']=$true
        throw $signal
    }
    if($script:PoolRole -cne 'Monitor'){return}
    $signal=[OperationCanceledException]::new('This emulator needs a loading slot; the monitor is returning it to the setup queue.')
    $signal.Data['PoolNeedsSetup']=$true
    throw $signal
}

function Test-PoolScheduledRestartDue {
    param($InstanceInfo)
    if(-not $Config.AutoRestartHours -or -not $InstanceInfo -or $InstanceInfo.ProcessId -le 0){return $false}
    if($script:EmulatorUptimeProcessId -ne $InstanceInfo.ProcessId){
        $script:EmulatorUptimeProcessId=$InstanceInfo.ProcessId;$script:EmulatorUptimeSince=[datetime]::UtcNow
        try{$script:EmulatorUptimeSince=(Get-Process -Id $InstanceInfo.ProcessId -ErrorAction Stop).StartTime.ToUniversalTime()}catch{}
    }
    return ([datetime]::UtcNow-$script:EmulatorUptimeSince).TotalHours -ge $Config.AutoRestartHours
}

function Invoke-PoolInstanceTurn {
    param($Record,[ValidateSet('Monitor','Setup')][string]$Role,$Settings,[string[]]$StateNames)
    foreach($name in $StateNames){Set-Variable -Scope Script -Name $name -Value $null}
    foreach($name in $Record.State.Keys){Set-Variable -Scope Script -Name $name -Value $Record.State[$name]}
    $script:PoolRole=$Role
    
    $PoolWorkerControl=$Record
    $Config=$Record.Config.Clone();$Config.LdPlayerIds=@($Settings.LdPlayerIds)
    $InstanceIndex=[int]$Record.Id;$CloudflarePackage='com.cloudflare.onedotonedotonedotone';$UiDumpPath='/sdcard/launcher-flow.xml'
    $LaunchStateFile=$Settings.PoolLaunchStateFile;$LaunchMutexName=$Settings.PoolLaunchMutexName
    try{
        if($Role -eq 'Setup'){
            Enter-EmulatorLoadingSlot
            
            $cookiesReady=$false
            try{$cookiesReady=Invoke-PendingGameAppCookieUpdates}
            catch [System.Management.Automation.PipelineStoppedException]{throw}
            catch [OperationCanceledException]{throw}
            catch{Write-FlowStatus 'Captured cookie update will retry from its protected pending file; saved data was kept.'}
            if(-not $cookiesReady){
                Set-BootRequestPhase Failed
                return 'NeedsSetup'
            }
        }
        $status=Invoke-WorkerWithInstanceReplacement
        if($status -in @('WaitingForCookie','Monitoring','Retired')){return [string]$status}
        return 'Monitoring'
    }catch [OperationCanceledException]{
        if($Role -eq 'Monitor' -and $_.Exception.Data['LdCommandTimedOut']){
            $null=Request-MonitorQuickRecovery -Package $Config.GamePackage -EmulatorUnresponsive
            return 'NeedsSetup'
        }
        if($_.Exception.Data['PoolWorkerRetired'] -or $_.Exception.Data['DynamicLaunchDeferred']){
            if($script:BootRequestRecord.Phase -in @('Waiting','SettingUp')){Set-BootRequestPhase Failed}
            Write-FlowStatus $_.Exception.Message
        }
        if($_.Exception.Data['PoolNeedsSetup']){return 'NeedsSetup'}
        throw
    }finally{
        if($script:PoolReplacementConfig){$Record.Config=$script:PoolReplacementConfig}
        $saved=@{}
        foreach($name in $StateNames){$saved[$name]=Get-Variable -Scope Script -Name $name -ValueOnly -ErrorAction SilentlyContinue}
        $Record.State=$saved
        foreach($name in $StateNames){Set-Variable -Scope Script -Name $name -Value $null}
        $Config=$null;$script:PoolRole=$null
    }
}

function New-EmulatorPoolRunspace {
    param([string]$Definitions,[string]$Role,[int]$Number)
    $runspace=[Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState='STA';$runspace.ThreadOptions='ReuseThread';$runspace.Open()
    $initializer=[Management.Automation.PowerShell]::Create();$initializer.Runspace=$runspace
    try{
        $null=$initializer.AddScript((' $ErrorActionPreference="Stop";'+"`n"+$Definitions),$false)
        $null=$initializer.Invoke()
        if($initializer.HadErrors){throw ('Worker initialization failed: '+$initializer.Streams.Error[0].Exception.Message)}
        return @{Runspace=$runspace;Role=$Role;Number=$Number;Task=$null;Record=$null;Handle=$null;ErrorSeen=$false;NextWorkCheck=[datetime]::MinValue}
    }catch{$runspace.Dispose();throw}
    finally{$initializer.Dispose()}
}

function Test-EmulatorPoolWorkDue {
    param($Worker,[datetime]$Now=[datetime]::UtcNow)
    if($Worker.Task -or $Worker.NextWorkCheck -gt $Now){return $false}
    $Worker.NextWorkCheck=$Now.AddSeconds(3)
    return $true
}

function Wait-EmulatorPoolWork {
    param($Workers)
    if(@($Workers|Where-Object{$_.Task}).Count){Start-Sleep -Milliseconds 100;return}
    
    
    $deadline=[datetime]::UtcNow.AddSeconds(3)
    while([datetime]::UtcNow -lt $deadline){
        if(Test-FlowStopRequested){return}
        Start-Sleep -Milliseconds 100
    }
}

function Start-EmulatorPoolTurn {
    param($Worker,$Record,$Settings)
    if($Worker.Task -or $Record.BusyRole){throw 'An emulator is already owned by a worker.'}
    if(-not $Record.LaunchOwner){$Record.LaunchOwner=[guid]::NewGuid().ToString('N')}
    $Worker.StopReason=$null
    
    
    $Worker.NextWorkCheck=[datetime]::MinValue
    $Record.RetireRequested=$false
    $Record.BusyRole=$Worker.Role
    $task=[Management.Automation.PowerShell]::Create();$task.Runspace=$Worker.Runspace
    try{
        $null=$task.AddScript('param($Record,$Role,$Settings,$StateNames) Invoke-PoolInstanceTurn $Record $Role $Settings $StateNames',$false).AddArgument($Record).AddArgument($Worker.Role).AddArgument($Settings).AddArgument($Settings.PoolStateNames)
        $Worker.Record=$Record;$Worker.Task=$task;$Worker.ErrorSeen=$false
        $Worker.Handle=$task.BeginInvoke()
    }catch{$Record.BusyRole='';$Worker.Record=$null;$Worker.Task=$null;$Worker.Handle=$null;$task.Dispose();throw}
}

function Write-EmulatorPoolTurnMessages {
    param($Worker)
    if(-not $Worker.Task){return}
    foreach($entry in @($Worker.Task.Streams.Information.ReadAll())){
        if($entry.MessageData){Write-Host ([string]$entry.MessageData)}
    }
    foreach($entry in @($Worker.Task.Streams.Warning.ReadAll())){Write-Host ([string]$entry.Message)}
    foreach($entry in @($Worker.Task.Streams.Error.ReadAll())){
        $Worker.ErrorSeen=$true
        if(-not $Worker.StopReason -and -not (Test-FlowStopRequested)){Write-Host ("[LDPlayer $($Worker.Record.Id)] Worker turn will retry: "+$entry.Exception.Message)}
    }
}

function Complete-EmulatorPoolTurn {
    param($Worker,$Settings)
    if(-not $Worker.Task -or -not $Worker.Handle.IsCompleted){return $false}
    $record=$Worker.Record;$status='NeedsSetup'
    try{
        $values=@($Worker.Task.EndInvoke($Worker.Handle))
        Write-EmulatorPoolTurnMessages $Worker
        if(-not $Worker.ErrorSeen){
            $statuses=@($values|ForEach-Object{[string]$_}|Where-Object{$_ -in @('NeedsSetup','Monitoring','WaitingForCookie','Retired')})
            if($statuses.Count){$status=$statuses[-1]}
            elseif(-not $Worker.StopReason -and -not (Test-FlowStopRequested)){Write-Host "[LDPlayer $($record.Id)] Worker returned no completed turn; setup will retry."}
        }
    }catch{
        if(-not $Worker.StopReason -and -not (Test-FlowStopRequested)){Write-Host ("[LDPlayer $($record.Id)] Worker turn will retry: "+$_.Exception.Message)}
    }finally{
        $record.Status=$status;$record.BusyRole=''
        $delay=[math]::Max(1,[int]$Settings.GameCheckInterval)
        if($status -eq 'NeedsSetup'){$delay=[math]::Max(1,[int]$Settings.RetryDelay)}
        $record.NextCheckAt=[datetime]::UtcNow.AddSeconds($delay)
        $Worker.Task.Dispose();$Worker.Task=$null;$Worker.Handle=$null;$Worker.Record=$null
    }
    return $true
}

function Sync-EmulatorPoolReplacementRecords {
    param($Settings,[object[]]$Records)
    foreach($record in $Records){
        if($record.Proxy.Name -notmatch '^LDPlayer-(\d+)$'){throw 'An emulator worker assignment has an invalid replacement ID.'}
        $newId=[int]$Matches[1]
        if($record.Id -eq $newId){continue}
        if(@($Records|Where-Object{$_ -ne $record -and $_.Id -eq $newId}).Count){throw 'A replacement ID is already assigned to another emulator record.'}
        $oldId=$record.Id;$record.Id=$newId
        $record.Config.LdPlayerIds=@($Settings.LdPlayerIds)
        $record.Config.ExcludedLdPlayerIds=@($Settings.ExcludedLdPlayerIds)
        Write-Host "Worker-pool assignment moved from LDPlayer $oldId to $newId."
    }
}

function Sync-EmulatorPoolCapacity {
    param($Workers,[int]$Capacity,[string]$Definitions)
    foreach($worker in @($Workers|Where-Object{$_.Role -eq 'Setup'})){
        if($worker.Number -le $Capacity){
            $worker.Retiring=$false
            if($worker.Record){$worker.Record.RetireRequested=$false}
            continue
        }
        if($worker.Task){
            if(-not $worker.Retiring){Write-Host "Setup worker $($worker.Number) is stopping at its next safe step. Its emulator will remain queued if more work is needed."}
            $worker.Retiring=$true;$worker.Record.RetireRequested=$true
        }else{
            $worker.Runspace.Close();$worker.Runspace.Dispose();$null=$Workers.Remove($worker)
            Write-Host "Setup worker $($worker.Number) stopped for the current loading limit."
        }
    }
    for($number=1;$number -le $Capacity;$number++){
        if(@($Workers|Where-Object{$_.Role -eq 'Setup' -and $_.Number -eq $number}).Count){continue}
        $Workers.Add((New-EmulatorPoolRunspace $Definitions 'Setup' $number))
        Write-Host "Setup worker $number started for the current loading limit."
    }
}

function Get-EmulatorReplacementStatus {
    param($Settings,$Records,$State)
    $paths=Get-InstanceReplacementPaths $Settings
    if(-not $paths){return @()}
    if(-not $State.ReplacementCache){$State.ReplacementCache=@{}}
    if(-not $State.NextReplacementRead -or $State.NextReplacementRead -le [datetime]::UtcNow){
        $State.NextReplacementRead=[datetime]::UtcNow.AddSeconds(1)
        try{
            $historyStamp='absent'
            if([IO.File]::Exists($paths.History)){$historyFile=Get-Item -LiteralPath $paths.History;$historyStamp="$($historyFile.LastWriteTimeUtc.Ticks)|$($historyFile.Length)"}
            if($State.ReplacementHistoryStamp -cne $historyStamp){
                $State.ReplacementHistory=Read-InstanceReplacementHistory $Settings
                $State.ReplacementSuccessors=New-InstanceReplacementSuccessorIndex $State.ReplacementHistory
                $State.ReplacementHistoryStamp=$historyStamp
            }
        }catch{if(-not $State.ReplacementHistory){$State.ReplacementHistory=@{};$State.ReplacementSuccessors=@{}}}
        $ids=@($Records|ForEach-Object{[int]$_.Id})
        foreach($id in @($State.ReplacementCache.Keys)){if($ids -notcontains $id){$State.ReplacementCache.Remove($id)}}
        foreach($record in $Records){
            $id=[int]$record.Id;$path=Join-Path $paths.State "replacement-$id.json"
            try{
                if(-not [IO.File]::Exists($path)){$State.ReplacementCache.Remove($id);continue}
                $file=Get-Item -LiteralPath $path;$stamp="$($file.LastWriteTimeUtc.Ticks)|$($file.Length)"
                if($State.ReplacementCache.ContainsKey($id) -and $State.ReplacementCache[$id].Stamp -ceq $stamp){continue}
                $journal=ConvertFrom-Json ([IO.File]::ReadAllText($path))
                $oldId=0;$newId=0
                if($journal.Kind -cne 'InstanceReplacement' -or -not [int]::TryParse([string]$journal.OldId,[ref]$oldId) -or -not [int]::TryParse([string]$journal.NewId,[ref]$newId) -or $oldId -ne $id -or $newId -le $id){continue}
                $State.ReplacementCache[$id]=@{Stamp=$stamp;Journal=$journal}
            }catch{} 
        }
    }
    foreach($record in @($Records|Sort-Object {[int]$_.Id})){
        $cached=$State.ReplacementCache[[int]$record.Id]
        if(-not $cached -or -not (Test-InstanceReplacementPending $cached.Journal)){continue}
        $journal=$cached.Journal
        $successor=Get-InstanceReplacementSuccessor $Settings $journal $State.ReplacementHistory $State.ReplacementSuccessors
        $step=if($journal.Step){[string]$journal.Step}else{[string]$journal.Phase}
        @{FromId=[int]$journal.OldId;ToId=[int]$journal.NewId;Chain=$successor.Chain;Step=$step;Retrying=[bool]$journal.LastError;Reason=[string]$journal.LastError;Queued=($record.BusyRole -ne 'Setup')}
    }
}

function Set-EmulatorLiveObservation {
    param([string]$EmulatorState,[string]$AppState,[string]$Package=$Config.GamePackage,[switch]$ResetApps)
    
    
    if($script:PoolRole -notin @('Monitor','Setup') -or -not $PoolWorkerControl){return}
    try{
        $previous=$PoolWorkerControl.LiveStatus
        if($previous.InstanceId -ne $InstanceIndex){$previous=$null}
        $packages=@($Config.GamePackages);if(-not $packages.Count -or -not $packages[0]){$packages=@($Config.GamePackage)}
        $apps=@(foreach($name in $packages){
            if(-not $name){continue}
            $state='Pending'
            if(-not $ResetApps -and $previous){$old=@($previous.Apps|Where-Object{$_.Package -ceq $name})|Select-Object -First 1;if($old){$state=[string]$old.State}}
            if($AppState -and $name -ceq $Package){$state=switch($AppState){'Minimized'{'Hidden'};'Background'{'Hidden'};default{$AppState}}}
            @{Package=[string]$name;State=$state}
        })
        $boot=if($EmulatorState){$EmulatorState}elseif($previous.EmulatorState){[string]$previous.EmulatorState}else{'Checking'}
        $PoolWorkerControl.LiveStatus=@{InstanceId=[int]$InstanceIndex;EmulatorState=$boot;Apps=$apps}
    }catch{} 
}

function Publish-GameAppObservation {
    param([string]$State)
    Set-EmulatorLiveObservation -AppState $State -Package $Config.GamePackage
    return $State
}

function Get-EmulatorLiveStatusModel {
    param($Record,[switch]$Stopped)
    if($Stopped){return @{Id=[int]$Record.Id;Status='Monitoring stopped'}}
    $snapshot=$Record.LiveStatus
    if($snapshot.InstanceId -ne $Record.Id){$snapshot=$null}
    $boot=[string]$snapshot.EmulatorState;$apps=@($snapshot.Apps)
    $summary=switch($boot){
        'Offline'{'Offline'};'Unresponsive'{'Unresponsive'};'Starting'{'Starting'};'Restarting'{'Restarting'};'Replacing'{'Replacing'};'CloseRequested'{'Emulator close requested'};'Unknown'{'Status unavailable'}
        default{
            $observed=@($apps|Where-Object{$null -ne $_ -and $_.Package})
            if($observed.Count -gt 0 -and @($observed|Where-Object{$_.State -ne 'InGame'}).Count -eq 0){'InGame'}
            elseif(-not $observed.Count -or @($observed|Where-Object{$_.State -ne 'Pending'}).Count -eq 0){'Checking'}
            else{
                $parts=@();$index=0
                foreach($app in $observed){
                    $label=if($index -lt 26){'App '+[char](65+$index)}else{'App '+($index+1)};$index++
                    if($app.State -eq 'InGame'){continue}
                    $state=switch($app.State){'Pending'{'checking'};'Unknown'{'status unavailable'};'Hidden'{'hidden'};'CloseRequested'{'close requested'};'Login'{'waiting for login'};'Blocked'{'account/access error'};'StartupConnectionFailed'{'connection error'};default{([string]$app.State).ToLowerInvariant()}}
                    $parts+=$label+' '+$state
                }
                $parts -join ', '
            }
        }
    }
    $queued=$Record.Status -eq 'NeedsSetup' -and $Record.BusyRole -ne 'Setup'
    if($queued){$summary=if($summary -eq 'Checking'){'Queued for setup'}else{$summary+' (queued)'}}
    elseif($Record.BusyRole -eq 'Setup'){$summary=if($summary -eq 'Checking'){'Setting up'}elseif($summary -in @('Starting','Restarting','Replacing')){$summary}else{$summary+' (setup)'}}
    return @{Id=[int]$Record.Id;Status=[string]$summary}
}

function Publish-EmulatorWorkerStatus {
    param($Workers,$State,[switch]$Stopped,$Settings=$Config,$Records=@())
    if(-not $State.Path){return}
    if(-not $Stopped -and $State.NextPublish -gt [datetime]::UtcNow){return}
    $State.NextPublish=[datetime]::UtcNow.AddMilliseconds(200)
    $models=@(foreach($worker in $Workers){
        $id=if(-not $Stopped -and $worker.Task -and $worker.Record){[int]$worker.Record.Id}else{$null}
        @{Role=[string]$worker.Role;Number=[int]$worker.Number;InstanceId=$id;Retiring=[bool]$worker.Retiring}
    })
    $replacements=@()
    try{if(-not $Stopped){$replacements=@(Get-EmulatorReplacementStatus $Settings $Records $State)}}
    catch{} 
    $emulators=@()
    try{$emulators=@(foreach($record in @($Records|Where-Object{$_.Status -ne 'Retired'}|Sort-Object {[int]$_.Id})){Get-EmulatorLiveStatusModel $record -Stopped:$Stopped})}
    catch{} 
    $document=@{Version=1;Workers=$models;Replacements=$replacements;Emulators=$emulators}
    $fingerprint=ConvertTo-Json -InputObject $document -Depth 5 -Compress
    if($State.Fingerprint -ceq $fingerprint){return}
    try{
        Write-TemplateStageManifest $State.Path $document
        $State.Fingerprint=$fingerprint;$State.ErrorReported=$false
    }catch{
        if(-not $State.ErrorReported){Write-Host 'Live worker status could not be published. Emulator workers will continue.';$State.ErrorReported=$true}
    }
}

function Invoke-FixedEmulatorWorkerPool {
    param($Settings,[string]$FunctionDefinitions,[string]$StateFile,[string]$MutexName,[object[]]$Assignments)
    $Config=$Settings
    $count=[int](Get-LoadingLimitPolicy $Settings).WorkerCapacity
    $dynamic=[bool](Get-LoadingLimitPolicy $Settings).Dynamic
    $desiredCapacity=if($dynamic){0}else{$count}
    $records=New-Object 'System.Collections.Generic.List[object]'
    foreach($assignment in @($Assignments|Sort-Object {[int]$_.InstanceId})){
        $workerSettings=$Settings.Clone();$workerSettings.ServerLink=$assignment.ServerLink
        $record=@{Id=[int]$assignment.InstanceId;Config=$workerSettings;State=@{};Status='NeedsMonitor';BusyRole='';NextCheckAt=[datetime]::MinValue;Proxy=[pscustomobject]@{Name="LDPlayer-$($assignment.InstanceId)"}}
        $records.Add($record)
    }
    if(-not $records.Count){return @()}
    $Settings.PoolLaunchStateFile=$StateFile;$Settings.PoolLaunchMutexName=$MutexName
    $scheduler=New-BootScheduler -Settings $Settings -StateFile $StateFile
    $layoutState=@{NextAttempt=[datetime]::MinValue}
    $workers=New-Object 'System.Collections.Generic.List[object]'
    $workerStatus=@{Path=$(if($StateFile){Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($StateFile))) 'worker-status.json'}else{''});Fingerprint='';NextPublish=[datetime]::MinValue;ErrorReported=$false}
    $lastMonitorId=-1
    $thresholdWaitId=-1
    try{
        $workers.Add((New-EmulatorPoolRunspace $FunctionDefinitions 'Monitor' 0))
        Sync-EmulatorPoolCapacity $workers $desiredCapacity $FunctionDefinitions
        Write-Host "Started 1 monitor for $($records.Count) emulators. Setup workers follow the current loading limit."
        while($true){
            foreach($worker in $workers){Write-EmulatorPoolTurnMessages $worker;$null=Complete-EmulatorPoolTurn $worker $Settings}
            foreach($record in @($records|Where-Object{$_.Status -eq 'Retired' -and -not $_.BusyRole})){
                $id=[int]$record.Id;$null=$records.Remove($record)
                $Settings.LdPlayerIds=@($Settings.LdPlayerIds|Where-Object{$_ -ne $id})
                $Settings.ExcludedLdPlayerIds=@(@($Settings.ExcludedLdPlayerIds)+@($id)|Sort-Object -Unique)
                $scheduler.Active.Remove($id);$scheduler.InitialPending=@($scheduler.InitialPending|Where-Object{$_ -ne $id})
                Write-Host "Removed obsolete LDPlayer $id from the worker pool after its replacement chain was finalized."
            }
            if(Test-FlowStopRequested){
                $activeRestoreIds=@()
                try{$activeRestoreIds=@(Get-ActiveRestoreInstanceIds)}catch{Write-Host 'Waiting to verify active instance replacements before stopping...';Start-Sleep -Milliseconds 500;continue}
                foreach($worker in $workers){
                    if($worker.Task -and $worker.Record.Id -notin $activeRestoreIds -and -not $worker.Handle.IsCompleted){
                        $worker.StopReason='Tool stopped';try{$worker.Task.Stop()}catch{}
                    }
                }
                if(@($workers|Where-Object{$_.Task -and -not $_.Handle.IsCompleted}).Count -eq 0){break}
                Start-Sleep -Milliseconds 200;continue
            }
            try{
                Update-InstanceReplacementHandoffs -Settings $Settings -Jobs @($records|ForEach-Object{$_.Proxy}) -Scheduler $scheduler
                Sync-EmulatorPoolReplacementRecords $Settings $records.ToArray()
            }catch [System.Management.Automation.PipelineStoppedException]{throw}
            catch [OperationCanceledException]{throw}
            catch{Write-Host ('Replacement worker handoff will retry: '+$_.Exception.Message)}
            try{Update-EmulatorWindowLayout -Settings $Settings -State $layoutState}catch{Write-Host ('Window arrangement will retry: '+$_.Exception.Message)}
            try{Update-CookieOverwriteTracking -Settings $Settings}catch{Write-Host ('Cookie overwrite status will retry: '+$_.Exception.Message)}
            try{Update-BootScheduler -Scheduler $scheduler -AliveIds @($records|ForEach-Object{[int]$_.Id})}
            catch [System.Management.Automation.PipelineStoppedException]{throw}
            catch [OperationCanceledException]{throw}
            catch{Write-Host ('Emulator setup queue will retry: '+$_.Exception.Message)}
            
            
            $dispatchLimit=$count
            if($scheduler.ContainsKey('CurrentLimit')){$dispatchLimit=if($null -eq $scheduler.CurrentLimit){0}else{[math]::Min($count,[int]$scheduler.CurrentLimit)}}
            
            
            $launchGate=@{Busy=$false;Owner=''}
            if($dynamic){
                try{$launchGate=Update-DynamicLaunchGate $scheduler $records.ToArray()}
                catch{Write-Host ('New emulator starts are waiting: '+$_.Exception.Message);$launchGate=@{Busy=$true;Owner=''}}
            }
            if($dispatchLimit -gt 0){
                if(-not $dynamic){$desiredCapacity=$dispatchLimit}
                elseif($desiredCapacity -gt $dispatchLimit){$desiredCapacity=$dispatchLimit}
                elseif($desiredCapacity -lt $dispatchLimit -and -not $launchGate.Busy){
                    $idle=@($workers|Where-Object{$_.Role -eq 'Setup' -and -not $_.Task -and -not $_.Retiring}).Count
                    $demand=@($records|Where-Object{-not $_.BusyRole -and $_.Status -eq 'NeedsSetup' -and $_.NextCheckAt -le [datetime]::UtcNow -and (-not $launchGate.Owner -or $_.LaunchOwner -ceq $launchGate.Owner)}).Count
                    
                    
                    if($demand -gt 0 -and $idle -eq 0 -and (-not $launchGate.Owner -or $desiredCapacity -eq 0)){$desiredCapacity++}
                }
            }
            Sync-EmulatorPoolCapacity $workers $desiredCapacity $FunctionDefinitions
            $setupBusy=@($workers|Where-Object{$_.Role -eq 'Setup' -and $_.Task}).Count
            foreach($worker in @($workers|Where-Object{$_.Role -eq 'Setup' -and -not $_.Task -and -not $_.Retiring})){
                if($setupBusy -ge $dispatchLimit){break}
                if($launchGate.Busy){break}
                if(-not (Test-EmulatorPoolWorkDue $worker)){continue}
                $eligible=@($records|Where-Object{-not $_.BusyRole -and $_.Status -eq 'NeedsSetup' -and $_.NextCheckAt -le [datetime]::UtcNow}|Sort-Object {[int]$_.Id})
                if($dynamic -and $launchGate.Owner){$eligible=@($eligible|Where-Object{$_.LaunchOwner -ceq $launchGate.Owner})}
                $candidate=$null
                $pendingRunningIds=@(if($dynamic -and $scheduler.Inventory){foreach($pending in $records){$row=$scheduler.Inventory[[int]$pending.Id];if($pending.Status -eq 'NeedsSetup' -and $row -and ($row.ProcessId -gt 0 -or $row.AndroidStarted)){[int]$pending.Id}}})
                $loadingIds=@(@($scheduler.Active.Keys)+@($workers|Where-Object{$_.Role -eq 'Setup' -and $_.Task}|ForEach-Object{$_.Record.Id})+$pendingRunningIds|ForEach-Object{[int]$_}|Sort-Object -Unique)
                foreach($next in $eligible){
                    $otherLoads=$loadingIds.Count
                    if($loadingIds -contains [int]$next.Id){$otherLoads--}
                    if($dynamic -and (Test-ThresholdLaunchWait $Settings $scheduler.Inventory ([int]$next.Id) $otherLoads)){
                        if($thresholdWaitId -lt 0){Write-Host "Waiting to start LDPlayer $($next.Id): finish the current loading group before crossing the running threshold and reducing the loading limit.";$thresholdWaitId=[int]$next.Id}
                        continue
                    }
                    $candidate=$next;break
                }
                if(-not $candidate){break}
                if($dynamic){
                    $row=if($scheduler.Inventory){$scheduler.Inventory[[int]$candidate.Id]}else{$null}
                    $reserve=if(-not $row -or $row.ProcessId -le 0){$candidate}else{$null}
                    try{$launchGate=Update-DynamicLaunchGate $scheduler $records.ToArray() $reserve}catch{Write-Host ('Emulator launch reservation will retry: '+$_.Exception.Message);break}
                    if($launchGate.Busy -or ($launchGate.Owner -and $launchGate.Owner -cne $candidate.LaunchOwner)){break}
                }
                Start-EmulatorPoolTurn $worker $candidate $Settings
                $thresholdWaitId=-1
                $setupBusy++
                if($dynamic -and $launchGate.Owner){break}
            }
            $monitor=$workers[0]
            if(-not $monitor.Task -and (Test-EmulatorPoolWorkDue $monitor)){
                $eligible=@($records|Where-Object{-not $_.BusyRole -and $_.Status -ne 'NeedsSetup' -and $_.NextCheckAt -le [datetime]::UtcNow}|Sort-Object {[int]$_.Id})
                $candidate=@($eligible|Where-Object{$_.Id -gt $lastMonitorId})|Select-Object -First 1
                if(-not $candidate){$candidate=$eligible|Select-Object -First 1}
                if($candidate){$lastMonitorId=[int]$candidate.Id;Start-EmulatorPoolTurn $monitor $candidate $Settings}
            }
            Publish-EmulatorWorkerStatus -Workers $workers -State $workerStatus -Settings $Settings -Records $records.ToArray()
            Wait-EmulatorPoolWork $workers
        }
        foreach($worker in $workers){Write-EmulatorPoolTurnMessages $worker;$null=Complete-EmulatorPoolTurn $worker $Settings}
        return @($records|ForEach-Object{[pscustomobject]@{InstanceId=[int]$_.Id;Succeeded=$true;Action='MonitorStopped'}})
    }finally{
        foreach($worker in $workers){
            if($worker.Task){
                
                
                $diskActive=$false
                try{$diskActive=$worker.Record.Id -in @(Get-ActiveRestoreInstanceIds)}catch{$diskActive=$true}
                if($diskActive){while(-not $worker.Handle.IsCompleted){Write-EmulatorPoolTurnMessages $worker;Start-Sleep -Milliseconds 500}}
                elseif(-not $worker.Handle.IsCompleted){$worker.StopReason='Controller shutdown';try{$worker.Task.Stop()}catch{}}
                $null=Complete-EmulatorPoolTurn $worker $Settings
            }
            $worker.Runspace.Close();$worker.Runspace.Dispose()
        }
        Publish-EmulatorWorkerStatus -Workers $workers -State $workerStatus -Stopped
    }
}


function Invoke-SelectedEmulators {
    param($Settings,[string]$FunctionDefinitions,[string]$StateFile,[string]$MutexName)
    $Settings.LdPlayerIds=@(Get-SelectedLdPlayerIds -Settings $Settings)
    if(-not $Settings.LdPlayerIds.Count){Write-Host 'No LDPlayer instances remain after applying the exclusions.';return @()}
    $assignments=@(Get-EmulatorServerAssignments -Settings $Settings)
    $Settings.LdPlayerIds=@($assignments|ForEach-Object{$_.InstanceId})
    Initialize-CookieCheckTracking -Settings $Settings -Directory ([IO.Path]::GetDirectoryName($StateFile))
    if($Settings.LogSnapshotLdPlayerId -ge 0 -and $Settings.LdPlayerIds -notcontains $Settings.LogSnapshotLdPlayerId){Write-Host "Log snapshot target LDPlayer $($Settings.LogSnapshotLdPlayerId) is not included. No snapshot will be taken for it."}
    $Settings.WindowLayoutDirectory=Join-Path ([IO.Path]::GetDirectoryName($StateFile)) 'window-layout'
    $Settings.ReplacementHandoffDirectory=Join-Path ([IO.Path]::GetDirectoryName($StateFile)) 'replacement-handoffs'
    $null=[IO.Directory]::CreateDirectory($Settings.WindowLayoutDirectory)
    $null=[IO.Directory]::CreateDirectory($Settings.ReplacementHandoffDirectory)
    
    
    $Settings.PoolStateNames=@([regex]::Matches($FunctionDefinitions,'\$script:([A-Za-z][A-Za-z0-9_]*)')|ForEach-Object{$_.Groups[1].Value}|Where-Object{$_ -notin @('Ui','PoolRole')}|Sort-Object -Unique)
    return Invoke-FixedEmulatorWorkerPool $Settings $FunctionDefinitions $StateFile $MutexName $assignments
}

function Read-LauncherUiConfig {
    param([string]$Path)
    $values=[ordered]@{}
    foreach($line in [IO.File]::ReadAllLines($Path)) {
        if($line -match '^\s*([^#;=]+)=(.*)$') {$values[(ConvertTo-LauncherConfigKey $Matches[1].Trim())]=$Matches[2].Trim()}
    }
    return $values
}

function Get-LauncherUiCookieSettings {
    param([string]$Directory)
    $values=Read-LauncherUiConfig (Join-Path $Directory 'config.ini')
    $packages=@()
    if($values.GamePackages){$packages=@($values.GamePackages -split ','|ForEach-Object{$_.Trim()})}
    elseif($values.GamePackage){$packages=@($values.GamePackage)}
    else{$packages=@('local.deltalite.a')}
    $path=Join-Path $Directory 'cookies.json'
    $hash=[Security.Cryptography.SHA256]::Create()
    try{$digest=[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($path.ToLowerInvariant()))).Replace('-','')}finally{$hash.Dispose()}
    return @{CookieStorePath=$path;CookieStoreMutexName=('Local\CodexCookieStore-'+$digest.Substring(0,24));GamePackages=$packages;GamePackage=$packages[0];CommandTimeout=30}
}

function Set-LauncherUiProperty {
    param($Control,[string]$Name,$Value)
    if($null -ne $Control -and -not [object]::Equals($Control.$Name,$Value)){$Control.$Name=$Value}
}

function Enable-LauncherGridBuffering {
    param($Grid)
    
    
    try {
        $property=[Windows.Forms.Control].GetProperty('DoubleBuffered',[Reflection.BindingFlags]'Instance,NonPublic')
        if($property){$property.SetValue($Grid,$true,$null)}
    }catch{}
}

function Write-LauncherUiStartupError {
    param($Failure)
    $message=$Failure.Exception.Message
    $details="launcher UI startup failed`r`nTime: $([datetime]::Now.ToString('s'))`r`nPowerShell: $($PSVersionTable.PSVersion)`r`n.NET: $([Environment]::Version)`r`nError: $message`r`nLocation: $($Failure.ScriptStackTrace)`r`n"
    
    
    [Console]::Error.WriteLine($details)
    $directory=[IO.Path]::GetDirectoryName($env:LAUNCHER_FLOW_FILE)
    $fallback=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Launcher'
    foreach($folder in @($directory,$fallback)){
        try {
            if(-not $folder){continue}
            $null=[IO.Directory]::CreateDirectory($folder)
            $path=Join-Path $folder 'launcher-ui-error.log'
            [IO.File]::WriteAllText($path,$details,[Text.UTF8Encoding]::new($false))
            return $path
        }catch{}
    }
    return ''
}

function Add-LauncherUiLog {
    param([string]$Text)
    if(-not $Text){return}
    if($Ui.LogArchiveWriter){
        try{$Ui.LogArchiveWriter.Write($Text);$Ui.LogArchiveWriter.Flush()}
        catch{$Ui.LogArchiveError=$true}
    }
    $Ui.Log.AppendText($Text)
    if($Ui.Log.TextLength -gt 200000){
        $current=$Ui.Log.Text
        $start=[math]::Max(0,$current.Length-100000)
        $line=$current.IndexOf("`n",$start)
        if($line -ge 0 -and $line+1 -lt $current.Length){$start=$line+1}
        
        
        $Ui.Log.Text=$current.Substring($start)
    }
    $Ui.Log.SelectionStart=$Ui.Log.TextLength; $Ui.Log.ScrollToCaret()
}

function Copy-LauncherUiText {
    param([string]$Text)
    if(-not $Text){throw 'There are no logs to copy yet.'}
    [Windows.Forms.Clipboard]::SetText($Text,[Windows.Forms.TextDataFormat]::UnicodeText)
}

function Copy-LauncherUiLiveLog {
    if($Ui.OutputSink){Add-LauncherUiLog ($Ui.OutputSink.Drain())}
    if($Ui.LogArchiveError){throw 'The full live-log archive could not be written. Copy the visible text instead.'}
    $text=$Ui.Log.Text
    if($Ui.LogArchiveWriter){
        $Ui.LogArchiveWriter.Flush()
        $reader=[IO.StreamReader]::new([IO.File]::Open($Ui.LogArchivePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite),[Text.Encoding]::UTF8)
        try{$text=$reader.ReadToEnd()}finally{$reader.Dispose()}
    }
    Copy-LauncherUiText $text
    Set-LauncherUiProperty $Ui.LogCopyStatus Text 'Copied all live logs.'
}

function Get-LauncherLogReadSettings {
    param([string]$ConfigPath)
    $values=Read-LauncherUiConfig $ConfigPath
    $settings=Get-LauncherUiCookieSettings ([IO.Path]::GetDirectoryName($ConfigPath))
    $folder=$values.LdPlayerInstallPath
    if(-not $folder -and $values.LdConsolePath){$folder=[IO.Path]::GetDirectoryName($values.LdConsolePath)}
    if(-not $folder){$folder='C:\LDPlayer\LDPlayer9'}
    $folder=[Environment]::ExpandEnvironmentVariables($folder.Trim('"'))
    foreach($name in @('ldconsole.exe','dnconsole.exe')){
        $candidate=Join-Path $folder $name
        if(Test-Path -LiteralPath $candidate -PathType Leaf){$settings.LdConsolePath=$candidate;break}
    }
    if(-not $settings.LdConsolePath){throw 'Check the LDPlayer installation folder in Settings.'}
    $settings.MinCheckDelay=1
    $delay=0;if([int]::TryParse([string]$values.MinCheckDelay,[ref]$delay) -and $delay -ge 1){$settings.MinCheckDelay=$delay}
    foreach($package in $settings.GamePackages){if($package -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$'){throw 'The configured game package name is invalid.'}}
    return $settings
}

function Get-LauncherEmulatorLogText {
    param([int]$Id)
    $InstanceIndex=$Id
    $deadline=[datetime]::UtcNow.AddSeconds(90)
    $instance=Get-InstanceInfo -Id $Id
    if(-not $instance -or $instance.ProcessId -le 0 -or -not $instance.AndroidStarted){throw "LDPlayer $Id must be running with Android started before copying its logs."}
    $text=New-Object Text.StringBuilder
    $null=$text.AppendLine("LDPlayer $Id - current game app logs")
    $null=$text.AppendLine('Captured: '+[datetime]::Now.ToString('o'))
    $captured=0
    foreach($package in $Config.GamePackages){
        $null=$text.AppendLine("`r`n===== $package =====")
        try{
            $reply=(Invoke-Android "shell pidof $package" -TimeoutSeconds (Get-CommandBudget $deadline)).Trim()
            if($reply -notmatch '^\d+(?:\s+\d+)*$'){
                if($reply){throw 'Android did not return valid app process IDs.'}
                $null=$text.AppendLine('App is not running; no current log is available.');continue
            }
            $found=$false
            foreach($appProcessId in ($reply -split '\s+')){
                $descriptors=Invoke-Android "shell su -c 'ls -l /proc/$appProcessId/fd'" -TimeoutSeconds (Get-CommandBudget $deadline)
                $pattern='(?m)^\S+[^\r\n]*?\s(?<fd>\d+)\s+->\s+(?<log>/data/(?:data|user/0)/'+[regex]::Escape($package)+'/files/appData/logs/[^\r\n]*_Player_[^\r\n]*\.log)\s*(?:\(deleted\))?\s*$'
                $handle=[regex]::Matches($descriptors,$pattern) | Sort-Object {$_.Groups['log'].Value} -Descending | Select-Object -First 1
                if(-not $handle){continue}
                $fd=$handle.Groups['fd'].Value
                $raw=Invoke-Android "shell su -c 'cat /proc/$appProcessId/fd/$fd'" -TimeoutSeconds (Get-CommandBudget $deadline)
                if(-not $raw -or $raw -match '(?m)^(?:cat:|su:).*?(?:Permission denied|No such file|not found)'){throw 'The current player log could not be read.'}
                
                $raw=[regex]::Replace($raw,'(?i)(\.ROBLOSECURITY\s*[=:]\s*["'']?)[^\s;"''<>]+','$1[REDACTED]')
                $raw=[regex]::Replace($raw,'(?im)(\b(?:Cookie|Authorization):\s*)[^\r\n]+','$1[REDACTED]')
                $null=$text.AppendLine("--- PID $appProcessId ---")
                $null=$text.AppendLine($raw.Replace([string][char]0,''));$found=$true;$captured++
            }
            if(-not $found){$null=$text.AppendLine('App is running, but no current Player log was found. Check Android root access.')}
        }catch{$null=$text.AppendLine('Log unavailable: '+$_.Exception.Message)}
    }
    if(-not $captured){throw ('No game logs could be captured. '+$text.ToString())}
    return $text.ToString()
}

function Start-LauncherUiEmulatorLogCopy {
    if($Ui.ForceClosePending -or $Ui.ForceCloseTask){throw 'Wait for force close to finish.'}
    if($Ui.LogReadTask){return}
    $names=@('ConvertTo-LauncherConfigKey','Read-LauncherUiConfig','Get-LauncherUiCookieSettings','Get-LauncherLogReadSettings','ConvertTo-NativeArgument','Test-StatusCheckCommand','Wait-StatusCheckSlot','Start-LauncherProcess','Invoke-Ld','New-LdCommandTimeoutError','Invoke-Android','Get-InstanceInfo','Get-CommandBudget','Get-LauncherEmulatorLogText')
    $definitions=foreach($name in $names){'function '+$name+" {`r`n"+(Get-Command $name -CommandType Function).Definition+"`r`n}"}
    $worker=[Management.Automation.PowerShell]::Create()
    try{
        $code='param($Definitions,$ConfigPath,$Id) $ErrorActionPreference="Stop"; . ([scriptblock]::Create($Definitions)); $Config=Get-LauncherLogReadSettings $ConfigPath; Get-LauncherEmulatorLogText -Id $Id'
        $null=$worker.AddScript($code).AddArgument(($definitions -join "`r`n")).AddArgument($Ui.ConfigPath).AddArgument([int]$Ui.LogEmulatorId.Value)
        $handle=$worker.BeginInvoke()
        $Ui.LogReadTask=@{Worker=$worker;Handle=$handle;Id=[int]$Ui.LogEmulatorId.Value}
        Set-LauncherUiProperty $Ui.CopyEmulatorLog Enabled $false
        Set-LauncherUiProperty $Ui.LogEmulatorId Enabled $false
        Set-LauncherUiProperty $Ui.LogCopyStatus Text "Reading LDPlayer $($Ui.LogReadTask.Id) logs..."
    }catch{$worker.Dispose();throw}
}

function Invoke-LauncherForceCloseProcesses {
    param([string]$Directory)
    $paths=Get-LauncherRunPaths $Directory
    $mutex=New-Object Threading.Mutex $false,$paths.MutexName;$held=$false
    try{
        try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not $held){throw 'Automation is still running. No LDPlayer processes were force closed. Wait for Stop to finish and try again.'}
        $names=@('dnplayer','ld9boxheadless','ld9BoxSVC');$stopped=@{};$failures=@{}
        for($attempt=1;$attempt -le 3;$attempt++){
            $targets=@(Get-Process -Name $names -ErrorAction SilentlyContinue)
            foreach($process in $targets){
                try{
                    
                    if($process.ProcessName -notin $names){continue}
                    Stop-Process -InputObject $process -Force -ErrorAction Stop
                    $stopped[[int]$process.Id]=$true
                }catch{$failures[[int]$process.Id]=$process.ProcessName+'.exe (PID '+$process.Id+'): '+$_.Exception.Message}
                finally{$process.Dispose()}
            }
            $remaining=@(Get-Process -Name $names -ErrorAction SilentlyContinue)
            $live=@(foreach($process in $remaining){try{if($process.ProcessName -in $names){@{Name=$process.ProcessName+'.exe';Id=[int]$process.Id}}}finally{$process.Dispose()}})
            if(-not $live.Count){break}
            if($attempt -lt 3){Start-Sleep -Milliseconds 200}
        }
        return @{StoppedCount=$stopped.Count;Remaining=$live;Errors=@($failures.Values)}
    }finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
}

function Close-AppsBeforeManualShutdown {
    $packages=@(@($Config.GamePackages)+@('com.cloudflare.onedotonedotonedotone')|Select-Object -Unique)
    foreach($package in $packages){if($package -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+$'){throw 'Invalid app package in the shutdown settings.'}}
    foreach($package in $packages){
        if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Instance shutdown cancelled before the next app close.')}
        Write-FlowStatus "Closing $package using LDPlayer killapp, as in regular app recovery..."
        try{
            $reply=Invoke-Ld -Arguments @('killapp','--index',"$InstanceIndex",'--packagename',$package)
            if($reply -match '(?i)(device.*not found|device offline|cannot connect|error: closed|no devices/emulators found)'){throw [TimeoutException]::new('ADB was unavailable during app closure.')}
        }catch [OperationCanceledException]{throw}
        catch{
            if($_.Exception -is [TimeoutException] -or $_.Exception.Message -match '(?i)(device.*not found|device offline|cannot connect|error: closed|no devices/emulators found)'){$_.Exception.Data['ManualShutdownAdbUnavailable']=$true}
            throw
        }
    }
    if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Instance shutdown cancelled after app closure.')}
    try{
        $result=Invoke-Android 'shell sh -c ''sync && echo LAUNCHER_SHUTDOWN_SYNC_OK'''
        if($result.Trim() -cne 'LAUNCHER_SHUTDOWN_SYNC_OK'){throw 'ADB did not confirm disk sync.'}
    }catch{
        $failure=[InvalidOperationException]::new('ADB did not respond during shutdown sync. Closing this instance immediately.', $_.Exception)
        $failure.Data['ManualShutdownAdbUnavailable']=$true;throw $failure
    }
    Write-FlowStatus 'Configured game apps and VPN closed through LDPlayer killapp; disk sync confirmed.'
    if($Config.PostSyncDelay -gt 0){Write-FlowStatus "Waiting $($Config.PostSyncDelay) seconds after sync before closing LDPlayer...";Wait-FlowPause $Config.PostSyncDelay}
}

function Get-LauncherShutdownWorkerFunctionNames {
    return @('Invoke-LauncherCloseInstance','Close-AppsBeforeManualShutdown','Test-EmulatorResponsive','Set-EmulatorLiveObservation','Test-FlowStopRequested','Wait-FlowPause','Invoke-Android','Write-FlowStatus','Invoke-Ld','Get-InstanceInfo','ConvertTo-NativeArgument','Test-StatusCheckCommand','Wait-StatusCheckSlot','Clear-ProcessCheckCache','Start-LauncherProcess','New-LdCommandTimeoutError')
}

function Invoke-LauncherCloseInstance {
    param($Settings,[int]$Id,$InstanceInfo)
    $Config=$Settings.Clone();$InstanceIndex=$Id;$script:PoolRole=$null;$script:CookieAdbSerial=$null;$script:LastStatusCheckFinishedTicks=0
    $failures=New-Object 'System.Collections.Generic.List[string]';$blocked=$false;$cancelled=$false
    try{
        if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Instance shutdown cancelled.')}
        $responsive=Test-EmulatorResponsive -InstanceInfo $InstanceInfo
        if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Instance shutdown cancelled.')}
        if($responsive){
            Write-FlowStatus 'Android is responding. Closing game apps through the regular LDPlayer killapp flow...'
            try{Close-AppsBeforeManualShutdown}
            catch [OperationCanceledException]{throw}
            catch{
                if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Instance shutdown cancelled.')}
                if(-not $_.Exception.Data['ManualShutdownAdbUnavailable'] -and (Test-EmulatorResponsive -InstanceInfo $InstanceInfo)){
                    $failures.Add("LDPlayer $Id apps: "+$_.Exception.Message);$blocked=$true
                    Write-FlowStatus 'App closure was not confirmed and Android is still responding. Skipping built-in quit for this instance; the final force-close phase will handle remaining processes.'
                }else{Write-FlowStatus 'Android or ADB stopped responding during app closure. Closing this instance immediately through LDPlayer.'}
            }
        }else{Write-FlowStatus 'Android is not responding. Closing this instance immediately through LDPlayer.'}
        if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Instance shutdown cancelled.')}
        if(-not $blocked){
            try{$null=Invoke-Ld -Arguments @('quit','--index',"$Id");Write-FlowStatus 'LDPlayer built-in close command sent.'}
            catch [OperationCanceledException]{throw}
            catch{$failures.Add("LDPlayer $Id close: "+$_.Exception.Message)}
        }
    }catch [OperationCanceledException]{$cancelled=$true}
    return @{Id=$Id;Blocked=$blocked;Cancelled=$cancelled;Errors=$failures.ToArray()}
}

function Invoke-LauncherCloseRunningInstances {
    param([string]$Directory,[string]$StopFile='')
    $paths=Get-LauncherRunPaths $Directory;$mutex=New-Object Threading.Mutex $false,$paths.MutexName;$held=$false
    $pool=$null;$jobs=New-Object 'System.Collections.Generic.List[object]';$ownStopFile=-not [bool]$StopFile
    if($ownStopFile){$StopFile=Join-Path ([IO.Path]::GetTempPath()) ('launcher-close-'+[guid]::NewGuid().ToString('N')+'.stop')}
    try{
        try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not $held){throw 'Automation is still running. Wait for Stop to finish before closing instances.'}
        $configPath=Join-Path $Directory 'config.ini';$Config=Get-LauncherLogReadSettings $configPath
        $values=Read-LauncherUiConfig $configPath;$delay=10
        if($values.PostSyncDelay -and (-not [int]::TryParse([string]$values.PostSyncDelay,[ref]$delay) -or $delay -lt 0 -or $delay -gt 3600)){throw 'Pause after disk sync must be between 0 and 3600 seconds.'}
        $Config.PostSyncDelay=$delay;$Config.LauncherRelaunchDelay=0;$Config.CommandTimeout=10;$Config.StopFilePath=$StopFile
        $inventory=Get-BootInventory $Config
        $ids=@($inventory.Values|Where-Object{$_.ProcessId -gt 0}|ForEach-Object{[int]$_.Id}|Sort-Object -Unique)
        $failures=New-Object 'System.Collections.Generic.List[string]';$blocked=New-Object 'System.Collections.Generic.List[int]';$cancelled=$false
        if($ids.Count -and -not (Test-FlowStopRequested)){
            $definitions=foreach($name in @(Get-LauncherShutdownWorkerFunctionNames)){'function '+$name+" {`r`n"+(Get-Command $name -CommandType Function).Definition+"`r`n}"}
            $definitions=$definitions -join "`r`n"
            $pool=[Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool($ids.Count,$ids.Count)
            $pool.ApartmentState='STA';$pool.ThreadOptions='ReuseThread';$pool.Open()
            Write-Host "Starting $($ids.Count) temporary shutdown workers for $($ids.Count) running instances."
            foreach($id in $ids){
                if(Test-FlowStopRequested){$cancelled=$true;break}
                $task=[Management.Automation.PowerShell]::Create();$task.RunspacePool=$pool
                try{
                    $null=$task.AddScript('param($Definitions,$Settings,$Id,$Info) $ErrorActionPreference="Stop"; . ([scriptblock]::Create($Definitions)); Invoke-LauncherCloseInstance -Settings $Settings -Id $Id -InstanceInfo $Info').AddArgument($definitions).AddArgument($Config).AddArgument([int]$id).AddArgument($inventory[$id])
                    $handle=$task.BeginInvoke();$jobs.Add(@{Id=[int]$id;Task=$task;Handle=$handle;Done=$false})
                }catch{$task.Dispose();$failures.Add("LDPlayer $id shutdown could not start: "+$_.Exception.Message);$blocked.Add([int]$id)}
            }
            do{
                if(Test-FlowStopRequested){$cancelled=$true}
                foreach($job in $jobs){
                    if($job.Done){continue}
                    foreach($entry in @($job.Task.Streams.Information.ReadAll())){if($entry.MessageData){Write-Host ([string]$entry.MessageData)}}
                    if(-not $job.Handle.IsCompleted){continue}
                    try{
                        $result=@($job.Task.EndInvoke($job.Handle))
                        if($job.Task.HadErrors){throw [string]$job.Task.Streams.Error[0]}
                        if(-not $result.Count){throw 'Shutdown worker returned no result.'}
                        $summary=$result[-1]
                        if($summary.Cancelled){$cancelled=$true}
                        if($summary.Blocked){$blocked.Add([int]$job.Id)}
                        foreach($message in @($summary.Errors)){if($message){$failures.Add([string]$message)}}
                    }catch{if(-not $cancelled){$failures.Add("LDPlayer $($job.Id) shutdown failed: "+$_.Exception.Message)};$blocked.Add([int]$job.Id)}
                    finally{
                        foreach($entry in @($job.Task.Streams.Information.ReadAll())){if($entry.MessageData){Write-Host ([string]$entry.MessageData)}}
                        $job.Task.Dispose();$job.Task=$null;$job.Done=$true
                    }
                }
                if(@($jobs|Where-Object{-not $_.Done}).Count){Start-Sleep -Milliseconds 50}
            }while(@($jobs|Where-Object{-not $_.Done}).Count)
        }elseif(Test-FlowStopRequested){$cancelled=$true}
        $deadline=[datetime]::UtcNow.AddSeconds(10)
        do{
            $inventory=Get-BootInventory $Config
            $remaining=@($inventory.Values|Where-Object{$_.ProcessId -gt 0}|Sort-Object Id|ForEach-Object{@{Name=('LDPlayer '+$_.Id);Id=[int]$_.Id}})
            if(Test-FlowStopRequested){$cancelled=$true}
            if(-not $remaining.Count -or $cancelled -or @($remaining|Where-Object{$_.Id -notin $blocked}).Count -eq 0){break}
            Start-Sleep -Milliseconds 250
        }while([datetime]::UtcNow -lt $deadline)
        $stoppedCount=@($ids|Where-Object{$_ -notin @($remaining.Id)}).Count
        $forceStoppedCount=0;$forceCloseRan=$false
        if(-not $cancelled -and -not (Test-FlowStopRequested)){
            Write-Host 'Built-in instance close phase finished. Force closing remaining dnplayer.exe, ld9boxheadless.exe and ld9BoxSVC.exe processes...'
            $force=Invoke-LauncherForceCloseProcesses $Directory
            $forceCloseRan=$true;$forceStoppedCount=[int]$force.StoppedCount
            $remaining=@($force.Remaining)
            foreach($message in @($force.Errors)){if($message){$failures.Add([string]$message)}}
            if(-not $remaining.Count){$stoppedCount=$ids.Count}
        }else{$cancelled=$true}
        return @{StoppedCount=$stoppedCount;Remaining=$remaining;Errors=$failures.ToArray();Cancelled=$cancelled;WorkerCount=$jobs.Count;ForceCloseRan=$forceCloseRan;ForceStoppedCount=$forceStoppedCount}
    }finally{
        if(@($jobs|Where-Object{-not $_.Done}).Count){try{[IO.File]::WriteAllText($StopFile,'stop')}catch{}}
        foreach($job in $jobs){if($job.Task){try{if(-not $job.Handle.IsCompleted){$job.Task.Stop()};$null=$job.Task.EndInvoke($job.Handle)}catch{}finally{$job.Task.Dispose()}}}
        if($pool){try{$pool.Close()}catch{};try{$pool.Dispose()}catch{}}
        if($ownStopFile -and [IO.File]::Exists($StopFile)){[IO.File]::Delete($StopFile)}
        if($held){$mutex.ReleaseMutex()};$mutex.Dispose()
    }
}

function Start-LauncherUiStopAndClose {
    if($Ui.ForceClosePending -or $Ui.ForceCloseTask){return}
    $Ui.CloseCancelPath=Join-Path ([IO.Path]::GetTempPath()) ('launcher-close-'+[guid]::NewGuid().ToString('N')+'.stop')
    $Ui.CloseCancelRequested=$false;$Ui.CloseInstances=$true;$Ui.ForceClosePending=$true
    try{
        Stop-LauncherUiRun -AutomationOnly
        Add-LauncherUiLog "Stop and close requested for ALL running LDPlayer instances, including excluded IDs. Waiting for automation and active file operations to finish...`r`n"
        Update-LauncherUi
    }catch{$Ui.ForceClosePending=$false;$Ui.CloseInstances=$false;throw}
}

function Confirm-LauncherUiForceClose {
    if($Ui.ForceClosePending -or $Ui.ForceCloseTask){return}
    $message="Force close ALL running dnplayer.exe, ld9boxheadless.exe and ld9BoxSVC.exe processes?`r`n`r`nThis affects every LDPlayer instance, including excluded instances. Unsaved app progress may be lost.`r`n`r`nThe tool will stop its workers and finish any active disk operation before force closing these processes."
    $answer=[Windows.Forms.MessageBox]::Show($Ui.Form,$message,'Force close LDPlayer',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning,[Windows.Forms.MessageBoxDefaultButton]::Button2)
    if($answer -ne [Windows.Forms.DialogResult]::Yes){return}
    $Ui.CloseInstances=$false;$Ui.ForceClosePending=$true
    try{
        Stop-LauncherUiRun
        Add-LauncherUiLog "Force close confirmed. Waiting for automation and any log/window operations to stop...`r`n"
        Update-LauncherUi
    }catch{$Ui.ForceClosePending=$false;throw}
}

function Complete-LauncherUiForceClose {
    $graceful=[bool]$Ui.CloseInstances
    $button=if($graceful){$Ui.StopClose}else{$Ui.ForceClose}
    $label=if($graceful){'Stop and close'}else{'Force close'}
    $idleText=if($graceful){'Stop and close instances'}else{'Force close LDPlayer'}
    if($Ui.ForceClosePending -and -not $Ui.ForceCloseTask){
        if(($Ui.Process -and -not $Ui.Process.HasExited) -or (Test-LauncherRunning $Ui.Directory) -or $Ui.LogReadTask -or $Ui.ArrangeTask){return}
        $worker=[Management.Automation.PowerShell]::Create()
        try{
            $names=@('Get-LauncherRunPaths','Invoke-LauncherForceCloseProcesses')
            $action='Invoke-LauncherForceCloseProcesses'
            if($graceful){
                $names=@('Get-LauncherRunPaths','Invoke-LauncherForceCloseProcesses','Invoke-LauncherCloseRunningInstances','Get-LauncherShutdownWorkerFunctionNames','Get-LauncherLogReadSettings','Get-LauncherUiCookieSettings','Read-LauncherUiConfig','ConvertTo-LauncherConfigKey','Get-BootInventory')+@(Get-LauncherShutdownWorkerFunctionNames)
                $action='Invoke-LauncherCloseRunningInstances'
            }
            $definitions=foreach($name in $names){'function '+$name+" {`r`n"+(Get-Command $name -CommandType Function).Definition+"`r`n}"}
            $null=$worker.AddScript('param($Definitions,$Directory,$Action,$StopFile) $ErrorActionPreference="Stop"; . ([scriptblock]::Create($Definitions)); if($Action -eq "Invoke-LauncherCloseRunningInstances"){ & $Action $Directory -StopFile $StopFile }else{ & $Action $Directory }').AddArgument(($definitions -join "`r`n")).AddArgument($Ui.Directory).AddArgument($action).AddArgument([string]$Ui.CloseCancelPath)
            $handle=$worker.BeginInvoke();$Ui.ForceCloseTask=@{Worker=$worker;Handle=$handle}
            Add-LauncherUiLog $(if($graceful){"Closing apps, then all running instances through LDPlayer...`r`n"}else{"Force closing dnplayer.exe, ld9boxheadless.exe and ld9BoxSVC.exe...`r`n"})
        }catch{$worker.Dispose();$Ui.ForceClosePending=$false;$Ui.CloseInstances=$false;Set-LauncherUiProperty $button Text ($label+': retry');Add-LauncherUiLog ($label+' could not start: '+$_.Exception.Message+"`r`n");return}
    }
    $task=$Ui.ForceCloseTask
    if($task){foreach($entry in @($task.Worker.Streams.Information.ReadAll())){if($entry.MessageData){Add-LauncherUiLog ([string]$entry.MessageData+"`r`n")}}}
    if(-not $task -or -not $task.Handle.IsCompleted){return}
    try{
        $result=@($task.Worker.EndInvoke($task.Handle))
        if($task.Worker.HadErrors){throw [string]$task.Worker.Streams.Error[0]}
        if(-not $result.Count){throw 'No instance-close result was returned.'}
        $summary=$result[-1]
        if($graceful -and $summary.ForceCloseRan){Add-LauncherUiLog ("Final force close stopped $($summary.ForceStoppedCount) remaining LDPlayer process(es).`r`n")}
        if($graceful -and $summary.Cancelled){
            Add-LauncherUiLog ("Stop and close cancelled. $($summary.StoppedCount) instance(s) already closed; remaining instances were left open.`r`n")
            Set-LauncherUiProperty $button Text $idleText
        }elseif(@($summary.Remaining).Count){
            $details=(@($summary.Remaining|ForEach-Object{if($graceful){$_.Name}else{$_.Name+' (PID '+$_.Id+')'}}) -join ', ')
            Add-LauncherUiLog ($label+' incomplete. Still running: '+$details+'. '+(@($summary.Errors) -join '; ')+"`r`n")
            Set-LauncherUiProperty $button Text ($label+': retry')
        }else{
            Add-LauncherUiLog $(if($graceful){"Stop and close finished. $($summary.StoppedCount) instance(s) closed; no running instances remain.`r`n"}else{"Force close finished. $($summary.StoppedCount) matching process(es) stopped; none remain.`r`n"})
            if($graceful -and @($summary.Errors).Count){Add-LauncherUiLog ('App/close warnings: '+(@($summary.Errors) -join '; ')+"`r`n")}
            Set-LauncherUiProperty $button Text $idleText
        }
    }catch{Add-LauncherUiLog ($label+' failed: '+$_.Exception.Message+"`r`n");Set-LauncherUiProperty $button Text ($label+': retry')}
    finally{
        $task.Worker.Dispose();$Ui.ForceCloseTask=$null;$Ui.ForceClosePending=$false;$Ui.CloseInstances=$false
        if($graceful){if($Ui.CloseCancelPath -and [IO.File]::Exists($Ui.CloseCancelPath)){[IO.File]::Delete($Ui.CloseCancelPath)};$Ui.CloseCancelPath=$null;$Ui.CloseCancelRequested=$false;if($Ui.Tabs){$Ui.Tabs.SelectedTab=$Ui.SettingsTab}}
    }
}

function Get-LauncherWindowLayoutSettings {
    param([string]$ConfigPath,[hashtable]$Overrides=@{})
    $values=Read-LauncherUiConfig $ConfigPath
    foreach($key in $Overrides.Keys){$values[$key]=$Overrides[$key]}
    $folder=[string]$values.LdPlayerInstallPath
    if(-not $folder -and $values.LdConsolePath){$folder=[IO.Path]::GetDirectoryName([string]$values.LdConsolePath)}
    if(-not $folder){$folder='C:\LDPlayer\LDPlayer9'}
    $folder=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($folder.Trim('"')))
    $console='';foreach($name in @('ldconsole.exe','dnconsole.exe')){$candidate=Join-Path $folder $name;if([IO.File]::Exists($candidate)){$console=$candidate;break}}
    if(-not $console){throw 'Check the LDPlayer installation folder in Settings.'}
    $columns=5
    if($values.InstancesPerRow -and (-not [int]::TryParse([string]$values.InstancesPerRow,[ref]$columns) -or $columns -lt 1 -or $columns -gt 50)){throw 'Instances per row must be a whole number from 1 to 50.'}
    $excluded=@(foreach($part in ([string]$values.ExcludedLdPlayerIds -split ',')){
        if(-not $part.Trim()){continue};$id=0
        if(-not [int]::TryParse($part.Trim(),[ref]$id) -or $id -lt 0){throw 'Excluded emulator IDs must be comma-separated nonnegative numbers.'};$id
    })
    return @{ConfigFilePath=$ConfigPath;LdPlayerInstallPath=$folder;LdConsolePath=$console;InstancesPerRow=$columns;ExcludedLdPlayerIds=$excluded;CommandTimeout=10;MinCheckDelay=0;LdPlayerIds=@()}
}

function Start-LauncherUiWindowArrangement {
    if($Ui.ForceClosePending -or $Ui.ForceCloseTask){throw 'Wait for force close to finish.'}
    if($Ui.ArrangeTask){return}
    $busy=($Ui.Process -and -not $Ui.Process.HasExited) -or (Test-LauncherRunning $Ui.Directory)
    if($busy -and $Ui.Operation -eq 'Reset'){throw 'Wait for Reset to finish before arranging windows.'}
    $overrides=@{}
    if(-not $busy){
        $null=$Ui.Settings.EndEdit()
        foreach($row in $Ui.Settings.Rows){if($row.Tag -in @('InstancesPerRow','ExcludedLdPlayerIds','LdPlayerInstallPath','LdConsolePath')){$overrides[[string]$row.Tag]=[string]$row.Cells[1].Value}}
    }
    $settings=Get-LauncherWindowLayoutSettings $Ui.ConfigPath $overrides
    $names=@('Get-LauncherRunPaths','ConvertTo-NativeArgument','Test-StatusCheckCommand','Wait-StatusCheckSlot','Start-LauncherProcess','Invoke-Ld','New-LdCommandTimeoutError','Clear-ProcessCheckCache','Initialize-EmulatorWindowLayoutNative','Get-EmulatorWindowInventory','Get-EmulatorHostWindowGeometry','Get-EmulatorWindowWorkArea','Get-EmulatorWindowLayoutPlan','Set-EmulatorHostWindowPlacement','Update-EmulatorWindowLayout')
    $definitions=foreach($name in $names){'function '+$name+" {`r`n"+(Get-Command $name -CommandType Function).Definition+"`r`n}"}
    $worker=[Management.Automation.PowerShell]::Create()
    try{
        $code='param($Definitions,$Settings) $ErrorActionPreference="Stop"; . ([scriptblock]::Create($Definitions)); $Config=$Settings; Update-EmulatorWindowLayout -Settings $Settings -State @{} -Force'
        $null=$worker.AddScript($code).AddArgument(($definitions -join "`r`n")).AddArgument($settings)
        $handle=$worker.BeginInvoke();$Ui.ArrangeTask=@{Worker=$worker;Handle=$handle;Columns=$settings.InstancesPerRow}
        Set-LauncherUiProperty $Ui.Arrange Enabled $false
        Set-LauncherUiProperty $Ui.ArrangeStatus Text 'Arranging windows...'
        Set-LauncherUiProperty $Ui.ArrangeStatus ForeColor ([Drawing.Color]::FromArgb(153,169,190))
    }catch{$worker.Dispose();throw}
}

function Complete-LauncherUiWindowArrangement {
    $task=$Ui.ArrangeTask
    if(-not $task -or -not $task.Handle.IsCompleted){return}
    try{
        $result=@($task.Worker.EndInvoke($task.Handle))
        if($task.Worker.HadErrors){throw [string]$task.Worker.Streams.Error[0]}
        $count=if($result.Count){[int]$result[-1]}else{0}
        $message=if($count){"Arranged $count windows, $($task.Columns) per row."}else{'No visible included emulator windows.'}
        Set-LauncherUiProperty $Ui.ArrangeStatus Text $message
        Set-LauncherUiProperty $Ui.ArrangeStatus ForeColor ([Drawing.Color]::FromArgb(135,211,159))
        Add-LauncherUiLog ($message+"`r`n")
    }catch{
        Set-LauncherUiProperty $Ui.ArrangeStatus Text 'Could not arrange windows.'
        Set-LauncherUiProperty $Ui.ArrangeStatus ForeColor ([Drawing.Color]::FromArgb(255,135,140))
        Add-LauncherUiLog ('Arrange windows: '+$_.Exception.Message+"`r`n")
    }finally{$task.Worker.Dispose();$Ui.ArrangeTask=$null;Set-LauncherUiProperty $Ui.Arrange Enabled $true}
}

function Complete-LauncherUiEmulatorLogCopy {
    $task=$Ui.LogReadTask
    if(-not $task -or -not $task.Handle.IsCompleted){return}
    try{
        $result=$task.Worker.EndInvoke($task.Handle)
        if($task.Worker.HadErrors){throw [string]$task.Worker.Streams.Error[0]}
        Copy-LauncherUiText ($result -join "`r`n")
        Set-LauncherUiProperty $Ui.LogCopyStatus Text "Copied LDPlayer $($task.Id) game logs."
    }catch{
        Set-LauncherUiProperty $Ui.LogCopyStatus Text 'Could not copy emulator logs.'
        Add-LauncherUiLog ('Copy emulator logs: '+$_.Exception.Message+"`r`n")
    }finally{
        $task.Worker.Dispose();$Ui.LogReadTask=$null
        Set-LauncherUiProperty $Ui.CopyEmulatorLog Enabled $true
        Set-LauncherUiProperty $Ui.LogEmulatorId Enabled $true
    }
}

function Initialize-LauncherOutputReader {
    if('LauncherOutputReader' -as [type]){return}
    $definition=@'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Text;
public sealed class LauncherOutputReader : IDisposable {
    private readonly ConcurrentQueue<string> lines = new ConcurrentQueue<string>();
    private readonly object gate = new object();
    private readonly Process process;
    private StreamWriter writer;
    private bool disposed;
    public LauncherOutputReader(Process process, string logFile) {
        this.process = process;
        writer = new StreamWriter(new FileStream(logFile, FileMode.Append, FileAccess.Write, FileShare.ReadWrite), new UTF8Encoding(false));
        writer.AutoFlush = true;
        process.OutputDataReceived += Receive;
        process.ErrorDataReceived += Receive;
    }
    private void Receive(object sender, DataReceivedEventArgs e) {
        if(e.Data == null) return;
        var line = e.Data + Environment.NewLine;
        lock(gate) {
            if(disposed) return;
            lines.Enqueue(line);
            try { writer.Write(line); } catch(IOException) { }
        }
    }
    public void Start() { process.BeginOutputReadLine(); process.BeginErrorReadLine(); }
    public string Drain() {
        var text = new StringBuilder(); string line;
        while(text.Length < 262144 && lines.TryDequeue(out line)) text.Append(line);
        return text.ToString();
    }
    public void Dispose() {
        lock(gate) {
            if(disposed) return;
            disposed = true;
            process.OutputDataReceived -= Receive;
            process.ErrorDataReceived -= Receive;
            writer.Dispose();
        }
    }
}
'@
    if($PSVersionTable.PSVersion.Major -ge 6){Add-Type -TypeDefinition $definition}
    else{Add-Type -TypeDefinition $definition -ReferencedAssemblies 'System.dll','System.Core.dll'}
}

function Clear-LauncherRunState {
    param([string]$Directory)
    if(-not $Directory -or -not (Test-Path -LiteralPath $Directory -PathType Container)){return}
    $full=[IO.Path]::GetFullPath($Directory)
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $full.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^launcher-[0-9a-f]{32}$'){return}
    foreach($file in @(Get-ChildItem -LiteralPath $full -Filter 'boot-*.json' -File)){
        Remove-Item -LiteralPath $file.FullName -Force -Confirm:$false -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath (Join-Path $full 'last-launch.txt') -Force -Confirm:$false -ErrorAction SilentlyContinue
    
    
    if([IO.Directory]::GetFileSystemEntries($full).Length -eq 0){[IO.Directory]::Delete($full)}
}

function Read-LauncherUiSettings {
    $values=Read-LauncherUiConfig $Ui.ConfigPath
    if(-not $values.Contains('ResetInstanceCount')){$values['ResetInstanceCount']='20'}
    if(-not $values.Contains('InstancesPerRow')){$values['InstancesPerRow']='5'}
    foreach($key in @('PackageCheckFailuresBeforeRestart','PackageCheckRecoveryCyclesBeforeRestore','AppCrashLimit')){if(-not $values.Contains($key)){$values[$key]='2'}}
    if(-not $values.Contains('MaxReplacingInstances')){$values['MaxReplacingInstances']='1'}
    if(-not $values.Contains('LoadingInstanceThreshold')){$values['LoadingInstanceThreshold']='10'}
    if(-not $values.Contains('MaxLoadingInstancesAboveThreshold')){$values['MaxLoadingInstancesAboveThreshold']='3'}
    if(-not $values.Contains('PackageCheckRetryDelay')){$values['PackageCheckRetryDelay']='10'}

    if(-not $values.Contains('RecoveryMode')){$values['RecoveryMode']='Backup'}
    if(-not $values.Contains('RecoveryTemplateId')){$values['RecoveryTemplateId']='0'}
    $labels=@{GamePackages='Game app packages';MaxLoadingInstances='Emulators loading at once';MaxReplacingInstances='Instance replacements at once';CloudflareTimeoutLimit='VPN timeouts before replacement';InstanceOpenTimeoutLimit='Startup timeouts before replacement';GameOpenTimeoutLimit='Game timeouts before replacement';RestoreBackupFile='Restore backup (.ldbk)';AutoRestartHours='Restart after (hours)';PostSyncDelay='Pause after disk sync (seconds)';ExcludedLdPlayerIds='Excluded emulator IDs';LdPlayerInstallPath='LDPlayer installation folder';GameCheckInterval='Game check interval (seconds)';GameHomeTimeout='Home timeout after link (seconds)';GameJoinTimeout='Join timeout (seconds)';LauncherOpenTimeout='Game app opening timeout (seconds)'}
    $Ui.Settings.Rows.Clear()
    $labels['InstancesPerRow']='Instances per row'
    $labels['ResetInstanceCount']='Game emulators after reset (plus template 0)'
    $labels['InstanceOpenTimeoutLimit']='Startup attempts before disk recovery'
    $labels['PackageCheckRetryDelay']='Pause between package checks (seconds)'

    $labels['RestoreBackupFile']='Reset backup (.ldbk)'
    $labels['PackageCheckFailuresBeforeRestart']='Failed package checks before creating a replacement instance'
    $labels['PackageCheckRecoveryCyclesBeforeRestore']='Failed package-check loads before disk recovery'
    $labels['AppCrashLimit']='Crashes of the same app before emulator restart'
    $labels['MaxLoadingInstances']='Loading limit at/below running threshold'
    $labels['LoadingInstanceThreshold']='Running emulator threshold (0 disables)'
    $labels['MaxLoadingInstancesAboveThreshold']='Loading limit above running threshold'
    $groups=[ordered]@{
        'Instances and workload'=@('LdPlayerInstallPath','LdConsolePath','GamePackages','MaxLoadingInstances','LoadingInstanceThreshold','MaxLoadingInstancesAboveThreshold','MaxReplacingInstances','EmulatorsPerServerLink','InstancesPerRow')
        'Timeout and failure counts'=@('InstanceOpenTimeoutLimit','CloudflareTimeoutLimit','PackageCheckFailuresBeforeRestart','AppCrashLimit','MaxCloudflareAttempts','MaxServerLinkAttempts')
        'Timeouts (seconds)'=@('LdPlayerOpenTimeout','CloudflareOpenTimeout','CloudflareConnectTimeout','LauncherOpenTimeout','GameJoinTimeout','GameHomeTimeout','CommandTimeout')
        'Check intervals and retry delays (seconds)'=@('GameCheckInterval','PollInterval','MinCheckDelay','RetryDelay','PackageCheckRetryDelay','CloudflarePollInterval','CloudflareRetryDelay','InstanceLaunchDelay','InstanceRelaunchDelay','LauncherRelaunchDelay')
        'Scheduled restart and shutdown'=@('AutoRestartHours','PostSyncDelay')
        'Game detection and diagnostics'=@('MonitorGame','GameReadyLogMarker','LogSnapshotLdPlayerId')
    }
    $hidden=@('ResetInstanceCount','RestoreBackupFile','RecoveryMode','RecoveryTemplateId','OverwriteExistingCookies','SkipRepairNextStart','ServerLink','GameOpenTimeoutLimit','PackageCheckRecoveryCyclesBeforeRestore','MaxInstanceLaunchAttempts','CookieAuthenticationInterval')
    $visible=@($values.Keys|Where-Object{$_ -notin $hidden -and $_ -notmatch '^ServerLink\.[1-9][0-9]*$'})
    $settingNames=New-Object 'System.Collections.Generic.List[string]';$assigned=@{}
    if($visible -contains 'ExcludedLdPlayerIds'){$settingNames.Add('ExcludedLdPlayerIds');$assigned['ExcludedLdPlayerIds']=$true}
    foreach($group in $groups.Keys){
        $names=@($groups[$group]|Where-Object{$_ -in $visible})
        if(-not $names.Count){continue}
        $settingNames.Add('__group__'+$group)
        foreach($name in $names){$settingNames.Add($name);$assigned[$name]=$true}
    }
    $other=@($visible|Where-Object{-not $assigned.ContainsKey($_)})
    if($other.Count){$settingNames.Add('__group__Other settings');foreach($name in $other){$settingNames.Add($name)}}
    foreach($name in $settingNames) {
        if($name.StartsWith('__group__')){
            $index=$Ui.Settings.Rows.Add($name.Substring(9),'');$row=$Ui.Settings.Rows[$index];$row.ReadOnly=$true
            $row.DefaultCellStyle.BackColor=[Drawing.Color]::FromArgb(34,43,57)
            $row.DefaultCellStyle.ForeColor=[Drawing.Color]::FromArgb(218,226,238)
            $row.DefaultCellStyle.Font=[Drawing.Font]::new($Ui.Settings.Font,[Drawing.FontStyle]::Bold)
            $row.MinimumHeight=30;continue
        }
        $label=if($labels.ContainsKey($name)){$labels[$name]}else{[regex]::Replace([string]$name,'([a-z])([A-Z])','$1 $2')}
        $index=$Ui.Settings.Rows.Add([string]$label,[string]$values[$name])
        $Ui.Settings.Rows[$index].Tag=[string]$name
        if($name -eq 'RecoveryMode'){
            $cell=New-Object Windows.Forms.DataGridViewComboBoxCell
            $null=$cell.Items.Add('Template');$null=$cell.Items.Add('Backup')
            $cell.Value=[string]$values[$name];$cell.FlatStyle='Flat';$Ui.Settings.Rows[$index].Cells[1]=$cell
        }
        if($name -eq 'RestoreBackupFile'){
            $cell=New-Object Windows.Forms.DataGridViewComboBoxCell
            $null=$cell.Items.Add('')
            foreach($file in @(Get-ChildItem -LiteralPath $Ui.Directory -Filter '*.ldbk' -File|Sort-Object Name)){$null=$cell.Items.Add($file.Name)}
            if($values[$name] -and -not $cell.Items.Contains([string]$values[$name])){$null=$cell.Items.Add([string]$values[$name])}
            $cell.Value=[string]$values[$name];$cell.FlatStyle='Flat';$Ui.Settings.Rows[$index].Cells[1]=$cell
        }
    }
    $linkKeys=@($values.Keys|Where-Object{$_ -match '^ServerLink\.[1-9][0-9]*$'}|Sort-Object{[int]($_.Split('.')[1])})
    $links=if($linkKeys.Count){@($linkKeys|ForEach-Object{[string]$values[$_]})}else{@([string]$values.ServerLink)}
    $Ui.ServerLinks.Text=(@($links|Where-Object{$_ -and $_.Trim()}|ForEach-Object{$_.Trim()}) -join "`r`n")
    $Ui.Overwrite.Checked=($values.OverwriteExistingCookies -eq '1')
    $Ui.SkipRepair.Checked=($values.SkipRepairNextStart -eq '1')
    $count=20
    if(-not [int]::TryParse([string]$values.ResetInstanceCount,[ref]$count) -or $count -lt 0 -or $count -gt 1000){throw 'The reset count must be a whole number from 0 to 1000, plus template 0.'}
    $Ui.ResetCount.Value=$count
    Update-LauncherUiInputSizes
}

function Get-LauncherUiServerLinks {
    $links=@($Ui.ServerLinks.Text -split '\r?\n'|ForEach-Object{$_.Trim()}|Where-Object{$_})
    foreach($link in $links){
        $uri=$null
        if(-not [Uri]::TryCreate($link,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https'){throw 'Enter one complete https server link per line.'}
    }
    return $links
}

function Update-LauncherUiInputSizes {
    param([ValidateSet('All','Links','Cookie','Setting')][string]$Part='All')
    if($Part -in @('All','Links') -and $Ui.ServerLinks){
        $width=[math]::Max(120,$Ui.ServerLinks.ClientSize.Width-12)
        $text=if($Ui.ServerLinks.Text){$Ui.ServerLinks.Text}else{' '}
        $flags=[Windows.Forms.TextFormatFlags]::WordBreak -bor [Windows.Forms.TextFormatFlags]::TextBoxControl
        $size=[Windows.Forms.TextRenderer]::MeasureText($text,$Ui.ServerLinks.Font,[Drawing.Size]::new($width,100000),$flags)
        $maxHeight=[math]::Max(100,[int]($Ui.Form.ClientSize.Height*0.3))
        $height=[math]::Min($maxHeight,[math]::Max(48,$size.Height+14))
        if($Ui.ServerLinks.Height -ne $height){$Ui.ServerLinks.Height=$height}
        $count=@($Ui.ServerLinks.Text -split '\r?\n'|Where-Object{$_.Trim()}).Count
        Set-LauncherUiProperty $Ui.LinkCount Text "$count server link(s). One link per line; blank lines are ignored."
    }
    if($Part -in @('All','Cookie') -and $Ui.CookieInput -and $Ui.CookieEdit){
        $remaining=$Ui.CookieEdit.ClientSize.Width-12
        foreach($control in $Ui.CookieEdit.Controls){if($control -ne $Ui.CookieInput){$remaining-=$control.Width+$control.Margin.Horizontal}}
        $remaining=[math]::Max(160,$remaining-$Ui.CookieInput.Margin.Horizontal)
        $mask=([string][char]0x25cf)*([math]::Min(512,[math]::Max(1,$Ui.CookieInput.TextLength)))
        $size=[Windows.Forms.TextRenderer]::MeasureText($mask,$Ui.CookieInput.Font)
        Set-LauncherUiProperty $Ui.CookieInput Width ([int][math]::Min($remaining,[math]::Max(180,$size.Width+20)))
    }
    if($Part -in @('All','Setting') -and $Ui.Settings -and $Ui.Settings.IsCurrentCellInEditMode -and $Ui.Settings.EditingControl){
        $cell=$Ui.Settings.CurrentCell;$editor=$Ui.Settings.EditingControl
        $width=[math]::Max(80,$cell.Size.Width-12)
        $flags=[Windows.Forms.TextFormatFlags]::WordBreak -bor [Windows.Forms.TextFormatFlags]::TextBoxControl
        $size=[Windows.Forms.TextRenderer]::MeasureText(($editor.Text+' '),$editor.Font,[Drawing.Size]::new($width,100000),$flags)
        Set-LauncherUiProperty $Ui.Settings.Rows[$cell.RowIndex] MinimumHeight ([int][math]::Min(240,[math]::Max(28,$size.Height+10)))
    }
}

function Save-LauncherUiSettings {
    if(Test-LauncherRunning $Ui.Directory){throw 'Stop the tool before changing settings.'}
    $null=$Ui.Settings.EndEdit()
    $values=@{OverwriteExistingCookies='0';SkipRepairNextStart=$(if($Ui.SkipRepair.Checked){'1'}else{'0'});ResetInstanceCount=[string][int]$Ui.ResetCount.Value}
    foreach($row in $Ui.Settings.Rows) {
        if($row.IsNewRow -or -not $row.Tag){continue}
        $values[[string]$row.Tag]=[string]$row.Cells[1].Value
    }
    $links=@(Get-LauncherUiServerLinks)
    if($links.Count -eq 0){throw 'Add at least one server link before saving settings.'}
    for($i=0;$i -lt $links.Count;$i++){$values['ServerLink.'+($i+1)]=$links[$i]}
    Set-LauncherConfigValues -Path $Ui.ConfigPath -Values $values -ReplaceServerLinks
}

function Update-LauncherCookieMismatchNotice {
    param([object[]]$Statuses)
    $ids=@($Statuses|Where-Object{$_.Status -eq 'Cookie mismatch' -and [string]$_.InstanceId -match '^\d+$'}|ForEach-Object{[int]$_.InstanceId}|Sort-Object -Unique)
    $text=if($ids.Count){'Cookie mismatch detected (ID): '+($ids -join ',')}else{''}
    Set-LauncherUiProperty $Ui.CookieMismatch Text $text
    Set-LauncherUiProperty $Ui.CookieMismatch Visible ([bool]$ids.Count)
}

function Read-LauncherUiAccounts {
    $map=$null
    try{
        $Config=Get-LauncherUiCookieSettings $Ui.Directory
        $root=Get-GameAppDataRoot $Config
        $files=@();if([IO.Directory]::Exists($root)){$files=@(Get-ChildItem -LiteralPath $root -Filter manifest.json -File -Recurse|Sort-Object FullName)}
        $fingerprint=$root+'|'+(@($files|ForEach-Object{$_.FullName+':'+$_.Length+':'+$_.LastWriteTimeUtc.Ticks}) -join '|')
        if($Ui.AccountsFingerprint -ceq $fingerprint){return}
        $models=New-Object 'System.Collections.Generic.List[object]'
        foreach($file in $files){
            $id=$file.Directory.Parent.Name;$package=$file.Directory.Name
            if($id -notmatch '^\d+$'){continue}
            $paths=Get-GameAppDataPaths -Id ([int]$id) -Package $package -Settings $Config
            $entry=Read-GameAppDataManifest $paths
            $state=if($entry.RestoreRequired){'Restore pending'}else{'Saved'}
            $models.Add([pscustomobject]@{Key="$id|$package";Values=[object[]]@($id,$package,([math]::Round($entry.Length/1MB,1).ToString()+' MB'),$entry.SavedUtc,$state,'Private app data and package external folders');Mismatch=$false})
        }
        Set-LauncherUiProperty $Ui.CookieMismatch Visible $false
        $grid=$Ui.Accounts;$selected='';$topKey='';$oldCell=$grid.CurrentCell;$horizontal=$grid.HorizontalScrollingOffset
        if($grid.SelectedRows.Count){$selected=[string]$grid.SelectedRows[0].Tag}
        if($grid.FirstDisplayedScrollingRowIndex -ge 0){$topKey=[string]$grid.Rows[$grid.FirstDisplayedScrollingRowIndex].Tag}
        $desired=@{};foreach($model in $models){$desired[$model.Key]=$model}
        $Ui.RefreshingAccounts=$true;$grid.SuspendLayout()
        try{
            
            
            for($i=$grid.Rows.Count-1;$i -ge 0;$i--){if(-not $desired.ContainsKey([string]$grid.Rows[$i].Tag)){$grid.Rows.RemoveAt($i)}}
            $rows=@{};foreach($row in $grid.Rows){$rows[[string]$row.Tag]=$row}
            $position=0
            foreach($model in $models){
                if($rows.ContainsKey($model.Key)){$row=$rows[$model.Key]}
                else{
                    $index=[math]::Min($position,$grid.Rows.Count)
                    $grid.Rows.Insert($index,[object[]]$model.Values)
                    $row=$grid.Rows[$index];$row.Tag=$model.Key;$rows[$model.Key]=$row
                }
                for($column=0;$column -lt $model.Values.Count;$column++){
                    if(-not [object]::Equals($row.Cells[$column].Value,$model.Values[$column])){$row.Cells[$column].Value=$model.Values[$column]}
                }
                $color=if($model.Mismatch){[Drawing.Color]::FromArgb(255,135,140)}else{[Drawing.Color]::Empty}
                if(-not $row.DefaultCellStyle.ForeColor.Equals($color)){$row.DefaultCellStyle.ForeColor=$color}
                $position++
            }
            if($selected -and $rows.ContainsKey($selected)){
                $row=$rows[$selected]
                if($oldCell -and $oldCell.OwningRow -eq $row -and $grid.CurrentCell -ne $oldCell){$grid.CurrentCell=$oldCell}
                if(-not $row.Selected){$grid.ClearSelection();$row.Selected=$true}
            }elseif($selected -and $Ui.CookieInput.TextLength){$Ui.CookieInput.Clear()}
            try{
                if($topKey -and $rows.ContainsKey($topKey) -and $rows[$topKey].Visible -and $grid.FirstDisplayedScrollingRowIndex -ne $rows[$topKey].Index){$grid.FirstDisplayedScrollingRowIndex=$rows[$topKey].Index}
                if($grid.HorizontalScrollingOffset -ne $horizontal){$grid.HorizontalScrollingOffset=$horizontal}
            }catch{}
        }finally{$grid.ResumeLayout($false);$Ui.RefreshingAccounts=$false}
        Set-LauncherUiProperty $Ui.CookieHint Text 'Game data is saved when a cookie is present and restored when it is missing. Login apps release their slot and wait for a cookie. Snapshots contain private account data.'
        $Ui.AccountsFingerprint=$fingerprint
    }catch{Set-LauncherUiProperty $Ui.CookieHint Text 'Could not read an app-data snapshot. Check the live log and app-data folder.'}
    finally{$map=$null}
}

function Get-LauncherResetSettings {
    param([string]$ConfigPath)
    $directory=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ConfigPath))
    $values=Read-LauncherUiConfig $ConfigPath
    $settings=Get-LauncherUiCookieSettings $directory
    $count=20
    if($values.Contains('ResetInstanceCount') -and (-not [int]::TryParse([string]$values.ResetInstanceCount,[ref]$count) -or $count -lt 0 -or $count -gt 1000)){throw 'ResetInstanceCount must be a whole number from 0 to 1000, excluding template 0.'}
    $settings.ResetInstanceCount=$count;$settings.ConfigFilePath=[IO.Path]::GetFullPath($ConfigPath)
    $install=[string]$values.LdPlayerInstallPath
    if(-not $install -and $values.LdConsolePath){$install=[IO.Path]::GetDirectoryName([string]$values.LdConsolePath)}
    if(-not $install){$install='C:\LDPlayer\LDPlayer9'}
    $settings.LdPlayerInstallPath=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($install.Trim('"')))
    $settings.LdConsolePath=''
    foreach($name in @('ldconsole.exe','dnconsole.exe')){
        $candidate=Join-Path $settings.LdPlayerInstallPath $name
        if([IO.File]::Exists($candidate)){$settings.LdConsolePath=$candidate;break}
    }
    if(-not $settings.LdConsolePath){throw 'Check the LDPlayer installation folder before resetting.'}
    $settings.RestoreBackupPath=Join-Path $settings.LdPlayerInstallPath 'vms\leidian0'
    $settings.ResetPendingPath=Join-Path $directory 'launcher-reset.pending.json'
    $hash=[Security.Cryptography.SHA256]::Create()
    try{$digest=[BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($settings.LdPlayerInstallPath.ToLowerInvariant()))).Replace('-','').Substring(0,24)}finally{$hash.Dispose()}
    $settings.ResetMutexName='Local\LauncherReset-'+$digest
    $settings.RestoreMutexName='Local\CodexJoinerRestore-'+$digest
    $settings.RestoreStateDirectory=Initialize-LauncherRecoveryStateDirectory $settings
    return $settings
}

function Assert-LauncherResetNotPending {
    param([string]$Directory)
    if([IO.File]::Exists((Join-Path $Directory 'launcher-reset.pending.json'))){throw 'The previous reset did not finish. Use Reset emulators again to finish rebuilding before starting the tool.'}
}

function Invoke-LauncherResetNative {
    param([string[]]$Arguments,[string]$FilePath=$Config.LdConsolePath,[int]$TimeoutSeconds=0)
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$FilePath;$info.Arguments=(@($Arguments|ForEach-Object{ConvertTo-NativeArgument $_}) -join ' ')
    $info.WorkingDirectory=$Config.LdPlayerInstallPath;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.RedirectStandardInput=$true
    $process=New-Object Diagnostics.Process;$process.StartInfo=$info
    try{
        if(-not $process.Start()){throw 'The reset command could not start.'}
        $process.StandardInput.Close()
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        $timer=[Diagnostics.Stopwatch]::StartNew();$reported=0
        
        while(-not $process.WaitForExit(1000)){
            if($TimeoutSeconds -gt 0 -and $timer.Elapsed.TotalSeconds -ge $TimeoutSeconds){try{$process.Kill()}catch{};throw 'LDPlayer reset status command timed out.'}
            if($timer.Elapsed.TotalSeconds -ge $reported+15){Write-Host ('Reset: waiting for '+$Arguments[0]+' to finish...');$reported=[int]$timer.Elapsed.TotalSeconds}
        }
        $out=$stdout.GetAwaiter().GetResult();$err=$stderr.GetAwaiter().GetResult()
        $diagnosticError=[bool]($err.Trim() -or $out -match '(?im)^\s*(?:error\b|failed\b|failure\b|fatal\b|exception\b|invalid\b|cannot\b|(-1|-2)\s*$)')
        if($process.ExitCode -ne 0 -or $diagnosticError){
            $failure=[InvalidOperationException]::new(('Reset command '+$Arguments[0]+' failed (exit '+$process.ExitCode+'). '+($err.Trim()+"`n"+$out.Trim()).Trim()))
            $failure.Data['NativeCommand']=$Arguments[0];$failure.Data['NativeExitCode']=$process.ExitCode;$failure.Data['NativeDiagnosticError']=$diagnosticError
            throw $failure
        }
        return $out.Trim()
    }finally{$process.Dispose()}
}

function Get-LauncherResetInventory {
    $listing=Invoke-LauncherResetNative @('list2') -TimeoutSeconds 30
    $map=@{}
    foreach($line in ($listing -split '\r?\n')){
        if(-not $line.Trim()){continue}
        if($line.Trim() -notmatch '^(\d+),(.*?),(-?\d+),(-?\d+),([01]),(-?\d+),(-?\d+)(?:,(\d+),(\d+),(\d+))?$'){throw 'LDPlayer returned an incomplete instance list. Reset was stopped.'}
        $id=[int]$Matches[1]
        if($map.ContainsKey($id)){throw 'LDPlayer returned duplicate instance IDs. Reset was stopped.'}
        $map[$id]=@{Id=$id;Running=($Matches[5] -eq '1' -or [long]$Matches[3] -gt 0 -or [long]$Matches[4] -gt 0 -or [long]$Matches[6] -gt 0 -or [long]$Matches[7] -gt 0)}
    }
    return $map
}

function Assert-LauncherResetContinue {
    if(Test-FlowStopRequested){throw [OperationCanceledException]::new('Reset stopped after the current disk operation finished. Use Reset emulators again before starting the tool.')}
}

function Assert-LauncherResetClosed {
    $inventory=Get-LauncherResetInventory
    if(@($inventory.Values|Where-Object{$_.Running}).Count){throw 'An emulator is still running. No more reset files will be changed.'}
    return $inventory
}

function Wait-LauncherResetEmulatorsClosed {
    $null=Invoke-LauncherResetNative @('quitall') -TimeoutSeconds 30
    $deadline=[datetime]::UtcNow.AddSeconds(120);$stopped=0;$inventory=@{}
    while($stopped -lt 2){
        Assert-LauncherResetContinue
        $inventory=Get-LauncherResetInventory
        if(@($inventory.Values|Where-Object{$_.Running}).Count){$stopped=0}else{$stopped++}
        if([datetime]::UtcNow -ge $deadline){throw 'An emulator did not finish closing. No more reset files will be changed.'}
        if($stopped -lt 2){Start-Sleep -Seconds 1}
    }
    return $inventory
}

function Get-LauncherResetInstanceFiles {
    $install=$Config.LdPlayerInstallPath;$vms=Join-Path $install 'vms'
    Assert-InstanceReplacementDirectory $vms $install
    $items=New-Object 'System.Collections.Generic.List[string]'
    if([IO.Directory]::Exists($vms)){
        foreach($item in @(Get-ChildItem -LiteralPath $vms -Force)){
            if($item.PSIsContainer -and $item.Name -match '^leidian\d+$'){$items.Add($item.FullName)}
        }
        $configDirectory=Join-Path $vms 'config'
        Assert-InstanceReplacementDirectory $configDirectory $vms
        if([IO.Directory]::Exists($configDirectory)){
            foreach($item in @(Get-ChildItem -LiteralPath $configDirectory -Force -File)){
                if($item.Name -match '^leidian\d+[.]config(?:[.]bak)?$'){$items.Add($item.FullName)}
            }
        }
    }
    foreach($path in $items){
        Assert-InstanceReplacementDirectory $path $vms
        if($Config.RestoreBackupPath.StartsWith($path.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'The reset backup must be outside the emulator files being deleted.'}
        if([IO.Directory]::Exists($path)){
            
            foreach($child in @(Get-ChildItem -LiteralPath $path -Force -Recurse)){
                if($child.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reset does not delete redirected emulator files.'}
            }
        }
    }
    return $items.ToArray()
}

function Test-LauncherResetBackup {
    $template=Get-LauncherResetTemplateFiles $Config
    $configuration=ConvertFrom-Json ([IO.File]::ReadAllText($template.ConfigFile))
    if($configuration.'basicSettings.standaloneSysVmdk'){throw 'LDPlayer 0 must use the shared-system disk layout.'}
    $xml=[xml]::new();$xml.XmlResolver=$null;$xml.Load($template.VmFile)
    $machine=$xml.SelectSingleNode('//*[local-name()="Machine"]');$data=$xml.SelectSingleNode('//*[local-name()="HardDisk" and @location="data.vmdk"]')
    $descriptor=Get-TemplateDiskDescriptor $template.DataFile
    if(-not $machine -or $machine.name -cne 'leidian0' -or -not $data -or ($descriptor.UuidKind -eq 'VirtualBox' -and $data.uuid.Trim('{}') -ine $descriptor.Uuid)){throw 'LDPlayer 0 VM and data disk identifiers do not match.'}
    $null=Get-TemplateDiskDescriptor $template.SdFile
    Write-Host 'Existing LDPlayer 0 validated as the copy source.'
}
function Initialize-LauncherResetInstance {
    param([int]$Id,[string]$StageDirectory='',[switch]$RefreshTemplate)
    $inventory=Get-LauncherResetInventory
    if($inventory.ContainsKey($Id) -and $inventory[$Id].Running){throw 'The reset target is still running.'}
    $template=Get-LauncherResetTemplateFiles $Config
    $vms=Join-Path $Config.LdPlayerInstallPath 'vms';$source=$template.VmDirectory;$target=Join-Path $vms "leidian$Id"
    $sourceConfig=$template.ConfigFile;$targetConfig=Join-Path $vms "config\leidian$Id.config"
    if($StageDirectory){
        Assert-InstanceReplacementDirectory $StageDirectory $vms
        if($Id -lt 0 -or [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($StageDirectory)) -ine [IO.Path]::GetFullPath($vms) -or [IO.Path]::GetFileName($StageDirectory) -notmatch ('^[.]launcher-reset-'+$Id+'-[a-f0-9]{32}$')){throw 'Reset staging directory does not match its target ID.'}
        if(($Id -gt 0 -and $inventory.ContainsKey($Id) -and -not ($script:ResetNativeIds -and $script:ResetNativeIds[$Id])) -or (-not $RefreshTemplate -and ((Test-Path -LiteralPath $target) -or (Test-Path -LiteralPath $targetConfig)))){throw 'The reset target ID already exists. No instance was overwritten.'}
        $target=Join-Path $StageDirectory 'payload';$targetConfig=Join-Path $StageDirectory 'leidian.config'
    }elseif(-not $inventory.ContainsKey($Id)){throw "New emulator $Id was not registered at the expected ID."}
    foreach($path in @($target,$targetConfig)){Assert-InstanceReplacementDirectory $path $vms}
    $locks=New-Object 'System.Collections.Generic.List[object]'
    try{
        foreach($path in @($sourceConfig,$template.VmFile,(Join-Path $source 'data.vmdk'),(Join-Path $source 'sdcard.vmdk'))){
            if($Id -gt 0){$locks.Add([IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))}
        }
        $configuration=ConvertFrom-Json ([IO.File]::ReadAllText($sourceConfig))
        if($configuration.'basicSettings.standaloneSysVmdk'){throw 'Reset copying requires the shared-system LDPlayer layout.'}
        $xml=[xml]::new();$xml.XmlResolver=$null;$xml.PreserveWhitespace=$true;$xml.Load($template.VmFile)
        $machine=$xml.SelectSingleNode('//*[local-name()="Machine"]');$data=$xml.SelectSingleNode('//*[local-name()="HardDisk" and @location="data.vmdk"]')
        if(-not $machine -or $machine.name -cne 'leidian0' -or -not $data -or $data.type -cne 'Normal'){throw 'Reset template VM registration is unsupported.'}
        $sourceDescriptor=Get-TemplateDiskDescriptor (Join-Path $source 'data.vmdk')
        $sourceData=$sourceDescriptor.Uuid
        if($sourceDescriptor.UuidKind -eq 'VirtualBox' -and $sourceData -ine $data.uuid.Trim('{}')){throw 'The restored template data disk does not match its VM registration.'}
        if($sourceDescriptor.UuidKind -ne 'VirtualBox'){$sourceData=$data.uuid.Trim('{}')}
        $dataUuid=Get-TemplateTargetUuid $sourceData 0 $Id
        $sourceSd=(Get-TemplateDiskDescriptor (Join-Path $source 'sdcard.vmdk')).Uuid
        if(-not $sourceSd -or $sourceSd -ieq $sourceDescriptor.Uuid){
            $digest=[Security.Cryptography.SHA256]::Create()
            try{$seed=$digest.ComputeHash([Text.Encoding]::UTF8.GetBytes($sourceData+'|sdcard.vmdk'));$sourceSd=([guid]::new([byte[]]$seed[0..15])).ToString()}finally{$digest.Dispose()}
        }
        $sdUuid=Get-TemplateTargetUuid $sourceSd 0 $Id
        $machineUuid=Get-TemplateTargetUuid $machine.uuid.Trim('{}') 0 $Id
        foreach($disk in $xml.SelectNodes('//*[local-name()="HardDisk"]')){
            if($disk -eq $data){continue}
            if($disk.type -cne 'Readonly' -or [IO.Path]::GetFullPath($disk.location) -ine (Join-Path $Config.LdPlayerInstallPath 'system.vmdk')){throw 'Reset template references an unsupported system disk.'}
        }
        $machine.SetAttribute('name',"leidian$Id");$machine.SetAttribute('uuid',"{$machineUuid}");$data.SetAttribute('uuid',"{$dataUuid}")
        foreach($image in $xml.SelectNodes('//*[local-name()="Image"]')){if($image.uuid.Trim('{}') -ieq $sourceData){$image.SetAttribute('uuid',"{$dataUuid}")}}
        foreach($name in @('data.vmdk','sdcard.vmdk')){
            $path=Join-Path $target $name;Assert-InstanceReplacementDirectory $path $vms
            if((Get-Item -LiteralPath $path).Length -ne (Get-Item -LiteralPath (Join-Path $source $name)).Length){throw "The copied disk for emulator $Id has an unexpected length."}
            if($Id -gt 0){$uuid=if($name -eq 'data.vmdk'){$dataUuid}else{$sdUuid};Set-TemplateDiskHostUuid $path $uuid}
        }
        $configuration|Add-Member NoteProperty 'basicSettings.autoRun' $false -Force
        $configuration|Add-Member NoteProperty 'statusSettings.playerName' "LDPlayer-$Id" -Force
        [IO.File]::WriteAllText((Join-Path $target 'leidian.vbox'),$xml.OuterXml,[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($targetConfig,($configuration|ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
    }finally{foreach($lock in $locks){$lock.Dispose()}}
}

function Copy-LauncherResetInstanceFiles {
    param([int]$Id)
    if($Id -lt 0){throw 'The target ID must be nonnegative.'}
    $inventory=Get-LauncherResetInventory
    if($inventory.ContainsKey($Id) -and $inventory[$Id].Running){throw 'The template copy target is running.'}
    $template=Get-LauncherResetTemplateFiles $Config
    $vms=Join-Path $Config.LdPlayerInstallPath 'vms';$source=$template.VmDirectory
    $target=Join-Path $vms "leidian$Id";$targetConfig=Join-Path $vms "config\leidian$Id.config"
    $stage=Join-Path $vms ('.launcher-reset-'+$Id+'-'+[guid]::NewGuid().ToString('N'));$payload=Join-Path $stage 'payload'
    foreach($path in @($target,$targetConfig,$stage)){Assert-InstanceReplacementDirectory $path $vms}
    if($Id -gt 0 -and -not ($script:ResetNativeIds -and $script:ResetNativeIds[$Id]) -and ((Test-Path -LiteralPath $target) -or (Test-Path -LiteralPath $targetConfig))){throw 'The reset copy target already exists.'}
    $locks=New-Object 'System.Collections.Generic.List[object]'
    try{
        foreach($path in $template.Files){
            $locks.Add([IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))
        }
        $null=[IO.Directory]::CreateDirectory($payload)
        foreach($name in @('data.vmdk','sdcard.vmdk')){[IO.File]::Copy((Join-Path $source $name),(Join-Path $payload $name),$false)}
        Initialize-LauncherResetInstance -Id $Id -StageDirectory $stage -RefreshTemplate
        $inventory=Get-LauncherResetInventory
        if(($Id -gt 0 -and -not ($script:ResetNativeIds -and $script:ResetNativeIds[$Id]) -and ($inventory.ContainsKey($Id) -or (Test-Path -LiteralPath $target) -or (Test-Path -LiteralPath $targetConfig))) -or ($inventory.ContainsKey($Id) -and $inventory[$Id].Running)){throw 'The reset target appeared during copying. Registration was postponed.'}
        Publish-LauncherResetFiles -Id $Id -StageDirectory $stage
    }finally{
        foreach($lock in $locks){$lock.Dispose()}
        if([IO.Directory]::Exists($stage)){
            Assert-InstanceReplacementDirectory $stage $vms
            foreach($child in @(Get-ChildItem -LiteralPath $stage -Force -Recurse)){if($child.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reset staging cleanup does not follow redirected files.'}}
            [IO.Directory]::Delete($stage,$true)
        }
    }
}

function Publish-LauncherResetFiles {
    param([int]$Id,[string]$StageDirectory)
    $vms=Join-Path $Config.LdPlayerInstallPath 'vms';$target=Join-Path $vms "leidian$Id"
    $payload=Join-Path $StageDirectory 'payload';$targetConfig=Join-Path $vms "config\leidian$Id.config"
    foreach($path in @($target,$payload,$targetConfig,$StageDirectory)){Assert-InstanceReplacementDirectory $path $vms}
    if([IO.Path]::GetFileName($StageDirectory) -notmatch ('^[.]launcher-reset-'+$Id+'-[a-f0-9]{32}$')){throw 'Reset publication stage does not match its target ID.'}
    $inventory=Get-LauncherResetInventory
    if($Id -lt 0 -or ($inventory.ContainsKey($Id) -and $inventory[$Id].Running)){throw 'The target must remain closed during reset publication.'}
    if($Id -gt 0 -and -not ($script:ResetNativeIds -and $script:ResetNativeIds[$Id])){
        if($inventory.ContainsKey($Id) -or [IO.Directory]::Exists($target) -or [IO.File]::Exists($targetConfig)){throw 'The new reset target is already occupied. It was not overwritten.'}
        [IO.Directory]::Move($payload,$target)
        [IO.File]::Move((Join-Path $StageDirectory 'leidian.config'),$targetConfig)
        return
    }
    
    
    $null=[IO.Directory]::CreateDirectory($target)
    foreach($name in @('data.vmdk','sdcard.vmdk','leidian.vbox')){
        $from=Join-Path $payload $name;$to=Join-Path $target $name
        Assert-InstanceReplacementDirectory $from $vms
        Assert-InstanceReplacementDirectory $to $vms
        if([IO.File]::Exists($to)){[IO.File]::Replace($from,$to,[NullString]::Value)}else{[IO.File]::Move($from,$to)}
    }
    $from=Join-Path $StageDirectory 'leidian.config'
    if([IO.File]::Exists($targetConfig)){[IO.File]::Replace($from,$targetConfig,[NullString]::Value)}else{[IO.File]::Move($from,$targetConfig)}
}

function Clear-LauncherResetState {
    $directory=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Config.ConfigFilePath))
    $appData=[IO.Path]::GetFullPath((Get-GameAppDataRoot $Config))
    if($appData -ine (Join-Path $directory 'app-data')){throw 'Reset app-data cleanup target is outside the tool folder.'}
    Assert-InstanceReplacementDirectory $appData $directory
    if([IO.Directory]::Exists($appData)){
        $pendingDirectories=New-Object 'System.Collections.Generic.Stack[string]';$pendingDirectories.Push($appData)
        while($pendingDirectories.Count){
            $next=$pendingDirectories.Pop()
            foreach($child in @(Get-ChildItem -LiteralPath $next -Force)){
                Assert-InstanceReplacementDirectory $child.FullName $appData
                if($child.PSIsContainer){$pendingDirectories.Push($child.FullName)}
            }
        }
        [IO.Directory]::Delete($appData,$true)
    }
    if($Config.CookieStorePath -and [IO.File]::Exists($Config.CookieStorePath)){
        Assert-InstanceReplacementDirectory $Config.CookieStorePath $directory
        [IO.File]::Delete($Config.CookieStorePath)
    }
    $run=Read-LauncherRunRecord $directory
    if($run){Clear-LauncherRunState $run.RunDirectory}
    Write-Host 'Deleted saved app-data snapshots, standalone cookies, pending cookie updates and legacy cookies. Clearing recovery queues...'
    $vms=Join-Path $Config.LdPlayerInstallPath 'vms'
    foreach($item in @(Get-ChildItem -LiteralPath $vms -Force -Directory)){
        if($item.Name -notmatch '^[.](?:launcher-template|launcher-replacement|launcher-reset)-\d+-[a-f0-9]{32}$'){continue}
        Assert-InstanceReplacementDirectory $item.FullName $vms
        foreach($child in @(Get-ChildItem -LiteralPath $item.FullName -Force -Recurse)){if($child.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reset staging cleanup does not follow redirected files.'}}
        [IO.Directory]::Delete($item.FullName,$true)
    }
    $history=Get-InstanceReplacementPaths $Config
    if([IO.File]::Exists($history.History)){[IO.File]::Delete($history.History)}
    if([IO.Directory]::Exists($history.State)){
        foreach($file in @(Get-ChildItem -LiteralPath $history.State -File -Filter 'replacement-*.json')){if($file.Name -match '^replacement-\d+[.]json$'){[IO.File]::Delete($file.FullName)}}
    }
    if([IO.Directory]::Exists($Config.RestoreStateDirectory)){
        foreach($file in @(Get-ChildItem -LiteralPath $Config.RestoreStateDirectory -File -Filter 'template-accounts-*.json')){if($file.Name -match '^template-accounts-\d+[.]json$'){[IO.File]::Delete($file.FullName)}}
        foreach($file in @(Get-ChildItem -LiteralPath $Config.RestoreStateDirectory -File -Filter 'restore-*.json')){
            if($file.Name -match '^restore-\d+-[a-f0-9]{32}[.]json$'){
                Assert-InstanceReplacementDirectory $file.FullName $Config.RestoreStateDirectory
                [IO.File]::Delete($file.FullName)
            }
        }
    }
}

function Initialize-LauncherResetTemplateRegistration {
    
    
    if(@(Get-LauncherResetInstanceFiles).Count){throw 'Old emulator files remain. Template creation was postponed.'}
    for($attempt=1;$attempt -le 4;$attempt++){
        Assert-LauncherResetContinue
        $inventory=Assert-LauncherResetClosed
        $remaining=@($inventory.Keys|Where-Object{[int]$_ -ne 0}|Sort-Object -Descending)
        if(-not $remaining.Count){break}
        Write-Host "Waiting for old emulator registrations to clear (IDs: $($remaining -join ','); attempt $attempt/4)..."
        if($attempt -eq 4){throw ('Old emulator registrations still remain: '+($remaining -join ',')+'. Reset has not added any new instances. Close LDMultiplayer and retry Reset emulators.')}
        foreach($id in $remaining){
            Assert-LauncherResetContinue;$null=Assert-LauncherResetClosed
            $null=Invoke-LauncherResetNative @('remove','--index',"$id")
        }
        Start-Sleep -Milliseconds 500
    }
    $inventory=Assert-LauncherResetClosed
    if($inventory.Count -eq 1 -and $inventory.ContainsKey(0)){
        Write-Host 'LDPlayer retained its closed default registration (ID 0). Reusing it for the template restore.'
    }elseif($inventory.Count -eq 0){
        $null=Invoke-LauncherResetNative @('add','--name','LDPlayer-0')
    }else{throw 'The template registration changed during reset. No backup was restored.'}
    $deadline=[datetime]::UtcNow.AddSeconds(10)
    do{
        Assert-LauncherResetContinue
        $inventory=Assert-LauncherResetClosed
        if($inventory.Count -eq 1 -and $inventory.ContainsKey(0)){return}
        if(@($inventory.Keys|Where-Object{[int]$_ -ne 0}).Count){throw ('Unexpected instance IDs appeared while creating template 0: '+(($inventory.Keys|Sort-Object) -join ',')+'. Reset stopped before restoring another ID.')}
        Start-Sleep -Milliseconds 500
    }while([datetime]::UtcNow -lt $deadline)
    throw 'Template 0 registration did not become available. Reset stopped before restoring a backup.'
}

function Remove-LauncherNativeResetInstance {
    param([int]$Id)
    Assert-LauncherResetContinue
    $inventory=Assert-LauncherResetClosed
    if(-not $inventory.ContainsKey($Id)){return}
    Write-Host "Deleting LDPlayer $Id using LDPlayer's built-in delete command..."
    $nativeFailure=$null
    try{$null=Invoke-LauncherResetNative @('remove','--index',"$Id")}
    catch{$nativeFailure=$_.Exception}
    $deadline=[datetime]::UtcNow.AddSeconds(30)
    do{
        Assert-LauncherResetContinue
        $inventory=Assert-LauncherResetClosed
        if(-not $inventory.ContainsKey($Id)){
            Write-Host "LDPlayer $Id was deleted by LDPlayer."
            return
        }
        
        
        if($Id -eq 0){
            Write-Host 'LDPlayer retained its closed default instance 0 after the built-in delete request. Its template files will be refreshed.'
            return
        }
        if($nativeFailure -or [datetime]::UtcNow -ge $deadline){
            if($nativeFailure){throw $nativeFailure}
            throw "LDPlayer did not delete instance $Id. Reset stopped before deleting remaining files or creating new instances."
        }
        Start-Sleep -Milliseconds 500
    }while($true)
}

function Get-LauncherResetTemplateFiles {
    param($Settings=$Config)
    return (Get-LauncherTemplateFiles $Settings)
}

function Assert-LauncherResetOnlyTemplate {
    param($Settings=$Config)
    $Config=$Settings;$inventory=Get-LauncherResetInventory
    if($inventory.Count -ne 1 -or -not $inventory.ContainsKey(0)){throw 'Reset requires only LDPlayer 0 to exist. Remove other instances manually first; this reset does not delete emulators.'}
    $vms=Join-Path $Settings.LdPlayerInstallPath 'vms'
    foreach($item in @(Get-ChildItem -LiteralPath $vms -Directory)){
        if($item.Name -match '^leidian\d+$' -and $item.Name -cne 'leidian0'){throw ('An old instance folder still exists: '+$item.Name+'. It was not deleted. Only LDPlayer 0 may exist before creating copies.')}
    }
    foreach($item in @(Get-ChildItem -LiteralPath (Join-Path $vms 'config') -Filter 'leidian*.config' -File)){
        if($item.Name -match '^leidian\d+[.]config$' -and $item.Name -cne 'leidian0.config'){throw ('An old instance config still exists: '+$item.Name+'. It was not deleted. Only LDPlayer 0 may exist before creating copies.')}
    }
    return $inventory
}

function Invoke-LauncherGeneralReset {
    $mutex=New-Object Threading.Mutex $false,$Config.ResetMutexName;$held=$false
    $replacementMutex=New-Object Threading.Mutex $false,($Config.RestoreMutexName+'-NewInstance');$replacementHeld=$false;$sourceLocks=$null
    try{
        try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
        try{$replacementHeld=$replacementMutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$replacementHeld=$true}
        if(-not $held -or -not $replacementHeld -or @(Get-ActiveRestoreInstanceIds).Count){throw 'Another reset/replacement is active. No emulator was deleted or copied.'}
        $inventory=Assert-LauncherResetOnlyTemplate
        if($inventory[0].Running){
            Write-Host 'Closing only template LDPlayer 0 before copying its disks...'
            $null=Invoke-LauncherResetNative @('quit','--index','0')
            $deadline=[datetime]::UtcNow.AddSeconds(60)
            do{
                Assert-LauncherResetContinue;$inventory=Assert-LauncherResetOnlyTemplate
                if(-not $inventory[0].Running){break}
                if([datetime]::UtcNow -ge $deadline){throw 'LDPlayer 0 did not finish closing. No copies were created.'}
                Start-Sleep -Milliseconds 500
            }while($true)
        }
        $template=Get-LauncherResetTemplateFiles
        $sourceLocks=New-Object 'System.Collections.Generic.List[object]'
        foreach($path in $template.Files){$sourceLocks.Add([IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read))}
        Test-LauncherResetBackup
        Assert-LauncherResetContinue
        Write-TemplateStageManifest $Config.ResetPendingPath @{Version=2;Mode='CopiesFromExisting0';Count=$Config.ResetInstanceCount;StartedUtc=[datetime]::UtcNow.ToString('o')}
        $script:ResetNativeIds=@{}
        Clear-LauncherResetState
        $range=if($Config.ResetInstanceCount -gt 0){'1-'+$Config.ResetInstanceCount}else{'none'}
        Write-Host "Keeping LDPlayer 0. Creating exactly $($Config.ResetInstanceCount) new copies (IDs: $range) from its files; no emulator will be deleted."
        for($id=1;$id -le $Config.ResetInstanceCount;$id++){
            Assert-LauncherResetContinue;$null=Assert-LauncherResetClosed
            New-LauncherNativeResetInstance $id
            Write-Host "Copying template 0 files to LDPlayer $id/$($Config.ResetInstanceCount) and assigning its instance/disk registration IDs..."
            Copy-LauncherResetInstanceFiles $id
            $inventory=Assert-LauncherResetClosed
            if($inventory.Count -ne $id+1 -or -not $inventory.ContainsKey($id)){throw 'The created IDs differ from the requested copies. Creation stopped; no instances were deleted.'}
        }
        Assert-LauncherResetContinue;$inventory=Assert-LauncherResetClosed
        if((($inventory.Keys|Sort-Object) -join ',') -cne ((0..$Config.ResetInstanceCount) -join ',')){throw 'The final instance IDs do not match the requested copies.'}
        Set-LauncherConfigValues $Config.ConfigFilePath @{ExcludedLdPlayerIds='0';RecoveryTemplateId='0';ResetInstanceCount=[string]$Config.ResetInstanceCount} -Automatic
        [IO.File]::Delete($Config.ResetPendingPath)
        Write-Host "RESET COMPLETE: created $($Config.ResetInstanceCount) new copies, IDs: $range. Template 0 was kept; saved app data, cookies and queues were cleared. All instances are closed."
    }finally{
        if($sourceLocks){foreach($lock in $sourceLocks){$lock.Dispose()}}
        if($replacementHeld){$replacementMutex.ReleaseMutex()};$replacementMutex.Dispose()
        if($held){$mutex.ReleaseMutex()};$mutex.Dispose()
    }
}

function Confirm-LauncherUiReset {
    if($Ui.ForceClosePending -or $Ui.ForceCloseTask){throw 'Wait for force close to finish.'}
    if(($Ui.Process -and -not $Ui.Process.HasExited) -or (Test-LauncherRunning $Ui.Directory)){throw 'Stop the tool before creating emulator copies.'}
    if($Ui.LogReadTask){throw 'Wait for the emulator log copy to finish.'}
    if($Ui.ArrangeTask){throw 'Wait for window arrangement to finish.'}
    $null=$Ui.Settings.EndEdit();$count=[int]$Ui.ResetCount.Value
    Save-LauncherUiSettings
    $settings=Get-LauncherResetSettings $Ui.ConfigPath
    $null=Assert-LauncherResetOnlyTemplate $settings
    $message="Create exactly $count new instances (IDs 1-$count) by copying the existing LDPlayer 0?`r`n`r`nOnly LDPlayer 0 may exist before starting. No emulator is deleted. Template 0 is kept and closed before copying.`r`n`r`nAll locally saved app-data snapshots, standalone cookies, pending cookie updates and legacy cookies will be deleted. Exclusions and recovery queues are reset.`r`n`r`nEach copy uses native new-instance followed by direct file copying, without the clone feature."
    if($count -eq 0){$message=$message.Replace('Create exactly 0 new instances (IDs 1-0)','Keep template 0 without creating new instances')}
    $answer=[Windows.Forms.MessageBox]::Show($Ui.Form,$message,'Create copies from LDPlayer 0',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Question,[Windows.Forms.MessageBoxDefaultButton]::Button2)
    if($answer -eq [Windows.Forms.DialogResult]::Yes){Start-LauncherUiRun -Operation Reset}
}

function New-LauncherNativeResetInstance {
    param([int]$Id)
    $inventory=Assert-LauncherResetClosed
    if($inventory.ContainsKey($Id)){
        if($Id -ne 0 -or $inventory.Count -ne 1){throw 'The requested reset ID is already occupied.'}
        Write-Host 'Using the default instance 0 initialized by LDPlayer before applying template files.'
    }else{
        Write-Host "Creating LDPlayer $Id using LDPlayer's built-in new-instance command..."
        $addResultError=$null
        try{$null=Invoke-LauncherResetNative @('add','--name',"LDPlayer-$Id")}
        catch{
            
            
            if($_.Exception.Data['NativeCommand'] -cne 'add' -or [int]$_.Exception.Data['NativeExitCode'] -le 0 -or $_.Exception.Data['NativeDiagnosticError']){throw}
            $addResultError=$_.Exception
        }
        $inventory=Assert-LauncherResetClosed
        if(-not $inventory.ContainsKey($Id) -or $inventory.Count -ne $Id+1){throw "LDPlayer did not create the expected new instance $Id. Reset was stopped before applying template files."}
        $vms=Join-Path $Config.LdPlayerInstallPath 'vms'
        $configFile=Join-Path $vms "config\leidian$Id.config";Assert-InstanceReplacementDirectory $configFile $vms
        $configuration=ConvertFrom-Json ([IO.File]::ReadAllText($configFile))
        if(-not $configuration){throw "Native instance $Id has an incomplete configuration. Reset stopped before applying template files."}
        foreach($name in @('data.vmdk','sdcard.vmdk')){
            $disk=Join-Path $vms "leidian$Id\$name";Assert-InstanceReplacementDirectory $disk $vms
            $stream=[IO.File]::Open($disk,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            try{
                $magic=New-Object byte[] 4
                if($stream.Length -lt 1024 -or $stream.Read($magic,0,4) -ne 4 -or [Text.Encoding]::ASCII.GetString($magic) -cne 'KDMV'){throw "Native instance $Id has an incomplete $name. Reset stopped before applying template files."}
            }finally{$stream.Dispose()}
        }
        if($addResultError){Write-Host "LDPlayer add returned exit $($addResultError.Data['NativeExitCode']), but instance $Id is registered with valid generated disks and config. Continuing with the template files."}
    }
    if($null -eq $script:ResetNativeIds){$script:ResetNativeIds=@{}}
    $script:ResetNativeIds[$Id]=$true
}





function Save-LauncherUiCookie { throw 'Cookie editing has been replaced by automatic game-data snapshots.' }

function Start-LauncherUiRun {
    param([ValidateSet('Run','Reset')][string]$Operation='Run')
    if($Ui.ForceClosePending -or $Ui.ForceCloseTask){throw 'Wait for force close to finish.'}
    if($Ui.Process -and -not $Ui.Process.HasExited){throw 'The previous run is still stopping. Wait until the status says Stopped.'}
    if(Test-LauncherRunning $Ui.Directory){throw 'The tool is already running from this folder.'}
    if($Ui.ArrangeTask){throw 'Wait for window arrangement to finish.'}
    if($Ui.LogReadTask -and $Operation -eq 'Reset'){throw 'Wait for the emulator log copy to finish before resetting.'}
    if($Operation -eq 'Reset'){$settings=Get-LauncherResetSettings $Ui.ConfigPath}
    else{
        Assert-LauncherResetNotPending $Ui.Directory
        Save-LauncherUiSettings
        $settings=Read-FlowConfig -Path $Ui.ConfigPath
        $null=Resolve-LauncherRecoverySource -Settings $settings -Directory $Ui.Directory -CheckClosed
    }
    $directory=Join-Path ([IO.Path]::GetTempPath()) ('launcher-'+[guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $directory
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=Get-LauncherPowerShellPath
    $info.Arguments='-NoProfile -STA -NonInteractive -InputFormat Text -OutputFormat Text -Command "'+ '$content=[IO.File]::ReadAllText($env:LAUNCHER_FLOW_FILE); $marker=''# POWER''+''SHELL START''; & ([scriptblock]::Create($content.Substring($content.LastIndexOf($marker)+$marker.Length)))' +'"'
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.WorkingDirectory=$Ui.Directory
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
    $info.EnvironmentVariables['LAUNCHER_FLOW_FILE']=$Ui.LauncherPath
    $info.EnvironmentVariables['LAUNCHER_FLOW_MODE']=if($Operation -eq 'Reset'){'reset'}else{'worker'}
    $info.EnvironmentVariables['LAUNCHER_FLOW_RUN_DIRECTORY']=$directory
    $info.EnvironmentVariables['LAUNCHER_FLOW_STOP_FILE']=Join-Path $directory 'stop.request'
    $process=New-Object Diagnostics.Process;$process.StartInfo=$info
    Initialize-LauncherOutputReader
    $sink=[LauncherOutputReader]::new($process,(Join-Path $directory 'worker.log'))
    try{if(-not (Start-LauncherProcess $process 'PowerShell worker')){throw 'The tool could not start.'};$sink.Start()}catch{$sink.Dispose();$process.Dispose();throw}
    if($Ui.OutputSink){$Ui.OutputSink.Dispose()}
    if($Ui.Process){$Ui.Process.Dispose()}
    $Ui.OutputSink=$sink
    $Ui.Operation=$Operation;$Ui.Process=$process;$Ui.RunDirectory=$directory;$Ui.StopPending=$false;$Ui.LastWasBusy=$true
    if($Operation -eq 'Run' -and $Ui.Tabs){$Ui.Tabs.SelectedTab=$Ui.LogTab}
    Add-LauncherUiLog $(if($Operation -eq 'Reset'){"Starting confirmed emulator reset...`r`n"}else{"Starting tool...`r`n"})
    Update-LauncherUi
}

function Stop-LauncherUiRun {
    param([switch]$AutomationOnly)
    if(-not $AutomationOnly -and $Ui.CloseInstances -and ($Ui.ForceClosePending -or $Ui.ForceCloseTask)){
        if($Ui.ForceCloseTask){
            if(-not $Ui.CloseCancelRequested){[IO.File]::WriteAllText($Ui.CloseCancelPath,'stop');$Ui.CloseCancelRequested=$true;Add-LauncherUiLog "Cancelling Stop and close. Waiting for the current safe step; remaining instances will stay open...`r`n"}
        }else{
            $Ui.ForceClosePending=$false;$Ui.CloseInstances=$false;$Ui.CloseCancelPath=$null;$Ui.CloseCancelRequested=$false
            Set-LauncherUiProperty $Ui.StopClose Text 'Stop and close instances'
            Add-LauncherUiLog "Stop and close cancelled before instance shutdown began. The automation stop request remains active.`r`n"
        }
        return
    }
    $record=Read-LauncherRunRecord $Ui.Directory
    $path=$null
    if($Ui.Process -and -not $Ui.Process.HasExited -and $Ui.RunDirectory){$path=Join-Path $Ui.RunDirectory 'stop.request'}
    elseif($record -and (Test-LauncherRunning $Ui.Directory)){$path=$record.StopFile}
    if($path){[IO.File]::WriteAllText($path,'stop');$Ui.StopPending=$true;Add-LauncherUiLog "Stop requested. Waiting for workers and any active instance replacement to finish...`r`n"}
}

function Update-LauncherUiWorkerStatus {
    param([bool]$Running,$Record)
    if(-not $Ui.Workers){return}
    if(-not $Running){Set-LauncherUiProperty $Ui.Workers Text 'Workers: stopped';if($Ui.EmulatorStatuses){Set-LauncherUiProperty $Ui.EmulatorStatuses Text 'Monitoring stopped'};return}
    if($Ui.Operation -eq 'Reset'){Set-LauncherUiProperty $Ui.Workers Text 'Workers: waiting for Reset to finish';if($Ui.EmulatorStatuses){Set-LauncherUiProperty $Ui.EmulatorStatuses Text 'Resetting emulators...'};return}
    if(-not $Record){Set-LauncherUiProperty $Ui.Workers Text 'Workers: starting...';if($Ui.EmulatorStatuses){Set-LauncherUiProperty $Ui.EmulatorStatuses Text 'Waiting for the first checks...'};return}
    $path=Join-Path $Record.RunDirectory 'worker-status.json'
    try{
        $status=ConvertFrom-Json ([IO.File]::ReadAllText($path))
        if($Ui.EmulatorStatuses){
            $entries=@($status.Emulators|Sort-Object {[int]$_.Id}|ForEach-Object{"$($_.Id): $($_.Status)"})
            $statusText=if($entries.Count){$entries -join '  |  '}else{'Waiting for the first checks...'}
            Set-LauncherUiProperty $Ui.EmulatorStatuses Text $statusText
        }
        $items=@(foreach($worker in $status.Workers){
            $name=if($worker.Role -eq 'Monitor'){'Monitor'}else{'Setup '+[int]$worker.Number}
            $value=if($null -eq $worker.InstanceId){'idle'}else{'LDPlayer '+[int]$worker.InstanceId}
            if($worker.Retiring){$value+=' (stopping)'}
            $name+': '+$value
        })
        $text='Workers: '+($items -join '  |  ')
        $replacements=@(foreach($replacement in $status.Replacements){
            $state=if($replacement.Queued){'waiting for a loading slot'}elseif($replacement.Retrying){'retrying: '+$replacement.Step}else{$replacement.Step}
            if($replacement.Retrying -and -not $replacement.Queued -and $replacement.Reason){$reason=([string]$replacement.Reason -replace '[\r\n]+',' ');if($reason.Length -gt 120){$reason=$reason.Substring(0,117)+'...'};$state+='; '+$reason}
            $ids=if(@($replacement.Chain).Count -gt 2){$replacement.Chain -join " $([char]0x2192) "}else{"$($replacement.FromId) $([char]0x2192) $($replacement.ToId)"}
            "$ids ($state)"
        })
        if($replacements.Count){$text='Instance replacement: '+($replacements -join '  |  ')+"`r`n"+$text}
        $policyPath=Join-Path $Record.RunDirectory 'loading-policy.json'
        if([IO.File]::Exists($policyPath)){
            try{
                $policy=ConvertFrom-Json ([IO.File]::ReadAllText($policyPath))
                if($policy.Available){$text+="`r`nLoading limit: $($policy.Limit)  |  Reserved slots: $($policy.ActiveCount)";if($policy.Dynamic){$text+="  |  Running: $($policy.RunningCount)"}}
                else{$text+="`r`nRunning count unavailable. New loading actions are waiting."}
                $gate=Read-DynamicLaunchGate $Record.RunDirectory
                if($gate){$text+="`r`nWaiting for LDPlayer $($gate.Id) to open before another emulator starts."}
            }catch{}
        }
        Set-LauncherUiProperty $Ui.Workers Text $text
    }catch{Set-LauncherUiProperty $Ui.Workers Text 'Workers: waiting for live assignments...'}
}

function Update-LauncherUi {
    Complete-LauncherUiEmulatorLogCopy
    Complete-LauncherUiWindowArrangement
    Complete-LauncherUiForceClose
    if($Ui.OutputSink){Add-LauncherUiLog ($Ui.OutputSink.Drain())}
    $ownRunning=$Ui.Process -and -not $Ui.Process.HasExited
    $busy=[bool]($ownRunning -or (Test-LauncherRunning $Ui.Directory))
    $forceBusy=[bool]($Ui.ForceClosePending -or $Ui.ForceCloseTask)
    if($busy -and -not $Ui.LastWasBusy){$null=$Ui.Settings.EndEdit()}
    Set-LauncherUiProperty $Ui.Settings ReadOnly ([bool]($busy -or $forceBusy))
    Set-LauncherUiProperty $Ui.ServerLinks ReadOnly ([bool]($busy -or $forceBusy))
    foreach($name in @('Overwrite','SkipRepair','Save','Reload','CookieInput','ApplyCookie','ClearCookie','Reset','ResetCount')){Set-LauncherUiProperty $Ui[$name] Enabled (-not $busy -and -not $forceBusy)}
    Set-LauncherUiProperty $Ui.ForceClose Enabled (-not $forceBusy)
    Set-LauncherUiProperty $Ui.StopClose Enabled (-not $forceBusy)
    if($forceBusy){$closeButton=if($Ui.CloseInstances){$Ui.StopClose}else{$Ui.ForceClose};Set-LauncherUiProperty $closeButton Text $(if($Ui.ForceCloseTask){'Closing LDPlayer...'}else{'Waiting for stop...'})}
    Set-LauncherUiProperty $Ui.Stop Enabled ([bool]($(if($Ui.CloseInstances -and $forceBusy){-not $Ui.CloseCancelRequested}else{$busy -and -not $Ui.StopPending})))
    $canStart=-not $busy -and -not $forceBusy
    try{
        $savedSettings=Read-LauncherUiConfig $Ui.ConfigPath
        if($busy -or $Ui.LastWasBusy){
            foreach($row in $Ui.Settings.Rows){if($row.Tag -ceq 'ExcludedLdPlayerIds' -and [string]$row.Cells[1].Value -cne [string]$savedSettings.ExcludedLdPlayerIds){$row.Cells[1].Value=[string]$savedSettings.ExcludedLdPlayerIds}}
        }
        if($busy){Set-LauncherUiProperty $Ui.SkipRepair Checked ([bool]($savedSettings.SkipRepairNextStart -eq '1'))}
        $backup=Resolve-LauncherRecoverySource -Settings $savedSettings -Directory $Ui.Directory
        $backupText=''
        Set-LauncherUiProperty $Ui.Backup Text $backupText
        Set-LauncherUiProperty $Ui.Backup ForeColor ([Drawing.Color]::FromArgb(135,211,159))
    }catch{
        Set-LauncherUiProperty $Ui.Backup Text $_.Exception.Message
        Set-LauncherUiProperty $Ui.Backup ForeColor ([Drawing.Color]::FromArgb(255,135,140))
        $canStart=$false
    }
    try{Assert-LauncherResetNotPending $Ui.Directory}catch{
        $canStart=$false
        if(-not $busy){Set-LauncherUiProperty $Ui.Backup Text $_.Exception.Message;Set-LauncherUiProperty $Ui.Backup ForeColor ([Drawing.Color]::FromArgb(255,135,140))}
    }
    $resetBusy=$busy -and $Ui.Operation -eq 'Reset'
    Set-LauncherUiProperty $Ui.Arrange Enabled (-not $resetBusy -and -not $Ui.ArrangeTask -and -not $forceBusy)
    if($Ui.ArrangeTask){Set-LauncherUiProperty $Ui.Reset Enabled $false;$canStart=$false}
    if(-not $Ui.LogReadTask){Set-LauncherUiProperty $Ui.CopyEmulatorLog Enabled (-not $resetBusy -and -not $forceBusy);Set-LauncherUiProperty $Ui.LogEmulatorId Enabled (-not $resetBusy -and -not $forceBusy)}
    Set-LauncherUiProperty $Ui.Start Enabled ([bool]$canStart)
    $status=if($forceBusy){$(if($Ui.CloseCancelRequested){'Cancelling instance shutdown - waiting for the current safe step...'}elseif($Ui.ForceCloseTask){if($Ui.CloseInstances){'Closing apps and running LDPlayer instances...'}else{'Force closing LDPlayer processes...'}}else{'Waiting for current operations to stop before closing LDPlayer...'})}elseif($Ui.StopPending -and $busy){'Stopping - waiting for the current operation to finish...'}elseif($resetBusy){'Resetting emulators - settings are locked'}elseif($busy){'Running - settings are locked'}else{'Stopped - settings can be changed'}
    Set-LauncherUiProperty $Ui.Status Text $status
    Set-LauncherUiProperty $Ui.Status ForeColor $(if($busy){[Drawing.Color]::FromArgb(135,211,159)}else{[Drawing.Color]::FromArgb(153,169,190)})
    $record=Read-LauncherRunRecord $Ui.Directory
    Update-LauncherUiWorkerStatus -Running $busy -Record $record
    if($resetBusy){Set-LauncherUiProperty $Ui.Progress Text 'Reset in progress. Stop waits for the current disk operation to finish.'}
    elseif($busy -and $record){
        try{
            $progress=ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $record.RunDirectory 'cookie-check-progress.json')))
            Set-LauncherUiProperty $Ui.Overwrite Checked ([bool]$progress.OverwriteEnabled)
            Set-LauncherUiProperty $Ui.Progress Text "Initial game-data checks: $($progress.Checked)/$($progress.Total)."
        }catch{Set-LauncherUiProperty $Ui.Progress Text 'Starting - game-data snapshots have not begun yet.'}
    }elseif(-not $busy){Set-LauncherUiProperty $Ui.Progress Text ''}
    if($Ui.LastWasBusy -and -not $busy){
        if($Ui.Tabs){$Ui.Tabs.SelectedTab=$Ui.SettingsTab}
        $Ui.StopPending=$false
        if($Ui.OutputSink){Add-LauncherUiLog ($Ui.OutputSink.Drain());$Ui.OutputSink.Dispose();$Ui.OutputSink=$null}
        if($Ui.Process){$Ui.LastExitCode=$Ui.Process.ExitCode;$Ui.Process.Dispose();$Ui.Process=$null}
        if($Ui.Operation -eq 'Reset'){
            $Ui.CookieInput.Clear();$Ui.AccountsFingerprint=''
            if($Ui.LastExitCode -eq 0){Add-LauncherUiLog "Reset finished. Use Start tool when ready.`r`n"}
            else{Add-LauncherUiLog "Copy creation did not finish. Keep LDPlayer 0, remove partial copies manually, then use Reset emulators again. No emulator was deleted by this reset.`r`n"}
        }else{Add-LauncherUiLog "Tool stopped. You can start it again.`r`n"}
        if($savedSettings){
            Set-LauncherUiProperty $Ui.Overwrite Checked ([bool]($savedSettings.OverwriteExistingCookies -eq '1'))
            Set-LauncherUiProperty $Ui.SkipRepair Checked ([bool]($savedSettings.SkipRepairNextStart -eq '1'))
        }
        Read-LauncherUiAccounts
        if($Ui.CloseWhenStopped -and -not $forceBusy){$Ui.Timer.Stop();$Ui.Form.Close();return}
    }
    $Ui.LastWasBusy=$busy
    if(([datetime]::UtcNow-$Ui.LastAccountRefresh).TotalSeconds -ge 3){Read-LauncherUiAccounts;$Ui.LastAccountRefresh=[datetime]::UtcNow}
}

function Initialize-LauncherDarkControls {
    if('LauncherDarkTabs' -as [type]){return}
    Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -WarningAction SilentlyContinue -TypeDefinition @'
using System.Drawing;
using System.Windows.Forms;
public sealed class LauncherDarkTabs : TabControl {
    public LauncherDarkTabs(){SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer|ControlStyles.ResizeRedraw,true);}
    protected override void OnPaint(PaintEventArgs e){
        Color background=Color.FromArgb(18,23,31);e.Graphics.Clear(background);
        for(int i=0;i<TabCount;i++){
            Rectangle r=GetTabRect(i);bool selected=i==SelectedIndex;
            using(var b=new SolidBrush(selected?Color.FromArgb(25,32,44):background))e.Graphics.FillRectangle(b,r);
            TextRenderer.DrawText(e.Graphics,TabPages[i].Text,Font,r,selected?ForeColor:Color.FromArgb(153,169,190),TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter);
            if(selected)using(var b=new SolidBrush(Color.FromArgb(76,140,240)))e.Graphics.FillRectangle(b,r.Left,r.Bottom-3,r.Width,3);
        }
    }
    protected override void OnSelectedIndexChanged(System.EventArgs e){base.OnSelectedIndexChanged(e);Invalidate();}
}
public sealed class LauncherDarkButton : Button {
    protected override void OnPaint(PaintEventArgs e){
        if(Enabled){base.OnPaint(e);return;}
        e.Graphics.Clear(BackColor);
        using(var p=new Pen(Color.FromArgb(42,53,70)))e.Graphics.DrawRectangle(p,0,0,Width-1,Height-1);
        TextRenderer.DrawText(e.Graphics,Text,Font,ClientRectangle,Color.FromArgb(115,132,155),TextFormatFlags.HorizontalCenter|TextFormatFlags.VerticalCenter);
    }
}
'@
}

function Update-LauncherUiToolbarHeight {
    if(-not $Ui.Toolbar -or -not $Ui.MainLayout){return}
    $Ui.Toolbar.PerformLayout()
    $bottom=0;foreach($control in $Ui.Toolbar.Controls){if($control.Visible){$bottom=[math]::Max($bottom,$control.Bottom)}}
    $height=[math]::Max(74,$bottom+12)
    if($Ui.MainLayout.RowStyles[0].Height -ne $height){$Ui.MainLayout.RowStyles[0].Height=$height}
}

function Set-LauncherUiDarkTheme {
    param($Control)
    $background=[Drawing.Color]::FromArgb(18,23,31);$surface=[Drawing.Color]::FromArgb(25,32,44);$raised=[Drawing.Color]::FromArgb(34,44,60)
    $text=[Drawing.Color]::FromArgb(225,232,242);$muted=[Drawing.Color]::FromArgb(153,169,190);$border=[Drawing.Color]::FromArgb(52,66,88)
    $Control.BackColor=$background;$Control.ForeColor=$text
    foreach($child in $Control.Controls){Set-LauncherUiDarkTheme $child}
    if($Control -is [Windows.Forms.Button]){
        $Control.FlatStyle='Flat';$Control.UseVisualStyleBackColor=$false;$Control.BackColor=$raised
        $Control.FlatAppearance.BorderColor=$border;$Control.FlatAppearance.MouseOverBackColor=[Drawing.Color]::FromArgb(43,59,81);$Control.FlatAppearance.MouseDownBackColor=[Drawing.Color]::FromArgb(49,78,119)
        if($Control -eq $Ui.Start){$Control.BackColor=[Drawing.Color]::FromArgb(37,84,148);$Control.FlatAppearance.BorderColor=[Drawing.Color]::FromArgb(76,140,240)}
        elseif($Control -eq $Ui.ForceClose){$Control.BackColor=[Drawing.Color]::FromArgb(67,33,44);$Control.ForeColor=[Drawing.Color]::FromArgb(255,185,191);$Control.FlatAppearance.BorderColor=[Drawing.Color]::FromArgb(119,56,72)}
        elseif($Control -eq $Ui.StopClose){$Control.BackColor=[Drawing.Color]::FromArgb(71,52,32);$Control.ForeColor=[Drawing.Color]::FromArgb(255,216,151)}
    }elseif($Control -is [Windows.Forms.DataGridView]){
        $Control.BackgroundColor=$surface;$Control.GridColor=[Drawing.Color]::FromArgb(40,50,65);$Control.EnableHeadersVisualStyles=$false
        $Control.DefaultCellStyle.BackColor=$surface;$Control.DefaultCellStyle.ForeColor=$text;$Control.DefaultCellStyle.SelectionBackColor=[Drawing.Color]::FromArgb(49,78,119);$Control.DefaultCellStyle.SelectionForeColor=$text
        $Control.AlternatingRowsDefaultCellStyle.BackColor=[Drawing.Color]::FromArgb(22,29,40)
        $Control.ColumnHeadersDefaultCellStyle.BackColor=$raised;$Control.ColumnHeadersDefaultCellStyle.ForeColor=$text;$Control.ColumnHeadersDefaultCellStyle.SelectionBackColor=$raised
        $Control.ColumnHeadersBorderStyle='Single';$Control.ColumnHeadersHeight=32
    }elseif($Control -is [Windows.Forms.TextBoxBase] -or $Control -is [Windows.Forms.NumericUpDown]){
        $Control.BackColor=$surface;$Control.ForeColor=$text
        if($Control -is [Windows.Forms.RichTextBox]){$Control.BackColor=[Drawing.Color]::FromArgb(12,17,24)}
    }elseif($Control -is [Windows.Forms.TabPage]){$Control.UseVisualStyleBackColor=$false}
    elseif($Control -is [Windows.Forms.TabControl]){
        $Control.DrawMode='OwnerDrawFixed';$Control.Padding=[Drawing.Point]::new(18,7)
        $Control.Add_DrawItem({
            param($sender,$event)
            $selected=$event.Index -eq $sender.SelectedIndex
            $brush=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(18,23,31))
            try{$event.Graphics.FillRectangle($brush,$event.Bounds)}finally{$brush.Dispose()}
            $color=if($selected){[Drawing.Color]::FromArgb(225,232,242)}else{[Drawing.Color]::FromArgb(153,169,190)}
            [Windows.Forms.TextRenderer]::DrawText($event.Graphics,$sender.TabPages[$event.Index].Text,$sender.Font,$event.Bounds,$color,([Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [Windows.Forms.TextFormatFlags]::VerticalCenter))
            if($selected){$brush=[Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(76,140,240));try{$event.Graphics.FillRectangle($brush,$event.Bounds.Left,$event.Bounds.Bottom-3,$event.Bounds.Width,3)}finally{$brush.Dispose()}}
        })
    }elseif($Control -is [Windows.Forms.Label] -and $Control -ne $Ui.Title){$Control.ForeColor=$muted}
}

function Show-LauncherUi {
    param([string]$LauncherPath)
    Add-Type -AssemblyName System.Windows.Forms,System.Drawing
    Initialize-LauncherDarkControls
    [Windows.Forms.Application]::EnableVisualStyles()
    $script:Ui=@{LauncherPath=$LauncherPath;Directory=[IO.Path]::GetDirectoryName($LauncherPath);Process=$null;LastWasBusy=$false;StopPending=$false;CloseWhenStopped=$false;RefreshingAccounts=$false;LastAccountRefresh=[datetime]::MinValue;OutputSink=$null;LastExitCode=0}
    $Ui.LogArchivePath=Join-Path ([IO.Path]::GetTempPath()) ('launcher-live-log-'+[guid]::NewGuid().ToString('N')+'.txt')
    $Ui.LogArchiveWriter=[IO.StreamWriter]::new($Ui.LogArchivePath,$false,[Text.UTF8Encoding]::new($false))
    $Ui.ConfigPath=Join-Path $Ui.Directory 'config.ini'
    $form=New-Object Windows.Forms.Form;$Ui.Form=$form
    $form.Text='launcher';$form.StartPosition='CenterScreen';$form.Size=[Drawing.Size]::new(1160,900);$form.MinimumSize=[Drawing.Size]::new(950,750)
    $form.Font=[Drawing.Font]::new('Segoe UI',10);$form.BackColor=[Drawing.Color]::White
    $layout=New-Object Windows.Forms.TableLayoutPanel;$Ui.MainLayout=$layout;$layout.Dock='Fill';$layout.ColumnCount=1;$layout.RowCount=4
    $null=$layout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent,100))
    $null=$layout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute,110))
    $null=$layout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute,282))
    $null=$layout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent,100))
    $null=$layout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute,28))
    $layout.Padding=[Windows.Forms.Padding]::new(14);$form.Controls.Add($layout)
    $top=New-Object Windows.Forms.TableLayoutPanel;$top.Dock='Fill';$top.ColumnCount=2;$top.RowCount=1
    $null=$top.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute,180));$null=$top.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent,100))
    $brand=New-Object Windows.Forms.Panel;$brand.Dock='Fill';$top.Controls.Add($brand,0,0)
    $title=New-Object Windows.Forms.Label;$Ui.Title=$title;$title.Text='launcher';$title.Font=[Drawing.Font]::new('Segoe UI',18,[Drawing.FontStyle]::Bold);$title.AutoSize=$true;$title.Location=[Drawing.Point]::new(0,7);$brand.Controls.Add($title)
    $subtitle=New-Object Windows.Forms.Label;$subtitle.Text='Multi-instance control';$subtitle.AutoSize=$true;$subtitle.Location=[Drawing.Point]::new(3,43);$brand.Controls.Add($subtitle)
    $actions=New-Object Windows.Forms.FlowLayoutPanel;$Ui.Toolbar=$actions;$actions.Dock='Fill';$actions.WrapContents=$true;$top.Controls.Add($actions,1,0)
    foreach($entry in @(@('Start','Start tool'),@('Stop','Stop tool'),@('Save','Save settings'),@('Reload','Reload'),@('Reset','Reset emulators'))){
        if($entry[0] -eq 'Reset'){continue}
        $width=switch($entry[0]){'Start'{108};'Stop'{100};'Save'{124};default{88}}
        $button=New-Object LauncherDarkButton;$button.Text=$entry[1];$button.Size=[Drawing.Size]::new($width,36);$button.Margin=[Windows.Forms.Padding]::new(0,4,8,4);$Ui[$entry[0]]=$button;$actions.Controls.Add($button)
        if($entry[0] -eq 'Stop'){$stopClose=New-Object LauncherDarkButton;$Ui.StopClose=$stopClose;$stopClose.Text='Stop and close instances';$stopClose.Size=[Drawing.Size]::new(190,36);$stopClose.Margin=[Windows.Forms.Padding]::new(0,4,8,4);$actions.Controls.Add($stopClose)}
    }
    $resetGroup=New-Object Windows.Forms.FlowLayoutPanel;$resetGroup.WrapContents=$false;$resetGroup.Size=[Drawing.Size]::new(274,44);$resetGroup.Margin=[Windows.Forms.Padding]::new(0);$actions.Controls.Add($resetGroup)
    $reset=New-Object LauncherDarkButton;$Ui.Reset=$reset;$reset.Text='Reset emulators';$reset.Size=[Drawing.Size]::new(144,36);$reset.Margin=[Windows.Forms.Padding]::new(0,4,8,4);$resetGroup.Controls.Add($reset)
    $resetCountLabel=New-Object Windows.Forms.Label;$resetCountLabel.Text='Count';$resetCountLabel.AutoSize=$true;$resetCountLabel.Margin=[Windows.Forms.Padding]::new(0,13,3,0);$resetGroup.Controls.Add($resetCountLabel)
    $resetCount=New-Object Windows.Forms.NumericUpDown;$Ui.ResetCount=$resetCount
    $resetCount.Minimum=0;$resetCount.Maximum=1000;$resetCount.Value=20;$resetCount.DecimalPlaces=0;$resetCount.ThousandsSeparator=$false;$resetCount.Width=64;$resetCount.Margin=[Windows.Forms.Padding]::new(3,9,0,0);$resetGroup.Controls.Add($resetCount)
    $resetCount.Add_TextChanged({
        $size=[Windows.Forms.TextRenderer]::MeasureText(($Ui.ResetCount.Text+' '),$Ui.ResetCount.Font)
        Set-LauncherUiProperty $Ui.ResetCount Width ([int][math]::Max(56,$size.Width+30))
    })
    $layout.Controls.Add($top,0,0)
    $policy=New-Object Windows.Forms.Panel;$policy.Dock='Fill'
    $forceClose=New-Object LauncherDarkButton;$Ui.ForceClose=$forceClose;$forceClose.Text='Force close LDPlayer';$forceClose.Size=[Drawing.Size]::new(180,32);$forceClose.Location=[Drawing.Point]::new(($policy.ClientSize.Width-180),0);$forceClose.Anchor='Top,Right';$policy.Controls.Add($forceClose)
    $overwrite=New-Object Windows.Forms.CheckBox;$Ui.Overwrite=$overwrite
    $overwrite.Visible=$false;$overwrite.Text='Game data is saved automatically';$overwrite.AutoSize=$true;$overwrite.Location=[Drawing.Point]::new(0,0);$policy.Controls.Add($overwrite)
    $skipRepair=New-Object Windows.Forms.CheckBox;$Ui.SkipRepair=$skipRepair;$skipRepair.Text='Skip Repair all on next Start (one use)';$skipRepair.AutoSize=$true;$skipRepair.Location=[Drawing.Point]::new(0,5);$policy.Controls.Add($skipRepair)
    $arrange=New-Object LauncherDarkButton;$Ui.Arrange=$arrange;$arrange.Text='Arrange windows';$arrange.Size=[Drawing.Size]::new(160,32);$arrange.Location=[Drawing.Point]::new(($policy.ClientSize.Width-348),0);$arrange.Anchor='Top,Right';$policy.Controls.Add($arrange)
    $arrangeStatus=New-Object Windows.Forms.Label;$Ui.ArrangeStatus=$arrangeStatus;$arrangeStatus.Size=[Drawing.Size]::new(348,24);$arrangeStatus.Location=[Drawing.Point]::new(($policy.ClientSize.Width-348),67);$arrangeStatus.Anchor='Top,Right';$arrangeStatus.TextAlign='MiddleRight';$arrangeStatus.AutoEllipsis=$true;$policy.Controls.Add($arrangeStatus)
    $arrange.Add_Click({try{Start-LauncherUiWindowArrangement}catch{Set-LauncherUiProperty $Ui.ArrangeStatus Text $_.Exception.Message;Set-LauncherUiProperty $Ui.ArrangeStatus ForeColor ([Drawing.Color]::FromArgb(255,135,140))}})
    $progress=New-Object Windows.Forms.Label;$Ui.Progress=$progress;$progress.AutoSize=$true;$progress.Location=[Drawing.Point]::new(0,43);$policy.Controls.Add($progress)
    $backupLabel=New-Object Windows.Forms.Label;$Ui.Backup=$backupLabel;$backupLabel.AutoSize=$true;$backupLabel.Location=[Drawing.Point]::new(0,69);$policy.Controls.Add($backupLabel)
    $mismatch=New-Object Windows.Forms.Label;$Ui.CookieMismatch=$mismatch
    $mismatch.AutoSize=$true;$mismatch.Visible=$false;$mismatch.Location=[Drawing.Point]::new(0,121)
    $mismatch.Font=[Drawing.Font]::new('Segoe UI',10,[Drawing.FontStyle]::Bold);$mismatch.ForeColor=[Drawing.Color]::FromArgb(255,135,140);$mismatch.BackColor=[Drawing.Color]::MistyRose
    $policy.Controls.Add($mismatch)
    $workerDisplay=New-Object Windows.Forms.TextBox;$Ui.Workers=$workerDisplay
    $workerDisplay.ReadOnly=$true;$workerDisplay.Multiline=$true;$workerDisplay.WordWrap=$true;$workerDisplay.ScrollBars='Vertical'
    $workerDisplay.BorderStyle='None';$workerDisplay.BackColor=[Drawing.Color]::White;$workerDisplay.ForeColor=[Drawing.Color]::FromArgb(218,226,238)
    $workerDisplay.Location=[Drawing.Point]::new(0,108);$workerDisplay.Size=[Drawing.Size]::new([math]::Max(100,$policy.ClientSize.Width),60)
    $workerDisplay.Anchor='Top,Left,Right';$workerDisplay.TabStop=$false;$workerDisplay.Text='Workers: stopped';$policy.Controls.Add($workerDisplay)
    $statusLabel=New-Object Windows.Forms.Label;$statusLabel.Text='LDPlayer status (latest checks)';$statusLabel.AutoSize=$true;$statusLabel.Location=[Drawing.Point]::new(0,184);$policy.Controls.Add($statusLabel)
    $emulatorStatuses=New-Object Windows.Forms.TextBox;$Ui.EmulatorStatuses=$emulatorStatuses
    $emulatorStatuses.ReadOnly=$true;$emulatorStatuses.Multiline=$true;$emulatorStatuses.WordWrap=$true;$emulatorStatuses.ScrollBars='Vertical'
    $emulatorStatuses.BorderStyle='FixedSingle';$emulatorStatuses.BackColor=[Drawing.Color]::White;$emulatorStatuses.ForeColor=[Drawing.Color]::FromArgb(218,226,238)
    $emulatorStatuses.Location=[Drawing.Point]::new(0,207);$emulatorStatuses.Size=[Drawing.Size]::new([math]::Max(100,$policy.ClientSize.Width),66)
    $emulatorStatuses.Anchor='Top,Left,Right';$emulatorStatuses.TabStop=$false;$emulatorStatuses.Text='Monitoring stopped';$policy.Controls.Add($emulatorStatuses)
    $layout.Controls.Add($policy,0,1)
    $tabs=New-Object LauncherDarkTabs;$Ui.Tabs=$tabs;$tabs.Dock='Fill';$layout.Controls.Add($tabs,0,2)
    $settingsTab=New-Object Windows.Forms.TabPage;$Ui.SettingsTab=$settingsTab;$settingsTab.Text='Settings';$tabs.TabPages.Add($settingsTab)
    $grid=New-Object Windows.Forms.DataGridView;$Ui.Settings=$grid
    Enable-LauncherGridBuffering $grid
    $grid.Dock='Fill';$grid.AllowUserToAddRows=$false;$grid.AllowUserToDeleteRows=$false;$grid.RowHeadersVisible=$false;$grid.BackgroundColor=[Drawing.Color]::White;$grid.BorderStyle='None';$grid.AutoSizeColumnsMode='Fill'
    $null=$grid.Columns.Add('Setting','Setting');$null=$grid.Columns.Add('Value','Value');$grid.Columns[0].ReadOnly=$true;$grid.Columns[0].FillWeight=35;$grid.Columns[1].FillWeight=65
    $grid.AllowUserToResizeColumns=$false;$grid.AllowUserToResizeRows=$false;$grid.AutoSizeRowsMode='AllCells';$grid.DefaultCellStyle.WrapMode='True';$grid.RowTemplate.MinimumHeight=28;$grid.EditMode='EditProgrammatically'
    foreach($column in $grid.Columns){$column.SortMode='NotSortable'}
    $settingsLayout=New-Object Windows.Forms.TableLayoutPanel;$settingsLayout.Dock='Fill';$settingsLayout.ColumnCount=1;$settingsLayout.RowCount=2
    $null=$settingsLayout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent,100))
    $null=$settingsLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize));$null=$settingsLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent,100));$settingsTab.Controls.Add($settingsLayout)
    $linkPanel=New-Object Windows.Forms.TableLayoutPanel;$linkPanel.Dock='Top';$linkPanel.AutoSize=$true;$linkPanel.ColumnCount=1;$linkPanel.RowCount=3
    $null=$linkPanel.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent,100))
    $linkLabel=New-Object Windows.Forms.Label;$linkLabel.Text='Server links';$linkLabel.AutoSize=$true;$linkPanel.Controls.Add($linkLabel,0,0)
    $linksInput=New-Object Windows.Forms.TextBox;$Ui.ServerLinks=$linksInput;$linksInput.Multiline=$true;$linksInput.AcceptsReturn=$true;$linksInput.WordWrap=$true;$linksInput.ScrollBars='Vertical';$linksInput.Dock='Top';$linksInput.Height=48;$linksInput.MaxLength=1048576;$linkPanel.Controls.Add($linksInput,0,1)
    $linkCount=New-Object Windows.Forms.Label;$Ui.LinkCount=$linkCount;$linkCount.AutoSize=$true;$linkCount.Margin=[Windows.Forms.Padding]::new(3,3,3,10);$linkCount.ForeColor=[Drawing.Color]::FromArgb(153,169,190);$linkPanel.Controls.Add($linkCount,0,2)
    $settingsLayout.Controls.Add($linkPanel,0,0);$settingsLayout.Controls.Add($grid,0,1)
    $linksInput.Add_TextChanged({Update-LauncherUiInputSizes -Part Links});$linksInput.Add_SizeChanged({Update-LauncherUiInputSizes -Part Links})
    $grid.Add_CellDoubleClick({param($sender,$event) if($event.RowIndex -ge 0 -and $event.ColumnIndex -eq 1 -and -not $Ui.Settings.ReadOnly){$null=$Ui.Settings.BeginEdit($true)}})
    $grid.Add_EditingControlShowing({param($sender,$event) $event.Control.remove_TextChanged($Ui.ResizeEditorHandler);$event.Control.add_TextChanged($Ui.ResizeEditorHandler);Update-LauncherUiInputSizes -Part Setting})
    $Ui.ResizeEditorHandler=[EventHandler]{Update-LauncherUiInputSizes -Part Setting}
    $grid.Add_CellEndEdit({param($sender,$event) if($event.RowIndex -ge 0){$Ui.Settings.Rows[$event.RowIndex].MinimumHeight=28;$Ui.Settings.AutoResizeRow($event.RowIndex)}})
    $accountsTab=New-Object Windows.Forms.TabPage;$accountsTab.Text='Game data';$tabs.TabPages.Add($accountsTab)
    $accountLayout=New-Object Windows.Forms.TableLayoutPanel;$accountLayout.Dock='Fill';$accountLayout.ColumnCount=1;$accountLayout.RowCount=3
    $null=$accountLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent,100));$null=$accountLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute,0));$null=$accountLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute,54));$accountsTab.Controls.Add($accountLayout)
    $accounts=New-Object Windows.Forms.DataGridView;$Ui.Accounts=$accounts
    Enable-LauncherGridBuffering $accounts
    $accounts.Dock='Fill';$accounts.ReadOnly=$true;$accounts.AllowUserToAddRows=$false;$accounts.AllowUserToDeleteRows=$false;$accounts.RowHeadersVisible=$false;$accounts.MultiSelect=$false;$accounts.SelectionMode='FullRowSelect';$accounts.AutoSizeColumnsMode='Fill';$accounts.BackgroundColor=[Drawing.Color]::White;$accounts.BorderStyle='None'
    $accounts.AllowUserToResizeColumns=$false;$accounts.AllowUserToResizeRows=$false;$accounts.AutoSizeRowsMode='AllCells';$accounts.DefaultCellStyle.WrapMode='True'
    foreach($column in @(@('Id','Emulator',10),@('Package','App package',24),@('Local','Snapshot size',18),@('App','Last saved (UTC)',15),@('Status','Status',20),@('Message','Details',45))){$index=$accounts.Columns.Add($column[0],$column[1]);$accounts.Columns[$index].FillWeight=$column[2]}
    $accountLayout.Controls.Add($accounts,0,0)
    $edit=New-Object Windows.Forms.FlowLayoutPanel;$edit.Dock='Fill';$edit.WrapContents=$false
    $Ui.CookieEdit=$edit;$edit.Visible=$false
    $inputLabel=New-Object Windows.Forms.Label;$inputLabel.Text='Replacement cookie:';$inputLabel.AutoSize=$true;$inputLabel.Margin=[Windows.Forms.Padding]::new(0,10,7,0);$edit.Controls.Add($inputLabel)
    $input=New-Object Windows.Forms.TextBox;$Ui.CookieInput=$input;$input.UseSystemPasswordChar=$true;$input.Width=300;$input.MaxLength=16384;$input.Margin=[Windows.Forms.Padding]::new(0,7,8,0);$edit.Controls.Add($input)
    $apply=New-Object Windows.Forms.Button;$Ui.ApplyCookie=$apply;$apply.Text='Save for selected app';$apply.Size=[Drawing.Size]::new(185,34);$apply.Margin=[Windows.Forms.Padding]::new(0,4,8,0);$edit.Controls.Add($apply)
    $clear=New-Object Windows.Forms.Button;$Ui.ClearCookie=$clear;$clear.Text='Clear saved value';$clear.Size=[Drawing.Size]::new(160,34);$clear.Margin=[Windows.Forms.Padding]::new(0,4,0,0);$edit.Controls.Add($clear)
    $input.Add_TextChanged({Update-LauncherUiInputSizes -Part Cookie});$edit.Add_SizeChanged({Update-LauncherUiInputSizes -Part Cookie})
    $accountLayout.Controls.Add($edit,0,1)
    $hint=New-Object Windows.Forms.Label;$Ui.CookieHint=$hint;$hint.Dock='Fill';$hint.Padding=[Windows.Forms.Padding]::new(2,7,2,0);$hint.ForeColor=[Drawing.Color]::FromArgb(153,169,190);$accountLayout.Controls.Add($hint,0,2)
    $logTab=New-Object Windows.Forms.TabPage;$logTab.Text='Live log';$Ui.LogTab=$logTab;$tabs.TabPages.Add($logTab)
    $logPanel=New-Object Windows.Forms.GroupBox;$logPanel.Text='Live log';$logPanel.Dock='Fill';$logPanel.Padding=[Windows.Forms.Padding]::new(7);$logTab.Controls.Add($logPanel)
    $logLayout=New-Object Windows.Forms.TableLayoutPanel;$logLayout.Dock='Fill';$logLayout.ColumnCount=1;$logLayout.RowCount=2
    $null=$logLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute,38));$null=$logLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent,100));$logPanel.Controls.Add($logLayout)
    $logTools=New-Object Windows.Forms.FlowLayoutPanel;$logTools.Dock='Fill';$logTools.WrapContents=$false;$logLayout.Controls.Add($logTools,0,0)
    $copyAll=New-Object Windows.Forms.Button;$Ui.CopyLiveLog=$copyAll;$copyAll.Text='Copy all live logs';$copyAll.AutoSize=$true;$logTools.Controls.Add($copyAll)
    $idLabel=New-Object Windows.Forms.Label;$idLabel.Text='Emulator ID:';$idLabel.AutoSize=$true;$idLabel.Margin=[Windows.Forms.Padding]::new(12,7,3,0);$logTools.Controls.Add($idLabel)
    $logId=New-Object Windows.Forms.NumericUpDown;$Ui.LogEmulatorId=$logId;$logId.Minimum=0;$logId.Maximum=2147483647;$logId.Width=65;$logId.Margin=[Windows.Forms.Padding]::new(3,4,5,0);$logTools.Controls.Add($logId)
    $copyEmulator=New-Object Windows.Forms.Button;$Ui.CopyEmulatorLog=$copyEmulator;$copyEmulator.Text='Copy emulator logs';$copyEmulator.AutoSize=$true;$logTools.Controls.Add($copyEmulator)
    $copyStatus=New-Object Windows.Forms.Label;$Ui.LogCopyStatus=$copyStatus;$copyStatus.AutoSize=$true;$copyStatus.Margin=[Windows.Forms.Padding]::new(8,7,0,0);$copyStatus.ForeColor=[Drawing.Color]::FromArgb(153,169,190);$logTools.Controls.Add($copyStatus)
    $log=New-Object Windows.Forms.RichTextBox;$Ui.Log=$log;$log.Dock='Fill';$log.ReadOnly=$true;$log.Font=[Drawing.Font]::new('Consolas',10);$log.BackColor=[Drawing.Color]::FromArgb(25,29,35);$log.ForeColor=[Drawing.Color]::Gainsboro;$log.BorderStyle='None';$logLayout.Controls.Add($log,0,1)
    $copyAll.Add_Click({try{Copy-LauncherUiLiveLog}catch{Set-LauncherUiProperty $Ui.LogCopyStatus Text $_.Exception.Message}})
    $copyEmulator.Add_Click({try{Start-LauncherUiEmulatorLogCopy}catch{Set-LauncherUiProperty $Ui.LogCopyStatus Text $_.Exception.Message}})
    $status=New-Object Windows.Forms.Label;$Ui.Status=$status;$status.Dock='Fill';$status.Padding=[Windows.Forms.Padding]::new(2,4,0,0);$layout.Controls.Add($status,0,3)
    $Ui.Start.Add_Click({try{Start-LauncherUiRun}catch{Add-LauncherUiLog ($_.Exception.Message+"`r`n");[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Could not start',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Warning)|Out-Null}})
    $Ui.Stop.Add_Click({try{Stop-LauncherUiRun;Update-LauncherUi}catch{[Windows.Forms.MessageBox]::Show('The stop request could not be sent. Try again.','Stop tool')|Out-Null}})
    $stopClose.Add_Click({try{Start-LauncherUiStopAndClose}catch{Add-LauncherUiLog ('Stop and close: '+$_.Exception.Message+"`r`n");[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Stop and close instances')|Out-Null}})
    $forceClose.Add_Click({try{Confirm-LauncherUiForceClose}catch{Add-LauncherUiLog ('Force close: '+$_.Exception.Message+"`r`n");[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Force close LDPlayer',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Warning)|Out-Null}})
    $Ui.Save.Add_Click({try{Save-LauncherUiSettings;Add-LauncherUiLog "Settings saved.`r`n"}catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Settings')|Out-Null}})
    $Ui.Reload.Add_Click({try{Read-LauncherUiSettings;Read-LauncherUiAccounts}catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Reload')|Out-Null}})
    $Ui.Reset.Add_Click({try{Confirm-LauncherUiReset}catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Reset emulators')|Out-Null}})
    $Ui.ApplyCookie.Add_Click({try{Save-LauncherUiCookie}catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Saved cookie')|Out-Null}})
    $Ui.ClearCookie.Add_Click({
        if([Windows.Forms.MessageBox]::Show('Clear only this saved file entry? The app cookie is unchanged and may be captured again at startup.','Clear saved value',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Question) -eq [Windows.Forms.DialogResult]::Yes){try{Save-LauncherUiCookie -Clear}catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Saved cookie')|Out-Null}}
    })
    $accounts.Add_SelectionChanged({if(-not $Ui.RefreshingAccounts){$Ui.CookieInput.Clear()}})
    $accounts.Add_CellDoubleClick({param($sender,$event) if($event.RowIndex -ge 0 -and $Ui.CookieInput.Enabled){$Ui.CookieInput.Focus()|Out-Null}})
    $actions.Add_SizeChanged({if($Ui.Form.IsHandleCreated -and -not $Ui.Form.IsDisposed){$null=$Ui.Form.BeginInvoke([Action]{Update-LauncherUiToolbarHeight})}})
    $form.Add_Shown({Update-LauncherUiInputSizes;Update-LauncherUiToolbarHeight});$form.Add_Resize({Update-LauncherUiInputSizes;Update-LauncherUiToolbarHeight})
    $form.Add_FormClosing({
        param($sender,$event)
        if($Ui.ForceClosePending -or $Ui.ForceCloseTask){$event.Cancel=$true;[Windows.Forms.MessageBox]::Show('Wait for the current instance-close operation to finish before closing the launcher.','Closing LDPlayer')|Out-Null;return}
        $busy=($Ui.Process -and -not $Ui.Process.HasExited) -or (Test-LauncherRunning $Ui.Directory)
        if($busy){
            $event.Cancel=$true
            if(-not $Ui.CloseWhenStopped -and [Windows.Forms.MessageBox]::Show($(if($Ui.Operation -eq 'Reset'){'Stop the reset after the current disk operation finishes, then close? An incomplete reset must be run again before Start tool.'}else{'Stop the tool before closing? Your emulators and apps will stay open.'}),'Close launcher',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Question) -eq [Windows.Forms.DialogResult]::Yes){$Ui.CloseWhenStopped=$true;Stop-LauncherUiRun}
        }
    })
    $timer=New-Object Windows.Forms.Timer;$Ui.Timer=$timer;$timer.Interval=1000
    $timer.Add_Tick({try{Update-LauncherUi}catch{Add-LauncherUiLog ('UI refresh: '+$_.Exception.Message+"`r`n")}})
    try {
        Set-LauncherUiDarkTheme $form
        Read-LauncherUiSettings;Read-LauncherUiAccounts;Update-LauncherUi;$timer.Start()
        $null=$form.ShowDialog()
    }finally{
        $timer.Stop();$timer.Dispose();$form.Dispose()
        if($Ui.LogReadTask){$Ui.LogReadTask.Worker.Stop();$Ui.LogReadTask.Worker.Dispose()}
        if($Ui.ArrangeTask){$Ui.ArrangeTask.Worker.Stop();$Ui.ArrangeTask.Worker.Dispose()}
        if($Ui.ForceCloseTask){$Ui.ForceCloseTask.Worker.Stop();$Ui.ForceCloseTask.Worker.Dispose()}
        if($Ui.LogArchiveWriter){$Ui.LogArchiveWriter.Dispose();[IO.File]::Delete($Ui.LogArchivePath)}
        if($Ui.OutputSink){$Ui.OutputSink.Dispose()};if($Ui.Process -and $Ui.Process.HasExited){$Ui.Process.Dispose()}
    }
}


if ($env:LAUNCHER_FLOW_MODE -notin @('worker','console','reset')) {
    try {Show-LauncherUi -LauncherPath $env:LAUNCHER_FLOW_FILE;exit 0}
    catch {
        $failure=$_
        $log=Write-LauncherUiStartupError $failure
        if($env:LAUNCHER_FLOW_HOST_DIAGNOSTICS -ne '1'){
            Add-Type -AssemblyName System.Windows.Forms
            $notice='UI could not open: '+$failure.Exception.Message
            if($log){$notice+="`r`n`r`nDetails saved to:`r`n"+$log}
            [Windows.Forms.MessageBox]::Show($notice,'launcher')|Out-Null
        }
        exit 1
    }
}
try {[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)}catch{}
$runDirectory = $null
$runMutex=$null; $runHeld=$false; $runPaths=$null
try {
    $configPath = Join-Path ([IO.Path]::GetDirectoryName($env:LAUNCHER_FLOW_FILE)) 'config.ini'
    $runPaths=Get-LauncherRunPaths ([IO.Path]::GetDirectoryName($configPath))
    $runMutex=New-Object Threading.Mutex $false,$runPaths.MutexName
    try {$runHeld=$runMutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$runHeld=$true}
    if(-not $runHeld){throw 'The tool is already running from this folder.'}
    $runId=[guid]::NewGuid().ToString('N')
    $runDirectory=Join-Path ([IO.Path]::GetTempPath()) "launcher-$runId"
    if($env:LAUNCHER_FLOW_RUN_DIRECTORY){
        $candidate=[IO.Path]::GetFullPath($env:LAUNCHER_FLOW_RUN_DIRECTORY)
        if(-not $candidate.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($candidate) -notmatch '^launcher-[0-9a-f]{32}$'){throw 'Invalid tool state directory.'}
        $runDirectory=$candidate
    }
    if(-not (Test-Path -LiteralPath $runDirectory)){$null=New-Item -ItemType Directory -Path $runDirectory}
    [IO.File]::WriteAllText($runPaths.RecordPath,(@{ProcessId=$PID;RunDirectory=$runDirectory}|ConvertTo-Json -Compress))
    if($env:LAUNCHER_FLOW_MODE -eq 'reset'){
        $Config=Get-LauncherResetSettings $configPath
        $Config.StopFilePath=Join-Path $runDirectory 'stop.request'
        Invoke-LauncherGeneralReset
        exit 0
    }
    Assert-LauncherResetNotPending ([IO.Path]::GetDirectoryName($configPath))
    $Config = Read-FlowConfig -Path $configPath
    $Config.StopFilePath=Join-Path $runDirectory 'stop.request'
    $Config.RestoreBackupPath=Resolve-LauncherRecoverySource -Settings $Config -Directory ([IO.Path]::GetDirectoryName($configPath)) -CheckClosed
    $launcher = [IO.File]::ReadAllText($env:LAUNCHER_FLOW_FILE)
    $marker = ':LAUNCHER_' + 'POWERSHELL'
    $source = $launcher.Substring($launcher.LastIndexOf($marker) + $marker.Length)
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors.Message -join '; ') }
    $functions = $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]}, $true)
    $definitions = $functions.Extent.Text -join "`n"
    Initialize-GameAppDataStore
    if(@(Get-ActiveRestoreInstanceIds).Count -gt 0){Write-Host 'Waiting for an existing instance replacement to finish before starting repairs or emulators...'}
    while(@(Get-ActiveRestoreInstanceIds).Count -gt 0 -and -not (Test-FlowStopRequested)){Start-Sleep -Seconds 1}
    if (-not (Test-FlowStopRequested)) {Invoke-StartupRepairPolicy}
    if (Test-FlowStopRequested) {Write-Host 'Tool stopped. Emulators and apps were left open.';exit 0}
    $results = @(Invoke-SelectedEmulators -Settings $Config -FunctionDefinitions $definitions -StateFile (Join-Path $runDirectory 'last-launch.txt') -MutexName "Local\Launcher-$runId")
    if (Test-FlowStopRequested) {Write-Host 'Tool stopped. Emulators and apps were left open.';exit 0}
    if ($results.Count -eq 0) { throw 'No emulator workers were started. Check ExcludedLdPlayerIds in config.ini. The launcher window will stay open so you can read this message.' }
    $failed = @($results | Where-Object { -not $_.Succeeded })
    foreach ($result in $results) {
        if ($result.Succeeded) {
            if ($result.Action -eq 'AlreadyInGame') { Write-Host "LDPlayer $($result.InstanceId): already in a game; server link skipped." }
            elseif ($result.Action -eq 'AlreadyJoining') { Write-Host "LDPlayer $($result.InstanceId): already joining a game; duplicate link skipped." }
            elseif ($result.Action -eq 'LinkOpened') { Write-Host "LDPlayer $($result.InstanceId): server link opened." }
            elseif ($result.Action -eq 'MonitorStopped') { Write-Host "LDPlayer $($result.InstanceId): game watcher stopped." }
            else { Write-Host "LDPlayer $($result.InstanceId): completed." }
        }
        else { Write-Host "LDPlayer $($result.InstanceId): $($result.Error)" -ForegroundColor Red }
    }
    Write-Host "Finished. Successful: $($results.Count - $failed.Count). Failed: $($failed.Count)."
    if ($failed.Count -gt 0) { exit 1 }
    exit 0
}
catch {
    Write-Host ('Stopped: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
finally {
    try {Clear-LauncherRunState -Directory $runDirectory}
    catch {Write-Host ('Temporary state cleanup was skipped: '+$_.Exception.Message)}
    finally {
        if($runHeld -and $runPaths){
            try{$record=ConvertFrom-Json ([IO.File]::ReadAllText($runPaths.RecordPath));if($record.ProcessId -eq $PID){Remove-Item -LiteralPath $runPaths.RecordPath -Force -Confirm:$false -ErrorAction SilentlyContinue}}catch{}
        }
        if($runHeld){$runMutex.ReleaseMutex()};if($runMutex){$runMutex.Dispose()}
    }
}
