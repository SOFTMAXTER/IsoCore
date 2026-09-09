# IsoCore.ImageInfo v1.3.1 - Windows PowerShell 5.1; UTF-8 con BOM.
$script:IsoInfoModulePath = $PSCommandPath

function Get-IsoInfoProperty {
    param($Object, [string[]]$Names, $Fallback = $null)
    foreach ($name in $Names) {
        if ($null -ne $Object) {
            $property = $Object.PSObject.Properties[$name]
            if ($null -ne $property -and $null -ne $property.Value -and
                -not [string]::IsNullOrWhiteSpace([string]$property.Value)) { return $property.Value }
        }
    }
    return $Fallback
}

function ConvertTo-IsoInfoBytes {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [ValueType]) {
        try { if ([decimal]$Value -ge 0) { return [long]$Value } } catch {}
        return $null
    }
    $text = ([string]$Value).Trim()
    $integer = 0L
    if ([long]::TryParse($text, [ref]$integer) -and $integer -ge 0) { return $integer }
    if ($text -match '^(?<n>[0-9]+(?:[.,][0-9]+)?)\s*(?<u>KiB|MiB|GiB|TiB|KB|MB|GB|TB|B)$') {
        $number = [double]::Parse($matches.n.Replace(',', '.'), [Globalization.CultureInfo]::InvariantCulture)
        $unit = $matches.u.ToUpperInvariant()
        $factor = switch -Regex ($unit) { '^T' { 1TB } '^G' { 1GB } '^M' { 1MB } '^K' { 1KB } default { 1 } }
        try { return [long]($number * $factor) } catch { return $null }
    }
    return $null
}

function Format-IsoInfoBytes {
    param($Bytes)
    if ($null -eq $Bytes) { return '—' }
    $factor = 1; $unit = 'B'
    if ($Bytes -ge 1TB) { $factor = 1TB; $unit = 'TiB' }
    elseif ($Bytes -ge 1GB) { $factor = 1GB; $unit = 'GiB' }
    elseif ($Bytes -ge 1MB) { $factor = 1MB; $unit = 'MiB' }
    elseif ($Bytes -ge 1KB) { $factor = 1KB; $unit = 'KiB' }
    return ('{0} {1}' -f ([double]($Bytes / $factor)).ToString('0.00', [Globalization.CultureInfo]::InvariantCulture), $unit)
}

function Get-IsoInfoPercent {
    param([int]$Done, [int]$Total)
    if ($Total -le 0 -or $Done -le 0) { return 0 }
    if ($Done -ge $Total) { return 100 }
    return [int][math]::Min(99, [math]::Round(100.0 * $Done / $Total))
}

function ConvertTo-IsoInfoDate {
    param($Value)
    if ($null -eq $Value) { return '' }
    try { return ([datetime]$Value).ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) }
    catch { return [string]$Value }
}

function Get-IsoInfoLanguageData {
    param($Image, [string]$NativeText = '')
    $raw = @(Get-IsoInfoProperty $Image @('Languages','Language') @())
    $values = @(foreach ($entry in $raw) {
        $text = if ($entry -is [string]) { $entry } else { [string](Get-IsoInfoProperty $entry @('Name','Value') ([string]$entry)) }
        if ($text -match '^\s*([a-z]{2,3}(?:-[a-z0-9]{2,8})+)\s*(?:\([^)]*\))?\s*$') { $matches[1] } else { '' }
    })
    $default = [string](Get-IsoInfoProperty $Image @('DefaultLanguage'))
    $source = if ($default) { 'Get-WindowsImage.DefaultLanguage' } else { '' }
    $position = Get-IsoInfoProperty $Image @('DefaultLanguageIndex')
    $index = 0
    if (-not $default -and $null -ne $position -and [int]::TryParse([string]$position, [ref]$index) -and
        $index -ge 0 -and $index -lt $values.Count -and $values[$index]) {
        # Índice de la matriz original de idiomas; nunca ordenar antes de resolverlo.
        $default = $values[$index]; $source = 'Get-WindowsImage.DefaultLanguageIndex'
    }
    $marked = @($raw | Where-Object { [string]$_ -match '\((?:Default|predeterminado)\)\s*$' })
    if (-not $default -and $marked.Count -eq 1 -and [string]$marked[0] -match '^\s*([a-z]{2,3}(?:-[a-z0-9]{2,8})+)') {
        $default = $matches[1]; $source = 'Get-WindowsImage.Languages (Default)'
    }
    if (-not $default -and $NativeText) {
        $marked = [regex]::Matches($NativeText, '(?im)^\s*([a-z]{2,3}(?:-[a-z0-9]{2,8})+)\s+\(Default\)\s*$')
        if ($marked.Count -eq 1) { $default = $marked[0].Groups[1].Value; $source = 'DISM /English /Get-WimInfo (Default)' }
    }
    if ($default -and $default -notmatch '^[a-z]{2,3}(?:-[a-z0-9]{2,8})+$') { $default = ''; $source = '' }
    $languages = @(@($values) + @($default) | Where-Object { $_ } | Sort-Object -Unique)
    [pscustomobject]@{ Default = $default; Source = $source; Languages = $languages;
        Status = $(if ($default) { 'Confirmado' } else { 'No confirmado' });
        Text = (($languages | ForEach-Object { if ($_ -ieq $default) { "$_ (predeterminado)" } else { $_ } }) -join ', ') }
}

function ConvertTo-IsoInfoShortDescription {
    param([string]$Text, [int]$Limit = 120)
    $compact = ($Text -replace '\s+', ' ').Trim()
    if ($compact.Length -le $Limit) { return $compact }
    $cut = $compact.Substring(0, $Limit - 1)
    $space = $cut.LastIndexOf(' ')
    if ($space -gt ($Limit / 2)) { $cut = $cut.Substring(0, $space) }
    return $cut.TrimEnd() + '…'
}

function ConvertTo-IsoInfoNativeArgument {
    param([string]$Value)
    # Comillas Windows: proteger espacios, comillas y barras finales, sin intérprete de shell.
    return '"' + ([regex]::Replace(([regex]::Replace($Value, '(\\*)"', '$1$1\"')), '(\\+)$', '$1$1')) + '"'
}

function Invoke-IsoInfoNative {
    param([ValidateSet('dism.exe','reg.exe')][string]$Name, [string[]]$Arguments)
    $systemFolder = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { 'Sysnative' } else { 'System32' }
    $executable = Join-Path (Join-Path $env:WINDIR $systemFolder) $Name
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw "No se encontró $Name en Windows." }
    $process = New-Object Diagnostics.Process
    try {
        $process.StartInfo.FileName = $executable
        $process.StartInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-IsoInfoNativeArgument $_ }) -join ' ')
        $process.StartInfo.UseShellExecute = $false; $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardOutput = $true; $process.StartInfo.RedirectStandardError = $true
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $output = $stdout.GetAwaiter().GetResult() + "`r`n" + $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "$Name terminó con código $($process.ExitCode). $($output.Trim())" }
        return $output
    } finally { $process.Dispose() }
}

function ConvertFrom-IsoInfoIntl {
    param([string]$Text)
    $values = [ordered]@{ SystemUILanguage = ''; SystemPreferredUILanguage = ''; SystemLocale = '' }
    $patterns = @{ SystemUILanguage = 'Default system UI language'; SystemPreferredUILanguage = 'System preferred UI language'; SystemLocale = 'System locale' }
    foreach ($name in $values.Keys | ForEach-Object { $_ }) {
        $match = [regex]::Match($Text, '(?im)^\s*' + [regex]::Escape($patterns[$name]) + '\s*:\s*([a-z]{2,3}(?:-[a-z0-9]{2,8})+)\s*$')
        if ($match.Success) { $values[$name] = $match.Groups[1].Value }
    }
    if (-not $values.SystemUILanguage) { throw 'DISM /Get-Intl no devolvió un idioma de interfaz predeterminado reconocible.' }
    return [pscustomobject]$values
}

