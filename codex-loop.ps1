[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Goal,

    [Alias("Check", "Verifier")]
    [string]$SuccessCommand = "",

    [string]$Project = (Get-Location).Path,

    [int]$MaxRuns = 10,

    [ValidateSet("read-only", "workspace-write", "danger-full-access")]
    [string]$Sandbox = "workspace-write",

    [string]$Model,

    [bool]$Yolo = $true,

    [bool]$FullAuto = $false,

    [switch]$DangerouslyBypassSandbox,

    [switch]$Resume,

    [switch]$SkipInitialCheck,

    [int]$StopAfterNoChangeRuns = 0,

    [int]$MaxHistoryChars = 60000,

    [switch]$SkipGoalReview,

    [switch]$AutoApproveGoal,

    [switch]$ShowJsonResult,

    [switch]$ShowCommands
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Limit-Text {
    param(
        [AllowNull()]
        [string]$Text,
        [int]$MaxChars = 12000
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ""
    }

    if ($Text.Length -le $MaxChars) {
        return $Text
    }

    return $Text.Substring($Text.Length - $MaxChars)
}

function Limit-TextStart {
    param(
        [AllowNull()]
        [string]$Text,
        [int]$MaxChars = 220
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ""
    }

    if ($Text.Length -le $MaxChars) {
        return $Text
    }

    if ($MaxChars -le 3) {
        return $Text.Substring(0, $MaxChars)
    }

    return $Text.Substring(0, $MaxChars - 3) + "..."
}

function Save-Text {
    param(
        [string]$Path,
        [AllowNull()]
        [string]$Text
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent | Out-Null
    }

    [System.IO.File]::WriteAllText($Path, [string]$Text, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-ProjectCommand {
    param(
        [string]$Command,
        [string]$WorkingDirectory,
        [string]$OutputPath
    )

    Push-Location -LiteralPath $WorkingDirectory
    $oldErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $lines = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $Command 2>&1
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) {
            $exitCode = if ($?) { 0 } else { 1 }
        }
    }
    catch {
        $lines = @($_.Exception.Message)
        $exitCode = 1
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
        Pop-Location
    }

    $text = ($lines | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    Save-Text -Path $OutputPath -Text $text

    [pscustomobject]@{
        ExitCode = [int]$exitCode
        Output   = $text
    }
}

function Invoke-GitText {
    param(
        [string]$WorkingDirectory,
        [string[]]$GitArgs
    )

    Push-Location -LiteralPath $WorkingDirectory
    try {
        $output = & git @GitArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            return ""
        }

        return (($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine)
    }
    catch {
        return ""
    }
    finally {
        Pop-Location
    }
}

function Test-GitRepo {
    param([string]$WorkingDirectory)

    Push-Location -LiteralPath $WorkingDirectory
    try {
        & git rev-parse --is-inside-work-tree *> $null
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
    finally {
        Pop-Location
    }
}

function Get-StringHash {
    param([AllowNull()][string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
        $hashBytes = $sha.ComputeHash($bytes)
        return -join ($hashBytes | ForEach-Object { $_.ToString("x2") })
    }
    finally {
        $sha.Dispose()
    }
}

function Get-GitSummary {
    param([string]$WorkingDirectory)

    if (-not (Test-GitRepo -WorkingDirectory $WorkingDirectory)) {
        return "Not a git repository."
    }

    $status = Invoke-GitText -WorkingDirectory $WorkingDirectory -GitArgs @("status", "--short")
    $stat = Invoke-GitText -WorkingDirectory $WorkingDirectory -GitArgs @("diff", "--stat", "--", ".", ":(exclude).codex-loop")
    $untracked = Invoke-GitText -WorkingDirectory $WorkingDirectory -GitArgs @("ls-files", "--others", "--exclude-standard")

    return @"
git status --short
$status

git diff --stat
$stat

untracked files
$untracked
"@
}

function Get-GitDiffHash {
    param([string]$WorkingDirectory)

    if (-not (Test-GitRepo -WorkingDirectory $WorkingDirectory)) {
        return ""
    }

    $trackedDiff = Invoke-GitText -WorkingDirectory $WorkingDirectory -GitArgs @("diff", "--", ".", ":(exclude).codex-loop")
    $untracked = Invoke-GitText -WorkingDirectory $WorkingDirectory -GitArgs @("ls-files", "--others", "--exclude-standard")
    return Get-StringHash -Text ($trackedDiff + [Environment]::NewLine + $untracked)
}

function Get-ThreadIdFromJsonLines {
    param([string[]]$Lines)

    foreach ($line in $Lines) {
        if ($line -notmatch "^\s*\{") {
            continue
        }

        try {
            $event = $line | ConvertFrom-Json
            if ($event.type -eq "thread.started" -and $event.thread_id) {
                return [string]$event.thread_id
            }
        }
        catch {
            continue
        }
    }

    return $null
}

function New-CodexResultSchemaText {
    return @'
{
  "type": "object",
  "additionalProperties": false,
  "required": [
    "status",
    "run_status_claim",
    "goal_restated",
    "attempt_summary",
    "context",
    "changes_made",
    "files_changed",
    "commands_run",
    "verifier_command",
    "verifier_result_claim",
    "failure_details",
    "next_attempt_plan",
    "needs_user_input",
    "notes_for_next_run"
  ],
  "properties": {
    "status": {
      "type": "string",
      "enum": ["success", "failure", "failed", "partial", "blocked", "unknown"]
    },
    "run_status_claim": {
      "type": "string",
      "enum": ["success", "failure", "failed", "partial", "blocked", "unknown"]
    },
    "goal_restated": {
      "type": "string"
    },
    "attempt_summary": {
      "type": "string"
    },
    "context": {
      "type": "string"
    },
    "changes_made": {
      "type": "array",
      "items": { "type": "string" }
    },
    "files_changed": {
      "type": "array",
      "items": { "type": "string" }
    },
    "commands_run": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["command", "exit_code", "summary"],
        "properties": {
          "command": { "type": "string" },
          "exit_code": { "type": "string" },
          "summary": { "type": "string" }
        }
      }
    },
    "verifier_command": {
      "type": "string"
    },
    "verifier_result_claim": {
      "type": "object",
      "additionalProperties": false,
      "required": ["ran_exact_verifier", "passed_claim", "exit_code", "summary"],
      "properties": {
        "ran_exact_verifier": { "type": "boolean" },
        "passed_claim": { "type": "boolean" },
        "exit_code": { "type": "string" },
        "summary": { "type": "string" }
      }
    },
    "failure_details": {
      "type": "string"
    },
    "next_attempt_plan": {
      "type": "array",
      "items": { "type": "string" }
    },
    "needs_user_input": {
      "type": "boolean"
    },
    "notes_for_next_run": {
      "type": "string"
    }
  }
}
'@
}

function New-GoalRefinementSchemaText {
    return @'
{
  "type": "object",
  "additionalProperties": false,
  "required": ["goal"],
  "properties": {
    "goal": {
      "type": "string"
    }
  }
}
'@
}

function Convert-GoalRefinementResult {
    param(
        [string]$LastMessagePath,
        [string]$FallbackGoal
    )

    if (-not (Test-Path -LiteralPath $LastMessagePath)) {
        return [pscustomobject]@{
            Goal       = $FallbackGoal
            ParseError = "Goal refinement did not produce a final message file."
        }
    }

    $raw = Get-Content -LiteralPath $LastMessagePath -Raw
    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add($raw)

    $fenceMatch = [regex]::Match($raw, '```(?:json)?\s*(.*?)\s*```', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($fenceMatch.Success) {
        $candidates.Add($fenceMatch.Groups[1].Value)
    }

    $firstBrace = $raw.IndexOf("{")
    $lastBrace = $raw.LastIndexOf("}")
    if ($firstBrace -ge 0 -and $lastBrace -gt $firstBrace) {
        $candidates.Add($raw.Substring($firstBrace, $lastBrace - $firstBrace + 1))
    }

    foreach ($candidate in $candidates) {
        try {
            $parsed = $candidate | ConvertFrom-Json
            $goalValue = Get-ObjectPropertyValue -Object $parsed -Name "goal"
            if (-not [string]::IsNullOrWhiteSpace([string]$goalValue)) {
                return [pscustomObject]@{
                    Goal       = ([string]$goalValue).Trim()
                    ParseError = $null
                }
            }
        }
        catch {
            continue
        }
    }

    return [pscustomobject]@{
        Goal       = $FallbackGoal
        ParseError = "Goal refinement response was not valid JSON with a non-empty goal."
    }
}

function Get-JsonOutputInstructions {
    param([string]$SchemaText)

    return @"
## Required Final Response Format
Your final response must be exactly one valid JSON object and nothing else. Do not wrap it in Markdown fences.

The loop reads this JSON before deciding whether to stop or make another attempt. If an external verifier command was provided, that verifier is the source of truth. Otherwise, the "status" field is the source of truth.

Use this JSON Schema:
$SchemaText
"@
}

function Convert-CodexResult {
    param(
        [string]$LastMessagePath,
        [string]$RunDirectory
    )

    $normalizedPath = Join-Path $RunDirectory "codex-result.json"
    $parseErrorPath = Join-Path $RunDirectory "codex-result-parse-error.txt"

    if (-not (Test-Path -LiteralPath $LastMessagePath)) {
        $fallback = [ordered]@{
            status              = "unknown"
            run_status_claim    = "unknown"
            goal_restated       = ""
            attempt_summary     = "Codex did not produce a final message file."
            context             = "No Codex context was available because no final message file was produced."
            changes_made        = @()
            files_changed       = @()
            commands_run        = @()
            verifier_command    = ""
            verifier_result_claim = [ordered]@{
                ran_exact_verifier = $false
                passed_claim       = $false
                exit_code          = ""
                summary            = "No Codex verifier claim was available."
            }
            failure_details     = "Missing Codex final message."
            next_attempt_plan   = @("Run another attempt with the full mission packet.")
            needs_user_input    = $false
            notes_for_next_run  = ""
        }
        Save-Text -Path $normalizedPath -Text (($fallback | ConvertTo-Json -Depth 8) + [Environment]::NewLine)
        Save-Text -Path $parseErrorPath -Text "Missing Codex final message."
        return [pscustomobject]@{
            Object     = $fallback
            JsonText   = Get-Content -LiteralPath $normalizedPath -Raw
            Path       = $normalizedPath
            ParseError = "Missing Codex final message."
        }
    }

    $raw = Get-Content -LiteralPath $LastMessagePath -Raw
    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add($raw)

    $fenceMatch = [regex]::Match($raw, '```(?:json)?\s*(.*?)\s*```', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($fenceMatch.Success) {
        $candidates.Add($fenceMatch.Groups[1].Value)
    }

    $firstBrace = $raw.IndexOf("{")
    $lastBrace = $raw.LastIndexOf("}")
    if ($firstBrace -ge 0 -and $lastBrace -gt $firstBrace) {
        $candidates.Add($raw.Substring($firstBrace, $lastBrace - $firstBrace + 1))
    }

    foreach ($candidate in $candidates) {
        try {
            $parsed = $candidate | ConvertFrom-Json
            $normalized = $parsed | ConvertTo-Json -Depth 12
            Save-Text -Path $normalizedPath -Text ($normalized + [Environment]::NewLine)
            return [pscustomobject]@{
                Object     = $parsed
                JsonText   = $normalized + [Environment]::NewLine
                Path       = $normalizedPath
                ParseError = $null
            }
        }
        catch {
            continue
        }
    }

    $errorText = "Codex final message was not valid JSON. Raw tail:" + [Environment]::NewLine + (Limit-Text -Text $raw -MaxChars 6000)
    Save-Text -Path $parseErrorPath -Text $errorText

    $fallbackObject = [ordered]@{
        status              = "unknown"
        run_status_claim    = "unknown"
        goal_restated       = ""
        attempt_summary     = "Codex final message could not be parsed as JSON."
        context             = "The final response could not be parsed, so the raw response tail was saved for the next attempt."
        changes_made        = @()
        files_changed       = @()
        commands_run        = @()
        verifier_command    = ""
        verifier_result_claim = [ordered]@{
            ran_exact_verifier = $false
            passed_claim       = $false
            exit_code          = ""
            summary            = "No parseable verifier claim was available."
        }
        failure_details     = "The loop could not parse Codex's final response as JSON."
        next_attempt_plan   = @("Return only a valid JSON object matching the required schema.")
        needs_user_input    = $false
        notes_for_next_run  = Limit-Text -Text $raw -MaxChars 3000
    }
    $fallbackJson = $fallbackObject | ConvertTo-Json -Depth 12
    Save-Text -Path $normalizedPath -Text ($fallbackJson + [Environment]::NewLine)

    [pscustomobject]@{
        Object     = $fallbackObject
        JsonText   = $fallbackJson + [Environment]::NewLine
        Path       = $normalizedPath
        ParseError = $errorText
    }
}

function Get-CodexClaimStatus {
    param([AllowNull()]$CodexResultObject)

    if ($null -eq $CodexResultObject) {
        return "unknown"
    }

    $propertyNames = $CodexResultObject.PSObject.Properties.Name
    if (($propertyNames -contains "status") -and $CodexResultObject.status) {
        return ([string]$CodexResultObject.status).ToLowerInvariant()
    }

    if (($propertyNames -contains "run_status_claim") -and $CodexResultObject.run_status_claim) {
        return ([string]$CodexResultObject.run_status_claim).ToLowerInvariant()
    }

    return "unknown"
}

function Convert-AttemptHistoryToText {
    param(
        [System.Collections.IEnumerable]$History,
        [int]$MaxChars
    )

    if ($History -is [System.Collections.Generic.List[object]]) {
        $items = @($History.ToArray())
    }
    else {
        $items = @($History)
    }

    $json = ConvertTo-Json -InputObject $items -Depth 18
    return Limit-Text -Text $json -MaxChars $MaxChars
}

function Get-ObjectPropertyValue {
    param(
        [AllowNull()]$Object,
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Format-OneLine {
    param(
        [AllowNull()]
        [string]$Text,
        [int]$MaxChars = 220
    )

    $flat = ([string]$Text -replace "\s+", " ").Trim()
    $doubleQuote = [string][char]34

    $mojiApostrophe = -join ([char]0x0393, [char]0x00c7, [char]0x00d6)
    $mojiOpenQuote = -join ([char]0x0393, [char]0x00c7, [char]0x00a3)
    $mojiCloseQuote = -join ([char]0x0393, [char]0x00c7, [char]0x00a5)
    $mojiEnDash = -join ([char]0x0393, [char]0x00c7, [char]0x00f4)
    $mojiEmDash = -join ([char]0x0393, [char]0x00c7, [char]0x00f6)
    $mojiEllipsis = -join ([char]0x0393, [char]0x00c7, [char]0x00aa)

    $flat = $flat.Replace($mojiApostrophe, "'").Replace($mojiOpenQuote, $doubleQuote).Replace($mojiCloseQuote, $doubleQuote)
    $flat = $flat.Replace($mojiEnDash, "-").Replace($mojiEmDash, "-").Replace($mojiEllipsis, "...")
    return Limit-TextStart -Text $flat -MaxChars $MaxChars
}
function Format-CommandDisplay {
    param(
        [AllowNull()]
        [string]$Command,
        [int]$MaxChars = 180
    )

    $display = Format-OneLine -Text $Command -MaxChars 2000

    $patterns = @(
        '^(?:"[^"]*powershell(?:\.exe)?"|powershell(?:\.exe)?)\s+-Command\s+''(?<inner>.*)''$',
        '^(?:"[^"]*powershell(?:\.exe)?"|powershell(?:\.exe)?)\s+-Command\s+"(?<inner>.*)"$',
        '^(?:"[^"]*powershell(?:\.exe)?"|powershell(?:\.exe)?)\s+-Command\s+(?<inner>.*)$'
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match($display, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($match.Success) {
            $display = $match.Groups["inner"].Value
            break
        }
    }

    $display = $display.Trim()
    if ($display.Length -ge 2) {
        $first = $display[0]
        $last = $display[$display.Length - 1]
        if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
            $display = $display.Substring(1, $display.Length - 2)
        }
    }
    if ($display.StartsWith('"') -or $display.StartsWith("'")) {
        $display = $display.Substring(1)
    }

    return Format-OneLine -Text $display -MaxChars $MaxChars
}

function Get-CommandVerb {
    param([AllowNull()][string]$Command)

    $display = Format-CommandDisplay -Command $Command -MaxChars 200
    if ($display -match '^\s*([^\s]+)') {
        return $matches[1]
    }

    return "command"
}

function Format-PathLabel {
    param([AllowNull()][string]$PathText)

    if ([string]::IsNullOrWhiteSpace($PathText)) {
        return "files"
    }

    $label = ([string]$PathText).Trim().Trim('"').Trim("'")
    $label = $label -replace "\\\\", "\"

    if ([System.IO.Path]::IsPathRooted($label)) {
        try {
            $projectRoot = [System.IO.Path]::GetFullPath($Project)
            $fullPath = [System.IO.Path]::GetFullPath($label)
            if ($fullPath.StartsWith($projectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $label = $fullPath.Substring($projectRoot.Length).TrimStart("\", "/")
            }
            else {
                $label = Split-Path -Leaf $fullPath
            }
        }
        catch {
            $label = Split-Path -Leaf $label
        }
    }

    if ($label -eq "." -or $label -eq ".\") {
        return "project files"
    }

    return $label
}

function Get-FirstPathFromCommand {
    param([AllowNull()][string]$Command)

    $display = Format-CommandDisplay -Command $Command -MaxChars 4000
    $pattern = "(?i)(?:^|[\s'""])(?<path>(?:[A-Za-z]:)?(?:[^'"">\s|;{}()]+[\\/])*[^'"">\s|;{}()]+\.(?:py|ps1|ts|tsx|js|jsx|json|md|toml|yaml|yml|csv|parquet|txt|html|css|scss|ini|env))"
    $match = [regex]::Match($display, $pattern)
    if ($match.Success) {
        return Format-PathLabel -PathText $match.Groups["path"].Value
    }

    if ($display -match "(?i)\b(?:Get-ChildItem|dir|ls)\s+(?<path>[^\s|]+)") {
        $candidate = [string]$matches["path"]
        if (-not $candidate.StartsWith("-")) {
            return Format-PathLabel -PathText $candidate
        }
    }

    return $null
}

function Get-HumanCommandAction {
    param(
        [AllowNull()][string]$Command,
        [AllowNull()]$ExitCode,
        [bool]$Completed
    )

    $display = (Format-CommandDisplay -Command $Command -MaxChars 4000).Trim()
    $verb = (Get-CommandVerb -Command $display).ToLowerInvariant()
    $pathLabel = Get-FirstPathFromCommand -Command $display

    if ($verb -in @("get-content", "type", "import-csv")) {
        return "Reading $(if ($pathLabel) { $pathLabel } else { "file" })"
    }

    if ($verb -in @("get-childitem", "dir", "ls")) {
        return "Listing $(if ($pathLabel) { $pathLabel } else { "project files" })"
    }

    if ($verb -in @("rg", "select-string", "findstr")) {
        if ($display -match "(^|\s)--files(\s|$)") {
            return "Scanning project files"
        }
        return "Searching the codebase"
    }

    if ($verb -eq "git") {
        if ($display -match "(?i)^git\s+status\b") { return "Checking git status" }
        if ($display -match "(?i)^git\s+diff\b") { return "Reviewing code changes" }
        if ($display -match "(?i)^git\s+(show|log)\b") { return "Reading git history" }
        return "Running git"
    }

    if ($display -match "(?i)(^|\s)(python|py)\s+-m\s+pytest\b" -or $verb -eq "pytest") {
        return "Running tests"
    }

    if ($display -match "(?i)(^|\s)(python|py)\s+(?<script>[^\s|;]+\.py)") {
        return "Running $(Format-PathLabel -PathText $matches["script"])"
    }

    if ($display -match "(?i)\b(apply_patch|set-content|add-content|new-item|copy-item|move-item|remove-item)\b") {
        return "Updating files"
    }

    if ($verb -in @("npm", "pnpm", "yarn")) {
        return "Running $verb"
    }

    if ($verb -in @("ruff", "mypy", "eslint", "tsc")) {
        return "Checking code quality"
    }

    if ($display) {
        return "Running command"
    }

    return "Working"
}

function Get-HumanCommandCompletion {
    param([string]$Action)

    if ($Action -eq "Running tests") {
        return "Tests finished"
    }

    if ($Action -match "^Running (?<target>.+)$") {
        return "Finished $($matches["target"])"
    }

    if ($Action -eq "Checking code quality") {
        return "Code quality check finished"
    }

    if ($Action -eq "Updating files") {
        return "Files updated"
    }

    return "$Action finished"
}

function Should-ShowCommandOutput {
    param(
        [AllowNull()][string]$Command,
        [AllowNull()]$ExitCode,
        [AllowNull()][string]$Output
    )

    if ([string]::IsNullOrWhiteSpace($Output)) {
        return $false
    }

    if ($null -ne $ExitCode -and [string]$ExitCode -ne "0") {
        return $true
    }

    $verb = (Get-CommandVerb -Command $Command).ToLowerInvariant()
    if ($verb -in @("get-content", "rg", "get-childitem", "dir", "ls")) {
        return $false
    }

    return $Output.Length -le 500
}

function Should-ShowCommandEvent {
    param(
        [AllowNull()][string]$Command,
        [AllowNull()]$ExitCode,
        [bool]$Completed
    )

    if ($ShowCommands) {
        return $true
    }

    if ($Completed -and $null -ne $ExitCode -and [string]$ExitCode -ne "0") {
        return $true
    }

    $display = (Format-CommandDisplay -Command $Command -MaxChars 1000).Trim()
    $verb = (Get-CommandVerb -Command $Command).ToLowerInvariant()

    $quietVerbs = @(
        "get-content",
        "get-childitem",
        "rg",
        "select-string",
        "findstr",
        "type",
        "dir",
        "ls"
    )

    if ($verb -in $quietVerbs) {
        return $false
    }

    if ($verb -eq "git" -and $display -match '^git\s+(status|diff|show|log|ls-files|rev-parse)\b') {
        return $false
    }

    return $true
}

function Format-OutputPreview {
    param(
        [AllowNull()]
        [string]$Output,
        [int]$MaxChars = 220
    )

    $clean = [string]$Output
    try {
        $projectRoot = [System.IO.Path]::GetFullPath($Project)
        $clean = $clean.Replace($projectRoot, ".")
        $clean = $clean.Replace($projectRoot.Replace('\', '\\'), ".")
    }
    catch {
        # Best-effort cleanup only.
    }

    return Format-OneLine -Text $clean -MaxChars $MaxChars
}

function Format-ResultText {
    param(
        [AllowNull()][string]$Text,
        [int]$MaxChars = 500
    )

    $clean = [string]$Text
    try {
        $projectRoot = [System.IO.Path]::GetFullPath($Project)
        $clean = $clean.Replace($projectRoot, ".")
        $clean = $clean.Replace($projectRoot.Replace('\', '\\'), ".")
    }
    catch {
        # Best-effort cleanup only.
    }

    return Format-OneLine -Text $clean -MaxChars $MaxChars
}

function Format-DisplayPath {
    param([AllowNull()][string]$PathText)

    if ([string]::IsNullOrWhiteSpace($PathText)) {
        return ""
    }

    $display = [string]$PathText
    try {
        $projectRoot = [System.IO.Path]::GetFullPath($Project)
        $fullPath = [System.IO.Path]::GetFullPath($display)
        if ($fullPath.StartsWith($projectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $relative = $fullPath.Substring($projectRoot.Length).TrimStart("\", "/")
            if ($relative) {
                return $relative
            }
            return "."
        }
    }
    catch {
        # Best-effort cleanup only.
    }

    return $display
}

function Reset-ProgressActivity {
    $script:ProgressActivity = [ordered]@{
        Commands  = 0
        Inspected = 0
        Created   = 0
        Edited    = 0
        Deleted   = 0
        Failed    = 0
    }
}

function Add-ProgressCommandActivity {
    param(
        [AllowNull()][string]$Command,
        [AllowNull()]$ExitCode
    )

    if ($null -eq $script:ProgressActivity) {
        Reset-ProgressActivity
    }

    $display = (Format-CommandDisplay -Command $Command -MaxChars 4000).Trim()
    $verb = (Get-CommandVerb -Command $display).ToLowerInvariant()

    $script:ProgressActivity.Commands++

    if ($null -ne $ExitCode -and [string]$ExitCode -ne "0") {
        $script:ProgressActivity.Failed++
    }

    if ($verb -in @("get-content", "type", "import-csv", "get-childitem", "dir", "ls", "rg", "select-string", "findstr")) {
        $script:ProgressActivity.Inspected++
    }

    if ($display -match "(?i)\b(new-item|mkdir)\b") {
        $script:ProgressActivity.Created++
    }
    elseif ($display -match "(?i)\b(remove-item|del|erase|rm)\b") {
        $script:ProgressActivity.Deleted++
    }
    elseif ($display -match "(?i)\b(apply_patch|set-content|add-content|out-file|copy-item|move-item)\b") {
        $script:ProgressActivity.Edited++
    }
}

function Add-ProgressFileActivity {
    param([AllowNull()]$Changes)

    if ($null -eq $script:ProgressActivity) {
        Reset-ProgressActivity
    }

    foreach ($change in @($Changes)) {
        $kind = [string](Get-ObjectPropertyValue -Object $change -Name "kind")
        switch ($kind.ToLowerInvariant()) {
            "add" { $script:ProgressActivity.Created++ }
            "create" { $script:ProgressActivity.Created++ }
            "update" { $script:ProgressActivity.Edited++ }
            "modify" { $script:ProgressActivity.Edited++ }
            "delete" { $script:ProgressActivity.Deleted++ }
            "remove" { $script:ProgressActivity.Deleted++ }
            default { $script:ProgressActivity.Edited++ }
        }
    }
}

function Format-ActivityPhrase {
    param(
        [int]$Count,
        [string]$Verb,
        [string]$SingularNoun,
        [string]$PluralNoun
    )

    if ($Count -eq 1) {
        return "$Verb 1 $SingularNoun"
    }

    return "$Verb $Count $PluralNoun"
}

function ConvertTo-SentenceStart {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    if ($Text.Length -eq 1) {
        return $Text.ToUpperInvariant()
    }

    return $Text.Substring(0, 1).ToUpperInvariant() + $Text.Substring(1)
}

function Write-ProgressActivitySummary {
    if ($ShowCommands) {
        return
    }

    if ($null -eq $script:ProgressActivity) {
        Reset-ProgressActivity
        return
    }

    $parts = New-Object 'System.Collections.Generic.List[string]'
    if ($script:ProgressActivity.Created -gt 0) {
        $parts.Add((Format-ActivityPhrase -Count $script:ProgressActivity.Created -Verb "created" -SingularNoun "file" -PluralNoun "files")) | Out-Null
    }
    if ($script:ProgressActivity.Edited -gt 0) {
        $parts.Add((Format-ActivityPhrase -Count $script:ProgressActivity.Edited -Verb "edited" -SingularNoun "file" -PluralNoun "files")) | Out-Null
    }
    if ($script:ProgressActivity.Deleted -gt 0) {
        $parts.Add((Format-ActivityPhrase -Count $script:ProgressActivity.Deleted -Verb "removed" -SingularNoun "file" -PluralNoun "files")) | Out-Null
    }
    if ($script:ProgressActivity.Inspected -gt 0) {
        $parts.Add((Format-ActivityPhrase -Count $script:ProgressActivity.Inspected -Verb "inspected" -SingularNoun "item" -PluralNoun "items")) | Out-Null
    }
    if ($script:ProgressActivity.Commands -gt 0) {
        $parts.Add((Format-ActivityPhrase -Count $script:ProgressActivity.Commands -Verb "ran" -SingularNoun "command" -PluralNoun "commands")) | Out-Null
    }
    if ($script:ProgressActivity.Failed -gt 0) {
        $parts.Add((Format-ActivityPhrase -Count $script:ProgressActivity.Failed -Verb "hit" -SingularNoun "failure" -PluralNoun "failures")) | Out-Null
    }

    if ($parts.Count -gt 0) {
        Write-Host ("  {0}" -f (ConvertTo-SentenceStart -Text ($parts -join ", "))) -ForegroundColor DarkGray
        Write-Host ""
    }

    Reset-ProgressActivity
}

function Write-AgentParagraph {
    param(
        [AllowNull()][string]$Text,
        [switch]$Success,
        [switch]$Failure
    )

    $message = Format-OneLine -Text $Text -MaxChars 700
    if ([string]::IsNullOrWhiteSpace($message)) {
        return
    }

    if ($Success) {
        Write-Host ("  Success: {0}" -f $message)
    }
    elseif ($Failure) {
        Write-Host ("  Not solved yet: {0}" -f $message)
    }
    else {
        Write-Host ("  {0}" -f $message)
    }
    Write-Host ""
}

function Write-HumanResult {
    param(
        $LoopResult,
        [bool]$ShowJson,
        [AllowNull()][string]$JsonText
    )

    $codexResult = $LoopResult.codex_result
    $summary = Get-ObjectPropertyValue -Object $codexResult -Name "attempt_summary"
    $context = Get-ObjectPropertyValue -Object $codexResult -Name "context"
    $failure = Get-ObjectPropertyValue -Object $codexResult -Name "failure_details"
    $filesChanged = @(Get-ObjectPropertyValue -Object $codexResult -Name "files_changed")
    $changesMade = @(Get-ObjectPropertyValue -Object $codexResult -Name "changes_made")

    Write-Host ""
    Write-Host "Result"
    Write-Host "------"
    Write-Host ("Status: {0}" -f $LoopResult.actual_status)
    if ($ShowCommands) {
        Write-Host ("Decision: {0}" -f $LoopResult.decision_source)
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$summary)) {
        Write-Host ("Summary: {0}" -f (Format-ResultText -Text $summary -MaxChars 500))
    }

    if ($filesChanged.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$filesChanged[0])) {
        Write-Host "Files changed:"
        foreach ($file in $filesChanged | Select-Object -First 8) {
            Write-Host ("  - {0}" -f $file)
        }
        if ($filesChanged.Count -gt 8) {
            Write-Host ("  ...and {0} more" -f ($filesChanged.Count - 8))
        }
    }
    elseif ($changesMade.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$changesMade[0])) {
        Write-Host "Changes:"
        foreach ($change in $changesMade | Select-Object -First 5) {
            Write-Host ("  - {0}" -f (Format-OneLine -Text $change -MaxChars 220))
        }
    }

    if ($LoopResult.actual_status -ne "success" -and -not [string]::IsNullOrWhiteSpace([string]$failure)) {
        Write-Host ("Failure: {0}" -f (Format-ResultText -Text $failure -MaxChars 500))
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$context)) {
        Write-Host ("Context: {0}" -f (Format-ResultText -Text $context -MaxChars 500))
    }

    Write-Host ("Logs: {0}" -f (Format-DisplayPath -PathText $LoopResult.run_dir))

    if ($ShowJson -and -not [string]::IsNullOrWhiteSpace($JsonText)) {
        Write-Host ""
        Write-Host "Raw JSON"
        Write-Host "--------"
        Write-Output $JsonText
    }
}

function Write-CodexEventProgress {
    param([string]$Line)

    if ($Line -notmatch "^\s*\{") {
        return
    }

    try {
        $event = $Line | ConvertFrom-Json
    }
    catch {
        return
    }

    $eventType = Get-ObjectPropertyValue -Object $event -Name "type"
    switch ($eventType) {
        "thread.started" {
            $threadId = Get-ObjectPropertyValue -Object $event -Name "thread_id"
            if ($ShowCommands -and $threadId) {
                Write-Host "  Session: $threadId"
            }
        }
        "turn.started" {
            if ($ShowCommands) {
                Write-Host "  Codex is working..."
            }
        }
        "item.started" {
            $item = Get-ObjectPropertyValue -Object $event -Name "item"
            $itemType = Get-ObjectPropertyValue -Object $item -Name "type"
            if ($itemType -eq "command_execution") {
                $command = Get-ObjectPropertyValue -Object $item -Name "command"
                if ($ShowCommands -and (Should-ShowCommandEvent -Command $command -ExitCode $null -Completed:$false)) {
                    Write-Host ("  > {0}" -f (Format-CommandDisplay -Command $command -MaxChars 180))
                }
            }
            elseif ($ShowCommands -and $itemType -eq "file_change") {
                Write-Host "  > editing files"
            }
        }
        "item.completed" {
            $item = Get-ObjectPropertyValue -Object $event -Name "item"
            $itemType = Get-ObjectPropertyValue -Object $item -Name "type"

            if ($itemType -eq "agent_message") {
                $text = [string](Get-ObjectPropertyValue -Object $item -Name "text")
                try {
                    $json = $text | ConvertFrom-Json
                    $status = Get-ObjectPropertyValue -Object $json -Name "status"
                    if (-not $status) {
                        $status = Get-ObjectPropertyValue -Object $json -Name "run_status_claim"
                    }
                    $summary = Get-ObjectPropertyValue -Object $json -Name "attempt_summary"
                    if ($status -or $summary) {
                        Write-ProgressActivitySummary
                        $summaryText = Format-OneLine -Text $summary -MaxChars 700
                        if (-not [string]::IsNullOrWhiteSpace($summaryText)) {
                            if ($status -eq "success") {
                                Write-AgentParagraph -Text $summaryText -Success
                            }
                            elseif ($status -eq "failure") {
                                Write-AgentParagraph -Text $summaryText -Failure
                            }
                            else {
                                Write-AgentParagraph -Text $summaryText
                            }
                        }
                        return
                    }
                }
                catch {
                    # The final message should be JSON, but intermediate messages may be plain text.
                }

                Write-ProgressActivitySummary
                Write-AgentParagraph -Text $text
            }
            elseif ($itemType -eq "command_execution") {
                $rawCommand = Get-ObjectPropertyValue -Object $item -Name "command"
                $command = Format-CommandDisplay -Command $rawCommand -MaxChars 160
                $exitCode = Get-ObjectPropertyValue -Object $item -Name "exit_code"
                $status = Get-ObjectPropertyValue -Object $item -Name "status"
                Add-ProgressCommandActivity -Command $rawCommand -ExitCode $exitCode
                $showCommandEvent = Should-ShowCommandEvent -Command $rawCommand -ExitCode $exitCode -Completed:$true
                if ($ShowCommands -and $showCommandEvent) {
                    Write-Host "  < exit ${exitCode}: $command"
                }

                $rawOutput = [string](Get-ObjectPropertyValue -Object $item -Name "aggregated_output")
                if ($ShowCommands -and (Should-ShowCommandOutput -Command $rawCommand -ExitCode $exitCode -Output $rawOutput)) {
                    Write-Host ("    {0}" -f (Format-OutputPreview -Output $rawOutput -MaxChars 260))
                }
            }
            elseif ($itemType -eq "file_change") {
                $changes = Get-ObjectPropertyValue -Object $item -Name "changes"
                Add-ProgressFileActivity -Changes $changes
                if ($ShowCommands) {
                    Write-Host "  < files updated"
                }
            }
        }
        "turn.completed" {
            $usage = Get-ObjectPropertyValue -Object $event -Name "usage"
            $inputTokens = Get-ObjectPropertyValue -Object $usage -Name "input_tokens"
            $outputTokens = Get-ObjectPropertyValue -Object $usage -Name "output_tokens"
            if ($ShowCommands -and ($inputTokens -or $outputTokens)) {
                Write-Host "  Turn complete. Tokens in/out: $inputTokens/$outputTokens"
            }
            elseif ($ShowCommands) {
                Write-Host "  Turn complete."
            }
        }
        "error" {
            Write-Host ("  Codex error: {0}" -f (Format-OneLine -Text $Line -MaxChars 260))
        }
    }
}

function Invoke-GoalRefinement {
    param(
        [string]$OriginalPrompt,
        [AllowNull()]
        [string]$CurrentGoal,
        [AllowNull()]
        [string]$Modification,
        [string]$WorkingDirectory,
        [string]$StateRoot,
        [int]$ReviewNumber
    )

    $reviewRoot = Join-Path $StateRoot "goal-review"
    New-Item -ItemType Directory -Path $reviewRoot -Force | Out-Null

    $schemaPath = Join-Path $StateRoot "goal-refinement-schema.json"
    Save-Text -Path $schemaPath -Text ((New-GoalRefinementSchemaText) + [Environment]::NewLine)

    $reviewName = "{0:D2}" -f $ReviewNumber
    $lastMessagePath = Join-Path $reviewRoot "goal-$reviewName.json"
    $eventsPath = Join-Path $reviewRoot "goal-$reviewName-events.jsonl"
    $promptPath = Join-Path $reviewRoot "goal-$reviewName-prompt.md"

    $prompt = @"
Convert the user's raw Codex request into a clear goal brief for an autonomous coding agent.

Rules:
- Return exactly one JSON object matching the provided schema.
- The "goal" value may be multiline text.
- For simple requests, keep the goal very short.
- For complex requests with context, constraints, metrics, or validation needs, use this compact structure:
  GOAL:
  CONTEXT:
  MAIN OBJECTIVE:
  IMPORTANT RULES:
  APPROACH:
  SUCCESS CRITERIA:
- Keep the goal concise but complete, usually 150 to 350 words for complex requests.
- Preserve concrete constraints, metrics, file/project targets, validation requirements, and success criteria from the user.
- Make implicit validation needs explicit when they are naturally required by the request, such as testing across provided datasets, avoiding overfitting, and reporting relevant metrics.
- Do not add instructions about retrying, looping, JSON output, terminal interaction, or approval; the wrapper handles those.
- Do not invent unrelated requirements.
- If the original prompt is already clear, lightly tighten it.
- Use plain ASCII characters unless the user explicitly requires otherwise.

Original user prompt:
$OriginalPrompt

Current proposed goal:
$CurrentGoal

User requested modification:
$Modification
"@

    Save-Text -Path $promptPath -Text $prompt

    $args = @("exec", "--json", "--sandbox", "read-only", "--skip-git-repo-check", "--output-schema", $schemaPath, "-C", $WorkingDirectory, "-o", $lastMessagePath)
    if ($Model) {
        $args += @("-m", $Model)
    }
    $args += "-"

    Push-Location -LiteralPath $WorkingDirectory
    $oldErrorActionPreference = $ErrorActionPreference
    $lineList = New-Object 'System.Collections.Generic.List[string]'
    try {
        $ErrorActionPreference = "Continue"
        $prompt | & codex @args 2>&1 | ForEach-Object {
            $lineList.Add($_.ToString()) | Out-Null
        }
    }
    catch {
        $lineList.Add($_.Exception.Message) | Out-Null
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
        Pop-Location
    }

    Save-Text -Path $eventsPath -Text (($lineList.ToArray() -join [Environment]::NewLine) + [Environment]::NewLine)
    $parsed = Convert-GoalRefinementResult -LastMessagePath $lastMessagePath -FallbackGoal $OriginalPrompt

    [pscustomobject]@{
        Goal            = $parsed.Goal
        ParseError      = $parsed.ParseError
        LastMessagePath = $lastMessagePath
        EventsPath      = $eventsPath
        PromptPath      = $promptPath
    }
}

function Invoke-CodexAttempt {
    param(
        [string]$Prompt,
        [string]$WorkingDirectory,
        [string]$RunDirectory,
        [AllowNull()]
        [string]$SessionId,
        [bool]$NeedSkipGitRepoCheck,
        [string]$OutputSchemaPath
    )

    $lastMessagePath = Join-Path $RunDirectory "codex-last-message.md"
    $eventsPath = Join-Path $RunDirectory "codex-events.jsonl"

    if ($SessionId) {
        $args = @("exec", "resume", "--json", "-o", $lastMessagePath)
        if ($Model) {
            $args += @("-m", $Model)
        }
        if ($Yolo -or $DangerouslyBypassSandbox) {
            $args += "--dangerously-bypass-approvals-and-sandbox"
        }
        elseif ($FullAuto) {
            $args += "--full-auto"
        }
        if ($NeedSkipGitRepoCheck) {
            $args += "--skip-git-repo-check"
        }
        $args += @($SessionId, "-")
    }
    else {
        $args = @("exec", "--json", "-o", $lastMessagePath)
        if ($OutputSchemaPath) {
            $args += @("--output-schema", $OutputSchemaPath)
        }
        if ($Model) {
            $args += @("-m", $Model)
        }
        if ($Yolo -or $DangerouslyBypassSandbox) {
            $args += "--dangerously-bypass-approvals-and-sandbox"
        }
        elseif ($FullAuto) {
            $args += "--full-auto"
        }
        else {
            $args += @("--sandbox", $Sandbox)
        }
        if ($NeedSkipGitRepoCheck) {
            $args += "--skip-git-repo-check"
        }
        $args += @("-C", $WorkingDirectory, "-")
    }

    Push-Location -LiteralPath $WorkingDirectory
    $oldErrorActionPreference = $ErrorActionPreference
    $lineList = New-Object 'System.Collections.Generic.List[string]'
    try {
        $ErrorActionPreference = "Continue"
        $Prompt | & codex @args 2>&1 | ForEach-Object {
            $line = $_.ToString()
            $lineList.Add($line) | Out-Null
            Write-CodexEventProgress -Line $line
        }
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) {
            $exitCode = if ($?) { 0 } else { 1 }
        }
    }
    catch {
        $lineList.Add($_.Exception.Message) | Out-Null
        $exitCode = 1
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
        Pop-Location
    }

    $lineStrings = @($lineList.ToArray() | ForEach-Object { $_.ToString() })
    Save-Text -Path $eventsPath -Text ($lineStrings -join [Environment]::NewLine)
    $threadId = Get-ThreadIdFromJsonLines -Lines $lineStrings

    if (($null -eq $exitCode -or $exitCode -ne 0) -and $threadId -and (Test-Path -LiteralPath $lastMessagePath)) {
        $exitCode = 0
    }

    [pscustomobject]@{
        ExitCode        = [int]$exitCode
        ThreadId        = $threadId
        LastMessagePath = $lastMessagePath
        EventsPath      = $eventsPath
    }
}

function Save-State {
    param(
        [string]$Path,
        [hashtable]$State
    )

    $json = $State | ConvertTo-Json -Depth 8
    Save-Text -Path $Path -Text ($json + [Environment]::NewLine)
}

$resolvedProject = (Resolve-Path -LiteralPath $Project).Path
$stateRoot = Join-Path $resolvedProject ".codex-loop"
$runsRoot = Join-Path $stateRoot "runs"
$statePath = Join-Path $stateRoot "state.json"
$goalPacketPath = Join-Path $stateRoot "goal.md"
$outputSchemaPath = Join-Path $stateRoot "codex-result-schema.json"
$historyPath = Join-Path $stateRoot "history.json"
$originalPromptPath = Join-Path $stateRoot "original-prompt.txt"
$approvedGoalPath = Join-Path $stateRoot "approved-goal.txt"

New-Item -ItemType Directory -Path $runsRoot -Force | Out-Null

$codexCommand = Get-Command codex -ErrorAction SilentlyContinue
if (-not $codexCommand) {
    throw "The 'codex' command was not found on PATH."
}

$originalPrompt = $Goal
Save-Text -Path $originalPromptPath -Text ($originalPrompt + [Environment]::NewLine)

if (-not $SkipGoalReview -and -not $Resume) {
    $currentGoal = ""
    $modification = ""
    $reviewNumber = 1

    while ($true) {
        Write-Host ""
        Write-Host "Refining your prompt into a short, clear goal..."
        $refinement = Invoke-GoalRefinement -OriginalPrompt $originalPrompt -CurrentGoal $currentGoal -Modification $modification -WorkingDirectory $resolvedProject -StateRoot $stateRoot -ReviewNumber $reviewNumber
        $candidateGoal = $refinement.Goal

        if ($refinement.ParseError) {
            Write-Host "Goal refinement warning: $($refinement.ParseError)"
        }

        Write-Host ""
        Write-Host "Proposed goal:"
        Write-Host "----------------------------------------"
        Write-Host $candidateGoal
        Write-Host "----------------------------------------"

        if ($AutoApproveGoal) {
            Write-Host "Auto-approving proposed goal."
            $Goal = $candidateGoal
            break
        }

        $choice = Read-Host "Proceed, modify, or cancel? [P/m/c]"
        if ([string]::IsNullOrWhiteSpace($choice) -or $choice.Trim().ToLowerInvariant().StartsWith("p")) {
            $Goal = $candidateGoal
            break
        }

        if ($choice.Trim().ToLowerInvariant().StartsWith("m")) {
            $modification = Read-Host "What should be changed in the proposed goal?"
            $currentGoal = $candidateGoal
            $reviewNumber++
            continue
        }

        if ($choice.Trim().ToLowerInvariant().StartsWith("c")) {
            Write-Host "Cancelled before starting the loop."
            exit 130
        }

        Write-Host "Please enter P to proceed, M to modify, or C to cancel."
    }
}

Save-Text -Path $approvedGoalPath -Text ($Goal + [Environment]::NewLine)

$hasVerifier = -not [string]::IsNullOrWhiteSpace($SuccessCommand)

$executionMode = if ($Yolo -or $DangerouslyBypassSandbox) {
    "YOLO: codex exec --dangerously-bypass-approvals-and-sandbox"
}
elseif ($FullAuto) {
    "Full auto: codex exec --full-auto"
}
else {
    "Sandbox: codex exec --sandbox $Sandbox"
}

$verifierSection = if ($hasVerifier) {
    @"
## External Verifier Command
$SuccessCommand
"@
}
else {
    @"
## External Verifier Command
None provided. The loop will use Codex's final JSON status field to decide whether to stop or retry.
"@
}

$successRule = if ($hasVerifier) {
    "The result is acquired only when the external verifier command exits with code 0. Codex's JSON status is still recorded as context, but the verifier decides actual success."
}
else {
    "The result is acquired when Codex returns a valid JSON object whose status is success. If status is failure, failed, partial, blocked, unknown, or the JSON cannot be parsed, the loop retries."
}

$goalPacket = @"
# codex-loop Mission Packet

This is the authoritative goal for every Codex attempt. Always optimize for this full goal, not only for the latest failure output.

## Goal
$Goal

$verifierSection

## Success Rule
$successRule

## Retry Rule
Each attempt must use the accumulated previous attempt context as diagnostic evidence while still pursuing the full original goal above.

## Execution Mode
$executionMode
"@

Save-Text -Path $goalPacketPath -Text ($goalPacket + [Environment]::NewLine)
$codexResultSchemaText = New-CodexResultSchemaText
Save-Text -Path $outputSchemaPath -Text ($codexResultSchemaText + [Environment]::NewLine)
$jsonOutputInstructions = Get-JsonOutputInstructions -SchemaText $codexResultSchemaText

$isGitRepo = Test-GitRepo -WorkingDirectory $resolvedProject
$needSkipGitRepoCheck = -not $isGitRepo
$sessionId = $null
$startIteration = 1
$previousVerifierOutput = ""
$previousCodexMessage = ""
$attemptHistory = New-Object 'System.Collections.Generic.List[object]'
$previousLoopResultJson = ""
$previousDiffHash = Get-GitDiffHash -WorkingDirectory $resolvedProject
$noChangeRuns = 0

if ($Resume -and (Test-Path -LiteralPath $statePath)) {
    $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $sessionId = [string]$saved.sessionId
    $startIteration = [int]$saved.iteration + 1
    if (($saved.PSObject.Properties.Name -contains "lastVerifierOutput") -and $saved.lastVerifierOutput) {
        $previousVerifierOutput = [string]$saved.lastVerifierOutput
    }
    if (Test-Path -LiteralPath $historyPath) {
        $loadedHistory = Get-Content -LiteralPath $historyPath -Raw | ConvertFrom-Json
        foreach ($historyItem in @($loadedHistory)) {
            $attemptHistory.Add($historyItem) | Out-Null
        }
    }
    elseif (($saved.PSObject.Properties.Name -contains "lastLoopResultPath") -and $saved.lastLoopResultPath -and (Test-Path -LiteralPath ([string]$saved.lastLoopResultPath))) {
        $attemptHistory.Add((Get-Content -LiteralPath ([string]$saved.lastLoopResultPath) -Raw | ConvertFrom-Json)) | Out-Null
    }
    Write-Host "Resuming codex-loop session $sessionId at attempt $startIteration."
}
elseif ($Resume) {
    Write-Host "No previous state found at $statePath. Starting a new loop."
}

if ($hasVerifier -and -not $SkipInitialCheck -and -not $Resume) {
    $precheckDir = Join-Path $runsRoot "0000-precheck"
    New-Item -ItemType Directory -Path $precheckDir -Force | Out-Null
    Write-Host "Running initial verifier check..."
    $precheck = Invoke-ProjectCommand -Command $SuccessCommand -WorkingDirectory $resolvedProject -OutputPath (Join-Path $precheckDir "verifier-output.txt")
    if ($precheck.ExitCode -eq 0) {
        Save-State -Path $statePath -State @{
            goal                 = $Goal
            successCommand       = $SuccessCommand
            project              = $resolvedProject
            sessionId            = $sessionId
            iteration            = 0
            status               = "success"
            lastRunDir           = $precheckDir
            lastVerifierExitCode = 0
            lastVerifierOutput   = Limit-Text -Text $precheck.Output
            goalPacketPath        = $goalPacketPath
            originalPromptPath    = $originalPromptPath
            approvedGoalPath      = $approvedGoalPath
            outputSchemaPath      = $outputSchemaPath
            executionMode         = $executionMode
            updatedAt            = (Get-Date).ToString("o")
        }
        Write-Host "Verifier already passes. Nothing to loop."
        exit 0
    }

    $previousVerifierOutput = $precheck.Output
}

for ($iteration = $startIteration; $iteration -lt ($startIteration + $MaxRuns); $iteration++) {
    $runName = "{0:D4}" -f $iteration
    $runDir = Join-Path $runsRoot $runName
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null

    $gitSummaryBefore = Get-GitSummary -WorkingDirectory $resolvedProject
    Save-Text -Path (Join-Path $runDir "git-before.txt") -Text $gitSummaryBefore
    $historyText = Convert-AttemptHistoryToText -History $attemptHistory -MaxChars $MaxHistoryChars

    if ($sessionId) {
        $prompt = @"
Continue the codex-loop task for this project.

Assume this prompt must stand on its own. Re-read the full mission packet and do not rely on memory from earlier turns.

$goalPacket

$jsonOutputInstructions

The previous attempt did not pass. Keep useful work, inspect the current codebase, diagnose the failure, and make another concrete attempt. The failure below is diagnostic, not a replacement for the mission packet.

Accumulated previous attempt history JSON:
$historyText

Last verifier output:
$(Limit-Text -Text $previousVerifierOutput)

Previous Codex final message:
$(Limit-Text -Text $previousCodexMessage -MaxChars 6000)

Current git summary:
$gitSummaryBefore

This attempt's logs are in:
$runDir
"@
    }
    else {
        $prompt = @"
You are running under codex-loop. Make a concrete attempt to achieve the full mission packet in this project.

Assume this prompt must stand on its own. Everything required is included here.

$goalPacket

$jsonOutputInstructions

After your changes, summarize what you changed and anything important learned in the required JSON. Do not claim success unless the mission packet's success rule is met.

Current git summary:
$gitSummaryBefore

This attempt's logs are in:
$runDir
"@
    }

    Save-Text -Path (Join-Path $runDir "prompt.md") -Text $prompt

    Write-Host ""
    Write-Host ("Attempt {0}/{1}" -f $iteration, ($startIteration + $MaxRuns - 1))
    Write-Host "-------------"
    Reset-ProgressActivity
    $codexResult = Invoke-CodexAttempt -Prompt $prompt -WorkingDirectory $resolvedProject -RunDirectory $runDir -SessionId $sessionId -NeedSkipGitRepoCheck $needSkipGitRepoCheck -OutputSchemaPath $outputSchemaPath
    Write-ProgressActivitySummary
    if ($codexResult.ThreadId) {
        $sessionId = $codexResult.ThreadId
    }

    if (Test-Path -LiteralPath $codexResult.LastMessagePath) {
        $previousCodexMessage = Get-Content -LiteralPath $codexResult.LastMessagePath -Raw
    }
    else {
        $previousCodexMessage = ""
    }

    $codexJsonResult = Convert-CodexResult -LastMessagePath $codexResult.LastMessagePath -RunDirectory $runDir

    if ($hasVerifier) {
        Write-Host "Attempt ${iteration}: running external verifier..."
        $verifier = Invoke-ProjectCommand -Command $SuccessCommand -WorkingDirectory $resolvedProject -OutputPath (Join-Path $runDir "verifier-output.txt")
        $previousVerifierOutput = $verifier.Output
    }
    else {
        $verifier = [pscustomobject]@{
            ExitCode = $null
            Output   = ""
        }
        Save-Text -Path (Join-Path $runDir "verifier-output.txt") -Text ""
        $previousVerifierOutput = ""
    }

    $gitSummaryAfter = Get-GitSummary -WorkingDirectory $resolvedProject
    Save-Text -Path (Join-Path $runDir "git-after.txt") -Text $gitSummaryAfter

    $currentDiffHash = Get-GitDiffHash -WorkingDirectory $resolvedProject
    if ($StopAfterNoChangeRuns -gt 0 -and $currentDiffHash -eq $previousDiffHash) {
        $noChangeRuns++
    }
    else {
        $noChangeRuns = 0
    }
    $previousDiffHash = $currentDiffHash

    $codexClaimStatus = Get-CodexClaimStatus -CodexResultObject $codexJsonResult.Object
    $status = if ($hasVerifier) {
        if ($verifier.ExitCode -eq 0) { "success" } else { "failure" }
    }
    else {
        if (($null -eq $codexJsonResult.ParseError) -and $codexClaimStatus -eq "success") { "success" } else { "failure" }
    }
    $decisionSource = if ($hasVerifier) { "external_verifier" } else { "codex_json_status" }
    $loopResultPath = Join-Path $runDir "loop-result.json"
    $loopResult = [ordered]@{
        actual_status             = $status
        decision_source           = $decisionSource
        codex_claim_status        = $codexClaimStatus
        has_external_verifier     = $hasVerifier
        actual_verifier_exit_code = $verifier.ExitCode
        actual_verifier_output    = Limit-Text -Text $verifier.Output
        goal                      = $Goal
        success_command           = $SuccessCommand
        codex_exit_code           = $codexResult.ExitCode
        codex_thread_id           = $sessionId
        codex_result_parse_error  = $codexJsonResult.ParseError
        codex_result              = $codexJsonResult.Object
        git_summary_after         = $gitSummaryAfter
        run_dir                   = $runDir
        updated_at                = (Get-Date).ToString("o")
    }
    $previousLoopResultJson = ($loopResult | ConvertTo-Json -Depth 16)
    Save-Text -Path $loopResultPath -Text ($previousLoopResultJson + [Environment]::NewLine)
    $attemptHistory.Add($loopResult) | Out-Null
    Save-Text -Path $historyPath -Text ((ConvertTo-Json -InputObject @($attemptHistory.ToArray()) -Depth 18) + [Environment]::NewLine)

    Save-State -Path $statePath -State @{
        goal                 = $Goal
        successCommand       = $SuccessCommand
        project              = $resolvedProject
        sessionId            = $sessionId
        iteration            = $iteration
        status               = $status
        lastRunDir           = $runDir
        lastCodexExitCode    = $codexResult.ExitCode
        lastVerifierExitCode = $verifier.ExitCode
        lastVerifierOutput   = Limit-Text -Text $verifier.Output
        goalPacketPath        = $goalPacketPath
        originalPromptPath    = $originalPromptPath
        approvedGoalPath      = $approvedGoalPath
        outputSchemaPath      = $outputSchemaPath
        historyPath           = $historyPath
        lastCodexResultPath   = $codexJsonResult.Path
        lastLoopResultPath    = $loopResultPath
        lastCodexParseError   = $codexJsonResult.ParseError
        executionMode         = $executionMode
        updatedAt            = (Get-Date).ToString("o")
    }

    if ($status -eq "success") {
        Write-HumanResult -LoopResult $loopResult -ShowJson:$ShowJsonResult -JsonText $previousLoopResultJson
        exit 0
    }

    Write-HumanResult -LoopResult $loopResult -ShowJson:$false -JsonText $null

    if ($hasVerifier) {
        Write-Host "Next: retrying because the external verifier did not pass."
    }
    else {
        Write-Host "Next: retrying because the status is '$codexClaimStatus'."
    }

    if ($StopAfterNoChangeRuns -gt 0 -and $noChangeRuns -ge $StopAfterNoChangeRuns) {
        Write-Host "Stopping because there were $noChangeRuns failed run(s) with no detected git diff change."
        exit 2
    }
}

Write-Host "Stopped after $MaxRuns Codex attempt(s); goal was not acquired."
Write-Host "State: $statePath"
if (-not [string]::IsNullOrWhiteSpace($previousLoopResultJson)) {
    if ($ShowJsonResult) {
        Write-Output $previousLoopResultJson
    }
}
exit 1
