# Semak signal forex, gold dan crypto (strategi sama seperti signal-app.html), hantar noti Telegram,
# dan tulis vk-signals.json untuk laman VK Signal (vk-signal.html).
# Dijalankan setiap jam oleh GitHub Actions. Perlu env: TWELVE_DATA_KEY. Telegram pilihan: TELEGRAM_TOKEN, TELEGRAM_CHAT_ID.
# Tambah atau buang simbol dalam senarai-noti.txt.
# -UjiFail <json>: kira signal dari fail sahaja dan cetak, tanpa internet (untuk ujian).
# -UjiVK <json> -VkOut <fail>: ujian VK Signal tanpa internet. Candle dibaca dari fail { "XAU/USD": [[masa,o,h,l,c],...] }.
param([string]$UjiFail, [string]$UjiVK, [string]$VkOut, [int]$Lookback = 3)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$dir   = $PSScriptRoot
$list  = Join-Path $dir 'senarai-noti.txt'
$state = Join-Path $dir 'noti-state.json'
$inv   = [Globalization.CultureInfo]::InvariantCulture
$iv    = '1h'; $ivName = 'H1'
$slAtr = 1.5
# Kalau satu run GitHub terlewat, signal 3 candle terakhir masih dihantar
$lookback = $Lookback
$vkFile = if ($VkOut) { $VkOut } else { Join-Path $dir 'vk-signals.json' }
$riskEg = 10

function Get-Ema($src, $p) {
  $out = New-Object 'object[]' $src.Count
  if ($src.Count -lt $p) { return ,$out }
  $s = 0.0; for ($i = 0; $i -lt $p; $i++) { $s += $src[$i] }
  $prev = $s / $p; $out[$p - 1] = $prev; $k = 2.0 / ($p + 1)
  for ($i = $p; $i -lt $src.Count; $i++) { $prev = $src[$i] * $k + $prev * (1 - $k); $out[$i] = $prev }
  ,$out
}
function Get-Rsi($c, $p) {
  $out = New-Object 'object[]' $c.Count
  if ($c.Count -le $p) { return ,$out }
  $g = 0.0; $l = 0.0
  for ($i = 1; $i -le $p; $i++) { $d = $c[$i] - $c[$i - 1]; if ($d -gt 0) { $g += $d } else { $l -= $d } }
  $g /= $p; $l /= $p
  $out[$p] = if ($l -eq 0) { 100.0 } else { 100 - 100 / (1 + $g / $l) }
  for ($i = $p + 1; $i -lt $c.Count; $i++) {
    $d = $c[$i] - $c[$i - 1]
    $g = ($g * ($p - 1) + [Math]::Max($d, 0)) / $p
    $l = ($l * ($p - 1) + [Math]::Max(-$d, 0)) / $p
    $out[$i] = if ($l -eq 0) { 100.0 } else { 100 - 100 / (1 + $g / $l) }
  }
  ,$out
}
function Get-Atr($B, $p) {
  $n = $B.c.Count; $out = New-Object 'object[]' $n
  if ($n -le $p) { return ,$out }
  $tr = New-Object 'double[]' $n; $tr[0] = $B.h[0] - $B.l[0]
  for ($i = 1; $i -lt $n; $i++) {
    $tr[$i] = [Math]::Max($B.h[$i] - $B.l[$i], [Math]::Max([Math]::Abs($B.h[$i] - $B.c[$i - 1]), [Math]::Abs($B.l[$i] - $B.c[$i - 1])))
  }
  $a = 0.0; for ($i = 1; $i -le $p; $i++) { $a += $tr[$i] }
  $a /= $p; $out[$p] = $a
  for ($i = $p + 1; $i -lt $n; $i++) { $a = ($a * ($p - 1) + $tr[$i]) / $p; $out[$i] = $a }
  ,$out
}

