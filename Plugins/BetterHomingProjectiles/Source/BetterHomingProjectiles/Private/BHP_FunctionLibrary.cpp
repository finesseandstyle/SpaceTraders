// Copyright 2023 Harlan Cox. All Rights Reserved.

#include "BHP_FunctionLibrary.h"
#include "Engine/World.h"
#include "CollisionShape.h"
#include "Engine/HitResult.h"

DEFINE_LOG_CATEGORY(BHP_Plugin);

void UBHP_FunctionLibrary::UpdateProNavState(FProNavState& ProNavState, const FHomingKinematicState& HomingKinematicState, const float DeltaTime)
{
	if (DeltaTime <= 0.f) return;
	
	const FVector PreviousLineOfSightDirection = ProNavState.PreviousLineOfSight.GetSafeNormal();
	const FVector LineOfSight = HomingKinematicState.TargetsLocation - HomingKinematicState.PursuerLocation;
	ProNavState.LineOfSightDistance = LineOfSight.Size();
	ProNavState.LineOfSightDirection = FMath::IsNearlyZero(ProNavState.LineOfSightDistance) ? FVector::ZeroVector : LineOfSight / ProNavState.LineOfSightDistance;
	ProNavState.LineOfSightAngularSpeed = FMath::Acos( FMath::Clamp(FVector::DotProduct(ProNavState.LineOfSightDirection, PreviousLineOfSightDirection), -1.f, 1.f)) / DeltaTime;
	ProNavState.LineOfSightRotationAxis = FVector::CrossProduct(PreviousLineOfSightDirection, ProNavState.LineOfSightDirection).GetSafeNormal();
	ProNavState.ClosingSpeed = (HomingKinematicState.PursuerVelocity - HomingKinematicState.TargetsVelocity).Dot(ProNavState.LineOfSightDirection);
	ProNavState.PreviousLineOfSight = LineOfSight;
}

FVector UBHP_FunctionLibrary::ComputeTrueProNavAcceleration(const FProNavState& ProNavState)
{
	const FVector AccelerationDirection = FVector::CrossProduct(ProNavState.LineOfSightRotationAxis, ProNavState.LineOfSightDirection);
	const float AccelerationMagnitude = ProNavState.Gain * ProNavState.LineOfSightAngularSpeed * ProNavState.ClosingSpeed;
	
	return AccelerationMagnitude * AccelerationDirection;
}

FVector UBHP_FunctionLibrary::ComputePureProNavAcceleration(const FProNavState& ProNavState, const FVector& PursuerVelocity)
{
	const FVector AccelerationDirection = FVector::CrossProduct(ProNavState.LineOfSightRotationAxis, PursuerVelocity).GetSafeNormal();
	const float AccelerationMagnitude = ProNavState.Gain * ProNavState.LineOfSightAngularSpeed * PursuerVelocity.Size();

	return AccelerationMagnitude * AccelerationDirection;
}

