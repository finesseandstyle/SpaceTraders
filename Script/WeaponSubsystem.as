struct FPendingVfxProjectile
{
    UNiagaraComponent NiagaraComponent;
    AGameObject TargetObject;
    
    FVector CurrentPosition;
    FVector OffsetPosition; //Maybe change this to the ship's size so that we can randomize our shots
    
    // Impact VFX to spawn on hit
    UNiagaraSystem ImpactVfx;
    //TODO: vfx id system -> get vfx from id from a DT or smth -> spawn impact vfx, no need to track it here
}

const float DefaultProjectileSpeed = 15000.0;

class UWeaponSubsystem : UScriptWorldSubsystem
{
    private TArray<FPendingVfxProjectile> ActiveShots;

    UFUNCTION()
    void FireProjectile(
        UNiagaraSystem TracerVfx, 
        UNiagaraSystem ImpactVfx,
        FVector MuzzleLocation, 
        AGameObject GameObject,
        FVector OffsetPosition)
    {
        if (GameObject == nullptr || TracerVfx == nullptr)
            return;

        FPendingVfxProjectile NewShot;
        NewShot.CurrentPosition = MuzzleLocation;
        NewShot.TargetObject = GameObject;
        NewShot.ImpactVfx = ImpactVfx;
        NewShot.OffsetPosition = OffsetPosition; 

        FVector InitialTargetPos = GameObject.ActorLocation;
        FVector InitialDir = (InitialTargetPos - MuzzleLocation).GetSafeNormal();
        FRotator InitialRotation = InitialDir.IsNearlyZero() ? FRotator::ZeroRotator : InitialDir.Rotation();

        NewShot.NiagaraComponent = Niagara::SpawnSystemAtLocation(
            TracerVfx,
            MuzzleLocation,
            InitialRotation,
            FVector(1.0),
            true,
            true
        );
        
        if (NewShot.NiagaraComponent != nullptr)
        {
            //scaling particle lifetime with projectile speed
            NewShot.NiagaraComponent.SetFloatParameter(n"Lifetime", 200/DefaultProjectileSpeed);
            
            // Advance simulation 1 step to prevent 1-frame spawn delay at muzzle
            NewShot.NiagaraComponent.AdvanceSimulation(1, 0.01);
        }

        ActiveShots.Add(NewShot);
    }

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaTime)
    {
        //Projectiles
        for (int32 i = ActiveShots.Num() - 1; i >= 0; --i)
        {
            FPendingVfxProjectile& Shot = ActiveShots[i];

            const float FullStep = DefaultProjectileSpeed * DeltaTime;
            const FVector TargetLocation = Shot.TargetObject.ActorLocation + Shot.OffsetPosition;

            // Compute vector and distance to target BEFORE updating position
            const FVector ToTarget = TargetLocation - Shot.CurrentPosition;
            const float DistToTarget = ToTarget.Size();

            // Check if step overshoots or reaches target this frame
            if (DistToTarget <= FullStep || DistToTarget <= 0.001)
            {
                // Impact target
                FRotator ImpactRotation = ToTarget.IsNearlyZero() ? FRotator::ZeroRotator : ToTarget.Rotation();

                if (Shot.NiagaraComponent != nullptr)
                {
                    Shot.NiagaraComponent.SetWorldLocationAndRotation(TargetLocation, ImpactRotation);
                    Shot.NiagaraComponent.Deactivate();
                }

                if (Shot.ImpactVfx != nullptr)
                {
                    Niagara::SpawnSystemAttached(
                        Shot.ImpactVfx,
                        Shot.TargetObject.RootComponent,
                        NAME_None,
                        TargetLocation,
                        ImpactRotation,
                        EAttachLocation::KeepWorldPosition,
                        true,
                        true
                    );
                }

                ActiveShots.RemoveAtSwap(i);
            }
            else
            {
                // Step towards target at constant speed
                FVector Direction = ToTarget / DistToTarget; // Normalized direction vector
                Shot.CurrentPosition = Shot.CurrentPosition + (Direction * FullStep);
                FRotator CurrentRotation = Direction.Rotation();

                if (Shot.NiagaraComponent != nullptr)
                {
                    Shot.NiagaraComponent.SetWorldLocationAndRotation(Shot.CurrentPosition, CurrentRotation);
                }
            }
        }

        //Beams
        
    }
}