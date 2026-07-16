// Copyright 2023 Harlan Cox. All Rights Reserved.

#include "BHP_MissileMovementComponent.h"
#include "Engine/World.h"
#include "TimerManager.h"

void UBHP_MissileMovementComponent::BeginPlay()
{
	Super::BeginPlay();

	// Homing should not apply thrust until the rocket motor ignites.
	bCanHomingChangeSpeed = false;

	// Cache the base homing rotation interp speed for ramping and restarting.
	BaseHomingRotationInterpSpeed =	HomingRotationInterpSpeed;

	// Cache the default homing state for restarting.
	bDefaultIsHomingProjectile = bIsHomingProjectile;
	
	HandleRocketMotorIgnition();

	HandleHomingDelay();
}

void UBHP_MissileMovementComponent::TickComponent(float DeltaTime, ELevelTick TickType, FActorComponentTickFunction* ThisTickFunction)
{
	// TRACE_CPUPROFILER_EVENT_SCOPE(STAT_BHP_MissileMovementComponent_TickComponent);
	// TRACE_BOOKMARK(TEXT("BHP_MissileMovementComponent_TickComponent"))

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
		else if (bRocketMotorActive)
		{
			// If the rocket motor is active and homing is not active, apply thrust in the forward direction.
			AddForce(HomingAccelerationMagnitude * UpdatedComponent->GetForwardVector());
		}
	
		HandleProjectileRotation(DeltaTime);
	}
	
	Super::Super::TickComponent(DeltaTime, TickType, ThisTickFunction);

	// Have to check for missed target after tick
	if (bCheckForMissedTarget)
	{
		CheckForMissedTarget();
	}
}

void UBHP_MissileMovementComponent::HandleRocketMotorIgnition()
{
	if (bAutoIgniteRocketMotor && BurnDuration != 0.f)
	{
		if (IgnitionDelay > 0.f)
		{
			if (const UWorld* World = GetWorld())
			{
				World->GetTimerManager().SetTimer(IgnitionDelayTimerHandle, this, &UBHP_MissileMovementComponent::IgniteRocketMotor, IgnitionDelay);
			}
		}
		else
		{
			IgniteRocketMotor();
		}
	}
}

void UBHP_MissileMovementComponent::HandleHomingDelay()
{
	if (!bIsHomingProjectile) return;
	
	if (HomingDelay > 0.f)
	{
		bIsHomingProjectile = false;
		if (const UWorld* World = GetWorld())
		{
			World->GetTimerManager().SetTimer(HomingDelayTimerHandle, this, &UBHP_MissileMovementComponent::HomingDelayElapsed,HomingDelay);
		}
	}
	else
	{		
		StartRampingHomingRotationInterpSpeed();
	}
}

bool UBHP_MissileMovementComponent::IsHomingActive() const
{
	// If bCanHomingChangeSpeed is true, homing will apply thrust, so don't allow homing to be active if the rocket motor is off.
	if (bCanHomingChangeSpeed && !bRocketMotorActive) return false;
	
	return Super::IsHomingActive();
}

void UBHP_MissileMovementComponent::HandleProjectileRotation(const float DeltaTime)
{
	if (bRotationFollowsVelocity) return; // If true, rotation was handled in Super::Super::TickComponent.

	FVector TargetDirection;
	float InterpSpeed;
	
	if (bHomingActiveThisUpdate)
	{
		if (bRocketMotorActive)
		{
			// Simulates maneuvering to vector the thrust in the direction of the homing acceleration.
			TargetDirection = HomingAcceleration.GetSafeNormal();
		}
		else
		{
			// Simulates control surfaces turning the projectile.
			TargetDirection = Velocity.GetSafeNormal();
		}
		
		InterpSpeed = HomingRotationInterpSpeed;
	}
	else
	{
		// Simulates stabilizing fins causing the projectile to turn toward the velocity
		TargetDirection = Velocity.GetSafeNormal();
		InterpSpeed = NonHomingRotationInterpSpeed;
	}

	RotateProjectile(TargetDirection, InterpSpeed, DeltaTime);
}

void UBHP_MissileMovementComponent::StartRampingHomingRotationInterpSpeed()
{
	if (HomingRotationInterpSpeedRampTime <= 0.f)
	{
		HomingRotationInterpSpeed = BaseHomingRotationInterpSpeed;
		return;
	}

	if (const UWorld* World = GetWorld())
	{
		HomingRotationRampTimer = 0.f;
		HomingRotationInterpSpeed = 0.f;
		World->GetTimerManager().SetTimer(HomingRotationRampTimerHandle, this, &UBHP_MissileMovementComponent::RampHomingRotationInterpSpeed, 1.f / 30.f, true);
	}
}

void UBHP_MissileMovementComponent::RampHomingRotationInterpSpeed()
{
	const UWorld* World = GetWorld();
	if (!World) return;
	
	FTimerManager& TimerManager = World->GetTimerManager();
	if (!TimerManager.TimerExists(HomingRotationRampTimerHandle)) return;

	HomingRotationRampTimer += TimerManager.GetTimerElapsed(HomingRotationRampTimerHandle);
	if (HomingRotationRampTimer > HomingRotationInterpSpeedRampTime)
	{
		HomingRotationInterpSpeed = BaseHomingRotationInterpSpeed;
		TimerManager.ClearTimer(HomingRotationRampTimerHandle);
		return;
	}
	
	HomingRotationInterpSpeed = FMath::Lerp(0.f, BaseHomingRotationInterpSpeed, FMath::Clamp(HomingRotationRampTimer / HomingRotationInterpSpeedRampTime, 0.f, 1.f));
}