FVector UBHP_FunctionLibrary::Compute_BHP_HomingAcceleration(
	const UObject* WorldContextObject,
	const FProNavState& ProNavState,
	const FHomingKinematicState& HomingKinematicState, 
	const float MaxAccelerationMagnitude, 
	const float MaxSpeed,
	const float DeltaTime, 
	const bool bCanHomingChangeSpeed, 
	const FVector& ExternalAcceleration, 
	const float TargetImpactTimeSeconds)
{
	if (MaxAccelerationMagnitude <= 0.f || DeltaTime <= 0.f)
	{
		return FVector::ZeroVector;
	}

	FVector HomingAcceleration;
	
	if (!bCanHomingChangeSpeed)
	{
		// Returns an acceleration perpendicular to the velocity.
		const FVector TargetHomingAcceleration = ComputePureProNavAcceleration(ProNavState, HomingKinematicState.PursuerVelocity);
		const FVector PursuerVelocityDirection = HomingKinematicState.PursuerVelocity.GetSafeNormal();
			
		// Attempt to compensate for external acceleration to prevent the projectile from sagging due to gravity or being pushed off course by external forces.
		HomingAcceleration = TargetHomingAcceleration - (ExternalAcceleration - ExternalAcceleration.Dot(PursuerVelocityDirection) * PursuerVelocityDirection);
		HomingAcceleration = HomingAcceleration.GetClampedToMaxSize(MaxAccelerationMagnitude);

		return HomingAcceleration;
	}

	if (ProNavState.ClosingSpeed > 0.f) // We're getting closer to the target
	{
		// Returns acceleration perpendicular to the line of sight and the line of sight rotation axis.
		const FVector TargetHomingAcceleration = ComputeTrueProNavAcceleration(ProNavState);

		// Attempt to compensate for external acceleration to prevent the projectile from sagging due to gravity or being pushed off course by external forces.
		HomingAcceleration = TargetHomingAcceleration - (ExternalAcceleration - ExternalAcceleration.Dot(ProNavState.LineOfSightDirection) * ProNavState.LineOfSightDirection);

		// If the acceleration perpendicular to the line of sight is less than the HomingAccelerationMagnitude,
		// then we can add acceleration in the direction of the line of sight.
		const float MaxAccelerationMagnitudeSquared = FMath::Square(MaxAccelerationMagnitude);
		const float HomingAccelerationSizeSquared = HomingAcceleration.SizeSquared();
		if (HomingAccelerationSizeSquared < MaxAccelerationMagnitudeSquared)
		{
			const float RemainingAccelerationMagnitude = FMath::Sqrt(MaxAccelerationMagnitudeSquared - HomingAccelerationSizeSquared);

			if (WorldContextObject)
			{
				const UWorld* World = WorldContextObject->GetWorld();

				if (World && TargetImpactTimeSeconds > World->TimeSeconds) // Valid TargetImpactTime in the future.
				{
					const float DistanceToHomingPoint = (HomingKinematicState.TargetsLocation - HomingKinematicState.PursuerLocation).Size();
					const float TimeUntilImpact = TargetImpactTimeSeconds - World->TimeSeconds;
					const float TargetClosureRate = DistanceToHomingPoint / TimeUntilImpact;
					HomingAcceleration += ProNavState.LineOfSightDirection * FMath::Clamp((TargetClosureRate - ProNavState.ClosingSpeed) / DeltaTime, -RemainingAccelerationMagnitude, RemainingAccelerationMagnitude);
				}
				else // Apply all remaining acceleration along LOS to arrive at the target ASAP.
				{
					HomingAcceleration += RemainingAccelerationMagnitude * ProNavState.LineOfSightDirection;
				}	
			}
			else // Apply all remaining acceleration along LOS to arrive at the target ASAP.
			{
				HomingAcceleration += RemainingAccelerationMagnitude * ProNavState.LineOfSightDirection;

				if (TargetImpactTimeSeconds > 0.f)
				{
					UE_LOG(BHP_Plugin, Warning, TEXT("Compute_BHP_HomingAcceleration called with TargetImpactTimeSeconds > 0.f but WorldContextObject is null. Unable to compute acceleration for target impact time. Returning normal homing acceleration."));
				}
			}
		}
		else
		{
			HomingAcceleration = HomingAcceleration.GetClampedToMaxSize(MaxAccelerationMagnitude);
		}

		return HomingAcceleration;
	}

	// We're getting further away from the target. 
	if (MaxSpeed > 0.f)
	{
		const FVector VelocityTarget = MaxSpeed * ProNavState.LineOfSightDirection;
		const FVector NewVelocity = FMath::VInterpConstantTo(HomingKinematicState.PursuerVelocity, VelocityTarget, DeltaTime, MaxAccelerationMagnitude);
		HomingAcceleration = (NewVelocity - HomingKinematicState.PursuerVelocity) / DeltaTime;
	}
	else // Max speed is infinity
	{
		HomingAcceleration = MaxAccelerationMagnitude * ProNavState.LineOfSightDirection;
	}

	return HomingAcceleration;
}

