# Player One: Radar de Videojuegos en Steam

Consola de monitoreo y pipeline reproducible de ciencia de datos sobre el catálogo y la actividad en vivo de Steam, desarrollada en **Nushell** con el plugin **`polars`** y **R** (`Rscript`) restringido exclusivamente al ajuste de regresión logística.

## Estructura del repositorio

- `player_one.nu`: módulo principal en Nushell con los comandos de consulta a Steam, las etapas del pipeline y los comandos avanzados.
- `motor_logistico.R`: script en R invocado por `st modelar` exclusivamente para ajustar `glm` y emitir el predictor lineal (`eta`).
- `data/`: selección maestra (`seleccion.csv`), mediciones crudas consolidadas (`mediciones_raw.csv`), serie depurada (`depurada.csv`, `depurada.parquet`), tablas de exploración (`exploracion/`) y artefactos del modelo (`modelo/`).
- `informe/`: memoria técnica en LaTeX (`informe.tex`) y documento compilado (`informe.pdf`).

## Requisitos e instalación

- **Nushell** (`0.116.0`) con plugin **`polars`** (`0.116.1`).
- **Git**, **curl**, **jq**, **GNU Parallel** y **R** (`Rscript` 4.3.3).

En Ubuntu / WSL2:

```bash
sudo apt update
sudo apt install -y git curl jq parallel r-base

```

## Configuración previa

Antes de ejecutar comandos que consultan la API de Steam, define la variable de entorno con un correo de contacto (para la cabecera User-Agent; nunca se guarda en el código) y carga el módulo en Nushell:

```bash
$env.PLAYER_ONE_EMAIL = "tu_correo@ejemplo.cl"
use player_one.nu *

```

## Uso de los comandos

### 1. Comandos sobre Steam

```bash
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

```

### 2. Pipeline reproducible (Observatorio)

```bash
# Seleccionar juegos desde una lista de AppIDs candidatos
st seleccionar --appids [730 570 440 230410 578080 620 105600 413150 252490 1245620]

# Medir jugadores conectados en serie por rondas horarias
st medir --horas 72

# Depurar JSON locales (jq + GNU Parallel) y generar CSV/Parquet
st depurar

# Explorar la serie de tiempo con Polars
st explorar

# Entrenar y evaluar modelos (pre/post en Nushell, ajuste logístico en R)
st modelar

# Ejecutar el pipeline completo omitiendo la medición (usa datos ya descargados)
st pipeline --omitir-medicion

```
### 3. Comandos avanzados

```bash
# Comparar dos juegos (precio, jugadores, rareza de logros e indicador valor/precio)
st versus 620 730

# Pronosticar probabilidad de subida en la próxima hora para un juego monitoreado
st pronostico 730
```

