// Copyright 2023 Harlan Cox. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "Kismet/BlueprintFunctionLibrary.h"
#include "Engine/EngineTypes.h"
#include "BHP_FunctionLibrary.generated.h"

DECLARE_LOG_CATEGORY_EXTERN(BHP_Plugin, Log, All);

struct FCollisionShape;

/**
 * FiringSolution is the result of ComputeFiringSolution. It contains whether a valid solution was found,
 * the impact location where the projectile should hit the target, and the time to impact in seconds.
 * Check if bValidSolution is true before using the other properties.
 */
USTRUCT(BlueprintType, Category = "Better Homing Projectiles")
struct FFiringSolution
{
	GENERATED_BODY()

	/**
	 * If false, a valid solution was not found, which can happen if projectile is fired at a speed that is too low to reach the target,
	 * given the initial locations and target velocity. Projectile speed should be greater than the target's speed to maximize the chances of a valid solution. 
	 */
	UPROPERTY(BlueprintReadOnly, Category = "Better Homing Projectiles")
	bool bValidSolution = false;

	/**
	 * Where the projectile should impact the target, in world space, if the target and projectile maintain their current velocities.
	 */
	UPROPERTY(BlueprintReadOnly, Category = "Better Homing Projectiles")
	FVector ImpactLocation = FVector::ZeroVector;

	/**
	 * The time in seconds until the projectile impacts the target, if the target and projectile maintain their current velocities.
	 * If bValidSolution is false, this will be -1.f.
	 */
	UPROPERTY(BlueprintReadOnly, Category = "Better Homing Projectiles")
	float TimeToImpactSeconds = -1.f;
};

/**
 * A ProNavState defines the state of a pursuer using Proportional Navigation (ProNav) to home in on a target.
 * It includes the variables needed to compute the homing acceleration using proportional navigation.
 * To use this struct for non-projectile actors, create an instance of it for your pursuer,
 * and call UpdateProNavState on tick with the pursuer and target locations and velocities.
 * Then call your preferred compute acceleration function to get the homing acceleration needed for your pursuer.
 */
USTRUCT(BlueprintType, Category = "Better Homing Projectiles")
struct FProNavState
{
	GENERATED_BODY()

	// Proportional Navigation Gain is a constant that determines how aggressively the pursuer will adjust its acceleration to home in on the target.
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Better Homing Projectiles")
	float Gain = 5.f;

	// The line of sight rate. How fast the direction to the target is rotating, relative to the pursuer.
	UPROPERTY(BlueprintReadWrite, Category = "Better Homing Projectiles")
	float LineOfSightAngularSpeed = 0.f;

	// The unit vector defining the direction from the pursuer to the target.
	UPROPERTY(BlueprintReadWrite, Category = "Better Homing Projectiles")
	FVector LineOfSightDirection = FVector::ZeroVector;

	UPROPERTY(BlueprintReadWrite, Category = "Better Homing Projectiles")
	float LineOfSightDistance = 0.f;

	// The unit vector defining the axis of rotation from the previous line of sight direction to the current line of sight direction.
	UPROPERTY(BlueprintReadWrite, Category = "Better Homing Projectiles")
	FVector LineOfSightRotationAxis = FVector::ZeroVector;

	// The previous line of sight, used to compute the line of sight rate.
	UPROPERTY(BlueprintReadWrite, Category = "Better Homing Projectiles")
	FVector PreviousLineOfSight = FVector::ZeroVector;

	// The closing speed is the rate at which the pursuer is getting closer to the target. Will be negative if the pursuer is getting further away.
	UPROPERTY(BlueprintReadWrite, Category = "Better Homing Projectiles")
	float ClosingSpeed = 0.f;
};

/**
 * A HomingKinematicState defines the kinematic state (locations and velocities) of a pursuer and its target.
 */
USTRUCT(BlueprintType, Category = "Better Homing Projectiles")
struct FHomingKinematicState
{
	GENERATED_BODY()

	UPROPERTY(BlueprintReadWrite, Category = "Better Homing Projectiles")
	FVector PursuerLocation = FVector::ZeroVector;

	UPROPERTY(BlueprintReadWrite, Category = "Better Homing Projectiles")
	FVector PursuerVelocity = FVector::ZeroVector;

	UPROPERTY(BlueprintReadWrite, Category = "Better Homing Projectiles")
	FVector TargetsLocation = FVector::ZeroVector;

	UPROPERTY(BlueprintReadWrite, Category = "Better Homing Projectiles")
	FVector TargetsVelocity = FVector::ZeroVector;
	
};

