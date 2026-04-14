# E2E parameter matrix for whisper_podlodka using WAV input
# Prerequisite: pwsh tests/start-test-orchestrator.ps1
# Run: pwsh tests/e2e/test-param-matrix.ps1

. "$PSScriptRoot\..\helpers\common.ps1"

if (-not (Test-OrchestratorRunning)) {
    throw "Test orchestrator is not running"
}

$audioFiles = @(Get-TestAudioFiles)

$cases = @(
    @{ Label = "default parameters"; Params = @{}; ExpectSegments = $true; ExpectLanguage = $null; ExpectWords = $false },
    @{ Label = "language=ru"; Params = @{ language = "ru" }; ExpectSegments = $true; ExpectLanguage = "ru"; ExpectWords = $false },
    @{ Label = "language=auto"; Params = @{ language = "auto" }; ExpectSegments = $true; ExpectLanguage = "__detected__"; ExpectWords = $false },
    @{ Label = "language=en"; Params = @{ language = "en" }; ExpectSegments = $true; ExpectLanguage = "en"; ExpectWords = $false },
    @{ Label = "timestamps=false"; Params = @{ timestamps = $false }; ExpectSegments = $false; ExpectLanguage = $null; ExpectWords = $false },
    @{ Label = "timestamps=true"; Params = @{ timestamps = $true }; ExpectSegments = $true; ExpectLanguage = $null; ExpectWords = $false },
    @{ Label = "timestamps=true, word_timestamps=false"; Params = @{ timestamps = $true; word_timestamps = $false }; ExpectSegments = $true; ExpectLanguage = $null; ExpectWords = $false },
    @{ Label = "timestamps=true, word_timestamps=true"; Params = @{ timestamps = $true; word_timestamps = $true }; ExpectSegments = $true; ExpectLanguage = $null; ExpectWords = $true },
    @{ Label = "language=ru, timestamps=true, word_timestamps=true"; Params = @{ language = "ru"; timestamps = $true; word_timestamps = $true }; ExpectSegments = $true; ExpectLanguage = "ru"; ExpectWords = $true }
)

Write-TestHeader "Audio fixtures"
Assert-GreaterThan "audio fixture count" $audioFiles.Count 0
if ($audioFiles.Count -eq 0) {
    Complete-TestRun
}

foreach ($audioPath in $audioFiles) {
    $audioLabel = Get-TestAudioLabel -AudioPath $audioPath

    foreach ($case in $cases) {
        $label = "$($case.Label) [$audioLabel]"
        $run = Invoke-TestTranscriptionFlow -Label $label -InputMethod body -AudioPath $audioPath -Params $case.Params
        if ($null -eq $run -or $null -eq $run.Result) {
            continue
        }

        $segments = @($run.Result.normalized.segments)
        if ($case.ExpectSegments) {
            Assert-GreaterThan "$label - segment count" $segments.Count 0
            $firstSegment = $segments[0]
            Assert-NotNull "$label - first segment text" $firstSegment.text
            Assert-NotNull "$label - first segment start" $firstSegment.start
            Assert-NotNull "$label - first segment end" $firstSegment.end
            Assert-IsArray "$label - words array exists" $firstSegment.words
        } else {
            Assert-Equal "$label - no segments" 0 $segments.Count
        }

        if ($case.ExpectLanguage -eq "__detected__") {
            Assert-NotNull "$label - detected language exists" $run.Result.normalized.language
        } elseif ($null -ne $case.ExpectLanguage) {
            Assert-Equal "$label - language" $case.ExpectLanguage $run.Result.normalized.language
        }

        Write-TestStep "Artifacts preserved for job [$audioLabel]: $($run.JobId)"
    }
}

Complete-TestRun


