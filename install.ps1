#Requires -Version 5.1
<#
.SYNOPSIS
    dev-kit - one-shot developer environment installer for Windows.
.DESCRIPTION
    Installs and keeps up to date a selectable set of developer tools under the
    current user account (no admin needed for the language toolchains):
    git, JDK (Temurin >=21, multi-version via Use-Jdk), Maven, Gradle, Go, Rust,
    Node.js (via fnm), pnpm and bun. Re-running updates everything and prunes
    superseded versions. Auto-detects whether to use China mirrors.
.EXAMPLE
    .\install.ps1
    Interactive menu.
.EXAMPLE
    .\install.ps1 -All -Yes
    Install everything, no prompts.
.EXAMPLE
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/zzhtl/dev-kit/main/install.ps1))) -All -Yes
    One-liner install from the web.
#>
# Write-Host is the deliberate UI channel for this installer; empty catch blocks are
# intentional best-effort cleanup; the internal Set-/Update-/Remove- helpers do not
# take pipeline input and never need -WhatIf, so ShouldProcess would only add noise.
# No BOM on purpose: a BOM makes `irm <url>/install.ps1 | iex` fail (the leading
# U+FEFF ends up inside the parsed text). The only non-ASCII left in the file is in
# comments -- every Chinese UI string is stored as \uXXXX escapes.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseBOMForUnicodeEncodedFile', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
param(
    [switch]$All,
    [string[]]$With,
    [switch]$Yes,
    [string[]]$JdkVersion,
    [string]$GoVersion,
    [string]$RustVersion,
    [string]$NodeVersion,
    [ValidateSet('auto', 'cn', 'off')]
    [string]$Mirror = 'auto',
    [switch]$NoShellInit,
    [switch]$Uninstall,
    [switch]$KeepCache,
    [ValidateSet('zh', 'en', '')]
    [string]$Lang = '',
    [switch]$NoTui,
    [switch]$Help
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$script:DevKitVersion = '0.1.0'
$script:AllComponents = @('git', 'jdk', 'maven', 'gradle', 'go', 'rust', 'node', 'pnpm', 'bun')

# ----------------------------------------------------------------------------
# logging
# ----------------------------------------------------------------------------
function Write-DevKitInfo { param([string]$Message) Write-Host "  $Message" -ForegroundColor Gray }
function Write-DevKitStep { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-DevKitWarn { param([string]$Message) Write-Host "[warn] $Message" -ForegroundColor Yellow }
function Write-DevKitErr  { param([string]$Message) Write-Host "[error] $Message" -ForegroundColor Red }
function Write-DevKitOk   { param([string]$Message) Write-Host "[ok] $Message" -ForegroundColor Green }

function Show-DevKitUsage {
    Write-Host @'
dev-kit installer (Windows)

Run it with no arguments and you get an interactive menu: pick install or
uninstall, tick the components with the arrow keys and space, and review every
option before it runs. Every choice also has a parameter, so scripts never
need the menu.

Usage:
  .\install.ps1 [-All] [-With jdk,go,rust,git,node,bun,maven,gradle,pnpm] [-Yes]
                [-JdkVersion 21,25] [-GoVersion 1.27.1] [-RustVersion stable|1.90.0]
                [-NodeVersion lts|24] [-Mirror auto|cn|off] [-NoShellInit]
                [-Lang zh|en] [-NoTui] [-Help]

One-liner from the web (parameters need the scriptblock form):
  & ([scriptblock]::Create((irm <url>/install.ps1))) -All -Yes
  # or set $env:DEVKIT_ARGS = '-All -Yes' before: irm <url>/install.ps1 | iex

Uninstall:
  .\install.ps1 -Uninstall [-All | -With a,b,c] [-KeepCache] [-Yes]
  Removes the selected toolchains, their caches, and dev-kit config.
  User files (git/maven/gradle/npm config) are kept and reported.

Components : git jdk maven gradle go rust node pnpm bun
Mirror     : auto (probe github/go.dev; fall back to CN mirrors), cn, off
JDK        : Temurin, majors >=21; switch later with  Use-Jdk <major> [-Persist]
'@
}

# ----------------------------------------------------------------------------
# $env:DEVKIT_ARGS fallback (for `irm | iex` where params cannot be bound)
# ----------------------------------------------------------------------------
if ($PSBoundParameters.Count -eq 0 -and $env:DEVKIT_ARGS) {
    $toks = @($env:DEVKIT_ARGS -split '\s+' | Where-Object { $_ -ne '' })
    for ($i = 0; $i -lt $toks.Count; $i++) {
        $t = $toks[$i].ToLower()
        switch ($t) {
            '-all'           { $All = $true }
            '--all'          { $All = $true }
            '-yes'           { $Yes = $true }
            '--yes'          { $Yes = $true }
            '-noshellinit'   { $NoShellInit = $true }
            '--no-shell-init'{ $NoShellInit = $true }
            '-uninstall'     { $Uninstall = $true }
            '--uninstall'    { $Uninstall = $true }
            '-remove'        { $Uninstall = $true }
            '--remove'       { $Uninstall = $true }
            '-keepcache'     { $KeepCache = $true }
            '--keep-cache'   { $KeepCache = $true }
            '-notui'         { $NoTui = $true }
            '--no-tui'       { $NoTui = $true }
            '-lang'          { $i++; if ($i -lt $toks.Count) { $Lang = $toks[$i] } }
            '--lang'         { $i++; if ($i -lt $toks.Count) { $Lang = $toks[$i] } }
            '-help'          { $Help = $true }
            '--help'         { $Help = $true }
            '-with'          { $i++; if ($i -lt $toks.Count) { $With = $toks[$i] -split ',' } }
            '--with'         { $i++; if ($i -lt $toks.Count) { $With = $toks[$i] -split ',' } }
            '-mirror'        { $i++; if ($i -lt $toks.Count) { $Mirror = $toks[$i] } }
            '--mirror'       { $i++; if ($i -lt $toks.Count) { $Mirror = $toks[$i] } }
            '-jdkversion'    { $i++; if ($i -lt $toks.Count) { $JdkVersion = $toks[$i] -split ',' } }
            '--jdk-version'  { $i++; if ($i -lt $toks.Count) { $JdkVersion = $toks[$i] -split ',' } }
            '-goversion'     { $i++; if ($i -lt $toks.Count) { $GoVersion = $toks[$i] } }
            '--go-version'   { $i++; if ($i -lt $toks.Count) { $GoVersion = $toks[$i] } }
            '-rustversion'   { $i++; if ($i -lt $toks.Count) { $RustVersion = $toks[$i] } }
            '--rust-version' { $i++; if ($i -lt $toks.Count) { $RustVersion = $toks[$i] } }
            '-nodeversion'   { $i++; if ($i -lt $toks.Count) { $NodeVersion = $toks[$i] } }
            '--node-version' { $i++; if ($i -lt $toks.Count) { $NodeVersion = $toks[$i] } }
            default          { }
        }
    }
}

if ($Help) { Show-DevKitUsage; return }

# ----------------------------------------------------------------------------
# platform guard
# ----------------------------------------------------------------------------
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Write-DevKitErr 'install.ps1 is for Windows. On macOS/Linux use install.sh.'
    exit 1
}

# ----------------------------------------------------------------------------
# directories / state
# ----------------------------------------------------------------------------
$script:DevKitHome = Join-Path $env:LOCALAPPDATA 'dev-kit'
$script:JdkDir     = Join-Path $script:DevKitHome 'jdk'
$script:StateFile  = Join-Path $script:DevKitHome 'state.json'
$script:EnvFile    = Join-Path $script:DevKitHome 'env.ps1'
$script:FnmDir     = Join-Path $script:DevKitHome 'fnm'
$script:BunInstall = $env:BUN_INSTALL
if (-not $script:BunInstall) { $script:BunInstall = Join-Path $env:USERPROFILE '.bun' }
$script:PnpmHome = $env:PNPM_HOME
if (-not $script:PnpmHome) { $script:PnpmHome = Join-Path $env:LOCALAPPDATA 'pnpm' }
$script:CargoHome = $env:CARGO_HOME
if (-not $script:CargoHome) { $script:CargoHome = Join-Path $env:USERPROFILE '.cargo' }

if (-not (Test-Path $script:DevKitHome)) { New-Item -ItemType Directory -Force -Path $script:DevKitHome | Out-Null }
$script:TmpDir = Join-Path ([IO.Path]::GetTempPath()) ("dev-kit-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $script:TmpDir | Out-Null

# arch
$script:Arch = 'x64'
if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $script:Arch = 'arm64' }
elseif ($env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { $script:Arch = 'arm64' }

function Get-DevKitState {
    if (Test-Path $script:StateFile) {
        try { return (Get-Content -Raw -Path $script:StateFile | ConvertFrom-Json) } catch { }
    }
    return (New-Object PSObject)
}
# `$State.PSObject.Properties.Name` is member enumeration over the property
# collection. On a fresh machine the state object has no properties at all, and
# enumerating a member off an empty collection throws under Set-StrictMode 2.0
# ("The property 'Name' cannot be found on this object") -- which killed the
# very first state read. The indexer returns $null for a missing name instead.
function Get-DevKitStateValue {
    param($State, [string]$Name)
    if ($null -eq $State) { return $null }
    $prop = $State.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}
function Set-DevKitStateValue {
    param($State, [string]$Name, $Value)
    if ($null -ne $State.PSObject.Properties[$Name]) { $State.$Name = $Value }
    else { $State | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}
function Save-DevKitState {
    param($State)
    # UTF-8 without BOM; PS 5.1 Set-Content -Encoding UTF8 emits a BOM that can
    # trip ConvertFrom-Json on the next read, which would reset our cleanup state.
    Write-DevKitTextFile -Path $script:StateFile -Content ($State | ConvertTo-Json -Depth 6)
}

$script:State = Get-DevKitState

# ----------------------------------------------------------------------------
# network / archive helpers
# ----------------------------------------------------------------------------
function Invoke-DevKitWebString {
    param([string]$Url, [int]$TimeoutSec = 30)
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $resp = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec $TimeoutSec
            return $resp.Content
        } catch {
            if ($attempt -ge 3) { throw }
            Start-Sleep -Seconds 2
        }
    }
}

function Get-DevKitJson {
    param([string]$Url, [int]$TimeoutSec = 30)
    return (Invoke-DevKitWebString -Url $Url -TimeoutSec $TimeoutSec | ConvertFrom-Json)
}

function Get-DevKitFile {
    param([string]$Url, [string]$Dest, [string]$Sha256)
    $part = "$Dest.part"
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            if (Test-Path $part) { Remove-Item -Force $part }
            Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $part -TimeoutSec 600
            break
        } catch {
            if ($attempt -ge 3) { throw }
            Start-Sleep -Seconds 2
        }
    }
    if ($Sha256) {
        $got = (Get-FileHash -Algorithm SHA256 -Path $part).Hash.ToLower()
        if ($got -ne $Sha256.ToLower()) {
            Remove-Item -Force $part
            throw "sha256 mismatch for $Url (expected $Sha256 got $got)"
        }
    }
    if (Test-Path $Dest) { Remove-Item -Force -Recurse $Dest }
    Move-Item -Force $part $Dest
}

function Expand-DevKitArchive {
    param([string]$Path, [string]$Dest)
    if (-not (Test-Path $Dest)) { New-Item -ItemType Directory -Force -Path $Dest | Out-Null }
    $tarExe = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (Test-Path $tarExe) {
        & $tarExe -x -f $Path -C $Dest
        if ($LASTEXITCODE -ne 0) { throw "tar extraction failed for $Path" }
    } elseif ($Path -match '\.zip$') {
        Expand-Archive -Path $Path -DestinationPath $Dest -Force
    } else {
        throw "cannot extract $Path (no tar.exe available and not a .zip)"
    }
}

function Compare-DevKitVersion {
    param([string]$A, [string]$B)
    $ra = [regex]::Matches($A, '\d+')
    $rb = [regex]::Matches($B, '\d+')
    $n = [Math]::Max($ra.Count, $rb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $va = 0; $vb = 0
        if ($i -lt $ra.Count) { $va = [int64]$ra[$i].Value }
        if ($i -lt $rb.Count) { $vb = [int64]$rb[$i].Value }
        if ($va -gt $vb) { return 1 }
        if ($va -lt $vb) { return -1 }
    }
    return 0
}

# ----------------------------------------------------------------------------
# mirror detection
# ----------------------------------------------------------------------------
function Test-DevKitUrl {
    param([string]$Url)
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $Url -Method Head -TimeoutSec 4 | Out-Null
        return $true
    } catch { return $false }
}

function Resolve-DevKitMirror {
    param([string]$Requested)
    if ($Requested -eq 'cn') { return 'cn' }
    if ($Requested -eq 'off') { return 'off' }
    $githubOk = Test-DevKitUrl 'https://github.com'
    $goOk = Test-DevKitUrl 'https://go.dev'
    if ((-not $githubOk) -or (-not $goOk)) {
        if (Test-DevKitUrl 'https://mirrors.tuna.tsinghua.edu.cn') {
            Write-DevKitInfo 'international sources slow/unreachable; using China mirrors'
            return 'cn'
        }
    }
    return 'off'
}

# ----------------------------------------------------------------------------
# PATH / env helpers (User scope only)
# ----------------------------------------------------------------------------
function Send-DevKitSettingChange {
    try {
        if (-not ('Win32.DevKitNative' -as [type])) {
            Add-Type -Namespace Win32 -Name DevKitNative -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
'@
        }
        $HWND_BROADCAST = [IntPtr]0xffff
        $WM_SETTINGCHANGE = 0x1A
        $out = [UIntPtr]::Zero
        [void][Win32.DevKitNative]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$out)
    } catch { }
}

