//Copyright 2016-2019 Mookie

#include "SixDOFMovementComponent.h"

void USixDOFMovementComponent::SimulationStep(float DeltaTime, bool UsePhysics, FBodyInstance* BodyInstance) {
	if (DeltaTime == 0) return; //nothing needs to be done if this is zero anyway

	FVector OldLocation;
	FQuat OldRotation;
	FVector OldVelocity;
	FVector OldAngularVelocity;

	GetComponentTransformAndVelocity(UsePhysics, BodyInstance, OldLocation, OldRotation, OldVelocity, OldAngularVelocity);

	FVector APRot = AutopilotRotation(OldLocation, OldRotation);
	FVector APTrans = AutopilotTranslation(OldLocation, OldRotation);
	AngularVelocity = GetUpdatedAngularVelocity(OldRotation, OldAngularVelocity, APRot, DeltaTime);
	Velocity = GetUpdatedLinearVelocity(OldLocation, OldRotation, OldVelocity, APTrans, DeltaTime);

	if (UsePhysics) {
		BodyInstance->AddForce((Velocity - OldVelocity) / DeltaTime, false, true);
		BodyInstance->AddTorqueInRadians((AngularVelocity - OldAngularVelocity), false, true);
	}
	else {
		FQuat DeltaRotation = FQuat((AngularVelocity + OldAngularVelocity)*PI / 360.0f, DeltaTime);
		FQuat Rotation = (DeltaRotation*OldRotation).GetNormalized();

		float RemainingDelta = DeltaTime;
		int RemainingSteps = CollisionMaxIterations;
		while ((RemainingDelta > 0.0f) && (RemainingSteps > 0)) {
			FHitResult Result;
			SafeMoveUpdatedComponent((Velocity + OldVelocity) *RemainingDelta / 2.0f, Rotation, true, Result, ETeleportType::None);

			if (Result.bBlockingHit) {
				FVector SlideVec = FVector::CrossProduct(Velocity, Result.Normal).RotateAngleAxis(90.0f, Result.Normal);
				FVector Reflect = Velocity.MirrorByVector(Result.Normal);
				Velocity = FMath::Lerp(SlideVec, Reflect, CollisionRestitution);
				RemainingDelta = RemainingDelta*(1.0f - Result.Time);
				RemainingSteps--;

				OldVelocity = Velocity;
				OldLocation = UpdatedComponent->GetComponentLocation();
				Velocity = GetUpdatedLinearVelocity(OldLocation, Rotation, OldVelocity, APTrans, RemainingDelta);


				if (CollisionMargin > 0.0f) {
					SafeMoveUpdatedComponent(Result.Normal*CollisionMargin, Rotation, false, Result, ETeleportType::None);
				}
			}
			else {
				RemainingDelta = 0;
			}
		}
	}
}