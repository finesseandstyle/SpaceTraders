// Copyright 2023 Harlan Cox. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "BHP_FunctionLibrary.h"
#include "GameFramework/ProjectileMovementComponent.h"
#include "BHP_ProjectileMovementComponent.generated.h"

class AActor;

/**
 * Delegate for when the projectile has missed its target. Broadcasts when the distance between the projectile and its target
 * changes from decreasing to increasing if the projectile is within the MissedHomingTargetDistanceThreshold. It will trigger only
 * once each time it is within the threshold. This can be used to trigger a "miss" effect, like exploding a missile at its
 * closest proximity to the target or to notify the target that it dodged the projectile.
 */
DECLARE_DYNAMIC_MULTICAST_DELEGATE(FOnMissedHomingTargetDelegate);

/**
 * BHP_ProjectileMovementComponent is a custom projectile movement component that overrides homing functionality to improve
 * homing performance and enable homing on any arbitrary point in space. It also provides utility functions for estimating
 * impact locations between a projectile and a moving target, and between a moving target and a projectile fired by a moving shooter. 
 */
UCLASS(Blueprintable, meta = (BlueprintSpawnableComponent))

class BETTERHOMINGPROJECTILES_API UBHP_ProjectileMovementComponent : public UProjectileMovementComponent
{
	GENERATED_BODY()
	
public:

	UBHP_ProjectileMovementComponent();
	
	virtual void InitializeComponent() override;
	
	virtual void TickComponent(float DeltaTime, ELevelTick TickType, FActorComponentTickFunction* ThisTickFunction) override;

	virtual bool ShouldUseSubStepping() const override;

	// Returns the point in world space the projectile is homing in on.
	FVector GetHomingPoint() const { return HomingPoint; }

	// Returns the HomingPoint's linear velocity.
	FVector GetHomingPointVelocity() const { return HomingPointVelocity; }

	// Returns the current homing acceleration applied to the projectile.
	FVector GetHomingAcceleration() const { return HomingAcceleration; }

	// Returns the actor the projectile is homing in on, or nullptr if the homing point is an off-actor homing point.
	AActor* GetHomingTargetActor() const { return HomingTargetActor.IsValid() ? HomingTargetActor.Get() : HomingTargetComponent.IsValid() ? HomingTargetComponent->GetOwner() : nullptr; }

	// Returns the line of sight vector from the projectile to the HomingPoint.
	FVector GetLineOfSight() const { return LineOfSightAxis * LineOfSightDistance; }

	// Returns the closing speed between the projectile and the HomingPoint. Positive values indicate the projectile is getting closer to the HomingPoint, negative values indicate it is getting further away.
	float GetClosingSpeed () const { return ClosingSpeed; }
	
	/**
	 * Returns true when bIsHomingProjectile is true and the homing target was set in one of the following ways:
	 * 1. HomingTargetComponent was set. 2. SetHomingPointOnActor was called. 3. SetHomingPointOffActor was called.
	 */
	UFUNCTION(BlueprintCallable, Category = "Homing")
	virtual bool IsHomingActive() const;
	
	/**
	 * Call this to set a specific HomingPoint attached to an actor.
	 * Enter NewHomingPoint in world space. It will be transformed to the target's local space and will move with the actor.
	 * If TargetActor is null, the homing target will be cleared.
	 */
	UFUNCTION(BlueprintCallable, Category = "Homing")
	void SetHomingPointOnActor(AActor* TargetActor, const FVector& NewHomingPoint);

	// Call this to set a HomingPoint in world space, with no dependence on any actor.
	UFUNCTION(BlueprintCallable, Category = "Homing")
	void SetHomingPointOffActor(const FVector& NewHomingPoint);

	UFUNCTION(BlueprintCallable, Category = "Homing")
	void ClearHomingTarget();

	// Adds acceleration to the projectile.
	UFUNCTION(BlueprintCallable, Category = "Homing")
	void AddAcceleration(const FVector& Acceleration);
	
	virtual FVector ComputeAcceleration(const FVector& InVelocity, float DeltaTime) const override;
	
	virtual FVector ComputeMoveDelta(const FVector& InVelocity, float DeltaTime) const override;
	
	/**
	 * When PreventCollisionTunnelingWithTarget is true, this is called to predict whether this projectile's bounding sphere
	 * and the homing target's bounding sphere will collide during the current frame, accounting for the simultaneous motion of the projectile and target.
	 * This helps avoid collision tunneling when a projectile is homing on a fast-moving target with a small hitbox.   
	*/
	virtual bool WillBoundingSpheresCollide(const FVector& InVelocity, float DeltaTime) const;
	
