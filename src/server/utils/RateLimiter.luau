--!strict
--[[
	Rate limit por jugador para los handlers de red. Un limitador guarda, por
	jugador y por clave, cuándo se usó por última vez; la clave separa acciones que
	no deben bloquearse entre sí (p. ej. "buy" y "equip:<slot>").

	  tryConsume → comprueba y marca a la vez (marcar al entrar: el spam se corta
	               aunque la petición falle después).
	  isReady + mark → marcar solo tras un éxito real (una petición rechazada no
	               castiga al jugador).

	Las entradas de un jugador se borran solas al salir.
]]

local Players = game:GetService("Players")

export type RateLimiter = {
	tryConsume: (self: RateLimiter, player: Player, key: string?) -> boolean,
	isReady: (self: RateLimiter, player: Player, key: string?) -> boolean,
	mark: (self: RateLimiter, player: Player, key: string?) -> (),
	clearPlayer: (self: RateLimiter, userId: number) -> (),
	clearAll: (self: RateLimiter) -> (),
}

type Internal = RateLimiter & {
	_seconds: number,
	_lastByUserId: { [number]: { [string]: number } },
}

local DEFAULT_KEY = "_"

local RateLimiter = {}
RateLimiter.__index = RateLimiter

-- Claves débiles: un limitador que nadie referencia no se queda vivo por esto.
local _limiters: { [Internal]: true } = setmetatable({}, { __mode = "k" }) :: any

Players.PlayerRemoving:Connect(function(player: Player)
	for limiter in _limiters do
		limiter:clearPlayer(player.UserId)
	end
end)

function RateLimiter.new(seconds: number): RateLimiter
	local self = setmetatable({
		_seconds = seconds,
		_lastByUserId = {},
	}, RateLimiter) :: any
	_limiters[self] = true
	return self
end

function RateLimiter.isReady(self: Internal, player: Player, key: string?): boolean
	local byKey = self._lastByUserId[player.UserId]
	local last = if byKey then byKey[key or DEFAULT_KEY] else nil
	return last == nil or time() - last >= self._seconds
end

function RateLimiter.mark(self: Internal, player: Player, key: string?)
	local byKey = self._lastByUserId[player.UserId]
	if not byKey then
		byKey = {}
		self._lastByUserId[player.UserId] = byKey
	end
	byKey[key or DEFAULT_KEY] = time()
end

function RateLimiter.tryConsume(self: Internal, player: Player, key: string?): boolean
	if not self:isReady(player, key) then
		return false
	end
	self:mark(player, key)
	return true
end

function RateLimiter.clearPlayer(self: Internal, userId: number)
	self._lastByUserId[userId] = nil
end

function RateLimiter.clearAll(self: Internal)
	table.clear(self._lastByUserId)
end

return RateLimiter
