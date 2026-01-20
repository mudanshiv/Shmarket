
# ===================== CONFIG ======================
$org = "orgname"         # Example: myorg
$project = "projectname" # Example: SampleProject
$pat = "test"              # Azure DevOps PAT Token
# ====================================================
$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
$headers = @{ Authorization = "Basic $base64AuthInfo" }

$now = Get-Date
$last24 = $now.AddHours(-240)

Write-Host "Fetching latest releases executed in last 24 hours..." -ForegroundColor Yellow

# Fetch releases with environments
$releaseUrl = "https://vsrm.dev.azure.com/$org/$project/_apis/release/releases?`$expand=environments&queryOrder=descending&api-version=7.1-preview.8"
$allReleases = (Invoke-RestMethod -Uri $releaseUrl -Headers $headers -Method Get).value

# Pick only latest per definition + last 24 hours
$latestReleases = $allReleases |
    Where-Object { ([datetime]$_.createdOn) -ge $last24 } |
    Group-Object -Property { $_.releaseDefinition.id } |
    ForEach-Object { $_.Group | Sort-Object createdOn -Descending | Select-Object -First 1 }

$results = @()
$testDetails = @()

foreach ($release in $latestReleases) {

    $releaseId = $release.id
    $releaseName = $release.name
    Write-Host "`nProcessing Release: $releaseName ($releaseId)" -ForegroundColor Cyan

    foreach ($env in $release.environments) {

        $stageName = $env.name
        $envId = $env.id
        $StageReleaseStatus = $env.status

        Write-Host " ➜ Stage: $stageName" -ForegroundColor Blue

        $top = 50
        $url = "https://dev.azure.com/$org/$project/_apis/test/runs?releaseEnvIds=$envId&`$top=$top&api-version=7.1"

        $runsResponse = Invoke-RestMethod -Uri $url -Headers $headers -Method Get

        $latest = $runsResponse.value | Sort-Object lastUpdatedDate -Descending | Select-Object -Last 1

        $latestRunId  = $latest.id
        $latestRelId  = $latest.release.id
        $latestEnvId  = $latest.releaseEnvironment.id

        Write-Host "Latest RunId     : $latestRunId"




        # ----------------------------
        # 1) Get aggregated summary
        # ----------------------------
        $summaryUrl = "https://vstmr.dev.azure.com/$org/$project/_apis/testresults/resultsummarybyrelease?releaseId=$releaseId&releaseEnvId=$envId&api-version=7.1-preview.1"
        $runData = Invoke-RestMethod -Uri $summaryUrl -Headers $headers -Method Get


        if ($runData.aggregatedResultsAnalysis.totalTests -eq 0) {
            Write-Host "    No tests executed for stage" -ForegroundColor DarkGray

            $results += [PSCustomObject]@{
                PipelineName           = $release.releaseDefinition.name
                ReleaseName            = $releaseName
                StageName              = $stageName
                StageReleaseStatus     = $StageReleaseStatus
                TotalTests             = 0
                Passed                 = 0
                Failed                 = 0
                Other                  = 0
                TestrunSummaryByOutcome= "NA"
                ReleaseDate            = $release.createdOn
            }

            continue
        }

        $testResults = $runData.aggregatedResultsAnalysis.resultsByOutcome

        $passed = $testResults.Passed.count
        $failed = $testResults.Failed.count
        $total  = $runData.aggregatedResultsAnalysis.totalTests
        $other  = $total - ($passed + $failed)

        $runSummaryByOutcome = $runData.aggregatedResultsAnalysis.runSummaryByOutcome.psobject.Properties.Name

        $results += [PSCustomObject]@{
            PipelineName           = $release.releaseDefinition.name
            ReleaseName            = $releaseName
            StageName              = $stageName
            StageReleaseStatus     = $StageReleaseStatus
            TotalTests             = $total
            Passed                 = $passed
            Failed                 = $failed
            Other                  = $other
            TestrunSummaryByOutcome= ($runSummaryByOutcome -join ",")
            ReleaseDate            = $release.createdOn
        }



        # ----------------------------
        # 2) Get Test Runs for release+stage
        # ----------------------------

        $resultsUrl = "https://dev.azure.com/$org/$project/_apis/test/Runs/$runID/results?`$top=5000&api-version=7.1-preview.6"
        $resultsResponse = Invoke-RestMethod -Uri $resultsUrl -Headers $headers -Method Get



                # API URL to fetch results
       # $resultsUrl = "$orgUrl/$project/_apis/test/Runs/$runId/results?`$top=5000&api-version=7.1-preview.6"
       # $resultsResponse = Invoke-RestMethod -Uri $resultsUrl -Headers $headers -Method Get

        # Convert results into Excel-friendly objects
        $excelRows = $resultsResponse.value | ForEach-Object {
            [PSCustomObject]@{
                TestRunId      = $_.testRun.id
                TestRunName    = $_.testRun.name
                TestCaseTitle  = $_.testCaseTitle
                Outcome        = $_.outcome
                StartedDate    = $_.startedDate
                CompletedDate  = $_.completedDate
                ErrorMessage   = $_.errorMessage
                StackTrace     = $_.stackTrace
                ReleaseId      = $_.releaseReference.id
                ReleaseName    = $_.releaseReference.name
                EnvironmentId  = $_.releaseReference.environmentId
                DefinitionId   = $_.releaseReference.definitionId
                BuildId        = $_.build.id
                BuildName      = $_.build.name
            }
        }

        # Export CSV (Excel-readable)
        $excelRows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

        Write-Host "✅ Test results exported to: $csvPath" -ForegroundColor Green

        foreach ($r in $resultsResponse.value) {
            Write-Host ("TestCase: {0} | Outcome: {1}" -f $r.testCaseTitle, $r.outcome)
        }

        #$runsUrl = "https://dev.azure.com/$org/$project/_apis/test/runs?releaseId=$releaseId&releaseEnvId=$envId&api-version=7.1-preview.5"
        #$runsResponse = Invoke-RestMethod -Uri $runsUrl -Headers $headers -Method Get

        if ($runsResponse.count -eq 0) {
            Write-Host "    No Test Runs found for this stage." -ForegroundColor DarkGray
            continue
        }

        #foreach ($run in $runsResponse.value) {

            $runId = $latestRunId
            #$runName = $run.name

            Write-Host "    ➜ Test Run Found: $runName (RunId=$runId)" -ForegroundColor Magenta

            # ----------------------------
            # 3) Get Test Results for each Run
            # ----------------------------
            $runsUrl = "https://dev.azure.com/$org/$project/_apis/test/runs?`$top=100&api-version=7.1-preview.3"
            $runsResponse = Invoke-RestMethod -Uri $runsUrl -Headers $headers -Method Get


            $resultsUrl = "https://dev.azure.com/$org/$project/_apis/test/Runs/$runId/results?`$top=5000&api-version=7.1-preview.6"
            $resultsResponse = Invoke-RestMethod -Uri $resultsUrl -Headers $headers -Method Get

            if ($resultsResponse.count -eq 0) {
                Write-Host "       No test results inside run." -ForegroundColor DarkGray
                continue
            }

            foreach ($r in $resultsResponse.value) {

                $testDetails += [PSCustomObject]@{
                    PipelineName        = $release.releaseDefinition.name
                    ReleaseName         = $releaseName
                    ReleaseId           = $releaseId
                    StageName           = $stageName
                    StageReleaseStatus  = $StageReleaseStatus
                    TestRunId           = $runId
                    TestRunName         = $runName
                    TestCaseTitle       = $r.testCaseTitle
                    Outcome             = $r.outcome
                    DurationMs          = $r.durationInMs
                    ErrorMessage        = $r.errorMessage
                    CompletedDate       = $r.completedDate
                }
            #}
        }
    }
}

# Export CSV Reports
$timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")

$summaryCsvPath = "Release_Stage_Test_Summary_$timestamp.csv"
$detailsCsvPath = "Release_Stage_Test_Details_$timestamp.csv"

$results | Export-Csv -Path $summaryCsvPath -NoTypeInformation
$testDetails | Export-Csv -Path $detailsCsvPath -NoTypeInformation

Write-Host "`n======== Report Generated Successfully! ========" -ForegroundColor Green
Write-Host "Summary CSV : $summaryCsvPath" -ForegroundColor Green
Write-Host "Details CSV : $detailsCsvPath" -ForegroundColor Green
