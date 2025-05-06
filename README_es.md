# Proyecto EESSI Setup

Un conjunto completo de herramientas para configurar y mantener la infraestructura EESSI (European Environment for Scientific Software Installations), incluyendo despliegue de servidores Stratum 1, configuración de clientes y herramientas de monitorización.

## Descripción General

El Proyecto EESSI Setup proporciona un conjunto de scripts y herramientas para:

1. **Desplegar servidores EESSI Stratum 1** - Crear y mantener réplicas locales CVMFS del repositorio de software EESSI
2. **Configurar clientes EESSI** - Configurar fácilmente estaciones de trabajo y nodos de cómputo para acceder al software EESSI
3. **Monitorizar la infraestructura EESSI** - Seguimiento del rendimiento, estado de sincronización y salud de los componentes EESSI
4. **Integrar con entornos HPC** - Módulos de entorno y servicios del sistema para una integración perfecta con EESSI

EESSI (pronunciado "easy") proporciona un repositorio compartido de instalaciones de software científico que puede utilizarse en diferentes distribuciones Linux y arquitecturas de procesadores, desde portátiles hasta clusters HPC.

## Estructura del Proyecto

```
.
├── client
│   ├── bin
│   │   ├── eessi_client_setup.sh      # Script de instalación del cliente
│   │   └── eessi_diagnostics.sh       # Utilidad de diagnóstico del cliente
│   ├── modules
│   │   └── EESSI-2023.06.lua          # Archivo de módulo Lmod de ejemplo
│   └── systemd
│       └── eessi-mount.service        # Servicio systemd para montaje automático
├── README.md                          # Documentación principal del proyecto
└── stratum1
    └── bin
        ├── eessi_stratum1_monitoring.sh  # Utilidad de monitorización
        └── eessi_stratum1_setup.sh       # Script de despliegue de Stratum 1
```

## ¿Qué es EESSI?

El European Environment for Scientific Software Installations (EESSI) es un proyecto colaborativo que proporciona un stack común de software científico para sistemas HPC y otros entornos de computación. EESSI funciona como un servicio de streaming para software científico, haciéndolo disponible bajo demanda en diferentes plataformas.

Características principales:
- **Compatible entre sistemas** - Funciona en varias distribuciones Linux y arquitecturas de procesadores
- **Optimizado para rendimiento** - El software se compila con optimizaciones específicas para cada arquitectura
- **Fácil de desplegar y usar** - Requisitos mínimos del sistema y configuración sencilla
- **Mantenido por la comunidad** - Desarrollado y mantenido por centros HPC de toda Europa

EESSI utiliza el CernVM File System (CVMFS) para una distribución eficiente del software.

## Arquitectura CVMFS y EESSI

EESSI está construido sobre el CernVM File System (CVMFS), que proporciona un sistema de distribución de software fiable y escalable. La arquitectura consta de:

- **Servidor Stratum 0** - El repositorio central donde se publica el software
- **Servidores Stratum 1** - Puntos de distribución que replican el contenido desde Stratum 0
- **Clientes CVMFS** - Sistemas de usuario final que montan los repositorios

En esta arquitectura:
1. El software se publica en el servidor Stratum 0
2. Los servidores Stratum 1 se sincronizan periódicamente con Stratum 0
3. Los clientes se conectan a los servidores Stratum 1 para acceder al software
4. El almacenamiento en caché local garantiza un acceso eficiente al contenido utilizado con frecuencia

## Configuración y Gestión del Servidor Stratum 1

### Prerrequisitos

- Un servidor Linux con al menos 4GB de RAM y almacenamiento suficiente (recomendado 500GB+)
- Acceso root o sudo
- Conectividad de red a Internet y a las máquinas cliente
- Puerto abierto: 80 (HTTP)

### Instalación Básica

```bash
sudo stratum1/bin/eessi_stratum1_setup.sh
```

Este script:
1. Instalará las dependencias requeridas (Ansible, CVMFS, Apache)
2. Clonará el repositorio EESSI filesystem-layer
3. Configurará el servidor como una réplica Stratum 1
4. Configurará el servidor web
5. Verificará la instalación

