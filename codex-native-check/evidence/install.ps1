[CmdletBinding()]
param(
    [string]$Release = $env:CODEX_RELEASE
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

if ([string]::IsNullOrWhiteSpace($Release)) {
    $Release = "latest"
}

$NonInteractive = $env:CODEX_NON_INTERACTIVE -match "^(?i:1|true|yes)$"
$DefaultPreferReleasesOpenAICom = $true
$PreferReleasesOpenAICom = if ([string]::IsNullOrWhiteSpace($env:CODEX_INSTALLER_USE_RELEASES_OPENAI_COM)) {
    $DefaultPreferReleasesOpenAICom
} else {
    $env:CODEX_INSTALLER_USE_RELEASES_OPENAI_COM -match "^(?i:1|true|yes)$"
}
$ReleasesBaseUri = "https://releases.openai.com/codex"
$ReleasesMetadataTimeoutSec = 30
$ReleasesAssetTimeoutSec = 300

function Write-Step {
    param(
        [string]$Message
    )

    Write-Host "==> $Message"
}

function Write-WarningStep {
    param(
        [string]$Message
    )

    Write-Warning $Message
}

function Prompt-YesNo {
    param(
        [string]$Prompt
    )

    if ($NonInteractive) {
        return $false
    }

    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        return $false
    }

    $choice = Read-Host "$Prompt [y/N]"
    return $choice -match "^(?i:y(?:es)?)$"
}

function Normalize-Version {
    param(
        [string]$RawVersion
    )

    if ([string]::IsNullOrWhiteSpace($RawVersion) -or $RawVersion -eq "latest") {
        return "latest"
    }

    if ($RawVersion.StartsWith("rust-v")) {
        return $RawVersion.Substring(6)
    }

    if ($RawVersion.StartsWith("v")) {
        return $RawVersion.Substring(1)
    }

    return $RawVersion
}

function Assert-ValidReleaseVersion {
    param(
        [string]$Version
    )

    if ($Version -cne "latest" -and $Version -cnotmatch "^[0-9]+\.[0-9]+\.[0-9]+(?:-alpha(?:\.[0-9]+){0,2}|-beta(?:\.[0-9]+)?)?$") {
        throw "Invalid Codex release version: $Version. Expected latest or x.y.z[-alpha[.N[.M]]|-beta[.N]]."
    }
}

function Find-ReleaseAssetMetadata {
    param(
        [string]$AssetName,
        [object]$ReleaseMetadata,
        [string]$Url = $null,
        [string]$FallbackUrl = $null
    )

    $asset = $ReleaseMetadata.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
    if ($null -eq $asset) {
        return $null
    }

    $digestMatch = [regex]::Match([string]$asset.digest, "^sha256:([0-9a-fA-F]{64})$")
    if (-not $digestMatch.Success) {
        throw "Could not find SHA-256 digest for release asset $AssetName."
    }

    return [PSCustomObject]@{
        Url = if ([string]::IsNullOrWhiteSpace($Url)) { $asset.browser_download_url } else { $Url }
        FallbackUrl = $FallbackUrl
        Sha256 = $digestMatch.Groups[1].Value.ToLowerInvariant()
    }
}

function Invoke-WebRequestWithFallback {
    param(
        [object]$Metadata,
        [string]$OutFile,
        [string]$ExpectedDigest,
        [string]$AssetName,
        [string]$ReleaseVersion,
        [string]$RequiredManifestAsset
    )

    try {
        if ($Metadata.Url.StartsWith("$ReleasesBaseUri/", [System.StringComparison]::OrdinalIgnoreCase)) {
            Invoke-WebRequest -UseBasicParsing -Uri $Metadata.Url -OutFile $OutFile -TimeoutSec $ReleasesAssetTimeoutSec
        } else {
            Invoke-WebRequest -UseBasicParsing -Uri $Metadata.Url -OutFile $OutFile
        }
        Test-ArchiveDigest -ArchivePath $OutFile -ExpectedDigest $ExpectedDigest
        if (-not [string]::IsNullOrWhiteSpace($RequiredManifestAsset)) {
            $null = Get-PackageArchiveDigest -ManifestPath $OutFile -AssetName $RequiredManifestAsset
        }
    } catch {
        if ([string]::IsNullOrWhiteSpace($Metadata.FallbackUrl)) {
            throw
        }
        Write-WarningStep "Could not download or verify $($Metadata.Url); retrying from GitHub Releases."
        Invoke-WebRequest -UseBasicParsing -Uri $Metadata.FallbackUrl -OutFile $OutFile
        try {
            Test-ArchiveDigest -ArchivePath $OutFile -ExpectedDigest $ExpectedDigest
            if (-not [string]::IsNullOrWhiteSpace($RequiredManifestAsset)) {
                $null = Get-PackageArchiveDigest -ManifestPath $OutFile -AssetName $RequiredManifestAsset
            }
        } catch {
            $githubRelease = Resolve-ReleaseFromGitHub -NormalizedVersion $ReleaseVersion
            $githubAssetMetadata = Find-ReleaseAssetMetadata -AssetName $AssetName -ReleaseMetadata $githubRelease.Metadata
            if ($null -eq $githubAssetMetadata) {
                throw "Could not find GitHub release metadata for asset $AssetName."
            }
            Test-ArchiveDigest -ArchivePath $OutFile -ExpectedDigest $githubAssetMetadata.Sha256
            if (-not [string]::IsNullOrWhiteSpace($RequiredManifestAsset)) {
                $null = Get-PackageArchiveDigest -ManifestPath $OutFile -AssetName $RequiredManifestAsset
            }
        }
    }
}

function Resolve-ReleaseAssetSelection {
    param(
        [object]$ResolvedRelease,
        [string]$Target,
        [string]$NpmTag
    )

    $version = $ResolvedRelease.Version
    $releaseMetadata = $ResolvedRelease.Metadata
    $packageAsset = "codex-package-$Target.tar.gz"
    $checksumAsset = "codex-package_SHA256SUMS"
    $packageUrl = $null
    $packageFallbackUrl = $null
    $checksumUrl = $null
    $checksumFallbackUrl = $null
    if ($ResolvedRelease.Source -eq "ReleasesOpenAICom") {
        $packageUrl = "$ReleasesBaseUri/releases/$version/$packageAsset"
        $packageFallbackUrl = "https://github.com/openai/codex/releases/download/rust-v$version/$packageAsset"
        $checksumUrl = "$ReleasesBaseUri/releases/$version/$checksumAsset"
        $checksumFallbackUrl = "https://github.com/openai/codex/releases/download/rust-v$version/$checksumAsset"
    }

    $packageMetadata = Find-ReleaseAssetMetadata -AssetName $packageAsset -ReleaseMetadata $releaseMetadata -Url $packageUrl -FallbackUrl $packageFallbackUrl
    $checksumMetadata = Find-ReleaseAssetMetadata -AssetName $checksumAsset -ReleaseMetadata $releaseMetadata -Url $checksumUrl -FallbackUrl $checksumFallbackUrl
    if ($null -ne $packageMetadata -and $null -ne $checksumMetadata) {
        return [PSCustomObject]@{
            PackageAsset = $packageAsset
            PackageMetadata = $packageMetadata
            ChecksumMetadata = $checksumMetadata
            InstallLayout = "Package"
        }
    }

    $packageAsset = "codex-npm-$NpmTag-$version.tgz"
    $packageUrl = $null
    $packageFallbackUrl = $null
    if ($ResolvedRelease.Source -eq "ReleasesOpenAICom") {
        $packageUrl = "$ReleasesBaseUri/releases/$version/$packageAsset"
        $packageFallbackUrl = "https://github.com/openai/codex/releases/download/rust-v$version/$packageAsset"
    }
    $packageMetadata = Find-ReleaseAssetMetadata -AssetName $packageAsset -ReleaseMetadata $releaseMetadata -Url $packageUrl -FallbackUrl $packageFallbackUrl
    if ($null -eq $packageMetadata) {
        throw "Could not find Codex package or platform npm release assets for Codex $version."
    }

    return [PSCustomObject]@{
        PackageAsset = $packageAsset
        PackageMetadata = $packageMetadata
        ChecksumMetadata = $null
        InstallLayout = "LegacyPlatformNpm"
    }
}

function Test-ArchiveDigest {
    param(
        [string]$ArchivePath,
        [string]$ExpectedDigest
    )

    # A native launcher can pass PowerShell 7 module paths to Windows PowerShell,
    # preventing Get-FileHash from loading. Hash directly without module lookup.
    $providerPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ArchivePath)
    $sha256 = [System.Security.Cryptography.SHA256CryptoServiceProvider]::new()
    try {
        $stream = [System.IO.File]::OpenRead($providerPath)
        try {
            $actualDigest = [System.BitConverter]::ToString($sha256.ComputeHash($stream)).Replace("-", "").ToLowerInvariant()
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha256.Dispose()
    }

    if ($actualDigest -ne $ExpectedDigest) {
        throw "Downloaded Codex archive checksum did not match expected digest. Expected $ExpectedDigest but got $actualDigest."
    }
}

function Get-PackageArchiveDigest {
    param(
        [string]$ManifestPath,
        [string]$AssetName
    )

    $escapedAssetName = [regex]::Escape($AssetName)
    foreach ($line in Get-Content -LiteralPath $ManifestPath) {
        $match = [regex]::Match($line, "^\s*([0-9a-fA-F]{64})\s+$escapedAssetName\s*$")
        if ($match.Success) {
            return $match.Groups[1].Value.ToLowerInvariant()
        }
    }

    throw "Could not find SHA-256 digest for $AssetName in codex-package_SHA256SUMS."
}

