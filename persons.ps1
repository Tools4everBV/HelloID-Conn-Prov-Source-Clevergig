##################################################
# HelloID-Conn-Prov-Source-Clevergig-Persons
#
# Version: 1.0.0
##################################################
# Initialize default value's
$config = $configuration | ConvertFrom-Json
$allGigs = [System.Collections.Generic.List[object]]::new()
$allIncluded = [System.Collections.Generic.List[object]]::new()
$allRoles = [System.Collections.Generic.List[object]]::new()
$allOrganizations = [System.Collections.Generic.List[object]]::new()
$allWorklogsDTO = [System.Collections.Generic.List[object]]::new()
$allWorkers = [System.Collections.Generic.List[object]]::new()

# Set debug logging
switch ($($config.IsDebug)) {
    $true { $VerbosePreference = 'Continue' }
    $false { $VerbosePreference = 'SilentlyContinue' }
}

#region functions
function Invoke-CleverGigRestMethod {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Uri,

        [Parameter()]
        [switch]
        $UsePaging,

        [Parameter()]
        [int]
        $Page = 1,

        [Parameter()]
        [int]
        $PerPage = 1000,

        [Parameter()]
        [int]
        $MaxPages
    )

    process {
        try {
            $headers = [System.Collections.Generic.Dictionary[[String], [String]]]::new()
            $headers.Add("Authorization", "Bearer $($config.APIKey)")
            $apiUrl = "$($config.BaseUrl)/api/external/$Uri"

            $splatParams = @{
                Uri         = $apiUrl
                Method      = 'GET'
                ContentType = 'application/json'
                Headers     = $headers
            }

            if ($UsePaging) {
                $allData = [System.Collections.Generic.List[object]]::new()

                $pagedUrl = "$apiUrl&page=$Page&per_page=$PerPage"
                $splatParams.Uri = $pagedUrl
                $firstResponse = Invoke-RestMethod @splatParams -Verbose:$false
                $allData.Add($firstResponse)

                if ($MaxPages) {
                    $totalPages = $MaxPages
                } else {
                    $totalPages = $firstResponse.Meta.pagination.total_pages
                }

                for ($Page = 2; $Page -le $totalPages; $Page++) {
                    $pagedUrl = "$apiUrl&page=$Page&per_page=$PerPage"
                    $splatParams.Uri = $pagedUrl
                    $response = Invoke-RestMethod @splatParams -Verbose:$false
                    $allData.Add($response)
                }
                Write-Output $allData
            } else {
                Invoke-RestMethod @splatParams -Verbose:$false
            }
        } catch {
            $PSCmdlet.ThrowTerminatingError($_)
        }
    }
}


#endregion

