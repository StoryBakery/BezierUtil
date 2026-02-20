--[=[
	@class BezierCurve
	
	Keyframe 배열을 기반으로 1차원 베지어 곡선을 구성하고 특정 시간의 값을 계산하는 객체입니다.
	부분 키프레임을 자동으로 보정해 곡선을 매끄럽게 유지하는 헬퍼 유틸리티를 제공합니다.
]=]

local BezierCurve = {}
BezierCurve.__index = BezierCurve
BezierCurve.__type = "BezierCurve"

local SHOULD_VALIDATE_PARTIAL_KEYFRAME_ORDER = if game then game:GetService("RunService"):IsStudio() else true

--[=[
	베지어 핸들을 자동 계산할 때 사용하는 규칙 이름입니다.
	
	@variant Auto - 양쪽 기울기를 일정하게 맞춰 자연스럽게 이어집니다.
	@variant AutoClamped - Auto와 같지만 오버슈트를 방지하도록 값을 클램프합니다.
	@variant Vector - 이전/다음 키프레임을 향하는 벡터 방향으로 1/3 비율의 핸들을 만듭니다.
	@variant Free - 핸들 값을 직접 지정할 수 있도록 기본값을 키프레임 값으로 둡니다.
	@variant Aligned - 한쪽 핸들을 기준으로 180° 반대 방향의 동일 길이 핸들을 맞춥니다.
]=]
export type HandleType = "Auto" | "AutoClamped" | "Vector" | "Free" | "Aligned"

--[=[
	@interface Handle
	베지어 곡선의 핸들을 표현합니다. Time은 시간 축, Value는 값 축입니다.
]=]
export type Handle = { Time: number, Value: number }

--[=[
	@interface Keyframe
	
	베지어 곡선을 구성하는 완전한 키프레임입니다.
]=]
export type Keyframe = {
	--- 시간 좌표.
	Time: number,

	--- 해당 시점의 값.
	Value: number,

	--- 이전 키프레임에서 들어오는 핸들.
	HandleIn: Handle,

	--- 다음 키프레임으로 나가는 핸들.
	HandleOut: Handle,
}

--[=[
	@interface PartialKeyframe
	
	핸들이 비어 있을 수 있는 키프레임입니다. [BezierCurve.FillKeyframeHandles]로 보정됩니다.
]=]
export type PartialKeyframe = {
	--- 시간 좌표
	Time: number,

	--- 해당 시점의 값
	Value: number,

	--- 직접 지정할 수 있는 In 핸들.
	HandleIn: Handle?,

	--- 직접 지정할 수 있는 Out 핸들.
	HandleOut: Handle?,

	--[=[
		In 핸들을 채우는 규칙
		@default "Auto"
	]=]
	HandleTypeIn: HandleType?,

	--[=[
		Out 핸들을 채우는 규칙
		@default "Auto"
	]=]
	HandleTypeOut: HandleType?,
}

local function cubicBezier(u: number, p0: number, p1: number, p2: number, p3: number): number
	local mu = 1 - u
	local mu2, u2 = mu * mu, u * u
	return (mu2 * mu) * p0 + 3 * (mu2 * u) * p1 + 3 * (mu * u2) * p2 + (u2 * u) * p3
end

local function cubicBezierDerivative(
	u: number,
	p0: number,
	p1: number,
	p2: number,
	p3: number
): number
	local mu = 1 - u
	return 3 * ((p1 - p0) * mu * mu + 2 * (p2 - p1) * mu * u + (p3 - p2) * u * u)
end

local function deCasteljauSolve(t: number, p0: number, p1: number, p2: number, p3: number): number
	local u0, u1 = 0.0, 1.0
	for _ = 1, 12 do
		local um = (u0 + u1) * 0.5
		local xm = cubicBezier(um, p0, p1, p2, p3)
		if xm > t then
			u1 = um
		else
			u0 = um
		end
	end
	return (u0 + u1) * 0.5
end

export type BezierCurve = setmetatable<{
	_keyframes: { Keyframe },
	_lastIndex: number,
}, typeof(BezierCurve)>

local function createBezierCurve(keyframes: { Keyframe }): BezierCurve
	local self = setmetatable({}, BezierCurve)
	self._keyframes = keyframes
	self._lastIndex = 1
	return self
