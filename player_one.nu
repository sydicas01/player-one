# ==============================================================================
# Player One - Radar de videojuegos en Steam (Nushell)
# ==============================================================================

# ------------------------------------------------------------------------------
# HELPERS INTERNOS
# ------------------------------------------------------------------------------

# Construye el header User-Agent leyendo el correo desde variable de entorno
def st-headers [] {
    let email = ($env.PLAYER_ONE_EMAIL? | default "" | str trim)
    if ($email | is-empty) {
        error make -u {
            msg: "Falta la variable de entorno PLAYER_ONE_EMAIL. Configúrala antes de continuar (ej: $env.PLAYER_ONE_EMAIL = 'tu_correo@ubiobio.cl')."
        }
    }
    { User-Agent: $"PlayerOne-UBB/1.0 \(($email)\)" }
}

# Petición GET controlada: envía User-Agent y detecta HTTP 429 y otros errores
def st-http-get [url: string] {
    let res = try {
        http get -ef -H (st-headers) $url
    } catch { |e|
        error make -u { msg: $"Error de conexión al consultar ($url): ($e.msg)" }
    }

    if $res.status == 429 {
        error make -u {
            msg: "Error HTTP 429 (Too Many Requests): Steam limitó las solicitudes. Detén las consultas repetidas y espera unos minutos."
        }
    }

    if $res.status != 200 {
        error make -u {
            msg: $"Error HTTP ($res.status) al consultar ($url)"
        }
    }

    if (($res.body | describe) | str starts-with "string") {
        $res.body | from json
    } else {
        $res.body
    }
}

# Convierte montos de Steam (multiplicados por 100) a valor numérico real
def st-normalizar-precio [monto_raw, moneda] {
    if ($monto_raw == null) {
        return null
    }
    if (($moneda | default "" | str uppercase) == "CLP") {
        ($monto_raw | into int) // 100
    } else {
        ($monto_raw | into int) / 100
    }
}

# Convierte la fecha de lanzamiento de Steam a tipo datetime de Nushell
def st-parse-fecha [fecha_str] {
    if ($fecha_str == null) or ($fecha_str | into string | str trim | is-empty) {
        return null
    }
    let limpia = (
        $fecha_str
        | into string
        | str lowercase
        | str replace -a "." ""
        | str replace -a "," ""
        | str replace -r '\bene\b' "jan"
        | str replace -r '\babr\b' "apr"
        | str replace -r '\bago\b' "aug"
        | str replace -r '\bsept\b' "sep"
        | str replace -r '\bdic\b' "dec"
        | str trim
    )
    try {
        $"($limpia) 00:00:00 +0000" | into datetime --format "%d %b %Y %H:%M:%S %z"
    } catch {
        try {
            $"($limpia) 00:00:00 +0000" | into datetime --format "%b %d %Y %H:%M:%S %z"
        } catch {
            null
        }
    }
}

# Obtiene la ficha cruda (appdetails) usando caché en disco con vigencia de 12 horas
def st-ficha-raw [
    appid: int
    --pais (-p): string = "CL"
    --idioma (-l): string = "spanish"
] {
    let dir_cache = (["data" "cache"] | path join)
    mkdir $dir_cache
    let archivo = (
        [$dir_cache $"appdetails_($appid)_($pais | str uppercase)_($idioma | str lowercase).json"]
        | path join
    )

    let usar_cache = if ($archivo | path exists) {
        let modificado = (ls $archivo | first | get modified)
        ((date now) - $modificado) < 12hr
    } else {
        false
    }

    let raw = if $usar_cache {
        open $archivo
    } else {
        let url = ({
            scheme: "https"
            host: "store.steampowered.com"
            path: "/api/appdetails"
            params: {
                appids: ($appid | into string)
                cc: $pais
                l: $idioma
            }
        } | url join)
        let resp = (st-http-get $url)
        let clave = ($appid | into string)
        let entrada_tmp = ($resp | get -o $clave)
        if ($entrada_tmp != null) and ($entrada_tmp.success? | default false) {
            $resp | to json | save -f $archivo
        }
        $resp
    }

    let clave = ($appid | into string)
    let entrada = ($raw | get -o $clave)
    if ($entrada == null) or (not ($entrada.success? | default false)) {
        error make -u {
            msg: $"Steam respondió success: false para el AppID ($appid) en país ($pais) - puede no existir o no estar disponible en esta región."
        }
    }
    $entrada.data
}

# ------------------------------------------------------------------------------
# 1.2.1 BUSCAR JUEGOS: st buscar <texto>
# ------------------------------------------------------------------------------
export def "st buscar" [
    texto: string                      # Texto de búsqueda en la tienda de Steam
    --pais (-p): string = "CL"         # País de la tienda (predeterminado: CL)
    --idioma (-l): string = "spanish"  # Idioma de la tienda (predeterminado: spanish)
    --limite (-n): int = 10            # Límite máximo de resultados
] {
    let url = ({
        scheme: "https"
        host: "store.steampowered.com"
        path: "/api/storesearch/"
        params: {
            term: $texto
            cc: $pais
            l: $idioma
        }
    } | url join)

    let resp = (st-http-get $url)
    let items = ($resp.items? | default [] | first $limite)

    $items | each { |it|
        let moneda = ($it.price?.currency? | default null)
        let precio_final = if ($it.price?.final? == null) {
            0
        } else {
            st-normalizar-precio $it.price.final $moneda
        }

        {
            appid: ($it.id | into int)
            nombre: $it.name
            tipo: $it.type
            moneda: $moneda
            precio_final: $precio_final
        }
    }
}

# ------------------------------------------------------------------------------
# 1.2.2 FICHA DE UN JUEGO: st juego <appid>
# ------------------------------------------------------------------------------
export def "st juego" [
    appid: int                         # AppID del juego en Steam (ej: 620, 730)
    --pais (-p): string = "CL"         # País de la tienda (predeterminado: CL)
    --idioma (-l): string = "spanish"  # Idioma de la ficha (predeterminado: spanish)
] {
    let data = (st-ficha-raw $appid --pais $pais --idioma $idioma)

    let es_gratis = ($data.is_free? | default false)
    let po = ($data.price_overview? | default null)

    let moneda = if ($po != null) { $po.currency? } else { null }
    let precio_inicial = if $es_gratis {
        0
    } else if ($po != null) {
        st-normalizar-precio $po.initial $moneda
    } else {
        null
    }
    let precio_final = if $es_gratis {
        0
    } else if ($po != null) {
        st-normalizar-precio $po.final $moneda
    } else {
        null
    }
    let descuento = if $es_gratis {
        0
    } else if ($po != null) {
        ($po.discount_percent | into int)
    } else {
        null
    }

    let desarrolladores = if ($data.developers? != null) {
        $data.developers | str join ", "
    } else {
        null
    }
    let generos = if ($data.genres? != null) {
        $data.genres | get description | str join ", "
    } else {
        null
    }

    {
        nombre: ($data.name? | default null)
        tipo: ($data.type? | default null)
        fecha_lanzamiento: (st-parse-fecha ($data.release_date?.date? | default null))
        desarrolladores: $desarrolladores
        generos: $generos
        moneda: $moneda
        precio_inicial: $precio_inicial
        precio_final: $precio_final
        descuento_pct: $descuento
        metacritic: ($data.metacritic?.score? | default null)
    }
}

