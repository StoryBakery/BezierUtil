--[=[
	@class BezierInterpolator
	
	3차 베지어 곡선을 사용하여 숫자 값들을 보간하는 기능을 제공하는 모듈입니다.
	제어점(ControlPoint)들의 배열을 기반으로 특정 진행도(progress)에 따른 값을 계산할 수 있습니다.
	핸들 값이 일부 누락된 제어점들이나, 단순 숫자 배열로부터도 베지어 보간 객체를 생성할 수 있는 편의 기능을 제공합니다.
]=]

local BezierInterpolator = {}
BezierInterpolator.__index = BezierInterpolator
BezierInterpolator.__type = "BezierInterpolator"

--[=[
	@interface ControlPoint
	
	베지어 곡선에서 사용하는 완전한 컨트롤 포인트입니다.
]=]
export type ControlPoint = {
	--- 기준 값
	Value: number,
	--- 다음 포인트를 향하는 핸들 값
	HandleOut: number,
	--- 이전 포인트에서 현재 포인트로 향하는 핸들 값
	HandleIn: number,
}

--[=[
	@interface PartialControlPoint
	@within BezierInterpolator
	
	제어점의 값은 필수이지만, 핸들 값은 선택적으로 가질 수 있는 테이블입니다.
	
	.Value number -- 기준 값.
	.HandleOut number? -- nil 이면 [BezierInterpolator.FillControlPointHandles] 로 자동으로 계산될 수 있습니다.
	.HandleIn number? -- nil 이면 [BezierInterpolator.FillControlPointHandles] 로 자동으로 계산될 수 있습니다.
]=]
export type PartialControlPoint = {
	Value: number,
	HandleOut: number?,
	HandleIn: number?,
}

export type BezierInterpolator = setmetatable<{
	--[=[
		보간이 사용하는 컨트롤 포인트 배열입니다. `from*` 생성 함수를 통해 채워집니다.
	]=]
	ControlPoints: { ControlPoint },
}, typeof(BezierInterpolator)>

local function cubicBezier(t: number, p0: number, p1: number, p2: number, p3: number): number
	local mt = 1 - t
	local mt2 = mt * mt
	local t2 = t * t

	return (mt2 * mt * p0) + (3 * mt2 * t * p1) + (3 * mt * t2 * p2) + (t2 * t * p3)
end

--[=[
	모든 핸들이 채워진 컨트롤 포인트 배열로 BezierInterpolator를 생성합니다.
	@param controlPoints {ControlPoint} -- 시간 순서로 정렬된 컨트롤 포인트 배열.
	@return BezierInterpolator -- 생성된 보간기.
]=]
function BezierInterpolator.fromControlPoints(controlPoints: { ControlPoint }): BezierInterpolator
	local self = setmetatable({}, BezierInterpolator)
	self.ControlPoints = table.clone(controlPoints)
	return self
end

--[=[
	누락된 핸들을 자동으로 채워 완전한 컨트롤 포인트 배열을 만든 뒤 인스턴스를 생성합니다.
	@param partialControlPoints {PartialControlPoint} -- 핸들 값이 비어 있을 수 있는 포인트 배열.
	@return BezierInterpolator -- 생성된 보간기.
]=]
function BezierInterpolator.fromPartialControlPoints(
	partialControlPoints: { PartialControlPoint }
): BezierInterpolator
	local filledControlPoints = BezierInterpolator.FillControlPointHandles(partialControlPoints)
	return BezierInterpolator.fromControlPoints(filledControlPoints)
end

--[=[
	순수 값 목록으로부터 균일한 베지어 핸들을 채우고 인스턴스를 생성합니다.
	@param values - 진행도에 따라 연결할 값 목록.
	@return BezierInterpolator - 생성된 보간기.
]=]
function BezierInterpolator.fromFloats(values: { number }): BezierInterpolator
	local partialControlPoints: { PartialControlPoint } = {}
	for _, val in ipairs(values) do
		table.insert(partialControlPoints, { Value = val }) -- HandleIn, HandleOut은 nil로 두어 자동 계산되도록 합니다.
	end
	return BezierInterpolator.fromPartialControlPoints(partialControlPoints)
