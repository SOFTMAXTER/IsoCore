# ==============================================================================
#   ___           ____               
#  |_ _|___  ___ / ___|___  _ __ ___ 
#   | |/ __|/ _ \ |   / _ \| '__/ _ \
#   | |\__ \ (_) | |__| (_) | | |  __/
#  |___|___/\___/ \____\___/|_|  \___|
#                                     
#  IsoCore v1.3.5
#  Author: SOFTMAXTER
#
#  DESCRIPTION:
#  Generador de imagenes ISO booteables (BIOS/UEFI/ARM64) con integracion de
#  automatizacion OOBE mediante autounattend.xml e inyeccion MRP.
#
# ==============================================================================
# Copyright (C) 2026 SOFTMAXTER
# ==============================================================================

function Invoke-IsoCoreInternal {

$script:IsoCore_Version = "1.3.5"

function Write-IsoCoreLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('INFO', 'ACTION', 'WARN', 'ERROR')]
        [string]$LogLevel,

        [Parameter(Mandatory=$true)]
        [string]$Message
    )

    if (-not $script:IsoCore_logFile) { return }

    try {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "[$timestamp] [$LogLevel] - $Message" | Out-File -FilePath $script:IsoCore_logFile -Append -Encoding utf8
    }
    catch {
        Write-Warning "No se pudo escribir en el archivo de log: $_"
    }
}

# 1. Verificacion de plataforma y permisos de Administrador
$isWindowsPlatform = ($PSVersionTable.PSEdition -eq 'Desktop') -or
                     ($null -ne (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) -and $IsWindows)

if (-not $isWindowsPlatform) {
    Write-Error "IsoCore solo puede ejecutarse en Windows."
    return
}

$isAdministrator = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $isAdministrator) {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show(
            "IsoCore requiere permisos de Administrador para leer imagenes WIM/ESD, escribir archivos temporales y ejecutar oscdimg.exe.`n`nAbre AdminImagenOffline o este script mediante 'Ejecutar como administrador'.",
            "IsoCore - Permisos requeridos",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    } catch {
        Write-Warning "IsoCore requiere permisos de Administrador. Ejecuta el programa mediante 'Ejecutar como administrador'."
    }
    return
}

# 2. Inicializacion del sistema de Logs
try {
    $scriptRoot    = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
    $parentDir     = Split-Path -Parent $scriptRoot
    $script:IsoCore_logDir = Join-Path -Path $parentDir -ChildPath "Logs"

    if (-not (Test-Path -LiteralPath $script:IsoCore_logDir)) {
        New-Item -Path $script:IsoCore_logDir -ItemType Directory -Force | Out-Null
    }

    $script:IsoCore_logFile = Join-Path -Path $script:IsoCore_logDir -ChildPath "Registro.log"
    $maxLogSizeMB   = 1

    if (Test-Path -LiteralPath $script:IsoCore_logFile) {
        $logItem = Get-Item -LiteralPath $script:IsoCore_logFile
        if ($logItem.Length -gt ($maxLogSizeMB * 1MB)) {
            Write-Host "Realizando mantenimiento del archivo de Log..." -ForegroundColor Gray
            $oldLogFile = Join-Path -Path $script:IsoCore_logDir -ChildPath "Registro_old.log"
            Move-Item -LiteralPath $script:IsoCore_logFile -Destination $oldLogFile -Force
        }
    }
} catch {
    Write-Warning "No se pudo crear el directorio de Logs. El registro de eventos se desactivara. Error: $_"
    $script:IsoCore_logFile = $null
}

Write-IsoCoreLog -LogLevel INFO -Message "================================================="
Write-IsoCoreLog -LogLevel INFO -Message "IsoCore v$($script:IsoCore_Version) iniciado en modo Administrador."

function Show-IsoCoreGUI {

    Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: Iniciando interfaz grafica del generador ISO."

    # ------------------------------------------------------------------
    # 1. Busqueda de oscdimg.exe
    # ------------------------------------------------------------------
    $scriptPath = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }

    $projectRoot = if ([string]::Equals(
        (Split-Path -Path $scriptPath -Leaf),
        'Script',
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        Split-Path -Path $scriptPath -Parent
    } else {
        $scriptPath
    }

    $oscdimgPaths = @(
        (Join-Path -Path $projectRoot -ChildPath 'Tools\oscdimg.exe'),
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    )

    $oscdimgExe = $null
    foreach ($path in $oscdimgPaths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) { $oscdimgExe = $path; break }
    }

    if (-not $oscdimgExe) {
        $cmd = Get-Command "oscdimg.exe" -ErrorAction SilentlyContinue
        if ($cmd) { $oscdimgExe = $cmd.Source }
    }

    if (-not $oscdimgExe) {
        Write-IsoCoreLog -LogLevel WARN -Message "IsoCore: oscdimg.exe no encontrado en rutas estandar. Solicitando ubicacion manual..."

        Add-Type -AssemblyName System.Windows.Forms
        $res = [System.Windows.Forms.MessageBox]::Show(
            "No se encontro 'oscdimg.exe' en las rutas estandar del ADK.`n`nDeseas buscar el ejecutable manualmente?",
            "Falta Dependencia",
            'YesNo',
            'Warning'
        )

        if ($res -eq 'Yes') {
            $ofd        = New-Object System.Windows.Forms.OpenFileDialog
            $ofd.Filter = "Oscdimg (oscdimg.exe)|oscdimg.exe"
            if ($ofd.ShowDialog() -eq 'OK') {
                $oscdimgExe = $ofd.FileName
                Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: oscdimg.exe localizado manualmente por el usuario en: $oscdimgExe"
            } else {
                Write-IsoCoreLog -LogLevel WARN -Message "IsoCore: El usuario cancelo el cuadro de dialogo de busqueda manual. Saliendo."
                return
            }
        } else {
            Write-IsoCoreLog -LogLevel ERROR -Message "IsoCore: Dependencia faltante. El usuario declino buscar oscdimg.exe. Saliendo."
            $msg = "Para utilizar el Generador de ISO, es un requisito estricto contar con 'oscdimg.exe'.`n`n" +
                   "Por favor, descarga e instala el Windows Assessment and Deployment Kit (ADK)."
            [System.Windows.Forms.MessageBox]::Show($msg, "Requisito Faltante: Windows ADK", 'OK', 'Error')
            return
        }
    }

    $oscdimgVerStr = ""
    try {
        $vi = (Get-Item -LiteralPath $oscdimgExe).VersionInfo
        $oscdimgVerStr = "$($vi.FileMajorPart).$($vi.FileMinorPart).$($vi.FileBuildPart).$($vi.FilePrivatePart)"
        Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: oscdimg.exe encontrado — version $oscdimgVerStr — ruta: $oscdimgExe"
    } catch {
        Write-IsoCoreLog -LogLevel WARN -Message "IsoCore: No se pudo leer la version del PE de oscdimg.exe."
    }

    # ------------------------------------------------------------------
    # 2. Cargar assemblies GUI
    # ------------------------------------------------------------------
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop

    # Rutas ancladas al script: no dependen del directorio de la consola.
    # La carga se realiza despues de crear la pestaña de diagnostico.
    $imageInfoModuleCandidates = @(
        (Join-Path -Path $scriptPath  -ChildPath 'Modules\IsoCore.ImageInfo.psm1'),
        (Join-Path -Path $projectRoot -ChildPath 'Modules\IsoCore.ImageInfo.psm1'),
        (Join-Path -Path $scriptPath  -ChildPath 'IsoCore.ImageInfo.psm1'),
        (Join-Path -Path $projectRoot -ChildPath 'IsoCore.ImageInfo.psm1')
    ) | Select-Object -Unique

# Verificar identidad e integridad del motor antes de utilizarlo.
$oscdimgHash = $null
$oscdimgSignatureStatus = 'Unknown'
$oscdimgSigner = 'Sin firmante'
try {
    $oscdimgHash = (Get-FileHash -LiteralPath $oscdimgExe -Algorithm SHA256 -ErrorAction Stop).Hash
    $signature = Get-AuthenticodeSignature -LiteralPath $oscdimgExe -ErrorAction Stop
    $oscdimgSignatureStatus = [string]$signature.Status
    if ($signature.SignerCertificate) { $oscdimgSigner = [string]$signature.SignerCertificate.Subject }
    $isTrustedMicrosoft = ($signature.Status -eq [System.Management.Automation.SignatureStatus]::Valid) -and
                          ($oscdimgSigner -match 'Microsoft')
    & Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: oscdimg SHA-256: $oscdimgHash | Firma: $oscdimgSignatureStatus | Firmante: $oscdimgSigner"
    if (-not $isTrustedMicrosoft) {
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "La firma digital de oscdimg.exe no pudo validarse como Microsoft.`n`nEstado: $oscdimgSignatureStatus`nFirmante: $oscdimgSigner`nSHA-256: $oscdimgHash`nRuta: $oscdimgExe`n`n¿Deseas continuar bajo tu responsabilidad?",
            'Verificacion de oscdimg.exe',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
            & Write-IsoCoreLog -LogLevel WARN -Message "IsoCore: Ejecucion cancelada porque oscdimg.exe no tiene una firma Microsoft valida."
            return
        }
    }
} catch {
    & Write-IsoCoreLog -LogLevel ERROR -Message "IsoCore: No se pudo verificar la integridad de oscdimg.exe: $($_.Exception.Message)"
    [System.Windows.Forms.MessageBox]::Show(
        "No se pudo calcular el hash o verificar la firma de oscdimg.exe.`n`nDetalle:`n$($_.Exception.Message)",
        'oscdimg.exe no verificable', 'OK', 'Error'
    ) | Out-Null
    return
}

    # Lector asincronico puro .NET para stdout/stderr. Evita el bloqueo producido por
    # StreamReader.Peek() cuando oscdimg escribe progreso principalmente en stderr.
    if ($null -eq ("IsoCore.ProcessOutputPump" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Collections.Concurrent;
using System.Diagnostics;

namespace IsoCore
{
    public static class ProcessOutputPump
    {
        public static DataReceivedEventHandler CreateHandler(ConcurrentQueue<string> queue)
        {
            if (queue == null) throw new ArgumentNullException("queue");
            return delegate(object sender, DataReceivedEventArgs e)
            {
                if (e.Data != null) queue.Enqueue(e.Data);
            };
        }
    }
}
"@ -Language CSharp -ErrorAction Stop
    }
    $chkMRP  = $null
    $btnAbout = $null
    $picCD   = $null
    $cdTimer = $null
    $script:IsoCore_mrpExtractRoot = $null

    $script:IsoCore_detectedArchitecture = $null
    $script:IsoCore_analyzedSource       = $null
    $script:IsoCore_sourceBytes          = 0L
    $script:IsoCore_reparsePointCount    = 0
    $script:IsoCore_bootOrderFile        = $null
    $script:IsoCore_sourceSnapshot       = $null
    $script:IsoCore_expectedIsoFiles     = @()
    $script:IsoCore_requireInstallImage  = $true
    $script:IsoCore_verificationResult   = $null
    $script:IsoCore_outputTransactionState = 'NONE'
    $script:IsoCore_analysisCache       = @{}
    $script:IsoCore_analysisSizeResult  = $null
    $script:IsoCore_analysisDismResult  = $null
    $script:IsoCore_analysisQuickFingerprint = $null
    $script:IsoCore_analysisCancelled   = $false

    # ------------------------------------------------------------------
    # 3. Construccion del formulario
    # ------------------------------------------------------------------
    $uiBg        = [System.Drawing.Color]::FromArgb(18, 23, 29)
    $uiPanel     = [System.Drawing.Color]::FromArgb(30, 35, 40)
    $uiText      = [System.Drawing.Color]::FromArgb(230, 234, 238)
    $uiSecondary = [System.Drawing.Color]::FromArgb(184, 194, 204)
    $uiMuted     = [System.Drawing.Color]::FromArgb(150, 162, 174)
    $uiCyan      = [System.Drawing.Color]::FromArgb(74, 205, 255)
    $uiGreen     = [System.Drawing.Color]::FromArgb(55, 225, 135)
    $uiOrange    = [System.Drawing.Color]::FromArgb(255, 170, 45)

    $palette = [ordered]@{
        Background = $uiBg
        Panel      = $uiPanel
        Text       = $uiText
        Secondary  = $uiSecondary
        Muted      = $uiMuted
        Cyan       = $uiCyan
        Green      = $uiGreen
        Orange     = $uiOrange
    }
    foreach ($entry in $palette.GetEnumerator()) {
        if ($null -eq $entry.Value) {
            throw "La paleta visual no inicializo el color '$($entry.Key)'."
        }
    }

    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = "IsoCore v$($script:IsoCore_Version) by SOFTMAXTER"
    $form.ClientSize      = New-Object System.Drawing.Size(930, 650)
    $form.StartPosition   = "CenterScreen"
    $form.BackColor       = $uiBg
    $form.ForeColor       = $uiText
    $form.Font            = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox     = $false
    $form.AutoScaleMode   = [System.Windows.Forms.AutoScaleMode]::Dpi

    # --- Header ---
    $lblHeaderTitle           = New-Object System.Windows.Forms.Label
    $lblHeaderTitle.Text      = "IsoCore"
    $lblHeaderTitle.Font      = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
    $lblHeaderTitle.ForeColor = $uiCyan
    $lblHeaderTitle.Location  = "15, 10"
    $lblHeaderTitle.AutoSize  = $true
    $form.Controls.Add($lblHeaderTitle)

    $lblHeaderSub           = New-Object System.Windows.Forms.Label
    $lblHeaderSub.Text      = "• Creación de Medios de Instalación Windows BIOS/UEFI"
    $lblHeaderSub.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
    $lblHeaderSub.ForeColor = $uiSecondary
    $lblHeaderSub.Location  = "105, 18"
    $lblHeaderSub.AutoSize  = $true
    $form.Controls.Add($lblHeaderSub)

    # ================= COLUMNA IZQUIERDA =================

    # --- 1. CONFIGURACION DE IMAGEN ---
    $grpCfg           = New-Object System.Windows.Forms.GroupBox
    $grpCfg.Text      = " CONFIGURACION DE IMAGEN "
    $grpCfg.Location  = "15, 50"
    $grpCfg.Size      = "450, 190"
    $grpCfg.ForeColor = $uiCyan
    $grpCfg.BackColor = $uiBg
    $form.Controls.Add($grpCfg)

    $lblSrc           = New-Object System.Windows.Forms.Label
    $lblSrc.Text      = "CARPETA ORIGEN (boot, efi, sources...)"
    $lblSrc.Location  = "15, 25"
    $lblSrc.Size      = "425, 20"
    $lblSrc.AutoSize  = $false
    $lblSrc.BackColor = $uiBg
    $lblSrc.ForeColor = $uiSecondary
    $grpCfg.Controls.Add($lblSrc)

    $txtSrc             = New-Object System.Windows.Forms.TextBox
    $txtSrc.Location    = "15, 52"
    $txtSrc.Size        = "340, 23"
    $txtSrc.BackColor   = $uiPanel
    $txtSrc.ForeColor   = $uiText
    $txtSrc.BorderStyle = "FixedSingle"
    $grpCfg.Controls.Add($txtSrc)

    $btnSrc                           = New-Object System.Windows.Forms.Button
    $btnSrc.Text                      = "Explorar..."
    $btnSrc.Location                  = "365, 51"
    $btnSrc.Size                      = "75, 25"
    $btnSrc.BackColor                 = $uiCyan
    $btnSrc.ForeColor                 = [System.Drawing.Color]::Black
    $btnSrc.FlatStyle                 = "Flat"
    $btnSrc.FlatAppearance.BorderSize = 0
    $grpCfg.Controls.Add($btnSrc)

    $lblDst           = New-Object System.Windows.Forms.Label
    $lblDst.Text      = "ARCHIVO ISO DESTINO"
    $lblDst.Location  = "15, 84"
    $lblDst.Size      = "425, 20"
    $lblDst.AutoSize  = $false
    $lblDst.BackColor = $uiBg
    $lblDst.ForeColor = $uiSecondary
    $grpCfg.Controls.Add($lblDst)

    $txtDst             = New-Object System.Windows.Forms.TextBox
    $txtDst.Location    = "15, 111"
    $txtDst.Size        = "340, 23"
    $txtDst.BackColor   = $uiPanel
    $txtDst.ForeColor   = $uiText
    $txtDst.BorderStyle = "FixedSingle"
    $grpCfg.Controls.Add($txtDst)

    $btnDst                           = New-Object System.Windows.Forms.Button
    $btnDst.Text                      = "Guardar"
    $btnDst.Location                  = "365, 110"
    $btnDst.Size                      = "75, 25"
    $btnDst.BackColor                 = [System.Drawing.Color]::FromArgb(60, 65, 70)
    $btnDst.ForeColor                 = [System.Drawing.Color]::White
    $btnDst.FlatStyle                 = "Flat"
    $btnDst.FlatAppearance.BorderSize = 0
    $grpCfg.Controls.Add($btnDst)

    $lblLabel           = New-Object System.Windows.Forms.Label
    $lblLabel.Text      = "ETIQUETA DE VOLUMEN:"
    $lblLabel.Location  = "15, 151"
    $lblLabel.Size      = "145, 22"
    $lblLabel.AutoSize  = $false
    $lblLabel.BackColor = $uiBg
    $lblLabel.ForeColor = $uiSecondary
    $lblLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $grpCfg.Controls.Add($lblLabel)

    $txtLabel             = New-Object System.Windows.Forms.TextBox
    $txtLabel.Location    = "165, 150"
    $txtLabel.Size        = "275, 23"
    $txtLabel.Text        = "WINDOWS_CUSTOM"
    $txtLabel.BackColor   = $uiPanel
    $txtLabel.ForeColor   = $uiText
    $txtLabel.BorderStyle = "FixedSingle"
    $grpCfg.Controls.Add($txtLabel)

    # --- 2. AUTOMATIZACION OOBE ---
    $grpAuto           = New-Object System.Windows.Forms.GroupBox
    $grpAuto.Text      = " AUTOMATIZACION OOBE (Opcional) "
    $grpAuto.Location  = "15, 250"
    $grpAuto.Size      = "450, 145"
    $grpAuto.ForeColor = $uiOrange
    $grpAuto.BackColor = $uiBg
    $form.Controls.Add($grpAuto)

    $lblAutoInfo           = New-Object System.Windows.Forms.Label
    $lblAutoInfo.Text      = "INYECTAR autounattend.xml EN LA RAIZ DEL MEDIO"
    $lblAutoInfo.Location  = "15, 25"
    $lblAutoInfo.Size      = "425, 20"
    $lblAutoInfo.AutoSize  = $false
    $lblAutoInfo.BackColor = $uiBg
    $lblAutoInfo.ForeColor = $uiSecondary
    $grpAuto.Controls.Add($lblAutoInfo)

    $txtUnattend             = New-Object System.Windows.Forms.TextBox
    $txtUnattend.Location    = "15, 52"
    $txtUnattend.Size        = "340, 23"
    $txtUnattend.BackColor   = $uiPanel
    $txtUnattend.ForeColor   = $uiText
    $txtUnattend.BorderStyle = "FixedSingle"
    $grpAuto.Controls.Add($txtUnattend)

    $btnUnattend                           = New-Object System.Windows.Forms.Button
    $btnUnattend.Text                      = "XML..."
    $btnUnattend.Location                  = "365, 51"
    $btnUnattend.Size                      = "75, 25"
    $btnUnattend.BackColor                 = [System.Drawing.Color]::FromArgb(160, 80, 20)
    $btnUnattend.ForeColor                 = [System.Drawing.Color]::White
    $btnUnattend.FlatStyle                 = "Flat"
    $btnUnattend.FlatAppearance.BorderSize = 0
    $grpAuto.Controls.Add($btnUnattend)

    $lnkWeb                 = New-Object System.Windows.Forms.LinkLabel
    $lnkWeb.Text            = "Generador online — schneegans.de"
    $lnkWeb.Location        = "15, 84"
    $lnkWeb.Size            = "280, 22"
    $lnkWeb.AutoSize        = $false
    $lnkWeb.BackColor       = $uiBg
    $lnkWeb.LinkColor       = [System.Drawing.Color]::FromArgb(115, 190, 225)
    $lnkWeb.ActiveLinkColor = [System.Drawing.Color]::White
    $grpAuto.Controls.Add($lnkWeb)

    $chkMRP           = New-Object System.Windows.Forms.CheckBox
    $chkMRP.Text      = "Inyectar Multi OEM/Retail Project (MRP) en ISO\sources"
    $chkMRP.Location  = "15, 111"
    $chkMRP.Size      = "425, 24"
    $chkMRP.AutoSize  = $false
    $chkMRP.BackColor = $uiBg
    $chkMRP.ForeColor = $uiSecondary
    $grpAuto.Controls.Add($chkMRP)

    # --- 3. VALIDACION DE ORIGEN ---
    $grpVal           = New-Object System.Windows.Forms.GroupBox
    $grpVal.Text      = " VALIDACION DE ORIGEN "
    $grpVal.Location  = "15, 405"
    $grpVal.Size      = "450, 160"
    $grpVal.ForeColor = [System.Drawing.Color]::FromArgb(105, 205, 225)
    $grpVal.BackColor = $uiBg
    $form.Controls.Add($grpVal)

    $validationFont = New-Object System.Drawing.Font("Consolas", 8.25)

    $lblValBoot           = New-Object System.Windows.Forms.Label
    $lblValBoot.Text      = "• boot\etfsboot.com"
    $lblValBoot.Location  = "10, 24"
    $lblValBoot.Size      = "430, 18"
    $lblValBoot.ForeColor = $uiMuted
    $lblValBoot.BackColor = $uiBg
    $lblValBoot.Font      = $validationFont
    $lblValBoot.AutoEllipsis = $true
    $grpVal.Controls.Add($lblValBoot)

    $lblValEfi           = New-Object System.Windows.Forms.Label
    $lblValEfi.Text      = "• efisys.bin (UEFI)"
    $lblValEfi.Location  = "10, 46"
    $lblValEfi.Size      = "430, 18"
    $lblValEfi.ForeColor = $uiMuted
    $lblValEfi.BackColor = $uiBg
    $lblValEfi.Font      = $validationFont
    $lblValEfi.AutoEllipsis = $true
    $grpVal.Controls.Add($lblValEfi)

    $lblValWim           = New-Object System.Windows.Forms.Label
    $lblValWim.Text      = "• sources\install.*"
    $lblValWim.Location  = "10, 68"
    $lblValWim.Size      = "430, 18"
    $lblValWim.ForeColor = $uiMuted
    $lblValWim.BackColor = $uiBg
    $lblValWim.Font      = $validationFont
    $lblValWim.AutoEllipsis = $true
    $grpVal.Controls.Add($lblValWim)

    $lblValSpace           = New-Object System.Windows.Forms.Label
    $lblValSpace.Text      = "• Espacio libre en destino: (Esperando...)"
    $lblValSpace.Location  = "10, 90"
    $lblValSpace.Size      = "430, 18"
    $lblValSpace.ForeColor = $uiMuted
    $lblValSpace.BackColor = $uiBg
    $lblValSpace.Font      = $validationFont
    $lblValSpace.AutoEllipsis = $true
    $grpVal.Controls.Add($lblValSpace)

    $lblValSrcSize           = New-Object System.Windows.Forms.Label
    $lblValSrcSize.Text      = "• Tamaño carpeta origen: (Esperando...)"
    $lblValSrcSize.Location  = "10, 112"
    $lblValSrcSize.Size      = "430, 18"
    $lblValSrcSize.ForeColor = $uiMuted
    $lblValSrcSize.BackColor = $uiBg
    $lblValSrcSize.Font      = $validationFont
    $lblValSrcSize.AutoEllipsis = $true
    $grpVal.Controls.Add($lblValSrcSize)

    $lblValLang           = New-Object System.Windows.Forms.Label
    $lblValLang.Text      = "• Idioma predeterminado: (Esperando...)"
    $lblValLang.Location  = "10, 134"
    $lblValLang.Size      = "430, 18"
    $lblValLang.ForeColor = $uiMuted
    $lblValLang.BackColor = $uiBg
    $lblValLang.Font      = $validationFont
    $lblValLang.AutoEllipsis = $true
    $grpVal.Controls.Add($lblValLang)

    # ================= COLUMNA DERECHA =================

    # --- 4. PROGRESO DE COMPILACION ---
    $grpProg           = New-Object System.Windows.Forms.GroupBox
    $grpProg.Text      = " PROGRESO DE COMPILACION "
    $grpProg.Location  = "475, 50"
    $grpProg.Size      = "440, 515"
    $grpProg.ForeColor = $uiGreen
    $grpProg.BackColor = $uiBg
    $form.Controls.Add($grpProg)

    $motorText = if ($oscdimgVerStr) {
        "Motor: $oscdimgExe`n[v$oscdimgVerStr]"
    } else {
        "Motor: $oscdimgExe"
    }
    $lblMotorInfo           = New-Object System.Windows.Forms.Label
    $lblMotorInfo.Text      = $motorText
    $lblMotorInfo.Location  = "15, 25"
    $lblMotorInfo.Size      = "355, 42"
    $lblMotorInfo.ForeColor = $uiSecondary
    $lblMotorInfo.Font      = New-Object System.Drawing.Font("Consolas", 8.25)
    $lblMotorInfo.AutoEllipsis = $true
    $grpProg.Controls.Add($lblMotorInfo)

    # ANIMACION DE CD GIRATORIO
    $script:IsoCore_cdAngle = 0
    $picCD          = New-Object System.Windows.Forms.PictureBox
    $picCD.Location = "385, 24"
    $picCD.Size     = "40, 40"
    $picCD.BackColor = [System.Drawing.Color]::Transparent
    $picCD.Visible   = $false
    $grpProg.Controls.Add($picCD)

    $cdTimer          = New-Object System.Windows.Forms.Timer
    $cdTimer.Interval = 40
    $cdTimer.Add_Tick({
        $script:IsoCore_cdAngle = ($script:IsoCore_cdAngle + 15) % 360
        $picCD.Refresh()
    })

    $picCD.Add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

        $g.TranslateTransform(20, 20)
        $g.RotateTransform($script:IsoCore_cdAngle)
        $g.TranslateTransform(-20, -20)

        $g.FillEllipse([System.Drawing.Brushes]::MediumSpringGreen, 2, 2, 36, 36)
        $g.FillPie([System.Drawing.Brushes]::DarkSlateGray, 2, 2, 36, 36, 45, 40)
        $g.FillPie([System.Drawing.Brushes]::DarkSlateGray, 2, 2, 36, 36, 225, 40)

        $bgBrush = New-Object System.Drawing.SolidBrush($uiBg)
        $g.FillEllipse($bgBrush, 14, 14, 12, 12)
        $bgBrush.Dispose()

        $g.DrawEllipse([System.Drawing.Pens]::DarkGreen, 14, 14, 12, 12)
        $g.DrawEllipse([System.Drawing.Pens]::SeaGreen,  2,  2, 36, 36)
    })

    $lblPhase           = New-Object System.Windows.Forms.Label
    $lblPhase.Text      = "Esperando configuracion..."
    $lblPhase.Location  = "15, 82"
    $lblPhase.Size      = "410, 42"
    $lblPhase.ForeColor = $uiCyan
    $lblPhase.Font      = New-Object System.Drawing.Font("Segoe UI", 10.5, [System.Drawing.FontStyle]::Bold)
    $lblPhase.AutoEllipsis = $true
    $grpProg.Controls.Add($lblPhase)

    $pbMain          = New-Object System.Windows.Forms.ProgressBar
    $pbMain.Location = "15, 130"
    $pbMain.Size     = "410, 25"
    $pbMain.Minimum  = 0
    $pbMain.Maximum  = 100
    $pbMain.Value    = 0
    $pbMain.Style    = [System.Windows.Forms.ProgressBarStyle]::Continuous
    $grpProg.Controls.Add($pbMain)

    $lblPercent           = New-Object System.Windows.Forms.Label
    $lblPercent.Text      = "0 % completado"
    $lblPercent.Location  = "15, 165"
    $lblPercent.AutoSize  = $true
    $lblPercent.ForeColor = $uiGreen
    $lblPercent.Font      = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $grpProg.Controls.Add($lblPercent)

    $lblFileInfo           = New-Object System.Windows.Forms.Label
    $lblFileInfo.Text      = ""
    $lblFileInfo.Location  = "15, 205"
    $lblFileInfo.Size      = "410, 20"
    $lblFileInfo.ForeColor = $uiSecondary
    $grpProg.Controls.Add($lblFileInfo)

    $lblSizeInfo           = New-Object System.Windows.Forms.Label
    $lblSizeInfo.Text      = ""
    $lblSizeInfo.Location  = "15, 232"
    $lblSizeInfo.Size      = "410, 20"
    $lblSizeInfo.ForeColor = $uiSecondary
    $grpProg.Controls.Add($lblSizeInfo)

    $lblHashInfo           = New-Object System.Windows.Forms.Label
    $lblHashInfo.Text      = ""
    $lblHashInfo.Location  = "15, 260"
    $lblHashInfo.Size      = "410, 55"
    $lblHashInfo.ForeColor = $uiGreen
    $lblHashInfo.Font      = New-Object System.Drawing.Font("Consolas", 8)
    $grpProg.Controls.Add($lblHashInfo)

    # ================= FILA INFERIOR DE BOTONES =================

    $btnExportLog                            = New-Object System.Windows.Forms.Button
    $btnExportLog.Text                       = "Exportar Log"
    $btnExportLog.Location                   = "15, 575"
    $btnExportLog.Size                       = "140, 40"
    $btnExportLog.BackColor                  = [System.Drawing.Color]::FromArgb(30, 35, 40)
    $btnExportLog.ForeColor                  = [System.Drawing.Color]::Gray
    $btnExportLog.FlatStyle                  = "Flat"
    $btnExportLog.FlatAppearance.BorderSize  = 1
    $btnExportLog.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(50, 55, 60)
    $btnExportLog.Enabled                    = $false
    $form.Controls.Add($btnExportLog)

    $btnMake                           = New-Object System.Windows.Forms.Button
    $btnMake.Text                      = "► CREAR ISO BOOTEABLE"
    $btnMake.Location                  = "165, 575"
    $btnMake.Size                      = "590, 40"
    $btnMake.BackColor                 = [System.Drawing.Color]::FromArgb(18, 105, 69)
    $btnMake.ForeColor                 = [System.Drawing.Color]::White
    $btnMake.FlatStyle                 = "Flat"
    $btnMake.FlatAppearance.BorderSize = 0
    $btnMake.Font                      = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($btnMake)

    $btnCancel                           = New-Object System.Windows.Forms.Button
    $btnCancel.Text                      = "✖  Cancelar"
    $btnCancel.Location                  = "605, 575"
    $btnCancel.Size                      = "150, 40"
    $btnCancel.BackColor                 = [System.Drawing.Color]::FromArgb(110, 20, 20)
    $btnCancel.ForeColor                 = [System.Drawing.Color]::White
    $btnCancel.FlatStyle                 = "Flat"
    $btnCancel.FlatAppearance.BorderSize = 0
    $btnCancel.Font                      = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $btnCancel.Visible                   = $false
    $form.Controls.Add($btnCancel)

    $btnAbout                            = New-Object System.Windows.Forms.Button
    $btnAbout.Text                       = "Acerca de"
    $btnAbout.Location                   = "765, 575"
    $btnAbout.Size                       = "130, 40"
    $btnAbout.BackColor                  = [System.Drawing.Color]::FromArgb(30, 35, 40)
    $btnAbout.ForeColor                  = $uiCyan
    $btnAbout.FlatStyle                  = "Flat"
    $btnAbout.FlatAppearance.BorderSize  = 1
    $btnAbout.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(50, 55, 60)
    $form.Controls.Add($btnAbout)

    $btnOpenFolder                           = New-Object System.Windows.Forms.Button
    $btnOpenFolder.Text                      = ">> Abrir carpeta de la imagen generada"
    $btnOpenFolder.Location                  = "15, 620"
    $btnOpenFolder.Size                      = "880, 25"
    $btnOpenFolder.BackColor                 = [System.Drawing.Color]::FromArgb(10, 40, 20)
    $btnOpenFolder.ForeColor                 = [System.Drawing.Color]::LimeGreen
    $btnOpenFolder.FlatStyle                 = "Flat"
    $btnOpenFolder.FlatAppearance.BorderSize = 0
    $btnOpenFolder.Visible                   = $false
    $form.Controls.Add($btnOpenFolder)

