# Function to check if PowerShell is running as Administrator
function Test-Admin {
    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
        Write-Host "Please run PowerShell as Administrator." -ForegroundColor Red
        exit
    }
}

# Function to check if the SCVMM module is installed
function Test-SCVMMModule {
    if (-not (Get-Module -ListAvailable -Name VirtualMachineManager)) {
        Write-Host "The SCVMM module is not installed. Please install it before continuing." -ForegroundColor Red
        exit
    }
}

# Function to check if the Hyper-V module is installed (optional, for managing Hyper-V VMs directly)
function Test-HyperVModule {
    if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
        Import-Module -Name Hyper-V -ErrorAction SilentlyContinue
    }
}
# Function to check if the Hyper-V role is installed (optional, if managing local Hyper-V VMs)
function Test-HyperVRole {
    $hyperVRole = Get-WindowsFeature -Name "Hyper-V" -ErrorAction SilentlyContinue
    if ($null -eq $hyperVRole) {
        Write-Host "The Hyper-V role is not available on this machine. This machine may not support Hyper-V." -ForegroundColor Yellow
    }
    elseif ($hyperVRole.InstallState -ne "Installed") {
        Write-Host "The Hyper-V role is not installed on this machine. If you're not managing local Hyper-V VMs, you can ignore this." -ForegroundColor Yellow
    }
}

# Function to check if the Hyper-V Virtual Machine Management service is running (optional)
function Test-HyperVService {
    $vmmsService = Get-Service -Name vmms -ErrorAction SilentlyContinue
    if ($null -eq $vmmsService) {
        Write-Host "The Hyper-V Virtual Machine Management service (vmms) is not installed on this machine." -ForegroundColor Yellow
    }
    elseif ($vmmsService.Status -ne 'Running') {
        Write-Host "The Hyper-V Virtual Machine Management service (vmms) is not running. Starting the service..." -ForegroundColor Yellow
        Start-Service -Name vmms
        Write-Host "The vmms service has been started." -ForegroundColor Green
    }
}

# Function to check if all prerequisites are met (Hyper-V checks are optional)
function Test-Prerequisites {
    Test-Admin
    Test-SCVMMModule
    Test-HyperVModule
}

# Function to get Integration Services for a Hyper-V VM
function Get-IntegrationServices {
    param (
        [string]$VMName,
        [string]$HyperVHost
    )
    $session = New-PSSession -ComputerName $HyperVHost
    $integrationServices = Invoke-Command -Session $session -ScriptBlock {
        param ($VMName)
        Get-VMIntegrationService -VMName $VMName | Select-Object Name, Enabled
    } -ArgumentList $VMName
    Remove-PSSession -Session $session

    $servicesInfo = @{}
    foreach ($service in $integrationServices) {
        $serviceName = $service.Name -replace ' ', ''
        $servicesInfo["$($serviceName)Enabled"] = $service.Enabled
    }
    return $servicesInfo
}

# Function to get IPv4 address for a VM
function Get-IPv4 {
    param (
        [string]$VMID
    )
    $vmNetwork = Get-SCVirtualNetworkAdapter -VM (Get-SCVirtualMachine -ID $VMID)
    $ipv4 = $vmNetwork | Where-Object { $null -ne $_.IPv4Addresses } | Select-Object -ExpandProperty IPv4Addresses
    return $ipv4
}

# Function to identify if the VM is managed by Hyper-V, SCVMM, or both
function Get-VMManager {
    param (
        [string]$VMName
    )
    $managerType = @()

    # Check if the VM is managed by SCVMM
    try {
        $scvmmVM = Get-SCVirtualMachine -Name $VMName -ErrorAction SilentlyContinue
        if ($scvmmVM) {
            $managerType += "SCVMM"
        }
    }
    catch {
        Write-Host "Error while checking SCVMM for VM: $VMName" -ForegroundColor Yellow
    }

    # Check if the VM is managed by Hyper-V
    try {
        $hypervVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
        if ($hypervVM) {
            $managerType += "Hyper-V"
        }
    }
    catch {
        Write-Host "Error while checking Hyper-V for VM: $VMName" -ForegroundColor Yellow
    }

    if ($managerType.Count -eq 0) {
        return "Unknown"
    }

    return $managerType -join ", "
}

# Function to export VM information to CSV
function Export-VMInventory {
    param (
        [string]$outputFile,
        [array]$inventory
    )

    if ($inventory.Count -gt 0) {
        Write-Host "Exporting inventory to: $outputFile" -ForegroundColor Green
        $inventory | Export-Csv -Path $outputFile -NoTypeInformation -Force
        Write-Host "Inventory completed. Report saved to: $outputFile" -ForegroundColor Green
    }
    else {
        Write-Host "No data to export. The inventory is empty." -ForegroundColor Red
    }
}

