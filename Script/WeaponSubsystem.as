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

enum EWeaponState {
    Unequipped,
    Equipped,
    Broken,
    Disabled, //by debuffs for example
    Pressed, //UI only for the player when they initially select a weapon before assigning to a target
    Targeting
}


struct FWeaponShotCluster
{
    TArray<FWeaponShot> Shots;
}

struct FWeaponShot
{
    UPROPERTY() FGameplayTag WeaponSlot;
    UPROPERTY() FName WeaponName;

    UPROPERTY() UShipStateComponent Attacker;
    UPROPERTY() AGameObject Target;
    UPROPERTY() USceneComponent SourceRoot, TargetRoot; //Both Required for beams, Target required for ballistic firing
    UPROPERTY() EWeaponFiringType FiringType; //Instant -> Attacker.FireWeaponAt; Ballistic->Projectile->Attacker.FireProjectileWeapon & Spawn Homing Projectile
    UPROPERTY() float Initiative;
    UPROPERTY() float FinalFireTime;
    UPROPERTY() float Range;

    UPROPERTY() EWeaponState WeaponState;

    bool opCmp(const FWeaponShot& Other) const
    {
        return FinalFireTime < Other.FinalFireTime;
    }

    FWeaponShot(FGameplayTag InWeaponSlot, FName InWeaponName, UShipStateComponent InAttacker, AGameObject InTarget,
                USceneComponent InSourceRoot, USceneComponent InTargetRoot,
                EWeaponFiringType InFiringType, float InInitiative, float InRange, EWeaponState InWeaponState=EWeaponState::Unequipped)
    {
        WeaponSlot = InWeaponSlot;
        WeaponName = InWeaponName;
        Attacker = InAttacker;
        Target = InTarget;
        SourceRoot = InSourceRoot;
        TargetRoot = InTargetRoot;
        FiringType = InFiringType;
        Initiative = InInitiative;
        WeaponState = InWeaponState;
        Range = InRange;
    }

};

struct FWeaponSpawningRuleRow
{
    UPROPERTY() UStaticMesh ProjectileMesh;
    UPROPERTY() UNiagaraSystem ShotNS;
    UPROPERTY() UNiagaraSystem ImpactNS;
    UPROPERTY() USoundWave ShotSound;
    UPROPERTY() USoundWave ImpactSound;
}

class UWeaponSubsystem : UScriptWorldSubsystem
{
    private TArray<FPendingVfxProjectile> ActiveVFXShots;
    private TArray<FPendingVfxBeam> ActiveVFXBeams;
    private float TurnDuration = 4.0;

    UPROPERTY() UDataTable WeaponSpawningRules;

    private TArray<FWeaponShot> Timeline;
    private float ElapsedTurnTime = 0.0;
    private int32 NextShotIndex = 0;
    private bool bTurnActive = false;


    UFUNCTION()
    void FireInstantProjectile(FName RowName, FGameplayTag WeaponSlot, FVector MuzzleLocation, AGameObject Attacker, AGameObject Defender, FVector OffsetPosition)
    {
        FWeaponSpawningRuleRow Row;
        WeaponSpawningRules.FindRow(RowName, Row);
        UShipStateComponent Stats = Attacker.GetComponentByClass(UShipStateComponent);

        if (Defender.ObjectType == GameplayTags::GameObject_Ship)
        {
            float Damage;
            Stats.FireWeaponAt(WeaponSlot, nullptr, Damage);
        }
        else if (Defender.ObjectType == GameplayTags::GameObject_Loot)
        {
            Defender.DestroyActor(); //any instance of damage against Loot will destroy it
        }
        else if (Defender.ObjectType == GameplayTags::GameObject_Projectile)
        {
            //Projectiles have their own simplified health
        }
        FireProjectile(Row.ShotNS, Row.ImpactNS, MuzzleLocation, Defender.RootComponent, OffsetPosition);
    }

    private void FireProjectile(
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

        ActiveVFXShots.Add(NewShot);
    }

