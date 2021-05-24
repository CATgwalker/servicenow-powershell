<#
.SYNOPSIS
    Retrieves records for the specified table
.DESCRIPTION
    The Get-ServiceNowTable function retrieves records for the specified table
.INPUTS
    None
.OUTPUTS
    System.Management.Automation.PSCustomObject
.LINK
    Service-Now Kingston REST Table API: https://docs.servicenow.com/bundle/kingston-application-development/page/integrate/inbound-rest/concept/c_TableAPI.html
    Service-Now Table API FAQ: https://hi.service-now.com/kb_view.do?sysparm_article=KB0534905
#>
function Invoke-ServiceNowRestMethod {

    [OutputType([System.Management.Automation.PSCustomObject])]
    [CmdletBinding(SupportsPaging)]
    Param (
        [parameter()]
        [ValidateSet('Get', 'Post', 'Patch', 'Delete')]
        [string] $Method = 'Get',

        # Name of the table we're querying (e.g. incidents)
        [parameter(Mandatory, ParameterSetName = 'Table')]
        [ValidateNotNullOrEmpty()]
        [Alias('sys_class_name')]
        [string] $Table,

        [parameter(ParameterSetName = 'Table')]
        [ValidateNotNullOrEmpty()]
        [string] $SysId,

        [parameter(ParameterSetName = 'Uri')]
        [ValidateNotNullOrEmpty()]
        [string] $UriLeaf,

        # [parameter()]
        # [hashtable] $Header,

        [parameter()]
        [hashtable] $Values,

        [parameter()]
        [System.Collections.ArrayList] $Filter,

        [parameter()]
        [ValidateNotNullOrEmpty()]
        [System.Collections.ArrayList] $Sort = @('opened_at', 'desc'),

        # sysparm_query param in the format of a ServiceNow encoded query string (see http://wiki.servicenow.com/index.php?title=Encoded_Query_Strings)
        [Parameter()]
        [string] $Query,

        # Fields to return
        [Parameter()]
        [Alias('Fields')]
        [string[]] $Properties,

        # Whether or not to show human readable display values instead of machine values
        [Parameter()]
        [ValidateSet('true', 'false', 'all')]
        [string] $DisplayValues = 'true',

        [Parameter()]
        [PSCredential] $Credential,

        [Parameter()]
        [string] $ServiceNowUrl,

        [Parameter()]
        [hashtable] $Connection,

        [Parameter()]
        [hashtable] $ServiceNowSession = $script:ServiceNowSession
    )

    $getAuth = @{
        Credential        = $Credential
        ServiceNowUrl     = $ServiceNowUrl
        Connection        = $Connection
        ServiceNowSession = $ServiceNowSession
    }
    $params = Get-ServiceNowAuth @getAuth

    $params.Method = $Method
    $params.ContentType = 'application/json'

    if ( $Table ) {
        # table can either be the actual table name or class name
        # look up the actual table name
        $tableName = $script:ServiceNowTable | Where-Object { $_.Name -eq $Table -or $_.ClassName -eq $Table } | Select-Object -ExpandProperty Name
        # if not in our lookup, just use the table name as provided
        if ( -not $tableName ) {
            $tableName = $Table
        }

        $params.Uri += "/table/$tableName"
        if ( $SysId ) {
            $params.Uri += "/$SysId"
        }
    }
    else {
        $params.Uri += $UriLeaf
    }

    if ( $Method -eq 'Get') {
        $Body = @{
            'sysparm_display_value' = $DisplayValues
            'sysparm_query'         = (New-ServiceNowQuery -Filter $Filter -Sort $Sort)
            'sysparm_limit'         = 10
        }

        # Handle paging parameters
        # The value of -First defaults to [uint64]::MaxValue if not specified.
        # If no paging information was provided, default to the legacy behavior, which was to return 10 records.

        if ($PSCmdlet.PagingParameters.First -ne [uint64]::MaxValue) {
            $Body['sysparm_limit'] = $PSCmdlet.PagingParameters.First
        }
        # else {
        #     $Body['sysparm_limit'] = 10
        # }

        if ($PSCmdlet.PagingParameters.Skip) {
            $Body['sysparm_offset'] = $PSCmdlet.PagingParameters.Skip
        }

        if ($Query) {
            $Body.sysparm_query = $Query
        }

        if ($Properties) {
            $Body.sysparm_fields = ($Properties -join ',').ToLower()
        }
    }

    # Populate the query
    # else {
    #     $body['sysparm_query'] = (New-ServiceNowQuery -Filter $Filter -Sort $Sort)
    # }


    if ( $Values ) {
        $Body = $Values | ConvertTo-Json

        #Convert to UTF8 array to support special chars such as the danish "ï¿½","ï¿½","ï¿½"
        $body = [System.Text.Encoding]::UTf8.GetBytes($Body)
    }

    if ( $Body ) {
        $params.Body = $Body
    }

    Write-Verbose ($params | ConvertTo-Json)

    # hide invoke-webrequest progress
    $oldProgressPreference = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'

    $response = Invoke-WebRequest @params

    $content = $response.content | ConvertFrom-Json
    if ( $content.PSobject.Properties.Name -contains "result" ) {
        $records = @($content | Select-Object -ExpandProperty result)
    }
    else {
        $records = @($content)
    }

    $totalRecordCount = [int]$response.Headers.'X-Total-Count'
    Write-Verbose "Total number of records for this query: $totalRecordCount"

    # if option to get all records was provided, loop and get them all
    if ( $PSCmdlet.PagingParameters.IncludeTotalCount.IsPresent ) {

        Write-Warning "Getting $($totalRecordCount - $PSCmdlet.PagingParameters.Skip) records, this could take a while..."

        $setPoint = $params.body.sysparm_offset + $params.body.sysparm_limit

        while ($totalRecordCount -gt $setPoint) {

            # up the offset so we get the next set of records
            $params.body.sysparm_offset += $params.body.sysparm_limit
            $setPoint = $params.body.sysparm_offset + $params.body.sysparm_limit

            $end = if ( $totalRecordCount -lt $setPoint ) {
                $totalRecordCount
            }
            else { 
                $setPoint
            }

            Write-Verbose ('getting {0}-{1} of {2}' -f ($params.body.sysparm_offset + 1), $end, $totalRecordCount)
            $response = Invoke-WebRequest @params -Verbose:$false

            $content = $response.content | ConvertFrom-Json
            if ( $content.PSobject.Properties.Name -contains "result" ) {
                $records += $content | Select-Object -ExpandProperty result
            }
            else {
                $records += $content
            }
        }

        if ( $totalRecordCount -ne ($records.count + $PSCmdlet.PagingParameters.Skip) ) {
            Write-Error ('The expected number of records was not received.  This can occur if your -First value, how many records retrieved at once, is too large.  Lower this value and try again.  Received: {0}, expected: {1}' -f $records.count, ($totalRecordCount - $PSCmdlet.PagingParameters.Skip))
        }
    }

    # set the progress pref back now that done with invoke-webrequest
    $ProgressPreference = $oldProgressPreference

    switch ($Method) {
        'Get' {
            $ConvertToDateField = @('closed_at', 'expected_start', 'follow_up', 'opened_at', 'sys_created_on', 'sys_updated_on', 'work_end', 'work_start')
            ForEach ($SNResult in $records) {
                ForEach ($Property in $ConvertToDateField) {
                    If (-not [string]::IsNullOrEmpty($SNResult.$Property)) {
                        Try {
                            # Extract the default Date/Time formatting from the local computer's "Culture" settings, and then create the format to use when parsing the date/time from Service-Now
                            $CultureDateTimeFormat = (Get-Culture).DateTimeFormat
                            $DateFormat = $CultureDateTimeFormat.ShortDatePattern
                            $TimeFormat = $CultureDateTimeFormat.LongTimePattern
                            $DateTimeFormat = "$DateFormat $TimeFormat"
                            $SNResult.$Property = [DateTime]::ParseExact($($SNResult.$Property), $DateTimeFormat, [System.Globalization.DateTimeFormatInfo]::InvariantInfo, [System.Globalization.DateTimeStyles]::None)
                        }
                        Catch {
                            Try {
                                # Universal Format
                                $DateTimeFormat = 'yyyy-MM-dd HH:mm:ss'
                                $SNResult.$Property = [DateTime]::ParseExact($($SNResult.$Property), $DateTimeFormat, [System.Globalization.DateTimeFormatInfo]::InvariantInfo, [System.Globalization.DateTimeStyles]::None)
                            }
                            Catch {
                                # If the local culture and universal formats both fail keep the property as a string (Do nothing)
                                $null = 'Silencing a PSSA alert with this line'
                            }
                        }
                    }
                }
            }
        }

        { $_ -in 'Post', 'Patch' } {
            $records = $content | Select-Object -ExpandProperty result
        }

        'Delete' {
            # nothing to do
        }

        Default {
            # we should never get here given the list of methods is set
        }
    }

    $records
}