function Set-DevKitUserPath {
    param([string[]]$Prepend)
    $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $cur) { $cur = '' }
    $parts = @($cur -split ';' | Where-Object { $_ -ne '' -and $_ -notmatch '\\dev-kit\\' })
    $prependSet = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $Prepend) { if ($p) { [void]$prependSet.Add($p) } }
    $seen = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    $kept = @()
    foreach ($p in $parts) {
        if ($prependSet.Contains($p)) { continue }
        if ($seen.Add($p)) { $kept += $p }
    }
    $final = @()
    foreach ($p in $Prepend) { if ($p -and (Test-Path $p)) { $final += $p } }
    $final += $kept
    $newPath = ($final -join ';')
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (-not $machine) { $machine = '' }
    $env:Path = "$newPath;$machine"
    Send-DevKitSettingChange
}

function Set-DevKitUserEnv {
    param([string]$Name, [string]$Value)
    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    Set-Item -Path ("Env:" + $Name) -Value $Value
}
function Remove-DevKitUserEnv {
    param([string]$Name)
    [Environment]::SetEnvironmentVariable($Name, $null, 'User')
    if (Test-Path ("Env:" + $Name)) { Remove-Item -Path ("Env:" + $Name) -ErrorAction SilentlyContinue }
}

# ----------------------------------------------------------------------------
# marker-block file editing
# ----------------------------------------------------------------------------
function Set-DevKitMarkerBlock {
    param([string]$File, [string]$Content)
    $begin = '# >>> dev-kit >>>'
    $end = '# <<< dev-kit <<<'
    $block = "$begin`r`n$Content`r`n$end"
    $dir = Split-Path -Parent $File
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $existing = ''
    if (Test-Path $File) { $existing = [IO.File]::ReadAllText($File) }
    $pattern = [regex]::Escape($begin) + '.*?' + [regex]::Escape($end)
    $rx = New-Object System.Text.RegularExpressions.Regex($pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($rx.IsMatch($existing)) {
        $evaluator = [System.Text.RegularExpressions.MatchEvaluator] { param($m) $null = $m; $block }
        $out = $rx.Replace($existing, $evaluator)
    } else {
        $sep = ''
        if ($existing -and -not $existing.EndsWith("`n")) { $sep = "`r`n" }
        $out = $existing + $sep + $block + "`r`n"
    }
    [IO.File]::WriteAllText($File, $out, (New-Object System.Text.UTF8Encoding($false)))
}
function Remove-DevKitMarkerBlock {
    param([string]$File)
    if (-not (Test-Path $File)) { return }
    $begin = '# >>> dev-kit >>>'
    $end = '# <<< dev-kit <<<'
    $existing = [IO.File]::ReadAllText($File)
    $pattern = '\r?\n?' + [regex]::Escape($begin) + '.*?' + [regex]::Escape($end) + '\r?\n?'
    $rx = New-Object System.Text.RegularExpressions.Regex($pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $out = $rx.Replace($existing, "`r`n")
    [IO.File]::WriteAllText($File, $out, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-DevKitTextFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

# ----------------------------------------------------------------------------
# winget helper
# ----------------------------------------------------------------------------
function Get-DevKitHasWinget { return [bool](Get-Command winget -ErrorAction SilentlyContinue) }

# ----------------------------------------------------------------------------
# component: git
# ----------------------------------------------------------------------------
function Install-DevKitGit {
    if (Get-DevKitHasWinget) {
        $isInstalled = $false
        try {
            & winget list --id Git.Git -e --accept-source-agreements 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { $isInstalled = $true }
        } catch { }
        if ($isInstalled) {
            Write-DevKitInfo 'git present; checking for upgrade via winget'
            try { & winget upgrade --id Git.Git -e --silent --accept-package-agreements --accept-source-agreements 2>$null | Out-Null } catch { }
        } else {
            Write-DevKitInfo 'installing git via winget (user scope)'
            & winget install --id Git.Git -e --scope user --silent --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) { throw "winget install Git.Git failed ($LASTEXITCODE)" }
        }
        return
    }
    Write-DevKitWarn 'winget not available; installing portable MinGit under dev-kit'
    Install-DevKitGitPortable
}

function Install-DevKitGitPortable {
    if ($script:Mirror -eq 'cn') {
        $base = 'https://registry.npmmirror.com/-/binary/git-for-windows/'
        $listing = Invoke-DevKitWebString $base
        $dirs = [regex]::Matches($listing, '"name":"(v[0-9.]+\.windows\.[0-9]+)/"')
        if ($dirs.Count -eq 0) { throw 'no git-for-windows releases on npmmirror' }
        $bestDir = $null
        foreach ($d in $dirs) { $v = $d.Groups[1].Value; if (-not $bestDir -or (Compare-DevKitVersion $v $bestDir) -gt 0) { $bestDir = $v } }
        $sub = "$base$bestDir/"
        $subListing = Invoke-DevKitWebString $sub
        $asset = [regex]::Match($subListing, '"name":"(MinGit-[0-9.]+-64-bit\.zip)"')
        if (-not $asset.Success) { throw "no MinGit zip in $sub" }
        $url = "$sub$($asset.Groups[1].Value)"
    } else {
        $rel = Get-DevKitJson 'https://api.github.com/repos/git-for-windows/git/releases/latest'
        $asset = @($rel.assets | Where-Object { $_.name -match '^MinGit-[0-9.]+-64-bit\.zip$' }) | Select-Object -First 1
        if (-not $asset) { throw 'no MinGit asset in latest git-for-windows release' }
        $url = $asset.browser_download_url
    }
    $zip = Join-Path $script:TmpDir 'mingit.zip'
    Get-DevKitFile -Url $url -Dest $zip
    $target = Join-Path $script:DevKitHome 'git'
    if (Test-Path $target) { Remove-Item -Recurse -Force $target }
    Expand-DevKitArchive -Path $zip -Dest $target
}

# ----------------------------------------------------------------------------
# component: jdk
# ----------------------------------------------------------------------------
function Get-DevKitLtsMajorList {
    try {
        $info = Get-DevKitJson 'https://api.adoptium.net/v3/info/available_releases'
        return @($info.available_lts_releases | ForEach-Object { [int]$_ } | Where-Object { $_ -ge 21 })
    } catch { return @(21, 25) }
}
function Get-DevKitDefaultJdkMajor {
    $lts = Get-DevKitLtsMajorList
    if ($lts.Count -gt 0) { return (@($lts | Sort-Object -Descending))[0] }
    return 21
}

function Get-DevKitJdkInstalledVersion {
    param([int]$Major)
    $rel = Join-Path (Join-Path $script:JdkDir $Major) 'release'
    if (Test-Path $rel) {
        $line = Select-String -Path $rel -Pattern '^JAVA_VERSION=' | Select-Object -First 1
        if ($line) { return ($line.Line -replace 'JAVA_VERSION=', '' -replace '"', '').Trim() }
    }
    return $null
}

function Resolve-DevKitJdkAdoptium {
    param([int]$Major)
    $arch = 'x64'
    if ($script:Arch -eq 'arm64') { $arch = 'aarch64' }
    $api = "https://api.adoptium.net/v3/assets/latest/$Major/hotspot?os=windows&architecture=$arch&image_type=jdk"
    $data = @(Get-DevKitJson $api)
    if ($data.Count -eq 0 -and $arch -eq 'aarch64') {
        Write-DevKitWarn "no arm64 Temurin $Major; using x64 build under emulation"
        $api = "https://api.adoptium.net/v3/assets/latest/$Major/hotspot?os=windows&architecture=x64&image_type=jdk"
        $data = @(Get-DevKitJson $api)
    }
    if ($data.Count -eq 0) { throw "Adoptium has no Windows JDK $Major" }
    $o = $data[0]
    $ver = $o.release_name -replace '^jdk-', ''
    return [PSCustomObject]@{ Version = $ver; Url = $o.binary.package.link; Sha256 = $o.binary.package.checksum }
}

function Resolve-DevKitJdkTuna {
    param([int]$Major)
    $dirArch = 'x64'
    if ($script:Arch -eq 'arm64' -and $Major -eq 21) { $dirArch = 'aarch64' }
    $base = "https://mirrors.tuna.tsinghua.edu.cn/Adoptium/$Major/jdk/$dirArch/windows/"
    $html = Invoke-DevKitWebString $base
    $mlist = [regex]::Matches($html, 'href="(OpenJDK\d+U-jdk_[^"]+_hotspot_[^"]+\.zip)"')
    if ($mlist.Count -eq 0) { throw "no Windows JDK zip in $base" }
    $best = $null; $bestVer = $null
    foreach ($mm in $mlist) {
        $fn = $mm.Groups[1].Value
        $v = ($fn -replace '.*_hotspot_', '' -replace '\.zip$', '')
        $v = $v -replace '_([0-9]+)$', '+$1'
        if (-not $best -or (Compare-DevKitVersion $v $bestVer) -gt 0) { $best = $fn; $bestVer = $v }
    }
    $url = "$base$best"
    $sha = $null
    try { $sha = ((Invoke-DevKitWebString "$url.sha256.txt") -split '\s+')[0] } catch { }
    return [PSCustomObject]@{ Version = $bestVer; Url = $url; Sha256 = $sha }
}

function Resolve-DevKitJdk {
    param([int]$Major)
    if ($script:Mirror -eq 'cn') {
        try { return (Resolve-DevKitJdkTuna -Major $Major) }
        catch { Write-DevKitWarn "TUNA JDK $Major unavailable, falling back to Adoptium: $($_.Exception.Message)" }
    }
    return (Resolve-DevKitJdkAdoptium -Major $Major)
}

function Install-DevKitJdkArchive {
    param([int]$Major, $Resolved)
    $zip = Join-Path $script:TmpDir "jdk-$Major.zip"
    Get-DevKitFile -Url $Resolved.Url -Dest $zip -Sha256 $Resolved.Sha256
    $ex = Join-Path $script:TmpDir "jdk-$Major-x"
    if (Test-Path $ex) { Remove-Item -Recurse -Force $ex }
    Expand-DevKitArchive -Path $zip -Dest $ex
    $inner = @(Get-ChildItem -Path $ex -Directory) | Select-Object -First 1
    if (-not $inner) { throw "empty JDK archive for $Major" }
    $target = Join-Path $script:JdkDir $Major
    $new = "$target.new"
    if (Test-Path $new) { Remove-Item -Recurse -Force $new }
    Move-Item -Force $inner.FullName $new
    if (Test-Path $target) { Remove-Item -Recurse -Force $target }
    Move-Item -Force $new $target
}

function Install-DevKitJdk {
    $existing = @()
    if (Test-Path $script:JdkDir) {
        Get-ChildItem $script:JdkDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.Name -match '^\d+$') { $existing += [int]$_.Name }
        }
    }
    $req = @()
    foreach ($j in $script:JdkReq) { $req += [int]((($j) -split '\.')[0]) }
    $majors = @()
    foreach ($m in ($req + $existing)) { if ($majors -notcontains $m) { $majors += $m } }
    if ($majors.Count -eq 0) { $majors = @((Get-DevKitDefaultJdkMajor)) }

    if ($req.Count -gt 0) {
        $defaultMajor = $req[0]
    } else {
        $ltsSet = Get-DevKitLtsMajorList
        $inBoth = @($majors | Where-Object { $ltsSet -contains $_ })
        if ($inBoth.Count -gt 0) { $defaultMajor = (@($inBoth | Sort-Object -Descending))[0] }
        else { $defaultMajor = (@($majors | Sort-Object -Descending))[0] }
    }

    $installedOk = @()
    foreach ($M in $majors) {
        try {
            $r = Resolve-DevKitJdk -Major $M
            $cur = Get-DevKitJdkInstalledVersion -Major $M
            if ($cur -and (Compare-DevKitVersion $r.Version $cur) -le 0) {
                Write-DevKitInfo "JDK $M up to date ($cur)"
            } else {
                Write-DevKitInfo "JDK $M -> $($r.Version)"
                Install-DevKitJdkArchive -Major $M -Resolved $r
            }
            $installedOk += $M
        } catch {
            Write-DevKitWarn "JDK $M failed: $($_.Exception.Message)"
        }
    }
    if ($installedOk.Count -eq 0) { throw 'no JDK major could be installed' }
    if ($installedOk -notcontains $defaultMajor) { $defaultMajor = (@($installedOk | Sort-Object -Descending))[0] }
    Set-Content -Path (Join-Path $script:JdkDir 'default') -Value $defaultMajor -NoNewline
    Set-DevKitUserEnv 'JAVA_HOME' (Join-Path $script:JdkDir $defaultMajor)
    Write-DevKitInfo "default JDK -> $defaultMajor"
}

# ----------------------------------------------------------------------------
# component: maven
# ----------------------------------------------------------------------------
function Get-DevKitLatestMaven {
    if ($script:Mirror -eq 'cn') {
        $base = 'https://mirrors.tuna.tsinghua.edu.cn/apache/maven/maven-3/'
    } else {
        $base = 'https://dlcdn.apache.org/maven/maven-3/'
    }
    $html = Invoke-DevKitWebString $base
    $mlist = [regex]::Matches($html, 'href="(3\.[0-9]+\.[0-9]+)/"')
    if ($mlist.Count -eq 0) { throw "no Maven 3.x versions at $base" }
    $best = $null
    foreach ($mm in $mlist) { $v = $mm.Groups[1].Value; if (-not $best -or (Compare-DevKitVersion $v $best) -gt 0) { $best = $v } }
    return [PSCustomObject]@{ Version = $best; Base = $base }
}
function Install-DevKitMaven {
    $info = Get-DevKitLatestMaven
    $ver = $info.Version
    $root = Join-Path $script:DevKitHome 'maven'
    $dir = Join-Path $root "apache-maven-$ver"
    if (Test-Path (Join-Path $dir 'bin\mvn.cmd')) {
        Write-DevKitInfo "Maven $ver up to date"
    } else {
        Write-DevKitInfo "Maven -> $ver"
        $url = "$($info.Base)$ver/binaries/apache-maven-$ver-bin.zip"
        $zip = Join-Path $script:TmpDir "maven-$ver.zip"
        Get-DevKitFile -Url $url -Dest $zip
        if (-not (Test-Path $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
        Expand-DevKitArchive -Path $zip -Dest $root
    }
    Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "apache-maven-$ver" } | ForEach-Object { Remove-Item -Recurse -Force $_.FullName }
}

# ----------------------------------------------------------------------------
# component: gradle
# ----------------------------------------------------------------------------
function Install-DevKitGradle {
    $g = Get-DevKitJson 'https://services.gradle.org/versions/current'
    $ver = $g.version
    $root = Join-Path $script:DevKitHome 'gradle'
    $dir = Join-Path $root "gradle-$ver"
    if (Test-Path (Join-Path $dir 'bin\gradle.bat')) {
        Write-DevKitInfo "Gradle $ver up to date"
    } else {
        Write-DevKitInfo "Gradle -> $ver"
        if ($script:Mirror -eq 'cn') {
            $url = "https://mirrors.cloud.tencent.com/gradle/gradle-$ver-bin.zip"
            $sha = $null
        } else {
            $url = $g.downloadUrl
            $sha = $g.checksum
        }
        $zip = Join-Path $script:TmpDir "gradle-$ver.zip"
        Get-DevKitFile -Url $url -Dest $zip -Sha256 $sha
        if (-not (Test-Path $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
        Expand-DevKitArchive -Path $zip -Dest $root
    }
    Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "gradle-$ver" } | ForEach-Object { Remove-Item -Recurse -Force $_.FullName }
}

# ----------------------------------------------------------------------------
# component: go
# ----------------------------------------------------------------------------
function Install-DevKitGo {
    if ($script:Mirror -eq 'cn') { $dlBase = 'https://golang.google.cn/dl/' } else { $dlBase = 'https://go.dev/dl/' }
    $json = Get-DevKitJson "$dlBase`?mode=json"
    if ($GoVersion) { $ver = "go$GoVersion" } else { $ver = $json[0].version }
    $arch = 'amd64'
    if ($script:Arch -eq 'arm64') { $arch = 'arm64' }
    $fname = "$ver.windows-$arch.zip"
    $sha = $null
    foreach ($rel in $json) {
        if ($rel.version -eq $ver) {
            foreach ($f in $rel.files) {
                if ($f.filename -eq $fname) { $sha = $f.sha256; break }
            }
        }
    }
    $goRoot = Join-Path $script:DevKitHome 'go'
    $goExe = Join-Path $goRoot 'bin\go.exe'
    $cur = $null
    if (Test-Path $goExe) {
        try {
            $vout = & $goExe version 2>$null
            $mm = [regex]::Match([string]$vout, 'go[0-9][0-9.]*')
            if ($mm.Success) { $cur = $mm.Value }
        } catch { }
    }
    if ($cur -eq $ver) {
        Write-DevKitInfo "Go $ver up to date"
    } else {
        Write-DevKitInfo "Go -> $ver"
        $url = "$dlBase$fname"
        $zip = Join-Path $script:TmpDir "$fname"
        Get-DevKitFile -Url $url -Dest $zip -Sha256 $sha
        $ex = Join-Path $script:TmpDir 'go-x'
        if (Test-Path $ex) { Remove-Item -Recurse -Force $ex }
        Expand-DevKitArchive -Path $zip -Dest $ex
        $inner = Join-Path $ex 'go'
        $new = "$goRoot.new"
        if (Test-Path $new) { Remove-Item -Recurse -Force $new }
        Move-Item -Force $inner $new
        if (Test-Path $goRoot) { Remove-Item -Recurse -Force $goRoot }
        Move-Item -Force $new $goRoot
    }
    if ($script:Mirror -eq 'cn') {
        try { & $goExe env -w GOPROXY=https://goproxy.cn,direct } catch { }
    } else {
        try {
            $gp = (& $goExe env GOPROXY) 2>$null
            if ([string]$gp -match 'goproxy\.cn') { & $goExe env -u GOPROXY }
        } catch { }
    }
}

# ----------------------------------------------------------------------------
# component: rust
# ----------------------------------------------------------------------------
function Test-DevKitMsvc {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        try {
            $p = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath -latest 2>$null
            if ($p) { return $true }
        } catch { }
    }
    if (Get-Command cl.exe -ErrorAction SilentlyContinue) { return $true }
    return $false
}

function Install-DevKitVsBuildTool {
    if (-not (Get-DevKitHasWinget)) {
        Write-DevKitWarn 'winget not available; install "Visual Studio Build Tools" (C++ workload) manually for Rust linking'
        return $false
    }
    $ok = $script:Yes
    if (-not $ok) {
        $ans = Read-Host 'Rust needs the MSVC C++ Build Tools. Install now via winget? [y/N]'
        if ($ans -match '^(y|yes)$') { $ok = $true }
    }
    if (-not $ok) { return $false }
    Write-DevKitInfo 'installing Visual Studio 2022 Build Tools (VCTools) - a UAC prompt may appear'
    try {
        & winget install --id Microsoft.VisualStudio.2022.BuildTools -e --accept-package-agreements --accept-source-agreements --override "--quiet --wait --norestart --nocache --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
        if ($LASTEXITCODE -eq 0) { return $true }
        if ($LASTEXITCODE -eq 3010) { Write-DevKitWarn 'Build Tools installed; a reboot is required'; return $true }
        Write-DevKitWarn "winget Build Tools exit code $LASTEXITCODE"
        return $false
    } catch {
        Write-DevKitWarn "Build Tools install failed: $($_.Exception.Message)"
        return $false
    }
}

function Set-DevKitCargoMirror {
    param([bool]$Enable)
    $cfg = Join-Path $script:CargoHome 'config.toml'
    $begin = '# >>> dev-kit >>>'
    if ($Enable) {
        $existing = ''
        if (Test-Path $cfg) { $existing = [IO.File]::ReadAllText($cfg) }
        if ($existing -match '\[source\.crates-io\]' -and $existing -notmatch [regex]::Escape($begin)) {
            Write-DevKitWarn 'cargo config.toml already has [source.crates-io]; leaving mirror config to you'
            return
        }
        $block = @'
[source.crates-io]
replace-with = 'rsproxy-sparse'
[source.rsproxy-sparse]
registry = "sparse+https://rsproxy.cn/index/"
[registries.rsproxy-sparse]
index = "sparse+https://rsproxy.cn/index/"
[net]
git-fetch-with-cli = true
'@
        Set-DevKitMarkerBlock -File $cfg -Content $block
    } else {
        Remove-DevKitMarkerBlock -File $cfg
    }
}

function Install-DevKitRust {
    if ($RustVersion) { $toolchain = $RustVersion } else { $toolchain = 'stable' }
    $isPin = ($toolchain -match '^\d+\.\d+(\.\d+)?$')

    $hasMsvc = Test-DevKitMsvc
    if (-not $hasMsvc) {
        $installed = Install-DevKitVsBuildTool
        if ($installed) { $hasMsvc = Test-DevKitMsvc }
    }
    $script:RustMsvcMissing = (-not $hasMsvc)

    if ($script:Arch -eq 'arm64') { $triple = 'aarch64-pc-windows-msvc' } else { $triple = 'x86_64-pc-windows-msvc' }

    $rustup = Join-Path $script:CargoHome 'bin\rustup.exe'
    if (-not (Test-Path $rustup)) { $rustup = (Get-Command rustup -ErrorAction SilentlyContinue).Source }

    if ($script:Mirror -eq 'cn') {
        $env:RUSTUP_DIST_SERVER = 'https://rsproxy.cn'
        $env:RUSTUP_UPDATE_ROOT = 'https://rsproxy.cn/rustup'
    }

    if ($rustup -and (Test-Path $rustup)) {
        Write-DevKitInfo 'rustup present; updating'
        try { & $rustup self update } catch { }
        & $rustup update
        if ($isPin) {
            & $rustup toolchain install $toolchain
            & $rustup default $toolchain
            $prevPin = Get-DevKitStateValue $script:State 'rust_pin'
            if ($prevPin -and $prevPin -ne $toolchain) {
                Write-DevKitInfo "removing superseded Rust toolchain $prevPin"
                try { & $rustup toolchain uninstall $prevPin } catch { }
            }
            Set-DevKitStateValue $script:State 'rust_pin' $toolchain
        } else {
            & $rustup default $toolchain
        }
    } else {
        Write-DevKitInfo "installing rustup (toolchain: $toolchain)"
        $initExe = Join-Path $script:TmpDir 'rustup-init.exe'
        if ($script:Mirror -eq 'cn') { $initUrl = "https://rsproxy.cn/rustup/dist/$triple/rustup-init.exe" }
        else { $initUrl = "https://static.rust-lang.org/rustup/dist/$triple/rustup-init.exe" }
        Get-DevKitFile -Url $initUrl -Dest $initExe
        & $initExe -y --no-modify-path --default-toolchain $toolchain --profile default
        if ($LASTEXITCODE -ne 0) { throw "rustup-init failed ($LASTEXITCODE)" }
        if ($isPin) { Set-DevKitStateValue $script:State 'rust_pin' $toolchain }
    }

    Set-DevKitCargoMirror -Enable ($script:Mirror -eq 'cn')
}

# ----------------------------------------------------------------------------
# component: node (fnm)
# ----------------------------------------------------------------------------
function Install-DevKitFnmBinary {
    $binDir = Join-Path $script:DevKitHome 'bin'
    if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Force -Path $binDir | Out-Null }
    $fnmExe = Join-Path $binDir 'fnm.exe'
    if ($script:Arch -eq 'arm64') { Write-DevKitWarn 'no native arm64 fnm; using x64 build under emulation' }
    $url = 'https://github.com/Schniz/fnm/releases/latest/download/fnm-windows.zip'
    $zip = Join-Path $script:TmpDir 'fnm-windows.zip'
    Get-DevKitFile -Url $url -Dest $zip
    $ex = Join-Path $script:TmpDir 'fnm-x'
    if (Test-Path $ex) { Remove-Item -Recurse -Force $ex }
    Expand-DevKitArchive -Path $zip -Dest $ex
    $src = @(Get-ChildItem -Path $ex -Recurse -Filter 'fnm.exe') | Select-Object -First 1
    if (-not $src) { throw 'fnm.exe not found in archive' }
    Copy-Item -Force $src.FullName $fnmExe
    return $fnmExe
}

function Install-DevKitNode {
    $fnmExe = Join-Path $script:DevKitHome 'bin\fnm.exe'
    if (-not (Test-Path $fnmExe)) { $fnmExe = Install-DevKitFnmBinary }
    else { $fnmExe = Install-DevKitFnmBinary }  # always refresh to latest fnm

    $env:FNM_DIR = $script:FnmDir
    Set-DevKitUserEnv 'FNM_DIR' $script:FnmDir
    if ($script:Mirror -eq 'cn') {
        $env:FNM_NODE_DIST_MIRROR = 'https://npmmirror.com/mirrors/node'
        Set-DevKitUserEnv 'FNM_NODE_DIST_MIRROR' 'https://npmmirror.com/mirrors/node'
    }

    $want = $NodeVersion
    if (-not $want) { $want = 'lts' }
    Write-DevKitInfo "installing Node ($want)"
    if ($want -eq 'lts') { & $fnmExe install --lts } else { & $fnmExe install $want }
    if ($LASTEXITCODE -ne 0) { throw "fnm install $want failed" }

    # parse installed versions
    $lsOut = & $fnmExe ls 2>$null
    $vers = @()
    foreach ($ln in @($lsOut -split "`n")) {
        $mm = [regex]::Match($ln, 'v(\d+\.\d+\.\d+)')
        if ($mm.Success) { $vers += $mm.Groups[1].Value }
    }
    $byMajor = @{}
    foreach ($v in $vers) {
        $maj = ($v -split '\.')[0]
        if (-not $byMajor.ContainsKey($maj)) { $byMajor[$maj] = @() }
        $byMajor[$maj] += $v
    }
    # prune older patch within each major
    foreach ($maj in @($byMajor.Keys)) {
        $sorted = @($byMajor[$maj] | Sort-Object { [version]$_ } -Descending)
        for ($i = 1; $i -lt $sorted.Count; $i++) {
            Write-DevKitInfo "removing superseded Node v$($sorted[$i])"
            try { & $fnmExe uninstall "v$($sorted[$i])" } catch { }
        }
        $byMajor[$maj] = @($sorted[0])
    }
    # default major
    if ($want -match '^\d+\.\d+\.\d+$') { $defMajor = ($want -split '\.')[0] }
    elseif ($want -match '^\d+$') { $defMajor = $want }
    else {
        $curDef = & $fnmExe default 2>$null
        $dm = [regex]::Match([string]$curDef, 'v(\d+)\.')
        if ($dm.Success) { $defMajor = $dm.Groups[1].Value }
        else { $defMajor = $null }
    }
    if (-not $defMajor -or -not $byMajor.ContainsKey($defMajor)) {
        $defMajor = @($byMajor.Keys | Sort-Object { [int]$_ } -Descending)[0]
    }
    if ($defMajor -and $byMajor.ContainsKey($defMajor)) {
        & $fnmExe default "v$($byMajor[$defMajor][0])"
        Write-DevKitInfo "default Node -> v$($byMajor[$defMajor][0])"
    }
}

# ----------------------------------------------------------------------------
# component: pnpm
# ----------------------------------------------------------------------------
function Install-DevKitPnpm {
    $tags = Get-DevKitJson 'https://registry.npmjs.org/-/package/pnpm/dist-tags'
    $ver = $tags.latest
    if ($script:Arch -eq 'arm64') { $arch = 'arm64' } else { $arch = 'x64' }
    if ($script:Mirror -eq 'cn') { $registry = 'https://registry.npmmirror.com' } else { $registry = 'https://registry.npmjs.org' }
    $url = "$registry/@pnpm/exe.win32-$arch/-/exe.win32-$arch-$ver.tgz"
    Write-DevKitInfo "pnpm -> $ver"
    $tgz = Join-Path $script:TmpDir "pnpm-$ver.tgz"
    Get-DevKitFile -Url $url -Dest $tgz
    $ex = Join-Path $script:TmpDir 'pnpm-x'
    if (Test-Path $ex) { Remove-Item -Recurse -Force $ex }
    Expand-DevKitArchive -Path $tgz -Dest $ex
    $bin = @(Get-ChildItem -Path $ex -Recurse -Filter 'pnpm.exe') | Select-Object -First 1
    if (-not $bin) { throw 'pnpm.exe not found in tarball' }
    if (-not (Test-Path $script:PnpmHome)) { New-Item -ItemType Directory -Force -Path $script:PnpmHome | Out-Null }
    Copy-Item -Force $bin.FullName (Join-Path $script:PnpmHome 'pnpm.exe')
    Set-DevKitUserEnv 'PNPM_HOME' $script:PnpmHome

    # npm registry mirror (only if user has no explicit registry)
    $npmrc = Join-Path $env:USERPROFILE '.npmrc'
    if ($script:Mirror -eq 'cn') {
        $existing = ''
        if (Test-Path $npmrc) { $existing = [IO.File]::ReadAllText($npmrc) }
        if ($existing -notmatch '(?m)^\s*registry\s*=' -or $existing -match [regex]::Escape('# >>> dev-kit >>>')) {
            Set-DevKitMarkerBlock -File $npmrc -Content 'registry=https://registry.npmmirror.com'
        }
    } else {
        Remove-DevKitMarkerBlock -File $npmrc
    }
}

# ----------------------------------------------------------------------------
# component: bun
# ----------------------------------------------------------------------------
function Install-DevKitBun {
    if ($script:Arch -eq 'arm64') { $arch = 'aarch64' } else { $arch = 'x64' }
    if ($script:Mirror -eq 'cn') {
        $base = 'https://registry.npmmirror.com/-/binary/bun/'
        $listing = Invoke-DevKitWebString $base
        $tags = [regex]::Matches($listing, '"name":"(bun-v[0-9.]+)/"')
        if ($tags.Count -eq 0) { throw 'no bun releases on npmmirror' }
        $tag = $null
        foreach ($tm in $tags) { $v = $tm.Groups[1].Value; if (-not $tag -or (Compare-DevKitVersion $v $tag) -gt 0) { $tag = $v } }
        $url = "$base$tag/bun-windows-$arch.zip"
    } else {
        $rel = Get-DevKitJson 'https://api.github.com/repos/oven-sh/bun/releases/latest'
        $tag = $rel.tag_name
        $url = "https://github.com/oven-sh/bun/releases/download/$tag/bun-windows-$arch.zip"
    }
    Write-DevKitInfo "bun -> $tag"
    $zip = Join-Path $script:TmpDir 'bun-windows.zip'
    Get-DevKitFile -Url $url -Dest $zip
    $ex = Join-Path $script:TmpDir 'bun-x'
    if (Test-Path $ex) { Remove-Item -Recurse -Force $ex }
    Expand-DevKitArchive -Path $zip -Dest $ex
    $bin = @(Get-ChildItem -Path $ex -Recurse -Filter 'bun.exe') | Select-Object -First 1
    if (-not $bin) { throw 'bun.exe not found in archive' }
    $bunBin = Join-Path $script:BunInstall 'bin'
    if (-not (Test-Path $bunBin)) { New-Item -ItemType Directory -Force -Path $bunBin | Out-Null }
    Copy-Item -Force $bin.FullName (Join-Path $bunBin 'bun.exe')
    Set-DevKitUserEnv 'BUN_INSTALL' $script:BunInstall
}

# ----------------------------------------------------------------------------
# env.ps1 + profile integration
# ----------------------------------------------------------------------------
function Write-DevKitEnvFile {
    $jdkInstalled = (Test-Path $script:JdkDir) -and (@(Get-ChildItem $script:JdkDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+$' }).Count -gt 0)
    $fnmInstalled = Test-Path (Join-Path $script:DevKitHome 'bin\fnm.exe')

    $header = "# dev-kit environment - do not edit (regenerated on each run)`r`n"
    $jdkBlock = @'
function Use-Jdk {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Major, [switch]$Persist)
    $base = Join-Path $env:LOCALAPPDATA 'dev-kit\jdk'
    $jdkHome = Join-Path $base $Major
    if (-not (Test-Path (Join-Path $jdkHome 'bin\java.exe'))) { Write-Error "JDK $Major is not installed under dev-kit"; return }
    $env:JAVA_HOME = $jdkHome
    $binPath = Join-Path $jdkHome 'bin'
    $parts = @($env:Path -split ';' | Where-Object { $_ -ne '' -and $_ -notmatch '\\dev-kit\\jdk\\' })
    $env:Path = (@($binPath) + $parts) -join ';'
    if ($Persist) {
        [Environment]::SetEnvironmentVariable('JAVA_HOME', $jdkHome, 'User')
        Set-Content -Path (Join-Path $base 'default') -Value $Major -NoNewline
        $up = [Environment]::GetEnvironmentVariable('Path','User'); if (-not $up) { $up = '' }
        $uparts = @($up -split ';' | Where-Object { $_ -ne '' -and $_ -notmatch '\\dev-kit\\jdk\\' })
        [Environment]::SetEnvironmentVariable('Path', ((@($binPath) + $uparts) -join ';'), 'User')
    }
    Write-Host "JAVA_HOME -> $jdkHome"
}
function Get-DevKitJdk {
    $base = Join-Path $env:LOCALAPPDATA 'dev-kit\jdk'
    if (-not (Test-Path $base)) { return }
    Get-ChildItem -Path $base -Directory | Where-Object { $_.Name -match '^\d+$' } | ForEach-Object {
        $rel = Join-Path $_.FullName 'release'; $ver = ''
        if (Test-Path $rel) { $l = Select-String -Path $rel -Pattern '^JAVA_VERSION=' | Select-Object -First 1; if ($l) { $ver = ($l.Line -replace 'JAVA_VERSION=','' -replace '"','') } }
        [PSCustomObject]@{ Major = $_.Name; Version = $ver; Home = $_.FullName }
    }
}
$__dkDefault = Join-Path $env:LOCALAPPDATA 'dev-kit\jdk\default'
if (Test-Path $__dkDefault) {
    $__dkMajor = (Get-Content -Raw $__dkDefault).Trim()
    $__dkHome = Join-Path (Join-Path $env:LOCALAPPDATA 'dev-kit\jdk') $__dkMajor
    if (Test-Path $__dkHome) { $env:JAVA_HOME = $__dkHome }
}
'@
    $fnmBlock = @'
if (Get-Command fnm -ErrorAction SilentlyContinue) {
    fnm env --use-on-cd --shell powershell | Out-String | Invoke-Expression
}
'@
    $content = $header
    if ($jdkInstalled) { $content += $jdkBlock + "`r`n" }
    if ($fnmInstalled) { $content += $fnmBlock + "`r`n" }
    Write-DevKitTextFile -Path $script:EnvFile -Content $content
}

function Get-DevKitProfilePath {
    $paths = @()
    $paths += (Join-Path (Join-Path $HOME 'Documents\WindowsPowerShell') 'profile.ps1')
    $paths += (Join-Path (Join-Path $HOME 'Documents\PowerShell') 'profile.ps1')
    try {
        $docs = [Environment]::GetFolderPath('MyDocuments')
        if ($docs) {
            $paths += (Join-Path (Join-Path $docs 'WindowsPowerShell') 'profile.ps1')
            $paths += (Join-Path (Join-Path $docs 'PowerShell') 'profile.ps1')
        }
    } catch { }
    return @($paths | Select-Object -Unique)
}

function Update-DevKitProfile {
    $block = 'if (Test-Path "$env:LOCALAPPDATA\dev-kit\env.ps1") { . "$env:LOCALAPPDATA\dev-kit\env.ps1" }'
    foreach ($p in Get-DevKitProfilePath) {
        try { Set-DevKitMarkerBlock -File $p -Content $block }
        catch { Write-DevKitWarn "could not update profile $p : $($_.Exception.Message)" }
    }
}

function Get-DevKitPathEntry {
    $entries = @()
    $binDir = Join-Path $script:DevKitHome 'bin'
    if (Test-Path (Join-Path $binDir 'fnm.exe')) { $entries += $binDir }
    $defFile = Join-Path $script:JdkDir 'default'
    if (Test-Path $defFile) {
        $m = (Get-Content -Raw $defFile).Trim()
        $jb = Join-Path (Join-Path $script:JdkDir $m) 'bin'
        if (Test-Path $jb) { $entries += $jb }
    }
    $goBin = Join-Path (Join-Path $script:DevKitHome 'go') 'bin'
    if (Test-Path $goBin) { $entries += $goBin; $entries += (Join-Path $env:USERPROFILE 'go\bin') }
    $cargoBin = Join-Path $script:CargoHome 'bin'
    if (Test-Path $cargoBin) { $entries += $cargoBin }
    $bunBin = Join-Path $script:BunInstall 'bin'
    if (Test-Path (Join-Path $bunBin 'bun.exe')) { $entries += $bunBin }
    if (Test-Path (Join-Path $script:PnpmHome 'pnpm.exe')) { $entries += $script:PnpmHome }
    $mvnRoot = Join-Path $script:DevKitHome 'maven'
    if (Test-Path $mvnRoot) { $d = @(Get-ChildItem $mvnRoot -Directory -ErrorAction SilentlyContinue) | Select-Object -First 1; if ($d) { $entries += (Join-Path $d.FullName 'bin') } }
    $gradleRoot = Join-Path $script:DevKitHome 'gradle'
    if (Test-Path $gradleRoot) { $d = @(Get-ChildItem $gradleRoot -Directory -ErrorAction SilentlyContinue) | Select-Object -First 1; if ($d) { $entries += (Join-Path $d.FullName 'bin') } }
    $gitCmd = Join-Path (Join-Path $script:DevKitHome 'git') 'cmd'
    if (Test-Path $gitCmd) { $entries += $gitCmd }
    return $entries
}

function Update-DevKitGithubEnv {
    param([string[]]$PathEntries)
    if ($env:GITHUB_ACTIONS -ne 'true') { return }
    if ($env:GITHUB_PATH) { foreach ($e in $PathEntries) { Add-Content -Path $env:GITHUB_PATH -Value $e } }
    if ($env:GITHUB_ENV) {
        $jh = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'User')
        if ($jh) { Add-Content -Path $env:GITHUB_ENV -Value "JAVA_HOME=$jh" }
        Add-Content -Path $env:GITHUB_ENV -Value "FNM_DIR=$script:FnmDir"
        Add-Content -Path $env:GITHUB_ENV -Value "BUN_INSTALL=$script:BunInstall"
        Add-Content -Path $env:GITHUB_ENV -Value "PNPM_HOME=$script:PnpmHome"
    }
}

# ----------------------------------------------------------------------------
# doctor
# ----------------------------------------------------------------------------
function Get-DevKitToolVersion {
    param([string]$Exe, [string[]]$VersionArgs)
    $cmd = Get-Command $Exe -ErrorAction SilentlyContinue
    if (-not $cmd) { return $null }
    try {
        $out = & $cmd.Source @VersionArgs 2>&1 | Select-Object -First 1
        return [PSCustomObject]@{ Version = ([string]$out).Trim(); Path = $cmd.Source }
    } catch {
        return [PSCustomObject]@{ Version = '(present)'; Path = $cmd.Source }
    }
}

function Show-DevKitDoctor {
    param([string[]]$Failed)
    Write-Host ''
    Write-DevKitStep 'doctor'
    $rows = @()
    $checks = @(
        @{ n = 'git';    e = 'git';    a = @('--version') },
        @{ n = 'java';   e = 'java';   a = @('-version') },
        @{ n = 'mvn';    e = 'mvn';    a = @('-v') },
        @{ n = 'gradle'; e = 'gradle'; a = @('-v') },
        @{ n = 'go';     e = 'go';     a = @('version') },
        @{ n = 'cargo';  e = 'cargo';  a = @('--version') },
        @{ n = 'node';   e = 'node';   a = @('-v') },
        @{ n = 'pnpm';   e = 'pnpm';   a = @('-v') },
        @{ n = 'bun';    e = 'bun';    a = @('--version') }
    )
    # make our tools visible in this session even before a new shell
    foreach ($e in (Get-DevKitPathEntry)) { if ($env:Path -notlike "*$e*") { $env:Path = "$e;$env:Path" } }
    if (Test-Path $script:EnvFile) { try { . $script:EnvFile } catch { } }

    foreach ($c in $checks) {
        $info = Get-DevKitToolVersion -Exe $c.e -VersionArgs $c.a
        if ($info) { $rows += [PSCustomObject]@{ Tool = $c.n; Version = $info.Version; Path = $info.Path } }
        else { $rows += [PSCustomObject]@{ Tool = $c.n; Version = '-'; Path = '-' } }
    }
    $rows | Format-Table -AutoSize | Out-String | Write-Host

    if (Test-Path $script:JdkDir) {
        $majors = @(Get-ChildItem $script:JdkDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+$' } | ForEach-Object { $_.Name })
        if ($majors.Count -gt 0) { Write-DevKitInfo "installed JDKs: $($majors -join ', ')  (switch with: Use-Jdk <major>)" }
    }
    if ($script:RustMsvcMissing) { Write-DevKitWarn 'MSVC C++ Build Tools missing: Rust compiles but linking will fail until you install them' }
    try {
        $ep = Get-ExecutionPolicy -Scope CurrentUser
        if ($ep -eq 'Restricted') { Write-DevKitWarn 'ExecutionPolicy is Restricted; run:  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned' }
    } catch { }
    if ($Failed.Count -gt 0) { Write-DevKitErr "failed: $($Failed -join ', ')" }
    Write-Host ''
    Write-DevKitOk 'done. Open a NEW PowerShell (or run:  . $PROFILE ) so PATH/JAVA_HOME take effect.'
}

# ----------------------------------------------------------------------------
# menu
# ----------------------------------------------------------------------------
function Show-DevKitMenu {
    param([switch]$ForUninstall)
    $installed = Get-DevKitInstalledComponent
    $chosen = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    # install: preselect already-installed; uninstall: start empty (removal is opt-in)
    if (-not $ForUninstall) { foreach ($c in $installed) { [void]$chosen.Add($c) } }

    while ($true) {
        Write-Host ''
        if ($ForUninstall) { Write-Host 'Select components to UNINSTALL (installed ones marked *):' -ForegroundColor Cyan }
        else { Write-Host 'Select components to install/update:' -ForegroundColor Cyan }
        for ($i = 0; $i -lt $script:AllComponents.Count; $i++) {
            $c = $script:AllComponents[$i]
            $mark = ' '
            if ($chosen.Contains($c)) { $mark = 'x' }
            $inst = ''
            if ($ForUninstall -and ($installed -contains $c)) { $inst = ' *' }
            Write-Host ("  {0,2}) [{1}] {2}{3}" -f ($i + 1), $mark, $c, $inst)
        }
        Write-Host '   a) select all    n) select none    Enter) confirm    q) quit'
        $line = Read-Host 'toggle number(s)'
        if ($null -eq $line) { break }
        $line = $line.Trim()
        if ($line -eq '') { break }
        if ($line -eq 'q') { Write-Host 'aborted.'; exit 0 }
        if ($line -eq 'a') { foreach ($c in $script:AllComponents) { [void]$chosen.Add($c) }; continue }
        if ($line -eq 'n') { $chosen.Clear(); continue }
        foreach ($tok in @($line -split '[,\s]+')) {
            if ($tok -match '^\d+$') {
                $idx = [int]$tok - 1
                if ($idx -ge 0 -and $idx -lt $script:AllComponents.Count) {
                    $c = $script:AllComponents[$idx]
                    if ($chosen.Contains($c)) { [void]$chosen.Remove($c) } else { [void]$chosen.Add($c) }
                }
            }
        }
    }
    $result = @()
    foreach ($c in $script:AllComponents) { if ($chosen.Contains($c)) { $result += $c } }
    return $result
}

function Get-DevKitInstalledComponent {
    $r = @()
    if (Get-Command git -ErrorAction SilentlyContinue) { $r += 'git' }
    if (Test-Path $script:JdkDir) { $r += 'jdk' }
    if (Test-Path (Join-Path $script:DevKitHome 'maven')) { $r += 'maven' }
    if (Test-Path (Join-Path $script:DevKitHome 'gradle')) { $r += 'gradle' }
    if (Test-Path (Join-Path $script:DevKitHome 'go\bin\go.exe')) { $r += 'go' }
    if (Test-Path (Join-Path $script:CargoHome 'bin\rustup.exe')) { $r += 'rust' }
    if (Test-Path (Join-Path $script:DevKitHome 'bin\fnm.exe')) { $r += 'node' }
    if (Test-Path (Join-Path $script:PnpmHome 'pnpm.exe')) { $r += 'pnpm' }
    if (Test-Path (Join-Path $script:BunInstall 'bin\bun.exe')) { $r += 'bun' }
    return $r
}

# ----------------------------------------------------------------------------
# uninstall
# ----------------------------------------------------------------------------
$script:Kept = @()

function Remove-DevKitPath {
    param([string[]]$Path)
    foreach ($p in $Path) {
        if ($p -and (Test-Path $p)) {
            Write-DevKitInfo "removing $p"
            try { Remove-Item -Recurse -Force -Path $p -ErrorAction Stop }
            catch { Write-DevKitWarn "could not remove $p : $($_.Exception.Message)" }
        }
    }
}
function Remove-DevKitCache {
    param([string[]]$Path)
    if ($KeepCache) { return }
    Remove-DevKitPath -Path $Path
}
function Add-DevKitKept {
    param([string]$Path, [string]$Why)
    if (Test-Path $Path) { $script:Kept += "$Path  ($Why)" }
}
function Remove-DevKitNpmMirror {
    $npmrc = Join-Path $env:USERPROFILE '.npmrc'
    if (Test-Path $npmrc) { Remove-DevKitMarkerBlock -File $npmrc }
}

function Uninstall-DevKitGit {
    if (Get-DevKitHasWinget) {
        & winget list --id Git.Git -e 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-DevKitInfo 'winget uninstall Git.Git'
            try { & winget uninstall --id Git.Git -e --silent 2>$null | Out-Null } catch { }
        }
    }
    Remove-DevKitPath (Join-Path $script:DevKitHome 'git')
    Add-DevKitKept (Join-Path $env:USERPROFILE '.gitconfig') 'your git config'
}
function Uninstall-DevKitJdk {
    Remove-DevKitPath $script:JdkDir
    Remove-DevKitUserEnv 'JAVA_HOME'
}
function Uninstall-DevKitMaven {
    Remove-DevKitPath (Join-Path $script:DevKitHome 'maven')
    Remove-DevKitCache (Join-Path $env:USERPROFILE '.m2\repository')
    Add-DevKitKept (Join-Path $env:USERPROFILE '.m2\settings.xml') 'your Maven settings'
}
function Uninstall-DevKitGradle {
    Remove-DevKitPath (Join-Path $script:DevKitHome 'gradle')
    $g = Join-Path $env:USERPROFILE '.gradle'
    Remove-DevKitCache @((Join-Path $g 'caches'), (Join-Path $g 'wrapper'), (Join-Path $g 'daemon'))
    Add-DevKitKept (Join-Path $g 'gradle.properties') 'your Gradle properties'
}
function Uninstall-DevKitGo {
    Remove-DevKitPath (Join-Path $script:DevKitHome 'go')
    $gocache = $env:GOCACHE; if (-not $gocache) { $gocache = Join-Path $env:LOCALAPPDATA 'go-build' }
    $gopath = $env:GOPATH; if (-not $gopath) { $gopath = Join-Path $env:USERPROFILE 'go' }
    Remove-DevKitCache @($gocache, (Join-Path $gopath 'pkg'))
    $goenv = Join-Path $env:APPDATA 'go\env'
    if (Test-Path $goenv) {
        $lines = @(Get-Content -Path $goenv | Where-Object { $_ -notmatch 'goproxy\.cn' })
        [IO.File]::WriteAllText($goenv, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    }
    Add-DevKitKept (Join-Path $gopath 'bin') "tools you installed with 'go install'"
}
function Uninstall-DevKitRust {
    $rustup = Join-Path $script:CargoHome 'bin\rustup.exe'
    if (Test-Path $rustup) {
        Write-DevKitInfo 'rustup self uninstall'
        try { & $rustup self uninstall -y | Out-Null } catch { }
    }
    Remove-DevKitPath @($script:CargoHome, (Join-Path $env:USERPROFILE '.rustup'))
    Remove-DevKitUserEnv 'RUSTUP_DIST_SERVER'
    Remove-DevKitUserEnv 'RUSTUP_UPDATE_ROOT'
}
function Uninstall-DevKitNode {
    Remove-DevKitPath @((Join-Path $script:DevKitHome 'bin\fnm.exe'), $script:FnmDir)
    Remove-DevKitCache @((Join-Path $env:APPDATA 'npm-cache'), (Join-Path $env:LOCALAPPDATA 'npm-cache'))
    Remove-DevKitUserEnv 'FNM_DIR'
    Remove-DevKitUserEnv 'FNM_NODE_DIST_MIRROR'
    Remove-DevKitNpmMirror
    Add-DevKitKept (Join-Path $env:USERPROFILE '.npmrc') 'your npm config'
}
function Uninstall-DevKitPnpm {
    Remove-DevKitPath $script:PnpmHome
    Remove-DevKitCache @((Join-Path $env:LOCALAPPDATA 'pnpm-cache'), (Join-Path $env:LOCALAPPDATA 'pnpm-store'))
    Remove-DevKitUserEnv 'PNPM_HOME'
    Remove-DevKitNpmMirror
}
function Uninstall-DevKitBun {
    Remove-DevKitPath $script:BunInstall
    Remove-DevKitUserEnv 'BUN_INSTALL'
}

function Remove-DevKitFromUserPath {
    param([string[]]$Extra)
    $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $cur) { $cur = '' }
    $drop = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $Extra) { if ($e) { [void]$drop.Add($e) } }
    $kept = @()
    foreach ($p in @($cur -split ';' | Where-Object { $_ -ne '' })) {
        if ($p -match '\\dev-kit\\') { continue }
        if ($drop.Contains($p)) { continue }
        $kept += $p
    }
    [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
    Send-DevKitSettingChange
}

function Complete-DevKitUninstall {
    $extra = @(
        (Join-Path $script:CargoHome 'bin'),
        (Join-Path $script:BunInstall 'bin'),
        $script:PnpmHome,
        (Join-Path $env:USERPROFILE 'go\bin')
    )
    Remove-DevKitFromUserPath -Extra $extra
    # git is a system/winget package that need not keep dev-kit config alive
    $remaining = @(Get-DevKitInstalledComponent | Where-Object { $_ -ne 'git' })
    if ($remaining.Count -eq 0) {
        foreach ($v in @('DEVKIT_HOME', 'JAVA_HOME', 'FNM_DIR', 'FNM_NODE_DIST_MIRROR', 'BUN_INSTALL', 'PNPM_HOME', 'RUSTUP_DIST_SERVER', 'RUSTUP_UPDATE_ROOT')) {
            Remove-DevKitUserEnv $v
        }
        foreach ($p in Get-DevKitProfilePath) { Remove-DevKitMarkerBlock -File $p }
        Remove-DevKitPath $script:DevKitHome
        Write-DevKitOk 'dev-kit fully removed'
    } else {
        Set-DevKitUserPath -Prepend (Get-DevKitPathEntry)
        Write-DevKitEnvFile
        Write-DevKitInfo "still installed: $($remaining -join ', ')"
    }
}

function Invoke-DevKitUninstall {
    param([string[]]$Components)
    if (-not $Yes -and -not $script:WizConfirmed) {
        Write-Host ''
        Write-Host "About to UNINSTALL: $($Components -join ', ')" -ForegroundColor Yellow
        if ($KeepCache) { Write-Host 'Removes the toolchains and dev-kit config (caches kept).' }
        else { Write-Host 'Removes the toolchains, their caches, and dev-kit config.' }
        Write-Host 'User files (git/maven/gradle/npm config) are kept.'
        $ans = Read-Host 'Proceed? [y/N]'
        if ($ans -notmatch '^(y|yes)$') { Write-Host 'aborted.'; exit 0 }
    }
    $failed = @()
    foreach ($c in $script:AllComponents) {
        if ($Components -notcontains $c) { continue }
        Write-DevKitStep "uninstalling: $c"
        try {
            switch ($c) {
                'git'    { Uninstall-DevKitGit }
                'jdk'    { Uninstall-DevKitJdk }
                'maven'  { Uninstall-DevKitMaven }
                'gradle' { Uninstall-DevKitGradle }
                'go'     { Uninstall-DevKitGo }
                'rust'   { Uninstall-DevKitRust }
                'node'   { Uninstall-DevKitNode }
                'pnpm'   { Uninstall-DevKitPnpm }
                'bun'    { Uninstall-DevKitBun }
            }
            Write-DevKitOk $c
        } catch {
            $failed += $c
            Write-DevKitErr "$c failed: $($_.Exception.Message)"
        }
    }
    Complete-DevKitUninstall
    Write-Host ''
    Write-DevKitStep 'uninstall summary'
    if ($failed.Count -gt 0) { Write-DevKitWarn "issues with: $($failed -join ', ')" }
    if ($script:Kept.Count -gt 0) {
        Write-DevKitInfo 'kept (delete yourself if you want them gone):'
        foreach ($k in $script:Kept) { Write-DevKitInfo "  $k" }
    }
    Write-DevKitInfo 'open a new terminal so removed tools leave your PATH'
    if ($failed.Count -gt 0) { exit 2 }
    exit 0
}

# ----------------------------------------------------------------------------
# i18n - interactive UI strings only (progress output stays English)
#
# The Chinese strings are stored as \uXXXX escapes so this file stays pure
# ASCII: Windows PowerShell 5.1 reads a BOM-less script with the ANSI code
# page (which would mangle UTF-8 text), and adding a BOM would break
# `irm ... | iex`. The readable text is in the comment above each entry.
# ----------------------------------------------------------------------------
$script:TextZh = @{
    # 选择要执行的操作
    'mode.title'   = '\u9009\u62e9\u8981\u6267\u884c\u7684\u64cd\u4f5c'
    # 安装 / 更新组件
    'mode.install' = '\u5b89\u88c5 / \u66f4\u65b0\u7ec4\u4ef6'
    # 卸载组件
    'mode.uninst'  = '\u5378\u8f7d\u7ec4\u4ef6'
    # 退出
    'mode.quit'    = '\u9000\u51fa'
    # 勾选要安装 / 更新的组件
    'pick.install' = '\u52fe\u9009\u8981\u5b89\u88c5 / \u66f4\u65b0\u7684\u7ec4\u4ef6'
    # 勾选要卸载的组件（* = 已安装）
    'pick.uninst'  = '\u52fe\u9009\u8981\u5378\u8f7d\u7684\u7ec4\u4ef6\uff08* = \u5df2\u5b89\u88c5\uff09'
    # 安装选项
    'opts.title'   = '\u5b89\u88c5\u9009\u9879'
    # 卸载选项
    'opts.titleu'  = '\u5378\u8f7d\u9009\u9879'
    # ↑/↓ 移动   空格 勾选   回车 确认
    'hint.chk1'    = '\u2191/\u2193 \u79fb\u52a8   \u7a7a\u683c \u52fe\u9009   \u56de\u8f66 \u786e\u8ba4'
    # a 全选   n 全不选   i 反选   q 退出
    'hint.chk2'    = 'a \u5168\u9009   n \u5168\u4e0d\u9009   i \u53cd\u9009   q \u9000\u51fa'
    # ↑/↓ 移动   回车 选择   q 退出
    'hint.menu1'   = '\u2191/\u2193 \u79fb\u52a8   \u56de\u8f66 \u9009\u62e9   q \u9000\u51fa'
    # 输入后回车；留空用默认值
    'hint.input'   = '\u8f93\u5165\u540e\u56de\u8f66\uff1b\u7559\u7a7a\u7528\u9ed8\u8ba4\u503c'
    # JDK 主版本
    'lbl.jdk'      = 'JDK \u4e3b\u7248\u672c'
    # Go 版本
    'lbl.go'       = 'Go \u7248\u672c'
    # Rust 工具链
    'lbl.rust'     = 'Rust \u5de5\u5177\u94fe'
    # Node 版本
    'lbl.node'     = 'Node \u7248\u672c'
    # 镜像源
    'lbl.mirror'   = '\u955c\u50cf\u6e90'
    # 写入 PowerShell 配置
    'lbl.shell'    = '\u5199\u5165 PowerShell \u914d\u7f6e'
    # 保留缓存
    'lbl.cache'    = '\u4fdd\u7559\u7f13\u5b58'
    # 开始安装
    'act.start'    = '\u5f00\u59cb\u5b89\u88c5'
    # 开始卸载
    'act.startu'   = '\u5f00\u59cb\u5378\u8f7d'
    # 返回上一步
    'act.back'     = '\u8fd4\u56de\u4e0a\u4e00\u6b65'
    # 最新版
    'val.latest'   = '\u6700\u65b0\u7248'
    # 最新 LTS
    'val.lts'      = '\u6700\u65b0 LTS'
    # 手动输入…
    'val.custom'   = '\u624b\u52a8\u8f93\u5165\u2026'
    # 默认
    'val.default'  = '\u9ed8\u8ba4'
    # 是
    'val.yes'      = '\u662f'
    # 否
    'val.no'       = '\u5426'
    # auto — 探测网络后自动选择
    'val.auto'     = 'auto \u2014 \u63a2\u6d4b\u7f51\u7edc\u540e\u81ea\u52a8\u9009\u62e9'
    # cn — 使用国内镜像
    'val.cn'       = 'cn \u2014 \u4f7f\u7528\u56fd\u5185\u955c\u50cf'
    # off — 只用官方源
    'val.off'      = 'off \u2014 \u53ea\u7528\u5b98\u65b9\u6e90'
    # Go 版本号，例如 1.27.1
    'in.go'        = 'Go \u7248\u672c\u53f7\uff0c\u4f8b\u5982 1.27.1'
    # Rust 版本号，例如 1.90.0
    'in.rust'      = 'Rust \u7248\u672c\u53f7\uff0c\u4f8b\u5982 1.90.0'
    # Node 主版本号，例如 24
    'in.node'      = 'Node \u4e3b\u7248\u672c\u53f7\uff0c\u4f8b\u5982 24'
    # 即将安装 / 更新：
    'sum.install'  = '\u5373\u5c06\u5b89\u88c5 / \u66f4\u65b0\uff1a'
    # 即将卸载：
    'sum.uninst'   = '\u5373\u5c06\u5378\u8f7d\uff1a'
    # 将删除工具链、缓存和 dev-kit 自身的配置
    'sum.u1'       = '\u5c06\u5220\u9664\u5de5\u5177\u94fe\u3001\u7f13\u5b58\u548c dev-kit \u81ea\u8eab\u7684\u914d\u7f6e'
    # 将删除工具链和 dev-kit 自身的配置（保留缓存）
    'sum.u1k'      = '\u5c06\u5220\u9664\u5de5\u5177\u94fe\u548c dev-kit \u81ea\u8eab\u7684\u914d\u7f6e\uff08\u4fdd\u7559\u7f13\u5b58\uff09'
    # 你自己写的配置文件不会被删除
    'sum.u2'       = '\u4f60\u81ea\u5df1\u5199\u7684\u914d\u7f6e\u6587\u4ef6\u4e0d\u4f1a\u88ab\u5220\u9664'
    # 确认执行？
    'sum.ask'      = '\u786e\u8ba4\u6267\u884c\uff1f'
    # 已取消
    'msg.cancel'   = '\u5df2\u53d6\u6d88'
    # 没有勾选任何组件
    'msg.none'     = '\u6ca1\u6709\u52fe\u9009\u4efb\u4f55\u7ec4\u4ef6'
    # 当前没有由 dev-kit 安装的组件
    'msg.noinst'   = '\u5f53\u524d\u6ca1\u6709\u7531 dev-kit \u5b89\u88c5\u7684\u7ec4\u4ef6'
    # 正在获取可用版本…
    'msg.loading'  = '\u6b63\u5728\u83b7\u53d6\u53ef\u7528\u7248\u672c\u2026'
    # 格式不对，请重新输入
    'msg.badver'   = '\u683c\u5f0f\u4e0d\u5bf9\uff0c\u8bf7\u91cd\u65b0\u8f93\u5165'
    'desc.git'     = 'Git'
    # JDK（Temurin）
    'desc.jdk'     = 'JDK\uff08Temurin\uff09'
    'desc.maven'   = 'Apache Maven'
    'desc.gradle'  = 'Gradle'
    'desc.go'      = 'Go'
    # Rust（rustup）
    'desc.rust'    = 'Rust\uff08rustup\uff09'
    # Node.js（经 fnm）
    'desc.node'    = 'Node.js\uff08\u7ecf fnm\uff09'
    'desc.pnpm'    = 'pnpm'
    'desc.bun'     = 'Bun'
}

$script:TextEn = @{
    'mode.title'   = 'what would you like to do?'
    'mode.install' = 'install / update components'
    'mode.uninst'  = 'uninstall components'
    'mode.quit'    = 'quit'
    'pick.install' = 'select components to install / update'
    'pick.uninst'  = 'select components to uninstall (* = installed)'
    'opts.title'   = 'install options'
    'opts.titleu'  = 'uninstall options'
    'hint.chk1'    = 'up/down move   space toggle   enter confirm'
    'hint.chk2'    = 'a all   n none   i invert   q quit'
    'hint.menu1'   = 'up/down move   enter select   q quit'
    'hint.input'   = 'type and press enter; empty keeps the default'
    'lbl.jdk'      = 'JDK majors'
    'lbl.go'       = 'Go version'
    'lbl.rust'     = 'Rust toolchain'
    'lbl.node'     = 'Node version'
    'lbl.mirror'   = 'mirrors'
    'lbl.shell'    = 'write the PowerShell profile'
    'lbl.cache'    = 'keep caches'
    'act.start'    = 'start install'
    'act.startu'   = 'start uninstall'
    'act.back'     = 'back'
    'val.latest'   = 'latest'
    'val.lts'      = 'latest LTS'
    'val.custom'   = 'enter manually...'
    'val.default'  = 'default'
    'val.yes'      = 'yes'
    'val.no'       = 'no'
    'val.auto'     = 'auto - probe the network'
    'val.cn'       = 'cn - China mirrors'
    'val.off'      = 'off - upstream only'
    'in.go'        = 'Go version, e.g. 1.27.1'
    'in.rust'      = 'Rust version, e.g. 1.90.0'
    'in.node'      = 'Node major, e.g. 24'
    'sum.install'  = 'about to install / update: '
    'sum.uninst'   = 'about to uninstall: '
    'sum.u1'       = 'removes the toolchains, their caches and dev-kit config'
    'sum.u1k'      = 'removes the toolchains and dev-kit config (caches kept)'
    'sum.u2'       = 'your own config files are kept'
    'sum.ask'      = 'proceed?'
    'msg.cancel'   = 'cancelled'
    'msg.none'     = 'nothing selected'
    'msg.noinst'   = 'nothing installed by dev-kit'
    'msg.loading'  = 'fetching available versions...'
    'msg.badver'   = 'invalid version, try again'
    'desc.git'     = 'Git'
    'desc.jdk'     = 'JDK (Temurin)'
    'desc.maven'   = 'Apache Maven'
    'desc.gradle'  = 'Gradle'
    'desc.go'      = 'Go'
    'desc.rust'    = 'Rust (rustup)'
    'desc.node'    = 'Node.js (via fnm)'
    'desc.pnpm'    = 'pnpm'
    'desc.bun'     = 'Bun'
}

$script:UiLang = 'en'   # separate from the -Lang parameter, which is script-scoped too
$script:UiCursor = '>'
$script:UiGo = '> '
$script:UiBack = '< '
$script:UiDot = '*'
$script:UiTop = 0
$script:UiNote = @()
$script:UiEncoding = $null
$script:WizSelected = $null
$script:WizInstalled = @()
$script:WizJdk = @()
$script:WizConfirmed = $false

function Expand-DevKitEscape {
    param([string]$Text)
    if ($Text -notmatch '\\u') { return $Text }
    return [regex]::Replace($Text, '\\u([0-9a-fA-F]{4})', {
            param($m) [string][char][Convert]::ToInt32($m.Groups[1].Value, 16) })
}

function Get-DevKitText {
    param([string]$Key)
    if ($script:UiLang -eq 'zh' -and $script:TextZh.ContainsKey($Key)) {
        return (Expand-DevKitEscape $script:TextZh[$Key])
    }
    if ($script:TextEn.ContainsKey($Key)) { return $script:TextEn[$Key] }
    return $Key
}

function Get-DevKitComponentDesc {
    param([string]$Name)
    return (Get-DevKitText "desc.$Name")
}

function Initialize-DevKitLang {
    $want = $Lang
    if (-not $want) { $want = $env:DEVKIT_LANG }
    if ($want) {
        if ($want -match '^(zh|cn)') { $script:UiLang = 'zh' } else { $script:UiLang = 'en' }
    } else {
        $culture = ''
        try { $culture = [System.Globalization.CultureInfo]::CurrentUICulture.Name } catch { $culture = '' }
        if ($culture -like 'zh*') { $script:UiLang = 'zh' } else { $script:UiLang = 'en' }
    }
    # the box-drawing marks and any Chinese need a UTF-8 console
    $utf8 = $false
    try {
        $script:UiEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
        $utf8 = $true
    } catch { $utf8 = $false }
    if ($utf8) {
        $script:UiCursor = Expand-DevKitEscape '\u25b8'
        $script:UiGo     = (Expand-DevKitEscape '\u25b6') + ' '
        $script:UiBack   = (Expand-DevKitEscape '\u2190') + ' '
        $script:UiDot    = Expand-DevKitEscape '\u25cf'
    } elseif ($script:UiLang -eq 'zh') {
        $script:UiLang = 'en'
    }
}

function Restore-DevKitConsole {
    if ($null -ne $script:UiEncoding) {
        try { [Console]::OutputEncoding = $script:UiEncoding } catch { }
        $script:UiEncoding = $null
    }
    try { [Console]::CursorVisible = $true } catch { }
}

# ----------------------------------------------------------------------------
# terminal UI: arrow keys + checkboxes
# ----------------------------------------------------------------------------
function Test-DevKitTui {
    if ($NoTui) { return $false }
    if ($env:DEVKIT_NO_TUI -eq '1') { return $false }
    if (-not [Environment]::UserInteractive) { return $false }
    try {
        if ([Console]::IsInputRedirected) { return $false }
        if ([Console]::WindowWidth -lt 44) { return $false }
    } catch { return $false }
    return $true
}

# CJK glyphs take two columns; PadRight counts one, so measure it properly
function Get-DevKitDisplayWidth {
    param([string]$Text)
    $n = 0
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int][char]$ch
        if (($c -ge 0x1100 -and $c -le 0x115F) -or ($c -ge 0x2E80 -and $c -le 0xA4CF) -or
            ($c -ge 0xAC00 -and $c -le 0xD7A3) -or ($c -ge 0xF900 -and $c -le 0xFAFF) -or
            ($c -ge 0xFE30 -and $c -le 0xFE6F) -or ($c -ge 0xFF00 -and $c -le 0xFF60) -or
            ($c -ge 0xFFE0 -and $c -le 0xFFE6)) { $n += 2 } else { $n += 1 }
    }
    return $n
}

