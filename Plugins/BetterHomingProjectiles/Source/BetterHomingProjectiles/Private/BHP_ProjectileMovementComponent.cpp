// Copyright 2023 Harlan Cox. All Rights Reserved.

#include "BHP_ProjectileMovementComponent.h"

#include "BHP_FunctionLibrary.h"
#include "GameFramework/Actor.h"
#include "Components/PrimitiveComponent.h"
#include "Engine/World.h"

UBHP_ProjectileMovementComponent::UBHP_ProjectileMovementComponent()
{
	bIsHomingProjectile = true;
}

void UBHP_ProjectileMovementComponent::SetHomingPointOnActor(AActor* TargetActor, const FVector& NewHomingPoint)
{
	ClearHomingTarget();
	
	if (TargetActor != nullptr)
	{
		HomingTargetActor = TargetActor;
		HomingPointLocalOffset = TargetActor->GetTransform().InverseTransformPosition(NewHomingPoint);
		bTransformLocalOffset = !HomingPointLocalOffset.IsNearlyZero(1.f); // 1 cm is close enough
	}
}

void UBHP_ProjectileMovementComponent::SetHomingPointOffActor(const FVector& NewHomingPoint)
{
	ClearHomingTarget();
	
	bHomingPointOffActor = true;
	HomingPoint = NewHomingPoint;
}

void UBHP_ProjectileMovementComponent::ClearHomingTarget()
{
	HomingTargetComponent = nullptr;
	HomingTargetActor = nullptr;
	HomingPoint = FVector::ZeroVector;
	HomingPointLocalOffset = FVector::ZeroVector;
	bTransformLocalOffset = false;
	bHomingPointOffActor = false;
	PreviousHomingPoint = FVector::ZeroVector;
	PreviousLineOfSight = FVector::ZeroVector;
	CachedBoundsTargetActor = nullptr;
}

void UBHP_ProjectileMovementComponent::AddAcceleration(const FVector& Acceleration)
{
	// AddForce from parent PMC adds force as acceleration (mass has no effect).
	// See parent ComputeAcceleration function where Acceleration += PendingForceThisUpdate;
	AddForce(Acceleration);
}

bool UBHP_ProjectileMovementComponent::GetTargetBoundingSphere(const AActor* TargetActor, FVector& OutCenter, float& OutRadius) const
{
	if (!TargetActor) return false;

	// Recompute the rotation/scale-independent local box only when the actor changes.
	if (CachedBoundsTargetActor.Get() != TargetActor)
	{
		const FBox LocalBox = TargetActor->CalculateComponentsBoundingBoxInLocalSpace();
		if (!LocalBox.IsValid)
		{
			return false; 
		}
		CachedTargetLocalExtent = LocalBox.GetExtent();
		CachedTargetLocalCenter = LocalBox.GetCenter();
		CachedBoundsTargetActor = TargetActor;
	}

	// The bounding sphere may not be centered on the actor's origin, so we have to transform the sphere's offset from the 
	// actor's origin to get the actual center of the sphere in world space.
	const FTransform& TargetActorTransform = TargetActor->GetActorTransform();
	OutCenter = TargetActorTransform.TransformPosition(CachedTargetLocalCenter);
	
	// We scale the radius by the actor's scale in case the actor's scale is changing at runtime. 
	OutRadius = (CachedTargetLocalExtent * TargetActor->GetActorScale3D()).Size();
	
	return OutRadius > 0.f;
}