function Get-IsoInfoOfflineVersion {
    param([string]$MountPath, [string]$SystemRoot = 'Windows')
    $relative = $SystemRoot.Trim('\','/')
    if (-not $relative) { $relative = 'Windows' }
    if ($relative -match '[:\\/]' -or $relative -in @('.','..')) { throw 'Directorio de Windows no válido en los metadatos.' }
    $source = Join-Path (Join-Path (Join-Path $MountPath $relative) 'System32') 'config'
    $folder = Join-Path ([IO.Path]::GetTempPath()) ('IsoCore_Hive_' + [guid]::NewGuid().ToString('N'))
    $keyName = 'IsoCore_Info_' + [guid]::NewGuid().ToString('N')
    $loaded = $false; $attempted = $false; $key = $null; $rootKey = $null
    [void][IO.Directory]::CreateDirectory($folder)
    try {
        foreach ($name in @('SOFTWARE','SOFTWARE.LOG1','SOFTWARE.LOG2')) {
            $file = Join-Path $source $name
            if ($name -eq 'SOFTWARE' -or (Test-Path -LiteralPath $file -PathType Leaf)) {
                Copy-Item -LiteralPath $file -Destination (Join-Path $folder $name) -ErrorAction Stop
                (Get-Item -LiteralPath (Join-Path $folder $name)).IsReadOnly = $false
            }
        }
        $attempted = $true
        $null = Invoke-IsoInfoNative 'reg.exe' @('load', "HKLM\$keyName", (Join-Path $folder 'SOFTWARE'))
        $loaded = $true
        $rootKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        $key = $rootKey.OpenSubKey("$keyName\Microsoft\Windows NT\CurrentVersion", $false)
        if ($null -eq $key) { throw 'La imagen no contiene la clave CurrentVersion.' }
        [pscustomobject]@{
            DisplayVersion = [string]$key.GetValue('DisplayVersion', '')
            ReleaseId = [string]$key.GetValue('ReleaseId', '')
            OfflineBuild = [string]$key.GetValue('CurrentBuildNumber', '')
            OfflineRevision = $key.GetValue('UBR', $null)
        }
    } finally {
        if ($null -ne $key) { $key.Dispose() }
        if ($null -ne $rootKey) { $rootKey.Dispose() }
        if ($loaded) {
            try { $null = Invoke-IsoInfoNative 'reg.exe' @('unload', "HKLM\$keyName"); $loaded = $false }
            catch { throw "No se pudo liberar HKLM\$keyName. Copia temporal conservada en $folder. $($_.Exception.Message)" }
        } elseif ($attempted) {
            # Una carga fallida no autoriza borrar una copia que pudiera seguir abierta.
            $probe = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
            try {
                $existing = $probe.OpenSubKey($keyName, $false)
                if ($null -ne $existing) {
                    $existing.Dispose()
                    try { $null = Invoke-IsoInfoNative 'reg.exe' @('unload', "HKLM\$keyName") }
                    catch { $loaded = $true; throw "Revisa HKLM\$keyName y la copia $folder. $($_.Exception.Message)" }
                }
            } finally { $probe.Dispose() }
        }
        if (-not $loaded) {
            # Solo archivos de la carpeta de trabajo propia; nunca la imagen montada.
            foreach ($file in @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue }
            try { [IO.Directory]::Delete($folder, $false) } catch {}
        }
    }
}

function Get-IsoInfoServicing {
    param([object[]]$Packages)
    $result = [ordered]@{}
    foreach ($kind in @('ServicingStack','CumulativeUpdate')) {
        $pattern = if ($kind -eq 'ServicingStack') { '^Package_for_ServicingStack(?:_|~)' } else { '^Package_for_RollupFix~' }
        $candidates = @(foreach ($package in $Packages) {
            if ([string]$package.PackageState -ine 'Installed' -or [string]$package.PackageName -notmatch $pattern) { continue }
            $version = $null
            $last = ([string]$package.PackageName -split '~')[-1]
            if ([version]::TryParse($last, [ref]$version)) {
                [pscustomobject]@{ Name = [string]$package.PackageName; Version = $version; Installed = ConvertTo-IsoInfoDate (Get-IsoInfoProperty $package @('InstallTime')) }
            }
        })
        $latest = @($candidates | Sort-Object Version -Descending | Select-Object -First 1)
        $result[$kind] = if ($latest.Count) { $latest[0].Name } else { '' }
        $result[$kind + 'Version'] = if ($latest.Count) { [string]$latest[0].Version } else { '' }
        $result[$kind + 'Installed'] = if ($latest.Count) { $latest[0].Installed } else { '' }
    }
    $result['ServicingStatus'] = 'Consulta completada. Se identifica la mayor versión instalada por nombre de paquete; un campo vacío significa no identificado, no ausencia de actualizaciones.'
    return [pscustomobject]$result
}

function Assert-IsoInfoStamp {
    param([string]$Path, $ExpectedStamp)
    $actual = Get-IsoInfoFileStamp $Path
    if ($null -eq $ExpectedStamp -or $actual.Path -ine $ExpectedStamp.Path -or
        $actual.SizeBytes -ne $ExpectedStamp.SizeBytes -or $actual.ModifiedUtc -ne $ExpectedStamp.ModifiedUtc) {
        throw 'El archivo cambió o no se ha leído. Pulsa Leer antes de repetir la operación.'
    }
    return $actual
}

function Invoke-IsoInfoAdvanced {
    param($Request, $Shared)
    $ErrorActionPreference = 'Stop'
    $row = $Request.Row.PSObject.Copy()
    $mountPath = $null; $attempted = $false; $released = $false; $done = 0; $errors = 0; $outcome = 'Completo'
    $messages = New-Object 'System.Collections.Generic.List[string]'
    # Una segunda consulta nunca debe dejar valores anteriores como si fueran actuales.
    foreach ($field in @('DisplayVersion','DisplayVersionSource','ReleaseId','OfflineBuild','OfflineRevision','SystemUILanguage','SystemPreferredUILanguage','SystemLocale',
        'ServicingStack','ServicingStackVersion','ServicingStackInstalled','CumulativeUpdate','CumulativeUpdateVersion','CumulativeUpdateInstalled','ServicingStatus')) { $row.$field = '' }
    try {
        Import-Module Dism -ErrorAction Stop
        $null = Assert-IsoInfoStamp $Request.Path $Request.ExpectedStamp
        if ([IO.Path]::GetExtension($Request.Path) -ine '.wim') { throw 'Los detalles avanzados requieren WIM; DISM no monta ESD directamente.' }
        if ($Shared.CancelRequested) { $outcome = 'Cancelado'; return }
        $mountPath = Join-Path ([IO.Path]::GetTempPath()) ('IsoCore_Info_' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($mountPath)
        Send-IsoInfoEvent $Shared 'Current' 'Montando el índice en modo de solo lectura...'
        $attempted = $true
        Mount-WindowsImage -ImagePath $Request.Path -Index $row.Index -Path $mountPath -ReadOnly -ErrorAction Stop | Out-Null
        foreach ($task in @('Idioma y configuración regional','Versión offline','Actualizaciones instaladas')) {
            if ($Shared.CancelRequested) { $outcome = 'Cancelado'; break }
            Send-IsoInfoEvent $Shared 'Current' "Consultando $task..."
            try {
                switch ($task) {
                    'Idioma y configuración regional' {
                        $intl = ConvertFrom-IsoInfoIntl (Invoke-IsoInfoNative 'dism.exe' @('/English', "/Image:$mountPath", '/Get-Intl'))
                        foreach ($p in $intl.PSObject.Properties) { $row.($p.Name) = $p.Value }
                        if (-not $row.DefaultLanguage) {
                            $row.DefaultLanguage = $intl.SystemUILanguage
                            $row.DefaultLanguageSource = 'DISM /Get-Intl: Default system UI language (configuración offline)'
                            $row.DefaultLanguageStatus = 'Confirmado en configuración offline'
                            $row.Languages = @(@($row.Languages) + @($row.DefaultLanguage) | Sort-Object -Unique)
                            $row.Language = (($row.Languages | ForEach-Object { if ($_ -ieq $row.DefaultLanguage) { "$_ (predeterminado)" } else { $_ } }) -join ', ')
                        }
                    }
                    'Versión offline' {
                        $version = Get-IsoInfoOfflineVersion $mountPath $row.SystemRoot
                        foreach ($p in $version.PSObject.Properties) { $row.($p.Name) = $p.Value }
                        $row.DisplayVersionSource = if ($row.DisplayVersion) { 'SOFTWARE offline: Microsoft\Windows NT\CurrentVersion\DisplayVersion' } else { 'DisplayVersion no presente en el registro offline; ReleaseId se muestra por separado.' }
                    }
                    'Actualizaciones instaladas' {
                        $servicing = Get-IsoInfoServicing @(Get-WindowsPackage -Path $mountPath -ErrorAction Stop)
                        foreach ($p in $servicing.PSObject.Properties) { $row.($p.Name) = $p.Value }
                    }
                }
            } catch { $errors++; $messages.Add("${task}: $($_.Exception.Message)") }
            $done++; Send-IsoInfoEvent $Shared 'Progress' ([pscustomobject]@{ Done = $done; Total = 4; Failures = $errors })
        }
        $null = Assert-IsoInfoStamp $Request.Path $Request.ExpectedStamp
    } catch { $errors++; $outcome = 'Error'; $messages.Add($_.Exception.Message) }
    finally {
        if ($attempted) {
            Send-IsoInfoEvent $Shared 'Current' 'Liberando el montaje de solo lectura...'
            try {
                $mounted = @(Get-WindowsImage -Mounted -ErrorAction Stop | Where-Object { $_.Path -ieq $mountPath -or $_.MountPath -ieq $mountPath })
                if ($mounted.Count) { Dismount-WindowsImage -Path $mountPath -Discard -ErrorAction Stop | Out-Null }
                $released = $true
            } catch { $errors++; $outcome = 'Error de desmontaje'; $messages.Add("No se pudo liberar $mountPath. $($_.Exception.Message)") }
        } else { $released = $true }
        if ($mountPath -and $released) { try { [IO.Directory]::Delete($mountPath, $false) } catch {} }
        if ($attempted -and $released) { $done++; Send-IsoInfoEvent $Shared 'Progress' ([pscustomobject]@{ Done = $done; Total = 4; Failures = $errors }) }
        if ($outcome -eq 'Completo' -and $errors) { $outcome = 'Con errores' }
        $row.AdvancedStatus = $outcome; $row.AdvancedReadUtc = [datetime]::UtcNow.ToString('o'); $row.AdvancedError = $messages -join "`r`n"
        Send-IsoInfoEvent $Shared 'Advanced' $row
        if ($row.AdvancedError) { Send-IsoInfoEvent $Shared 'Error' $row.AdvancedError }
        Send-IsoInfoEvent $Shared 'Finished' ([pscustomobject]@{ Outcome = $outcome; Done = $done; Total = 4; Failures = $errors; Error = $row.AdvancedError })
    }
}

function Invoke-IsoInfoVerify {
    param($Request, $Shared)
    $ErrorActionPreference = 'Stop'
    $folder = $null; $copyPath = $null; $done = 0; $total = 0; $errors = 0; $outcome = 'Completo'; $fatal = ''
    $results = New-Object 'System.Collections.Generic.List[object]'
    $method = 'DISM Export-WindowsImage -CheckIntegrity: todos los índices a una copia WIM temporal'
    try {
        Import-Module Dism -ErrorAction Stop
        $null = Assert-IsoInfoStamp $Request.Path $Request.ExpectedStamp
        if ($Shared.CancelRequested) { $outcome = 'Cancelado'; return }
        $parent = Get-Item -LiteralPath $Request.WorkingFolder -ErrorAction Stop
        if (-not $parent.PSIsContainer) { throw 'Elige una carpeta para la copia temporal.' }
        $indices = @(Get-WindowsImage -ImagePath $Request.Path -ErrorAction Stop | ForEach-Object { [int](Get-IsoInfoProperty $_ @('ImageIndex','Index') 0) })
        if (-not $indices.Count -or @($indices | Where-Object { $_ -lt 1 }).Count -or @($indices | Sort-Object -Unique).Count -ne $indices.Count) { throw 'DISM no devolvió índices válidos para la verificación.' }
        $total = $indices.Count + 1
        foreach ($index in $indices) { $results.Add([pscustomobject]@{ Index = $index; Result = 'No verificado'; Method = $method; Error = '' }) }
        $folder = Join-Path $parent.FullName ('IsoCore_Verify_' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($folder)
        $copyPath = Join-Path $folder 'verification.wim'
        Send-IsoInfoEvent $Shared 'Progress' ([pscustomobject]@{ Done = 0; Total = $total; Failures = 0 })
        foreach ($result in $results) {
            if ($Shared.CancelRequested) { $outcome = 'Cancelado'; break }
            Send-IsoInfoEvent $Shared 'Current' "Comprobando índice $($result.Index) con DISM; creando copia temporal..."
            try {
                Export-WindowsImage -SourceImagePath $Request.Path -SourceIndex $result.Index -DestinationImagePath $copyPath -CompressionType max -CheckIntegrity -ErrorAction Stop | Out-Null
                $result.Result = 'Sin errores detectados por DISM'
            } catch {
                $result.Result = 'No se pudo completar'; $result.Error = $_.Exception.Message
                throw
            }
            $done++; Send-IsoInfoEvent $Shared 'Progress' ([pscustomobject]@{ Done = $done; Total = $total; Failures = 0 })
        }
        $null = Assert-IsoInfoStamp $Request.Path $Request.ExpectedStamp
    } catch { $outcome = 'Error'; $errors++; $fatal = $_.Exception.Message }
    finally {
        if ($folder) {
            Send-IsoInfoEvent $Shared 'Current' 'Eliminando la copia temporal de verificación...'
            try {
                if ($copyPath -and (Test-Path -LiteralPath $copyPath -PathType Leaf)) { Remove-Item -LiteralPath $copyPath -Force -ErrorAction Stop }
                [IO.Directory]::Delete($folder, $false)
                $done++; Send-IsoInfoEvent $Shared 'Progress' ([pscustomobject]@{ Done = $done; Total = $total; Failures = $errors })
            } catch { $outcome = 'Error de limpieza'; $errors++; $fatal += " No se pudo eliminar la copia temporal en $folder. $($_.Exception.Message)" }
        }
        $verified = [datetime]::UtcNow.ToString('o')
        $summary = if ($outcome -eq 'Completo') { 'Sin errores detectados por DISM en todos los índices.' } else { "Verificación no completada: $outcome." }
        if ($outcome -eq 'Completo' -and (-not $results.Count -or @($results | Where-Object { $_.Result -ne 'Sin errores detectados por DISM' }).Count)) { $outcome = 'Cancelado'; $summary = 'Verificación no completada.' }
        Send-IsoInfoEvent $Shared 'Verification' ([pscustomobject]@{ Outcome = $outcome; Summary = $summary; Method = $method; VerifiedUtc = $verified;
            Rows = @($results.ToArray()); Error = $fatal; Scope = 'Comprueba la exportación de los índices con DISM. No certifica autenticidad, arranque ni funcionamiento de Windows.' })
        if ($fatal) { Send-IsoInfoEvent $Shared 'Error' $fatal }
        Send-IsoInfoEvent $Shared 'Finished' ([pscustomobject]@{ Outcome = $outcome; Done = $done; Total = $total; Failures = $errors; Error = $fatal })
    }
}

function New-IsoInfoRow {
    param($Summary, $Image, [string]$Status = 'Pendiente', [string]$Message = '')
    $index = [int](Get-IsoInfoProperty $Summary @('ImageIndex','Index') 0)
    $name = Get-IsoInfoProperty $Image @('ImageName','Name') (Get-IsoInfoProperty $Summary @('ImageName','Name') "Índice $index")
    $size = ConvertTo-IsoInfoBytes (Get-IsoInfoProperty $Image @('ImageSize') (Get-IsoInfoProperty $Summary @('ImageSize')))
    $arch = [string](Get-IsoInfoProperty $Image @('Architecture'))
    $arch = switch -Regex ($arch.ToUpperInvariant()) {
        '^(0|X86|I386|INTEL)$' { 'x86' }
        '^(9|X64|AMD64)$' { 'x64' }
        '^(12|ARM64|AARCH64)$' { 'arm64' }
        '^(5|ARM)$' { 'arm' }
        default { $arch }
    }
    $version = [string](Get-IsoInfoProperty $Image @('Version','VersionString'))
    $build = Get-IsoInfoProperty $Image @('Build')
    $revision = Get-IsoInfoProperty $Image @('ServicePackBuild','SPBuild')
    $parsed = $null
    if ([version]::TryParse($version, [ref]$parsed)) {
        if ($null -eq $build -and $parsed.Build -ge 0) { $build = $parsed.Build }
        if ($null -eq $revision -and $parsed.Revision -gt 0) { $revision = $parsed.Revision }
    }
    $languageData = Get-IsoInfoLanguageData $Image
    $description = [string](Get-IsoInfoProperty $Image @('ImageDescription','Description'))
    [pscustomobject][ordered]@{
        Index = $index; Name = [string]$name; Status = $Status; Message = $Message
        SizeBytes = $size; SizeText = Format-IsoInfoBytes $size
        Architecture = $arch; Version = $version
        Build = if ($null -ne $build) { [int]$build } else { $null }
        Revision = if ($null -ne $revision) { [int]$revision } else { $null }
        Modified = ConvertTo-IsoInfoDate (Get-IsoInfoProperty $Image @('ModifiedTime'))
        Created = ConvertTo-IsoInfoDate (Get-IsoInfoProperty $Image @('CreatedTime'))
        Language = $languageData.Text; Languages = @($languageData.Languages); DefaultLanguage = $languageData.Default
        DefaultLanguageSource = $languageData.Source; DefaultLanguageStatus = $languageData.Status
        Description = $description; DescriptionShort = ConvertTo-IsoInfoShortDescription $description
        DisplayVersion = ''; DisplayVersionSource = ''; ReleaseId = ''; OfflineBuild = ''; OfflineRevision = $null
        SystemUILanguage = ''; SystemPreferredUILanguage = ''; SystemLocale = ''
        ServicingStack = ''; ServicingStackVersion = ''; ServicingStackInstalled = ''
        CumulativeUpdate = ''; CumulativeUpdateVersion = ''; CumulativeUpdateInstalled = ''; ServicingStatus = 'No consultado'
        ProductKeyRequired = 'No determinable desde WIM/ESD'
        ProductKeyReason = 'Depende del medio de instalación, la configuración de Setup y la licencia del equipo; no se leen ni exportan claves.'
        AdvancedStatus = 'No consultado'; AdvancedReadUtc = ''; AdvancedError = ''
        VerificationState = 'No verificada'; VerificationMethod = ''; VerifiedUtc = ''; VerificationError = ''
        EditionID = [string](Get-IsoInfoProperty $Image @('EditionId','EditionID'))
        InstallationType = [string](Get-IsoInfoProperty $Image @('InstallationType'))
        ProductType = [string](Get-IsoInfoProperty $Image @('ProductType'))
        ProductSuite = [string](Get-IsoInfoProperty $Image @('ProductSuite'))
        SystemRoot = [string](Get-IsoInfoProperty $Image @('SystemRoot'))
        WimBoot = [string](Get-IsoInfoProperty $Image @('WimBoot'))
    }
}

function Get-IsoInfoFileStamp {
    param([string]$Path)
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.PSIsContainer) { throw 'Selecciona un archivo WIM o ESD.' }
    [pscustomobject]@{ Path = $file.FullName; SizeBytes = [long]$file.Length; ModifiedUtc = $file.LastWriteTimeUtc.ToString('o') }
}

function Find-IsoInfoCandidates {
    param([string]$InputPath)
    if ([string]::IsNullOrWhiteSpace($InputPath)) { throw 'Indica una unidad, carpeta o archivo WIM/ESD.' }
    $path = [Environment]::ExpandEnvironmentVariables($InputPath.Trim().Trim('"'))
    if (-not (Test-Path -LiteralPath $path)) { throw "La ruta no existe o no es accesible: $path" }
    $item = Get-Item -LiteralPath $path -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        if ($item.Extension -notin @('.wim','.esd')) { throw 'El archivo debe tener extensión .wim o .esd.' }
        $files = @($item)
    } else {
        $files = @(Get-ChildItem -LiteralPath $item.FullName -File -ErrorAction Stop |
            Where-Object { $_.Extension -in @('.wim','.esd') })
        $sources = Join-Path $item.FullName 'sources'
        if (Test-Path -LiteralPath $sources -PathType Container) {
            $files += @(Get-ChildItem -LiteralPath $sources -File -ErrorAction Stop |
                Where-Object { $_.Extension -in @('.wim','.esd') })
        }
    }
    foreach ($file in @($files | Sort-Object FullName -Unique)) {
        [pscustomobject]@{
            Path = $file.FullName; SizeBytes = [long]$file.Length
            Display = '{0} | {1} | {2}' -f $file.Name, (Format-IsoInfoBytes $file.Length), $file.DirectoryName
        }
    }
}

function Send-IsoInfoEvent {
    param($Shared, [string]$Type, $Data)
    $Shared.Events.Enqueue([pscustomobject]@{ Type = $Type; Data = $Data })
}

function Invoke-IsoInfoRead {
    param($Request, $Shared)
    $ErrorActionPreference = 'Stop'
    $done = 0; $failures = 0; $total = 0; $outcome = 'Completo'; $fatal = ''
    try {
        Import-Module Dism -ErrorAction Stop
        if ($Shared.CancelRequested) { $outcome = 'Cancelado'; return }
        $stamp = Get-IsoInfoFileStamp $Request.Path
        if ($null -ne $Request.ExpectedStamp -and
            ($stamp.Path -ine $Request.ExpectedStamp.Path -or $stamp.SizeBytes -ne $Request.ExpectedStamp.SizeBytes -or
             $stamp.ModifiedUtc -ne $Request.ExpectedStamp.ModifiedUtc)) {
            throw 'El archivo cambió desde la lectura anterior. Pulsa Leer para iniciar una lectura nueva.'
        }
        Send-IsoInfoEvent $Shared 'File' $stamp
        $summaries = @(Get-WindowsImage -ImagePath $stamp.Path -ErrorAction Stop)
        $seen = @{}
        foreach ($summary in $summaries) {
            $idx = [int](Get-IsoInfoProperty $summary @('ImageIndex','Index') 0)
            if ($idx -lt 1 -or $seen.ContainsKey($idx)) { throw 'DISM devolvió índices no válidos o duplicados.' }
            $seen[$idx] = $true
        }
        if (@($Request.Indices).Count -gt 0) {
            foreach ($idx in $Request.Indices) {
                if (-not $seen.ContainsKey([int]$idx)) { throw "El índice $idx ya no existe. Inicia una lectura nueva." }
            }
            $summaries = @($summaries | Where-Object { [int](Get-IsoInfoProperty $_ @('ImageIndex','Index')) -in $Request.Indices })
        }
        $total = $summaries.Count
        Send-IsoInfoEvent $Shared 'Detected' ([pscustomobject]@{
            Total = $total; Rows = @($summaries | ForEach-Object { New-IsoInfoRow -Summary $_ })
        })
        foreach ($summary in $summaries) {
            if ($Shared.CancelRequested) { $outcome = 'Cancelado'; break }
            $idx = [int](Get-IsoInfoProperty $summary @('ImageIndex','Index'))
            Send-IsoInfoEvent $Shared 'Current' "Leyendo índice $idx..."
            try {
                $details = @(Get-WindowsImage -ImagePath $stamp.Path -Index $idx -ErrorAction Stop)
                if ($details.Count -ne 1) { throw 'DISM no devolvió una ficha única para este índice.' }
                $row = New-IsoInfoRow -Summary $summary -Image $details[0] -Status 'Correcto'
                if (-not $row.DefaultLanguage -and -not $Shared.CancelRequested) {
                    try {
                        $native = Invoke-IsoInfoNative 'dism.exe' @('/English','/Get-WimInfo',"/WimFile:$($stamp.Path)","/Index:$idx")
                        $languageData = Get-IsoInfoLanguageData $details[0] $native
                        $row.DefaultLanguage = $languageData.Default; $row.DefaultLanguageSource = $languageData.Source
                        $row.DefaultLanguageStatus = $languageData.Status; $row.Languages = @($languageData.Languages); $row.Language = $languageData.Text
                    } catch { $row.DefaultLanguageStatus = 'No confirmado: ' + $_.Exception.Message }
                }
            } catch {
                $failures++
                $row = New-IsoInfoRow -Summary $summary -Status 'Error' -Message $_.Exception.Message
            }
            $done++
            Send-IsoInfoEvent $Shared 'Row' ([pscustomobject]@{ Row = $row; Done = $done; Total = $total; Failures = $failures })
        }
        if ($failures -gt 0 -and $outcome -eq 'Completo') { $outcome = 'Con errores' }
        if ($total -eq 0 -and $outcome -eq 'Completo') { $outcome = 'Sin índices' }
        $after = Get-IsoInfoFileStamp $stamp.Path
        if ($stamp.SizeBytes -ne $after.SizeBytes -or $stamp.ModifiedUtc -ne $after.ModifiedUtc) {
            throw 'El archivo cambió durante la lectura. Los resultados deben volver a leerse.'
        }
    } catch {
        $outcome = 'Error'; $fatal = $_.Exception.Message
        Send-IsoInfoEvent $Shared 'Error' $fatal
    } finally {
        Send-IsoInfoEvent $Shared 'Finished' ([pscustomobject]@{ Outcome = $outcome; Done = $done; Total = $total; Failures = $failures; Error = $fatal })
    }
}

function Get-IsoInfoMatchKey {
    param($Row)
    $identity = if ($Row.EditionID) { 'edition:' + $Row.EditionID } else { 'name:' + $Row.Name }
    # JSON evita colisiones cuando el nombre contiene separadores.
    return (ConvertTo-Json -InputObject @($identity, $Row.Architecture, $Row.InstallationType) -Compress).ToLowerInvariant()
}

function Compare-IsoInfoImages {
    param($A, $B)
    $groupsA = @{}; $groupsB = @{}
    foreach ($pair in @(@($A,$groupsA), @($B,$groupsB))) {
        foreach ($row in $pair[0].Rows.Values) {
            if ($row.Status -ne 'Correcto') {
                [pscustomobject]@{ Edition = $row.Name; Field = 'Lectura'; A = $(if ($pair[0] -eq $A) { "$($row.Index): $($row.Status)" } else { '' }); B = $(if ($pair[0] -eq $B) { "$($row.Index): $($row.Status)" } else { '' }); Status = 'Sin comparar' }
                continue
            }
            $key = Get-IsoInfoMatchKey $row
            if (-not $pair[1].ContainsKey($key)) { $pair[1][$key] = @() }
            $pair[1][$key] += $row
        }
    }
    if ($A.Stamp.SizeBytes -ne $B.Stamp.SizeBytes) {
        [pscustomobject]@{ Edition = 'Archivo'; Field = 'Tamaño del archivo (bytes)'; A = [string]$A.Stamp.SizeBytes; B = [string]$B.Stamp.SizeBytes; Status = 'Diferente' }
    }
    $fields = [ordered]@{ Index = 'Índice'; Name = 'Nombre'; Description = 'Descripción'; SizeBytes = 'Sin comprimir (bytes)';
        Architecture = 'Arquitectura'; Version = 'Versión'; Build = 'Compilación'; Revision = 'Revisión';
        EditionID = 'Edición'; InstallationType = 'Tipo de instalación'; Created = 'Creado'; Modified = 'Modificado';
        Languages = 'Idiomas'; DefaultLanguage = 'Idioma predeterminado'; ProductType = 'Tipo de producto';
        ProductSuite = 'Suite'; SystemRoot = 'Directorio Windows'; WimBoot = 'WIMBoot' }
    foreach ($key in @(@($groupsA.Keys) + @($groupsB.Keys) | Sort-Object -Unique)) {
        $left = @($groupsA[$key] | Where-Object { $null -ne $_ }); $right = @($groupsB[$key] | Where-Object { $null -ne $_ })
        $label = if ($left.Count) { $left[0].Name } else { $right[0].Name }
        if ($left.Count -gt 1 -or $right.Count -gt 1) {
            [pscustomobject]@{ Edition = $label; Field = 'Coincidencia de edición'; A = ($left.Index -join ', '); B = ($right.Index -join ', '); Status = 'Ambigua' }
            continue
        }
        if ($left.Count -eq 0 -or $right.Count -eq 0) {
            $status = if ($A.State -ne 'Completo' -or $B.State -ne 'Completo') { 'No verificable' } elseif ($left.Count) { 'Solo en A' } else { 'Solo en B' }
            [pscustomobject]@{ Edition = $label; Field = 'Edición'; A = ($left.Name -join ''); B = ($right.Name -join ''); Status = $status }
            continue
        }
        $different = $false
        foreach ($field in $fields.Keys) {
            $vA = $left[0].$field; $vB = $right[0].$field
            if ($field -eq 'Languages') { $vA = (@($vA) | Sort-Object) -join ', '; $vB = (@($vB) | Sort-Object) -join ', ' }
            if ([string]$vA -cne [string]$vB) {
                $different = $true
                [pscustomobject]@{ Edition = $label; Field = $fields[$field]; A = [string]$vA; B = [string]$vB; Status = 'Diferente' }
            }
        }
        if (-not $different) { [pscustomobject]@{ Edition = $label; Field = 'Metadatos comparados'; A = "Índice $($left[0].Index)"; B = "Índice $($right[0].Index)"; Status = 'Igual' } }
    }
}

function Get-IsoInfoTableRows {
    param($Dataset)
    foreach ($row in $Dataset.Rows.Values) {
        $output = [ordered]@{ Archivo = $Dataset.Path; EstadoLectura = $Dataset.State; ErrorLectura = $Dataset.Error;
            TamanoArchivoBytes = $Dataset.Stamp.SizeBytes; LeidoUTC = $Dataset.ReadAtUtc }
        foreach ($prop in $row.PSObject.Properties) {
            $output[$prop.Name] = if ($prop.Name -eq 'Languages') { $prop.Value -join ', ' } else { $prop.Value }
        }
        [pscustomobject]$output
    }
}

function Write-IsoInfoReport {
    param([string]$Path, $Report)
    $encoding = New-Object Text.UTF8Encoding($true)
    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    $rows = @($Report.Rows)
    switch ($extension) {
        '.json' { $content = ConvertTo-Json -InputObject $Report -Depth 12 }
        '.csv' {
            if ($rows.Count -eq 0) {
                $rows = @([pscustomobject]@{ Reporte = $Report.Title; Resumen = $Report.Summary; ExportadoUTC = $Report.ExportedUtc })
            }
            $safe = foreach ($row in $rows) {
                $props = [ordered]@{ Reporte = $Report.Title; FechaAnalisisUTC = $Report.AnalysisUtc; Equipo = $Report.ComputerName; VersionIsoCore = $Report.ApplicationVersion; FechaExportacionUTC = $Report.ExportedUtc }
                foreach ($p in $row.PSObject.Properties) {
                    $v = $p.Value
                    # Evitar que nombres/metadatos de una imagen se ejecuten como fórmulas en Excel.
                    if ($v -is [string] -and $v -match '^[\s]*[=+@-]|^[\t\r\n]') { $v = "'" + $v }
                    $props[$p.Name] = $v
                }
                foreach ($name in @($props.Keys)) {
                    $v = $props[$name]
                    if ($v -is [string] -and $v -match '^[\s]*[=+@-]|^[\t\r\n]') { $props[$name] = "'" + $v }
                }
                [pscustomobject]$props
            }
            $content = (@($safe | ConvertTo-Csv -NoTypeInformation -UseCulture) -join "`r`n") + "`r`n"
        }
        '.html' {
            $title = [Net.WebUtility]::HtmlEncode([string]$Report.Title)
            $summary = [Net.WebUtility]::HtmlEncode([string]$Report.Summary)
            $builder = New-Object Text.StringBuilder
            [void]$builder.Append('<!doctype html><html lang="es"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>')
            [void]$builder.Append($title)
            [void]$builder.Append('</title><style>body{font:14px system-ui,sans-serif;margin:28px;color:#172332}h1{font-size:24px}p{white-space:pre-wrap}table{border-collapse:collapse;width:100%}th,td{border:1px solid #ced7df;padding:8px;text-align:left;vertical-align:top;white-space:pre-wrap}th{background:#e8f3f7;position:sticky;top:0}tr:nth-child(even){background:#f6f8fa}.table{overflow:auto}footer{margin-top:20px;color:#526273}</style><h1>')
            [void]$builder.Append($title); [void]$builder.Append('</h1><p>'); [void]$builder.Append($summary)
            [void]$builder.Append('</p><p>IsoCore ' + [Net.WebUtility]::HtmlEncode([string]$Report.ApplicationVersion) +
                ' | Equipo: ' + [Net.WebUtility]::HtmlEncode([string]$Report.ComputerName) +
                ' | Análisis UTC: ' + [Net.WebUtility]::HtmlEncode([string]$Report.AnalysisUtc) + '</p><div class="table"><table><thead><tr>')
            $names = if ($rows.Count) { @($rows[0].PSObject.Properties.Name) } else { @() }
            foreach ($name in $names) { [void]$builder.Append('<th>' + [Net.WebUtility]::HtmlEncode($name) + '</th>') }
            [void]$builder.Append('</tr></thead><tbody>')
            foreach ($row in $rows) {
                [void]$builder.Append('<tr>')
                foreach ($name in $names) { [void]$builder.Append('<td>' + [Net.WebUtility]::HtmlEncode([string]$row.$name) + '</td>') }
                [void]$builder.Append('</tr>')
            }
            [void]$builder.Append('</tbody></table></div><footer>IsoCore 1.3.1 · ' + [Net.WebUtility]::HtmlEncode([string]$Report.ExportedUtc) + '</footer></html>')
            $content = $builder.ToString()
        }
        default { throw 'Usa una extensión .csv, .html o .json.' }
    }
    [IO.File]::WriteAllText($Path, [string]$content, $encoding)
}

function Invoke-IsoInfoInventory {
    param($Request, $Shared)
    $ErrorActionPreference = 'Stop'
    $mountPath = $null; $mountAttempted = $false; $released = $false; $outcome = 'Completo'; $done = 0; $errors = 0
    try {
        Import-Module Dism -ErrorAction Stop
        if ([IO.Path]::GetExtension($Request.Path) -ine '.wim') { throw 'El inventario requiere una imagen WIM. La consulta de metadatos también admite ESD.' }
        $stamp = Get-IsoInfoFileStamp $Request.Path
        if ($stamp.SizeBytes -ne $Request.ExpectedStamp.SizeBytes -or $stamp.ModifiedUtc -ne $Request.ExpectedStamp.ModifiedUtc) {
            throw 'El archivo cambió. Vuelve a leerlo antes de consultar el inventario.'
        }
        if ($Shared.CancelRequested) { $outcome = 'Cancelado'; return }
        $mountPath = Join-Path ([IO.Path]::GetTempPath()) ('IsoCore_Info_' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($mountPath)
        Send-IsoInfoEvent $Shared 'Current' 'Montando el índice en modo de solo lectura...'
        $mountAttempted = $true
        Mount-WindowsImage -ImagePath $Request.Path -Index $Request.Index -Path $mountPath -ReadOnly -ErrorAction Stop | Out-Null
        foreach ($category in @('Controladores','Paquetes','Características')) {
            if ($Shared.CancelRequested) { $outcome = 'Cancelado'; break }
            Send-IsoInfoEvent $Shared 'Current' "Consultando $category..."
            try {
                $items = switch ($category) {
                    'Controladores' { @(Get-WindowsDriver -Path $mountPath -All -ErrorAction Stop) }
                    'Paquetes' { @(Get-WindowsPackage -Path $mountPath -ErrorAction Stop) }
                    'Características' { @(Get-WindowsOptionalFeature -Path $mountPath -ErrorAction Stop) }
                }
                $rows = @(foreach ($item in $items) {
                    [pscustomobject]@{ Category = $category; Name = [string](Get-IsoInfoProperty $item @('Driver','PackageName','FeatureName'));
                        Version = [string](Get-IsoInfoProperty $item @('Version')); State = [string](Get-IsoInfoProperty $item @('PackageState','State'));
                        Provider = [string](Get-IsoInfoProperty $item @('ProviderName')); Detail = [string](Get-IsoInfoProperty $item @('OriginalFileName','ReleaseType')); Error = '' }
                })
                Send-IsoInfoEvent $Shared 'Inventory' ([pscustomobject]@{ Category = $category; Rows = $rows; Count = $rows.Count; Error = '' })
            } catch {
                $errors++
                Send-IsoInfoEvent $Shared 'Inventory' ([pscustomobject]@{ Category = $category; Rows = @(); Count = 0; Error = $_.Exception.Message })
            }
            $done++
            Send-IsoInfoEvent $Shared 'Progress' ([pscustomobject]@{ Done = $done; Total = 4; Failures = $errors })
        }
        if ($errors -gt 0 -and $outcome -eq 'Completo') { $outcome = 'Con errores' }
    } catch {
        $outcome = 'Error'
        Send-IsoInfoEvent $Shared 'Error' $_.Exception.Message
    } finally {
        if ($mountAttempted) {
            Send-IsoInfoEvent $Shared 'Current' 'Liberando el montaje de solo lectura...'
            try {
                $mounted = @(Get-WindowsImage -Mounted -ErrorAction Stop | Where-Object { $_.Path -ieq $mountPath -or $_.MountPath -ieq $mountPath })
                if ($mounted.Count -gt 0) { Dismount-WindowsImage -Path $mountPath -Discard -ErrorAction Stop | Out-Null }
                $released = $true
            } catch {
                $outcome = 'Error de desmontaje'
                Send-IsoInfoEvent $Shared 'Error' "No se pudo liberar el montaje $mountPath. $($_.Exception.Message)"
            }
        } else { $released = $true }
        # Nunca borrar recursivamente una ruta que podría seguir montada.
        if ($mountPath -and $released) { try { [IO.Directory]::Delete($mountPath, $false) } catch {} }
        if ($mountAttempted -and $released) {
            $done++
            Send-IsoInfoEvent $Shared 'Progress' ([pscustomobject]@{ Done = $done; Total = 4; Failures = $errors })
        }
        Send-IsoInfoEvent $Shared 'Finished' ([pscustomobject]@{ Outcome = $outcome; Done = $done; Total = 4; Failures = $errors; Error = '' })
    }
}

function New-IsoInfoDataset {
    param([string]$Path)
    [pscustomobject]@{ Path = $Path; Stamp = $null; Rows = [ordered]@{}; State = 'Leyendo'; Error = ''; ReadAtUtc = '' }
}

function Select-IsoInfoRows {
    param($Dataset, [string]$Search = '', [string]$Architecture = 'Todas', [string]$Language = 'Todos', [string]$Sort = 'Index', [bool]$Descending = $false)
    if ($null -eq $Dataset) { return }
    $rows = @($Dataset.Rows.Values | Where-Object {
        ($Architecture -eq 'Todas' -or $_.Architecture -eq $Architecture) -and
        ($Language -eq 'Todos' -or $Language -in $_.Languages) -and
        ([string]::IsNullOrWhiteSpace($Search) -or
         (($_.Name, $_.EditionID, $_.Architecture, $_.Language, $_.Version, $_.DisplayVersion, $_.Description, $_.Status, $_.Message) -join ' ').IndexOf($Search, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    })
    $rows | Sort-Object -Property @{ Expression = { $_.$Sort }; Descending = $Descending }, Index
}

function New-IsoInfoReport {
    param([string]$Title, [string]$Summary, [object[]]$Rows, $Sources = @(), [string]$AnalysisUtc = '')
    $times = @($Rows | ForEach-Object { Get-IsoInfoProperty $_ @('LeidoUTC'); Get-IsoInfoProperty $_ @('AdvancedReadUtc'); Get-IsoInfoProperty $_ @('VerifiedUtc') } | Where-Object { $_ } | Sort-Object)
    [pscustomobject][ordered]@{ SchemaVersion = 2; ApplicationVersion = '1.3.1'; Title = $Title; Summary = $Summary;
        AnalysisUtc = $(if ($AnalysisUtc) { $AnalysisUtc } elseif ($times.Count) { $times[-1] } else { '' }); ComputerName = [Environment]::MachineName;
        ExportedUtc = [datetime]::UtcNow.ToString('o'); Sources = @($Sources); Rows = @($Rows) }
}

function Show-IsoInfoReport {
    param($Owner, $Palette, $Report, [string[]]$Columns, [string[]]$Labels)
    $saveCommand = Get-Command Write-IsoInfoReport
    $window = New-Object System.Windows.Forms.Form
    try {
        $window.Text = $Report.Title
        $window.StartPosition = 'CenterParent'
        $window.ClientSize = New-Object Drawing.Size(980, 540)
        $window.MinimumSize = New-Object Drawing.Size(720, 440)
        $window.BackColor = $Palette.Background; $window.ForeColor = $Palette.Text
        $window.Font = New-Object Drawing.Font('Segoe UI', 9)
        $layout = New-Object System.Windows.Forms.TableLayoutPanel
        $layout.Dock = 'Fill'; $layout.Padding = New-Object System.Windows.Forms.Padding(12)
        $layout.ColumnCount = 1; $layout.RowCount = 4
        [void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 100)))
        [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 88)))
        [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
        [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
        $layout.RowStyles.Insert(2, (New-Object System.Windows.Forms.RowStyle('Absolute', 110)))
        $summaryBox = New-Object System.Windows.Forms.TextBox
        $summaryBox.Multiline = $true; $summaryBox.ReadOnly = $true; $summaryBox.Dock = 'Fill'; $summaryBox.ScrollBars = 'Vertical'
        $summaryBox.BackColor = $Palette.Panel; $summaryBox.ForeColor = $Palette.Text; $summaryBox.Text = $Report.Summary
        $grid = New-Object System.Windows.Forms.ListView
        $grid.Dock = 'Fill'; $grid.View = 'Details'; $grid.FullRowSelect = $true; $grid.GridLines = $true
        $grid.BackColor = $Palette.Panel; $grid.ForeColor = $Palette.Text
        for ($i = 0; $i -lt $Columns.Count; $i++) { [void]$grid.Columns.Add($Labels[$i], $(if ($i -eq 0) { 210 } else { 170 })) }
        foreach ($row in $Report.Rows) {
            $item = New-Object System.Windows.Forms.ListViewItem([string]$row.($Columns[0]))
            for ($i = 1; $i -lt $Columns.Count; $i++) { [void]$item.SubItems.Add([string]$row.($Columns[$i])) }
            $item.Tag = $row
            [void]$grid.Items.Add($item)
        }
        $valueBox = New-Object System.Windows.Forms.TextBox
        $valueBox.Name = 'ImageInfoFullValue'; $valueBox.Multiline = $true; $valueBox.ReadOnly = $true
        $valueBox.Dock = 'Fill'; $valueBox.ScrollBars = 'Vertical'; $valueBox.BackColor = $Palette.Panel; $valueBox.ForeColor = $Palette.Text
        $valueBox.Text = 'Selecciona una fila para leer y copiar su contenido completo.'
        $grid.Add_SelectedIndexChanged({
            if ($grid.SelectedItems.Count -ne 1) { return }
            $selectedRow = $grid.SelectedItems[0].Tag
            $valueBox.Text = (@(for ($n = 0; $n -lt $Columns.Count; $n++) { $Labels[$n] + ': ' + [string]$selectedRow.($Columns[$n]) }) -join "`r`n")
        }.GetNewClosure())
        $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
        $buttons.Dock = 'Fill'; $buttons.AutoSize = $true
        $export = New-Object System.Windows.Forms.Button
        $export.Text = 'Exportar reporte'; $export.AutoSize = $true; $export.BackColor = $Palette.Panel; $export.ForeColor = $Palette.Cyan
        $close = New-Object System.Windows.Forms.Button
        $close.Text = 'Cerrar'; $close.AutoSize = $true; $close.BackColor = $Palette.Panel; $close.ForeColor = $Palette.Text
        $export.Add_Click({
            $dialog = New-Object System.Windows.Forms.SaveFileDialog
            try {
                $dialog.Filter = 'HTML (*.html)|*.html|JSON (*.json)|*.json|CSV (*.csv)|*.csv'
                $dialog.FileName = 'IsoCore_Reporte'; $dialog.AddExtension = $true
                if ($dialog.ShowDialog($window) -eq 'OK') {
                    & $saveCommand -Path $dialog.FileName -Report $Report
                    $summaryBox.Text = $Report.Summary + "`r`nGuardado: " + $dialog.FileName
                }
            } catch { $summaryBox.Text = $Report.Summary + "`r`nNo se pudo guardar: " + $_.Exception.Message }
            finally { $dialog.Dispose() }
        }.GetNewClosure())
        $close.Add_Click({ $window.Close() }.GetNewClosure())
        [void]$buttons.Controls.Add($export); [void]$buttons.Controls.Add($close)
        [void]$layout.Controls.Add($summaryBox,0,0); [void]$layout.Controls.Add($grid,0,1); [void]$layout.Controls.Add($valueBox,0,2); [void]$layout.Controls.Add($buttons,0,3)
        [void]$window.Controls.Add($layout)
        [void]$window.ShowDialog($Owner)
    } finally { $window.Dispose() }
}

function New-IsoCoreImageInfoTab {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Palette, [scriptblock]$LogAction)
    $ErrorActionPreference = 'Stop'
    $modulePath = $script:IsoInfoModulePath
    # CommandInfo mantiene el ámbito del módulo al ejecutarse eventos GetNewClosure.
    $api = @{}
    foreach ($command in @('New-IsoInfoDataset','Select-IsoInfoRows','Get-IsoInfoPercent','Format-IsoInfoBytes','Compare-IsoInfoImages',
        'Get-IsoInfoTableRows','Write-IsoInfoReport','New-IsoInfoReport','Show-IsoInfoReport')) {
        $api[$command] = Get-Command $command -CommandType Function
    }
    $tab = $null; $tip = $null; $timer = $null
    $state = @{ Busy = $false; Closing = $false; CloseRequested = $false; Muting = $false; Polling = $false;
        A = $null; B = $null; PowerShell = $null; Runspace = $null; Handle = $null; Shared = $null;
        Request = $null; Final = $null; Candidates = @(); AutoRead = $null; Sort = 'Index'; Descending = $false;
        Done = 0; Total = 0; Failures = 0; Current = ''; Fatal = ''; Inventory = $null; InventoryResult = $null; Verification = $null; VerificationResult = $null }
    $actions = @{}
    try {
        $tab = New-Object System.Windows.Forms.TabPage
        $tab.Name = 'IsoCoreImageInfo'; $tab.Text = 'Info WIM / ESD'
        $tab.BackColor = $Palette.Background; $tab.ForeColor = $Palette.Text; $tab.UseVisualStyleBackColor = $false
        $tab.Padding = New-Object System.Windows.Forms.Padding(8)
        $tip = New-Object System.Windows.Forms.ToolTip
        $tip.AutoPopDelay = 15000; $tip.InitialDelay = 300; $tip.ShowAlways = $true
        $root = New-Object System.Windows.Forms.TableLayoutPanel
        $root.Dock = 'Fill'; $root.ColumnCount = 1; $root.RowCount = 9
        [void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent',100)))
        for ($i = 0; $i -lt 9; $i++) {
            if ($i -eq 7) { [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent',100))) }
            else { [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize'))) }
        }
        $newLabel = {
            param([string]$Text)
            $label = New-Object System.Windows.Forms.Label
            $label.Text = $Text; $label.AutoSize = $true; $label.ForeColor = $Palette.Secondary
            $label.Margin = New-Object System.Windows.Forms.Padding(3,7,8,3)
            return $label
        }.GetNewClosure()
        $newButton = {
            param([string]$Name,[string]$Text)
            $button = New-Object System.Windows.Forms.Button
            $button.Name = $Name; $button.Text = $Text; $button.AutoSize = $true; $button.Height = 29
            $button.BackColor = $Palette.Panel; $button.ForeColor = $Palette.Cyan; $button.FlatStyle = 'Flat'
            $button.FlatAppearance.BorderSize = 1; $button.FlatAppearance.BorderColor = $Palette.Muted
            $button.Margin = New-Object System.Windows.Forms.Padding(3)
            return $button
        }.GetNewClosure()
        $newFlow = {
            $flow = New-Object System.Windows.Forms.FlowLayoutPanel
            $flow.Dock = 'Fill'; $flow.AutoSize = $true; $flow.WrapContents = $true
            return $flow
        }
        $title = & $newLabel 'Información de imágenes Windows'
        $title.Font = New-Object Drawing.Font('Segoe UI',14,[Drawing.FontStyle]::Bold)
        $title.ForeColor = $Palette.Cyan
        [void]$root.Controls.Add($title,0,0)

        $driveBar = & $newFlow
        [void]$driveBar.Controls.Add((& $newLabel 'Unidad:'))
        $drive = New-Object System.Windows.Forms.ComboBox
        $drive.Name = 'ImageInfoDrive'; $drive.DropDownStyle = 'DropDownList'; $drive.Width = 450
        $drive.BackColor = $Palette.Panel; $drive.ForeColor = $Palette.Text; $drive.DisplayMember = 'Display'
        $refresh = & $newButton 'ImageInfoRefresh' 'Actualizar unidades'
        [void]$driveBar.Controls.Add($drive); [void]$driveBar.Controls.Add($refresh)
        [void]$root.Controls.Add($driveBar,0,1)

        $pathBar = New-Object System.Windows.Forms.TableLayoutPanel
        $pathBar.Dock = 'Fill'; $pathBar.AutoSize = $true; $pathBar.ColumnCount = 5; $pathBar.RowCount = 1
        [void]$pathBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
        [void]$pathBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent',100)))
        1..3 | ForEach-Object { [void]$pathBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize'))) }
        $path = New-Object System.Windows.Forms.TextBox
        $path.Name = 'ImageInfoPath'; $path.Dock = 'Fill'; $path.BackColor = $Palette.Panel; $path.ForeColor = $Palette.Text
        $path.Margin = New-Object System.Windows.Forms.Padding(3,5,3,3)
        $browseFile = & $newButton 'ImageInfoBrowse' 'Archivo...'
        $browseFolder = & $newButton 'ImageInfoBrowseFolder' 'Carpeta...'
        $read = & $newButton 'ImageInfoRead' 'Leer'
        [void]$pathBar.Controls.Add((& $newLabel 'Ruta:'),0,0); [void]$pathBar.Controls.Add($path,1,0)
        [void]$pathBar.Controls.Add($browseFile,2,0); [void]$pathBar.Controls.Add($browseFolder,3,0); [void]$pathBar.Controls.Add($read,4,0)
        [void]$root.Controls.Add($pathBar,0,2)

        $candidateBar = New-Object System.Windows.Forms.TableLayoutPanel
        $candidateBar.Dock = 'Fill'; $candidateBar.AutoSize = $true; $candidateBar.ColumnCount = 2; $candidateBar.RowCount = 1
        [void]$candidateBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('AutoSize')))
        [void]$candidateBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent',100)))
        $candidates = New-Object System.Windows.Forms.ComboBox
        $candidates.Name = 'ImageInfoCandidates'; $candidates.DropDownStyle = 'DropDownList'; $candidates.Dock = 'Fill'
        $candidates.DisplayMember = 'Display'; $candidates.BackColor = $Palette.Panel; $candidates.ForeColor = $Palette.Text
        [void]$candidateBar.Controls.Add((& $newLabel 'Imágenes:'),0,0); [void]$candidateBar.Controls.Add($candidates,1,0)
        [void]$root.Controls.Add($candidateBar,0,3)

        $fileLabel = & $newLabel 'Archivo: ninguno seleccionado'
        $fileLabel.Name = 'ImageInfoFile'; $fileLabel.AutoSize = $false; $fileLabel.AutoEllipsis = $true; $fileLabel.Dock = 'Fill'; $fileLabel.Height = 38
        [void]$root.Controls.Add($fileLabel,0,4)
        $filters = & $newFlow
        [void]$filters.Controls.Add((& $newLabel 'Buscar:'))
        $search = New-Object System.Windows.Forms.TextBox
        $search.Name = 'ImageInfoSearch'; $search.Width = 210; $search.BackColor = $Palette.Panel; $search.ForeColor = $Palette.Text
        [void]$filters.Controls.Add($search); [void]$filters.Controls.Add((& $newLabel 'Arquitectura:'))
        $archFilter = New-Object System.Windows.Forms.ComboBox
        $archFilter.Name = 'ImageInfoArchFilter'; $archFilter.DropDownStyle = 'DropDownList'; $archFilter.Width = 100
        $archFilter.BackColor = $Palette.Panel; $archFilter.ForeColor = $Palette.Text
        [void]$archFilter.Items.Add('Todas'); $archFilter.SelectedIndex = 0
        [void]$filters.Controls.Add($archFilter); [void]$filters.Controls.Add((& $newLabel 'Idioma:'))
        $langFilter = New-Object System.Windows.Forms.ComboBox
        $langFilter.Name = 'ImageInfoLangFilter'; $langFilter.DropDownStyle = 'DropDownList'; $langFilter.Width = 130
        $langFilter.BackColor = $Palette.Panel; $langFilter.ForeColor = $Palette.Text
        [void]$langFilter.Items.Add('Todos'); $langFilter.SelectedIndex = 0
        [void]$filters.Controls.Add($langFilter)
        [void]$root.Controls.Add($filters,0,5)

        $toolbar = & $newFlow
        $details = & $newButton 'ImageInfoDetails' 'Detalles'
        $copy = & $newButton 'ImageInfoCopy' 'Copiar filas'
        $compare = & $newButton 'ImageInfoCompare' 'Comparar con...'
        $viewComparison = & $newButton 'ImageInfoViewComparison' 'Ver comparación'
        $inventory = & $newButton 'ImageInfoInventory' 'Inventario WIM'
        $viewInventory = & $newButton 'ImageInfoViewInventory' 'Ver inventario'
        $advanced = & $newButton 'ImageInfoAdvanced' 'Analizar índice'
        $verify = & $newButton 'ImageInfoVerify' 'Verificar archivo'
        $viewVerification = & $newButton 'ImageInfoViewVerification' 'Ver verificación'
        foreach ($button in @($details,$copy,$advanced,$compare,$viewComparison,$inventory,$viewInventory,$verify,$viewVerification)) { [void]$toolbar.Controls.Add($button) }
        [void]$root.Controls.Add($toolbar,0,6)
        $list = New-Object System.Windows.Forms.ListView
        $list.Name = 'ImageInfoList'; $list.Dock = 'Fill'; $list.View = 'Details'; $list.FullRowSelect = $true
        $list.GridLines = $true; $list.MultiSelect = $true; $list.HideSelection = $false; $list.ShowItemToolTips = $true
        $list.BackColor = $Palette.Panel; $list.ForeColor = $Palette.Text; $list.Font = New-Object Drawing.Font('Segoe UI',9)
        $columnKeys = @('Index','Name','Status','SizeBytes','Architecture','Version','Build','Revision','Modified','Language','EditionID','DefaultLanguage','DisplayVersion','ServicingStackVersion','CumulativeUpdateVersion','VerificationState','DescriptionShort')
        foreach ($column in @(@('Ind.',48),@('Nombre',205),@('Estado',88),@('Sin comprimir',112),@('Arq.',60),
            @('Versión',126),@('Compilación',85),@('Revisión',73),@('Modificado',145),@('Idiomas',195),@('EditionID',120),@('Idioma pred.',110),@('DisplayVersion',110),@('SSU instalada',115),@('Acumulativa',115),@('Verificación',205),@('Descripción corta',300))) {
            [void]$list.Columns.Add([string]$column[0],[int]$column[1])
        }
        [void]$root.Controls.Add($list,0,7)
        $footer = New-Object System.Windows.Forms.TableLayoutPanel
        $footer.Dock = 'Fill'; $footer.AutoSize = $true; $footer.ColumnCount = 1; $footer.RowCount = 2
        [void]$footer.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent',100)))
        [void]$footer.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
        [void]$footer.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
        $status = & $newLabel 'Listo. Selecciona una unidad, carpeta o archivo WIM/ESD.'
        $status.Name = 'ImageInfoStatus'; $status.AutoSize = $false; $status.AutoEllipsis = $true; $status.Height = 45; $status.Dock = 'Fill'
        $footerButtons = & $newFlow
        $progress = New-Object System.Windows.Forms.ProgressBar
        $progress.Name = 'ImageInfoProgress'; $progress.Width = 190; $progress.Height = 24; $progress.Style = 'Continuous'
        $progress.Minimum = 0; $progress.Maximum = 100; $progress.Value = 0
        $percent = & $newLabel '0 %'
        $percent.Name = 'ImageInfoPercent'
        $cancel = & $newButton 'ImageInfoCancel' 'Cancelar'
        $retry = & $newButton 'ImageInfoRetry' 'Reintentar pendientes'
        $export = & $newButton 'ImageInfoExport' 'Exportar'
        $clear = & $newButton 'ImageInfoClear' 'Limpiar'
        foreach ($control in @($progress,$percent,$cancel,$retry,$export,$clear)) { [void]$footerButtons.Controls.Add($control) }
        [void]$footer.Controls.Add($status,0,0); [void]$footer.Controls.Add($footerButtons,0,1)
        [void]$root.Controls.Add($footer,0,8); [void]$tab.Controls.Add($root)
        $tip.SetToolTip($progress,'Avanza al terminar cada índice, incluido un intento que termine con error. No representa tiempo restante.')
        $tip.SetToolTip($retry,'Reintenta los índices fallidos o pendientes de la imagen A; conserva los índices correctos.')
        $tip.SetToolTip($inventory,'Consulta controladores, paquetes y características del índice seleccionado; montaje WIM de solo lectura.')
        $tip.SetToolTip($advanced,'Consulta idiomas, DisplayVersion y actualizaciones del índice seleccionado. Requiere WIM y montaje de solo lectura.')
        $tip.SetToolTip($verify,'Comprueba todos los índices mediante DISM -CheckIntegrity al exportar una copia temporal. Elige una carpeta con espacio suficiente; puede tardar varios minutos.')
        $tip.SetToolTip($list,'Doble clic: detalles. Clic en una columna: ordenar. Ctrl+C: copiar filas seleccionadas.')
        $tip.SetToolTip($export,'Exporta todos los índices de A, incluidos errores y pendientes. Los filtros solo afectan a la tabla.')

        $actions.Log = {
            param([string]$Level,[string]$Message)
            if ($null -ne $LogAction) { try { & $LogAction $Level "Info WIM/ESD: $Message" } catch {} }
        }.GetNewClosure()
        $actions.Status = {
            param([string]$Text,[string]$Tone = 'Normal')
            if ($tab.IsDisposed) { return }
            $status.Text = $Text
            $status.ForeColor = switch ($Tone) { 'Error' { [Drawing.Color]::OrangeRed } 'Warning' { [Drawing.Color]::Orange } 'Success' { $Palette.Green } default { $Palette.Secondary } }
            $tip.SetToolTip($status,$Text)
        }.GetNewClosure()
        $actions.Controls = {
            if ($state.Closing -or $tab.IsDisposed) { return }
            foreach ($control in @($path,$drive,$refresh,$browseFile,$browseFolder,$read,$candidates,$clear)) { $control.Enabled = -not $state.Busy }
            $cancel.Enabled = $state.Busy -and -not $state.Shared.CancelRequested
            $hasRows = $null -ne $state.A -and $state.A.Rows.Count -gt 0
            $selected = $list.SelectedItems.Count -gt 0
            $details.Enabled = $selected
            $copy.Enabled = $selected
            $export.Enabled = -not $state.Busy -and $hasRows
            $compare.Enabled = -not $state.Busy -and $hasRows
            $viewComparison.Enabled = -not $state.Busy -and $null -ne $state.B
            $retry.Enabled = -not $state.Busy -and $hasRows -and @($state.A.Rows.Values | Where-Object { $_.Status -in @('Error','Pendiente') }).Count -gt 0
            $inventory.Enabled = -not $state.Busy -and $list.SelectedItems.Count -eq 1 -and
                $null -ne $state.A -and [IO.Path]::GetExtension($state.A.Path) -ieq '.wim' -and $list.SelectedItems[0].Tag.Status -eq 'Correcto'
            $viewInventory.Enabled = -not $state.Busy -and $null -ne $state.InventoryResult
            $advanced.Enabled = $inventory.Enabled
            $verify.Enabled = -not $state.Busy -and $hasRows -and $null -ne $state.A.Stamp
            $viewVerification.Enabled = -not $state.Busy -and $null -ne $state.VerificationResult
        }.GetNewClosure()
        $actions.Render = {
            if ($state.Closing -or $tab.IsDisposed) { return }
            $selectedIndices = @($list.SelectedItems | ForEach-Object { $_.Tag.Index })
            $rows = @(& $api['Select-IsoInfoRows'] -Dataset $state.A -Search $search.Text -Architecture ([string]$archFilter.SelectedItem) -Language ([string]$langFilter.SelectedItem) -Sort $state.Sort -Descending $state.Descending)
            $list.BeginUpdate()
            try {
                $list.Items.Clear()
                foreach ($row in $rows) {
                    $item = New-Object System.Windows.Forms.ListViewItem([string]$row.Index)
                    foreach ($value in @($row.Name,$row.Status,$row.SizeText,$row.Architecture,$row.Version,$row.Build,$row.Revision,$row.Modified,$row.Language,$row.EditionID,$row.DefaultLanguage,$row.DisplayVersion,$row.ServicingStackVersion,$row.CumulativeUpdateVersion,$row.VerificationState,$row.DescriptionShort)) {
                        [void]$item.SubItems.Add($(if ([string]::IsNullOrWhiteSpace([string]$value)) { '—' } else { [string]$value }))
                    }
                    $item.Tag = $row; $item.ToolTipText = (@($row.Message,$row.Description,$row.DefaultLanguageStatus,$row.AdvancedError) | Where-Object { $_ }) -join "`r`n"
                    if ($row.Status -eq 'Error') { $item.ForeColor = [Drawing.Color]::OrangeRed }
                    elseif ($row.Status -eq 'Pendiente') { $item.ForeColor = $Palette.Muted }
                    [void]$list.Items.Add($item)
                    if ($row.Index -in $selectedIndices) { $item.Selected = $true }
                }
            } finally { $list.EndUpdate() }
            if ($null -ne $state.A) {
                $totalRows = $state.A.Rows.Count
                $fileLabel.Text = "A: $($state.A.Path)`r`nArchivo: $(& $api['Format-IsoInfoBytes'] $state.A.Stamp.SizeBytes) | Índices visibles: $($rows.Count)/$totalRows | $($state.A.State)"
            } else { $fileLabel.Text = 'Archivo: ninguno seleccionado' }
            $tip.SetToolTip($fileLabel,$fileLabel.Text)
            & $actions.Controls
        }.GetNewClosure()
        $actions.Filters = {
            $state.Muting = $true
            try {
                foreach ($entry in @(@($archFilter,'Todas','Architecture'),@($langFilter,'Todos','Languages'))) {
                    $control = $entry[0]; $previous = [string]$control.SelectedItem
                    $control.Items.Clear(); [void]$control.Items.Add($entry[1])
                    if ($null -ne $state.A) {
                        $values = @($state.A.Rows.Values | ForEach-Object { $_.($entry[2]) } | Where-Object { $_ } | Sort-Object -Unique)
                        foreach ($value in $values) { [void]$control.Items.Add([string]$value) }
                    }
                    $control.SelectedIndex = if ($control.Items.Contains($previous)) { $control.Items.IndexOf($previous) } else { 0 }
                }
            } finally { $state.Muting = $false }
        }.GetNewClosure()
        $actions.Reset = {
            $state.A = $null; $state.B = $null; $state.Inventory = $null; $state.InventoryResult = $null; $state.Verification = $null; $state.VerificationResult = $null
            $state.Muting = $true
            try { $candidates.Items.Clear(); $candidates.SelectedIndex = -1; $search.Clear() } finally { $state.Muting = $false }
            $state.Candidates = @(); $progress.Value = 0; $percent.Text = '0 %'
            & $actions.Filters; & $actions.Render
        }.GetNewClosure()
        $actions.Progress = {
            param($Data)
            $state.Done = [int]$Data.Done; $state.Total = [int]$Data.Total; $state.Failures = [int]$Data.Failures
            $value = & $api['Get-IsoInfoPercent'] $state.Done $state.Total
            $progress.Value = [math]::Min(100,[math]::Max(0,$value)); $percent.Text = "$($progress.Value) %"
            $unit = if ($state.Request.Operation -in @('Inventory','Advanced','Verify')) { 'tareas' } else { 'índices' }
            $prefix = if ($state.Request.Target -eq 'B') { 'Imagen B — ' } else { '' }
            $cancelText = if ($state.Shared.CancelRequested) { 'Cancelación solicitada. Esperando la consulta actual.' } else { $state.Current }
            & $actions.Status "${prefix}$($state.Done) de $($state.Total) $unit procesados; $($state.Failures) con error. $cancelText"
        }.GetNewClosure()
        $actions.Start = {
            param($Request)
            if ($state.Busy -or $state.Closing) { return }
            $state.Request = $Request; $state.Final = $null; $state.Fatal = ''; $state.Current = ''; $state.AutoRead = $null
            $state.Done = 0; $state.Total = 0; $state.Failures = 0
            $progress.Value = 0; $percent.Text = '0 %'
            $state.Shared = [hashtable]::Synchronized(@{ CancelRequested = $false; Events = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]') })
            $state.Busy = $true
            & $actions.Controls
            & $actions.Status $(if ($Request.Operation -eq 'Discover') { 'Buscando imágenes WIM/ESD...' } elseif ($Request.Operation -eq 'Inventory') { 'Preparando inventario...' } elseif ($Request.Operation -eq 'Advanced') { 'Preparando análisis avanzado...' } elseif ($Request.Operation -eq 'Verify') { 'Preparando verificación DISM...' } else { 'Detectando índices...' })
            try {
                $state.Runspace = [runspacefactory]::CreateRunspace(); $state.Runspace.Open()
                $state.PowerShell = [powershell]::Create(); $state.PowerShell.Runspace = $state.Runspace
                $worker = {
                    param($ModulePath,$Request,$Shared)
                    $ErrorActionPreference = 'Stop'
                    try {
                        $module = Import-Module -Name $ModulePath -Force -PassThru -ErrorAction Stop
                        & $module {
                            param($Request,$Shared)
                            switch ($Request.Operation) {
                                'Read' { Invoke-IsoInfoRead $Request $Shared }
                                'Inventory' { Invoke-IsoInfoInventory $Request $Shared }
                                'Advanced' { Invoke-IsoInfoAdvanced $Request $Shared }
                                'Verify' { Invoke-IsoInfoVerify $Request $Shared }
                                'Discover' {
                                    $found = @(Find-IsoInfoCandidates $Request.Path)
                                    if (-not $Shared.CancelRequested) { Send-IsoInfoEvent $Shared 'Candidates' $found }
                                    Send-IsoInfoEvent $Shared 'Finished' ([pscustomobject]@{ Outcome = $(if ($Shared.CancelRequested) { 'Cancelado' } else { 'Completo' }); Done = 0; Total = 0; Failures = 0; Error = '' })
                                }
                            }
                        } $Request $Shared
                    } catch {
                        $Shared.Events.Enqueue([pscustomobject]@{ Type = 'Error'; Data = $_.Exception.Message })
                        $Shared.Events.Enqueue([pscustomobject]@{ Type = 'Finished'; Data = [pscustomobject]@{ Outcome = 'Error'; Done = 0; Total = 0; Failures = 0; Error = $_.Exception.Message } })
                    }
                }
                [void]$state.PowerShell.AddScript($worker.ToString()).AddArgument($modulePath).AddArgument($Request).AddArgument($state.Shared)
                $state.Handle = $state.PowerShell.BeginInvoke()
                $state.Timer.Start()
            } catch {
                $state.Fatal = $_.Exception.Message
                & $actions.Release
                if ($Request.Operation -eq 'Read' -and $null -ne $state[$Request.Target]) {
                    $state[$Request.Target].State = 'Error'; $state[$Request.Target].Error = $state.Fatal
                    & $actions.Render
                }
                if ($Request.Operation -eq 'Verify' -and $null -ne $state.A) {
                    foreach ($row in $state.A.Rows.Values) { $row.VerificationState = 'No completada: Error'; $row.VerificationError = $state.Fatal }
                    & $actions.Render
                }
                & $actions.Status "No se pudo iniciar la operación: $($state.Fatal)" 'Error'
                & $actions.Log 'ERROR' $state.Fatal
            }
        }.GetNewClosure()
        $actions.ReadImage = {
            param([string]$ImagePath,[string]$Target = 'A',[bool]$Retry = $false)
            if ($state.Busy) { return }
            $indices = @(); $expected = $null
            if ($Retry) {
                $dataset = $state[$Target]
                $indices = @($dataset.Rows.Values | Where-Object { $_.Status -in @('Error','Pendiente') } | ForEach-Object { [int]$_.Index })
                if (-not $indices.Count) { return }
                $expected = $dataset.Stamp
            } else {
                $state[$Target] = & $api['New-IsoInfoDataset'] $ImagePath
                if ($Target -eq 'A') { $state.B = $null; $state.Inventory = $null; $state.InventoryResult = $null; $state.Verification = $null; $state.VerificationResult = $null }
            }
            $state[$Target].State = 'Leyendo'; $state[$Target].Error = ''
            & $actions.Render
            & $actions.Start ([pscustomobject]@{ Operation = 'Read'; Path = $ImagePath; Target = $Target; Indices = $indices; ExpectedStamp = $expected })
        }.GetNewClosure()
        $actions.Discover = {
            if ($state.Busy -or $state.Closing) { return }
            if ($null -ne $candidates.SelectedItem) { & $actions.ReadImage ([string]$candidates.SelectedItem.Path) 'A' $false; return }
            & $actions.Start ([pscustomobject]@{ Operation = 'Discover'; Path = $path.Text; Target = 'A' })
        }.GetNewClosure()
        $actions.ComparisonReport = {
            if ($null -eq $state.A -or $null -eq $state.B) { return $null }
            $rows = @(& $api['Compare-IsoInfoImages'] $state.A $state.B)
            $summary = "A: $($state.A.Path) [$($state.A.State)]`r`nB: $($state.B.Path) [$($state.B.State)]`r`nCoincidencia por edición, arquitectura y tipo de instalación; las coincidencias múltiples se marcan como ambiguas. Se comparan metadatos."
            if ($state.A.Error -or $state.B.Error) { $summary += "`r`nErrores: $($state.A.Error) $($state.B.Error)" }
            # Contexto también en cada fila para que el CSV sea autosuficiente.
            $rows = @($rows | Select-Object *, @{n='ArchivoA';e={$state.A.Path}}, @{n='ArchivoB';e={$state.B.Path}}, @{n='EstadoA';e={$state.A.State}}, @{n='EstadoB';e={$state.B.State}})
            & $api['New-IsoInfoReport'] 'Comparación de imágenes — IsoCore' $summary $rows @($state.A.Stamp,$state.B.Stamp) (@($state.A.ReadAtUtc,$state.B.ReadAtUtc) | Sort-Object | Select-Object -Last 1)
        }.GetNewClosure()
        $actions.ShowComparison = {
            $report = & $actions.ComparisonReport
            if ($null -ne $report) { & $api['Show-IsoInfoReport'] $tab.FindForm() $Palette $report @('Edition','Field','A','B','Status') @('Edición','Campo','Imagen A','Imagen B','Resultado') }
        }.GetNewClosure()
        $actions.ShowInventory = {
            if ($null -ne $state.InventoryResult) {
                & $api['Show-IsoInfoReport'] $tab.FindForm() $Palette $state.InventoryResult @('Category','Name','Version','State','Provider','Detail','Error') @('Categoría','Nombre','Versión','Estado','Proveedor','Detalle','Error')
            }
        }.GetNewClosure()
        $actions.ShowVerification = {
            if ($null -ne $state.VerificationResult) {
                & $api['Show-IsoInfoReport'] $tab.FindForm() $Palette $state.VerificationResult @('Index','Result','Error') @('Índice','Resultado','Detalle')
            }
        }.GetNewClosure()
        $actions.Drain = {
            $changed = $false; $evt = $null
            while ($state.Shared.Events.TryDequeue([ref]$evt)) {
                switch ($evt.Type) {
                    'File' { $state[$state.Request.Target].Stamp = $evt.Data; $changed = $true }
                    'Candidates' {
                        $state.Candidates = @($evt.Data)
                        $state.Muting = $true
                        try {
                            $candidates.Items.Clear(); $candidates.SelectedIndex = -1
                            foreach ($candidate in $state.Candidates) { [void]$candidates.Items.Add($candidate) }
                            if ($state.Candidates.Count -eq 1) { $candidates.SelectedIndex = 0; $state.AutoRead = $state.Candidates[0].Path }
                        } finally { $state.Muting = $false }
                    }
                    'Detected' {
                        foreach ($row in $evt.Data.Rows) { $state[$state.Request.Target].Rows[[string]$row.Index] = $row }
                        & $actions.Progress ([pscustomobject]@{ Done = 0; Total = $evt.Data.Total; Failures = 0 })
                        $changed = $true
                    }
                    'Current' { $state.Current = [string]$evt.Data; & $actions.Progress ([pscustomobject]@{ Done = $state.Done; Total = $state.Total; Failures = $state.Failures }) }
                    'Row' {
                        $row = $evt.Data.Row
                        $state[$state.Request.Target].Rows[[string]$row.Index] = $row
                        if ($row.Status -eq 'Error') { & $actions.Log 'WARN' "Índice $($row.Index): $($row.Message)" }
                        & $actions.Progress $evt.Data; $changed = $true
                    }
                    'Advanced' {
                        $state.A.Rows[[string]$evt.Data.Index] = $evt.Data; $changed = $true
                    }
                    'Verification' {
                        $state.Verification = $evt.Data
                        foreach ($row in $state.A.Rows.Values) {
                            $row.VerificationState = if ($evt.Data.Outcome -eq 'Completo') { 'Sin errores detectados por DISM' } else { 'No completada: ' + $evt.Data.Outcome }
                            $row.VerificationMethod = $evt.Data.Method; $row.VerifiedUtc = $evt.Data.VerifiedUtc; $row.VerificationError = $evt.Data.Error
                        }
                        $changed = $true
                    }
                    'Progress' { & $actions.Progress $evt.Data }
                    'Inventory' {
                        $state.Inventory.Categories.Add([pscustomobject]@{ Category = $evt.Data.Category; Count = $evt.Data.Count; Error = $evt.Data.Error })
                        foreach ($row in $evt.Data.Rows) { $state.Inventory.Rows.Add($row) }
                        if ($evt.Data.Error) {
                            $state.Inventory.Rows.Add([pscustomobject]@{ Category = $evt.Data.Category; Name = ''; Version = ''; State = 'Error'; Provider = ''; Detail = ''; Error = $evt.Data.Error })
                        }
                    }
                    'Error' { $state.Fatal = [string]$evt.Data; & $actions.Log 'ERROR' $state.Fatal }
                    'Finished' { $state.Final = $evt.Data }
                }
                $evt = $null
            }
            if ($changed) { & $actions.Filters; & $actions.Render }
        }.GetNewClosure()
        $actions.Poll = {
            if ($state.Polling -or $null -eq $state.Handle) { return }
            $state.Polling = $true
            try {
                & $actions.Drain
                if (-not $state.Handle.IsCompleted) { return }
                try { $null = $state.PowerShell.EndInvoke($state.Handle) }
                catch { $state.Fatal = $_.Exception.Message; & $actions.Log 'ERROR' $state.Fatal }
                & $actions.Drain
                if ($null -eq $state.Final) { $state.Final = [pscustomobject]@{ Outcome = 'Error'; Done = $state.Done; Total = $state.Total; Failures = $state.Failures; Error = 'La consulta terminó sin un resultado final.' } }
                $result = $state.Final; $request = $state.Request
                $outcome = [string]$result.Outcome
                if ($state.Fatal -and $outcome -eq 'Completo') { $outcome = 'Error' }
                if ($request.Operation -eq 'Read') {
                    $data = $state[$request.Target]
                    if ($outcome -eq 'Completo' -and @($data.Rows.Values | Where-Object { $_.Status -ne 'Correcto' }).Count) { $outcome = 'Con errores' }
                    $data.State = $outcome; $data.Error = $state.Fatal; $data.ReadAtUtc = [datetime]::UtcNow.ToString('o')
                }
                if ($request.Operation -eq 'Inventory') {
                    $categorySummary = ($state.Inventory.Categories | ForEach-Object { "$($_.Category): $($_.Count) elementos$(if ($_.Error) { ' — Error: ' + $_.Error })" }) -join '; '
                    $inventorySummary = "Archivo: $($request.Path) | Índice: $($request.Index)`r`nEstado: $outcome. $categorySummary`r`n$($state.Fatal)"
                    $inventoryRows = @($state.Inventory.Rows | Select-Object *, @{n='Archivo';e={$request.Path}}, @{n='Indice';e={$request.Index}}, @{n='EstadoInventario';e={$outcome}})
                    $state.InventoryResult = & $api['New-IsoInfoReport'] 'Inventario WIM — IsoCore' $inventorySummary $inventoryRows @($request.ExpectedStamp) ([datetime]::UtcNow.ToString('o'))
                }
                if ($request.Operation -eq 'Verify' -and $null -eq $state.Verification) {
                    $reason = if ($state.Fatal) { $state.Fatal } else { 'La consulta terminó sin un resultado de verificación.' }
                    $state.Verification = [pscustomobject]@{ Outcome = 'Error'; Summary = 'Verificación no completada.';
                        Method = 'DISM Export-WindowsImage -CheckIntegrity'; Scope = ''; VerifiedUtc = [datetime]::UtcNow.ToString('o'); Rows = @(); Error = $reason }
                    $outcome = 'Error'; $state.Fatal = $reason
                    foreach ($row in $state.A.Rows.Values) { $row.VerificationState = 'No completada: Error'; $row.VerificationError = $reason }
                }
                if ($request.Operation -eq 'Verify' -and $null -ne $state.Verification) {
                    $v = $state.Verification
                    $verifyRows = @($v.Rows | Select-Object *, @{n='Archivo';e={$request.Path}}, @{n='EstadoVerificacion';e={$v.Outcome}}, @{n='VerifiedUtc';e={$v.VerifiedUtc}})
                    $verifySummary = "Archivo: $($request.Path)`r`n$($v.Summary)`r`n$($v.Method)`r`n$($v.Scope)`r`n$($v.Error)"
                    $state.VerificationResult = & $api['New-IsoInfoReport'] 'Verificación DISM — IsoCore' $verifySummary $verifyRows @($request.ExpectedStamp) $v.VerifiedUtc
                }
                $auto = $state.AutoRead
                & $actions.Release
                & $actions.Render
                if ($request.Operation -eq 'Discover' -and $outcome -eq 'Completo') {
                    if ($auto -and -not $state.Shared.CancelRequested -and -not $state.CloseRequested) { & $actions.ReadImage $auto 'A' $false; return }
                    $message = if ($state.Candidates.Count) { "$($state.Candidates.Count) imágenes detectadas. Elige una en la lista Imágenes." } else { 'No se encontraron imágenes WIM/ESD en la carpeta ni en sources.' }
                } else { $message = "$outcome. $($result.Done) de $($result.Total) procesados; $($result.Failures) con error." }
                if ($state.Fatal) { $message += " $($state.Fatal)" }
                & $actions.Status $message $(if ($outcome -eq 'Completo') { 'Success' } elseif ($outcome -like 'Error*') { 'Error' } else { 'Warning' })
                & $actions.Log $(if ($outcome -like 'Error*') { 'ERROR' } else { 'INFO' }) "$($request.Operation): $message"
                if ($state.CloseRequested -and -not $state.Busy) {
                    $owner = $tab.FindForm()
                    if ($null -ne $owner) { $owner.Close() }
                    return
                }
                if ($request.Operation -eq 'Read' -and $request.Target -eq 'B') { & $actions.ShowComparison }
                if ($request.Operation -eq 'Inventory') { & $actions.ShowInventory }
                if ($request.Operation -eq 'Advanced') { & $actions.Details }
                if ($request.Operation -eq 'Verify') { & $actions.ShowVerification }
            } catch {
                $state.Fatal = $_.Exception.Message
                & $actions.Log 'ERROR' "Interfaz: $($state.Fatal)"
                & $actions.Status "Error actualizando la vista: $($state.Fatal)" 'Error'
                # Si el worker sigue activo, permitir Cancelar y seguir sondeando su finalización.
                if ($null -ne $state.Handle -and $state.Handle.IsCompleted) { & $actions.Release }
            } finally { $state.Polling = $false }
        }.GetNewClosure()
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 120
        $timer.Add_Tick({ & $actions.Poll }.GetNewClosure())
        # El estado compartido conserva el temporizador para todos los eventos.
        $state.Timer = $timer
        $actions.Release = {
            $state.Timer.Stop()
            if ($null -ne $state.PowerShell) { try { $state.PowerShell.Dispose() } catch {} }
            if ($null -ne $state.Runspace) { try { $state.Runspace.Close(); $state.Runspace.Dispose() } catch {} }
            $state.PowerShell = $null; $state.Runspace = $null; $state.Handle = $null; $state.Busy = $false
            & $actions.Controls
        }.GetNewClosure()

        $actions.Cancel = {
            if (-not $state.Busy) { return }
            $state.Shared.CancelRequested = $true
            & $actions.Controls
            & $actions.Status 'Cancelación solicitada. Se conserva lo procesado; esperando a que termine la consulta actual.' 'Warning'
        }.GetNewClosure()
        $actions.RefreshDrives = {
            if ($state.Busy) { return }
            $state.Muting = $true
            try {
                $previous = if ($null -ne $drive.SelectedItem) { $drive.SelectedItem.Path } else { '' }
                $drive.Items.Clear(); $drive.SelectedIndex = -1
                foreach ($item in [IO.DriveInfo]::GetDrives()) {
                    try {
                        if (-not $item.IsReady) { continue }
                        [void]$drive.Items.Add([pscustomobject]@{ Path = $item.RootDirectory.FullName; Display = "$($item.RootDirectory.FullName) — $($item.VolumeLabel) ($($item.DriveFormat))" })
                        if ($item.RootDirectory.FullName -eq $previous) { $drive.SelectedIndex = $drive.Items.Count - 1 }
                    } catch { continue }
                }
            } finally { $state.Muting = $false }
        }.GetNewClosure()
        $actions.Copy = {
            if ($list.SelectedItems.Count -eq 0) { return }
            try {
                $lines = New-Object 'System.Collections.Generic.List[string]'
                $lines.Add(($list.Columns | ForEach-Object { $_.Text }) -join "`t")
                foreach ($item in $list.SelectedItems) { $lines.Add(($item.SubItems | ForEach-Object { $_.Text.Replace("`t",' ').Replace("`r",' ').Replace("`n",' ') }) -join "`t") }
                [System.Windows.Forms.Clipboard]::SetText(($lines -join "`r`n"))
                & $actions.Status "$($list.SelectedItems.Count) fila(s) copiadas."
            } catch { & $actions.Status "No se pudo copiar: $($_.Exception.Message)" 'Error' }
        }.GetNewClosure()
        $actions.Details = {
            if ($list.SelectedItems.Count -eq 0) { return }
            $row = $list.SelectedItems[0].Tag
            $fields = [ordered]@{ Index='Índice'; Name='Nombre'; Status='Estado'; Message='Error'; Description='Descripción'; EditionID='Identificador de edición';
                InstallationType='Tipo de instalación'; Architecture='Arquitectura'; Version='Versión DISM'; Build='Compilación'; Revision='Revisión';
                SizeText='Tamaño sin comprimir'; SizeBytes='Sin comprimir (bytes)'; Created='Creado'; Modified='Modificado'; Language='Idiomas';
                DefaultLanguage='Idioma predeterminado'; ProductType='Tipo de producto'; ProductSuite='Suite'; SystemRoot='Directorio Windows'; WimBoot='WIMBoot' }
            $rows = @([pscustomobject]@{ Campo='Archivo'; Valor=$state.A.Path }, [pscustomobject]@{ Campo='Tamaño del archivo'; Valor=(& $api['Format-IsoInfoBytes'] $state.A.Stamp.SizeBytes) })
            foreach ($field in $fields.Keys) { $rows += [pscustomobject]@{ Campo=$fields[$field]; Valor=$(if ($null -eq $row.$field -or [string]$row.$field -eq '') { 'No disponible' } else { [string]$row.$field }) } }
            foreach ($prop in $row.PSObject.Properties) {
                if (-not $fields.Contains($prop.Name) -and $prop.Name -notin @('Languages','SizeBytes','SizeText')) {
                    $rows += [pscustomobject]@{ Campo = $prop.Name; Valor = $(if ($null -eq $prop.Value -or [string]$prop.Value -eq '') { 'No disponible' } else { [string]$prop.Value }) }
                }
            }
            $report = & $api['New-IsoInfoReport'] "Detalles — $($row.Name)" "Índice $($row.Index) | $($row.Status) | Lectura: $($state.A.State)" $rows @($state.A.Stamp) $(if ($row.AdvancedReadUtc) { $row.AdvancedReadUtc } else { $state.A.ReadAtUtc })
            & $api['Show-IsoInfoReport'] $tab.FindForm() $Palette $report @('Campo','Valor') @('Campo','Valor')
        }.GetNewClosure()

        $path.Add_TextChanged({ if (-not $state.Busy -and -not $state.Muting) { & $actions.Reset; & $actions.Status 'Ruta modificada. Pulsa Leer para buscar imágenes.' } }.GetNewClosure())
        $path.Add_KeyDown({ param($sender,$eventArgs); if ($eventArgs.KeyCode -eq 'Enter') { $eventArgs.SuppressKeyPress = $true; & $actions.Discover } }.GetNewClosure())
        $read.Add_Click({ & $actions.Discover }.GetNewClosure())
        $cancel.Add_Click({ & $actions.Cancel }.GetNewClosure())
        $refresh.Add_Click({ & $actions.RefreshDrives }.GetNewClosure())
        $clear.Add_Click({ if (-not $state.Busy) { $path.Clear(); & $actions.Reset; & $actions.Status 'Listo. Selecciona una imagen.' } }.GetNewClosure())
        $retry.Add_Click({ if ($null -ne $state.A) { & $actions.ReadImage $state.A.Path 'A' $true } }.GetNewClosure())
        $search.Add_TextChanged({ if (-not $state.Muting) { & $actions.Render } }.GetNewClosure())
        $archFilter.Add_SelectedIndexChanged({ if (-not $state.Muting) { & $actions.Render } }.GetNewClosure())
        $langFilter.Add_SelectedIndexChanged({ if (-not $state.Muting) { & $actions.Render } }.GetNewClosure())
        $drive.Add_SelectedIndexChanged({
            if ($state.Muting -or $state.Busy -or $null -eq $drive.SelectedItem) { return }
            $path.Text = $drive.SelectedItem.Path; & $actions.Reset; & $actions.Discover
        }.GetNewClosure())
        $candidates.Add_SelectedIndexChanged({
            if ($state.Muting -or $state.Busy -or $null -eq $candidates.SelectedItem) { return }
            & $actions.ReadImage $candidates.SelectedItem.Path 'A' $false
        }.GetNewClosure())
        $browseFile.Add_Click({
            $dialog = New-Object System.Windows.Forms.OpenFileDialog
            try {
                $dialog.Filter = 'Imágenes Windows (*.wim;*.esd)|*.wim;*.esd'; $dialog.Title = 'Seleccionar imagen WIM o ESD'
                if ($dialog.ShowDialog($tab.FindForm()) -eq 'OK') { $path.Text = $dialog.FileName; & $actions.Reset; & $actions.Discover }
            } finally { $dialog.Dispose() }
        }.GetNewClosure())
        $browseFolder.Add_Click({
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            try {
                $dialog.Description = 'Buscar WIM/ESD en esta carpeta y en su subcarpeta sources.'
                if ($dialog.ShowDialog($tab.FindForm()) -eq 'OK') { $path.Text = $dialog.SelectedPath; & $actions.Reset; & $actions.Discover }
            } finally { $dialog.Dispose() }
        }.GetNewClosure())
        $list.Add_SelectedIndexChanged({ & $actions.Controls }.GetNewClosure())
        $list.Add_DoubleClick({ & $actions.Details }.GetNewClosure())
        $list.Add_KeyDown({ param($sender,$eventArgs); if ($eventArgs.Control -and $eventArgs.KeyCode -eq 'C') { $eventArgs.SuppressKeyPress = $true; & $actions.Copy } }.GetNewClosure())
        $list.Add_ColumnClick({
            param($sender,$eventArgs)
            $key = $columnKeys[$eventArgs.Column]
            if ($state.Sort -eq $key) { $state.Descending = -not $state.Descending } else { $state.Sort = $key; $state.Descending = $false }
            & $actions.Render
        }.GetNewClosure())
        $copy.Add_Click({ & $actions.Copy }.GetNewClosure())
        $details.Add_Click({ & $actions.Details }.GetNewClosure())
        $viewComparison.Add_Click({ & $actions.ShowComparison }.GetNewClosure())
        $viewInventory.Add_Click({ & $actions.ShowInventory }.GetNewClosure())
        $viewVerification.Add_Click({ & $actions.ShowVerification }.GetNewClosure())
        $advanced.Add_Click({
            if (-not $advanced.Enabled -or $list.SelectedItems.Count -ne 1) { return }
            $row = $list.SelectedItems[0].Tag
            & $actions.Start ([pscustomobject]@{ Operation = 'Advanced'; Target = 'A'; Path = $state.A.Path; Row = $row; ExpectedStamp = $state.A.Stamp })
        }.GetNewClosure())
        $verify.Add_Click({
            if (-not $verify.Enabled) { return }
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            try {
                $dialog.Description = 'Verificar todos los índices con DISM. Elige una carpeta con espacio para una copia WIM temporal, que se eliminará al terminar. El proceso puede tardar varios minutos.'
                if ($dialog.ShowDialog($tab.FindForm()) -eq 'OK') {
                    $state.Verification = $null; $state.VerificationResult = $null
                    foreach ($row in $state.A.Rows.Values) { $row.VerificationState = 'Verificando'; $row.VerifiedUtc = ''; $row.VerificationError = ''; $row.VerificationMethod = '' }
                    & $actions.Render
                    & $actions.Start ([pscustomobject]@{ Operation = 'Verify'; Target = 'A'; Path = $state.A.Path; WorkingFolder = $dialog.SelectedPath; ExpectedStamp = $state.A.Stamp })
                }
            } finally { $dialog.Dispose() }
        }.GetNewClosure())
        $compare.Add_Click({
            if ($null -eq $state.A) { return }
            $dialog = New-Object System.Windows.Forms.OpenFileDialog
            try {
                $dialog.Filter = 'Imágenes Windows (*.wim;*.esd)|*.wim;*.esd'; $dialog.Title = 'Seleccionar imagen B para comparar'
                if ($dialog.ShowDialog($tab.FindForm()) -eq 'OK') { & $actions.ReadImage $dialog.FileName 'B' $false }
            } finally { $dialog.Dispose() }
        }.GetNewClosure())
        $export.Add_Click({
            if ($null -eq $state.A) { return }
            $dialog = New-Object System.Windows.Forms.SaveFileDialog
            try {
                $dialog.Filter = 'CSV (*.csv)|*.csv|HTML (*.html)|*.html|JSON (*.json)|*.json'
                $dialog.FileName = 'IsoCore_WIM_ESD_Info'; $dialog.AddExtension = $true
                if ($dialog.ShowDialog($tab.FindForm()) -eq 'OK') {
                    $rows = @(& $api['Get-IsoInfoTableRows'] $state.A)
                    $summary = "Archivo: $($state.A.Path)`r`nEstado: $($state.A.State). $($state.A.Rows.Count) índices.`r`n$($state.A.Error)"
                    $report = & $api['New-IsoInfoReport'] 'Información WIM / ESD — IsoCore' $summary $rows @($state.A.Stamp)
                    & $api['Write-IsoInfoReport'] $dialog.FileName $report
                    & $actions.Status "Exportado: $($dialog.FileName)" 'Success'
                }
            } catch { & $actions.Status "No se pudo exportar: $($_.Exception.Message)" 'Error' }
            finally { $dialog.Dispose() }
        }.GetNewClosure())
        $inventory.Add_Click({
            if (-not $inventory.Enabled -or $list.SelectedItems.Count -ne 1) { return }
            $row = $list.SelectedItems[0].Tag
            $state.Inventory = @{ Rows = (New-Object 'System.Collections.Generic.List[object]'); Categories = (New-Object 'System.Collections.Generic.List[object]') }
            $state.InventoryResult = $null
            & $actions.Start ([pscustomobject]@{ Operation = 'Inventory'; Target = 'A'; Path = $state.A.Path; Index = $row.Index; ExpectedStamp = $state.A.Stamp })
        }.GetNewClosure())
        $actions.CanClose = {
            if (-not $state.Busy) { $state.CloseRequested = $false; return $true }
            $state.CloseRequested = $true
            & $actions.Cancel
            return $false
        }.GetNewClosure()
        $actions.Cleanup = {
            if ($state.Closing) { return }
            $state.Closing = $true
            if ($null -ne $state.Shared) { $state.Shared.CancelRequested = $true }
            if ($null -ne $state.PowerShell -and $null -ne $state.Handle -and -not $state.Handle.IsCompleted) {
                # Respaldo para Dispose externo; el cierre normal espera por CanClose.
                try { $state.PowerShell.Stop() } catch {}
            }
            & $actions.Release
            try { $state.Timer.Dispose() } catch {}
            try { $tip.Dispose() } catch {}
        }.GetNewClosure()
        $tab.Tag = [pscustomobject]@{ Cleanup = $actions.Cleanup; CanClose = $actions.CanClose }
        $tab.Add_Disposed({ & $actions.Cleanup }.GetNewClosure())
        & $actions.RefreshDrives
        & $actions.Controls
        return ,$tab
    } catch {
        if ($actions.Cleanup) { try { & $actions.Cleanup } catch {} }
        if ($null -ne $timer) { try { $timer.Dispose() } catch {} }
        if ($null -ne $tip) { try { $tip.Dispose() } catch {} }
        if ($null -ne $tab) { try { $tab.Dispose() } catch {} }
        throw
    }
}

Export-ModuleMember -Function New-IsoCoreImageInfoTab
