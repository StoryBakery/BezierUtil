local BezierCurve = require("@self/Curve")
local BezierInterpolator = require("@self/Interploator")

export type BezierCurve = BezierCurve.BezierCurve
export type Handle = BezierCurve.Handle
export type Keyframe = BezierCurve.Keyframe
export type PartialKeyframe = BezierCurve.PartialKeyframe
export type HandleType = BezierCurve.HandleType

export type BezierInterpolator = BezierInterpolator.BezierInterpolator
export type ControlPoint = BezierInterpolator.ControlPoint
export type PartialControlPoint = BezierInterpolator.PartialControlPoint

local BezierUtil = {
	Curve = BezierCurve,
	Interpolator = BezierInterpolator,
}

return BezierUtil
