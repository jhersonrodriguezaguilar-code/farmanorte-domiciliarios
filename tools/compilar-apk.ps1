# Compila la APK de farmanorte con Supabase real y deja registro en _build_logs.
# No imprime claves: solo el host de Supabase y el prefijo del tipo de clave.
$ErrorActionPreference = 'Continue'
$project = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $project

$logDir = Join-Path $project '_build_logs'
New-Item -ItemType Directory -Force $logDir | Out-Null
$log = Join-Path $logDir 'build.log'
$statusFile = Join-Path $logDir 'estado.json'
"" | Out-File -Encoding utf8 $log
$status = [ordered]@{ started = (Get-Date).ToString('s'); done = $false; steps = [ordered]@{} }

function Save-Status { $status | ConvertTo-Json -Depth 5 | Out-File -Encoding utf8 $statusFile }
function Write-Log([string]$text) { $text | Out-File -Append -Encoding utf8 $log }
function Run-Step([string]$name, [scriptblock]$block) {
  Write-Log "`n=== $name === $((Get-Date).ToString('T'))"
  $status.steps[$name] = 'running'; Save-Status
  & $block *>&1 | ForEach-Object { "$_" } | Out-File -Append -Encoding utf8 $log
  $code = $LASTEXITCODE
  Write-Log "EXIT $name = $code"
  $status.steps[$name] = $code
  Save-Status
  return $code
}
Save-Status

# --- Herramientas -----------------------------------------------------------
$tools = 'C:\Users\jhers\Documents\Codex\tools'
$flutterBin = Join-Path $tools 'flutter\bin'
if (-not (Test-Path (Join-Path $flutterBin 'flutter.bat'))) {
  $found = Get-Command flutter -ErrorAction SilentlyContinue
  if ($found) { $flutterBin = Split-Path -Parent $found.Source }
}
$env:Path = "$flutterBin;$env:Path"
$env:ANDROID_HOME = Join-Path $tools 'android-sdk'
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME

if (-not $env:JAVA_HOME -or -not (Test-Path (Join-Path $env:JAVA_HOME 'bin\java.exe'))) {
  $candidates = @()
  $candidates += Get-ChildItem -Path $tools -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'bin\java.exe') } | ForEach-Object { $_.FullName }
  $candidates += Get-ChildItem -Path $tools -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Get-ChildItem -Path $_.FullName -Directory -ErrorAction SilentlyContinue } |
    Where-Object { Test-Path (Join-Path $_.FullName 'bin\java.exe') } | ForEach-Object { $_.FullName }
  $candidates += @('C:\Program Files\Android\Android Studio\jbr', 'C:\Program Files\Android\Android Studio\jre') |
    Where-Object { Test-Path (Join-Path $_ 'bin\java.exe') }
  $candidates += Get-ChildItem 'C:\Program Files\Java', 'C:\Program Files\Eclipse Adoptium', 'C:\Program Files\Microsoft' -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'jdk' -and (Test-Path (Join-Path $_.FullName 'bin\java.exe')) } | ForEach-Object { $_.FullName }
  if ($candidates.Count -gt 0) { $env:JAVA_HOME = $candidates[0] }
}
if ($env:JAVA_HOME) { $env:Path = "$(Join-Path $env:JAVA_HOME 'bin');$env:Path" }
Write-Log "Flutter: $flutterBin"
Write-Log "JAVA_HOME: $env:JAVA_HOME"
Write-Log "ANDROID_HOME: $env:ANDROID_HOME"

# --- Variables de Supabase (sin imprimir valores) ----------------------------
$envFile = Join-Path $project 'pharmacy_web\.env.local'
$vars = @{}
if (Test-Path $envFile) {
  Get-Content $envFile | ForEach-Object {
    if ($_ -match '^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$') { $vars[$Matches[1]] = $Matches[2].Trim('"', "'", ' ') }
  }
}
$supabaseUrl = $vars['VITE_SUPABASE_URL']
$supabaseKey = $vars['VITE_SUPABASE_PUBLISHABLE_KEY']
if (-not $supabaseUrl -or -not $supabaseKey) {
  Write-Log 'ERROR: faltan VITE_SUPABASE_URL o VITE_SUPABASE_PUBLISHABLE_KEY en pharmacy_web\.env.local'
  $status.error = 'missing_supabase_env'; $status.done = $true; Save-Status; exit 1
}
if ($supabaseKey -like 'sb_secret_*' -or $supabaseKey -match 'service_role') {
  Write-Log 'ERROR: la clave de .env.local es secreta; la APK solo puede usar la clave publishable.'
  $status.error = 'secret_key_refused'; $status.done = $true; Save-Status; exit 1
}
Write-Log "Supabase host: $(([Uri]$supabaseUrl).Host)"
Write-Log "Tipo de clave: $($supabaseKey.Substring(0, [Math]::Min(15, $supabaseKey.Length)))..."

# --- Pasos ------------------------------------------------------------------
Run-Step 'flutter_version' { flutter --version } | Out-Null
Run-Step 'pub_get' { flutter pub get } | Out-Null
Run-Step 'dart_format' { dart format lib/main.dart } | Out-Null
Run-Step 'analyze' { flutter analyze --no-fatal-infos } | Out-Null
$buildCode = Run-Step 'build_apk' {
  flutter build apk --release -PallowDebugSigning=true `
    "--dart-define=SUPABASE_URL=$supabaseUrl" `
    "--dart-define=SUPABASE_PUBLISHABLE_KEY=$supabaseKey"
}

$apk = Join-Path $project 'build\app\outputs\flutter-apk\app-release.apk'
if ($buildCode -eq 0 -and (Test-Path $apk)) {
  $version = (Select-String -Path (Join-Path $project 'pubspec.yaml') -Pattern '^version:\s*(.+)$').Matches[0].Groups[1].Value.Trim()
  $outDir = Join-Path $project 'salidas-apk'
  New-Item -ItemType Directory -Force $outDir | Out-Null
  $target = Join-Path $outDir ("farmanorte-domicilios-$version.apk" -replace '\+', '-build')
  Copy-Item $apk $target -Force
  $hash = (Get-FileHash $target -Algorithm SHA256).Hash
  $status.apk = $target
  $status.apk_sha256 = $hash
  $status.apk_bytes = (Get-Item $target).Length
  Write-Log "APK: $target"
  Write-Log "SHA256: $hash"
}
Save-Status

Run-Step 'test' { flutter test } | Out-Null
$status.finished = (Get-Date).ToString('s')
$status.done = $true
Save-Status
