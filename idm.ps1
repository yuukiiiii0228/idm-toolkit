#Requires -Version 5.1
<#
    IDM Toolkit  ·  Internet Download Manager 授权工具
    ------------------------------------------------------------------
    交互式界面，纯 PowerShell 实现，零外部依赖（不需要 Python / pefile）。

    用法（首次）：
        irm https://raw.githubusercontent.com/yuukiiiii0228/idm-toolkit/main/idm.ps1 | iex

    用法（安装全局命令后）：
        idm

    作者: <你的名字>            License: MIT
#>

param(
    [switch]$NoElevate,
    [switch]$DryRun,
    [switch]$Status,
    [switch]$Patch,
    [switch]$Restore,
    [switch]$Uninstall,
    [switch]$Download,
    [string]$Url,
    [string]$InstallerPath,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

# ======================================================================
#  配置区 —— 上传 GitHub 后把这里改成你自己的仓库地址
# ======================================================================
$TOOLKIT = [ordered]@{
    Name      = 'IDM Toolkit'
    Version   = '1.0.0'
    RawUrl    = 'https://raw.githubusercontent.com/yuukiiiii0228/idm-toolkit/main/idm.ps1'
    Home      = Join-Path $env:LOCALAPPDATA 'IdmToolkit'
}
$TOOLKIT.CachePath  = Join-Path $TOOLKIT.Home 'idm.ps1'
$TOOLKIT.BackupMeta = Join-Path $TOOLKIT.Home 'backup.json'
$TOOLKIT.LogPath    = Join-Path $TOOLKIT.Home 'toolkit.log'

# 运行时选项（由命令行参数覆盖）
$script:OptUrl       = $null
$script:OptInstaller = $null

# 已知版本的 IDMan.exe 指纹（仅用于提示，不影响打补丁 —— 补丁全部靠签名定位）
$KNOWN_BUILDS = @{
    'E3FC655A335E17A6FDD09A9B315291D0C8863180F0D801E5DD7433C9E56AFBD8' = '6.43 build 15  (6.43.15.2)'
}

# ---- IDM 安装包下载源 ----------------------------------------------------
$IDM_PAGE    = 'https://www.internetdownloadmanager.com/download.html'
$IDM_MIRRORS = @(
    'https://download.internetdownloadmanager.com/{0}',
    'https://mirror2.internetdownloadmanager.com/{0}',
    'https://mirror3.internetdownloadmanager.com/{0}',
    'https://mirror4.internetdownloadmanager.com/{0}',
    'https://mirror5.internetdownloadmanager.com/{0}'
)
$IDM_SIGNER  = 'Tonec Inc.'          # 安装包 Authenticode 签名者
$IDM_MIN_SIZE = 5MB                  # 小于这个体积肯定不是安装包

# 补丁后的预期指纹（6.43 build 15 原始文件打满 9 个补丁的结果）
$KNOWN_PATCHED = @{
    '6.43 build 15  (6.43.15.2)' = '40E7889493657CADE255798E41E2CEC5500C337E6A880B74D345BB9968ADE869'
}

# ======================================================================
#  终端 UI
# ======================================================================
$CO = @{
    Title = 'Cyan';  Acc = 'Magenta'; Ok = 'Green'
    Warn  = 'Yellow'; Err = 'Red';     Dim = 'DarkGray'
    Text  = 'Gray';   Hi  = 'White'
}
$script:UIWidth = 74

# 输出被重定向（管道 / 文件）时不能用 \r 做单行动画：
# PowerShell 5.1 的 Write-Host -NoNewline 会去取控制台缓冲区信息，
# 在非控制台宿主下会抛 Win32 错误（0xE9）。
$script:Animate = $true
try { if ([Console]::IsOutputRedirected) { $script:Animate = $false } } catch { $script:Animate = $false }
$script:LastProgress = [DateTime]::MinValue

function Write-Log([string]$Message) {
    try {
        if (-not (Test-Path $TOOLKIT.Home)) { New-Item -ItemType Directory -Path $TOOLKIT.Home -Force | Out-Null }
        $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -Path $TOOLKIT.LogPath -Value $line -Encoding UTF8
    } catch { }
}

function Get-DisplayWidth([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return 0 }
    $w = 0
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int]$ch
        if (($c -ge 0x1100 -and $c -le 0x115F) -or
            ($c -ge 0x2E80 -and $c -le 0xA4CF) -or
            ($c -ge 0xAC00 -and $c -le 0xD7A3) -or
            ($c -ge 0xF900 -and $c -le 0xFAFF) -or
            ($c -ge 0xFE30 -and $c -le 0xFE6F) -or
            ($c -ge 0xFF00 -and $c -le 0xFF60) -or
            ($c -ge 0xFFE0 -and $c -le 0xFFE6)) { $w += 2 } else { $w += 1 }
    }
    return $w
}

function Pad-Display([string]$Text, [int]$Width) {
    $d = Get-DisplayWidth $Text
    if ($d -ge $Width) { return $Text }
    return $Text + (' ' * ($Width - $d))
}

function Write-Rule([string]$Char = '-') {
    Write-Host ($Char * $script:UIWidth) -ForegroundColor $CO.Dim
}

function Write-Kv([string]$Key, [string]$Value, [string]$ValueColor = 'Gray') {
    $k = Pad-Display $Key 16
    Write-Host "  $k" -ForegroundColor $CO.Dim -NoNewline
    Write-Host $Value -ForegroundColor $ValueColor
}

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host ("  >> " + $Text) -ForegroundColor $CO.Acc
}

function Write-Ok([string]$Text)   { Write-Host "     [OK]   $Text" -ForegroundColor $CO.Ok }
function Write-Info([string]$Text) { Write-Host "     [..]   $Text" -ForegroundColor $CO.Text }
function Write-Warn([string]$Text) { Write-Host "     [!!]   $Text" -ForegroundColor $CO.Warn }
function Write-Err([string]$Text)  { Write-Host "     [XX]   $Text" -ForegroundColor $CO.Err }
function Write-Note([string]$Text) { Write-Host "            $Text" -ForegroundColor $CO.Dim }

function Write-Banner {
    Write-Host ''
    Write-Host ('=' * $script:UIWidth) -ForegroundColor $CO.Title
    $left  = "  $($TOOLKIT.Name)  v$($TOOLKIT.Version)"
    $right = 'Internet Download Manager 授权工具  '
    $gap   = $script:UIWidth - (Get-DisplayWidth $left) - (Get-DisplayWidth $right)
    if ($gap -lt 2) { $gap = 2 }
    Write-Host $left -ForegroundColor $CO.Title -NoNewline
    Write-Host (' ' * $gap) -NoNewline
    Write-Host $right -ForegroundColor $CO.Dim
    Write-Host ('=' * $script:UIWidth) -ForegroundColor $CO.Title
}

function Clear-Screen {
    try { Clear-Host } catch { }
}

function Pause-Any([string]$Prompt = '按 Enter 返回主菜单') {
    if ($Yes) { return }
    Write-Host ''
    Read-Host "  $Prompt" | Out-Null
}

function Confirm-Action([string]$Prompt) {
    if ($Yes) { return $true }
    $a = Read-Host "  $Prompt [y/N]"
    return ($a -match '^(y|yes|是|Y)$')
}

# ======================================================================
#  基础工具
# ======================================================================
function Get-Sha256([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '') }
    finally { $sha.Dispose() }
}

