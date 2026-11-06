# Windows PowerShell does not consistently wait for GUI-subsystem executables.
# Explicit process ownership and concurrent pipe reads make CLI setup reliable.
function Invoke-MeteorCli([string]$Executable,[string[]]$Options,[AllowNull()][string]$InputText=$null) {
    $quoted=@($Options | ForEach-Object {
        $escaped=[regex]::Replace($_,'(\\*)"','$1$1\"')
        $escaped=[regex]::Replace($escaped,'(\\+)$','$1$1')
        '"'+$escaped+'"'
    })
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$Executable
    $info.Arguments=$quoted -join ' '
    $info.UseShellExecute=$false
    $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true
    $info.RedirectStandardError=$true
    $info.RedirectStandardInput=$PSBoundParameters.ContainsKey('InputText')
    $process=[Diagnostics.Process]::new();$process.StartInfo=$info
    try {
        if(-not $process.Start()){throw 'Could not start Meteor setup command'}
        $stdout=$process.StandardOutput.ReadToEndAsync()
        $stderr=$process.StandardError.ReadToEndAsync()
        if($info.RedirectStandardInput){$process.StandardInput.Write($InputText);$process.StandardInput.Close()}
        $process.WaitForExit()
        $text=$stdout.GetAwaiter().GetResult()
        $errorText=$stderr.GetAwaiter().GetResult()
        if($process.ExitCode){throw "Meteor command failed ($($process.ExitCode)): $($errorText.Trim())"}
        return $text.TrimEnd()
    } finally {$process.Dispose()}
}