FVector UBHP_FunctionLibrary::Compute_BHP_HomingAccelerationWithCollisionAvoidance(
	FCollisionAvoidanceParams& CollisionAvoidanceParams,
	const USceneComponent* CollisionComponent,
	const FProNavState& ProNavState, 
	const FHomingKinematicState& HomingKinematicState,
	const float MaxAccelerationMagnitude,
	const float MaxSpeed, 
	const float DeltaTime,
	const bool bCanHomingChangeSpeed,
	const FVector& ExternalAcceleration, 
	const float TargetImpactTimeSeconds,
	const FVector PlaneConstraintNormal)
{
	CollisionAvoidanceParams.bAvoidingCollision = false;
	if (HomingKinematicState.PursuerVelocity.IsNearlyZero())
	{
		return Compute_BHP_HomingAcceleration(
			CollisionComponent,
			ProNavState,
			HomingKinematicState,
			MaxAccelerationMagnitude,
			MaxSpeed,
			DeltaTime,
			bCanHomingChangeSpeed,
			ExternalAcceleration,
			TargetImpactTimeSeconds);
	}
	if (!CollisionComponent)
	{
		UE_LOG(BHP_Plugin, Warning, TEXT("ApplyCollisionAvoidanceToActorAcceleration called with null CollisionComponent. Unable to use collision avoidance."));
		return Compute_BHP_HomingAcceleration(
			CollisionComponent,
			ProNavState,
			HomingKinematicState,
			MaxAccelerationMagnitude,
			MaxSpeed,
			DeltaTime,
			bCanHomingChangeSpeed,
			ExternalAcceleration,
			TargetImpactTimeSeconds);
	}

	const UWorld* World = CollisionComponent->GetWorld();
	if (!World || MaxAccelerationMagnitude <= 0.f || DeltaTime <= 0.f)
	{
		return FVector::ZeroVector;
	}
	
	const UE::Math::TSphere BoundingSphere = CollisionComponent->Bounds.GetSphere();
	const float SphereBoundsRadius = BoundingSphere.W;
	if (SphereBoundsRadius <= 0.f)
	{
		UE_LOG(BHP_Plugin, Warning, TEXT("ComputeHomingAccelerationWithCollisionAvoidance called with zero sphere bounds radius. Unable to use collision avoidance. Ensure the CollisionComponent has a valid collision shape."));
		return Compute_BHP_HomingAcceleration(
			CollisionComponent,
			ProNavState,
			HomingKinematicState,
			MaxAccelerationMagnitude,
			MaxSpeed,
			DeltaTime,
			bCanHomingChangeSpeed,
			ExternalAcceleration,
			TargetImpactTimeSeconds);
	}

	FVector Acceleration;
	
	FVector CollisionComponentLocation = CollisionComponent->GetComponentLocation();
	const FCollisionShape ModifiedSphere = FCollisionShape::MakeSphere(SphereBoundsRadius * CollisionAvoidanceParams.SphereRadiusMultiplier);
	const float ModifiedRadius = SphereBoundsRadius * CollisionAvoidanceParams.SphereRadiusMultiplier;

	// Offset the trace in the direction of the velocity to avoid initial overlap behind the projectile.
	const float Offset = CollisionAvoidanceParams.SphereRadiusMultiplier > 1.f ? ModifiedRadius - SphereBoundsRadius : 0.f;
	const FVector VelocityDirection = HomingKinematicState.PursuerVelocity.GetUnsafeNormal(); // We know InVelocity is not zero, so we can use GetUnsafeNormal().
	FVector SphereTraceStart = BoundingSphere.Center + VelocityDirection * Offset;
	const float StopDistance = HomingKinematicState.PursuerVelocity.SizeSquared() / (2.f * MaxAccelerationMagnitude);

	// Max trace distance is the distance which would make the sphere trace just touch the homing point if directed toward it.
	const float SphereTraceDistance = FMath::Clamp(StopDistance * CollisionAvoidanceParams.TraceDistanceFactor, CollisionAvoidanceParams.MinTraceDistance, ProNavState.LineOfSightDistance - Offset - ModifiedRadius);
	FVector SphereTraceEnd = SphereTraceStart + VelocityDirection * SphereTraceDistance;

	FHitResult HitResult;
	FCollisionQueryParams Params;
	Params.AddIgnoredActors(CollisionAvoidanceParams.IgnoredActors);
	Params.AddIgnoredActor(CollisionComponent->GetOwner()); // Ignore the owner of the CollisionComponent.
	bool bHit = World->SweepSingleByChannel(HitResult, SphereTraceStart, SphereTraceEnd, FQuat::Identity, CollisionAvoidanceParams.CollisionAvoidanceTraceChannel, ModifiedSphere, Params);
	const float LineOfSightDistanceSquared = FMath::Square(ProNavState.LineOfSightDistance);

	if (bHit && (HitResult.ImpactPoint - CollisionComponentLocation).SizeSquared() < LineOfSightDistanceSquared) // Obstacle must not be beyond the homing point.
	{
		CollisionAvoidanceParams.bAvoidingCollision = true;
		FQuat VelocityQuat;
		const bool bConstrainToPlane = !PlaneConstraintNormal.IsNearlyZero();
		if (bConstrainToPlane)
		{
			VelocityQuat = FQuat(FRotationMatrix::MakeFromXZ(HomingKinematicState.PursuerVelocity, PlaneConstraintNormal));
		}
		else
		{
			VelocityQuat = FQuat::FindBetweenVectors(FVector::ForwardVector, VelocityDirection);
		}
		
		if (HitResult.Distance == 0.f)
		{
			// Initial overlap.
			Acceleration = MaxAccelerationMagnitude * HitResult.Normal;
			return Acceleration;
		}
		
		if (CollisionAvoidanceParams.CollisionAvoidanceTracePoints.IsEmpty())
		{
			CollisionAvoidanceParams.CollisionAvoidanceTracePoints = GenerateCollisionAvoidanceTraceDirections(CollisionAvoidanceParams.CollisionAvoidanceTraceAngle, bConstrainToPlane);
		}

		for (int32 i = 0; i < CollisionAvoidanceParams.CollisionAvoidanceTracePoints.Num(); ++i)
		{
			FVector TraceDirection = VelocityQuat.RotateVector(CollisionAvoidanceParams.CollisionAvoidanceTracePoints[i]);
			SphereTraceEnd = SphereTraceStart + TraceDirection * SphereTraceDistance;

			// Start with a line trace. If the line trace is blocked, then we can skip the sphere trace.
			// SphereTraceEnd is where the center of the sphere would stop. To reach the back of the sphere, we need to add the radius in the TraceDirection.
			const FVector LineTraceStart = BoundingSphere.Center;
			const FVector LineTraceEnd = SphereTraceEnd + ModifiedRadius * TraceDirection;
			bHit = World->LineTraceSingleByChannel(HitResult, LineTraceStart, LineTraceEnd, CollisionAvoidanceParams.CollisionAvoidanceTraceChannel, Params);
			if (bHit && (HitResult.ImpactPoint - HomingKinematicState.PursuerLocation).SizeSquared() < LineOfSightDistanceSquared)
			{
				continue;
			}

			// The line trace was not blocked, so we must perform a sphere trace to check if we can fit through the gap.
			bHit = World->SweepSingleByChannel(HitResult, SphereTraceStart, SphereTraceEnd, FQuat::Identity, CollisionAvoidanceParams.CollisionAvoidanceTraceChannel, ModifiedSphere, Params);
			if (bHit && (HitResult.ImpactPoint - CollisionComponentLocation).SizeSquared() < LineOfSightDistanceSquared)
			{
				continue;
			}
			
			if (bCanHomingChangeSpeed)
			{
				// We know the traces were generated using CollisionAvoidanceTraceAngle, so we can use it to determine the turn angle.
				const int32 VectorsPerGroup = bConstrainToPlane ? 2 : 8;
				const int32 Group = (i / VectorsPerGroup) + 1;
				const float TurnAngle = FMath::Min(CollisionAvoidanceParams.CollisionAvoidanceTraceAngle * Group, 180.f); // must not be > 180.
				
				if (TurnAngle > CollisionAvoidanceParams.FullBrakeTurnAngleDegrees)
				{
					// Full brake
					Acceleration = MaxAccelerationMagnitude * -VelocityDirection;
				}
				else
				{
					// Mix turning and braking, depending on the turn angle.
					const float BrakeFactor = FMath::IsNearlyZero(CollisionAvoidanceParams.FullBrakeTurnAngleDegrees) ? 1.f : FMath::Clamp(TurnAngle / CollisionAvoidanceParams.FullBrakeTurnAngleDegrees, 0.f, 1.f);
					const FVector TurnComponent = TraceDirection - (FVector::DotProduct(TraceDirection, VelocityDirection) * VelocityDirection);
					const FVector TurnForceDirection = TurnComponent.GetSafeNormal();
					const FVector BrakeAcceleration = MaxAccelerationMagnitude * -VelocityDirection * BrakeFactor;
					const float BrakeAccelerationSizeSquared = BrakeAcceleration.SizeSquared();
					const float MaxAccelerationSizeSquared = FMath::Square(MaxAccelerationMagnitude); 
					
					FVector TurnAcceleration = FVector::ZeroVector;
					if (BrakeAccelerationSizeSquared < MaxAccelerationSizeSquared)
					{
						TurnAcceleration = FMath::Sqrt(MaxAccelerationSizeSquared - BrakeAccelerationSizeSquared) * TurnForceDirection;
					}
					
					Acceleration = BrakeAcceleration + TurnAcceleration;
				}
			}
			else
			{
				// This finds the component of TraceDirection that is perpendicular to VelocityDirection.
				const FVector TurnComponent = TraceDirection - (FVector::DotProduct(TraceDirection, VelocityDirection) * VelocityDirection);
				const FVector TurnForceDirection = TurnComponent.GetSafeNormal();
				Acceleration = MaxAccelerationMagnitude * TurnForceDirection;
			}
			
			return Acceleration;
		
		}
		// No collision-free path was found.
		if (bCanHomingChangeSpeed)
		{
			// If we can change speed, brake. This will shorten the trace in the future and improve our chances of finding a path.
			Acceleration = -VelocityDirection * MaxAccelerationMagnitude;
		}
		else
		{
			// If we can't change speed, we just apply the normal homing acceleration.
			Acceleration = Compute_BHP_HomingAcceleration(
				CollisionComponent,
				ProNavState,
				HomingKinematicState,
				MaxAccelerationMagnitude,
				MaxSpeed,
				DeltaTime,
				bCanHomingChangeSpeed,
				ExternalAcceleration,
				TargetImpactTimeSeconds);
		}
		return Acceleration;	
	}
	
	// No collision detected, so we can apply the homing acceleration if doing so won't cause a collision.
	Acceleration = Compute_BHP_HomingAcceleration(
		CollisionComponent,
		ProNavState,
		HomingKinematicState,
		MaxAccelerationMagnitude,
		MaxSpeed,
		DeltaTime,
		bCanHomingChangeSpeed,
		ExternalAcceleration,
		TargetImpactTimeSeconds);

	FVector NewVelocity = HomingKinematicState.PursuerVelocity + Acceleration * DeltaTime;
	const FVector NewVelocityDirection = NewVelocity.GetSafeNormal();
	SphereTraceStart = BoundingSphere.Center + NewVelocityDirection * Offset;
	SphereTraceEnd = SphereTraceStart + NewVelocityDirection * SphereTraceDistance;
	bHit = World->SweepSingleByChannel(HitResult, SphereTraceStart, SphereTraceEnd, FQuat::Identity, CollisionAvoidanceParams.CollisionAvoidanceTraceChannel, ModifiedSphere, Params);
	if (bHit && (HitResult.ImpactPoint - CollisionComponentLocation).SizeSquared() < LineOfSightDistanceSquared) // Obstacle must not be beyond the homing point.
	{
		CollisionAvoidanceParams.bAvoidingCollision = true;
		
		// Pursuit acceleration would cause a collision, so we don't apply it. Instead, just wait until we clear the obstacle.
		Acceleration = bCanHomingChangeSpeed ? MaxAccelerationMagnitude * VelocityDirection : FVector::ZeroVector;
	}

	return Acceleration;
}

