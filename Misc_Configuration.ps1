# Disable DEP

bcdedit.exe /set nx optin

# Disable CDROM

reg add HKLM\System\CurrentControlSet\Services\cdrom /t REG_DWORD /v "Start" /d 4 /f

# Powershell Policy

New-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell' -Name 'ExecutionPolicy' -Value 'Unrestricted' -PropertyType String -Force -ea SilentlyContinue;

# Create Temp Folder

mkdir c:\Temp -Force

# Set Firewall

netsh advfirewall firewall set rule group="Remote Desktop" new enable=yes
netsh int tcp set global timestamps=disabled
netsh firewall set icmpsetting 13 disable

# Disable EvenTtracker

New-Item -Path 'registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows NT\Reliability'
New-ItemProperty -Path 'registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows NT\Reliability' -Name ShutdownReasonOn -Value 0
Set-ItemProperty -Path 'registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows NT\Reliability' -Name ShutdownReasonOn -Value 0

# Disable IPV6

if((Test-Path -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters") -ne $true) {  New-Item "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters" -force -ea SilentlyContinue };
New-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' -Name 'DisabledComponents' -Value 255 -PropertyType DWord -Force -ea SilentlyContinue;

# Disable Services : MapsBroker / Sync Host / Spooler

get-service "MapsBroker" | Stop-Service 
get-service "MapsBroker" | Set-Service -StartupType  Disabled -Confirm:$false
get-service "spooler" | Stop-Service
get-service "spooler" | Set-Service -StartupType  Disabled -Confirm:$false

Get-Item -Path Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\OneSyncSvc_* | New-ItemProperty -Name 'Start' -Value 4 -PropertyType DWord -Force -ea SilentlyContinue

# End

Write-host "End of MISC Config"
