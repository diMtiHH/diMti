$ErrorActionPreference = 'Stop'
# Development-time only. The app plays bundled WAV; it never synthesizes speech.
# Uses installed Windows voices, no network or paid service. Final sound is pending.
$mobileRoot = Split-Path $PSScriptRoot -Parent
$script = Get-Content -LiteralPath (Join-Path $mobileRoot 'assets/onboarding/script.json') -Raw -Encoding utf8 | ConvertFrom-Json
$output = Join-Path $mobileRoot 'build/stage5/audio'
New-Item -ItemType Directory -Force -Path $output | Out-Null
$voices = @{
  ru = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Speech_OneCore\Voices\Tokens\MSTTS_V110_ruRU_PavelM'
  en = 'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Speech\Voices\Tokens\TTS_MS_EN-US_ZIRA_11.0'
}
foreach ($language in @('ru', 'en')) {
  $speaker = New-Object -ComObject SAPI.SpVoice
  $token = New-Object -ComObject SAPI.SpObjectToken
  $token.SetId($voices[$language])
  $speaker.Voice = $token
  $speaker.Rate = -1
  $speaker.Volume = 100
  $index = 0
  foreach ($line in $script.$language) {
    $stream = New-Object -ComObject SAPI.SpFileStream
    $stream.Format.Type = 22 # 22050 Hz, 16-bit, mono.
    try {
      $stream.Open((Join-Path $output "$language-$index.wav"), 3, $false)
      $speaker.AudioOutputStream = $stream
      $speaker.Speak($line, 0) | Out-Null
    } finally {
      $stream.Close()
    }
    $index++
  }
  Write-Output "$language provisional phrases prepared"
}
& python (Join-Path $PSScriptRoot 'package_test_narration.py')
exit $LASTEXITCODE