function Test-Signal($B, $Ind, $i) {
  if ($i -lt 5 -or $null -eq $Ind.e200[$i] -or $null -eq $Ind.e9[$i - 1] -or $null -eq $Ind.a[$i]) { return $null }
  $c = $B.c[$i]; $e50 = $Ind.e50[$i]; $e200 = $Ind.e200[$i]; $r = $Ind.r[$i]
  $up = $e50 -gt $e200 -and $c -gt $e200
  $dn = $e50 -lt $e200 -and $c -lt $e200
  $xUp = $Ind.e9[$i - 1] -le $Ind.e21[$i - 1] -and $Ind.e9[$i] -gt $Ind.e21[$i]
  $xDn = $Ind.e9[$i - 1] -ge $Ind.e21[$i - 1] -and $Ind.e9[$i] -lt $Ind.e21[$i]
  if ($up -and $xUp -and $r -ge 50 -and $r -le 70) { $side = 'BUY'; $d = 1 }
  elseif ($dn -and $xDn -and $r -ge 30 -and $r -le 50) { $side = 'SELL'; $d = -1 }
  else { return $null }
  $R1 = $Ind.a[$i] * $slAtr
  $score = 3
  if ([Math]::Abs($c - $e50) / $Ind.a[$i] -lt 2) { $score++ }
  if ($d * ($c - $B.o[$i]) -gt 0) { $score++ }
  if ($d * ($e50 - $Ind.e50[$i - 5]) -gt 0) { $score++ }
  @{ i = $i; side = $side; d = $d; entry = $c; sl = $c - $d * $R1; tp1 = $c + $d * $R1; tp2 = $c + $d * 2 * $R1; tp3 = $c + $d * 3 * $R1; R = $R1; score = $score; time = $B.t[$i] }
}
function Get-Result($B, $s) {
  $d = $s.d; $tps = @($s.tp1, $s.tp2, $s.tp3); $sl = $s.sl; $stage = 0; $pnl = 0.0
  for ($j = $s.i + 1; $j -lt $B.c.Count; $j++) {
    if (($d -eq 1 -and $B.l[$j] -le $sl) -or ($d -eq -1 -and $B.h[$j] -ge $sl)) {
      if ($stage -eq 0) { $pnl = -1.0 } elseif ($stage -eq 2) { $pnl += 1 / 3 }
      return @{ pnl = $pnl; stage = $stage; exit = $j; status = @('SL kena', 'TP1 BE', 'TP2 SL@TP1')[$stage] }
    }
    while ($stage -lt 3 -and (($d -eq 1 -and $B.h[$j] -ge $tps[$stage]) -or ($d -eq -1 -and $B.l[$j] -le $tps[$stage]))) {
      $pnl += ($stage + 1) / 3; $stage++
      if ($stage -eq 1) { $sl = $s.entry }
      if ($stage -eq 2) { $sl = $s.tp1 }
    }
    if ($stage -eq 3) { return @{ pnl = $pnl; stage = $stage; exit = $j; status = 'TP3 penuh' } }
  }
  @{ pnl = $pnl; stage = $stage; exit = $null; status = 'BERJALAN' }
}
# Satu trade pada satu masa, sama seperti analyze() dalam app. Candle terakhir belum tutup, jadi tidak dikira.
function Get-Trades($B) {
  $Ind = @{ e9 = Get-Ema $B.c 9; e21 = Get-Ema $B.c 21; e50 = Get-Ema $B.c 50; e200 = Get-Ema $B.c 200; r = Get-Rsi $B.c 14; a = Get-Atr $B 14 }
  $last = $B.c.Count - 2; $busy = -1
  $trades = New-Object System.Collections.ArrayList
  for ($i = 1; $i -le $last; $i++) {
    if ($i -le $busy) { continue }
    $s = Test-Signal $B $Ind $i
    if (-not $s) { continue }
    $res = Get-Result $B $s
    foreach ($k in $res.Keys) { $s[$k] = $res[$k] }
    [void]$trades.Add($s)
    $busy = if ($null -eq $res.exit) { [int]::MaxValue } else { $res.exit }
  }
  ,$trades
}
function New-Bars($rows) {
  $B = @{ t = New-Object string[] $rows.Count; o = New-Object double[] $rows.Count; h = New-Object double[] $rows.Count; l = New-Object double[] $rows.Count; c = New-Object double[] $rows.Count }
  for ($i = 0; $i -lt $rows.Count; $i++) {
    $x = $rows[$i]; $B.t[$i] = $x[0]; $B.o[$i] = $x[1]; $B.h[$i] = $x[2]; $B.l[$i] = $x[3]; $B.c[$i] = $x[4]
  }
  $B
}

