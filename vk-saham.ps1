# VK Saham: kira signal harian Bursa Malaysia dan tulis vk-saham.json untuk vk-saham.html.
# Dijalankan oleh GitHub Actions (vk-saham.yml) setiap hari dagangan selepas pasaran tutup.
#
# STRATEGI (sama dengan Engine.java, diuji 10 tahun, 960 saham, kos 0.5%, PromptTest 2026-11-15):
#   BELI bila harga tutup > tutup tertinggi 250 hari sebelum (52 minggu), EMA50 > EMA200, tutup > EMA200,
#   nilai dagangan purata 50 hari >= RM1 juta, harga >= RM0.20.
#   Beli harga BUKA esok hanya jika <= tutup + 0.5 ATR. SL = 2 ATR. JUAL bila tutup bawah EMA50 atau SL kena.
#   ATR = purata Wilder |tutup - tutup semalam| 14 hari (sama seperti enjin).
# Peraturan swing/penny daripada prompt pengguna RUGI dalam ujian yang sama, jadi tidak dijadikan signal.
#
# Ujian luar talian: ./vk-saham.ps1 -Had 10 -Keluar uji.json
param([int]$Had = 0, [string]$Keluar = '', [string]$Mula = '2026-11-16')
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
$inv = [Globalization.CultureInfo]::InvariantCulture
$myt = [DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(8))
$outFile = if ($Keluar) { $Keluar } else { Join-Path $dir 'vk-saham.json' }
$COST = 0.005; $SLATR = 2.0; $CHASE = 0.5; $HIGH = 250; $NCLOSE = 180

function Get-Ema([double[]]$c, [int]$p) {
  $o = New-Object double[] $c.Length
  for ($i = 0; $i -lt $c.Length; $i++) { $o[$i] = [double]::NaN }
  if ($c.Length -lt $p) { return ,$o }
  $s = 0.0; for ($i = 0; $i -lt $p; $i++) { $s += $c[$i] }
  $prev = $s / $p; $o[$p - 1] = $prev; $k = 2.0 / ($p + 1)
  for ($i = $p; $i -lt $c.Length; $i++) { $prev = $c[$i] * $k + $prev * (1 - $k); $o[$i] = $prev }
  return ,$o
}
function Get-AtrClose([double[]]$c, [int]$p) {
  $o = New-Object double[] $c.Length
  for ($i = 0; $i -lt $c.Length; $i++) { $o[$i] = [double]::NaN }
  if ($c.Length -le $p) { return ,$o }
  $a = 0.0; for ($i = 1; $i -le $p; $i++) { $a += [math]::Abs($c[$i] - $c[$i - 1]) }
  $a /= $p; $o[$p] = $a
  for ($i = $p + 1; $i -lt $c.Length; $i++) { $a = ($a * ($p - 1) + [math]::Abs($c[$i] - $c[$i - 1])) / $p; $o[$i] = $a }
  return ,$o
}
function N($x, $f = '0.####') { if ($null -eq $x -or [double]::IsNaN([double]$x) -or [double]::IsInfinity([double]$x)) { 'null' } else { ([double]$x).ToString($f, $inv) } }
function Q($s) { '"' + (($s -replace '\\', '\\') -replace '"', '\"') + '"' }