	/**
	 * Estimates the impact location between a projectile and a moving target, assuming constant target velocity, constant
	 * projectile velocity, and no external forces like drag or gravity. Returns whether a valid impact location was found.
	 * If more than one valid solution exists, it returns the impact location which has the shortest time until impact.
	 */
	UE_DEPRECATED(5.3, "Use UBHP_FunctionLibrary::ComputeFiringSolution with the optional parameter, ShooterVelocity, omitted or equal to FVector::ZeroVector. Deprecated in plugin version 2.3.0.")
	UFUNCTION(BlueprintCallable, Category = "Homing", meta = (DeprecatedFunction, DeprecationMessage="Use UBHP_FunctionLibrary::ComputeFiringSolution with the optional parameter, ShooterVelocity, omitted or equal to FVector::ZeroVector. Deprecated in plugin version 2.3.0."))
	static bool EstimateImpactLocation(FVector& OutImpactLocation, const FVector& ProjectileLocation, const float ProjectileSpeed, const FVector& TargetLocation, FVector TargetVelocity);

	/**
	 * Estimates the impact location and time until impact between a projectile and a moving target, assuming constant
	 * target velocity, constant projectile velocity, and no external forces like drag or gravity. Returns whether a valid
	 * impact location was found and the impact location. If more than one valid solution exists, we will return the solution
	 * with the shortest time until impact, unless bUseMinTimeToImpact is false, in which we'll return the solution with
	 * the longest time until impact.
	 */
	UE_DEPRECATED(5.3, "Use UBHP_FunctionLibrary::ComputeFiringSolution with the optional parameter, ShooterVelocity, omitted or equal to FVector::ZeroVector. Deprecated in plugin version 2.3.0.")
	UFUNCTION(BlueprintCallable, Category = "Homing", meta = (DeprecatedFunction, DeprecationMessage="Use UBHP_FunctionLibrary::ComputeFiringSolution with the optional parameter, ShooterVelocity, omitted or equal to FVector::ZeroVector. Deprecated in plugin version 2.3.0."))
	static bool EstimateImpactLocationAndTimeToImpact(FVector& OutImpactLocation, float& OutTimeToImpact, const FVector& ProjectileLocation, const float ProjectileSpeed, const FVector& TargetLocation, FVector TargetVelocity, const bool bPreferMinTimeToImpact = true);

	/**
	 * Estimates the impact location between a moving target and a projectile fired by a moving shooter, assuming the projectile
	 * inherits the shooter's velocity upon firing. Also assumes constant target velocity, constant projectile velocity,
	 * and no external forces like drag or gravity. Returns whether a valid impact location was found and the impact location.
	 * If more than one valid solution exists, we will return the solution with the shortest time until impact
	 */
	UE_DEPRECATED(5.3, "Use UBHP_FunctionLibrary::ComputeFiringSolution instead. Deprecated in plugin version 2.3.0.")
	UFUNCTION(BlueprintCallable, Category = "Homing", meta = (DeprecatedFunction, DeprecationMessage="Use UBHP_FunctionLibrary::ComputeFiringSolution instead. Deprecated in plugin version 2.3.0."))
	static bool EstimateFiringSolution(FVector& OutImpactLocation, const FVector& ShooterLocation, const FVector& ShooterVelocity, const FVector& TargetLocation, FVector TargetVelocity, const float ProjectileSpeed);
	
	/**
	 * Estimates the impact location and time until impact between a moving target and a projectile fired by a moving shooter,
	 * assuming the projectile inherits the shooter's velocity upon firing. Also assumes constant target velocity, constant
	 * projectile velocity, and no external forces like drag or gravity. Returns whether a valid impact location was found,
	 * the impact location, and the time until impact. If more than one valid solution exists, we will return the solution
	 * with the shortest time until impact, unless bUseMinTimeToImpact is false, in which we'll return the solution with
	 * the longest time until impact.
	 */
	UE_DEPRECATED(5.3, "Use UBHP_FunctionLibrary::ComputeFiringSolution instead. Deprecated in plugin version 2.3.0.")
	UFUNCTION(BlueprintCallable, Category = "Homing", meta = (DeprecatedFunction, DeprecationMessage="Use UBHP_FunctionLibrary::ComputeFiringSolution instead. Deprecated in plugin version 2.3.0."))
	static bool EstimateFiringSolutionAndTimeToImpact(FVector& OutImpactLocation, float& OutTimeToImpact, const FVector& ShooterLocation, const FVector& ShooterVelocity, const FVector& TargetLocation, FVector TargetVelocity, const float ProjectileSpeed, const bool bPreferMinTimeToImpact = true);
	