USTRUCT(BlueprintType)
struct FHomingWithCollisionAvoidanceResult
{
	GENERATED_BODY()
	
	UPROPERTY(BlueprintReadWrite, Category = "Collision Avoidance")
	FVector HomingAcceleration = FVector::ZeroVector;

};

/**
 * Parameters which define how collision avoidance behaves.
 */
USTRUCT(BlueprintType)
struct FCollisionAvoidanceParams
{
	GENERATED_BODY()

	/*
	 * Multiple of the CollisionComponent's sphere bounds to use when checking for collisions with sphere traces.
	 * Increasing this number helps increase the clearance around obstacles. 
	 */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Collision Avoidance", meta = (ClampMin = "1.0"))
	float SphereRadiusMultiplier = 2.f;

	/**
	 * Actors to ignore when checking for collisions.
	 */
	UPROPERTY(BlueprintReadWrite, Category = "Collision Avoidance")
	TArray<AActor*> IgnoredActors;

	/**
	 * Determines the distance along the velocity vector we trace to look for collisions at a given speed. 
	 * The trace distance will be the TraceDistanceFactor * stopping distance at the current speed.
	 * This is also the distance we will use to look for clear space around us when an obstacle is found in our path.
	 * The stopping distance, and therefore the trace distance, is proportional to the square of the speed.
	 * Recommended values are between 1.5 and 3.
	 */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Collision Avoidance")
	float TraceDistanceFactor = 2.f;

	/**
	 * The minimum distance that a sphere trace will be performed along the actor's vector to look for obstacles.
	 * A non-zero value can help slow actors avoid semi-enclosed spaces where they would get stuck.
	 * For example, imagine an actor flying toward an open shipping container. If it is slow enough, the trace won't be
	 * long enough to reach the back of the container, so it will fly in. Once inside, the homing force / anti-collision forces
	 * will be in conflict, causing the actor to get stuck. BHP does NOT include pathfinding, so these situations can only
	 * be mitigated (not always avoided) by a MinTraceDistance. If your levels include mostly convex obstacles, and/or your
	 * collision-avoiding actors don't often get stuck, then you can leave this at zero.
	 */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Collision Avoidance")
	float MinTraceDistance = 0.f;

	/**
	 * The minimum distance to sphere trace along the velocity vector to look for collisions. Can be left at zero for most cases.
	 * You can use this if you need your projectiles to avoid concave obstacles where they otherwise might get stuck. 
	 */
	UPROPERTY(EditAnywhere, BlueprintReadOnly, Category = "Collision Avoidance")
	float CollisionAvoidanceTraceAngle = 30.f;
	
	/**
	 * This is the turn angle at which the actor will devote all of its acceleration to braking to avoid a collision.
	 * The turn angle is the angle between the actor's velocity and the direction to a clear path. Below this turn angle,
	 * the fraction of available acceleration devoted to braking is the turn angle/FullBrakeTurnAngleDegrees, and all
	 * remaining acceleration is used to turn away from the obstacle. Range is 0 to 180 degrees. 
	 * Recommended value is between 30 and 60 degrees.
	 */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Collision Avoidance", meta = (ClampMin = "0.0", ClampMax = "180.0"))
	float FullBrakeTurnAngleDegrees = 45.f;

	/**
	 * The points on a unit sphere around the projectile that will be used to trace for a clear path when an unwanted
	 * collision is detected. Use GenerateCollisionAvoidanceTraceDirections to generate these points. If you pass
	 * CollisionAvoidanceParams to Compute_BHP_HomingAccelerationWithCollisionAvoidance with no CollisionAvoidanceTracePoints,
	 * they will be generated for you.
	 */
	UPROPERTY(BlueprintReadWrite, Category = "Collision Avoidance")
	TArray<FVector> CollisionAvoidanceTracePoints;

	/**
	 * The collision channel used to detect obstacles in the projectile's path when bEnableCollisionAvoidance is true.
	 * This should be set to a channel that is blocked by the objects you want the actor to avoid.
	 * Default is ECC_Visibility.
	 */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Collision Avoidance")
	TEnumAsByte<ECollisionChannel> CollisionAvoidanceTraceChannel = ECollisionChannel::ECC_Visibility;
	
	/**
	* Returns true if collision avoidance was used to calculate the acceleration by Compute_BHP_HomingAccelerationWithCollisionAvoidance.
	*/
	UPROPERTY(BlueprintReadOnly, Category = "Collision Avoidance")
	bool bAvoidingCollision = false;
};