function Path-Contains {
    param(
        [string]$PathValue,
        [string]$Entry
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $false
    }

    $needle = $Entry.TrimEnd("\")
    foreach ($segment in $PathValue.Split(";", [System.StringSplitOptions]::RemoveEmptyEntries)) {
        if ($segment.TrimEnd("\") -ieq $needle) {
            return $true
        }
    }

    return $false
}

function Prepend-PathEntry {
    param(
        [string]$PathValue,
        [string]$Entry
    )

    $needle = $Entry.TrimEnd("\")
    $segments = @($Entry)
    if (-not [string]::IsNullOrWhiteSpace($PathValue)) {
        $segments += $PathValue.Split(";", [System.StringSplitOptions]::RemoveEmptyEntries) |
            Where-Object { $_.TrimEnd("\") -ine $needle }
    }

    return ($segments -join ";")
}

function Invoke-WithInstallLock {
    param(
        [string]$LockPath,
        [scriptblock]$Script
    )

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LockPath) | Out-Null
    $lock = $null
    while ($null -eq $lock) {
        try {
            $lock = [System.IO.File]::Open(
                $LockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 250
        }
    }
    try {
        & $Script
    } finally {
        $lock.Dispose()
    }
}

function Remove-StaleInstallArtifacts {
    param(
        [string]$ReleasesDir
    )

    if (Test-Path -LiteralPath $ReleasesDir -PathType Container) {
        Get-ChildItem -LiteralPath $ReleasesDir -Force -Directory -Filter ".staging.*" -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-VersionFromReleaseMetadata {
    param(
        [object]$ReleaseMetadata
    )

    if (-not $ReleaseMetadata.tag_name) {
        throw "Failed to resolve the latest Codex release version."
    }

    $resolvedVersion = Normalize-Version -RawVersion $ReleaseMetadata.tag_name
    Assert-ValidReleaseVersion -Version $resolvedVersion
    return $resolvedVersion
}

function Resolve-ReleaseFromGitHub {
    param(
        [string]$NormalizedVersion
    )

    if ($NormalizedVersion -eq "latest") {
        $requestedRelease = "latest"
        $metadataUri = "https://api.github.com/repos/openai/codex/releases/latest"
    } else {
        $resolvedVersion = $NormalizedVersion
        $requestedRelease = $resolvedVersion
        $metadataUri = "https://api.github.com/repos/openai/codex/releases/tags/rust-v$resolvedVersion"
    }

    try {
        $releaseMetadata = Invoke-RestMethod -Uri $metadataUri
    } catch {
        throw "Could not fetch GitHub release metadata for Codex $requestedRelease. GitHub API may be unavailable or rate limited. $($_.Exception.Message)"
    }

    if ($NormalizedVersion -eq "latest") {
        $resolvedVersion = Resolve-VersionFromReleaseMetadata -ReleaseMetadata $releaseMetadata
    }

    return [PSCustomObject]@{
        Version = $resolvedVersion
        Metadata = $releaseMetadata
        Source = "GitHub"
    }
}

function Resolve-ReleaseFromReleases {
    param(
        [string]$NormalizedVersion
    )

    $metadataUri = if ($NormalizedVersion -eq "latest") {
        "$ReleasesBaseUri/channels/latest"
    } else {
        "$ReleasesBaseUri/releases/$NormalizedVersion/release.json"
    }
    try {
        $metadataResponse = Invoke-WebRequest -UseBasicParsing -Uri $metadataUri -TimeoutSec $ReleasesMetadataTimeoutSec
        $releaseMetadata = [string]$metadataResponse.Content | ConvertFrom-Json -ErrorAction Stop
        $resolvedVersion = Resolve-VersionFromReleaseMetadata -ReleaseMetadata $releaseMetadata
        if ($NormalizedVersion -ne "latest" -and $resolvedVersion -cne $NormalizedVersion) {
            throw "Release metadata version did not match requested Codex version $NormalizedVersion."
        }
        $resolvedRelease = [PSCustomObject]@{
            Version = $resolvedVersion
            Metadata = $releaseMetadata
            Source = "ReleasesOpenAICom"
        }
        $null = Resolve-ReleaseAssetSelection -ResolvedRelease $resolvedRelease -Target $target -NpmTag $npmTag
    } catch {
        return $null
    }
    return $resolvedRelease
}

function Resolve-Release {
    $normalizedVersion = Normalize-Version -RawVersion $Release
    Assert-ValidReleaseVersion -Version $normalizedVersion

    if ($PreferReleasesOpenAICom) {
        $release = Resolve-ReleaseFromReleases -NormalizedVersion $normalizedVersion
        if ($null -ne $release) {
            return $release
        }
        Write-WarningStep "releases.openai.com is unavailable; falling back to GitHub Releases."
    }

    return Resolve-ReleaseFromGitHub -NormalizedVersion $normalizedVersion
}

function Get-VersionFromBinary {
    param(
        [string]$CodexPath
    )

    if (-not (Test-Path -LiteralPath $CodexPath -PathType Leaf)) {
        return $null
    }

    try {
        $versionOutput = & $CodexPath --version 2>$null
    } catch {
        return $null
    }

    if ($versionOutput -match '([0-9][0-9A-Za-z.+-]*)$') {
        return $matches[1]
    }

    return $null
}

function Get-CurrentInstalledVersion {
    param(
        [string]$StandaloneCurrentDir
    )

    $standaloneVersion = Get-VersionFromBinary -CodexPath (Join-Path $StandaloneCurrentDir "bin\codex.exe")
    if (-not [string]::IsNullOrWhiteSpace($standaloneVersion)) {
        return $standaloneVersion
    }

    $standaloneVersion = Get-VersionFromBinary -CodexPath (Join-Path $StandaloneCurrentDir "codex.exe")
    if (-not [string]::IsNullOrWhiteSpace($standaloneVersion)) {
        return $standaloneVersion
    }

    return $null
}

function Test-OldStandaloneBinLayout {
    param(
        [string]$VisibleBinDir,
        [string]$DefaultVisibleBinDir
    )

    if (-not $VisibleBinDir.Equals($DefaultVisibleBinDir, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $VisibleBinDir -PathType Container)) {
        return $false
    }

    $item = Get-Item -LiteralPath $VisibleBinDir -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        return $false
    }

    $requiredFiles = @("codex.exe", "rg.exe")
    foreach ($fileName in $requiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $VisibleBinDir $fileName) -PathType Leaf)) {
            return $false
        }
    }

    $knownFiles = @(
        "codex.exe",
        "rg.exe",
        "codex-command-runner.exe",
        "codex-windows-sandbox.exe",
        "codex-windows-sandbox-setup.exe"
    )
    foreach ($child in Get-ChildItem -LiteralPath $VisibleBinDir -Force) {
        if ($child.PSIsContainer) {
            return $false
        }
        if ($knownFiles -notcontains $child.Name) {
            return $false
        }
    }

    return $true
}

function Move-OldStandaloneBinIfApproved {
    param(
        [string]$VisibleBinDir,
        [string]$DefaultVisibleBinDir
    )

    if (-not (Test-OldStandaloneBinLayout -VisibleBinDir $VisibleBinDir -DefaultVisibleBinDir $DefaultVisibleBinDir)) {
        return $null
    }

    Write-Step "We found an older Codex install at $VisibleBinDir"
    Write-WarningStep "To continue, Codex needs to update the install at this path."
    if (-not (Prompt-YesNo "Replace it with the current Codex setup now?")) {
        throw "Cannot replace older standalone install without confirmation: $VisibleBinDir"
    }

    $backupDir = "$VisibleBinDir.backup.$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()).$PID"
    Write-Step "Moving older standalone install to $backupDir"
    Move-Item -LiteralPath $VisibleBinDir -Destination $backupDir
    return $backupDir
}

function Add-JunctionSupportType {
    # Older installer types remain loaded when users rerun irm | iex in one session.
    if (([System.Management.Automation.PSTypeName]'CodexInstaller.JunctionV2').Type) {
        return
    }

    Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace CodexInstaller
{
    public static class JunctionV2
    {
        private const uint GENERIC_WRITE = 0x40000000;
        private const uint FILE_SHARE_READ = 0x00000001;
        private const uint FILE_SHARE_WRITE = 0x00000002;
        private const uint FILE_SHARE_DELETE = 0x00000004;
        private const uint OPEN_EXISTING = 3;
        private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        private const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
        private const uint FSCTL_SET_REPARSE_POINT = 0x000900A4;
        private const uint IO_REPARSE_TAG_MOUNT_POINT = 0xA0000003;
        private const int HeaderLength = 20;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string lpFileName,
            uint dwDesiredAccess,
            uint dwShareMode,
            IntPtr lpSecurityAttributes,
            uint dwCreationDisposition,
            uint dwFlagsAndAttributes,
            IntPtr hTemplateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeviceIoControl(
            SafeFileHandle hDevice,
            uint dwIoControlCode,
            byte[] lpInBuffer,
            int nInBufferSize,
            IntPtr lpOutBuffer,
            int nOutBufferSize,
            out int lpBytesReturned,
            IntPtr lpOverlapped);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(
            SafeFileHandle file, StringBuilder path, uint length, uint flags);

        public static string ResolveDirectory(string path)
        {
            using (SafeFileHandle handle = CreateFileW(
                path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero))
            {
                if (handle.IsInvalid) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
                StringBuilder resolved = new StringBuilder(32768);
                uint length = GetFinalPathNameByHandleW(handle, resolved, (uint)resolved.Capacity, 0);
                if (length == 0) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
                if (length >= resolved.Capacity) { throw new IOException("Resolved path is too long."); }
                return resolved.ToString().TrimEnd('\\');
            }
        }

        public static void SetTarget(string linkPath, string targetPath)
        {
            string substituteName = "\\??\\" + Path.GetFullPath(targetPath);
            byte[] substituteNameBytes = Encoding.Unicode.GetBytes(substituteName);
            if (substituteNameBytes.Length > ushort.MaxValue - HeaderLength) {
                throw new ArgumentException("Junction target path is too long.", "targetPath");
            }

            byte[] reparseBuffer = new byte[substituteNameBytes.Length + HeaderLength];
            WriteUInt32(reparseBuffer, 0, IO_REPARSE_TAG_MOUNT_POINT);
            WriteUInt16(reparseBuffer, 4, checked((ushort)(substituteNameBytes.Length + 12)));
            WriteUInt16(reparseBuffer, 8, 0);
            WriteUInt16(reparseBuffer, 10, checked((ushort)substituteNameBytes.Length));
            WriteUInt16(reparseBuffer, 12, checked((ushort)(substituteNameBytes.Length + 2)));
            WriteUInt16(reparseBuffer, 14, 0);
            Buffer.BlockCopy(substituteNameBytes, 0, reparseBuffer, 16, substituteNameBytes.Length);

            using (SafeFileHandle handle = CreateFileW(
                linkPath,
                GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                IntPtr.Zero,
                OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
                IntPtr.Zero))
            {
                if (handle.IsInvalid) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }

                int bytesReturned;
                if (!DeviceIoControl(
                    handle,
                    FSCTL_SET_REPARSE_POINT,
                    reparseBuffer,
                    reparseBuffer.Length,
                    IntPtr.Zero,
                    0,
                    out bytesReturned,
                    IntPtr.Zero))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            }
        }

        private static void WriteUInt16(byte[] buffer, int offset, ushort value)
        {
            buffer[offset] = (byte)value;
            buffer[offset + 1] = (byte)(value >> 8);
        }

        private static void WriteUInt32(byte[] buffer, int offset, uint value)
        {
            buffer[offset] = (byte)value;
            buffer[offset + 1] = (byte)(value >> 8);
            buffer[offset + 2] = (byte)(value >> 16);
            buffer[offset + 3] = (byte)(value >> 24);
        }
    }
}
"@
}

function Set-JunctionTarget {
    param(
        [string]$LinkPath,
        [string]$TargetPath
    )

    Add-JunctionSupportType
    [CodexInstaller.JunctionV2]::SetTarget($LinkPath, $TargetPath)
}

function Test-IsJunction {
    param(
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $item = Get-Item -LiteralPath $Path -Force
    return ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $item.LinkType -eq "Junction"
}

function Ensure-Junction {
    param(
        [string]$LinkPath,
        [string]$TargetPath,
        [string]$InstallerOwnedTargetPrefix
    )

    if (-not (Test-Path -LiteralPath $LinkPath)) {
        New-Item -ItemType Junction -Path $LinkPath -Target $TargetPath | Out-Null
        return
    }

    $item = Get-Item -LiteralPath $LinkPath -Force
    if (Test-IsJunction -Path $LinkPath) {
        Add-JunctionSupportType
        $existingTarget = [CodexInstaller.JunctionV2]::ResolveDirectory($LinkPath)
        if (-not [string]::IsNullOrWhiteSpace($InstallerOwnedTargetPrefix)) {
            $ownedTargetPrefix = [CodexInstaller.JunctionV2]::ResolveDirectory($InstallerOwnedTargetPrefix) + "\"
            if (-not $existingTarget.StartsWith($ownedTargetPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing to retarget junction at $LinkPath because it is not managed by this installer."
            }
        }
        if ($existingTarget.Equals([CodexInstaller.JunctionV2]::ResolveDirectory($TargetPath), [System.StringComparison]::OrdinalIgnoreCase)) {
            return
        }

        # Keep the path itself in place and only retarget the junction. That
        # avoids a gap where current or the visible bin path disappears during
        # an update.
        Set-JunctionTarget -LinkPath $LinkPath -TargetPath $TargetPath
        return
    }

    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Refusing to replace non-junction reparse point at $LinkPath."
    }

    if ($item.PSIsContainer) {
        if ((Get-ChildItem -LiteralPath $LinkPath -Force | Select-Object -First 1) -ne $null) {
            throw "Refusing to replace non-empty directory at $LinkPath with a junction."
        }

        Remove-Item -LiteralPath $LinkPath -Force
        New-Item -ItemType Junction -Path $LinkPath -Target $TargetPath | Out-Null
        return
    }

    throw "Refusing to replace file at $LinkPath with a junction."
}

function Test-PackageContentsAreComplete {
    param(
        [string]$PackageDir
    )

    if (-not (Test-Path -LiteralPath $PackageDir -PathType Container)) {
        return $false
    }

    $expectedFiles = @(
        "codex-package.json",
        "bin\codex.exe",
        "bin\codex-code-mode-host.exe",
        "codex-path\rg.exe",
        "codex-resources\codex-command-runner.exe",
        "codex-resources\codex-windows-sandbox-setup.exe"
    )
    foreach ($name in $expectedFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $PackageDir $name) -PathType Leaf)) {
            return $false
        }
    }

    return $true
}