    UFUNCTION()
    void FireBeam(FName RowName, FGameplayTag WeaponSlot, AGameObject Attacker,
        AGameObject Defender, FVector OffsetPosition)
    {
        FWeaponSpawningRuleRow Row;
        WeaponSpawningRules.FindRow(RowName, Row);

        if (Defender.ObjectType == GameplayTags::GameObject_Ship)
        {
            float Damage;
            UShipStateComponent AttackerStats = Attacker.GetComponentByClass(UShipStateComponent);
            UShipStateComponent DefenderStats = Defender.GetComponentByClass(UShipStateComponent);
            AttackerStats.FireWeaponAt(WeaponSlot, DefenderStats, Damage);
            UTopDownPlannerComponent Planner = Gameplay::GetPlayerController(0).GetComponentByClass(UTopDownPlannerComponent);

            if (Planner != nullptr)
                Planner.DisplayDamageNumbers(Defender.ActorLocation + OffsetPosition, Damage);
        }
        else if (Defender.ObjectType == GameplayTags::GameObject_Loot || Defender.ObjectType == GameplayTags::GameObject_Projectile)
        {
            
            float Damage;
            UShipStateComponent AttackerStats = Attacker.GetComponentByClass(UShipStateComponent);
            AttackerStats.FireWeaponAt(WeaponSlot, nullptr, Damage);
            //UShipStateComponent AttackerStats = Attacker.GetComponentByClass(UShipStateComponent);
            //AttackerStats.AddHeat(Weapon.HeatUse * HeatModifier); // firing costs the shooter heat too
            Defender.DestroyActor(); //any instance of damage against Loot will destroy it
            //TODO: Projectiles have their own simplified health
        }
        
        FireBeam2(Row.ShotNS, Row.ImpactNS, Attacker.RootComponent, Defender.RootComponent, OffsetPosition);
    }

    private void FireBeam2(
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

        ActiveVFXBeams.Add(NewBeam);
    }

    UFUNCTION()
    void FireBallisticProjectile(FName RowName, FGameplayTag WeaponSlot, AGameObject Attacker, USceneComponent TargetRootComponent)
    {
        FWeaponSpawningRuleRow Row;
        WeaponSpawningRules.FindRow(RowName, Row);
        UShipStateComponent Stats = Attacker.GetComponentByClass(UShipStateComponent);
        FProjectileDamageSpec Damage2;
        Stats.FireProjectileWeapon(WeaponSlot, TargetRootComponent, Damage2);
        UTurnBasedMovementComponent MoveComp = Attacker.GetComponentByClass(UTurnBasedMovementComponent);

        ABallisticProjectile Projectile = SpawnActor(ABallisticProjectile, Attacker.ActorLocation, Attacker.ActorRotation, bDeferredSpawn = true);
        Projectile.Owner = Attacker;
        Projectile.ProjectileMesh.SetStaticMesh(Row.ProjectileMesh);
        Projectile.Damage = Damage2;
        Projectile.ImpactNS = Row.ImpactNS;
        Projectile.ExhaustNS.SetAsset(Row.ShotNS);
        //UTurnBasedMovement's Speed = 1 / ~0.265 real UU Speed, idk why
        Projectile.InheritedSpeed = MoveComp.GetInstantSpeed() * 0.265 + 200.0;  //slightly faster than the attacker
        FinishSpawningActor(Projectile);

    }

