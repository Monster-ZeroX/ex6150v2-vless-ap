# ex6150v2-vless-ap installer for Windows (PowerShell 5.1+). Start it with install-windows.bat.
#   install.ps1            guided: download, flash, find the extender, set it up
#   install.ps1 -SetupOnly skip flashing
# Your Netgear and router passwords are never asked for or stored by this script: you type them
# into the Netgear web page or into ssh yourself.
param([switch]$SetupOnly)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Net.Http

$Repo = if ($env:REPO) { $env:REPO } else { 'Monster-ZeroX/ex6150v2-vless-ap' }
$Key  = Join-Path $HOME '.ssh\ex6150v2_vpn'
$DL   = Join-Path $HOME 'Downloads\ex6150v2-vless-ap'
$script:Ext = $null

function Say($t)  { Write-Host "`n==> $t" -ForegroundColor Cyan }
function Die($t)  { Write-Host "`nERROR: $t" -ForegroundColor Red; Read-Host 'Press Enter to close'; exit 1 }
function Ask($t)  { (Read-Host $t).Trim() }
function Secret($t) {
	$s = Read-Host $t -AsSecureString
	[Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
}
function Need($c) { if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { Die "'$c' was not found. On Windows 10/11 enable it in Settings > Apps > Optional features > OpenSSH Client." } }

$Http = New-Object System.Net.Http.HttpClient
$Http.Timeout = [TimeSpan]::FromSeconds(60)
function Status($ip, [int]$ms = 2500) {
	try {
		$c = New-Object System.Net.Http.HttpClient; $c.Timeout = [TimeSpan]::FromMilliseconds($ms)
		$r = $c.GetStringAsync("http://${ip}:90/cgi-bin/vpn?action=status").Result
		$o = $r | ConvertFrom-Json
		if ($o.app -eq 'ex6150v2-vless-ap') { return $o }
	} catch {}
	return $null
}

# ------------------------------------------------------------------------------------------
function Download {
	Say "Downloading the latest firmware from github.com/$Repo"
	New-Item -ItemType Directory -Force $DL | Out-Null
	try { $rel = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -UseBasicParsing } catch { Die 'cannot reach GitHub' }
	foreach ($a in $rel.assets) {
		if ($a.name -match '(factory\.img|sysupgrade\.bin|SHA256SUMS)$') {
			Write-Host "  $($a.name)"
			Invoke-WebRequest $a.browser_download_url -OutFile (Join-Path $DL $a.name) -UseBasicParsing
		}
	}
	$script:Factory = Get-ChildItem $DL -Filter '*ex6150v2*factory.img' | Select-Object -First 1
	$script:Sysup   = Get-ChildItem $DL -Filter '*ex6150v2*sysupgrade.bin' | Select-Object -First 1
	$sums = Join-Path $DL 'SHA256SUMS'
	if (-not $Factory -or -not $Sysup -or -not (Test-Path $sums)) { Die "release $($rel.tag_name) is missing files" }
	$table = @{}
	foreach ($l in Get-Content $sums) { $p = $l -split '\s+\*?'; if ($p.Count -ge 2) { $table[$p[1]] = $p[0].ToLower() } }
	foreach ($f in @($Factory, $Sysup)) {
		$h = (Get-FileHash $f.FullName -Algorithm SHA256).Hash.ToLower()
		if ($table[$f.Name] -ne $h) { Die "checksum mismatch for $($f.Name) - delete $DL and try again" }
	}
	Write-Host "Release $($rel.tag_name) verified (SHA-256 OK) in $DL"
}

function FlashStock {
	Say 'Flash from the Netgear firmware'
	Write-Host @"
1. Connect this PC to the extender (its Wi-Fi or Ethernet). Your browser opens
      http://mywifiext.net   (if not, use the extender's IP address)
   Log in with your Netgear admin password.
2. Go to  Settings -> Firmware Update  (on some versions: Maintenance -> Firmware Update).
3. Click Browse and pick this file (its folder opens now), then Upload:
      $($Factory.FullName)
4. Wait about 5 minutes. Do NOT unplug the extender while it flashes.
5. Plug an Ethernet cable from the extender into your home router (or a switch on it).
   The extender gets an address from your router automatically. Its Wi-Fi stays OFF until setup.
"@
	Start-Process 'http://mywifiext.net'
	Start-Process explorer.exe "/select,`"$($Factory.FullName)`""
	Read-Host 'Press Enter when the extender has rebooted and is connected by cable'
}

function FlashOpenWrt {
	Say 'Upgrade an extender that already runs OpenWrt'
	Need ssh; Need scp
	$ip = Ask 'Extender IP address'
	Write-Host "ssh may ask for the extender's root password (type it there; this script never sees it)."
	& scp -O -o StrictHostKeyChecking=accept-new $Sysup.FullName "root@${ip}:/tmp/fw.bin"
	if ($LASTEXITCODE -ne 0) { & scp -o StrictHostKeyChecking=accept-new $Sysup.FullName "root@${ip}:/tmp/fw.bin" }
	if ($LASTEXITCODE -ne 0) { Die 'upload failed' }
	$t = & ssh "root@$ip" 'sysupgrade -T /tmp/fw.bin && echo IMAGE-OK'
	if (-not ($t -match 'IMAGE-OK')) { Die 'the extender rejected the image' }
	$keep = Ask 'Does it already run ex6150v2-vless-ap (keep its settings)? [y/N]'
	if ($keep -match '^[yY]') { & ssh "root@$ip" 'sysupgrade /tmp/fw.bin'; $script:Ext = $ip }
	else {
		Write-Host "Flashing WITHOUT old settings. Afterwards plug the extender's Ethernet into your home router."
		& ssh "root@$ip" 'sysupgrade -n /tmp/fw.bin'
	}
	Write-Host 'Flashing. Waiting 3 minutes for the reboot...'
	Start-Sleep -Seconds 180
}

# ------------------------------------------------------------------------------------------
function FindExtender {
	if ($script:Ext -and (Status $script:Ext)) { return }
	Say 'Looking for the extender on your network'
	$route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
	$addr = if ($route) { Get-NetIPAddress -InterfaceIndex $route.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1 }
	if ($addr) {
		$pre = ($addr.IPAddress -split '\.')[0..2] -join '.'
		Write-Host "Scanning $pre.1-254 ..."
		$c = New-Object System.Net.Http.HttpClient; $c.Timeout = [TimeSpan]::FromSeconds(3)
		$tasks = @{}
		1..254 | ForEach-Object { $ip = "$pre.$_"; $tasks[$ip] = $c.GetStringAsync("http://${ip}:90/cgi-bin/vpn?action=status") }
		try { [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($tasks.Values), 4000) | Out-Null } catch {}
		foreach ($kv in $tasks.GetEnumerator()) {
			if ($kv.Value.Status -eq 'RanToCompletion' -and $kv.Value.Result -match '"app":"ex6150v2-vless-ap"') { $script:Ext = $kv.Key; break }
		}
	}
	if (-not $script:Ext) {
		Write-Host "Not found automatically. Look up the extender in your router's list of connected devices (name: ex6150v2-vpn)."
		$script:Ext = Ask 'Extender IP address'
		if (-not (Status $script:Ext 5000)) { Die "no VPN manager answers on http://$($script:Ext):90" }
	}
	Write-Host "Found the extender at $($script:Ext)"
}

function Setup {
	$st = Status $script:Ext 5000
	if (-not $st.setup_required) {
		Say 'This extender is already set up'
		Write-Host "Manage it at http://$($script:Ext):90 (log in with your admin password)."
		return
	}
	Say 'Set up your VPN access point'
	while ($true) {
		$pw = Secret 'Admin password (min. 8 characters; also the LuCI/SSH root password)'
		$pw2 = Secret 'Repeat it'
		if ($pw -eq $pw2 -and $pw.Length -ge 8) { break }
		Write-Host 'Passwords differ or are shorter than 8 characters.'
	}
	do { $ssid = Ask 'Wi-Fi name for the VPN network' } until ($ssid.Length -ge 1 -and $ssid.Length -le 32)
	do { $wkey = Secret 'Wi-Fi password (8-63 characters)' } until ($wkey.Length -ge 8 -and $wkey.Length -le 63)
	do { $link = Ask 'Paste your VLESS link (vless://...)' } until ($link.StartsWith('vless://'))
	$sni = Ask "SNI override - hostname shown on the network instead of your server's (Enter = none)"
	$pub = ''
	if (Get-Command ssh-keygen -ErrorAction SilentlyContinue) {
		if (-not (Test-Path $Key)) {
			New-Item -ItemType Directory -Force (Split-Path $Key) | Out-Null
			& ssh-keygen -q -t ed25519 -N '""' -C 'ex6150v2-vpn' -f $Key
			if (-not (Test-Path $Key)) { & ssh-keygen -q -t ed25519 -N '' -C 'ex6150v2-vpn' -f $Key }
		}
		if (Test-Path "$Key.pub") { $pub = (Get-Content "$Key.pub" -Raw).Trim() }
	}
	$body = @{ password = $pw; wifi_ssid = $ssid; wifi_key = $wkey; link = $link; sni = $sni; ssh_key = $pub } | ConvertTo-Json -Compress
	$content = New-Object System.Net.Http.StringContent($body, [Text.Encoding]::UTF8, 'application/json')
	try { $r = $Http.PostAsync("http://$($script:Ext):90/cgi-bin/vpn?action=setup", $content).Result.Content.ReadAsStringAsync().Result } catch { Die "setup request failed: $_" }
	$o = $r | ConvertFrom-Json
	if (-not $o.ok) { Die "setup failed: $($o.error)" }
	Write-Host 'Setup saved.'
	if ($pub) { Write-Host "SSH key: $Key   (ssh -i `"$Key`" root@$($script:Ext))" }
}