# Controles de analisis y vista detallada.
$btnCancelAnalysis = New-Object System.Windows.Forms.Button
$btnCancelAnalysis.Text = 'Cancelar analisis'
$btnCancelAnalysis.BackColor = [System.Drawing.Color]::FromArgb(110, 55, 20)
$btnCancelAnalysis.ForeColor = [System.Drawing.Color]::White
$btnCancelAnalysis.FlatStyle = 'Flat'
$btnCancelAnalysis.FlatAppearance.BorderSize = 0
$btnCancelAnalysis.Visible = $false
$btnCancelAnalysis.Dock = 'Fill'

$btnDetails = New-Object System.Windows.Forms.Button
$btnDetails.Text = 'Ver detalles del analisis'
$btnDetails.BackColor = $uiPanel
$btnDetails.ForeColor = $uiCyan
$btnDetails.FlatStyle = 'Flat'
$btnDetails.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(60, 75, 85)
$btnDetails.Dock = 'Fill'

$txtDetails = New-Object System.Windows.Forms.TextBox
$txtDetails.Multiline = $true
$txtDetails.ReadOnly = $true
$txtDetails.ScrollBars = 'Both'
$txtDetails.WordWrap = $false
$txtDetails.BackColor = [System.Drawing.Color]::FromArgb(12, 16, 21)
$txtDetails.ForeColor = $uiText
$txtDetails.Font = New-Object System.Drawing.Font('Consolas', 8.25)
$txtDetails.Dock = 'Fill'
$txtDetails.Visible = $false

# Diseño adaptable basado en TableLayoutPanel
$form.SuspendLayout()
$form.Controls.Clear()
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
$form.MaximizeBox = $true
$form.MinimumSize = New-Object System.Drawing.Size(950, 860)
$form.ClientSize = New-Object System.Drawing.Size(1020, 760)
$form.AutoScroll = $true

$rootLayout = New-Object System.Windows.Forms.TableLayoutPanel
$rootLayout.Dock = 'Fill'
$rootLayout.Padding = New-Object System.Windows.Forms.Padding(10)
$rootLayout.ColumnCount = 1
$rootLayout.RowCount = 4
[void]$rootLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 50)))
[void]$rootLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))

$headerLayout = New-Object System.Windows.Forms.TableLayoutPanel
$headerLayout.Dock = 'Fill'; $headerLayout.AutoSize = $true
$headerLayout.ColumnCount = 2; $headerLayout.RowCount = 1
[void]$headerLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$headerLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$lblHeaderTitle.Dock = 'Fill'; $lblHeaderTitle.AutoSize = $true
$lblHeaderSub.Dock = 'Fill'; $lblHeaderSub.AutoSize = $true; $lblHeaderSub.TextAlign = 'MiddleLeft'
[void]$headerLayout.Controls.Add($lblHeaderTitle, 0, 0)
[void]$headerLayout.Controls.Add($lblHeaderSub, 1, 0)

$mainLayout = New-Object System.Windows.Forms.TableLayoutPanel
$mainLayout.Dock = 'Fill'; $mainLayout.ColumnCount = 2; $mainLayout.RowCount = 1
[void]$mainLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$mainLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))

$leftLayout = New-Object System.Windows.Forms.TableLayoutPanel
$leftLayout.Dock = 'Fill'; $leftLayout.ColumnCount = 1; $leftLayout.RowCount = 3
$leftLayout.Padding = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
[void]$leftLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$leftLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$leftLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

$grpCfg.Dock = 'Fill'; $grpCfg.AutoSize = $true
$grpAuto.Dock = 'Fill'; $grpAuto.AutoSize = $true
$grpVal.Dock = 'Fill'
[void]$leftLayout.Controls.Add($grpCfg, 0, 0)
[void]$leftLayout.Controls.Add($grpAuto, 0, 1)
[void]$leftLayout.Controls.Add($grpVal, 0, 2)

# --- 1. Configuracion de Imagen ---
$cfgLayout = New-Object System.Windows.Forms.TableLayoutPanel
$cfgLayout.Dock = 'Fill'; $cfgLayout.AutoSize = $true
$cfgLayout.Padding = New-Object System.Windows.Forms.Padding(12, 22, 12, 12)
$cfgLayout.ColumnCount = 3
[void]$cfgLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$cfgLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$cfgLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
for($i=0; $i -lt 5; $i++){ [void]$cfgLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) }
$grpCfg.Controls.Clear()

$lblSrc.AutoSize=$true; $lblSrc.Dock='Fill'; $lblSrc.TextAlign='BottomLeft'; $lblSrc.Margin=New-Object System.Windows.Forms.Padding(3,3,3,3)
$txtSrc.Dock='Fill'; $txtSrc.Margin=New-Object System.Windows.Forms.Padding(3,4,3,3)
$btnSrc.AutoSize=$true; $btnSrc.Dock='Fill'; $btnSrc.Margin=New-Object System.Windows.Forms.Padding(3,3,3,3)
$lblDst.AutoSize=$true; $lblDst.Dock='Fill'; $lblDst.TextAlign='BottomLeft'; $lblDst.Margin=New-Object System.Windows.Forms.Padding(3,10,3,3)
$txtDst.Dock='Fill'; $txtDst.Margin=New-Object System.Windows.Forms.Padding(3,4,3,3)
$btnDst.AutoSize=$true; $btnDst.Dock='Fill'; $btnDst.Margin=New-Object System.Windows.Forms.Padding(3,3,3,3)
$lblLabel.AutoSize=$true; $lblLabel.Dock='Fill'; $lblLabel.TextAlign='MiddleLeft'; $lblLabel.Margin=New-Object System.Windows.Forms.Padding(3,10,3,3)
$txtLabel.Dock='Fill'; $txtLabel.Margin=New-Object System.Windows.Forms.Padding(3,10,3,3)

[void]$cfgLayout.Controls.Add($lblSrc, 0, 0); $cfgLayout.SetColumnSpan($lblSrc, 3)
[void]$cfgLayout.Controls.Add($txtSrc, 0, 1); $cfgLayout.SetColumnSpan($txtSrc, 2)
[void]$cfgLayout.Controls.Add($btnSrc, 2, 1)
[void]$cfgLayout.Controls.Add($lblDst, 0, 2); $cfgLayout.SetColumnSpan($lblDst, 3)
[void]$cfgLayout.Controls.Add($txtDst, 0, 3); $cfgLayout.SetColumnSpan($txtDst, 2)
[void]$cfgLayout.Controls.Add($btnDst, 2, 3)
[void]$cfgLayout.Controls.Add($lblLabel, 0, 4)
[void]$cfgLayout.Controls.Add($txtLabel, 1, 4); $cfgLayout.SetColumnSpan($txtLabel, 2)
[void]$grpCfg.Controls.Add($cfgLayout)

# --- 2. Automatizacion OOBE ---
$autoLayout = New-Object System.Windows.Forms.TableLayoutPanel
$autoLayout.Dock = 'Fill'; $autoLayout.AutoSize = $true
$autoLayout.Padding = New-Object System.Windows.Forms.Padding(12, 22, 12, 12)
$autoLayout.ColumnCount = 2
[void]$autoLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$autoLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
for($i=0; $i -lt 4; $i++){ [void]$autoLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) }
$grpAuto.Controls.Clear()

$lblAutoInfo.AutoSize=$true; $lblAutoInfo.Dock='Fill'; $lblAutoInfo.TextAlign='BottomLeft'; $lblAutoInfo.Margin=New-Object System.Windows.Forms.Padding(3,3,3,3)
$txtUnattend.Dock='Fill'; $txtUnattend.Margin=New-Object System.Windows.Forms.Padding(3,4,3,3)
$btnUnattend.AutoSize=$true; $btnUnattend.Dock='Fill'; $btnUnattend.Margin=New-Object System.Windows.Forms.Padding(3,3,3,3)
$lnkWeb.AutoSize=$true; $lnkWeb.Dock='Fill'; $lnkWeb.TextAlign='MiddleLeft'; $lnkWeb.Margin=New-Object System.Windows.Forms.Padding(3,10,3,3)
$chkMRP.AutoSize=$true; $chkMRP.Dock='Fill'; $chkMRP.Margin=New-Object System.Windows.Forms.Padding(3,10,3,3)

[void]$autoLayout.Controls.Add($lblAutoInfo, 0, 0); $autoLayout.SetColumnSpan($lblAutoInfo, 2)
[void]$autoLayout.Controls.Add($txtUnattend, 0, 1)
[void]$autoLayout.Controls.Add($btnUnattend, 1, 1)
[void]$autoLayout.Controls.Add($lnkWeb, 0, 2); $autoLayout.SetColumnSpan($lnkWeb, 2)
[void]$autoLayout.Controls.Add($chkMRP, 0, 3); $autoLayout.SetColumnSpan($chkMRP, 2)
[void]$grpAuto.Controls.Add($autoLayout)

# --- 3. Validacion ---
$valLayout = New-Object System.Windows.Forms.TableLayoutPanel
$valLayout.Dock = 'Fill'
$valLayout.Padding = New-Object System.Windows.Forms.Padding(12, 22, 12, 12)
$valLayout.ColumnCount = 1
[void]$valLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))

$valLayout.RowCount = 8
for($i=0; $i -lt 7; $i++){ 
    [void]$valLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) 
}
[void]$valLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

$grpVal.Controls.Clear()

foreach($c in @($lblValBoot, $lblValEfi, $lblValWim, $lblValSpace, $lblValSrcSize, $lblValLang)) {
    $c.AutoSize = $true; $c.Dock = 'Fill'; $c.TextAlign = 'MiddleLeft'
    $c.Margin = New-Object System.Windows.Forms.Padding(3, 4, 3, 4)
}
$btnCancelAnalysis.Dock = 'Top'; $btnCancelAnalysis.Margin = New-Object System.Windows.Forms.Padding(3, 10, 3, 3)

[void]$valLayout.Controls.Add($lblValBoot, 0, 0)
[void]$valLayout.Controls.Add($lblValEfi, 0, 1)
[void]$valLayout.Controls.Add($lblValWim, 0, 2)
[void]$valLayout.Controls.Add($lblValSpace, 0, 3)
[void]$valLayout.Controls.Add($lblValSrcSize, 0, 4)
[void]$valLayout.Controls.Add($lblValLang, 0, 5)
[void]$valLayout.Controls.Add($btnCancelAnalysis, 0, 6)
[void]$grpVal.Controls.Add($valLayout)

# --- 4. Progreso ---
$grpProg.Dock = 'Fill'; $grpProg.Controls.Clear()
$progLayout = New-Object System.Windows.Forms.TableLayoutPanel
$progLayout.Dock = 'Fill'
$progLayout.Padding = New-Object System.Windows.Forms.Padding(12, 22, 12, 12)
$progLayout.ColumnCount = 1
[void]$progLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))

[void]$progLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$progLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 45)))
[void]$progLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 35)))
[void]$progLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$progLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$progLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$progLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$progLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$progLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 0)))

$motorLayout = New-Object System.Windows.Forms.TableLayoutPanel
$motorLayout.Dock = 'Fill'; $motorLayout.AutoSize = $true; $motorLayout.Margin = New-Object System.Windows.Forms.Padding(0)
$motorLayout.ColumnCount = 2; $motorLayout.RowCount = 1
[void]$motorLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$motorLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$motorLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))

$lblMotorInfo.AutoSize = $true; $lblMotorInfo.Dock = 'Fill'; $lblMotorInfo.TextAlign = 'MiddleLeft'
$picCD.Margin = New-Object System.Windows.Forms.Padding(10, 0, 5, 0)
[void]$motorLayout.Controls.Add($lblMotorInfo, 0, 0)
[void]$motorLayout.Controls.Add($picCD, 1, 0)

$lblPhase.AutoSize = $false; $lblPhase.Dock = 'Fill'; $lblPhase.TextAlign = 'MiddleLeft'
$pbMain.Dock = 'Fill'; $pbMain.Margin = New-Object System.Windows.Forms.Padding(3, 5, 3, 5)
$lblPercent.AutoSize = $true; $lblPercent.Dock = 'Fill'; $lblPercent.TextAlign = 'MiddleLeft'; $lblPercent.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 10)
$lblFileInfo.AutoSize = $true; $lblFileInfo.Dock = 'Fill'; $lblFileInfo.TextAlign = 'MiddleLeft'; $lblFileInfo.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 4)
$lblSizeInfo.AutoSize = $true; $lblSizeInfo.Dock = 'Fill'; $lblSizeInfo.TextAlign = 'MiddleLeft'; $lblSizeInfo.Margin = New-Object System.Windows.Forms.Padding(3, 3, 3, 4)
$lblHashInfo.AutoSize = $true; $lblHashInfo.Dock = 'Fill'; $lblHashInfo.TextAlign = 'MiddleLeft'; $lblHashInfo.Margin = New-Object System.Windows.Forms.Padding(3, 10, 3, 10)
$btnDetails.Dock = 'Top'; $btnDetails.Margin = New-Object System.Windows.Forms.Padding(3, 10, 3, 3)
$txtDetails.Dock = 'Fill'; $txtDetails.Margin = New-Object System.Windows.Forms.Padding(3, 5, 3, 3)

[void]$progLayout.Controls.Add($motorLayout, 0, 0)
[void]$progLayout.Controls.Add($lblPhase, 0, 1)
[void]$progLayout.Controls.Add($pbMain, 0, 2)
[void]$progLayout.Controls.Add($lblPercent, 0, 3)
[void]$progLayout.Controls.Add($lblFileInfo, 0, 4)
[void]$progLayout.Controls.Add($lblSizeInfo, 0, 5)
[void]$progLayout.Controls.Add($lblHashInfo, 0, 6)
[void]$progLayout.Controls.Add($btnDetails, 0, 7)
[void]$progLayout.Controls.Add($txtDetails, 0, 8)
[void]$grpProg.Controls.Add($progLayout)

[void]$mainLayout.Controls.Add($leftLayout, 0, 0)
[void]$mainLayout.Controls.Add($grpProg, 1, 0)

# --- 5. Controles de Accion (Botones inferiores) ---
$actionLayout = New-Object System.Windows.Forms.TableLayoutPanel
$actionLayout.Dock = 'Fill'; $actionLayout.Margin = New-Object System.Windows.Forms.Padding(0)
$actionLayout.ColumnCount = 4; $actionLayout.RowCount = 1
[void]$actionLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 140)))
[void]$actionLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$actionLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 0))) # Oculto por defecto
[void]$actionLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 130)))
[void]$actionLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

$btnExportLog.Dock = 'Fill'; $btnExportLog.Margin = New-Object System.Windows.Forms.Padding(3, 3, 10, 3)
$btnMake.Dock = 'Fill'; $btnMake.Margin = New-Object System.Windows.Forms.Padding(3)
$btnCancel.Dock = 'Fill'; $btnCancel.Margin = New-Object System.Windows.Forms.Padding(10, 3, 3, 3)
$btnAbout.Dock = 'Fill'; $btnAbout.Margin = New-Object System.Windows.Forms.Padding(10, 3, 3, 3)

[void]$actionLayout.Controls.Add($btnExportLog, 0, 0)
[void]$actionLayout.Controls.Add($btnMake, 1, 0)
[void]$actionLayout.Controls.Add($btnCancel, 2, 0)
[void]$actionLayout.Controls.Add($btnAbout, 3, 0)

$btnOpenFolder.AutoSize = $false
$btnOpenFolder.Dock = 'Top'
$btnOpenFolder.Height = 35
$btnOpenFolder.Margin = New-Object System.Windows.Forms.Padding(0, 10, 0, 15)

[void]$rootLayout.Controls.Add($headerLayout, 0, 0)
[void]$rootLayout.Controls.Add($mainLayout, 0, 1)
[void]$rootLayout.Controls.Add($actionLayout, 0, 2)
[void]$rootLayout.Controls.Add($btnOpenFolder, 0, 3)

# ------------------------------------------------------------------
# Pestañas de IsoCore
# ------------------------------------------------------------------
$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Dock = 'Fill'
$tabControl.BackColor = $uiBg
$tabControl.ForeColor = $uiText
$tabControl.Padding = New-Object System.Drawing.Point(14, 5)

$tabGenerator = New-Object System.Windows.Forms.TabPage
$tabGenerator.Text = 'Generador ISO'
$tabGenerator.BackColor = $uiBg
$tabGenerator.ForeColor = $uiText
$tabGenerator.UseVisualStyleBackColor = $false
$tabGenerator.Padding = New-Object System.Windows.Forms.Padding(0)
[void]$tabGenerator.Controls.Add($rootLayout)
[void]$tabControl.TabPages.Add($tabGenerator)

$imageInfoState = @{ Page = $null }
$imageInfoLogCommand = Get-Command Write-IsoCoreLog -CommandType Function
$imageInfoLogAction = {
    param([string]$Level, [string]$Message)
    try { & $imageInfoLogCommand -LogLevel $Level -Message $Message } catch {}
}.GetNewClosure()

# La pestaña existe siempre, incluso si falta el modulo o falla su importacion.
$imageInfoPlaceholder = New-Object System.Windows.Forms.TabPage
$imageInfoPlaceholder.Name = 'IsoCoreImageInfoDiagnostic'
$imageInfoPlaceholder.Text = 'Info WIM / ESD'
$imageInfoPlaceholder.BackColor = $uiBg
$imageInfoPlaceholder.ForeColor = $uiText
$imageInfoPlaceholder.UseVisualStyleBackColor = $false
$imageInfoPlaceholder.Padding = New-Object System.Windows.Forms.Padding(16)

$imageInfoDiagnosticLayout = New-Object System.Windows.Forms.TableLayoutPanel
$imageInfoDiagnosticLayout.Dock = 'Fill'
$imageInfoDiagnosticLayout.ColumnCount = 1
$imageInfoDiagnosticLayout.RowCount = 2
[void]$imageInfoDiagnosticLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$imageInfoDiagnosticLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$imageInfoDiagnosticLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
$imageInfoDiagnostic = New-Object System.Windows.Forms.TextBox
$imageInfoDiagnostic.Name = 'ImageInfoLoadError'
$imageInfoDiagnostic.Multiline = $true
$imageInfoDiagnostic.ReadOnly = $true
$imageInfoDiagnostic.Dock = 'Fill'
$imageInfoDiagnostic.ScrollBars = 'Both'
$imageInfoDiagnostic.BackColor = $uiPanel
$imageInfoDiagnostic.ForeColor = $uiOrange
$imageInfoDiagnostic.Text = 'Cargando el visor WIM/ESD...'

$imageInfoRetry = New-Object System.Windows.Forms.Button
$imageInfoRetry.Text = 'Reintentar carga'
$imageInfoRetry.AutoSize = $true
$imageInfoRetry.BackColor = $uiCyan
$imageInfoRetry.ForeColor = [System.Drawing.Color]::Black
$imageInfoRetry.FlatStyle = 'Flat'
[void]$imageInfoDiagnosticLayout.Controls.Add($imageInfoDiagnostic, 0, 0)
[void]$imageInfoDiagnosticLayout.Controls.Add($imageInfoRetry, 0, 1)
[void]$imageInfoPlaceholder.Controls.Add($imageInfoDiagnosticLayout)
[void]$tabControl.TabPages.Add($imageInfoPlaceholder)

$imageInfoLogDirectory = $script:IsoCore_logDir
$loadImageInfoTab = {
    if ($null -ne $imageInfoState.Page) { return }
    $loadErrors = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in $imageInfoModuleCandidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $loadedPage = $null
        try {
            $infoModule = Import-Module -Name $candidate -Scope Local -Force -PassThru -ErrorAction Stop
            $factory = $infoModule.ExportedCommands['New-IsoCoreImageInfoTab']
            if ($null -eq $factory) { throw 'El modulo no exporta New-IsoCoreImageInfoTab.' }
            $loadedPage = & $factory -Palette $palette -LogAction $imageInfoLogAction -LogDirectory $imageInfoLogDirectory -ErrorAction Stop
            if ($loadedPage -isnot [System.Windows.Forms.TabPage]) {
                throw 'El modulo no devolvio una pestaña valida.'
            }
            $wasSelected = ($tabControl.SelectedTab -eq $imageInfoPlaceholder)
            [void]$tabControl.TabPages.Add($loadedPage)
            $tabControl.TabPages.Remove($imageInfoPlaceholder)
            $imageInfoState.Page = $loadedPage
            if ($wasSelected) { $tabControl.SelectedTab = $loadedPage }
            & $imageInfoLogAction 'INFO' "IsoCore: visor WIM/ESD cargado desde $candidate."
            return
        } catch {
            if ($loadedPage -is [System.Windows.Forms.TabPage]) {
                try { $loadedPage.Dispose() } catch {}
            }
            [void]$loadErrors.Add("$candidate`r`n$($_.Exception.Message)")
        }
    }
    $reason = if ($loadErrors.Count -gt 0) { $loadErrors -join "`r`n`r`n" } else { 'No se encontro IsoCore.ImageInfo.psm1.' }
    $imageInfoDiagnostic.Text = "No se pudo cargar el visor WIM/ESD.`r`n`r`n$reason`r`n`r`n" +
        "Extrae ambos archivos del paquete. Coloca Modules\IsoCore.ImageInfo.psm1 junto a IsoCore.ps1 y pulsa Reintentar carga.`r`n`r`n" +
        "Rutas comprobadas:`r`n" + ($imageInfoModuleCandidates -join "`r`n")
    & $imageInfoLogAction 'ERROR' "IsoCore: fallo al cargar el visor WIM/ESD. $reason"
}.GetNewClosure()
$imageInfoRetry.Add_Click({ & $loadImageInfoTab }.GetNewClosure())
& $loadImageInfoTab