function Get-FileSha256([string]$Path) {
    return (Get-Sha256 ([System.IO.File]::ReadAllBytes($Path)))
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Remove-ZoneMark([string]$Path) {
    try { Remove-Item -Path $Path -Stream Zone.Identifier -ErrorAction SilentlyContinue } catch { }
}

function Enable-Tls12 {
    # Windows PowerShell 5.1 默认不启用 TLS 1.2，访问 https 会直接失败
    try {
        $cur = [Net.ServicePointManager]::SecurityProtocol
        [Net.ServicePointManager]::SecurityProtocol = $cur -bor `
            [Net.SecurityProtocolType]::Tls12 -bor `
            [Net.SecurityProtocolType]::Tls11 -bor `
            [Net.SecurityProtocolType]::Tls
    } catch { }
}

function Format-ByteSize([double]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:0.00} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:0.0} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:0.0} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f [int]$Bytes)
}

# ======================================================================
#  下载 / 安装 IDM
# ======================================================================
function Test-IdmInstaller([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @{ Ok = $false; Reason = '文件不存在' } }

    $fi = Get-Item -LiteralPath $Path
    if ($fi.Length -lt $IDM_MIN_SIZE) {
        return @{ Ok = $false; Reason = ('体积只有 {0}，不是完整的安装包' -f (Format-ByteSize $fi.Length)) }
    }

    $fs = [System.IO.File]::OpenRead($Path)
    try {
        $hdr = New-Object byte[] 2
        [void]$fs.Read($hdr, 0, 2)
    } finally { $fs.Dispose() }
    if ($hdr[0] -ne 0x4D -or $hdr[1] -ne 0x5A) {
        return @{ Ok = $false; Reason = '缺少 MZ 头，不是 PE 可执行文件' }
    }

    $subject = ''
    try {
        $cert    = [Security.Cryptography.X509Certificates.X509Certificate]::CreateFromSignedFile($Path)
        $subject = $cert.Subject
    } catch {
        return @{ Ok = $false; Reason = '没有 Authenticode 数字签名' }
    }
    if ($subject -notlike "*$IDM_SIGNER*") {
        return @{ Ok = $false; Reason = ("签名者不是 {0}（实际：{1}）" -f $IDM_SIGNER, $subject) }
    }

    return @{ Ok = $true; Reason = $subject; Size = $fi.Length }
}

function Show-DownloadProgress([long]$Got, [long]$Total, [double]$Bps) {
    $tail = if ($Total -gt 0) { '{0,9} / {1}' -f (Format-ByteSize $Got), (Format-ByteSize $Total) }
            else            { '{0,9} / ????    ' -f (Format-ByteSize $Got) }

    if (-not $script:Animate) {
        # 重定向场景：每 3 秒打一行普通日志，不画进度条
        $now = [DateTime]::UtcNow
        if (($now - $script:LastProgress).TotalSeconds -lt 3) { return }
        $script:LastProgress = $now
        Write-Host "     $tail   $(Format-ByteSize $Bps)/s" -ForegroundColor $CO.Dim
        return
    }

    $barW = 28
    if ($Total -gt 0) {
        $pct  = [Math]::Min(100, [int](($Got * 100) / $Total))
        $fill = [int](($pct * $barW) / 100)
    } else {
        $pct = 0; $fill = 0
    }
    $bar  = ('#' * $fill) + ('.' * ($barW - $fill))
    $line = "     [$bar] {0,3}%  $tail   {1,8}/s   " -f $pct, (Format-ByteSize $Bps)
    Write-Host "`r$line" -NoNewline -ForegroundColor $CO.Text
}

function Save-RemoteFile {
    param([string]$Url, [string]$OutFile, [switch]$Quiet)

    Enable-Tls12
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.UserAgent          = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
    $req.Accept             = '*/*'
    $req.Timeout            = 30000
    $req.ReadWriteTimeout   = 60000
    $req.AllowAutoRedirect  = $true

    $resp = $null; $in = $null; $out = $null
    try {
        $resp  = $req.GetResponse()
        $total = $resp.ContentLength
        $in    = $resp.GetResponseStream()
        $out   = [System.IO.File]::Create($OutFile)

        $buf = New-Object byte[] 262144
        $got = 0
        $sw  = [Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            $n = $in.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $out.Write($buf, 0, $n)
            $got += $n
            if (-not $Quiet) {
                $sec = $sw.Elapsed.TotalSeconds
                Show-DownloadProgress -Got $got -Total $total -Bps $(if ($sec -gt 0.3) { $got / $sec } else { 0 })
            }
        }
        if (-not $Quiet -and $script:Animate) { Write-Host '' }
        return $got
    } finally {
        if ($out)  { $out.Dispose() }
        if ($in)   { $in.Dispose() }
        if ($resp) { $resp.Dispose() }
    }
}

function Test-HostsBlocked {
    $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if (-not (Test-Path $hosts)) { return $false }
    return ((Get-Content $hosts -Raw -ErrorAction SilentlyContinue) -like '*IDM Toolkit BEGIN*')
}

# 从官方下载页解析当前安装包文件名（返回 @{ FileName; Urls } 或 $null）
function Get-IdmDownloadInfo {
    Enable-Tls12

    # 如果之前开过 hosts 屏蔽，www.internetdownloadmanager.com 会被拦，临时关掉
    $wasBlocked = Test-HostsBlocked
    if ($wasBlocked) {
        Write-Note 'hosts 屏蔽正在生效，临时解除以便访问官方下载页 ...'
        Set-HostsBlock -Remove -Quiet
    }

    $fileName = $null
    $direct   = $null
    try {
        $html = Invoke-WebRequest -Uri $IDM_PAGE -UseBasicParsing -TimeoutSec 25 -ErrorAction Stop
        $m = [regex]::Match($html.Content, 'href="(https?://[^"]*?/(idman\d+build\d+\.exe))"')
        if ($m.Success) {
            $direct   = $m.Groups[1].Value
            $fileName = $m.Groups[2].Value
        } else {
            $m2 = [regex]::Match($html.Content, '(idman\d+build\d+\.exe)')
            if ($m2.Success) { $fileName = $m2.Groups[1].Value }
        }
    } catch {
        Write-Note "下载页解析失败：$($_.Exception.Message)"
    } finally {
        if ($wasBlocked) {
            Set-HostsBlock -Quiet
            Write-Note 'hosts 屏蔽已恢复。'
        }
    }

    if (-not $fileName) { return $null }

    $urls = @()
    if ($direct) { $urls += $direct }
    foreach ($m in $IDM_MIRRORS) { $urls += ($m -f $fileName) }
    $urls = @($urls | Select-Object -Unique)

    return @{ FileName = $fileName; Urls = $urls }
}

# 拿到一个已校验的安装包，返回其本地路径
function Get-IdmInstaller {
    param([string]$DestDir, [string]$Url, [string]$LocalPath)

    if (-not $DestDir) { $DestDir = Join-Path $env:USERPROFILE 'Downloads' }
    if (-not (Test-Path $DestDir)) { New-Item -ItemType Directory -Path $DestDir -Force | Out-Null }

    # ---------- A. 用本地已有的安装包 ----------
    if ($LocalPath) {
        if (-not (Test-Path -LiteralPath $LocalPath)) { throw "找不到文件：$LocalPath" }
        $t = Test-IdmInstaller $LocalPath
        if (-not $t.Ok) { throw "本地安装包校验失败：$($t.Reason)" }
        Write-Ok "使用本地安装包：$LocalPath"
        Write-Note "签名  $($t.Reason)"
        return (Resolve-Path -LiteralPath $LocalPath).Path
    }

    # ---------- B. 确定候选下载地址 ----------
    $candidates = @()
    if ($Url) {
        $candidates = @($Url)
        Write-Info "使用指定地址：$Url"
    } else {
        Write-Info '正在从官方下载页获取最新安装包地址 ...'
        $info = Get-IdmDownloadInfo
        if ($info) {
            Write-Ok "当前版本：$($info.FileName)"
            $candidates = $info.Urls
        } else {
            Write-Warn '无法从官网获取下载地址。'
        }
    }

    if ($candidates.Count -eq 0) {
        Write-Host ''
        Write-Note '你可以手动提供安装包地址或本地路径：'
        $manual = Read-Host '  安装包 URL 或本地文件路径（留空则取消）'
        if (-not $manual) { throw '未获取到安装包。' }
        if ($manual -match '^https?://') { $candidates = @($manual) }
        else { return (Get-IdmInstaller -DestDir $DestDir -LocalPath $manual) }
    }

    # ---------- C. 逐个候选地址下载 ----------
    $lastErr = ''
    foreach ($u in $candidates) {
        $name = Split-Path $u -Leaf
        if (-not $name -or $name -notmatch '\.exe$') { $name = 'idman_setup.exe' }
        $dest = Join-Path $DestDir $name

        Write-Host ''
        Write-Info "下载  $u"
        try {
            if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue }
            $bytes = Save-RemoteFile -Url $u -OutFile $dest
            Remove-ZoneMark $dest
        } catch {
            $lastErr = $_.Exception.Message
            Write-Warn "下载失败：$lastErr"
            continue
        }

        $t = Test-IdmInstaller $dest
        if (-not $t.Ok) {
            $lastErr = $t.Reason
            Write-Warn "校验失败：$($t.Reason)"
            Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
            continue
        }

        Write-Ok "已下载并校验：$dest"
        Write-Note "大小  $(Format-ByteSize $t.Size)"
        Write-Note "签名  $($t.Reason)"
        return $dest
    }

    throw "所有下载源都失败了。最后一次错误：$lastErr"
}

# 静默运行安装包，并等待安装完成
#
# 安装包是「自解压 SFX + 清单解释器」：它自己解包，自己执行清单里的
# <DEST>/<LNK>/<DEL>/<RUN> 指令（见 docs/TECHNICAL.md），
# 并**不会**再启动一个子安装进程。因此「进程退出」就是「安装结束」。
function Install-IdmFromInstaller {
    param([string]$Path, [int]$TimeoutSec = 420)

    $before = Get-IdmInstallPath
    if ($before) { Stop-Idm }

    Write-Info '启动安装程序（/skipdlgs）...'
    $proc = $null
    try {
        $proc = Start-Process -FilePath $Path -ArgumentList '/skipdlgs' -PassThru -ErrorAction Stop
    } catch {
        Write-Warn "带 /skipdlgs 启动失败，改用普通方式启动：$($_.Exception.Message)"
        $proc = Start-Process -FilePath $Path -PassThru
    }

    Write-Note '安装过程中若弹出窗口，按默认设置点「下一步 / 完成」即可。'
    Write-Note '本工具会自动等待安装结束并继续。'
    Write-Host ''

    $sw       = [Diagnostics.Stopwatch]::StartNew()
    $lastSize = -1
    $stable   = 0
    $found    = $null
    $lastLog  = -999

    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        Start-Sleep -Seconds 2

        $busy = $false
        if ($proc) { try { $busy = -not $proc.HasExited } catch { $busy = $false } }
        if (-not $busy) { $busy = Test-IdmSetupRunning $Path }

        $cur  = Get-IdmInstallPath
        $size = -1
        if ($cur) { try { $size = (Get-Item -LiteralPath $cur).Length } catch { $size = -1 } }

        if ($cur -and $size -gt $IDM_MIN_SIZE) {
            if ($size -eq $lastSize) { $stable++ } else { $stable = 0 }
            $lastSize = $size
        } else {
            $stable = 0
        }

        # 安装进程已退出，且 IDMan.exe 体积稳定 → 认为装完了
        if (-not $busy -and $stable -ge 2) { $found = $cur; break }

        $wait = [int]$sw.Elapsed.TotalSeconds
        $msg  = if ($busy) { "安装中 ... {$wait}s" } else { "等待安装结束 ... {$wait}s" }
        if ($script:Animate) {
            Write-Host "`r     $msg          " -NoNewline -ForegroundColor $CO.Dim
        } elseif (($wait - $lastLog) -ge 15) {
            Write-Host "     $msg" -ForegroundColor $CO.Dim
            $lastLog = $wait
        }
    }
    if ($script:Animate) { Write-Host '' }

    if (-not $found) {
        $found = Get-IdmInstallPath
        if (-not $found) { throw "等待安装超时（${TimeoutSec}s）且未检测到 IDM。请手动完成安装后重试。" }
        Write-Warn '等待超时，但已检测到 IDM，继续。'
    }

    Stop-Idm
    Write-Ok "IDM 已安装：$found"
    return $found
}

function Test-IdmSetupRunning([string]$InstallerPath) {
    $base = [IO.Path]::GetFileNameWithoutExtension($InstallerPath)
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        if ($p.ProcessName -ieq $base) { return $true }
        $path = $null
        try { $path = $p.Path } catch { }
        if ($path -and ($path -like '*IDM_Setup_Temp*')) { return $true }
    }
    return $false
}

# ======================================================================
#  PE 引擎 —— 解析 + 签名扫描（移植自 patch_idm_generic.py）
# ======================================================================
$script:Latin1 = [Text.Encoding]::GetEncoding(28591)