function Get-DevKitFrameWidth {
    $w = 80
    try { $w = [Console]::WindowWidth - 1 } catch { $w = 80 }
    if ($w -lt 20) { $w = 20 }
    return $w
}

# $Line: array of @{ T = text; C = colour name or '' }
function Show-DevKitFrame {
    param([object[]]$Line)
    $w = Get-DevKitFrameWidth
    try { [Console]::SetCursorPosition(0, $script:UiTop) } catch { }
    foreach ($l in $Line) {
        $t = [string]$l.T
        $pad = $w - (Get-DevKitDisplayWidth $t)
        if ($pad -gt 0) { $t = $t + (' ' * $pad) }
        if ($l.C) { Write-Host $t -ForegroundColor $l.C } else { Write-Host $t }
    }
    try {
        $script:UiTop = [Console]::CursorTop - $Line.Count
        if ($script:UiTop -lt 0) { $script:UiTop = 0 }
    } catch { }
}

function Clear-DevKitFrame {
    param([int]$Count)
    $w = Get-DevKitFrameWidth
    try {
        [Console]::SetCursorPosition(0, $script:UiTop)
        for ($i = 0; $i -lt $Count; $i++) { Write-Host (' ' * $w) }
        [Console]::SetCursorPosition(0, $script:UiTop)
    } catch { }
}