# ------------------------------------------------------------------------------
# 1.2.3 JUGADORES CONECTADOS: st jugadores <appid>...
# ------------------------------------------------------------------------------
export def "st jugadores" [
    ...appids: int                     # Uno o más AppIDs de Steam
    --pais (-p): string = "CL"         # País para obtener el nombre en caché
    --idioma (-l): string = "spanish"  # Idioma para obtener el nombre en caché
] {
    if ($appids | is-empty) {
        error make -u { msg: "Debes proporcionar al menos un AppID." }
    }

    # Consultas estrictamente seriales (each) y sin caché para jugadores
    $appids | each { |id|
        let url = ({
            scheme: "https"
            host: "api.steampowered.com"
            path: "/ISteamUserStats/GetNumberOfCurrentPlayers/v1/"
            params: { appid: ($id | into string) }
        } | url join)

        let resp = (st-http-get $url)
        let jugadores = ($resp.response?.player_count? | default 0 | into int)

        let nombre = try {
            (st-ficha-raw $id --pais $pais --idioma $idioma).name
        } catch {
            null
        }

        {
            appid: $id
            nombre: $nombre
            jugadores: $jugadores
        }
    } | sort-by jugadores -r
}

# ------------------------------------------------------------------------------
# 1.2.4 LOGROS GLOBALES: st logros <appid>
# ------------------------------------------------------------------------------
export def "st logros" [
    appid: int                         # AppID del juego en Steam
    --raros (-r): int                  # Muestra los n logros menos desbloqueados
    --comunes (-c): int                # Muestra los n logros más desbloqueados
] {
    if ($raros != null) and ($comunes != null) {
        error make -u {
            msg: "Error de uso: no se pueden usar --raros (-r) y --comunes (-c) al mismo tiempo."
        }
    }

    let url = ({
        scheme: "https"
        host: "api.steampowered.com"
        path: "/ISteamUserStats/GetGlobalAchievementPercentagesForApp/v2/"
        params: { gameid: ($appid | into string) }
    } | url join)

    let resp = try {
        st-http-get $url
    } catch { |e|
        if ($e.msg | str contains "429") {
            error make -u { msg: $e.msg }
        }
        print $"El juego con AppID ($appid) no tiene logros globales disponibles."
        return []
    }

    let lista = ($resp.achievementpercentages?.achievements? | default [])
    if ($lista | is-empty) {
        print $"El juego con AppID ($appid) no tiene logros globales registrados."
        return []
    }

    let tabla = ($lista | each { |a|
        {
            logro: $a.name
            porcentaje: ($a.percent | into float)
        }
    })

    if ($raros != null) {
        $tabla | sort-by porcentaje | first $raros
    } else if ($comunes != null) {
        $tabla | sort-by porcentaje -r | first $comunes
    } else {
        $tabla
    }
}

# ------------------------------------------------------------------------------
# 1.2.5 REPORTAR UN JUEGO: st reportar <appid>
# ------------------------------------------------------------------------------
export def "st reportar" [
    appid: int                         # AppID del juego a reportar
    --pais (-p): string = "CL"         # País de la tienda
    --idioma (-l): string = "spanish"  # Idioma de la ficha
    --user-id: int = 1                 # Identificador userId para JSONPlaceholder
] {
    let ficha = (st juego $appid --pais $pais --idioma $idioma)
    let jug = (st jugadores $appid --pais $pais --idioma $idioma | first)

    let precio_txt = if ($ficha.precio_final == 0) {
        "Gratuito (0)"
    } else if ($ficha.precio_final == null) {
        "Sin precio disponible"
    } else {
        $"($ficha.precio_final) ($ficha.moneda | default '')" | str trim
    }

    let payload = {
        title: $ficha.nombre
        body: $"AppID: ($appid) | Precio: ($precio_txt) | Jugadores conectados: ($jug.jugadores)"
        userId: $user_id
    }

    let res = try {
        http post -ef -t application/json -H (st-headers) "https://jsonplaceholder.typicode.com/posts" ($payload | to json)
    } catch { |e|
        error make -u { msg: $"Error al enviar el reporte POST a JSONPlaceholder: ($e.msg)" }
    }

    if ($res.status < 200) or ($res.status >= 300) {
        error make -u { msg: $"JSONPlaceholder devolvió error HTTP ($res.status)" }
    }

    let cuerpo = if (($res.body | describe) | str starts-with "string") {
        $res.body | from json
    } else {
        $res.body
    }

    {
        codigo_http: $res.status
        respuesta: $cuerpo
    }
}

# ------------------------------------------------------------------------------
# 2.1.1 SELECCIÓN DE JUEGOS: st seleccionar
# ------------------------------------------------------------------------------
export def "st seleccionar" [
    --appids: list<int>                # Lista de AppIDs candidatos a evaluar
    --n: int = 10                      # Cantidad de juegos a conservar (mín. 10)
    --pais: string = "CL"              # País de la tienda
    --tipo: string = "game"            # Tipo de producto a conservar
    --min-jugadores: int = 500         # Mínimo de jugadores conectados al seleccionar
    --max-consultas: int = 80          # Máximo de fichas a consultar
    --idioma: string = "spanish"       # Idioma de la ficha
    --salida: string = "data/seleccion.csv" # Ruta del CSV de selección
] {
    if ($appids == null) or ($appids | is-empty) {
        error make -u {
            msg: "Debes entregar una lista de candidatos con --appids (ej: st seleccionar --appids [730 570 620])."
        }
    }

    let dir_raw = (["data" "raw"] | path join)
    let dir_cache = (["data" "cache"] | path join)
    mkdir $dir_raw
    mkdir $dir_cache

    mut revisados = 0
    mut consultas = 0
    mut omitidos_success_false = 0
    mut omitidos_tipo = 0
    mut omitidos_jugadores = 0
    mut omitidos_error = 0
    mut seleccion = []

    for $id in $appids {
        if ($seleccion | length) >= $n {
            break
        }
        if $consultas >= $max_consultas {
            break
        }

        $revisados = $revisados + 1
        $consultas = $consultas + 1

        # 1) Consultar ficha usando el caché de 12 horas
        let ficha_res = try {
            { ok: true, data: (st-ficha-raw $id --pais $pais --idioma $idioma), err: "" }
        } catch { |e|
            { ok: false, data: null, err: $e.msg }
        }

        if not $ficha_res.ok {
            if ($ficha_res.err | str contains "429") {
                error make -u { msg: $ficha_res.err }
            } else if ($ficha_res.err | str contains "success: false") {
                $omitidos_success_false = $omitidos_success_false + 1
            } else {
                $omitidos_error = $omitidos_error + 1
            }
            continue
        }

        let data = $ficha_res.data
        let tipo_juego = ($data.type? | default "")
        if $tipo_juego != $tipo {
            $omitidos_tipo = $omitidos_tipo + 1
            continue
        }

        # 2) Consultar jugadores conectados (serial y sin caché)
        let url_jug = ({
            scheme: "https"
            host: "api.steampowered.com"
            path: "/ISteamUserStats/GetNumberOfCurrentPlayers/v1/"
            params: { appid: ($id | into string) }
        } | url join)

        let jug_res = try {
            let r = (st-http-get $url_jug)
            { ok: true, n: ($r.response?.player_count? | default 0 | into int), err: "" }
        } catch { |e|
            { ok: false, n: 0, err: $e.msg }
        }

        if not $jug_res.ok {
            if ($jug_res.err | str contains "429") {
                error make -u { msg: $jug_res.err }
            }
            $omitidos_error = $omitidos_error + 1
            continue
        }

        if $jug_res.n < $min_jugadores {
            $omitidos_jugadores = $omitidos_jugadores + 1
            continue
        }

        # 3) Conservar juego: guardar ficha JSON y logros JSON en data/raw/
        let archivo_cache = (
            [$dir_cache $"appdetails_($id)_($pais | str uppercase)_($idioma | str lowercase).json"]
            | path join
        )
        let archivo_ficha_raw = ([$dir_raw $"ficha_($id).json"] | path join)
        open $archivo_cache | to json | save -f $archivo_ficha_raw

        let url_logros = ({
            scheme: "https"
            host: "api.steampowered.com"
            path: "/ISteamUserStats/GetGlobalAchievementPercentagesForApp/v2/"
            params: { gameid: ($id | into string) }
        } | url join)

        let logros_json = try {
            st-http-get $url_logros
        } catch { |e|
            if ($e.msg | str contains "429") {
                error make -u { msg: $e.msg }
            }
            { achievementpercentages: { achievements: [] } }
        }
        let archivo_logros_raw = ([$dir_raw $"logros_($id).json"] | path join)
        $logros_json | to json | save -f $archivo_logros_raw

        # 4) Extraer campos clave para seleccion.csv
        let es_gratis = ($data.is_free? | default false)
        let po = ($data.price_overview? | default null)
        let moneda = if ($po != null) { $po.currency? } else { if $es_gratis { "CLP" } else { null } }
        let precio_final = if $es_gratis {
            0
        } else if ($po != null) {
            st-normalizar-precio $po.final $moneda
        } else {
            0
        }

        $seleccion = ($seleccion | append {
            appid: $id
            nombre: ($data.name? | default "")
            tipo: $tipo_juego
            moneda: ($moneda | default "")
            precio_final: $precio_final
            gratis: (if $es_gratis { 1 } else { 0 })
            jugadores_seleccion: $jug_res.n
        })

        sleep 300ms
    }

    $seleccion | to csv | save -f $salida

    let total_omitidos = $omitidos_success_false + $omitidos_tipo + $omitidos_jugadores + $omitidos_error
    print "=== Resumen de selección (st seleccionar) ==="
    print $"Candidatos revisados: ($revisados) | fichas consultadas: ($consultas)/($max_consultas)"
    print $"Juegos conservados: ($seleccion | length)/($n)"
    print $"Omitidos en total: ($total_omitidos)"
    print $"  - success: false: ($omitidos_success_false)"
    print $"  - tipo distinto de '($tipo)': ($omitidos_tipo)"
    print $"  - menos de ($min_jugadores) jugadores: ($omitidos_jugadores)"
    print $"  - otros errores HTTP/red: ($omitidos_error)"
    if ($seleccion | length) < $n {
        print $"AVISO: No se completó la meta de ($n) juegos. Ajusta --appids, --min-jugadores o --max-consultas."
    }
    print $"Selección guardada en: ($salida)"

    $seleccion
}