function Test-LegacyPlatformNpmContentsAreComplete {
    param(
        [string]$PackageDir
    )

    if (-not (Test-Path -LiteralPath $PackageDir -PathType Container)) {
        return $false
    }

    $expectedFiles = @(
        "codex.exe",
        "codex-resources\codex-command-runner.exe",
        "codex-resources\codex-windows-sandbox-setup.exe",
        "codex-resources\rg.exe"
    )
    foreach ($name in $expectedFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $PackageDir $name) -PathType Leaf)) {
            return $false
        }
    }

    return $true
}

function Test-ReleaseIsComplete {
    param(
        [string]$ReleaseDir,
        [string]$ExpectedVersion,
        [string]$ExpectedTarget,
        [string]$Layout
    )

    switch ($Layout) {
        "Package" {
            if (-not (Test-PackageContentsAreComplete -PackageDir $ReleaseDir)) {
                return $false
            }
            $codexPath = Join-Path $ReleaseDir "bin\codex.exe"
        }
        "LegacyPlatformNpm" {
            if (-not (Test-LegacyPlatformNpmContentsAreComplete -PackageDir $ReleaseDir)) {
                return $false
            }
            $codexPath = Join-Path $ReleaseDir "codex.exe"
        }
        default {
            throw "Unknown Codex installer layout: $Layout"
        }
    }

    return (Split-Path -Leaf $ReleaseDir) -eq "$ExpectedVersion-$ExpectedTarget" -and
        (Get-VersionFromBinary -CodexPath $codexPath) -ceq $ExpectedVersion
}

function Get-ExistingCodexCommand {
    $existing = Get-Command codex -ErrorAction SilentlyContinue
    if ($null -eq $existing) {
        return $null
    }

    return $existing.Source
}

function Get-ExistingCodexManager {
    param(
        [string]$ExistingPath,
        [string]$VisibleBinDir
    )

    if ([string]::IsNullOrWhiteSpace($ExistingPath)) {
        return $null
    }

    if ($ExistingPath.StartsWith($VisibleBinDir, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    if ($ExistingPath -match "\\.bun\\") {
        return "bun"
    }

    if ($ExistingPath -match "node_modules" -or $ExistingPath -match "\\npm\\") {
        return "npm"
    }

    return $null
}

function Get-ConflictingInstall {
    param(
        [string]$VisibleBinDir
    )

    $existingPath = Get-ExistingCodexCommand
    $manager = Get-ExistingCodexManager -ExistingPath $existingPath -VisibleBinDir $VisibleBinDir
    if ($null -eq $manager) {
        return $null
    }

    Write-Step "Detected existing $manager-managed Codex at $existingPath"
    Write-WarningStep "Multiple managed Codex installs can be ambiguous because PATH order decides which one runs."

    return [PSCustomObject]@{
        Manager = $manager
        Path = $existingPath
    }
}

function Maybe-HandleConflictingInstall {
    param(
        [object]$Conflict
    )

    if ($null -eq $Conflict) {
        return
    }

    $manager = $Conflict.Manager

    $uninstallArgs = if ($manager -eq "bun") {
        @("remove", "-g", "@openai/codex")
    } else {
        @("uninstall", "-g", "@openai/codex")
    }
    $uninstallCommand = if ($manager -eq "bun") { "bun" } else { "npm" }

    if (Prompt-YesNo "Uninstall the existing $manager-managed Codex now?") {
        Write-Step "Running: $uninstallCommand $($uninstallArgs -join ' ')"
        try {
            & $uninstallCommand @uninstallArgs
        } catch {
            Write-WarningStep "Failed to uninstall the existing $manager-managed Codex. Continuing with the standalone install."
        }
    } else {
        Write-WarningStep "Leaving the existing $manager-managed Codex installed. PATH order will determine which codex runs."
    }
}

function Test-VisibleCodexCommand {
    param(
        [string]$VisibleBinDir
    )

    $codexCommand = Join-Path $VisibleBinDir "codex.exe"
    & $codexCommand --version *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Installed Codex command failed verification: $codexCommand --version"
    }
}

if ($env:OS -ne "Windows_NT") {
    Write-Error "install.ps1 supports Windows only. Use install.sh on macOS or Linux."
    exit 1
}

if (-not [Environment]::Is64BitOperatingSystem) {
    Write-Error "Codex requires a 64-bit version of Windows."
    exit 1
}

$architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
$target = $null
$platformLabel = $null
$npmTag = $null
switch ($architecture) {
    "Arm64" {
        $target = "aarch64-pc-windows-msvc"
        $platformLabel = "Windows (ARM64)"
        $npmTag = "win32-arm64"
    }
    "X64" {
        $target = "x86_64-pc-windows-msvc"
        $platformLabel = "Windows (x64)"
        $npmTag = "win32-x64"
    }
    default {
        Write-Error "Unsupported architecture: $architecture"
        exit 1
    }
}

$codexHome = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
    Join-Path $env:USERPROFILE ".codex"
} else {
    $env:CODEX_HOME
}
$daemonOnly = $env:CODEX_INSTALL_DAEMON_ONLY -eq "1"
$standaloneRoot = Join-Path $codexHome $(if ($daemonOnly) { "packages\app-server-daemon" } else { "packages\standalone" })
$releasesDir = Join-Path $standaloneRoot "releases"
$currentDir = Join-Path $standaloneRoot "current"
$deferSelection = $env:CODEX_INSTALL_DEFER_SELECTION -eq "1"
if ($deferSelection) {
    if (-not $daemonOnly) { throw "Deferred selection requires a daemon-only installation." }
    $currentDir = Join-Path $standaloneRoot ".migration-current"
}
$autoUpdateVersion = Join-Path $standaloneRoot "auto-update-version"
$lockPath = Join-Path $standaloneRoot "install.lock"

$defaultVisibleBinDir = Join-Path $env:LOCALAPPDATA "Programs\OpenAI\Codex\bin"
if ([string]::IsNullOrWhiteSpace($env:CODEX_INSTALL_DIR)) {
    $visibleBinDir = $defaultVisibleBinDir
} else {
    $visibleBinDir = $env:CODEX_INSTALL_DIR
}

$currentVersion = Get-CurrentInstalledVersion -StandaloneCurrentDir $currentDir
$resolvedRelease = Resolve-Release
$resolvedVersion = $resolvedRelease.Version
$releaseMetadata = $resolvedRelease.Metadata
$releaseName = "$resolvedVersion-$target"
$releaseDir = Join-Path $releasesDir $releaseName

if (-not [string]::IsNullOrWhiteSpace($currentVersion) -and $currentVersion -ne $resolvedVersion) {
    Write-Step "Updating Codex CLI from $currentVersion to $resolvedVersion"
} elseif (-not [string]::IsNullOrWhiteSpace($currentVersion)) {
    Write-Step "Updating Codex CLI"
} else {
    Write-Step "Installing Codex CLI"
}
Write-Step "Detected platform: $platformLabel"
Write-Step "Resolved version: $resolvedVersion"

$conflictingInstall = if ($daemonOnly) { $null } else { Get-ConflictingInstall -VisibleBinDir $visibleBinDir }
$oldStandaloneBackup = $null

$checksumAsset = "codex-package_SHA256SUMS"
$assetSelection = Resolve-ReleaseAssetSelection -ResolvedRelease $resolvedRelease -Target $target -NpmTag $npmTag
$packageAsset = $assetSelection.PackageAsset
$packageMetadata = $assetSelection.PackageMetadata
$checksumMetadata = $assetSelection.ChecksumMetadata
$installLayout = $assetSelection.InstallLayout
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-install-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
$guardRejected = $false

