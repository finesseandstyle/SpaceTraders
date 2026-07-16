//Copyright 2020 Mookie
#include "SixDOFMovementComponent.h"

FVector USixDOFMovementComponent::AutopilotLookAt_Implementation(const FQuat& CurrentRotation, const FVector& Goal) const {
	FVector LookAtOutput = FVector(0, 0, 0);

	float FwdDot = FVector::DotProduct(CurrentRotation.GetForwardVector(), Goal);
	float RightDot = FVector::DotProduct(CurrentRotation.GetRightVector(), Goal);
	float UpDot = FVector::DotProduct(CurrentRotation.GetUpVector(), Goal);

	LookAtOutput.X = -FMath::Atan2(RightDot, FwdDot) * LookAtSensitivityRoll;
	LookAtOutput.Y = -FMath::Atan2(UpDot, FwdDot) * LookAtSensitivityPitch;
	LookAtOutput.Z = FMath::Atan2(RightDot, FwdDot) * LookAtSensitivityYaw;

	return LookAtOutput;
}

FVector USixDOFMovementComponent::AutopilotAutolevel_Implementation(const FQuat& CurrentRotation, const FVector& UpVector) const {
	FVector LevelOutput = FVector(0, 0, 0);

	float FwdDot = FVector::DotProduct(CurrentRotation.GetForwardVector(), UpVector);
	float RightDot = FVector::DotProduct(CurrentRotation.GetRightVector(), UpVector);
	float UpDot = FVector::DotProduct(CurrentRotation.GetUpVector(), UpVector);

	LevelOutput.X = -FMath::Atan2(RightDot, UpDot) * AutolevelSensitivityRoll;
	LevelOutput.Y = FMath::Atan2(FwdDot, UpDot) * AutolevelSensitivityPitch;
	LevelOutput.Z = -FMath::Atan2(FwdDot, RightDot) * AutolevelSensitivityYaw;

	return LevelOutput;
}


FVector USixDOFMovementComponent::AutopilotRotationDamping_Implementation(const FQuat& CurrentRotation, const FVector& CurrentAngularVelocity) const {
	FVector DampInput = -CurrentRotation.Inverse().RotateVector(CurrentAngularVelocity) / 180.0f * PI;
	FVector DampOutput = DampInput * FVector(RotationDampingRoll, RotationDampingPitch, RotationDampingYaw);
	return DampOutput;
}

FVector USixDOFMovementComponent::AutopilotTranslationDamping_Implementation(const FQuat& CurrentRotation, const FVector& CurrentVelocity) const {
	FVector DampInput = -CurrentRotation.Inverse().RotateVector(CurrentVelocity);
	FVector DampOutput = DampInput * FVector(TranslationDampingForward, TranslationDampingRight, TranslationDampingUp);
	return DampOutput;
}