    //Tickable structs where we manually control their lifetimes
    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaTime)
    {
        //Projectiles
        for (int32 i = ActiveVFXShots.Num() - 1; i >= 0; --i)
        {
            FPendingVfxProjectile& Shot = ActiveVFXShots[i];

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

                ActiveVFXShots.RemoveAtSwap(i);
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
        for (int32 i = ActiveVFXBeams.Num() - 1; i >= 0; --i)
        {
            FPendingVfxBeam& Beam = ActiveVFXBeams[i];
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

                ActiveVFXBeams.RemoveAtSwap(i);
                continue;
            }

            Beam.LaserTemplateNS.SetVectorParameter(n"BeamStart", Beam.SourceRoot.WorldLocation);
            Beam.LaserTemplateNS.SetVectorParameter(n"BeamEnd", Beam.TargetRoot.WorldLocation + Beam.OffsetPosition);
        }

        //We always let the weapon VFX play out first 

        if (!bTurnActive)
            return;

        ElapsedTurnTime += DeltaTime;

        while (NextShotIndex < Timeline.Num() && Timeline[NextShotIndex].FinalFireTime <= ElapsedTurnTime)
        {
            ExecuteShot(Timeline[NextShotIndex]);
            NextShotIndex++;
        }

        if (NextShotIndex >= Timeline.Num())
        {
            bTurnActive = false;
            // TODO: broadcast an OnTurnResolved event/delegate here so
            // whatever owns the turn loop knows it's safe to advance.
        }
    }

    // ------------------------------------------------------------------
    // Call once per turn, after every ship has submitted its WeaponOrders.
    // ------------------------------------------------------------------
    UFUNCTION()
    void BeginTurn()
    {
        Timeline = BuildTimeline();
        ElapsedTurnTime = 0.0;
        NextShotIndex = 0;
        bTurnActive = Timeline.Num() > 0;
    }

    UFUNCTION()
    bool IsTurnResolved() const
    {
        return !bTurnActive;
    }

    // ------------------------------------------------------------------
    // Step 1: gather every active FWeaponShot order for this turn.
    // (This is your commented-out scaffold, filled in.)
    // ------------------------------------------------------------------
    private TArray<FWeaponShot> GatherActiveShots() const
    {
        TArray<FWeaponShot> ActiveShots;

        ATopDown_GameState GameState = Cast<ATopDown_GameState>(Gameplay::GetGameState());
        if (GameState == nullptr)
            return ActiveShots;

        for (AGameObject Ship : GameState.GameObjects)
        {
            if (Ship == nullptr)
                continue;

            UShipStateComponent AttackerState = Ship.GetComponentByClass(UShipStateComponent);
            if (AttackerState == nullptr)
                continue;

            for (FWeaponShot Shot : AttackerState.WeaponOrders)
            {
                if (Shot.WeaponState == EWeaponState::Targeting && Shot.Target != nullptr)
                    ActiveShots.Add(Shot);
            }
        }

        return ActiveShots;
    }

    // ------------------------------------------------------------------
    // Steps 2-4: build the combat graph, cluster it, resolve per-cluster
    // timing from Initiative, then merge everything into one global,
    // chronologically-sorted timeline.
    // ------------------------------------------------------------------
    private TArray<FWeaponShot> BuildTimeline() const
    {
        TArray<FWeaponShot> AllShots = GatherActiveShots();

        TArray<FWeaponShot> FinalTimeline;
        if (AllShots.Num() == 0)
            return FinalTimeline;

        // --- Union-Find over every ship that appears as attacker or target ---
        TMap<UObject, int32> NodeIndex;
        TArray<int32> Parent;

        for (FWeaponShot Shot : AllShots)
        {
            UObject AttackerNode = GetAttackerNode(Shot);
            EnsureNode(AttackerNode, NodeIndex, Parent);

            if (Shot.Target != nullptr)
            {
                EnsureNode(Shot.Target, NodeIndex, Parent);
                if (AttackerNode != nullptr)
                    UnionNodes(Parent, NodeIndex[AttackerNode], NodeIndex[Shot.Target]);
            }
        }

        // --- Group shots by cluster root, tracking unique roots as we go ---
        TMap<int32, FWeaponShotCluster> Clusters;
        TArray<int32> ClusterRoots;

        for (FWeaponShot Shot : AllShots)
        {
            UObject AttackerNode = GetAttackerNode(Shot);
            if (AttackerNode == nullptr || !NodeIndex.Contains(AttackerNode))
                continue; // no attacker identity to cluster on -- malformed order

            int32 RootIdx = FindRoot(Parent, NodeIndex[AttackerNode]);

            if (!Clusters.Contains(RootIdx))
            {
                Clusters.Add(RootIdx, FWeaponShotCluster());
                ClusterRoots.Add(RootIdx);
            }

            Clusters[RootIdx].Shots.Add(Shot);
        }

        // --- Step 3: resolve firing order + timing within each cluster ---
        for (int32 Root : ClusterRoots)
        {
            FWeaponShotCluster Cluster = Clusters[Root];
            SortByInitiativeDescending(Cluster.Shots);

            const int32 Count = Cluster.Shots.Num();
            for (int32 i = 0; i < Count; i++)
            {
                FWeaponShot TimedShot = Cluster.Shots[i];

                // Spread this cluster's shots evenly across the turn window.
                // Same-rank shots in equal-sized clusters land on the same
                // timestamp by construction -- that's what keeps unrelated
                // duels executing in lockstep, while a cluster's internal
                // order stays strictly Initiative-ordered.
                //
                // Divide by Count (not Count - 1): this reserves one extra,
                // unused slot at rank == Count (i.e. at exactly TurnDuration)
                // so the last real shot never lands right on the turn
                // boundary. E.g. 4 weapons -> 0.0, 0.25, 0.5, 0.75, with
                // 1.0 left empty.
                TimedShot.FinalFireTime = (float(i) / float(Count)) * TurnDuration;

                FinalTimeline.Add(TimedShot);
            }
        }

        // --- Step 4: merge everything into one global chronological timeline ---
        SortByFinalFireTimeAscending(FinalTimeline);
        return FinalTimeline;
    }

    private UObject GetAttackerNode(const FWeaponShot& Shot) const
    {
        if (Shot.Attacker == nullptr)
            return nullptr;
        return Shot.Attacker.Owner; // owning ship actor -- must match Shot.Target's identity
    }

    // ------------------------------------------------------------------
    // Union-Find helpers
    // ------------------------------------------------------------------
    private void EnsureNode(UObject Node, TMap<UObject, int32>& NodeIndex, TArray<int32>& Parent) const
    {
        if (Node == nullptr || NodeIndex.Contains(Node))
            return;

        int32 NewIndex = Parent.Num();
        NodeIndex.Add(Node, NewIndex);
        Parent.Add(NewIndex); // self-parent = own root
    }

    private int32 FindRoot(TArray<int32>& Parent, int32& X) const
    {
        while (Parent[X] != X)
        {
            Parent[X] = Parent[Parent[X]]; // path compression
            X = Parent[X];
        }
        return X;
    }

    private void UnionNodes(TArray<int32>& Parent, int32& A, int32& B) const
    {
        int32 RootA = FindRoot(Parent, A);
        int32 RootB = FindRoot(Parent, B);
        if (RootA != RootB)
            Parent[RootA] = RootB;
    }

    // ------------------------------------------------------------------
    // Insertion sort
    // TODO : replace with proper faster sorting and add more sorting params like weapon slots used, stats and weapon id
    // ------------------------------------------------------------------
    private void SortByInitiativeDescending(TArray<FWeaponShot>& Shots) const
    {
        for (int32 i = 1; i < Shots.Num(); i++)
        {
            FWeaponShot Key = Shots[i];
            int32 j = i - 1;
            while (j >= 0 && Shots[j].Initiative < Key.Initiative)
            {
                Shots[j + 1] = Shots[j];
                j--;
            }
            Shots[j + 1] = Key;
        }
    }

    private void SortByFinalFireTimeAscending(TArray<FWeaponShot>& Shots) const
    {
        for (int32 i = 1; i < Shots.Num(); i++)
        {
            FWeaponShot Key = Shots[i];
            int32 j = i - 1;
            while (j >= 0 && Shots[j].FinalFireTime > Key.FinalFireTime)
            {
                Shots[j + 1] = Shots[j];
                j--;
            }
            Shots[j + 1] = Key;
        }
    }

    // ------------------------------------------------------------------
    // Step 5: dispatch each shot to the right WeaponSubsystem call.
    // See the note below the file for why the actual calls are commented.
    // ------------------------------------------------------------------
    private void ExecuteShot(FWeaponShot Shot)
    {
        AGameObject AttackerObject = Cast<AGameObject>(GetAttackerNode(Shot));
        AGameObject DefenderObject = Cast<AGameObject>(Shot.Target);

        //Objects can be destroyed during turn execution, we don't fire if any of the 2 are invalid
        //TODO: object destruction sequences 
        if (!IsValid(AttackerObject) || !IsValid(DefenderObject))
            return;

        //Range check
        if (!GameLogic::IsInRange(AttackerObject.ActorLocation, DefenderObject.ActorLocation, Shot.Range))
            return;

        float OffsetMax = 75;
        FVector Offset = FVector(Math::RandRange(0, OffsetMax), Math::RandRange(0, OffsetMax), Math::RandRange(0, OffsetMax));
        

        switch (Shot.FiringType)
        {
            case EWeaponFiringType::Projectile:
                FireInstantProjectile(Shot.WeaponName, Shot.WeaponSlot, Shot.SourceRoot.WorldLocation, AttackerObject, DefenderObject, Offset);
                break;

            case EWeaponFiringType::Beam:
                FireBeam(Shot.WeaponName, Shot.WeaponSlot, AttackerObject, DefenderObject, Offset);
                break;

            case EWeaponFiringType::Ballistic:
                FireBallisticProjectile(Shot.WeaponName, Shot.WeaponSlot, AttackerObject, Shot.TargetRoot);
                break;

            default:
                break;
        }
    }
}