bool UBHP_ProjectileMovementComponent::WillBoundingSpheresCollide(const FVector& InVelocity, float DeltaTime) const
{
	if (bHomingPointOffActor)
	{
		return false;
	}
	
	const float ProjectileRadius = UpdatedComponent->Bounds.GetSphere().W;
	if (ProjectileRadius <= 0.f)
	{
		FString OwnerName = GetOwner() ? GetOwner()->GetName() : "";
		if (GetOwner())
		{
			UE_LOG(BHP_Plugin, Warning, TEXT("Cannot predict collision between frames with projectile %s radius == 0."), *OwnerName);
		}
		return false;			
	}
	
	// Can't predict a collision without a target actor. Our goal is to predict collisions with the target only, NOT every other actor in the world.
	const AActor* TargetActor = GetHomingTargetActor();
	if (!TargetActor) return false;
	
	FVector TargetSphereLocation;
	float TargetRadius;
	if (!GetTargetBoundingSphere(TargetActor, TargetSphereLocation, TargetRadius))
	{
		UE_LOG(BHP_Plugin, Warning, TEXT("Cannot predict collision: target %s has invalid bounds."), *TargetActor->GetName());
		return false;
	}
	
	const FVector ProjectileSphereLocation = UpdatedComponent->Bounds.GetSphere().Center; // NOT component location, because the component origin may be offset from the sphere bounds origin.
	const FVector ProjectileLocationDelta = ComputeMoveDelta(InVelocity, DeltaTime);
	const FVector NewProjectileLocation = ProjectileSphereLocation + ProjectileLocationDelta;
	
	// Assume the target actor continues at its current velocity. Other projectiles can change their acceleration instantly,
	// so this is often a better assumption than assuming constant acceleration in hopes of a better approximation.
	const FVector TargetActorVelocity = TargetActor->GetVelocity();
	if (TargetActorVelocity.IsNearlyZero())
	{
		// If target is not moving, we don't have to predict collision between frames, because normal projectile movement will return the collision if bSweepCollision is true.
		return false;
	}
	const FVector TargetLocationDelta = TargetActorVelocity * DeltaTime;
	const FVector NewTargetLocation = TargetSphereLocation + TargetLocationDelta;	
	
	return UBHP_FunctionLibrary::WillSpheresCollide(
		ProjectileSphereLocation,
		NewProjectileLocation,
		ProjectileRadius,
		TargetSphereLocation,
		NewTargetLocation,
		TargetRadius);
}

bool UBHP_ProjectileMovementComponent::EstimateImpactLocationAndTimeToImpact(FVector& OutImpactLocation, float& OutTimeToImpact, const FVector& ProjectileLocation,
                                                                             const float ProjectileSpeed, const FVector& TargetLocation, FVector TargetVelocity, const bool bPreferMinTimeToImpact)
{
	const FFiringSolution FiringSolutionResult =
		UBHP_FunctionLibrary::ComputeFiringSolution(
		ProjectileLocation,
		TargetLocation,
		TargetVelocity,
		ProjectileSpeed,
		FVector::ZeroVector, // ShooterVelocity is not used in this function
		bPreferMinTimeToImpact);

	OutImpactLocation = FiringSolutionResult.ImpactLocation;
	OutTimeToImpact = FiringSolutionResult.TimeToImpactSeconds;
	return FiringSolutionResult.bValidSolution;
}

bool UBHP_ProjectileMovementComponent::EstimateImpactLocation(FVector& OutImpactLocation, const FVector& ProjectileLocation, const float ProjectileSpeed, const FVector& TargetLocation, FVector TargetVelocity)
{
	const FFiringSolution FiringSolutionResult =
		UBHP_FunctionLibrary::ComputeFiringSolution(
		ProjectileLocation,
		TargetLocation,
		TargetVelocity,
		ProjectileSpeed);

	OutImpactLocation = FiringSolutionResult.ImpactLocation;
	return FiringSolutionResult.bValidSolution;
}

