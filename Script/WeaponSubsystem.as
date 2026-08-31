struct FPendingVfxProjectile
{
    UNiagaraComponent NiagaraComponent;
    USceneComponent TargetRoot;
    
    FVector CurrentPosition;
    FVector OffsetPosition; //Maybe change this to the ship's size so that we can randomize our shots
    
    // Impact VFX to spawn on hit
    UNiagaraSystem ImpactVfx;
    //TODO: vfx id system -> get vfx from id from a DT or smth -> spawn impact vfx, no need to track it here
}

struct FPendingVfxBeam
{
    UNiagaraComponent LaserTemplateNS;
    UNiagaraComponent ImpactTemplateNS;
    USceneComponent SourceRoot;
    USceneComponent TargetRoot;

    FVector OffsetPosition;

    float Duration = 0.0;
    float ElapsedTime = 0.0;
}

const float DefaultProjectileSpeed = 15000.0;
const float DefaultBeamSpeed = 35000.0;
const float BeamSustainTime = 0.25;
const int MaxFiringRounds = 3;

enum EWeaponFiringType 
{
    //Instant point to point
    Projectile, 
    Beam,
    Cone,
    Shockwave,
    //Spawns a AGameObject
    Ballistic
}

struct FWeaponShot
{
    UShipStateComponent Attacker;
    UShipStateComponent Target;
    USceneComponent SourceRoot, TargetRoot; //Both Required for beams, Target required for ballistic firing
    EWeaponFiringType FiringType; //Instant -> Attacker.FireWeaponAt; Ballistic->Projectile->Attacker.FireProjectileWeapon & Spawn Homing Projectile
    float Initiative;
    float FinalFireTime;
    EWeaponState WeaponState;

    bool opCmp(const FWeaponShot& Other) const
    {
        return FinalFireTime < Other.FinalFireTime;
    }

    FWeaponShot(UShipStateComponent InAttacker, UShipStateComponent InTarget,
                USceneComponent InSourceRoot, USceneComponent InTargetRoot,
                EWeaponFiringType InFiringType, float InInitiative, EWeaponState InWeaponState=EWeaponState::Unequipped)
    {
        Attacker = InAttacker;
        Target = InTarget;
        SourceRoot = InSourceRoot;
        TargetRoot = InTargetRoot;
        FiringType = InFiringType;
        Initiative = InInitiative;
        WeaponState = InWeaponState;
    }

};

class UWeaponSubsystem : UScriptWorldSubsystem
{
    private TArray<FPendingVfxProjectile> ActiveShots;
    private TArray<FPendingVfxBeam> ActiveBeams;
    private float TurnDuration = 4.0;