function Format-Price($v, $ref) {
  $dp = if ($ref -lt 10) { 5 } elseif ($ref -lt 1000) { 3 } else { 2 }
  $v.ToString("F$dp", $inv)
}
function Format-Message($sym, $s, $now, $url) {
  $icon = [char]::ConvertFromUtf32($(if ($s.side -eq 'BUY') { 0x1F7E2 } else { 0x1F534 }))
  $word = @{ 3 = 'Lemah'; 4 = 'Sederhana'; 5 = 'Kuat'; 6 = 'Sangat Kuat' }[[int]$s.score]
  $p = { param($v) Format-Price $v $s.entry }
  $m = @(
    "$icon $($s.side) $sym ($ivName)"
    "Skor $($s.score)/6 ($word)"
    "Candle tutup: $($s.time) (waktu Malaysia)"
    ""
    "Entry: $(& $p $s.entry)"
    "Harga kini: $(& $p $now)"
    "Stop Loss: $(& $p $s.sl)"
    "TP1: $(& $p $s.tp1)  (tutup 1/3, alih SL ke entry)"
    "TP2: $(& $p $s.tp2)  (tutup 1/3, alih SL ke TP1)"
    "TP3: $(& $p $s.tp3)  (tutup baki)"
    ""
    "Contoh risiko `$$($riskEg):"
    "SL kena: -`$$($riskEg.ToString('F2', $inv))"
    "TP1 kemudian patah balik: +`$$(($riskEg / 3).ToString('F2', $inv))"
    "TP1 dan TP2 kemudian patah balik: +`$$(($riskEg * 4 / 3).ToString('F2', $inv))"
    "Semua TP kena: +`$$(($riskEg * 2).ToString('F2', $inv))"
    ""
    "Elak masuk kalau harga dah jauh dari entry, atau dekat berita besar. Bukan nasihat kewangan."
  )
  if ($url) { $m += $url }
  $m -join "`n"
}

if ($UjiFail) {
  # Ujian: { "nama": [[masa,o,h,l,c],...] } -> senarai trade untuk dibanding dengan app
  $data = Get-Content $UjiFail -Raw | ConvertFrom-Json
  foreach ($prop in $data.PSObject.Properties) {
    $B = New-Bars $prop.Value
    $tr = Get-Trades $B
    foreach ($t in $tr) {
      [string]::Format($inv, '{0}|{1}|{2}|{3}|{4:0.000000}|{5:0.000000}|{6}|{7}|{8:0.000000}', $prop.Name, $t.i, $t.side, $t.score, $t.entry, $t.sl, $t.stage, $(if ($null -eq $t.exit) { 'null' } else { $t.exit }), $t.pnl)
    }
    if ($tr.Count) { $script:lastMsg = Format-Message $prop.Name $tr[$tr.Count - 1] $B.c[$B.c.Count - 1] 'https://contoh.github.io/app/' }
  }
  if ($script:lastMsg) { [IO.File]::WriteAllText("$UjiFail.msg.txt", $script:lastMsg, (New-Object Text.UTF8Encoding $false)) }
  exit
}