function Verify {
	Say 'Waiting for the VPN tunnel'
	for ($i = 0; $i -lt 30; $i++) {
		$st = Status $script:Ext 3000
		if ($st -and $st.tunnel) {
			Write-Host "`nDone! The VPN is connected." -ForegroundColor Green
			Write-Host @"
  - Join the Wi-Fi network you just named. Everything on it goes through your VLESS server.
  - Manage the VPN:   http://$($script:Ext):90
  - Router dashboard: http://$($script:Ext)   (LuCI, user root, your admin password)
  - Check it: on a phone on that Wi-Fi, open https://ipinfo.io - it should show your server's location.
"@
			Start-Process "http://$($script:Ext):90"
			return
		}
		Start-Sleep -Seconds 3
	}
	Write-Host "The tunnel is not up yet. Open http://$($script:Ext):90 and check the link (see docs/TROUBLESHOOTING.md)."
}

# ------------------------------------------------------------------------------------------
Write-Host 'EX6150v2 VLESS access point installer' -ForegroundColor Cyan
if (-not $SetupOnly) {
	Write-Host 'What is on your extender now?'
	Write-Host "  1) Netgear's original firmware"
	Write-Host '  2) OpenWrt (this project or another OpenWrt build)'
	Write-Host '  3) Already flashed - only set it up'
	switch (Ask 'Choose 1, 2 or 3') {
		'1' { Download; FlashStock }
		'2' { Download; FlashOpenWrt }
		'3' { }
		default { Die 'please choose 1, 2 or 3' }
	}
}
FindExtender
Setup
Verify
Read-Host "`nPress Enter to close"