# ------------------------------------------------------------------------------
# 2.1.2 MEDICIÓN HORARIA: st medir
# ------------------------------------------------------------------------------
export def "st medir" [
    --seleccion: string = "data/seleccion.csv" # CSV generado por st seleccionar
    --horas: int = 72                          # Cantidad de rondas horarias (mín. 72)
    --intervalo: duration = 1hr                # Intervalo entre rondas (predeterminado: 1hr)
] {
    if not ($seleccion | path exists) {
        error make -u { msg: $"No existe el archivo de selección '($seleccion)'. Ejecuta primero st seleccionar." }
    }

    let juegos = (open $seleccion)
    if ($juegos | is-empty) {
        error make -u { msg: "El archivo de selección está vacío." }
    }

    let dir_raw = (["data" "raw"] | path join)
    mkdir $dir_raw

    mut total_ok = 0
    mut total_faltantes = 0

    print $"Iniciando medición de ($juegos | length) juegos por ($horas) rondas | intervalo: ($intervalo)..."

    for $ronda in 1..$horas {
        let inicio_ronda = (date now)
        let marca_local = ($inicio_ronda | format date "%Y-%m-%d %H:%M:%S")
        print $"[Ronda ($ronda)/($horas) - ($marca_local)] Consultando ($juegos | length) juegos..."

        for $juego in $juegos {
            let id = ($juego.appid | into int)
            let ts_utc = (date now | date to-timezone UTC | format date "%Y%m%dT%H%M%SZ")
            let archivo = ([$dir_raw $"med_($id)_($ts_utc).json"] | path join)

            let url = ({
                scheme: "https"
                host: "api.steampowered.com"
                path: "/ISteamUserStats/GetNumberOfCurrentPlayers/v1/"
                params: { appid: ($id | into string) }
            } | url join)

            let res = try {
                { ok: true, body: (st-http-get $url), err: "" }
            } catch { |e|
                { ok: false, body: null, err: $e.msg }
            }

            if $res.ok {
                $res.body | to json | save -f $archivo
                $total_ok = $total_ok + 1
            } else {
                # Registra medición como faltante y continúa sin detener el bucle
                {
                    response: { player_count: null, result: 0 }
                    faltante: true
                    error: $res.err
                } | to json | save -f $archivo
                $total_faltantes = $total_faltantes + 1
                print $"  [FALLO] AppID ($id) en ($ts_utc): ($res.err) -> registrada como faltante"
            }

            sleep 400ms
        }

        if $ronda < $horas {
            let transcurrido = ((date now) - $inicio_ronda)
            if $transcurrido < $intervalo {
                sleep ($intervalo - $transcurrido)
            }
        }
    }

    print "=== Medición finalizada ==="
    print $"Mediciones exitosas: ($total_ok)"
    print $"Mediciones faltantes: ($total_faltantes)"
}