function Get-DevKitHeaderLine {
    param([string]$Title)
    $out = @()
    $out += @{ T = ''; C = '' }
    $out += @{ T = "  dev-kit $script:DevKitVersion  $Title"; C = 'Cyan' }
    $out += @{ T = ''; C = '' }
    foreach ($n in $script:UiNote) { $out += @{ T = $n; C = 'Yellow' } }
    if ($script:UiNote.Count -gt 0) { $out += @{ T = ''; C = '' } }
    return $out
}

function Get-DevKitFooterLine {
    param([string[]]$Hint)
    $out = @()
    $out += @{ T = ''; C = '' }
    foreach ($h in $Hint) { $out += @{ T = "  $h"; C = 'DarkGray' } }
    return $out
}

function Read-DevKitKey {
    $k = $null
    try { $k = [Console]::ReadKey($true) } catch { return 'quit' }
    switch ($k.Key) {
        'UpArrow'   { return 'up' }
        'DownArrow' { return 'down' }
        'Enter'     { return 'enter' }
        'Spacebar'  { return 'space' }
        'Escape'    { return 'quit' }
    }
    $c = "$($k.KeyChar)".ToLower()
    if ($c -match '^[1-9]$') { return "digit:$c" }
    switch ($c) {
        'k' { return 'up' }
        'j' { return 'down' }
        'a' { return 'all' }
        'n' { return 'none' }
        'i' { return 'invert' }
        'q' { return 'quit' }
    }
    return 'other'
}

