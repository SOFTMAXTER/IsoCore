# IsoCore v1.0.0 by SOFTMAXTER

<p align="center">
  <img width="350" height="150" alt="IsoCore Logo" src="https://github.com/user-attachments/assets/2672db7d-05d8-4666-a880-7ef9234fc242" />
</p>

## Descripción General
**IsoCore** es un motor desarrollado en PowerShell, provisto de una interfaz gráfica (GUI) robusta. Su propósito principal es la generación automatizada, controlada y segura de medios de instalación de Windows en formato ISO, garantizando una compatibilidad absoluta de arranque dual (Legacy BIOS y UEFI).

La herramienta está dirigida a ingenieros de sistemas, administradores de TI, técnicos de soporte y entusiastas del *modding* o *sysprep* de Windows (OEM customization). IsoCore resuelve la complejidad de empaquetar imágenes personalizadas (`.wim` o `.esd`), permitiendo inyectar respuestas desatendidas (OOBE) e integrar de forma transparente paquetes de personalización de marca o scripts de post-instalación. El proceso se ejecuta de forma fluida y optimizada.

## Características Principales
* **Arranque Dual Híbrido Estricto:** Generación de imágenes con sectores de arranque duales utilizando los binarios nativos del ADK: `etfsboot.com` (BIOS) y `efisys.bin` (UEFI), asegurando compatibilidad con hardware moderno y heredado.
* **Análisis DISM Inteligente:** Extracción de metadatos profundos de la imagen origen (`install.wim` o `install.esd`). El sistema autogenera etiquetas de volumen precisas basándose en la arquitectura, edición y lenguaje (ej. `CCCOMA_X64FRE_EN-US_DV9`).
* **Procesamiento en Segundo Plano:** El cálculo de directorios, la lectura en vivo de los logs del motor de compilación (`oscdimg.exe`) y la generación de hashes operan de manera transparente sin interrumpir el uso de la aplicación principal.
* **Inyección Automatizada OOBE:** Capacidad de seleccionar un archivo XML de respuesta desatendida (`autounattend.xml`) e inyectarlo dinámicamente en la raíz del medio de instalación temporal antes de la compilación.
* **Integración Nativa con MRP:** Módulo dedicado para la búsqueda, extracción y despliegue automático de paquetes *Multi OEM/Retail Project* directamente en el directorio `\sources` de la imagen. 
* **Sanitización Estricta UDF:** Motor de validación de texto en tiempo real para asegurar que la etiqueta de volumen cumpla con los estándares rigurosos ISO 9660 / UDF (máximo 32 caracteres, conversión a mayúsculas, restricción a caracteres alfanuméricos y guiones).
* **Verificación de Integridad:** Cálculo automático y exportación del Hash SHA-256 de la imagen ISO resultante para verificar la integridad del medio antes de su despliegue físico.
* **Sistema de Limpieza (Cleanup):** Algoritmo que garantiza la eliminación segura de archivos temporales inyectados tras finalizar o cancelar la tarea, manteniendo limpio el directorio de origen.
* **Registro de Eventos (Logging):** Generación automática de logs detallados (`Registro.log` y logs de compilación por fecha) para auditar cada fase del proceso y facilitar la depuración de errores.