end

local function validatePartialKeyframeOrder(pks: { PartialKeyframe })
	for i = 2, #pks do
		if pks[i].Time <= pks[i - 1].Time then
			error(`PartialKeyframes must be strictly sorted by Time: index {i - 1} ({pks[i - 1].Time}) >= index {i} ({pks[i].Time})`)
		end
	end
end

--[=[
	정렬된 Keyframe 배열로 BezierCurve 인스턴스를 생성합니다.
	
	@param keyframes - 시간 오름차순으로 정렬된 키프레임 목록.
	@return - 생성된 곡선 객체.
]=]
function BezierCurve.fromKeyframes(keyframes: { Keyframe }): BezierCurve
	assert(#keyframes > 0, "BezierCurve requires at least one keyframe")

	-- 시간 순으로 정렬 & 중복 검사
	local kfs = table.clone(keyframes)
	table.sort(kfs, function(a, b)
		return a.Time < b.Time
	end)
	for i = 2, #kfs do
		assert(kfs[i].Time > kfs[i - 1].Time, "Duplicate keyframe times detected")
	end

	return createBezierCurve(kfs)
end

--[=[
	PartialKeyframe 배열을 자동 보정해 BezierCurve를 생성합니다.
	정렬 검사는 개발 환경(예: Lune, Studio)에서만 수행하고, 실제 게임 실행 환경에서는 생략됩니다.
	
	@param pks - 시간 오름차순으로 정렬된, 핸들 정보가 비어 있을 수 있는 키프레임 목록.
	@return - 생성된 곡선 객체.
]=]
function BezierCurve.fromPartialKeyframes(pks: { PartialKeyframe }): BezierCurve
	if SHOULD_VALIDATE_PARTIAL_KEYFRAME_ORDER then
		validatePartialKeyframeOrder(pks)
	end

	local keyframes = BezierCurve.FillKeyframeHandles(pks)
	return createBezierCurve(keyframes)
end

local function findSegmentIndex(self: BezierCurve, t: number): number
	local keys, n = self._keyframes, #self._keyframes
	local i = self._lastIndex
	if i < n and t >= keys[i].Time and t <= keys[i + 1].Time then
		return i
	end
	local lo, hi = 1, n - 1
	while lo <= hi do
		local mid = (lo + hi) // 2
		if t < keys[mid].Time then
			hi = mid - 1
		elseif t > keys[mid + 1].Time then
			lo = mid + 1
		else
			self._lastIndex = mid
			return mid
		end
	end
	-- fallback – clamp
	self._lastIndex = math.clamp(lo, 1, n - 1)
	return self._lastIndex
end

--[=[
	주어진 시간에서 3차 베지어 보간 값을 계산합니다.
	
	@param t - 조회할 시간.
	@return - 계산된 곡선 값.
]=]
function BezierCurve:GetValueAtTime(t: number): number
	local keys, n = self._keyframes, #self._keyframes
	if n == 1 then
		return keys[1].Value
	end
	if t <= keys[1].Time then
		return keys[1].Value
	end
	if t >= keys[n].Time then
		return keys[n].Value
	end

	-- Locate segment (binary search + cache)
	local idx = findSegmentIndex(self, t)
	local k0, k1 = keys[idx], keys[idx + 1]

	-- Solve Bx(u) = t (Newton + fallback)
	local u, maxIter = 0.5, 7
	for _ = 1, maxIter do
		local x = cubicBezier(u, k0.Time, k0.HandleOut.Time, k1.HandleIn.Time, k1.Time)
		local dx = cubicBezierDerivative(u, k0.Time, k0.HandleOut.Time, k1.HandleIn.Time, k1.Time)
		if math.abs(dx) < 1e-9 then
			break
		end
		local prev = u
		u = u - (x - t) / dx
		if u < 0 then
			u = 0
		elseif u > 1 then
			u = 1
		end
		if math.abs(u - prev) < 1e-5 then
			break
		end
	end
	-- Newton 실패 시 de Casteljau 분할
	if
		math.abs(cubicBezier(u, k0.Time, k0.HandleOut.Time, k1.HandleIn.Time, k1.Time) - t) > 1e-4
	then
		u = deCasteljauSolve(t, k0.Time, k0.HandleOut.Time, k1.HandleIn.Time, k1.Time)
	end

	-- Evaluate y
	return cubicBezier(u, k0.Value, k0.HandleOut.Value, k1.HandleIn.Value, k1.Value)
end

local function createAutoHandle(pks, i: number, isIn: boolean, clamped: boolean): Handle
	local pkf, prev, next = pks[i], pks[i - 1], pks[i + 1]

	if not prev and not next then
		return { Time = pkf.Time, Value = pkf.Value }
	end
	if not prev then
		local dx, dy = (next.Time - pkf.Time) / 3, (next.Value - pkf.Value) / 3
		if isIn then
			return { Time = pkf.Time - dx, Value = pkf.Value - dy }
		end
		return { Time = pkf.Time + dx, Value = pkf.Value + dy }
	end
	if not next then
		local dx, dy = (pkf.Time - prev.Time) / 3, (pkf.Value - prev.Value) / 3
		if isIn then
			return { Time = pkf.Time - dx, Value = pkf.Value - dy }
		end
		return { Time = pkf.Time + dx, Value = pkf.Value + dy }
	end

	-- Middle key
	local slope = (next.Value - prev.Value) / (next.Time - prev.Time)
	local len = (isIn and (pkf.Time - prev.Time) or (next.Time - pkf.Time)) / 3
	local dx, dy = (isIn and -len or len), slope * len
	local h = { Time = pkf.Time + dx, Value = pkf.Value + dy }

	-- Clamp overshoot
	if clamped and (pkf.Value - prev.Value) * (next.Value - pkf.Value) < 0 then
		h.Value = pkf.Value
	end
	return h
end

-- Align helper: make handles colinear & equal length
local function alignHandles(pk: PartialKeyframe, hIn: Handle, hOut: Handle)
	local dx, dy = pk.Time - hIn.Time, pk.Value - hIn.Value
	hOut.Time = pk.Time + dx
	hOut.Value = pk.Value + dy
end

--[=[
	PartialKeyframe 배열을 HandleType 규칙에 따라 보정해 완전한 Keyframe 목록으로 변환합니다.
	@param pks - 보정할 키프레임 목록.
	@return - 계산된 핸들을 포함한 키프레임 목록.
]=]
function BezierCurve.FillKeyframeHandles(pks: { PartialKeyframe }): { Keyframe }
	assert(#pks > 0, "PartialKeyframes cannot be empty")

	local res = {}
	for i, pk in ipairs(pks) do
		local inT, outT = pk.HandleTypeIn or "Auto", pk.HandleTypeOut or "Auto"
		local hIn, hOut = pk.HandleIn, pk.HandleOut

		-- Out handle
		if not hOut then
			if outT == "Auto" or outT == "Aligned" then
				hOut = createAutoHandle(pks, i, false, false)
			elseif outT == "AutoClamped" then
				hOut = createAutoHandle(pks, i, false, true)
			elseif outT == "Vector" then
				local nxt = pks[i + 1] or pk
				hOut = {
					Time = pk.Time + (nxt.Time - pk.Time) / 3,
					Value = pk.Value + (nxt.Value - pk.Value) / 3,
				}
			else -- Free
				hOut = { Time = pk.Time, Value = pk.Value }
			end
		end

		-- In handle
		if not hIn then
			if inT == "Auto" or inT == "Aligned" then
				hIn = createAutoHandle(pks, i, true, false)
			elseif inT == "AutoClamped" then
				hIn = createAutoHandle(pks, i, true, true)
			elseif inT == "Vector" then
				local prv = pks[i - 1] or pk
				hIn = {
					Time = pk.Time - (pk.Time - prv.Time) / 3,
					Value = pk.Value - (pk.Value - prv.Value) / 3,
				}
			else -- Free
				hIn = { Time = pk.Time, Value = pk.Value }
			end
		end

		-- Aligned rule: 두 핸들이 항상 180° 정렬
		if outT == "Aligned" then
			alignHandles(pk, hIn, hOut)
		elseif inT == "Aligned" then
			alignHandles(pk, hOut, hIn)
		end

		res[i] = { Time = pk.Time, Value = pk.Value, HandleIn = hIn, HandleOut = hOut }
	end
	return res
end

return BezierCurve
