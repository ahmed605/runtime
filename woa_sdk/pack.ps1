# .\pack.ps1 -Version 11.0.0-armnt.1 -SourceDir "C:\WoaSDK\Source" -OutDir "C:\WoaSDK"

param
(
  [Parameter(Mandatory)][string]$Version,
  [Parameter(Mandatory)][string]$OutDir,
  [Parameter(Mandatory)][string]$SourceDir,
  [string]$OldVersion  = '11.0.0-dev',
  [string]$Nuget       = 'nuget.exe',
  [string]$VersionProp = 'NativeAotPackagesVersion',
  [switch]$SkipSymbolPkgs = $false,
  [switch]$StripSymbols = $false
)

<# if (-not $PSBoundParameters.ContainsKey('StripSymbols'))
{
  $StripSymbols = -not $SkipSymbolPkgs
} #>

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$ids = @(
  'Microsoft.DotNet.ILCompiler',
  'runtime.win-arm.Microsoft.DotNet.ILCompiler',
  'runtime.win-x64.Microsoft.DotNet.ILCompiler',
# 'runtime.win-arm64.Microsoft.DotNet.ILCompiler',
  'Microsoft.NETCore.App.Runtime.NativeAOT.win-arm',
  'runtime.win-arm.Microsoft.NETCore.DotNetAppHost',
  'Microsoft.NETCore.DotNetAppHost',
  'Microsoft.NETCore.App.Host.win-arm',
  'Microsoft.NETCore.App.Ref'
)

New-Item -ItemType Directory $OutDir -Force | Out-Null

$props = Join-Path $PSScriptRoot 'Sdk\Sdk.props'
$text  = [IO.File]::ReadAllText($props)
$rx    = "(<$VersionProp[^>]*>)[^<]*(</$VersionProp>)"
if ($text -notmatch $rx) { throw "<$VersionProp> not found in $props" }
$text = [regex]::Replace($text, $rx, "`${1}$Version`${2}")
[IO.File]::WriteAllText($props, $text, (New-Object Text.UTF8Encoding($false)))

& $Nuget pack (Join-Path $PSScriptRoot 'COMplicated.NAOT.WoA32.nuspec') `
    -BasePath $PSScriptRoot -OutputDirectory $OutDir
if ($LASTEXITCODE) { throw 'SDK pack failed' }


function Edit-Entry($zip, $entry, [scriptblock]$edit)
{
  $name = $entry.FullName
  $sr = New-Object IO.StreamReader($entry.Open(), [Text.Encoding]::UTF8)
  $content = $sr.ReadToEnd(); $sr.Dispose()
  $entry.Delete()
  $new = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
  $sw = New-Object IO.StreamWriter($new.Open(), (New-Object Text.UTF8Encoding($false)))
  $sw.Write((& $edit $content)); $sw.Dispose()
}

$suffixes = @('.nupkg')
if (-not $SkipSymbolPkgs) { $suffixes += '.symbols.nupkg' }

foreach ($id in $ids)
{
  foreach ($suffix in $suffixes)
  {
    $isSymbolPkg = $suffix -eq '.symbols.nupkg'

    $srcName = "$id.$OldVersion$suffix"
    $src = Join-Path $SourceDir $srcName
    if (-not (Test-Path $src)) { Write-Warning "missing: $srcName"; continue }
    $dst = Join-Path $OutDir "$id.$Version$suffix"
    Copy-Item $src $dst -Force

    $zip = [IO.Compression.ZipFile]::Open($dst, 'Update')
    try
    {
      foreach ($e in @($zip.Entries))
      {
        $n = $e.FullName
        if ($n -eq '.signature.p7s') { $e.Delete(); continue }

        if ($StripSymbols -and -not $isSymbolPkg -and $n -like '*.pdb')
		{
          $e.Delete()
          continue
        }

        $isNuspec = ($n -like '*.nuspec') -and ($n -notlike '*/*')
        $isPsmdcp = $n -like 'package/services/metadata/core-properties/*.psmdcp'
		
        if ($isNuspec -or $isPsmdcp)
		{
          Edit-Entry $zip $e { param($t) $t.Replace($OldVersion, $Version) }
        }
      }
    } finally { $zip.Dispose() }

    Write-Host "repacked: $(Split-Path $dst -Leaf)"
  }
}