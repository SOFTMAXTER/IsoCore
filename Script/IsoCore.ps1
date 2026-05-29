# ==============================================================================
#   ___           ____               
#  |_ _|___  ___ / ___|___  _ __ ___ 
#   | |/ __|/ _ \ |   / _ \| '__/ _ \
#   | |\__ \ (_) | |__| (_) | | |  __/
#  |___|___/\___/ \____\___/|_|  \___|
#                                     
#  IsoCore v1.0.0
#  Author: SOFTMAXTER
#
#  DESCRIPTION:
#  Generador de imagenes ISO booteables (BIOS/UEFI) con integracion de
#  automatizacion OOBE (Unattend.xml) e inyeccion de paquetes MRP.
#
# ==============================================================================
# Copyright (C) 2026 SOFTMAXTER
# ==============================================================================

$script:Version = "1.0.0"

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('INFO', 'ACTION', 'WARN', 'ERROR')]
        [string]$LogLevel,

        [Parameter(Mandatory=$true)]
        [string]$Message
    )

    if (-not $script:logFile) { return }

    try {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "[$timestamp] [$LogLevel] - $Message" | Out-File -FilePath $script:logFile -Append -Encoding utf8
    }
    catch {
        Write-Warning "No se pudo escribir en el archivo de log: $_"
    }
}

# 1. Verificacion de permisos de Administrador
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Este script necesita ser ejecutado como Administrador para evitar errores de lectura/escritura."
    Write-Host "Cierra esta ventana, haz clic derecho en el script y selecciona 'Ejecutar con PowerShell como Administrador'."
    Pause
    exit
}

# 2. Inicializacion del sistema de Logs
try {
    $scriptRoot    = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
    $parentDir     = Split-Path -Parent $scriptRoot
    $script:logDir = Join-Path -Path $parentDir -ChildPath "Logs"

    if (-not (Test-Path $script:logDir)) {
        New-Item -Path $script:logDir -ItemType Directory -Force | Out-Null
    }

    $script:logFile = Join-Path -Path $script:logDir -ChildPath "Registro.log"
    $maxLogSizeMB   = 1

    if (Test-Path -LiteralPath $script:logFile) {
        $logItem = Get-Item -LiteralPath $script:logFile
        if ($logItem.Length -gt ($maxLogSizeMB * 1MB)) {
            Write-Host "Realizando mantenimiento del archivo de Log..." -ForegroundColor Gray
            $oldLogFile = Join-Path -Path $script:logDir -ChildPath "Registro_old.log"
            Move-Item -LiteralPath $script:logFile -Destination $oldLogFile -Force
        }
    }
} catch {
    Write-Warning "No se pudo crear el directorio de Logs. El registro de eventos se desactivara. Error: $_"
    $script:logFile = $null
}

Write-Log -LogLevel INFO -Message "================================================="
Write-Log -LogLevel INFO -Message "IsoCore v$($script:Version) iniciado en modo Administrador."