/**
 * This library provides homing utility functions that can be used in any class. Create a ProNavState struct for your
 * pursuer and call UpdateProNavState on tick to update the state with the pursuer and target locations and velocities.
 * Then call any one of the desired compute acceleration functions on tick to get the homing acceleration needed for your pursuer.
 * The goal of Proportional Navigation (ProNav) is to adjust the pursuer's acceleration so that it reduces the line of sight rate,
 * which is the rate at which the direction to the target changes relative to the pursuer.
 * See https://en.wikipedia.org/wiki/Proportional_navigation for more information on ProNav.
 */
UCLASS()
class BETTERHOMINGPROJECTILES_API UBHP_FunctionLibrary : public UBlueprintFunctionLibrary
{
	GENERATED_BODY()

public:
	/**
	 * Updates the ProNavState given new pursuer and target locations and velocities.
	 * Recommended to call on tick. 
	 */
	UFUNCTION(BlueprintCallable, Category = "Better Homing Projectiles")
	static void UpdateProNavState(UPARAM(ref) FProNavState& ProNavState, const FHomingKinematicState& HomingKinematicState, const float DeltaTime);
	
	/**
	 * Returns an unclamped acceleration which will reduce the line of sight rate. The acceleration is perpendicular to the line of sight and
	 * the line of sight rotation axis. Recommended to clamp the result to a maximum. Can change the velocity magnitude and direction,
	 * but doesn't apply thrust. When used alone, it can bleed off the pursuer's speed, so it is best used in conjunction with a thrust acceleration.
	 * Recommend using Compute_BHP_HomingAcceleration if you want a complete homing acceleration that includes thrust.
	 * Call on tick after updating the ProNavState.
	*/
	UFUNCTION(BlueprintCallable, Category = "Better Homing Projectiles")
	static FVector ComputeTrueProNavAcceleration(const FProNavState& ProNavState);

	/**
	 * Returns an unclamped acceleration which will reduce the line of sight rate. The acceleration is perpendicular to the velocity,
	 * so that only the velocity direction is changed, not its magnitude. Recommended to clamp the result to a maximum.
	 * Call on tick after updating the ProNavState.
	*/
	UFUNCTION(BlueprintCallable, Category = "Better Homing Projectiles")
	static FVector ComputePureProNavAcceleration(const FProNavState& ProNavState, const FVector& PursuerVelocity);
	
	/**
	 * Custom homing acceleration function that computes the acceleration needed to home in on a target. It uses TrueProNav
	 * if bCanHomingChangeSpeed = true and PureProNav if bCanHomingChangeSpeed = false. If bCanHomingChangeSpeed = true,
	 * acceleration not used to establish a collision course is used to thrust toward the target. It attempts to compensate for external
	 * acceleration, which is useful for preventing the projectile from sagging due to gravity or being pushed off course by external forces.
	 * If a valid TargetImpactTimeSeconds is provided, it will attempt to compute the acceleration needed to reach the target at that world time.
	 * Call on tick after updating the ProNavState.
	 */
	UFUNCTION(BlueprintCallable, Category = "Better Homing Projectiles")
	static FVector Compute_BHP_HomingAcceleration(
		const UObject* WorldContextObject,
		const FProNavState& ProNavState,
		const FHomingKinematicState& HomingKinematicState,
		const float MaxAccelerationMagnitude,
		const float MaxSpeed,
		const float DeltaTime,
		const bool bCanHomingChangeSpeed = true,
		const FVector& ExternalAcceleration = FVector::ZeroVector,
		const float TargetImpactTimeSeconds = -1.f);

	/**
	 * Computes a homing acceleration that avoids collisions with obstacles in the flying actor's path. If no collision is detected,
	 * it will compute the homing acceleration using Compute_BHP_HomingAcceleration. The sphere bounds of the CollisionComponent
	 * will be used to determine the size of the sphere trace used to detect collisions. Pass in a unit vector PlaneConstraintNormal
	 * to constrain the acceleration to a plane. If the CollisionTracePoints in the CollisionAvoidanceParams is empty,
	 * they will be generated for you and returned in the CollisionAvoidanceParams for use in future iterations.
	 */
	UFUNCTION(BlueprintCallable, Category = "Better Homing Projectiles")
	static FVector Compute_BHP_HomingAccelerationWithCollisionAvoidance(
		UPARAM(ref) FCollisionAvoidanceParams& CollisionAvoidanceParams,
		const USceneComponent* CollisionComponent,
		const FProNavState& ProNavState,
		const FHomingKinematicState& HomingKinematicState,
		const float MaxAccelerationMagnitude,
		const float MaxSpeed,
		const float DeltaTime,
		const bool bCanHomingChangeSpeed = true,
		const FVector& ExternalAcceleration = FVector::ZeroVector,
		const float TargetImpactTimeSeconds = -1.f,
		const FVector PlaneConstraintNormal = FVector::ZeroVector);