# ------------------------------------------------------------------------------
# 2.2 DEPURACIÓN: st depurar
# ------------------------------------------------------------------------------
export def "st depurar" [
    --dir-raw: string = "data/raw"                  # Carpeta con los JSON de mediciones
    --seleccion: string = "data/seleccion.csv"      # CSV de juegos seleccionados
    --salida-raw-csv: string = "data/mediciones_raw.csv" # CSV crudo generado con jq + parallel
    --salida-parquet: string = "data/depurada.parquet"   # Tabla depurada en Parquet
    --salida-csv: string = "data/depurada.csv"           # Tabla depurada en CSV
] {
    if not ($seleccion | path exists) {
        error make -u { msg: $"No existe '($seleccion)'. Ejecuta primero st seleccionar." }
    }

    let patron = ([$dir_raw "med_*.json"] | path join)
    let archivos = (glob $patron | sort)
    if ($archivos | is-empty) {
        error make -u { msg: $"No se encontraron archivos de medición en '($dir_raw)'." }
    }

    # 1) Convertir JSON locales a CSV usando jq y GNU Parallel (solo archivos locales)
    let jq_filter = r#'[(input_filename | split("/") | last | split(".") | first | split("_") | (.[1], .[2])), (.response.player_count // ""), (.response.result // "")] | @csv'#
    let cuerpo_csv = (
        $archivos
        | str join "\n"
        | ^parallel --will-cite --keep-order -q jq -r $jq_filter '{}'
    )
    let csv_completo = $"appid,ts_utc_raw,jugadores,result\n($cuerpo_csv)"
    $csv_completo | save -f $salida_raw_csv

    # 2) Leer CSV crudo y tipar fechas y números en Nushell
    let raw = (
        open $salida_raw_csv
        | each { |r|
            let dt_exacto = ($r.ts_utc_raw | into string | str replace "Z" "+0000" | into datetime --format "%Y%m%dT%H%M%S%z")
            let hora_key = ($dt_exacto | format date "%Y-%m-%dT%H:00:00+0000")
            let dt_hora = ($hora_key | into datetime --format "%Y-%m-%dT%H:%M:%S%z")

            let jug_raw = if ($r.jugadores == null) or (($r.jugadores | into string | str trim) | is-empty) {
                null
            } else {
                ($r.jugadores | into int)
            }
            let res_code = if ($r.result == null) or (($r.result | into string | str trim) | is-empty) {
                0
            } else {
                ($r.result | into int)
            }
            let es_valida = ($jug_raw != null) and ($jug_raw > 0) and ($res_code == 1)

            {
                appid: ($r.appid | into int)
                ts_exacto: $dt_exacto
                fecha_hora_utc: $dt_hora
                clave_hora: $"($r.appid)_($hora_key)"
                jugadores_raw: $jug_raw
                result: $res_code
                prioridad_valida: (if $es_valida { 0 } else { 1 })
            }
        }
    )

    let total_raw = ($raw | length)

    # 3) Deduplicar por (appid, hora_utc): prioriza medición válida y más temprana
    let dedup = (
        $raw
        | sort-by appid fecha_hora_utc prioridad_valida ts_exacto
        | uniq-by clave_hora
    )
    let descartadas_duplicadas = ($total_raw - ($dedup | length))

    # 4) Construir grilla horaria completa (min_hora .. max_hora) x juegos seleccionados
    let juegos = (
        open $seleccion
        | each { |j|
            {
                appid: ($j.appid | into int)
                nombre: ($j.nombre | into string)
                precio_final: ($j.precio_final | into int)
                gratis: ($j.gratis | into int)
            }
        }
    )

    let min_hora = ($dedup | get fecha_hora_utc | math min)
    let max_hora = ($dedup | get fecha_hora_utc | math max)

    mut horas_grid = []
    mut h_actual = $min_hora
    while $h_actual <= $max_hora {
        $horas_grid = ($horas_grid | append $h_actual)
        $h_actual = ($h_actual + 1hr)
    }

    # Indexar mediciones deduplicadas por clave (appid_horaUTC)
    let mapa_med = (
        $dedup
        | reduce --fold {} { |r, acc| $acc | upsert $r.clave_hora $r }
    )

    # 5) Armar tabla base, limpiar faltantes/anómalos y calcular variacion_prev y sube
    mut n_faltantes_api = 0
    mut n_faltantes_hueco = 0
    mut n_anomalos_cero = 0
    mut n_sin_prev = 0
    mut n_sin_next = 0
    mut n_empates = 0
    mut tabla_final = []

    for $juego in $juegos {
        let id = $juego.appid
        mut serie_juego = []

        for $dt_h in $horas_grid {
            let h_key = ($dt_h | format date "%Y-%m-%dT%H:00:00+0000")
            let clave = $"($id)_($h_key)"
            let med = ($mapa_med | get -o $clave)

            let jug_limpio = if ($med == null) {
                $n_faltantes_hueco = $n_faltantes_hueco + 1
                null
            } else if ($med.jugadores_raw == null) or ($med.result != 1) {
                $n_faltantes_api = $n_faltantes_api + 1
                null
            } else if ($med.jugadores_raw <= 0) {
                $n_anomalos_cero = $n_anomalos_cero + 1
                null
            } else {
                $med.jugadores_raw
            }

            let hora_cl = ($dt_h | date to-timezone "America/Santiago" | format date "%H" | into int)

            $serie_juego = ($serie_juego | append {
                appid: $id
                nombre: $juego.nombre
                fecha_hora_utc: $dt_h
                hora_chile: $hora_cl
                jugadores: $jug_limpio
                gratis: $juego.gratis
                precio_final: $juego.precio_final
            })
        }

        let n_horas = ($serie_juego | length)
        for $i in 0..($n_horas - 1) {
            let curr = ($serie_juego | get $i)

            # variacion_prev: ln(jug_t) - ln(jug_{t-1}) solo si existe hora inmediatamente anterior válida
            let var_prev = if ($i == 0) or ($curr.jugadores == null) {
                $n_sin_prev = $n_sin_prev + 1
                null
            } else {
                let prev = ($serie_juego | get ($i - 1))
                if ($prev.jugadores == null) or (($curr.fecha_hora_utc - $prev.fecha_hora_utc) != 1hr) {
                    $n_sin_prev = $n_sin_prev + 1
                    null
                } else {
                    ($curr.jugadores | math ln) - ($prev.jugadores | math ln)
                }
            }

            # sube: 1 si jug_{t+1} > jug_t, 0 en caso contrario (incluye empates)
            let sube_val = if ($i == ($n_horas - 1)) or ($curr.jugadores == null) {
                $n_sin_next = $n_sin_next + 1
                null
            } else {
                let nxt = ($serie_juego | get ($i + 1))
                if ($nxt.jugadores == null) or (($nxt.fecha_hora_utc - $curr.fecha_hora_utc) != 1hr) {
                    $n_sin_next = $n_sin_next + 1
                    null
                } else if $nxt.jugadores > $curr.jugadores {
                    1
                } else {
                    if $nxt.jugadores == $curr.jugadores {
                        $n_empates = $n_empates + 1
                    }
                    0
                }
            }

            $tabla_final = ($tabla_final | append {
                appid: $curr.appid
                nombre: $curr.nombre
                fecha_hora_utc: $curr.fecha_hora_utc
                hora_chile: $curr.hora_chile
                jugadores: $curr.jugadores
                variacion_prev: $var_prev
                gratis: $curr.gratis
                precio_final: $curr.precio_final
                sube: $sube_val
            })
        }
    }

    # 6) Guardar en CSV y Parquet (preservando tipos nativos en Parquet)
    $tabla_final | update fecha_hora_utc { |r| $r.fecha_hora_utc | format date "%Y-%m-%dT%H:%M:%SZ" } | to csv | save -f $salida_csv
    try {
        $tabla_final | update fecha_hora_utc { |r| $r.fecha_hora_utc | format date "%Y-%m-%dT%H:%M:%SZ" } | polars into-df --schema { appid: i64, nombre: str, fecha_hora_utc: str, hora_chile: i64, jugadores: f64, variacion_prev: f64, gratis: i64, precio_final: i64, sube: f64 } | polars save ($env.PWD | path join $salida_parquet)
    } catch { |e|
        print $"Aviso al guardar Parquet: ($e.msg) - se guardó el CSV correctamente."
    }

    let filas_totales = ($tabla_final | length)
    let filas_validas = ($tabla_final | where jugadores != null | length)
    let filas_modelables = ($tabla_final | where variacion_prev != null and sube != null | length)

    print "=== Resumen de depuración (st depurar) ==="
    print $"Archivos JSON procesados con jq + parallel: ($archivos | length)"
    print $"Filas crudas extraídas: ($total_raw)"
    print $"Duplicados en misma hora UTC descartados: ($descartadas_duplicadas)"
    print $"Horas en la grilla: ($horas_grid | length) | Filas totales: ($filas_totales)"
    print $"Mediciones válidas: ($filas_validas)"
    print $"Faltantes por error de API: ($n_faltantes_api)"
    print $"Faltantes por hueco horario: ($n_faltantes_hueco)"
    print $"Valores anómalos <= 0 jugadores: ($n_anomalos_cero)"
    print $"Filas sin variacion_prev: ($n_sin_prev)"
    print $"Filas sin sube: ($n_sin_next)"
    print $"Empates en horas consecutivas - sube = 0: ($n_empates)"
    print $"Filas completas para modelación: ($filas_modelables)"
    print $"Guardado en: ($salida_raw_csv), ($salida_csv) y ($salida_parquet)"

    $tabla_final
}