bool UBHP_ProjectileMovementComponent::EstimateFiringSolutionAndTimeToImpact(FVector& OutImpactLocation, float& OutTimeToImpact, const FVector& ShooterLocation,
const FVector& ShooterVelocity, const FVector& TargetLocation, FVector TargetVelocity, const float ProjectileSpeed, const bool bPreferMinTimeToImpact)
{
	const FFiringSolution FiringSolutionResult =
		UBHP_FunctionLibrary::ComputeFiringSolution(
		ShooterLocation,
		TargetLocation,
		TargetVelocity,
		ProjectileSpeed,
		ShooterVelocity,
		bPreferMinTimeToImpact);

	OutImpactLocation = FiringSolutionResult.ImpactLocation;
	OutTimeToImpact = FiringSolutionResult.TimeToImpactSeconds;
	return FiringSolutionResult.bValidSolution;
}

bool UBHP_ProjectileMovementComponent::EstimateFiringSolution(FVector& OutImpactLocation, const FVector& ShooterLocation, const FVector& ShooterVelocity, const FVector& TargetLocation, FVector TargetVelocity, const float ProjectileSpeed)
{
	const FFiringSolution FiringSolutionResult =
		UBHP_FunctionLibrary::ComputeFiringSolution(
		ShooterLocation,
		TargetLocation,
		TargetVelocity,
		ProjectileSpeed,
		ShooterVelocity);

	OutImpactLocation = FiringSolutionResult.ImpactLocation;
	return FiringSolutionResult.bValidSolution;
}

void UBHP_ProjectileMovementComponent::InitializeComponent()
{
	Super::Super::InitializeComponent();

	// InitialSpeed > 0 overrides initial velocity magnitude.
	if (InitialSpeed > 0.f)
	{
		Velocity = Velocity.GetSafeNormal() * InitialSpeed;
	}

	if (bInitialVelocityInLocalSpace)
	{
		SetVelocityInLocalSpace(Velocity);
	}

	if (bInheritProjectileOwnerVelocity)
	{
		if (const AActor* Projectile = GetOwner())
		{
			if (const AActor* ProjectileOwner = Projectile->GetOwner())
			{
				const FVector NewVelocity = Velocity + ProjectileOwner->GetVelocity();
				if (MaxSpeed > 0.f && bInheritedVelocityOverridesMaxSpeed)
				{
					MaxSpeed = FMath::Max(MaxSpeed, NewVelocity.Size());
				}
				Velocity = LimitVelocity(NewVelocity);
			}
		}
	}

	if (Velocity.SizeSquared() > 0.f)
	{
		if (bRotationFollowsVelocity && UpdatedComponent)
		{
			FRotator DesiredRotation = Velocity.Rotation();
			if (bRotationRemainsVertical)
			{
				DesiredRotation.Pitch = 0.0f;
				DesiredRotation.Yaw = FRotator::NormalizeAxis(DesiredRotation.Yaw);
				DesiredRotation.Roll = 0.0f;
			}

			UpdatedComponent->SetWorldRotation(DesiredRotation);
		}

		UpdateComponentVelocity();
	
		if (UpdatedPrimitive && UpdatedPrimitive->IsSimulatingPhysics())
		{
			UpdatedPrimitive->SetPhysicsLinearVelocity(Velocity);
		}
	}

	if (bEnableCollisionAvoidance)
	{
		CollisionAvoidanceParams.CollisionAvoidanceTracePoints = UBHP_FunctionLibrary::GenerateCollisionAvoidanceTraceDirections(CollisionAvoidanceParams.CollisionAvoidanceTraceAngle, bConstrainToPlane);
	}
}

