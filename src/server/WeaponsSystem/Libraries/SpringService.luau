-- SpringService.lua
-- Binds properties to spring simulations
-- @author Parker Stebbins <pstebbins@roblox.com>

local RunService = game:GetService('RunService')

local LinearSpring = {} do
	LinearSpring.__index = LinearSpring

	local pi = math.pi
	local exp = math.exp
	local sin = math.sin
	local cos = math.cos
	local sqrt = math.sqrt

	function LinearSpring.new(dampingRatio, frequency, goal)
		assert(
			dampingRatio*frequency >= 0,
			'No steady state solution for the given damping ratio & frequency'
		)

		return setmetatable(
			{
				d = dampingRatio, -- Damping ratio - Dimensionless
				f = frequency, -- Undamped frequency - Hertz
				g = goal, -- Goal position - Vector
				v = goal*0, -- Current velocity - Vector
			},
			LinearSpring
		)
	end

	function LinearSpring:setGoal(goal)
		self.g = goal
	end

	-- Sprint 3 (Sleep implementation):
	-- Antes devolvía siempre `false` → el RenderStepped global iteraba TODOS
	-- los springs aunque ya hubieran alcanzado el goal. UIs con muchos
	-- elementos animados pagaban update perpetuo (post-anim).
	--
	-- Ahora: spring duerme cuando ‖p - g‖² + ‖v‖² < SLEEP_THRESHOLD².
	-- El loop sale del state, evitando trabajo redundante en el resto del frame.
	-- Threshold pequeño (1e-4) elige seguridad sobre eagerness — un nuevo
	-- :Target() despierta el spring inmediatamente al re-insertarse en springStates.
	local SLEEP_THRESHOLD_SQ = 1e-4 * 1e-4

	function LinearSpring:canSleep(p)
		if not p then return false end
		local g = self.g
		local v = self.v
		local sumSq = 0
		for i = 1, #v do
			local dp = p[i] - g[i]
			local dv = v[i]
			sumSq += dp * dp + dv * dv
			if sumSq >= SLEEP_THRESHOLD_SQ then
				return false
			end
		end
		return true
	end

	function LinearSpring:step(dt, p0)

		-- Problem: Advance the spring simulation by t seconds.
		-- Start by taking the ODE of a damped harmonic oscillator:
		--    f^2*(X[t] - g) + 2*d*f*X'[t] + X''[t] = 0
		-- Where X[t] is position at time t, g is desired position, f is angular frequency, and d is damping ratio.
		-- Apply some constant initial conditions:
		--    X[0] = p0
		--    X'[0] = v0
		-- The IVP can now be solved to obtain analytic expressions for X[t] and X'[t].
		-- The solution takes on one of three forms depending on the value of d.

		local d = self.d
		local f = self.f*pi*2 -- cycle/s -> rad/s
		local g = self.g
		local v0 = self.v

		local o = p0 - g
		local decay = exp(-dt*d*f)

		local p1, v1

		if d == 1 then -- Critically damped

			p1 = (v0*dt + o*(f*dt + 1))*decay + g
			v1 = (v0 - (o*f + v0)*(f*dt))*decay

		elseif d < 1 then -- Underdamped

			local c = sqrt(1 - d*d)

			local i = cos(dt*f*c)
			local j = sin(dt*f*c)

			-- @todo improve stability as d approaches 1

			p1 = (o*i + (v0 + o*(d*f))*j/(f*c))*decay + g
			v1 = (v0*(i*c) - (v0*d + o*f)*j)*(decay/c)

		else -- Overdamped

			local c = sqrt(d*d - 1)

			local r1 = -f*(d - c)
			local r2 = -f*(d + c)

			-- @todo improve stability as d approaches 1

			local co2 = (v0 - o*r1)/(2*f*c)
			local co1 = o - co2

			local e1 = co1*exp(r1*dt)
			local e2 = co2*exp(r2*dt)

			p1 = e1 + e2 + g
			v1 = r1*e1 + r2*e2
		end

		self.v = v1

		return p1
	end
end