## Requisitos
Para garantizar el correcto funcionamiento del motor de compilación, el entorno de ejecución debe cumplir estrictamente con lo siguiente:
* **Sistema Operativo:** Windows 10 o Windows 11 (Arquitectura de 64 bits recomendada).
* **Permisos:** Ejecución con privilegios elevados de Administrador. Necesario para eludir las restricciones de lectura/escritura en directorios del sistema.
* **Dependencia del Motor de Compilación:** La herramienta requiere el binario `oscdimg.exe`. Si no se detecta en las rutas estándar de instalación, el sistema pedirá al usuario que lo localice manualmente mediante un cuadro de diálogo.
  * ⚠️ **Aclaración sobre oscdimg.exe:** El proyecto incluye una copia de `oscdimg.exe` en la carpeta `Tools/` con fines estrictamente prácticos para que puedas probar la herramienta inmediatamente tras descargarla. Sin embargo, se recomienda encarecidamente eliminar este archivo del directorio y utilizar el motor original descargando e instalando el [Windows Assessment and Deployment Kit (ADK) oficial de Microsoft](https://learn.microsoft.com/es-es/windows-hardware/get-started/adk-install).

## Modo de Uso y Estructura

### Estructura de Directorios
Para un despliegue adecuado y detección automática de componentes (como herramientas de terceros y paquetes MRP), respeta la siguiente jerarquía de archivos:

    TuCarpetaPrincipal/
    │
    ├── IsoCore.exe            <-- Ejecutable Lanzador
    ├── Tools/                 <-- Directorio clave para dependencias:
    │   ├── oscdimg.exe        <-- (Ver aclaración en sección Requisitos)
    │   └── Archivo_MRP.zip    <-- Archivo comprimido del paquete Multi OEM/Retail Project
    └── Script/
        │
        ├── IsoCore.ps1        <-- Código fuente principal de la aplicación

### Flujo de Ejecución y Menú Principal
1. **Configuración de Imagen:** Utiliza el explorador para definir la **Carpeta Origen** (debe contener la estructura extraída de una ISO de Windows: `boot\`, `efi\`, `sources\`). Luego, define la ruta de salida del **Archivo ISO Destino**.
2. **Automatización OOBE (Opcional):** Define un archivo de configuración desatendida, o habilita la casilla de inyección MRP para desplegar herramientas OEM automáticas.
3. **Validación de Origen:** Observa el panel de telemetría. La herramienta verificará en tiempo real la existencia de los binarios de arranque, calculará el peso de los archivos a compilar y validará si existe espacio suficiente en el disco destino.
4. **Compilación:** Haz clic en "CREAR ISO BOOTEABLE". El panel derecho mostrará la consola de progreso interceptando la salida nativa de `oscdimg`, finalizando con la validación SHA-256.

## Componentes de Terceros y Créditos Adicionales

### Proyecto MRP (Multi OEM/Retail Project)
IsoCore incluye soporte nativo y automatizado para inyectar este poderoso conjunto de herramientas. Es importante destacar que el paquete MRP es un proyecto externo e independiente. Todo el crédito por el desarrollo, el mantenimiento y la evolución continua de los scripts integrados en MRP corresponde enteramente a su creador y a la comunidad que lo respalda.

⚠️ **Aviso de Uso y Alcance Educativo:** El paquete MRP proporcionado mediante este enlace: https://acortar.link/dFE5TE está diseñado y configurado para utilizarse **únicamente para la inyección de logotipos e información de soporte OEM** de los fabricantes de hardware. Su inclusión tiene fines estrictamente **educativos** e ilustrativos sobre cómo funciona el despliegue desatendido en entornos corporativos. IsoCore no promueve ni asume responsabilidad por la modificación manual de dicho paquete para alterar mecanismos de licenciamiento.

* 📥 **Obtén las últimas actualizaciones de MRP y da soporte a su creador original visitando el foro oficial en:** [My Digital Life (MDL) Forums](https://forums.mydigitallife.net/threads/multi-oem-retail-project-mrp-mk3.71555/) *(Requiere registro en la comunidad).*

## Notas de Seguridad y Mejores Prácticas
* **Falsos Positivos (Antivirus):** Si utilizas la inyección del paquete MRP, es **absolutamente crítico** desactivar temporalmente la protección en tiempo real de Windows Defender o de tu suite de seguridad de terceros. Incluso las configuraciones básicas de inyección OEM en scripts desatendidos suelen ser clasificadas sistemáticamente como falsos positivos (heurística). Si el antivirus interviene durante la extracción en la carpeta `\sources`, archivos vitales serán puestos en cuarentena de forma silenciosa, resultando en una ISO corrupta que fallará durante la instalación de Windows.
* **Manejo de Espacio en Disco:** Una imagen moderna de Windows modificada puede superar los 6 GB. Asegúrate de tener un mínimo de 10 GB de espacio libre en la partición donde se guardará el archivo `.iso` final para permitir un buffer adecuado durante el proceso de optimización.
* **Manipulación Manual durante Compilación:** No abras, modifiques, ni bloquees ningún archivo de la carpeta origen mientras la herramienta esté trabajando en la generación de la imagen.

## Apoya el Proyecto
El desarrollo de estas herramientas de automatización y sus interfaces nativas requiere cientos de horas de ingeniería y pruebas continuas. Si IsoCore ha optimizado tu flujo de trabajo, ahorrándote tiempo y dolores de cabeza en tus despliegues, considera apoyar el desarrollo continuo:

* [💳 Donar vía PayPal](https://www.paypal.com/donate/?hosted_button_id=U65G2GXDTUGML)

## Autor y Colaboradores
* **Autor Principal:** SOFTMAXTER
* **Contacto y Blog:** [Visita el blog oficial de SOFTMAXTER](https://softmaxter.blogspot.com/)
* **Análisis y refinamiento de código:** Realizado en colaboración con **Gemini** para garantizar la estabilidad, eficiencia y calidad del script.

## Cómo Contribuir
Si eres desarrollador, sysadmin o entusiasta, tus contribuciones son bienvenidas para hacer este motor aún más robusto:
1. Realiza un *Fork* de este repositorio.
2. Crea una rama descriptiva para tu función (`git checkout -b feature/NuevaMejora`).
3. Haz *Commit* de tus cambios asegurándote de documentar el código (`git commit -m 'Añade nueva validación de directorios'`).
4. Haz *Push* a tu rama (`git push origin feature/NuevaMejora`).
5. Abre un *Pull Request* explicando detalladamente la lógica de tu modificación.

## Reporte de Errores y Soporte
Si experimentas un cierre inesperado, un fallo de compilación o un comportamiento anómalo en la interfaz, el sistema de registro (*Logging*) interno de la herramienta es vital para ayudarnos a diagnosticar el problema. 

Para agilizar la resolución, por favor sigue estos pasos al abrir un *Issue* en GitHub:
1. **Fallo de Compilación:** Si la creación de la ISO falla, utiliza el botón **"Exportar Log"** en la interfaz para guardar el archivo `.txt` y adjúntalo a tu reporte.
2. **Fallo de la Interfaz/Script:** Si el error ocurre antes de compilar (ej. no se detecta la carpeta, falla el análisis), dirígete a la carpeta `Logs/` dentro del directorio del proyecto y adjunta el archivo **`Registro.log`**.
3. **Detalles del Entorno:** Incluye siempre tu versión de Windows, la versión del ADK que tienes instalada y los pasos exactos que realizaste antes de que ocurriera el fallo.

## Descargo de Responsabilidad
Este script y su código fuente se proporcionan "tal cual" (as is), sin garantías de ningún tipo, explícitas o implícitas, incluyendo pero no limitándose a las garantías de comerciabilidad e idoneidad para un propósito particular. El autor (SOFTMAXTER) no asume ninguna responsabilidad por pérdida de datos, imágenes ISO corruptas, interrupción de la actividad comercial o cualquier fallo en el despliegue del sistema operativo resultante del uso o incapacidad de uso de esta herramienta. Se recomienda encarecidamente probar exhaustivamente cualquier imagen generada en un entorno de máquina virtual (Hyper-V, VirtualBox, VMware) antes de su implementación en equipos físicos o entornos de producción.
