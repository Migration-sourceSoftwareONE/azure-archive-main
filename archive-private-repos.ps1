# Script now uses environment variables instead of parameters

Import-Module Az.Accounts -Force
Import-Module Az.Storage -Force

# Get configuration from environment variables
$GitHubOrg = $env:GITHUB_ORG
$GitHubToken = $env:GITHUB_TOKEN
$StorageAccountName = $env:AZURE_STORAGE_ACCOUNT
$StorageAccountKey = $env:AZURE_STORAGE_KEY
$ContainerName = $env:CONTAINER_NAME
$RetentionDays = if ($env:RETENTION_DAYS) { [int]$env:RETENTION_DAYS } else { 60 }

# Validate required environment variables
$requiredVariables = @{
    "GITHUB_ORG" = $GitHubOrg
    "GITHUB_TOKEN" = $GitHubToken
    "AZURE_STORAGE_ACCOUNT" = $StorageAccountName
    "AZURE_STORAGE_KEY" = $StorageAccountKey
    "CONTAINER_NAME" = $ContainerName
}

foreach ($key in $requiredVariables.Keys) {
    if ([string]::IsNullOrEmpty($requiredVariables[$key])) {
        Write-Error "Required environment variable $key is not set."
        exit 1
    }
}

# Azure Storage context
$connectionString = "DefaultEndpointsProtocol=https;AccountName=$StorageAccountName;AccountKey=$StorageAccountKey;EndpointSuffix=core.windows.net"
$ctx = New-AzStorageContext -ConnectionString $connectionString

# GitHub API headers
$headers = @{ Authorization = "token $GitHubToken" }

# Get all repos from the organization
$page = 1
$repos = @()

do {
    $response = Invoke-RestMethod -Uri "https://api.github.com/orgs/$GitHubOrg/repos?per_page=100&page=$page" -Headers $headers
    $repos += $response
    $page++
} while ($response.Count -gt 0)

Write-Host "Found $($repos.Count) repositories."

foreach ($repo in $repos) {
    $repoName = $repo.name
    $cloneUrl = $repo.clone_url
    $safeName = $repoName -replace '[^a-zA-Z0-9\-]', '_'
    $tempDir = Join-Path $env:RUNNER_TEMP $safeName
    $zipPath = "$env:RUNNER_TEMP\$safeName.zip"

    Write-Host "`n==> Cloning: $repoName"
    git clone --depth 1 "https://x-access-token:$GitHubToken@github.com/$GitHubOrg/$repoName.git" $tempDir

    if (-Not (Test-Path -Path $tempDir)) {
        Write-Host "❌ Failed to clone $repoName. Skipping."
        continue
    }

    Write-Host "✅ Cloned $repoName. Creating ZIP..."
    Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
    [System.IO.Compression.ZipFile]::CreateFromDirectory($tempDir, $zipPath)

    Write-Host "📤 Uploading $safeName.zip to Azure Blob (Archive tier)..."
    Set-AzStorageBlobContent -File $zipPath `
                             -Container $ContainerName `
                             -Blob "$safeName-$(Get-Date -Format yyyyMMdd-HHmmss).zip" `
                             -Context $ctx `
                             -StandardBlobTier "Archive" `
                             -Force
}

# Implement retention policy - delete backups older than retention days
Write-Host "`n==> Cleaning up old backups (older than $RetentionDays days)..."
$cutoffDate = (Get-Date).AddDays(-$RetentionDays)
$oldBackups = Get-AzStorageBlob -Container $ContainerName -Context $ctx | Where-Object {
    $_.LastModified.DateTime -lt $cutoffDate
}

if ($oldBackups.Count -gt 0) {
    foreach ($blob in $oldBackups) {
        Write-Host "🗑️ Deleting old backup: $($blob.Name) (Last modified: $($blob.LastModified))"
        Remove-AzStorageBlob -Blob $blob.Name -Container $ContainerName -Context $ctx -Force
    }
    Write-Host "✅ Deleted $($oldBackups.Count) old backups."
} else {
    Write-Host "✅ No old backups to delete."
}