local LinearValue = {} do
	LinearValue.__index = LinearValue

	function LinearValue.new(...)
		return setmetatable(
			{
				...
			},
			LinearValue
		)
	end

	function LinearValue:__add(rhs)
		-- vector + vector
		assert(type(rhs) == 'table', 'rhs must be a table')

		local out = LinearValue.new(unpack(self))
		for i = 1, #out do
			out[i] = out[i] + rhs[i]
		end

		return out
	end

	function LinearValue:__sub(rhs)
		-- vector - vector
		assert(type(rhs) == 'table', 'rhs must be a table')

		local out = LinearValue.new(unpack(self))
		for i = 1, #out do
			out[i] = out[i] - rhs[i]
		end

		return out
	end

	function LinearValue:__mul(rhs)
		-- vector*scalar
		assert(type(rhs) == 'number', 'rhs must be a number')

		local out = LinearValue.new(unpack(self))
		for i = 1, #out do
			out[i] = out[i]*rhs
		end

		return out
	end

	function LinearValue:__div(rhs)
		-- vector/scalar
		assert(type(rhs) == 'number', 'rhs must be a number')

		local out = LinearValue.new(unpack(self))
		for i = 1, #out do
			out[i] = out[i]/rhs
		end

		return out
	end
end

local springMetadata = {
	-- Defines a spring type with functions for converting to/from values that the spring can digest
	number = {
		springType = LinearSpring,
		toIntermediate = function(value)
			return LinearValue.new(value)
		end,
		fromIntermediate = function(value)
			return value[1]
		end,
	},

	UDim = {
		springType = LinearSpring,
		toIntermediate = function(value)
			return LinearValue.new(value.Scale, value.Offset)
		end,
		fromIntermediate = function(value)
			return UDim.new(value[1], value[2])
		end,
	},

	UDim2 = {
		springType = LinearSpring,
		toIntermediate = function(value)
			local x = value.X
			local y = value.Y
			return LinearValue.new(x.Scale, x.Offset, y.Scale, y.Offset)
		end,
		fromIntermediate = function(value)
			return UDim2.new(value[1], value[2], value[3], value[4])
		end,
	},

	Vector2 = {
		springType = LinearSpring,
		toIntermediate = function(value)
			return LinearValue.new(value.X, value.Y)
		end,
		fromIntermediate = function(value)
			return Vector2.new(value[1], value[2])
		end,
	},

	Vector3 = {
		springType = LinearSpring,
		toIntermediate = function(value)
			return LinearValue.new(value.X, value.Y, value.Z)
		end,
		fromIntermediate = function(value)
			return Vector3.new(value[1], value[2], value[3])
		end,
	},
}

local springStates = {} -- {[object] = {[property] = Spring}

local steppedEvent = RunService:IsClient() and RunService.RenderStepped or RunService.Heartbeat
steppedEvent:Connect(function(dt)
	for object, state in pairs(springStates) do
		for name, spring in pairs(state) do
			local oldValue = object[name]
			local meta = assert(springMetadata[typeof(oldValue)], 'Unsupported spring type: ' .. typeof(oldValue))

			local oldIntermediate = meta.toIntermediate(oldValue)
			local newIntermediate = spring:step(dt, oldIntermediate)

			-- Sprint 3: pasar `newIntermediate` (posición canónica post-step) a
			-- canSleep. Sin esta posición el spring no podía evaluar si la
			-- distancia al goal era suficientemente pequeña para dormir.
			if spring:canSleep(newIntermediate) then
				state[name] = nil
			end

			object[name] = meta.fromIntermediate(newIntermediate)
		end

		if not next(state) then
			springStates[object] = nil
		end
	end
end)

local SpringService = {} do
	function SpringService:Target(object, dampingRatio, frequency, properties)
		local state = springStates[object]

		if not state then
			state = {}
			springStates[object] = state
		end

		for name, goal in pairs(properties) do
			local spring = state[name]

			local meta = assert(
				springMetadata[typeof(goal)],
				'Unsupported type: ' .. typeof(goal)
			)
			local intermediateGoal = meta.toIntermediate(goal)

			if spring then
				spring:setGoal(intermediateGoal)
			else
				spring = meta.springType.new(dampingRatio, frequency, intermediateGoal)
				state[name] = spring
			end
		end
	end

	function SpringService:Stop(object, property)
		if property then
			-- Unbind a property
			local state = springStates[object]
			if state then
				state[property] = nil
			end
		else
			-- Unbind all the properties
			springStates[object] = nil
		end
	end
end

return SpringService