# ------------------------------------------------------------------------------
# 2.3 EXPLORACIÓN CON POLARS: st explorar
# ------------------------------------------------------------------------------
export def "st explorar" [
    --entrada: string = "data/depurada.csv"         # Tabla depurada generada por st depurar
    --dir-salida: string = "data/exploracion"       # Carpeta donde se guardan las tablas resumen
] {
    if not ($entrada | path exists) {
        error make -u { msg: $"No existe '($entrada)'. Ejecuta primero st depurar." }
    }

    mkdir $dir_salida

    # Normalizar tipos antes de pasar a Polars (convierte vacíos "" en null)
    let tabla_norm = (
        open $entrada
        | each { |r|
            let jug = if ($r.jugadores == null) or (($r.jugadores | into string | str trim) | is-empty) {
                null
            } else {
                ($r.jugadores | into float)
            }
            let sube_v = if ($r.sube == null) or (($r.sube | into string | str trim) | is-empty) {
                null
            } else {
                ($r.sube | into float)
            }
            {
                appid: ($r.appid | into int)
                nombre: ($r.nombre | into string)
                hora_chile: ($r.hora_chile | into int)
                jugadores: $jug
                gratis: ($r.gratis | into int)
                precio_final: ($r.precio_final | into float)
                sube: $sube_v
            }
        }
    )

    let df = (
        $tabla_norm
        | polars into-df --schema {
            appid: i64
            nombre: str
            hora_chile: i64
            jugadores: f64
            gratis: i64
            precio_final: f64
            sube: f64
        }
    )

    let df_validos = ($df | polars filter (polars col jugadores | polars is-not-null))

    # 1) Mediciones válidas y faltantes por juego (con Polars)
    let tot_por_juego = (
        $df
        | polars group-by [appid nombre]
        | polars agg [
            (polars col appid | polars count | polars as "total_horas")
        ]
        | polars collect
        | polars into-nu
    )

    let val_por_juego = (
        $df_validos
        | polars group-by [appid nombre]
        | polars agg [
            (polars col jugadores | polars count | polars as "validas")
            (polars col jugadores | polars mean | polars as "jugadores_prom")
            (polars col gratis | polars first | polars as "gratis")
            (polars col precio_final | polars first | polars as "precio_final")
        ]
        | polars collect
        | polars into-nu
    )

    let mapa_val = ($val_por_juego | reduce --fold {} { |r, acc| $acc | upsert ($r.appid | into string) $r })

    let resumen_juegos = (
        $tot_por_juego
        | each { |t|
            let v = ($mapa_val | get -o ($t.appid | into string))
            let validas = if ($v != null) { ($v.validas | into int) } else { 0 }
            let faltantes = (($t.total_horas | into int) - $validas)
            {
                appid: $t.appid
                nombre: $t.nombre
                gratis: (if ($v != null) { $v.gratis } else { null })
                precio_final: (if ($v != null) { ($v.precio_final | into int) } else { null })
                jugadores_prom: (if ($v != null) { ($v.jugadores_prom | math round -p 1) } else { null })
                validas: $validas
                faltantes: $faltantes
                pct_faltantes: (if $t.total_horas > 0 { (($faltantes / $t.total_horas) * 100 | math round -p 2) } else { 0.0 })
            }
        }
        | sort-by jugadores_prom -r
    )

    # 2) Promedio de jugadores por hora_chile para cada juego + índice relativo
    let por_juego_hora_raw = (
        $df_validos
        | polars group-by [appid nombre hora_chile]
        | polars agg [
            (polars col jugadores | polars mean | polars as "jugadores_prom_hora")
            (polars col jugadores | polars count | polars as "n_obs")
        ]
        | polars collect
        | polars into-nu
    )

    let por_juego_hora = (
        $por_juego_hora_raw
        | each { |r|
            let v = ($mapa_val | get -o ($r.appid | into string))
            let prom_j = if ($v != null) and ($v.jugadores_prom > 0) { $v.jugadores_prom } else { null }
            let idx = if ($prom_j != null) { ($r.jugadores_prom_hora / $prom_j | math round -p 4) } else { null }
            {
                appid: $r.appid
                nombre: $r.nombre
                hora_chile: $r.hora_chile
                jugadores_prom_hora: ($r.jugadores_prom_hora | math round -p 1)
                indice_relativo: $idx
                n_obs: $r.n_obs
            }
        }
        | sort-by appid hora_chile
    )

    # 3) Amplitud diaria de cada juego (max promedio horario / min promedio horario) con Polars
    let df_jh = ($por_juego_hora | polars into-df)
    let amplitud = (
        $df_jh
        | polars group-by [appid nombre]
        | polars agg [
            (polars col jugadores_prom_hora | polars max | polars as "max_prom_horario")
            (polars col jugadores_prom_hora | polars min | polars as "min_prom_horario")
        ]
        | polars collect
        | polars into-nu
        | each { |r|
            let amp = if ($r.min_prom_horario > 0) {
                ($r.max_prom_horario / $r.min_prom_horario | math round -p 3)
            } else {
                null
            }
            {
                appid: $r.appid
                nombre: $r.nombre
                min_prom_horario: ($r.min_prom_horario | math round -p 1)
                max_prom_horario: ($r.max_prom_horario | math round -p 1)
                amplitud_diaria: $amp
            }
        }
        | sort-by amplitud_diaria -r
    )

    # 4) Porcentaje de horas con sube == 1 según hora_chile (con Polars)
    let df_sube_valid = ($df | polars filter (polars col sube | polars is-not-null))
    let sube_por_hora = (
        $df_sube_valid
        | polars group-by hora_chile
        | polars agg [
            (polars col sube | polars mean | polars as "prop_sube")
            (polars col sube | polars count | polars as "n_obs")
        ]
        | polars collect
        | polars into-nu
        | each { |r|
            {
                hora_chile: $r.hora_chile
                pct_sube: (($r.prop_sube * 100) | math round -p 2)
                n_obs: $r.n_obs
            }
        }
        | sort-by hora_chile
    )

    # 5) Jugadores promedio según gratuito vs. de pago (con Polars) y relación con precio
    let por_gratis = (
        $df_validos
        | polars group-by gratis
        | polars agg [
            (polars col jugadores | polars mean | polars as "jugadores_prom")
            (polars col precio_final | polars mean | polars as "precio_prom_clp")
            (polars col jugadores | polars count | polars as "n_mediciones")
        ]
        | polars collect
        | polars into-nu
        | each { |r|
            {
                tipo_precio: (if $r.gratis == 1 { "Gratuito" } else { "De pago" })
                gratis: $r.gratis
                jugadores_prom: ($r.jugadores_prom | math round -p 1)
                precio_prom_clp: ($r.precio_prom_clp | math round -p 0)
                n_mediciones: $r.n_mediciones
            }
        }
        | sort-by gratis -r
    )

    # Correlación de Pearson entre precio_final y jugadores_prom (nivel juego)
    let calc_corr = { |filas|
        let n = ($filas | length)
        if $n < 2 {
            null
        } else {
            let mx = ($filas | get precio_final | math avg)
            let my = ($filas | get jugadores_prom | math avg)
            let num = ($filas | each { |r| ($r.precio_final - $mx) * ($r.jugadores_prom - $my) } | math sum)
            let dx = ($filas | each { |r| (($r.precio_final - $mx) ** 2) } | math sum | math sqrt)
            let dy = ($filas | each { |r| (($r.jugadores_prom - $my) ** 2) } | math sum | math sqrt)
            if ($dx * $dy) == 0 { null } else { ($num / ($dx * $dy) | math round -p 4) }
        }
    }

    let juegos_con_datos = ($resumen_juegos | where jugadores_prom != null)
    let corr_todos = (do $calc_corr $juegos_con_datos)
    let corr_pago = (do $calc_corr ($juegos_con_datos | where gratis == 0))

    # 6) Visualización en terminal: índice relativo promedio por hora_chile (barra ASCII)
    let ritmo_horario = (
        $df_jh
        | polars group-by hora_chile
        | polars agg [
            (polars col indice_relativo | polars mean | polars as "indice_medio")
        ]
        | polars collect
        | polars into-nu
        | sort-by hora_chile
        | each { |r|
            let ancho = (($r.indice_medio * 20) | math round | into int)
            let barra = (if $ancho > 0 { (1..$ancho | each { "#" } | str join "") } else { "" })
            {
                hora_chile: $r.hora_chile
                indice_relativo_medio: ($r.indice_medio | math round -p 3)
                grafico: $barra
            }
        }
    )

    # Guardar tablas resumen para el informe
    $resumen_juegos | to csv | save -f ([$dir_salida "resumen_juegos.csv"] | path join)
    $por_juego_hora | to csv | save -f ([$dir_salida "promedio_por_juego_hora.csv"] | path join)
    $amplitud | to csv | save -f ([$dir_salida "amplitud_diaria.csv"] | path join)
    $sube_por_hora | to csv | save -f ([$dir_salida "sube_por_hora.csv"] | path join)
    $por_gratis | to csv | save -f ([$dir_salida "gratis_vs_pago.csv"] | path join)
    $ritmo_horario | to csv | save -f ([$dir_salida "ritmo_horario.csv"] | path join)

    print "=== 1. Resumen por juego (mediciones válidas, faltantes y precio) ==="
    print ($resumen_juegos | table)

    print "\n=== 2. Jugadores promedio: Gratuito vs. De pago ==="
    print ($por_gratis | table)
    print $"Correlación precio_final vs jugadores_prom - todos los juegos: ($corr_todos)"
    print $"Correlación precio_final vs jugadores_prom - solo juegos de pago: ($corr_pago)"

    print "\n=== 3. Amplitud diaria por juego - max / min promedio horario ==="
    print ($amplitud | table)

    print "\n=== 4. Porcentaje de horas con sube = 1 según hora de Chile ==="
    if ($sube_por_hora | is-empty) {
        print "Aún no hay horas consecutivas suficientes para calcular sube."
    } else {
        print ($sube_por_hora | table)
    }

    print "\n=== 5. Visualización: Índice relativo promedio por hora de Chile ==="
    print ($ritmo_horario | table)

    print $"\nTablas de exploración guardadas en: ($dir_salida)/"

    {
        resumen_juegos: $resumen_juegos
        gratis_vs_pago: $por_gratis
        amplitud_diaria: $amplitud
        sube_por_hora: $sube_por_hora
        ritmo_horario: $ritmo_horario
        corr_todos: $corr_todos
        corr_pago: $corr_pago
    }
}

