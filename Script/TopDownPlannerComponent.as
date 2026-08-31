//Ideally create a few more like: On Landable Object, On Ship, On Loot
enum EInteractionResult {
        Invalid,
        OnPlayfield,
        OnSelf,
        OnPlanet,
        OnStation,
        OnLoot,
        OnSpaceship,
        OnAsteroid,
        OnProjectile
}

enum EPathingClickType {
    NewPath,
    AddWaypointToPath,
    QueuePathMidTurn,
    CancelPathQueueing,
}

enum ETurnMovementType {
    Fly,
    Land,
    Follow,
    Intercept,
    AutoFight,
    LongRange,
    Hyperjump
}

event void FOnHoveredObjectChanged(AGameObject PreviousObject, AGameObject Object);

class UTopDownPlannerComponent : UActorComponent
{
    UPROPERTY() FOnHoveredObjectChanged OnHoveredObjectChanged;

    UPROPERTY() FVector PlayfieldLocation; //Should be aligned with GameState's MaxZPlane
    UPROPERTY() FVector ScrollingLocation;
    
    UPROPERTY() AGameObject SelectedObject;
    UPROPERTY() AGameObject HoveredObject;
    private AGameObject CurrentHoveredObject = nullptr;

    UPROPERTY() AGameObject PlayerShip;
    UPROPERTY() UTurnBasedMovementComponent MoveComp;
    UPROPERTY() UShipStateComponent ShipComp;

    UPROPERTY() TArray<AActor> ActorsToIgnore; //Playfield and any helper actors that should not obstruct hovering
    UPROPERTY() TArray<AActor> Stars;

    UPROPERTY() bool bCursorOverUI = false;
    UPROPERTY() bool bMultiWaypoint = false;
    UPROPERTY() bool bRotatingPath = false;
    UPROPERTY() float PathClickingDistance = 100;

    UPROPERTY() UNiagaraComponent PlayerPath;
    UPROPERTY() UNiagaraComponent HoveredPath;

    UPROPERTY() UNiagaraSystem PathTemplate;

    UPROPERTY() ETurnMovementType MovementType = ETurnMovementType::Fly;
    UPROPERTY() AActor LandingObject;
    UPROPERTY() ATurnMarker TurnMarker;

    private bool bHasResult;
    private FTimerHandle HidePathHandle;

    private FCollisionQueryParams Params;

    // Segmented ring material
    UPROPERTY(Category = "Range Ring")
    UMaterialInterface RingMaterial;
    UPROPERTY(Category = "Range Ring")
    UStaticMesh RingMesh;

    UPROPERTY() FLinearColor PickupColor = FLinearColor(0.0, 0.0, 1.0);
    UPROPERTY() FLinearColor RadarColor = FLinearColor(0.00, 0.70, 0.00);
    UPROPERTY() FLinearColor WeaponColor = FLinearColor(1.00, 0.00, 0.00);
    UPROPERTY() FLinearColor FalloffColor = FLinearColor(0.05, 0.05, 0.05, 1.0);

    UPROPERTY() URangeIndicatorComponent PickupRangeIndicator;
    UPROPERTY() URangeIndicatorComponent RadarRangeIndicator;
    UPROPERTY() URangeIndicatorComponent WeaponMinRangeIndicator;
    UPROPERTY() URangeIndicatorComponent WeaponMaxRangeIndicator;
    UPROPERTY() URangeIndicatorComponent DamageFalloffIndicator;

    UFUNCTION(BlueprintOverride)
    void BeginPlay()
    {
        Gameplay::GetAllActorsWithTag(n"Playfield", ActorsToIgnore);
        //not expected to change
        
        for (AActor Actor : ActorsToIgnore)
        {
            Params.AddIgnoredActor(Actor);
        }
        //SetTickGroup(ETickingGroup::TG_PostPhysics);
        TurnMarker.SetActorHiddenInGame(true);
        MoveComp = PlayerShip.GetComponentByClass(UTurnBasedMovementComponent); 
        ShipComp = PlayerShip.GetComponentByClass(UShipStateComponent); 
        InitializeRangeIndicator();
    }

