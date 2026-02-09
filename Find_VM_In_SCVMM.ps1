# Check the PowerShell version
if ($PSVersionTable.PSVersion.Major -lt 5 -or ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -lt 1)) {
    Write-Host "This script must be run under PowerShell 5.1 or later." -ForegroundColor Red
    Exit
}

# Load the required modules
try {
    Import-Module -Name "VirtualMachineManager" -ErrorAction Stop
}
catch {
    Write-Host "Failed to load the VirtualMachineManager module: $_" -ForegroundColor Red
    Exit
}

# Function to log messages
function LogMessage {
    param (
        [string]$Message,
        [string]$Level = "INFO",
        [string]$LogFilePath = "$PSScriptRoot\logfile.log"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Write-Host $logEntry
    $logEntry | Out-File -FilePath $LogFilePath -Append
}

# Function to get virtual machine information and check VM Additions / Integration Services version
function Get-VirtualMachineInfo {
    param (
        [string]$VMName,
        [string]$ServerName
    )

    try {
        # Check if a connection to the SCVMM server already exists
        if (-not (Get-SCVMMServer -ComputerName $ServerName -ErrorAction SilentlyContinue)) {
            LogMessage "Connecting to SCVMM server: $ServerName"
            Get-SCVMMServer -ComputerName $ServerName | Out-Null
            LogMessage "Successfully connected to SCVMM server: $ServerName" "SUCCESS"
        }

        $VirtualMachine = Get-SCVirtualMachine -Name $VMName -ErrorAction SilentlyContinue

        if ($VirtualMachine) {
            Write-Host "SCVMM : $ServerName" -ForegroundColor Cyan
            Write-Host "*************************" -ForegroundColor Cyan
            Write-Host "VM Name: $($VirtualMachine.Name)"
            Write-Host "VM Host: $($VirtualMachine.VMHost)"
            Write-Host "Computer Name: $($VirtualMachine.ComputerName)"
            Write-Host "Status: $($VirtualMachine.Status)"
            Write-Host "Operating System: $($VirtualMachine.OperatingSystem)"
            Write-Host "CPU Count: $($VirtualMachine.CPUCount)"
            Write-Host "Memory (MB): $($VirtualMachine.Memory)"
            Write-Host "Creation Time: $($VirtualMachine.CreationTime)"
            Write-Host "VM Additions: $($VirtualMachine.VMAddition)"
            Write-Host "Configuration Version: $($VirtualMachine.Version)"
            Write-Host "Generation: $($VirtualMachine.Generation)"
            Write-Host "User Role: $($VirtualMachine.UserRole.Name)"
            Write-Host "Owner: $($VirtualMachine.Owner)"

            # Check if OS is Windows or Linux
            if ($VirtualMachine.OperatingSystem -like "*Windows*") {
                # For Windows VMs, check for VM Additions
                if (-not $VirtualMachine.VMAddition) {
                    Write-Host "Warning: VM Additions are not installed on this Windows VM." -ForegroundColor Yellow
                }
                else {
                    # Check the version of VM Additions (for Windows)
                    if ($VirtualMachine.Version -lt "6.3") {
                        Write-Host "Warning: VM Additions version is outdated for this Windows VM. Please update to a newer version." -ForegroundColor Yellow
                    }
                    else {
                        Write-Host "VM Additions are up to date on this Windows VM." -ForegroundColor Green
                    }
                }
            }
            elseif ($VirtualMachine.OperatingSystem -like "*Linux*") {
                # For Linux VMs, check for Linux Integration Services (LIS)
                # You may need additional logic to verify LIS versions depending on the distribution

                Write-Host "Linux VM detected. Checking for Linux Integration Services..." -ForegroundColor Cyan

                # Assuming a Linux VM, we don't get direct version information here. Check status (hypothetical scenario)
                if (-not $VirtualMachine.VMAddition) {
                    Write-Host "Warning: Linux Integration Services (LIS) are not installed on this Linux VM." -ForegroundColor Yellow
                }
                else {
                    # Assume Linux integration services are installed but might need an update
                    Write-Host "Linux Integration Services are installed. Ensure they are up to date according to the distribution." -ForegroundColor Green
                }
            }
            else {
                Write-Host "Operating System not recognized. Ensure VM Additions or Integration Services are installed." -ForegroundColor Red
            }

            return $true
        }
        else {
            LogMessage "Virtual machine '$VMName' not found on SCVMM server '$ServerName'." "WARNING"
        }
    }
    catch {
        LogMessage "Error connecting to ${ServerName}: $_" "ERROR"
    }

    return $false
}

# Validate user input
$VMName = Read-Host -Prompt 'Enter the VM name (without FQDN):'
if ([string]::IsNullOrWhiteSpace($VMName)) {
    Write-Host "Invalid VM name. Please enter a valid VM name." -ForegroundColor Red
    Exit
}

Write-Host ""
Write-Host "Searching for VM '$VMName' in SCVMM servers..." -ForegroundColor Yellow
Write-Host ""

# Use a relative path to read the list of servers
$scriptPath = $PSScriptRoot
$serversFilePath = Join-Path -Path $scriptPath -ChildPath "SCVMMServers.txt"

if (-not (Test-Path $serversFilePath)) {
    Write-Host "Server list file not found at '$serversFilePath'. Please ensure it exists." -ForegroundColor Red
    Exit
}

$servers = Get-Content -Path $serversFilePath

$connectedToSCVMM = $false

foreach ($server in $servers) {
    if (Get-VirtualMachineInfo -VMName $VMName -ServerName $server) {
        $connectedToSCVMM = $true
        break  # Exit the loop once the VM is found
    }
}

if (-not $connectedToSCVMM) {
    Write-Host "Sorry, VM '$VMName' was not found on any SCVMM server." -ForegroundColor Cyan
}