# returns the ticked items, or $null when the user backs out
function Show-DevKitChecklist {
    param(
        [string]$Title,
        [string[]]$Item,
        [string[]]$Selected,
        [scriptblock]$LabelFn,
        [scriptblock]$MarkFn
    )
    if ($Item.Count -eq 0) { return ,@() }
    $sel = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($s in $Selected) { [void]$sel.Add($s) }
    $cur = 0
    $count = 0
    try { [Console]::CursorVisible = $false } catch { }
    $script:UiTop = 0
    try { $script:UiTop = [Console]::CursorTop } catch { }
    while ($true) {
        $lines = Get-DevKitHeaderLine $Title
        for ($i = 0; $i -lt $Item.Count; $i++) {
            $c = $Item[$i]
            $box = ' '
            if ($sel.Contains($c)) { $box = 'x' }
            $ptr = ' '
            if ($i -eq $cur) { $ptr = $script:UiCursor }
            $mark = '  '
            if ($MarkFn) { $mark = [string](& $MarkFn $c) }
            $label = ''
            if ($LabelFn) { $label = [string](& $LabelFn $c) }
            $row = '  {0} [{1}] {2} {3}{4}' -f $ptr, $box, $c.PadRight(7), $mark, $label
            if ($i -eq $cur) { $lines += @{ T = $row; C = 'Green' } } else { $lines += @{ T = $row; C = '' } }
        }
        $lines += Get-DevKitFooterLine @((Get-DevKitText 'hint.chk1'), (Get-DevKitText 'hint.chk2'))
        $count = $lines.Count
        Show-DevKitFrame $lines
        $key = Read-DevKitKey
        switch -Regex ($key) {
            '^up$'     { $cur--; if ($cur -lt 0) { $cur = $Item.Count - 1 } }
            '^down$'   { $cur++; if ($cur -ge $Item.Count) { $cur = 0 } }
            '^space$'  { $c = $Item[$cur]; if ($sel.Contains($c)) { [void]$sel.Remove($c) } else { [void]$sel.Add($c) } }
            '^digit:'  {
                $n = [int]($key -replace '^digit:', '') - 1
                if ($n -ge 0 -and $n -lt $Item.Count) {
                    $c = $Item[$n]
                    if ($sel.Contains($c)) { [void]$sel.Remove($c) } else { [void]$sel.Add($c) }
                }
            }
            '^all$'    { foreach ($c in $Item) { [void]$sel.Add($c) } }
            '^none$'   { $sel.Clear() }
            '^invert$' {
                $keep = @($Item | Where-Object { -not $sel.Contains($_) })
                $sel.Clear()
                foreach ($c in $keep) { [void]$sel.Add($c) }
            }
            '^enter$'  {
                Clear-DevKitFrame $count
                return ,@($Item | Where-Object { $sel.Contains($_) })
            }
            '^quit$'   { Clear-DevKitFrame $count; return $null }
        }
    }
}

