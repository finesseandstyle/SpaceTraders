// Copyright 2023 Harlan Cox. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "BHP_ProjectileMovementComponent.h"
#include "BHP_MissileMovementComponent.generated.h"

DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FRocketMotorActiveSignature, bool, bRocketMotorActive);

/**
 * BHP_MissileMovementComponent adds functionality on top of the BHP_ProjectileMovementComponent which can be used to build
 * missiles, rockets, and bombs. 
 */
UCLASS(Blueprintable, meta = (BlueprintSpawnableComponent))
class BETTERHOMINGPROJECTILES_API UBHP_MissileMovementComponent : public UBHP_ProjectileMovementComponent
{
	GENERATED_BODY()

	public:

	virtual void TickComponent(float DeltaTime, ELevelTick TickType, FActorComponentTickFunction* ThisTickFunction) override;

	virtual bool IsHomingActive() const override;

	/**
	 * Ignites the rocket motor. Will set bCanHomingChangeSpeed to true to allow homing to control thrust when homing is active.
	 * When homing is inactive, the rocket motor will apply thrust equal to the HomingAccelerationMagnitude in the direction
	 * of the projectile's forward vector.
	 */
	UFUNCTION(BlueprintCallable, Category = "Rocket Motor")
	virtual void IgniteRocketMotor();

	/**
	 * Extinguishes the rocket motor. Will set bCanHomingChangeSpeed to false to prevent homing from adding thrust.
	 * When homing is inactive, the projectile will no longer add thrust in its forward direction.
	 * If bAllowHomingAfterMotorBurnout is true, homing will continue by turning the velocity vector.
	 */
	UFUNCTION(BlueprintCallable, Category = "Rocket Motor")
	virtual void ExtinguishRocketMotor();

	bool GetRocketMotorActive() const { return bRocketMotorActive; }

	// Will restart the MissileMovementComponent as if it was just spawned. Useful when re-activating a missile from a projectile pool.  
	virtual void Restart();

	// Broadcasts when the rocket motor is ignited (true) or extinguished (false).
	UPROPERTY(BlueprintAssignable, Category = "Rocket Motor")
	FRocketMotorActiveSignature OnRocketMotorActiveChanged;

	/**
	 * When true, the rocket motor will ignite automatically after the IgnitionDelay when the projectile is spawned.
	 * When false, the rocket motor must be ignited manually by calling IgniteRocketMotor.
	 */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Rocket Motor")
	bool bAutoIgniteRocketMotor = true;

	// Time after the projectile is spawned before the rocket motor ignites. When <= 0, the rocket motor ignites immediately.
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Rocket Motor", meta = (EditCondition = "bAutoIgniteRocketMotor", ClampMin = 0.f))
	float IgnitionDelay = 0.f;

	// Time the rocket motor burns before extinguishing. When == 0, there is no rocket motor. When < 0, the rocket motor burns indefinitely.
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Rocket Motor")
	float BurnDuration = -1.f;

	/**
	 * If bRotationFollowsVelocity is true, this value is ignored and the projectile will snap its rotation to match its velocity vector.
	 * When RotationFollowsVelocity is false, the projectile will rotate toward the homing acceleration vector at this rate.
	 * Simulates the projectile maneuvering to aim its thrust vector when homing. The projectile rotation is cosmetic
	 * and has no impact on the homing acceleration. Recommended to be greater than NonHomingInterpSpeed because it
	 * represents actively controlled rotation, while NonHomingInterpSpeed represents passive rotation. Values that are too high
	 * can result in sporadic rotation behavior, because the homing acceleration vector can change rapidly. 0.0 results in no rotation.
	 */
    UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Projectile", meta = (EditCondition = "!bRotationFollowsVelocity", ClampMin = 0.f))
    float HomingRotationInterpSpeed = 5.f;