	// Broadcasts when the projectile stops getting closer to the HomingPoint and starts getting further away.
	UPROPERTY(BlueprintAssignable, BlueprintCallable, Category = "Homing")
	FOnMissedHomingTargetDelegate OnMissedHomingTarget;
	
	/**
	 * This value determines how aggressively the projectile will use its available homing acceleration to respond to
	 * the target's maneuvers. Recommended 3.0 - 5.0. Higher values result in more aggressive maneuvering toward target intercept.
	 * Value of 1 results in pure pursuit, in which the projectile does not lead the target, and is not recommended.
	 */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Homing", meta = (ClampMin = "1.0"))
	float ProportionalNavigationGain = 5.f;

	/**
	 * If true, the projectile will speed up or slow down as needed to maximize the chance of hitting the target.
	 * If false, homing acceleration will be applied to change the direction of the projectile's velocity, but not its magnitude.
	 * Note: The BHP_MissileMovementComponent manages bCanHomingChangeSpeed automatically based on the rocket motor state.
	 */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Homing")
	bool bCanHomingChangeSpeed = true;

	/**
	 * If > 0.f, OnMissedHomingTarget will broadcast only if the projectile is within this distance of the HomingPoint.
	 * This helps prevent false positives when the projectile is too far from the target to consider the change of closure rate a miss.
	 * If <= 0.f, OnMissedHomingTarget will broadcast without checking distance to the HomingPoint, possibly triggering far from the target.
	 * OnMissedHomingTarget will trigger only once for each time the projectile is within the MissedHomingTargetDistanceThreshold.
	 */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Homing")
	float MissedHomingTargetDistanceThreshold = 0.f;

	/**
	 * When true, the projectile will inherit the owner's velocity when spawned. This can be useful for projectiles
	 * fired from moving objects. Owner must be set prior to spawning projectile via spawn parameters for this to work.
	 */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Projectile")
	bool bInheritProjectileOwnerVelocity = false;

	// When true and the inherited velocity would cause the projectile to exceed its MaxSpeed, the projectile's MaxSpeed
	// will be increased to the magnitude of (velocity + inherited velocity). When MaxSpeed <= 0, speed is unlimited.
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Projectile", meta = (EditCondition = "bInheritProjectileOwnerVelocity && MaxSpeed > 0.0"))
	bool bInheritedVelocityOverridesMaxSpeed = false;

	/**
	 * When bCanHomingChangeSpeed is true and a TargetImpactTimeSeconds is specified, the projectile will vary its speed as
	 * necessary to attempt to hit the target at the specified game time. The projectile will still obey its speed and homing
	 * acceleration limits, so if it doesn’t have enough speed or acceleration, it may not be able to hit the target at
	 * the desired time. Tuning will be required to ensure the projectile can hit the target at the desired time.
	 * The final time of contact also depends on the size of your projectile and where the homing point is in the target.
	 * The surfaces of the projectile and target actor can make contact before the desired impact time if the projectile
	 * has a significant size and/or if the HomingPoint is deep inside the target actor. You can use SetHomingPointOnActor
	 * to set the homing point on the surface of the target to minimize error. Projectiles with smaller volumes or an
	 * origin at the front can also help minimize the error in impact time.
	*/
	UPROPERTY(BlueprintReadWrite, Category = "Homing")
	float TargetImpactTimeSeconds = -1.f;

	/**
	 * When true, an additional check will be performed to determine if the projectile's bounding sphere is expected to collide with 
	 * the homing target actor's bounding sphere within the current frame. This can prevent collision tunneling that would normally
	 * occur when a projectile is homing on a high speed target with a small hitbox. Such targets move large distances between 
	 * frames, leaving gaps that the projectile can pass through without triggering a hit, even if bSweepCollision == true.
	 * In most situations, enabling this setting is not necessary. It's recommended only when collision tunneling is preventing expected hits 
	 * between projectiles and targets with very high speed/small hitboxes. This ONLY prevents collision tunneling with the homing target actor.
	 * Enabling this does nothing if an off actor homing point is used, because then there is no homing target actor to test against.
	 */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Homing")
	bool bPreventCollisionTunnelingWithHomingTarget = false;

