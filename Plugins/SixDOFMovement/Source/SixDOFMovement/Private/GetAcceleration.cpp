//Copyright 2016-2018 Mookie

#include "SixDOFMovementComponent.h"

FVector USixDOFMovementComponent::GetActiveAcceleration() const {
	FVector OldLocation;
	FQuat OldRotation;
	FVector OldVelocity;
	FVector OldAngularVelocity;

	FBodyInstance *BodyInstance=NULL;
	bool UsePhysics = false;

	if (IsValid(UpdatedPrimitive)) {
		if (UpdatedPrimitive->IsSimulatingPhysics()) {
			UsePhysics = true;
			BodyInstance = UpdatedPrimitive->GetBodyInstance();
			if (!BodyInstance) {
				UE_LOG(LogTemp, Error, TEXT("Physics enabled but component has no BodyInstance"));
				return FVector(0, 0, 0);
			}
		}
	}
	GetComponentTransformAndVelocity(UsePhysics, BodyInstance, OldLocation, OldRotation, OldVelocity, OldAngularVelocity);

	float Delta = 0.01; //constant delta
	FVector APTrans = AutopilotTranslation(OldLocation, OldRotation);
	FVector NewVelocity = GetUpdatedLinearVelocity(OldLocation, OldRotation, OldVelocity, APTrans, Delta); 
	FVector NewVelocityPassive = GetUpdatedLinearVelocity(OldLocation, OldRotation, OldVelocity, FVector(0,0,0), Delta); //constant delta, no inputs

	return (NewVelocity-NewVelocityPassive)*Delta;
}

void USixDOFMovementComponent::GetComponentTransformAndVelocity(bool UsePhysics, const FBodyInstance* BodyInstance, FVector & OutLocation, FQuat & OutRotation, FVector & OutVelocity, FVector & OutAngularVelocity) const{
	if (UsePhysics) {
		if (!BodyInstance) {
			UE_LOG(LogTemp, Error, TEXT("Physics enabled but component has no BodyInstance, this shouldn't be happening"));
			return;
		}

		OutLocation = BodyInstance->GetUnrealWorldTransform().GetLocation();
		OutRotation = BodyInstance->GetUnrealWorldTransform().GetRotation();
		OutVelocity = BodyInstance->GetUnrealWorldVelocity();
		OutAngularVelocity = BodyInstance->GetUnrealWorldAngularVelocityInRadians() / PI*180.0f; //pre-4.18 was in degrees
	}
	else {
		OutRotation = UpdatedComponent->GetComponentQuat();
		OutLocation = UpdatedComponent->GetComponentLocation();
		OutVelocity = Velocity;
		OutAngularVelocity = AngularVelocity;
	}
}