	/**
	 * Computes a firing solution for a projectile to hit a moving target. Assumes constant target velocity, constant projectile speed,
	 * and no external forces like drag or gravity. A solution may not be found if the projectile speed is too low to reach the target,
	 * given the initial locations and target velocity. Projectile speed should be greater than the target's speed to maximize the chances of a valid solution.
	 * @param ShooterLocation Shooter's location in world space (the projectile's initial location).
	 * @param TargetLocation Target's location in world space.
	 * @param TargetVelocity Target's velocity in world space.
	 * @param ProjectileSpeed The speed of the projectile in world space. Must be positive. If using with variable speed projectiles, recommend using max speed.
	 * @param ShooterVelocity Shooter's velocity in world space. If omitted, defaults to FVector::ZeroVector.
	 * @param bPreferMinTimeToImpact Whether to prefer the solution with the minimum time to impact. If false, it will return the solution with the maximum time to impact.
	 * @return FiringSolutionResult containing whether a solution was found, and if so, the predicted impact location and time to impact.
	 */
	UFUNCTION(BlueprintCallable, Category = "Better Homing Projectiles")
	static FFiringSolution ComputeFiringSolution(
		const FVector& ShooterLocation, 
		const FVector& TargetLocation, 
		FVector TargetVelocity, 
		const float ProjectileSpeed, 
		const FVector ShooterVelocity = FVector::ZeroVector, 
		const bool bPreferMinTimeToImpact = true);

	/**
	 * Generates a set of points on a UV sphere or on a circle in the XY plane used as the directions for collision avoidance
	 * traces to find a clear path around obstacles. If not constrained to a plane, 8 points will be generated at each angle
	 * increment, from 0 to 180 degrees. If constrained to a plane, 2 points will be generated at each angle increment.
	 * @param AngleIncrementDeg The angle in degrees used to generate points on a UV sphere. The smaller the value, the more points will be generated.
	 * @param bConstrainToPlane If true, the points will be constrained to a plane defined by the XY axes. If false, the points will be on a unit sphere.
	 * @return Points that can be used to trace for a clear path around obstacles. Grouped by the angle increment specified.
	 */
	UFUNCTION(BlueprintCallable, Category = "Better Homing Projectiles")
	static TArray<FVector> GenerateCollisionAvoidanceTraceDirections(const float AngleIncrementDeg, const bool bConstrainToPlane = false);

	/** 
	 * Predicts whether the bounding spheres of two actors will collide within the given DeltaTime,
	 * accounting for the simultaneous motion of both actors (assuming each continues at its current velocity).
	 * Each actor is approximated as a sphere whose radius and center are derived from its world-space
	 * axis-aligned bounding box (via GetActorBounds).
	 *
	 * @note Because the bounding box is world-space axis-aligned, the derived radius changes as the actor
	 *       rotates — a non-spherical actor's box diagonal grows when it turns off-axis. If you need a stable,
	 *       rotation-independent radius, compute the box once in local space with
	 *       CalculateComponentsBoundingBoxInLocalSpace, take its extent length as the radius, and call
	 *       PredictCollisionBetweenSpheres directly with your own cached radii and centers.
	 *
	 * @param Actor_A    First actor, approximated by its bounding sphere. Must not be null.
	 * @param Actor_B    Second actor, approximated by its bounding sphere. Must not be null.
	 * @param DeltaTime  Look-ahead window over which to predict the collision, in seconds.
	 * @param OutHitTime Predicted time of impact as a fraction of DeltaTime, in [0, 1] (e.g. 0.5 = halfway
	 *                   through the window). Set to -1 when no collision is predicted.
	 * @param Sphere_A_OutHitLocation  Center of Sphere A at the predicted impact time. Only valid when the function returns true.
	 * @param Sphere_B_OutHitLocation  Center of Sphere B at the predicted impact time. Only valid when the function returns true.
	 * @param OutImpactPoint           Point on the line between the sphere centers, on Sphere A's surface, at impact. Only valid when the function returns true.
	 * @return true if a collision is predicted within the window; false otherwise (including null actors or a zero radius on either actor).
	 */
	UFUNCTION(BlueprintCallable, Category = "Better Homing Projectiles")
	static bool PredictActorBoundingSphereCollision(
		const AActor* Actor_A, 
		const AActor* Actor_B, 
		const float DeltaTime, 
		float& OutHitTime, 
		FVector& Sphere_A_OutHitLocation, 
		FVector& Sphere_B_OutHitLocation,
		FVector& OutImpactPoint);
	