    private void InitializeRangeIndicator()
    {
        AActor OwnerActor = GetOwner();
        if (OwnerActor == nullptr)
            return;

        USceneComponent RootComp = PlayerShip.GetRootComponent();
        if (RootComp == nullptr)
            return;

        PickupRangeIndicator = CreateRangeIndicator(RootComp, n"PickupRangeIndicator", PickupColor);    
        RadarRangeIndicator = CreateRangeIndicator(RootComp, n"RadarRangeIndicator", RadarColor);
        WeaponMinRangeIndicator = CreateRangeIndicator(RootComp, n"WeaponMinRangeIndicator", WeaponColor);
        WeaponMaxRangeIndicator = CreateRangeIndicator(RootComp, n"WeaponMaxRangeIndicator", WeaponColor);
        DamageFalloffIndicator = CreateRangeIndicator(RootComp, n"DamageFalloffIndicator", FalloffColor);

        PickupRangeIndicator.SetRingMaterial(RingMesh, RingMaterial);
        RadarRangeIndicator.SetRingMaterial(RingMesh, RingMaterial);
        WeaponMinRangeIndicator.SetRingMaterial(RingMesh, RingMaterial);
        WeaponMaxRangeIndicator.SetRingMaterial(RingMesh, RingMaterial);
        DamageFalloffIndicator.SetRingMaterial(RingMesh, RingMaterial);

        //Prevent Z fighting
        PickupRangeIndicator.SetRelativeLocation(FVector(0,0,-1));
        RadarRangeIndicator.SetRelativeLocation(FVector(0,0,0));
        WeaponMinRangeIndicator.SetRelativeLocation(FVector(0,0,2));
        WeaponMaxRangeIndicator.SetRelativeLocation(FVector(0,0,-2));
        DamageFalloffIndicator.SetRelativeLocation(FVector(0,0,1));

        PickupRangeIndicator.SetRadius(1200);
        RadarRangeIndicator.SetRadius(94000);
        WeaponMinRangeIndicator.SetRadius(2500);
        WeaponMaxRangeIndicator.SetRadius(4000);
        DamageFalloffIndicator.SetRadius(5000);
    }