try {
    $historicalDays = (Get-Date).ToUniversalTime().AddDays(-$($config.HistoricalDays))
    $futureDays = (Get-Date).ToUniversalTime().AddDays($($config.FutureDays))
    $importStartDate =$($historicalDays.ToString('dd-MM-yyyy'))
    $importFinishDate = $($futureDays.ToString('dd-MM-yyyy'))

    # Import CSV mapping
    $costCenterCodes = Import-Csv -Path $config.CSVMappingFile -Delimiter $config.CSVMappingDelimiter

    # Retrieve all roles
    $allRoles =  Invoke-ClevergigRestMethod -Uri 'roles'

    # Retrieve all organizations
    $allOrganizations = Invoke-ClevergigRestMethod -Uri 'organizations?' -UsePaging

    # Retrieve worklogs per organization and filter on date range
    foreach ($organization in $allOrganizations.data) {
        $organizationWorklogs = Invoke-CleverGigRestMethod -Uri "worklogs?by_organizations=$($organization.id)&by_daterange[start_date]=$importStartDate&by_daterange[finish_date]=$importFinishDate" -UsePaging
        foreach ($organizationWorklog in $organizationWorklogs.data){
            $organizationWorklogDTO = @{
                OrganizationId = $organization.id
                logId = $organizationWorklog.id
                WorkerId = $organizationWorklog.attributes.worker_id
            }
            $allWorklogsDTO.Add($organizationWorklogDTO)
        }
    }

    # Retrieve gigs, associated data and filter on date range
    $allGigsResponse = Invoke-ClevergigRestMethod -Uri "gigs?include=roles%2Cworkers&start_date=$importStartDate&finish_date=$importFinishDate" -UsePaging

    # Separate the gigs and associated data into lists
    foreach ($gigObject in $allGigsResponse){
        $allGigs.AddRange($gigObject.data)
        $allIncluded.AddRange($gigObject.included)
    }

    # Gather all workers
    foreach ($gig in $allGigs) {
        if ($null -ne $gig.relationships.workers.data) {
            # Process each worker in the gig
            foreach ($workerRelation in $gig.relationships.workers.data) {
                $workerId = $workerRelation.id

                # Search for worker details in the allGigsIncluded list
                $workerDetails = $allIncluded | Where-Object { $_.id -eq $workerId -and $_.type -eq 'worker' } | Select-Object -First 1

                # Construct the basic raw worker object
                $rawWorkerObject = @{
                    ExternalId = $workerDetails.attributes.external_id
                    DisplayName = ($workerDetails.attributes.first_name + ' ' + $workerDetails.attributes.last_name)
                    WorkerId = $workerId
                    Details = $workerDetails
                }
            }

            # Make sure to only add the worker to the 'allWorkers' list 1 time
            if (-not ($allWorkers | Where-Object { $_.WorkerId -eq $workerId })){
                $allWorkers.Add($rawWorkerObject)
            }

        }
    }

    # Process all workers
    $processedWorkers = [System.Collections.Generic.List[object]]::new()
    foreach ($worker in $allWorkers) {
        $workerObject = [PSCustomObject]@{
            ExternalId = $worker.ExternalId
            DisplayName = $worker.DisplayName
            WorkerDetails = $worker.Details
            Contracts = [System.Collections.Generic.List[object]]::new()
        }

        # Get all workerGigs. (Each gig will result in a separate contract)
        $workerGigs = $allGigs | Where-Object { $_.relationships.workers.data.id -contains $worker.WorkerId }
        foreach ($workerGig in $workerGigs){

            # Create the gig contract
            $gigContract = @{
                ExternalId = "$($worker.details.attributes.external_id)$($workerGig.id)"
                ContractType = $workerGig.type
                Attributes = $workerGig.attributes
                StartDate = $null
                EndDate = $null
                Title = $null
                CostCenterDetails = $null
            }

            # Retrieve worklogs and associate CostCenter details
            $gigDTOWorklogs = [System.Collections.Generic.List[object]]::new()
            foreach ($worklogDTO in $allWorklogsDTO) {
                if ($worklogDTO.logId -eq $workerGig.relationships.worklogs.data[0].id -and $worklogDTO.WorkerId -eq $worker.WorkerId) {
                    $gigDTOWorklogs.add($worklogDTO)
                }
            }

            # Get the organizationId
            if ($gigDTOWorklogs.count -gt 0) {
                $organizationId = ($gigDTOWorklogs | Select-Object -First 1).OrganizationId

                # Look for the CostCenterDetails within the CSV mapping
                if ($null -ne $organizationId){
                    $costCenter = $costCenterCodes | Where-Object { $_.Id -eq $organizationId }
                    $costCenterDetails = @{
                        Id = $costCenter.Id
                        Title = $costCenter.Titel
                        LocatiesAdressen = $costCenter.'Locaties adressen'
                        IntusResourceGroupId = $costCenter.'Intus-resourceGroupId'
                        FactureringKostenplaats = $costCenter.'Facturering Kostenplaats'
                    }
                    $gigContract.CostCenterDetails = $costCenterDetails
                }
            }

            # Get title information by looking up the roleId within the allRoles list
            if ($null -ne $gig.relationships.roles.data) {
                $gigContract.Title = ($allRoles.data | Where-Object { $_.id -eq $gig.relationships.roles.data[0].id }).attributes.title
            }

            # Construct the startDate and endDate
            $gigContract.StartDate = [datetime]::ParseExact($workerGig.attributes.date, "dd-MM-yyyy", $null).Date
            $gigContract.EndDate = $gigContract.StartDate.AddDays(1).AddSeconds(-1)

            $workerObject.Contracts.Add($gigContract)
        }

        # Create separate contracts for each role
        if ($null -ne $worker.Details.relationships){
            $workerRoles = $worker.Details.relationships.roles.data
            foreach ($workerRole in $workerRoles){
                $title = $allRoles.data | Where-Object { $_.id -eq $workerRole.id }
                $roleContract = @{
                    ExternalId = "$($worker.details.attributes.external_id)$($workerRole.id)"
                    ContractType = $workerRole.type
                    StartDate = $worker.Details.attributes.created_at
                    Title = $title.attributes.title
                }
                $workerObject.Contracts.Add($roleContract)
            }
        }

        $processedWorkers.Add($workerObject)
    }

    $processedWorkers | ConvertTo-Json -Depth 20
} catch {
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $streamReaderResponse = [System.IO.StreamReader]::new($ex.Exception.Response.GetResponseStream()).ReadToEnd()
        $errorDetails = $streamReaderResponse | ConvertFrom-Json
        Write-Verbose "Could not import Clevergig persons. Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($errorDetails.errors.message)"
        Write-Error "Could not import Clevergig persons. Error: $($errorObj.FriendlyMessage)"
    } else {
        Write-Verbose "Could not import Clevergig persons. Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
        Write-Error "Could not import Clevergig persons. Error: $($errorObj.FriendlyMessage)"
    }
}
