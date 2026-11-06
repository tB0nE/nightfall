param([Parameter(Mandatory)][string]$Root,[uint32[]]$AppIds=@(846470,438100),
    [ValidateSet('h264','h265')][string]$Codec='h264',
    [ValidateRange(256,4096)][int]$EyeWidth=1024,[ValidateRange(256,4096)][int]$EyeHeight=1024,
    [switch]$SteamWrapper,[string]$TestExecutable='')
# Local synthetic-tracking check of the same catalog/claim path used by Quest.
# Opens explicitly registered games; never connects to or launches the headset.
$ErrorActionPreference='Stop'
$target=Join-Path (Split-Path $PSScriptRoot) 'meteor\target'
$env:NIGHTFALL_WINDOWS_XR_ROOT=(Resolve-Path $Root).Path
$env:NIGHTFALL_WINDOWS_XR_OBSERVE_SECONDS='5'
$env:METEOR_NEUTRAL_INPUT='1'
$env:NIGHTFALL_WINDOWS_XR_TEST_WIDTH="$EyeWidth"
$env:NIGHTFALL_WINDOWS_XR_TEST_HEIGHT="$EyeHeight"
$env:NIGHTFALL_WINDOWS_XR_TEST_CODEC=$Codec
if($SteamWrapper){$env:NIGHTFALL_WINDOWS_XR_STEAM_WRAPPER='1'}
else{Remove-Item Env:NIGHTFALL_WINDOWS_XR_STEAM_WRAPPER -ErrorAction SilentlyContinue}
$env:NIGHTFALL_WINDOWS_XR_TEST_BITRATE='32'
$publisher=$null
$summary=@{ok=$false;headset=$false;check='windows-native-catalog';steam_wrapper=[bool]$SteamWrapper;codec=$Codec;eye_width=$EyeWidth;eye_height=$EyeHeight;apps=@()}
try {
    foreach($id in $AppIds) {
    Remove-Item Env:NIGHTFALL_WINDOWS_TRACKING_PORT -ErrorAction SilentlyContinue
    $publisher=Start-Process "$target\windows-runtime-probe\Release\meteor-tracking-socket.exe" -ArgumentList '--serve','0' -PassThru -RedirectStandardOutput "$target\windows-catalog-tracking.out" -RedirectStandardError "$target\windows-catalog-tracking.err"
    for($attempt=0;$attempt -lt 100;$attempt++) {
        if((Get-Content "$target\windows-catalog-tracking.out" -Raw) -match 'loopback:(\d+)'){$env:NIGHTFALL_WINDOWS_TRACKING_PORT=$Matches[1];break}
        Start-Sleep -Milliseconds 50
    }
    if(-not $env:NIGHTFALL_WINDOWS_TRACKING_PORT){throw 'Tracking publisher not ready'}
        $env:NIGHTFALL_WINDOWS_XR_CATALOG_APP="$id"
        if($TestExecutable) {
            & $TestExecutable xr_session::tests::configured_application_delivers_frames_before_bounded_stop --ignored --nocapture
        } else {
            & cargo test --manifest-path "$target\..\Cargo.toml" --release --locked --no-default-features --bin nightfall-meteor xr_session::tests::configured_application_delivers_frames_before_bounded_stop -- --ignored --nocapture
        }
        if($LASTEXITCODE){throw "Catalog game $id failed"}
        $format=if($Codec -eq 'h265'){'hevc'}else{'h264'}
        $capture=Join-Path $env:NIGHTFALL_WINDOWS_XR_ROOT "application-startup.$format"
        $saved=Join-Path $target "windows-catalog-$id-${EyeWidth}x${EyeHeight}.$format"
        Copy-Item $capture $saved -Force
        $ffprobe=Join-Path $target 'windows-ffmpeg\extract\ffmpeg-n8.0.1-66-g27b8d1a017-win64-lgpl-shared-8.0\bin\ffprobe.exe'
        $probe=(& $ffprobe -v error -f $format -count_frames -show_entries stream=codec_name,width,height,nb_read_frames -of json $saved | ConvertFrom-Json).streams[0]
        if($LASTEXITCODE -or $probe.codec_name -ne $format -or $probe.width -ne ($EyeWidth*2) -or $probe.height -ne $EyeHeight -or [int]$probe.nb_read_frames -lt 3){throw 'Decoded video does not match requested codec/dimensions'}
        $summary.apps+=@{app_id=$id;capture_validated=$true;owned_cleanup=$true;decoded=$probe;recording=$saved}
        if($publisher -and -not $publisher.HasExited){Stop-Process -Id $publisher.Id}
        $publisher=$null
    }
    $summary.ok=$true
} finally {
    if($publisher -and -not $publisher.HasExited){Stop-Process -Id $publisher.Id}
    Remove-Item Env:NIGHTFALL_WINDOWS_XR_CATALOG_APP -ErrorAction SilentlyContinue
    $summary | ConvertTo-Json -Depth 5 | Set-Content "$target\windows-catalog-summary.json" -Encoding utf8
}
