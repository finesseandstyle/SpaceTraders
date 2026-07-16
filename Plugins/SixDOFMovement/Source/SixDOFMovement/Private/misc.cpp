//Copyright 2016-2018 Mookie

#include "SixDOFMovementComponent.h"

float USixDOFMovementComponent::BlendInput(float low, float high) const {
	return FMath::Lerp(FMath::Clamp(low, -1.0f, 1.0f), FMath::Sign(high), FMath::Min(FMath::Abs(high), 1.0f));
}

FVector USixDOFMovementComponent::BlendInput(FVector low, FVector high) const {
	FVector Out;
	Out.X = FMath::Lerp(FMath::Clamp(low.X, -1.0f, 1.0f), FMath::Sign(high.X), FMath::Min(FMath::Abs(high.X), 1.0f));
	Out.Y = FMath::Lerp(FMath::Clamp(low.Y, -1.0f, 1.0f), FMath::Sign(high.Y), FMath::Min(FMath::Abs(high.Y), 1.0f));
	Out.Z = FMath::Lerp(FMath::Clamp(low.Z, -1.0f, 1.0f), FMath::Sign(high.Z), FMath::Min(FMath::Abs(high.Z), 1.0f));

	return Out;
}