function Get-PeImage([string]$Path) {
    $data = [System.IO.File]::ReadAllBytes($Path)
    if ($data.Length -lt 0x200) { throw "文件太小，不是有效的 PE：$Path" }

    $elf = [BitConverter]::ToInt32($data, 0x3C)
    if ($elf -le 0 -or $elf + 0x100 -gt $data.Length) { throw "e_lfanew 越界，不是有效的 PE：$Path" }
    if ([BitConverter]::ToUInt32($data, $elf) -ne 0x00004550) { throw "缺少 PE\0\0 签名：$Path" }

    $coff    = $elf + 4
    $machine = [BitConverter]::ToUInt16($data, $coff)
    $nsec    = [BitConverter]::ToUInt16($data, $coff + 2)
    $sizeOpt = [BitConverter]::ToUInt16($data, $coff + 16)
    $opt     = $coff + 20
    $magic   = [BitConverter]::ToUInt16($data, $opt)

    if ($machine -ne 0x014C) { throw ("仅支持 32 位 x86 PE（Machine=0x{0:X4}）：{1}" -f $machine, $Path) }
    if ($magic   -ne 0x010B) { throw ("仅支持 PE32（Magic=0x{0:X4}）：{1}" -f $magic, $Path) }

    $imageBase = [BitConverter]::ToUInt32($data, $opt + 28)
    $secStart  = $opt + $sizeOpt

    $sections = @()
    for ($i = 0; $i -lt $nsec; $i++) {
        $o = $secStart + $i * 40
        if ($o + 40 -gt $data.Length) { throw "节区表越界" }
        $sections += @{
            Name             = ([Text.Encoding]::ASCII.GetString($data, $o, 8)).TrimEnd([char]0)
            VirtualSize      = [BitConverter]::ToUInt32($data, $o + 8)
            VirtualAddress   = [BitConverter]::ToUInt32($data, $o + 12)
            SizeOfRawData    = [BitConverter]::ToUInt32($data, $o + 16)
            PointerToRawData = [BitConverter]::ToUInt32($data, $o + 20)
        }
    }

    return @{
        Path       = (Resolve-Path $Path).Path
        Data       = $data
        ImageBase  = $imageBase
        Sections   = $sections
        DataDirOff = $opt + 96          # PE32 可选头 -> 数据目录表
        TextCache  = @{}
        Sha256     = (Get-Sha256 $data)
    }
}

function Get-Section($Img, [string]$Name) {
    $s = $Img.Sections | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $s) { throw "节区 $Name 不存在" }
    return $s
}

function Convert-VaToOff($Img, [uint32]$Va) {
    if ($Va -lt $Img.ImageBase) { throw ("VA {0:X8} 小于 ImageBase，不是绝对地址" -f $Va) }
    $rva = $Va - $Img.ImageBase
    foreach ($s in $Img.Sections) {
        $size = [Math]::Max($s.VirtualSize, $s.SizeOfRawData)
        if ($rva -ge $s.VirtualAddress -and $rva -lt ($s.VirtualAddress + $size)) {
            $off = [int]($s.PointerToRawData + ($rva - $s.VirtualAddress))
            if ($off -ge 0 -and $off -lt $Img.Data.Length) { return $off }
        }
    }
    throw ("VA {0:X8} (RVA {1:X8}) 不在任何节区内" -f $Va, $rva)
}

function Get-SectionText($Img, [string]$Name) {
    if ($Img.TextCache.ContainsKey($Name)) { return $Img.TextCache[$Name] }
    $s   = Get-Section $Img $Name
    $len = [int]$s.SizeOfRawData
    if ($s.PointerToRawData + $len -gt $Img.Data.Length) { $len = $Img.Data.Length - [int]$s.PointerToRawData }
    $blob = New-Object byte[] $len
    [Array]::Copy($Img.Data, [int]$s.PointerToRawData, $blob, 0, $len)
    $txt = $script:Latin1.GetString($blob)
    $Img.TextCache[$Name] = $txt
    return $txt
}

function ConvertTo-ScanPattern([string]$Hex) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($p in ($Hex -split '\s+' | Where-Object { $_ })) {
        if ($p -eq '??' -or $p -eq '?') { [void]$sb.Append('.') }
        else { [void]$sb.Append('\x' + $p.PadLeft(2, '0')) }
    }
    return $sb.ToString()
}

function Find-Pattern($Img, [string]$Hex, [string]$SectionName = '.text', [int]$MaxHits = 64) {
    $s   = Get-Section $Img $SectionName
    $txt = Get-SectionText $Img $SectionName
    $rx  = [regex]::new((ConvertTo-ScanPattern $Hex), [Text.RegularExpressions.RegexOptions]::Singleline)
    $res = @()
    foreach ($m in $rx.Matches($txt)) {
        $res += @{
            Va  = [uint32]($Img.ImageBase + $s.VirtualAddress + $m.Index)
            Off = [int]($s.PointerToRawData + $m.Index)
            Len = $m.Length
        }
        if ($res.Count -ge $MaxHits) { break }
    }
    return $res
}

function Find-StringVa($Img, [string]$Needle, [string]$SectionName = '.rdata') {
    $s   = Get-Section $Img $SectionName
    $txt = Get-SectionText $Img $SectionName
    $idx = $txt.IndexOf($Needle + [char]0)
    if ($idx -lt 0) { return $null }
    return [uint32]($Img.ImageBase + $s.VirtualAddress + $idx)
}

function Read-AsciiZ($Img, [uint32]$Va) {
    $o   = Convert-VaToOff $Img $Va
    $end = $o
    while ($end -lt $Img.Data.Length -and $Img.Data[$end] -ne 0) { $end++ }
    return [Text.Encoding]::ASCII.GetString($Img.Data, $o, $end - $o)
}

function Get-ImportAddress($Img, [string]$DllName, [string]$FuncName) {
    $dirRva = [BitConverter]::ToUInt32($Img.Data, $Img.DataDirOff + 8)
    if ($dirRva -eq 0) { return $null }

    $o = Convert-VaToOff $Img ($Img.ImageBase + $dirRva)
    while ($o + 20 -le $Img.Data.Length) {
        $oft     = [BitConverter]::ToUInt32($Img.Data, $o)
        $nameRva = [BitConverter]::ToUInt32($Img.Data, $o + 12)
        $ft      = [BitConverter]::ToUInt32($Img.Data, $o + 16)
        if ($oft -eq 0 -and $nameRva -eq 0 -and $ft -eq 0) { break }

        if ((Read-AsciiZ $Img ($Img.ImageBase + $nameRva)) -ieq $DllName) {
            $thunk = if ($oft -ne 0) { $oft } else { $ft }
            $t = Convert-VaToOff $Img ($Img.ImageBase + $thunk)
            $i = 0
            while ($t + $i * 4 + 4 -le $Img.Data.Length) {
                $v = [BitConverter]::ToUInt32($Img.Data, $t + $i * 4)
                if ($v -eq 0) { break }
                if (($v -band 0x80000000) -eq 0) {
                    if ((Read-AsciiZ $Img ($Img.ImageBase + $v + 2)) -eq $FuncName) {
                        return [uint32]($Img.ImageBase + $ft + $i * 4)
                    }
                }
                $i++
            }
        }
        $o += 20
    }
    return $null
}

# ======================================================================
#  补丁定义 —— 9 个补丁点，全部靠签名定位，与版本无关
# ======================================================================
function New-PatchSite {
    param(
        [string]$Id, [string]$Func, [string]$Note,
        [int]$Off, [int]$Len, [byte[]]$Patched, [scriptblock]$Validate
    )
    return [pscustomobject]@{
        Id = $Id; Func = $Func; Note = $Note
        Off = $Off; Len = $Len; Patched = $Patched; Validate = $Validate
    }
}

function Read-ImgBytes($Img, [int]$Off, [int]$Len) {
    $b = New-Object byte[] $Len
    [Array]::Copy($Img.Data, $Off, $b, 0, $Len)
    return , $b
}

function Test-BytesEqual([byte[]]$A, [byte[]]$B) {
    if ($null -eq $A -or $null -eq $B) { return $false }
    if ($A.Length -ne $B.Length) { return $false }
    for ($i = 0; $i -lt $A.Length; $i++) { if ($A[$i] -ne $B[$i]) { return $false } }
    return $true
}

function Test-PatternAt($Img, [int]$Off, [string]$Hex) {
    $parts = @($Hex -split '\s+' | Where-Object { $_ })
    for ($k = 0; $k -lt $parts.Count; $k++) {
        $p = $parts[$k]
        if ($p -eq '??' -or $p -eq '?') { continue }
        $o = $Off + $k
        if ($o -lt 0 -or $o -ge $Img.Data.Length) { return $false }
        if ($Img.Data[$o] -ne [Convert]::ToByte($p, 16)) { return $false }
    }
    return $true
}

