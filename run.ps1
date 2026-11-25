
& {
    $Repository = 'championsDecay/l'
    $Branch = 'main'

    $ErrorActionPreference = 'Stop'
    if ($Repository -eq 'YOUR_USERNAME/YOUR_REPOSITORY') {
        throw 'Edit the Repository value at the top of run.ps1 to your GitHub username/repository first.'
    }
    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or -not $Branch) {
        throw 'Set Repository to username/repository and Branch to your GitHub branch name.'
    }
    $localRoot = [Environment]::GetFolderPath('LocalApplicationData')
    if ($env:LAUNCHER_DIRECTORY) {
        if (-not [IO.Path]::IsPathRooted($env:LAUNCHER_DIRECTORY)) { throw 'The starter folder must be an absolute path.' }
        $directory = [IO.Path]::GetFullPath($env:LAUNCHER_DIRECTORY)
    } else {
        $directory = Join-Path $localRoot ('DeltaJoiner\' + $Repository.Replace('/', '\'))
    }
    $baseUrl = 'https://raw.githubusercontent.com/' + $Repository + '/' + [Uri]::EscapeDataString($Branch)
    $null = [IO.Directory]::CreateDirectory($directory)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $digest = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($directory.ToLowerInvariant()))).Replace('-', '').Substring(0, 24) }
    finally { $hash.Dispose() }
    $mutex = [Threading.Mutex]::new($false, ('Local\DeltaJoinerDownload-' + $digest))
    $held = $false
    $stage = $null
    try {
        try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'This GitHub launcher is already running. Close its tool window before running it again.' }
        
        $runMutex = [Threading.Mutex]::new($false, ('Local\CodexJoinerRun-' + $digest))
        $runHeld = $false
        try {
            try { $runHeld = $runMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $runHeld = $true }
            if (-not $runHeld) { throw 'Stop and exit the tool before downloading an update.' }
            $stage = Join-Path $directory ('.download-' + [guid]::NewGuid().ToString('N'))
            $null = [IO.Directory]::CreateDirectory($stage)
            $launcher = Join-Path $directory 'launcher.cmd'
            $config = Join-Path $directory 'config.ini'
            $download = Join-Path $stage 'launcher.cmd'
            Write-Host 'Downloading the latest tool from GitHub...'
            $oldProtocol = [Net.ServicePointManager]::SecurityProtocol
            try {
                [Net.ServicePointManager]::SecurityProtocol = $oldProtocol -bor [Net.SecurityProtocolType]::Tls12
                $downloadQuery = '?launcher=' + [guid]::NewGuid().ToString('N')
                $downloadHeaders = @{'Cache-Control'='no-cache';'Pragma'='no-cache'}
                Invoke-WebRequest -UseBasicParsing -Uri ($baseUrl + '/launcher.cmd') -OutFile $download -TimeoutSec 60
                Invoke-WebRequest -UseBasicParsing -Uri ($baseUrl + '/launcher.cmd' + $downloadQuery) -Headers $downloadHeaders -OutFile $download -TimeoutSec 60
                
                if (-not [IO.File]::Exists($config)) {
                    Invoke-WebRequest -UseBasicParsing -Uri ($baseUrl + '/config.example.ini') -OutFile (Join-Path $stage 'config.ini') -TimeoutSec 60
                    Invoke-WebRequest -UseBasicParsing -Uri ($baseUrl + '/config.example.ini' + $downloadQuery) -Headers $downloadHeaders -OutFile (Join-Path $stage 'config.ini') -TimeoutSec 60
                }
            } finally { [Net.ServicePointManager]::SecurityProtocol = $oldProtocol }
            $content = [IO.File]::ReadAllText($download)
            $marker = ':LAUNCHER_POWERSHELL'
            $index = $content.LastIndexOf($marker, [StringComparison]::Ordinal)
            if (-not $content.StartsWith('@echo off') -or $index -lt 0) {
                throw 'GitHub did not return a valid tool CMD. Existing local files were kept.'
            }
            $tokens = $null; $parseErrors = $null
            $null = [Management.Automation.Language.Parser]::ParseInput($content.Substring($index + $marker.Length), [ref]$tokens, [ref]$parseErrors)
            if ($parseErrors.Count) { throw 'The downloaded tool contains PowerShell syntax errors. Existing local files were kept.' }
            if (-not [IO.File]::Exists($config)) {
                $example = Join-Path $stage 'config.ini'
                $configText = [IO.File]::ReadAllText($example)
                if ($configText -notmatch '(?m)^LdPlayerInstallPath=' -or $configText -notmatch '(?m)^GamePackages=') {
                    throw 'config.example.ini is missing the required settings. Existing local files were kept.'
                }
                [IO.File]::Move($example, $config)
            }
            if ([IO.File]::Exists($launcher)) {
                if ((Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash) {
                    [IO.File]::Replace($download, $launcher, (Join-Path $stage 'previous.cmd'))
                }
            } else { [IO.File]::Move($download, $launcher) }
        } finally {
            if ($runHeld) { $runMutex.ReleaseMutex() }
            $runMutex.Dispose()
        }
        
        $code = @'
$ErrorActionPreference='Stop'
try {
    $content=[IO.File]::ReadAllText($env:LAUNCHER_FLOW_FILE)
    $marker=':LAUNCHER_POWERSHELL'
    & ([scriptblock]::Create($content.Substring($content.LastIndexOf($marker)+$marker.Length)))
} catch {
    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.MessageBox]::Show($_.Exception.Message,'launcher could not start')|Out-Null
    exit 1
}
'@
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $info.Arguments = '-NoProfile -STA -NonInteractive -WindowStyle Hidden -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
        $info.WorkingDirectory = $directory
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.EnvironmentVariables['LAUNCHER_FLOW_FILE'] = $launcher
        $info.EnvironmentVariables['LAUNCHER_FLOW_MODE'] = 'ui'
        Write-Host ('Opening launcher. Settings and saved data stay in: ' + $directory)
        $process = [Diagnostics.Process]::new()
        try {
            $process.StartInfo = $info
            if (-not $process.Start()) { throw 'Windows could not start the tool.' }
            
            
            $process.WaitForExit()
            if ($process.ExitCode -ne 0) { throw 'The tool could not start or exited with an error.' }
        } finally { $process.Dispose() }
    } finally {
        if ($stage -and [IO.Directory]::Exists($stage)) {
            
            foreach ($name in @('launcher.cmd', 'config.ini', 'previous.cmd')) {
                $path = Join-Path $stage $name
                if ([IO.File]::Exists($path)) { [IO.File]::Delete($path) }
            }
            [IO.Directory]::Delete($stage, $false)
        }
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