	/**
	 * If > 0.f and RotationFollowsVelocity is false, the homing rotation rate will gradually increase from 0 to HomingInterpSpeed
	 * over this time period after the HomingDelay has elapsed. This can help avoid a sudden jerk in rotation upon homing
	 * activation when the HomingRotationInterpSpeed is high.
	 */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Projectile", meta = (EditCondition = "!bRotationFollowsVelocity", ClampMin = 0.f))
	float HomingRotationInterpSpeedRampTime = 0.f;

	/**
	 * If bRotationFollowsVelocity is true, this value is ignored and the projectile will snap its rotation to match its velocity vector.
	 * When RotationFollowsVelocity is false and homing is not active, the projectile will rotate toward its velocity at this rate.
	 * Simulates stabilizing fins that cause the projectile to turn toward its velocity vector. Recommended to be less than
	 * HomingInterpSpeed because it represents passive rotation, while HomingInterpSpeed represents actively controlled rotation.
	 * 0.0 results in no rotation.
	 */
    UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Projectile", meta = (EditCondition = "!bRotationFollowsVelocity", ClampMin = 0.f))
	float NonHomingRotationInterpSpeed = 3.f;
	
	/**
	 * When false, the projectile will ignore roll. False is recommended for radially-symmetric projectiles.
	 * When true and homing is active, the projectile will roll to simulate banking into turns.
	 * When true and homing is not active, the projectile will roll upright to wings (right vector) level with the horizon.
	 * Use true for projectiles with wings, like cruise missiles or drones, that should look like they bank into their turns. 
	 */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Projectile")
	bool bRollProjectile = false;

	/**
	 * Roll interpolation speed used when bRollProjectile is true. Higher values result in faster roll. 0 results in no roll.
	 */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Projectile", meta = (EditCondition = "bRollProjectile", ClampMin = 0.f))
	float RollInterpSpeed = 2.f;

	/**
	 * If > 0 and < 180, this limits the maximum bank angle in degrees relative to the horizon when bRollProjectile is true.
	 * When <= 0 or >= 180, no bank angle limit is applied, and the projectile can roll to any angle to try to align with the homing acceleration vector.
	 * Use a bank angle limit <= 90 degrees to prevent the projectile from rolling inverted.
	 */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Projectile", meta = (EditCondition = "bRollProjectile", ClampMin = 0.f, ClampMax = 180.f))
	float MaxBankAngleDegrees = 180.f;	
	
	/**
	 * If > 0, homing will not be available until this delay has passed. When <= 0, homing is available immediately upon BeginPlay.
	 * Useful to help create distance between the projectile and the shooter before the projectile starts maneuvering.
	 */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Homing", meta = (ClampMin = 0.f))
	float HomingDelay = 0.f;

	/**
	 * When true, the projectile will set bCanHomingChangeSpeed to false and continue homing in on the target after the rocket motor burns out.
	 * When false, the projectile will stop homing after the rocket motor burns out.
	 */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Homing")
	bool bAllowHomingAfterMotorBurnout = false;
	
protected:
	
	virtual void BeginPlay() override;

	virtual void HandleRocketMotorIgnition();

	virtual void HandleHomingDelay();

	virtual void HomingDelayElapsed();
	
	virtual void HandleProjectileRotation(const float DeltaTime);

	virtual void RampHomingRotationInterpSpeed();

	// Target direction should be a unit vector. InterpSpeed should be >= 0.
	virtual void RotateProjectile(const FVector& TargetDirection, const float InterpSpeed, const float DeltaTime);

	void StartRampingHomingRotationInterpSpeed();
	
	float HomingRotationRampTimer = 0.f;
	
	float BaseHomingRotationInterpSpeed = 0.f;

	bool bDefaultIsHomingProjectile = true;

	FTimerHandle HomingRotationRampTimerHandle;
	FTimerHandle HomingDelayTimerHandle;
	FTimerHandle IgnitionDelayTimerHandle;
	FTimerHandle BurnOutTimerHandle;

private:

	UPROPERTY(BlueprintReadOnly, Category = "Rocket Motor", meta = (AllowPrivateAccess = "true"))
	bool bRocketMotorActive = false;
};