end

--[=[
	진행도(progress)를 입력받아 0~1 범위 내에서 보간된 값을 계산합니다.
	
	@param progress - 0.0 - 1.0 범위의 진행도.
	@return - 보간 결과 값.
]=]
function BezierInterpolator:GetValueAtProgress(progress: number): number
	local numPoints = #self.ControlPoints
	if numPoints == 0 then
		return 0
	end
	if numPoints == 1 then
		return self.ControlPoints[1].Value
	end

	local numSegments = numPoints - 1

	-- progress 값을 [0, 1] 범위로 클램핑합니다.
	progress = math.clamp(progress, 0, 1)

	if progress == 0 then
		return self.ControlPoints[1].Value
	end
	if progress == 1 then
		return self.ControlPoints[numPoints].Value
	end

	local targetPos = progress * numSegments
	local segmentIndex = math.floor(targetPos)

	-- 마지막 세그먼트에 정확히 도달하는 경우 (progress가 1에 매우 가까울 때 targetPos가 numSegments가 될 수 있음)

	if segmentIndex >= numSegments then
		segmentIndex = numSegments - 1
	end

	local tInSegment = targetPos - segmentIndex

	local p0Cp = self.ControlPoints[segmentIndex + 1]
	local p1Cp = self.ControlPoints[segmentIndex + 2]

	local p0 = p0Cp.Value
	local p1 = p0Cp.HandleOut -- 첫 번째 제어점의 나가는 핸들
	local p2 = p1Cp.HandleIn -- 두 번째 제어점의 들어오는 핸들
	local p3 = p1Cp.Value

	return cubicBezier(tInSegment, p0, p1, p2, p3)
end

--[=[
	핸들이 비어 있는 컨트롤 포인트 배열을 자동 규칙에 따라 채웁니다.
	@param partialControlPoints {PartialControlPoint} -- 자동으로 보완할 포인트 배열.
	@return {ControlPoint} -- 채워진 컨트롤 포인트 배열.
]=]
function BezierInterpolator.FillControlPointHandles(
	partialControlPoints: { PartialControlPoint }
): { ControlPoint }
	local filledPoints: { ControlPoint } = {}
	local numPoints = #partialControlPoints

	if numPoints == 0 then
		return {}
	end

	for i = 1, numPoints do
		local currentP = partialControlPoints[i]
		local prevP = (i > 1) and partialControlPoints[i - 1] or nil
		local nextP = (i < numPoints) and partialControlPoints[i + 1] or nil

		local val = currentP.Value
		local hIn = currentP.HandleIn
		local hOut = currentP.HandleOut

		-- HandleIn 자동 계산
		if hIn == nil then
			if prevP and nextP then -- 중간점
				local delta = (nextP.Value - prevP.Value) / 6.0
				hIn = val - delta
			elseif prevP then -- 마지막점 (i == numPoints)
				hIn = val - (val - prevP.Value) / 3.0
			else -- 첫번째점 (i == 1)
				hIn = val -- 첫 점의 HandleIn은 자기 자신 값 (곡선에 영향 없음)
			end
		end

		-- HandleOut 자동 계산
		if hOut == nil then
			if prevP and nextP then -- 중간점
				local delta = (nextP.Value - prevP.Value) / 6.0
				hOut = val + delta
			elseif nextP then -- 첫번째점 (i == 1)
				hOut = val + (nextP.Value - val) / 3.0
			else -- 마지막점 (i == numPoints)
				hOut = val -- 마지막 점의 HandleOut은 자기 자신 값 (곡선에 영향 없음)
			end
		end

		table.insert(filledPoints, {
			Value = val,
			HandleIn = hIn,
			HandleOut = hOut,
		})
	end

	return filledPoints
end

return BezierInterpolator