function Show-IsoMaker-GUI {

    Write-Log -LogLevel INFO -Message "IsoCore: Iniciando interfaz grafica del generador ISO."

    # ------------------------------------------------------------------
    # 1. Busqueda de oscdimg.exe
    # ------------------------------------------------------------------
    $scriptPath = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }

    $adkPaths = @(
        "$scriptPath\Tools\oscdimg.exe",
        "$scriptPath\..\Tools\oscdimg.exe",
        "${env:ProgramFiles(x86)}\Windows Kits\11\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    )

    $oscdimgExe = $null
    foreach ($path in $adkPaths) {
        if (Test-Path $path) { $oscdimgExe = $path; break }
    }

    if (-not $oscdimgExe) {
        $cmd = Get-Command "oscdimg.exe" -ErrorAction SilentlyContinue
        if ($cmd) { $oscdimgExe = $cmd.Source }
    }

    if (-not $oscdimgExe) {
        Write-Log -LogLevel WARN -Message "IsoCore: oscdimg.exe no encontrado en rutas estandar. Solicitando ubicacion manual..."

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
                Write-Log -LogLevel INFO -Message "IsoCore: oscdimg.exe localizado manualmente por el usuario en: $oscdimgExe"
            } else {
                Write-Log -LogLevel WARN -Message "IsoCore: El usuario cancelo el cuadro de dialogo de busqueda manual. Saliendo."
                return
            }
        } else {
            Write-Log -LogLevel ERROR -Message "IsoCore: Dependencia faltante. El usuario declino buscar oscdimg.exe. Saliendo."
            $msg = "Para utilizar el Generador de ISO, es un requisito estricto contar con 'oscdimg.exe'.`n`n" +
                   "Por favor, descarga e instala el Windows Assessment and Deployment Kit (ADK)."
            [System.Windows.Forms.MessageBox]::Show($msg, "Requisito Faltante: Windows ADK", 'OK', 'Error')
            return
        }
    }

    # [F4] Leer version del ejecutable oscdimg desde su PE header.
    # Permite mostrar exactamente que build del ADK esta en uso (ADK 10 vs ADK 11
    # tienen comportamientos distintos en algunos edge cases de UDF).
    $oscdimgVerStr = ""
    try {
        $vi = (Get-Item -LiteralPath $oscdimgExe).VersionInfo
        $oscdimgVerStr = "$($vi.FileMajorPart).$($vi.FileMinorPart).$($vi.FileBuildPart).$($vi.FilePrivatePart)"
        Write-Log -LogLevel INFO -Message "IsoCore: oscdimg.exe encontrado — version $oscdimgVerStr — ruta: $oscdimgExe"
    } catch {
        Write-Log -LogLevel WARN -Message "IsoCore: No se pudo leer la version del PE de oscdimg.exe."
    }

    # ------------------------------------------------------------------
    # 2. Cargar assemblies GUI
    # ------------------------------------------------------------------
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $chkMRP  = $null
    $picCD   = $null
    $cdTimer = $null

    # ------------------------------------------------------------------
    # 3. Construccion del formulario
    # ------------------------------------------------------------------
    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = "IsoCore v$($script:Version) by SOFTMAXTER"
    $form.Size            = New-Object System.Drawing.Size(930, 590)
    $form.StartPosition   = "CenterScreen"
    $form.BackColor       = [System.Drawing.Color]::FromArgb(18, 22, 28)
    $form.ForeColor       = [System.Drawing.Color]::Silver
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox     = $false

    # --- Header ---
    $lblHeaderTitle           = New-Object System.Windows.Forms.Label
    $lblHeaderTitle.Text      = "IsoCore"
    $lblHeaderTitle.Font      = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
    $lblHeaderTitle.ForeColor = [System.Drawing.Color]::FromArgb(64, 196, 255)
    $lblHeaderTitle.Location  = "15, 10"
    $lblHeaderTitle.AutoSize  = $true
    $form.Controls.Add($lblHeaderTitle)

    $lblHeaderSub           = New-Object System.Windows.Forms.Label
    $lblHeaderSub.Text      = "• Creación de Medios de Instalación Windows BIOS/UEFI"
    $lblHeaderSub.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
    $lblHeaderSub.ForeColor = [System.Drawing.Color]::Gray
    $lblHeaderSub.Location  = "105, 18"
    $lblHeaderSub.AutoSize  = $true
    $form.Controls.Add($lblHeaderSub)

    # ================= COLUMNA IZQUIERDA =================

    # --- 1. CONFIGURACION DE IMAGEN ---
    $grpCfg           = New-Object System.Windows.Forms.GroupBox
    $grpCfg.Text      = " CONFIGURACION DE IMAGEN "
    $grpCfg.Location  = "15, 50"
    $grpCfg.Size      = "450, 160"
    $grpCfg.ForeColor = [System.Drawing.Color]::FromArgb(64, 196, 255)
    $form.Controls.Add($grpCfg)

    $lblSrc           = New-Object System.Windows.Forms.Label
    $lblSrc.Text      = "CARPETA ORIGEN (boot, efi, sources...)"
    $lblSrc.Location  = "15, 25"
    $lblSrc.AutoSize  = $true
    $lblSrc.ForeColor = [System.Drawing.Color]::DarkGray
    $grpCfg.Controls.Add($lblSrc)

    $txtSrc             = New-Object System.Windows.Forms.TextBox
    $txtSrc.Location    = "15, 45"
    $txtSrc.Size        = "340, 23"
    $txtSrc.BackColor   = [System.Drawing.Color]::FromArgb(30, 35, 40)
    $txtSrc.ForeColor   = [System.Drawing.Color]::White
    $txtSrc.BorderStyle = "FixedSingle"
    $grpCfg.Controls.Add($txtSrc)

    $btnSrc                           = New-Object System.Windows.Forms.Button
    $btnSrc.Text                      = "Explorar..."
    $btnSrc.Location                  = "365, 44"
    $btnSrc.Size                      = "75, 25"
    $btnSrc.BackColor                 = [System.Drawing.Color]::FromArgb(64, 196, 255)
    $btnSrc.ForeColor                 = [System.Drawing.Color]::Black
    $btnSrc.FlatStyle                 = "Flat"
    $btnSrc.FlatAppearance.BorderSize = 0
    $grpCfg.Controls.Add($btnSrc)

    $lblDst           = New-Object System.Windows.Forms.Label
    $lblDst.Text      = "ARCHIVO ISO DESTINO"
    $lblDst.Location  = "15, 75"
    $lblDst.AutoSize  = $true
    $lblDst.ForeColor = [System.Drawing.Color]::DarkGray
    $grpCfg.Controls.Add($lblDst)

    $txtDst             = New-Object System.Windows.Forms.TextBox
    $txtDst.Location    = "15, 95"
    $txtDst.Size        = "340, 23"
    $txtDst.BackColor   = [System.Drawing.Color]::FromArgb(30, 35, 40)
    $txtDst.ForeColor   = [System.Drawing.Color]::White
    $txtDst.BorderStyle = "FixedSingle"
    $grpCfg.Controls.Add($txtDst)

    $btnDst                           = New-Object System.Windows.Forms.Button
    $btnDst.Text                      = "Guardar"
    $btnDst.Location                  = "365, 94"
    $btnDst.Size                      = "75, 25"
    $btnDst.BackColor                 = [System.Drawing.Color]::FromArgb(60, 65, 70)
    $btnDst.ForeColor                 = [System.Drawing.Color]::White
    $btnDst.FlatStyle                 = "Flat"
    $btnDst.FlatAppearance.BorderSize = 0
    $grpCfg.Controls.Add($btnDst)

    $lblLabel           = New-Object System.Windows.Forms.Label
    $lblLabel.Text      = "ETIQUETA DE VOLUMEN:"
    $lblLabel.Location  = "15, 130"
    $lblLabel.AutoSize  = $true
    $lblLabel.ForeColor = [System.Drawing.Color]::DarkGray
    $grpCfg.Controls.Add($lblLabel)

    $txtLabel             = New-Object System.Windows.Forms.TextBox
    $txtLabel.Location    = "165, 127"
    $txtLabel.Size        = "275, 23"
    $txtLabel.Text        = "WINDOWS_CUSTOM"
    $txtLabel.BackColor   = [System.Drawing.Color]::FromArgb(30, 35, 40)
    $txtLabel.ForeColor   = [System.Drawing.Color]::White
    $txtLabel.BorderStyle = "FixedSingle"
    $grpCfg.Controls.Add($txtLabel)

    # --- 2. AUTOMATIZACION OOBE ---
    $grpAuto           = New-Object System.Windows.Forms.GroupBox
    $grpAuto.Text      = " AUTOMATIZACION OOBE (Opcional) "
    $grpAuto.Location  = "15, 220"
    $grpAuto.Size      = "450, 120"
    $grpAuto.ForeColor = [System.Drawing.Color]::FromArgb(255, 140, 0)
    $form.Controls.Add($grpAuto)

    $lblAutoInfo           = New-Object System.Windows.Forms.Label
    $lblAutoInfo.Text      = "INYECTAR autounattend.xml EN LA RAIZ DEL MEDIO"
    $lblAutoInfo.Location  = "15, 25"
    $lblAutoInfo.AutoSize  = $true
    $lblAutoInfo.ForeColor = [System.Drawing.Color]::DarkGray
    $grpAuto.Controls.Add($lblAutoInfo)

    $txtUnattend             = New-Object System.Windows.Forms.TextBox
    $txtUnattend.Location    = "15, 45"
    $txtUnattend.Size        = "340, 23"
    $txtUnattend.BackColor   = [System.Drawing.Color]::FromArgb(30, 35, 40)
    $txtUnattend.ForeColor   = [System.Drawing.Color]::White
    $txtUnattend.BorderStyle = "FixedSingle"
    $grpAuto.Controls.Add($txtUnattend)

    $btnUnattend                           = New-Object System.Windows.Forms.Button
    $btnUnattend.Text                      = "XML..."
    $btnUnattend.Location                  = "365, 44"
    $btnUnattend.Size                      = "75, 25"
    $btnUnattend.BackColor                 = [System.Drawing.Color]::FromArgb(160, 80, 20)
    $btnUnattend.ForeColor                 = [System.Drawing.Color]::White
    $btnUnattend.FlatStyle                 = "Flat"
    $btnUnattend.FlatAppearance.BorderSize = 0
    $grpAuto.Controls.Add($btnUnattend)

    $lnkWeb                 = New-Object System.Windows.Forms.LinkLabel
    $lnkWeb.Text            = "Generador online — schneegans.de"
    $lnkWeb.Location        = "15, 75"
    $lnkWeb.AutoSize        = $true
    $lnkWeb.LinkColor       = [System.Drawing.Color]::Gray
    $lnkWeb.ActiveLinkColor = [System.Drawing.Color]::White
    $grpAuto.Controls.Add($lnkWeb)

    $chkMRP           = New-Object System.Windows.Forms.CheckBox
    $chkMRP.Text      = "Inyectar Multi OEM/Retail Project (MRP) en ISO\sources"
    $chkMRP.Location  = "15, 95"
    $chkMRP.AutoSize  = $true
    $chkMRP.ForeColor = [System.Drawing.Color]::DarkGray
    $grpAuto.Controls.Add($chkMRP)

    # --- 3. VALIDACION DE ORIGEN ---
    $grpVal           = New-Object System.Windows.Forms.GroupBox
    $grpVal.Text      = " VALIDACION DE ORIGEN "
    $grpVal.Location  = "15, 350"
    $grpVal.Size      = "450, 85"
    $grpVal.ForeColor = [System.Drawing.Color]::FromArgb(90, 160, 180)
    $form.Controls.Add($grpVal)

    $lblValBoot           = New-Object System.Windows.Forms.Label
    $lblValBoot.Text      = "• boot\etfsboot.com"
    $lblValBoot.Location  = "10, 25"
    $lblValBoot.Size      = "145, 18"
    $lblValBoot.ForeColor = [System.Drawing.Color]::Gray
    $lblValBoot.Font      = New-Object System.Drawing.Font("Consolas", 8)
    $grpVal.Controls.Add($lblValBoot)

    $lblValEfi           = New-Object System.Windows.Forms.Label
    $lblValEfi.Text      = "• efisys.bin (UEFI)"
    $lblValEfi.Location  = "155, 25"
    $lblValEfi.Size      = "145, 18"
    $lblValEfi.ForeColor = [System.Drawing.Color]::Gray
    $lblValEfi.Font      = New-Object System.Drawing.Font("Consolas", 8)
    $grpVal.Controls.Add($lblValEfi)

    $lblValWim           = New-Object System.Windows.Forms.Label
    $lblValWim.Text      = "• sources\install.*"
    $lblValWim.Location  = "300, 25"
    $lblValWim.Size      = "140, 18"
    $lblValWim.ForeColor = [System.Drawing.Color]::Gray
    $lblValWim.Font      = New-Object System.Drawing.Font("Consolas", 8)
    $grpVal.Controls.Add($lblValWim)

    $lblValSpace           = New-Object System.Windows.Forms.Label
    $lblValSpace.Text      = "• Espacio libre en destino: (Esperando...)"
    $lblValSpace.Location  = "10, 45"
    $lblValSpace.Size      = "430, 16"
    $lblValSpace.ForeColor = [System.Drawing.Color]::Gray
    $lblValSpace.Font      = New-Object System.Drawing.Font("Consolas", 8)
    $grpVal.Controls.Add($lblValSpace)

    $lblValSrcSize           = New-Object System.Windows.Forms.Label
    $lblValSrcSize.Text      = "• Tamaño carpeta origen: (Esperando...)"
    $lblValSrcSize.Location  = "10, 62"
    $lblValSrcSize.Size      = "430, 16"
    $lblValSrcSize.ForeColor = [System.Drawing.Color]::Gray
    $lblValSrcSize.Font      = New-Object System.Drawing.Font("Consolas", 8)
    $grpVal.Controls.Add($lblValSrcSize)

    # ================= COLUMNA DERECHA =================

    # --- 4. PROGRESO DE COMPILACION ---
    $grpProg           = New-Object System.Windows.Forms.GroupBox
    $grpProg.Text      = " PROGRESO DE COMPILACION "
    $grpProg.Location  = "475, 50"
    $grpProg.Size      = "420, 385"
    $grpProg.ForeColor = [System.Drawing.Color]::FromArgb(40, 200, 120)
    $form.Controls.Add($grpProg)

    # [F4] Texto del motor incluye version de oscdimg leida del PE header.
    # Si la lectura fallo, muestra solo la ruta (comportamiento anterior).
    $motorText = if ($oscdimgVerStr) {
        "Motor: $oscdimgExe`n[v$oscdimgVerStr]"
    } else {
        "Motor: $oscdimgExe"
    }
    $lblMotorInfo           = New-Object System.Windows.Forms.Label
    $lblMotorInfo.Text      = $motorText
    $lblMotorInfo.Location  = "15, 25"
    $lblMotorInfo.Size      = "350, 30"
    $lblMotorInfo.ForeColor = [System.Drawing.Color]::FromArgb(80, 90, 100)
    $lblMotorInfo.Font      = New-Object System.Drawing.Font("Consolas", 8)
    $grpProg.Controls.Add($lblMotorInfo)

    # ANIMACION DE CD GIRATORIO
    $script:cdAngle = 0
    $picCD          = New-Object System.Windows.Forms.PictureBox
    $picCD.Location = "365, 45"
    $picCD.Size     = "40, 40"
    $picCD.BackColor = [System.Drawing.Color]::Transparent
    $picCD.Visible   = $false
    $grpProg.Controls.Add($picCD)

    $cdTimer          = New-Object System.Windows.Forms.Timer
    $cdTimer.Interval = 40
    $cdTimer.Add_Tick({
        $script:cdAngle = ($script:cdAngle + 15) % 360
        $picCD.Refresh()
    })

    $picCD.Add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

        $g.TranslateTransform(20, 20)
        $g.RotateTransform($script:cdAngle)
        $g.TranslateTransform(-20, -20)

        $g.FillEllipse([System.Drawing.Brushes]::MediumSpringGreen, 2, 2, 36, 36)
        $g.FillPie([System.Drawing.Brushes]::DarkSlateGray, 2, 2, 36, 36, 45, 40)
        $g.FillPie([System.Drawing.Brushes]::DarkSlateGray, 2, 2, 36, 36, 225, 40)

        $bgBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(18, 22, 28))
        $g.FillEllipse($bgBrush, 14, 14, 12, 12)
        $bgBrush.Dispose()

        $g.DrawEllipse([System.Drawing.Pens]::DarkGreen, 14, 14, 12, 12)
        $g.DrawEllipse([System.Drawing.Pens]::SeaGreen,  2,  2, 36, 36)
    })

    $lblPhase           = New-Object System.Windows.Forms.Label
    $lblPhase.Text      = "Esperando configuracion..."
    $lblPhase.Location  = "15, 90"
    $lblPhase.Size      = "390, 22"
    $lblPhase.ForeColor = [System.Drawing.Color]::FromArgb(64, 196, 255)
    $lblPhase.Font      = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $grpProg.Controls.Add($lblPhase)

    $pbMain          = New-Object System.Windows.Forms.ProgressBar
    $pbMain.Location = "15, 120"
    $pbMain.Size     = "390, 25"
    $pbMain.Minimum  = 0
    $pbMain.Maximum  = 100
    $pbMain.Value    = 0
    $pbMain.Style    = [System.Windows.Forms.ProgressBarStyle]::Continuous
    $grpProg.Controls.Add($pbMain)

    $lblPercent           = New-Object System.Windows.Forms.Label
    $lblPercent.Text      = "0 % completado"
    $lblPercent.Location  = "15, 155"
    $lblPercent.AutoSize  = $true
    $lblPercent.ForeColor = [System.Drawing.Color]::FromArgb(40, 200, 120)
    $lblPercent.Font      = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $grpProg.Controls.Add($lblPercent)

    $lblFileInfo           = New-Object System.Windows.Forms.Label
    $lblFileInfo.Text      = ""
    $lblFileInfo.Location  = "15, 190"
    $lblFileInfo.Size      = "390, 18"
    $lblFileInfo.ForeColor = [System.Drawing.Color]::Gray
    $grpProg.Controls.Add($lblFileInfo)

    $lblSizeInfo           = New-Object System.Windows.Forms.Label
    $lblSizeInfo.Text      = ""
    $lblSizeInfo.Location  = "15, 215"
    $lblSizeInfo.Size      = "390, 18"
    $lblSizeInfo.ForeColor = [System.Drawing.Color]::Gray
    $grpProg.Controls.Add($lblSizeInfo)

    $lblHashInfo           = New-Object System.Windows.Forms.Label
    $lblHashInfo.Text      = ""
    $lblHashInfo.Location  = "15, 240"
    $lblHashInfo.Size      = "390, 35"
    $lblHashInfo.ForeColor = [System.Drawing.Color]::FromArgb(40, 200, 120)
    $lblHashInfo.Font      = New-Object System.Drawing.Font("Consolas", 8)
    $grpProg.Controls.Add($lblHashInfo)

    # ================= FILA INFERIOR DE BOTONES =================

    $btnExportLog                            = New-Object System.Windows.Forms.Button
    $btnExportLog.Text                       = "Exportar Log"
    $btnExportLog.Location                   = "15, 450"
    $btnExportLog.Size                       = "140, 40"
    $btnExportLog.BackColor                  = [System.Drawing.Color]::FromArgb(30, 35, 40)
    $btnExportLog.ForeColor                  = [System.Drawing.Color]::Gray
    $btnExportLog.FlatStyle                  = "Flat"
    $btnExportLog.FlatAppearance.BorderSize  = 1
    $btnExportLog.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(50, 55, 60)
    $btnExportLog.Enabled                    = $false
    $form.Controls.Add($btnExportLog)

    # [F1] btnMake ocupa 590 px en reposo.
    # Al iniciar compilacion se reduce a 430 px para que aparezca btnCancel.
    $btnMake                           = New-Object System.Windows.Forms.Button
    $btnMake.Text                      = "► CREAR ISO BOOTEABLE"
    $btnMake.Location                  = "165, 450"
    $btnMake.Size                      = "590, 40"
    $btnMake.BackColor                 = [System.Drawing.Color]::FromArgb(18, 105, 69)
    $btnMake.ForeColor                 = [System.Drawing.Color]::Black
    $btnMake.FlatStyle                 = "Flat"
    $btnMake.FlatAppearance.BorderSize = 0
    $btnMake.Font                      = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($btnMake)

    # [F1] Boton Cancelar — visible solo durante la compilacion.
    # Se ubica donde estaba la mitad derecha de btnMake (605..755).
    $btnCancel                           = New-Object System.Windows.Forms.Button
    $btnCancel.Text                      = "✖  Cancelar"
    $btnCancel.Location                  = "605, 450"
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
    $btnAbout.Location                   = "765, 450"
    $btnAbout.Size                       = "130, 40"
    $btnAbout.BackColor                  = [System.Drawing.Color]::FromArgb(30, 35, 40)
    $btnAbout.ForeColor                  = [System.Drawing.Color]::FromArgb(64, 196, 255)
    $btnAbout.FlatStyle                  = "Flat"
    $btnAbout.FlatAppearance.BorderSize  = 1
    $btnAbout.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(50, 55, 60)
    $form.Controls.Add($btnAbout)

    $btnOpenFolder                           = New-Object System.Windows.Forms.Button
    $btnOpenFolder.Text                      = ">> Abrir carpeta de la imagen generada"
    $btnOpenFolder.Location                  = "15, 500"
    $btnOpenFolder.Size                      = "880, 25"
    $btnOpenFolder.BackColor                 = [System.Drawing.Color]::FromArgb(10, 40, 20)
    $btnOpenFolder.ForeColor                 = [System.Drawing.Color]::LimeGreen
    $btnOpenFolder.FlatStyle                 = "Flat"
    $btnOpenFolder.FlatAppearance.BorderSize = 0
    $btnOpenFolder.Visible                   = $false
    $form.Controls.Add($btnOpenFolder)

    # ------------------------------------------------------------------
    # 4. Helpers de UI
    # ------------------------------------------------------------------

    $script:SetPhase = {
        param([string]$Text, [System.Drawing.Color]$Color = [System.Drawing.Color]::Cyan)
        $lblPhase.Text      = $Text
        $lblPhase.ForeColor = $Color
        $form.Refresh()
    }

    # Helper: restablecer barra de progreso al modo normal (Continuous) y
    # los botones de compilacion a su estado de reposo.
    # Usado por los paths de exito, error, cancelacion y excepcion.
    $script:RestoreCompileUI = {
        if ($null -ne $cdTimer -and -not $cdTimer.IsDisposed) { try { $cdTimer.Stop() } catch {} }
        if ($null -ne $picCD   -and -not $picCD.IsDisposed)   { $picCD.Visible = $false }
        # [F1] Ocultar Cancelar y restaurar ancho de btnMake
        $btnCancel.Visible = $false
        $btnMake.Size      = "590, 40"
        if ($null -ne $form -and -not $form.IsDisposed) {
            $btnMake.Enabled  = $true
            $grpCfg.Enabled   = $true
            $grpAuto.Enabled  = $true
            $form.Cursor      = [System.Windows.Forms.Cursors]::Default
        }
    }

    $script:UpdateValidation = {
        param([string]$srcPath)
        $okC   = [System.Drawing.Color]::FromArgb(40, 200, 120)
        $errC  = [System.Drawing.Color]::Crimson
        $warnC = [System.Drawing.Color]::Orange
        $grayC = [System.Drawing.Color]::Gray

        if ([string]::IsNullOrWhiteSpace($srcPath)) {
            $lblValBoot.Text = "• boot\etfsboot.com"; $lblValBoot.ForeColor = $grayC
            $lblValEfi.Text  = "• efisys.bin (UEFI)"; $lblValEfi.ForeColor  = $grayC
            $lblValWim.Text  = "• sources\install.*"; $lblValWim.ForeColor  = $grayC
            return
        }
        $hasBoot              = Test-Path -LiteralPath (Join-Path $srcPath 'boot\etfsboot.com')
        $lblValBoot.Text      = "• boot\etfsboot.com"
        $lblValBoot.ForeColor = if ($hasBoot) { $okC } else { $errC }

        $hasEfi              = Test-Path -LiteralPath (Join-Path $srcPath 'efi\microsoft\boot\efisys.bin')
        $lblValEfi.Text      = if ($hasEfi)  { "• efisys.bin (UEFI)"      } else { "• efisys.bin (solo BIOS)" }
        $lblValEfi.ForeColor = if ($hasEfi)  { $okC } else { $warnC }

        $hasWim = (Test-Path -LiteralPath (Join-Path $srcPath 'sources\install.wim')) -or
                  (Test-Path -LiteralPath (Join-Path $srcPath 'sources\install.esd'))
        $lblValWim.Text      = "• sources\install.*"
        $lblValWim.ForeColor = if ($hasWim)  { $okC } else { $errC }
    }

    $script:UpdateDiskSpace = {
        param([string]$srcPath, [string]$dstPath)
        if ([string]::IsNullOrWhiteSpace($dstPath)) {
            $lblValSpace.Text      = "• Espacio libre en destino: (Esperando...)"
            $lblValSpace.ForeColor = [System.Drawing.Color]::Gray
            return
        }
        try {
            $q = Split-Path -Qualifier $dstPath -ErrorAction SilentlyContinue
            if (-not $q) { return }
            $drive = Get-PSDrive -Name $q.TrimEnd(':') -ErrorAction SilentlyContinue
            if (-not $drive) { return }
            $freeGB = [math]::Round($drive.Free / 1GB, 1)
            if ($drive.Free -ge 5GB) {
                $lblValSpace.Text      = "• Espacio libre en destino: $freeGB GB"
                $lblValSpace.ForeColor = [System.Drawing.Color]::FromArgb(40, 200, 120)
            } else {
                $lblValSpace.Text      = "• Espacio libre en destino: $freeGB GB (puede ser insuficiente)"
                $lblValSpace.ForeColor = [System.Drawing.Color]::Orange
            }
        } catch {}
    }

    $script:AnalyzeSrc = {
        param([string]$srcPath)
        $txtSrc.Text = $srcPath
        # [FIX D2] Nueva carpeta origen -> permitir que DISM auto-complete la etiqueta de nuevo
        $script:labelUserEdited = $false
        Write-Log -LogLevel INFO -Message "IsoCore: Carpeta origen seleccionada: $srcPath"

        # ------------------------------------------------------------------
        # [FIX E1] Cancelar timers y runspaces de un analisis anterior que
        # pudiera seguir en curso. Sin esto, los timers huerfanos siguen
        # disparandose y acceden a $script:sizeQueue / $script:dismQueue
        # despues de que ya fueron nulificados por la segunda llamada,
        # provocando NullReferenceException en el tick ("No se puede llamar
        # a un metodo en una expresion con valor NULL").
        # ------------------------------------------------------------------
        if ($null -ne $script:sizeTimer) {
            try { $script:sizeTimer.Stop(); $script:sizeTimer.Dispose() } catch {}
            $script:sizeTimer = $null
        }
        if ($null -ne $script:sizePS) {
            try { $script:sizePS.Stop(); $script:sizePS.Dispose() } catch {}
            $script:sizePS = $null
        }
        if ($null -ne $script:sizeRS) {
            try { $script:sizeRS.Close(); $script:sizeRS.Dispose() } catch {}
            $script:sizeRS = $null
        }
        $script:sizeHandle = $null
        $script:sizeQueue  = $null

        if ($null -ne $script:dismTimer) {
            try { $script:dismTimer.Stop(); $script:dismTimer.Dispose() } catch {}
            $script:dismTimer = $null
        }
        if ($null -ne $script:dismPS) {
            try { $script:dismPS.Stop(); $script:dismPS.Dispose() } catch {}
            $script:dismPS = $null
        }
        if ($null -ne $script:dismRS) {
            try { $script:dismRS.Close(); $script:dismRS.Dispose() } catch {}
            $script:dismRS = $null
        }
        $script:dismHandle = $null
        $script:dismQueue  = $null

        # Restaurar btnSrc por si quedara desactivado de un analisis DISM previo interrumpido
        $btnSrc.Enabled = $true

        # Restaurar barra al modo Continuous si quedara atascada en Marquee
        if ($pbMain.Style -eq [System.Windows.Forms.ProgressBarStyle]::Marquee) {
            $pbMain.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
            $pbMain.Value = 0
        }

        & $script:UpdateValidation $srcPath
        & $script:UpdateDiskSpace  $srcPath $txtDst.Text

        $lblValSrcSize.Text      = "• Calculando Tamaño de la carpeta origen..."
        $lblValSrcSize.ForeColor = [System.Drawing.Color]::Gray

        # --- Calculo de Tamaño de la carpeta (async) ---
        $script:sizeQueue = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
        $script:sizeRS    = [runspacefactory]::CreateRunspace()
        $script:sizeRS.Open()
        $script:sizeRS.SessionStateProxy.SetVariable('srcPath',   $srcPath)
        $script:sizeRS.SessionStateProxy.SetVariable('sizeQueue', $script:sizeQueue)

        $script:sizePS = [powershell]::Create()
        $script:sizePS.Runspace = $script:sizeRS
        [void]$script:sizePS.AddScript({
            $result = @{ Bytes = 0L; Count = 0; DirCount = 0; Error = $null }
            try {
                # Buscamos archivos y directorios por separado
                $files = Get-ChildItem -LiteralPath $srcPath -Recurse -File -ErrorAction SilentlyContinue
                $dirs  = Get-ChildItem -LiteralPath $srcPath -Recurse -Directory -ErrorAction SilentlyContinue
                
                $result.Count    = $files.Count
                $result.DirCount = $dirs.Count
                $result.Bytes    = ($files | Measure-Object -Property Length -Sum).Sum
            } catch {
                $result.Error = $_.Exception.Message
            }
            $sizeQueue.Enqueue($result)
        })
        $script:sizeHandle = $script:sizePS.BeginInvoke()

        $script:sizeTimer          = New-Object System.Windows.Forms.Timer
        $script:sizeTimer.Interval = 150
        $script:sizeTimer.Add_Tick({
            $res = $null
            if (-not $script:sizeQueue.TryDequeue([ref]$res)) { return }

            $script:sizeTimer.Stop()
            $script:sizeTimer.Dispose()
            $script:sizeTimer = $null
            try { $script:sizePS.EndInvoke($script:sizeHandle) } catch {}
            try { $script:sizePS.Dispose()                     } catch {}
            try { $script:sizeRS.Close(); $script:sizeRS.Dispose() } catch {}
            $script:sizePS = $null; $script:sizeRS = $null
            $script:sizeHandle = $null; $script:sizeQueue = $null

            if ($null -ne $res.Error) {
                $lblValSrcSize.Text      = "• No se pudo calcular el Tamaño de la carpeta origen"
                $lblValSrcSize.ForeColor = [System.Drawing.Color]::Orange
                Write-Log -LogLevel WARN -Message "IsoCore: No se pudo calcular el Tamaño de la carpeta origen: $($res.Error)"
            } else {
                $bytes = $res.Bytes
                $strSz = if ($bytes -ge 1GB)  { "$([math]::Round($bytes/1GB, 2)) GB"  }
                         elseif ($bytes -ge 1MB) { "$([math]::Round($bytes/1MB, 1)) MB"  }
                         else   { "$bytes bytes" }
                $color = if ($bytes -ge 8GB) { [System.Drawing.Color]::Orange }  # > 8 GB: probablemente incluye drivers/updates adicionales fuera de lo habitual
                         else                { [System.Drawing.Color]::FromArgb(40, 200, 120) }
                $lblValSrcSize.Text      = "• Tamaño carpeta origen: $strSz ($($res.Count) archivos | $($res.DirCount) directorios)"
                $lblValSrcSize.ForeColor = $color
                Write-Log -LogLevel INFO -Message "IsoCore: Tamaño carpeta origen: $strSz ($($res.Count) archivos | $($res.DirCount) directorios)."
            }
        })
        $script:sizeTimer.Start()

        # --- Extraccion de metadatos DISM (async) ---
        $installWim  = Join-Path $srcPath "sources\install.wim"
        $installEsd  = Join-Path $srcPath "sources\install.esd"
        $targetImage = $null
        if     (Test-Path -LiteralPath $installWim) { $targetImage = $installWim }
        elseif (Test-Path -LiteralPath $installEsd) { $targetImage = $installEsd }

        if ($targetImage) {
            Write-Log -LogLevel INFO -Message "IsoCore: Imagen base detectada: $targetImage. Extrayendo metadatos DISM (async)..."
            # [FIX E5] Pasar color explicito (azul claro) en lugar del default Cyan
            & $script:SetPhase "Analizando metadatos de la imagen (DISM)..." ([System.Drawing.Color]::FromArgb(64, 196, 255))
            $btnSrc.Enabled = $false

            # [F2] Activar modo Marquee mientras DISM trabaja en background,
            # para que el usuario vea actividad visual en lugar de una barra vacia.
            $pbMain.Style                 = [System.Windows.Forms.ProgressBarStyle]::Marquee
            $pbMain.MarqueeAnimationSpeed = 20

            $script:dismQueue = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
            $script:dismRS    = [runspacefactory]::CreateRunspace()
            $script:dismRS.Open()
            $script:dismRS.SessionStateProxy.SetVariable('targetImage', $targetImage)
            $script:dismRS.SessionStateProxy.SetVariable('dismQueue',   $script:dismQueue)

            $script:dismPS = [powershell]::Create()
            $script:dismPS.Runspace = $script:dismRS
            [void]$script:dismPS.AddScript({
                $result = @{ Label = $null; Error = $null }
                try {
                    $prefix    = "CCCOMA"
                    $allImages = Get-WindowsImage -ImagePath $targetImage -ErrorAction Stop
                    $allNames  = $allImages.ImageName -join " "

                    if     ($allNames -match "Server")                            { $prefix = "SSS"   }
                    elseif ($allNames -match "Enterprise.*LTSC|LTSC.*Enterprise") { $prefix = "CCCEA" }
                    elseif ($allNames -match "Enterprise")                        { $prefix = "CCCEA" }

                    $detailedImage = Get-WindowsImage -ImagePath $targetImage -Index 1 -ErrorAction Stop

                    $archStr = switch ($detailedImage.Architecture) {
                        0       { "X86"   }
                        9       { "X64"   }
                        12      { "ARM64" }
                        Default { "X64"   }
                    }

                    $langStr = "EN-US"
                    if ($null -ne $detailedImage.Languages -and $detailedImage.Languages.Count -gt 0) {
                        $langStr = $detailedImage.Languages[0].ToString().ToUpper()
                    } elseif ($null -ne $detailedImage.Language) {
                        $langStr = $detailedImage.Language.ToString().ToUpper()
                    }

                    $result.Label = "${prefix}_${archStr}FRE_${langStr}_DV9"
                } catch {
                    $result.Error = $_.Exception.Message
                }
                $dismQueue.Enqueue($result)
            })
            $script:dismHandle = $script:dismPS.BeginInvoke()

            $script:dismTimer          = New-Object System.Windows.Forms.Timer
            $script:dismTimer.Interval = 100
            $script:dismTimer.Add_Tick({
                $res = $null
                if (-not $script:dismQueue.TryDequeue([ref]$res)) { return }

                $script:dismTimer.Stop()
                $script:dismTimer.Dispose()
                $script:dismTimer = $null
                try { $script:dismPS.EndInvoke($script:dismHandle) } catch {}
                try { $script:dismPS.Dispose()                     } catch {}
                try { $script:dismRS.Close(); $script:dismRS.Dispose() } catch {}
                $script:dismPS = $null; $script:dismRS = $null
                $script:dismHandle = $null; $script:dismQueue = $null
                $btnSrc.Enabled = $true

                # [F2] Restaurar barra al modo continuo al terminar el analisis DISM.
                $pbMain.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
                $pbMain.Value = 0

                if ($null -ne $res.Error) {
                    if (-not $script:labelUserEdited) {
                        $txtLabel.Text = "WINDOWS_CUSTOM"
                        $script:labelUserEdited = $false
                    }
                    Write-Log -LogLevel WARN -Message "IsoCore: Fallo al extraer metadatos DISM: $($res.Error). Etiqueta por defecto aplicada."
                    & $script:SetPhase "Error leyendo metadatos. Etiqueta por defecto aplicada." ([System.Drawing.Color]::Orange)
                } else {
                    if (-not $script:labelUserEdited) {
                        $txtLabel.Text          = $res.Label
                        $script:labelUserEdited = $false   # reset: fue escritura automatica, no del usuario
                        Write-Log -LogLevel INFO -Message "IsoCore: Etiqueta generada dinamicamente: $($txtLabel.Text)"
                        & $script:SetPhase "Etiqueta generada: $($txtLabel.Text)" ([System.Drawing.Color]::FromArgb(40, 200, 120))
                    } else {
                        Write-Log -LogLevel INFO -Message "IsoCore: Etiqueta DISM ignorada (usuario edito manualmente): '$($txtLabel.Text)'."
                        & $script:SetPhase "Etiqueta personalizada conservada: $($txtLabel.Text)" ([System.Drawing.Color]::FromArgb(255, 200, 40))
                    }
                }
            })
            $script:dismTimer.Start()

        } else {
            $txtLabel.Text = "WINDOWS_CUSTOM"
            Write-Log -LogLevel WARN -Message "IsoCore: Archivo install.wim/esd no detectado en sources. Aplicando etiqueta base."
            & $script:SetPhase "install.wim/esd no encontrado. Etiqueta base aplicada." ([System.Drawing.Color]::Orange)
        }
    }

    # ------------------------------------------------------------------
    # [FIX B3] Helper centralizado para eliminar archivos inyectados.
    # Ordena por profundidad real del path (descendente) para garantizar
    # que los archivos se borren antes que sus carpetas contenedoras.
    # ------------------------------------------------------------------
    $script:CleanupInjectedFiles = {
        if ($null -eq $script:injectedFiles -or $script:injectedFiles.Count -eq 0) { return }

        $toDelete = $script:injectedFiles |
            ForEach-Object { Get-Item -LiteralPath $_ -ErrorAction SilentlyContinue } |
            Where-Object   { $null -ne $_ } |
            Sort-Object    { $_.FullName.Split([IO.Path]::DirectorySeparatorChar).Count } -Descending

        foreach ($item in $toDelete) {
            try {
                if ($item.PSIsContainer) {
                    if (-not (Get-ChildItem -LiteralPath $item.FullName -ErrorAction SilentlyContinue)) {
                        Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
                    }
                } else {
                    Remove-Item -LiteralPath $item.FullName -Force -ErrorAction SilentlyContinue
                }
            } catch {}
        }
        $script:injectedFiles = $null
    }

    # ------------------------------------------------------------------
    # 5. Eventos de controles
    # ------------------------------------------------------------------

    $txtSrc.Add_TextChanged({ & $script:UpdateValidation $txtSrc.Text; & $script:UpdateDiskSpace $txtSrc.Text $txtDst.Text })
    $txtDst.Add_TextChanged({ & $script:UpdateDiskSpace $txtSrc.Text $txtDst.Text })

    $chkMRP.Add_CheckedChanged({
        if ($chkMRP.Checked) {
            $msgAuto = "Has habilitado la inyección del paquete MRP.`n`n" +
                       "RECOMENDACIÓN IMPORTANTÍSIMA:`n" +
                       "Desactiva temporalmente tu antivirus (incluyendo la protección en tiempo real de Windows Defender) durante la creación de la ISO.`n`n" +
                       "Los activadores y scripts de OEM integrados en MRP suelen ser detectados como falsos positivos. Si el antivirus interviene durante la extracción, eliminará archivos clave y la imagen ISO quedará corrupta."
            
            [System.Windows.Forms.MessageBox]::Show(
                $msgAuto, 
                "Aviso de Antivirus - MRP", 
                [System.Windows.Forms.MessageBoxButtons]::OK, 
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            Write-Log -LogLevel INFO -Message "IsoCore: El usuario marcó la opción MRP. Se mostró la advertencia del antivirus."
        }
    })

    # [FIX D2] Rastrear si el usuario ha editado manualmente la etiqueta, para que el resultado
    # del analisis DISM asincronico no sobreescriba un valor introducido intencionalmente.
    $script:labelUserEdited = $false

    # [F3] Validacion en tiempo real de la etiqueta de volumen.
    # ISO 9660 / UDF solo admiten A-Z, 0-9, guion y guion_bajo, maximo 32 chars.
    # [FIX E3] Se fuerza uppercase en el handler para que la conversion posterior de
    # la sanitizacion (ToUpper) no sorprenda al usuario. La posicion del cursor se
    # preserva para que escribir en mitad del texto siga funcionando con naturalidad.
    $txtLabel.Add_TextChanged({
        # Forzar uppercase manteniendo la posicion del cursor
        $pos = $txtLabel.SelectionStart
        $up  = $txtLabel.Text.ToUpper()
        if ($txtLabel.Text -cne $up) {
            $txtLabel.Text           = $up
            $txtLabel.SelectionStart = [Math]::Min($pos, $up.Length)
        }
        $script:labelUserEdited = $true
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
        if ($fbd.ShowDialog() -eq 'OK') { & $script:AnalyzeSrc $fbd.SelectedPath }
    })

    $btnDst.Add_Click({
        $sfd        = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.Filter = "Imagen ISO (*.iso)|*.iso"
        if ($sfd.ShowDialog() -eq 'OK') {
            $txtDst.Text = $sfd.FileName
            Write-Log -LogLevel INFO -Message "IsoCore: Archivo de destino configurado: $($txtDst.Text)"
            & $script:UpdateDiskSpace $txtSrc.Text $txtDst.Text
        }
    })

    $btnUnattend.Add_Click({
        $ofd        = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "XML Files (*.xml)|*.xml"
        if ($ofd.ShowDialog() -eq 'OK') {
            $txtUnattend.Text = $ofd.FileName
            Write-Log -LogLevel INFO -Message "IsoCore: Archivo Unattend.xml configurado: $($txtUnattend.Text)"
        }
    })

    $lnkWeb.Add_Click({
        $lnkWeb.LinkVisited = $true   # [FIX C6] Actualizar estado visual del enlace
        Start-Process "https://schneegans.de/windows/unattend-generator/"
    })

    $btnAbout.Add_Click({
        $msg = "IsoCore v$($script:Version)`n" +
               "Desarrollado por SOFTMAXTER`n`n" +
               "Email: softmaxter@hotmail.com`n" +
               "Blog: softmaxter.blogspot.com`n`n" +
               "Un motor avanzado para la creacion de imagenes ISO booteables (BIOS/UEFI) " +
               "con integracion de respuestas desatendidas (OOBE)."
        [System.Windows.Forms.MessageBox]::Show($msg, "Acerca de IsoCore", 'OK', 'Information')
    })

    # [F5] Tooltips en controles clave.
    # ShowAlways = $true para que funcionen aunque el form no tenga foco.
    $tip                  = New-Object System.Windows.Forms.ToolTip
    $tip.AutoPopDelay     = 8000
    $tip.InitialDelay     = 400
    $tip.ReshowDelay      = 200
    $tip.ShowAlways       = $true
    $tip.SetToolTip($txtSrc,      "Carpeta raiz de la fuente de instalacion de Windows (debe contener boot\, efi\, sources\).")
    $tip.SetToolTip($btnSrc,      "Abrir explorador para seleccionar la carpeta origen.")
    $tip.SetToolTip($txtDst,      "Ruta completa del archivo ISO que se generara (p. ej. C:\Output\Windows11.iso).")
    $tip.SetToolTip($btnDst,      "Elegir ruta y nombre del archivo ISO de salida.")
    $tip.SetToolTip($txtLabel,    "Maximo 32 caracteres. Solo A-Z, 0-9, guion y guion_bajo. Se genera automaticamente desde los metadatos DISM.")
    $tip.SetToolTip($txtUnattend, "Archivo XML de respuesta desatendida. Se copiara como autounattend.xml en la raiz de la ISO.")
    $tip.SetToolTip($btnUnattend, "Seleccionar archivo autounattend.xml.")
    $tip.SetToolTip($lnkWeb,      "Abre schneegans.de — generador online de archivos autounattend.xml para automatizacion OOBE.")
    $tip.SetToolTip($chkMRP,      "Extrae el ZIP 'MRP*.zip' de la carpeta Tools e inyecta su contenido en \sources antes de compilar.")
    $tip.SetToolTip($btnExportLog,"Guarda el log completo de la ultima compilacion como archivo .txt.")
    $tip.SetToolTip($btnMake,     "Inicia la compilacion de la imagen ISO booteable con los parametros configurados.")
    $tip.SetToolTip($btnCancel,   "Interrumpe la compilacion en curso. El archivo ISO quedara incompleto.")
    $tip.SetToolTip($btnAbout,    "Informacion sobre IsoCore y datos de contacto del autor.")

    # ------------------------------------------------------------------
    # [F1] Boton Cancelar
    # Cancela el proceso oscdimg en curso, limpia todos los recursos y
    # restaura la UI al estado de reposo sin necesidad de cerrar el form.
    # ------------------------------------------------------------------
    $btnCancel.Add_Click({
        if ($null -eq $script:isoProc -or $script:isoProc.HasExited) { return }

        $res = [System.Windows.Forms.MessageBox]::Show(
            "Se cancelara la compilacion en curso.`nEl archivo ISO quedara incompleto y debera eliminarse manualmente.`n`n¿Confirmas la cancelacion?",
            "Cancelar Compilacion",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($res -eq 'No') { return }

        Write-Log -LogLevel WARN -Message "IsoCore: Compilacion cancelada por el usuario desde el boton Cancelar."

        # Detener timer de progreso y liberar wait handle
        if ($null -ne $script:pollTimer) {
            try { $script:pollTimer.Stop(); $script:pollTimer.Dispose() } catch {}
            $script:pollTimer = $null
        }
        if ($null -ne $script:buildDone) {
            try { $script:buildDone.Dispose() } catch {}
            $script:buildDone = $null
        }

        # Terminar proceso oscdimg
        try { $script:isoProc.Kill() } catch {}
        try { $script:isoProc.Dispose() } catch {}
        $script:isoProc = $null

        # Liberar worker de lectura de stdout/stderr
        if ($null -ne $script:bgPS) {
            try { $script:bgPS.EndInvoke($script:bgHandle) } catch {}
            try { $script:bgPS.Dispose()                   } catch {}
            $script:bgPS = $null
        }
        if ($null -ne $script:bgRunspace) {
            try { $script:bgRunspace.Close(); $script:bgRunspace.Dispose() } catch {}
            $script:bgRunspace = $null   # [FIX C3] Nulificar para evitar double-close en FormClosing
        }
        $script:bgHandle = $null
        # [FIX C3] Descartar colas para que un tick residual del pollTimer no procese
        # lineas parciales de un proceso ya terminado/matado.
        $script:outQueue = $null
        $script:errQueue = $null

        # Limpiar archivos inyectados (XML, MRP)
        & $script:CleanupInjectedFiles

        # Actualizar HUD
        & $script:SetPhase "Compilacion cancelada por el usuario." ([System.Drawing.Color]::Orange)
        $pbMain.Value         = 0
        $lblPercent.Text      = "Cancelado"
        $lblPercent.ForeColor = [System.Drawing.Color]::Orange
        $btnExportLog.Enabled = $true

        Write-Log -LogLevel ACTION -Message "IsoCore: Recursos liberados correctamente tras la cancelacion. Listo para nueva compilacion."
        & $script:RestoreCompileUI
    })

    # ------------------------------------------------------------------
    # 6. Logica principal — CREAR ISO BOOTEABLE
    # ------------------------------------------------------------------
    $btnMake.Add_Click({
        $src        = $txtSrc.Text
        $script:iso = $txtDst.Text
        $xmlPath    = $txtUnattend.Text
        $iso        = $script:iso

        if (-not $src -or -not $iso) {
            Write-Log -LogLevel WARN -Message "IsoCore: El usuario intento compilar sin definir rutas de origen o destino."
            [System.Windows.Forms.MessageBox]::Show("Faltan rutas.", "Error", 'OK', 'Error')
            return
        }

        if (-not (Test-Path $src)) {
            Write-Log -LogLevel ERROR -Message "IsoCore: La carpeta origen no existe: $src"
            [System.Windows.Forms.MessageBox]::Show("La carpeta origen no existe.", "Error", 'OK', 'Error')
            return
        }

        $biosBoot = Join-Path $src "boot\etfsboot.com"
        $uefiBoot = Join-Path $src "efi\microsoft\boot\efisys.bin"

        if (-not (Test-Path $biosBoot)) {
            Write-Log -LogLevel ERROR -Message "IsoCore: Fallo estructural. Falta boot\etfsboot.com en la ruta de origen ($src)."
            [System.Windows.Forms.MessageBox]::Show("No se encuentra boot\etfsboot.com.", "Error Estructural", 'OK', 'Error')
            return
        }

        $uefiDisponible = Test-Path $uefiBoot
        if (-not $uefiDisponible) {
            Write-Log -LogLevel WARN -Message "IsoCore: No se encontro efi\microsoft\boot\efisys.bin. Se ofrecera modo BIOS-only."
            $resUefi = [System.Windows.Forms.MessageBox]::Show(
                "No se encontro el archivo de arranque UEFI:`nefi\microsoft\boot\efisys.bin`n`nLa ISO resultante solo sera arrancable en modo BIOS/Legacy (no UEFI).`n`n¿Deseas continuar de todas formas?",
                "UEFI Boot Ausente",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($resUefi -eq 'No') { return }
            Write-Log -LogLevel INFO -Message "IsoCore: Usuario acepto continuar en modo BIOS-only (sin UEFI)."
        }

        $srcWim = Join-Path $src "sources\install.wim"
        $srcEsd = Join-Path $src "sources\install.esd"
        if (-not (Test-Path -LiteralPath $srcWim) -and -not (Test-Path -LiteralPath $srcEsd)) {
            Write-Log -LogLevel WARN -Message "IsoCore: No se encontro sources\install.wim ni install.esd."
            $resWim = [System.Windows.Forms.MessageBox]::Show(
                "No se encontro 'sources\install.wim' ni 'sources\install.esd' en la carpeta origen.`n`nEsto puede indicar una fuente de instalacion incompleta.`n`n¿Deseas continuar de todas formas?",
                "Imagen de Instalacion Ausente",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($resWim -eq 'No') { return }
            Write-Log -LogLevel INFO -Message "IsoCore: Usuario acepto continuar sin imagen de instalacion (install.wim/esd)."
        }

        try {
            $dstQ = Split-Path -Qualifier $iso -ErrorAction SilentlyContinue
            if ($dstQ) {
                $drive = Get-PSDrive -Name $dstQ.TrimEnd(':') -ErrorAction SilentlyContinue
                if ($drive -and $drive.Free -lt 5GB) {
                    $freeGB  = [math]::Round($drive.Free / 1GB, 1)
                    $proceed = [System.Windows.Forms.MessageBox]::Show(
                        "Espacio libre en el destino: $freeGB GB`n`nUna imagen ISO de Windows suele requerir entre 4 y 6 GB.`nPodrias quedarte sin espacio durante la compilacion.`n`n¿Deseas continuar de todas formas?",
                        "Espacio en Disco Limitado",
                        [System.Windows.Forms.MessageBoxButtons]::YesNo,
                        [System.Windows.Forms.MessageBoxIcon]::Warning
                    )
                    if ($proceed -eq 'No') {
                        Write-Log -LogLevel WARN -Message "IsoCore: El usuario cancelo la compilacion por espacio insuficiente ($freeGB GB libres)."
                        return
                    }
                    Write-Log -LogLevel INFO -Message "IsoCore: Usuario acepto continuar con espacio limitado en disco ($freeGB GB libres)."
                }
            }
        } catch {}

        $btnOpenFolder.Visible = $false
        $lblHashInfo.Text      = ""
        $lblHashInfo.ForeColor = [System.Drawing.Color]::FromArgb(40, 200, 120)

        $script:injectedFiles = [System.Collections.Generic.List[string]]::new()

        if (-not [string]::IsNullOrWhiteSpace($xmlPath) -and (Test-Path $xmlPath)) {
            Write-Log -LogLevel INFO -Message "IsoCore: Archivo Unattend.xml detectado. Inyectando en la raiz de la ISO."
            try {
                $xmlDest = Join-Path $src "autounattend.xml"
                Copy-Item -Path $xmlPath -Destination $xmlDest -Force -ErrorAction Stop
                $script:injectedFiles.Add($xmlDest)
                Write-Log -LogLevel ACTION -Message "IsoCore: autounattend.xml inyectado correctamente en: $xmlDest"
            } catch {
                Write-Log -LogLevel ERROR -Message "IsoCore: Fallo al copiar el archivo XML a la raiz - $($_.Exception.Message)"
                [System.Windows.Forms.MessageBox]::Show("Error copiando XML: $_", "Error", 'OK', 'Error')
                return
            }
        }

        # Bloquear controles y mostrar indicadores de actividad
        $btnMake.Enabled      = $false
        $grpCfg.Enabled       = $false
        $grpAuto.Enabled      = $false
        $form.Cursor          = [System.Windows.Forms.Cursors]::WaitCursor
        $pbMain.Value         = 0
        $lblPercent.Text      = "0 % completado"
        $lblPercent.ForeColor = [System.Drawing.Color]::FromArgb(40, 200, 120)
        $lblFileInfo.Text     = ""
        $lblSizeInfo.Text     = ""

        & $script:SetPhase "Iniciando compilacion..." ([System.Drawing.Color]::FromArgb(64, 196, 255))
        $picCD.Visible = $true
        $cdTimer.Start()

        # [F1] Mostrar boton Cancelar y ajustar ancho de btnMake para hacerle espacio
        $btnMake.Size      = "430, 40"
        $btnCancel.Visible = $true

        if ($chkMRP.Checked) {
            Write-Log -LogLevel INFO -Message "IsoCore: El usuario marco la inyeccion de MRP. Buscando archivo ZIP..."
            & $script:SetPhase "Buscando paquete MRP en el directorio Tools..." ([System.Drawing.Color]::FromArgb(64, 196, 255))

            $mrpZipPath = $null
            $mrpPaths   = @(
                (Join-Path $scriptPath "Tools"),
                (Join-Path $scriptPath "..\Tools")
            )
            foreach ($p in $mrpPaths) {
                if (Test-Path $p) {
                    $found = Get-ChildItem -Path $p -Filter "*MRP*.zip" -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($found) { $mrpZipPath = $found.FullName; break }
                }
            }

            if ($mrpZipPath) {
                Write-Log -LogLevel INFO -Message "IsoCore: Archivo MRP detectado: $mrpZipPath. Extrayendo en sources..."
                & $script:SetPhase "Extrayendo MRP en \sources (Esto puede tardar unos segundos)..." ([System.Drawing.Color]::FromArgb(64, 196, 255))
                try {
                    $sourcesDir = Join-Path $src "sources"
                    if (-not (Test-Path $sourcesDir)) { New-Item -Path $sourcesDir -ItemType Directory -Force | Out-Null }

                    $preExisting = Get-ChildItem -Path $sourcesDir -Recurse -ErrorAction SilentlyContinue |
                                   Select-Object -ExpandProperty FullName

                    Expand-Archive -Path $mrpZipPath -DestinationPath $sourcesDir -Force -ErrorAction Stop

                    # [FIX C5] Comparacion case-insensitive: Windows no distingue mayusculas en rutas,
                    # pero -notin usa comparacion exacta -> duplicados si Expand-Archive normaliza
                    # la capitalizacion de forma diferente a Get-ChildItem.
                    $preExistingLower = $preExisting | ForEach-Object { $_.ToLower() }
                    Get-ChildItem -Path $sourcesDir -Recurse -ErrorAction SilentlyContinue |
                        Where-Object   { $_.FullName.ToLower() -notin $preExistingLower } |
                        ForEach-Object { $script:injectedFiles.Add($_.FullName) }

                    Write-Log -LogLevel ACTION -Message "IsoCore: MRP inyectado correctamente en $sourcesDir."
                } catch {
                    Write-Log -LogLevel ERROR -Message "IsoCore: Fallo al extraer MRP - $($_.Exception.Message)"
                    [System.Windows.Forms.MessageBox]::Show("Error al extraer el archivo ZIP de MRP:`n$($_.Exception.Message)", "Error de Extraccion", 'OK', 'Error')
                    & $script:RestoreCompileUI
                    return
                }
            } else {
                Write-Log -LogLevel WARN -Message "IsoCore: No se encontro el archivo ZIP de MRP en la carpeta Tools."
                [System.Windows.Forms.MessageBox]::Show("No se ha encontrado ningun archivo ZIP que contenga la palabra 'MRP' en su nombre.", "Archivo no encontrado", 'OK', 'Warning')
                & $script:RestoreCompileUI
                return
            }
        }

        # [FIX B8] Sanitizacion estricta ISO 9660 / UDF.
        # Solo A-Z, 0-9, guion y guion_bajo. UDF no admite minusculas.
        $label = ($txtLabel.Text -replace '[^A-Za-z0-9_\-]', '_').ToUpper().Trim('_')
        if ($label.Length -eq 0)  { $label = "WINDOWS_CUSTOM" }
        if ($label.Length -gt 32) { $label = $label.Substring(0, 32) }
        if ($label -ne $txtLabel.Text.ToUpper()) {
            Write-Log -LogLevel INFO -Message "IsoCore: Etiqueta sanitizada (ISO 9660/UDF): '$($txtLabel.Text)' -> '$label'."
        } else {
            Write-Log -LogLevel INFO -Message "IsoCore: Etiqueta de volumen: '$label'."
        }

        $script:lastPct = 0

        # [FIX B5] Interpolacion de strings en lugar del operador -f.
        # -f interpreta { } como especificadores de formato y lanza FormatException
        # si las rutas contienen esos caracteres.
        # [FIX E2] TrimEnd('\') en $srcNorm: FolderBrowserDialog puede devolver rutas
        # de unidad raiz con backslash final (ej. "C:\"). Al embeber en "$srcNorm",
        # CommandLineToArgvW interpreta \" como comilla escapada, dejando el argumento
        # abierto y absorbiendo los parametros siguientes. TrimEnd garantiza que el
        # argumento cierre correctamente en todos los casos.
        $srcNorm = $src.TrimEnd('\')

        $bootArg = if ($uefiDisponible) {
            "-bootdata:2#p0,e,b`"$biosBoot`"#pEF,e,b`"$uefiBoot`""
        } else {
            "-bootdata:1#p0,e,b`"$biosBoot`""
        }
        $allArgs = "-m -o -u2 -udfver102 -l`"$label`" $bootArg `"$srcNorm`" `"$iso`""

        Write-Log -LogLevel ACTION -Message "IsoCore: Iniciando compilacion de ISO..."
        & $script:SetPhase "Analizando arbol de directorios y calculando estructura..." ([System.Drawing.Color]::FromArgb(64, 196, 255))

        $script:cleanLogBuilder = New-Object System.Text.StringBuilder
        $script:cleanLogBuilder.AppendLine("COMANDO:")             | Out-Null
        $script:cleanLogBuilder.AppendLine("oscdimg.exe $allArgs") | Out-Null
        $script:cleanLogBuilder.AppendLine("----------------")     | Out-Null

        $script:errLogBuilder = New-Object System.Text.StringBuilder

        $rxOptsC          = [System.Text.RegularExpressions.RegexOptions]::Compiled
        $script:rxPercent = [regex]::new('(\d+)%\s+complete', $rxOptsC)

        $script:outQueue  = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        $script:errQueue  = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        $script:buildDone = [System.Threading.ManualResetEventSlim]::new($false)

        try {
            $pInfo                        = New-Object System.Diagnostics.ProcessStartInfo
            $pInfo.FileName               = $oscdimgExe
            $pInfo.Arguments              = $allArgs
            $pInfo.RedirectStandardOutput = $true
            $pInfo.RedirectStandardError  = $true
            $pInfo.UseShellExecute        = $false
            $pInfo.CreateNoWindow         = $true

            $script:isoProc           = New-Object System.Diagnostics.Process
            $script:isoProc.StartInfo = $pInfo

            if (-not $script:isoProc.Start()) { throw "No inicio oscdimg" }
            Write-Log -LogLevel ACTION -Message "IsoCore: Proceso oscdimg lanzado (PID: $($script:isoProc.Id)). Argumentos: oscdimg.exe $allArgs"

            $script:bgRunspace = [runspacefactory]::CreateRunspace()
            $script:bgRunspace.Open()
            $script:bgRunspace.SessionStateProxy.SetVariable('isoProc',   $script:isoProc)
            $script:bgRunspace.SessionStateProxy.SetVariable('outQueue',  $script:outQueue)
            $script:bgRunspace.SessionStateProxy.SetVariable('errQueue',  $script:errQueue)
            $script:bgRunspace.SessionStateProxy.SetVariable('buildDone', $script:buildDone)

            $script:bgPS = [powershell]::Create()
            $script:bgPS.Runspace = $script:bgRunspace
            [void]$script:bgPS.AddScript({
                try {
                    while (-not $isoProc.HasExited) {
                        while ($isoProc.StandardOutput.Peek() -gt -1) {
                            $l = $isoProc.StandardOutput.ReadLine()
                            if ($null -ne $l) { $outQueue.Enqueue($l) }
                        }
                        while ($isoProc.StandardError.Peek() -gt -1) {
                            $l = $isoProc.StandardError.ReadLine()
                            if ($null -ne $l) { $errQueue.Enqueue($l) }
                        }
                        [System.Threading.Thread]::Sleep(30)
                    }
                    $rem = $isoProc.StandardOutput.ReadToEnd()
                    # [FIX C4] Sin filtro `if ($l)`: preservar lineas vacias del stdout final,
                    # consistente con la preservacion explicita del tick normal del pollTimer.
                    if ($rem) { foreach ($l in ($rem -split '\r?\n')) { $outQueue.Enqueue($l) } }
                    $rem = $isoProc.StandardError.ReadToEnd()
                    # [FIX E4] Mismo criterio que el loop principal: preservar todas las lineas
                    # no-null, incluidas las vacias. El loop usaba `if ($null -ne $l)` mientras
                    # que el flush usaba `if ($l)`, filtrando vacias inconsistentemente.
                    if ($rem) { foreach ($l in ($rem -split '\r?\n')) { $errQueue.Enqueue($l) } }
                } finally {
                    $buildDone.Set()
                }
            })

            $script:bgHandle = $script:bgPS.BeginInvoke()

            # ============================================================
            # TEMPORIZADOR DE PROGRESO
            # ============================================================
            $script:pollTimer          = New-Object System.Windows.Forms.Timer
            $script:pollTimer.Interval = 50

            $pollTickScript = {
                if ($null -eq $script:pollTimer) { return }

                try {
                    $line = $null

                    if ($null -ne $script:outQueue) {
                        while ($script:outQueue.TryDequeue([ref]$line)) {
                            # Preservar todas las lineas, incluidas las en blanco, para
                            # que el log refleje el espaciado original de la salida de oscdimg.
                            $script:cleanLogBuilder.AppendLine($line) | Out-Null
                            if (-not [string]::IsNullOrWhiteSpace($line) -and
                                $line -match '(\d+) files in (\d+) directories') {
                                $lblFileInfo.Text = "$($matches[1]) archivos | $($matches[2]) directorios"
                                $lblFileInfo.Refresh()
                            }
                        }
                    }

                    if ($null -ne $script:errQueue) {
                        while ($script:errQueue.TryDequeue([ref]$line)) {
                            if ([string]::IsNullOrWhiteSpace($line)) { continue }
                            $script:errLogBuilder.AppendLine($line) | Out-Null

                            $m = $script:rxPercent.Match($line)
                            if ($m.Success) {
                                $pct = [int]$m.Groups[1].Value
                                $script:lastPct = $pct
                                if ($pct -gt $pbMain.Value) {
                                    if ($pbMain.Value -eq 0 -and $pct -gt 0) {
                                        & $script:SetPhase "Escribiendo imagen ISO en disco..." ([System.Drawing.Color]::FromArgb(64, 196, 255))
                                    }
                                    # [FIX B1] Clampar al maximo para evitar ArgumentOutOfRangeException
                                    $pbMain.Value    = [Math]::Min($pct, $pbMain.Maximum)
                                    $lblPercent.Text = "$pct % completado"
                                    $lblPercent.Refresh()
                                    if ($pct -eq 100) {
                                        & $script:SetPhase "Optimizando almacenamiento y finalizando..." ([System.Drawing.Color]::FromArgb(255, 140, 0))
                                    }
                                }
                            }
                        }
                    }

                    if ($null -eq $script:buildDone -or -not $script:buildDone.IsSet) { return }

                    # ============================================================
                    # VACIADO FINAL Y CIERRE DE HILOS
                    # ============================================================
                    while ($script:outQueue.TryDequeue([ref]$line)) {
                        # Sin filtro: preservar blancos del stdout de oscdimg
                        $script:cleanLogBuilder.AppendLine($line) | Out-Null
                    }
                    while ($script:errQueue.TryDequeue([ref]$line)) {
                        if (-not [string]::IsNullOrWhiteSpace($line)) {
                            $script:errLogBuilder.AppendLine($line) | Out-Null
                            $m2 = $script:rxPercent.Match($line)
                            if ($m2.Success) { $script:lastPct = [int]$m2.Groups[1].Value }
                        }
                    }

                    # Inyectar la linea de porcentaje final en la posicion correcta del log.
                    # oscdimg escribe el progreso en stderr, separado del stdout, por lo que
                    # "100% complete" no aparece en el log de salida de forma natural.
                    # Se inserta despues de "Writing N files in M directories..." para que
                    # el log refleje exactamente el orden que se ve en consola.
                    if ($script:lastPct -gt 0) {
                        $rawLog  = $script:cleanLogBuilder.ToString()
                        $pctLine = "$($script:lastPct)% complete"
                        $rawLog  = [regex]::Replace(
                            $rawLog,
                            '(?im)(Writing \d+ files in \d+ directories[^\r\n]*)',
                            "`$1`r`n`r`n$pctLine"
                        )
                        [void]$script:cleanLogBuilder.Clear()
                        [void]$script:cleanLogBuilder.Append($rawLog)
                    }

                    # [FIX B2] Detener Y liberar pollTimer + ManualResetEventSlim.
                    if ($null -ne $script:pollTimer) {
                        try { $script:pollTimer.Stop()    } catch {}
                        try { $script:pollTimer.Dispose() } catch {}
                        $script:pollTimer = $null
                    }
                    try { $script:buildDone.Dispose() } catch {}
                    $script:buildDone = $null

                    $exitCode = 0
                    if ($null -ne $script:isoProc) {
                        try { $exitCode = $script:isoProc.ExitCode } catch { $exitCode = -1 }
                    }

                    # ==================== PATH EXITO ====================
                    if ($exitCode -eq 0) {
                        & $script:SetPhase "Calculando Hash SHA256 (esto puede tomar unos minutos)..." ([System.Drawing.Color]::FromArgb(255, 140, 0))

                        $script:hashRS = [runspacefactory]::CreateRunspace()
                        $script:hashRS.Open()
                        # [FIX C1] Inyectar la ruta via SessionStateProxy en lugar de AddArgument.
                        # AddArgument pasa el valor como elemento de pipeline ($input), no como
                        # argumento del param() declarado en el script-block -> $isoPath era $null.
                        $script:hashRS.SessionStateProxy.SetVariable('isoPath', $script:iso)
                        $script:hashPS = [powershell]::Create()
                        $script:hashPS.Runspace = $script:hashRS
                        [void]$script:hashPS.AddScript({
                            try {
                                $sha256   = (Get-FileHash -Path $isoPath -Algorithm SHA256).Hash
                                $hashFile = [System.IO.Path]::ChangeExtension($isoPath, '.sha256')
                                "$sha256  $([System.IO.Path]::GetFileName($isoPath))" | Out-File -FilePath $hashFile -Encoding ascii -Force
                                return $sha256
                            } catch {
                                return "ERROR: $($_.Exception.Message)"
                            }
                        })
                        $script:hashHandle = $script:hashPS.BeginInvoke()

                        $script:hashTimer          = New-Object System.Windows.Forms.Timer
                        $script:hashTimer.Interval = 200
                        $script:hashTimer.Add_Tick({
                            if (-not $script:hashHandle.IsCompleted) { return }

                            $script:hashTimer.Stop()
                            $script:hashTimer.Dispose()
                            $script:hashTimer = $null

                            # [FIX D1] EndInvoke devuelve PSDataCollection<PSObject>, no string directamente.
                            # Se extrae el primer elemento y se fuerza a string para evitar comparaciones
                            # y expansiones de cadena que funcionen por coercion implicita.
                            $script:lastBuildHash = [string]($script:hashPS.EndInvoke($script:hashHandle) | Select-Object -First 1)
                            try { $script:hashPS.Dispose() } catch {}
                            try { $script:hashRS.Close(); $script:hashRS.Dispose() } catch {}
                            $script:hashPS = $null; $script:hashRS = $null; $script:hashHandle = $null

                            if ($script:lastBuildHash -and $script:lastBuildHash -notmatch '^ERROR') {
                                Write-Log -LogLevel ACTION -Message "IsoCore: SHA-256 calculado: $script:lastBuildHash"
                            } else {
                                Write-Log -LogLevel WARN -Message "IsoCore: Fallo el calculo del hash SHA-256: $script:lastBuildHash"
                            }

                            $fullLogText = $script:cleanLogBuilder.ToString()

                            # ==============================================================================
                            # LIMPIEZA DE LOG (OSCDIMG)
                            # ==============================================================================
                            # 1. Agrupar la cabecera: Unir "Premastering Utility" con "Copyright"
                            $fullLogText = $fullLogText -replace "(?im)(Premastering Utility)\s+(Copyright)", "`$1`r`n`$2"

                            # 2. Agrupar las líneas de "Scanning source tree" (absorbiendo espacios invisibles finales)
                            $fullLogText = [regex]::Replace($fullLogText, '(?im)(Scanning source tree[^\r\n]*)\r?\n\s*(Scanning source tree complete)', "`$1`r`n`$2")

                            # 3. Agrupar las líneas de "Computing directory information"
                            $fullLogText = [regex]::Replace($fullLogText, '(?im)(Computing directory information[^\r\n]*)\r?\n\s*(Computing directory information complete)', "`$1`r`n`$2")
							
							# 4. Fijar estrictamente el espaciado alrededor del porcentaje (1 línea en blanco antes y después)                            $fullLogText = [regex]::Replace($fullLogText, '(?im)\s*(100% complete)\s+', "`r`n`r`n`$1`r`n`r`n")

                            # 5. Reducir cualquier exceso de saltos de línea (3 o más) a exactamente una línea en blanco (\r\n\r\n) en el resto del documento
                            $fullLogText = [regex]::Replace($fullLogText, '(\r?\n){3,}', "`r`n`r`n")

                            # 6. (Opcional) Restaurar un salto doble para separar el comando de la cabecera oscdimg
                            $fullLogText = $fullLogText -replace "----------------\r?\nOSCDIMG", "----------------`r`n`r`nOSCDIMG"

                            $script:lastBuildLog = $fullLogText

                            try {
                                $timestamp   = Get-Date -Format "yyyyMMdd_HHmmss"
                                $logFileName = "ISO_Build_$timestamp.log"
                                if ($null -ne $script:logDir) {
                                    $logPath = Join-Path $script:logDir $logFileName
                                    $fullLogText | Out-File -FilePath $logPath -Encoding utf8 -Force
                                    Write-Log -LogLevel ACTION -Message "IsoCore: Log de compilacion guardado en: $logPath"
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
                            $btnExportLog.ForeColor = [System.Drawing.Color]::White
                            & $script:SetPhase "ISO creada exitosamente en: $script:iso" ([System.Drawing.Color]::FromArgb(40, 200, 120))
                            $btnOpenFolder.Visible = $true

                            $lblFileInfo.Text = if ($mOptSaved.Success) {
                                "$cFiles archivos | $cDirs directorios | Optimizacion: $($mOptSaved.Groups[1].Value.Replace('Storage optimization saved ',''))"
                            } else {
                                "$cFiles archivos | $cDirs directorios"
                            }
                            if ($bAfter -gt 0) { $lblSizeInfo.Text = "Tamaño final: $strAfter ($bAfter bytes)" }

                            if ($script:lastBuildHash -and $script:lastBuildHash -notmatch '^ERROR') {
                                $lblHashInfo.Text      = "SHA-256:`n$script:lastBuildHash"
                                $lblHashInfo.ForeColor = [System.Drawing.Color]::FromArgb(40, 200, 120)
                            } else {
                                $lblHashInfo.Text      = "SHA-256: Error al calcular"
                                $lblHashInfo.ForeColor = [System.Drawing.Color]::Orange
                            }

                            $form.Refresh()

                            Write-Log -LogLevel ACTION -Message "IsoCore: ISO generada exitosamente. Archivos: $cFiles | Tamaño final: $strAfter | Espacio ahorrado: $strSaved | Destino: $script:iso"

                            $msgSummary  = "La imagen ISO se ha compilado exitosamente.`n`n"
                            $msgSummary += "ESTADISTICAS DE COMPILACION:`n"
                            $msgSummary += "-------------------------------------------------------------`n"
                            $msgSummary += " Archivos inyectados  : $cFiles (en $cDirs carpetas)`n"
                            $msgSummary += " Tamaño original      : $strBefore`n"
                            $msgSummary += " Tamaño optimizado    : $strAfter`n"
                            $msgSummary += " Espacio ahorrado     : $strSaved`n"
                            $msgSummary += "-------------------------------------------------------------`n`n"
                            $msgSummary += "Ruta de la imagen:`n$script:iso"
                            if ($script:lastBuildHash -and $script:lastBuildHash -notmatch '^ERROR') {
                                $msgSummary += "`n`nSHA-256:`n$script:lastBuildHash"
                            }
                            [System.Windows.Forms.MessageBox]::Show($msgSummary, "ISO Creada con Exito", 'OK', 'Information')

                            # [FIX B3] Cleanup con orden correcto por profundidad
                            & $script:CleanupInjectedFiles

                            if ($null -ne $script:isoProc) {
                                if (-not $script:isoProc.HasExited) { try { $script:isoProc.Kill() } catch {} }
                                $script:isoProc.Dispose(); $script:isoProc = $null
                            }
                            # [FIX B6] Solo EndInvoke + Dispose, sin Stop() previo
                            if ($null -ne $script:bgPS) {
                                try { $script:bgPS.EndInvoke($script:bgHandle) } catch {}
                                try { $script:bgPS.Dispose()                   } catch {}
                                $script:bgPS = $null
                            }
                            if ($null -ne $script:bgRunspace) {
                                try { $script:bgRunspace.Close(); $script:bgRunspace.Dispose() } catch {}
                                $script:bgRunspace = $null
                            }
                            $script:bgHandle = $null

                            & $script:RestoreCompileUI
                        })
                        $script:hashTimer.Start()

                    # ==================== PATH ERROR ====================
                    } else {
                        $script:cleanLogBuilder.AppendLine("`r`n=== ERRORES REPORTADOS ===") | Out-Null
                        $script:cleanLogBuilder.AppendLine($script:errLogBuilder.ToString())  | Out-Null
                        $script:lastBuildLog = $script:cleanLogBuilder.ToString()

                        Write-Log -LogLevel ERROR -Message "IsoCore: Fallo la compilacion. oscdimg retorno codigo de salida $exitCode."
                        $pbMain.Value    = 0
                        $lblPercent.Text = "Error (Codigo: $exitCode)"
                        $lblPercent.Refresh()
                        & $script:SetPhase "Fallo la compilacion. Codigo: $exitCode" ([System.Drawing.Color]::Crimson)
                        [System.Windows.Forms.MessageBox]::Show("Fallo la creacion de la ISO. Revisa el log para detalles.`nCodigo de Salida: $exitCode", "Error Critico", 'OK', 'Error')

                        # [FIX B3] Cleanup con orden correcto por profundidad
                        & $script:CleanupInjectedFiles

                        if ($null -ne $script:isoProc) {
                            if (-not $script:isoProc.HasExited) { try { $script:isoProc.Kill() } catch {} }
                            $script:isoProc.Dispose(); $script:isoProc = $null
                        }
                        # [FIX B6] Solo EndInvoke + Dispose, sin Stop() previo
                        if ($null -ne $script:bgPS) {
                            try { $script:bgPS.EndInvoke($script:bgHandle) } catch {}
                            try { $script:bgPS.Dispose()                   } catch {}
                            $script:bgPS = $null
                        }
                        if ($null -ne $script:bgRunspace) {
                            try { $script:bgRunspace.Close(); $script:bgRunspace.Dispose() } catch {}
                            $script:bgRunspace = $null
                        }
                        $script:bgHandle      = $null
                        $btnExportLog.Enabled = $true

                        & $script:RestoreCompileUI
                    }

                } catch {
                    Write-Log -LogLevel ERROR -Message "IsoCore: Error critico en el bucle de actualizacion de progreso: $($_.Exception.Message)"
                    # [FIX B2] Garantizar liberacion en el path de excepcion del propio tick
                    if ($null -ne $script:pollTimer) {
                        try { $script:pollTimer.Stop(); $script:pollTimer.Dispose() } catch {}
                        $script:pollTimer = $null
                    }
                    if ($null -ne $script:buildDone) {
                        try { $script:buildDone.Dispose() } catch {}
                        $script:buildDone = $null
                    }
                    Write-Warning "pollTimer encontro un error critico: $($_.Exception.Message)`nStack: $($_.Exception.StackTrace)"
                    & $script:RestoreCompileUI
                }
            }

            $script:pollTimer.Add_Tick($pollTickScript)
            $script:pollTimer.Start()

        } catch {
            Write-Log -LogLevel ERROR -Message "IsoCore: Excepcion no controlada en el motor de compilacion: $($_.Exception.Message)"
            & $script:SetPhase "Excepcion: $($_.Exception.Message)" ([System.Drawing.Color]::Crimson)
            [System.Windows.Forms.MessageBox]::Show("Excepcion: $_", "Crash", 'OK', 'Error')

            # [FIX B2] Liberar timer y buildDone en el catch exterior del btnMake
            if ($null -ne $script:pollTimer) {
                try { $script:pollTimer.Stop(); $script:pollTimer.Dispose() } catch {}
                $script:pollTimer = $null
            }
            if ($null -ne $script:buildDone) {
                try { $script:buildDone.Dispose() } catch {}
                $script:buildDone = $null
            }
            & $script:RestoreCompileUI
        }
    })

    # ------------------------------------------------------------------
    # 7. Botones de accion post-build
    # ------------------------------------------------------------------
    $btnExportLog.Add_Click({
        if (-not $script:lastBuildLog) {
            [System.Windows.Forms.MessageBox]::Show("No hay ningun log de compilacion disponible aun.`nRealiza una compilacion primero.", "Sin Log", 'OK', 'Information')
            return
        }
        $sfd          = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.Filter   = "Archivo de Log (*.txt)|*.txt|Todos los archivos (*.*)|*.*"
        $sfd.FileName = "IsoCore_Build_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
        if ($sfd.ShowDialog() -eq 'OK') {
            try {
                $script:lastBuildLog | Out-File -FilePath $sfd.FileName -Encoding utf8 -Force
                Write-Log -LogLevel ACTION -Message "IsoCore: Log exportado manualmente a: $($sfd.FileName)"
                [System.Windows.Forms.MessageBox]::Show("Log exportado correctamente en:`n$($sfd.FileName)", "Log Exportado", 'OK', 'Information')
            } catch {
                [System.Windows.Forms.MessageBox]::Show("Error al exportar el log:`n$($_.Exception.Message)", "Error", 'OK', 'Error')
            }
        }
    })

    $btnOpenFolder.Add_Click({
        $target = if ($script:iso) { Split-Path -Parent $script:iso } else { $null }
        if ($target -and (Test-Path -LiteralPath $target)) {
            Write-Log -LogLevel INFO -Message "IsoCore: El usuario abrio la carpeta de destino: $target"
            Invoke-Item -Path $target
        } else {
            [System.Windows.Forms.MessageBox]::Show("No se pudo determinar la carpeta de destino.", "Error", 'OK', 'Warning')
        }
    })

    # ------------------------------------------------------------------
    # 8. Evento FormClosing — [FIX B4]
    # Cleanup incondicional de runspaces DISM/Size al inicio, fuera de
    # cualquier condicional, para que se ejecute siempre independientemente
    # de si hay o no una compilacion activa.
    # ------------------------------------------------------------------
    $form.Add_FormClosing({
        # Cleanup incondicional: runspaces de analisis en background (DISM y Tamaño)
        foreach ($t in @($script:sizeTimer, $script:dismTimer)) {
            if ($null -ne $t) { try { $t.Stop(); $t.Dispose() } catch {} }
        }
        foreach ($p in @($script:sizePS, $script:dismPS)) {
            if ($null -ne $p) { try { $p.Stop(); $p.Dispose() } catch {} }
        }
        foreach ($r in @($script:sizeRS, $script:dismRS)) {
            if ($null -ne $r) { try { $r.Close(); $r.Dispose() } catch {} }
        }
        $script:sizeTimer = $null; $script:dismTimer = $null
        $script:sizePS    = $null; $script:dismPS    = $null
        $script:sizeRS    = $null; $script:dismRS    = $null

        # [FIX D3] Liberar ToolTip (no se disponia antes)
        if ($null -ne $tip -and -not $tip.IsDisposed) { try { $tip.Dispose() } catch {} }

        # Si hay compilacion activa, pedir confirmacion antes de abortar
        if ($null -ne $script:isoProc -and -not $script:isoProc.HasExited) {
            $res = [System.Windows.Forms.MessageBox]::Show(
                "La ISO se esta compilando en este momento.`nSi sales ahora, la operacion se cancelara y el archivo ISO quedara corrupto.`n`n¿Deseas forzar la salida?",
                "Advertencia de Interrupcion",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($res -eq 'No') {
                $_.Cancel = $true
            } else {
                Write-Log -LogLevel WARN -Message "IsoCore: El usuario forzo el cierre de la aplicacion durante la compilacion."

                if ($null -ne $script:pollTimer) {
                    try { $script:pollTimer.Stop(); $script:pollTimer.Dispose() } catch {}
                    $script:pollTimer = $null
                }
                if ($null -ne $script:hashTimer) {
                    try { $script:hashTimer.Stop(); $script:hashTimer.Dispose() } catch {}
                    $script:hashTimer = $null   # [FIX C2] Evitar ObjectDisposedException si el tick dispara post-cierre
                }
                if ($null -ne $script:buildDone) {
                    try { $script:buildDone.Dispose() } catch {}
                    $script:buildDone = $null
                }
                if ($null -ne $script:hashPS) { try { $script:hashPS.Stop(); $script:hashPS.Dispose() } catch {}; $script:hashPS = $null }
                if ($null -ne $script:hashRS) { try { $script:hashRS.Close(); $script:hashRS.Dispose() } catch {}; $script:hashRS = $null }

                if ($null -ne $script:bgPS) {
                    # [FIX B6] Sin Stop() previo a EndInvoke para evitar PipelineStoppedException
                    try { $script:bgPS.EndInvoke($script:bgHandle) } catch {}
                    try { $script:bgPS.Dispose()                   } catch {}
                }
                if ($null -ne $script:bgRunspace) {
                    try { $script:bgRunspace.Close(); $script:bgRunspace.Dispose() } catch {}
                }
                try { $script:isoProc.Kill() } catch {}
            }
        }
        if (-not $_.Cancel) {
            Write-Log -LogLevel INFO -Message "IsoCore: Sesion finalizada. Formulario cerrado por el usuario."
        }
    })

    # ------------------------------------------------------------------
    # 9. Mostrar y limpiar
    # ------------------------------------------------------------------
    $form.ShowDialog() | Out-Null
    $form.Dispose()
    [GC]::Collect()
}

Show-IsoMaker-GUI
