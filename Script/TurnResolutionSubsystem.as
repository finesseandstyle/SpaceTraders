// TurnResolutionSubsystem.as
//
// Respnosible for managing lifecycle of gameobjects, turn managament, weapon

event void FOnTurnUpdate2();
event void FOnTurnResume2();
event void FOnTurnPaused2();
event void FOnTurnDurationChanged2();
event void FOnSmallObjectSpawned2(USceneComponent RootComponent, FGameplayTag ObjectType, FGameplayTag Race);
event void FOnSmallObjectDestroyed2(USceneComponent RootComponent);
event void FOnGameStateInitialized2();

const float DefaultProjectileSpeed = 15000.0;
const float DefaultBeamSpeed = 35000.0;
const float BeamSustainTime = 0.25;
const int MaxFiringRounds = 3;

/*
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
}*/

class UTurnResolutionSubsystem : UScriptWorldSubsystem
{
    // ==================================================================
    // -- From TopDown_GameState: turn clock, pause state, world registry --
    // ==================================================================
    const FTimespan OneTurn = FTimespan::FromDays(1);

    UPROPERTY() FOnTurnUpdate2 OnTurnUpdate;
    UPROPERTY() FOnTurnResume2 OnTurnResume;
    UPROPERTY() FOnTurnPaused2 OnTurnPaused;
    UPROPERTY() FOnTurnDurationChanged2 OnTurnDurationChanged;
    UPROPERTY() FOnSmallObjectSpawned2 OnSmallObjectSpawned;
    UPROPERTY() FOnSmallObjectDestroyed2 OnSmallObjectDestroyed;
    UPROPERTY() FOnGameStateInitialized2 OnGameStateReady;

    //1 January 3300
    UPROPERTY() FDateTime CurrentTurnDate = FDateTime(3300, 1, 1);

    //World Stuff, Ships spawn in their own horizontal plane
    UPROPERTY() float LocalWorldHalfSize = 200000.0; //depends on the star system
    UPROPERTY() float MinZPlane = 5700.0;
    UPROPERTY() float MaxZPlane = 6100;

    //Turn Logic stuff
    private FTimerHandle TurnTimer;
    UPROPERTY() float TurnDuration; //USpaceTradersSettings::GetUserSettings().TurnDuration;

    //We default 1.0 at turn's end like it's 23:59, just before a new day/turn
    UPROPERTY() float NormalizedTurnProgress = 1.0;
    UPROPERTY() bool bIsGamePaused = false;

    UPROPERTY() TArray<AGameObject> GameObjects;
    UPROPERTY() TArray<AGameObject> Planets;

    bool bQueuePause = false;

    // ==================================================================
    // -- From WeaponSubsystem: VFX pools + weapon data --
    // ==================================================================
    private TArray<FPendingVfxProjectile> ActiveVFXShots;
    private TArray<FPendingVfxBeam> ActiveVFXBeams;

    UPROPERTY() UDataTable WeaponSpawningRules;

    // ==================================================================
    // -- Combat timeline state (previously WeaponSubsystem's own clock) --
    // ==================================================================
    private TArray<FWeaponShot> Timeline;
    private int32 NextShotIndex = 0;
    private bool bTurnActive = false;

    // ------------------------------------------------------------------
    // Lifecycle (from TopDown_GameState::BeginPlay)
    // ------------------------------------------------------------------
    UFUNCTION(BlueprintOverride)
    void Initialize()
    {
        bQueuePause = true;
        bIsGamePaused = true;
        TurnDuration = UTopDown_Settings().GetTurnDuration();

        OnGameStateReady.Broadcast();

        GetAllActorsOfClass(GameObjects);
        HandleTurn();
    }

