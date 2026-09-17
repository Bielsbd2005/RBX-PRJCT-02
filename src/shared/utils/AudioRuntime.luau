--!strict
--[[
	SoundService.Runtime: destino de los Sound clonados en runtime (pools), para
	no mezclar clones con los originales autorados en SoundService.Audio.
	No autorar nada aquí: `tools/audio/SetupSoundService.luau` la vacía.
]]

local SoundService = game:GetService("SoundService")

local FOLDER_NAME = "Runtime"

local AudioRuntime = {}

--- No usar FindFirstChild: puede haber un AudioPlayer hermano con el mismo nombre
--- que el Sound, y si sale primero el sonido no suena sin ningún error.
function AudioRuntime.findSound(parent: Instance?, name: string): Sound?
	if not parent then
		return nil
	end
	for _, child in parent:GetChildren() do
		if child.Name == name and child:IsA("Sound") then
			return child
		end
	end
	return nil
end

function AudioRuntime.folder(): Folder
	local existing = SoundService:FindFirstChild(FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = SoundService
	return folder
end

function AudioRuntime.clone(template: Sound): Sound
	local copy = template:Clone()
	copy.Parent = AudioRuntime.folder()
	return copy
end

return AudioRuntime