void UBHP_ProjectileMovementComponent::TickComponent(float DeltaTime, ELevelTick TickType, FActorComponentTickFunction* ThisTickFunction)
{
	// TRACE_CPUPROFILER_EVENT_SCOPE(STAT_BHP_ProjectileMovementComponent_TickComponent);
	// TRACE_BOOKMARK(TEXT("BHP_ProjectileMovementComponent_TickComponent"))

	bool bCheckForMissedTarget = false;
	bForceHitThisFrame = false;
	if (IsActive() && IsValid(UpdatedComponent) && !UpdatedComponent->IsSimulatingPhysics() && bSimulationEnabled && !ShouldSkipUpdate(DeltaTime))
	{
		bHomingActiveThisUpdate = IsHomingActive();
		if (bHomingActiveThisUpdate)
		{
			UpdateHomingPoint(DeltaTime);
			UpdateProNavState(DeltaTime);
			
			if (bPreventCollisionTunnelingWithHomingTarget && WillBoundingSpheresCollide(Velocity, DeltaTime))
			{
				bForceHitThisFrame = true;
			}
			else
			{
				FVector ExternalAcceleration = GetPendingForce();
				ExternalAcceleration.Z += GetGravityZ();
				HomingAcceleration =
					bEnableCollisionAvoidance ?
					ComputeHomingAccelerationWithCollisionAvoidance(Velocity, DeltaTime, ExternalAcceleration) :
					ComputeBetterHomingAcceleration(Velocity, DeltaTime, ExternalAcceleration);
				AddForce(HomingAcceleration);
				bCheckForMissedTarget = true;
			}
		}
	}
	
	Super::TickComponent(DeltaTime, TickType, ThisTickFunction);
	
	// Have to check for missed target after tick
	if (bCheckForMissedTarget)
	{
		CheckForMissedTarget();
	}
}

bool UBHP_ProjectileMovementComponent::ShouldUseSubStepping() const
{
	return bForceSubStepping || GetGravityZ() != 0.f || bHomingActiveThisUpdate;
}

bool UBHP_ProjectileMovementComponent::IsHomingActive() const
{
	return bIsHomingProjectile && (HomingTargetComponent.IsValid() || HomingTargetActor.IsValid() || bHomingPointOffActor);
}

void UBHP_ProjectileMovementComponent::UpdateHomingPoint(const float DeltaTime)
{	
	if (HomingTargetComponent.IsValid())
	{
		HomingPoint = HomingTargetComponent->GetComponentLocation();
	}
	else if (HomingTargetActor.IsValid())
	{
		if (bTransformLocalOffset)
		{
			HomingPoint = HomingTargetActor->GetTransform().TransformPosition(HomingPointLocalOffset);
		}
		else
		{
			HomingPoint = HomingTargetActor->GetActorLocation();
		}
	}

	// Estimate the HomingPoint's velocity. The first frame will result in an invalid velocity, but the PreviousLineOfSight
	// will also be zero resulting in zero LineOfSightRotationAxis and zero ProNav homing acceleration. Therefore, no
	// correction is required to account for the incorrect velocity on the first frame. 
	HomingPointVelocity = (HomingPoint - PreviousHomingPoint) / DeltaTime;
	PreviousHomingPoint = HomingPoint;
}

void UBHP_ProjectileMovementComponent::UpdateProNavState(const float DeltaTime)
{
	if (!IsValid(UpdatedComponent)) return;
	
	const FVector PreviousLineOfSightAxis = PreviousLineOfSight.GetSafeNormal();
	const FVector LineOfSight = HomingPoint - UpdatedComponent->GetComponentLocation();
	LineOfSightDistance = LineOfSight.Size();
	LineOfSightAxis = FMath::IsNearlyZero(LineOfSightDistance) ? FVector::ZeroVector : LineOfSight / LineOfSightDistance;
	LineOfSightAngularSpeed = FMath::Acos( FMath::Clamp(FVector::DotProduct(LineOfSightAxis, PreviousLineOfSightAxis), -1.f, 1.f)) / DeltaTime;
	LineOfSightRotationAxis = FVector::CrossProduct(PreviousLineOfSightAxis, LineOfSightAxis).GetSafeNormal();
	ClosingSpeed = (Velocity - HomingPointVelocity).Dot(LineOfSightAxis);
	PreviousLineOfSight = LineOfSight;
}