    // ------------------------------------------------------------------
    // Combined per-frame tick: VFX advance first (as before), then the
    // turn clock + combat timeline execution.
    // ------------------------------------------------------------------
    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaTime)
    {
        if (bIsGamePaused) return;
        
        NormalizedTurnProgress = System::GetTimerElapsedTimeHandle(TurnTimer) / TurnDuration;

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

        // Reuse the game-state's own turn timer as the combat clock, instead
        // of accumulating a second, separate ElapsedTurnTime counter.
        const float ElapsedTurnTime = GetElapsedTime();

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
    // Turn clock / pause-resume (from TopDown_GameState, unchanged)
    // ------------------------------------------------------------------
    //Returns real time seconds elapsed after turn start
    UFUNCTION(BlueprintPure)
    float GetElapsedTime()
    {
        return System::GetTimerElapsedTimeHandle(TurnTimer);
    }

    UFUNCTION()
    void TogglePause(bool&out bIsQueuePaused)
    {
        if (bQueuePause)
        {
            TryResumeTurn();
        }
        else
        {
            TryPauseTurn();
        }
        bIsQueuePaused = bQueuePause;
    }

    UFUNCTION()
    void TryPauseTurn()
    {
        bQueuePause = true;
    }

    UFUNCTION()
    void TryResumeTurn()
    {
        bQueuePause = false;
        if (bIsGamePaused)
        {
            NormalizedTurnProgress = 0.0; //otherwise ships will teleport to their destination on the 1st frame

            OnTurnResume.Broadcast();
            HandleTurn();
            for (AGameObject GameObject : GameObjects)
            {
                if (GameObject != nullptr) //Dirty fix for destroyed objects not updating the array
                    GameObject.TurnResume();
            }
        }
    }

    UFUNCTION()
    void SetNewTurnDuration(float NewTurnDuration)
    {
        if (bIsGamePaused)
        {
            TurnDuration = NewTurnDuration; //input validation is done inside settings menu UI;
            OnTurnDurationChanged.Broadcast();
        }
    }

    // ------------------------------------------------------------------
    // HandleTurn now also kicks off combat resolution: the moment a turn
    // actually starts ticking is the same moment the weapon timeline
    // should be built and armed, so BeginTurn() is folded in here rather
    // than requiring a second external call.
    // ------------------------------------------------------------------
    UFUNCTION()
    void HandleTurn()
    {
        if (!bQueuePause)
        {
            CurrentTurnDate = CurrentTurnDate + OneTurn;
            bIsGamePaused = false;

            for (AGameObject GameObject : GameObjects)
            {
                GameObject.TurnUpdate();
            }
            OnTurnUpdate.Broadcast();

            BeginTurn();

            TurnTimer = System::SetTimer(this, n"HandleTurn", TurnDuration, false);
        }
        else
        {
            bIsGamePaused = true;

            for (AGameObject GameObject : GameObjects)
            {
                GameObject.TurnPause();
            }
            OnTurnPaused.Broadcast();

            System::ClearAndInvalidateTimerHandle(TurnTimer);
        }
    }

    // ------------------------------------------------------------------
    // Call once per turn, after every ship has submitted its WeaponOrders.
    // Called automatically from HandleTurn(); kept public in case you need
    // to rebuild/re-arm the timeline from elsewhere (e.g. a debug tool).
    // ------------------------------------------------------------------
    UFUNCTION()
    void BeginTurn()
    {
        Timeline = BuildTimeline();
        NextShotIndex = 0;
        bTurnActive = Timeline.Num() > 0;
    }

    UFUNCTION()
    bool IsTurnResolved() const
    {
        return !bTurnActive;
    }

    // ==================================================================
    // -- Weapon firing (from WeaponSubsystem, unchanged) --
    // ==================================================================
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

    // ==================================================================
    // -- Combat resolution pipeline (from WeaponSubsystem, unchanged) --
    // ==================================================================

    // ------------------------------------------------------------------
    // Step 1: gather every active FWeaponShot order for this turn.
    // Now reads GameObjects directly off this subsystem instead of
    // fetching ATopDown_GameState.
    // ------------------------------------------------------------------
    private TArray<FWeaponShot> GatherActiveShots() const
    {
        TArray<FWeaponShot> ActiveShots;

        for (AGameObject Ship : GameObjects)
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
    // Step 5: dispatch each shot to the right firing function.
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

// ======================================================================
// MIGRATION NOTES
// ======================================================================
// 1. Any `Cast<ATopDown_GameState>(Gameplay::GetGameState())` elsewhere in
//    the project needs to become a subsystem fetch instead, e.g.:
//        UTurnResolutionSubsystem TurnSys = GetWorld().GetSubsystem(UTurnResolutionSubsystem);
//    (adjust to whatever subsystem accessor your AngelScript build exposes).
//
// 2. ATopDown_GameState::BeginPlay() ran via the actor lifecycle; subsystems
//    don't have BeginPlay. I mapped its body to Initialize() (the common
//    subsystem-init override in AngelScript-UE) -- confirm this is the
//    right override name/timing in your build, since GetAllActorsOfClass
//    and world setup may need the world to be further along than a
//    subsystem's Initialize() guarantees.
//
// 3. ATopDown_GameState::SetActorTickEnabled(...) was an AActor method and
//    doesn't exist on a subsystem. I renamed calls to SetTickEnabled(...)
//    as a placeholder -- replace with however this AngelScript-UE build
//    toggles tick on a UScriptWorldSubsystem (some builds just gate the
//    work inside Tick() with a bool instead of disabling the tick itself).
//
// 4. If anything (UI, save data, other subsystems) held a direct reference
//    to the ATopDown_GameState actor itself (not just its fields), that
//    reference will need to be repointed at this subsystem too.