# ------------------------------------------------------------------------------
# 2.4 MODELACIÓN: st modelar (pre/post en Nushell; ajuste en motor_logistico.R)
# ------------------------------------------------------------------------------
export def "st modelar" [
    --entrada: string = "data/depurada.csv"         # Tabla depurada generada por st depurar
    --dir-modelo: string = "data/modelo"            # Carpeta para tablas de train/test y resultados
    --script-r: string = "motor_logistico.R"        # Script del motor externo en R
] {
    if not ($entrada | path exists) {
        error make -u { msg: $"No existe '($entrada)'. Ejecuta primero st depurar." }
    }
    if not ($script_r | path exists) {
        error make -u { msg: $"No existe el script del motor externo '($script_r)'." }
    }

    mkdir $dir_modelo

    # 1) Lectura y construcción de predictores en Nushell
    let pi = 3.141592653589793
    let e_const = 2.718281828459045
    let eps = 1e-15

    let tabla_base = (
        open $entrada
        | each { |r|
            let var_p = if ($r.variacion_prev == null) or (($r.variacion_prev | into string | str trim) | is-empty) {
                null
            } else {
                ($r.variacion_prev | into float)
            }
            let sube_v = if ($r.sube == null) or (($r.sube | into string | str trim) | is-empty) {
                null
            } else {
                ($r.sube | into int)
            }
            let jug_v = if ($r.jugadores == null) or (($r.jugadores | into string | str trim) | is-empty) {
                null
            } else {
                ($r.jugadores | into float)
            }
            {
                appid: ($r.appid | into int)
                nombre: ($r.nombre | into string)
                fecha_hora_utc: ($r.fecha_hora_utc | into datetime)
                hora_chile: ($r.hora_chile | into int)
                jugadores: $jug_v
                variacion_prev: $var_p
                gratis: ($r.gratis | into int)
                sube: $sube_v
            }
        }
    )

    # Estimación de ruido: % de pares consecutivos con variación relativa < 1%
    let pares_consecutivos = ($tabla_base | where variacion_prev != null)
    let n_pares = ($pares_consecutivos | length)
    let n_ruido_1pct = (
        $pares_consecutivos
        | where { |r| ((($e_const ** $r.variacion_prev) - 1.0) | math abs) < 0.01 }
        | length
    )
    let pct_ruido_1pct = if $n_pares > 0 {
        (($n_ruido_1pct / $n_pares) * 100 | math round -p 2)
    } else {
        null
    }

    # Filtrar filas modelables (tienen variacion_prev y sube) y crear sin/cos en Nushell
    let datos = (
        $tabla_base
        | where variacion_prev != null and sube != null
        | each { |r|
            let ang = (2.0 * $pi * ($r.hora_chile | into float) / 24.0)
            {
                appid: $r.appid
                nombre: $r.nombre
                fecha_hora_utc: $r.fecha_hora_utc
                hora_chile: $r.hora_chile
                sin_h: ($ang | math sin)
                cos_h: ($ang | math cos)
                variacion_prev: $r.variacion_prev
                gratis: $r.gratis
                sube: $r.sube
            }
        }
        | sort-by fecha_hora_utc appid
    )

    let horas_unicas = ($datos | get fecha_hora_utc | uniq | sort)
    let n_horas = ($horas_unicas | length)
    if $n_horas < 3 {
        error make -u {
            msg: $"Se necesitan al menos 3 horas completas con variacion_prev y sube para entrenar y evaluar. Actualmente hay ($n_horas) horas modelables."
        }
    }

    # 2) Partición cronológica 70% más antiguo / 30% más reciente (mismo corte para todos los juegos)
    let idx_corte = ((($n_horas | into float) * 0.7) | math floor | into int)
    let idx_corte_safe = if $idx_corte < 1 {
        1
    } else if $idx_corte >= $n_horas {
        $n_horas - 1
    } else {
        $idx_corte
    }
    let fecha_corte = ($horas_unicas | get ($idx_corte_safe - 1))

    let train = ($datos | where fecha_hora_utc <= $fecha_corte)
    let test = ($datos | where fecha_hora_utc > $fecha_corte)

    # Guardar tablas ya preparadas para el motor externo (solo columnas necesarias)
    let train_csv = ([$dir_modelo "train.csv"] | path join)
    let test_csv = ([$dir_modelo "test.csv"] | path join)
    let coef_csv = ([$dir_modelo "coeficientes.csv"] | path join)
    let pred_eta_csv = ([$dir_modelo "pred_eta_test.csv"] | path join)
    let tabla_hora_csv = ([$dir_modelo "tabla_hora.csv"] | path join)
    let metricas_csv = ([$dir_modelo "metricas.csv"] | path join)

    $train | select sube sin_h cos_h variacion_prev gratis | to csv | save -f $train_csv
    $test | select sin_h cos_h variacion_prev gratis | to csv | save -f $test_csv

    # 3) Invocar motor externo R únicamente para ajuste y cálculo del predictor lineal (eta)
    ^Rscript $script_r $train_csv $test_csv $coef_csv $pred_eta_csv

    # 4) Postprocesamiento en Nushell: convertir eta a probabilidades (sigmoide)
    let probs_logit = (
        open $pred_eta_csv
        | each { |r|
            let eta = ($r.eta | into float)
            if $eta >= 0.0 {
                1.0 / (1.0 + ($e_const ** (-1.0 * $eta)))
            } else {
                let z = ($e_const ** $eta)
                $z / (1.0 + $z)
            }
        }
    )

    # 5) Alternativa (a): proporción constante de sube en entrenamiento
    let p_const = ($train | get sube | math avg)

    # 6) Alternativa (b): proporción de sube por hora_chile en entrenamiento (fallback a p_const)
    let mapa_hora = (
        $train
        | group-by { |r| $r.hora_chile | into string }
        | transpose hora filas
        | reduce --fold {} { |it, acc|
            $acc | upsert $it.hora ($it.filas | get sube | math avg)
        }
    )

    # Guardar tabla completa de 24 horas (0..23) para usar en st pronostico
    let tabla_hora = (
        0..23
        | each { |h|
            let clave = ($h | into string)
            let obs_h = ($train | where hora_chile == $h | length)
            let p_h = ($mapa_hora | get -o $clave | default $p_const)
            {
                hora_chile: $h
                prob_sube: $p_h
                n_train: $obs_h
                usa_fallback: (if $obs_h == 0 { 1 } else { 0 })
            }
        }
    )
    $tabla_hora | to csv | save -f $tabla_hora_csv

    # 7) Calcular métricas en Nushell: exactitud (umbral 0.5) y log-loss con recorte [1e-15, 1-1e-15]
    let evaluar = { |nombre_mod, y_real, probs|
        let pares = ($y_real | zip $probs)
        let n = ($pares | length)
        let aciertos = (
            $pares
            | where { |par|
                let y = $par.0
                let pred = if $par.1 >= 0.5 { 1 } else { 0 }
                $y == $pred
            }
            | length
        )
        let suma_ll = (
            $pares
            | each { |par|
                let y = ($par.0 | into float)
                let p_raw = ($par.1 | into float)
                let p = if $p_raw < $eps {
                    $eps
                } else if $p_raw > (1.0 - $eps) {
                    1.0 - $eps
                } else {
                    $p_raw
                }
                -1.0 * ($y * ($p | math ln) + (1.0 - $y) * ((1.0 - $p) | math ln))
            }
            | math sum
        )
        {
            modelo: $nombre_mod
            exactitud: (($aciertos / $n) | math round -p 4)
            perdida_log: (($suma_ll / $n) | math round -p 4)
            n_prueba: $n
        }
    }

    let y_test = ($test | get sube)
    let probs_a = ($test | each { $p_const })
    let probs_b = ($test | each { |r| $mapa_hora | get -o ($r.hora_chile | into string) | default $p_const })

    let metricas = [
        (do $evaluar "(a) Constante (prop. train)" $y_test $probs_a)
        (do $evaluar "(b) Por hora_chile (train)" $y_test $probs_b)
        (do $evaluar "(c) Regresión logística (R)" $y_test $probs_logit)
    ]
    $metricas | to csv | save -f $metricas_csv

    # Composición de la muestra (participación de jugadores por juego)
    let validas = ($tabla_base | where jugadores != null)
    let total_jug = ($validas | get jugadores | math sum)
    let composicion = (
        $validas
        | group-by nombre
        | transpose nombre filas
        | each { |g|
            let suma_j = ($g.filas | get jugadores | math sum)
            {
                nombre: $g.nombre
                mediciones: ($g.filas | length)
                jugadores_prom: (($g.filas | get jugadores | math avg) | math round -p 1)
                pct_total_jugadores: (if $total_jug > 0 { (($suma_j / $total_jug) * 100 | math round -p 2) } else { 0.0 })
            }
        }
        | sort-by pct_total_jugadores -r
    )

    let coefs = (open $coef_csv)

    print "=== Resumen de modelación (st modelar) ==="
    print $"Horas modelables: ($n_horas) | Corte cronológico 70/30: ($fecha_corte | format date '%Y-%m-%d %H:%M UTC')"
    print $"Filas entrenamiento: ($train | length) | Filas prueba: ($test | length)"
    print $"Proporción sube en entrenamiento: (($p_const * 100) | math round -p 2)%"
    print $"Ruido - pares consecutivos con variación relativa < 1%: ($n_ruido_1pct)/($n_pares) = ($pct_ruido_1pct)%"

    print "\n=== Evaluación en conjunto de prueba ==="
    print ($metricas | table)

    print "\n=== Coeficientes del modelo logístico - motor R ==="
    print ($coefs | table)

    print "\n=== Composición de la muestra por juego ==="
    print ($composicion | table)
    print $"\nArtefactos del modelo guardados en: ($dir_modelo)/"

    {
        fecha_corte: $fecha_corte
        p_const: $p_const
        pct_ruido_1pct: $pct_ruido_1pct
        metricas: $metricas
        coeficientes: $coefs
        tabla_hora: $tabla_hora
        composicion: $composicion
    }
}