	/**
	 * Whether to avoid collisions on the way to the homing point. Leave this disabled if not needed for better performance.
	 */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Collision Avoidance")
	bool bEnableCollisionAvoidance = false;
	
	/**
	 * Parameters that define how the projectile should avoid collisions.
	 */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Collision Avoidance")
	mutable FCollisionAvoidanceParams CollisionAvoidanceParams;
	
protected:
	
	virtual void UpdateHomingPoint(const float DeltaTime);

	virtual void UpdateProNavState(const float DeltaTime);
	
	virtual FVector ComputeBetterHomingAcceleration(const FVector& InVelocity, float DeltaTime, const FVector& ExternalAcceleration);

	virtual FVector ComputeHomingAccelerationWithCollisionAvoidance(const FVector& InVelocity, float DeltaTime, const FVector& ExternalAcceleration);

	void CheckForMissedTarget() const;
	
	// Returns an acceleration that is perpendicular to the line of sight and the line of sight rotation axis. Used when bCanHomingChangeSpeed == true.
	virtual FVector ComputeTrueProNavAcceleration(const float InClosureRate) const;
	
	// Returns an acceleration that is perpendicular to the velocity. Used when bCanHomingChangeSpeed == false.
	virtual FVector ComputePureProNavAcceleration(const FVector& InVelocity) const;
	
	bool GetTargetBoundingSphere(const AActor* TargetActor, FVector& OutCenter, float& OutRadius) const;
	
	// The point in world space the projectile will home in on.
	UPROPERTY(BlueprintReadOnly, Category = "Homing")
	FVector HomingPoint = FVector::ZeroVector;
	
	// The HomingPoint's linear velocity.
	UPROPERTY(BlueprintReadOnly, Category = "Homing")
	FVector HomingPointVelocity = FVector::ZeroVector;

	UPROPERTY(BlueprintReadOnly, Category = "Homing")
	float LineOfSightDistance = 0.f;
	
	// The unit vector defining the direction from the projectile to the Homing Point.
	UPROPERTY(BlueprintReadOnly, Category = "Homing")
	FVector LineOfSightAxis = FVector::ZeroVector;

	// The line of sight axis of rotation from the previous frame to the current frame.
	UPROPERTY(BlueprintReadOnly, Category = "Homing")
	FVector LineOfSightRotationAxis = FVector::ZeroVector;

	// The angular rate of change of the LineOfSight in radians per second.
	UPROPERTY(BlueprintReadOnly, Category = "Homing")
	float LineOfSightAngularSpeed = 0.f;
	
	// Target actor to home in on. Non-null when the homing target was set via SetHomingPointOnActor. Null otherwise.
	UPROPERTY(BlueprintReadOnly, Category = "Homing")
	TWeakObjectPtr<AActor> HomingTargetActor = nullptr;

	// Defines the HomingPoint position, relative to the HomingTargetActor.
	UPROPERTY(BlueprintReadOnly, Category = "Homing")
	FVector HomingPointLocalOffset = FVector::ZeroVector;

	// If true, SetHomingPointOffActor was called to set the homing point to a specific point in world space, not relative to any actor.
	UPROPERTY(BlueprintReadOnly, Category = "Homing")
	bool bHomingPointOffActor = false;

	// The current homing acceleration applied to the projectile.
	UPROPERTY(BlueprintReadOnly, Category = "Homing")
	mutable FVector HomingAcceleration = FVector::ZeroVector;

	UPROPERTY(BlueprintReadOnly, Category = "Homing")
	float ClosingSpeed = 0.f;
	
	FVector PreviousHomingPoint = FVector::ZeroVector;
	
	FVector PreviousLineOfSight = FVector::ZeroVector;

	bool bHomingActiveThisUpdate = false;

	mutable bool bPreviousClosureRatePositive = false;

	// Prevents OnMissedHomingTarget from broadcasting multiple times when the projectile is within the MissedHomingTargetDistanceThreshold.
	mutable bool bMissedHomingTarget = false;

	bool bTransformLocalOffset = false;
	
	bool bForceHitThisFrame = false;
	
	mutable TWeakObjectPtr<const AActor> CachedBoundsTargetActor;
	mutable FVector CachedTargetLocalExtent = FVector::ZeroVector;
	mutable FVector CachedTargetLocalCenter = FVector::ZeroVector;
};