--!optimize 2
--!strict

local types = require(script.Parent.Parent.types)

local nothing = {
	Write = function() end;
	Read = function()
		return nil, 0
	end;
}

return function(): types.DataTypeInterface<nil>
	return nothing
end
