#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptPath,

    [Parameter(Mandatory = $true)]
    [string]$ArgumentsPath,

    [Parameter(Mandatory = $true)]
    [string]$ExitCodePath
)

$ErrorActionPreference = 'Stop'
$exitCode = 0

try {
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "Workflow script was not found: $ScriptPath"
    }
    if (-not (Test-Path -LiteralPath $ArgumentsPath -PathType Leaf)) {
        throw "Workflow arguments file was not found: $ArgumentsPath"
    }

    $argumentsJson = Get-Content -LiteralPath $ArgumentsPath -Raw
    $parsedArguments = ConvertFrom-Json -InputObject $argumentsJson
    if ($parsedArguments -isnot [System.Array]) {
        throw 'Workflow arguments must be a JSON array.'
    }
    $argumentList = New-Object 'System.Collections.Generic.List[string]'
    foreach ($argument in $parsedArguments) {
        $argumentList.Add([string]$argument)
    }
    $scriptArguments = $argumentList.ToArray()
    if ($scriptArguments.Count % 2 -ne 0) {
        throw 'Workflow arguments must contain parameter-name/value pairs.'
    }
    $scriptParameters = @{}
    for ($index = 0; $index -lt $scriptArguments.Count; $index += 2) {
        $parameterName = $scriptArguments[$index]
        if ($parameterName -notmatch '^-[A-Za-z][A-Za-z0-9]*$') {
            throw "Invalid workflow parameter name: $parameterName"
        }
        $parameterName = $parameterName.Substring(1)
        if ($scriptParameters.ContainsKey($parameterName)) {
            throw "Duplicate workflow parameter: $parameterName"
        }
        $scriptParameters[$parameterName] = $scriptArguments[$index + 1]
    }
    & $ScriptPath @scriptParameters
    if (-not $?) {
        throw "Workflow script reported failure: $ScriptPath"
    }
}
catch {
    [Console]::Error.WriteLine($_.ToString())
    $exitCode = 1
}

try {
    [System.IO.File]::WriteAllText(
        $ExitCodePath,
        [string]$exitCode,
        [System.Text.UTF8Encoding]::new($false)
    )
}
catch {
    [Console]::Error.WriteLine("Failed to write workflow exit code: $($_.ToString())")
    exit 1
}

exit $exitCode
