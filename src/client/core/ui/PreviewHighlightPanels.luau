--!strict
-- Paneles del lobby (hijos directos de PlayerGui.UserInterface) que ocultan el contorno
-- de los previews 3D mientras están abiertos. Lista única compartida por LobbyCharacterPreview
-- y WeaponPreviewController. El Locker se excluye a propósito: ahí el contorno marca la silueta.
local PreviewHighlightPanels = {}

local PANEL_NAMES = {
	Gifting = true,
	Store = true,
	Settings = true,
	Credits = true,
	Rewards = true,
	Voting = true,
	GiftAlert = true,
	BattlePass = true,
}

--- Llama a `onChanged(hidden)` con el estado actual y en cada cambio; devuelve la limpieza.
--- Los paneles que repliquen tarde se recogen por ChildAdded.
function PreviewHighlightPanels.observe(
	uiGui: Instance?,
	onChanged: (hidden: boolean) -> ()
): () -> ()
	local panels: { GuiObject } = {}
	local connections: { RBXScriptConnection } = {}

	local function apply()
		local anyPanelOpen = false
		for _, panel in panels do
			if panel.Visible then
				anyPanelOpen = true
				break
			end
		end
		onChanged(anyPanelOpen)
	end

	local function track(node: Instance)
		if not (PANEL_NAMES[node.Name] and node:IsA("GuiObject")) then
			return
		end
		table.insert(panels, node)
		table.insert(connections, node:GetPropertyChangedSignal("Visible"):Connect(apply))
	end

	if uiGui then
		for _, child in uiGui:GetChildren() do
			track(child)
		end
		table.insert(
			connections,
			uiGui.ChildAdded:Connect(function(child)
				local before = #panels
				track(child)
				if #panels ~= before then
					apply()
				end
			end)
		)
	end

	apply()

	return function()
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
		table.clear(panels)
	end
end

return PreviewHighlightPanels