FFiringSolution UBHP_FunctionLibrary::ComputeFiringSolution(
	const FVector& ShooterLocation,
	const FVector& TargetLocation,
	FVector TargetVelocity,
	const float ProjectileSpeed,
	const FVector ShooterVelocity,
	const bool bPreferMinTimeToImpact)
{
	TargetVelocity = TargetVelocity - ShooterVelocity; // What matters is the velocity relative to the shooter.
	
	FFiringSolution FiringSolution;
	const FVector LineOfSight = TargetLocation - ShooterLocation;
	if (LineOfSight.IsNearlyZero())
	{
		// Target and projectile are already in the same place.
		FiringSolution.bValidSolution = true;
		FiringSolution.TimeToImpactSeconds = 0.f;
		FiringSolution.ImpactLocation = TargetLocation;
		return FiringSolution;
	}

	// ProjectileSpeed must be positive.
	if (ProjectileSpeed < 0.f)
	{
		UE_LOG(BHP_Plugin, Warning, TEXT("Cannot estimate impact location with negative projectile speed: %f"), ProjectileSpeed);
		return FFiringSolution{};
	}
	
	if (TargetVelocity.IsNearlyZero())
	{
		if (!FMath::IsNearlyZero(ProjectileSpeed))
		{
			FiringSolution.bValidSolution = true;
			FiringSolution.ImpactLocation = TargetLocation;
			FiringSolution.TimeToImpactSeconds = FVector::Dist(ShooterLocation, TargetLocation) / ProjectileSpeed;
			return FiringSolution;
		}

		// Projectile and target are both stationary
		return FFiringSolution{};
	}

	// Target is moving and projectile is stationary (unlikely case, but possible)
	if (FMath::IsNearlyZero(ProjectileSpeed))
	{
		// We know TargetsSpeed is not zero from the check above
		const float TargetsSpeed = TargetVelocity.Size();

		const FVector TargetToProjectile = -LineOfSight;
		const FVector TargetsVelocityDirection = TargetVelocity / TargetsSpeed;
		const float ProjectionOnVelocity = FVector::DotProduct(TargetToProjectile, TargetsVelocityDirection);

		// Calculate the perpendicular distance from the projectile to the target's line of travel.
		const float MissDistanceSq = (TargetToProjectile - ProjectionOnVelocity * TargetsVelocityDirection).SizeSquared();

		// Time until closest approach (when the target is nearest to the projectile).
		const float T = ProjectionOnVelocity / TargetsSpeed;

		if (T >= 0.f && MissDistanceSq <= 1.e-8f) // miss distance <= (1e-4); 1e-8 = 1e-4^2
		{
			FiringSolution.bValidSolution = true;
			FiringSolution.ImpactLocation = ShooterLocation;
			FiringSolution.TimeToImpactSeconds = T;
			return FiringSolution;
		}

		return FFiringSolution{};
	}

	// Solution is quadratic of the form A*T^2 + B*T + C = 0;
	const float A = FVector::DotProduct(TargetVelocity, TargetVelocity) - FMath::Square(ProjectileSpeed);
	const float B = FVector::DotProduct(LineOfSight, TargetVelocity) * 2.f;
	const float C = FVector::DotProduct(LineOfSight, LineOfSight);
	const float D = B * B - 4 * A * C;

	// Special case where the projectile speed is nearly equal to the target's speed (resulting in A nearly 0)
	if (FMath::IsNearlyZero(A))
	{
		// A == 0 => the equation is B*T + C = 0 => T = -C / B
		if (!FMath::IsNearlyZero(B))
		{
			const float T = -C / B;
			if (T >= 0.f)
			{
				// We have a valid positive intercept time
				FiringSolution.bValidSolution = true;
				FiringSolution.TimeToImpactSeconds = T;
				FiringSolution.ImpactLocation = TargetLocation + TargetVelocity * T;
				return FiringSolution;
			}
		}
		// Either B is 0 or T was negative => no valid intercept
		return FFiringSolution{};
	}

	// no real solution
	if (D < 0.f)
	{
		return FFiringSolution{};
	}
	
	const float SqrtD = FMath::Sqrt(D);
	const float Solution1 = (-B + SqrtD) / (2.f * A);
	const float Solution2 = (-B - SqrtD) / (2.f * A);

	if (Solution1 >= 0.f)
	{
		if (Solution2 >= 0.f)
		{
			FiringSolution.TimeToImpactSeconds = bPreferMinTimeToImpact ? FMath::Min(Solution1, Solution2) : FMath::Max(Solution1, Solution2);
		}
		else
		{
			FiringSolution.TimeToImpactSeconds = Solution1;
		}
	}
	else if (Solution2 >= 0.f)
	{
		FiringSolution.TimeToImpactSeconds = Solution2;
	}
	else
	{
		return FFiringSolution{};
	}

	FiringSolution.bValidSolution = true;
	FiringSolution.ImpactLocation = TargetLocation + TargetVelocity * FiringSolution.TimeToImpactSeconds;
	return FiringSolution;
}

