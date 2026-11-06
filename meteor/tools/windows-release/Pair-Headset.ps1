# User-invoked pairing dialog. Never expose host credentials or PINs in argv.
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'Meteor-Cli.ps1')
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$mutex=[Threading.Mutex]::new($false,('Local\Nightfall.Meteor.Pair.'+$sid))
if(-not $mutex.WaitOne(0)){$mutex.Dispose();exit}
try {
    $form=[Windows.Forms.Form]::new()
    $form.Text='Pair Nightfall headset';$form.ClientSize=[Drawing.Size]::new(430,210)
    $form.StartPosition='CenterScreen';$form.FormBorderStyle='FixedDialog'
    $form.MaximizeBox=$false;$form.MinimizeBox=$false;$form.TopMost=$true
    $label=[Windows.Forms.Label]::new();$label.Location=[Drawing.Point]::new(18,16)
    $label.Size=[Drawing.Size]::new(394,42)
    $label.Text='In Nightfall, select this PC and start pairing. Enter the four-digit PIN shown on your headset.'
    $pin=[Windows.Forms.TextBox]::new();$pin.Location=[Drawing.Point]::new(18,66)
    $pin.Width=130;$pin.MaxLength=4;$pin.Font=[Drawing.Font]::new('Segoe UI',18)
    $status=[Windows.Forms.Label]::new();$status.Location=[Drawing.Point]::new(18,116)
    $status.Size=[Drawing.Size]::new(394,45)
    $send=[Windows.Forms.Button]::new();$send.Text='Send PIN';$send.Location=[Drawing.Point]::new(234,173);$send.Width=86
    $close=[Windows.Forms.Button]::new();$close.Text='Close';$close.Location=[Drawing.Point]::new(326,173);$close.Width=86
    $close.DialogResult=[Windows.Forms.DialogResult]::Cancel
    $pin.Add_TextChanged({$send.Enabled=$pin.Text -cmatch '^[0-9]{4}$'})
    $send.Add_Click({
        if($pin.Text -cnotmatch '^[0-9]{4}$'){$status.Text='Enter the four digits shown in Nightfall.';return}
        $send.Enabled=$false;$form.UseWaitCursor=$true;$status.Text='Sending PIN...'
        [Windows.Forms.Application]::DoEvents()
        try {
            $status.Text=Invoke-MeteorCli -Executable (Join-Path $PSScriptRoot 'nightfall-meteor.exe') -Options @('--host-pair-pin') -InputText $pin.Text
            $pin.Clear();$send.Enabled=$false
        } catch {$status.Text=$_.Exception.Message;$send.Enabled=$true} finally {$form.UseWaitCursor=$false}
    })
    $form.Controls.AddRange(@($label,$pin,$status,$send,$close))
    $form.AcceptButton=$send;$form.CancelButton=$close
    $form.Add_Shown({$pin.Focus()})
    [void]$form.ShowDialog()
    $form.Dispose()
} finally {$mutex.ReleaseMutex();$mutex.Dispose()}
