//Ideally create a few more like: On Landable Object, On Ship, On Loot
enum EInteractionResult {
        Invalid,
        OnActor,
        OnPlayfield,
        OnSelf,
        OnPlanet,
        OnStation,
        OnLoot
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


class UTopDownPlannerComponent : UActorComponent
{
    UPROPERTY() FVector PlayfieldLocation;
    UPROPERTY() FVector ScrollingLocation;
    
    UPROPERTY() AActor SelectedObject;
    UPROPERTY() AActor HoveredObject;

    UPROPERTY() AActor PlayerShip;
    UPROPERTY() UTurnBasedMovementComponent MoveComp;

    UPROPERTY() TArray<AActor> ActorsToIgnore; //Playfield and any helper actors that should not obstruct hovering
    UPROPERTY() TArray<AActor> Stars;

    UPROPERTY() bool bMultiWaypoint = false;
    UPROPERTY() float PathClickingDistance = 100;

    UPROPERTY() UNiagaraComponent PlayerPath;
    UPROPERTY() UNiagaraComponent HoveredPath;

    UPROPERTY() UNiagaraSystem PathTemplate;

    UPROPERTY() ETurnMovementType MovementType = ETurnMovementType::Fly;
    UPROPERTY() AActor LandingObject;
    UPROPERTY() ATurnMarker TurnMarker;
    //UPROPERTY() AActor smthelse
    private bool bHasResult;
    private FTimerHandle HidePathHandle;

    private FCollisionQueryParams Params;

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
    }

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaSeconds)
    {
        bHasResult = GameMath::GetPlayfieldLocation(Gameplay::GetPlayerController(0), PlayfieldLocation);
        GameMath::GetObjectAtCursorLocation(PlayfieldLocation, Params, HoveredObject);
        Print(f"{System::GetDisplayName(HoveredObject)}", 0);
    }

    UFUNCTION()
    EInteractionResult GetInteractedObject() {
        if (!bHasResult)
            return EInteractionResult::Invalid;

        if (HoveredObject == nullptr || Stars.Contains(HoveredObject))
            return EInteractionResult::OnPlayfield;

        if (HoveredObject == PlayerShip)
            return EInteractionResult::OnSelf;

        return EInteractionResult::OnActor;
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
            if (MoveComp.IsMoving())
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
            else 
            {
                if (GetOwner().ActorLocation.Distance(DestinationLocation) >= PathClickingDistance)
                {
                    if (MoveComp.QueuePathMidTurn(DestinationLocation, AdjustedLocation, Distance, Days))
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
        //Hide Path
    }

    //Duration -1 means we draw forever until there's a change
    UFUNCTION()
    void DrawPath(UTurnBasedMovementComponent MovementComponent, FVector AdjustedLocation, int Distance, int Days, bool UsePlayerPath=true, float Duration=-1)
    {
        if (UsePlayerPath)
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
            for (FVector Location : CurrentPath)
            {
                ShadowPath1.Add(FVector(Location.X, Location.Y, Location.Z - 1));
            }
            for (FVector Location : RemainingPath)
            {
                ShadowPath2.Add(FVector(Location.X, Location.Y, Location.Z - 1));
            }
            NiagaraDataInterfaceArray::SetNiagaraArrayVector(PlayerPath, n"ShadowPositions", ShadowPath1);
            NiagaraDataInterfaceArray::SetNiagaraArrayVector(PlayerPath, n"ShadowPositionsRemaining", ShadowPath2);

            if (MovementComponent.CheckpointDistances.Num() > 2)
            {
                PlayerPath.SetFloatParameter(n"HostileOpacityRemaining", 0.0);
            }
            else 
            {
                PlayerPath.SetFloatParameter(n"HostileOpacityCurrent", 0.0);    
            }

            if (Duration == -1)
            {
                System::ClearAndInvalidateTimerHandle(HidePathHandle);
            } 
            else 
            {
                HidePathHandle = System::SetTimer(this, n"HidePath", Duration, false);
            }

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
}