# ------------------------------------------------------------------------------
# PIPELINE COMPLETO: st pipeline (permite omitir la medición)
# ------------------------------------------------------------------------------
export def "st pipeline" [
    --appids: list<int>                  # Lista opcional de AppIDs para ejecutar st seleccionar
    --horas: int = 72                    # Horas de medición si no se omite la medición
    --omitir-medicion                    # Omite st medir y trabaja con los datos ya descargados
] {
    print "=== Iniciando pipeline Player One ==="

    if ($appids != null) and (not ($appids | is-empty)) {
        print "\n[1/5] Ejecutando st seleccionar..."
        st seleccionar --appids $appids | ignore
    } else if not ("data/seleccion.csv" | path exists) {
        error make -u { msg: "No existe data/seleccion.csv. Pasa --appids o ejecuta st seleccionar primero." }
    } else {
        print "\n[1/5] Usando selección existente en data/seleccion.csv"
    }

    if $omitir_medicion {
        print "\n[2/5] Medición omitida (--omitir-medicion): usando archivos existentes en data/raw/"
    } else {
        print $"\n[2/5] Ejecutando st medir por ($horas) horas..."
        st medir --horas $horas
    }

    print "\n[3/5] Ejecutando st depurar..."
    st depurar | ignore

    print "\n[4/5] Ejecutando st explorar..."
    st explorar | ignore

    print "\n[5/5] Ejecutando st modelar..."
    st modelar | ignore

    print "\n=== Pipeline finalizado correctamente ==="
}