[void]$form.Controls.Add($tabControl)
$form.ResumeLayout($true)

    $uiToolTip = New-Object System.Windows.Forms.ToolTip
    $uiToolTip.AutoPopDelay = 15000
    $uiToolTip.InitialDelay = 350
    $uiToolTip.ReshowDelay  = 100
    $uiToolTip.ShowAlways   = $true
    $uiToolTip.SetToolTip($lblMotorInfo, $motorText)
    foreach ($statusLabel in @($lblValBoot, $lblValEfi, $lblValWim, $lblValSpace, $lblValSrcSize, $lblValLang, $lblPhase, $lblFileInfo, $lblSizeInfo, $lblHashInfo)) {
        $statusLabel.Add_MouseEnter({
            try { $uiToolTip.SetToolTip($this, $this.Text) } catch {}
        })
    }

    # ------------------------------------------------------------------
    # 4. Helpers de UI
    # ------------------------------------------------------------------

    $script:IsoCore_SetPhase = {
        param([string]$Text, [System.Drawing.Color]$Color = $uiCyan)
        $lblPhase.Text      = $Text
        $lblPhase.ForeColor = $Color
        try { $uiToolTip.SetToolTip($lblPhase, $Text) } catch {}
        $form.Refresh()
    }

$script:IsoCore_RefreshDetails = {
    try {
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("ISOCORE - DETALLES DE ANALISIS")
        $lines.Add(('=' * 64))
        $lines.Add("Origen: $($txtSrc.Text)")
        $lines.Add("Destino: $($txtDst.Text)")
        $lines.Add("Arquitectura: $(if($script:IsoCore_detectedArchitecture){$script:IsoCore_detectedArchitecture}else{'Pendiente'})")
        $lines.Add($lblValLang.Text.TrimStart('•',' '))
        $lines.Add($lblValSrcSize.Text.TrimStart('•',' '))
        $lines.Add($lblValWim.Text.TrimStart('•',' '))
        if ($script:IsoCore_sourceSnapshot) {
            $lines.Add("Huella completa: $($script:IsoCore_sourceSnapshot.FullFingerprint)")
            $lines.Add("Archivos: $($script:IsoCore_sourceSnapshot.FileCount) | Directorios: $($script:IsoCore_sourceSnapshot.DirCount) | Reparse: $($script:IsoCore_sourceSnapshot.ReparsePointCount)")
        }
        if ($script:IsoCore_analysisDismResult) {
            $d=$script:IsoCore_analysisDismResult
            if ($d.ImageCount) { $lines.Add("Indices de imagen: $($d.ImageCount)") }
            if ($d.ImageNames) { $lines.Add("Ediciones: $($d.ImageNames -join ', ')") }
            if ($d.InstalledLanguages) { $lines.Add("Idiomas instalados: $($d.InstalledLanguages -join ', ')") }
        }
        if (-not [string]::IsNullOrWhiteSpace($txtSrc.Text) -and (Test-Path -LiteralPath $txtSrc.Text -PathType Container)) {
            $swm=& $script:IsoCore_GetSwmSetInfo $txtSrc.Text $false
            if ($swm.Exists) { $lines.Add("SWM: $($swm.Summary) | $($swm.TotalBytes) bytes") }
        }
        $lines.Add('')
        $lines.Add("oscdimg: $oscdimgExe")
        $lines.Add("Version: $oscdimgVerStr")
        $lines.Add("Firma: $oscdimgSignatureStatus")
        $lines.Add("Firmante: $oscdimgSigner")
        $lines.Add("SHA-256 motor: $oscdimgHash")
        if ($script:IsoCore_buildBootProfile) { $lines.Add("Perfil de arranque: $($script:IsoCore_buildBootProfile)") }
        $lines.Add("Estado de salida: $($script:IsoCore_outputTransactionState)")
        if ($script:IsoCore_buildAttempts) {
            $lines.Add('Perfiles oscdimg:')
            foreach($a in $script:IsoCore_buildAttempts){$lines.Add(" - $($a.Name): $($a.Args)")}
        }
        $txtDetails.Text = $lines -join "`r`n"
    } catch { $txtDetails.Text = "No se pudieron actualizar los detalles: $($_.Exception.Message)" }
}

$script:IsoCore_UpdateActionLayout = {
    if ($null -eq $actionLayout -or $actionLayout.IsDisposed) { return }
    try {
        if ($btnCancel.Visible) {
            $actionLayout.ColumnStyles[2].Width = 150
        } else {
            $actionLayout.ColumnStyles[2].Width = 0
        }
    } catch {}
}

$script:IsoCore_UpdateAnalysisState = {
    $running = ($null -ne $script:IsoCore_sizeTimer) -or ($null -ne $script:IsoCore_dismTimer)
    $btnCancelAnalysis.Visible = $running
    $btnMake.Enabled = -not $running
    if (-not $running) { & $script:IsoCore_RefreshDetails }
}

$script:IsoCore_SaveAnalysisCache = {
    if ($null -eq $script:IsoCore_analysisSizeResult -or $null -eq $script:IsoCore_analysisDismResult) { return }
    if ([string]::IsNullOrWhiteSpace([string]$script:IsoCore_analyzedSource)) { return }
    $key = (& $script:IsoCore_NormalizeDirectoryPath ([string]$script:IsoCore_analyzedSource)).ToUpperInvariant()
    $script:IsoCore_analysisCache[$key] = [pscustomobject]@{
        QuickFingerprint = $script:IsoCore_analysisQuickFingerprint
        SizeResult = $script:IsoCore_analysisSizeResult
        DismResult = $script:IsoCore_analysisDismResult
        Snapshot = $script:IsoCore_sourceSnapshot
        SavedAt = Get-Date
    }
}

