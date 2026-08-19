<#
.SYNOPSIS
    Reports the latest GitHub Actions runs for Completion Navigator.

.DESCRIPTION
    No authentication and no GitHub CLI required -- the repository is public.

    Reports each step's STATUS as well as its conclusion. An earlier version
    printed only the conclusion, which is empty both for a step that is running
    and for one that has not started, so a wedged run and a queued run looked
    identical. Elapsed time is shown for the same reason: "in progress" means
    nothing without knowing for how long.

    Run:  .\ci-status.ps1
#>

$repo    = "Dam-Beaver-Studios-LLC/CompletionNavigator"
$headers = @{ "User-Agent" = "CompletionNavigator"; "Accept" = "application/vnd.github+json" }

function Format-Age {
    param([string] $Timestamp)

    if (-not $Timestamp) { return "" }

    $started = [datetime]::Parse($Timestamp).ToUniversalTime()
    $span    = (Get-Date).ToUniversalTime() - $started

    if ($span.TotalHours -ge 1) {
        return ("{0:N0}h {1:N0}m" -f [math]::Floor($span.TotalHours), $span.Minutes)
    }

    return ("{0:N0}m" -f [math]::Max(0, $span.TotalMinutes))
}

try {
    $runs = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/actions/runs?per_page=5" -Headers $headers
}
catch {
    Write-Host "Could not reach the GitHub API: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  https://github.com/$repo/actions" -ForegroundColor Cyan
    exit 1
}

Write-Host ""
Write-Host "Recent workflow runs" -ForegroundColor Cyan

foreach ($r in $runs.workflow_runs) {
    $colour = if ($r.conclusion -eq "success") { "Green" }
              elseif ($r.conclusion -eq "failure") { "Red" }
              elseif ($r.status -eq "in_progress" -or $r.status -eq "queued") { "Yellow" }
              else { "Gray" }

    $state = if ($r.conclusion) { $r.conclusion } else { $r.status }

    Write-Host ("  {0,-22} {1,-12} running for {2}" -f `
        $r.display_title, $state, (Format-Age $r.created_at)) -ForegroundColor $colour
}

$latest = $runs.workflow_runs | Select-Object -First 1

if (-not $latest) { Write-Host "No runs found."; exit 0 }

Write-Host ""
Write-Host "Latest run: $($latest.display_title)   started $((Format-Age $latest.created_at)) ago" -ForegroundColor Cyan

try {
    $jobs = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/actions/runs/$($latest.id)/jobs" -Headers $headers
}
catch {
    Write-Host "  Could not read the job list. $($latest.html_url)" -ForegroundColor Yellow
    exit 1
}

foreach ($job in $jobs.jobs) {
    Write-Host ("  job '{0}' is {1}" -f $job.name, $job.status) -ForegroundColor DarkGray

    foreach ($step in $job.steps) {
        $state = if ($step.conclusion) { $step.conclusion } else { $step.status }

        $colour = switch ($state) {
            "success"     { "DarkGray" }
            "failure"     { "Red" }
            "skipped"     { "Yellow" }
            "in_progress" { "Magenta" }
            "queued"      { "DarkGray" }
            default       { "Gray" }
        }

        $age = ""

        if ($step.status -eq "in_progress" -and $step.started_at) {
            $age = "  <-- running for " + (Format-Age $step.started_at)
        }

        Write-Host ("  {0,-3} {1,-42} {2}{3}" -f `
            $step.number, $step.name, $state, $age) -ForegroundColor $colour
    }
}

$running = $jobs.jobs.steps | Where-Object { $_.status -eq "in_progress" } | Select-Object -First 1
$failed  = $jobs.jobs.steps | Where-Object { $_.conclusion -eq "failure" } | Select-Object -First 1

Write-Host ""

if ($failed) {
    Write-Host "FAILED AT: $($failed.name)" -ForegroundColor Red
    Write-Host "  $($latest.html_url)" -ForegroundColor Cyan
}
elseif ($running) {
    $stuckFor = Format-Age $running.started_at

    Write-Host "RUNNING: $($running.name)  (for $stuckFor)" -ForegroundColor Magenta

    if ($running.started_at -and
        ((Get-Date).ToUniversalTime() - [datetime]::Parse($running.started_at).ToUniversalTime()).TotalMinutes -gt 8) {
        Write-Host ""
        Write-Host "That is far too long for this step. It is wedged, not working." -ForegroundColor Red
        Write-Host "Cancel it: $($latest.html_url)" -ForegroundColor Cyan
    }
}
elseif ($latest.conclusion -eq "success") {
    Write-Host "Run succeeded. If CurseForge has no file, read 'Package and upload':" -ForegroundColor Green
    Write-Host "  $($latest.html_url)" -ForegroundColor Cyan
}
else {
    Write-Host "Queued, waiting for a runner." -ForegroundColor Yellow
}