try {
    Invoke-WithInstallLock -LockPath $lockPath -Script {
        $updaterRecord = Join-Path $codexHome "app-server-daemon\app-server-updater.pid"
        if ($daemonOnly) { $updaterRecord = Join-Path $codexHome "app-server-daemon\daemon-updater.pid" }
        $oldUpdaterParent = $false
        if ($Release -eq "latest" -and $env:CODEX_INSTALL_IF_LATEST -ne "1" -and $env:CODEX_INSTALL_IF_CURRENT -ne "1" -and (Test-Path -LiteralPath $updaterRecord)) {
            $updaterPid = $null
            $updaterStartTime = $null
            try {
                $record = Get-Content -LiteralPath $updaterRecord -Raw | ConvertFrom-Json
                $updaterPid = [long]$record.pid
                $updaterStartTime = [string]$record.processStartTime
            } catch {
                # Empty or stale PID reservations must not block a manual install.
            }
            if ($null -ne $updaterPid -and $updaterPid -gt 0 -and -not [string]::IsNullOrEmpty($updaterStartTime)) {
                $updaterProcess = Get-Process -Id $updaterPid -ErrorAction SilentlyContinue
                if ($null -ne $updaterProcess -and $updaterStartTime -eq [string]$updaterProcess.StartTime.ToFileTimeUtc()) {
                    try {
                        $parentPid = (Get-CimInstance Win32_Process -Filter "ProcessId = $PID" -ErrorAction Stop).ParentProcessId
                        if ([long]$parentPid -le 0) { throw "Missing updater parent process." }
                    } catch {
                        try {
                            $parentPid = (Get-WmiObject Win32_Process -Filter "ProcessId = $PID" -ErrorAction Stop).ParentProcessId
                            if ([long]$parentPid -le 0) { throw "Missing updater parent process." }
                        } catch {
                            throw "Cannot verify whether the standalone installer was launched by an older updater."
                        }
                    }
                    $oldUpdaterParent = $updaterPid -eq $parentPid
                }
            }
        }
        if ($env:CODEX_INSTALL_IF_LATEST -eq "1" -or $env:CODEX_INSTALL_IF_CURRENT -eq "1" -or $oldUpdaterParent) {
            $previousRelease = if ($oldUpdaterParent -and (Test-Path -LiteralPath $autoUpdateVersion)) {
                [System.IO.File]::ReadAllText($autoUpdateVersion)
            } else {
                $env:CODEX_UPDATE_FROM_RELEASE
            }
            Add-JunctionSupportType
            $currentTarget = if (Test-Path -LiteralPath $currentDir) { (Get-Item -LiteralPath $currentDir).Target } else { $null }
            if ($Release -ne "latest" -or [string]::IsNullOrEmpty($previousRelease) -or [string]::IsNullOrEmpty($currentTarget) -or
                -not (Test-Path -LiteralPath (Join-Path $releasesDir $previousRelease)) -or
                [CodexInstaller.JunctionV2]::ResolveDirectory($currentDir) -ne [CodexInstaller.JunctionV2]::ResolveDirectory((Join-Path $releasesDir $previousRelease))) {
                if ($env:CODEX_INSTALL_IF_CURRENT -eq "1") { throw "Daemon selection changed; retry the update." }
                $script:guardRejected = $true
                return
            }
            # Explicit daemon updates may leave a local or pinned release.
            if ($env:CODEX_INSTALL_IF_CURRENT -ne "1" -and
                (-not (Test-Path -LiteralPath $autoUpdateVersion) -or
                [System.IO.File]::ReadAllText($autoUpdateVersion) -cne $previousRelease)) {
                $script:guardRejected = $true
                return
            }
        }
        Remove-StaleInstallArtifacts -ReleasesDir $releasesDir

        if (-not (Test-ReleaseIsComplete -ReleaseDir $releaseDir -ExpectedVersion $resolvedVersion -ExpectedTarget $target -Layout $installLayout)) {
            if (Test-Path -LiteralPath $releaseDir) {
                if ($daemonOnly) { throw "Refusing to overwrite existing daemon release $releaseDir." }
                Write-WarningStep "Found incomplete existing release at $releaseDir. Reinstalling."
            }

            $archivePath = Join-Path $tempDir $packageAsset
            $checksumPath = Join-Path $tempDir $checksumAsset
            $stagingDir = Join-Path $releasesDir ".staging.$releaseName.$PID"

            Write-Step "Downloading Codex CLI"
            if ($installLayout -eq "Package") {
                Invoke-WebRequestWithFallback -Metadata $checksumMetadata -OutFile $checksumPath -ExpectedDigest $checksumMetadata.Sha256 -AssetName $checksumAsset -ReleaseVersion $resolvedVersion -RequiredManifestAsset $packageAsset
                $expectedPackageDigest = Get-PackageArchiveDigest -ManifestPath $checksumPath -AssetName $packageAsset
            } else {
                $expectedPackageDigest = $packageMetadata.Sha256
            }
            Invoke-WebRequestWithFallback -Metadata $packageMetadata -OutFile $archivePath -ExpectedDigest $expectedPackageDigest -AssetName $packageAsset -ReleaseVersion $resolvedVersion

            New-Item -ItemType Directory -Force -Path $releasesDir | Out-Null
            if (Test-Path -LiteralPath $stagingDir) {
                Remove-Item -LiteralPath $stagingDir -Recurse -Force
            }
            New-Item -ItemType Directory -Force -Path $stagingDir | Out-Null
            if ($installLayout -eq "Package") {
                tar -xzf $archivePath -C $stagingDir
                if (-not (Test-PackageContentsAreComplete -PackageDir $stagingDir)) {
                    throw "Downloaded Codex package archive did not contain the expected package layout."
                }
            } else {
                $extractDir = Join-Path $tempDir "extract"
                New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
                tar -xzf $archivePath -C $extractDir

                $vendorRoot = Join-Path $extractDir "package/vendor/$target"
                $resourcesDir = Join-Path $stagingDir "codex-resources"
                New-Item -ItemType Directory -Force -Path $resourcesDir | Out-Null
                $copyMap = @{
                    "codex/codex.exe" = "codex.exe"
                    "codex/codex-command-runner.exe" = "codex-resources\codex-command-runner.exe"
                    "codex/codex-windows-sandbox-setup.exe" = "codex-resources\codex-windows-sandbox-setup.exe"
                    "path/rg.exe" = "codex-resources\rg.exe"
                }

                foreach ($relativeSource in $copyMap.Keys) {
                    Copy-Item -LiteralPath (Join-Path $vendorRoot $relativeSource) -Destination (Join-Path $stagingDir $copyMap[$relativeSource])
                }

                if (-not (Test-LegacyPlatformNpmContentsAreComplete -PackageDir $stagingDir)) {
                    throw "Downloaded Codex npm archive did not contain the expected legacy platform package layout."
                }
            }

            if (Test-Path -LiteralPath $releaseDir) {
                Remove-Item -LiteralPath $releaseDir -Recurse -Force
            }
            Move-Item -LiteralPath $stagingDir -Destination $releaseDir
        }

        if (-not (Test-ReleaseIsComplete -ReleaseDir $releaseDir -ExpectedVersion $resolvedVersion -ExpectedTarget $target -Layout $installLayout)) {
            throw "Installed Codex command did not report expected version $resolvedVersion."
        }

        New-Item -ItemType Directory -Force -Path $standaloneRoot | Out-Null
        if ($deferSelection -and (Get-Item -LiteralPath (Join-Path $standaloneRoot "current") -Force -ErrorAction SilentlyContinue)) {
            throw "A dedicated daemon is already selected; retry the update."
        }
        if ($daemonOnly -and -not $deferSelection) {
            $installedCodex = Join-Path $releaseDir $(if ($installLayout -eq "Package") { "bin\codex.exe" } else { "codex.exe" })
            & $installedCodex app-server daemon pid-update-loop --check-package-ownership | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "The production release does not support daemon-owned packages; the current selection was left unchanged."
            }
        }
        Ensure-Junction -LinkPath $currentDir -TargetPath $releaseDir -InstallerOwnedTargetPrefix $releasesDir
        if ($Release -eq "latest") {
            $tempMarker = "$autoUpdateVersion.tmp.$PID"
            [System.IO.File]::WriteAllText($tempMarker, $releaseName)
            Move-Item -LiteralPath $tempMarker -Destination $autoUpdateVersion -Force
        } else {
            if (Test-Path -LiteralPath $autoUpdateVersion) {
                Remove-Item -LiteralPath $autoUpdateVersion -Force -ErrorAction Stop
            }
        }

        if ($daemonOnly) { return }
        $visibleParent = Split-Path -Parent $visibleBinDir
        $currentBinDir = if ($installLayout -eq "Package") {
            Join-Path $currentDir "bin"
        } else {
            $currentDir
        }
        New-Item -ItemType Directory -Force -Path $visibleParent | Out-Null
        $oldStandaloneBackup = Move-OldStandaloneBinIfApproved -VisibleBinDir $visibleBinDir -DefaultVisibleBinDir $defaultVisibleBinDir
        try {
            Ensure-Junction -LinkPath $visibleBinDir -TargetPath $currentBinDir -InstallerOwnedTargetPrefix $standaloneRoot
            Test-VisibleCodexCommand -VisibleBinDir $visibleBinDir
        } catch {
            if ($null -ne $oldStandaloneBackup -and (Test-Path -LiteralPath $oldStandaloneBackup)) {
                if (Test-Path -LiteralPath $visibleBinDir) {
                    Remove-Item -LiteralPath $visibleBinDir -Recurse -Force
                }
                Move-Item -LiteralPath $oldStandaloneBackup -Destination $visibleBinDir
            }
            throw
        }
        if ($null -ne $oldStandaloneBackup) {
            Remove-Item -LiteralPath $oldStandaloneBackup -Recurse -Force
        }
    }
} finally {
    Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
}
if ($guardRejected -or $daemonOnly) { return }