### Opciones Avanzadas de Instalación

El script `eessi_stratum1_setup.sh` acepta varias variables para personalizar el despliegue:

```bash
# Usar ubicación de almacenamiento personalizada
CUSTOM_STORAGE_DIR="/data/cvmfs" sudo stratum1/bin/eessi_stratum1_setup.sh

# Habilitar GeoAPI para la redirección de clientes basada en la geografía
USE_GEOAPI="yes" sudo stratum1/bin/eessi_stratum1_setup.sh

# Especificar el repositorio a replicar
REPOSITORY="software.eessi.io" sudo stratum1/bin/eessi_stratum1_setup.sh
```

### Monitorización de Stratum 1

El script `eessi_stratum1_monitoring.sh` proporciona una monitorización completa para servidores EESSI Stratum 1.

Uso básico:
```bash
sudo stratum1/bin/eessi_stratum1_monitoring.sh
```

Esto:
1. Comprobará el tamaño y contenido del repositorio
2. Monitorizará la información del catálogo
3. Analizará el servidor web y las conexiones de clientes
4. Monitorizará el uso del espacio en disco
5. Comprobará la sincronización con Stratum 0

Opciones avanzadas:
```bash
# Generar informe HTML
sudo stratum1/bin/eessi_stratum1_monitoring.sh -o /var/www/html/eessi-report.html

# Generar informe y enviarlo por correo electrónico
sudo stratum1/bin/eessi_stratum1_monitoring.sh -o /var/www/html/eessi-report.html -e admin@example.org

# Comprobar con un servidor Stratum 0 específico
sudo stratum1/bin/eessi_stratum1_monitoring.sh -s cvmfs-stratum0.example.org
```

Para monitorización automatizada, configure un trabajo cron:
```bash
# Crear un trabajo cron para ejecutarse cada hora
echo "0 * * * * root /path/to/stratum1/bin/eessi_stratum1_monitoring.sh -o /var/www/html/eessi-report.html" | sudo tee /etc/cron.d/eessi-monitoring
```

### Mantenimiento de Stratum 1

#### Actualización del Contenido del Repositorio

Para activar manualmente la sincronización:
```bash
sudo cvmfs_server snapshot software.eessi.io
```

Para sincronizar todos los repositorios:
```bash
sudo cvmfs_server snapshot -a
```

#### Gestión del Almacenamiento

La ubicación de almacenamiento predeterminada para los repositorios CVMFS es `/srv/cvmfs`. Si el espacio de almacenamiento es escaso:

1. Compruebe el uso actual:
   ```bash
   df -h /srv/cvmfs
   ```

2. La recolección de basura se ejecuta automáticamente con cada snapshot, pero puede activarse manualmente:
   ```bash
   sudo cvmfs_server gc software.eessi.io
   ```

#### Ajuste de Rendimiento

Para servidores Stratum 1 con alta carga:

1. Ajustar la configuración de Apache:
   - Aumentar `MaxClients` en la configuración de Apache
   - Considerar el uso de MPM "worker" o "event" en lugar de "prefork"

2. Optimizar el rendimiento del sistema de archivos:
   - Considerar el uso de almacenamiento SSD para los datos del repositorio
   - Ajustar las opciones de montaje del sistema de archivos para un mejor rendimiento

### Solución de Problemas de Stratum 1

#### Problemas Comunes

1. **Fallos de sincronización**
   - Comprobar la conectividad de red a los servidores Stratum 0
   - Verificar que los servidores Stratum 0 son accesibles
   - Comprobar errores en `/var/log/cvmfs` o en el journal de systemd

2. **Problemas del servidor web**
   - Verificar la configuración de Apache: `sudo apachectl configtest`
   - Comprobar los logs de Apache: `/var/log/httpd/error_log` o `/var/log/apache2/error.log`
   - Reiniciar Apache: `sudo systemctl restart httpd` o `sudo systemctl restart apache2`