# Mesej ralat sebenar daripada pelayan (badan respons), bukan sekadar "400 Bad Request"
function Get-HttpError($e) {
  $m = "$($e.Exception.Message)"
  try {
    $r = $e.Exception.Response
    if ($r) {
      $b = if ($e.ErrorDetails -and $e.ErrorDetails.Message) { "$($e.ErrorDetails.Message)" } else {
        $st = $r.GetResponseStream(); if ($st.CanSeek) { $st.Position = 0 }
        (New-Object IO.StreamReader($st)).ReadToEnd()
      }
      $m = "HTTP $([int]$r.StatusCode)" + $(if ($b) { ': ' + $b.Substring(0, [Math]::Min(200, $b.Length)) } else { '' })
    }
  } catch { }
  $m
}
function Send-Telegram($text) {
  if (-not $env:TELEGRAM_TOKEN -or -not $env:TELEGRAM_CHAT_ID) { return }
  $body = @{ chat_id = $env:TELEGRAM_CHAT_ID; text = $text; disable_web_page_preview = $true } | ConvertTo-Json
  [void](Invoke-RestMethod -Uri "https://api.telegram.org/bot$($env:TELEGRAM_TOKEN)/sendMessage" -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 30)
}
# Had pelan percuma Twelve Data: 8 panggilan seminit
function Get-Candles($sym) {
  if ($UjiVK) { return New-Bars @($script:ujiData.$sym) }
  $q = [uri]::EscapeDataString($sym)
  $url = "https://api.twelvedata.com/time_series?symbol=$q&interval=$iv&outputsize=1000&timezone=Asia/Kuala_Lumpur&apikey=$($env:TWELVE_DATA_KEY)"
  for ($try = 0; $try -lt 2; $try++) {
    $j = $null; $err = ''
    try { $j = Invoke-RestMethod -Uri $url -TimeoutSec 30 } catch { $err = Get-HttpError $_ }
    if ($j -and $j.values) { break }
    if (-not $err) { $err = "HTTP $($j.code): $($j.message)" }
    if ($env:TWELVE_DATA_KEY) { $err = $err.Replace($env:TWELVE_DATA_KEY, '***') }
    # Cuba semula hanya untuk had kadar (429) atau masalah rangkaian; ralat 4xx lain (cth. simbol tiada dalam pelan) tidak akan berubah
    if ($try -eq 1 -or ($err -match '^HTTP 4' -and $err -notmatch '^HTTP 429|credit')) { throw $err }
    Start-Sleep -Seconds 65
  }
  $rows = @($j.values); [array]::Reverse($rows)
  New-Bars @($rows | ForEach-Object { ,@($_.datetime, [double]::Parse($_.open, $inv), [double]::Parse($_.high, $inv), [double]::Parse($_.low, $inv), [double]::Parse($_.close, $inv)) })
}

# ---------- VK Signal ----------
# Strategi VK lain daripada noti Telegram: lihat Update-VK. Signal hanya ditambah bila ia baru berlaku (dalam $lookback candle terakhir), jadi rekod prestasi
# bermula dari hari pertama laman ini berjalan. Signal yang masih berjalan disemak semula setiap jam.
function Get-AssetType($sym) {
  if ($sym -match '^(XAU|XAG)') { 'metal' } elseif ($sym -match '^(BTC|ETH|SOL|XRP|BNB|ADA|DOGE|LTC)') { 'crypto' } else { 'forex' }
}
function To-Iso($t) { if ($t) { ($t -replace ' ', 'T') + '+08:00' } else { $null } }
function Round6($v) { [Math]::Round([double]$v, 6) }
$vk = @{}; $vkMarket = New-Object System.Collections.ArrayList; $vkMula = $null
$vkSymbols = @('XAU/USD', 'XAG/USD', 'BTC/USD', 'ETH/USD', 'SOL/USD', 'XRP/USD')
if (Test-Path $vkFile) {
  try {
    $old = Get-Content $vkFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $vkMula = $old.mula
    foreach ($s in @($old.signals)) { if ($s.id) { $vk[$s.id] = $s } }
  } catch { Write-Host "  vk-signals.json rosak, mula baru" }
}
if (-not $vkMula) { $vkMula = (Get-Date).ToUniversalTime().AddHours(8).ToString('yyyy-MM-ddTHH:mm:ss+08:00', $inv) }