FVector UBHP_ProjectileMovementComponent::ComputeAcceleration(const FVector& InVelocity, float DeltaTime) const
{
	FVector Acceleration(FVector::ZeroVector);
	
	Acceleration.Z += GetGravityZ();
	
	Acceleration += PendingForceThisUpdate;

	// Homing acceleration is added to the pending force in TickComponent.
	
	return Acceleration;
}

FVector UBHP_ProjectileMovementComponent::ComputeBetterHomingAcceleration(const FVector& InVelocity, float DeltaTime, const FVector& ExternalAcceleration)
{
	if (HomingAccelerationMagnitude <= 0.f)
	{
		return FVector::ZeroVector;
	}

	FVector Acceleration;
	if (!bCanHomingChangeSpeed)
	{
		// Returns an acceleration perpendicular to the velocity.
		const FVector TargetHomingAcceleration = ComputePureProNavAcceleration(InVelocity);
		const FVector InVelocityDirection = InVelocity.GetSafeNormal();
			
		// Attempt to compensate for external acceleration to prevent the projectile from sagging due to gravity or being pushed off course by external forces.
		Acceleration = TargetHomingAcceleration - (ExternalAcceleration - ExternalAcceleration.Dot(InVelocityDirection) * InVelocityDirection);
		Acceleration = Acceleration.GetClampedToMaxSize(HomingAccelerationMagnitude);

		return Acceleration;
	}

	if (ClosingSpeed > 0.f) // We're getting closer to the target
	{
		// Returns acceleration perpendicular to the line of sight and the line of sight rotation axis.
		const FVector TargetHomingAcceleration = ComputeTrueProNavAcceleration(ClosingSpeed);

		// Attempt to compensate for external acceleration to prevent the projectile from sagging due to gravity or being pushed off course by external forces.
		Acceleration = TargetHomingAcceleration - (ExternalAcceleration - ExternalAcceleration.Dot(LineOfSightAxis) * LineOfSightAxis);

		// If the acceleration perpendicular to the line of sight is less than the HomingAccelerationMagnitude,
		// then we can add acceleration in the direction of the line of sight.
		const float HomingAccelerationMagnitudeSquared = FMath::Square(HomingAccelerationMagnitude);
		const float HomingAccelerationSizeSquared = Acceleration.SizeSquared();
		if (HomingAccelerationSizeSquared < HomingAccelerationMagnitudeSquared)
		{
			const float RemainingAccelerationMagnitude = FMath::Sqrt(HomingAccelerationMagnitudeSquared - HomingAccelerationSizeSquared);
			const UWorld* World = GetWorld();

			if (World && TargetImpactTimeSeconds > World->TimeSeconds) // Valid TargetImpactTime in the future.
			{
				const float TimeUntilImpact = TargetImpactTimeSeconds - World->TimeSeconds;
				const float TargetClosureRate = LineOfSightDistance / TimeUntilImpact;
				Acceleration += LineOfSightAxis * FMath::Clamp((TargetClosureRate - ClosingSpeed) / DeltaTime, -RemainingAccelerationMagnitude, RemainingAccelerationMagnitude);
			}
			else // Apply all remaining acceleration along LOS to arrive at the target ASAP.
			{
				Acceleration += RemainingAccelerationMagnitude * LineOfSightAxis;
			}
		}
		else
		{
			Acceleration = Acceleration.GetClampedToMaxSize(HomingAccelerationMagnitude);
		}

		return Acceleration;
	}

	// We're getting further away from the target. 
	if (MaxSpeed > 0.f)
	{
		const FVector TargetVelocity = MaxSpeed * LineOfSightAxis;
		const FVector NewVelocity = FMath::VInterpConstantTo(InVelocity, TargetVelocity, DeltaTime, HomingAccelerationMagnitude);
		Acceleration = (NewVelocity - InVelocity) / DeltaTime;
	}
	else // Max speed is infinity
	{
		Acceleration = HomingAccelerationMagnitude * LineOfSightAxis;
	}

	return Acceleration;
}

