# Player One: Radar de videojuegos en Steam

Consola de monitoreo y pipeline reproducible de ciencia de datos sobre el catálogo y actividad de Steam, desarrollada íntegramente en **Nushell** con el plugin `polars` y **R** (`Rscript`) como motor externo exclusivo para el ajuste de regresión logística.

## Requisitos e instalación

* **Nushell** (probado en versión `0.116.0`) con plugin **`polars`** (`0.116.1`).
* **Git**, **curl**, **jq**, **GNU Parallel** y **R** (`Rscript` 4.3.3).

En Ubuntu / WSL:
```bash
sudo apt update
sudo apt install -y git curl jq parallel r-base

Configuración previa
Antes de ejecutar comandos que consultan la API de Steam, define la variable de entorno con un correo de contacto (para la cabecera User-Agent; nunca se guarda en el código) y carga el módulo en Nushell:

$env.PLAYER_ONE_EMAIL = "tu_correo@ejemplo.cl"
use player_one.nu *

# Uso de los comandos
## 1. Comandos sobre Steam

# Buscar juegos en la tienda de Chile (CLP)
st buscar "portal" --pais CL --idioma spanish --limite 5

# Ficha de un juego (con caché en disco vigente por 12 horas)
st juego 620

# Jugadores conectados en tiempo real (serial, sin caché, ordenado de mayor a menor)
st jugadores 730 620 570

# Logros globales (más raros o más comunes; no usar ambos a la vez)
st logros 620 --raros 5
st logros 620 --comunes 5

# Enviar reporte JSON vía POST a JSONPlaceholder
st reportar 620

# 2. Pipeline reproducible (Observatorio)

# 2.1.1 Seleccionar 10 juegos desde una lista de AppIDs candidatos
st seleccionar --appids [730 570 440 230410 578080 620 105600 413150 252490 1245620]

# 2.1.2 Medir jugadores conectados cada hora por 72 horas consecutivas
st medir --horas 72

# 2.2 Depurar JSON locales (jq + GNU Parallel) y generar CSV/Parquet
st depurar

# 2.3 Explorar la serie de tiempo con Polars
st explorar

# 2.4 Entrenar y evaluar modelos (pre/post en Nushell, ajuste logístico en R)
st modelar

# Ejecutar el pipeline completo omitiendo la medición (usa datos ya descargados)
st pipeline --omitir-medicion

# 3. Comandos avanzados

# Comparar dos juegos (precio, jugadores, rareza de logros e indicador valor/precio)
st versus 620 730

# Pronosticar probabilidad de subida en la próxima hora para un juego monitoreado
st pronostico 730