function Get-Yahoo($sym) {
  $u = "https://query1.finance.yahoo.com/v8/finance/chart/$sym" + '?interval=1d&range=3y&events=div'
  $r = $null
  for ($t = 0; $t -lt 3 -and -not $r; $t++) {
    try { $r = Invoke-RestMethod -Uri $u -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36' -TimeoutSec 30 }
    catch { Start-Sleep -Seconds (2 + 3 * $t) }
  }
  if (-not $r) { throw 'Yahoo gagal' }
  $res = $r.chart.result[0]; $q = $res.indicators.quote[0]
  $d = New-Object System.Collections.Generic.List[string]; $o = New-Object System.Collections.Generic.List[double]
  $h = New-Object System.Collections.Generic.List[double]; $l = New-Object System.Collections.Generic.List[double]
  $c = New-Object System.Collections.Generic.List[double]; $v = New-Object System.Collections.Generic.List[double]
  for ($i = 0; $i -lt $res.timestamp.Count; $i++) {
    if ($null -eq $q.open[$i] -or $null -eq $q.high[$i] -or $null -eq $q.low[$i] -or $null -eq $q.close[$i]) { continue }
    $dt = [DateTimeOffset]::FromUnixTimeSeconds($res.timestamp[$i]).ToOffset([TimeSpan]::FromHours(8))
    if ($dt.Date -eq $myt.Date -and $myt.Hour -lt 17) { continue }   # candle hari ini belum lengkap
    $ds = $dt.ToString('yyyy-MM-dd')
    if ($d.Count -gt 0 -and $d[$d.Count - 1] -eq $ds) { continue }
    $d.Add($ds); $o.Add([double]$q.open[$i]); $h.Add([double]$q.high[$i]); $l.Add([double]$q.low[$i]); $c.Add([double]$q.close[$i])
    $v.Add($(if ($null -eq $q.volume[$i]) { 0.0 } else { [double]$q.volume[$i] }))
  }
  $div = 0.0
  if ($res.events -and $res.events.dividends) {
    $cut = [DateTimeOffset]::UtcNow.AddDays(-365).ToUnixTimeSeconds()
    foreach ($p in $res.events.dividends.PSObject.Properties) { if ([long]$p.Value.date -ge $cut) { $div += [double]$p.Value.amount } }
  }
  [pscustomobject]@{ d = $d.ToArray(); o = $o.ToArray(); h = $h.ToArray(); l = $l.ToArray(); c = $c.ToArray(); v = $v.ToArray(); div = $div }
}

# Data Yahoo kadang-kadang ada harga salah (sama seperti Engine.suspicious)
function Test-Pelik([double[]]$c) {
  for ($i = 1; $i -lt $c.Length - 1; $i++) {
    $r1 = $c[$i] / $c[$i - 1]; $r2 = $c[$i + 1] / $c[$i]
    if (($r1 -gt 1.6 -and $r2 -lt 0.7) -or ($r1 -lt 0.4 -and $r2 -gt 1.6) -or $r1 -gt 3 -or $r1 -lt 0.25) { return $true }
  }
  return $false
}

# ---------- senarai saham ----------
$list = @()
foreach ($row in Get-Content (Join-Path $dir 'senarai-vk-saham.txt') -Encoding UTF8) {
  if (-not $row.Trim() -or $row.StartsWith('#')) { continue }
  $p = $row.Split('|')
  $list += [pscustomobject]@{ k = $p[0]; n = $p[1]; mc = [double]::Parse($p[2], $inv); eps = $(if ($p[3]) { [double]::Parse($p[3], $inv) } else { [double]::NaN }) }
}
if ($Had -gt 0) { $list = $list | Select-Object -First $Had }

# ---------- KLCI ----------
$klciJson = 'null'
try {
  $kd = Get-Yahoo '%5EKLSE'; $ke = Get-Ema $kd.c 200; $n = $kd.c.Length
  $kc = New-Object System.Collections.Generic.List[string]
  for ($i = [math]::Max(0, $n - $NCLOSE); $i -lt $n; $i++) { $kc.Add((N $kd.c[$i] '0.##')) }
  $klciJson = '{"tarikh":' + (Q $kd.d[$n - 1]) + ',"tutup":' + (N $kd.c[$n - 1] '0.##') + ',"semalam":' + (N $kd.c[$n - 2] '0.##') +
    ',"ema200":' + (N $ke[$n - 1] '0.##') + ',"naik":' + $(if ($kd.c[$n - 1] -gt $ke[$n - 1]) { 'true' } else { 'false' }) + ',"c":[' + ($kc -join ',') + ']}'
  Write-Host "OK KLCI $($kd.d[$n - 1]) $($kd.c[$n - 1])"
} catch { Write-Host "GAGAL KLCI: $($_.Exception.Message)" }

# ---------- setiap saham ----------
$stocks = New-Object System.Collections.Generic.List[string]
$trades = New-Object System.Collections.Generic.List[object]
$done = @{}; $fail = @(); $lastDate = ''
$since = $myt.AddDays(-400).ToString('yyyy-MM-dd')
foreach ($s in $list) {
  try {
    $y = Get-Yahoo "$($s.k).KL"
    $c = $y.c; $n = $c.Length
    if ($n -lt $HIGH + 60) { throw "data sedikit ($n hari)" }
    if (Test-Pelik $c) { throw 'data pelik (lonjakan harga salah)' }
    $e50 = Get-Ema $c 50; $e200 = Get-Ema $c 200; $atr = Get-AtrClose $c 14
    # nilai dagangan purata 50 hari dan paras tertinggi 250 hari sebelum
    $val = New-Object double[] $n; $hh = New-Object double[] $n; $sum = 0.0
    for ($i = 0; $i -lt $n; $i++) {
      $sum += $c[$i] * $y.v[$i]; if ($i -ge 50) { $sum -= $c[$i - 50] * $y.v[$i - 50] }
      $val[$i] = if ($i -ge 49) { $sum / 50 } else { [double]::NaN }
    }
    $dq = New-Object System.Collections.Generic.LinkedList[int]   # deque untuk max gelongsor
    for ($i = 0; $i -lt $n; $i++) {
      while ($dq.Count -gt 0 -and $dq.First.Value -lt $i - $HIGH) { $dq.RemoveFirst() }
      $hh[$i] = if ($dq.Count -gt 0) { $c[$dq.First.Value] } else { [double]::NegativeInfinity }
      while ($dq.Count -gt 0 -and $c[$dq.Last.Value] -le $c[$i]) { $dq.RemoveLast() }
      [void]$dq.AddLast($i)
    }
    # jalankan strategi (satu trade pada satu masa), simpan trade yang isyaratnya dalam ~13 bulan lepas
    for ($i = $HIGH; $i -lt $n; $i++) {
      if ($c[$i] -lt 0.20 -or -not ($val[$i] -ge 1000000) -or [double]::IsNaN($e200[$i]) -or [double]::IsNaN($atr[$i])) { continue }
      if (-not ($e50[$i] -gt $e200[$i] -and $c[$i] -gt $e200[$i] -and $c[$i] -gt $hh[$i])) { continue }
      $t = [ordered]@{ k = $s.k; n = $s.n; sig = $y.d[$i]; close = $c[$i]; atr = $atr[$i]; buyMax = $c[$i] + $CHASE * $atr[$i]; sl = $c[$i] - $SLATR * $atr[$i]
        masuk = $null; entry = $null; keluar = $null; exit = $null; sebab = ''; status = 'BARU'; ret = $null; harga = $c[$n - 1] }
      if ($i + 1 -ge $n) { if ($y.d[$i] -ge $since) { $trades.Add($t) }; break }
      $open = $y.o[$i + 1]
      if ($open -gt $t.buyMax) { $t.status = 'TERLEPAS'; $t.sebab = 'Harga buka melepasi had beli'; if ($y.d[$i] -ge $since) { $trades.Add($t) }; continue }
      $t.masuk = $y.d[$i + 1]; $t.entry = $open; $t.sl = [math]::Min($t.sl, $open - $SLATR * $atr[$i])
      $j = $i + 1
      for (; $j -lt $n; $j++) {
        if ($y.l[$j] -le $t.sl) { $t.exit = [math]::Min($y.o[$j], $t.sl); $t.sebab = 'Stop Loss'; break }
        if ($c[$j] -lt $e50[$j]) { $t.exit = $c[$j]; $t.sebab = 'Tutup bawah EMA50'; break }
      }
      if ($j -lt $n) { $t.keluar = $y.d[$j]; $t.status = 'SELESAI'; $t.ret = $t.exit / $t.entry - 1 - $COST }
      else { $t.status = 'PEGANG'; $t.ret = $c[$n - 1] / $t.entry - 1 }
      if ($y.d[$i] -ge $since) { $trades.Add($t) }
      if ($j -ge $n) { break }
      $i = $j
    }
    # status semasa
    $L = $n - 1
    $naik = $e50[$L] -gt $e200[$L] -and $c[$L] -gt $e200[$L]
    $st = if (-not $naik) { 'TURUN' } elseif ($c[$L] -gt $hh[$L]) { 'BELI' } elseif ($c[$L] -ge 0.97 * $hh[$L]) { 'HAMPIR' } else { 'NAIK' }
    $vol = [double]::NaN
    if ($n -gt 253) {
      $a = 0.0; $b = 0.0
      for ($i = $n - 252; $i -lt $n; $i++) { $r = [math]::Log($c[$i] / $c[$i - 1]); $a += $r; $b += $r * $r }
      $vol = [math]::Sqrt([math]::Max(0.0, $b / 252 - ($a / 252) * ($a / 252))) * [math]::Sqrt(252)
    }
    $vavg = 0.0; for ($i = $n - 51; $i -lt $n - 1; $i++) { $vavg += $y.v[$i] }; $vavg /= 50
    $cl = New-Object System.Collections.Generic.List[string]
    for ($i = [math]::Max(0, $n - $NCLOSE); $i -lt $n; $i++) { $cl.Add((N $c[$i])) }
    $stocks.Add('{"k":' + (Q $s.k) + ',"n":' + (Q $s.n) + ',"mc":' + (N $s.mc '0') + ',"eps":' + (N $s.eps) +
      ',"tarikh":' + (Q $y.d[$L]) + ',"c":' + (N $c[$L]) + ',"semalam":' + (N $c[$L - 1]) + ',"e50":' + (N $e50[$L]) + ',"e200":' + (N $e200[$L]) +
      ',"atr":' + (N $atr[$L]) + ',"hh":' + (N $hh[$L]) + ',"nilai":' + (N $val[$L] '0') + ',"volx":' + (N ($(if ($vavg -gt 0) { $y.v[$L] / $vavg } else { [double]::NaN })) '0.##') +
      ',"dy":' + (N ($(if ($c[$L] -gt 0) { $y.div / $c[$L] * 100 } else { 0 })) '0.##') + ',"vol":' + (N ($vol * 100) '0.#') + ',"st":' + (Q $st) +
      ',"cl":[' + ($cl -join ',') + ']}')
    if ($y.d[$L] -gt $lastDate) { $lastDate = $y.d[$L] }
    $done[$s.k] = $true
    Write-Host "OK $($s.k) $($s.n) $st"
  } catch {
    $fail += "$($s.k)"
    Write-Host "GAGAL $($s.k) $($s.n): $($_.Exception.Message)"
  }
  Start-Sleep -Milliseconds 300
}

if ($stocks.Count -lt [math]::Max(1, [int]($list.Count * 0.5))) {
  Write-Host "GAGAL: hanya $($stocks.Count) daripada $($list.Count) saham. Fail lama dikekalkan."
  exit 1
}

# Rekod langsung: trade dari tarikh mula yang tiada dalam larian ini (saham gagal/keluar senarai) dikekalkan dari fail lama
$old = @()
if (Test-Path $outFile) { try { $old = (Get-Content $outFile -Raw -Encoding UTF8 | ConvertFrom-Json).trades } catch { $old = @() } }
$keep = @($old | Where-Object { $_ -and $_.sig -ge $Mula -and -not $done.ContainsKey([string]$_.k) })

$tj = New-Object System.Collections.Generic.List[string]
foreach ($t in $trades) {
  $tj.Add('{"k":' + (Q $t.k) + ',"n":' + (Q $t.n) + ',"sig":' + (Q $t.sig) + ',"close":' + (N $t.close) + ',"atr":' + (N $t.atr) +
    ',"buyMax":' + (N $t.buyMax) + ',"sl":' + (N $t.sl) + ',"masuk":' + $(if ($t.masuk) { Q $t.masuk } else { 'null' }) + ',"entry":' + (N $t.entry) +
    ',"keluar":' + $(if ($t.keluar) { Q $t.keluar } else { 'null' }) + ',"exit":' + (N $t.exit) + ',"sebab":' + (Q $t.sebab) +
    ',"status":' + (Q $t.status) + ',"ret":' + (N $t.ret '0.#####') + ',"harga":' + (N $t.harga) + '}')
}
foreach ($t in $keep) { $tj.Add(($t | ConvertTo-Json -Compress -Depth 3)) }

$json = '{"dikemas":' + (Q $myt.ToString('yyyy-MM-dd HH:mm')) + ',"tarikhData":' + (Q $lastDate) + ',"mula":' + (Q $Mula) +
  ',"kos":' + (N $COST) + ',"gagal":[' + (($fail | ForEach-Object { Q $_ }) -join ',') + '],"klci":' + $klciJson +
  ',"saham":[' + ($stocks -join ',') + '],"trades":[' + ($tj -join ',') + ']}'
[IO.File]::WriteAllText($outFile, $json, (New-Object Text.UTF8Encoding $false))

# Fail kecil untuk notifikasi app Android (VkWorker.semakSaham): signal baru, yang sedang dipegang, dan yang selesai/terlepas dalam 14 hari
if ($true) {
  $notiFile = if ($Keluar) { "$Keluar.noti.json" } else { Join-Path $dir 'vk-saham-noti.json' }
  $cut = $myt.AddDays(-14).ToString('yyyy-MM-dd')
  $nj = New-Object System.Collections.Generic.List[string]
  foreach ($t in $trades) {
    if ($t.status -eq 'SELESAI' -and $t.keluar -lt $cut) { continue }
    if ($t.status -eq 'TERLEPAS' -and $t.sig -lt $cut) { continue }
    $nj.Add('{"k":' + (Q $t.k) + ',"n":' + (Q $t.n) + ',"sig":' + (Q $t.sig) + ',"status":' + (Q $t.status) + ',"buyMax":' + (N $t.buyMax) +
      ',"sl":' + (N $t.sl) + ',"entry":' + (N $t.entry) + ',"exit":' + (N $t.exit) + ',"ret":' + (N $t.ret '0.#####') + ',"sebab":' + (Q $t.sebab) + '}')
  }
  [IO.File]::WriteAllText($notiFile,'{"tarikhData":' + (Q $lastDate) + ',"t":[' + ($nj -join ',') + ']}', (New-Object Text.UTF8Encoding $false))
}
Write-Host "Siap: $($stocks.Count) saham, $($trades.Count) trade, gagal $($fail.Count). Data $lastDate -> $outFile"
