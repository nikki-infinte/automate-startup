<#
.SYNOPSIS
    Zero-boilerplate engine powering dev.bat (start | status | stop).
.DESCRIPTION
    - Spring Boot apps: auto-detects @SpringBootApplication main class, module name, port,
      and health URL; creates native IntelliJ Run/Debug config; opens IntelliJ IDEA
      automatically; triggers Debug mode (Shift+F9) so live logs & breakpoints appear
      directly inside IntelliJ; waits for positive health before starting the next app.
    - Frontend apps: auto-detects port & command (npm run dev / npm start) and launches
      in a visible terminal window after backend dependencies are healthy.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("start", "status", "stop")]
    [string]$Action = "start",

    [string]$ConfigPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$workspaceRoot = Split-Path -Parent $scriptDir
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $workspaceRoot "apps.json"
}

$runtimeTmpDir = Join-Path $env:TEMP "dev-runner"
$stateFile = Join-Path $workspaceRoot ".dev-state.json"
$pollIntervalMs = 1500
$debugRetryEverySec = 20

# --- Win32 Window Focus Helper (Built-in .NET, zero installs) -----------------

$win32Loaded = $false
function Initialize-WindowAutomation {
    if ($script:win32Loaded) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class DevWin32 {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    [DllImport("user32.dll")]
    public static extern uint MapVirtualKey(uint uCode, uint uMapType);

    public static string GetTitle(IntPtr hWnd) {
        int len = GetWindowTextLength(hWnd);
        if (len <= 0) return "";
        var sb = new StringBuilder(len + 1);
        GetWindowText(hWnd, sb, sb.Capacity);
        return sb.ToString();
    }

    // Finds the main IntelliJ window of a project (skips "Trust Project" style dialogs).
    public static IntPtr FindIntelliJWindow(string titleContains) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((hWnd, lParam) => {
            if (!IsWindowVisible(hWnd)) return true;
            string title = GetTitle(hWnd);
            if (string.IsNullOrEmpty(title)) return true;
            if (title.IndexOf(titleContains, StringComparison.OrdinalIgnoreCase) < 0) return true;
            if (title.IndexOf("Trust", StringComparison.OrdinalIgnoreCase) >= 0) return true;

            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            try {
                var p = Process.GetProcessById((int)pid);
                if (p.ProcessName.IndexOf("idea", StringComparison.OrdinalIgnoreCase) >= 0) {
                    found = hWnd;
                    return false;
                }
            } catch { }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static bool FocusWindow(IntPtr hWnd) {
        if (hWnd == IntPtr.Zero) return false;
        if (IsIconic(hWnd)) {
            ShowWindow(hWnd, 9); // SW_RESTORE
        } else {
            ShowWindow(hWnd, 5); // SW_SHOW
        }

        IntPtr fg = GetForegroundWindow();
        uint curThread = GetCurrentThreadId();
        uint fgThread = 0;
        uint targetThread = 0;
        if (fg != IntPtr.Zero) GetWindowThreadProcessId(fg, out fgThread);
        GetWindowThreadProcessId(hWnd, out targetThread);

        // Tap Alt (down+up) to satisfy the Windows foreground activation policy
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(0x12, 0, 2, UIntPtr.Zero);

        bool attachedFg = false;
        bool attachedTarget = false;
        try {
            if (fgThread != 0 && fgThread != curThread) {
                attachedFg = AttachThreadInput(curThread, fgThread, true);
            }
            if (targetThread != 0 && targetThread != curThread) {
                attachedTarget = AttachThreadInput(curThread, targetThread, true);
            }
            BringWindowToTop(hWnd);
            SetForegroundWindow(hWnd);
        } finally {
            if (attachedTarget) AttachThreadInput(curThread, targetThread, false);
            if (attachedFg) AttachThreadInput(curThread, fgThread, false);
        }
        return GetForegroundWindow() == hWnd;
    }

    public static void SendKey(byte vk) {
        // Hardware-style key press (Java/Swing ignores WinForms SendKeys for F-keys).
        byte scan = (byte)MapVirtualKey(vk, 0);
        keybd_event(vk, scan, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(80);
        keybd_event(vk, scan, 2, UIntPtr.Zero);
    }

    public static void SendEscape() { SendKey(0x1B); }

    // F5 = Debug in this IntelliJ keymap (Shift+F9 only opens the "Debug..." chooser popup).
    public static void SendDebugKey() { SendKey(0x74); }
}
"@
    $script:win32Loaded = $true
}

# --- General Helpers ----------------------------------------------------------

function Get-OptionalProp {
    param($Obj, [string]$PropName, $DefaultValue = $null)
    if ($null -eq $Obj -or ($Obj -is [string])) { return $DefaultValue }
    $prop = $Obj.PSObject.Properties[$PropName]
    if ($null -eq $prop) { return $DefaultValue }
    return $prop.Value
}

function Resolve-AppDir {
    param([string]$BaseDir, [string]$RawPath)
    if ([System.IO.Path]::IsPathRooted($RawPath)) {
        return [System.IO.Path]::GetFullPath($RawPath)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $BaseDir $RawPath))
}

function Test-TcpPort {
    param([int]$TargetPort, [string]$TargetHost = "127.0.0.1", [int]$TimeoutMs = 600)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($TargetHost, $TargetPort, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($iar)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

function Test-HttpHealth {
    param([string]$Url, [int]$TimeoutSec = 2)
    try {
        $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -Method Get -TimeoutSec $TimeoutSec -ErrorAction Stop
        $code = [int]$resp.StatusCode
        return @{ Ok = ($code -ge 200 -and $code -lt 400); Detail = "HTTP $code" }
    }
    catch {
        return @{ Ok = $false; Detail = $_.Exception.Message }
    }
}

function Test-PidAlive {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $false }
    try {
        $null = Get-Process -Id $ProcessId -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Get-ListeningPidByPort {
    param([int]$TargetPort)
    try {
        $conn = @(Get-NetTCPConnection -LocalPort $TargetPort -State Listen -ErrorAction Stop | Select-Object -First 1)
        if ($conn.Count -gt 0 -and $conn[0].OwningProcess -gt 0) {
            return [int]$conn[0].OwningProcess
        }
    }
    catch {
        # Fallback to netstat if Get-NetTCPConnection is unavailable
    }

    try {
        $lines = @(& netstat -ano -p TCP 2>$null)
        foreach ($line in $lines) {
            if ($line -match "^\s*TCP\s+\S+:$TargetPort\s+\S+\s+LISTENING\s+(\d+)\s*$") {
                return [int]$Matches[1]
            }
        }
    }
    catch { }
    return $null
}

function Stop-ProcessTree {
    param([int]$ProcessId)
    if (-not (Test-PidAlive -ProcessId $ProcessId)) { return $false }
    $null = & taskkill /PID $ProcessId /T /F 2>&1
    return ($LASTEXITCODE -eq 0)
}

# True once IntelliJ has actually launched the app JVM in DEBUG mode
# (IntelliJ's debug JVMs always carry -agentlib:jdwp in their command line).
function Test-SpringDebugJvmRunning {
    param($App)
    try {
        $procs = @(Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction Stop)
        foreach ($p in $procs) {
            $cl = [string](Get-OptionalProp $p "CommandLine" "")
            if (-not $cl) { continue }
            if ($cl -notmatch 'jdwp') { continue }
            if ($App.main_class -and $cl.Contains($App.main_class)) { return $true }
            if ($cl.Contains("--server.port=$($App.port)")) { return $true }
        }
    }
    catch { }
    return $false
}

# --- Auto-Discovery (Abstracts Away Internal Project Details) -----------------

function Detect-AppType {
    param([string]$AppDir, [string]$ExplicitCmd)
    if ($ExplicitCmd -match '\bmvn(w)?\b|spring-boot') { return "spring-boot" }
    if ($ExplicitCmd -match '\b(npm|yarn|pnpm|vite|next|ng)\b') { return "frontend" }
    if (Test-Path -LiteralPath (Join-Path $AppDir "pom.xml")) { return "spring-boot" }
    if (Test-Path -LiteralPath (Join-Path $AppDir "package.json")) { return "frontend" }
    return "custom"
}

function Detect-SpringPort {
    param([string]$AppDir)
    $propsFile = Join-Path $AppDir "src\main\resources\application.properties"
    if (Test-Path -LiteralPath $propsFile) {
        $content = Get-Content -LiteralPath $propsFile -Raw -ErrorAction SilentlyContinue
        if ($content -match '(?m)^\s*server\.port\s*=\s*(\d+)') {
            return [int]$Matches[1]
        }
    }
    foreach ($ymlName in @("application.yml", "application.yaml")) {
        $ymlFile = Join-Path $AppDir "src\main\resources\$ymlName"
        if (Test-Path -LiteralPath $ymlFile) {
            $content = Get-Content -LiteralPath $ymlFile -Raw -ErrorAction SilentlyContinue
            if ($content -match '(?m)^\s*port\s*:\s*(\d+)') {
                return [int]$Matches[1]
            }
        }
    }
    return 8080
}

function Detect-SpringMainClass {
    param([string]$AppDir)
    $srcJava = Join-Path $AppDir "src\main\java"
    if (-not (Test-Path -LiteralPath $srcJava)) { return $null }
    $javaFiles = @(Get-ChildItem -Path $srcJava -Filter "*.java" -Recurse -ErrorAction SilentlyContinue)
    foreach ($jf in $javaFiles) {
        $txt = Get-Content -LiteralPath $jf.FullName -Raw -ErrorAction SilentlyContinue
        if ($txt -match '@SpringBootApplication') {
            $pkg = ""
            if ($txt -match '(?m)^\s*package\s+([\w\.]+)\s*;') {
                $pkg = $Matches[1]
            }
            $cls = [System.IO.Path]::GetFileNameWithoutExtension($jf.Name)
            if ($txt -match 'public\s+class\s+(\w+)') {
                $cls = $Matches[1]
            }
            if ($pkg) { return "$pkg.$cls" }
            return $cls
        }
    }
    return $null
}

function Detect-MavenArtifactId {
    param([string]$AppDir)
    $pomFile = Join-Path $AppDir "pom.xml"
    if (-not (Test-Path -LiteralPath $pomFile)) { return (Split-Path -Leaf $AppDir) }
    try {
        [xml]$pom = Get-Content -LiteralPath $pomFile -Raw -Encoding UTF8
        if ($pom.project.artifactId) {
            return [string]$pom.project.artifactId
        }
    }
    catch { }
    return (Split-Path -Leaf $AppDir)
}

function Detect-SpringHealthUrl {
    param([string]$AppDir, [int]$Port)
    $pomFile = Join-Path $AppDir "pom.xml"
    if (Test-Path -LiteralPath $pomFile) {
        $pomText = Get-Content -LiteralPath $pomFile -Raw -ErrorAction SilentlyContinue
        if ($pomText -match 'spring-boot-starter-actuator') {
            return "http://127.0.0.1:$Port/actuator/health"
        }
    }

    $srcJava = Join-Path $AppDir "src\main\java"
    if (Test-Path -LiteralPath $srcJava) {
        $javaFiles = @(Get-ChildItem -Path $srcJava -Filter "*.java" -Recurse -ErrorAction SilentlyContinue)
        foreach ($jf in $javaFiles) {
            $txt = Get-Content -LiteralPath $jf.FullName -Raw -ErrorAction SilentlyContinue
            if ($txt -match '@GetMapping\(\s*"/api/health"\s*\)') {
                return "http://127.0.0.1:$Port/api/health"
            }
            if ($txt -match '@RequestMapping\(\s*"/api"\s*\)' -and $txt -match '@GetMapping\(\s*"/health"\s*\)') {
                return "http://127.0.0.1:$Port/api/health"
            }
            if ($txt -match '@GetMapping\(\s*"/health"\s*\)') {
                return "http://127.0.0.1:$Port/health"
            }
        }
    }
    return $null
}

function Detect-FrontendDetails {
    param([string]$AppDir)
    $defaultCmd = "npm run dev"
    $defaultPort = 5173
    $pkgFile = Join-Path $AppDir "package.json"

    if (Test-Path -LiteralPath $pkgFile) {
        try {
            $pkg = Get-Content -LiteralPath $pkgFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $scripts = Get-OptionalProp $pkg "scripts" $null
            $devScript = [string](Get-OptionalProp $scripts "dev" "")
            $startScript = [string](Get-OptionalProp $scripts "start" "")

            if ($devScript) {
                $defaultCmd = "npm run dev"
                $activeScript = $devScript
            }
            elseif ($startScript) {
                $defaultCmd = "npm start"
                $activeScript = $startScript
            }
            else {
                $activeScript = ""
            }

            if ($activeScript -match '(?:--port|-p)\s+(\d+)') {
                $defaultPort = [int]$Matches[1]
            }
            elseif ($activeScript -match '\bvite\b') { $defaultPort = 5173 }
            elseif ($activeScript -match '\bng\s+serve\b') { $defaultPort = 4200 }
            elseif ($activeScript -match '\b(next|react-scripts)\b') { $defaultPort = 3000 }
        }
        catch { }
    }
    return @{ Command = $defaultCmd; Port = $defaultPort }
}

function Load-Apps {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path"
    }
    $fullConfigPath = (Resolve-Path -LiteralPath $Path).Path
    $baseDir = Split-Path -Parent $fullConfigPath
    $raw = Get-Content -LiteralPath $fullConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $items = @()
    if ($raw -is [System.Array]) { $items = @($raw) }
    elseif ($null -ne (Get-OptionalProp $raw "apps" $null)) { $items = @($raw.apps) }
    else { $items = @($raw) }

    $resolved = New-Object System.Collections.ArrayList
    $usedNames = @{}

    foreach ($entry in $items) {
        if ($null -eq $entry) { continue }
        $enabledProp = Get-OptionalProp $entry "enabled" $true
        if (-not [bool]$enabledProp) { continue }

        $rawPath = if ($entry -is [string]) { $entry } else { [string](Get-OptionalProp $entry "path" "") }
        if (-not $rawPath) { throw "Every entry in apps.json must include a 'path'." }

        $appDir = Resolve-AppDir -BaseDir $baseDir -RawPath $rawPath
        $explicitCmd = [string](Get-OptionalProp $entry "command" "")
        $appType = [string](Get-OptionalProp $entry "type" "")
        if (-not $appType) { $appType = Detect-AppType -AppDir $appDir -ExplicitCmd $explicitCmd }

        $baseName = [string](Get-OptionalProp $entry "name" "")
        if (-not $baseName) { $baseName = Split-Path -Leaf $appDir }
        $finalName = $baseName
        $suffix = 2
        while ($usedNames.ContainsKey($finalName)) {
            $finalName = "$baseName-$suffix"
            $suffix++
        }
        $usedNames[$finalName] = $true

        $explicitPort = Get-OptionalProp $entry "port" $null
        if ($appType -eq "spring-boot") {
            $cmd = if ($explicitCmd) { $explicitCmd } else { "mvn spring-boot:run" }
            $port = if ($null -ne $explicitPort) { [int]$explicitPort } else { Detect-SpringPort -AppDir $appDir }
            $healthUrl = Get-OptionalProp $entry "health_url" $null
            if (-not $healthUrl) { $healthUrl = Detect-SpringHealthUrl -AppDir $appDir -Port $port }
            $mainClass = Detect-SpringMainClass -AppDir $appDir
            $moduleName = Detect-MavenArtifactId -AppDir $appDir
            # First open of a project in IntelliJ includes Maven import + indexing: allow time.
            $timeoutSec = [int](Get-OptionalProp $entry "timeout" 300)
        }
        elseif ($appType -eq "frontend") {
            $fe = Detect-FrontendDetails -AppDir $appDir
            $cmd = if ($explicitCmd) { $explicitCmd } else { $fe.Command }
            $port = if ($null -ne $explicitPort) { [int]$explicitPort } else { $fe.Port }
            $healthUrl = Get-OptionalProp $entry "health_url" $null
            $mainClass = $null
            $moduleName = $null
            $timeoutSec = [int](Get-OptionalProp $entry "timeout" 60)
        }
        else {
            $cmd = $explicitCmd
            if (-not $cmd) { throw "Could not auto-detect command for '$finalName'. Add 'command' in apps.json." }
            $port = if ($null -ne $explicitPort) { [int]$explicitPort } else { throw "Please specify 'port' for '$finalName'." }
            $healthUrl = Get-OptionalProp $entry "health_url" $null
            $mainClass = $null
            $moduleName = $null
            $timeoutSec = [int](Get-OptionalProp $entry "timeout" 60)
        }

        [void]$resolved.Add([PSCustomObject]@{
            name        = $finalName
            type        = $appType
            path        = $appDir
            port        = $port
            command     = $cmd
            health_url  = $healthUrl
            main_class  = $mainClass
            module_name = $moduleName
            timeout_sec = $timeoutSec
        })
    }

    return @($resolved.ToArray())
}

# --- Executable Discovery (IntelliJ IDEA & npm) -------------------------------

function Resolve-IntelliJExecutable {
    if ($env:INTELLIJ_EXE -and (Test-Path -LiteralPath $env:INTELLIJ_EXE)) {
        return $env:INTELLIJ_EXE
    }

    foreach ($cmdName in @("idea64.exe", "idea.cmd", "idea")) {
        $found = Get-Command $cmdName -ErrorAction SilentlyContinue
        if ($null -ne $found) { return $found.Source }
    }

    $toolboxScript = Join-Path $env:LOCALAPPDATA "JetBrains\Toolbox\scripts\idea.cmd"
    if (Test-Path -LiteralPath $toolboxScript) { return $toolboxScript }

    $ideaInstallDirs = New-Object System.Collections.ArrayList
    $roots = @(
        "C:\Program Files\JetBrains",
        "C:\Program Files (x86)\JetBrains",
        (Join-Path $env:LOCALAPPDATA "Programs"),
        (Join-Path $env:LOCALAPPDATA "JetBrains\Toolbox\apps")
    )
    foreach ($root in $roots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        $direct = @(Get-ChildItem -Path $root -Directory -Filter "IntelliJ*" -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
        foreach ($d in $direct) { [void]$ideaInstallDirs.Add($d.FullName) }

        $toolbox = @(Get-ChildItem -Path $root -Directory -Filter "IDEA*" -ErrorAction SilentlyContinue)
        foreach ($tb in $toolbox) {
            $exe = @(Get-ChildItem -Path $tb.FullName -Filter "idea64.exe" -Recurse -Depth 5 -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1)
            if ($exe.Count -gt 0) { return $exe[0].FullName }
        }
    }

    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($rp in $regPaths) {
        $entries = @(Get-ItemProperty -Path $rp -ErrorAction SilentlyContinue | Where-Object {
            (Get-OptionalProp $_ "DisplayName" "") -like "*IntelliJ*"
        })
        foreach ($e in $entries) {
            $loc = Get-OptionalProp $e "InstallLocation" ""
            if ($loc -and (Test-Path -LiteralPath $loc)) { [void]$ideaInstallDirs.Add($loc) }
        }
    }

    foreach ($dir in $ideaInstallDirs) {
        $candidate = Join-Path $dir "bin\idea64.exe"
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    return $null
}

function Resolve-NpmExecutable {
    $onPath = Get-Command "npm" -ErrorAction SilentlyContinue
    if ($null -ne $onPath) { return $onPath.Source }

    $candidates = @(
        "C:\Program Files\nodejs\npm.cmd",
        (Join-Path $env:LOCALAPPDATA "Programs\nodejs\npm.cmd"),
        (Join-Path $env:APPDATA "npm\npm.cmd")
    )
    if ($env:NVM_SYMLINK) {
        $candidates = @((Join-Path $env:NVM_SYMLINK "npm.cmd")) + $candidates
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Resolve-JdkHome {
    if ($env:JAVA_HOME -and (Test-Path -LiteralPath (Join-Path $env:JAVA_HOME "bin\java.exe"))) {
        return $env:JAVA_HOME
    }
    $javaCmd = Get-Command "java" -ErrorAction SilentlyContinue
    if ($null -ne $javaCmd) {
        $binDir = Split-Path -Parent $javaCmd.Source
        $jdkHome = Split-Path -Parent $binDir
        if (Test-Path -LiteralPath (Join-Path $jdkHome "bin\java.exe")) {
            return $jdkHome
        }
    }
    return $null
}

# --- Native IntelliJ Run/Debug Configuration Sync -----------------------------

function Sync-IntelliJAppRunConfig {
    param($App)
    $runDir = Join-Path $App.path ".idea\runConfigurations"
    if (-not (Test-Path -LiteralPath $runDir)) {
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    }

    # Remove stale Remote_Debug_* configs so our native Application config is selected automatically
    Get-ChildItem -Path $runDir -Filter "Remote_Debug_*.xml" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

    $safeName = $App.name -replace '[^a-zA-Z0-9]', '_'
    $outFile = Join-Path $runDir "$safeName.xml"

    $jdkHome = Resolve-JdkHome
    $altJreXml = ""
    if ($jdkHome) {
        $jdkForward = $jdkHome -replace '\\', '/'
        $altJreXml = "    <option name=`"ALTERNATIVE_JRE_PATH`" value=`"$jdkForward`" />`r`n    <option name=`"ALTERNATIVE_JRE_PATH_ENABLED`" value=`"true`" />`r`n"
    }

    if ($App.main_class) {
        $xml = @"
<component name="ProjectRunConfigurationManager">
  <configuration default="false" name="$($App.name)" type="Application" factoryName="Application">
$altJreXml    <option name="MAIN_CLASS_NAME" value="$($App.main_class)" />
    <module name="$($App.module_name)" />
    <option name="PROGRAM_ARGUMENTS" value="--server.port=$($App.port)" />
    <method v="2">
      <option name="Make" enabled="true" />
    </method>
  </configuration>
</component>
"@
    }
    else {
        $xml = @"
<component name="ProjectRunConfigurationManager">
  <configuration default="false" name="$($App.name)" type="MavenRunConfiguration" factoryName="Maven">
    <MavenSettings>
      <option name="myGeneralSettings" />
      <option name="myRunnerSettings" />
      <option name="myRunnerParameters">
        <MavenRunnerParameters>
          <option name="workingDirPath" value="`$PROJECT_DIR`$" />
          <option name="goals">
            <list>
              <option value="spring-boot:run" />
              <option value="-Dspring-boot.run.arguments=--server.port=$($App.port)" />
            </list>
          </option>
        </MavenRunnerParameters>
      </option>
    </MavenSettings>
    <method v="2" />
  </configuration>
</component>
"@
    }

    $xml | Set-Content -LiteralPath $outFile -Encoding UTF8

    # Ensure .idea/misc.xml has ProjectRootManager JDK set so new projects don't show a red X
    $miscFile = Join-Path $App.path ".idea\misc.xml"
    $jdkVer = "21"
    if ($jdkHome -and ($jdkHome -match 'jdk-(\d+)')) { $jdkVer = $Matches[1] }
    if (Test-Path -LiteralPath $miscFile) {
        $miscContent = Get-Content -LiteralPath $miscFile -Raw -Encoding UTF8
        if ($miscContent -notmatch 'ProjectRootManager') {
            $sdkLine = "  <component name=`"ProjectRootManager`" version=`"2`" languageLevel=`"JDK_$jdkVer`" project-jdk-name=`"$jdkVer`" project-jdk-type=`"JavaSDK`" />`r`n</project>"
            $miscContent = $miscContent -replace '</project>\s*$', $sdkLine
            Set-Content -LiteralPath $miscFile -Value $miscContent -Encoding UTF8
        }
    }
    else {
        $newMisc = @"
<?xml version="1.0" encoding="UTF-8"?>
<project version="4">
  <component name="ExternalStorageConfigurationManager" enabled="true" />
  <component name="MavenProjectsManager">
    <option name="originalFiles">
      <list>
        <option value="`$PROJECT_DIR`$/pom.xml" />
      </list>
    </option>
  </component>
  <component name="ProjectRootManager" version="2" languageLevel="JDK_$jdkVer" project-jdk-name="$jdkVer" project-jdk-type="JavaSDK" />
</project>
"@
        Set-Content -LiteralPath $miscFile -Value $newMisc -Encoding UTF8
    }
}

# --- State Persistence --------------------------------------------------------

function Read-State {
    if (-not (Test-Path -LiteralPath $stateFile)) { return @{} }
    try {
        $raw = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $map = @{}
        foreach ($prop in $raw.PSObject.Properties) { $map[$prop.Name] = $prop.Value }
        return $map
    }
    catch { return @{} }
}

function Write-State {
    param([hashtable]$Map)
    $Map | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $stateFile -Encoding UTF8
}

# --- Start Spring Boot Inside IntelliJ IDEA (Debug Mode) ----------------------

function Start-SpringInIntelliJ {
    param($App, [string]$IdeaExe, [hashtable]$StateMap)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    if (Test-TcpPort -TargetPort $App.port) {
        Write-Host "[UP]    $($App.name) is already running on port $($App.port)." -ForegroundColor Yellow
        return $true
    }

    if (-not (Test-Path -LiteralPath $App.path)) {
        Write-Host "[FAIL]  $($App.name): Folder not found -> $($App.path)" -ForegroundColor Red
        return $false
    }

    # 1. Create native IntelliJ Run/Debug config inside the project
    Sync-IntelliJAppRunConfig -App $App

    # 2. Launch IntelliJ IDEA with this Spring Boot project
    Write-Host "[IDEA]  Opening $($App.name) in IntelliJ IDEA (Debug mode, port $($App.port))..." -ForegroundColor Cyan
    Start-Process -FilePath $IdeaExe -ArgumentList "`"$($App.path)`"" | Out-Null

    # 3. Wait for the IntelliJ project window
    Initialize-WindowAutomation
    $folderLeaf = Split-Path -Leaf $App.path
    $windowDeadline = [DateTime]::UtcNow.AddSeconds(120)
    $hwnd = [IntPtr]::Zero
    $trustHintShown = $false

    while ([DateTime]::UtcNow -lt $windowDeadline) {
        $hwnd = [DevWin32]::FindIntelliJWindow($folderLeaf)
        if ($hwnd -ne [IntPtr]::Zero) { break }
        if (-not $trustHintShown -and ([DateTime]::UtcNow -gt $windowDeadline.AddSeconds(-105))) {
            Write-Host "        Waiting for the IntelliJ window. If a 'Trust Project' dialog is showing, click 'Trust Project'." -ForegroundColor DarkYellow
            $trustHintShown = $true
        }
        Start-Sleep -Seconds 1
    }

    if ($hwnd -eq [IntPtr]::Zero) {
        Write-Host "[FAIL]  Timed out waiting for IntelliJ window '$folderLeaf' to open." -ForegroundColor Red
        return $false
    }

    Write-Host "        IntelliJ window is open. Letting it load the project (Maven import / indexing)..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 8

    # 4. Keep triggering Debug (Shift+F9) until IntelliJ really launches the debug JVM,
    #    then stop pressing (a second press would show a "Stop and rerun?" dialog)
    #    and just wait for the app to become healthy.
    $deadline = [DateTime]::UtcNow.AddSeconds($App.timeout_sec)
    $nextPressAt = [DateTime]::UtcNow
    $debugLaunched = $false
    $pressCount = 0
    $ready = $false
    $lastNote = "waiting for port $($App.port)"

    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-TcpPort -TargetPort $App.port) {
            if ($App.health_url) {
                $h = Test-HttpHealth -Url $App.health_url
                $lastNote = "$($App.health_url) -> $($h.Detail)"
                if ($h.Ok) { $ready = $true; break }
            }
            else {
                $ready = $true
                break
            }
        }

        if (-not $debugLaunched) {
            if (Test-SpringDebugJvmRunning -App $App) {
                $debugLaunched = $true
                Write-Host "        Debug session started inside IntelliJ. Waiting for $($App.name) to finish starting..." -ForegroundColor DarkGray
            }
            elseif ([DateTime]::UtcNow -ge $nextPressAt) {
                $hwndNow = [DevWin32]::FindIntelliJWindow($folderLeaf)
                if ($hwndNow -ne [IntPtr]::Zero) {
                    $focused = [DevWin32]::FocusWindow($hwndNow)
                    Start-Sleep -Milliseconds 500
                    [DevWin32]::SendEscape()          # close any popup left open
                    Start-Sleep -Milliseconds 300
                    [DevWin32]::SendDebugKey()        # F5 = Debug
                    $pressCount++
                    Write-Host "        Sent F5 (attempt $pressCount, window focused=$focused). Waiting for the debug session to start..." -ForegroundColor DarkGray
                    if ($pressCount -ge 3) {
                        Write-Host "        Still not started: IntelliJ may still be importing Maven / indexing, or the run config shows an error. I will keep retrying." -ForegroundColor DarkYellow
                    }
                }
                $nextPressAt = [DateTime]::UtcNow.AddSeconds($debugRetryEverySec)
            }
        }

        Start-Sleep -Milliseconds $pollIntervalMs
    }

    $sw.Stop()
    if (-not $ready) {
        Write-Host "[FAIL]  $($App.name) did not become healthy within $($App.timeout_sec)s ($lastNote)." -ForegroundColor Red
        Write-Host "        Check IntelliJ's Debug console for $($App.name)." -ForegroundColor DarkYellow
        return $false
    }

    $listenPid = Get-ListeningPidByPort -TargetPort $App.port
    $StateMap[$App.name] = [PSCustomObject]@{
        pid  = $listenPid
        port = $App.port
        mode = "intellij"
    }
    Write-State -Map $StateMap

    $secs = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
    Write-Host "[OK]    $($App.name) is running in IntelliJ Debug mode (${secs}s, http://localhost:$($App.port))" -ForegroundColor Green
    return $true
}

# --- Start Frontend / Custom App in Visible Terminal --------------------------

function Start-TerminalApp {
    param($App, [hashtable]$StateMap)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    if (Test-TcpPort -TargetPort $App.port) {
        Write-Host "[UP]    $($App.name) is already running on port $($App.port)." -ForegroundColor Yellow
        return $true
    }

    if (-not (Test-Path -LiteralPath $App.path)) {
        Write-Host "[FAIL]  $($App.name): Folder not found -> $($App.path)" -ForegroundColor Red
        return $false
    }

    $effectiveCmd = $App.command.Trim()
    if ($App.type -eq "frontend" -and $effectiveCmd -match '^npm(\s|$)') {
        $npmPath = Resolve-NpmExecutable
        if ($npmPath) {
            $effectiveCmd = $effectiveCmd -replace '^npm', "`"$npmPath`""
        }
        else {
            Write-Host "[FAIL]  $($App.name): 'npm' not found in PATH." -ForegroundColor Red
            return $false
        }
    }

    if (-not (Test-Path -LiteralPath $runtimeTmpDir)) {
        New-Item -ItemType Directory -Path $runtimeTmpDir -Force | Out-Null
    }
    $safeName = $App.name -replace '[^a-zA-Z0-9_-]', '_'
    $runnerCmd = Join-Path $runtimeTmpDir "_run_$safeName.cmd"
    $doneFile = Join-Path $runtimeTmpDir "_done_$safeName.txt"
    if (Test-Path -LiteralPath $doneFile) { Remove-Item -LiteralPath $doneFile -Force -ErrorAction SilentlyContinue }

    Write-Host "[START] $($App.name) [$($App.type)] port:$($App.port) (opening terminal)..." -ForegroundColor Cyan

    $wrapperLines = @(
        "@echo off",
        "title $($App.name) ^| http://localhost:$($App.port)",
        "set PORT=$($App.port)",
        "echo ============================================================",
        "echo   $($App.name) starting on http://localhost:$($App.port)",
        "echo   Dir: $($App.path)",
        "echo ============================================================",
        "call $effectiveCmd",
        "set APP_EXIT=%errorlevel%",
        "echo %APP_EXIT%> `"$doneFile`"",
        "echo.",
        "echo [EXITED] $($App.name) stopped with exit code %APP_EXIT%.",
        "pause"
    )
    Set-Content -LiteralPath $runnerCmd -Value $wrapperLines -Encoding ASCII

    $proc = Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c", "`"$runnerCmd`"" `
        -WorkingDirectory $App.path `
        -PassThru

    $deadline = [DateTime]::UtcNow.AddSeconds($App.timeout_sec)
    $ready = $false

    while ([DateTime]::UtcNow -lt $deadline) {
        if ($proc.HasExited -or (Test-Path -LiteralPath $doneFile)) {
            Write-Host "[FAIL]  $($App.name) crashed during startup. Check its terminal window." -ForegroundColor Red
            return $false
        }
        if (Test-TcpPort -TargetPort $App.port) {
            if ($App.health_url) {
                $h = Test-HttpHealth -Url $App.health_url
                if ($h.Ok) { $ready = $true; break }
            }
            else {
                $ready = $true
                break
            }
        }
        Start-Sleep -Milliseconds $pollIntervalMs
    }

    $sw.Stop()
    if (-not $ready) {
        $null = Stop-ProcessTree -ProcessId $proc.Id
        Write-Host "[FAIL]  $($App.name) timed out after $($App.timeout_sec)s." -ForegroundColor Red
        return $false
    }

    $StateMap[$App.name] = [PSCustomObject]@{
        pid  = $proc.Id
        port = $App.port
        mode = "terminal"
    }
    Write-State -Map $StateMap

    $secs = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
    Write-Host "[OK]    $($App.name) is running in ${secs}s (http://localhost:$($App.port))" -ForegroundColor Green
    return $true
}

# --- Status Table -------------------------------------------------------------

function Show-StatusTable {
    param([array]$Apps)
    Write-Host ""
    Write-Host ("{0,-20} {1,-12} {2,-10} {3,-8} {4,-7} {5}" -f "APP", "TYPE", "RUNNER", "STATE", "PORT", "HEALTH") -ForegroundColor Cyan
    Write-Host ("-" * 78)
    foreach ($a in $Apps) {
        $runner = if ($a.type -eq "spring-boot") { "IntelliJ" } else { "Terminal" }
        $portUp = Test-TcpPort -TargetPort $a.port
        $state = if ($portUp) { "UP" } else { "DOWN" }
        $health = "-"
        if ($portUp) {
            if ($a.health_url) {
                $h = Test-HttpHealth -Url $a.health_url
                $health = if ($h.Ok) { "OK ($($h.Detail))" } else { "UNHEALTHY" }
            }
            else {
                $health = "LISTENING"
            }
        }
        $color = if ($state -eq "UP") { "Green" } else { "Yellow" }
        Write-Host ("{0,-20} {1,-12} {2,-10} {3,-8} {4,-7} {5}" -f $a.name, $a.type, $runner, $state, $a.port, $health) -ForegroundColor $color
    }
    Write-Host ""
}

# --- Main ---------------------------------------------------------------------

$apps = @(Load-Apps -Path $ConfigPath)

switch ($Action) {
    "start" {
        if ($apps.Count -eq 0) {
            Write-Host "No apps found in $ConfigPath." -ForegroundColor Yellow
            exit 0
        }

        $hasSpring = @($apps | Where-Object { $_.type -eq "spring-boot" }).Count -gt 0
        $ideaExe = $null
        if ($hasSpring) {
            $ideaExe = Resolve-IntelliJExecutable
            if (-not $ideaExe) {
                Write-Host "[FAIL]  IntelliJ IDEA (idea64.exe) was not found automatically." -ForegroundColor Red
                Write-Host "        Set INTELLIJ_EXE to your idea64.exe path, e.g.:" -ForegroundColor Yellow
                Write-Host '        $env:INTELLIJ_EXE = "C:\Program Files\JetBrains\IntelliJ IDEA ...\bin\idea64.exe"' -ForegroundColor Yellow
                exit 1
            }
            Write-Host "Using IntelliJ IDEA: $ideaExe" -ForegroundColor DarkGray
        }

        $chain = ($apps | ForEach-Object { $_.name }) -join " -> "
        Write-Host "Starting chain: $chain" -ForegroundColor Cyan
        Write-Host ("-" * 65)

        $stateMap = Read-State
        $allOk = $true
        for ($i = 0; $i -lt $apps.Count; $i++) {
            $app = $apps[$i]
            if ($app.type -eq "spring-boot") {
                $ok = Start-SpringInIntelliJ -App $app -IdeaExe $ideaExe -StateMap $stateMap
            }
            else {
                $ok = Start-TerminalApp -App $app -StateMap $stateMap
            }

            if (-not $ok) {
                $allOk = $false
                for ($j = $i + 1; $j -lt $apps.Count; $j++) {
                    Write-Host "[SKIP]  $($apps[$j].name) skipped (upstream '$($app.name)' failed)." -ForegroundColor DarkYellow
                }
                break
            }
        }

        Show-StatusTable -Apps $apps
        if (-not $allOk) { exit 1 }
    }

    "status" {
        Show-StatusTable -Apps $apps
    }

    "stop" {
        $stateMap = Read-State
        $stoppedAny = $false
        $revApps = @($apps)
        if ($revApps.Count -gt 1) { [Array]::Reverse($revApps) }

        foreach ($a in $revApps) {
            $killed = $false
            # Prefer killing the tracked terminal PID (closes terminal + child) for terminal apps
            if ($stateMap.ContainsKey($a.name)) {
                $info = $stateMap[$a.name]
                $trackedPid = Get-OptionalProp $info "pid" $null
                if ($null -ne $trackedPid -and [int]$trackedPid -gt 0) {
                    $killed = Stop-ProcessTree -ProcessId ([int]$trackedPid)
                }
                $stateMap.Remove($a.name)
            }

            # Also stop whatever is listening on the app's port (e.g. JVM started inside IntelliJ)
            if (-not $killed) {
                $portPid = Get-ListeningPidByPort -TargetPort $a.port
                if ($null -ne $portPid) {
                    $killed = Stop-ProcessTree -ProcessId $portPid
                }
            }

            if ($killed) {
                $stoppedAny = $true
                Write-Host "[STOP]  $($a.name) (port $($a.port)): stopped" -ForegroundColor Cyan
            }
        }

        Write-State -Map $stateMap
        if (-not $stoppedAny) {
            Write-Host "No running apps to stop." -ForegroundColor Yellow
        }
    }
}