3. **Problemas de almacenamiento**
   - Asegurar suficiente espacio en disco para el crecimiento del repositorio
   - Comprobar errores en el sistema de archivos: `sudo fsck /dev/sdXY`
   - Monitorizar el rendimiento de I/O: `sudo iotop`

#### Herramientas de Diagnóstico

1. Comprobar el estado del repositorio:
   ```bash
   sudo cvmfs_server info software.eessi.io
   ```

2. Comprobar la salud del servidor:
   ```bash
   sudo cvmfs_server check software.eessi.io
   ```

3. Verificar la configuración del servidor web:
   ```bash
   curl -I http://localhost/cvmfs/software.eessi.io/.cvmfspublished
   ```

## Configuración y Gestión del Cliente

### Prerrequisitos

- Sistema operativo Linux (RHEL/CentOS/Rocky/Fedora o Debian/Ubuntu)
- Acceso root o sudo
- Conectividad de red a servidores EESSI Stratum 1

### Instalación Básica

```bash
sudo client/bin/eessi_client_setup.sh
```

Esto:
1. Instalará CVMFS y la configuración EESSI
2. Configurará CVMFS para acceder a los repositorios EESSI
3. Probará la conexión a los repositorios EESSI
4. Mostrará las versiones EESSI disponibles

### Opciones Avanzadas de Instalación

El script acepta varias variables de entorno para personalizar la instalación:

```bash
# Usar un servidor Stratum 1 específico
EESSI_STRATUM1_IP=10.1.12.5 sudo -E client/bin/eessi_client_setup.sh

# Configurar un tamaño de caché mayor (en MB)
EESSI_CACHE_SIZE=20000 sudo -E client/bin/eessi_client_setup.sh

# Usar una ubicación de caché personalizada
EESSI_CACHE_BASE=/data/cvmfs-cache sudo -E client/bin/eessi_client_setup.sh

# Especificar un archivo de log personalizado
EESSI_LOG_FILE=/var/log/eessi-client.log sudo -E client/bin/eessi_client_setup.sh

# Combinar múltiples opciones
EESSI_STRATUM1_IP=10.1.12.5 EESSI_CACHE_SIZE=20000 sudo -E client/bin/eessi_client_setup.sh
```

### Montaje Automático al Arranque

Para asegurar que los repositorios EESSI se monten correctamente cuando el sistema arranca:

```bash
# Copiar el archivo de servicio
sudo cp client/systemd/eessi-mount.service /etc/systemd/system/

# Habilitar e iniciar el servicio
sudo systemctl enable eessi-mount.service
sudo systemctl start eessi-mount.service
```

### Uso del Software EESSI

Después de la instalación, hay dos formas principales de acceder al software EESSI:

#### Inicialización Directa

```bash
source /cvmfs/software.eessi.io/versions/2023.06/init/bash
```

Esto inicializará el entorno EESSI para la sesión actual de shell, haciendo disponible todo el software EESSI.

#### Uso de Módulos de Entorno

Si su sistema utiliza módulos de entorno (como Lmod), puede usar el archivo de módulo proporcionado:

```bash
# Copiar el archivo de módulo a su directorio de módulos
sudo mkdir -p /etc/modulefiles/eessi
sudo cp client/modules/EESSI-2023.06.lua /etc/modulefiles/eessi/2023.06.lua

# Cargar el módulo EESSI
module load eessi/2023.06

# Listar software disponible
module avail

# Cargar software específico
module load Python/3.9.6
```

### Diagnóstico y Solución de Problemas del Cliente

Si encuentra problemas con el cliente EESSI, el script `eessi_diagnostics.sh` puede ayudar a identificar y resolver problemas comunes:

```bash
sudo client/bin/eessi_diagnostics.sh
```

#### Problemas Comunes

1. **Accesibilidad del repositorio**
   - Comprobar si el servicio cliente CVMFS está en ejecución: `systemctl status autofs`
   - Verificar la conectividad de red a los servidores Stratum 1 configurados
   - Probar el acceso directo al repositorio: `cvmfs_config probe software.eessi.io`

