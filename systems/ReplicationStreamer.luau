--!strict
-- ReplicationStreamer.luau
-- Server-authoritative area-of-interest (AOI) replication. Entities exist ONLY on the
-- server; each player receives spawn / despawn events and delta snapshots only for the
-- entities inside their interest radius. A uniform spatial hash keeps the per-tick
-- relevancy query close to O(entities-near-player) instead of O(all-entities), so a
-- world with 10k entities still replicates cheaply to each client.
--
-- Author: DEX  ·  Zero client trust. The client is told what it may see; nothing more.

local ReplicationStreamer = {}
ReplicationStreamer.__index = ReplicationStreamer

type Entity = { id: number, x: number, z: number, state: { [string]: any }, dirty: boolean }
type PlayerView = { player: any, x: number, z: number }

function ReplicationStreamer.new(cellSize: number, interestRadius: number)
	local self = setmetatable({}, ReplicationStreamer)
	self.cellSize = cellSize
	self.interestRadius = interestRadius
	self.entities = {} :: { [number]: Entity }
	self.cells = {} :: { [string]: { [number]: boolean } } -- spatial hash bucket -> set of ids
	self.playerSets = {} :: { [any]: { [number]: boolean } } -- last relevant id-set per player
	self.nextId = 1
	return self
end

local function key(cx: number, cz: number): string
	return string.format("%d:%d", cx, cz)
end

function ReplicationStreamer:_cellOf(x: number, z: number): (number, number)
	return math.floor(x / self.cellSize), math.floor(z / self.cellSize)
end

function ReplicationStreamer:addEntity(x: number, z: number, state: { [string]: any }): number
	local id = self.nextId
	self.nextId += 1
	self.entities[id] = { id = id, x = x, z = z, state = state, dirty = true }
	local k = key(self:_cellOf(x, z))
	self.cells[k] = self.cells[k] or {}
	self.cells[k][id] = true
	return id
end

function ReplicationStreamer:removeEntity(id: number)
	local e = self.entities[id]
	if not e then return end
	local bucket = self.cells[key(self:_cellOf(e.x, e.z))]
	if bucket then bucket[id] = nil end
	self.entities[id] = nil
end

function ReplicationStreamer:moveEntity(id: number, x: number, z: number)
	local e = self.entities[id]
	if not e then return end
	local ocx, ocz = self:_cellOf(e.x, e.z)
	local ncx, ncz = self:_cellOf(x, z)
	if ocx ~= ncx or ocz ~= ncz then
		local ob = self.cells[key(ocx, ocz)]
		if ob then ob[id] = nil end
		local nk = key(ncx, ncz)
		self.cells[nk] = self.cells[nk] or {}
		self.cells[nk][id] = true
	end
	e.x, e.z, e.dirty = x, z, true
end

function ReplicationStreamer:setState(id: number, field: string, value: any)
	local e = self.entities[id]
	if e then e.state[field] = value; e.dirty = true end
end

-- Per-tick relevancy diff. Returns, per player:
--   { spawns = {Entity}, updates = {Entity}, despawns = {id} }
-- Send spawns/updates as snapshots and despawns as ids over your RemoteEvent.
function ReplicationStreamer:tick(playerViews: { PlayerView })
	local result = {}
	local r = self.interestRadius
	local r2 = r * r
	local span = math.ceil(r / self.cellSize)

	for _, p in ipairs(playerViews) do
		local prev = self.playerSets[p.player] or {}
		local now = {}
		local spawns, updates, despawns = {}, {}, {}
		local pcx, pcz = self:_cellOf(p.x, p.z)

		for dx = -span, span do
			for dz = -span, span do
				local bucket = self.cells[key(pcx + dx, pcz + dz)]
				if bucket then
					for id in pairs(bucket) do
						local e = self.entities[id]
						local ddx, ddz = e.x - p.x, e.z - p.z
						if ddx * ddx + ddz * ddz <= r2 then
							now[id] = true
							if not prev[id] then
								spawns[#spawns + 1] = e
							elseif e.dirty then
								updates[#updates + 1] = e
							end
						end
					end
				end
			end
		end

		for id in pairs(prev) do
			if not now[id] then despawns[#despawns + 1] = id end
		end

		self.playerSets[p.player] = now
		result[p.player] = { spawns = spawns, updates = updates, despawns = despawns }
	end

	-- one dirty-clear pass after every player has been diffed this tick
	for _, e in pairs(self.entities) do e.dirty = false end
	return result
end

return ReplicationStreamer