function Update-VK($sym, $B) {
  # Strategi VK Signal (dipilih selepas backtest 2 tahun, 2026-11-10): breakout 50 candle H1 + trend EMA50/200,
  # SL 2 x ATR(14), keluar bila candle tutup lintas EMA50. Hanya emas, perak dan crypto (forex rugi dalam ujian).
  if ($sym -notin $vkSymbols) { return }
  $key = $sym -replace '/', ''
  $last = $B.c.Count - 1; $lastClosed = $last - 1
  $X = @{ e50 = Get-Ema $B.c 50; e200 = Get-Ema $B.c 200; a = Get-Atr $B 14; rsi = Get-Rsi $B.c 14 }
  # Semak semula signal yang masih berjalan (candle yang sudah tutup sahaja)
  $open = $false
  foreach ($s in @($vk.Values | Where-Object { $_.sym -eq $key -and $_.status -eq 'BERJALAN' })) {
    $k = [Array]::IndexOf($B.t, [string]$s.signalTime)
    if ($k -lt 0) { $open = $true; continue }
    Step-VK $B $X $s $k $lastClosed
    if ($s.status -eq 'BERJALAN') { $open = $true }
  }
  # Signal baru: hanya dalam $lookback candle terakhir, selepas signal sebelumnya selesai
  if (-not $open) {
    $after = ''
    foreach ($s in @($vk.Values | Where-Object { $_.sym -eq $key -and $_.exitRaw })) { if ([string]::CompareOrdinal($s.exitRaw, $after) -gt 0) { $after = $s.exitRaw } }
    $k = [Math]::Max(201, $lastClosed - $lookback + 1)
    while ($k -le $lastClosed) {
      if ([string]::CompareOrdinal($B.t[$k], $after) -le 0) { $k++; continue }
      $d = Test-Break $B $X $k
      if (-not $d) { $k++; continue }
      $id = $key + '-' + ($B.t[$k] -replace '[^0-9]', '')
      if ($vk.ContainsKey($id)) { break }
      $risk = 2 * $X.a[$k]; $en = $B.c[$k]
      $s = [pscustomobject][ordered]@{
        id = $id; sym = $key; asset = Get-AssetType $sym; side = $(if ($d -eq 1) { 'BUY' } else { 'SELL' }); tf = $ivName; strategy = 'breakout50'
        signalTime = [string]$B.t[$k]; time = To-Iso $B.t[$k]
        entry = Round6 $en; sl = Round6 ($en - $d * $risk); R = Round6 $risk; costR = Round6 ((Get-VkCost $key $en) / $risk)
        status = 'BERJALAN'; pnl = 0.0; exitTime = $null; exitRaw = $null; exitPrice = $null; exitLevel = $null
      }
      $vk[$id] = $s
      Write-Host "  VK BARU  $key $($s.side) $($B.t[$k])"
      Step-VK $B $X $s $k $lastClosed
      if ($s.status -eq 'BERJALAN') { break }
      $k = [Array]::IndexOf($B.t, [string]$s.exitRaw) + 1
    }
  }
  # Keadaan pasaran sekarang (candle terakhir yang sudah tutup)
  $c = $B.c[$lastClosed]; $e50 = $X.e50[$lastClosed]; $e200 = $X.e200[$lastClosed]
  $trend = if ($null -eq $e200) { 'TIADA' } elseif ($e50 -gt $e200 -and $c -gt $e200) { 'NAIK' } elseif ($e50 -lt $e200 -and $c -lt $e200) { 'TURUN' } else { 'MENDATAR' }
  $hi = [double]::MinValue; $lo = [double]::MaxValue
  for ($j = $lastClosed - 49; $j -le $lastClosed; $j++) { if ($B.c[$j] -gt $hi) { $hi = $B.c[$j] }; if ($B.c[$j] -lt $lo) { $lo = $B.c[$j] } }
  $from = [Math]::Max(0, $last - 120)
  [void]$vkMarket.Add([pscustomobject][ordered]@{
    sym = $key; asset = Get-AssetType $sym; price = Round6 $B.c[$last]; time = To-Iso $B.t[$last]
    trend = $trend; rsi = if ($null -ne $X.rsi[$lastClosed]) { [Math]::Round($X.rsi[$lastClosed], 1) } else { $null }
    hi50 = Round6 $hi; lo50 = Round6 $lo; ema50 = if ($null -ne $e50) { Round6 $e50 } else { $null }
    change24 = if ($last -ge 24) { [Math]::Round(($B.c[$last] / $B.c[$last - 24] - 1) * 100, 2) } else { $null }
    t = [object[]]@($B.t[$from..$last] | ForEach-Object { To-Iso $_ })
    c = [object[]]@($B.c[$from..$last] | ForEach-Object { Round6 $_ })
  })
}
# Anggaran spread + yuran pergi-balik (sama seperti backtest-forex.ps1), ditolak daripada keputusan di laman
function Get-VkCost($key, $price) {
  switch -regex ($key) { '^XAU' { 0.35 } '^XAG' { 0.03 } default { 0.001 * $price } }
}
# 1 = BUY, -1 = SELL, 0 = tiada. Sama seperti Run-Break dalam backtest-varian.ps1
function Test-Break($B, $X, $k) {
  if ($k -lt 201 -or $null -eq $X.a[$k] -or $null -eq $X.e200[$k]) { return 0 }
  $c = $B.c[$k]; $hi = [double]::MinValue; $lo = [double]::MaxValue
  for ($j = $k - 50; $j -lt $k; $j++) { if ($B.c[$j] -gt $hi) { $hi = $B.c[$j] }; if ($B.c[$j] -lt $lo) { $lo = $B.c[$j] } }
  if ($c -gt $hi -and $X.e50[$k] -gt $X.e200[$k] -and $c -gt $X.e200[$k]) { return 1 }
  if ($c -lt $lo -and $X.e50[$k] -lt $X.e200[$k] -and $c -lt $X.e200[$k]) { return -1 }
  0
}
# Jalankan trade dari candle selepas signal hingga candle terakhir yang sudah tutup
function Step-VK($B, $X, $s, $k, $lastClosed) {
  $d = if ($s.side -eq 'BUY') { 1 } else { -1 }
  for ($j = $k + 1; $j -le $lastClosed; $j++) {
    if (($d -eq 1 -and $B.l[$j] -le $s.sl) -or ($d -eq -1 -and $B.h[$j] -ge $s.sl)) {
      $s.status = 'SL kena'; $s.pnl = -1.0; $s.exitPrice = $s.sl; $s.exitRaw = [string]$B.t[$j]; $s.exitTime = To-Iso $B.t[$j]; $s.exitLevel = $null; return
    }
    if ($d * ($B.c[$j] - $X.e50[$j]) -lt 0) {
      $s.status = 'KELUAR'; $s.pnl = Round6 (($B.c[$j] - $s.entry) * $d / $s.R); $s.exitPrice = Round6 $B.c[$j]; $s.exitRaw = [string]$B.t[$j]; $s.exitTime = To-Iso $B.t[$j]; $s.exitLevel = $null; return
    }
  }
  $s.exitLevel = Round6 $X.e50[$lastClosed]
}
function Save-VK($symbols) {
  $sig = [object[]]@($vk.Values | Sort-Object { $_.time } -Descending | Select-Object -First 3000)
  $order = @($symbols | ForEach-Object { $_ -replace '/', '' })
  $mk = [object[]]@($vkMarket | Sort-Object { [Array]::IndexOf($order, $_.sym) })
  $doc = [pscustomobject][ordered]@{
    app = 'VK Signal'; updated = (Get-Date).ToUniversalTime().AddHours(8).ToString('yyyy-MM-ddTHH:mm:ss+08:00', $inv)
    mula = $vkMula; tf = $ivName; strategy = 'breakout50'; market = $mk; signals = $sig
  }
  [IO.File]::WriteAllText($vkFile, ($doc | ConvertTo-Json -Depth 6 -Compress), (New-Object Text.UTF8Encoding $false))
}