    // Helper to spawn, scale, attach, and color individual range billboards
    //TODO: Consolidate SetRingMaterial, ZLevel and radius all in here.
    private URangeIndicatorComponent CreateRangeIndicator(USceneComponent Parent, FName ComponentName, FLinearColor Color)
    {
        // Create component attached to the ship
        URangeIndicatorComponent Billboard = Cast<URangeIndicatorComponent>(
            PlayerShip.CreateComponent(URangeIndicatorComponent, ComponentName)
        );

        if (Billboard == nullptr)
            return nullptr;

        Billboard.AttachToComponent(Parent);
        
        // Scale component by 10 as specified
        Billboard.SetWorldScale3D(FVector(10.0, 10.0, 10.0));
        Billboard.BaseColor = Color;

        return Billboard;
    }

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaSeconds)
    {
        bCursorOverUI = UGameUtility::IsCursorOverUI();
        bHasResult = GameMath::GetPlayfieldLocation(Gameplay::GetPlayerController(0), PlayfieldLocation);
        
        GameMath::GetObjectAtCursorLocation(PlayfieldLocation, Params, HoveredObject);

        //Print(f"{System::GetDisplayName(HoveredObject)}", 0);
        
        //Ignore all objects if mouse is hovering over the UI
        if (bCursorOverUI && CurrentHoveredObject != nullptr)
        {
            OnHoveredObjectChanged.Broadcast(CurrentHoveredObject, nullptr);
            CurrentHoveredObject = nullptr;
            return;
        }

        if (!bCursorOverUI && HoveredObject != CurrentHoveredObject)
        {
            // Hovered object CHANGED to a new valid actor!
            OnHoveredObjectChanged.Broadcast(CurrentHoveredObject, HoveredObject);

            CurrentHoveredObject = HoveredObject;
        }
    }

    UFUNCTION()
    EInteractionResult GetInteractedObject() {
        if (!bHasResult)
            return EInteractionResult::Invalid;

        if (HoveredObject == nullptr || Stars.Contains(HoveredObject))
            return EInteractionResult::OnPlayfield;

        if (HoveredObject == PlayerShip)
            return EInteractionResult::OnSelf;

        //Can't do switch on GameplayTags :(
        if (HoveredObject.ObjectType == GameplayTags::GameObject_Ship)
            return EInteractionResult::OnSpaceship;

        if (HoveredObject.ObjectType == GameplayTags::GameObject_InhabitedPlanet || 
        HoveredObject.ObjectType == GameplayTags::GameObject_UninhabitedPlanet)
            return EInteractionResult::OnPlanet;

        if (HoveredObject.ObjectType == GameplayTags::GameObject_Asteroid)
            return EInteractionResult::OnAsteroid;

        if (HoveredObject.ObjectType == GameplayTags::GameObject_Loot)
            return EInteractionResult::OnLoot;

        if (HoveredObject.ObjectType == GameplayTags::GameObject_Projectile)
            return EInteractionResult::OnProjectile;

        return EInteractionResult::Invalid;
    }

    UFUNCTION()
    void GoToLocation(FVector DestinationLocation)
    {
        FVector AdjustedLocation;
        int Distance, Days;
        if (Cast<ATopDown_GameState>(Gameplay::GetGameState()).bIsGamePaused)
        {
            if (bMultiWaypoint && MoveComp.HasPathDefined())
            {
                if (MoveComp.SetNewWaypoint(DestinationLocation, AdjustedLocation, Distance, Days))
                {
                    DrawPath(MoveComp, AdjustedLocation, Distance, Days);
                }
            }
            else 
            {
                if (MoveComp.SetPath(DestinationLocation, AdjustedLocation, Distance, Days))
                {
                    DrawPath(MoveComp, AdjustedLocation, Distance, Days);
                }
            }
        }
        else 
        {
            if (MoveComp.IsMoving() || MoveComp.IsStoppedForPickup())
            {
                if (DestinationLocation.Distance(MoveComp.GetPathEndOfTurnLocation()) >= PathClickingDistance)
                {
                    if (MoveComp.QueuePathMidTurn(DestinationLocation, AdjustedLocation, Distance, Days))
                    {
                        DrawPath(MoveComp, AdjustedLocation, Distance, Days, Duration=1);
                    }
                }
                else
                {
                    MoveComp.CancelPathQueueing(AdjustedLocation, Distance, Days);
                    DrawPath(MoveComp, AdjustedLocation, Distance, Days);
                }
            }
            else if (MoveComp.IsStopped())
            {
                if (GetOwner().ActorLocation.Distance(DestinationLocation) >= PathClickingDistance)
                {
                    if (MoveComp.SetPath(DestinationLocation, AdjustedLocation, Distance, Days))
                    {
                        DrawPath(MoveComp, AdjustedLocation, Distance, Days, Duration=1);
                    }
                }
                else 
                {
                    CancelPath();
                }
            }

        }
    }

    UFUNCTION()
    void CancelPath()
    {
        MoveComp.CancelPath();
        HidePath();
    }

    //Duration -1 means we draw forever until there's a change
    //HostileAction is either 0.0 or 1.0
    UFUNCTION()
    void DrawPath(UTurnBasedMovementComponent MovementComponent, FVector AdjustedLocation, int Distance, int Days, bool bUsePlayerPath=true, float Duration=-1, float HostileAction=0.0)
    {
        if (bUsePlayerPath)
        {
            TurnMarker.SetActorHiddenInGame(false);
            TurnMarker.SetLandingState(MovementType);
            TurnMarker.UpdateTurnMarker(AdjustedLocation, Distance, Days);

            TArray<FVector> CurrentPath, RemainingPath, TraversedPath, Checkpoints, ShadowPath1, ShadowPath2;
            UPathingUtils::GetPathSamples(MovementComponent.PathSpline, MovementComponent.CheckpointDistances, MovementComponent.StartDistance, 
            CurrentPath, RemainingPath, TraversedPath, Checkpoints, 75, 0);
            if (PlayerPath != nullptr)
            {
                PlayerPath.DestroyComponent();
            }
            PlayerPath = Niagara::SpawnSystemAtLocation(PathTemplate, FVector::ZeroVector);
            NiagaraDataInterfaceArray::SetNiagaraArrayVector(PlayerPath, n"CurrentPathPositions", CurrentPath);
            NiagaraDataInterfaceArray::SetNiagaraArrayVector(PlayerPath, n"RemainingPathPositions", RemainingPath);
            NiagaraDataInterfaceArray::SetNiagaraArrayVector(PlayerPath, n"CheckpointPositions", Checkpoints);

            if (MovementComponent.CheckpointDistances.Num() > 2)
            {
                PlayerPath.SetFloatParameter(n"HostileOpacityRemaining", HostileAction);
            }
            else 
            {
                PlayerPath.SetFloatParameter(n"HostileOpacityCurrent", HostileAction);    
            }

            if (Duration == -1)
            {
                System::ClearAndInvalidateTimerHandle(HidePathHandle);
            } 
            else 
            {
                HidePathHandle = System::SetTimer(this, n"HidePath", Duration, false);
            }

            //We can set our path to show a hostile action. 
            //PlayerPath.SetFloatParameter(n"CurrentPathOpacity", 0.7);    
            //PlayerPath.SetFloatParameter(n"RemainingPathOpacity", 0.4);    
        }
    }

    UFUNCTION(BlueprintPure)
    bool GetPathDrawParams(UTurnBasedMovementComponent&out MovementComp, FVector&out PathEndLocation, int&out Distance, int&out Days)
    {
        MovementComp = PlayerShip.GetComponentByClass(UTurnBasedMovementComponent);
        Distance = MovementComp.GetPathDistance();
        PathEndLocation = MovementComp.PathSpline.GetLocationAtDistanceAlongSpline(MovementComp.PathSpline.SplineLength, ESplineCoordinateSpace::World);
        Days = MovementComp.PathDurationInTurns();

        return Distance > 1;
    }

    UFUNCTION()
    void HidePath()
    {
        if (PlayerPath != nullptr)
        {
            PlayerPath.DestroyComponent();
        }
        TurnMarker.SetActorHiddenInGame(true);
    }

    UFUNCTION()
    void GoToRotatedLocation(FVector ClickStartLocation, FVector DragEndLocation)
    {
        if (!Cast<ATopDown_GameState>(Gameplay::GetGameState()).bIsGamePaused)
            return;

        FVector AdjustedLocation;
        int Distance, Days;
        MoveComp.SetRotatedPath(ClickStartLocation, DragEndLocation, Distance, Days, AdjustedLocation);
        DrawPath(MoveComp, AdjustedLocation, Distance, Days);
    }

    //purely for testing purposes, for firing ships
    UFUNCTION()
    AGameObject GetNearestSpaceShip(AGameObject ExcludeObject)
    {
        // Retrieve the active GameState cast to your custom state
        ATopDown_GameState GameState = Cast<ATopDown_GameState>(Gameplay::GetGameState());
        if (GameState == nullptr)
            return nullptr;

        // Get the owner or origin location for distance calculations
        // (Assuming this function is inside an Actor/Component; fallback to zero vector if needed)
        FVector SearchOrigin = GetOwner().ActorLocation;

        AGameObject NearestShip = nullptr;
        float MinDistanceSq = MAX_flt;

        // Iterate through all tracked game objects in the GameState
        for (AGameObject Obj : GameState.GameObjects)
        {
            if (Obj == nullptr || Obj == ExcludeObject)
                continue;

            // Verify object has the Ship tag
            if (Obj.ObjectType.MatchesTagExact(GameplayTags::GameObject_Ship))
            {
                // Use GetSquaredDistanceTo for performance (avoids square root overhead)
                float DistSq = SearchOrigin.DistSquared(Obj.GetActorLocation());
                if (DistSq < MinDistanceSq)
                {
                    MinDistanceSq = DistSq;
                    NearestShip = Obj;
                }
            }
        }

        return NearestShip;
    }
    
    //Select a weapon from 0 to 5 (up to 9 with stations)
    // true = list is not empty = start combat cursor mode
    // false = list is empty back to select cursor mode
    UFUNCTION()
    bool SelectWeapon(int WeaponIndex) {
        //toggle the selected index
        bool bToggledWeapon = false;
        switch (ShipComp.WeaponOrders[WeaponIndex].WeaponState)
        {
            case EWeaponState::Equipped:
            {
                ShipComp.WeaponOrders[WeaponIndex].WeaponState = EWeaponState::Pressed;
                bToggledWeapon = true;
                break;
            }
            case EWeaponState::Pressed:
            {
                ShipComp.WeaponOrders[WeaponIndex].WeaponState = EWeaponState::Equipped;
                bToggledWeapon = true;
                break;
            }
            default: break;
        }

        //Get our min and max weapon ranges
        int PressedWeapons = 0;
        TArray<int> SelectedWeapons;
        for (int32 i = 0; i < ShipComp.WeaponOrders.Num(); i++)
        {
            switch (ShipComp.WeaponOrders[i].WeaponState)
            {
                case EWeaponState::Pressed:
                {
                    PressedWeapons++;
                    SelectedWeapons.Add(i);
                    break;
                }
                default: break;
            }
        }

        if (!bToggledWeapon)
            return PressedWeapons > 0;

        // Update weapon range indicators based on selection count and ranges
        if (SelectedWeapons.Num() == 0)
        {
            WeaponMinRangeIndicator.SetIndicatorVisibility(false);
            WeaponMaxRangeIndicator.SetIndicatorVisibility(false);
            DamageFalloffIndicator.SetIndicatorVisibility(false);
            return false;
        }
        else if (SelectedWeapons.Num() == 1)
        {
            FGameplayTag SlotTag = GameLogic::GetWeaponSlot(SelectedWeapons[0]);
            
            float WeaponRange = ShipComp.GetWeaponRange(SlotTag) * 10;

            WeaponMinRangeIndicator.SetRadius(WeaponRange);
            WeaponMinRangeIndicator.SetIndicatorVisibility(true);

            DamageFalloffIndicator.SetRadius(WeaponRange + GameLogic::FalloffRange);
            DamageFalloffIndicator.SetIndicatorVisibility(true);

            WeaponMaxRangeIndicator.SetIndicatorVisibility(false);
        }
        else // 2 or more weapons selected
        {
            float GlobalMinRange = MAX_flt;
            float GlobalMaxRange = -1.0f;

            for (int Index : SelectedWeapons)
            {
                FGameplayTag SlotTag = GameLogic::GetWeaponSlot(Index);
                float WeaponRange = ShipComp.GetWeaponRange(SlotTag) * 10;

                if (WeaponRange < GlobalMinRange) GlobalMinRange = WeaponRange;
                if (WeaponRange > GlobalMaxRange) GlobalMaxRange = WeaponRange;
            }

            DamageFalloffIndicator.SetIndicatorVisibility(false);

            // If all selected weapons have identical ranges
            if (Math::Abs(GlobalMinRange - GlobalMaxRange) < 0.01f)
            {
                WeaponMinRangeIndicator.SetRadius(GlobalMinRange);
                WeaponMinRangeIndicator.SetIndicatorVisibility(true);

                WeaponMaxRangeIndicator.SetIndicatorVisibility(false);
            }
            else // Selected weapons have different ranges
            {
                WeaponMinRangeIndicator.SetRadius(GlobalMinRange);
                WeaponMinRangeIndicator.SetIndicatorVisibility(true);

                WeaponMaxRangeIndicator.SetRadius(GlobalMaxRange);
                WeaponMaxRangeIndicator.SetIndicatorVisibility(true);
            }
        }
        
        PickupRangeIndicator.SetIndicatorVisibility(false);
        RadarRangeIndicator.SetIndicatorVisibility(true);
        return true;
    }

    UFUNCTION()
    void DropFiringList()
    {
        for (int32 i = 0; i < ShipComp.WeaponOrders.Num(); i++)
        {
            //TODO: return to its default state which might not be equipped
            switch (ShipComp.WeaponOrders[i].WeaponState)
            {
                case EWeaponState::Pressed:
                {
                    ShipComp.WeaponOrders[i].WeaponState = EWeaponState::Equipped;
                    break;
                }
                default: break;
            }
        }
        // Hide all range indicators
        WeaponMinRangeIndicator.SetIndicatorVisibility(false);
        WeaponMaxRangeIndicator.SetIndicatorVisibility(false);
        DamageFalloffIndicator.SetIndicatorVisibility(false);
        RadarRangeIndicator.SetIndicatorVisibility(false);
    }

    
}