$script:IsoCore_CancelAnalysis = {
    $script:IsoCore_analysisCancelled = $true
    foreach($timerName in @('sizeTimer','dismTimer')) {
        $timer=Get-Variable -Name ("IsoCore_"+$timerName) -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        if($timer){try{$timer.Stop();$timer.Dispose()}catch{};Set-Variable -Name ("IsoCore_"+$timerName) -Scope Script -Value $null}
    }
    foreach($psName in @('sizePS','dismPS')) {
        $ps=Get-Variable -Name ("IsoCore_"+$psName) -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        if($ps){try{$ps.Stop();$ps.Dispose()}catch{};Set-Variable -Name ("IsoCore_"+$psName) -Scope Script -Value $null}
    }
    foreach($rsName in @('sizeRS','dismRS')) {
        $rs=Get-Variable -Name ("IsoCore_"+$rsName) -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        if($rs){try{$rs.Close();$rs.Dispose()}catch{};Set-Variable -Name ("IsoCore_"+$rsName) -Scope Script -Value $null}
    }
    $script:IsoCore_sizeQueue=$null; $script:IsoCore_dismQueue=$null
    $script:IsoCore_sizeHandle=$null; $script:IsoCore_dismHandle=$null
    $btnSrc.Enabled=$true
    $pbMain.Style=[System.Windows.Forms.ProgressBarStyle]::Continuous; $pbMain.Value=0
    & $script:IsoCore_SetPhase 'Analisis cancelado por el usuario.' ([System.Drawing.Color]::Orange)
    & $script:IsoCore_UpdateAnalysisState
    Write-IsoCoreLog -LogLevel WARN -Message 'IsoCore: Analisis de fuente cancelado por el usuario.'
}

    $script:IsoCore_RestoreCompileUI = {
        if ($null -ne $cdTimer -and -not $cdTimer.IsDisposed) { try { $cdTimer.Stop() } catch {} }
        if ($null -ne $picCD   -and -not $picCD.IsDisposed)   { $picCD.Visible = $false }
        if ($null -ne $btnCancel -and -not $btnCancel.IsDisposed) { $btnCancel.Visible = $false }
        if ($null -ne $btnMake -and -not $btnMake.IsDisposed) { & $script:IsoCore_UpdateActionLayout }
        if ($null -ne $form -and -not $form.IsDisposed) {
            $btnMake.Enabled  = $true
            $grpCfg.Enabled   = $true
            $grpAuto.Enabled  = $true
            $form.Cursor      = [System.Windows.Forms.Cursors]::Default
        }
    }

    # Libera el proceso y sus lectores asincronicos sin dejar callbacks asociados.
    $script:IsoCore_DisposeIsoProcess = {
        param([bool]$KillProcess = $false)

        if ($null -ne $script:IsoCore_isoProc) {
            if ($KillProcess) {
                try {
                    if (-not $script:IsoCore_isoProc.HasExited) {
                        $script:IsoCore_isoProc.Kill()
                        [void]$script:IsoCore_isoProc.WaitForExit(3000)
                    }
                } catch {}
            }
            try { $script:IsoCore_isoProc.CancelOutputRead() } catch {}
            try { $script:IsoCore_isoProc.CancelErrorRead()  } catch {}
            if ($null -ne $script:IsoCore_stdoutHandler) {
                try { $script:IsoCore_isoProc.remove_OutputDataReceived($script:IsoCore_stdoutHandler) } catch {}
            }
            if ($null -ne $script:IsoCore_stderrHandler) {
                try { $script:IsoCore_isoProc.remove_ErrorDataReceived($script:IsoCore_stderrHandler) } catch {}
            }
            try { $script:IsoCore_isoProc.Dispose() } catch {}
        }
        $script:IsoCore_isoProc       = $null
        $script:IsoCore_stdoutHandler = $null
        $script:IsoCore_stderrHandler = $null
    }

    $script:IsoCore_CaptureInterruptedBuildLog = {
        param(
            [string]$ResultText = 'CANCELADO POR EL USUARIO',
            [string]$FilePrefix = 'ISO_Build_CANCELLED'
        )

        try {
            $line = $null
            if ($null -ne $script:IsoCore_outQueue -and $null -ne $script:IsoCore_attemptOutLogBuilder) {
                while ($script:IsoCore_outQueue.TryDequeue([ref]$line)) {
                    [void]$script:IsoCore_attemptOutLogBuilder.AppendLine($line)
                }
            }
            if ($null -ne $script:IsoCore_errQueue -and $null -ne $script:IsoCore_errLogBuilder) {
                while ($script:IsoCore_errQueue.TryDequeue([ref]$line)) {
                    if (-not [string]::IsNullOrWhiteSpace($line)) {
                        [void]$script:IsoCore_errLogBuilder.AppendLine($line)
                    }
                }
            }

            if ($null -eq $script:IsoCore_cleanLogBuilder) {
                $script:IsoCore_cleanLogBuilder = New-Object System.Text.StringBuilder
                [void]$script:IsoCore_cleanLogBuilder.AppendLine('COMPILACION ISO INTERRUMPIDA')
            }

            if ($null -ne $script:IsoCore_attemptOutLogBuilder) {
                $partialOutput = $script:IsoCore_attemptOutLogBuilder.ToString()
                if (-not [string]::IsNullOrEmpty($partialOutput)) {
                    [void]$script:IsoCore_cleanLogBuilder.Append($partialOutput)
                }
            }

            [void]$script:IsoCore_cleanLogBuilder.AppendLine('')
            [void]$script:IsoCore_cleanLogBuilder.AppendLine("RESULTADO: $ResultText")

            if ($null -ne $script:IsoCore_errLogBuilder) {
                $partialError = $script:IsoCore_errLogBuilder.ToString().Trim()
                if (-not [string]::IsNullOrWhiteSpace($partialError)) {
                    [void]$script:IsoCore_cleanLogBuilder.AppendLine('SALIDA STDERR DISPONIBLE:')
                    [void]$script:IsoCore_cleanLogBuilder.AppendLine($partialError)
                }
            }

            $script:IsoCore_lastBuildLog = $script:IsoCore_cleanLogBuilder.ToString()
            if (-not [string]::IsNullOrWhiteSpace($script:IsoCore_lastBuildLog) -and
                $script:IsoCore_logDir -and
                (Test-Path -LiteralPath $script:IsoCore_logDir -PathType Container)) {
                $interruptedLog = Join-Path $script:IsoCore_logDir ("{0}_{1}.log" -f $FilePrefix, (Get-Date -Format 'yyyyMMdd_HHmmss'))
                [System.IO.File]::WriteAllText(
                    $interruptedLog,
                    $script:IsoCore_lastBuildLog,
                    ([System.Text.UTF8Encoding]::new($true))
                )
                Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: Log de compilacion interrumpida guardado en: $interruptedLog"
                return $interruptedLog
            }
        } catch {
            Write-IsoCoreLog -LogLevel WARN -Message "IsoCore: No se pudo conservar el log parcial: $($_.Exception.Message)"
        }
        return $null
    }

    $script:IsoCore_QuoteWindowsArgument = {
        param([Parameter(Mandatory=$true)][string]$Value)
        if ($Value.IndexOf([char]34) -ge 0) {
            throw "La ruta contiene un caracter de comillas no valido: $Value"
        }
        $escaped = [regex]::Replace($Value, '(\\+)$', '$1$1')
        return '"' + $escaped + '"'
    }

    $script:IsoCore_RemoveBootOrderFile = {
        if ($script:IsoCore_bootOrderFile -and (Test-Path -LiteralPath $script:IsoCore_bootOrderFile)) {
            try {
                Remove-Item -LiteralPath $script:IsoCore_bootOrderFile -Force -ErrorAction Stop
            } catch {
                Write-IsoCoreLog -LogLevel WARN -Message "IsoCore: No se pudo eliminar BootOrder temporal '$script:IsoCore_bootOrderFile': $($_.Exception.Message)"
            }
        }
        $script:IsoCore_bootOrderFile = $null
    }

    $script:IsoCore_NewBootOrderFile = {
        param([Parameter(Mandatory=$true)][string]$SourcePath)

        & $script:IsoCore_RemoveBootOrderFile

        $candidates = @(
            'boot\bcd',
            'boot\boot.sdi',
            'boot\bootfix.bin',
            'boot\bootsect.exe',
            'boot\etfsboot.com',
            'boot\memtest.efi',
            'boot\memtest.exe',
            'efi\microsoft\boot\bcd',
            'efi\microsoft\boot\efisys.bin',
            'efi\microsoft\boot\efisys_noprompt.bin',
            'efi\boot\bootia32.efi',
            'efi\boot\bootx64.efi',
            'efi\boot\bootaa64.efi',
            'sources\boot.wim'
        )

        $orderedFiles = @(
            $candidates | Where-Object {
                Test-Path -LiteralPath (Join-Path $SourcePath $_) -PathType Leaf
            }
        )
        if ($orderedFiles.Count -eq 0) {
            throw "No se encontraron archivos de arranque para generar BootOrder.txt."
        }

        $tempRoots = @(
            (Join-Path $env:SystemRoot 'Temp'),
            (Join-Path $env:SystemDrive 'IsoCoreTemp'),
            ([System.IO.Path]::GetTempPath())
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

        $tempRoot = $null
        foreach ($candidateRoot in $tempRoots) {
            try {
                $candidateFull = [System.IO.Path]::GetFullPath($candidateRoot)
                if ($candidateFull -match '\s') { continue }
                if (-not (Test-Path -LiteralPath $candidateFull -PathType Container)) {
                    New-Item -Path $candidateFull -ItemType Directory -Force -ErrorAction Stop | Out-Null
                }
                $probe = Join-Path $candidateFull "IsoCore_$([guid]::NewGuid().ToString('N')).tmp"
                [System.IO.File]::WriteAllText($probe, 'OK', [System.Text.Encoding]::ASCII)
                Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
                $tempRoot = $candidateFull
                break
            } catch {}
        }
        if (-not $tempRoot) {
            throw "No se encontró una carpeta temporal escribible y sin espacios para BootOrder.txt."
        }

        $tempName = "IsoCore_BootOrder_$([guid]::NewGuid().ToString('N')).txt"
        $script:IsoCore_bootOrderFile = Join-Path $tempRoot $tempName
        $content = ($orderedFiles -join "`r`n") + "`r`n"
        [System.IO.File]::WriteAllText(
            $script:IsoCore_bootOrderFile,
            $content,
            [System.Text.Encoding]::ASCII
        )
        return $script:IsoCore_bootOrderFile
    }

    $script:IsoCore_FinalizeIsoOutput = {
        param([bool]$Success)

        $transactionActive = [bool]$script:IsoCore_outputTransactionStarted -or
                             -not [string]::IsNullOrWhiteSpace([string]$script:IsoCore_previousIsoBackup) -or
                             -not [string]::IsNullOrWhiteSpace([string]$script:IsoCore_previousHashBackup)
        if (-not $transactionActive) { return }

        $hashPath = if ($script:IsoCore_iso) { [System.IO.Path]::ChangeExtension($script:IsoCore_iso, '.sha256') } else { $null }

        if (-not [bool]$script:IsoCore_outputTransactionStarted) {
            if ($script:IsoCore_previousIsoBackup -and (Test-Path -LiteralPath $script:IsoCore_previousIsoBackup)) {
                if (-not (Test-Path -LiteralPath $script:IsoCore_iso)) {
                    try { Move-Item -LiteralPath $script:IsoCore_previousIsoBackup -Destination $script:IsoCore_iso -Force -ErrorAction Stop } catch {
                        Write-IsoCoreLog -LogLevel ERROR -Message "IsoCore: No se pudo restaurar la ISO durante la preparacion: $($_.Exception.Message)"
                    }
                } else {
                    Write-IsoCoreLog -LogLevel ERROR -Message "IsoCore: No se restauro '$script:IsoCore_previousIsoBackup' porque el destino '$script:IsoCore_iso' ya existe."
                }
            }
            if ($script:IsoCore_previousHashBackup -and (Test-Path -LiteralPath $script:IsoCore_previousHashBackup)) {
                if (-not (Test-Path -LiteralPath $hashPath)) {
                    try { Move-Item -LiteralPath $script:IsoCore_previousHashBackup -Destination $hashPath -Force -ErrorAction Stop } catch {
                        Write-IsoCoreLog -LogLevel ERROR -Message "IsoCore: No se pudo restaurar el hash durante la preparacion: $($_.Exception.Message)"
                    }
                } else {
                    Write-IsoCoreLog -LogLevel ERROR -Message "IsoCore: No se restauro '$script:IsoCore_previousHashBackup' porque el destino '$hashPath' ya existe."
                }
            }
            $script:IsoCore_previousIsoBackup        = $null
            $script:IsoCore_previousHashBackup       = $null
            $script:IsoCore_outputTransactionStarted = $false
            $script:IsoCore_outputTransactionState   = 'ROLLED_BACK'
            return
        }

        if ($Success) {
            foreach ($backup in @($script:IsoCore_previousIsoBackup, $script:IsoCore_previousHashBackup)) {
                if ($backup -and (Test-Path -LiteralPath $backup)) {
                    try { Remove-Item -LiteralPath $backup -Force -ErrorAction Stop } catch {
                        Write-IsoCoreLog -LogLevel WARN -Message "IsoCore: No se pudo eliminar el respaldo temporal '$backup': $($_.Exception.Message)"
                    }
                }
            }
        } else {
            if ($script:IsoCore_iso -and (Test-Path -LiteralPath $script:IsoCore_iso)) {
                try { Remove-Item -LiteralPath $script:IsoCore_iso -Force -ErrorAction Stop } catch {
                    Write-IsoCoreLog -LogLevel WARN -Message "IsoCore: No se pudo retirar la ISO parcial '$script:IsoCore_iso': $($_.Exception.Message)"
                }
            }
            if ($hashPath -and (Test-Path -LiteralPath $hashPath)) {
                try { Remove-Item -LiteralPath $hashPath -Force -ErrorAction Stop } catch {
                    Write-IsoCoreLog -LogLevel WARN -Message "IsoCore: No se pudo retirar el hash parcial '$hashPath': $($_.Exception.Message)"
                }
            }
            if ($script:IsoCore_previousIsoBackup -and (Test-Path -LiteralPath $script:IsoCore_previousIsoBackup)) {
                try { Move-Item -LiteralPath $script:IsoCore_previousIsoBackup -Destination $script:IsoCore_iso -Force -ErrorAction Stop } catch {
                    Write-IsoCoreLog -LogLevel ERROR -Message "IsoCore: No se pudo restaurar la ISO anterior: $($_.Exception.Message)"
                }
            }
            if ($script:IsoCore_previousHashBackup -and (Test-Path -LiteralPath $script:IsoCore_previousHashBackup)) {
                try { Move-Item -LiteralPath $script:IsoCore_previousHashBackup -Destination $hashPath -Force -ErrorAction Stop } catch {
                    Write-IsoCoreLog -LogLevel ERROR -Message "IsoCore: No se pudo restaurar el hash anterior: $($_.Exception.Message)"
                }
            }
        }
        $script:IsoCore_previousIsoBackup       = $null
        $script:IsoCore_previousHashBackup      = $null
        $script:IsoCore_outputTransactionStarted = $false
        if (-not $Success) { $script:IsoCore_outputTransactionState = 'ROLLED_BACK' }
    }

# ------------------------------------------------------------------
# Helpers de integridad, arquitectura, SWM, huella y verificacion ISO
# ------------------------------------------------------------------
$script:IsoCore_GetStringSha256 = {
    param([AllowEmptyString()][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    } finally {
        $sha.Dispose()
    }
}

$script:IsoCore_ResolveArchitecture = {
    param([string]$ArchitectureValue, [string]$SourcePath)

    $normalized = if ([string]::IsNullOrWhiteSpace($ArchitectureValue)) { '' } else { $ArchitectureValue.Trim().ToUpperInvariant() }
    $known = switch -Regex ($normalized) {
        '^(0|X86|INTEL)$'      { 'X86'; break }
        '^(9|X64|AMD64)$'      { 'X64'; break }
        '^(12|ARM64|AARCH64)$' { 'ARM64'; break }
        default                { $null }
    }
    if ($known) { return $known }

    $detected = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($SourcePath)) {
        if (Test-Path -LiteralPath (Join-Path $SourcePath 'efi\boot\bootaa64.efi') -PathType Leaf) { $detected.Add('ARM64') }
        if (Test-Path -LiteralPath (Join-Path $SourcePath 'efi\boot\bootx64.efi')  -PathType Leaf) { $detected.Add('X64') }
        if (Test-Path -LiteralPath (Join-Path $SourcePath 'efi\boot\bootia32.efi') -PathType Leaf) { $detected.Add('X86') }
    }
    $unique = @($detected | Select-Object -Unique)
    if ($unique.Count -eq 1) { return [string]$unique[0] }
    return 'DESCONOCIDA'
}

$script:IsoCore_GetSwmSetInfo = {
    param(
        [Parameter(Mandatory=$true)][string]$SourcePath,
        [bool]$ValidateWithDism = $false
    )

    $result = [ordered]@{
        Exists       = $false
        Valid        = $false
        PartCount    = 0
        TotalBytes   = 0L
        ImageCount   = 0
        BasePath     = $null
        Pattern      = $null
        Parts        = @()
        MissingParts = @()
        Errors       = @()
        Summary      = 'No se encontro un conjunto SWM.'
    }

    try {
        $sourcesDir = Join-Path $SourcePath 'sources'
        if (-not (Test-Path -LiteralPath $sourcesDir -PathType Container)) { return [pscustomobject]$result }

        $allCandidates = @(Get-ChildItem -LiteralPath $sourcesDir -Filter 'install*.swm' -File -ErrorAction SilentlyContinue)
        if ($allCandidates.Count -eq 0) { return [pscustomobject]$result }
        $result.Exists = $true

        $numbered = @{}
        foreach ($file in $allCandidates) {
            if ($file.Name -notmatch '^install(?<n>\d*)\.swm$') {
                $result.Errors += "Nombre SWM no valido: $($file.Name)"
                continue
            }
            $part = if ([string]::IsNullOrWhiteSpace($matches['n'])) { 1 } else { [int]$matches['n'] }
            if ($part -lt 1) {
                $result.Errors += "Numero de parte SWM no valido: $($file.Name)"
                continue
            }
            if ($numbered.ContainsKey($part)) {
                $result.Errors += "Parte SWM duplicada: $part"
                continue
            }
            if ($file.Length -le 0) { $result.Errors += "Parte SWM vacia: $($file.Name)" }
            $numbered[$part] = $file
            $result.TotalBytes += [long]$file.Length
        }

        if (-not $numbered.ContainsKey(1) -or $numbered[1].Name -ine 'install.swm') {
            $result.Errors += 'Falta sources\install.swm, que debe ser la primera parte del conjunto.'
        }

        if ($numbered.Count -gt 0) {
            $maxPart = [int](($numbered.Keys | Measure-Object -Maximum).Maximum)
            for ($n = 1; $n -le $maxPart; $n++) {
                if (-not $numbered.ContainsKey($n)) { $result.MissingParts += $n }
            }
            if ($result.MissingParts.Count -gt 0) {
                $result.Errors += "Faltan partes SWM: $($result.MissingParts -join ', ')"
            }
            $result.Parts = @($numbered.GetEnumerator() | Sort-Object Key | ForEach-Object { $_.Value.FullName })
            $result.PartCount = $result.Parts.Count
            $result.BasePath = if ($numbered.ContainsKey(1)) { $numbered[1].FullName } else { $null }
            $result.Pattern = Join-Path $sourcesDir 'install*.swm'
        }

        if ($result.Errors.Count -eq 0 -and $ValidateWithDism -and $result.BasePath) {

            $readable = $false
            $dismCmd = Get-Command dism.exe -ErrorAction SilentlyContinue
            if ($dismCmd) {
                if ([string]::IsNullOrWhiteSpace($script:IsoCore_logDir)) { throw 'No se ha configurado la carpeta Logs para DISM.' }
                [void][IO.Directory]::CreateDirectory($script:IsoCore_logDir)
                $dismLogPath = Join-Path $script:IsoCore_logDir ('DISM_ISO_SWM_' + [datetime]::UtcNow.ToString('yyyyMMdd_HHmmss_fff') + '_' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.log')
                $dismOutput = @(& $dismCmd.Source '/English' '/Get-ImageInfo' "/ImageFile:$($result.BasePath)" "/SWMFile:$($result.Pattern)" "/LogPath:$dismLogPath" 2>&1)
                $dismExitCode = $LASTEXITCODE
                if ($dismExitCode -eq 0) {
                    $result.ImageCount = @($dismOutput | Where-Object { [string]$_ -match '^\s*Index\s*:' }).Count
                    $readable = ($result.ImageCount -gt 0)
                    if (-not $readable) {
                        $result.Errors += 'DISM proceso el conjunto SWM, pero no devolvio ningun indice.'
                    }
                } else {
                    $detail = @($dismOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 6) -join ' | '
                    $result.Errors += ("DISM no pudo leer el conjunto SWM (codigo $dismExitCode). $detail").Trim()
                }
            } else {
                $result.Errors += 'No se encontro dism.exe para validar el conjunto SWM completo.'
            }
            if (-not $readable -and $result.Errors.Count -eq 0) {
                $result.Errors += 'DISM no devolvio indices para el conjunto SWM.'
            }
        }

        $result.Valid = ($result.Errors.Count -eq 0)
        if ($result.Valid) {
            $imagesText = if ($result.ImageCount -gt 0) { " | $($result.ImageCount) indices" } else { '' }
            $result.Summary = "Conjunto SWM valido: $($result.PartCount) partes$imagesText"
        } else {
            $result.Summary = "Conjunto SWM no valido: $($result.Errors -join ' | ')"
        }
    } catch {
        $result.Errors += $_.Exception.Message
        $result.Valid = $false
        $result.Summary = "No se pudo validar SWM: $($_.Exception.Message)"
    }
    return [pscustomobject]$result
}

$script:IsoCore_NormalizeDirectoryPath = {
    param([Parameter(Mandatory=$true)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ([string]::Equals($full, $root, [StringComparison]::OrdinalIgnoreCase)) { return $root }
    return $full.TrimEnd([char[]]@('\','/'))
}

$script:IsoCore_GetQuickSourceFingerprint = {
    param([Parameter(Mandatory=$true)][string]$SourcePath)
    $full = & $script:IsoCore_NormalizeDirectoryPath $SourcePath
    $items = New-Object System.Collections.Generic.List[string]
    $items.Add("PATH|$full")
    foreach ($relative in @('', 'sources', 'boot', 'efi', 'sources\boot.wim', 'sources\install.wim', 'sources\install.esd', 'sources\lang.ini')) {
        $candidate = if ([string]::IsNullOrEmpty($relative)) { $full } else { Join-Path $full $relative }
        if (Test-Path -LiteralPath $candidate) {
            $item = Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
            if ($item) {
                $length = if ($item.PSIsContainer) { 0L } else { [long]$item.Length }
                $items.Add("$relative|$length|$($item.LastWriteTimeUtc.Ticks)")
            }
        } else {
            $items.Add("$relative|MISSING")
        }
    }
    $sources = Join-Path $full 'sources'
    if (Test-Path -LiteralPath $sources -PathType Container) {
        foreach ($swm in @(Get-ChildItem -LiteralPath $sources -Filter 'install*.swm' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $items.Add("SWM|$($swm.Name)|$($swm.Length)|$($swm.LastWriteTimeUtc.Ticks)")
        }
    }
    $material = $items -join "`n"
    return [pscustomobject]@{
        Path     = $full
        Value    = (& $script:IsoCore_GetStringSha256 $material)
        Material = $material
    }
}

$script:IsoCore_GetSourceSnapshot = {
    param(
        [Parameter(Mandatory=$true)][string]$SourcePath,
        [scriptblock]$ProgressCallback = $null
    )

    $full = & $script:IsoCore_NormalizeDirectoryPath $SourcePath
    $bytes = 0L; $files = 0; $dirs = 0; $reparse = 0; $latestTicks = 0L
    $metadata = New-Object System.Collections.Generic.List[string]
    $lastProgress = [DateTime]::UtcNow

    Get-ChildItem -LiteralPath $full -Recurse -Force -ErrorAction Stop | ForEach-Object {
        $isReparse = (($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
        if ($isReparse) { $reparse++ }
        if ($_.PSIsContainer) { $dirs++; $kind = 'D'; $length = 0L } else { $files++; $kind = 'F'; $length = [long]$_.Length; $bytes += $length }
        if ($_.LastWriteTimeUtc.Ticks -gt $latestTicks) { $latestTicks = $_.LastWriteTimeUtc.Ticks }

        $relative = $_.FullName.Substring($full.Length).TrimStart([char[]]@('\','/'))
        $metadata.Add("$relative|$kind|$length|$($_.LastWriteTimeUtc.Ticks)|$([int]$_.Attributes)")

        if ($ProgressCallback -and (([DateTime]::UtcNow - $lastProgress).TotalMilliseconds -ge 250)) {
            & $ProgressCallback $files $dirs $bytes
            $lastProgress = [DateTime]::UtcNow
        }
    }

    if ($ProgressCallback) { & $ProgressCallback $files $dirs $bytes }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $encoding = [System.Text.Encoding]::UTF8
        foreach ($line in @($metadata | Sort-Object)) {
            $buffer = $encoding.GetBytes($line + "`n")
            [void]$sha.TransformBlock($buffer, 0, $buffer.Length, $buffer, 0)
        }
        $empty = [byte[]]@()
        [void]$sha.TransformFinalBlock($empty, 0, 0)
        $metadataFingerprint = ([System.BitConverter]::ToString($sha.Hash)).Replace('-', '')
    } finally {
        $sha.Dispose()
    }

    $quick = & $script:IsoCore_GetQuickSourceFingerprint $full
    $material = "$full|$bytes|$files|$dirs|$reparse|$latestTicks|$($quick.Value)|$metadataFingerprint"
    return [pscustomobject]@{
        Path = $full; Bytes = $bytes; FileCount = $files; DirCount = $dirs
        ReparsePointCount = $reparse; LatestWriteTicks = $latestTicks
        QuickFingerprint = $quick.Value; MetadataFingerprint = $metadataFingerprint
        FullFingerprint = (& $script:IsoCore_GetStringSha256 $material)
    }
}



$script:IsoCore_TestIsoImage = {
    param(
        [Parameter(Mandatory=$true)][string]$IsoPath,
        [Parameter(Mandatory=$true)][ValidateSet('BIOS','UEFI','DUAL')][string]$BootProfile,
        [bool]$RequireInstallImage = $true,
        [string[]]$ExpectedFiles = @(),
        [string]$ExpectedVolumeLabel = $null
    )

    $result = [ordered]@{ Valid = $false; Root = $null; Checks = @(); Errors = @(); Warnings = @() }
    $diskImage = $null
    $mountedByIsoCore = $false
    $isNonEmptyFile = {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
        try { return ((Get-Item -LiteralPath $Path -Force -ErrorAction Stop).Length -gt 0) } catch { return $false }
    }

    try {
        if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) { throw 'La ISO que se intentara verificar no existe.' }
        if ((Get-Item -LiteralPath $IsoPath -ErrorAction Stop).Length -le 0) { throw 'La ISO que se intentara verificar esta vacia.' }
        if (-not (Get-Command Mount-DiskImage -ErrorAction SilentlyContinue) -or
            -not (Get-Command Get-DiskImage -ErrorAction SilentlyContinue) -or
            -not (Get-Command Get-Volume -ErrorAction SilentlyContinue)) {
            throw 'Los cmdlets Mount-DiskImage, Get-DiskImage o Get-Volume no estan disponibles.'
        }

        $diskImage = Get-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue
        if ($null -eq $diskImage -or -not $diskImage.Attached) {
            $diskImage = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
            $mountedByIsoCore = $true
        }

        $volumes = @()
        for ($retry = 0; $retry -lt 20 -and $volumes.Count -eq 0; $retry++) {
            $volumes = @($diskImage | Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter })
            if ($volumes.Count -eq 0) { Start-Sleep -Milliseconds 250 }
        }
        if ($volumes.Count -eq 0) { throw 'La ISO se monto, pero no se obtuvo una letra de unidad.' }

        $root = "$($volumes[0].DriveLetter):\"
        $result.Root = $root
        if (-not [string]::IsNullOrWhiteSpace($ExpectedVolumeLabel)) {
            $actualLabel = [string]$volumes[0].FileSystemLabel
            $labelMatches = [string]::Equals($actualLabel, $ExpectedVolumeLabel, [StringComparison]::OrdinalIgnoreCase)
            $result.Checks += [pscustomobject]@{ Item="Etiqueta de volumen ($ExpectedVolumeLabel)"; Present=$labelMatches }
            if (-not $labelMatches) { $result.Errors += "La etiqueta de volumen es '$actualLabel' y se esperaba '$ExpectedVolumeLabel'." }
        }
        $fileSystem = [string]$volumes[0].FileSystem
        if (-not [string]::IsNullOrWhiteSpace($fileSystem) -and $fileSystem -notmatch '^UDF') {
            $result.Warnings += "El sistema de archivos montado se identifico como '$fileSystem' en lugar de UDF."
        }

        $required = New-Object System.Collections.Generic.List[string]
        $required.Add('sources\boot.wim')
        if ($BootProfile -in @('BIOS','DUAL')) { $required.Add('boot\etfsboot.com') }
        if ($BootProfile -in @('UEFI','DUAL')) {
            $efiStandard = Join-Path $root 'efi\microsoft\boot\efisys.bin'
            $efiNoPrompt = Join-Path $root 'efi\microsoft\boot\efisys_noprompt.bin'
            $hasEfi = (& $isNonEmptyFile $efiStandard) -or (& $isNonEmptyFile $efiNoPrompt)
            $result.Checks += [pscustomobject]@{ Item='Arranque UEFI'; Present=$hasEfi }
            if (-not $hasEfi) { $result.Errors += 'No se encontro una imagen de arranque UEFI valida dentro de la ISO.' }
        }

        foreach ($relative in $required) {
            $present = & $isNonEmptyFile (Join-Path $root $relative)
            $result.Checks += [pscustomobject]@{ Item=$relative; Present=$present }
            if (-not $present) { $result.Errors += "Falta $relative o el archivo esta vacio dentro de la ISO." }
        }

        if ($RequireInstallImage) {
            $hasWim = & $isNonEmptyFile (Join-Path $root 'sources\install.wim')
            $hasEsd = & $isNonEmptyFile (Join-Path $root 'sources\install.esd')
            $swmInfo = & $script:IsoCore_GetSwmSetInfo $root $false
            if ($swmInfo.Exists -and -not $swmInfo.Valid) {
                $result.Errors += "El conjunto SWM dentro de la ISO no es valido: $($swmInfo.Errors -join ' | ')"
            }
            $hasInstall = $hasWim -or $hasEsd -or ($swmInfo.Exists -and $swmInfo.Valid)
            $result.Checks += [pscustomobject]@{ Item='Imagen de instalacion'; Present=$hasInstall }
            if (-not $hasInstall) { $result.Errors += 'No se encontro install.wim, install.esd ni un conjunto install*.swm valido dentro de la ISO.' }
        }

        foreach ($relative in @($ExpectedFiles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
            $cleanRelative = ([string]$relative).TrimStart([char[]]@('\','/'))
            if ([System.IO.Path]::IsPathRooted($cleanRelative) -or $cleanRelative -match '(^|\\)\.\.(\\|$)' -or $cleanRelative -match ':') {
                $result.Errors += "Ruta esperada no segura durante la verificacion: $relative"
                continue
            }
            $present = Test-Path -LiteralPath (Join-Path $root $cleanRelative) -PathType Leaf
            $result.Checks += [pscustomobject]@{ Item=$cleanRelative; Present=$present }
            if (-not $present) { $result.Errors += "Falta el archivo esperado $cleanRelative dentro de la ISO." }
        }
        $result.Valid = ($result.Errors.Count -eq 0)
    } catch {
        $result.Errors += $_.Exception.Message
        $result.Valid = $false
    } finally {
        if ($mountedByIsoCore) {
            $dismounted = $false
            $lastDismountError = $null
            for ($attempt = 1; $attempt -le 4 -and -not $dismounted; $attempt++) {
                try {
                    Dismount-DiskImage -ImagePath $IsoPath -ErrorAction Stop | Out-Null
                    $dismounted = $true
                } catch {
                    $lastDismountError = $_.Exception.Message
                    Start-Sleep -Milliseconds 300
                }
            }
            if (-not $dismounted) {
                $result.Warnings += "La estructura se verifico, pero no se pudo desmontar la ISO: $lastDismountError"
            }
        }
    }
    return [pscustomobject]$result
}



    $script:IsoCore_UpdateValidation = {
        param([string]$srcPath)
        $okC   = $uiGreen
        $errC  = [System.Drawing.Color]::Crimson
        $warnC = [System.Drawing.Color]::Orange
        $grayC = $uiMuted

        if ([string]::IsNullOrWhiteSpace($srcPath)) {
            $lblValBoot.Text = "• boot\etfsboot.com"; $lblValBoot.ForeColor = $grayC
            $lblValEfi.Text  = "• efisys.bin (UEFI)"; $lblValEfi.ForeColor  = $grayC
            $lblValWim.Text  = "• sources\install.*"; $lblValWim.ForeColor  = $grayC
            $lblValLang.Text = "• Idioma predeterminado: (Esperando...)"; $lblValLang.ForeColor = $grayC
            return
        }
        $biosPath = Join-Path $srcPath 'boot\etfsboot.com'
        $hasBoot  = (Test-Path -LiteralPath $biosPath -PathType Leaf) -and ((Get-Item -LiteralPath $biosPath -ErrorAction SilentlyContinue).Length -gt 0)
        $lblValBoot.Text      = if ($hasBoot) { "• boot\etfsboot.com (BIOS)" } else { "• boot\etfsboot.com (BIOS no disponible)" }
        $lblValBoot.ForeColor = if ($hasBoot) { $okC } else { $warnC }

        $efiStandardPath = Join-Path $srcPath 'efi\microsoft\boot\efisys.bin'
        $efiNoPromptPath = Join-Path $srcPath 'efi\microsoft\boot\efisys_noprompt.bin'
        $hasEfiStandard  = (Test-Path -LiteralPath $efiStandardPath -PathType Leaf) -and ((Get-Item -LiteralPath $efiStandardPath -ErrorAction SilentlyContinue).Length -gt 0)
        $hasEfiNoPrompt  = (Test-Path -LiteralPath $efiNoPromptPath -PathType Leaf) -and ((Get-Item -LiteralPath $efiNoPromptPath -ErrorAction SilentlyContinue).Length -gt 0)
        $hasEfi          = $hasEfiStandard -or $hasEfiNoPrompt
        $lblValEfi.Text  = if ($hasEfiStandard) {
            "• efisys.bin (UEFI)"
        } elseif ($hasEfiNoPrompt) {
            "• efisys_noprompt.bin (UEFI automático)"
        } else {
            "• Imagen de arranque UEFI no disponible"
        }
        $lblValEfi.ForeColor = if ($hasEfi) { $okC } else { $warnC }

        $hasBootWim = Test-Path -LiteralPath (Join-Path $srcPath 'sources\boot.wim') -PathType Leaf
        $hasWim = Test-Path -LiteralPath (Join-Path $srcPath 'sources\install.wim') -PathType Leaf
        $hasEsd = Test-Path -LiteralPath (Join-Path $srcPath 'sources\install.esd') -PathType Leaf
        $swmInfo = & $script:IsoCore_GetSwmSetInfo $srcPath $false
        $hasInstall = $hasWim -or $hasEsd -or ($swmInfo.Exists -and $swmInfo.Valid)
        $lblValWim.Text = if (-not $hasBootWim) {
            "• sources\boot.wim ausente"
        } elseif ($hasWim) {
            "• boot.wim + install.wim"
        } elseif ($hasEsd) {
            "• boot.wim + install.esd"
        } elseif ($swmInfo.Exists -and $swmInfo.Valid) {
            "• boot.wim + SWM: $($swmInfo.PartCount) partes validas"
        } elseif ($swmInfo.Exists) {
            "• SWM no valido: $($swmInfo.Errors -join '; ')"
        } else {
            "• boot.wim presente | imagen de instalacion ausente"
        }
        $lblValWim.ForeColor = if (-not $hasBootWim) { $errC } elseif ($hasInstall) { $okC } else { $warnC }
    }

    $script:IsoCore_UpdateDiskSpace = {
        param([string]$srcPath, [string]$dstPath)

        if ([string]::IsNullOrWhiteSpace($dstPath)) {
            $lblValSpace.Text      = "• Espacio libre en destino: (Esperando...)"
            $lblValSpace.ForeColor = $uiMuted
            return
        }

        try {
            $q = Split-Path -Qualifier $dstPath -ErrorAction SilentlyContinue
            if (-not $q) {
                $lblValSpace.Text      = "• Espacio libre en destino: No disponible para esta ruta"
                $lblValSpace.ForeColor = $uiMuted
                return
            }

            $drive = Get-PSDrive -Name $q.TrimEnd(':') -ErrorAction SilentlyContinue
            if (-not $drive) {
                $lblValSpace.Text      = "• Espacio libre en destino: No disponible"
                $lblValSpace.ForeColor = $uiMuted
                return
            }

            $sourceMatches = $false
            try {
                if (-not [string]::IsNullOrWhiteSpace($srcPath) -and
                    -not [string]::IsNullOrWhiteSpace([string]$script:IsoCore_analyzedSource)) {
                    $sourceMatches = [string]::Equals(
                        (& $script:IsoCore_NormalizeDirectoryPath $srcPath),
                        (& $script:IsoCore_NormalizeDirectoryPath ([string]$script:IsoCore_analyzedSource)),
                        [StringComparison]::OrdinalIgnoreCase
                    )
                }
            } catch {}

            $requiredBytes = 5GB
            if ($sourceMatches -and [long]$script:IsoCore_sourceBytes -gt 0) {
                $requiredBytes = [long][math]::Ceiling(([double]$script:IsoCore_sourceBytes * 1.08) + 256MB)
            }

            $freeGB     = [math]::Round($drive.Free / 1GB, 1)
            $requiredGB = [math]::Round($requiredBytes / 1GB, 1)
            $lblValSpace.Text = "• Espacio libre en destino: $freeGB GB | Estimado requerido: $requiredGB GB"
            $lblValSpace.ForeColor = if ($drive.Free -ge $requiredBytes) { $uiGreen } else { [System.Drawing.Color]::Orange }
        } catch {
            $lblValSpace.Text      = "• Espacio libre en destino: No se pudo calcular"
            $lblValSpace.ForeColor = [System.Drawing.Color]::Orange
        }
    }

    $script:IsoCore_AnalyzeSrc = {
        param([string]$srcPath)
        $txtSrc.Text = $srcPath
        $script:IsoCore_labelUserEdited = $false
        try { $script:IsoCore_analyzedSource = [System.IO.Path]::GetFullPath($srcPath) } catch { $script:IsoCore_analyzedSource = $srcPath }
        $script:IsoCore_detectedArchitecture = $null
        $script:IsoCore_sourceBytes          = 0L
        $script:IsoCore_reparsePointCount    = 0
        $script:IsoCore_sourceSnapshot       = $null
        $script:IsoCore_analysisSizeResult   = $null
        $script:IsoCore_analysisDismResult   = $null
        $script:IsoCore_analysisCancelled    = $false
        $quickInfo = & $script:IsoCore_GetQuickSourceFingerprint $script:IsoCore_analyzedSource
        $script:IsoCore_analysisQuickFingerprint = $quickInfo.Value
        $cacheKey = (& $script:IsoCore_NormalizeDirectoryPath ([string]$script:IsoCore_analyzedSource)).ToUpperInvariant()
        $cached = if ($script:IsoCore_analysisCache.ContainsKey($cacheKey)) { $script:IsoCore_analysisCache[$cacheKey] } else { $null }
        $cacheIsFresh = $cached -and $cached.SavedAt -and (((Get-Date) - [datetime]$cached.SavedAt).TotalMinutes -le 30)
        if ($cached -and -not $cacheIsFresh) { [void]$script:IsoCore_analysisCache.Remove($cacheKey); $cached = $null }
        if ($cached -and $cached.QuickFingerprint -eq $quickInfo.Value) {
            $script:IsoCore_analysisSizeResult = $cached.SizeResult
            $script:IsoCore_analysisDismResult = $cached.DismResult
            $script:IsoCore_sourceSnapshot = $cached.Snapshot
            $script:IsoCore_sourceBytes = [long]$cached.SizeResult.Bytes
            $script:IsoCore_reparsePointCount = [int]$cached.SizeResult.ReparsePointCount
            $script:IsoCore_detectedArchitecture = [string]$cached.DismResult.Architecture
            $bytes=[long]$cached.SizeResult.Bytes
            $strSz=if($bytes-ge 1GB){"$([math]::Round($bytes/1GB,2)) GB"}elseif($bytes-ge 1MB){"$([math]::Round($bytes/1MB,1)) MB"}else{"$bytes bytes"}
            $lblValSrcSize.Text="• Tamaño carpeta origen: $strSz ($($cached.SizeResult.Count) archivos | $($cached.SizeResult.DirCount) directorios) [cache]"
            $lblValSrcSize.ForeColor=$uiGreen
            $lblValLang.Text="• Idioma predeterminado: $($cached.DismResult.DefaultLanguage) | Arquitectura: $($cached.DismResult.Architecture) [cache]"
            $lblValLang.ForeColor=$uiGreen
            if(-not $script:IsoCore_labelUserEdited -and $cached.DismResult.Label){$txtLabel.Text=$cached.DismResult.Label;$script:IsoCore_labelUserEdited=$false}
            & $script:IsoCore_UpdateValidation $srcPath
            & $script:IsoCore_UpdateDiskSpace $srcPath $txtDst.Text
            & $script:IsoCore_SetPhase "Analisis restaurado desde cache ($($cached.SavedAt))." ($uiGreen)
            Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: Analisis restaurado desde cache para $srcPath."
            & $script:IsoCore_RefreshDetails
            $btnMake.Enabled=$true
            return
        }
        $btnMake.Enabled = $false
        $btnCancelAnalysis.Visible = $true
        Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: Carpeta origen seleccionada: $srcPath"

        if ($null -ne $script:IsoCore_sizeTimer) {
            try { $script:IsoCore_sizeTimer.Stop(); $script:IsoCore_sizeTimer.Dispose() } catch {}
            $script:IsoCore_sizeTimer = $null
        }
        if ($null -ne $script:IsoCore_sizePS) {
            try { $script:IsoCore_sizePS.Stop(); $script:IsoCore_sizePS.Dispose() } catch {}
            $script:IsoCore_sizePS = $null
        }
        if ($null -ne $script:IsoCore_sizeRS) {
            try { $script:IsoCore_sizeRS.Close(); $script:IsoCore_sizeRS.Dispose() } catch {}
            $script:IsoCore_sizeRS = $null
        }
        $script:IsoCore_sizeHandle = $null
        $script:IsoCore_sizeQueue  = $null

        if ($null -ne $script:IsoCore_dismTimer) {
            try { $script:IsoCore_dismTimer.Stop(); $script:IsoCore_dismTimer.Dispose() } catch {}
            $script:IsoCore_dismTimer = $null
        }
        if ($null -ne $script:IsoCore_dismPS) {
            try { $script:IsoCore_dismPS.Stop(); $script:IsoCore_dismPS.Dispose() } catch {}
            $script:IsoCore_dismPS = $null
        }
        if ($null -ne $script:IsoCore_dismRS) {
            try { $script:IsoCore_dismRS.Close(); $script:IsoCore_dismRS.Dispose() } catch {}
            $script:IsoCore_dismRS = $null
        }
        $script:IsoCore_dismHandle = $null
        $script:IsoCore_dismQueue  = $null

        $btnSrc.Enabled = $true

        if ($pbMain.Style -eq [System.Windows.Forms.ProgressBarStyle]::Marquee) {
            $pbMain.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
            $pbMain.Value = 0
        }

        & $script:IsoCore_UpdateValidation $srcPath
        & $script:IsoCore_UpdateDiskSpace  $srcPath $txtDst.Text

        $lblValSrcSize.Text      = "• Calculando Tamaño de la carpeta origen..."
        $lblValSrcSize.ForeColor = $uiMuted
        $lblValLang.Text         = "• Idioma predeterminado: Detectando..."
        $lblValLang.ForeColor    = $uiMuted

        # --- Calculo de Tamaño de la carpeta (async) ---
        $script:IsoCore_sizeQueue = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
        $script:IsoCore_sizeRS    = [runspacefactory]::CreateRunspace()
        $script:IsoCore_sizeRS.Open()
        $script:IsoCore_sizeRS.SessionStateProxy.SetVariable('srcPath',   $srcPath)
        $script:IsoCore_sizeRS.SessionStateProxy.SetVariable('sizeQueue', $script:IsoCore_sizeQueue)

        $script:IsoCore_sizePS = [powershell]::Create()
        $script:IsoCore_sizePS.Runspace = $script:IsoCore_sizeRS
        [void]$script:IsoCore_sizePS.AddScript({
            $result = @{ Bytes = 0L; Count = 0; DirCount = 0; ReparsePointCount = 0; LastWriteTicks = 0L; IsFinal = $false; Error = $null }
            try { 
                $lastReport = [DateTime]::UtcNow
                Get-ChildItem -LiteralPath $srcPath -Recurse -Force -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        if (($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { $result.ReparsePointCount++ }
                        if ($_.PSIsContainer) { $result.DirCount++ } else { $result.Count++; $result.Bytes += [long]$_.Length }
                        if ($_.LastWriteTimeUtc.Ticks -gt $result.LastWriteTicks) { $result.LastWriteTicks = $_.LastWriteTimeUtc.Ticks }
                        if (([DateTime]::UtcNow - $lastReport).TotalMilliseconds -ge 400) {
                            $sizeQueue.Enqueue(@{ Bytes=$result.Bytes; Count=$result.Count; DirCount=$result.DirCount; ReparsePointCount=$result.ReparsePointCount; LastWriteTicks=$result.LastWriteTicks; IsFinal=$false; Error=$null })
                            $lastReport=[DateTime]::UtcNow
                        }
                    }
            } catch { $result.Error = $_.Exception.Message }
            $result.IsFinal = $true
            $sizeQueue.Enqueue($result)
        })
        $script:IsoCore_sizeHandle = $script:IsoCore_sizePS.BeginInvoke()

        $script:IsoCore_sizeTimer          = New-Object System.Windows.Forms.Timer
        $script:IsoCore_sizeTimer.Interval = 150
        $script:IsoCore_sizeTimer.Add_Tick({
            if ($null -eq $script:IsoCore_sizeQueue) { return }
            $res = $null
            if (-not $script:IsoCore_sizeQueue.TryDequeue([ref]$res)) { return }
            if (-not [bool]$res.IsFinal) {
                $progressSize = if ([long]$res.Bytes -ge 1GB) { "$([math]::Round([long]$res.Bytes/1GB,2)) GB" } elseif ([long]$res.Bytes -ge 1MB) { "$([math]::Round([long]$res.Bytes/1MB,1)) MB" } else { "$($res.Bytes) bytes" }
                $lblValSrcSize.Text = "• Analizando: $($res.Count) archivos | $progressSize examinados"
                $lblFileInfo.Text = "Analisis: $($res.Count) archivos | $($res.DirCount) directorios"
                & $script:IsoCore_SetPhase "Analizando contenido de la fuente... $($res.Count) archivos" ($uiCyan)
                return
            }

            $script:IsoCore_sizeTimer.Stop()
            $script:IsoCore_sizeTimer.Dispose()
            $script:IsoCore_sizeTimer = $null
            try { $script:IsoCore_sizePS.EndInvoke($script:IsoCore_sizeHandle) } catch {}
            try { $script:IsoCore_sizePS.Dispose()                     } catch {}
            try { $script:IsoCore_sizeRS.Close(); $script:IsoCore_sizeRS.Dispose() } catch {}
            $script:IsoCore_sizePS = $null; $script:IsoCore_sizeRS = $null
            $script:IsoCore_sizeHandle = $null; $script:IsoCore_sizeQueue = $null

            if ($null -ne $res.Error) {
                $lblValSrcSize.Text      = "• No se pudo calcular el Tamaño de la carpeta origen"
                $lblValSrcSize.ForeColor = [System.Drawing.Color]::Orange
                Write-IsoCoreLog -LogLevel WARN -Message "IsoCore: No se pudo calcular el Tamaño de la carpeta origen: $($res.Error)"
            } else {
                $bytes = [long]$res.Bytes
                $script:IsoCore_sourceBytes       = $bytes
                $script:IsoCore_reparsePointCount = [int]$res.ReparsePointCount
                $script:IsoCore_analysisSizeResult = $res
                $quickNow = & $script:IsoCore_GetQuickSourceFingerprint $script:IsoCore_analyzedSource
                $snapshotMaterial = "$($script:IsoCore_analyzedSource)|$bytes|$($res.Count)|$($res.DirCount)|$($res.ReparsePointCount)|$($res.LastWriteTicks)|$($quickNow.Value)"
                $script:IsoCore_sourceSnapshot = [pscustomobject]@{ Path=$script:IsoCore_analyzedSource; Bytes=$bytes; FileCount=[int]$res.Count; DirCount=[int]$res.DirCount; ReparsePointCount=[int]$res.ReparsePointCount; LatestWriteTicks=[long]$res.LastWriteTicks; QuickFingerprint=$quickNow.Value; FullFingerprint=(& $script:IsoCore_GetStringSha256 $snapshotMaterial) }
                $strSz = if ($bytes -ge 1GB)  { "$([math]::Round($bytes/1GB, 2)) GB"  }
                         elseif ($bytes -ge 1MB) { "$([math]::Round($bytes/1MB, 1)) MB"  }
                         else   { "$bytes bytes" }
                $color = if ($bytes -ge 8GB) { [System.Drawing.Color]::Orange }  # > 8 GB: probablemente incluye drivers/updates adicionales fuera de lo habitual
                         else                { $uiGreen }
                $lblValSrcSize.Text      = "• Tamaño carpeta origen: $strSz ($($res.Count) archivos | $($res.DirCount) directorios)"
                $lblValSrcSize.ForeColor = $color
                Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: Tamaño carpeta origen: $strSz ($($res.Count) archivos | $($res.DirCount) directorios) | Reparse points: $($res.ReparsePointCount)."
                & $script:IsoCore_SaveAnalysisCache
            }
            & $script:IsoCore_UpdateAnalysisState
        })
        $script:IsoCore_sizeTimer.Start()

        # --- Extraccion de metadatos DISM (async) ---
        $installWim  = Join-Path $srcPath "sources\install.wim"
        $installEsd  = Join-Path $srcPath "sources\install.esd"
        $bootWimMeta = Join-Path $srcPath "sources\boot.wim"
        $swmInfoAnalysis = & $script:IsoCore_GetSwmSetInfo $srcPath $false
        $targetImage = $null
        $metadataFromBootWim = $false
        if     (Test-Path -LiteralPath $installWim -PathType Leaf) { $targetImage = $installWim }
        elseif (Test-Path -LiteralPath $installEsd -PathType Leaf) { $targetImage = $installEsd }
        elseif ($swmInfoAnalysis.Exists -and $swmInfoAnalysis.Valid -and (Test-Path -LiteralPath $bootWimMeta -PathType Leaf)) {

            $targetImage = $bootWimMeta
            $metadataFromBootWim = $true
        }

        if ($targetImage) {
            Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: Imagen base detectada: $targetImage. Extrayendo metadatos DISM (async)..."
            & $script:IsoCore_SetPhase "Analizando metadatos de la imagen (DISM)..." ($uiCyan)
            $btnSrc.Enabled = $false

            $pbMain.Style                 = [System.Windows.Forms.ProgressBarStyle]::Marquee
            $pbMain.MarqueeAnimationSpeed = 20

            $script:IsoCore_dismQueue = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
            $script:IsoCore_dismRS    = [runspacefactory]::CreateRunspace()
            $script:IsoCore_dismRS.Open()
            $langIniPath = Join-Path $srcPath "sources\lang.ini"
            $script:IsoCore_dismRS.SessionStateProxy.SetVariable('targetImage', $targetImage)
            $script:IsoCore_dismRS.SessionStateProxy.SetVariable('langIniPath', $langIniPath)
            $script:IsoCore_dismRS.SessionStateProxy.SetVariable('dismQueue',   $script:IsoCore_dismQueue)
            $script:IsoCore_dismRS.SessionStateProxy.SetVariable('dismLogDirectory', $script:IsoCore_logDir)

            $script:IsoCore_dismPS = [powershell]::Create()
            $script:IsoCore_dismPS.Runspace = $script:IsoCore_dismRS
            [void]$script:IsoCore_dismPS.AddScript({
                $result = @{
                    Label              = $null
                    Architecture       = $null
                    DefaultLanguage    = $null
                    LanguageSource     = $null
                    InstalledLanguages = @()
                    ImageCount         = 0
                    ImageNames         = @()
                    Error              = $null
                }
                try {
                    Import-Module Dism -ErrorAction Stop
                    if ([string]::IsNullOrWhiteSpace($dismLogDirectory)) { throw 'No se ha configurado la carpeta Logs para DISM.' }
                    [void][IO.Directory]::CreateDirectory($dismLogDirectory)
                    $dismLogPath = Join-Path $dismLogDirectory ('DISM_ISO_Metadatos_' + [datetime]::UtcNow.ToString('yyyyMMdd_HHmmss_fff') + '_' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.log')

                    $prefix    = "CCCOMA"
                    $allImages = Get-WindowsImage -ImagePath $targetImage -LogPath $dismLogPath -ErrorAction Stop
                    $allNames  = $allImages.ImageName -join " "
                    $result.ImageCount = @($allImages).Count
                    $result.ImageNames = @($allImages | ForEach-Object { $_.ImageName })

                    if     ($allNames -match "Server")                            { $prefix = "SSS"   }
                    elseif ($allNames -match "Enterprise.*LTSC|LTSC.*Enterprise") { $prefix = "CCCEA" }
                    elseif ($allNames -match "Enterprise")                        { $prefix = "CCCEA" }

                    $detailedImage = Get-WindowsImage -ImagePath $targetImage -Index 1 -LogPath $dismLogPath -ErrorAction Stop

                    $archRaw = [string]$detailedImage.Architecture
                    $archStr = switch -Regex ($archRaw.Trim().ToUpperInvariant()) {
                        '^(0|X86|INTEL)$'       { "X86"; break }
                        '^(9|X64|AMD64)$'       { "X64"; break }
                        '^(12|ARM64|AARCH64)$'  { "ARM64"; break }
                        default                 { "DESCONOCIDA" }
                    }

                    if ($null -ne $detailedImage.Languages) {
                        $result.InstalledLanguages = @(
                            $detailedImage.Languages |
                                ForEach-Object { $_.ToString().ToUpperInvariant() } |
                                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                                Select-Object -Unique
                        )
                    }

                    $langStr    = $null
                    $langSource = $null

                    if (-not [string]::IsNullOrWhiteSpace($langIniPath) -and
                        (Test-Path -LiteralPath $langIniPath)) {

                        $currentSection    = ''
                        $explicitDefault   = $null
                        $availableLanguages = New-Object System.Collections.Generic.List[object]
                        $order = 0

                        foreach ($rawLine in (Get-Content -LiteralPath $langIniPath -ErrorAction Stop)) {
                            $line = ($rawLine -split '[;#]', 2)[0].Trim()
                            if ([string]::IsNullOrWhiteSpace($line)) { continue }

                            if ($line -match '^\[(?<section>[^\]]+)\]$') {
                                $currentSection = $matches['section'].Trim()
                                continue
                            }

                            if ($currentSection -ieq 'Default UI Language' -and
                                $line -match '^(?:[^=]+?\s*=\s*)?(?<lang>[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})+)\s*$') {
                                $explicitDefault = $matches['lang']
                                break
                            }

                            if ($currentSection -ieq 'Available UI Languages' -and
                                $line -match '^\s*(?<lang>[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})+)\s*=\s*(?<rank>\d+)\s*$') {
                                $availableLanguages.Add([pscustomobject]@{
                                    Language = $matches['lang']
                                    Rank     = [int]$matches['rank']
                                    Order    = $order
                                })
                                $order++
                            }
                        }

                        if (-not [string]::IsNullOrWhiteSpace($explicitDefault)) {
                            $langStr    = $explicitDefault
                            $langSource = 'sources\lang.ini [Default UI Language]'
                        } elseif ($availableLanguages.Count -gt 0) {
                            $preferred = $availableLanguages |
                                Sort-Object -Property @{ Expression = 'Rank'; Descending = $true },
                                                      @{ Expression = 'Order'; Descending = $false } |
                                Select-Object -First 1
                            if ($null -ne $preferred) {
                                $langStr    = [string]$preferred.Language
                                $langSource = 'sources\lang.ini [Available UI Languages]'
                            }
                        }
                    }

                    if ([string]::IsNullOrWhiteSpace($langStr)) {
                        $defaultLanguageProperty = $detailedImage.PSObject.Properties['DefaultLanguage']
                        if ($null -ne $defaultLanguageProperty -and
                            -not [string]::IsNullOrWhiteSpace([string]$defaultLanguageProperty.Value)) {
                            $langStr    = [string]$defaultLanguageProperty.Value
                            $langSource = 'Get-WindowsImage.DefaultLanguage'
                        }
                    }

                    if ([string]::IsNullOrWhiteSpace($langStr)) {
                        $languageProperty = $detailedImage.PSObject.Properties['Language']
                        if ($null -ne $languageProperty -and
                            -not [string]::IsNullOrWhiteSpace([string]$languageProperty.Value)) {
                            $langStr    = [string]$languageProperty.Value
                            $langSource = 'Get-WindowsImage.Language'
                        }
                    }

                    if ([string]::IsNullOrWhiteSpace($langStr) -and $result.InstalledLanguages.Count -gt 0) {
                        $langStr    = [string]$result.InstalledLanguages[0]
                        $langSource = 'Get-WindowsImage.Languages[0] (respaldo)'
                    }

                    if ([string]::IsNullOrWhiteSpace($langStr)) {
                        $langStr    = 'MULTI'
                        $langSource = 'sin metadatos concluyentes'
                    }

                    $langStr = $langStr.Trim().ToUpperInvariant()
                    $result.Architecture      = $archStr
                    $result.DefaultLanguage   = $langStr
                    $result.LanguageSource    = $langSource
                    $archLabel = if ($archStr -eq 'DESCONOCIDA') { 'UNK' } else { $archStr }
                    $result.Label             = "${prefix}_${archLabel}FRE_${langStr}_DV9"
                } catch {
                    $result.Error = $_.Exception.Message
                }
                $dismQueue.Enqueue($result)
            })
            $script:IsoCore_dismHandle = $script:IsoCore_dismPS.BeginInvoke()

            $script:IsoCore_dismTimer          = New-Object System.Windows.Forms.Timer
            $script:IsoCore_dismTimer.Interval = 100
            $script:IsoCore_dismTimer.Add_Tick({
                if ($null -eq $script:IsoCore_dismQueue) { return }
                $res = $null
                if (-not $script:IsoCore_dismQueue.TryDequeue([ref]$res)) { return }

                $script:IsoCore_dismTimer.Stop()
                $script:IsoCore_dismTimer.Dispose()
                $script:IsoCore_dismTimer = $null
                try { $script:IsoCore_dismPS.EndInvoke($script:IsoCore_dismHandle) } catch {}
                try { $script:IsoCore_dismPS.Dispose()                     } catch {}
                try { $script:IsoCore_dismRS.Close(); $script:IsoCore_dismRS.Dispose() } catch {}
                $script:IsoCore_dismPS = $null; $script:IsoCore_dismRS = $null
                $script:IsoCore_dismHandle = $null; $script:IsoCore_dismQueue = $null
                $btnSrc.Enabled  = $true

                $pbMain.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
                $pbMain.Value = 0

                if ($null -ne $res.Error) {
                    if (-not $script:IsoCore_labelUserEdited) {
                        $txtLabel.Text = "WINDOWS_CUSTOM"
                        $script:IsoCore_labelUserEdited = $false
                    }
                    $lblValLang.Text      = "• Idioma predeterminado: No detectado"
                    $lblValLang.ForeColor = [System.Drawing.Color]::Orange
                    Write-IsoCoreLog -LogLevel WARN -Message "IsoCore: Fallo al extraer metadatos DISM: $($res.Error). Etiqueta por defecto aplicada."
                    & $script:IsoCore_SetPhase "Error leyendo metadatos. Etiqueta por defecto aplicada." ([System.Drawing.Color]::Orange)
                } else {
                    $resolvedArchitecture = & $script:IsoCore_ResolveArchitecture ([string]$res.Architecture) ([string]$script:IsoCore_analyzedSource)
                    $res.Architecture = $resolvedArchitecture
                    if ($resolvedArchitecture -ne 'DESCONOCIDA' -and $res.Label -match '_UNKFRE_') {
                        $res.Label = $res.Label -replace '_UNKFRE_', "_${resolvedArchitecture}FRE_"
                    }
                    $script:IsoCore_detectedArchitecture = [string]$resolvedArchitecture
                    $script:IsoCore_analysisDismResult = $res
                    $lblValLang.Text = "• Idioma predeterminado: $($res.DefaultLanguage) | Arquitectura: $resolvedArchitecture"
                    $lblValLang.ForeColor = if ($res.DefaultLanguage -eq 'MULTI') {
                        [System.Drawing.Color]::Orange
                    } else {
                        $uiGreen
                    }
                    Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: Arquitectura: $resolvedArchitecture | Idioma predeterminado: $($res.DefaultLanguage) | Fuente: $($res.LanguageSource) | Instalados: $($res.InstalledLanguages -join ', ')."

                    if (-not $script:IsoCore_labelUserEdited) {
                        $txtLabel.Text          = $res.Label
                        $script:IsoCore_labelUserEdited = $false   # reset: fue escritura automatica, no del usuario
                        Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: Etiqueta generada dinamicamente: $($txtLabel.Text)"
                        & $script:IsoCore_SetPhase "Idioma: $($res.DefaultLanguage) | Etiqueta: $($txtLabel.Text)" ($uiGreen)
                    } else {
                        Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: Etiqueta DISM ignorada (usuario edito manualmente): '$($txtLabel.Text)'."
                        & $script:IsoCore_SetPhase "Idioma: $($res.DefaultLanguage) | Etiqueta personalizada conservada" ([System.Drawing.Color]::FromArgb(255, 200, 40))
                    }
                }
                if ($null -eq $script:IsoCore_analysisDismResult) { $script:IsoCore_analysisDismResult = $res }
                & $script:IsoCore_SaveAnalysisCache
                & $script:IsoCore_UpdateAnalysisState
            })
            $script:IsoCore_dismTimer.Start()

        } else {
            $txtLabel.Text          = "WINDOWS_CUSTOM"
            $script:IsoCore_labelUserEdited = $false
            $lblValLang.Text        = "• Idioma predeterminado: No disponible"
            $lblValLang.ForeColor   = [System.Drawing.Color]::Orange
            Write-IsoCoreLog -LogLevel WARN -Message "IsoCore: No se detecto una imagen de metadatos compatible (install.wim/esd o boot.wim para SWM). Aplicando etiqueta base."
            $script:IsoCore_analysisDismResult = [pscustomobject]@{ Architecture='DESCONOCIDA'; DefaultLanguage='MULTI'; LanguageSource='sin imagen'; InstalledLanguages=@(); ImageCount=0; ImageNames=@(); Label='WINDOWS_CUSTOM'; Error=$null }
            & $script:IsoCore_SaveAnalysisCache
            & $script:IsoCore_UpdateAnalysisState
            & $script:IsoCore_SetPhase "Imagen de metadatos no encontrada. Etiqueta base aplicada." ([System.Drawing.Color]::Orange)
        }
    }

    # ------------------------------------------------------------------
    # Inyeccion de autounattend.xml y MRP
    # ------------------------------------------------------------------
    $script:IsoCore_InitializeInjectionState = {
        & $script:IsoCore_CleanupInjectedFiles
        $script:IsoCore_injectedFiles      = [System.Collections.Generic.List[string]]::new()
        $script:IsoCore_injectionBackups   = [System.Collections.Generic.List[object]]::new()
        $script:IsoCore_injectionBackupRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("IsoCore_Backup_" + [guid]::NewGuid().ToString('N'))
        New-Item -Path $script:IsoCore_injectionBackupRoot -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }

    $script:IsoCore_PrepareInjectionTarget = {
        param([Parameter(Mandatory=$true)][string]$TargetPath)

        if (Test-Path -LiteralPath $TargetPath -PathType Container) {
            throw "No se puede reemplazar una carpeta con un archivo: $TargetPath"
        }

        if (Test-Path -LiteralPath $TargetPath -PathType Leaf) {
            $alreadyBackedUp = $false
            foreach ($entry in $script:IsoCore_injectionBackups) {
                if ([string]::Equals($entry.Original, $TargetPath, [StringComparison]::OrdinalIgnoreCase)) {
                    $alreadyBackedUp = $true
                    break
                }
            }
            if (-not $alreadyBackedUp) {
                $backupPath = Join-Path $script:IsoCore_injectionBackupRoot ([guid]::NewGuid().ToString('N'))
                Copy-Item -LiteralPath $TargetPath -Destination $backupPath -Force -ErrorAction Stop
                $script:IsoCore_injectionBackups.Add([pscustomobject]@{
                    Original = $TargetPath
                    Backup   = $backupPath
                })
            }
        } else {
            if (-not $script:IsoCore_injectedFiles.Contains($TargetPath)) {
                $script:IsoCore_injectedFiles.Add($TargetPath)
            }
        }
    }

    $script:IsoCore_RegisterCreatedDirectory = {
        param([Parameter(Mandatory=$true)][string]$Path)

        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null
            if (-not $script:IsoCore_injectedFiles.Contains($Path)) {
                $script:IsoCore_injectedFiles.Add($Path)
            }
        }
    }

    $script:IsoCore_CleanupInjectedFiles = {

        & $script:IsoCore_RemoveBootOrderFile

        if ($null -ne $script:IsoCore_injectedFiles) {
            $paths = $script:IsoCore_injectedFiles |
                Select-Object -Unique |
                Sort-Object { $_.Split([IO.Path]::DirectorySeparatorChar).Count } -Descending

            foreach ($path in $paths) {
                try {
                    if (Test-Path -LiteralPath $path -PathType Leaf) {
                        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                    } elseif (Test-Path -LiteralPath $path -PathType Container) {
                        if (-not (Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue)) {
                            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                        }
                    }
                } catch {
                    Write-IsoCoreLog -LogLevel WARN -Message "IsoCore: No se pudo eliminar el elemento temporal '$path': $($_.Exception.Message)"
                }
            }
        }

        if ($null -ne $script:IsoCore_injectionBackups) {
            foreach ($entry in $script:IsoCore_injectionBackups) {
                try {
                    $parent = Split-Path -Parent $entry.Original
                    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                        New-Item -Path $parent -ItemType Directory -Force | Out-Null
                    }
                    Copy-Item -LiteralPath $entry.Backup -Destination $entry.Original -Force -ErrorAction Stop
                } catch {
                    Write-IsoCoreLog -LogLevel ERROR -Message "IsoCore: No se pudo restaurar '$($entry.Original)': $($_.Exception.Message)"
                }
            }
        }

        foreach ($tempRoot in @($script:IsoCore_mrpExtractRoot, $script:IsoCore_injectionBackupRoot)) {
            if ($tempRoot -and (Test-Path -LiteralPath $tempRoot)) {
                try { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction Stop } catch {}
            }
        }

        $script:IsoCore_injectedFiles       = $null
        $script:IsoCore_injectionBackups    = $null
        $script:IsoCore_injectionBackupRoot = $null
        $script:IsoCore_mrpExtractRoot      = $null
    }

    # ------------------------------------------------------------------
    # 5. Eventos de controles
    # ------------------------------------------------------------------

$btnDetails.Add_Click({
    $showDetails = -not $txtDetails.Visible
    $txtDetails.Visible = $showDetails
    if ($showDetails) {
        $progLayout.RowStyles[8].SizeType = [System.Windows.Forms.SizeType]::Percent
        $progLayout.RowStyles[8].Height = 100
        $btnDetails.Text = 'Ocultar detalles del analisis'
    } else {
        $progLayout.RowStyles[8].SizeType = [System.Windows.Forms.SizeType]::Absolute
        $progLayout.RowStyles[8].Height = 0
        $btnDetails.Text = 'Ver detalles del analisis'
    }
    & $script:IsoCore_RefreshDetails
})
$btnCancelAnalysis.Add_Click({ & $script:IsoCore_CancelAnalysis })

    $txtSrc.Add_TextChanged({ & $script:IsoCore_UpdateValidation $txtSrc.Text; & $script:IsoCore_UpdateDiskSpace $txtSrc.Text $txtDst.Text })

    $txtSrc.Add_Leave({
        $typedSource = ([string]$txtSrc.Text).Trim()
        if ([string]::IsNullOrWhiteSpace($typedSource)) { return }

        # Aceptar rutas copiadas con comillas externas.
        if ($typedSource.Length -ge 2 -and
            $typedSource.StartsWith('"') -and $typedSource.EndsWith('"')) {
            $typedSource = $typedSource.Substring(1, $typedSource.Length - 2).Trim()
        }
        if ([string]::IsNullOrWhiteSpace($typedSource)) { return }

        try {
            $sourceItem = Get-Item -LiteralPath $typedSource -Force -ErrorAction Stop
            if (-not $sourceItem.PSIsContainer) { return }
            $fullPath = [System.IO.Path]::GetFullPath([string]$sourceItem.FullName)
        } catch {
            return
        }

        # Canonicalizar el contenido para que el preflight reciba una ruta limpia.
        if (-not [string]::Equals($txtSrc.Text, $fullPath, [StringComparison]::OrdinalIgnoreCase)) {
            $txtSrc.Text = $fullPath
        }

        $normalizedTyped = $fullPath.TrimEnd([char[]]@('\','/'))
        $normalizedAnalyzed = ''
        if (-not [string]::IsNullOrWhiteSpace([string]$script:IsoCore_analyzedSource)) {
            try {
                $normalizedAnalyzed = ([System.IO.Path]::GetFullPath([string]$script:IsoCore_analyzedSource)).TrimEnd([char[]]@('\','/'))
            } catch {
                $normalizedAnalyzed = ([string]$script:IsoCore_analyzedSource).TrimEnd([char[]]@('\','/'))
            }
        }

        if ([string]::Equals($normalizedTyped, $normalizedAnalyzed, [StringComparison]::OrdinalIgnoreCase)) {
            return
        }

        & $script:IsoCore_AnalyzeSrc $fullPath
    })

    $chkMRP.Add_CheckedChanged({
        if ($chkMRP.Checked) {
            $msgAuto = "Has habilitado la inyeccion del paquete MRP.`n`n" +
                       "AVISO DE SEGURIDAD:`n" +
                       "Utiliza unicamente un paquete MRP obtenido de una fuente confiable y revisado previamente.`n`n" +
                       "Algunos paquetes pueden contener herramientas que el antivirus detecte o bloquee. IsoCore no desactivara la proteccion del sistema ni omitira las alertas de seguridad."

            [System.Windows.Forms.MessageBox]::Show(
                $msgAuto,
                "Aviso de Antivirus - MRP",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: El usuario habilito MRP; se mostro la advertencia de seguridad."
        }
    })

    $txtDst.Add_TextChanged({ & $script:IsoCore_UpdateDiskSpace $txtSrc.Text $txtDst.Text })

    $script:IsoCore_labelUserEdited = $false

    $txtLabel.Add_TextChanged({
        $pos = $txtLabel.SelectionStart
        $up  = $txtLabel.Text.ToUpper()
        if ($txtLabel.Text -cne $up) {
            $txtLabel.Text           = $up
            $txtLabel.SelectionStart = [Math]::Min($pos, $up.Length)
        }
        $script:IsoCore_labelUserEdited = $true
        $raw     = $txtLabel.Text
        $invalid = $raw -match '[^A-Z0-9_\-]'
        $tooLong = $raw.Length -gt 32
        if ($invalid -or $tooLong) {
            $txtLabel.BackColor = [System.Drawing.Color]::FromArgb(60, 20, 20)
            $txtLabel.ForeColor = [System.Drawing.Color]::Tomato
        } else {
            $txtLabel.BackColor = [System.Drawing.Color]::FromArgb(30, 35, 40)
            $txtLabel.ForeColor = [System.Drawing.Color]::White
        }
    })

    $btnSrc.Add_Click({
        $fbd             = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = "Selecciona carpeta raiz de Windows (donde estan setup.exe, boot, efi...)"
        if ($fbd.ShowDialog() -eq 'OK') { & $script:IsoCore_AnalyzeSrc $fbd.SelectedPath }
    })

    $btnDst.Add_Click({
        $sfd        = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.Filter = "Imagen ISO (*.iso)|*.iso"
        if ($sfd.ShowDialog() -eq 'OK') {
            $txtDst.Text = $sfd.FileName
            Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: Archivo de destino configurado: $($txtDst.Text)"
            & $script:IsoCore_UpdateDiskSpace $txtSrc.Text $txtDst.Text
        }
    })

    $btnUnattend.Add_Click({
        $ofd        = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "XML Files (*.xml)|*.xml"
        if ($ofd.ShowDialog() -eq 'OK') {
            $txtUnattend.Text = $ofd.FileName
            Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: Archivo Unattend.xml configurado: $($txtUnattend.Text)"
        }
    })

    $lnkWeb.Add_Click({
        $lnkWeb.LinkVisited = $true
        Start-Process "https://schneegans.de/windows/unattend-generator/"
    })

    $btnAbout.Add_Click({
        $msg = "IsoCore v$($script:IsoCore_Version)`n" +
               "Desarrollado por SOFTMAXTER`n`n" +
               "Email: softmaxter@hotmail.com`n" +
               "Blog: softmaxter.blogspot.com`n`n" +
               "Motor para crear imagenes ISO booteables BIOS/UEFI/ARM64 con perfiles dinamicos de oscdimg, BootOrder, autounattend.xml e inyeccion MRP."
        [System.Windows.Forms.MessageBox]::Show($msg, "Acerca de IsoCore", 'OK', 'Information') | Out-Null
    })

    $tip                  = New-Object System.Windows.Forms.ToolTip
    $tip.AutoPopDelay     = 8000
    $tip.InitialDelay     = 400
    $tip.ReshowDelay      = 200
    $tip.ShowAlways       = $true
    $tip.SetToolTip($txtSrc,      "Carpeta raiz de la fuente de instalacion de Windows (debe contener boot\, efi\, sources\).")
    $tip.SetToolTip($btnSrc,      "Abrir explorador para seleccionar la carpeta origen.")
    $tip.SetToolTip($txtDst,      "Ruta completa del archivo ISO que se generara (p. ej. C:\Output\Windows11.iso).")
    $tip.SetToolTip($btnDst,      "Elegir ruta y nombre del archivo ISO de salida.")
    $tip.SetToolTip($txtLabel,    "Maximo 32 caracteres. Solo A-Z, 0-9, guion y guion_bajo. Se genera con arquitectura e idioma predeterminado detectados.")
    $tip.SetToolTip($lblValLang,  "Prioridad: DefaultLanguage/Language de DISM, lang.ini y, como respaldo, el primer idioma instalado.")
    $tip.SetToolTip($txtUnattend, "Archivo XML de respuesta desatendida. Se copiara como autounattend.xml en la raiz de la ISO.")
    $tip.SetToolTip($btnUnattend, "Seleccionar archivo autounattend.xml.")
    $tip.SetToolTip($lnkWeb,      "Abre schneegans.de — generador online de archivos autounattend.xml para automatizacion OOBE.")
    $tip.SetToolTip($chkMRP,      "Busca un ZIP '*MRP*.zip' en Tools, valida su contenido e inyecta sus archivos en \sources.")
    $tip.SetToolTip($btnExportLog,"Guarda el log completo de la ultima compilacion como archivo .txt.")
    $tip.SetToolTip($btnMake,     "Inicia la compilacion de la imagen ISO booteable con los parametros configurados.")
    $tip.SetToolTip($btnCancel,   "Interrumpe la compilacion en curso, elimina la salida parcial y restaura la ISO anterior si existia.")
    $tip.SetToolTip($btnAbout,    "Informacion sobre IsoCore, version y datos del autor.")

    $btnCancel.Add_Click({
        if ($null -eq $script:IsoCore_isoProc -or $script:IsoCore_isoProc.HasExited) { return }

        $res = [System.Windows.Forms.MessageBox]::Show(
            "Se cancelara la compilacion en curso.`nLa ISO parcial se eliminara automaticamente y, si existia una version anterior, se restaurara.`n`n¿Confirmas la cancelacion?",
            "Cancelar Compilacion",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($res -eq 'No') { return }

        Write-IsoCoreLog -LogLevel WARN -Message "IsoCore: Compilacion cancelada por el usuario desde el boton Cancelar."

        # Detener timer de progreso y liberar wait handle
        if ($null -ne $script:IsoCore_pollTimer) {
            try { $script:IsoCore_pollTimer.Stop(); $script:IsoCore_pollTimer.Dispose() } catch {}
            $script:IsoCore_pollTimer = $null
        }
        if ($null -ne $script:IsoCore_buildDone) {
            try { $script:IsoCore_buildDone.Dispose() } catch {}
            $script:IsoCore_buildDone = $null
        }

        & $script:IsoCore_DisposeIsoProcess $true
        [void](& $script:IsoCore_CaptureInterruptedBuildLog 'CANCELADO POR EL USUARIO' 'ISO_Build_CANCELLED')
        $script:IsoCore_outQueue = $null
        $script:IsoCore_errQueue = $null

        # Limpiar archivos inyectados y restaurar una ISO anterior, si existia.
        & $script:IsoCore_CleanupInjectedFiles
        & $script:IsoCore_FinalizeIsoOutput $false

        # Actualizar HUD
        & $script:IsoCore_SetPhase "Compilacion cancelada por el usuario." ([System.Drawing.Color]::Orange)
        $pbMain.Value         = 0
        $lblPercent.Text      = "Cancelado"
        $lblPercent.ForeColor = [System.Drawing.Color]::Orange
        $btnExportLog.Enabled = -not [string]::IsNullOrWhiteSpace($script:IsoCore_lastBuildLog)

        Write-IsoCoreLog -LogLevel ACTION -Message "IsoCore: Recursos liberados correctamente tras la cancelacion. Listo para nueva compilacion."
        & $script:IsoCore_RestoreCompileUI
    })

    # ------------------------------------------------------------------
    # 6. Logica principal — CREAR ISO BOOTEABLE
    # ------------------------------------------------------------------
    $btnMake.Add_Click({
        $src        = $txtSrc.Text
        $script:IsoCore_iso = $txtDst.Text
        $xmlPath    = $txtUnattend.Text
        $iso        = $script:IsoCore_iso

        if (-not $src -or -not $iso) {
            Write-IsoCoreLog -LogLevel WARN -Message "IsoCore: El usuario intento compilar sin definir rutas de origen o destino."
            [System.Windows.Forms.MessageBox]::Show("Faltan rutas.", "Error", 'OK', 'Error')
            return
        }

        if (-not (Test-Path -LiteralPath $src -PathType Container)) {
            Write-IsoCoreLog -LogLevel ERROR -Message "IsoCore: La carpeta origen no existe: $src"
            [System.Windows.Forms.MessageBox]::Show("La carpeta origen no existe.", "Error", 'OK', 'Error')
            return
        }

        try {
            $src = [System.IO.Path]::GetFullPath($src)
            $iso = [System.IO.Path]::GetFullPath($iso)
            if ([System.IO.Path]::GetExtension($iso) -ine '.iso') {
                $iso = [System.IO.Path]::ChangeExtension($iso, '.iso')
            }
            $script:IsoCore_iso = $iso
            $txtDst.Text = $iso
            $replaceExistingIso = $false

            $srcCompare = $src.TrimEnd([char[]]@('\','/'))
            $srcPrefix  = $srcCompare + [System.IO.Path]::DirectorySeparatorChar
            if ($iso.StartsWith($srcPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "El archivo ISO de destino no puede guardarse dentro de la carpeta origen."
            }

            $dstParent = Split-Path -Parent $iso
            if ([string]::IsNullOrWhiteSpace($dstParent)) {
                throw "No se pudo determinar la carpeta de destino."
            }
            if (-not (Test-Path -LiteralPath $dstParent)) {
                New-Item -Path $dstParent -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }

            if (Test-Path -LiteralPath $iso) {
                $overwrite = [System.Windows.Forms.MessageBox]::Show(
                    "El archivo de destino ya existe:`n$iso`n`n¿Deseas reemplazarlo?",
                    "Reemplazar ISO existente",
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Question
                )
                if ($overwrite -eq [System.Windows.Forms.DialogResult]::No) { return }
                $replaceExistingIso = $true
            }
        } catch {
            Write-IsoCoreLog -LogLevel ERROR -Message "IsoCore: Ruta de origen/destino no valida: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Ruta no valida", 'OK', 'Error') | Out-Null
            return
        }

        $biosBoot          = Join-Path $src "boot\etfsboot.com"
        $uefiBootStandard  = Join-Path $src "efi\microsoft\boot\efisys.bin"
        $uefiBootNoPrompt  = Join-Path $src "efi\microsoft\boot\efisys_noprompt.bin"

        $biosDisponible = (Test-Path -LiteralPath $biosBoot -PathType Leaf) -and
                          ((Get-Item -LiteralPath $biosBoot -ErrorAction SilentlyContinue).Length -gt 0)
        $uefiStandardDisponible = (Test-Path -LiteralPath $uefiBootStandard -PathType Leaf) -and
                                  ((Get-Item -LiteralPath $uefiBootStandard -ErrorAction SilentlyContinue).Length -gt 0)
        $uefiNoPromptDisponible = (Test-Path -LiteralPath $uefiBootNoPrompt -PathType Leaf) -and
                                  ((Get-Item -LiteralPath $uefiBootNoPrompt -ErrorAction SilentlyContinue).Length -gt 0)

        $uefiBoot = if ($uefiStandardDisponible) { $uefiBootStandard }
                    elseif ($uefiNoPromptDisponible) { $uefiBootNoPrompt }
                    else { $null }
        $uefiDisponible = -not [string]::IsNullOrWhiteSpace($uefiBoot)

        $sourceMatchesAnalysis = $false
        try {
            $sourceMatchesAnalysis = [string]::Equals(
                (& $script:IsoCore_NormalizeDirectoryPath $src),
                (& $script:IsoCore_NormalizeDirectoryPath ([string]$script:IsoCore_analyzedSource)),
                [StringComparison]::OrdinalIgnoreCase
            )
        } catch {}

        $detectedArch = if ($sourceMatchesAnalysis) { [string]$script:IsoCore_detectedArchitecture } else { $null }
        $detectedArch = & $script:IsoCore_ResolveArchitecture $detectedArch $src
        if ($detectedArch -eq 'DESCONOCIDA') {
            & Write-IsoCoreLog -LogLevel WARN -Message "IsoCore: No fue posible determinar con certeza la arquitectura. No se asumira X64."
        }

        try {
            & $script:IsoCore_SetPhase "Revalidando contenido de la fuente..." ($uiCyan)
            $currentSnapshot = & $script:IsoCore_GetSourceSnapshot $src {
                param($filesScanned, $dirsScanned, $bytesScanned)
                $sizeText = if ($bytesScanned -ge 1GB) { "$([math]::Round($bytesScanned / 1GB, 2)) GB" } elseif ($bytesScanned -ge 1MB) { "$([math]::Round($bytesScanned / 1MB, 1)) MB" } else { "$bytesScanned bytes" }
                & $script:IsoCore_SetPhase "Preflight: revalidando $filesScanned archivos | $sizeText..." ($uiCyan)
                [System.Windows.Forms.Application]::DoEvents()
            }
            $previousSnapshot = $script:IsoCore_sourceSnapshot
            $hasDeepFingerprint = ($null -ne $previousSnapshot) -and
                                  ($null -ne $previousSnapshot.PSObject.Properties['MetadataFingerprint']) -and
                                  (-not [string]::IsNullOrWhiteSpace([string]$previousSnapshot.MetadataFingerprint))
            $snapshotChanged = (-not $hasDeepFingerprint) -or
                               ($previousSnapshot.FullFingerprint -ne $currentSnapshot.FullFingerprint)
            if ($snapshotChanged) {
                $quickChanged = ($null -eq $previousSnapshot) -or
                                ($previousSnapshot.QuickFingerprint -ne $currentSnapshot.QuickFingerprint)
                if ($hasDeepFingerprint) {
                    & Write-IsoCoreLog -LogLevel WARN -Message "IsoCore: La fuente cambio desde el ultimo preflight; se actualizaron tamano, conteos y puntos de reanalisis."
                } else {
                    & Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: Huella profunda inicial completada durante preflight."
                }
                $script:IsoCore_sourceSnapshot = $currentSnapshot
                $script:IsoCore_sourceBytes = [long]$currentSnapshot.Bytes
                $script:IsoCore_reparsePointCount = [int]$currentSnapshot.ReparsePointCount
                $detectedArch = if ($quickChanged) {
                    & $script:IsoCore_ResolveArchitecture $null $src
                } else {
                    & $script:IsoCore_ResolveArchitecture $detectedArch $src
                }
                $script:IsoCore_detectedArchitecture = $detectedArch
                & $script:IsoCore_UpdateValidation $src
                & $script:IsoCore_UpdateDiskSpace $src $iso
                $cacheKeyPreflight = (& $script:IsoCore_NormalizeDirectoryPath $src).ToUpperInvariant()
                if ($script:IsoCore_analysisCache.ContainsKey($cacheKeyPreflight)) {
                    if ($quickChanged) {
                        [void]$script:IsoCore_analysisCache.Remove($cacheKeyPreflight)
                    } else {
                        $cachedPreflight = $script:IsoCore_analysisCache[$cacheKeyPreflight]
                        $cachedPreflight.Snapshot = $currentSnapshot
                        $cachedPreflight.QuickFingerprint = $currentSnapshot.QuickFingerprint
                        $cachedPreflight.SizeResult = [pscustomobject]@{
                            Bytes=[long]$currentSnapshot.Bytes; Count=[int]$currentSnapshot.FileCount
                            DirCount=[int]$currentSnapshot.DirCount; ReparsePointCount=[int]$currentSnapshot.ReparsePointCount
                            LastWriteTicks=[long]$currentSnapshot.LatestWriteTicks; IsFinal=$true; Error=$null
                        }
                        $cachedPreflight.SavedAt = Get-Date
                    }
                }
            } else {
                & Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: Huella profunda de la fuente sin cambios desde el ultimo preflight."
            }
            $currentSourceBytes = [long]$currentSnapshot.Bytes
        } catch {
            & Write-IsoCoreLog -LogLevel ERROR -Message "IsoCore: No se pudo revalidar la fuente durante preflight: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show(
                "No se pudo completar la revalidacion de la carpeta origen.`n`nDetalle:`n$($_.Exception.Message)",
                'Preflight incompleto', 'OK', 'Error'
            ) | Out-Null
            return
        }

        $bootProfile = $null
        if ($detectedArch -eq 'ARM64') {
            if (-not $uefiDisponible) {
                Write-IsoCoreLog -LogLevel ERROR -Message "IsoCore: Fuente ARM64 sin efisys.bin ni efisys_noprompt.bin; no es posible crear una ISO arrancable."
                [System.Windows.Forms.MessageBox]::Show(
                    "La fuente fue identificada como ARM64, pero no contiene una imagen de arranque UEFI válida:`n`nefi\microsoft\boot\efisys.bin`no`nefi\microsoft\boot\efisys_noprompt.bin",
                    "Arranque UEFI ARM64 ausente",
                    'OK',
                    'Error'
                ) | Out-Null
                return
            }
            $bootProfile = 'UEFI'
        } elseif ($biosDisponible -and $uefiDisponible) {
            $bootProfile = 'DUAL'
        } elseif ($biosDisponible) {
            $bootProfile = 'BIOS'
        } elseif ($uefiDisponible) {
            $bootProfile = 'UEFI'
        } else {
            Write-IsoCoreLog -LogLevel ERROR -Message "IsoCore: No se encontro ninguna imagen El Torito valida para BIOS o UEFI."
            [System.Windows.Forms.MessageBox]::Show(
                "No se encontró ninguna imagen de arranque válida.`n`nSe requiere al menos uno de estos archivos:`n• boot\etfsboot.com`n• efi\microsoft\boot\efisys.bin`n• efi\microsoft\boot\efisys_noprompt.bin",
                "Fuente no arrancable",
                'OK',
                'Error'
            ) | Out-Null
            return
        }

        if ($detectedArch -eq 'DESCONOCIDA') {
            $unknownChoice = [System.Windows.Forms.MessageBox]::Show(
                "No fue posible determinar con certeza la arquitectura de Windows. No se asumira X64.`n`nPerfil de arranque detectado: $bootProfile`n`nLa ISO se construira exclusivamente con los archivos de arranque realmente presentes. ¿Deseas continuar?",
                'Arquitectura no determinada',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($unknownChoice -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }

        if ($bootProfile -eq 'BIOS') {
            $confirmBoot = [System.Windows.Forms.MessageBox]::Show(
                "La fuente solo contiene arranque BIOS/Legacy.`nLa ISO no arrancará en equipos configurados exclusivamente para UEFI.`n`n¿Deseas continuar?",
                "Perfil BIOS-only",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($confirmBoot -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        } elseif ($bootProfile -eq 'UEFI' -and $detectedArch -ne 'ARM64') {
            $confirmBoot = [System.Windows.Forms.MessageBox]::Show(
                "La fuente solo contiene arranque UEFI.`nLa ISO no arrancará en equipos configurados exclusivamente para BIOS/Legacy.`n`n¿Deseas continuar?",
                "Perfil UEFI-only",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($confirmBoot -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }

        if ($uefiNoPromptDisponible -and -not $uefiStandardDisponible) {
            Write-IsoCoreLog -LogLevel WARN -Message "IsoCore: Se usara efisys_noprompt.bin porque efisys.bin no esta disponible. El arranque UEFI sera automatico."
        }
        Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: Perfil de arranque resuelto: $bootProfile | Arquitectura: $detectedArch | BIOS: $biosDisponible | UEFI: $uefiDisponible | Imagen UEFI: $uefiBoot"

        $resolveReparsePoints = $false
        if ($sourceMatchesAnalysis -and [int]$script:IsoCore_reparsePointCount -gt 0) {
            $linkChoice = [System.Windows.Forms.MessageBox]::Show(
                "Se detectaron $($script:IsoCore_reparsePointCount) enlaces simbólicos o junctions en la fuente.`n`nSí: resolver sus destinos mediante -r.`nNo: conservar el comportamiento normal de oscdimg.`nCancelar: detener la compilación.`n`nAdvertencia: -r puede incorporar contenido ubicado fuera de la carpeta seleccionada.",
                "Enlaces detectados en la fuente",
                [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($linkChoice -eq [System.Windows.Forms.DialogResult]::Cancel) { return }
            $resolveReparsePoints = ($linkChoice -eq [System.Windows.Forms.DialogResult]::Yes)
            Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: Enlaces detectados: $($script:IsoCore_reparsePointCount) | Resolver con -r: $resolveReparsePoints"
        }

        $bootWim = Join-Path $src "sources\boot.wim"
        if (-not (Test-Path -LiteralPath $bootWim -PathType Leaf) -or
            ((Get-Item -LiteralPath $bootWim -ErrorAction SilentlyContinue).Length -le 0)) {
            Write-IsoCoreLog -LogLevel ERROR -Message "IsoCore: Falta sources\boot.wim o el archivo está vacío; la fuente no puede iniciar Windows Setup/WinPE."
            [System.Windows.Forms.MessageBox]::Show(
                "No se encontró un archivo válido en sources\boot.wim.`n`nLa ISO podría tener catálogo El Torito, pero no podría iniciar Windows Setup o WinPE.",
                "boot.wim ausente",
                'OK',
                'Error'
            ) | Out-Null
            return
        }

        $srcWim = Join-Path $src "sources\install.wim"
        $srcEsd = Join-Path $src "sources\install.esd"
        $swmInfoPreflight = & $script:IsoCore_GetSwmSetInfo $src $true
        if ($swmInfoPreflight.Exists -and -not $swmInfoPreflight.Valid) {
            & Write-IsoCoreLog -LogLevel ERROR -Message "IsoCore: Conjunto SWM no valido: $($swmInfoPreflight.Errors -join ' | ')"
            [System.Windows.Forms.MessageBox]::Show(
                "El conjunto install*.swm no es valido.`n`n$($swmInfoPreflight.Errors -join "`n")",
                'Conjunto SWM no valido', 'OK', 'Error'
            ) | Out-Null
            return
        }
        $hasInstallImage = (Test-Path -LiteralPath $srcWim -PathType Leaf) -or
                           (Test-Path -LiteralPath $srcEsd -PathType Leaf) -or
                           ($swmInfoPreflight.Exists -and $swmInfoPreflight.Valid)
        if (-not $hasInstallImage) {
            & Write-IsoCoreLog -LogLevel WARN -Message "IsoCore: No se encontro sources\install.wim, install.esd ni un conjunto SWM valido."
            $resWim = [System.Windows.Forms.MessageBox]::Show(
                "No se encontro 'sources\install.wim', 'sources\install.esd' ni un conjunto SWM valido en la carpeta origen.`n`nEsto puede indicar una fuente incompleta o un medio WinPE sin imagen de instalacion.`n`n¿Deseas continuar de todas formas?",
                "Imagen de Instalacion Ausente",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($resWim -eq 'No') { return }
            & Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: Usuario acepto continuar sin imagen de instalacion."
        } elseif ($swmInfoPreflight.Exists) {
            & Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: $($swmInfoPreflight.Summary) | Tamano: $($swmInfoPreflight.TotalBytes) bytes."
        }
        $script:IsoCore_requireInstallImage = [bool]$hasInstallImage

        try {
            $dstQ = Split-Path -Qualifier $iso -ErrorAction SilentlyContinue
            if ($dstQ) {
                $drive = Get-PSDrive -Name $dstQ.TrimEnd(':') -ErrorAction SilentlyContinue
                if ($drive) {
                    $requiredBytes = 5GB
                    if ([long]$currentSourceBytes -gt 0) {
                        $requiredBytes = [long][math]::Ceiling(([double]$currentSourceBytes * 1.08) + 256MB)
                    }
                    $driveFormat = $null
                    try {
                        $driveRoot = [System.IO.Path]::GetPathRoot($iso)
                        if (-not [string]::IsNullOrWhiteSpace($driveRoot)) {
                            $driveInfo   = New-Object System.IO.DriveInfo($driveRoot)
                            $driveFormat = $driveInfo.DriveFormat
                        }
                    } catch {}

                    if ($driveFormat -eq 'FAT32' -and [long]$currentSourceBytes -ge 4GB) {
                        Write-IsoCoreLog -LogLevel ERROR -Message "IsoCore: El destino usa FAT32 y la ISO estimada supera el limite de 4 GB por archivo."
                        [System.Windows.Forms.MessageBox]::Show(
                            "La unidad de destino usa FAT32, que no admite archivos de 4 GB o mas.`n`nSelecciona una unidad NTFS, exFAT o ReFS para guardar esta ISO.",
                            "Destino FAT32 no compatible",
                            'OK',
                            'Error'
                        ) | Out-Null
                        return
                    }
                    if (-not [string]::IsNullOrWhiteSpace($driveFormat)) {
                        Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: Sistema de archivos del destino: $driveFormat."
                    }

                    if ($drive.Free -lt $requiredBytes) {
                        $freeGB     = [math]::Round($drive.Free / 1GB, 1)
                        $requiredGB = [math]::Round($requiredBytes / 1GB, 1)
                        $proceed = [System.Windows.Forms.MessageBox]::Show(
                            "Espacio libre en el destino: $freeGB GB`nEstimado requerido: $requiredGB GB`n`nLa compilacion puede fallar o dejar una salida parcial.`n`n¿Deseas continuar de todas formas?",
                            "Espacio en Disco Insuficiente",
                            [System.Windows.Forms.MessageBoxButtons]::YesNo,
                            [System.Windows.Forms.MessageBoxIcon]::Warning
                        )
                        if ($proceed -eq [System.Windows.Forms.DialogResult]::No) {
                            Write-IsoCoreLog -LogLevel WARN -Message "IsoCore: El usuario cancelo la compilacion por espacio insuficiente ($freeGB GB libres; $requiredGB GB estimados)."
                            return
                        }
                        Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: Usuario acepto continuar con espacio limitado ($freeGB GB libres; $requiredGB GB estimados)."
                    }
                }
            }
        } catch {
            Write-IsoCoreLog -LogLevel WARN -Message "IsoCore: No se pudo validar el espacio del destino: $($_.Exception.Message)"
        }

        $btnOpenFolder.Visible = $false
        $lblHashInfo.Text      = ""
        $lblHashInfo.ForeColor = $uiGreen

        try {
            & $script:IsoCore_InitializeInjectionState
        } catch {
            Write-IsoCoreLog -LogLevel ERROR -Message "IsoCore: No se pudo preparar el respaldo temporal de inyeccion: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show("No se pudo preparar la inyeccion:`n$($_.Exception.Message)", "Error", 'OK', 'Error') | Out-Null
            return
        }

        if (-not [string]::IsNullOrWhiteSpace($xmlPath)) {
            if (-not (Test-Path -LiteralPath $xmlPath -PathType Leaf)) {
                [System.Windows.Forms.MessageBox]::Show("El archivo XML seleccionado ya no existe:`n$xmlPath", "Archivo no encontrado", 'OK', 'Error') | Out-Null
                & $script:IsoCore_CleanupInjectedFiles
                return
            }
            try {
                [xml]$unattendDocument = Get-Content -LiteralPath $xmlPath -Raw -ErrorAction Stop
                if ($null -eq $unattendDocument.DocumentElement -or
                    $unattendDocument.DocumentElement.LocalName -ine 'unattend') {
                    throw "El elemento raiz del XML debe ser 'unattend'."
                }
            } catch {
                Write-IsoCoreLog -LogLevel ERROR -Message "IsoCore: autounattend.xml no es valido: $($_.Exception.Message)"
                [System.Windows.Forms.MessageBox]::Show(
                    "El archivo XML seleccionado no es un autounattend.xml valido.`n`nDetalle:`n$($_.Exception.Message)",
                    "XML no valido",
                    'OK',
                    'Error'
                ) | Out-Null
                & $script:IsoCore_CleanupInjectedFiles
                return
            }

            Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: Archivo Unattend.xml valido detectado. Inyectando en la raiz de la ISO."
            try {
                $xmlDest = Join-Path $src "autounattend.xml"
                $xmlFullPath  = [System.IO.Path]::GetFullPath($xmlPath)
                $destFullPath = [System.IO.Path]::GetFullPath($xmlDest)
                if ([string]::Equals($xmlFullPath, $destFullPath, [StringComparison]::OrdinalIgnoreCase)) {
                    Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: El autounattend.xml seleccionado ya se encuentra en la raiz del medio; no se requiere copiarlo."
                } else {
                    & $script:IsoCore_PrepareInjectionTarget $xmlDest
                    Copy-Item -LiteralPath $xmlPath -Destination $xmlDest -Force -ErrorAction Stop
                    Write-IsoCoreLog -LogLevel ACTION -Message "IsoCore: autounattend.xml inyectado correctamente en: $xmlDest"
                }
            } catch {
                Write-IsoCoreLog -LogLevel ERROR -Message "IsoCore: Fallo al copiar el archivo XML a la raiz - $($_.Exception.Message)"
                [System.Windows.Forms.MessageBox]::Show("Error copiando XML: $($_.Exception.Message)", "Error", 'OK', 'Error') | Out-Null
                & $script:IsoCore_CleanupInjectedFiles
                return
            }
        }

        $injectionDeltaBytes = 0L
        foreach ($createdPath in @($script:IsoCore_injectedFiles)) {
            if ($createdPath -and (Test-Path -LiteralPath $createdPath -PathType Leaf)) {
                $injectionDeltaBytes += [long](Get-Item -LiteralPath $createdPath -Force).Length
            }
        }
        foreach ($backupEntry in @($script:IsoCore_injectionBackups)) {
            if ($backupEntry -and $backupEntry.Original -and $backupEntry.Backup -and
                (Test-Path -LiteralPath $backupEntry.Original -PathType Leaf) -and
                (Test-Path -LiteralPath $backupEntry.Backup -PathType Leaf)) {
                $newLength = [long](Get-Item -LiteralPath $backupEntry.Original -Force).Length
                $oldLength = [long](Get-Item -LiteralPath $backupEntry.Backup -Force).Length
                $injectionDeltaBytes += ($newLength - $oldLength)
            }
        }
        if ($injectionDeltaBytes -ne 0) {
            $currentSourceBytes = [long][math]::Max(0, ([long]$currentSourceBytes + $injectionDeltaBytes))
            Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: Ajuste de tamano por inyecciones: $injectionDeltaBytes bytes | Tamano efectivo: $currentSourceBytes bytes."
        }

        # Bloquear controles y mostrar indicadores de actividad
        $btnMake.Enabled      = $false
        $grpCfg.Enabled       = $false
        $grpAuto.Enabled      = $false
        $form.Cursor          = [System.Windows.Forms.Cursors]::WaitCursor
        $pbMain.Value         = 0
        $lblPercent.Text      = "0 % completado"
        $lblPercent.ForeColor = $uiGreen
        $lblFileInfo.Text     = ""
        $lblSizeInfo.Text     = ""

        & $script:IsoCore_SetPhase "Iniciando compilacion..." ($uiCyan)
        $picCD.Visible = $true
        $cdTimer.Start()

        $btnCancel.Visible = $true
        & $script:IsoCore_UpdateActionLayout

        if ($chkMRP.Checked) {
            Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: El usuario habilito la inyeccion de MRP. Buscando archivo ZIP..."
            & $script:IsoCore_SetPhase "Buscando paquete MRP en el directorio Tools..." ($uiCyan)

            $mrpZipPath = $null
            $mrpPaths   = @(
                (Join-Path $scriptPath "Tools"),
                (Join-Path $scriptPath "..\Tools")
            )
            foreach ($candidateDirectory in $mrpPaths) {
                if (Test-Path -LiteralPath $candidateDirectory -PathType Container) {
                    $found = Get-ChildItem -LiteralPath $candidateDirectory -Filter "*MRP*.zip" -File -ErrorAction SilentlyContinue |
                             Sort-Object Name |
                             Select-Object -First 1
                    if ($found) {
                        $mrpZipPath = $found.FullName
                        break
                    }
                }
            }

            if ($mrpZipPath) {
                Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: Archivo MRP detectado: $mrpZipPath. Validando contenido..."
                & $script:IsoCore_SetPhase "Validando y extrayendo MRP en \sources..." ($uiCyan)
                try {
                    $sourcesDir = Join-Path $src "sources"
                    & $script:IsoCore_RegisterCreatedDirectory $sourcesDir

                    $script:IsoCore_mrpExtractRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("IsoCore_MRP_" + [guid]::NewGuid().ToString('N'))
                    New-Item -Path $script:IsoCore_mrpExtractRoot -ItemType Directory -Force -ErrorAction Stop | Out-Null

                    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
                    $zipArchive = [System.IO.Compression.ZipFile]::OpenRead($mrpZipPath)
                    try {
                        $extractRootFull = [System.IO.Path]::GetFullPath($script:IsoCore_mrpExtractRoot).TrimEnd('\') + '\'
                        foreach ($entry in $zipArchive.Entries) {
                            $entryName = [string]$entry.FullName
                            if ([string]::IsNullOrWhiteSpace($entryName)) { continue }

                            $entryWindows = $entryName.Replace('/', '\')
                            if ([System.IO.Path]::IsPathRooted($entryWindows) -or
                                $entryWindows -match '(^|\\)\.\.(\\|$)' -or
                                $entryWindows -match ':') {
                                throw "Entrada ZIP insegura: $entryName"
                            }

                            $entryTarget = [System.IO.Path]::GetFullPath((Join-Path $script:IsoCore_mrpExtractRoot $entryWindows))
                            if (-not $entryTarget.StartsWith($extractRootFull, [StringComparison]::OrdinalIgnoreCase) -and
                                -not [string]::Equals($entryTarget.TrimEnd('\'), $extractRootFull.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
                                throw "Entrada ZIP fuera del destino permitido: $entryName"
                            }

                            $unixType = (($entry.ExternalAttributes -shr 16) -band 0xF000)
                            if ($unixType -eq 0xA000) {
                                throw "El ZIP contiene un enlace simbolico no permitido: $entryName"
                            }
                        }
                    } finally {
                        if ($null -ne $zipArchive) { $zipArchive.Dispose() }
                    }

                    Expand-Archive -LiteralPath $mrpZipPath -DestinationPath $script:IsoCore_mrpExtractRoot -Force -ErrorAction Stop

                    $reparseItem = Get-ChildItem -LiteralPath $script:IsoCore_mrpExtractRoot -Recurse -Force -ErrorAction Stop |
                                   Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 } |
                                   Select-Object -First 1
                    if ($reparseItem) {
                        throw "El paquete MRP extrajo un enlace o punto de reanalisis no permitido: $($reparseItem.FullName)"
                    }

                    $rootPrefix = [System.IO.Path]::GetFullPath($script:IsoCore_mrpExtractRoot).TrimEnd('\') + '\'
                    $directories = Get-ChildItem -LiteralPath $script:IsoCore_mrpExtractRoot -Recurse -Directory -Force -ErrorAction Stop |
                                   Sort-Object { $_.FullName.Length }
                    foreach ($directory in $directories) {
                        $directoryFull = [System.IO.Path]::GetFullPath($directory.FullName)
                        $relative = $directoryFull.Substring($rootPrefix.Length)
                        if ([string]::IsNullOrWhiteSpace($relative)) { continue }
                        $targetDir = Join-Path $sourcesDir $relative
                        & $script:IsoCore_RegisterCreatedDirectory $targetDir
                    }

                    foreach ($file in (Get-ChildItem -LiteralPath $script:IsoCore_mrpExtractRoot -Recurse -File -Force -ErrorAction Stop)) {
                        $fileFull = [System.IO.Path]::GetFullPath($file.FullName)
                        $relative = $fileFull.Substring($rootPrefix.Length)
                        $targetFile = Join-Path $sourcesDir $relative
                        $targetParent = Split-Path -Parent $targetFile
                        & $script:IsoCore_RegisterCreatedDirectory $targetParent
                        & $script:IsoCore_PrepareInjectionTarget $targetFile
                        Copy-Item -LiteralPath $file.FullName -Destination $targetFile -Force -ErrorAction Stop
                    }

                    Write-IsoCoreLog -LogLevel ACTION -Message "IsoCore: MRP inyectado en $sourcesDir."
                } catch {
                    Write-IsoCoreLog -LogLevel ERROR -Message "IsoCore: Fallo al validar, extraer o inyectar MRP - $($_.Exception.Message)"
                    [System.Windows.Forms.MessageBox]::Show(
                        "Error al validar, extraer o inyectar el archivo ZIP de MRP:`n$($_.Exception.Message)",
                        "Error de MRP",
                        'OK',
                        'Error'
                    ) | Out-Null
                    & $script:IsoCore_CleanupInjectedFiles
                    & $script:IsoCore_RestoreCompileUI
                    return
                }
            } else {
                Write-IsoCoreLog -LogLevel WARN -Message "IsoCore: No se encontro un ZIP '*MRP*.zip' en las carpetas Tools."
                [System.Windows.Forms.MessageBox]::Show(
                    "No se encontro ningun archivo ZIP cuyo nombre contenga 'MRP' en la carpeta Tools.",
                    "Paquete MRP no encontrado",
                    'OK',
                    'Warning'
                ) | Out-Null
                & $script:IsoCore_CleanupInjectedFiles
                & $script:IsoCore_RestoreCompileUI
                return
            }
        }

        $label = ($txtLabel.Text -replace '[^A-Za-z0-9_\-]', '_').ToUpper().Trim('_')
        if ($label.Length -eq 0)  { $label = "WINDOWS_CUSTOM" }
        if ($label.Length -gt 32) { $label = $label.Substring(0, 32) }
        if ($label -ne $txtLabel.Text.ToUpper()) {
            Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: Etiqueta sanitizada (ISO 9660/UDF): '$($txtLabel.Text)' -> '$label'."
        } else {
            Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: Etiqueta de volumen: '$label'."
        }

        $script:IsoCore_lastPct = 0

        $srcNorm = [System.IO.Path]::GetFullPath($src)
        $srcArg  = & $script:IsoCore_QuoteWindowsArgument $srcNorm
        $isoArg  = & $script:IsoCore_QuoteWindowsArgument $iso
        $biosArg = if ($biosDisponible) { & $script:IsoCore_QuoteWindowsArgument $biosBoot } else { $null }
        $uefiArg = if ($uefiDisponible) { & $script:IsoCore_QuoteWindowsArgument $uefiBoot } else { $null }

        $bootArg = switch ($bootProfile) {
            'DUAL' { "-bootdata:2#p0,e,b$biosArg#pEF,e,b$uefiArg"; break }
            'BIOS' { "-b$biosArg -p0 -e"; break }
            'UEFI' { "-b$uefiArg -pEF -e"; break }
            default { throw "Perfil de arranque no reconocido: $bootProfile" }
        }

        $largeSource = ([long]$currentSourceBytes -gt [long](4.5 * 1GB))
        $bootOrderPath = $null
        $bootOrderSwitch = $null
        if ($largeSource) {
            try {
                $bootOrderPath   = & $script:IsoCore_NewBootOrderFile $srcNorm
                $bootOrderSwitch = "-yo$bootOrderPath"
                Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: BootOrder generado (fuente mayor de 4.5 GB): $bootOrderPath"
            } catch {
                Write-IsoCoreLog -LogLevel WARN -Message "IsoCore: No se pudo preparar BootOrder; se continuara con perfil compatible. Detalle: $($_.Exception.Message)"
                $bootOrderPath = $null
                $bootOrderSwitch = $null
            }
        } else {
            & $script:IsoCore_RemoveBootOrderFile
            Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: BootOrder no requerido (fuente de 4.5 GB o menor)."
        }

        $script:IsoCore_buildBootProfile = $bootProfile
        $script:IsoCore_expectedIsoFiles = @()
        $sourcePrefixForExpected = $src.TrimEnd('\') + '\'
        $expectedSourcePaths = New-Object System.Collections.Generic.List[string]
        foreach ($injectedPath in @($script:IsoCore_injectedFiles)) {
            if ($injectedPath -and (Test-Path -LiteralPath $injectedPath -PathType Leaf)) { $expectedSourcePaths.Add([string]$injectedPath) }
        }
        foreach ($backupEntry in @($script:IsoCore_injectionBackups)) {
            if ($backupEntry -and $backupEntry.Original -and (Test-Path -LiteralPath $backupEntry.Original -PathType Leaf)) {
                $expectedSourcePaths.Add([string]$backupEntry.Original)
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($xmlPath)) {
            $expectedSourcePaths.Add((Join-Path $src 'autounattend.xml'))
        }
        foreach ($expectedSourcePath in @($expectedSourcePaths | Select-Object -Unique)) {
            if ($expectedSourcePath.StartsWith($sourcePrefixForExpected, [StringComparison]::OrdinalIgnoreCase)) {
                $script:IsoCore_expectedIsoFiles += $expectedSourcePath.Substring($sourcePrefixForExpected.Length)
            }
        }

        $reparseArg = if ($resolveReparsePoints) { ' -r' } else { '' }

        $attempts = New-Object System.Collections.ArrayList
        if ($bootOrderSwitch) {
            [void]$attempts.Add([pscustomobject]@{
                Name = 'OPTIMIZADO'
                Description = 'BootOrder + archivos ocultos (UDF 1.02 compatible)'
                Args = "-m -o -h -u2 -udfver102 -l$label $bootOrderSwitch$reparseArg $bootArg $srcArg $isoArg"
            })
        }
        [void]$attempts.Add([pscustomobject]@{
            Name = 'ESTANDAR'
            Description = 'Incluye archivos ocultos; sin BootOrder ni diagnosticos'
            Args = "-m -o -h -u2 -udfver102 -l$label$reparseArg $bootArg $srcArg $isoArg"
        })
        [void]$attempts.Add([pscustomobject]@{
            Name = 'COMPATIBILIDAD'
            Description = 'Conjunto esencial compatible con oscdimg 2.56'
            Args = "-m -o -u2 -udfver102 -l$label$reparseArg $bootArg $srcArg $isoArg"
        })

        $script:IsoCore_buildAttempts = @($attempts)
        $script:IsoCore_attemptIndex  = 0
        $script:IsoCore_oscdimgExe    = $oscdimgExe

        Write-IsoCoreLog -LogLevel ACTION -Message "IsoCore: Iniciando compilacion de ISO..."
        & $script:IsoCore_SetPhase "Analizando arbol de directorios y calculando estructura..." ($uiCyan)

        $script:IsoCore_cleanLogBuilder = New-Object System.Text.StringBuilder
        $script:IsoCore_cleanLogBuilder.AppendLine("PERFIL DE ARRANQUE: $bootProfile | ARQUITECTURA: $detectedArch") | Out-Null
        $script:IsoCore_cleanLogBuilder.AppendLine("UEFI: $(if ($uefiDisponible) { Split-Path -Leaf $uefiBoot } else { 'No' }) | BIOS: $biosDisponible") | Out-Null

        $rxOptsC = [System.Text.RegularExpressions.RegexOptions]::Compiled
        $script:IsoCore_rxPercent = [regex]::new('(\d+)%\s+complete', $rxOptsC)

        $script:IsoCore_StartOscdimgAttempt = {
            param([Parameter(Mandatory=$true)][int]$AttemptIndex)

            $attempt = $script:IsoCore_buildAttempts[$AttemptIndex]
            $script:IsoCore_attemptIndex = $AttemptIndex
            $script:IsoCore_lastPct = 0
            $pbMain.Value = 0
            $lblPercent.Text = "0 % completado"
            $lblPercent.Refresh()

            $script:IsoCore_outQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
            $script:IsoCore_errQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
            $script:IsoCore_errLogBuilder = New-Object System.Text.StringBuilder
            $script:IsoCore_attemptOutLogBuilder = New-Object System.Text.StringBuilder
            $script:IsoCore_buildDone = [System.Threading.ManualResetEventSlim]::new($false)

            $script:IsoCore_cleanLogBuilder.AppendLine("") | Out-Null
            $script:IsoCore_cleanLogBuilder.AppendLine("INTENTO $($AttemptIndex + 1)/$($script:IsoCore_buildAttempts.Count): $($attempt.Name)") | Out-Null
            $script:IsoCore_cleanLogBuilder.AppendLine("DESCRIPCION: $($attempt.Description)") | Out-Null
            $script:IsoCore_cleanLogBuilder.AppendLine("COMANDO:") | Out-Null
            $script:IsoCore_cleanLogBuilder.AppendLine("oscdimg.exe $($attempt.Args)") | Out-Null
            $script:IsoCore_cleanLogBuilder.AppendLine("----------------") | Out-Null

            $pInfo = New-Object System.Diagnostics.ProcessStartInfo
            $pInfo.FileName               = $script:IsoCore_oscdimgExe
            $pInfo.Arguments              = $attempt.Args
            $pInfo.RedirectStandardOutput = $true
            $pInfo.RedirectStandardError  = $true
            $pInfo.UseShellExecute        = $false
            $pInfo.CreateNoWindow         = $true

            $script:IsoCore_isoProc           = New-Object System.Diagnostics.Process
            $script:IsoCore_isoProc.StartInfo = $pInfo
            $script:IsoCore_stdoutHandler     = [IsoCore.ProcessOutputPump]::CreateHandler($script:IsoCore_outQueue)
            $script:IsoCore_stderrHandler     = [IsoCore.ProcessOutputPump]::CreateHandler($script:IsoCore_errQueue)
            $script:IsoCore_isoProc.add_OutputDataReceived($script:IsoCore_stdoutHandler)
            $script:IsoCore_isoProc.add_ErrorDataReceived($script:IsoCore_stderrHandler)

            if (-not $script:IsoCore_isoProc.Start()) { throw "No inicio oscdimg" }
            $script:IsoCore_isoProc.BeginOutputReadLine()
            $script:IsoCore_isoProc.BeginErrorReadLine()

            Write-IsoCoreLog -LogLevel ACTION -Message "IsoCore: Intento $($AttemptIndex + 1)/$($script:IsoCore_buildAttempts.Count) [$($attempt.Name)] lanzado (PID: $($script:IsoCore_isoProc.Id)). Argumentos: oscdimg.exe $($attempt.Args)"
            & $script:IsoCore_SetPhase "Compilando con perfil $($attempt.Name)..." ($uiCyan)
        }

        try {
            $script:IsoCore_previousIsoBackup        = $null
            $script:IsoCore_previousHashBackup       = $null
            $script:IsoCore_outputTransactionStarted = $false
            $script:IsoCore_outputTransactionState = 'PREPARING'
            $oldHashPath = [System.IO.Path]::ChangeExtension($iso, '.sha256')

            if ($replaceExistingIso -and (Test-Path -LiteralPath $iso)) {
                $script:IsoCore_previousIsoBackup = "$iso.isocore.$([guid]::NewGuid().ToString('N')).bak"
                Move-Item -LiteralPath $iso -Destination $script:IsoCore_previousIsoBackup -Force -ErrorAction Stop
            }
            if (Test-Path -LiteralPath $oldHashPath) {
                $script:IsoCore_previousHashBackup = "$oldHashPath.isocore.$([guid]::NewGuid().ToString('N')).bak"
                Move-Item -LiteralPath $oldHashPath -Destination $script:IsoCore_previousHashBackup -Force -ErrorAction Stop
            }

            $script:IsoCore_outputTransactionStarted = $true
            $script:IsoCore_outputTransactionState = 'PREPARED'
            & $script:IsoCore_StartOscdimgAttempt 0

            # ============================================================
            # TEMPORIZADOR DE PROGRESO
            # ============================================================
            $script:IsoCore_pollTimer          = New-Object System.Windows.Forms.Timer
            $script:IsoCore_pollTimer.Interval = 50

            $pollTickScript = {
                if ($null -eq $script:IsoCore_pollTimer) { return }

                try {
                    $line = $null

                    if ($null -ne $script:IsoCore_outQueue) {
                        while ($script:IsoCore_outQueue.TryDequeue([ref]$line)) {
                            $script:IsoCore_attemptOutLogBuilder.AppendLine($line) | Out-Null
                            if (-not [string]::IsNullOrWhiteSpace($line) -and
                                $line -match '(\d+) files in (\d+) directories') {
                                $lblFileInfo.Text = "$($matches[1]) archivos | $($matches[2]) directorios"
                                $lblFileInfo.Refresh()
                            }
                        }
                    }

                    if ($null -ne $script:IsoCore_errQueue) {
                        while ($script:IsoCore_errQueue.TryDequeue([ref]$line)) {
                            if ([string]::IsNullOrWhiteSpace($line)) { continue }
                            $script:IsoCore_errLogBuilder.AppendLine($line) | Out-Null

                            $m = $script:IsoCore_rxPercent.Match($line)
                            if ($m.Success) {
                                $pct = [int]$m.Groups[1].Value
                                $script:IsoCore_lastPct = $pct
                                if ($pct -gt $pbMain.Value) {
                                    if ($pbMain.Value -eq 0 -and $pct -gt 0) {
                                        & $script:IsoCore_SetPhase "Escribiendo imagen ISO en disco..." ($uiCyan)
                                    }
                                    $pbMain.Value    = [Math]::Min($pct, $pbMain.Maximum)
                                    $lblPercent.Text = "$pct % completado"
                                    $lblPercent.Refresh()
                                    if ($pct -eq 100) {
                                        & $script:IsoCore_SetPhase "Optimizando almacenamiento y finalizando..." ([System.Drawing.Color]::Orange)
                                    }
                                }
                            }
                        }
                    }

                    if ($null -ne $script:IsoCore_isoProc -and $script:IsoCore_isoProc.HasExited -and
                        $null -ne $script:IsoCore_buildDone -and -not $script:IsoCore_buildDone.IsSet) {
                        try { $script:IsoCore_isoProc.WaitForExit() } catch {}
                        $script:IsoCore_buildDone.Set()
                    }

                    if ($null -eq $script:IsoCore_buildDone -or -not $script:IsoCore_buildDone.IsSet) { return }

                    # ============================================================
                    # VACIADO FINAL Y CIERRE DE HILOS
                    # ============================================================
                    while ($script:IsoCore_outQueue.TryDequeue([ref]$line)) {
                        $script:IsoCore_attemptOutLogBuilder.AppendLine($line) | Out-Null
                    }
                    while ($script:IsoCore_errQueue.TryDequeue([ref]$line)) {
                        if (-not [string]::IsNullOrWhiteSpace($line)) {
                            $script:IsoCore_errLogBuilder.AppendLine($line) | Out-Null
                            $m2 = $script:IsoCore_rxPercent.Match($line)
                            if ($m2.Success) { $script:IsoCore_lastPct = [int]$m2.Groups[1].Value }
                        }
                    }

                    $attemptLogText = $script:IsoCore_attemptOutLogBuilder.ToString()
                    if ($script:IsoCore_lastPct -gt 0) {
                        $pctLine = "$($script:IsoCore_lastPct)% complete"
                        $writingRegex = [regex]::new(
                            '(?im)(Writing \d+ files in \d+ directories[^\r\n]*)',
                            [System.Text.RegularExpressions.RegexOptions]::Compiled
                        )
                        if ($writingRegex.IsMatch($attemptLogText)) {
                            $attemptLogText = $writingRegex.Replace($attemptLogText, "`$1`r`n`r`n$pctLine", 1)
                        } else {
                            $attemptLogText += "`r`n$pctLine`r`n"
                        }
                    }
                    if (-not [string]::IsNullOrEmpty($attemptLogText)) {
                        [void]$script:IsoCore_cleanLogBuilder.Append($attemptLogText)
                    }

                    try { $script:IsoCore_buildDone.Dispose() } catch {}
                    $script:IsoCore_buildDone = $null

                    $exitCode = 0
                    if ($null -ne $script:IsoCore_isoProc) {
                        try { $exitCode = $script:IsoCore_isoProc.ExitCode } catch { $exitCode = -1 }
                    }

                    if ($exitCode -ne 0 -and
                        $script:IsoCore_attemptIndex -lt ($script:IsoCore_buildAttempts.Count - 1)) {

                        $failedAttempt = $script:IsoCore_buildAttempts[$script:IsoCore_attemptIndex]
                        $stderrAttempt = $script:IsoCore_errLogBuilder.ToString().Trim()
                        $stdoutAttempt = $script:IsoCore_attemptOutLogBuilder.ToString().Trim()
                        $diagnosticAttempt = if (-not [string]::IsNullOrWhiteSpace($stderrAttempt)) { $stderrAttempt } else { $stdoutAttempt }
                        $script:IsoCore_cleanLogBuilder.AppendLine("") | Out-Null
                        $script:IsoCore_cleanLogBuilder.AppendLine("RESULTADO: ERROR $exitCode EN PERFIL $($failedAttempt.Name)") | Out-Null
                        if (-not [string]::IsNullOrWhiteSpace($stderrAttempt)) {
                            $script:IsoCore_cleanLogBuilder.AppendLine("SALIDA STDERR:") | Out-Null
                            $script:IsoCore_cleanLogBuilder.AppendLine($stderrAttempt) | Out-Null
                        }

                        $nextIndex = $script:IsoCore_attemptIndex + 1
                        $nextAttempt = $script:IsoCore_buildAttempts[$nextIndex]
                        $detail = if ($diagnosticAttempt) {
                            ($diagnosticAttempt -split "`r?`n" |
                                Where-Object { $_.Trim() -and $_.Trim() -notmatch '^\d+%\s+complete$' } |
                                Select-Object -First 1)
                        } else {
                            'sin detalle devuelto por oscdimg'
                        }
                        Write-IsoCoreLog -LogLevel WARN -Message "IsoCore: Perfil $($failedAttempt.Name) fallo con codigo $exitCode ($detail). Reintentando automaticamente con $($nextAttempt.Name)."
                        & $script:IsoCore_SetPhase "Perfil $($failedAttempt.Name) incompatible; reintentando con $($nextAttempt.Name)..." ($uiOrange)

                        & $script:IsoCore_DisposeIsoProcess $false
                        if (Test-Path -LiteralPath $script:IsoCore_iso) {
                            try { Remove-Item -LiteralPath $script:IsoCore_iso -Force -ErrorAction Stop } catch {
                                throw "No se pudo eliminar la ISO parcial antes del reintento: $($_.Exception.Message)"
                            }
                        }

                        try {
                            & $script:IsoCore_StartOscdimgAttempt $nextIndex
                            return
                        } catch {
                            $exitCode = -3
                            $script:IsoCore_errLogBuilder.AppendLine("IsoCore: No se pudo iniciar el perfil de reintento: $($_.Exception.Message)") | Out-Null
                        }
                    }

                    if ($null -ne $script:IsoCore_pollTimer) {
                        try { $script:IsoCore_pollTimer.Stop() } catch {}
                        try { $script:IsoCore_pollTimer.Dispose() } catch {}
                        $script:IsoCore_pollTimer = $null
                    }

                    if ($exitCode -eq 0) {
                        try {
                            $isoItem = Get-Item -LiteralPath $script:IsoCore_iso -ErrorAction Stop
                            if ($isoItem.Length -le 0) { throw "El archivo ISO generado esta vacio." }
                        } catch {
                            $exitCode = -2
                            $script:IsoCore_errLogBuilder.AppendLine("IsoCore: oscdimg finalizo sin producir una ISO valida: $($_.Exception.Message)") | Out-Null
                        }
                    }

                    # ==================== PATH EXITO ====================
                    if ($exitCode -eq 0) {
                        $successfulAttempt = $script:IsoCore_buildAttempts[$script:IsoCore_attemptIndex]
                        $script:IsoCore_cleanLogBuilder.AppendLine("") | Out-Null
                        $script:IsoCore_cleanLogBuilder.AppendLine("RESULTADO: CORRECTO EN PERFIL $($successfulAttempt.Name)") | Out-Null
                        Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: Compilacion completada correctamente con el perfil $($successfulAttempt.Name)."

                        $script:IsoCore_outputTransactionState = 'CREATED'
                        & $script:IsoCore_CleanupInjectedFiles
                        $btnCancel.Visible = $false
                        & $script:IsoCore_UpdateActionLayout
                        & $script:IsoCore_SetPhase "Calculando Hash SHA256 (esto puede tomar unos minutos)..." ([System.Drawing.Color]::Orange)

                        $script:IsoCore_hashRS = [runspacefactory]::CreateRunspace()
                        $script:IsoCore_hashRS.Open()
                        $script:IsoCore_hashRS.SessionStateProxy.SetVariable('isoPath', $script:IsoCore_iso)
                        $script:IsoCore_hashPS = [powershell]::Create()
                        $script:IsoCore_hashPS.Runspace = $script:IsoCore_hashRS
                        [void]$script:IsoCore_hashPS.AddScript({
                            try {
                                $sha256   = (Get-FileHash -LiteralPath $isoPath -Algorithm SHA256).Hash
                                $hashFile = [System.IO.Path]::ChangeExtension($isoPath, '.sha256')
                                $hashLine = "$sha256  $([System.IO.Path]::GetFileName($isoPath))`r`n"
                                [System.IO.File]::WriteAllText($hashFile, $hashLine, [System.Text.Encoding]::ASCII)
                                return $sha256
                            } catch {
                                return "ERROR: $($_.Exception.Message)"
                            }
                        })
                        $script:IsoCore_hashHandle = $script:IsoCore_hashPS.BeginInvoke()

                        $script:IsoCore_hashTimer          = New-Object System.Windows.Forms.Timer
                        $script:IsoCore_hashTimer.Interval = 200
                        $script:IsoCore_hashTimer.Add_Tick({
                            if ($null -eq $script:IsoCore_hashHandle -or $null -eq $script:IsoCore_hashPS) { return }
                            if (-not $script:IsoCore_hashHandle.IsCompleted) { return }

                            try {
                                if ($null -ne $script:IsoCore_hashTimer) {
                                    $script:IsoCore_hashTimer.Stop()
                                    $script:IsoCore_hashTimer.Dispose()
                                    $script:IsoCore_hashTimer = $null
                                }

                                $script:IsoCore_lastBuildHash = [string]($script:IsoCore_hashPS.EndInvoke($script:IsoCore_hashHandle) | Select-Object -First 1)
                                if ([string]::IsNullOrWhiteSpace($script:IsoCore_lastBuildHash)) {
                                    $script:IsoCore_lastBuildHash = 'ERROR: El calculo SHA-256 no devolvio ningun resultado.'
                                }
                            } catch {
                                $script:IsoCore_lastBuildHash = "ERROR: $($_.Exception.Message)"
                            } finally {
                                if ($null -ne $script:IsoCore_hashPS) { try { $script:IsoCore_hashPS.Dispose() } catch {} }
                                if ($null -ne $script:IsoCore_hashRS) { try { $script:IsoCore_hashRS.Close(); $script:IsoCore_hashRS.Dispose() } catch {} }
                                $script:IsoCore_hashPS = $null; $script:IsoCore_hashRS = $null; $script:IsoCore_hashHandle = $null
                            }

                            if ($script:IsoCore_lastBuildHash -and $script:IsoCore_lastBuildHash -notmatch '^ERROR') {
                                Write-IsoCoreLog -LogLevel ACTION -Message "IsoCore: SHA-256 calculado: $script:IsoCore_lastBuildHash"
                            } else {
                                Write-IsoCoreLog -LogLevel WARN -Message "IsoCore: Fallo el calculo del hash SHA-256: $script:IsoCore_lastBuildHash"
                            }

& $script:IsoCore_SetPhase 'Verificando estructura de la ISO generada...' ($uiCyan)
$script:IsoCore_verificationResult = & $script:IsoCore_TestIsoImage `
    -IsoPath $script:IsoCore_iso `
    -BootProfile $script:IsoCore_buildBootProfile `
    -RequireInstallImage ([bool]$script:IsoCore_requireInstallImage) `
    -ExpectedFiles @($script:IsoCore_expectedIsoFiles) `
    -ExpectedVolumeLabel $label
$script:IsoCore_cleanLogBuilder.AppendLine('') | Out-Null
$script:IsoCore_cleanLogBuilder.AppendLine('VALIDACION POST-BUILD:') | Out-Null
foreach($check in @($script:IsoCore_verificationResult.Checks)) {
    $script:IsoCore_cleanLogBuilder.AppendLine(" - $($check.Item): $(if($check.Present){'CORRECTO'}else{'FALTA'})") | Out-Null
}
if ($script:IsoCore_verificationResult.Errors.Count -gt 0) {
    foreach($verifyError in $script:IsoCore_verificationResult.Errors) { $script:IsoCore_cleanLogBuilder.AppendLine(" - ERROR: $verifyError") | Out-Null }
}
if ($script:IsoCore_verificationResult.Warnings.Count -gt 0) {
    foreach($verifyWarning in $script:IsoCore_verificationResult.Warnings) { $script:IsoCore_cleanLogBuilder.AppendLine(" - ADVERTENCIA: $verifyWarning") | Out-Null }
}

$hashOk = $script:IsoCore_lastBuildHash -and $script:IsoCore_lastBuildHash -notmatch '^ERROR'
if (-not $hashOk -or -not $script:IsoCore_verificationResult.Valid) {
    $reason = if (-not $hashOk) { "No se pudo completar SHA-256: $script:IsoCore_lastBuildHash" } else { $script:IsoCore_verificationResult.Errors -join ' | ' }
    Write-IsoCoreLog -LogLevel ERROR -Message "IsoCore: La ISO fue creada, pero no supero la fase VERIFIED: $reason"
    $script:IsoCore_lastBuildLog = $script:IsoCore_cleanLogBuilder.ToString()
    & $script:IsoCore_FinalizeIsoOutput $false
    & $script:IsoCore_SetPhase 'La ISO no supero la verificacion; se restauro la salida anterior.' ([System.Drawing.Color]::Crimson)
    [System.Windows.Forms.MessageBox]::Show(
        "La compilacion termino, pero la ISO no supero la verificacion final.`n`n$reason`n`nLa ISO parcial se elimino y se restauro la version anterior cuando existia.",
        'Verificacion ISO fallida', 'OK', 'Error'
    ) | Out-Null
    & $script:IsoCore_DisposeIsoProcess $false
    & $script:IsoCore_RestoreCompileUI
    return
}
$script:IsoCore_outputTransactionState = 'VERIFIED'
& $script:IsoCore_FinalizeIsoOutput $true
$script:IsoCore_outputTransactionState = 'COMMITTED'
Write-IsoCoreLog -LogLevel ACTION -Message 'IsoCore: ISO verificada y transaccion de salida confirmada (COMMITTED).'

                            $fullLogText = $script:IsoCore_cleanLogBuilder.ToString()

                            # ==============================================================================
                            # LIMPIEZA DE LOG (OSCDIMG)
                            # ==============================================================================
                            # 1. Agrupar la cabecera: Unir "Premastering Utility" con "Copyright"
                            $fullLogText = $fullLogText -replace "(?im)(Premastering Utility)\s+(Copyright)", "`$1`r`n`$2"

                            # 2. Agrupar las líneas de "Scanning source tree" (absorbiendo espacios invisibles finales)
                            $fullLogText = [regex]::Replace($fullLogText, '(?im)(Scanning source tree[^\r\n]*)\r?\n\s*(Scanning source tree complete)', "`$1`r`n`$2")

                            # 3. Agrupar las líneas de "Computing directory information"
                            $fullLogText = [regex]::Replace($fullLogText, '(?im)(Computing directory information[^\r\n]*)\r?\n\s*(Computing directory information complete)', "`$1`r`n`$2")
							
                            # 4. Fijar estrictamente el espaciado alrededor del porcentaje.
                            $fullLogText = [regex]::Replace($fullLogText, '(?im)\s*(100% complete)\s+', "`r`n`r`n`$1`r`n`r`n")

                            # 5. Reducir cualquier exceso de saltos de línea (3 o más) a exactamente una línea en blanco (\r\n\r\n) en el resto del documento
                            $fullLogText = [regex]::Replace($fullLogText, '(\r?\n){3,}', "`r`n`r`n")

                            # 6. (Opcional) Restaurar un salto doble para separar el comando de la cabecera oscdimg
                            $fullLogText = $fullLogText -replace "----------------\r?\nOSCDIMG", "----------------`r`n`r`nOSCDIMG"

                            $script:IsoCore_lastBuildLog = $fullLogText

                            try {
                                $timestamp   = Get-Date -Format "yyyyMMdd_HHmmss"
                                $logFileName = "ISO_Build_$timestamp.log"
                                if ($null -ne $script:IsoCore_logDir) {
                                    $logPath = Join-Path $script:IsoCore_logDir $logFileName
                                    $fullLogText | Out-File -FilePath $logPath -Encoding utf8 -Force
                                    Write-IsoCoreLog -LogLevel ACTION -Message "IsoCore: Log de compilacion guardado en: $logPath"
                                }
                            } catch {}

                            $rxOptsCI  = [System.Text.RegularExpressions.RegexOptions]::Compiled -bor
                                         [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
                            $mScanFull = [regex]::Match($fullLogText, 'Scanning source tree complete \((\d+) files in (\d+) directories\)', $rxOptsCI)
                            $mImgBefor = [regex]::Match($fullLogText, 'Image file is (\d+) bytes',                                          $rxOptsCI)
                            $mOptSaved = [regex]::Match($fullLogText, '(Storage optimization saved [^\r\n]+)',                               $rxOptsCI)
                            $mImgAfter = [regex]::Match($fullLogText, 'After optimization, image file is (\d+) bytes',                      $rxOptsCI)
                            $mSpcSaved = [regex]::Match($fullLogText, 'Space saved.*?=\s*(\d+)',                                             $rxOptsCI)

                            $cFiles  = if ($mScanFull.Success) { $mScanFull.Groups[1].Value } else { "0" }
                            $cDirs   = if ($mScanFull.Success) { $mScanFull.Groups[2].Value } else { "0" }
                            $bBefore = if ($mImgBefor.Success) { [long]$mImgBefor.Groups[1].Value } else { 0 }
                            $bAfter  = if ($mImgAfter.Success) { [long]$mImgAfter.Groups[1].Value } else { 0 }
                            $bSaved  = if ($mSpcSaved.Success) { [long]$mSpcSaved.Groups[1].Value } else { 0 }

                            $fmt = { param($b) if ($b -ge 1GB) { "$([math]::Round($b/1GB,2)) GB" } elseif ($b -ge 1MB) { "$([math]::Round($b/1MB,2)) MB" } else { "$b bytes" } }
                            $strBefore = & $fmt $bBefore
                            $strAfter  = & $fmt $bAfter
                            $strSaved  = & $fmt $bSaved

                            $btnExportLog.Enabled   = $true
                            $btnExportLog.ForeColor = [System.Drawing.Color]::Silver
                            & $script:IsoCore_SetPhase "ISO creada exitosamente en: $script:IsoCore_iso" ($uiGreen)
                            $btnOpenFolder.Visible = $true

                            $lblFileInfo.Text = if ($mOptSaved.Success) {
                                "$cFiles archivos | $cDirs directorios | Optimizacion: $($mOptSaved.Groups[1].Value.Replace('Storage optimization saved ',''))"
                            } else {
                                "$cFiles archivos | $cDirs directorios"
                            }
                            if ($bAfter -gt 0) { $lblSizeInfo.Text = "Tamaño final: $strAfter ($bAfter bytes)" }

                            if ($script:IsoCore_lastBuildHash -and $script:IsoCore_lastBuildHash -notmatch '^ERROR') {
                                $lblHashInfo.Text      = "SHA-256:`n$script:IsoCore_lastBuildHash"
                                $lblHashInfo.ForeColor = $uiGreen
                            } else {
                                $lblHashInfo.Text      = "SHA-256: Error al calcular"
                                $lblHashInfo.ForeColor = [System.Drawing.Color]::Orange
                            }

                            $form.Refresh()

                            Write-IsoCoreLog -LogLevel ACTION -Message "IsoCore: ISO generada exitosamente. Archivos: $cFiles | Tamaño final: $strAfter | Espacio ahorrado: $strSaved | Destino: $script:IsoCore_iso"

                            $msgSummary  = "La imagen ISO se ha compilado exitosamente.`n`n"
                            $msgSummary += "ESTADISTICAS DE COMPILACION:`n"
                            $msgSummary += "-------------------------------------------------------------`n"
                            $msgSummary += " Archivos inyectados  : $cFiles (en $cDirs carpetas)`n"
                            $msgSummary += " Tamaño original      : $strBefore`n"
                            $msgSummary += " Tamaño optimizado    : $strAfter`n"
                            $msgSummary += " Espacio ahorrado     : $strSaved`n"
                            $msgSummary += "-------------------------------------------------------------`n`n"
                            $msgSummary += "Ruta de la imagen:`n$script:IsoCore_iso"
                            $msgSummary += "`n`nValidacion post-build: CORRECTA"
                            if ($script:IsoCore_verificationResult.Warnings.Count -gt 0) {
                                $msgSummary += "`nAdvertencias:`n" + (($script:IsoCore_verificationResult.Warnings | ForEach-Object { " - $_" }) -join "`n")
                            }
                            if ($script:IsoCore_lastBuildHash -and $script:IsoCore_lastBuildHash -notmatch '^ERROR') {
                                $msgSummary += "`n`nSHA-256:`n$script:IsoCore_lastBuildHash"
                            }
                            [System.Windows.Forms.MessageBox]::Show($msgSummary, "ISO Creada con Exito", 'OK', 'Information')

                            & $script:IsoCore_CleanupInjectedFiles

                            & $script:IsoCore_DisposeIsoProcess $false

                            & $script:IsoCore_RestoreCompileUI
                        })
                        $script:IsoCore_hashTimer.Start()

                    # ==================== PATH ERROR ====================
                    } else {
                        $script:IsoCore_cleanLogBuilder.AppendLine("`r`n=== ERRORES REPORTADOS ===") | Out-Null
                        $script:IsoCore_cleanLogBuilder.AppendLine($script:IsoCore_errLogBuilder.ToString()) | Out-Null
                        $script:IsoCore_lastBuildLog = $script:IsoCore_cleanLogBuilder.ToString()

                        $finalDiagnosticText = $script:IsoCore_errLogBuilder.ToString().Trim()
                        if ([string]::IsNullOrWhiteSpace($finalDiagnosticText)) {
                            $finalDiagnosticText = $script:IsoCore_attemptOutLogBuilder.ToString().Trim()
                        }
                        $errorLines = @(
                            $finalDiagnosticText -split "`r?`n" |
                            Where-Object {
                                -not [string]::IsNullOrWhiteSpace($_) -and
                                $_.Trim() -notmatch '^\d+%\s+complete$'
                            } |
                            Select-Object -First 8
                        )
                        $errorSummary = if ($errorLines.Count -gt 0) { $errorLines -join ' | ' } else { 'oscdimg no devolvio texto de error.' }
                        Write-IsoCoreLog -LogLevel ERROR -Message "IsoCore: Fallo la compilacion. Codigo de salida $exitCode. Detalle: $errorSummary"

                        try {
                            if ($script:IsoCore_logDir) {
                                $failureStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
                                $failureLog = Join-Path $script:IsoCore_logDir "ISO_Build_ERROR_$failureStamp.log"
                                [System.IO.File]::WriteAllText($failureLog, $script:IsoCore_lastBuildLog, ([System.Text.UTF8Encoding]::new($true)))
                                Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: Log detallado del fallo guardado automaticamente en: $failureLog"
                            }
                        } catch {
                            Write-IsoCoreLog -LogLevel WARN -Message "IsoCore: No se pudo guardar automaticamente el log detallado del fallo: $($_.Exception.Message)"
                        }
                        $pbMain.Value    = 0
                        $lblPercent.Text = "Error (Codigo: $exitCode)"
                        $lblPercent.Refresh()
                        & $script:IsoCore_SetPhase "Fallo la compilacion. Codigo: $exitCode" ([System.Drawing.Color]::Crimson)
                        [System.Windows.Forms.MessageBox]::Show(
                            "Fallo la creacion de la ISO despues de probar todos los perfiles compatibles.`n`nCodigo de salida: $exitCode`nDetalle: $errorSummary`n`nEl log detallado se guardo automaticamente en la carpeta Logs.",
                            "Error de compilacion",
                            'OK',
                            'Error'
                        )

                        & $script:IsoCore_CleanupInjectedFiles
                        & $script:IsoCore_FinalizeIsoOutput $false
                        & $script:IsoCore_DisposeIsoProcess $true
                        $btnExportLog.Enabled = $true

                        & $script:IsoCore_RestoreCompileUI
                    }

                } catch {
                    Write-IsoCoreLog -LogLevel ERROR -Message "IsoCore: Error critico en el bucle de actualizacion de progreso: $($_.Exception.Message)"
                    if ($null -ne $script:IsoCore_pollTimer) {
                        try { $script:IsoCore_pollTimer.Stop(); $script:IsoCore_pollTimer.Dispose() } catch {}
                        $script:IsoCore_pollTimer = $null
                    }
                    if ($null -ne $script:IsoCore_buildDone) {
                        try { $script:IsoCore_buildDone.Dispose() } catch {}
                        $script:IsoCore_buildDone = $null
                    }
                    & $script:IsoCore_DisposeIsoProcess $true
                    & $script:IsoCore_CleanupInjectedFiles
                    & $script:IsoCore_FinalizeIsoOutput $false
                    Write-Warning "pollTimer encontro un error critico: $($_.Exception.Message)`nStack: $($_.Exception.StackTrace)"
                    & $script:IsoCore_RestoreCompileUI
                }
            }

            $script:IsoCore_pollTimer.Add_Tick($pollTickScript)
            $script:IsoCore_pollTimer.Start()

        } catch {
            Write-IsoCoreLog -LogLevel ERROR -Message "IsoCore: Excepcion no controlada en el motor de compilacion: $($_.Exception.Message)"
            & $script:IsoCore_SetPhase "Excepcion: $($_.Exception.Message)" ([System.Drawing.Color]::Crimson)
            [System.Windows.Forms.MessageBox]::Show("Excepcion: $_", "Crash", 'OK', 'Error')

            if ($null -ne $script:IsoCore_pollTimer) {
                try { $script:IsoCore_pollTimer.Stop(); $script:IsoCore_pollTimer.Dispose() } catch {}
                $script:IsoCore_pollTimer = $null
            }
            if ($null -ne $script:IsoCore_buildDone) {
                try { $script:IsoCore_buildDone.Dispose() } catch {}
                $script:IsoCore_buildDone = $null
            }
            & $script:IsoCore_DisposeIsoProcess $true
            & $script:IsoCore_CleanupInjectedFiles
            & $script:IsoCore_FinalizeIsoOutput $false
            & $script:IsoCore_RestoreCompileUI
        }
    })

    # ------------------------------------------------------------------
    # 7. Botones de accion post-build
    # ------------------------------------------------------------------
    $btnExportLog.Add_Click({
        if (-not $script:IsoCore_lastBuildLog) {
            [System.Windows.Forms.MessageBox]::Show("No hay ningun log de compilacion disponible aun.`nRealiza una compilacion primero.", "Sin Log", 'OK', 'Information')
            return
        }
        $sfd          = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.Filter   = "Archivo de Log (*.txt)|*.txt|Todos los archivos (*.*)|*.*"
        $sfd.FileName = "IsoCore_Build_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
        if ($sfd.ShowDialog() -eq 'OK') {
            try {
                $script:IsoCore_lastBuildLog | Out-File -FilePath $sfd.FileName -Encoding utf8 -Force
                Write-IsoCoreLog -LogLevel ACTION -Message "IsoCore: Log exportado manualmente a: $($sfd.FileName)"
                [System.Windows.Forms.MessageBox]::Show("Log exportado correctamente en:`n$($sfd.FileName)", "Log Exportado", 'OK', 'Information')
            } catch {
                [System.Windows.Forms.MessageBox]::Show("Error al exportar el log:`n$($_.Exception.Message)", "Error", 'OK', 'Error')
            }
        }
    })

    $btnOpenFolder.Add_Click({
        $target = if ($script:IsoCore_iso) { Split-Path -Parent $script:IsoCore_iso } else { $null }
        if ($target -and (Test-Path -LiteralPath $target)) {
            Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: El usuario abrio la carpeta de destino: $target"
            Invoke-Item -LiteralPath $target
        } else {
            [System.Windows.Forms.MessageBox]::Show("No se pudo determinar la carpeta de destino.", "Error", 'OK', 'Warning')
        }
    })

    $form.Add_FormClosing({
        param($sender, $e)

        # El visor finaliza la consulta actual y libera su montaje antes de cerrar.
        if ($null -ne $imageInfoState.Page -and $null -ne $imageInfoState.Page.Tag -and
            $null -ne $imageInfoState.Page.Tag.CanClose) {
            if (-not (& $imageInfoState.Page.Tag.CanClose)) {
                $e.Cancel = $true
                $tabControl.SelectedTab = $imageInfoState.Page
                return
            }
        }

        # Cleanup incondicional: runspaces de analisis en background (DISM y Tamaño)
        foreach ($t in @($script:IsoCore_sizeTimer, $script:IsoCore_dismTimer)) {
            if ($null -ne $t) { try { $t.Stop(); $t.Dispose() } catch {} }
        }
        foreach ($p in @($script:IsoCore_sizePS, $script:IsoCore_dismPS)) {
            if ($null -ne $p) { try { $p.Stop(); $p.Dispose() } catch {} }
        }
        foreach ($r in @($script:IsoCore_sizeRS, $script:IsoCore_dismRS)) {
            if ($null -ne $r) { try { $r.Close(); $r.Dispose() } catch {} }
        }
        $script:IsoCore_sizeTimer = $null; $script:IsoCore_dismTimer = $null
        $script:IsoCore_sizePS    = $null; $script:IsoCore_dismPS    = $null
        $script:IsoCore_sizeRS    = $null; $script:IsoCore_dismRS    = $null

        # Si hay compilacion activa, pedir confirmacion antes de abortar
        if ($null -ne $script:IsoCore_isoProc -and -not $script:IsoCore_isoProc.HasExited) {
            $res = [System.Windows.Forms.MessageBox]::Show(
                "La ISO se esta compilando en este momento.`nSi sales ahora, la operacion se cancelara, se eliminara la salida parcial y se restaurara la version anterior cuando corresponda.`n`n¿Deseas forzar la salida?",
                "Advertencia de Interrupcion",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($res -eq 'No') {
                $e.Cancel = $true
            } else {
                Write-IsoCoreLog -LogLevel WARN -Message "IsoCore: El usuario forzo el cierre de la aplicacion durante la compilacion."

                if ($null -ne $script:IsoCore_pollTimer) {
                    try { $script:IsoCore_pollTimer.Stop(); $script:IsoCore_pollTimer.Dispose() } catch {}
                    $script:IsoCore_pollTimer = $null
                }
                if ($null -ne $script:IsoCore_hashTimer) {
                    try { $script:IsoCore_hashTimer.Stop(); $script:IsoCore_hashTimer.Dispose() } catch {}
                    $script:IsoCore_hashTimer = $null   # [FIX C2] Evitar ObjectDisposedException si el tick dispara post-cierre
                }
                if ($null -ne $script:IsoCore_buildDone) {
                    try { $script:IsoCore_buildDone.Dispose() } catch {}
                    $script:IsoCore_buildDone = $null
                }
                if ($null -ne $script:IsoCore_hashPS) { try { $script:IsoCore_hashPS.Stop(); $script:IsoCore_hashPS.Dispose() } catch {}; $script:IsoCore_hashPS = $null }
                if ($null -ne $script:IsoCore_hashRS) { try { $script:IsoCore_hashRS.Close(); $script:IsoCore_hashRS.Dispose() } catch {}; $script:IsoCore_hashRS = $null }

                & $script:IsoCore_DisposeIsoProcess $true
                [void](& $script:IsoCore_CaptureInterruptedBuildLog 'INTERRUMPIDO POR CIERRE FORZADO' 'ISO_Build_INTERRUPTED')
                $script:IsoCore_outQueue = $null
                $script:IsoCore_errQueue = $null
                & $script:IsoCore_CleanupInjectedFiles
                & $script:IsoCore_FinalizeIsoOutput $false
            }
        }
        if (-not $e.Cancel) {
            # El hash se ejecuta despues de que oscdimg termina; por eso debe limpiarse
            # incluso cuando ya no existe un proceso de compilacion activo.
            if ($null -ne $script:IsoCore_hashTimer) {
                try { $script:IsoCore_hashTimer.Stop(); $script:IsoCore_hashTimer.Dispose() } catch {}
                $script:IsoCore_hashTimer = $null
            }
            if ($null -ne $script:IsoCore_hashPS) { try { $script:IsoCore_hashPS.Stop(); $script:IsoCore_hashPS.Dispose() } catch {}; $script:IsoCore_hashPS = $null }
            if ($null -ne $script:IsoCore_hashRS) { try { $script:IsoCore_hashRS.Close(); $script:IsoCore_hashRS.Dispose() } catch {}; $script:IsoCore_hashRS = $null }
            $script:IsoCore_hashHandle = $null

            if ($null -ne $script:IsoCore_pollTimer) {
                try { $script:IsoCore_pollTimer.Stop(); $script:IsoCore_pollTimer.Dispose() } catch {}
                $script:IsoCore_pollTimer = $null
            }
            if ($null -ne $script:IsoCore_buildDone) {
                try { $script:IsoCore_buildDone.Dispose() } catch {}
                $script:IsoCore_buildDone = $null
            }

            & $script:IsoCore_DisposeIsoProcess $false
            & $script:IsoCore_CleanupInjectedFiles
            & $script:IsoCore_FinalizeIsoOutput $false

            # Liberar ToolTip solo cuando el cierre realmente continuara.
            if ($null -ne $tip -and -not $tip.IsDisposed) { try { $tip.Dispose() } catch {} }
            Write-IsoCoreLog -LogLevel INFO -Message "IsoCore: Sesion finalizada. Formulario cerrado por el usuario."
        }
    })

    # ------------------------------------------------------------------
    # 9. Mostrar y limpiar
    # ------------------------------------------------------------------
    try {
        $form.ShowDialog() | Out-Null
    } finally {
        # Se limpia al terminar ShowDialog, nunca si el usuario cancela el cierre.
        if ($null -ne $imageInfoState.Page -and $null -ne $imageInfoState.Page.Tag) {
            try { & $imageInfoState.Page.Tag.Cleanup } catch {
                Write-IsoCoreLog -LogLevel WARN -Message "IsoCore: error cerrando el visor WIM/ESD: $($_.Exception.Message)"
            }
        }
        $form.Dispose()
        $imageInfoPlaceholder.Dispose()
    }
    [GC]::Collect()
}

try {
    Show-IsoCoreGUI
} catch {
    $startupError = $_.Exception.Message
    Write-IsoCoreLog -LogLevel ERROR -Message "IsoCore: Error fatal durante el inicio: $startupError | $($_.ScriptStackTrace)"
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show(
            "IsoCore no pudo iniciar.`n`nDetalle:`n$startupError`n`nRevisa el archivo Logs\Registro.log para obtener mas informacion.",
            "IsoCore - Error de inicio",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    } catch {
        Write-Error "IsoCore no pudo iniciar: $startupError"
    }
}
}

try {
    Invoke-IsoCoreInternal
} finally {
    Remove-Item -Path Function:\Invoke-IsoCoreInternal -ErrorAction SilentlyContinue
}
