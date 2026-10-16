# BestScrap: poll Best Buy Canada for in-store pickup stock (Windows).
# Windows PowerShell 5.1 or PowerShell 7. Nothing to install.
param([Parameter(Position = 0)][string]$Command = 'watch')

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::DefaultConnectionLimit = 8
Add-Type -AssemblyName System.Net.Http

$Dir = $PSScriptRoot
$ConfigPath = Join-Path $Dir 'config.yml'
$Data = Join-Path $Dir 'data'
$StoresPath = Join-Path $Data 'stores.tsv'
$KeyPath = Join-Path $Data 'stores.key'
$Base = 'https://www.bestbuy.ca'
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'
$Utf8 = New-Object Text.UTF8Encoding($false)

$Http = New-Object System.Net.Http.HttpClient
$Http.Timeout = [TimeSpan]::FromSeconds(90)
[void]$Http.DefaultRequestHeaders.UserAgent.ParseAdd($UA)

function Fail($msg) { [Console]::Error.WriteLine("error: $msg"); exit 2 }

function Log($msg) {
    $ts = (Get-Date).ToString('d MMM. HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    Write-Host "[$ts] $msg"
}

function Get-Text($url) {
    for ($i = 1; ; $i++) {
        try { return $Http.GetStringAsync($url).GetAwaiter().GetResult() }
        catch { if ($i -ge 3) { throw }; Start-Sleep -Seconds (2 * $i) }
    }
}

# ---- config -----------------------------------------------------------------

function Read-Config {
    if (-not (Test-Path $ConfigPath)) { Fail 'no config.yml; copy example.config.yml to config.yml first' }
    $c = @{}
    foreach ($line in [IO.File]::ReadAllLines($ConfigPath)) {
        $l = ($line -replace '(^|\s)#.*$', '').Trim()
        if ($l -match '^([A-Za-z_]+):\s*(.*)$') { $c[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'") }
    }
    if (-not $c['sku']) { Fail 'sku is not set in config.yml' }
    $provs = @(($c['provinces'] -replace '[\[\],]', ' ').ToUpper() -split '\s+' | Where-Object { $_ })
    if (-not $provs) { Fail 'provinces is not set in config.yml (e.g. QC, or ALL)' }
    $interval = 45
    if ($c.ContainsKey('interval') -and $c['interval']) {
        if ($c['interval'] -notmatch '^\d+$') { Fail 'interval must be a number of seconds' }
        $interval = [int]$c['interval']
    }
    if ($interval -lt 10) { Fail 'interval must be at least 10 seconds' }
    $sound = 'sounds/alert.wav'
    if ($c.ContainsKey('sound')) { $sound = $c['sound'] }
    if ($sound -and -not [IO.Path]::IsPathRooted($sound)) { $sound = Join-Path $Dir $sound }
    $extra = @()
    if ($c['extra_seeds']) { $extra = @($c['extra_seeds'] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $script:Cfg = @{ Sku = $c['sku']; Provs = $provs; Interval = $interval; Sound = $sound; Extra = $extra }
    $script:ProvKey = ',' + ($provs -join ',') + ','
}

# ---- store discovery --------------------------------------------------------

function Get-Seeds {
    $seeds = @()
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $Dir 'seeds.txt'))) {
        if ($line -match '^\s*(#|$)') { continue }
        if ($line -match '^(\S+)\s+(.+?)\s*$') {
            if ($Cfg.Provs -contains 'ALL' -or $Cfg.Provs -contains $Matches[1]) { $seeds += $Matches[2] }
        }
    }
    $seeds + $Cfg.Extra
}

function Sync-Stores {
    New-Item -ItemType Directory -Force $Data | Out-Null
    $seeds = @(Get-Seeds)
    if (-not $seeds) { Fail "no seeds for provinces: $($Cfg.Provs -join ' ')" }
    Log "Finding stores in $($Cfg.Provs -join ' ') ($($seeds.Count) lookups, this takes a minute)"
    $tasks = foreach ($s in $seeds) {
        $k = if ($s -match '^[A-Za-z]\d[A-Za-z] ?\d[A-Za-z]\d$') { 'postalCode' } else { 'city' }
        $Http.GetStringAsync("$Base/api/v2/json/locations?lang=en&showOnlyStores=true&$k=$([uri]::EscapeDataString($s))")
    }
    try { [void][Threading.Tasks.Task]::WaitAll(@($tasks)) } catch { }
    $stores = @{}
    foreach ($t in $tasks) {
        if ($t.Status -ne 'RanToCompletion') { continue }
        foreach ($l in ($t.Result | ConvertFrom-Json).locations) {
            if ($Cfg.Provs -contains 'ALL' -or $Cfg.Provs -contains $l.region) {
                $stores[[string]$l.locationId] = ($l.locationId, $l.name, $l.city, $l.postalCode, $l.region, $l.address1, $l.phone1) -join "`t"
            }
        }
    }
    if ($stores.Count -eq 0) { Fail 'no stores found (network down or rate limited?)' }
    [IO.File]::WriteAllLines($StoresPath, [string[]]@($stores.Values | Sort-Object), $Utf8)
    [IO.File]::WriteAllText($KeyPath, "$ProvKey|$($Cfg.Extra -join ',')", $Utf8)
    Log "Found $($stores.Count) stores"
}

function Read-Stores {
    $script:Stores = [ordered]@{}
    foreach ($line in [IO.File]::ReadAllLines($StoresPath, $Utf8)) {
        $f = $line -split "`t"
        $script:Stores[$f[0]] = [pscustomobject]@{ Id = $f[0]; Name = $f[1]; City = $f[2]; Zip = $f[3]; Prov = $f[4]; Addr = $f[5]; Phone = $f[6] }
    }
}

function Confirm-Stores {
    $want = "$ProvKey|$($Cfg.Extra -join ',')"
    $have = if (Test-Path $KeyPath) { [IO.File]::ReadAllText($KeyPath).Trim() } else { '' }
    if (-not (Test-Path $StoresPath) -or $have -ne $want) { Sync-Stores }
    Read-Stores
}

function Label($s) { "$($s.Name) ($($s.City) $($s.Zip))" }

# ---- availability -----------------------------------------------------------

# Returns @{ id = @{Qty; Res} } for stores with stock. Throws on any failure.
function Get-Stock {
    $ids = @($Stores.Keys)
    $postal = $Stores[$ids[0]].Zip -replace ' ', ''
    $found = @{}
    for ($i = 0; $i -lt $ids.Count; $i += 25) {
        $chunk = $ids[$i..([Math]::Min($i + 24, $ids.Count - 1))] -join '|'
        $q = "accept=$([uri]::EscapeDataString('application/vnd.bestbuy.standardproduct.v1+json'))&accept-language=en-CA" +
             "&locations=$([uri]::EscapeDataString($chunk))&postalCode=$postal&skus=$($Cfg.Sku)"
        $r = (Get-Text "$Base/ecomm-api/availability/products?$q") | ConvertFrom-Json
        if (-not $r.availabilities) { throw 'bad availability response' }
        foreach ($a in $r.availabilities) {
            foreach ($l in $a.pickup.locations) {
                if ($l.quantityOnHand -gt 0 -or $l.hasInventory -or $l.isReservable) {
                    $found[[string]$l.locationKey] = @{ Qty = [int]$l.quantityOnHand; Res = [bool]$l.isReservable }
                }
            }
        }
    }
    $found
}

# ---- sound ------------------------------------------------------------------

function Play-Sound {
    if ($Cfg.Sound -and (Test-Path $Cfg.Sound)) {
        (New-Object System.Media.SoundPlayer $Cfg.Sound).Play()
    } else {
        [Console]::Beep(880, 250); [Console]::Beep(1175, 250); [Console]::Beep(880, 250)
    }
}

# ---- main -------------------------------------------------------------------

function Run($once) {
    Read-Config
    Confirm-Stores
    try {
        $p = (Get-Text "$Base/api/v2/json/product/$($Cfg.Sku)") | ConvertFrom-Json
        if (-not $p.name) { throw 'no product' }
    } catch { Fail "could not load SKU $($Cfg.Sku) (wrong SKU, or Best Buy unreachable)" }
    Log "Watching: $($p.name) (SKU $($Cfg.Sku), `$$($p.salePrice)) in $($Stores.Count) stores, every $($Cfg.Interval)s"

    $prev = @{}
    $first = $true
    while ($true) {
        try {
            $cur = Get-Stock
            $alert = $false
            $lines = @()
            foreach ($id in $cur.Keys) {
                if (-not $prev.ContainsKey($id)) {
                    $s = $Stores[$id]
                    $tag = if ($first) { 'IN STOCK' } else { 'NEW STOCK' }
                    $res = if ($cur[$id].Res) { ', reservable' } else { '' }
                    $lines += "${tag}: $(Label $s) $($s.Addr) $($s.Phone) - qty $($cur[$id].Qty)$res"
                    $alert = $true
                } elseif ($prev[$id].Qty -ne $cur[$id].Qty) {
                    $lines += "QTY CHANGE: $(Label $Stores[$id]) $($prev[$id].Qty) -> $($cur[$id].Qty)"
                }
            }
            foreach ($id in $prev.Keys) {
                if (-not $cur.ContainsKey($id)) { $lines += "GONE: $(Label $Stores[$id]) no longer available" }
            }
            foreach ($l in $lines) { Log $l }
            if ($alert) {
                Write-Host "    reserve: $Base/en-ca/reserve-and-pickup/$($Cfg.Sku)"
                Play-Sound
            } elseif ($first -and $cur.Count -eq 0) {
                Log 'Nothing in stock right now'
            }
            $prev = $cur
            $first = $false
        } catch {
            Log "check failed, will retry ($($_.Exception.Message))"
            if ($once) { exit 2 }
        }
        if ($once) { if ($prev.Count -gt 0) { exit 0 } else { exit 1 } }
        Start-Sleep -Seconds $Cfg.Interval
    }
}

switch ($Command) {
    'watch' { Run $false }
    'once'  { Run $true }
    'sync'  { Read-Config; Sync-Stores }
    'stores' {
        if (-not (Test-Path $StoresPath)) { Fail 'no store list yet; run: bestscrap sync' }
        Read-Stores
        $Stores.Values | Sort-Object Prov, City | ForEach-Object {
            '{0,-5} {1,-2} {2,-8} {3,-28} {4}' -f $_.Id, $_.Prov, $_.Zip, $_.Name, $_.City
        }
    }
    default {
        @'
usage: bestscrap.bat [command]

  watch    poll forever, report changes, play a sound when stock appears (default)
  once     check once; exit 0 if anything is in stock, 1 if not, 2 on error
  sync     rebuild the store list for the provinces in config.yml
  stores   print the cached store list
'@ | Write-Host
        if ($Command -notin 'help', '-h', '--help') { exit 2 }
    }
}