# ------------------------------------------------------------------------------
# 3.1 COMANDO AVANZADO: st versus <appid1> <appid2>
# ------------------------------------------------------------------------------
export def "st versus" [
    appid1: int                        # Primer AppID a comparar
    appid2: int                        # Segundo AppID a comparar
    --pais (-p): string = "CL"         # País de la tienda
    --idioma (-l): string = "spanish"  # Idioma de la ficha
] {
    # Consultas seriales: jugadores en vivo sin caché + fichas con caché + logros
    let jugs_tabla = (st jugadores $appid1 $appid2 --pais $pais --idioma $idioma)

    let filas = ([$appid1 $appid2] | each { |id|
        let ficha = (st juego $id --pais $pais --idioma $idioma)
        let jug = ($jugs_tabla | where appid == $id | first | get jugadores)
        let logros = (st logros $id)

        let n_logros = ($logros | length)
        let rareza_prom = if $n_logros > 0 {
            ($logros | each { |l| 100.0 - $l.porcentaje } | math avg | math round -p 2)
        } else {
            null
        }

        let precio_num = ($ficha.precio_final | default 0 | into float)
        let denom = ((1.0 + ($precio_num / 1000.0)) | math ln) + 1.0
        let valor_precio = (((1.0 + ($jug | into float)) | math ln) / $denom | math round -p 4)

        {
            appid: $id
            nombre: $ficha.nombre
            moneda: ($ficha.moneda | default "CLP")
            precio_final: ($ficha.precio_final | default 0)
            jugadores: $jug
            n_logros: $n_logros
            rareza_prom_pct: $rareza_prom
            valor_por_precio: $valor_precio
        }
    })

    let j1 = ($filas | get 0)
    let j2 = ($filas | get 1)

    print "=== Comparación st versus ==="
    print "Indicador: valor_por_precio = ln(1 + jugadores) / [ln(1 + precio_CLP / 1000) + 1]"
    print ($filas | table)

    if $j1.valor_por_precio > $j2.valor_por_precio {
        let diff = (($j1.valor_por_precio - $j2.valor_por_precio) | math round -p 4)
        print $"\nMayor valor por precio: ($j1.nombre) [AppID ($j1.appid)] con ($j1.valor_por_precio) frente a ($j2.valor_por_precio) de ($j2.nombre) | ventaja: +($diff)"
    } else if $j2.valor_por_precio > $j1.valor_por_precio {
        let diff = (($j2.valor_por_precio - $j1.valor_por_precio) | math round -p 4)
        print $"\nMayor valor por precio: ($j2.nombre) [AppID ($j2.appid)] con ($j2.valor_por_precio) frente a ($j1.valor_por_precio) de ($j1.nombre) | ventaja: +($diff)"
    } else {
        print $"\nEmpate exacto en valor por precio: ($j1.valor_por_precio)"
    }

    $filas
}

# ------------------------------------------------------------------------------
# 3.2 COMANDO AVANZADO: st pronostico <appid>
# ------------------------------------------------------------------------------
export def "st pronostico" [
    appid: int                                       # AppID del juego monitoreado
    --depurada: string = "data/depurada.csv"         # Tabla depurada de la serie
    --dir-modelo: string = "data/modelo"             # Carpeta con tabla_hora.csv y coeficientes.csv
    --pais (-p): string = "CL"                       # País de la tienda
    --idioma (-l): string = "spanish"                # Idioma de la ficha
] {
    let tabla_hora_path = ([$dir_modelo "tabla_hora.csv"] | path join)
    let coef_path = ([$dir_modelo "coeficientes.csv"] | path join)

    if not ($depurada | path exists) {
        error make -u { msg: $"No existe '($depurada)'. Ejecuta primero st depurar." }
    }
    if (not ($tabla_hora_path | path exists)) or (not ($coef_path | path exists)) {
        error make -u { msg: $"Faltan artefactos del modelo en '($dir_modelo)'. Ejecuta primero st modelar." }
    }

    # 1) Buscar última medición válida del juego en la serie guardada
    let hist_juego = (
        open $depurada
        | where { |r| ($r.appid | into int) == $appid }
        | where { |r| ($r.jugadores != null) and (not (($r.jugadores | into string | str trim) | is-empty)) }
        | each { |r|
            {
                appid: ($r.appid | into int)
                nombre: ($r.nombre | into string)
                fecha_hora_utc: ($r.fecha_hora_utc | into datetime)
                jugadores: ($r.jugadores | into int)
                gratis: ($r.gratis | into int)
            }
        }
        | sort-by fecha_hora_utc
    )

    if ($hist_juego | is-empty) {
        error make -u {
            msg: $"El AppID ($appid) no tiene mediciones válidas en '($depurada)'. Usa uno de los juegos de data/seleccion.csv."
        }
    }

    let ultima = ($hist_juego | last)

    # 2) Consultar jugadores conectados ahora (en vivo, sin caché)
    let ahora_dt = (date now)
    let jug_ahora_reg = (st jugadores $appid --pais $pais --idioma $idioma | first)
    let jug_ahora = ($jug_ahora_reg.jugadores | into int)

    if $jug_ahora <= 0 {
        error make -u { msg: $"La consulta en vivo devolvió ($jug_ahora) jugadores para AppID ($appid); no se puede calcular logaritmo." }
    }

    let hora_cl = ($ahora_dt | date to-timezone "America/Santiago" | format date "%H" | into int)
    let horas_desde_ultima = ((($ahora_dt - $ultima.fecha_hora_utc) / 1hr) | math round -p 2)
    let var_prev = (($jug_ahora | math ln) - ($ultima.jugadores | math ln))

    # 3) Probabilidad según tabla por hora de Chile del pipeline
    let tabla_hora = (open $tabla_hora_path)
    let fila_h = ($tabla_hora | where { |r| ($r.hora_chile | into int) == $hora_cl } | first)
    let p_tabla = ($fila_h.prob_sube | into float)
    let usa_fallback = (($fila_h.usa_fallback | into int) == 1)

    # 4) Probabilidad según modelo logístico (calculada en Nushell con coeficientes de R)
    let coefs = (open $coef_path)
    let get_coef = { |nombre_term|
        let match_c = ($coefs | where termino == $nombre_term)
        if ($match_c | is-empty) { 0.0 } else { ($match_c | first | get estimado | into float) }
    }

    let pi = 3.141592653589793
    let e_const = 2.718281828459045
    let ang = (2.0 * $pi * ($hora_cl | into float) / 24.0)
    let sin_h = ($ang | math sin)
    let cos_h = ($ang | math cos)

    let b0 = (do $get_coef "(Intercept)")
    let b_sin = (do $get_coef "sin_h")
    let b_cos = (do $get_coef "cos_h")
    let b_var = (do $get_coef "variacion_prev")
    let b_gra = (do $get_coef "gratis")

    let eta = $b0 + ($b_sin * $sin_h) + ($b_cos * $cos_h) + ($b_var * $var_prev) + ($b_gra * ($ultima.gratis | into float))
    let p_logit = if $eta >= 0.0 {
        1.0 / (1.0 + ($e_const ** (-1.0 * $eta)))
    } else {
        let z = ($e_const ** $eta)
        $z / (1.0 + $z)
    }

    let diff_p = ($p_logit - $p_tabla)
    let pred_tabla = if $p_tabla >= 0.5 { "Sube" } else { "No sube" }
    let pred_logit = if $p_logit >= 0.5 { "Sube" } else { "No sube" }

    let motivo = if ($pred_tabla != $pred_logit) {
        "Difieren en dirección: el modelo logístico incorpora la variación reciente, si el juego es gratuito y una curva horaria suave, mientras que la tabla solo mira el promedio histórico puntual de esta hora."
    } else if ($diff_p | math abs) >= 0.10 {
        "Coinciden en dirección pero difieren en magnitud (>= 10 pp): la variación reciente o la suavización sinusoidal desplazan la probabilidad logística respecto al promedio de la hora."
    } else {
        "Coinciden en dirección y magnitud cercana (< 10 pp): el comportamiento reciente está alineado con el patrón horario histórico."
    }

    let resultado = {
        appid: $appid
        nombre: $ultima.nombre
        hora_chile_actual: $hora_cl
        jugadores_ultima_serie: $ultima.jugadores
        jugadores_ahora: $jug_ahora
        horas_desde_ultima: $horas_desde_ultima
        variacion_prev: ($var_prev | math round -p 5)
        gratis: $ultima.gratis
        prob_tabla_hora: ($p_tabla | math round -p 4)
        pred_tabla_hora: $pred_tabla
        tabla_usa_fallback: $usa_fallback
        prob_logistico: ($p_logit | math round -p 4)
        pred_logistico: $pred_logit
        diferencia_logit_menos_tabla: ($diff_p | math round -p 4)
        analisis_diferencia: $motivo
    }

    print "=== Pronóstico de subida para la próxima hora (st pronostico) ==="
    print $resultado
    $resultado
}