# Function to collect SCVMM information (ProductVersion, DatabaseServer, DatabaseName, DatabaseVersion, DatabaseInstanceName)
function Get-SCVMMInfo {
    param (
        $scvmmServer
    )

    # Retrieve SCVMM product version and database info
    $scvmmInfo = $scvmmServer
    $productVersion = $scvmmInfo.ProductVersion
    $databaseServer = $scvmmInfo.DatabaseServerName
    $databaseName = $scvmmInfo.DatabaseName
    $databaseVersion = $scvmmInfo.DatabaseVersion
    $databaseInstanceName = $scvmmInfo.DatabaseInstanceName

    # Compare the product version to known SCVMM versions
    $scvmmEdition = "Unknown"
    switch ($productVersion) {
        {$_ -like "4.0.*"} { $scvmmEdition = "SCVMM 2016"; break }
        {$_ -like "10.19.*"} { $scvmmEdition = "SCVMM 2019"; break }
        {$_ -like "10.22.*"} { $scvmmEdition = "SCVMM 2022"; break }
        default { $scvmmEdition = "Unknown SCVMM Version"; break }
    }

    # Return SCVMM details including edition
    return [ordered]@{
        SCVMMServer        = $scvmmInfo.Name
        SCVMMEdition       = $scvmmEdition
        ProductVersion     = $productVersion
        DatabaseServer     = $databaseServer
        DatabaseName       = $databaseName
        DatabaseVersion    = $databaseVersion
        DatabaseInstanceName = $databaseInstanceName
    }
}

# Main processing loop to collect VM information
function Get-VMInventory {
    param (
        [string]$serversFilePath
    )
    $inventory = @()
    $servers = Get-Content -Path $serversFilePath
    foreach ($server in $servers) {
        try {
            Write-Host "Connecting to SCVMM server: $server" -ForegroundColor Cyan
            $scvmmServer = Get-SCVMMServer -ComputerName $server
            if (-not $scvmmServer) {
                Write-Host "Failed to connect to SCVMM server: $server" -ForegroundColor Red
                continue
            }
            Write-Host "Connected to SCVMM server: $server" -ForegroundColor Green

            # Retrieve SCVMM information
            $scvmmInfo = Get-SCVMMInfo -scvmmServer $scvmmServer

            # Ensure connection to SCVMM is valid
            if ($null -eq $scvmmServer) {
                Write-Host "Failed to retrieve SCVMM details for server: $server" -ForegroundColor Red
                continue
            }

            # Retrieve VM information
            $vms = Get-SCVirtualMachine -VMMServer $scvmmServer
            if ($vms.Count -eq 0) {
                Write-Host "No VMs found on SCVMM server: $server" -ForegroundColor Yellow
                continue
            }

            foreach ($vm in $vms) {
                try {
                    # Collecting VM information
                    $managerType = Get-VMManager -VMName $vm.Name
                    $ipv4 = Get-IPv4 -VMID $vm.ID
                    $hostName = if ($vm.VMHost) { $vm.VMHost.ComputerName -replace "\..*" } else { "N/A" }
                    $serverName = $server -replace "\..*"

                    # Retrieve integration services information
                    $integrationServices = @{}
                    if ($managerType -like "*SCVMM*" -or $managerType -like "*Hyper-V*") {
                        $integrationServices = Get-IntegrationServices -VMName $vm.Name -HyperVHost $hostName
                    }

                    # Prepare basic VM info
                    $vmInfo = [ordered]@{
                        ServerName           = $serverName.ToUpper()
                        SCVMMEdition         = $scvmmInfo.SCVMMEdition
                        ProductVersion       = $scvmmInfo.ProductVersion
                        DatabaseServer       = $scvmmInfo.DatabaseServer
                        DatabaseName         = $scvmmInfo.DatabaseName
                        DatabaseVersion      = $scvmmInfo.DatabaseVersion
                        DatabaseInstanceName = $scvmmInfo.DatabaseInstanceName
                        VMName               = $vm.Name
                        VMAddition           = $vm.VMAddition
                        ManagerType          = $managerType
                        VirtualMachineState  = $vm.VirtualMachineState
                        ComputerName         = $vm.ComputerName
                        Owner                = $vm.Owner
                        UserRole             = $vm.UserRole.Name
                        IPv4Address          = $ipv4 -join ", "
                        Host                 = $hostName.ToUpper()
                        ConfigurationVersion = $vm.Version
                        Generation           = $vm.Generation
                        IsHighlyAvailable    = if ($vm.IsHighlyAvailable) { $vm.IsHighlyAvailable } else { "N/A" }
                        Cloud                = if ($vm.Cloud.Name) { $vm.Cloud.Name } else { "[None - not associated to a cloud]" }
                        CreationTime         = $vm.CreationTime
                    }

                    # Add integration services info to VM info
                    foreach ($key in $integrationServices.Keys) {
                        $vmInfo[$key] = $integrationServices[$key]
                    }

                    # Display the VM info for debugging
                    Write-Host "VM Info for $($vm.Name):" -ForegroundColor Cyan
                    $vmInfo | Format-Table -AutoSize | Out-String | Write-Host

                    # Add the VM info to the inventory
                    $inventory += [PSCustomObject]$vmInfo
                }
                catch {
                    Write-Host "Error while processing VM: $($vm.Name) on SCVMM server $server" -ForegroundColor Red
                    Write-Host "Error details: $_" -ForegroundColor Yellow
                }
            }
        }
        catch {
            Write-Host "Error while connecting to or querying SCVMM server: $server" -ForegroundColor Red
            Write-Host "Error details: $_" -ForegroundColor Yellow
            continue
        }
    }
    return $inventory
}

# Check prerequisites (only SCVMM-related checks are critical here)
Test-Prerequisites

# Define paths
$serversFilePath = "$PSScriptRoot\SCVMMServers.txt"
$outputFile = "$PSScriptRoot\VM_Inventory_Report.csv"

# Collect VM information
$vmInventory = Get-VMInventory -serversFilePath $serversFilePath

# Export VM inventory to CSV
Export-VMInventory -outputFile $outputFile -inventory $vmInventory