	/**
	 * Predicts whether two spheres will collide as they each travel in a straight line from their start to
	 * their end location over a single time step, accounting for the simultaneous motion of both, and reports
	 * the time and locations of the predicted impact.
	 *
	 * If you only need a yes/no answer, prefer WillSpheresCollide: it is cheaper, solving for the time of
	 * closest approach directly rather than the full quadratic, and skips computing the hit time, hit
	 * locations, and impact point this function provides.
	 *
	 * Takes precomputed start/end endpoints rather than velocities, so the caller controls how each sphere's
	 * displacement is computed (e.g. a movement component's swept delta, or simply velocity * DeltaTime).
	 *
	 * @param Sphere_A_Start   Center of Sphere A at the start of the step, in world space.
	 * @param Sphere_A_End     Center of Sphere A at the end of the step, in world space.
	 * @param Sphere_A_Radius  Radius of Sphere A. Must be greater than zero.
	 * @param Sphere_B_Start   Center of Sphere B at the start of the step, in world space.
	 * @param Sphere_B_End     Center of Sphere B at the end of the step, in world space.
	 * @param Sphere_B_Radius  Radius of Sphere B. Must be greater than zero.
	 * @param OutHitTime       Predicted time of impact as a fraction of the step, in [0, 1] (e.g. 0.5 = halfway
	 *                         between start and end). Set to -1 when no collision is predicted.
	 * @param Sphere_A_OutHitLocation  Center of Sphere A at the predicted impact time. Only valid when the function returns true.
	 * @param Sphere_B_OutHitLocation  Center of Sphere B at the predicted impact time. Only valid when the function returns true.
	 * @param OutImpactPoint           Point on the line between the sphere centers, on Sphere A's surface, at impact. Only valid when the function returns true.
	 * @return true if a collision is predicted within the step; false otherwise (including a zero or negative radius on either sphere).
	 */
	UFUNCTION(BlueprintCallable, Category = "Better Homing Projectiles")
	static bool PredictCollisionBetweenSpheres(
		const FVector& Sphere_A_Start, 
		const FVector& Sphere_A_End, 
		const float Sphere_A_Radius, 
		const FVector& Sphere_B_Start, 
		const FVector& Sphere_B_End, 
		const float Sphere_B_Radius, 
		float& OutHitTime, 
		FVector& Sphere_A_OutHitLocation, 
		FVector& Sphere_B_OutHitLocation,
		FVector& OutImpactPoint);
	
	/**
	 * Predicts whether two spheres will collide as they each travel in a straight line from their start to
	 * their end location over a single time step, accounting for the simultaneous motion of both.
	 *
	 * Returns only a yes/no result, and is cheaper than PredictCollisionBetweenSpheres. 
	 * Prefer this function whenever you only need to know whether a collision occurs; 
	 * Use PredictCollisionBetweenSpheres only when you actually need hit details.
	 *
	 * @param Sphere_A_Start   Center of Sphere A at the start of the step, in world space.
	 * @param Sphere_A_End     Center of Sphere A at the end of the step, in world space.
	 * @param Sphere_A_Radius  Radius of Sphere A. Must be greater than zero.
	 * @param Sphere_B_Start   Center of Sphere B at the start of the step, in world space.
	 * @param Sphere_B_End     Center of Sphere B at the end of the step, in world space.
	 * @param Sphere_B_Radius  Radius of Sphere B. Must be greater than zero.
	 * @return true if the spheres overlap at any point during the step (including an initial overlap at the
	 *         start); false otherwise, or if either radius is not greater than zero.
	 */
	UFUNCTION(BlueprintCallable, Category = "Better Homing Projectiles")
	static bool WillSpheresCollide(
		const FVector& Sphere_A_Start,
		const FVector& Sphere_A_End,
		const float Sphere_A_Radius, 
		const FVector& Sphere_B_Start,
		const FVector& Sphere_B_End,
		const float Sphere_B_Radius);
};