FVector UBHP_ProjectileMovementComponent::ComputeHomingAccelerationWithCollisionAvoidance(const FVector& InVelocity, float DeltaTime, const FVector& ExternalAcceleration)
{
	if (InVelocity.IsNearlyZero())
	{
		return ComputeBetterHomingAcceleration(InVelocity, DeltaTime, ExternalAcceleration);
	}

	const UWorld* World = GetWorld();
	if (!World || HomingAccelerationMagnitude <= 0.f || !UpdatedComponent)
	{
		return FVector::ZeroVector;
	}

	const UE::Math::TSphere BoundingSphere = UpdatedComponent->Bounds.GetSphere();
	const float SphereBoundsRadius = BoundingSphere.W;

	if (SphereBoundsRadius <= 0.f)
	{
		UE_LOG(BHP_Plugin, Warning, TEXT("ComputeHomingAccelerationWithCollisionAvoidance called with zero sphere bounds radius. Unable to use collision avoidance. Ensure the UpdatedComponent has a valid collision shape."));
		return ComputeBetterHomingAcceleration(InVelocity, DeltaTime, ExternalAcceleration);
	}
	
	FVector Acceleration;

	FVector UpdatedComponentLocation = UpdatedComponent->GetComponentLocation();
	const FCollisionShape ModifiedSphere = FCollisionShape::MakeSphere(SphereBoundsRadius * CollisionAvoidanceParams.SphereRadiusMultiplier);
	const float ModifiedRadius = SphereBoundsRadius * CollisionAvoidanceParams.SphereRadiusMultiplier;

	// Offset the trace in the direction of the velocity to avoid initial overlap behind the projectile.
	const float Offset = CollisionAvoidanceParams.SphereRadiusMultiplier > 1.f ? ModifiedRadius - SphereBoundsRadius : 0.f;
	const FVector VelocityDirection = InVelocity.GetUnsafeNormal(); // We know InVelocity is not zero, so we can use GetUnsafeNormal().
	FVector SphereTraceStart = BoundingSphere.Center + VelocityDirection * Offset;
	const float StopDistance = InVelocity.SizeSquared() / (2.f * HomingAccelerationMagnitude);

	// Max trace distance is the distance which would make the sphere trace just touch the homing point if directed toward it.
	const float SphereTraceDistance = FMath::Clamp(StopDistance * CollisionAvoidanceParams.TraceDistanceFactor, CollisionAvoidanceParams.MinTraceDistance, LineOfSightDistance - Offset - ModifiedRadius);
	FVector SphereTraceEnd = SphereTraceStart + VelocityDirection * SphereTraceDistance;

	FHitResult HitResult;
	FCollisionQueryParams Params;
	Params.AddIgnoredActor(GetOwner());
	Params.AddIgnoredActor(HomingTargetActor.Get());
	if (HomingTargetComponent.IsValid()) Params.AddIgnoredActor(HomingTargetComponent->GetOwner());
	Params.AddIgnoredActors(CollisionAvoidanceParams.IgnoredActors);
	bool bHit = World->SweepSingleByChannel(HitResult, SphereTraceStart, SphereTraceEnd, FQuat::Identity, CollisionAvoidanceParams.CollisionAvoidanceTraceChannel, ModifiedSphere, Params);
	const float LineOfSightDistanceSquared = FMath::Square(LineOfSightDistance);

	if (bHit && (HitResult.ImpactPoint - UpdatedComponentLocation).SizeSquared() < LineOfSightDistanceSquared) // Obstacle must not be beyond the homing point.
	{
		FQuat VelocityQuat;
		if (bConstrainToPlane)
		{
			VelocityQuat = FQuat(FRotationMatrix::MakeFromXZ(InVelocity, GetPlaneConstraintNormal()));
		}
		else
		{
			VelocityQuat = FQuat::FindBetweenVectors(FVector::ForwardVector, VelocityDirection);
		}
		
		if (HitResult.Distance == 0.f)
		{
			// Initial overlap.
			Acceleration = HomingAccelerationMagnitude * HitResult.Normal;
			return Acceleration;
		}

		if (CollisionAvoidanceParams.CollisionAvoidanceTracePoints.IsEmpty()) // Could be empty if bEnableCollisionAvoidance was switched on after component initialization.
		{
			CollisionAvoidanceParams.CollisionAvoidanceTracePoints = UBHP_FunctionLibrary::GenerateCollisionAvoidanceTraceDirections(CollisionAvoidanceParams.CollisionAvoidanceTraceAngle, bConstrainToPlane);
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
			if (bHit && (HitResult.ImpactPoint - UpdatedComponentLocation).SizeSquared() < LineOfSightDistanceSquared)
			{
				continue;
			}
			
			// The line trace was not blocked, so we must perform a sphere trace to check if we can fit through the gap.
			bHit = World->SweepSingleByChannel(HitResult, SphereTraceStart, SphereTraceEnd, FQuat::Identity, CollisionAvoidanceParams.CollisionAvoidanceTraceChannel, ModifiedSphere, Params);
			if (bHit && (HitResult.ImpactPoint - UpdatedComponentLocation).SizeSquared() < LineOfSightDistanceSquared)
			{
				continue;
			}
			
			// No hit, or the hit was beyond the target.
			if (bCanHomingChangeSpeed)
			{
				// We know the traces were generated using CollisionAvoidanceTraceAngle, so we can use it to determine the turn angle.
				const int32 VectorsPerGroup = bConstrainToPlane ? 2 : 8;
				const int32 Group = (i / VectorsPerGroup) + 1;
				const float TurnAngle = FMath::Min(CollisionAvoidanceParams.CollisionAvoidanceTraceAngle * Group, 180.f); // must not be > 180.
				
				if (TurnAngle > CollisionAvoidanceParams.FullBrakeTurnAngleDegrees)
				{
					// Full brake
					Acceleration = HomingAccelerationMagnitude * -VelocityDirection;
				}
				else
				{
					// Mix turning and braking, depending on the turn angle.
					const float BrakeFactor = FMath::IsNearlyZero(CollisionAvoidanceParams.FullBrakeTurnAngleDegrees) ? 1.f : FMath::Clamp(TurnAngle / CollisionAvoidanceParams.FullBrakeTurnAngleDegrees, 0.f, 1.f);
					const FVector TurnComponent = TraceDirection - (FVector::DotProduct(TraceDirection, VelocityDirection) * VelocityDirection);
					const FVector TurnForceDirection = TurnComponent.GetSafeNormal();
					const FVector BrakeAcceleration = HomingAccelerationMagnitude * -VelocityDirection * BrakeFactor;
					const float BrakeAccelerationSizeSquared = BrakeAcceleration.SizeSquared();
					const float HomingAccelerationMagnitudeSquared = FMath::Square(HomingAccelerationMagnitude);
					
					FVector TurnAcceleration = FVector::ZeroVector;
					if (BrakeAccelerationSizeSquared < HomingAccelerationMagnitudeSquared)
					{
						TurnAcceleration = FMath::Sqrt(HomingAccelerationMagnitudeSquared - BrakeAccelerationSizeSquared) * TurnForceDirection;
					}
					
					Acceleration = BrakeAcceleration + TurnAcceleration;
				}
			}
			else
			{
				// This finds the component of TraceDirection that is perpendicular to VelocityDirection.
				const FVector TurnComponent = TraceDirection - (FVector::DotProduct(TraceDirection, VelocityDirection) * VelocityDirection);
				const FVector TurnForceDirection = TurnComponent.GetSafeNormal();
				Acceleration = HomingAccelerationMagnitude * TurnForceDirection;
			}
			
			return Acceleration;
		}
		// No collision-free path was found.
		if (bCanHomingChangeSpeed)
		{
			// If we can change speed, brake. This will shorten the trace in the future and improve our chances of finding a path.
			Acceleration = -VelocityDirection * HomingAccelerationMagnitude;
		}
		else
		{
			// If we can't change speed, we just apply the normal homing acceleration.
			Acceleration = ComputeBetterHomingAcceleration(InVelocity, DeltaTime, ExternalAcceleration);
		}
		return Acceleration;	
	}
	
	// No collision detected, so we can apply the homing acceleration if doing so won't cause a collision.
	Acceleration = ComputeBetterHomingAcceleration(InVelocity, DeltaTime, ExternalAcceleration);

	FVector NewVelocity = InVelocity + Acceleration * DeltaTime;
	const FVector NewVelocityDirection = NewVelocity.GetSafeNormal();
	SphereTraceStart = BoundingSphere.Center + NewVelocityDirection * Offset;	
	SphereTraceEnd = SphereTraceStart + NewVelocityDirection * SphereTraceDistance;
	bHit = World->SweepSingleByChannel(HitResult, SphereTraceStart, SphereTraceEnd, FQuat::Identity, CollisionAvoidanceParams.CollisionAvoidanceTraceChannel, ModifiedSphere, Params);
	if (bHit && (HitResult.ImpactPoint - UpdatedComponentLocation).SizeSquared() < LineOfSightDistanceSquared) // Obstacle must not be beyond the homing point.
	{
		// Pursuit acceleration would cause a collision, so we don't apply it. Instead, just wait until we clear the obstacle.
		Acceleration = bCanHomingChangeSpeed ? HomingAccelerationMagnitude * VelocityDirection : FVector::ZeroVector;
	}

	return Acceleration;
}