# returns the chosen item, or $null when the user backs out
function Show-DevKitChoice {
    param(
        [string]$Title,
        [string[]]$Item,
        [string]$Marked,
        [string]$Cursor,
        [scriptblock]$LabelFn
    )
    if ($Item.Count -eq 0) { return $null }
    $cur = 0
    for ($i = 0; $i -lt $Item.Count; $i++) { if ($Item[$i] -eq $Cursor) { $cur = $i } }
    $count = 0
    try { [Console]::CursorVisible = $false } catch { }
    $script:UiTop = 0
    try { $script:UiTop = [Console]::CursorTop } catch { }
    while ($true) {
        $lines = Get-DevKitHeaderLine $Title
        for ($i = 0; $i -lt $Item.Count; $i++) {
            $ptr = ' '
            if ($i -eq $cur) { $ptr = $script:UiCursor }
            $dot = ' '
            if ($Marked -and $Item[$i] -eq $Marked) { $dot = $script:UiDot }
            $label = $Item[$i]
            if ($LabelFn) { $label = [string](& $LabelFn $Item[$i]) }
            $row = '  {0} {1} {2}' -f $ptr, $dot, $label
            if ($i -eq $cur) { $lines += @{ T = $row; C = 'Green' } } else { $lines += @{ T = $row; C = '' } }
        }
        $lines += Get-DevKitFooterLine @((Get-DevKitText 'hint.menu1'))
        $count = $lines.Count
        Show-DevKitFrame $lines
        $key = Read-DevKitKey
        switch -Regex ($key) {
            '^up$'    { $cur--; if ($cur -lt 0) { $cur = $Item.Count - 1 } }
            '^down$'  { $cur++; if ($cur -ge $Item.Count) { $cur = 0 } }
            '^digit:' {
                $n = [int]($key -replace '^digit:', '') - 1
                if ($n -ge 0 -and $n -lt $Item.Count) { $cur = $n }
            }
            '^(enter|space)$' { Clear-DevKitFrame $count; return $Item[$cur] }
            '^quit$'  { Clear-DevKitFrame $count; return $null }
        }
    }
}

