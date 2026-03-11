package signals

// EffectiveDrift computes B̃(t) = B(t) ∧ ¬A(t).
// When authorized is true, all drift is masked (B̃ = 0).
// When authorized is false, effective drift equals raw drift.
func EffectiveDrift(raw DriftVector, authorized bool) DriftVector {
	if authorized {
		return DriftVector{} // all zeros — drift is masked
	}
	return raw
}