# 定位每个补丁点。所有定位模式都必须对「原始」与「已破解」两种状态都成立，
# 因此凡是会被补丁覆盖的字节一律写成 ?? 通配，或提供第二套备用模式。
function Resolve-PatchSites($Img) {
    $sites = New-Object System.Collections.Generic.List[object]

    function Find-NAny([string[]]$Patterns, [int]$Want, [string]$What) {
        $seen = @()
        foreach ($p in $Patterns) {
            $h = @(Find-Pattern $Img $p)
            if ($h.Count -eq $Want) { return $h }
            $seen += $h.Count
        }
        throw "$What 定位失败：期望命中 $Want 处，各模式实际命中 $($seen -join ' / ') 处"
    }
    function Find-One([string[]]$Patterns, [string]$What) {
        $r = Find-NAny $Patterns 1 $What
        return @($r)[0]
    }
    function PushHex([uint32]$Va) {
        return '68 ' + (($([BitConverter]::GetBytes($Va)) | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')
    }
    function Walk-Back([uint32]$FromVa, [int]$Limit, [string[]]$Patterns, [string]$What) {
        $sec     = Get-Section $Img '.text'
        $fromOff = Convert-VaToOff $Img $FromVa
        $minOff  = [Math]::Max([int]$sec.PointerToRawData, $fromOff - $Limit)
        for ($o = $fromOff; $o -ge $minOff; $o--) {
            foreach ($p in $Patterns) { if (Test-PatternAt $Img $o $p) { return $o } }
        }
        throw "$What 函数入口回溯失败"
    }

    # --- S1: dword_77BD24 —— 全局授权状态初始值 ---------------------------
    $h = Find-One @('A1 ?? ?? ?? ?? F7 D8 1B C0 83 E0 0F 83 C0 0F A3 ?? ?? ?? ??') 'S1 授权状态全局变量'
    $gStateVa  = [BitConverter]::ToUInt32($Img.Data, (Convert-VaToOff $Img ($h.Va + 1)))
    $gStateOff = Convert-VaToOff $Img $gStateVa
    $sites.Add((New-PatchSite 'S1' 'dword_77BD24' '全局授权状态初值 1(Trial) -> 0(Full)' `
        $gStateOff 1 ([byte[]]@(0x00)) { param($b) $b[0] -eq 0x01 }))

    # --- S2: 内置序列号黑名单短路 -----------------------------------------
    $h   = Find-One @('3B F3 ?? ?? 8B 45 ?? 50 FF 15 ?? ?? ?? ??') 'S2 内置黑名单比较'
    $off = Convert-VaToOff $Img ($h.Va + 2)
    $sites.Add((New-PatchSite 'S2' 'sub_450B40' '内置序列号黑名单 jnz -> nop' `
        $off 2 ([byte[]]@(0x90, 0x90)) { param($b) $b[0] -eq 0x75 }))

    # --- S3: HKLM 黑名单 ExitProcess ---------------------------------------
    $h   = Find-One @('6A 00 80 BF ?? ?? ?? ?? 00 ?? ??') 'S3 HKLM 黑名单判定'
    $off = Convert-VaToOff $Img ($h.Va + 9)
    $sites.Add((New-PatchSite 'S3' 'sub_46C970' 'HKLM 黑名单 jnz -> nop' `
        $off 2 ([byte[]]@(0x90, 0x90)) { param($b) $b[0] -eq 0x75 }))

    # --- S4: 三处 ExitProcess ----------------------------------------------
    $exitIat = Get-ImportAddress $Img 'kernel32.dll' 'ExitProcess'
    if (-not $exitIat) { throw 'S4 无法解析 kernel32!ExitProcess 的 IAT 地址' }
    $exitHex = 'FF 15 ' + (($([BitConverter]::GetBytes([uint32]$exitIat)) | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')
    $isExit  = { param($b) $b[0] -eq 0x6A -and $b[1] -eq 0x00 -and $b[2] -eq 0xFF -and $b[3] -eq 0x15 }

    $h   = Find-One @(
        "83 FB 07 74 ?? 83 FB 0C 75 ?? 6A 00 $exitHex",
        '83 FB 07 74 ?? 83 FB 0C 75 ?? 90 90 90 90 90 90 90 90'
    ) 'S4a 被封序列号 ExitProcess'
    $off = Convert-VaToOff $Img ($h.Va + 10)
    $sites.Add((New-PatchSite 'S4a' 'sub_521050' '被封序列号 push 0; call ExitProcess -> nop' `
        $off 8 ([byte[]](0x90) * 8) $isExit))

    $hs = Find-NAny @(
        "8D 4D ?? E8 ?? ?? ?? ?? 8D 4D ?? E8 ?? ?? ?? ?? 6A 00 $exitHex",
        '8D 4D ?? E8 ?? ?? ?? ?? 8D 4D ?? E8 ?? ?? ?? ?? 90 90 90 90 90 90 90 90'
    ) 2 'S4b 试用到期 ExitProcess'
    $n = 0
    foreach ($h in $hs) {
        $n++
        $off = Convert-VaToOff $Img ($h.Va + 16)
        $sites.Add((New-PatchSite ("S4b$n") 'sub_44CEF0/4670A0' '试用到期 push 0; call ExitProcess -> nop' `
            $off 8 ([byte[]](0x90) * 8) $isExit))
    }

    # --- S5: “检查更新”命令 ------------------------------------------------
    $strVa = Find-StringVa $Img 'update.cgi'
    if (-not $strVa) { throw "S5 找不到字符串 'update.cgi'" }
    $h    = Find-One @((PushHex $strVa)) "S5 'push update.cgi'"
    $fOff = Walk-Back $h.Va 0x3000 @('55 8B EC', 'C3 90 90 90 90') 'S5 sub_42E3A0'
    $sites.Add((New-PatchSite 'S5' 'sub_42E3A0' '“检查更新”命令 -> ret' `
        $fOff 5 ([byte[]]@(0xC3, 0x90, 0x90, 0x90, 0x90)) { param($b) $b[0] -eq 0x55 -and $b[1] -eq 0x8B -and $b[2] -eq 0xEC }))

    # --- S6: “是否已注册”判定函数 ------------------------------------------
    # 原版以 SEH 序言开头，已破解版被替换成 mov eax,1; ret，因此需要两套模式。
    $h = Find-One @(
        '6A FF 68 ?? ?? ?? ?? 64 A1 00 00 00 00 50 81 EC 5C 0A 00 00 A1 ?? ?? ?? ?? 33 C4 89 84 24',
        'B8 01 00 00 00 C3 ?? 64 A1 00 00 00 00 50 81 EC 5C 0A 00 00 A1 ?? ?? ?? ?? 33 C4 89 84 24'
    ) 'S6 sub_449850'
    $off = Convert-VaToOff $Img $h.Va
    $sites.Add((New-PatchSite 'S6' 'sub_449850' '“是否已注册” -> mov eax,1; ret' `
        $off 6 ([byte[]]@(0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3)) { param($b) $b[0] -eq 0x6A -and $b[1] -eq 0xFF }))

    # --- S7: CheckUpdtVM 写入 ----------------------------------------------
    $strVa = Find-StringVa $Img 'CheckUpdtVM'
    if (-not $strVa) { throw "S7 找不到字符串 'CheckUpdtVM'" }
    $h    = Find-One @((PushHex $strVa)) "S7 'push CheckUpdtVM'"
    $fOff = Walk-Back $h.Va 0x800 @('83 EC 44 A1', 'B8 01 00 00 00 C3') 'S7 sub_45A3D0'
    $sites.Add((New-PatchSite 'S7' 'sub_45A3D0' 'CheckUpdtVM 标记写入 -> mov eax,1; ret' `
        $fOff 6 ([byte[]]@(0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3)) { param($b) $b[0] -eq 0x83 -and $b[1] -eq 0xEC -and $b[2] -eq 0x44 }))

    return $sites
}

function Get-SiteState($Site, $Img) {
    if ($Site.Off + $Site.Len -gt $Img.Data.Length) { return 'unknown' }
    $cur = Read-ImgBytes $Img $Site.Off $Site.Len
    if (Test-BytesEqual $cur $Site.Patched) { return 'patched' }
    if (& $Site.Validate $cur) { return 'original' }
    return 'unknown'
}

function Get-BinaryState($Img) {
    try { $sites = Resolve-PatchSites $Img } catch { return @{ State = 'unknown'; Sites = @(); Error = $_.Exception.Message } }

    $states = @($sites | ForEach-Object { Get-SiteState $_ $Img })
    $p = @($states | Where-Object { $_ -eq 'patched' }).Count
    $o = @($states | Where-Object { $_ -eq 'original' }).Count

    $state = 'unknown'
    if ($p -eq $states.Count)  { $state = 'patched' }
    elseif ($o -eq $states.Count) { $state = 'original' }
    elseif ($p -gt 0 -and $o -gt 0) { $state = 'partial' }

    return @{ State = $state; Sites = $sites; SiteStates = $states; Error = $null }
}

function Invoke-PatchBinary {
    param([string]$Source, [string]$Destination, [switch]$DryRun)

    $img   = Get-PeImage $Source
    $sites = Resolve-PatchSites $img

    Write-Info ("源文件  {0}" -f $img.Path)
    Write-Note ("SHA-256  {0}" -f $img.Sha256)
    Write-Host ''

    $noteWidth = 0
    foreach ($s in $sites) {
        $w = Get-DisplayWidth $s.Note
        if ($w -gt $noteWidth) { $noteWidth = $w }
    }

    $todo = 0
    foreach ($s in $sites) {
        $st = Get-SiteState $s $img
        $tag = switch ($st) {
            'original' { '待打补丁' }
            'patched'  { '已是补丁' }
            default    { '字节不符' }
        }
        $col = switch ($st) {
            'original' { $CO.Warn }
            'patched'  { $CO.Ok }
            default    { $CO.Err }
        }
        $label = Pad-Display ("  {0,-6} {1}" -f $s.Id, $s.Func) 28
        Write-Host $label -ForegroundColor $CO.Hi -NoNewline
        Write-Host (Pad-Display $s.Note $noteWidth) -ForegroundColor $CO.Text -NoNewline
        Write-Host "  $tag" -ForegroundColor $col
        if ($st -eq 'original') { $todo++ }
        if ($st -eq 'unknown') { throw ("补丁点 {0} 处字节与预期不符，拒绝写入（文件可能已被其它工具修改）" -f $s.Id) }
    }

    Write-Host ''
    if ($todo -eq 0) {
        Write-Ok '所有补丁点均已处于已破解状态，无需修改。'
        return @{ Changed = $false; Sha = $img.Sha256; Path = $null; DryRun = $false }
    }

    if ($DryRun) {
        Write-Warn ("DryRun：跳过写入，本应修改 {0} 处。" -f $todo)
        return @{ Changed = $true; Sha = $null; Path = $null; DryRun = $true }
    }

    foreach ($s in $sites) {
        if ((Get-SiteState $s $img) -eq 'original') {
            [Array]::Copy($s.Patched, 0, $img.Data, $s.Off, $s.Patched.Length)
        }
    }

    [System.IO.File]::WriteAllBytes($Destination, $img.Data)
    $newSha = Get-FileSha256 $Destination
    Write-Ok ("已写入 {0} 处补丁 -> {1}" -f $todo, $Destination)
    Write-Note ("SHA-256  {0}" -f $newSha)
    Write-Log "patch $Source -> $Destination ($todo sites) sha=$newSha"
    return @{ Changed = $true; Sha = $newSha; Path = $Destination; DryRun = $false }
}

# ======================================================================
#  IDM 安装信息
# ======================================================================
function Get-IdmInstallPath {
    $cands = New-Object System.Collections.Generic.List[string]

    try {
        $v = (Get-ItemProperty 'HKCU:\Software\DownloadManager' -ErrorAction Stop).ExePath
        if ($v) { $cands.Add($v) }
    } catch { }

    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($r in $roots) {
        if (-not (Test-Path $r)) { continue }
        foreach ($sub in (Get-ChildItem $r -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty $sub.PSPath -ErrorAction SilentlyContinue
            if (-not $p) { continue }
            if ($p.DisplayName -like '*Internet Download Manager*') {
                if ($p.InstallLocation) { $cands.Add((Join-Path $p.InstallLocation 'IDMan.exe')) }
                if ($p.DisplayIcon) {
                    $ico = ($p.DisplayIcon -replace '^"', '' -replace '",.*$', '' -replace ',\d+$', '')
                    if ($ico) { $cands.Add($ico) }
                }
            }
        }
    }

    foreach ($pf in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if ($pf) { $cands.Add((Join-Path $pf 'Internet Download Manager\IDMan.exe')) }
    }

    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return (Resolve-Path -LiteralPath $c).Path }
    }
    return $null
}

function Get-IdmVersionText([string]$ExePath) {
    try {
        $vi = (Get-Item -LiteralPath $ExePath).VersionInfo
        $fv = $vi.FileVersion
        $m  = [regex]::Match($fv, '^(\d+)[,.]\s*(\d+)[,.]\s*(\d+)[,.]\s*(\d+)')
        if ($m.Success) {
            $a = [int]$m.Groups[1].Value; $b = [int]$m.Groups[2].Value
            $c = [int]$m.Groups[3].Value; $d = [int]$m.Groups[4].Value
            return ('{0}.{1} build {2}  ({0}.{1}.{2}.{3})' -f $a, $b, $c, $d)
        }
        return $fv
    } catch { return '未知' }
}

function Get-IdmRegistry {
    $k = 'HKCU:\Software\DownloadManager'
    $r = @{ Exists = $false; FName = ''; LName = ''; Email = ''; Serial = ''; idmvers = '' }
    if (-not (Test-Path $k)) { return $r }
    $r.Exists = $true
    $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
    if ($p) {
        foreach ($name in @('FName', 'LName', 'Email', 'Serial', 'idmvers')) {
            if ($p.PSObject.Properties.Name -contains $name) { $r[$name] = [string]$p.$name }
        }
    }
    return $r
}

function Get-BackupMeta {
    if (-not (Test-Path $TOOLKIT.BackupMeta)) { return $null }
    try { return (Get-Content $TOOLKIT.BackupMeta -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Save-BackupMeta($Meta) {
    if (-not (Test-Path $TOOLKIT.Home)) { New-Item -ItemType Directory -Path $TOOLKIT.Home -Force | Out-Null }
    $Meta | ConvertTo-Json -Depth 4 | Set-Content -Path $TOOLKIT.BackupMeta -Encoding UTF8
}

function Get-FullState {
    $st = [ordered]@{
        IsAdmin    = (Test-Admin)
        ExePath    = $null
        InstallDir = $null
        Version    = ''
        Sha256     = ''
        KnownBuild = $null
        KnownPatched = $false
        BackupPath = $null
        BackupSha  = ''
        Binary     = 'missing'      # missing | original | patched | partial | unknown
        Sites      = @()
        SitesDone  = 0
        Reg        = (Get-IdmRegistry)
        HostsBlock = $false
        Profile    = $false
    }

    $st.ExePath = Get-IdmInstallPath
    if (-not $st.ExePath) { return $st }

    $st.InstallDir = Split-Path -Parent $st.ExePath
    $st.Version    = Get-IdmVersionText $st.ExePath
    $st.Sha256     = Get-FileSha256 $st.ExePath
    if ($KNOWN_BUILDS.ContainsKey($st.Sha256)) { $st.KnownBuild = $KNOWN_BUILDS[$st.Sha256] }
    elseif (@($KNOWN_PATCHED.Values) -contains $st.Sha256) { $st.KnownPatched = $true }

    $bak = Join-Path $st.InstallDir 'IDMan.exe.bak'
    if (Test-Path -LiteralPath $bak) {
        $st.BackupPath = $bak
        try { $st.BackupSha = Get-FileSha256 $bak } catch { $st.BackupSha = '' }
    }

    try {
        $bs = Get-BinaryState (Get-PeImage $st.ExePath)
        $st.Binary = $bs.State
        $st.Sites  = $bs.Sites
        if ($bs.SiteStates) { $st.SitesDone = @($bs.SiteStates | Where-Object { $_ -eq 'patched' }).Count }
    } catch {
        $st.Binary = 'unknown'
        Write-Log "state error: $($_.Exception.Message)"
    }

    $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if (Test-Path $hosts) {
        $st.HostsBlock = ((Get-Content $hosts -Raw -ErrorAction SilentlyContinue) -like '*IDM Toolkit BEGIN*')
    }

    $prof = $PROFILE.CurrentUserAllHosts
    if ($prof -and (Test-Path $prof)) {
        $st.Profile = ((Get-Content $prof -Raw -ErrorAction SilentlyContinue) -like '*IDM Toolkit*')
    }

    return $st
}

# ======================================================================
#  界面：主面板
# ======================================================================
function Show-Dashboard($st) {
    Write-Banner

    Write-Host ''
    Write-Host '  环境' -ForegroundColor $CO.Acc

    if ($st.IsAdmin) { Write-Kv '管理员权限' '是' $CO.Ok }
    else             { Write-Kv '管理员权限' '否（打补丁前需要提权）' $CO.Warn }

    if (-not $st.ExePath) {
        Write-Kv 'IDM 安装' '未检测到' $CO.Err
        Write-Note '选 [1] 会自动下载官方安装包、静默安装，然后直接破解。'
        Write-Host ''
        Write-Host ('-' * $script:UIWidth) -ForegroundColor $CO.Dim
        Write-Host ''
        Write-Host '  操作' -ForegroundColor $CO.Acc
        Write-Host ''
        Write-Host '   [1]  ' -ForegroundColor $CO.Title -NoNewline
        Write-Host '下载并破解' -ForegroundColor $CO.Hi -NoNewline
        Write-Host '      自动获取官方安装包 -> 安装 -> 打补丁 -> 验证' -ForegroundColor $CO.Dim
        Write-Host '   [2]  ' -ForegroundColor $CO.Title -NoNewline
        Write-Host '从本地安装包安装' -ForegroundColor $CO.Hi -NoNewline
        Write-Host '  指定本机已有的 idman*.exe' -ForegroundColor $CO.Dim
        Write-Host '   [3]  ' -ForegroundColor $CO.Title -NoNewline
        Write-Host '只下载安装包' -ForegroundColor $CO.Hi -NoNewline
        Write-Host '      存到「下载」文件夹，稍后手动安装' -ForegroundColor $CO.Dim
        Write-Host '   [4]  ' -ForegroundColor $CO.Title -NoNewline
        Write-Host '安装全局命令 idm' -ForegroundColor $CO.Hi -NoNewline
        Write-Host '  以后直接输入 idm' -ForegroundColor $CO.Dim
        Write-Host '   [9]  ' -ForegroundColor $CO.Title -NoNewline
        Write-Host '刷新状态' -ForegroundColor $CO.Hi
        Write-Host '   [0]  ' -ForegroundColor $CO.Title -NoNewline
        Write-Host '退出' -ForegroundColor $CO.Hi
        Write-Host ''
        Write-Host ('-' * $script:UIWidth) -ForegroundColor $CO.Dim
        return $false
    }

    Write-Kv 'IDM 版本' $st.Version $CO.Hi
    Write-Kv '安装路径' $st.InstallDir $CO.Text

    if ($st.KnownBuild) { Write-Kv '指纹校验' "与已知原版匹配：$($st.KnownBuild)" $CO.Ok }
    elseif ($st.KnownPatched) { Write-Kv '指纹校验' '与工具输出的破解版字节级一致' $CO.Ok }
    else { Write-Kv '指纹校验' ('未在已知列表中（{0}…），仍将按签名定位打补丁' -f $st.Sha256.Substring(0, 16)) $CO.Warn }

    Write-Host ''
    Write-Host '  状态' -ForegroundColor $CO.Acc

    $binText = switch ($st.Binary) {
        'original' { '原始（未破解）' }
        'patched'  { '已破解' }
        'partial'  { '部分补丁（不完整）' }
        'unknown'  { '无法识别（已被其它工具修改？）' }
        default    { '读取失败' }
    }
    $binColor = switch ($st.Binary) {
        'patched' { $CO.Ok } 'original' { $CO.Warn } default { $CO.Err }
    }
    Write-Kv '二进制状态' $binText $binColor

    if ($st.Sites.Count -gt 0) {
        Write-Kv '补丁点' ("{0} / {1} 已应用" -f $st.SitesDone, $st.Sites.Count) $CO.Text
    }

    if ($st.BackupPath) {
        Write-Kv '原始备份' "有  $($st.BackupPath)" $CO.Ok
    } else {
        Write-Kv '原始备份' '无（首次打补丁时会自动创建）' $CO.Dim
    }

    $r = $st.Reg
    if ($r.Exists) {
        $name = (@($r.FName, $r.LName) | Where-Object { $_ -and $_.Trim() }) -join ' '
        if (-not $name) { $name = '（空）' }
        Write-Kv '注册姓名' $name $(if ($name -eq '（空）') { $CO.Dim } else { $CO.Text })
        Write-Kv '注册邮箱' $(if ($r.Email) { $r.Email } else { '（空）' }) $(if ($r.Email) { $CO.Text } else { $CO.Dim })
        Write-Kv '序列号'   $(if ($r.Serial) { $r.Serial } else { '（空）' }) $(if ($r.Serial) { $CO.Text } else { $CO.Dim })
        $verColor = if ($r.idmvers -like '*Full*') { $CO.Ok } elseif ($r.idmvers -like '*Trial*') { $CO.Warn } else { $CO.Text }
        Write-Kv 'idmvers' $(if ($r.idmvers) { $r.idmvers } else { '（空）' }) $verColor
    } else {
        Write-Kv '注册表' 'HKCU\Software\DownloadManager 不存在' $CO.Dim
    }

    Write-Kv '屏蔽更新' $(if ($st.HostsBlock) { '已开启（hosts）' } else { '未开启' }) $(if ($st.HostsBlock) { $CO.Ok } else { $CO.Dim })
    Write-Kv '全局命令' $(if ($st.Profile) { '已安装（直接输入 idm）' } else { '未安装' }) $(if ($st.Profile) { $CO.Ok } else { $CO.Dim })

    Write-Host ''
    Write-Host ('-' * $script:UIWidth) -ForegroundColor $CO.Dim
    Write-Host ''
    Write-Host '  操作' -ForegroundColor $CO.Acc
    Write-Host ''
    Write-Host '   [1]  ' -ForegroundColor $CO.Title -NoNewline
    Write-Host '一键破解' -ForegroundColor $CO.Hi -NoNewline
    Write-Host '      备份 + 打补丁 + 写入注册身份 + 启动验证' -ForegroundColor $CO.Dim
    Write-Host '   [2]  ' -ForegroundColor $CO.Title -NoNewline
    Write-Host '仅打补丁' -ForegroundColor $CO.Hi -NoNewline
    Write-Host '      只修改 IDMan.exe（自动备份）' -ForegroundColor $CO.Dim
    Write-Host '   [3]  ' -ForegroundColor $CO.Title -NoNewline
    Write-Host '设置注册身份' -ForegroundColor $CO.Hi -NoNewline
    Write-Host '  姓名 / 邮箱 / 序列号' -ForegroundColor $CO.Dim
    Write-Host '   [4]  ' -ForegroundColor $CO.Title -NoNewline
    Write-Host '屏蔽自动更新' -ForegroundColor $CO.Hi -NoNewline
    Write-Host '  写 hosts，阻止联网校验与更新' -ForegroundColor $CO.Dim
    Write-Host '   [5]  ' -ForegroundColor $CO.Title -NoNewline
    Write-Host '重置试用期' -ForegroundColor $CO.Hi -NoNewline
    Write-Host '      清理注册表里的试用计数' -ForegroundColor $CO.Dim
    Write-Host '   [6]  ' -ForegroundColor $CO.Title -NoNewline
    Write-Host '安装全局命令 idm' -ForegroundColor $CO.Hi -NoNewline
    Write-Host '  以后直接输入 idm 打开本界面' -ForegroundColor $CO.Dim
    Write-Host '   [7]  ' -ForegroundColor $CO.Title -NoNewline
    Write-Host '还原原始程序' -ForegroundColor $CO.Hi -NoNewline
    Write-Host '  从 .bak 恢复 IDMan.exe' -ForegroundColor $CO.Dim
    Write-Host '   [8]  ' -ForegroundColor $CO.Title -NoNewline
    Write-Host '完全卸载 / 回滚' -ForegroundColor $CO.Hi -NoNewline
    Write-Host '  还原程序 + 清理注册表 + hosts' -ForegroundColor $CO.Dim
    Write-Host '   [9]  ' -ForegroundColor $CO.Title -NoNewline
    Write-Host '刷新状态' -ForegroundColor $CO.Hi
    Write-Host '   [0]  ' -ForegroundColor $CO.Title -NoNewline
    Write-Host '退出' -ForegroundColor $CO.Hi
    Write-Host ''
    Write-Host ('-' * $script:UIWidth) -ForegroundColor $CO.Dim
    return $true
}

# ======================================================================
#  功能实现
# ======================================================================
function Stop-Idm {
    $p = Get-Process -Name 'IDMan' -ErrorAction SilentlyContinue
    if ($p) {
        Write-Info '正在关闭运行中的 IDM ...'
        $p | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Write-Ok '已关闭。'
    } else {
        Write-Info 'IDM 未在运行。'
    }
}

function Backup-IdmBinary([string]$ExePath, [string]$Version) {
    $bak = Join-Path (Split-Path -Parent $ExePath) 'IDMan.exe.bak'
    if (Test-Path -LiteralPath $bak) {
        $bsha = Get-FileSha256 $bak
        Write-Info "已存在备份：$bak"
        Write-Note "SHA-256  $bsha"
        if (-not $KNOWN_BUILDS.ContainsKey($bsha)) {
            Write-Warn '备份的指纹不在已知版本列表中 —— 建议确认后再继续。'
        }
        return $bak
    }
    Copy-Item -LiteralPath $ExePath -Destination $bak -Force
    $sha = Get-FileSha256 $bak
    Write-Ok "已备份原始程序 -> $bak"
    Write-Note "SHA-256  $sha"

    Save-BackupMeta ([ordered]@{
        Version    = $Version
        Source     = $ExePath
        BackupPath = $bak
        Sha256     = $sha
        CreatedAt  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        Toolkit    = $TOOLKIT.Version
    })
    return $bak
}

function Set-IdmIdentity {
    param([string]$FirstName, [string]$LastName, [string]$Email, [string]$Serial)

    if ($Serial.Length -ne 23 -or $Serial[5] -ne '-' -or $Serial[11] -ne '-' -or $Serial[17] -ne '-') {
        throw "序列号必须是 23 个字符、第 6/12/18 位为连字符（形如 ABCDE-FGHIJ-KLMNO-PQRST），当前为 '$Serial'"
    }

    $k = 'HKCU:\Software\DownloadManager'
    if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }

    Set-ItemProperty $k -Name 'FName' -Value $FirstName -Type String
    Set-ItemProperty $k -Name 'LName' -Value $LastName  -Type String
    Set-ItemProperty $k -Name 'Email' -Value $Email     -Type String
    Set-ItemProperty $k -Name 'Serial' -Value $Serial   -Type String

    Write-Ok "FName   = $FirstName"
    Write-Ok "LName   = $LastName"
    Write-Ok "Email   = $Email"
    Write-Ok "Serial  = $Serial"
    Write-Log "identity set: $FirstName $LastName <$Email> $Serial"
}

function New-RandomSerial {
    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $rnd = [Random]::new()
    $parts = @()
    for ($g = 0; $g -lt 4; $g++) {
        $s = ''
        for ($i = 0; $i -lt 5; $i++) { $s += $alphabet[$rnd.Next($alphabet.Length)] }
        $parts += $s
    }
    return ($parts -join '-')
}

function Set-HostsBlock {
    param([switch]$Remove, [switch]$Quiet)

    $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if (-not (Test-Path $hosts)) { throw "找不到 hosts 文件：$hosts" }

    $begin   = '# >>> IDM Toolkit BEGIN >>>'
    $end     = '# <<< IDM Toolkit END <<<'
    $domains = @(
        'internetdownloadmanager.com', 'www.internetdownloadmanager.com',
        'secure.internetdownloadmanager.com', 'registeridm.com', 'www.registeridm.com',
        'tonec.com', 'www.tonec.com'
    )

    $kept = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($line in [System.IO.File]::ReadAllLines($hosts)) {
        $t = $line.Trim()
        if ($t -eq $begin) { $skip = $true;  continue }
        if ($t -eq $end)   { $skip = $false; continue }
        if (-not $skip) { $kept.Add($line) }
    }

    if (-not $Remove) {
        $kept.Add('')
        $kept.Add($begin)
        foreach ($d in $domains) { $kept.Add("127.0.0.1`t$d") }
        $kept.Add($end)
    }

    Copy-Item $hosts "$hosts.idmtoolkit.bak" -Force -ErrorAction SilentlyContinue
    [System.IO.File]::WriteAllLines($hosts, $kept, (New-Object Text.UTF8Encoding($false)))
    try { & ipconfig /flushdns | Out-Null } catch { }

    if ($Remove) {
        if (-not $Quiet) { Write-Ok '已移除 hosts 屏蔽规则。' }
        Write-Log 'hosts unblock'
    } else {
        if (-not $Quiet) { Write-Ok ("已屏蔽 {0} 个域名（含联网序列号校验与更新服务器）。" -f $domains.Count) }
        Write-Log 'hosts block'
    }
}

function Reset-IdmTrial {
    $k = 'HKCU:\Software\DownloadManager'
    if (-not (Test-Path $k)) { Write-Warn '注册表键不存在，无需重置。'; return }

    $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
    if (-not $p) { Write-Warn '无法读取注册表。'; return }

    $removed = @()
    foreach ($name in $p.PSObject.Properties.Name) {
        if ($name -like 'checkRes*') {
            Remove-ItemProperty -Path $k -Name $name -ErrorAction SilentlyContinue
            $removed += $name
        }
    }
    if ($removed.Count -gt 0) {
        Write-Ok ("已删除 {0} 个试用计数项：{1}" -f $removed.Count, ($removed -join ', '))
    } else {
        Write-Info '未发现 checkRes* 试用计数项。'
    }

    foreach ($hklm in @('HKLM:\SOFTWARE\DownloadManager', 'HKLM:\SOFTWARE\WOW6432Node\DownloadManager')) {
        if (Test-Path $hklm) {
            Remove-Item $hklm -Recurse -Force -ErrorAction SilentlyContinue
            Write-Ok "已删除 $hklm"
        }
    }
    Write-Log "trial reset (removed $($removed.Count) values)"
}

function Install-GlobalCommand {
    $prof = $PROFILE.CurrentUserAllHosts
    if (-not $prof) { throw '无法确定 PowerShell profile 路径。' }

    $dir = Split-Path -Parent $prof
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $begin = '# >>> IDM Toolkit >>>'
    $end   = '# <<< IDM Toolkit <<<'

    $body = @(
        $begin,
        'function idm {',
        "    `$p = Join-Path `$env:LOCALAPPDATA 'IdmToolkit\idm.ps1'",
        "    if (-not (Test-Path `$p)) {",
        "        New-Item -ItemType Directory -Force -Path (Split-Path `$p) | Out-Null",
        "        Invoke-RestMethod '$($TOOLKIT.RawUrl)' -OutFile `$p",
        "        Remove-Item `$p -Stream Zone.Identifier -ErrorAction SilentlyContinue",
        '    }',
        "    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File `$p",
        '}',
        'function idm-update {',
        "    `$p = Join-Path `$env:LOCALAPPDATA 'IdmToolkit\idm.ps1'",
        "    New-Item -ItemType Directory -Force -Path (Split-Path `$p) | Out-Null",
        "    Invoke-RestMethod '$($TOOLKIT.RawUrl)' -OutFile `$p",
        "    Write-Host 'IDM Toolkit 已更新。' -ForegroundColor Green",
        '}',
        $end
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $skip  = $false
    if (Test-Path $prof) {
        foreach ($line in [System.IO.File]::ReadAllLines($prof)) {
            $t = $line.Trim()
            if ($t -eq $begin) { $skip = $true;  continue }
            if ($t -eq $end)   { $skip = $false; continue }
            if (-not $skip) { $lines.Add($line) }
        }
    }
    $lines.Add('')
    foreach ($l in $body) { $lines.Add($l) }

    [System.IO.File]::WriteAllLines($prof, $lines, (New-Object Text.UTF8Encoding($true)))

    # 同时把当前脚本缓存到本地，供 idm 命令离线使用
    if (-not (Test-Path $TOOLKIT.Home)) { New-Item -ItemType Directory -Path $TOOLKIT.Home -Force | Out-Null }
    if ($PSCommandPath -and (Test-Path $PSCommandPath) -and ($PSCommandPath -ne $TOOLKIT.CachePath)) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $TOOLKIT.CachePath -Force
        Write-Ok "已缓存脚本 -> $($TOOLKIT.CachePath)"
    }

    Write-Ok "已写入 PowerShell profile -> $prof"
    Write-Note '新开一个 PowerShell 窗口，之后直接输入：idm'
    Write-Log "global command installed -> $prof"
}

function Uninstall-GlobalCommand {
    $prof = $PROFILE.CurrentUserAllHosts
    if (-not $prof -or -not (Test-Path $prof)) { return }
    $begin = '# >>> IDM Toolkit >>>'
    $end   = '# <<< IDM Toolkit <<<'
    $lines = New-Object System.Collections.Generic.List[string]
    $skip  = $false
    foreach ($line in [System.IO.File]::ReadAllLines($prof)) {
        $t = $line.Trim()
        if ($t -eq $begin) { $skip = $true;  continue }
        if ($t -eq $end)   { $skip = $false; continue }
        if (-not $skip) { $lines.Add($line) }
    }
    [System.IO.File]::WriteAllLines($prof, $lines, (New-Object Text.UTF8Encoding($true)))
    Write-Ok '已移除全局命令 idm。'
}

function Restore-IdmBinary($st) {
    if (-not $st.BackupPath) { throw '没有找到备份（IDMan.exe.bak），无法还原。' }
    Stop-Idm
    Copy-Item -LiteralPath $st.BackupPath -Destination $st.ExePath -Force
    $sha = Get-FileSha256 $st.ExePath
    Write-Ok "已还原 -> $($st.ExePath)"
    Write-Note "SHA-256  $sha"
    if ($KNOWN_BUILDS.ContainsKey($sha)) { Write-Ok "指纹匹配：$($KNOWN_BUILDS[$sha])" }
    Write-Log "restored from $($st.BackupPath) sha=$sha"
}

function Test-IdmRunning($st) {
    Write-Info '正在启动 IDM 进行验证 ...'
    Start-Process -FilePath $st.ExePath | Out-Null
    Start-Sleep -Seconds 12

    $p = Get-Process -Name 'IDMan' -ErrorAction SilentlyContinue
    if (-not $p) {
        Write-Err 'IDM 未能保持运行 —— 请用「还原原始程序」回滚，或手动检查。'
        return $false
    }

    Write-Ok "IDM 正在运行 (PID $($p[0].Id))"
    $r = Get-IdmRegistry
    Write-Info "idmvers = $($r.idmvers)"
    if ($r.idmvers -like '*Full*') {
        Write-Ok '授权状态：Full（已注册）'
        return $true
    }
    Write-Warn 'idmvers 未显示 Full —— 请打开 IDM 的「关于」窗口人工确认。'
    return $false
}

# ======================================================================
#  交互流程
# ======================================================================
# 核心破解流程（前提：IDM 已安装 + 已是管理员）
function Invoke-CrackCore($st, [int]$StepBase = 2, [int]$StepTotal = 5) {

    Write-Step ("[{0}/{1}] 停止 IDM 并备份原始程序" -f $StepBase, $StepTotal)
    Stop-Idm
    Backup-IdmBinary $st.ExePath $st.Version | Out-Null

    Write-Step ("[{0}/{1}] 分析并定位补丁点（签名扫描）" -f ($StepBase + 1), $StepTotal)
    $tmp = Join-Path $env:TEMP ('IDMan.patched.{0}.exe' -f ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
    $res = Invoke-PatchBinary -Source $st.ExePath -Destination $tmp

    Write-Step ("[{0}/{1}] 安装补丁" -f ($StepBase + 2), $StepTotal)
    if ($res.Changed -and $res.Path) {
        Copy-Item -LiteralPath $res.Path -Destination $st.ExePath -Force
        $installed = Get-FileSha256 $st.ExePath
        Write-Ok "已安装 -> $($st.ExePath)"
        Write-Note "SHA-256  $installed"
        if ($installed -ne $res.Sha) { throw '安装后校验失败：文件哈希与写入结果不一致。' }
    } else {
        Write-Info '无需修改，跳过。'
    }
    if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }

    Write-Step ("[{0}/{1}] 写入注册身份并验证" -f ($StepBase + 3), $StepTotal)
    $r = $st.Reg
    $serial = if ($r.Serial -and $r.Serial.Length -eq 23) { $r.Serial } else { New-RandomSerial }
    $first  = if ($r.FName) { $r.FName } else { 'yuuki' }
    $last   = if ($r.LName) { $r.LName } else { ' ' }
    $email  = if ($r.Email) { $r.Email } else { 'yuuki@example.com' }
    Set-IdmIdentity -FirstName $first -LastName $last -Email $email -Serial $serial

    Write-Host ''
    Test-IdmRunning $st | Out-Null
}

function Invoke-OneClick($st) {
    Clear-Screen
    Write-Banner
    Write-Host ''
    Write-Host '  一键破解' -ForegroundColor $CO.Acc
    Write-Host ''

    if (-not $st.IsAdmin) { throw '需要管理员权限。' }
    if (-not $st.ExePath) { throw '未检测到 IDM 安装。' }

    Write-Step '[1/5] 环境检查'
    Write-Ok "IDM 版本  $($st.Version)"
    Write-Ok "主程序    $($st.ExePath)"
    if ($st.KnownBuild) { Write-Ok "指纹匹配  $($st.KnownBuild)" }
    elseif ($st.KnownPatched) { Write-Ok '指纹匹配  工具输出的破解版' }
    else { Write-Warn '指纹不在已知列表中，将按签名定位打补丁。' }

    Invoke-CrackCore $st 2 5

    Write-Host ''
    Write-Rule '='
    Write-Host '  完成' -ForegroundColor $CO.Ok
    Write-Rule '='
    Pause-Any
}

function Invoke-PatchOnly($st) {
    Clear-Screen
    Write-Banner
    Write-Host ''
    Write-Host '  仅打补丁' -ForegroundColor $CO.Acc
    Write-Host ''

    if (-not $st.IsAdmin) { throw '需要管理员权限。' }
    if (-not $st.ExePath) { throw '未检测到 IDM 安装。' }

    Write-Step '[1/3] 停止 IDM 并备份'
    Stop-Idm
    Backup-IdmBinary $st.ExePath $st.Version | Out-Null

    Write-Step '[2/3] 定位补丁点'
    $tmp = Join-Path $env:TEMP ('IDMan.patched.{0}.exe' -f ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
    $res = Invoke-PatchBinary -Source $st.ExePath -Destination $tmp

    Write-Step '[3/3] 安装补丁'
    if ($res.Changed -and $res.Path) {
        Copy-Item -LiteralPath $res.Path -Destination $st.ExePath -Force
        Write-Ok '完成。可回到主菜单选择 [3] 写入注册身份。'
    } else {
        Write-Info '无需修改。'
    }
    if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    Pause-Any
}

# 未安装 IDM 时的选项 1：自动下载 + 安装 + 破解
function Invoke-DownloadAndCrack($st) {
    Clear-Screen
    Write-Banner
    Write-Host ''
    Write-Host '  下载并破解' -ForegroundColor $CO.Acc
    Write-Host ''

    if (-not $st.IsAdmin) { throw '需要管理员权限。' }

    Write-Step '[1/6] 获取 IDM 官方安装包'
    $destDir   = Join-Path $env:USERPROFILE 'Downloads'
    $installer = Get-IdmInstaller -DestDir $destDir -Url $script:OptUrl

    Write-Step '[2/6] 安装 IDM'
    Install-IdmFromInstaller -Path $installer | Out-Null

    Write-Step '[3/6] 重新检测安装'
    $st2 = Get-FullState
    if (-not $st2.ExePath) { throw '安装完成后仍未检测到 IDM，请手动确认安装结果。' }
    Write-Ok "IDM 版本  $($st2.Version)"
    Write-Ok "主程序    $($st2.ExePath)"
    if ($st2.KnownBuild) { Write-Ok "指纹匹配  $($st2.KnownBuild)" }
    else { Write-Warn '指纹不在已知列表中，将按签名定位打补丁。' }

    Invoke-CrackCore $st2 4 6

    Write-Host ''
    Write-Rule '='
    Write-Host '  完成' -ForegroundColor $CO.Ok
    Write-Rule '='
    Write-Note "安装包已保留在：$installer"
    Pause-Any
}

# 未安装 IDM 时的选项 2：用本机已有的安装包
function Invoke-InstallFromLocal($st) {
    Clear-Screen
    Write-Banner
    Write-Host ''
    Write-Host '  从本地安装包安装' -ForegroundColor $CO.Acc
    Write-Host ''

    if (-not $st.IsAdmin) { throw '需要管理员权限。' }
    Write-Note '可以输入完整路径，也可以直接把文件拖进这个窗口。'
    Write-Host ''
    $p = Read-Host '  安装包路径（idman*.exe）'
    if (-not $p) { return }
    $p = $p.Trim().Trim('"').Trim("'")

    $installer = Get-IdmInstaller -LocalPath $p
    Write-Host ''
    Install-IdmFromInstaller -Path $installer | Out-Null

    $st2 = Get-FullState
    if ($st2.ExePath) {
        Write-Host ''
        Write-Ok "IDM $($st2.Version)  ->  $($st2.ExePath)"
        Write-Note '回到主菜单选 [1] 即可一键破解。'
    }
    Pause-Any
}

# 未安装 IDM 时的选项 3：只下载，不安装
function Invoke-DownloadOnly {
    Clear-Screen
    Write-Banner
    Write-Host ''
    Write-Host '  只下载安装包' -ForegroundColor $CO.Acc
    Write-Host ''

    $destDir   = Join-Path $env:USERPROFILE 'Downloads'
    $installer = Get-IdmInstaller -DestDir $destDir -Url $script:OptUrl

    Write-Host ''
    Write-Rule '='
    Write-Ok "安装包：$installer"
    Write-Note '双击即可手动安装。'
    Write-Rule '='
    Pause-Any
}

function Invoke-Identity($st) {
    Clear-Screen
    Write-Banner
    Write-Host ''
    Write-Host '  设置注册身份' -ForegroundColor $CO.Acc
    Write-Host ''
    Write-Note 'IDM「关于」窗口显示的姓名/邮箱直接读取这四个值；'
    Write-Note '序列号只要满足 23 字符、连字符在第 6/12/18 位即可。'
    Write-Host ''

    $r = $st.Reg
    $defFirst  = if ($r.FName)  { $r.FName }  else { 'yuuki' }
    $defLast   = if ($r.LName)  { $r.LName }  else { ' ' }
    $defEmail  = if ($r.Email)  { $r.Email }  else { 'yuuki@example.com' }
    $defSerial = if ($r.Serial) { $r.Serial } else { (New-RandomSerial) }

    $first  = Read-Host "  名字   [$defFirst]"
    if (-not $first)  { $first = $defFirst }
    $last   = Read-Host "  姓氏   [$defLast]"
    if (-not $last)   { $last = $defLast }
    $email  = Read-Host "  邮箱   [$defEmail]"
    if (-not $email)  { $email = $defEmail }
    $serial = Read-Host "  序列号 [$defSerial]"
    if (-not $serial) { $serial = $defSerial }

    Write-Host ''
    Set-IdmIdentity -FirstName $first -LastName $last -Email $email -Serial $serial
    Pause-Any
}

function Invoke-Restore($st) {
    Clear-Screen
    Write-Banner
    Write-Host ''
    Write-Host '  还原原始程序' -ForegroundColor $CO.Acc
    Write-Host ''
    if (-not $st.BackupPath) { Write-Err '没有备份文件，无法还原。'; Pause-Any; return }
    if (-not (Confirm-Action "确定要用备份覆盖 $($st.ExePath) 吗？")) { return }
    Write-Host ''
    Restore-IdmBinary $st
    Pause-Any
}

function Invoke-FullUninstall($st) {
    Clear-Screen
    Write-Banner
    Write-Host ''
    Write-Host '  完全卸载 / 回滚' -ForegroundColor $CO.Acc
    Write-Host ''
    Write-Warn '将执行：还原 IDMan.exe、清理注册身份、移除 hosts 屏蔽、移除全局命令。'
    if (-not (Confirm-Action '确定继续吗？')) { return }
    Write-Host ''

    if ($st.BackupPath) { Restore-IdmBinary $st } else { Write-Warn '没有备份，跳过还原。' }

    $k = 'HKCU:\Software\DownloadManager'
    if (Test-Path $k) {
        foreach ($n in @('FName', 'LName', 'Email', 'Serial')) {
            Remove-ItemProperty -Path $k -Name $n -ErrorAction SilentlyContinue
        }
        Write-Ok '已清理注册身份。'
    }

    if ($st.HostsBlock) { Set-HostsBlock -Remove }
    Uninstall-GlobalCommand
    Pause-Any
}

# ======================================================================
#  提权 / 自举
# ======================================================================
function Copy-SelfToCache {
    if (-not (Test-Path $TOOLKIT.Home)) { New-Item -ItemType Directory -Path $TOOLKIT.Home -Force | Out-Null }

    if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
        if ($PSCommandPath -ne $TOOLKIT.CachePath) {
            Copy-Item -LiteralPath $PSCommandPath -Destination $TOOLKIT.CachePath -Force
        }
        return $true
    }

    if ($TOOLKIT.RawUrl -like '*REPLACE_ME*') {
        Write-Err '脚本里还没有配置你自己的仓库地址（$TOOLKIT.RawUrl）。'
        Write-Note '把 idm.ps1 顶部配置区的 yuukiiiii0228 / idm-toolkit 改成你的 GitHub 用户名和仓库名。'
        return $false
    }

    try {
        Invoke-RestMethod -Uri $TOOLKIT.RawUrl -OutFile $TOOLKIT.CachePath -UseBasicParsing
        Remove-ZoneMark $TOOLKIT.CachePath
        return $true
    } catch {
        Write-Err "下载脚本失败：$($_.Exception.Message)"
        return $false
    }
}

function Restart-Elevated {
    if (-not (Copy-SelfToCache)) {
        Pause-Any '按 Enter 退出'
        return $false
    }

    Write-Host ''
    Write-Info '当前不是管理员，正在以管理员身份重新启动 ...'

    $psArgs = @(
        '-NoProfile', '-NoLogo', '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + $TOOLKIT.CachePath + '"')
    )
    if ($DryRun) { $psArgs += '-DryRun' }
    if ($Status) { $psArgs += '-Status' }
    if ($Yes)    { $psArgs += '-Yes' }
    if ($Url)    { $psArgs += @('-Url', ('"' + $Url + '"')) }
    if ($InstallerPath) { $psArgs += @('-InstallerPath', ('"' + $InstallerPath + '"')) }
    if ($Download) { $psArgs += '-Download' }
    if ($Patch)    { $psArgs += '-Patch' }

    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ($psArgs -join ' ') | Out-Null
        Write-Ok '已在新窗口中启动（请在 UAC 提示中允许）。'
    } catch {
        Write-Err "提权失败：$($_.Exception.Message)"
        Pause-Any '按 Enter 退出'
    }
    return $false
}

# ======================================================================
#  主循环
# ======================================================================
function Start-Interactive {
    while ($true) {
        Clear-Screen
        $st = Get-FullState
        $hasIdm = Show-Dashboard $st
        Write-Host ''

        $choice = Read-Host '  选择操作'
        Write-Host ''

        try {
            if (-not $hasIdm) {
                # ---------- 未安装 IDM ----------
                switch ($choice) {
                    '1' { Invoke-DownloadAndCrack $st }
                    '2' { Invoke-InstallFromLocal $st }
                    '3' { Invoke-DownloadOnly }
                    '4' { Install-GlobalCommand; Pause-Any }
                    '9' { }
                    '0' { return }
                    ''  { }
                    default { Write-Warn "未知选项：$choice"; Pause-Any }
                }
            } else {
                # ---------- 已安装 IDM ----------
                switch ($choice) {
                    '1' { Invoke-OneClick $st }
                    '2' { Invoke-PatchOnly $st }
                    '3' { Invoke-Identity $st }
                    '4' {
                        $st2 = Get-FullState
                        if ($st2.HostsBlock) {
                            if (Confirm-Action '当前已开启屏蔽，是否关闭？') { Set-HostsBlock -Remove } else { Write-Info '保持不变。' }
                        } else {
                            Set-HostsBlock
                        }
                        Pause-Any
                    }
                    '5' { Reset-IdmTrial; Pause-Any }
                    '6' { Install-GlobalCommand; Pause-Any }
                    '7' { Invoke-Restore $st }
                    '8' { Invoke-FullUninstall $st }
                    '9' { }
                    '0' { return }
                    ''  { }
                    default { Write-Warn "未知选项：$choice"; Pause-Any }
                }
            }
        } catch {
            Write-Host ''
            Write-Err $_.Exception.Message
            Write-Log "ERROR: $($_.Exception.Message)"
            Pause-Any
        }
    }
}

# ======================================================================
#  入口
# ======================================================================
try {
    if (-not (Test-Path $TOOLKIT.Home)) { New-Item -ItemType Directory -Path $TOOLKIT.Home -Force | Out-Null }
} catch { }

$script:OptUrl       = $Url
$script:OptInstaller = $InstallerPath

Write-Log "=== start v$($TOOLKIT.Version) admin=$(Test-Admin) dry=$DryRun ==="

if ($Status) {
    $st = Get-FullState
    Show-Dashboard $st | Out-Null
    return
}

if (-not (Test-Admin) -and -not $NoElevate) {
    Restart-Elevated | Out-Null
    return
}

if ($Download -or $Patch -or $Restore -or $Uninstall) {
    try {
        $st = Get-FullState
        if ($Download) {
            if ($InstallerPath) {
                $installer = Get-IdmInstaller -LocalPath $script:OptInstaller
                Install-IdmFromInstaller -Path $installer | Out-Null
                $st = Get-FullState
            }
            if (-not $st.ExePath) {
                Invoke-DownloadAndCrack $st
            } else {
                Write-Info '已检测到 IDM 安装，直接执行破解流程。'
                Invoke-CrackCore $st 1 4
            }
        }
        elseif ($Patch) {
            if (-not $st.ExePath) { throw '未检测到 IDM 安装。' }
            Stop-Idm
            Backup-IdmBinary $st.ExePath $st.Version | Out-Null
            $tmp = Join-Path $env:TEMP ('IDMan.patched.{0}.exe' -f ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
            $res = Invoke-PatchBinary -Source $st.ExePath -Destination $tmp -DryRun:$DryRun
            if ($res.Changed -and $res.Path) { Copy-Item -LiteralPath $res.Path -Destination $st.ExePath -Force }
            if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        }
        elseif ($Restore) { Restore-IdmBinary $st }
        elseif ($Uninstall) { Invoke-FullUninstall $st }
    } catch {
        Write-Err $_.Exception.Message
    }
    return
}

Start-Interactive
