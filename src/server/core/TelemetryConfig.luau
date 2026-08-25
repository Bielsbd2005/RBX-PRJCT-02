--!strict
--[[
	TelemetryConfig.luau
	Parámetros del pipeline de telemetría HTTP hacia el backend de GUNNERS
	Analytics. Es config pura: `TelemetryService` no hardcodea ningún número.

	Es la única salida de analítica del juego: el dual-write al AnalyticsService
	de Roblox (Creator Hub) se eliminó por ser WRITE-ONLY — no hay API pública
	para leer esos datos, así que no podía alimentar el dashboard.

	Vive en server/core (NO en shared/constants): es config puramente interna
	de TelemetryService y nada del cliente la necesita. Mantenerla fuera de
	ReplicatedStorage evita que un cliente pueda leer siquiera el NOMBRE del
	secreto o los parámetros de reintento/circuit breaker.

	Prerrequisitos operativos:
	  • "Allow HTTP Requests" activado en Game Settings.
	  • La clave registrada en el Secrets Store de Roblox bajo `SecretKey`.
	    `SecretKey` es solo el NOMBRE de esa entrada — HttpService:GetSecret
	    devuelve un objeto opaco cuyo valor nunca es legible desde Luau, ni
	    siquiera por el propio script. El valor real jamás toca este archivo.
	  • Studio SÍ alcanza `localhost`; un servidor de Roblox publicado NO.
	    Para producción hace falta un túnel (cloudflared/ngrok) o el VPS.
]]

local RunService = game:GetService("RunService")

export type TelemetryConfigType = {
	Enabled: boolean,
	IngestUrl: string,
	SecretKey: string,
	GameVersion: string,

	BatchMaxEvents: number,
	FlushIntervalSeconds: number,
	ServerFlushSeconds: number,
	QueueMaxEvents: number,
	RequestTimeoutSeconds: number,

	MaxRetries: number,
	BackoffBaseSeconds: number,
	BackoffMaxSeconds: number,
	CircuitBreakerThreshold: number,
	CircuitBreakerCooldownSeconds: number,

	ShutdownGraceSeconds: number,
	ShutdownDeadlineSeconds: number,

	Debug: boolean,
}

local TelemetryConfig: TelemetryConfigType = {
	-- Master switch. En false, TelemetryService se vuelve un no-op completo:
	-- no encola, no arranca loops y no hace requests.
	Enabled = true,

	-- Base del servicio de ingesta. El endpoint concreto es `/api/v1/telemetry/batch`.
	IngestUrl = "https://telemetria.bielsbd.com",

	-- Nombre de la entrada en el Secrets Store, NO el valor del secreto.
	SecretKey = "gunners_telemetry_key",

	-- Se envía en cada evento para poder segmentar métricas por release.
	GameVersion = "0.1.0",

	-- ── Batching ───────────────────────────────────────────────
	-- Un batch sale cuando se llena (BatchMaxEvents) o cuando vence el timer
	-- (FlushIntervalSeconds), lo que ocurra antes.
	BatchMaxEvents = 20,
	FlushIntervalSeconds = 5,

	-- Cada cuánto se emite el SERVER_FLUSH agregado. 300s = el diseño del
	-- documento de arquitectura. Con 6 jugadores por servidor esto es ~0.2
	-- req/min: un 0.04% del presupuesto de 500 req/min por servidor.
	ServerFlushSeconds = 300,

	-- Cola acotada: al desbordar se descarta lo MÁS VIEJO. La telemetría nunca
	-- puede hacer crecer la memoria del servidor sin límite.
	QueueMaxEvents = 200,

	RequestTimeoutSeconds = 10,

	-- ── Reintentos ─────────────────────────────────────────────
	-- El jitter no es opcional: a 12k CCU son ~2.000 servidores que reintentarían
	-- en sincronía si la ingesta cae (efecto manada).
	MaxRetries = 4,
	BackoffBaseSeconds = 2,
	BackoffMaxSeconds = 30,

	-- Tras N fallos consecutivos dejamos de intentarlo durante el cooldown.
	-- Evita quemar el presupuesto HTTP contra un backend caído.
	CircuitBreakerThreshold = 8,
	CircuitBreakerCooldownSeconds = 60,

	-- ── Apagado ────────────────────────────────────────────────
	-- DataService:BindToClose consume hasta 25s de la ventana de ~30s
	-- (core/data/DataService.luau). Roblox corre los callbacks de BindToClose
	-- EN PARALELO, así que el nuestro cabe holgadamente:
	--   Grace   → esperar a que ProfileUnloading encole los SESSION_END.
	--   Deadline→ tope duro para drenar la cola.
	ShutdownGraceSeconds = 2,
	ShutdownDeadlineSeconds = 10,

	-- Logs verbosos de batches enviados/fallidos. Dejar en false en producción.
	Debug = false,
}

--[[
	Overrides que SOLO aplican en Studio.

	Existen para que probar la telemetría no obligue a editar los valores de
	producción y acordarse de revertirlos — el riesgo real no es olvidar un
	`Debug = true`, es subir un `ServerFlushSeconds = 20` que multiplicaría por
	15 las peticiones de todos los servidores en vivo.

	En Studio interesa ver los eventos en segundos, no esperar cinco minutos.
]]
local STUDIO_OVERRIDES: { [string]: any } = {
	Debug = true,
	-- Un flush agregado cada 20s: suficiente para ver movimiento sin esperar.
	ServerFlushSeconds = 20,
	FlushIntervalSeconds = 2,
}

if RunService:IsStudio() then
	for key, value in STUDIO_OVERRIDES do
		(TelemetryConfig :: any)[key] = value
	end
end

return table.freeze(TelemetryConfig)