TArray<FVector> UBHP_FunctionLibrary::GenerateCollisionAvoidanceTraceDirections(const float AngleIncrementDeg, const bool bConstrainToPlane)
{
	TArray<FVector> Result;
	if (AngleIncrementDeg <= 0.f)
	{
		UE_LOG(BHP_Plugin, Warning, TEXT("AngleIncrementDeg must be positive to generate CollisionAvoidanceTraceDirections. AngleIncrementDeg: %f"), AngleIncrementDeg);
		return Result;
	}
	const int32 RotationsPerDirection = (180.f - AngleIncrementDeg) / AngleIncrementDeg;
	for (int32 i = 1; i <= RotationsPerDirection; ++i)
	{
		if (!bConstrainToPlane)
		{
			Result.Add(FVector::ForwardVector.RotateAngleAxis(i * AngleIncrementDeg, FVector::LeftVector)); // U
			Result.Add(FVector::ForwardVector.RotateAngleAxis(i * AngleIncrementDeg, FVector::RightVector)); // D
			Result.Add(FVector::ForwardVector.RotateAngleAxis(i * AngleIncrementDeg, FVector::UpVector)); // R
			Result.Add(FVector::ForwardVector.RotateAngleAxis(i * AngleIncrementDeg, FVector::DownVector)); // L
			Result.Add(FVector::ForwardVector.RotateAngleAxis(i * AngleIncrementDeg, FVector(0, -1, 1).GetSafeNormal())); // RU
			Result.Add(FVector::ForwardVector.RotateAngleAxis(i * AngleIncrementDeg, FVector(0, 1, -1).GetSafeNormal())); // LD
			Result.Add(FVector::ForwardVector.RotateAngleAxis(i * AngleIncrementDeg, FVector(0, 1, 1).GetSafeNormal())); // RD
			Result.Add(FVector::ForwardVector.RotateAngleAxis(i * AngleIncrementDeg, FVector(0, -1, -1).GetSafeNormal())); // LU
		}
		else
		{
			Result.Add(FVector::ForwardVector.RotateAngleAxis(i * AngleIncrementDeg, FVector::UpVector)); // R
			Result.Add(FVector::ForwardVector.RotateAngleAxis(i * AngleIncrementDeg, FVector::DownVector)); // L			
		}		
	}
	
	Result.Add(FVector::BackwardVector);
	return Result;
}