Maybe-HandleConflictingInstall -Conflict $conflictingInstall

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$prioritizeVisibleBin = $null -ne $conflictingInstall
if ($prioritizeVisibleBin) {
    $newUserPath = Prepend-PathEntry -PathValue $userPath -Entry $visibleBinDir
    if ($newUserPath -cne $userPath) {
        [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
        Write-Step "PATH updated for future PowerShell sessions."
    } else {
        Write-Step "$visibleBinDir is already first on PATH."
    }
} elseif (-not (Path-Contains -PathValue $userPath -Entry $visibleBinDir)) {
    if ([string]::IsNullOrWhiteSpace($userPath)) {
        $newUserPath = $visibleBinDir
    } else {
        $newUserPath = "$visibleBinDir;$userPath"
    }

    [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
    Write-Step "PATH updated for future PowerShell sessions."
} elseif (Path-Contains -PathValue $env:Path -Entry $visibleBinDir) {
    Write-Step "$visibleBinDir is already on PATH."
} else {
    Write-Step "PATH is already configured for future PowerShell sessions."
}

if ($prioritizeVisibleBin) {
    $env:Path = Prepend-PathEntry -PathValue $env:Path -Entry $visibleBinDir
} elseif (-not (Path-Contains -PathValue $env:Path -Entry $visibleBinDir)) {
    if ([string]::IsNullOrWhiteSpace($env:Path)) {
        $env:Path = $visibleBinDir
    } else {
        $env:Path = "$visibleBinDir;$env:Path"
    }
}

Write-Step "Current PowerShell session: codex"
Write-Step "Future PowerShell windows: open a new PowerShell window and run: codex"
Write-Host "Codex CLI $resolvedVersion installed successfully."

$codexCommand = Join-Path $visibleBinDir "codex.exe"
if (Prompt-YesNo "Start Codex now?") {
    Write-Step "Launching Codex"
    & $codexCommand
}

# SIG # Begin signature block
# MII9OgYJKoZIhvcNAQcCoII9KzCCPScCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA5iGIoT9ge3fQl
# XDplZ+geg8Ja/Qy8xGJG0bMk5hb7b6CCIgAwggXMMIIDtKADAgECAhBUmNLR1FsZ
# lUgTecgRwIeZMA0GCSqGSIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQK
# ExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVu
# dGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAy
# MDAeFw0yMDA0MTYxODM2MTZaFw00NTA0MTYxODQ0NDBaMHcxCzAJBgNVBAYTAlVT
# MR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xSDBGBgNVBAMTP01pY3Jv
# c29mdCBJZGVudGl0eSBWZXJpZmljYXRpb24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRo
# b3JpdHkgMjAyMDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALORKgeD
# Bmf9np3gx8C3pOZCBH8Ppttf+9Va10Wg+3cL8IDzpm1aTXlT2KCGhFdFIMeiVPvH
# or+Kx24186IVxC9O40qFlkkN/76Z2BT2vCcH7kKbK/ULkgbk/WkTZaiRcvKYhOuD
# PQ7k13ESSCHLDe32R0m3m/nJxxe2hE//uKya13NnSYXjhr03QNAlhtTetcJtYmrV
# qXi8LW9J+eVsFBT9FMfTZRY33stuvF4pjf1imxUs1gXmuYkyM6Nix9fWUmcIxC70
# ViueC4fM7Ke0pqrrBc0ZV6U6CwQnHJFnni1iLS8evtrAIMsEGcoz+4m+mOJyoHI1
# vnnhnINv5G0Xb5DzPQCGdTiO0OBJmrvb0/gwytVXiGhNctO/bX9x2P29Da6SZEi3
# W295JrXNm5UhhNHvDzI9e1eM80UHTHzgXhgONXaLbZ7LNnSrBfjgc10yVpRnlyUK
# xjU9lJfnwUSLgP3B+PR0GeUw9gb7IVc+BhyLaxWGJ0l7gpPKWeh1R+g/OPTHU3mg
# trTiXFHvvV84wRPmeAyVWi7FQFkozA8kwOy6CXcjmTimthzax7ogttc32H83rwjj
# O3HbbnMbfZlysOSGM1l0tRYAe1BtxoYT2v3EOYI9JACaYNq6lMAFUSw0rFCZE4e7
# swWAsk0wAly4JoNdtGNz764jlU9gKL431VulAgMBAAGjVDBSMA4GA1UdDwEB/wQE
# AwIBhjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBTIftJqhSobyhmYBAcnz1AQ
# T2ioojAQBgkrBgEEAYI3FQEEAwIBADANBgkqhkiG9w0BAQwFAAOCAgEAr2rd5hnn
# LZRDGU7L6VCVZKUDkQKL4jaAOxWiUsIWGbZqWl10QzD0m/9gdAmxIR6QFm3FJI9c
# Zohj9E/MffISTEAQiwGf2qnIrvKVG8+dBetJPnSgaFvlVixlHIJ+U9pW2UYXeZJF
# xBA2CFIpF8svpvJ+1Gkkih6PsHMNzBxKq7Kq7aeRYwFkIqgyuH4yKLNncy2RtNwx
# AQv3Rwqm8ddK7VZgxCwIo3tAsLx0J1KH1r6I3TeKiW5niB31yV2g/rarOoDXGpc8
# FzYiQR6sTdWD5jw4vU8w6VSp07YEwzJ2YbuwGMUrGLPAgNW3lbBeUU0i/OxYqujY
# lLSlLu2S3ucYfCFX3VVj979tzR/SpncocMfiWzpbCNJbTsgAlrPhgzavhgplXHT2
# 6ux6anSg8Evu75SjrFDyh+3XOjCDyft9V77l4/hByuVkrrOj7FjshZrM77nq81YY
# uVxzmq/FdxeDWds3GhhyVKVB0rYjdaNDmuV3fJZ5t0GNv+zcgKCf0Xd1WF81E+Al
# GmcLfc4l+gcK5GEh2NQc5QfGNpn0ltDGFf5Ozdeui53bFv0ExpK91IjmqaOqu/dk
# ODtfzAzQNb50GQOmxapMomE2gj4d8yu8l13bS3g7LfU772Aj6PXsCyM2la+YZr9T
# 03u4aUoqlmZpxJTG9F9urJh4iIAGXKKy7aIwggatMIIElaADAgECAhMzAAfjG2+R
# Z7bz+T8aAAAAB+MbMA0GCSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJ
# RCBWZXJpZmllZCBDUyBFT0MgQ0EgMDQwHhcNMjYxMDA3MjMxOTAxWhcNMjYxMDEw
# MjMxOTAxWjBwMQswCQYDVQQGEwJVUzETMBEGA1UECBMKQ2FsaWZvcm5pYTEWMBQG
# A1UEBxMNU2FuIEZyYW5jaXNjbzEZMBcGA1UEChMQT3BlbkFJIE9wQ28sIExMQzEZ
# MBcGA1UEAxMQT3BlbkFJIE9wQ28sIExMQzCCAaIwDQYJKoZIhvcNAQEBBQADggGP
# ADCCAYoCggGBAL10wsrwl1yPQo8gDhl274VCXm0x2usABp0tKm6/br2cN7wkw/8c
# H54ELg4Jam5B+fp2sN12Ji5riF4rBD1oi+nFAa6tfX1m98JtHoS7CveUKohQe84e
# 2Y8XsyMUKN9O6UNCOzIL8hcHr46/VurFYYK/jvKhYNauBZYmx7oD6xRFWwl6eF0X
# ngR8/hNBZYt/C1FQ88HWQOXNx/sqV9nCCpYmhcCx4F/tc4gLtkZF1SDogG/wL67J
# XacIYrv8mJI0VfrqBzmZPXWJnYrTP75N/YrPCWQPPWCw5zMHiIDmkeenRNYvmfaz
# qxPHD8oQfVjY2A7+OJ+cmFGtuPycisFLQ/f0tw3uWmHdsq2cGs5uN2V3jfwouAmE
# XTloMN9k44P/OwiODyLUCo166LkX9bWz3KHpWEvrFE7llVl9TofC4RYPWpL+zsac
# QsM/FLh2VMfSOPm+23EYU3eqMFV7xka7GOtkb2qfPzf+qi+UpXJhz6ey77mSCgyj
# wTiZDd6sFPQj8wIDAQABo4IB1DCCAdAwDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8E
# BAMCB4AwOwYDVR0lBDQwMgYKKwYBBAGCN2EBAAYIKwYBBQUHAwMGGisGAQQBgjdh
# kLSmdILG8u8FgtbC+HXA0usHMB0GA1UdDgQWBBQI3UnbRt+RX/qYpkr239r3fLzX
# 2jAfBgNVHSMEGDAWgBSa8VR3dQyHFjdGoKzeefn0f8F46TBnBgNVHR8EYDBeMFyg
# WqBYhlZodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3Nv
# ZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ1MlMjBFT0MlMjBDQSUyMDA0LmNybDB0Bggr
# BgEFBQcBAQRoMGYwZAYIKwYBBQUHMAKGWGh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENTJTIw
# RU9DJTIwQ0ElMjAwNC5jcnQwVAYDVR0gBE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUH
# AgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0
# b3J5Lmh0bTANBgkqhkiG9w0BAQwFAAOCAgEAGYH2UNg+4P4cZ2XQpj/GBf2mieyk
# 29naX6lKFwhjCLDJURMXqlhbMAtqTgzVXXt2t5yG1JgDOIQ5dETn7WNbX0iK9+hX
# PxQW18Q76hSMILz/cAmFTQTL+6yJpIr2WRscI0lgmTZqpr6jT5Vh7YzKQ5uVjmSH
# SwTv5OI9u16JdURo1Cw5PXw1oTd8ZDUwSz1i3aev8szUXNSuHu94jFM7Jb6OgJ0V
# sPToioGNib4OlBSCZdVpqKcXizNbrjKUnidDGBZQhRMD1HdORDxu3GZ1whDwtGb8
# dXK/68r8K66bP99pjk7A4XhQkqmNQgQxMAepI/93h4kFbWqgX/SOQH0XW5DN8Ew/
# Q+AA9EiRPuF8+5XqQYkKUKaiOxHVFE9fvktmxsan3KVKD9naGzDwRLYiW2WJieHz
# 1mWgfEtkae+mAuzAS/tBmjJ8QlEr5YL7jpsIdkGsP8g0ZNa5UgdUcULsDJw5FS/U
# RSYkSARiydatMuDytXAx+yIlMMjP95LLJJhtIrW3/8rin09YYtfbLCH2VARHU8AJ
# W4luKS2iT6rWdQ6EYpNX1UaIT+3X3pF9H3EqrKiVflTvO/U/HoOvDiVyiccHwpPy
# 0H7QNkVDIm2xgO7iqY0i4gEjz5ceYNijucdP+Ihrei7Z22hxrEK1IridAANxg727
# BtHoDDSib+w7rfswggatMIIElaADAgECAhMzAAfjG2+RZ7bz+T8aAAAAB+MbMA0G
# CSqGSIb3DQEBDAUAMFoxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQg
# Q29ycG9yYXRpb24xKzApBgNVBAMTIk1pY3Jvc29mdCBJRCBWZXJpZmllZCBDUyBF
# T0MgQ0EgMDQwHhcNMjYxMDA3MjMxOTAxWhcNMjYxMDEwMjMxOTAxWjBwMQswCQYD
# VQQGEwJVUzETMBEGA1UECBMKQ2FsaWZvcm5pYTEWMBQGA1UEBxMNU2FuIEZyYW5j
# aXNjbzEZMBcGA1UEChMQT3BlbkFJIE9wQ28sIExMQzEZMBcGA1UEAxMQT3BlbkFJ
# IE9wQ28sIExMQzCCAaIwDQYJKoZIhvcNAQEBBQADggGPADCCAYoCggGBAL10wsrw
# l1yPQo8gDhl274VCXm0x2usABp0tKm6/br2cN7wkw/8cH54ELg4Jam5B+fp2sN12
# Ji5riF4rBD1oi+nFAa6tfX1m98JtHoS7CveUKohQe84e2Y8XsyMUKN9O6UNCOzIL
# 8hcHr46/VurFYYK/jvKhYNauBZYmx7oD6xRFWwl6eF0XngR8/hNBZYt/C1FQ88HW
# QOXNx/sqV9nCCpYmhcCx4F/tc4gLtkZF1SDogG/wL67JXacIYrv8mJI0VfrqBzmZ
# PXWJnYrTP75N/YrPCWQPPWCw5zMHiIDmkeenRNYvmfazqxPHD8oQfVjY2A7+OJ+c
# mFGtuPycisFLQ/f0tw3uWmHdsq2cGs5uN2V3jfwouAmEXTloMN9k44P/OwiODyLU
# Co166LkX9bWz3KHpWEvrFE7llVl9TofC4RYPWpL+zsacQsM/FLh2VMfSOPm+23EY
# U3eqMFV7xka7GOtkb2qfPzf+qi+UpXJhz6ey77mSCgyjwTiZDd6sFPQj8wIDAQAB
# o4IB1DCCAdAwDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCB4AwOwYDVR0lBDQw
# MgYKKwYBBAGCN2EBAAYIKwYBBQUHAwMGGisGAQQBgjdhkLSmdILG8u8FgtbC+HXA
# 0usHMB0GA1UdDgQWBBQI3UnbRt+RX/qYpkr239r3fLzX2jAfBgNVHSMEGDAWgBSa
# 8VR3dQyHFjdGoKzeefn0f8F46TBnBgNVHR8EYDBeMFygWqBYhlZodHRwOi8vd3d3
# Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2NybC9NaWNyb3NvZnQlMjBJRCUyMFZlcmlm
# aWVkJTIwQ1MlMjBFT0MlMjBDQSUyMDA0LmNybDB0BggrBgEFBQcBAQRoMGYwZAYI
# KwYBBQUHMAKGWGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY2VydHMv
# TWljcm9zb2Z0JTIwSUQlMjBWZXJpZmllZCUyMENTJTIwRU9DJTIwQ0ElMjAwNC5j
# cnQwVAYDVR0gBE0wSzBJBgRVHSAAMEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cu
# bWljcm9zb2Z0LmNvbS9wa2lvcHMvRG9jcy9SZXBvc2l0b3J5Lmh0bTANBgkqhkiG
# 9w0BAQwFAAOCAgEAGYH2UNg+4P4cZ2XQpj/GBf2mieyk29naX6lKFwhjCLDJURMX
# qlhbMAtqTgzVXXt2t5yG1JgDOIQ5dETn7WNbX0iK9+hXPxQW18Q76hSMILz/cAmF
# TQTL+6yJpIr2WRscI0lgmTZqpr6jT5Vh7YzKQ5uVjmSHSwTv5OI9u16JdURo1Cw5
# PXw1oTd8ZDUwSz1i3aev8szUXNSuHu94jFM7Jb6OgJ0VsPToioGNib4OlBSCZdVp
# qKcXizNbrjKUnidDGBZQhRMD1HdORDxu3GZ1whDwtGb8dXK/68r8K66bP99pjk7A
# 4XhQkqmNQgQxMAepI/93h4kFbWqgX/SOQH0XW5DN8Ew/Q+AA9EiRPuF8+5XqQYkK
# UKaiOxHVFE9fvktmxsan3KVKD9naGzDwRLYiW2WJieHz1mWgfEtkae+mAuzAS/tB
# mjJ8QlEr5YL7jpsIdkGsP8g0ZNa5UgdUcULsDJw5FS/URSYkSARiydatMuDytXAx
# +yIlMMjP95LLJJhtIrW3/8rin09YYtfbLCH2VARHU8AJW4luKS2iT6rWdQ6EYpNX
# 1UaIT+3X3pF9H3EqrKiVflTvO/U/HoOvDiVyiccHwpPy0H7QNkVDIm2xgO7iqY0i
# 4gEjz5ceYNijucdP+Ihrei7Z22hxrEK1IridAANxg727BtHoDDSib+w7rfswggco
# MIIFEKADAgECAhMzAAAAFydFCQuLh6/GAAAAAAAXMA0GCSqGSIb3DQEBDAUAMGMx
# CzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xNDAy
# BgNVBAMTK01pY3Jvc29mdCBJRCBWZXJpZmllZCBDb2RlIFNpZ25pbmcgUENBIDIw
# MjEwHhcNMjYwMzI2MTgxMTMxWhcNMzEwMzI2MTgxMTMxWjBaMQswCQYDVQQGEwJV
# UzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSswKQYDVQQDEyJNaWNy
# b3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENBIDA0MIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEAgsdk/gMPZioBlcyfk6tDzJ+PRt4rSLGKW8ewpS0kRxXt
# URC3T3GdbCKljobEn8ussqhGqQpRh/SXvRVwNXEIGb76UG5IPkCJ1S6/9BD61QQs
# KzPepW0SNj8TXgsFxvS7MltoRuikIIp7Q5jQgaOM6QyK9++6ZVXUpYmZulAe6x8J
# rwZ0dNkE+rZ66lqtoocwepUSVUxM7odDmn8yDHjJ2DNPsfr3uRDix3X4qvh14jH/
# SW+2Cx7WIMhyIiQO201i6hUixmk4e2ZW8W7C1wPdTjq6BKb+zo8xbrt7ZKQvRX5Q
# OA6dhLquPqj5sVKnxqfk19IC0SafTSTs8yC43Ew965BRRW8VL9ccoOmr4rxQy7aC
# gYTNk3dd/LphNaTTmnGp7kmLTxyHkB5geoWhYuuGrywS8E0wJv0W4rfOtHBV0e9s
# KvuUIeIUpnsx6ilxEVj6VQXvgD6yeCKnPmj3jJiJKAlmUDtth5yzRVBUl44sMiG4
# L5R/yyACRKk2n088Q2YCoZS1O86+oMLKt1jaXGECOjbsVp8Id1VQw8he6J0KirOS
# 5e25XlTdGPFb6oBOOaacgW78Kjf0bp+XzAgkc92mDGNJGYSjvdnj+7eMx6meW0DA
# IGdLRNj8/429MIspFBfz3KDqqpN71S4kQ2LLer3dxhDDczKVFL0HLwRuOvgjiG8C
# AwEAAaOCAdwwggHYMA4GA1UdDwEB/wQEAwIBhjAQBgkrBgEEAYI3FQEEAwIBADAd
# BgNVHQ4EFgQUmvFUd3UMhxY3RqCs3nn59H/BeOkwVAYDVR0gBE0wSzBJBgRVHSAA
# MEEwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMv
# RG9jcy9SZXBvc2l0b3J5Lmh0bTAZBgkrBgEEAYI3FAIEDB4KAFMAdQBiAEMAQTAS
# BgNVHRMBAf8ECDAGAQH/AgEAMB8GA1UdIwQYMBaAFNlBKbAPD2Ns72nX9c0pnqRI
# ajDmMHAGA1UdHwRpMGcwZaBjoGGGX2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9w
# a2lvcHMvY3JsL01pY3Jvc29mdCUyMElEJTIwVmVyaWZpZWQlMjBDb2RlJTIwU2ln
# bmluZyUyMFBDQSUyMDIwMjEuY3JsMH0GCCsGAQUFBwEBBHEwbzBtBggrBgEFBQcw
# AoZhaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3Nv
# ZnQlMjBJRCUyMFZlcmlmaWVkJTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDIx
# LmNydDANBgkqhkiG9w0BAQwFAAOCAgEAkHVaGf1NJt/JdoimmRZbMWr6baaDi8mk
# dWvWStk0hdZDpxSYTA7HuipAoLL3qIhI101XOl7fOiCh5++jZOamQdAV79ojEUNo
# IgCZmL2XJrLaGanwdjNynecJyYVCTrRf2+h7KknpWOp4axdOs6K9ZQ5g0IsQWXCw
# fc0dfkSkLKNY3pDcWLlJPh2jd5NUue6pNDv/2G5MFNJhCwltODebyAjGceU+XOza
# v+7i721YQnQ+39m2aQOFO7zpAdaKAeAGhEd6Y6CdDGneSxcoujWvafWbv4ay3jo1
# ORSLUuWMbKr5X18QE4Sde+gppGLLSkZsrUh2eyYSkX1envWX7ZPzg2/wiuKRlQFa
# rDn+N9+20BqzhxwkNyLzfYJp1Lg4fCXb24XqFjx8SDdRgebFImOfOLVze8XQ/Cwk
# rEaib0PHu2t4GVk4FYroEbNUFqvjdBvTY3uiR5TdQoyXoYHvh+TxpLSY2vo7hhK9
# D/rpEpHC+qmmcRUE4d0gyO9Zb1vvt25fxM3ekjvDfVHcPq3qMr0Rwsk4krKZWUEg
# U1SXT5qN6gqRrshxbT6OQgZ9/xT04qiXdzPQR6KindBvSpoOnxnALxcJyzVwNpKL
# +9u8EZYy98qX6i+4gE/2J6cbpekcB0ZXDn/XQxoNUUb6/djT/wllVyG+vIHkdq71
# PzbH5rYxdcAwggeeMIIFhqADAgECAhMzAAAAB4ejNKN7pY4cAAAAAAAHMA0GCSqG
# SIb3DQEBDAUAMHcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29y
# cG9yYXRpb24xSDBGBgNVBAMTP01pY3Jvc29mdCBJZGVudGl0eSBWZXJpZmljYXRp
# b24gUm9vdCBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkgMjAyMDAeFw0yMTA0MDEyMDA1
# MjBaFw0zNjA0MDEyMDE1MjBaMGMxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNy
# b3NvZnQgQ29ycG9yYXRpb24xNDAyBgNVBAMTK01pY3Jvc29mdCBJRCBWZXJpZmll
# ZCBDb2RlIFNpZ25pbmcgUENBIDIwMjEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAw
# ggIKAoICAQCy8MCvGYgo4t1UekxJbGkIVQm0Uv96SvjB6yUo92cXdylN65Xy96q2
# YpWCiTas7QPTkGnK9QMKDXB2ygS27EAIQZyAd+M8X+dmw6SDtzSZXyGkxP8a8Hi6
# EO9Zcwh5A+wOALNQbNO+iLvpgOnEM7GGB/wm5dYnMEOguua1OFfTUITVMIK8faxk
# P/4fPdEPCXYyy8NJ1fmskNhW5HduNqPZB/NkWbB9xxMqowAeWvPgHtpzyD3PLGVO
# mRO4ka0WcsEZqyg6efk3JiV/TEX39uNVGjgbODZhzspHvKFNU2K5MYfmHh4H1qOb
# U4JKEjKGsqqA6RziybPqhvE74fEp4n1tiY9/ootdU0vPxRp4BGjQFq28nzawuvaC
# qUUF2PWxh+o5/TRCb/cHhcYU8Mr8fTiS15kRmwFFzdVPZ3+JV3s5MulIf3II5FXe
# ghlAH9CvicPhhP+VaSFW3Da/azROdEm5sv+EUwhBrzqtxoYyE2wmuHKws00x4GGI
# x7NTWznOm6x/niqVi7a/mxnnMvQq8EMse0vwX2CfqM7Le/smbRtsEeOtbnJBbtLf
# oAsC3TdAOnBbUkbUfG78VRclsE7YDDBUbgWt75lDk53yi7C3n0WkHFU4EZ83i83a
# bd9nHWCqfnYa9qIHPqjOiuAgSOf4+FRcguEBXlD9mAInS7b6V0UaNwIDAQABo4IC
# NTCCAjEwDgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQW
# BBTZQSmwDw9jbO9p1/XNKZ6kSGow5jBUBgNVHSAETTBLMEkGBFUdIAAwQTA/Bggr
# BgEFBQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1Jl
# cG9zaXRvcnkuaHRtMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB
# /wQFMAMBAf8wHwYDVR0jBBgwFoAUyH7SaoUqG8oZmAQHJ89QEE9oqKIwgYQGA1Ud
# HwR9MHsweaB3oHWGc2h0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2lvcHMvY3Js
# L01pY3Jvc29mdCUyMElkZW50aXR5JTIwVmVyaWZpY2F0aW9uJTIwUm9vdCUyMENl
# cnRpZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAyMC5jcmwwgcMGCCsGAQUFBwEBBIG2
# MIGzMIGBBggrBgEFBQcwAoZ1aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jZXJ0cy9NaWNyb3NvZnQlMjBJZGVudGl0eSUyMFZlcmlmaWNhdGlvbiUyMFJv
# b3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhvcml0eSUyMDIwMjAuY3J0MC0GCCsGAQUF
# BzABhiFodHRwOi8vb25lb2NzcC5taWNyb3NvZnQuY29tL29jc3AwDQYJKoZIhvcN
# AQEMBQADggIBAH8lKp7+1Kvq3WYK21cjTLpebJDjW4ZbOX3HD5ZiG84vjsFXT0OB
# +eb+1TiJ55ns0BHluC6itMI2vnwc5wDW1ywdCq3TAmx0KWy7xulAP179qX6VSBNQ
# kRXzReFyjvF2BGt6FvKFR/imR4CEESMAG8hSkPYso+GjlngM8JPn/ROUrTaeU/BR
# u/1RFESFVgK2wMz7fU4VTd8NXwGZBe/mFPZG6tWwkdmA/jLbp0kNUX7elxu2+HtH
# o0QO5gdiKF+YTYd1BGrmNG8sTURvn09jAhIUJfYNotn7OlThtfQjXqe0qrimgY4V
# poq2MgDW9ESUi1o4pzC1zTgIGtdJ/IvY6nqa80jFOTg5qzAiRNdsUvzVkoYP7bi4
# wLCj+ks2GftUct+fGUxXMdBUv5sdr0qFPLPB0b8vq516slCfRwaktAxK1S40MCvF
# bbAXXpAZnU20FaAoDwqq/jwzwd8Wo2J83r7O3onQbDO9TyDStgaBNlHzMMQgl95n
# HBYMelLEHkUnVVVTUsgC0Huj09duNfMaJ9ogxhPNThgq3i8w3DAGZ61AMeF0C1M+
# mU5eucj1Ijod5O2MMPeJQ3/vKBtqGZg4eTtUHt/BPjN74SsJsyHqAdXVS5c+ItyK
# Wg3Eforhox9k3WgtWTpgV4gkSiS4+A09roSdOI4vrRw+p+fL4WrxSK5nMYIakDCC
# GowCAQEwcTBaMQswCQYDVQQGEwJVUzEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSswKQYDVQQDEyJNaWNyb3NvZnQgSUQgVmVyaWZpZWQgQ1MgRU9DIENB
# IDA0AhMzAAfjG2+RZ7bz+T8aAAAAB+MbMA0GCWCGSAFlAwQCAQUAoF4wEAYKKwYB
# BAGCNwIBDDECMAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJKoZIhvcN
# AQkEMSIEIL42BOnyHPpybuHnr233v81gsVUyqRYsdCkySP/1kXmOMA0GCSqGSIb3
# DQEBAQUABIIBgJOVzm259yorOu+UorkJvT1/AeWe2wGGPjXlKgDbimvalUWGwcxY
# DhTNHcdSAeblBdV6dJtUvzG4DdctTviFEPXYOn92mIWnWWhLq6IWRWc5/jEu+Tqg
# bJtM6mi9de5z/t6j+CS7rgEzVDwnpQu+w2s/jb7ewc1rb7NRZGXUvE2dhh9cCkZp
# rbokYlwo5TDK6Hp9Kvv6zvJ57L7GYgUbZ7BHZs3E+XVtSS31/I0h0UHoHdDCaKCg
# YlKx+2bLqeyNgCbHxSzYX+tfpac4ae2ZAlfVKIxysryLojlud1jRVp8U0KYf/lep
# xt1btW6QzNowv5gSn+nAUyLnrMovBKTZiwGYWjgQKJQRQQFuagJ4S7yddOABLyL4
# wBbIXR/EvqMyr2559QWEBzE/+7M8Pc7shPzEXYOFOE4ErIfcx+ycCsmp1vs8Kmnq
# y7PoTELzkzWyRgs3N7kyXvXTWeUCb2azEF8l1mBDJhnY+mV+h5XHaw7DdaILGLBI
# 37mFo525L9shzKGCGBAwghgMBgorBgEEAYI3AwMBMYIX/DCCF/gGCSqGSIb3DQEH
# AqCCF+kwghflAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFiBgsqhkiG9w0BCRABBKCC
# AVEEggFNMIIBSQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQCAQUABCCjxgR/
# 9g1sNP4B4gumJEedy5BbPKViUWtCfc+i+awTigIGasj0E+iGGBMyMDI2MTAwOTE4
# MjQzMi40NzJaMASAAgH0oIHhpIHeMIHbMQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMSUwIwYDVQQLExxNaWNyb3NvZnQgQW1lcmljYSBPcGVyYXRp
# b25zMScwJQYDVQQLEx5uU2hpZWxkIFRTUyBFU046N0EwMC0wNUUwLUQ5NDcxNTAz
# BgNVBAMTLE1pY3Jvc29mdCBQdWJsaWMgUlNBIFRpbWUgU3RhbXBpbmcgQXV0aG9y
# aXR5oIIPITCCB4IwggVqoAMCAQICEzMAAAAF5c8P/2YuyYcAAAAAAAUwDQYJKoZI
# hvcNAQEMBQAwdzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjFIMEYGA1UEAxM/TWljcm9zb2Z0IElkZW50aXR5IFZlcmlmaWNhdGlv
# biBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDIwMB4XDTIwMTExOTIwMzIz
# MVoXDTM1MTExOTIwNDIzMVowYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jv
# c29mdCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0Eg
# VGltZXN0YW1waW5nIENBIDIwMjAwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIK
# AoICAQCefOdSY/3gxZ8FfWO1BiKjHB7X55cz0RMFvWVGR3eRwV1wb3+yq0OXDEqh
# UhxqoNv6iYWKjkMcLhEFxvJAeNcLAyT+XdM5i2CgGPGcb95WJLiw7HzLiBKrxmDj
# 1EQB/mG5eEiRBEp7dDGzxKCnTYocDOcRr9KxqHydajmEkzXHOeRGwU+7qt8Md5l4
# bVZrXAhK+WSk5CihNQsWbzT1nRliVDwunuLkX1hyIWXIArCfrKM3+RHh+Sq5RZ8a
# Yyik2r8HxT+l2hmRllBvE2Wok6IEaAJanHr24qoqFM9WLeBUSudz+qL51HwDYyID
# PSQ3SeHtKog0ZubDk4hELQSxnfVYXdTGncaBnB60QrEuazvcob9n4yR65pUNBCF5
# qeA4QwYnilBkfnmeAjRN3LVuLr0g0FXkqfYdUmj1fFFhH8k8YBozrEaXnsSL3kdT
# D01X+4LfIWOuFzTzuoslBrBILfHNj8RfOxPgjuwNvE6YzauXi4orp4Sm6tF245Da
# FOSYbWFK5ZgG6cUY2/bUq3g3bQAqZt65KcaewEJ3ZyNEobv35Nf6xN6FrA6jF944
# 7+NHvCjeWLCQZ3M8lgeCcnnhTFtyQX3XgCoc6IRXvFOcPVrr3D9RPHCMS6Ckg8wg
# gTrtIVnY8yjbvGOUsAdZbeXUIQAWMs0d3cRDv09SvwVRd61evQIDAQABo4ICGzCC
# AhcwDgYDVR0PAQH/BAQDAgGGMBAGCSsGAQQBgjcVAQQDAgEAMB0GA1UdDgQWBBRr
# aSg6NS9IY0DPe9ivSek+2T3bITBUBgNVHSAETTBLMEkGBFUdIAAwQTA/BggrBgEF
# BQcCARYzaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9Eb2NzL1JlcG9z
# aXRvcnkuaHRtMBMGA1UdJQQMMAoGCCsGAQUFBwMIMBkGCSsGAQQBgjcUAgQMHgoA
# UwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAUyH7SaoUqG8oZ
# mAQHJ89QEE9oqKIwgYQGA1UdHwR9MHsweaB3oHWGc2h0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY3JsL01pY3Jvc29mdCUyMElkZW50aXR5JTIwVmVyaWZp
# Y2F0aW9uJTIwUm9vdCUyMENlcnRpZmljYXRlJTIwQXV0aG9yaXR5JTIwMjAyMC5j
# cmwwgZQGCCsGAQUFBwEBBIGHMIGEMIGBBggrBgEFBQcwAoZ1aHR0cDovL3d3dy5t
# aWNyb3NvZnQuY29tL3BraW9wcy9jZXJ0cy9NaWNyb3NvZnQlMjBJZGVudGl0eSUy
# MFZlcmlmaWNhdGlvbiUyMFJvb3QlMjBDZXJ0aWZpY2F0ZSUyMEF1dGhvcml0eSUy
# MDIwMjAuY3J0MA0GCSqGSIb3DQEBDAUAA4ICAQBfiHbHfm21WhV150x4aPpO4dhE
# mSUVpbixNDmv6TvuIHv1xIs174bNGO/ilWMm+Jx5boAXrJxagRhHQtiFprSjMktT
# liL4sKZyt2i+SXncM23gRezzsoOiBhv14YSd1Klnlkzvgs29XNjT+c8hIfPRe9rv
# VCMPiH7zPZcw5nNjthDQ+zD563I1nUJ6y59TbXWsuyUsqw7wXZoGzZwijWT5oc6G
# vD3HDokJY401uhnj3ubBhbkR83RbfMvmzdp3he2bvIUztSOuFzRqrLfEvsPkVHYn
# vH1wtYyrt5vShiKheGpXa2AWpsod4OJyT4/y0dggWi8g/tgbhmQlZqDUf3UqUQsZ
# aLdIu/XSjgoZqDjamzCPJtOLi2hBwL+KsCh0Nbwc21f5xvPSwym0Ukr4o5sCcMUc
# Sy6TEP7uMV8RX0eH/4JLEpGyae6Ki8JYg5v4fsNGif1OXHJ2IWG+7zyjTDfkmQ1s
# nFOTgyEX8qBpefQbF0fx6URrYiarjmBprwP6ZObwtZXJ23jK3Fg/9uqM3j0P01nz
# VygTppBabzxPAh/hHhhls6kwo3QLJ6No803jUsZcd4JQxiYHHc+Q/wAMcPUnYKv/
# q2O444LO1+n6j01z5mggCSlRwD9faBIySAcA9S8h22hIAcRQqIGEjolCK9F6nK9Z
# yX4lhthsGHumaABdWzCCB5cwggV/oAMCAQICEzMAAABdxjl4T0B9M/0AAAAAAF0w
# DQYJKoZIhvcNAQEMBQAwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGlt
# ZXN0YW1waW5nIENBIDIwMjAwHhcNMjYwOTE3MTg1NzIxWhcNMjcwOTE0MTg1NzIx
# WjCB2zELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcT
# B1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UE
# CxMcTWljcm9zb2Z0IEFtZXJpY2EgT3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVs
# ZCBUU1MgRVNOOjdBMDAtMDVFMC1EOTQ3MTUwMwYDVQQDEyxNaWNyb3NvZnQgUHVi
# bGljIFJTQSBUaW1lIFN0YW1waW5nIEF1dGhvcml0eTCCAiIwDQYJKoZIhvcNAQEB
# BQADggIPADCCAgoCggIBAJ33qNzxFA+JrOqDscZ6+dPsV7GCAvPbhBo9jDI14cLJ
# pN9SETe7u3YkVsVK9T31amVEEsKSdDZQeDaeSJqUNsIqOzGwBLuxk/X8NlZRiQXW
# pxvO4DSika/dYqVOkfh0tr7JhkgJF9bioPywLlLbWfRzJOCGT7do8j/1LFMTQfDB
# LA2/tY1Tg0pLAxmcrTdiJhfOVG2fOLABs5CMGqR41YyyDnCNO537p6f/KbGA/peB
# uk01fkCPSsgSqRxoPeOcReQY7vI6O2rjz5x7zEo9ocxn52SsPBZT6pgHqblwpWUb
# 6b7ahzy83um4DC0SMvUf0hsm/0++9t4vQmrxeVcTNdURAbwXDULV9UL2d81qjD6Z
# PbuLCoJ2nFVaweldvs9YJeT4mhG0OpP+7IovdJu27sqdZ4T8bVWrqd7qdub7NJAD
# mjiTzp8xuLmQrAdDR/PhBDQFggz+j88S51ZmyicHcnQkVtEPKi/ksiHSVzKysfOX
# ODEza9IZp45mrUVj/JTIo+nnSGFjy8SFseXSTmJ+GlRJheRnhQKGUSscz0MNY31E
# JxAO8SdPqJaR2z30G8YvJNgTi0pUMx0ebwGtquF/l+yj4F1fz0SDmCZ1LikqppNE
# stixJHwa32fb9+aqb+UGBR/A1hr0oRoJWbAbiTCF1SyMk9bIhCfPX2JgLDDN/YzN
# AgMBAAGjggHLMIIBxzAdBgNVHQ4EFgQUQ9sKXZlO8H4eVu395ahoyH9a57kwHwYD
# VR0jBBgwFoAUa2koOjUvSGNAz3vYr0npPtk92yEwbAYDVR0fBGUwYzBhoF+gXYZb
# aHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9wcy9jcmwvTWljcm9zb2Z0JTIw
# UHVibGljJTIwUlNBJTIwVGltZXN0YW1waW5nJTIwQ0ElMjAyMDIwLmNybDB5Bggr
# BgEFBQcBAQRtMGswaQYIKwYBBQUHMAKGXWh0dHA6Ly93d3cubWljcm9zb2Z0LmNv
# bS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwUHVibGljJTIwUlNBJTIwVGltZXN0
# YW1waW5nJTIwQ0ElMjAyMDIwLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQM
# MAoGCCsGAQUFBwMIMA4GA1UdDwEB/wQEAwIHgDBmBgNVHSAEXzBdMFEGDCsGAQQB
# gjdMg30BATBBMD8GCCsGAQUFBwIBFjNodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20v
# cGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5odG0wCAYGZ4EMAQQCMA0GCSqGSIb3DQEB
# DAUAA4ICAQBCyETwKcMu124k4eFobUOoCnyXigtf6RyVDV/gjL73YFfBXoO6OKWg
# OJv6QrNPrzcQfy0kC60s42YCa4aUWgE04toodo2lHJ9dimsX2vgY1RzMrHyGIxmP
# RoSJWmUdZvrD2pLYnqaX/KyM/5V/Plse6M4GhRGJ1NO+kerQmxd1cTufwcm1K1xz
# CDKHDbUGe3kLR3MBNsIKLaBs5s9LlNoCYi+51r5eH2rQlHLTlgQmDh/dK073VDjd
# PlbQAaWrP5oV7q0MqQVVmyEz4q3XB4hKgHtinFBzAnmswbFL4R3yLENCsR3iDwA6
# WCZFUTTMQQooIQ6IrbBy0F++P+HCJPMSj6OgkOXmNQFCLlmOg4l0OBZo1ToPoCBD
# Ing8jkIrpJjE3THOmCt5GB/128sZElCs7Ohq/B5JAWYlN7Mi5HtwmnXrynaP4RV0
# j2bi1lr1eYY6N2nfMeD4N6FqLh/bz/sJq6w81Smv6Zx0WEZAonPpSSgjHPuCBXPM
# PYOUgpKFPp+JwsYMAjuvKj8mnLNThsZVat+MH8MHQiCzEe3LTOb6Anz+q+xuu1+D
# 1H11uQycKOmR3ndc66EY+IyGsWeS/SDZ7kvXFWpXcK/jWCJuZ5ObEACcwae7ulG7
# 8hm7Vl2Dzbcdib7/ETWE08z6mhWidmM5mmDrbOQGw78kR9rzYcmTSjGCB0Iwggc+
# AgEBMHgwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5n
# IENBIDIwMjACEzMAAABdxjl4T0B9M/0AAAAAAF0wDQYJYIZIAWUDBAIBBQCgggSb
# MBEGCyqGSIb3DQEJEAIPMQIFADAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQw
# HAYJKoZIhvcNAQkFMQ8XDTI2MTAwOTE4MjQzMlowLwYJKoZIhvcNAQkEMSIEIABc
# 8XiYC9PJl+WENEQyKIJfMh8QkE2YRh2IUz92gzA2MIG5BgsqhkiG9w0BCRACLzGB
# qTCBpjCBozCBoAQgLTVkS2/p8+5CYqFlp0aiuYaFAENeb9zL6xe93MQCSl0wfDBl
# pGMwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlv
# bjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5nIENB
# IDIwMjACEzMAAABdxjl4T0B9M/0AAAAAAF0wggNdBgsqhkiG9w0BCRACEjGCA0ww
# ggNIoYIDRDCCA0AwggIoAgEBMIIBCaGB4aSB3jCB2zELMAkGA1UEBhMCVVMxEzAR
# BgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1p
# Y3Jvc29mdCBDb3Jwb3JhdGlvbjElMCMGA1UECxMcTWljcm9zb2Z0IEFtZXJpY2Eg
# T3BlcmF0aW9uczEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjdBMDAtMDVFMC1E
# OTQ3MTUwMwYDVQQDEyxNaWNyb3NvZnQgUHVibGljIFJTQSBUaW1lIFN0YW1waW5n
# IEF1dGhvcml0eaIjCgEBMAcGBSsOAwIaAxUAvae6tbWxgM8HaMBsDxHEmsyWkPWg
# ZzBlpGMwYTELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3Jh
# dGlvbjEyMDAGA1UEAxMpTWljcm9zb2Z0IFB1YmxpYyBSU0EgVGltZXN0YW1waW5n
# IENBIDIwMjAwDQYJKoZIhvcNAQELBQACBQDuc3KWMCIYDzIwMjYxMDA5MTQwMzAy
# WhgPMjAyNjEwMTAxNDAzMDJaMHMwOQYKKwYBBAGEWQoEATErMCkwCgIFAO5zcpYC
# AQAwBgIBAAIBCDAHAgEAAgIP/DAKAgUA7nTEFgIBADA2BgorBgEEAYRZCgQCMSgw
# JjAMBgorBgEEAYRZCgMCoAowCAIBAAIDB6EgoQowCAIBAAIDAYagMA0GCSqGSIb3
# DQEBCwUAA4IBAQB+3mLa0tTM4FBIQjm6frv50z5aRcpNQk5Qy0GoPkkXXtgSTTs/
# rxOYYIyHkRtzdOcGpS3dK8CglqTskoLcXRiMdWb8XFUtgzHtT3OVfLzj9ypT1PBP
# poJsezAd0TeVkLeGxooWdYJ+DUq+YsTymCZGPIfiqxb5FG4Td/8vKGTKtTSIjxn+
# DmiEBA3p3JDUAptttM3YbunM9hhh5Xcgd4FbjCGDyn2i2NNmJ86sl6T36pF4UfHQ
# XHNIzaovmjPRkSsnpljgKU9P5b1TtjtMrkOgHTQe0STJIysGt0OcEgj/0IWR0h4b
# AsSlykjujDHkOWDs8ITHkz1UHruYnbFIgF/sMA0GCSqGSIb3DQEBAQUABIICABC3
# VST4Y8nFMhgkc10fq+cMYIf68oCtVp2/yXegAnbjJW63B+umcfZuYjOs/bdUeuxD
# 0HknMLv2H/iNlRB5zf0BdUe1OCyqrY17H9oZ/AdgbmO7upMncwvyZGzVsV7yRmqH
# yy9F2x4EmTI9TFCyI+xfbIzVkSMzKtiSwHOrtRXTlmbtQtiSZqcalz0DVUOAhUJm
# zwyXQEFwALJ/y1Ec8S5jxn6brr1nONe+SBV6kWbL6ssGfZlhokZ9X13fPT3xisRq
# yndcbyWjKYyylYZqHRPmXDzOeaHB6otkQBoHzn4kEhRwpuXdiPCirgOcfBf9iZjZ
# s+u+bz2JRF36+E+/iza4e+RmPB9fq1WS0ZhRBhu379R+9c5qCxonyrDb04/8Z0Og
# eEIMnx4KAipmfcFQ0wDrkYL8K+uYQaRuA2ucREn6GPpCvTna7ogPjNBFOTlUxaCY
# jek/RBcjizKAC52xxZ7MLCWBufRpcpOjtHG9GQay2VrSlPwt8u3+jR67g7B1dPii
# 1CWSmcxodPGylsYADUO1pl2ylKmxvqYeMqsXy5XGbLpe6sgynXSHCu2p86+7A6By
# DrPfpomXltAiUoGkjdu8k3UUYg/WJKd0/mI2ZB3a6qIu9/OfyqCa812B4ujqpcjM
# dhg9XB+bnLMqa9Fwk6VHnjZrzLiMLBgxxvwp6Dd0
# SIG # End signature block