    UFUNCTION()
    void FireProjectile(
        UNiagaraSystem TracerVfx, 
        UNiagaraSystem ImpactVfx,
        FVector MuzzleLocation, 
        USceneComponent TargetRoot,
        FVector OffsetPosition)
    {
        if (TargetRoot == nullptr || TracerVfx == nullptr)
            return;

        FPendingVfxProjectile NewShot;
        NewShot.CurrentPosition = MuzzleLocation;
        NewShot.TargetRoot = TargetRoot;
        NewShot.ImpactVfx = ImpactVfx;
        NewShot.OffsetPosition = OffsetPosition; 

        FVector InitialTargetPos = TargetRoot.WorldLocation;
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

    UFUNCTION()
    void FireBeam(
        UNiagaraSystem BeamVfx,
        UNiagaraSystem ImpactVfx,
        USceneComponent SourceRootComponent,
        USceneComponent TargetRootComponent,
        FVector OffsetPosition)
    {
        if (SourceRootComponent == nullptr || TargetRootComponent == nullptr || BeamVfx == nullptr)
            return;

        const FVector TargetLoc = TargetRootComponent.WorldLocation + OffsetPosition;
        const float Distance2D = (TargetLoc - SourceRootComponent.WorldLocation).Size2D();

        const float TravelTime = Math::GetMappedRangeValueUnclamped(
            FVector2D(0.0, DefaultBeamSpeed), 
            FVector2D(SMALL_NUMBER, 1), 
            Distance2D
        );
        const float Duration = TravelTime * 2.0 + BeamSustainTime;

        UNiagaraComponent LaserComp = Niagara::SpawnSystemAtLocation(
            BeamVfx,
            SourceRootComponent.WorldLocation,
            FRotator::ZeroRotator,
            FVector(1.0),
            true,
            true
        );

        if (LaserComp != nullptr)
        {
            LaserComp.SetFloatParameter(n"TravelTime", TravelTime);
            LaserComp.SetFloatParameter(n"Duration", Duration);
            LaserComp.SetFloatParameter(n"HoldTime", BeamSustainTime);
            LaserComp.SetVectorParameter(n"BeamStart", SourceRootComponent.WorldLocation);
            LaserComp.SetVectorParameter(n"BeamEnd", TargetLoc);
        }

        // 2. Spawn Impact VFX attached 75 units in direction from TargetLoc to MuzzleLocation
        UNiagaraComponent ImpactComp = nullptr;
        if (ImpactVfx != nullptr && TargetRootComponent != nullptr)
        {
            const FVector DirToMuzzle = (SourceRootComponent.WorldLocation - TargetLoc).GetSafeNormal();
            const FVector ImpactWorldLoc = TargetLoc + (DirToMuzzle * 75.0); //TODO: change hardcoded value

            ImpactComp = Niagara::SpawnSystemAttached(
                ImpactVfx,
                TargetRootComponent,
                NAME_None,
                ImpactWorldLoc,
                FRotator::ZeroRotator,
                EAttachLocation::KeepWorldPosition,
                true,
                true
            );
        }

        FPendingVfxBeam NewBeam;
        NewBeam.LaserTemplateNS = LaserComp;
        NewBeam.ImpactTemplateNS = ImpactComp;
        NewBeam.SourceRoot = SourceRootComponent;
        NewBeam.TargetRoot = TargetRootComponent;
        NewBeam.OffsetPosition = OffsetPosition;
        NewBeam.Duration = Duration;
        NewBeam.ElapsedTime = 0.0;

        ActiveBeams.Add(NewBeam);
    }

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaTime)
    {
        //Projectiles
        for (int32 i = ActiveShots.Num() - 1; i >= 0; --i)
        {
            FPendingVfxProjectile& Shot = ActiveShots[i];

            const float FullStep = DefaultProjectileSpeed * DeltaTime;
            const FVector TargetLocation = Shot.TargetRoot.WorldLocation + Shot.OffsetPosition;

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
                        Shot.TargetRoot,
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

        //Projectile "Water Jet" style Beams
        for (int32 i = ActiveBeams.Num() - 1; i >= 0; --i)
        {
            FPendingVfxBeam& Beam = ActiveBeams[i];
            Beam.ElapsedTime += DeltaTime;

            if (!(Beam.TargetRoot != nullptr && Beam.SourceRoot != nullptr) || Beam.ElapsedTime >= Beam.Duration)
            {
                if (Beam.LaserTemplateNS != nullptr)
                {
                    Beam.LaserTemplateNS.Deactivate();
                }

                if (Beam.ImpactTemplateNS != nullptr)
                {
                    Beam.ImpactTemplateNS.Deactivate();
                }

                ActiveBeams.RemoveAtSwap(i);
                continue;
            }

            Beam.LaserTemplateNS.SetVectorParameter(n"BeamStart", Beam.SourceRoot.WorldLocation);
            Beam.LaserTemplateNS.SetVectorParameter(n"BeamEnd", Beam.TargetRoot.WorldLocation + Beam.OffsetPosition);
        }
    }

    TArray<FWeaponShot> CalculateFiringTimeline(TArray<UShipStateComponent> ActiveShips)
    {
        TArray<FWeaponShot> PendingShots;
        TMap<UShipStateComponent, int> TargetCounts;

        // 1. No gathering, individual ships add orders to the subsystem on their own

        // 2. Calculate execution timeline based on target groupings
        int TotalEngagedTargets = TargetCounts.Num();
        
        // Distribute independent engagements evenly across the turn
        float SpreadInterval = TurnDuration / Math::Max(1, TotalEngagedTargets);
        int CurrentPairIndex = 0;

        TArray<FWeaponShot> FinalTimeline;

        for (auto Kvp : TargetCounts)
        {
            UShipStateComponent PinnedTarget = Kvp.Key;
            int AttackerCount = Kvp.Value;

            // Base timestamp for this specific engagement cluster
            float ClusterStartTime = CurrentPairIndex * SpreadInterval;

            // Swarm vs Duel Logic:
            // If many attackers (Swarm), TimeWindow shrinks, causing a rapid burst.
            // If 1v1 (Duel), TimeWindow utilizes the full interval, spreading shots out.
            float BurstCompression = 1.0 / float(AttackerCount);
            float TimeWindow = SpreadInterval * BurstCompression;

            // 3. Apply Initiative within the dynamically scaled time window
            for (int i = PendingShots.Num() - 1; i >= 0; i--)
            {
                if (PendingShots[i].Target == PinnedTarget)
                {
                    FWeaponShot FinalShot = PendingShots[i];
                    
                    // The weapon's initiative determines exactly when it fires inside the cluster
                    float InitiativeOffset = FinalShot.Initiative * TimeWindow;
                    FinalShot.FinalFireTime = ClusterStartTime + InitiativeOffset;
                    
                    FinalTimeline.Add(FinalShot);
                    PendingShots.RemoveAt(i);
                }
            }
            
            CurrentPairIndex++;
        }

        // 4. Sort the completed timeline chronologically for the execution manager
        FinalTimeline.Sort();
        return FinalTimeline;
    }
}