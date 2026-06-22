--!strict
-- FlowFieldPathfinding.luau
-- Grid flow-field pathing for large agent counts (swarms, tower-defense creeps).
-- ONE Dijkstra integration pass per goal feeds an O(1) per-agent lookup, so thousands
-- of agents share a single field instead of each running their own A*. This is how you
-- move 2,000 zombies toward a player at 60fps on a Roblox server.
--
-- Author: DEX  ·  Server-side, deterministic, allocation-light.

local FlowField = {}
FlowField.__index = FlowField

-- (dx, dy, stepCost) — 8-connected with diagonal cost ~sqrt(2)
local NEIGHBORS8 = {
	{ 1, 0, 1 }, { -1, 0, 1 }, { 0, 1, 1 }, { 0, -1, 1 },
	{ 1, 1, 1.41421 }, { 1, -1, 1.41421 }, { -1, 1, 1.41421 }, { -1, -1, 1.41421 },
}

function FlowField.new(width: number, height: number, cellSize: number)
	local self = setmetatable({}, FlowField)
	self.width = width
	self.height = height
	self.cellSize = cellSize
	self.cost = table.create(width * height, 1)        -- per-cell traversal cost (math.huge = wall)
	self.integration = table.create(width * height, math.huge)
	self.flow = table.create(width * height, nil)      -- {dx, dy} unit direction per cell
	return self
end

function FlowField:_idx(x: number, y: number): number
	return (y - 1) * self.width + x
end

function FlowField:inBounds(x: number, y: number): boolean
	return x >= 1 and y >= 1 and x <= self.width and y <= self.height
end

function FlowField:setCost(x: number, y: number, c: number)
	if self:inBounds(x, y) then self.cost[self:_idx(x, y)] = c end
end

function FlowField:setWall(x: number, y: number)
	self:setCost(x, y, math.huge)
end

-- Dijkstra integration field, flooded outward from the goal with a binary min-heap.
function FlowField:computeField(goalX: number, goalY: number)
	local W = self.width
	local integ = self.integration
	for i = 1, W * self.height do integ[i] = math.huge end
	if not self:inBounds(goalX, goalY) then return end

	local heap = {}            -- array of {idx, cost}; min-heap on cost
	local function push(node: number, c: number)
		heap[#heap + 1] = { node, c }
		local i = #heap
		while i > 1 do
			local p = i // 2
			if heap[p][2] <= heap[i][2] then break end
			heap[p], heap[i] = heap[i], heap[p]
			i = p
		end
	end
	local function pop()
		local top = heap[1]
		local n = #heap
		heap[1] = heap[n]; heap[n] = nil; n -= 1
		local i = 1
		while true do
			local l, r, s = i * 2, i * 2 + 1, i
			if l <= n and heap[l][2] < heap[s][2] then s = l end
			if r <= n and heap[r][2] < heap[s][2] then s = r end
			if s == i then break end
			heap[i], heap[s] = heap[s], heap[i]
			i = s
		end
		return top
	end

	local gi = self:_idx(goalX, goalY)
	integ[gi] = 0
	push(gi, 0)

	while #heap > 0 do
		local cur = pop()
		local ci, cc = cur[1], cur[2]
		if cc <= integ[ci] then                          -- skip stale heap entries
			local cx = (ci - 1) % W + 1
			local cy = (ci - 1) // W + 1
			for _, n in ipairs(NEIGHBORS8) do
				local nx, ny = cx + n[1], cy + n[2]
				if self:inBounds(nx, ny) then
					local ni = self:_idx(nx, ny)
					local stepCost = self.cost[ni]
					if stepCost ~= math.huge then
						local nc = cc + stepCost * n[3]
						if nc < integ[ni] then
							integ[ni] = nc
							push(ni, nc)
						end
					end
				end
			end
		end
	end

	self:_buildFlow()
end

-- Every cell points toward the neighbour with the lowest integration value.
function FlowField:_buildFlow()
	local W, H = self.width, self.height
	for y = 1, H do
		for x = 1, W do
			local i = self:_idx(x, y)
			if self.integration[i] == math.huge then
				self.flow[i] = { 0, 0 }
			else
				local best, bx, by = self.integration[i], 0, 0
				for _, n in ipairs(NEIGHBORS8) do
					local nx, ny = x + n[1], y + n[2]
					if self:inBounds(nx, ny) then
						local v = self.integration[self:_idx(nx, ny)]
						if v < best then best, bx, by = v, n[1], n[2] end
					end
				end
				local len = math.sqrt(bx * bx + by * by)
				self.flow[i] = len > 0 and { bx / len, by / len } or { 0, 0 }
			end
		end
	end
end

-- O(1) steering direction for an agent at a world (X, Z) position.
function FlowField:sample(worldX: number, worldZ: number): (number, number)
	local x = math.clamp(math.floor(worldX / self.cellSize) + 1, 1, self.width)
	local y = math.clamp(math.floor(worldZ / self.cellSize) + 1, 1, self.height)
	local f = self.flow[self:_idx(x, y)]
	return f[1], f[2]
end

return FlowField