if ($UjiVK) {
  $script:ujiData = Get-Content $UjiVK -Raw | ConvertFrom-Json
  $symbols = @($script:ujiData.PSObject.Properties.Name)
  foreach ($sym in $symbols) { $B = Get-Candles $sym; Update-VK $sym $B }
  Save-VK $symbols
  Write-Host "Ujian VK selesai: $($vk.Count) signal -> $vkFile"
  exit
}

if (-not $env:TWELVE_DATA_KEY) { Write-Host "Secret TWELVE_DATA_KEY belum diisi di GitHub."; exit 1 }
$seen = @{}
if (Test-Path $state) { (Get-Content $state -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $seen[$_.Name] = $_.Value } }
$url = if ($env:GITHUB_REPOSITORY) { $o, $n = $env:GITHUB_REPOSITORY -split '/'; "https://$($o.ToLower()).github.io/$n/" } else { '' }

$symbols = @(Get-Content $list -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
$fail = @(); $sent = 0; $first = $true
foreach ($sym in $symbols) {
  if (-not $first) { Start-Sleep -Seconds 8 }
  $first = $false
  try {
    $B = Get-Candles $sym
    $tr = Get-Trades $B
    try { Update-VK $sym $B } catch { Write-Host "  VK gagal $sym : $($_.Exception.Message)" }
    $lastClosed = $B.c.Count - 2
    $cand = @($tr | Where-Object { $_.i -gt $lastClosed - $lookback -and $_.status -eq 'BERJALAN' -and $_.stage -eq 0 })
    if ($cand.Count) {
      $s = $cand[$cand.Count - 1]
      if (-not $seen[$sym] -or [string]::CompareOrdinal($s.time, $seen[$sym]) -gt 0) {
        # Telegram gagal tidak dikira sebagai simbol gagal; signal akan dicuba lagi pada larian seterusnya
        try {
          Send-Telegram (Format-Message $sym $s $B.c[$B.c.Count - 1] $url)
          $seen[$sym] = $s.time; $sent++
          Write-Host "  HANTAR  $sym $($s.side) $($s.time)"
        } catch { $tgErr = Get-HttpError $_; Write-Host "  TELEGRAM GAGAL  $sym : $tgErr" }
      } else { Write-Host "  sudah dihantar  $sym" }
    } else { Write-Host "  tiada signal  $sym" }
  } catch {
    $fail += "$sym ($($_.Exception.Message))"
    Write-Host "  GAGAL  $sym : $($_.Exception.Message)"
  }
}
$ordered = [ordered]@{}; $seen.Keys | Sort-Object | ForEach-Object { $ordered[$_] = $seen[$_] }
[IO.File]::WriteAllText($state, ($ordered | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
if ($vkMarket.Count) { Save-VK $symbols }

if ($env:UJI -eq 'true') {
  $tick = [char]::ConvertFromUtf32(0x2705)
  $t = "$tick Noti Signal Trader berfungsi.`n$($symbols.Count - $fail.Count) daripada $($symbols.Count) simbol berjaya disemak, $sent signal baru."
  if ($fail) { $t += "`nGagal: $($fail -join '; ')" }
  try { Send-Telegram $t } catch { $tgErr = Get-HttpError $_; Write-Host "  TELEGRAM GAGAL (mesej ujian) : $tgErr" }
}
if ($tgErr) { Write-Host "Telegram tidak berjaya. Semak secret TELEGRAM_CHAT_ID dan TELEGRAM_TOKEN, dan pastikan anda sudah tekan Start pada bot." }
Write-Host "Selesai: $sent noti dihantar, $($fail.Count) gagal."
if ($symbols.Count -and $fail.Count -eq $symbols.Count) { exit 1 }
