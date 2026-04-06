param([int]$Port = 8080)
Add-Type -AssemblyName System.Web

function Run([string]$cmd, [string[]]$args) {
    try { $out = & $cmd @args 2>/dev/null; return ($out -join "`n").Trim() }
    catch { return "N/A" }
}

function Get-HardwareInfo {
    $cpuModel="N/A"; $cpuCores=0; $cpuArch="N/A"
    try {
        $lines=$( Get-Content /proc/cpuinfo -EA Stop )
        $cpuModel=(($lines|Select-String "model name"|Select-Object -First 1) -replace "model name\s*:\s*","").Trim()
        $cpuCores=($lines|Select-String "^processor").Count
        $cpuArch=Run "uname" @("-m")
    } catch {}
    $memTotalMB="N/A"; $memAvailMB="N/A"; $memSpeed="N/A"
    try {
        $mi=Get-Content /proc/meminfo -EA Stop
        $totalKB = [long](($mi | Select-String '^MemTotal')     -replace '\D','')
        $availKB = [long](($mi | Select-String '^MemAvailable') -replace '\D','')
        $memTotalMB = "$([math]::Round($totalKB/1024)) MB"
        $memAvailMB = "$([math]::Round($availKB/1024)) MB"
        $spd=Run "dmidecode" @("-t","memory")|Select-String "Speed:"|Select-Object -First 1
        if($spd){$memSpeed=($spd -replace ".*Speed:\s*","").Trim()}
    } catch {}
    $mbMfr="N/A"; $mbModel="N/A"
    try {
        $mbMfr=(Get-Content /sys/class/dmi/id/board_vendor -EA SilentlyContinue|Select-Object -First 1).Trim()
        $mbModel=(Get-Content /sys/class/dmi/id/board_name -EA SilentlyContinue|Select-Object -First 1).Trim()
    } catch {}
    $storage=@()
    try {
        $dfLines=(df -h --output=source,size,avail,fstype 2>/dev/null)|Select-Object -Skip 1
        foreach($line in $dfLines){
            $p=$line -split '\s+'|Where-Object{$_ -ne ""}
            if($p.Count -ge 4 -and $p[0] -match "^/dev/"){
                $storage+=[PSCustomObject]@{device=$p[0];size=$p[1];free=$p[2];fstype=$p[3]}
            }
        }
    } catch {}
    return @{cpu=@{model=$cpuModel;cores=$cpuCores;architecture=$cpuArch};memory=@{total=$memTotalMB;available=$memAvailMB;speed=$memSpeed};motherboard=@{manufacturer=$mbMfr;model=$mbModel};storage=@($storage)}
}

function Get-OSInfo {
    $osName="N/A"; $osVer="N/A"; $kernel="N/A"; $uptime="N/A"
    try {
        $rel=Get-Content /etc/os-release -EA Stop
        $osName=(($rel|Select-String '^NAME=') -replace 'NAME="?([^"]+)"?','$1').Trim()
        $v=(($rel|Select-String '^VERSION=') -replace 'VERSION="?([^"]+)"?','$1').Trim()
        $vid=(($rel|Select-String '^VERSION_ID=') -replace 'VERSION_ID="?([^"]+)"?','$1').Trim()
        $osVer=if($v){$v}else{$vid}
    } catch {}
    $kernel=Run "uname" @("-r")
    $uptime=Run "uptime" @("-p")
    $nets=@()
    try {
        $ipOut=(ip addr show 2>/dev/null) -join "`n"
        $ifaces=[regex]::Matches($ipOut,'^\d+:\s+(\w+):','Multiline')|ForEach-Object{$_.Groups[1].Value}
        foreach($iface in $ifaces){
            if($iface -eq "lo"){continue}
            $ipM=[regex]::Match($ipOut,"inet\s+([\d./]+)[^\n]*scope global[^\n]*$iface")
            $ip=if($ipM.Success){$ipM.Groups[1].Value}else{"N/A"}
            $macB=(ip link show $iface 2>/dev/null) -join " "
            $macM=[regex]::Match($macB,"link/ether\s+([0-9a-f:]+)")
            $mac=if($macM.Success){$macM.Groups[1].Value}else{"N/A"}
            $nets+=[PSCustomObject]@{interface=$iface;ip=$ip;mac=$mac}
        }
    } catch {}
    return @{name=$osName;version=$osVer;kernel=$kernel;uptime=$uptime;network=@($nets)}
}