void UBHP_MissileMovementComponent::RotateProjectile(const  FVector& TargetDirection, const float InterpSpeed, const float DeltaTime)
{
	if (!IsValid(UpdatedComponent)) return;

	FVector NewForwardVector = UpdatedComponent->GetForwardVector();
	if (InterpSpeed > 0.f)
	{
		// Using VInterpTo instead of RInterpTo produces better results.
		NewForwardVector = FMath::VInterpTo(UpdatedComponent->GetForwardVector(), TargetDirection, DeltaTime, InterpSpeed);
	}
	
	// Note, X and Y do not have to be perfectly orthogonal for FRotationMatrix::MakeFromXY to produce a valid rotation. This will get us what we need. 
	FRotator NewRotation = FRotationMatrix::MakeFromXY(NewForwardVector, UpdatedComponent->GetRightVector()).Rotator();
	
	if (bRollProjectile && RollInterpSpeed > 0.f)
	{
		FVector TargetUpVector;
		if (bHomingActiveThisUpdate)
		{
			// Align the up vector with the target direction to simulate banking into turns. 
			TargetUpVector = TargetDirection - TargetDirection.Dot(NewForwardVector) * NewForwardVector;
		}
		else
		{
			// Align the up vector with the world up vector. This will keep wings level with the horizon.
			TargetUpVector = FVector::UpVector;
		}

		// Apply bank angle limit if specified
		if (MaxBankAngleDegrees > 0.f && MaxBankAngleDegrees < 180.f)
		{
			const FVector WorldUp = FVector::UpVector;
			const FVector BankAxis = NewForwardVector;
		
			// Project world up onto the plane perpendicular to forward
			const FVector WorldUpProjected = (WorldUp - WorldUp.Dot(BankAxis) * BankAxis).GetSafeNormal();
		
			// Project target up onto the same plane
			const FVector TargetUpProjected = (TargetUpVector - TargetUpVector.Dot(BankAxis) * BankAxis).GetSafeNormal();
		
			// Now measure the angle between these projected vectors - this is the pure bank angle
			const float CurrentBankAngle = FMath::Acos(FMath::Clamp(WorldUpProjected.Dot(TargetUpProjected), -1.f, 1.f));
			const float MaxBankAngleRad = FMath::DegreesToRadians(MaxBankAngleDegrees);
		
			if (CurrentBankAngle > MaxBankAngleRad)
			{
				// Slerp between the projected vectors to clamp the bank
				const FQuat LimitRotation = FQuat::FindBetweenVectors(WorldUpProjected, TargetUpProjected);
				const FQuat ClampedRotation = FQuat::Slerp(FQuat::Identity, LimitRotation, MaxBankAngleRad / CurrentBankAngle);
  
				TargetUpVector = ClampedRotation.RotateVector(WorldUpProjected).GetSafeNormal();
			}
		}
		
		const FRotator TargetRotation = FRotationMatrix::MakeFromXZ(NewForwardVector, TargetUpVector).Rotator();
		
		NewRotation = FMath::RInterpTo(NewRotation, TargetRotation, DeltaTime, RollInterpSpeed);
	}

	if (bShouldBounce)
	{
		FHitResult HitResult;
		SafeMoveUpdatedComponent(FVector::ZeroVector, NewRotation.Quaternion(), false, HitResult);
	}
	else
	{
		MoveUpdatedComponent(FVector::ZeroVector, NewRotation, false);
	}
}

void UBHP_MissileMovementComponent::IgniteRocketMotor()
{
	if (BurnDuration == 0.f) return;

	bRocketMotorActive = true;

	// Will allow homing to apply the thrust.
	bCanHomingChangeSpeed = true;

	OnRocketMotorActiveChanged.Broadcast(true);

	if (const UWorld* World = GetWorld())
	{
		if (BurnDuration > 0.f)
		{
			World->GetTimerManager().SetTimer(BurnOutTimerHandle, this, &UBHP_MissileMovementComponent::ExtinguishRocketMotor,BurnDuration);
		}
		// else BurnDuration is negative, so the rocket motor will burn indefinitely.
	}
}

void UBHP_MissileMovementComponent::ExtinguishRocketMotor()
{
	bRocketMotorActive = false;

	// Homing should not apply thrust after the rocket motor burns out.
	bCanHomingChangeSpeed = false;

	if (!bAllowHomingAfterMotorBurnout) bIsHomingProjectile = false;

	OnRocketMotorActiveChanged.Broadcast(false);
}

void UBHP_MissileMovementComponent::HomingDelayElapsed()
{
	bIsHomingProjectile = true;
	StartRampingHomingRotationInterpSpeed();
}

void UBHP_MissileMovementComponent::Restart()
{
	const UWorld* World = GetWorld();
	if (!World) return;
	
	if (bRocketMotorActive)
	{
		ExtinguishRocketMotor();
	}

	bIsHomingProjectile = bDefaultIsHomingProjectile;	
	
	FTimerManager& TimerManager = World->GetTimerManager();
	TimerManager.ClearTimer(HomingRotationRampTimerHandle);
	TimerManager.ClearTimer(HomingDelayTimerHandle);
	TimerManager.ClearTimer(IgnitionDelayTimerHandle);
	TimerManager.ClearTimer(BurnOutTimerHandle);
	
	HomingRotationRampTimer = 0.f;
	HomingRotationInterpSpeed = BaseHomingRotationInterpSpeed;
	
	HandleRocketMotorIgnition();

	HandleHomingDelay();
}