# free-text entry; '' means "keep the default"
function Read-DevKitLine {
    param([string]$Title, [string]$Default)
    $lines = Get-DevKitHeaderLine $Title
    if ($Default) { $lines += @{ T = "  $(Get-DevKitText 'val.default'): $Default"; C = 'DarkGray' } }
    $lines += Get-DevKitFooterLine @((Get-DevKitText 'hint.input'))
    Show-DevKitFrame $lines
    try { [Console]::CursorVisible = $true } catch { }
    $answer = Read-Host '  >'
    try { [Console]::CursorVisible = $false } catch { }
    Clear-DevKitFrame ($lines.Count + 1)
    if ($null -eq $answer) { return '' }
    return $answer.Trim()
}

# $true / $false, or $null when the user backs out
function Show-DevKitYesNo {
    param([string]$Title, [bool]$Default)
    $want = 'no'
    if ($Default) { $want = 'yes' }
    $pick = Show-DevKitChoice -Title $Title -Item @('yes', 'no') -Marked $want -Cursor $want `
        -LabelFn { param($x) if ($x -eq 'yes') { Get-DevKitText 'val.yes' } else { Get-DevKitText 'val.no' } }
    if ($null -eq $pick) { return $null }
    return ($pick -eq 'yes')
}

# ----------------------------------------------------------------------------
# interactive wizard: mode -> components -> options -> run
# ----------------------------------------------------------------------------
function Get-DevKitAvailableJdkMajor {
    try {
        $info = Get-DevKitJson 'https://api.adoptium.net/v3/info/available_releases'
        return @($info.available_releases | ForEach-Object { [int]$_ } | Where-Object { $_ -ge 21 } | Sort-Object)
    } catch { return @(21, 25, 26) }
}

function Get-DevKitWizardOptionItem {
    if ($Uninstall) { return @('cache', 'startu', 'back') }
    $items = @()
    foreach ($c in @('jdk', 'go', 'rust', 'node')) {
        if ($script:WizSelected -contains $c) { $items += $c }
    }
    return @($items + @('mirror', 'shell', 'start', 'back'))
}

function Get-DevKitWizardOptionLabel {
    param([string]$Key)
    switch ($Key) {
        'jdk'    { return "$(Get-DevKitText 'lbl.jdk'): $($script:WizJdk -join ' ')" }
        'go'     { $v = $GoVersion; if (-not $v) { $v = Get-DevKitText 'val.latest' }
                   return "$(Get-DevKitText 'lbl.go'): $v" }
        'rust'   { $v = $RustVersion; if (-not $v) { $v = 'stable' }
                   return "$(Get-DevKitText 'lbl.rust'): $v" }
        'node'   { $v = $NodeVersion; if (-not $v) { $v = Get-DevKitText 'val.lts' }
                   return "$(Get-DevKitText 'lbl.node'): $v" }
        'mirror' { return "$(Get-DevKitText 'lbl.mirror'): $Mirror" }
        'shell'  { $v = Get-DevKitText 'val.yes'; if ($NoShellInit) { $v = Get-DevKitText 'val.no' }
                   return "$(Get-DevKitText 'lbl.shell'): $v" }
        'cache'  { $v = Get-DevKitText 'val.no'; if ($KeepCache) { $v = Get-DevKitText 'val.yes' }
                   return "$(Get-DevKitText 'lbl.cache'): $v" }
        'start'  { return "$script:UiGo$(Get-DevKitText 'act.start')" }
        'startu' { return "$script:UiGo$(Get-DevKitText 'act.startu')" }
        'back'   { return "$script:UiBack$(Get-DevKitText 'act.back')" }
    }
    return $Key
}

function Get-DevKitWizardChoiceLabel {
    param([string]$Key)
    switch ($Key) {
        'latest' { return (Get-DevKitText 'val.latest') }
        'lts'    { return (Get-DevKitText 'val.lts') }
        'custom' { return (Get-DevKitText 'val.custom') }
        'auto'   { return (Get-DevKitText 'val.auto') }
        'cn'     { return (Get-DevKitText 'val.cn') }
        'off'    { return (Get-DevKitText 'val.off') }
    }
    return $Key
}

function Read-DevKitWizardVersion {
    param([string]$PromptKey, [string]$Current, [string]$Pattern)
    $title = Get-DevKitText $PromptKey
    while ($true) {
        $answer = Read-DevKitLine -Title $title -Default $Current
        if (-not $answer) { return '' }
        if ($answer -match $Pattern) { return $answer }
        $title = "$(Get-DevKitText $PromptKey)   $(Get-DevKitText 'msg.badver')"
    }
}

function Invoke-DevKitWizardOption {
    param([string]$Key)
    switch ($Key) {
        'jdk' {
            Show-DevKitFrame @(@{ T = "  $(Get-DevKitText 'msg.loading')"; C = 'DarkGray' })
            $avail = @(Get-DevKitAvailableJdkMajor | ForEach-Object { [string]$_ })
            Clear-DevKitFrame 1
            $pick = Show-DevKitChecklist -Title (Get-DevKitText 'lbl.jdk') -Item $avail `
                -Selected @($script:WizJdk) -LabelFn { param($x) $null = $x; '' } -MarkFn $null
            if ($null -ne $pick -and @($pick).Count -gt 0) { $script:WizJdk = @($pick) }
        }
        'go' {
            $marked = 'latest'
            if ($GoVersion) { $marked = 'custom' }
            $pick = Show-DevKitChoice -Title (Get-DevKitText 'lbl.go') -Item @('latest', 'custom') `
                -Marked $marked -Cursor $marked -LabelFn ${function:Get-DevKitWizardChoiceLabel}
            if ($pick -eq 'latest') { $script:GoVersion = '' }
            elseif ($pick -eq 'custom') {
                $v = Read-DevKitWizardVersion -PromptKey 'in.go' -Current $GoVersion -Pattern '^\d+\.\d+(\.\d+)?$'
                if ($v) { $script:GoVersion = $v }
            }
        }
        'rust' {
            $marked = 'custom'
            if (-not $RustVersion) { $marked = 'stable' }
            elseif (@('stable', 'beta', 'nightly') -contains $RustVersion) { $marked = $RustVersion }
            $pick = Show-DevKitChoice -Title (Get-DevKitText 'lbl.rust') `
                -Item @('stable', 'beta', 'nightly', 'custom') -Marked $marked -Cursor $marked `
                -LabelFn ${function:Get-DevKitWizardChoiceLabel}
            if ($pick -eq 'stable') { $script:RustVersion = '' }
            elseif ($pick -eq 'custom') {
                $v = Read-DevKitWizardVersion -PromptKey 'in.rust' -Current $RustVersion -Pattern '^\d+\.\d+(\.\d+)?$'
                if ($v) { $script:RustVersion = $v }
            } elseif ($pick) { $script:RustVersion = $pick }
        }
        'node' {
            $marked = 'lts'
            if ($NodeVersion -and $NodeVersion -ne 'lts') { $marked = 'custom' }
            $pick = Show-DevKitChoice -Title (Get-DevKitText 'lbl.node') -Item @('lts', 'custom') `
                -Marked $marked -Cursor $marked -LabelFn ${function:Get-DevKitWizardChoiceLabel}
            if ($pick -eq 'lts') { $script:NodeVersion = '' }
            elseif ($pick -eq 'custom') {
                $v = Read-DevKitWizardVersion -PromptKey 'in.node' -Current $NodeVersion -Pattern '^\d+$'
                if ($v) { $script:NodeVersion = $v }
            }
        }
        'mirror' {
            $pick = Show-DevKitChoice -Title (Get-DevKitText 'lbl.mirror') -Item @('auto', 'cn', 'off') `
                -Marked $Mirror -Cursor $Mirror -LabelFn ${function:Get-DevKitWizardChoiceLabel}
            if ($pick) { $script:Mirror = $pick }
        }
        'shell' {
            $yes = Show-DevKitYesNo -Title (Get-DevKitText 'lbl.shell') -Default (-not $NoShellInit)
            if ($null -ne $yes) { $script:NoShellInit = (-not $yes) }
        }
        'cache' {
            $yes = Show-DevKitYesNo -Title (Get-DevKitText 'lbl.cache') -Default ([bool]$KeepCache)
            if ($null -ne $yes) { $script:KeepCache = $yes }
        }
    }
}

# $true = go ahead, $false = back to the component picker
function Show-DevKitWizardOption {
    $cursor = 'start'
    if ($Uninstall) { $cursor = 'startu' }
    while ($true) {
        $title = Get-DevKitText 'opts.title'
        $note = Get-DevKitText 'sum.install'
        if ($Uninstall) {
            $title = Get-DevKitText 'opts.titleu'
            $note = Get-DevKitText 'sum.uninst'
        }
        $script:UiNote = @("  $note$($script:WizSelected -join ' ')")
        $pick = Show-DevKitChoice -Title $title -Item (Get-DevKitWizardOptionItem) -Marked '' `
            -Cursor $cursor -LabelFn ${function:Get-DevKitWizardOptionLabel}
        $script:UiNote = @()
        if ($null -eq $pick) { return $false }
        $cursor = $pick
        if ($pick -eq 'start' -or $pick -eq 'startu') { return $true }
        if ($pick -eq 'back') { return $false }
        Invoke-DevKitWizardOption -Key $pick
    }
}

