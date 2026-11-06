param([Parameter(Mandatory)][string]$Root)
# Opened only after the user chooses Install SteamVR in Nightfall.
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$mutex=[Threading.Mutex]::new($false,('Local\Nightfall.Meteor.InstallSteamVR.'+$sid))
if(-not $mutex.WaitOne(0)){$mutex.Dispose();exit}
try {
    Start-Process 'steam://install/250820' | Out-Null
    $form=[Windows.Forms.Form]::new();$form.Text='Finish SteamVR setup'
    $form.ClientSize=[Drawing.Size]::new(460,185);$form.StartPosition='CenterScreen'
    $form.FormBorderStyle='FixedDialog';$form.MaximizeBox=$false;$form.MinimizeBox=$false
    $status=[Windows.Forms.Label]::new();$status.Location=[Drawing.Point]::new(18,18);$status.Size=[Drawing.Size]::new(420,110)
    $status.Text='Install SteamVR through Steam. Close SteamVR if it opens after installation, then click Continue to finish setup. Your desktop stream can stay connected.'
    $next=[Windows.Forms.Button]::new();$next.Text='Continue';$next.Location=[Drawing.Point]::new(240,140);$next.Width=95
    $cancel=[Windows.Forms.Button]::new();$cancel.Text='Cancel';$cancel.Location=[Drawing.Point]::new(345,140);$cancel.Width=95
    $cancel.DialogResult=[Windows.Forms.DialogResult]::Cancel
    $next.Add_Click({
        if(Get-Process vrserver,vrcompositor -ErrorAction SilentlyContinue){$status.Text='Close SteamVR, then click Continue. Meteor will leave your running VR session untouched.';return}
        $next.Enabled=$false;$form.UseWaitCursor=$true
        try {
            $result=& (Join-Path $PSScriptRoot 'Setup-Meteor.ps1') -EnablePCVR -Root $Root -Quiet -RefreshPCVRMetadata | ConvertFrom-Json
            if(-not $result.ok){throw $result.error}
            if(-not $result.steamvr_ready){throw 'SteamVR is not installed yet. Finish its installation in Steam and click Continue.'}
            $status.Text='SteamVR is ready. Refresh VR Apps in Nightfall, then launch your game.'
            $next.Visible=$false;$cancel.Text='Close'
        } catch {$status.Text=$_.Exception.Message;$next.Enabled=$true} finally {$form.UseWaitCursor=$false}
    })
    $form.Controls.AddRange(@($status,$next,$cancel));$form.AcceptButton=$next;$form.CancelButton=$cancel
    [void]$form.ShowDialog();$form.Dispose()
} finally {$mutex.ReleaseMutex();$mutex.Dispose()}
