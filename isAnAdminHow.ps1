param(
    [string]$ComputerName,
    [string]$UserIdentity  # e.g. 'john.smith' or UPN 'John.smith@ABC.COM'
)

if (-not $ComputerName) {
    $ComputerName = Read-Host "Enter the computer name"
}
if (-not $UserIdentity) {
    $UserIdentity = Read-Host "Enter the user (samAccountName or UPN, e.g. john.smith)"
}

$ComputerName = $ComputerName.Trim()
$UserIdentity = $UserIdentity.Trim()

function Get-UserLocalAdminSource {
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [string]$UserIdentity
    )

    #
    # 1. Use AD cmdlets (Get-ADUser / Get-ADGroup) only
    #
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
    } catch {
        throw "ActiveDirectory module not available on this machine. Install RSAT / AD DS tools and try again."
    }

    # Resolve user exactly the way you do interactively
    try {
        $user = Get-ADUser $UserIdentity -Properties SID, MemberOf
    } catch {
        throw "Get-ADUser failed for '$UserIdentity'. Error: $($_.Exception.Message)"
    }

    if (-not $user) {
        throw "Could not find AD user '$UserIdentity'."
    }

    $userSidValue = $user.SID.Value

    #
    # 2. Recursively collect all AD groups the user is a member of (direct + nested)
    #
    $allGroups    = @()
    $visitedDNs   = [System.Collections.Generic.HashSet[string]]::new()
    $queue        = New-Object System.Collections.Queue

    # Seed with the user's direct MemberOf DNs
    if ($user.MemberOf) {
        foreach ($dn in $user.MemberOf) {
            $queue.Enqueue($dn)
        }
    }

    while ($queue.Count -gt 0) {
        $dn = $queue.Dequeue()
        if (-not $dn) { continue }

        if ($visitedDNs.Contains($dn)) { continue }
        [void]$visitedDNs.Add($dn)

        try {
            $g = Get-ADGroup -Identity $dn -Properties SID, MemberOf
        } catch {
            continue
        }

        if ($g) {
            $allGroups += $g

            # Enqueue this group's parent groups for further expansion
            if ($g.MemberOf) {
                foreach ($parentDn in $g.MemberOf) {
                    if (-not $visitedDNs.Contains($parentDn)) {
                        $queue.Enqueue($parentDn)
                    }
                }
            }
        }
    }

    # Build the list of SIDs for all groups the user is effectively in
    $groupSidValues = $allGroups |
        Where-Object { $_.SID -ne $null } |
        ForEach-Object { $_.SID.Value } |
        Sort-Object -Unique

    #
    # 2a. PRINT the list of groups being checked (for visibility)
    #
    Write-Host ""
    Write-Host "User: $UserIdentity" -ForegroundColor Cyan
    Write-Host "User SID: $userSidValue" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "AD groups being checked for local admin via group membership:" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------"

    if ($allGroups.Count -eq 0) {
        Write-Host "(No groups found via MemberOf recursion – user appears to have no AD groups or AD visibility is restricted.)"
    } else {
        foreach ($g in $allGroups | Sort-Object Name) {
            $name = if ($g.SamAccountName) { $g.SamAccountName } else { $g.Name }
            "{0,-40} {1}" -f $name, $g.SID.Value
        }
    }

    Write-Host ""

    #
    # 3. On the remote machine: recursively walk nested local groups from Administrators
    #
    $results = Invoke-Command -ComputerName $ComputerName -ScriptBlock {
        param(
            [string]   $UserIdentityFromCaller,
            [string]   $UserSidValue,
            [string[]] $GroupSidValues
        )

        $out           = @()
        $visitedGroups = [System.Collections.Generic.HashSet[string]]::new()

        function Process-LocalGroup {
            param(
                [string]$GroupName,
                [string]$PathPrefix
            )

            if ($visitedGroups.Contains($GroupName)) { return }
            [void]$visitedGroups.Add($GroupName)

            try {
                $members = Get-LocalGroupMember -Group $GroupName -ErrorAction Stop
            } catch {
                return
            }

            foreach ($m in $members) {
                $memberPath = "$PathPrefix -> $($m.Name)"

                if ($m.ObjectClass -eq 'User') {
                    if ($m.SID.Value -eq $UserSidValue) {
                        $out += [pscustomobject]@{
                            Computer    = $env:COMPUTERNAME
                            User        = $UserIdentityFromCaller
                            SourceType  = 'Direct membership'
                            SourceName  = $m.Name
                            SourceSID   = $m.SID.Value
                            Path        = $memberPath
                            Explanation = "User is directly in local Administrators via path: $memberPath"
                        }
                    }
                }
                elseif ($m.ObjectClass -eq 'Group') {
                    $groupSidValue = $m.SID.Value

                    # If this group's SID is in the user's AD group SID list, they get admin via this group
                    if ($GroupSidValues -contains $groupSidValue) {
                        $out += [pscustomobject]@{
                            Computer    = $env:COMPUTERNAME
                            User        = $UserIdentityFromCaller
                            SourceType  = 'Group membership'
                            SourceName  = $m.Name
                            SourceSID   = $groupSidValue
                            Path        = $memberPath
                            Explanation = "User is member of '$($m.Name)', which leads to Administrators via path: $memberPath"
                        }
                    }

                    # If this is also a *local* group, recurse into it to handle Russian-doll nesting
                    $canExpand = $false
                    try {
                        Get-LocalGroupMember -Group $m.Name -ErrorAction Stop | Out-Null
                        $canExpand = $true
                    } catch {
                        $canExpand = $false
                    }

                    if ($canExpand) {
                        Process-LocalGroup -GroupName $m.Name -PathPrefix $memberPath
                    }
                }
            }
        }

        # Start from local Administrators
        Process-LocalGroup -GroupName 'Administrators' -PathPrefix 'Administrators'

        if (-not $out) {
            $out += [pscustomobject]@{
                Computer    = $env:COMPUTERNAME
                User        = $UserIdentityFromCaller
                SourceType  = 'None'
                SourceName  = $null
                SourceSID   = $null
                Path        = 'Administrators'
                Explanation = 'No local admin via local Administrators group (including nested local groups) detected'
            }
        }

        $out
    } -ArgumentList $UserIdentity, $userSidValue, $groupSidValues

    $results
}

Get-UserLocalAdminSource -ComputerName $ComputerName -UserIdentity $UserIdentity