2. **Problemas de caché**
   - Asegurar suficiente espacio en disco para la caché
   - Comprobar los permisos de la caché: `ls -la $EESSI_CACHE_BASE`
   - Restablecer la caché si está corrupta: `cvmfs_talk -i software.eessi.io cleanup 0`

3. **Problemas de rendimiento**
   - Considerar el uso de un servidor Stratum 1 local para mejor rendimiento
   - Ajustar el tamaño de caché según sus patrones de uso
   - Asegurar que el cliente tiene RAM y ancho de banda de red adecuados

### Configuración Avanzada del Cliente

#### Configuración de Dominio Personalizada

Para entornos con sus propios servidores espejo EESSI, cree o modifique `/etc/cvmfs/domain.d/eessi.io.local`:

```bash
CVMFS_SERVER_URL="http://your-local-mirror.example.org/cvmfs/@fqrn@;${CVMFS_SERVER_URL}"
CVMFS_USE_GEOAPI=no
```

#### Configuración de Conexión Directa

Para asegurar que los clientes se conecten directamente a los servidores Stratum 1 sin ningún proxy intermedio:

```bash
echo 'CVMFS_HTTP_PROXY="DIRECT"' | sudo tee -a /etc/cvmfs/default.local
sudo cvmfs_config reload
```

## Ejemplo de Despliegue Completo

Este ejemplo demuestra una configuración completa con un servidor Stratum 1 local y múltiples clientes.

### Paso 1: Desplegar el Servidor Stratum 1

```bash
# En el servidor Stratum 1 (ej., 10.0.0.1)
git clone https://github.com/yourusername/eessi-setup.git
cd eessi-setup
sudo stratum1/bin/eessi_stratum1_setup.sh

# Verificar instalación
curl --head http://localhost/cvmfs/software.eessi.io/.cvmfspublished

# Configurar monitorización
sudo stratum1/bin/eessi_stratum1_monitoring.sh -o /var/www/html/eessi-report.html
echo "0 * * * * root $(pwd)/stratum1/bin/eessi_stratum1_monitoring.sh -o /var/www/html/eessi-report.html" | sudo tee /etc/cron.d/eessi-monitoring
```

### Paso 2: Desplegar Clientes

```bash
# En cada cliente
git clone https://github.com/yourusername/eessi-setup.git
cd eessi-setup

# Configurar con el servidor Stratum 1 local
EESSI_STRATUM1_IP=10.0.0.1 sudo -E client/bin/eessi_client_setup.sh

# Configurar auto-montaje
sudo cp client/systemd/eessi-mount.service /etc/systemd/system/
sudo systemctl enable eessi-mount.service
sudo systemctl start eessi-mount.service

# Configurar módulo de entorno
sudo mkdir -p /etc/modulefiles/eessi
sudo cp client/modules/EESSI-2023.06.lua /etc/modulefiles/eessi/2023.06.lua
```

### Paso 3: Probar la Configuración

```bash
# En cada cliente, probar el acceso al repositorio EESSI
cvmfs_config probe software.eessi.io

# Probar el acceso al software mediante inicialización directa
source /cvmfs/software.eessi.io/versions/2023.06/init/bash
python3 --version  # Ejemplo de uso de software proporcionado por EESSI

# Probar mediante módulos de entorno
module load eessi/2023.06
module avail  # Debería mostrar el software EESSI disponible
```

## Contribuir

¡Las contribuciones al Proyecto EESSI Setup son bienvenidas! Por favor, siéntase libre de enviar un Pull Request o abrir un Issue en GitHub.

## Licencia

Este proyecto está licenciado bajo la GNU General Public License v3.0 - consulte el archivo LICENSE para más detalles.

## Agradecimientos

- El proyecto EESSI: https://www.eessi.io/
- CernVM-FS: https://cernvm.cern.ch/fs/
- La comunidad HPC europea por su continuo apoyo y contribuciones

## Recursos Adicionales

- [Documentación EESSI](https://eessi.github.io/docs/)
- [Documentación CVMFS](https://cvmfs.readthedocs.io/)
- [Organización GitHub EESSI](https://github.com/EESSI)