function Show-DevKitWizardPicker {
    $script:WizInstalled = @(Get-DevKitInstalledComponent)
    if ($Uninstall -and $script:WizInstalled.Count -eq 0) {
        Restore-DevKitConsole
        Write-DevKitErr (Get-DevKitText 'msg.noinst')
        exit 1
    }
    $title = Get-DevKitText 'pick.install'
    if ($Uninstall) { $title = Get-DevKitText 'pick.uninst' }
    # coming back from a later step: keep what was ticked, do not reset it
    $pre = @()
    if ($script:WizSelected) { $pre = @($script:WizSelected) } elseif (-not $Uninstall) { $pre = $script:WizInstalled }
    while ($true) {
        if ($Uninstall) {
            $pick = Show-DevKitChecklist -Title $title -Item $script:AllComponents -Selected $pre `
                -LabelFn ${function:Get-DevKitComponentDesc} `
                -MarkFn { param($x) if ($script:WizInstalled -contains $x) { '* ' } else { '  ' } }
        } else {
            $pick = Show-DevKitChecklist -Title $title -Item $script:AllComponents -Selected $pre `
                -LabelFn ${function:Get-DevKitComponentDesc} -MarkFn $null
        }
        if ($null -eq $pick) { return $false }
        if (@($pick).Count -gt 0) { $script:WizSelected = @($pick); return $true }
        $title = "$(Get-DevKitText 'pick.install')   $(Get-DevKitText 'msg.none')"
        if ($Uninstall) { $title = "$(Get-DevKitText 'pick.uninst')   $(Get-DevKitText 'msg.none')" }
    }
}

function Show-DevKitWizardConfirm {
    $note = Get-DevKitText 'sum.u1'
    if ($KeepCache) { $note = Get-DevKitText 'sum.u1k' }
    $script:UiNote = @(
        "  $(Get-DevKitText 'sum.uninst')$($script:WizSelected -join ' ')",
        "  $note",
        "  $(Get-DevKitText 'sum.u2')"
    )
    $yes = Show-DevKitYesNo -Title (Get-DevKitText 'sum.ask') -Default $false
    $script:UiNote = @()
    return ($yes -eq $true)
}

function Invoke-DevKitWizard {
    $step = 1
    if ($Uninstall) { $step = 2 }
    $modeForced = [bool]$Uninstall
    try {
        while ($true) {
            switch ($step) {
                1 {
                    $pick = Show-DevKitChoice -Title (Get-DevKitText 'mode.title') `
                        -Item @('install', 'uninstall', 'quit') -Marked '' -Cursor 'install' `
                        -LabelFn { param($x)
                            if ($x -eq 'install') { Get-DevKitText 'mode.install' }
                            elseif ($x -eq 'uninstall') { Get-DevKitText 'mode.uninst' }
                            else { Get-DevKitText 'mode.quit' } }
                    if ($null -eq $pick -or $pick -eq 'quit') {
                        Restore-DevKitConsole
                        Write-DevKitInfo (Get-DevKitText 'msg.cancel')
                        exit 0
                    }
                    if ($pick -eq 'uninstall') { $script:Uninstall = $true } else { $script:Uninstall = $false }
                    $step = 2
                }
                2 {
                    if (-not (Show-DevKitWizardPicker)) {
                        if ($modeForced) {
                            Restore-DevKitConsole
                            Write-DevKitInfo (Get-DevKitText 'msg.cancel')
                            exit 0
                        }
                        $step = 1
                    } else {
                        if (-not $Uninstall -and ($script:WizSelected -contains 'jdk') -and $script:WizJdk.Count -eq 0) {
                            if ($JdkVersion) {
                                $script:WizJdk = @($JdkVersion)
                            } else {
                                Show-DevKitFrame @(@{ T = "  $(Get-DevKitText 'msg.loading')"; C = 'DarkGray' })
                                $script:WizJdk = @([string](Get-DevKitDefaultJdkMajor))
                                Clear-DevKitFrame 1
                            }
                        }
                        $step = 3
                    }
                }
                3 {
                    if (Show-DevKitWizardOption) {
                        if ($Uninstall) { $step = 4 } else { $step = 9 }
                    } else { $step = 2 }
                }
                4 {
                    if (Show-DevKitWizardConfirm) { $step = 9 } else { $step = 3 }
                }
                9 {
                    $script:WizConfirmed = $true
                    if (-not $Uninstall -and $script:WizJdk.Count -gt 0) { $script:JdkVersion = @($script:WizJdk) }
                    return
                }
            }
        }
    } finally {
        Restore-DevKitConsole
    }
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
$script:RustMsvcMissing = $false
$script:Yes = [bool]$Yes

if (-not $All -and -not $With -and -not $Yes -and (Test-DevKitTui)) {
    Initialize-DevKitLang
    Invoke-DevKitWizard
}

if ($Uninstall) {
    $installed = Get-DevKitInstalledComponent
    $usel = @()
    if ($script:WizSelected) {
        $usel = $script:WizSelected
    } elseif ($All) {
        if ($installed.Count -eq 0) { Write-DevKitErr 'nothing installed by dev-kit to uninstall'; exit 1 }
        $usel = $installed
    } elseif ($With) {
        $flat = @()
        foreach ($w in $With) { foreach ($x in @($w -split ',')) { $x = $x.ToLower().Trim(); if ($x) { $flat += $x } } }
        foreach ($c in $flat) { if ($script:AllComponents -notcontains $c) { Write-DevKitErr "unknown component: $c"; exit 1 } }
        $usel = $flat
    } elseif ([Environment]::UserInteractive -and -not $Yes) {
        $usel = Show-DevKitMenu -ForUninstall
    } else {
        Write-DevKitErr 'uninstall needs an explicit selection: pass -All or -With <components>'
        exit 1
    }
    if ($usel.Count -eq 0) { Write-DevKitInfo 'nothing selected; exiting.'; exit 0 }
    Write-DevKitStep "dev-kit $script:DevKitVersion  (uninstall)"
    try { Invoke-DevKitUninstall -Components $usel }
    finally { if (Test-Path $script:TmpDir) { Remove-Item -Recurse -Force $script:TmpDir -ErrorAction SilentlyContinue } }
    return
}

# JDK requested majors (flatten comma/multiple)
$script:JdkReq = @()
if ($JdkVersion) { foreach ($j in $JdkVersion) { foreach ($p in @($j -split ',')) { $p = $p.Trim(); if ($p) { $script:JdkReq += $p } } } }
$script:NodeVersion = $NodeVersion

# mirror
$script:Mirror = Resolve-DevKitMirror -Requested $Mirror
Write-DevKitStep "dev-kit $script:DevKitVersion  (arch: $script:Arch, mirror: $script:Mirror)"

# mirror change handling (cn->off cleanup happens inside components; do go/env here for safety)
$prevMirror = Get-DevKitStateValue $script:State 'mirror'
if ($prevMirror -eq 'cn' -and $script:Mirror -ne 'cn') {
    Remove-DevKitUserEnv 'FNM_NODE_DIST_MIRROR'
    Remove-DevKitUserEnv 'RUSTUP_DIST_SERVER'
    Remove-DevKitUserEnv 'RUSTUP_UPDATE_ROOT'
}
if ($script:Mirror -eq 'cn') {
    Set-DevKitUserEnv 'RUSTUP_DIST_SERVER' 'https://rsproxy.cn'
    Set-DevKitUserEnv 'RUSTUP_UPDATE_ROOT' 'https://rsproxy.cn/rustup'
}

# selection
$selected = @()
if ($script:WizSelected) {
    $selected = $script:WizSelected
} elseif ($All) {
    $selected = $script:AllComponents
} elseif ($With) {
    $flat = @()
    foreach ($w in $With) { foreach ($x in @($w -split ',')) { $x = $x.ToLower().Trim(); if ($x) { $flat += $x } } }
    foreach ($c in $flat) { if ($script:AllComponents -notcontains $c) { Write-DevKitErr "unknown component: $c (valid: $($script:AllComponents -join ', '))"; exit 1 } }
    $selected = $flat
} elseif ($Yes) {
    $selected = Get-DevKitInstalledComponent
    if ($selected.Count -eq 0) { Write-DevKitErr 'nothing installed yet; pass -All or -With <components>'; exit 1 }
    Write-DevKitInfo "updating installed: $($selected -join ', ')"
} elseif ([Environment]::UserInteractive) {
    $selected = Show-DevKitMenu
} else {
    Write-DevKitErr 'no components selected and not interactive; pass -All or -With <components>'
    exit 1
}

if ($selected.Count -eq 0) { Write-DevKitInfo 'nothing selected; exiting.'; exit 0 }

# maven/gradle imply jdk
if ((($selected -contains 'maven') -or ($selected -contains 'gradle')) -and ($selected -notcontains 'jdk')) {
    if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
        Write-DevKitInfo 'maven/gradle need a JDK; adding jdk to the selection'
        $selected = @('jdk') + $selected
    }
}

# order
$ordered = @()
foreach ($c in $script:AllComponents) { if ($selected -contains $c) { $ordered += $c } }

$failed = @()
try {
    foreach ($c in $ordered) {
        Write-DevKitStep "installing/updating: $c"
        try {
            switch ($c) {
                'git'    { Install-DevKitGit }
                'jdk'    { Install-DevKitJdk }
                'maven'  { Install-DevKitMaven }
                'gradle' { Install-DevKitGradle }
                'go'     { Install-DevKitGo }
                'rust'   { Install-DevKitRust }
                'node'   { Install-DevKitNode }
                'pnpm'   { Install-DevKitPnpm }
                'bun'    { Install-DevKitBun }
            }
            Write-DevKitOk $c
        } catch {
            $failed += $c
            Write-DevKitErr "$c failed: $($_.Exception.Message)"
        }
    }

    # persist state
    Set-DevKitStateValue $script:State 'mirror' $script:Mirror
    Save-DevKitState $script:State

    # env + PATH + profiles
    $pathEntries = Get-DevKitPathEntry
    Set-DevKitUserPath -Prepend $pathEntries
    Set-DevKitUserEnv 'DEVKIT_HOME' $script:DevKitHome
    Write-DevKitEnvFile
    if (-not $NoShellInit) { Update-DevKitProfile }
    Update-DevKitGithubEnv -PathEntries $pathEntries

    Show-DevKitDoctor -Failed $failed
} finally {
    if (Test-Path $script:TmpDir) { Remove-Item -Recurse -Force $script:TmpDir -ErrorAction SilentlyContinue }
}

if ($failed.Count -gt 0) { exit 2 }
exit 0