function Get-ProcessList {
    $procs=Get-Process -EA SilentlyContinue|Sort-Object CPU -Descending|Select-Object -First 50|ForEach-Object{
        [PSCustomObject]@{name=$_.Name;pid=$_.Id;cpu=[math]::Round($_.CPU,2);memory=[math]::Round($_.WorkingSet64/1MB,2)}
    }
    return @($procs)
}

function Get-DirectoryListing([string]$Path=$HOME){
    if(!(Test-Path $Path -EA SilentlyContinue)){return @{error="Path not found: $Path"}}
    $items=Get-ChildItem -Path $Path -Force -EA SilentlyContinue|ForEach-Object{
        [PSCustomObject]@{name=$_.Name;type=if($_.PSIsContainer){"directory"}else{"file"};size=if($_.PSIsContainer){"-"}else{"$([math]::Round($_.Length/1KB,2)) KB"};modified=$_.LastWriteTime.ToString("yyyy-MM-dd HH:mm")}
    }
    return @{path=$Path;parent=(Split-Path $Path -Parent);items=@($items)}
}

function New-FileItem([string]$Path,[string]$Type){
    try{
        $itemType = if($Type -eq "file"){"File"}else{"Directory"}
        New-Item -Path $Path -ItemType $itemType -Force | Out-Null
        return @{success=$true;message="Created: $Path"}
    }
    catch{return @{success=$false;message=$_.Exception.Message}}
}

function Remove-FileItem([string]$Path){
    try{Remove-Item -Path $Path -Recurse -Force -EA Stop;return @{success=$true;message="Deleted: $Path"}}
    catch{return @{success=$false;message=$_.Exception.Message}}
}

function Rename-FileItem([string]$Path,[string]$NewName){
    try{Rename-Item -Path $Path -NewName $NewName -Force -EA Stop;return @{success=$true;message="Renamed to: $NewName"}}
    catch{return @{success=$false;message=$_.Exception.Message}}
}

function Search-Files([string]$SearchPath,[string]$Query,[bool]$SearchContent=$false){
    $results=@()
    try{
        if($SearchContent){
            $found=grep -rl $Query $SearchPath 2>/dev/null|Select-Object -First 100
            foreach($f in $found){if($f){$results+=[PSCustomObject]@{path=$f;matchType="Content Match"}}}
        }else{
            $found=find $SearchPath -iname "*$Query*" 2>/dev/null|Select-Object -First 100
            foreach($f in $found){if($f){$results+=[PSCustomObject]@{path=$f;matchType="Name Match"}}}
        }
    } catch {}
    return @{results=@($results);count=$results.Count}
}

function New-BootableDrive([string]$IsoPath,[string]$Device){
    if(!(Test-Path $IsoPath -EA SilentlyContinue)){return @{success=$false;message="ISO not found: $IsoPath"}}
    if(!(Test-Path $Device -EA SilentlyContinue)){return @{success=$false;message="Device not found: $Device"}}
    try{
        $out=& dd if=$IsoPath of=$Device bs=4M status=none oflag=sync 2>&1
        return @{success=$true;message="Bootable drive created on $Device";output="$out"}
    } catch{return @{success=$false;message=$_.Exception.Message}}
}

function Format-StorageDrive([string]$Device,[string]$FileSystem="ext4",[string]$Label=""){
    if(!(Test-Path $Device -EA SilentlyContinue)){return @{success=$false;message="Device not found: $Device"}}
    try{
        $fmtArgs=if($Label){@("-L",$Label,$Device)}else{@($Device)}
        $out=& "mkfs.$FileSystem" @fmtArgs 2>&1
        return @{success=$true;message="Formatted $Device as $FileSystem";output=($out -join "`n")}
    } catch{return @{success=$false;message=$_.Exception.Message}}
}

function Invoke-DiskOptimize([string]$MountPoint="/"){
    $log=@()
    try{$o=(fstrim -v $MountPoint 2>&1);$log+="[fstrim] $o"}catch{$log+="[fstrim] Not available or requires root."}
    try{apt-get clean 2>&1|Out-Null;$log+="[APT] Package cache cleared."}catch{$log+="[APT] Requires root or not applicable."}
    try{$o=(journalctl --vacuum-time=7d 2>&1);$log+="[journalctl] $o"}catch{$log+="[journalctl] Requires root or not present."}
    try{$sz=((du -sh /tmp 2>/dev/null) -split "\t")[0];$log+="[/tmp] Current size: $sz"}catch{$log+="[/tmp] Unable to read."}
    return @{success=$true;output=($log -join "`n")}
}