void UBHP_ProjectileMovementComponent::CheckForMissedTarget() const
{
	if (!IsValid(UpdatedComponent) || !OnMissedHomingTarget.IsBound()) return;
	
	bool bWithinThreshold;
	if (MissedHomingTargetDistanceThreshold <= 0.f)
	{
		bWithinThreshold = true;
	}
	else
	{
		bWithinThreshold = LineOfSightDistance <= MissedHomingTargetDistanceThreshold;		
	}

	if (bWithinThreshold)
	{
		if (bPreviousClosureRatePositive && ClosingSpeed < 0.f && !bMissedHomingTarget)
		{
			OnMissedHomingTarget.Broadcast();
			bMissedHomingTarget = true;
		}
	}
	else
	{
		bMissedHomingTarget = false;
	}

	bPreviousClosureRatePositive = ClosingSpeed > 0.f;
}

FVector UBHP_ProjectileMovementComponent::ComputeTrueProNavAcceleration(const float InClosureRate) const
{
	const FVector AccelerationDirection = FVector::CrossProduct(LineOfSightRotationAxis, LineOfSightAxis);
	const float AccelerationMagnitude = ProportionalNavigationGain * LineOfSightAngularSpeed * InClosureRate;
	
	return AccelerationMagnitude * AccelerationDirection;
}

FVector UBHP_ProjectileMovementComponent::ComputePureProNavAcceleration(const FVector& InVelocity) const
{
	const FVector AccelerationDirection = FVector::CrossProduct(LineOfSightRotationAxis, InVelocity).GetSafeNormal();
	const float AccelerationMagnitude = ProportionalNavigationGain * LineOfSightAngularSpeed * InVelocity.Size();

	return AccelerationMagnitude * AccelerationDirection;
}

FVector UBHP_ProjectileMovementComponent::ComputeMoveDelta(const FVector& InVelocity, float DeltaTime) const
{
	if (bForceHitThisFrame && IsValid(UpdatedComponent))
	{
		return HomingPoint - UpdatedComponent->GetComponentLocation();		
	}
	else
	{
		return Super::ComputeMoveDelta(InVelocity, DeltaTime);
	}
}