bool UBHP_FunctionLibrary::PredictActorBoundingSphereCollision(const AActor* Actor_A, const AActor* Actor_B, 
	const float DeltaTime, float& OutHitTime, FVector& Sphere_A_OutHitLocation, FVector& Sphere_B_OutHitLocation, FVector& OutImpactPoint)
{
	if (!Actor_A || !Actor_B) return false;
	
	FVector Sphere_A_Location;
	FVector BoxExtent;
	Actor_A->GetActorBounds(true, Sphere_A_Location, BoxExtent);
	const float Sphere_A_Radius = BoxExtent.Size();
	
	if (Sphere_A_Radius <= 0.f)
	{
		UE_LOG(BHP_Plugin, Warning, TEXT("Cannot predict bounding sphere collision. Actor_A %s radius == 0."), *Actor_A->GetName());
		return false;			
	}
	
	FVector Sphere_B_Location;
	Actor_B->GetActorBounds(true, Sphere_B_Location, BoxExtent);
	const float Sphere_B_Radius = BoxExtent.Size();
	
	if (Sphere_B_Radius <= 0.f)
	{
		UE_LOG(BHP_Plugin, Warning, TEXT("Cannot predict bounding sphere collision. Actor_B %s radius == 0."), *Actor_B->GetName());
		return false;			
	}
	
	// Project each actor forward over DeltaTime, assuming it continues at its current velocity.
	const FVector Sphere_A_End = Sphere_A_Location + Actor_A->GetVelocity() * DeltaTime;
	const FVector Sphere_B_End = Sphere_B_Location + Actor_B->GetVelocity() * DeltaTime;
	
	return PredictCollisionBetweenSpheres(
		Sphere_A_Location, 
		Sphere_A_End,
		Sphere_A_Radius, 
		Sphere_B_Location, 
		Sphere_B_End,
		Sphere_B_Radius, 
		OutHitTime, 
		Sphere_A_OutHitLocation, 
		Sphere_B_OutHitLocation,
		OutImpactPoint);
}

