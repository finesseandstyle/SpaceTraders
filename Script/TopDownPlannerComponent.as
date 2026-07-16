//Ideally create a few more like: On Landable Object, On Ship, On Loot
enum EInteractionResult {
        Invalid,
        OnActor,
        OnPlayfield,
        OnSelf
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

    UPROPERTY() TArray<AActor> ActorsToIgnore; //Playfield and any helper actors that should not obstruct hovering
    UPROPERTY() TArray<AActor> Stars;

    UPROPERTY() bool bMultiWaypoint = false;
    UPROPERTY() float PathClickingDistance = 100;

    UPROPERTY() UNiagaraComponent PlayerPath;
    UPROPERTY() UNiagaraComponent HoveredPath;

    UPROPERTY() UNiagaraSystem PathTemplate;
    //UPROPERTY() AActor smthelse
    private bool bHasResult;

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
        //
        if (PathTemplate != nullptr)
        {
            PlayerPath = Niagara::SpawnSystemAtLocation(PathTemplate, FVector(3000, 2000, 1100));
        }
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
        UTurnBasedMovementComponent MoveComp = PlayerShip.GetComponentByClass(UTurnBasedMovementComponent);
        FVector AdjustedLocation;
        int Distance, Days;
        if (Cast<ATopDown_GameState>(Gameplay::GetGameState()).bIsGamePaused)
        {
            if (bMultiWaypoint && MoveComp.HasPathDefined())
            {
                if (MoveComp.SetNewWaypoint(DestinationLocation, AdjustedLocation, Distance, Days))
                {
                    //Update Path Marker and Draw the Path
                    DrawPath(MoveComp);
                    Print("Add Waypoint");
                }
            }
            else 
            {
                if (MoveComp.SetPath(DestinationLocation, AdjustedLocation, Distance, Days))
                {
                    //Update Path Marker and Draw the Path, Show Path
                    DrawPath(MoveComp);
                    Print("New Path");
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
                        //Update Path Marker Redraw path
                        DrawPath(MoveComp);
                        Print("Queue path mid turn");
                    }
                }
                else
                {
                    //Update Path Marker Redraw path
                    DrawPath(MoveComp);
                    Print("Cancel Path Queueing");
                }
            }
            else 
            {
                if (GetOwner().ActorLocation.Distance(DestinationLocation) >= PathClickingDistance)
                {
                    if (MoveComp.QueuePathMidTurn(DestinationLocation, AdjustedLocation, Distance, Days))
                    {
                        //Update Path Marker Redraw path
                        DrawPath(MoveComp);
                        Print("Queue path mid turn");
                    }
                }
                else 
                {
                    MoveComp.CancelPath();
                    //Hide path
                    if (PlayerPath != nullptr)
                    {
                        DestroyComponent(PlayerPath);
                    }
                    Print("Cancel Path");
                }
            }

        }
    }

    UFUNCTION()
    void CancelPath()
    {        
        UTurnBasedMovementComponent MoveComp = PlayerShip.GetComponentByClass(UTurnBasedMovementComponent);
        MoveComp.CancelPath();
        if (PlayerPath != nullptr)
        {
            PlayerPath.DestroyComponent();
        }
        //Hide Path
    }

    UFUNCTION()
    void DrawPath(UTurnBasedMovementComponent MoveComp, bool UsePlayerPath=true)
    {
        if (UsePlayerPath)
        {
            TArray<FVector> CurrentPath, RemainingPath, TraversedPath, Checkpoints, ShadowPath1, ShadowPath2;
            UPathingUtils::GetPathSamples(MoveComp.PathSpline, MoveComp.CheckpointDistances, MoveComp.StartDistance, 
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

            if (MoveComp.CheckpointDistances.Num() > 2)
            {
                PlayerPath.SetFloatParameter(n"HostileOpacityRemaining", 0.0);
            }
            else 
            {
                PlayerPath.SetFloatParameter(n"HostileOpacityCurrent", 0.0);    
            }
            //PlayerPath.SetFloatParameter(n"CurrentPathOpacity", 0.7);    
            //PlayerPath.SetFloatParameter(n"RemainingPathOpacity", 0.4);    
        }
    }
}