# Load HTML
$ScriptDir=Split-Path -Parent $MyInvocation.MyCommand.Path
$HtmlFile=Join-Path $ScriptDir "index.html"
if(!(Test-Path $HtmlFile)){
    Write-Host "[ERROR] index.html not found in $ScriptDir" -ForegroundColor Red
    Write-Host "Make sure index.html is in the same folder as SysToolPro.ps1" -ForegroundColor Yellow
    exit 1
}
$HtmlContent=Get-Content $HtmlFile -Raw -Encoding UTF8

# HTTP Server
$listener=[System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
try{$listener.Start()}
catch{
    Write-Host "[ERROR] Cannot start on port $Port. Try: sudo pwsh SysToolPro.ps1" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "  ║   SysToolPro - MAC-SEEKEEP Ownly         ║" -ForegroundColor White
Write-Host "  ║   PT2 Final Case Study                   ║" -ForegroundColor White
Write-Host "  ╠══════════════════════════════════════════╣" -ForegroundColor Magenta
Write-Host "  ║  URL    : http://localhost:$Port          ║" -ForegroundColor Cyan
Write-Host "  ║  Status : Running                        ║" -ForegroundColor Green
Write-Host "  ║  Stop   : Ctrl+C                         ║" -ForegroundColor Yellow
Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host ""

try{Start-Process "xdg-open" "http://localhost:$Port" -EA SilentlyContinue}catch{}

while($listener.IsListening){
    $ctx=$listener.GetContext()
    $req=$ctx.Request; $res=$ctx.Response
    $res.Headers.Add("Access-Control-Allow-Origin","*")
    $res.Headers.Add("Cache-Control","no-cache")
    $url=$req.Url.AbsolutePath
    $method=$req.HttpMethod

    # Serve index.html
    if($url -eq "/" -or $url -eq "/index.html"){
        $res.ContentType="text/html; charset=utf-8"
        $bytes=[System.Text.Encoding]::UTF8.GetBytes($HtmlContent)
        $res.OutputStream.Write($bytes,0,$bytes.Length)
        $res.Close(); continue
    }

    # Serve static assets (images, gifs, etc.)
    if($url -match "^/assets/"){
        $safePath = $url -replace "/","\" -replace "\\\.\.","" # prevent path traversal
        $filePath = Join-Path $ScriptDir ($url.TrimStart('/').Replace('/',[System.IO.Path]::DirectorySeparatorChar))
        if(Test-Path $filePath -PathType Leaf){
            $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
            $res.ContentType = switch($ext){
                ".png"  { "image/png" }
                ".jpg"  { "image/jpeg" }
                ".jpeg" { "image/jpeg" }
                ".gif"  { "image/gif" }
                ".svg"  { "image/svg+xml" }
                ".ico"  { "image/x-icon" }
                default { "application/octet-stream" }
            }
            $bytes = [System.IO.File]::ReadAllBytes($filePath)
            $res.OutputStream.Write($bytes,0,$bytes.Length)
        } else {
            $res.StatusCode = 404
        }
        $res.Close(); continue
    }

    $body=$null
    if($method -eq "POST"){
        try{$reader=[System.IO.StreamReader]::new($req.InputStream);$body=$reader.ReadToEnd()|ConvertFrom-Json}catch{}
    }

    $res.ContentType="application/json; charset=utf-8"
    $result=try{
        switch -Regex ($url){
            "^/api/hardware$"     {Get-HardwareInfo}
            "^/api/osinfo$"       {Get-OSInfo}
            "^/api/processes$"    {Get-ProcessList}
            "^/api/files$"        {$p=[System.Web.HttpUtility]::UrlDecode($req.QueryString["path"]);if(!$p){$p=$HOME};Get-DirectoryListing -Path $p}
            "^/api/files/create$" {New-FileItem -Path $body.path -Type $body.type}
            "^/api/files/delete$" {Remove-FileItem -Path $body.path}
            "^/api/files/rename$" {Rename-FileItem -Path $body.path -NewName $body.newName}
            "^/api/search$"       {Search-Files -SearchPath $body.searchPath -Query $body.query -SearchContent ([bool]$body.searchContent)}
            "^/api/bootable$"     {New-BootableDrive -IsoPath $body.isoPath -Device $body.device}
            "^/api/format$"       {Format-StorageDrive -Device $body.device -FileSystem $body.fileSystem -Label $body.label}
            "^/api/optimize$"     {Invoke-DiskOptimize -MountPoint $body.mountPoint}
            default               {@{error="Route not found: $url"}}
        }
    } catch {@{error=$_.Exception.Message}}

    $json=$result|ConvertTo-Json -Depth 10 -Compress
    $bytes=[System.Text.Encoding]::UTF8.GetBytes($json)
    $res.OutputStream.Write($bytes,0,$bytes.Length)
    $res.Close()
}