bool UBHP_FunctionLibrary::PredictCollisionBetweenSpheres(
	const FVector& Sphere_A_Start, const FVector& Sphere_A_End, const float Sphere_A_Radius,
	const FVector& Sphere_B_Start, const FVector& Sphere_B_End, const float Sphere_B_Radius,
	float& OutHitTime, FVector& Sphere_A_OutHitLocation, FVector& Sphere_B_OutHitLocation, FVector& OutImpactPoint)
{
	if (Sphere_A_Radius <= 0.f)
	{
		UE_LOG(BHP_Plugin, Warning, TEXT("UBHP_FunctionLibrary::PredictCollisionBetweenSpheres - Cannot predict collision between spheres. Sphere_A radius == 0."));
		return false;			
	}
	
	if (Sphere_B_Radius <= 0.f)
	{
		UE_LOG(BHP_Plugin, Warning, TEXT("UBHP_FunctionLibrary::PredictCollisionBetweenSpheres - Cannot predict collision between spheres. Sphere_B radius == 0."));
		return false;
	}
	
	OutHitTime = -1.f;
	Sphere_A_OutHitLocation = FVector::ZeroVector;
	Sphere_B_OutHitLocation = FVector::ZeroVector;
	OutImpactPoint = FVector::ZeroVector;
	
	// Parameterize sphere positions as a function of t from 0 to 1, where t = 0 is the start location and t = 1 is the end location.
	// When the distance between the paths is equal to RadiusA + RadiusB, the sphere bounds would just touch, indicating a collision.
	// Sphere_A: A(t) = A0 + t * (A1 - A0) 
	// Sphere_B: B(t) = B0 + t * (B1 - B0)
	// Separation between them at time t is:
	// D(t) = (B(t) - A(t))
	//		= (B0 - A0) + t * ((B1 - A1) - (B0 - A0)) 
	// Let Start = B0 - A0 and Delta = (B1 - A1) - (B0 - A0) 
	// D(t) = Start + t * Delta
	// Solve for |D(t)|² = (RadiusA + RadiusB)². Let R = RadiusA + RadiusB
	// |D(t)|² = dot(D(t), D(t))
	// |D(t)|² = dot(Start + t*Delta, Start + t*Delta)
	// R² = dot(Start, Start) + 2t*dot(Start, Delta) + t²*dot(Delta, Delta)
	// 0 = at² + bt + (c - R²)
	// discriminant = b² - 4*a*(c - R²)
	// t = (-b ± sqrt(discriminant)) / (2*a)
	
	const FVector Start = Sphere_B_Start - Sphere_A_Start;
	const float StartSizeSquared = FVector::DotProduct(Start, Start);
	const float RadiiSumSquared = FMath::Square(Sphere_A_Radius + Sphere_B_Radius);
	
	if (StartSizeSquared <= RadiiSumSquared)
	{
		// Initial overlap.
		OutHitTime = 0.f;
		Sphere_A_OutHitLocation = Sphere_A_Start;
		Sphere_B_OutHitLocation = Sphere_B_Start;
		
		const FVector ImpactNormal = (Sphere_B_OutHitLocation - Sphere_A_OutHitLocation).GetSafeNormal();
		if (ImpactNormal.IsNearlyZero())
		{
			// Centers coincide, so there is no separation direction to use as the impact normal. Fall back to the relative
			// displacement direction (same direction as relative velocity, since both are scaled by the same step duration).
			const FVector RelativeDisplacement = (Sphere_B_End - Sphere_B_Start) - (Sphere_A_End - Sphere_A_Start);
			if (RelativeDisplacement.IsNearlyZero())
			{
				// Spheres share a location and have no relative motion, so there is no meaningful impact normal. Choose an arbitrary one.
				OutImpactPoint = Sphere_A_OutHitLocation + FVector(Sphere_A_Radius, 0.f, 0.f);
			}
			else
			{
				OutImpactPoint = Sphere_A_OutHitLocation + RelativeDisplacement.GetSafeNormal() * Sphere_A_Radius;
			}
		}
		else
		{
			OutImpactPoint = Sphere_A_OutHitLocation + ImpactNormal * Sphere_A_Radius;
		}
		
		return true;
	}
	
	// Since we know that we're NOT starting with an initial overlap, the collision occurs at the first time the separation equals Sphere_A_Radius + Sphere_B_Radius (t within 0 and 1).
	
	const FVector Sphere_A_Delta = Sphere_A_End - Sphere_A_Start;
	const FVector Sphere_B_Delta = Sphere_B_End - Sphere_B_Start;
	
	// Delta is the separation at t = 1 minus the separation at t = 0 (equivalently, the relative displacement over the step).
	// If Delta is zero, the spheres have no relative motion (both stationary, or moving with identical displacement). a will be 0 and we return false.
	const FVector Delta = Sphere_B_Delta - Sphere_A_Delta;
	
	const float a = FVector::DotProduct(Delta, Delta);
	if (a <= 0.f)
	{
		// Would result in divide by zero in quadratic equation.
		return false;
	}
	
	const float b = 2.f * FVector::DotProduct(Start, Delta);
	const float c = StartSizeSquared - RadiiSumSquared;
	const float discriminant = FMath::Square(b) - 4.f * a * c;
	if (discriminant < 0.f)
	{
		// No real solution.
		return false;
	}
	
	// T_Entry is -b MINUS a positive number and T_Exit is -b PLUS a positive number, we know that T_Entry is always less than T_Exit.
	const float T_Entry = (-b - FMath::Sqrt(discriminant)) / (2.f * a);
	if (T_Entry >= 0.f && T_Entry <= 1.f)
	{
		OutHitTime = T_Entry;
		Sphere_A_OutHitLocation = Sphere_A_Start + OutHitTime * Sphere_A_Delta;
		Sphere_B_OutHitLocation = Sphere_B_Start + OutHitTime * Sphere_B_Delta;
		
		const FVector ImpactNormal = (Sphere_B_OutHitLocation - Sphere_A_OutHitLocation).GetSafeNormal();
		OutImpactPoint = Sphere_A_OutHitLocation + ImpactNormal * Sphere_A_Radius;
		
		return true;
	}
	
	const float T_Exit = (-b + FMath::Sqrt(discriminant)) / (2.f * a);
	if (T_Exit >= 0.f && T_Exit <= 1.f)
	{
		// Entry rounded just below 0 at the overlap boundary; treat as contact at t = 0
		OutHitTime = 0.f;
		Sphere_A_OutHitLocation = Sphere_A_Start;
		Sphere_B_OutHitLocation = Sphere_B_Start;
		
		const FVector ImpactNormal = (Sphere_B_OutHitLocation - Sphere_A_OutHitLocation).GetSafeNormal();
		OutImpactPoint = Sphere_A_OutHitLocation + ImpactNormal * Sphere_A_Radius;
		
		return true;
	}

	return false;
}

