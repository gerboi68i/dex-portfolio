--!strict
-- ProceduralDungeon.luau
-- Deterministic, seedable dungeon generator. A fixed seed always produces the same
-- dungeon (so a server and every client can rebuild an identical map from one number,
-- and tests are reproducible). Rooms are scattered without overlap, connected by a
-- minimum-spanning-tree of L-shaped corridors, then optionally eroded with a
-- cellular-automata pass for organic cave edges.
--
-- Returns: { grid = {{0|1}}, rooms = {Room}, graph = {{a,b}}, width, height }
-- Author: DEX

local ProceduralDungeon = {}

-- Linear congruential RNG (Park-Miller). Deterministic across machines, unlike math.random.
local function rng(seed: number)
	local state = seed % 2147483647
	if state <= 0 then state += 2147483646 end
	return function(n: number?): number
		state = (state * 16807) % 2147483647
		local f = (state - 1) / 2147483646
		return n and (math.floor(f * n) + 1) or f
	end
end

type Room = { x: number, y: number, w: number, h: number, cx: number, cy: number }

local function overlaps(a: Room, b: Room): boolean
	return a.x <= b.x + b.w + 1 and a.x + a.w + 1 >= b.x
		and a.y <= b.y + b.h + 1 and a.y + a.h + 1 >= b.y
end

function ProceduralDungeon.generate(opts: {
	width: number?, height: number?, rooms: number?,
	minRoom: number?, maxRoom: number?, seed: number?, erode: number?,
})
	local W = opts.width or 64
	local H = opts.height or 64
	local maxRooms = opts.rooms or 14
	local minS, maxS = opts.minRoom or 5, opts.maxRoom or 12
	local rand = rng(opts.seed or 1337)

	local grid = {}
	for y = 1, H do grid[y] = table.create(W, 0) end

	-- 1) scatter non-overlapping rooms (rejection sampling)
	local rooms: { Room } = {}
	for _ = 1, maxRooms * 6 do
		if #rooms >= maxRooms then break end
		local w = rand(maxS - minS) + minS
		local h = rand(maxS - minS) + minS
		local x = rand(W - w - 2) + 1
		local y = rand(H - h - 2) + 1
		local room: Room = { x = x, y = y, w = w, h = h, cx = x + w // 2, cy = y + h // 2 }
		local ok = true
		for _, r in ipairs(rooms) do
			if overlaps(room, r) then ok = false break end
		end
		if ok then
			rooms[#rooms + 1] = room
			for yy = y, y + h do
				for xx = x, x + w do grid[yy][xx] = 1 end
			end
		end
	end

	-- 2) connect rooms with an MST (Prim) over centre distances; carve 2-wide L-corridors
	local graph = {}
	local connected = { [1] = true }
	local function carve(a: Room, b: Room)
		local x, y = a.cx, a.cy
		while x ~= b.cx do
			grid[y][x] = 1; grid[math.min(y + 1, H)][x] = 1
			x += (b.cx > x) and 1 or -1
		end
		while y ~= b.cy do
			grid[y][x] = 1; grid[y][math.min(x + 1, W)] = 1
			y += (b.cy > y) and 1 or -1
		end
	end
	while #rooms > 1 do
		local bestA, bestB, bestD
		for i in pairs(connected) do
			for j, rj in ipairs(rooms) do
				if not connected[j] then
					local d = (rooms[i].cx - rj.cx) ^ 2 + (rooms[i].cy - rj.cy) ^ 2
					if not bestD or d < bestD then bestD, bestA, bestB = d, i, j end
				end
			end
		end
		if not bestB then break end
		carve(rooms[bestA], rooms[bestB])
		graph[#graph + 1] = { bestA, bestB }
		connected[bestB] = true
	end

	-- 3) optional cellular-automata erosion for organic edges
	if opts.erode then
		for _ = 1, opts.erode do
			local nextG = {}
			for y = 1, H do nextG[y] = table.create(W, 0) end
			for y = 2, H - 1 do
				for x = 2, W - 1 do
					local n = 0
					for dy = -1, 1 do
						for dx = -1, 1 do
							if grid[y + dy][x + dx] == 1 then n += 1 end
						end
					end
					nextG[y][x] = (n >= 5) and 1 or 0
				end
			end
			grid = nextG
		end
	end

	return { grid = grid, rooms = rooms, graph = graph, width = W, height = H }
end

return ProceduralDungeon