bool UBHP_FunctionLibrary::WillSpheresCollide(const FVector& Sphere_A_Start, const FVector& Sphere_A_End,
	const float Sphere_A_Radius, const FVector& Sphere_B_Start, const FVector& Sphere_B_End, const float Sphere_B_Radius)
{
	if (Sphere_A_Radius <= 0.f)
	{
		UE_LOG(BHP_Plugin, Warning, TEXT("UBHP_FunctionLibrary::WillSpheresCollide - Cannot predict collision between spheres. Sphere_A radius == 0."));
		return false;			
	}
	
	if (Sphere_B_Radius <= 0.f)
	{
		UE_LOG(BHP_Plugin, Warning, TEXT("UBHP_FunctionLibrary::WillSpheresCollide - Cannot predict collision between spheres. Sphere_B radius == 0."));
		return false;
	}
	
	// Parameterize their positions over delta time as a function of t from 0 to 1.
	// When the distance between the paths is equal to RadiusA + RadiusB, Sphere_A & Sphere_B's surfaces would just touch, indicating a collision.
	// Sphere_A: A(t) = A0 + t * (A1 - A0) 
	// Sphere_B: B(t) = B0 + t * (B1 - B0)
	// Separation between them at time t is:
	// D(t) = (B(t) - A(t))
	//		= (B0 - A0) + t * ((B1 - A1) - (B0 - A0)) 
	// Let Start = B0 - A0 and Delta = (B1 - A1) - (B0 - A0) 
	// D(t) = Start + t * Delta
	// We want to find the time where |D(t)|² is the minimum. This is our time of closest approach. 
	// |D(t)|² = dot(D(t), D(t))
	// |D(t)|² = dot(Start + t*Delta, Start + t*Delta)
	// |D(t)|² = dot(Start, Start) + 2t*dot(Start, Delta) + t²*dot(Delta, Delta)
	// To find the minimum, take the derivative with respect to t and set it to zero:
	// d/dt |D(t)|² = 2t*dot(Delta, Delta) + 2*dot(Start, Delta) = 0
	// t = -dot(Start, Delta) / dot(Delta, Delta)
	
	const FVector Start = Sphere_B_Start - Sphere_A_Start;
	const FVector Delta = (Sphere_B_End - Sphere_A_End) - (Sphere_B_Start - Sphere_A_Start);
	const float StartSizeSquared = FVector::DotProduct(Start, Start);
	const float RadiiSumSquared = FMath::Square(Sphere_A_Radius + Sphere_B_Radius);
	if (StartSizeSquared <= RadiiSumSquared)
	{
		// Initial overlap.
		return true;
	}
	
	const float DeltaSizeSquared = FVector::DotProduct(Delta, Delta);
	if (DeltaSizeSquared <= 0.f)
	{
		return false;
	}
	
	const float TimeOfClosestApproach = FMath::Clamp(-FVector::DotProduct(Start, Delta) / DeltaSizeSquared, 0.f, 1.f);
	
	const FVector Sphere_A_LocationAtClosestApproach = Sphere_A_Start + TimeOfClosestApproach * (Sphere_A_End - Sphere_A_Start);
	const FVector Sphere_B_LocationAtClosestApproach = Sphere_B_Start + TimeOfClosestApproach * (Sphere_B_End - Sphere_B_Start);
	
	if ((Sphere_B_LocationAtClosestApproach - Sphere_A_LocationAtClosestApproach).SizeSquared() <= RadiiSumSquared)
	{
		return true;
	}
	
	return false;
}