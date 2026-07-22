// TurnBasedMovementComponent.as
//
// Drives a ship along a USplineComponent for a WEGO turn-based game, and
// owns its tractor-beam pickup behaviour along the way.

// MOVEMENT
//   Movement is driven externally: ATopDown_GameState exposes
//   NormalizedTurnProgress (0..1 over TurnDuration), advanced by whatever
//   owns turn playback — not by this component's own DeltaTime. Tick() just
//   samples MovementCurve at the current progress and places the actor.
//   PrecomputeMovementCurve() builds that curve via
//   UPathingUtils::GetMovementCurve2(), blending from OriginalNominalSpeed —
//   read BEFORE StartMovement() overwrites it with this turn's own nominal
//   speed, so at precompute time it still holds LAST turn's speed. That's
//   what gives continuous cross-turn acceleration/deceleration without a
//   dedicated "previous speed" field.
//
//   Setup order per turn: SetNextPathSegment() -> PrecomputeMovementCurve()
//   -> OnTurnStart() (which itself calls StartMovement() and plans any
//   pickup stops). This component doesn't detect end-of-turn itself — no
//   OnMovementComplete event — the external turn driver reaching
//   NormalizedTurnProgress >= 1 is what ends a turn.
//
// PICKUP
//   PlanCollectionStops() scans registered PickupTargets against the
//   CURRENT path spline once per turn (from OnTurnStart()) and produces an
//   ordered TArray<FStopEvent>, each a cluster of nearby items reachable
//   from one stop point. While MovementState == StoppedForPickup, Tick()
//   claims tractor-beam slots up to MaxSimultaneousPickups and pulls items
//   in; normal spline sampling is skipped entirely. There's no easing to or
//   from a pickup stop by design — the ship holds position exactly where it
//   was, and resumes exactly where it left off: StoppedTimeEnd accumulates
//   how much NormalizedTurnProgress elapsed while stopped and is subtracted
//   back out when sampling the curve, so no curve rebuild is needed to
//   "pause" it.

event void FOnItemCollected(AActor CollectedItem, FGameItem Item);

enum EShipMovementState
{
    NoPathDefined,
    HasPathDefined,
    Moving,
    StoppedForPickup
}

struct FBeamState
{
    AActor Item = nullptr;
    int32 BeamIndex = 0;
}

struct FStopEvent
{
    float StopDistance = 0.0;
    FVector StopLocation = FVector::ZeroVector;
    TArray<AActor> PendingItems;
}

struct FTurnState
{
    TArray<FBeamState> ActiveBeams;
    TArray<AActor> BeamQueue;
    TArray<FStopEvent> RemainingPlan;
}

// Helper struct for internal calculation in PlanCollectionStops
struct FItemWindow
{
    AActor Item;
    float Entry;
    float Exit;
    float OptDist;

    int opCmp(const FItemWindow& Other) const
    {
        if (OptDist < Other.OptDist)
            return -1;
        if (OptDist > Other.OptDist)
            return 1;
        return 0;
    }
}

UCLASS()
class UTurnBasedMovementComponent : UActorComponent
{
    ATopDown_GameState CachedGameState;

    // ------------------------------------------------------------------
    // Movement
    // ------------------------------------------------------------------
    UPROPERTY() TArray<float32> CheckpointDistances;
    UPROPERTY() float CurrentSpeed = 5000.0;
    UPROPERTY() float ZLevel = 810.0;

    UPROPERTY() USplineComponent PathSpline;
    UPROPERTY() float StartDistance = 0.0;
    UPROPERTY() float EndDistance = 1000.0;

    UPROPERTY() EShipMovementState MovementState = EShipMovementState::NoPathDefined;
    private EShipMovementState PreviousMovementState = EShipMovementState::NoPathDefined;
    private UCurveFloat MovementCurve; // normTime [0,1] -> normDist [0,1]

    UPROPERTY() float OriginalNominalSpeed = 0.0;
    private float SegmentLength = 0.0;
    private float StoppedTimeStart, StoppedTimeEnd = 0;
    private FVector OriginalDirection = FVector::ZeroVector;

    // ------------------------------------------------------------------
    // Pickup
    // ------------------------------------------------------------------
    UPROPERTY()
    FTurnState CurrentTurnState;

    UPROPERTY(Category = "Pickup") float TractorBeamRadius = 750.0;
    UPROPERTY(Category = "Pickup") float TractorBeamPullSpeed = 500.0;
    UPROPERTY(Category = "Pickup") int32 MaxSimultaneousPickups = 1;
    UPROPERTY(Category = "Pickup") float ProximityAlpha = 0.4;

    private TArray<AActor> PickupTargets;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------
    UPROPERTY()
    FOnItemCollected OnItemCollected;

    // ==================================================================
    // Engine lifecycle
    // ==================================================================

    UFUNCTION(BlueprintOverride)
    void BeginPlay()
    {
        SetComponentTickEnabled(false);
        CachedGameState = Cast<ATopDown_GameState>(Gameplay::GetGameState());
    }

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaSeconds)
    {
        if (PathSpline == nullptr || MovementState == EShipMovementState::NoPathDefined)
            return;

        if (MovementState == EShipMovementState::StoppedForPickup)
        {
            TickPickup(DeltaSeconds);
            return;
        }

        if (MovementState != EShipMovementState::Moving)
            return;

        // --- Position update ---
        float NormDist  = MovementCurve.GetFloatValue(CachedGameState.NormalizedTurnProgress - StoppedTimeEnd);
        float WorldDist = StartDistance + NormDist * SegmentLength;
        Owner.SetActorLocation(PathSpline.GetLocationAtDistanceAlongSpline(WorldDist, ESplineCoordinateSpace::World));

        // --- Pickup: have we reached the next planned stop? ---
        if (CurrentTurnState.RemainingPlan.IsValidIndex(0))
        {
            float CurrentSplineDist = PathSpline.GetDistanceAlongSplineAtLocation(Owner.ActorLocation, ESplineCoordinateSpace::World);
            float TargetStopDist = CurrentTurnState.RemainingPlan[0].StopDistance;

            const float ArrivalTolerance = 15.0;
            if (Math::Abs(CurrentSplineDist - TargetStopDist) <= ArrivalTolerance || CurrentSplineDist >= TargetStopDist)
            {
                StopForPickup();
                ExecuteNextStop();
            }
        }
    }

    // ==================================================================
    // Turn lifecycle
    // ==================================================================

    UFUNCTION()
    bool SetNextPathSegment()
    {
        if (PathSpline == nullptr) return false;
        if (HasPathDefined())
        {
            CheckpointDistances.Empty();

            // TODO: If ship speed has changed, the path has to be rebuilt.
            // Bug: Recalculating the path can sometimes produce a very short segment
            // at the end of the path. Some path shortening must be done. Something
            // like <200 units.
            float CurrentDistance = PathSpline.GetDistanceAlongSplineAtLocation(Owner.ActorLocation, ESplineCoordinateSpace::World);
            CheckpointDistances.Add(CurrentDistance);
            for (float d = CurrentDistance + CurrentSpeed; d < PathSpline.GetSplineLength(); d += CurrentSpeed)
            {
                CheckpointDistances.Add(d);
            }
            CheckpointDistances.Add(PathSpline.GetSplineLength());

            StartDistance = CheckpointDistances[0];
            EndDistance   = CheckpointDistances[1];
            return true;
        }

        // Reached the end of the path or there is no path defined, we don't do anything
        StopMovement();
        CancelPath();
        return false;
    }

    UFUNCTION()
    void PrecomputeMovementCurve()
    {
        SegmentLength = EndDistance - StartDistance;
        if (SegmentLength <= KINDA_SMALL_NUMBER)
        {
            MovementState = EShipMovementState::NoPathDefined;
            return;
        }

        FPathProperties Path;
        Path.EaseFraction = 0.1;
        Path.SampleInterval = 100;
        MovementCurve = UPathingUtils::GetMovementCurve2(PathSpline, StartDistance, SegmentLength, CachedGameState.TurnDuration, OriginalNominalSpeed, Path);
    }

    UFUNCTION()
    void StartMovement()
    {
        bool bImmediatePickup = false;
        PlanCollectionStops(PickupTargets, bImmediatePickup);

        if (!HasPathDefined())
        {
            SetComponentTickEnabled(true);
            return;
        }

        PreviousMovementState = MovementState;
        MovementState = (bImmediatePickup) ? EShipMovementState::StoppedForPickup : EShipMovementState::Moving;
        OriginalNominalSpeed = (CachedGameState.TurnDuration > 0.0) ? (SegmentLength / CachedGameState.TurnDuration) : 0.0;
        OriginalDirection = PathSpline.GetDirectionAtDistanceAlongSpline(EndDistance, ESplineCoordinateSpace::World);
        StoppedTimeStart = 0.0;
        StoppedTimeEnd = 0.0;
        if (bImmediatePickup)
        {
            StopForPickup(true);
        }
        SetComponentTickEnabled(true);
    }

    UFUNCTION()
    void StopMovement()
    {
        PreviousMovementState = MovementState;
        MovementState = HasPathDefined() ? EShipMovementState::HasPathDefined : EShipMovementState::NoPathDefined;
        
        SetComponentTickEnabled(false);
    }

    UFUNCTION()
    void StopForPickup(bool bImmediateStop = false)
    {
        if (!IsMoving())
            return;

        StoppedTimeStart = CachedGameState.NormalizedTurnProgress;

        MovementState = EShipMovementState::StoppedForPickup;
    }

    UFUNCTION()
    void ResumeFromPickup()
    {
        if (!IsStoppedForPickup())
            return;

        StoppedTimeEnd = StoppedTimeEnd + CachedGameState.NormalizedTurnProgress - StoppedTimeStart;

        MovementState = EShipMovementState::Moving;
    }

    // ==================================================================
    // Queries
    // ==================================================================

    UFUNCTION(BlueprintPure)
    bool IsMoving() const
    {
        return MovementState == EShipMovementState::Moving;
    }

    UFUNCTION(BlueprintPure)
    bool IsStoppedForPickup() const
    {
        return MovementState == EShipMovementState::StoppedForPickup;
    }

    UFUNCTION()
    int32 PathDurationInTurns() const
    {
        return CheckpointDistances.Num() - 1;
    }

    float GetOriginalNominalSpeed() const
    {
        return OriginalNominalSpeed;
    }

    UFUNCTION(BlueprintPure)
    bool HasPathDefined() const
    {
        return CheckpointDistances.Num() >= 1 && CheckpointDistances.Last() - StartDistance > 1.0;
    }

    //Returns the world location of the current path's location at the end of the turn
    UFUNCTION(BlueprintPure)
    FVector GetPathEndOfTurnLocation()
    {
        return PathSpline.GetLocationAtDistanceAlongSpline(EndDistance, ESplineCoordinateSpace::World);
    }

    UFUNCTION(BlueprintPure)
    int GetPathDistance()
    {
        float ScaledDistance = Math::Min(PathSpline.GetSplineLength() - StartDistance, CurrentSpeed * CheckpointDistances.Num()) / 10.0;
        return Math::RoundToInt(ScaledDistance);
    }

    // ==================================================================
    // Path building
    // ==================================================================

    UFUNCTION()
    bool SetPath(FVector DestinationLocation, FVector &out AdjustedLocation, int32 &out Distance, int32 &out Days)
    {
        AdjustedLocation = FVector::ZeroVector;
        Distance = 0;
        Days = 0;

        if (PathSpline == nullptr)
        {
            Warning("TurnBasedMovementComponent::SetPath: PathSpline is null.");
            return false;
        }

        if (Owner == nullptr)
            return false;

        // All points are flattened to ZLevel so the path is always horizontal.
        FVector CurrentLocation = FVector(Owner.ActorLocation.X, Owner.ActorLocation.Y, ZLevel);
        FVector Destination     = FVector(DestinationLocation.X, DestinationLocation.Y, ZLevel);
        FVector ForwardVector   = OriginalDirection != FVector::ZeroVector ? OriginalDirection
            : FVector(Owner.ActorForwardVector.X, Owner.ActorForwardVector.Y, 0.0).GetSafeNormal();

        UPathingUtils::CreateNewPath(PathSpline, CurrentLocation, ForwardVector, ZLevel, Destination, 400.0, FPathProperties(), CurrentSpeed);

        float PathLength = PathSpline.GetSplineLength();

        CheckpointDistances.Empty();
        StartDistance = 0.0;
        EndDistance   = Math::Min(CurrentSpeed, PathLength);

        CheckpointDistances.Add(StartDistance);
        for (float d = CurrentSpeed; d < PathLength; d += CurrentSpeed)
        {
            CheckpointDistances.Add(d);
        }

        if (PathLength - CheckpointDistances.Last() > 10.0)
        {
            CheckpointDistances.Add(PathLength);
        }

        AdjustedLocation = PathSpline.GetLocationAtDistanceAlongSpline(PathSpline.GetSplineLength(), ESplineCoordinateSpace::World);
        float ScaledDistance = Math::Min(PathSpline.GetSplineLength() - StartDistance, CurrentSpeed * CheckpointDistances.Num()) / 10.0;
        Distance = Math::RoundToInt(ScaledDistance);
        Days = PathDurationInTurns();

        MovementState = EShipMovementState::HasPathDefined;
        return true;
    }

    //Use when turn is paused and we clicked ourselves or if an invalid equipment configuration made us unable to move
    UFUNCTION()
    void CancelPath()
    {
        StartDistance = 0.0;
        EndDistance   = 0.0;
        CheckpointDistances.Empty();
        OriginalDirection = FVector::ZeroVector;
        MovementState = EShipMovementState::NoPathDefined;
    }

    UFUNCTION()
    void CancelPathQueueing(FVector &out AdjustedLocation, int32 &out Distance, int32 &out Days)
    {
        AdjustedLocation = FVector::ZeroVector;
        Distance = 0;
        Days = 0;

        if (PathSpline == nullptr || Owner == nullptr)
            return;

        FVector EndPoint = PathSpline.GetLocationAtDistanceAlongSpline(EndDistance, ESplineCoordinateSpace::World);
        int32 SplitIdx = Math::RoundToInt(PathSpline.FindInputKeyClosestToWorldLocation(EndPoint));

        // Remove every point that exists AFTER our SplitIdx
        while (PathSpline.GetNumberOfSplinePoints() > SplitIdx + 1)
        {
            PathSpline.RemoveSplinePoint(PathSpline.GetNumberOfSplinePoints() - 1, false);
        }
        PathSpline.UpdateSpline();

        int32 DeletionIndex = -1;
        for (int32 i = 0; i < CheckpointDistances.Num(); i++)
        {
            // Use a slightly larger epsilon for the checkpoint search to avoid
            // double-adding the current turn
            if (CheckpointDistances[i] >= EndDistance - 0.1f)
            {
                DeletionIndex = i;
                break;
            }
        }

        if (DeletionIndex != -1)
        {
            CheckpointDistances.RemoveAt(DeletionIndex);
        }

        AdjustedLocation = PathSpline.GetLocationAtDistanceAlongSpline(PathSpline.GetSplineLength(), ESplineCoordinateSpace::World);
        float ScaledDistance = Math::Min(PathSpline.GetSplineLength() - StartDistance, CurrentSpeed * CheckpointDistances.Num()) / 10.0;
        Distance = Math::RoundToInt(ScaledDistance);
        Days = Math::CeilToInt(Distance * 1.0 / (CurrentSpeed / 10.0));
    }

    UFUNCTION()
    bool QueuePathMidTurn(FVector DestinationLocation, FVector &out AdjustedLocation, int&out Distance, int&out Days)
    {
        if (PathSpline == nullptr || Owner == nullptr)
            return false;

        if (MovementState == EShipMovementState::Moving)
        {
            float SampleDist = Math::Max(0.0, EndDistance - 0.1);
            FVector EndPoint = PathSpline.GetLocationAtDistanceAlongSpline(EndDistance, ESplineCoordinateSpace::World);
            FVector ForwardVector = PathSpline.GetDirectionAtDistanceAlongSpline(SampleDist, ESplineCoordinateSpace::World);
            FVector Destination = FVector(DestinationLocation.X, DestinationLocation.Y, ZLevel);

            // 1. TRUNCATE FIRST
            for (int i = PathSpline.GetNumberOfSplinePoints() - 1; i >= 0; i--)
            {
                if (PathSpline.GetDistanceAlongSplineAtSplinePoint(i) > EndDistance + 0.5)
                {
                    PathSpline.RemoveSplinePoint(i, false);
                }
            }
            PathSpline.UpdateSpline();

            // 2. ADD OR REUSE ANCHOR (Shared Point)
            int AnchorIdx = PathSpline.GetNumberOfSplinePoints() - 1;
            float TailDist = PathSpline.GetDistanceAlongSplineAtSplinePoint(AnchorIdx);

            if (Math::Abs(TailDist - EndDistance) > 0.1)
            {
                PathSpline.AddSplinePoint(EndPoint, ESplineCoordinateSpace::World, false);
                AnchorIdx = PathSpline.GetNumberOfSplinePoints() - 1;
            }
            else
            {
                PathSpline.SetLocationAtSplinePoint(AnchorIdx, EndPoint, ESplineCoordinateSpace::World, false);
            }

            // 3. FIX THE "HANDOVER" SEGMENT (Point before Anchor -> Anchor)
            if (AnchorIdx > 0)
            {
                int32 PrevIdx = AnchorIdx - 1;
                FVector PrevLoc = PathSpline.GetLocationAtSplinePoint(PrevIdx, ESplineCoordinateSpace::World);
                float HandoverDist = PrevLoc.Distance(EndPoint);
                FVector HandoverDir = (EndPoint - PrevLoc).GetSafeNormal();

                // Fix Leave Tangent of the point BEFORE the shared point
                PathSpline.SetTangentsAtSplinePoint(PrevIdx,
                    PathSpline.GetArriveTangentAtSplinePoint(PrevIdx, ESplineCoordinateSpace::World),
                    HandoverDir * HandoverDist,
                    ESplineCoordinateSpace::World, false);

                // Fix Arrive Tangent of the SHARED point (Point 0 of the turn)
                PathSpline.SetTangentsAtSplinePoint(AnchorIdx,
                    HandoverDir * HandoverDist,
                    PathSpline.GetLeaveTangentAtSplinePoint(AnchorIdx, ESplineCoordinateSpace::World),
                    ESplineCoordinateSpace::World, false);
            }

            PathSpline.UpdateSpline();
            //4. Compensate for the fact that we may delete some points in between the curve to maintain the 4 +3n point count
            PadSplineToFormula(AnchorIdx);
            // 5. APPEND THE NEW PATH
            UPathingUtils::AddPointsToPath(PathSpline, EndPoint, ForwardVector, Destination,
                 400.0, EndDistance, ZLevel, CurrentSpeed, FPathProperties());


            float PathLength = PathSpline.GetSplineLength();
            float StartingDistance = CheckpointDistances[0];
            float EndingDistance = EndDistance;

            CheckpointDistances.Empty();
            CheckpointDistances.Add(StartingDistance);
            CheckpointDistances.Add(EndingDistance);
            for (float d = EndDistance + CurrentSpeed; d < PathLength; d += CurrentSpeed)
            {
                CheckpointDistances.Add(d);
            }

            if (PathLength - CheckpointDistances.Last() >= 10.0)
            {
                CheckpointDistances.Add(PathLength);
            }

            AdjustedLocation = PathSpline.GetLocationAtDistanceAlongSpline(PathSpline.GetSplineLength(), ESplineCoordinateSpace::World);
            float RemainingLen = PathSpline.GetSplineLength() - EndDistance;
            Distance = Math::RoundToInt(RemainingLen / 10.0);
            Days = PathDurationInTurns();

            return true;
        }

        SetPath(DestinationLocation, AdjustedLocation, Distance, Days);
        return true;
    }

    UFUNCTION()
    bool SetRotatedPath(FVector StartLocation, FVector DragEndLocation, int32 &out Distance, int32 &out Days, FVector &out AdjustedLocation)
    {
        Distance = 0;
        Days = 0;
        AdjustedLocation = FVector::ZeroVector;

        if (PathSpline == nullptr || Owner == nullptr)
            return false;

        FVector StartPos = FVector(Owner.ActorLocation.X, Owner.ActorLocation.Y, ZLevel);
        FVector StartDir = FVector(Owner.ActorForwardVector.X, Owner.ActorForwardVector.Y, 0.0).GetSafeNormal();
        FVector EndPos = FVector(StartLocation.X, StartLocation.Y, ZLevel);
        FVector EndDir = (DragEndLocation - StartLocation).GetSafeNormal();

        TArray<FPathPoint> Points = UPathingUtils::BuildRotatedDubinsPath(StartPos, StartDir, EndPos, EndDir, CurrentSpeed, ZLevel, FPathProperties());

        PathSpline.ClearSplinePoints(false);
        PathSpline.SetDefaultUpVector(FVector(0.0, 0.0, 1.0), ESplineCoordinateSpace::World);

        for (int32 p = 0; p < Points.Num(); p++)
        {
            // Add point without updating yet
            PathSpline.AddSplinePoint(Points[p].Location, ESplineCoordinateSpace::World, false);
            PathSpline.SetSplinePointType(p, ESplinePointType::CurveCustomTangent, false);

            // Apply Arrive and Leave tangents separately
            PathSpline.SetTangentsAtSplinePoint(p, Points[p].ArriveTangent, Points[p].LeaveTangent, ESplineCoordinateSpace::World, false);
        }

        PathSpline.UpdateSpline();

        float PathLength = PathSpline.GetSplineLength();
        CheckpointDistances.Empty();
        StartDistance = 0.0;
        EndDistance   = Math::Min(CurrentSpeed, PathLength);

        CheckpointDistances.Add(StartDistance);
        for (float d = CurrentSpeed; d < PathLength; d += CurrentSpeed)
        {
            CheckpointDistances.Add(d);
        }

        if (PathLength - CheckpointDistances.Last() > 10.0)
        {
            CheckpointDistances.Add(PathLength);
        }

        AdjustedLocation = PathSpline.GetLocationAtDistanceAlongSpline(PathSpline.GetSplineLength(), ESplineCoordinateSpace::World);
        float ScaledDistance = Math::Min(PathSpline.GetSplineLength() - StartDistance, CurrentSpeed * CheckpointDistances.Num()) / 10.0;
        Distance = Math::RoundToInt(ScaledDistance);
        Days = Math::CeilToInt((float(Distance) - 1.0) / (CurrentSpeed / 10.0));

        MovementState = EShipMovementState::HasPathDefined;
        return true;
    }

    bool SetNewWaypoint(const FVector DestinationLocation, FVector&out AdjustedLocation, int32&out Distance, int32&out Days)
    {
        if (PathSpline == nullptr || Owner == nullptr)
                return false;

        const FVector CurrentLocation = PathSpline.GetLocationAtDistanceAlongSpline(PathSpline.GetSplineLength(), ESplineCoordinateSpace::World);
        const FVector Destination     = FVector(DestinationLocation.X, DestinationLocation.Y, ZLevel);
        const FVector ForwardVector   = PathSpline.GetDirectionAtDistanceAlongSpline(PathSpline.GetSplineLength(), ESplineCoordinateSpace::World);

        //2xMaxR is the minimum distance required for a new waypoint
        if (!(DestinationLocation.Distance(CurrentLocation) * 0.5f > FPathProperties().DubinsTurnRadius + CurrentSpeed / 50.f))
            return false;

        bool AdjustedPath = UPathingUtils::AddPointsToPath(PathSpline, CurrentLocation, ForwardVector, Destination, 400, EndDistance, ZLevel, CurrentSpeed, FPathProperties());
        const float PathLength = PathSpline.GetSplineLength();

        CheckpointDistances.Empty();

        float CurrentDistance = PathSpline.GetDistanceAlongSplineAtLocation(GetOwner().ActorLocation, ESplineCoordinateSpace::World);
        CheckpointDistances.Add(CurrentDistance);
        for (float d = CurrentDistance + CurrentSpeed; d < PathSpline.GetSplineLength(); d += CurrentSpeed)
        {
            CheckpointDistances.Add(d);
        }

        if (PathLength - CheckpointDistances.Last() > 10.f)
        {
            CheckpointDistances.Add(PathLength);
        }
        AdjustedLocation = PathSpline.GetLocationAtDistanceAlongSpline(PathSpline.GetSplineLength(), ESplineCoordinateSpace::World);
        const float ScaledDistance = Math::Min((PathSpline.GetSplineLength() - StartDistance), CurrentSpeed * CheckpointDistances.Num()) / 10.f;
        Distance = Math::RoundToInt(ScaledDistance);
        Days = PathDurationInTurns();

        return true;
    }

    // ==================================================================
    // Pickup target API
    // ==================================================================

    UFUNCTION(BlueprintCallable, Category = "Pickup")
    void AddPickupTarget(AActor ItemActor)
    {
        if (ItemActor == nullptr)
            return;

        ULootComponent PC = ItemActor.GetComponentByClass(ULootComponent);
        if (PC == nullptr || PC.IsCollected())
            return;

        if (PickupTargets.Contains(ItemActor))
            return;

        PickupTargets.Add(ItemActor);
        PC.OnItemPickedUp.AddUFunction(this, n"HandleItemPickedUp");
        ItemActor.OnDestroyed.AddUFunction(this, n"HandleItemDestroyed");
    }

    UFUNCTION(BlueprintCallable, Category = "Pickup")
    void RemovePickupTarget(AActor ItemActor)
    {
        if (ItemActor != nullptr)
            UnregisterTarget(ItemActor, true);
    }

    UFUNCTION(BlueprintCallable, Category = "Pickup")
    void ClearAllPickupTargets()
    {
        TArray<AActor> Copy = PickupTargets;
        for (AActor Target : Copy)
        {
            if (Target != nullptr)
                UnregisterTarget(Target, true);
        }
        PickupTargets.Empty();
    }

    private FVector GetItemLocation(AActor ItemActor)
    {
        return FVector(ItemActor.GetActorLocation().X, ItemActor.GetActorLocation().Y, ZLevel);
    }

    UFUNCTION(BlueprintCallable, Category = "Pickup")
    void PlanCollectionStops(const TArray<AActor>& CandidateItems, bool& bImmediatePickup)
    {
        bImmediatePickup = false;

        TArray<FItemWindow> ReachableWindows;
        CurrentTurnState.RemainingPlan.Empty();

        if (CandidateItems.Num() > 0 && PathSpline != nullptr)
        {
            // 1. Identify Reachable Windows
            for (AActor Item : CandidateItems)
            {
                if (Item == nullptr) continue;

                FVector ItemLoc = GetItemLocation(Item);
                float DistAtClosest = GetClosestSplineDist(ItemLoc);
                float ActualDist = ItemLoc.Distance(PathSpline.GetLocationAtDistanceAlongSpline(DistAtClosest, ESplineCoordinateSpace::World));

                if (ActualDist <= TractorBeamRadius)
                {
                    float HalfWindow = Math::Sqrt(Math::Square(TractorBeamRadius) - Math::Square(ActualDist));

                    FItemWindow Win;
                    Win.Item = Item;
                    Win.Entry = DistAtClosest - HalfWindow;
                    Win.Exit = DistAtClosest + HalfWindow;
                    Win.OptDist = DistAtClosest;

                    ReachableWindows.Add(Win);
                }
            }

            // Sort upcoming windows linearly along the spline track
            ReachableWindows.Sort();

            // 2. Dynamic Cluster Thresholding using Ship Speed vs. Pull Speed
            TArray<FStopEvent> BuiltStops;
            FStopEvent CurrentStop;
            float CurrentExt = 0.0;
            float CurrentEnt = 0.0;

            const float DynamicMaxSpan = ProximityAlpha * TractorBeamRadius;

            for (int32 i = 0; i < ReachableWindows.Num(); i++)
            {
                FItemWindow Win = ReachableWindows[i];

                if (CurrentStop.PendingItems.Num() == 0)
                {
                    CurrentStop.PendingItems.Add(Win.Item);
                    CurrentEnt = Win.Entry;
                    CurrentExt = Win.Exit;
                }
                else
                {
                    float NextEnt = Math::Max(CurrentEnt, Win.Entry);
                    float NextExt = Math::Min(CurrentExt, Win.Exit);

                    bool bWindowsOverlap = (NextEnt <= NextExt);

                    // OptLSpan calculation relative to cluster head
                    float GroupStartOptDist = GetClosestSplineDist(GetItemLocation(CurrentStop.PendingItems[0]));
                    float OptLSpan = Win.OptDist - GroupStartOptDist;

                    if (bWindowsOverlap && (OptLSpan <= DynamicMaxSpan))
                    {
                        CurrentStop.PendingItems.Add(Win.Item);
                        CurrentEnt = NextEnt;
                        CurrentExt = NextExt;
                    }
                    else
                    {
                        // Commit current cluster
                        CurrentStop.StopDistance = Math::Max((CurrentEnt + CurrentExt) / 2.0, 0.0);
                        CurrentStop.StopLocation = PathSpline.GetLocationAtDistanceAlongSpline(CurrentStop.StopDistance, ESplineCoordinateSpace::World);
                        BuiltStops.Add(CurrentStop);

                        // Initialize a new cluster
                        CurrentStop.PendingItems.Empty();
                        CurrentStop.PendingItems.Add(Win.Item);
                        CurrentEnt = Win.Entry;
                        CurrentExt = Win.Exit;
                    }
                }
            }

            if (CurrentStop.PendingItems.Num() > 0)
            {
                CurrentStop.StopDistance = (CurrentEnt + CurrentExt) / 2.0;
                CurrentStop.StopLocation = PathSpline.GetLocationAtDistanceAlongSpline(CurrentStop.StopDistance, ESplineCoordinateSpace::World);
                BuiltStops.Add(CurrentStop);
            }

            // 3. LPT Sort inside stops
            for (FStopEvent& Stop : BuiltStops)
            {
                UGameUtility::SortActorsOnDistance(Stop.PendingItems, Stop.StopLocation);
                CurrentTurnState.RemainingPlan.Add(Stop);
            }

            // 4. Immediate pickup evaluation
            if (CurrentTurnState.RemainingPlan.Num() > 0)
            {
                const float CurrentShipDist = GetShipSplineDist();
                const float FirstStopDist = CurrentTurnState.RemainingPlan[0].StopDistance;

                const float ImmediatePickupTolerance = 5.0;
                bImmediatePickup = (FirstStopDist <= CurrentShipDist + ImmediatePickupTolerance);
            }
        }
    }

    UFUNCTION(BlueprintPure, Category = "Pickup")
    TArray<AActor> GetPickupTargets() const
    {
        return PickupTargets;
    }

    UFUNCTION(BlueprintCallable, Category = "Pickup")
    TArray<FVector> GetPlannedStopLocations() const
    {
        TArray<FVector> Locations;
        Locations.Reserve(CurrentTurnState.RemainingPlan.Num());

        for (const FStopEvent& Stop : CurrentTurnState.RemainingPlan)
        {
            Locations.Add(Stop.StopLocation);
        }

        return Locations;
    }

    // ==================================================================
    // Reactive event handlers
    // ==================================================================

    UFUNCTION()
    private void HandleItemPickedUp(AActor LootObject, FGameItem Item)
    {
        if (LootObject == nullptr)
            return;

        UnregisterTarget(LootObject, false);
        OnItemCollected.Broadcast(LootObject, Item);
        CachedGameState.GameObjects.Remove(Cast<AGameObject>(LootObject));
        //TODO: Inventory transfer functionality
        LootObject.DestroyActor();

        if (IsStoppedForPickup() && CurrentTurnState.ActiveBeams.Num() == 0 && CurrentTurnState.BeamQueue.Num() == 0)
        {
            ResumeFromPickup();
        }
    }

    UFUNCTION()
    private void HandleItemDestroyed(AActor DestroyedActor)
    {
        if (DestroyedActor == nullptr)
            return;

        ULootComponent PC = DestroyedActor.GetComponentByClass(ULootComponent);
        if (PC != nullptr)
        {
            PC.ReleasePullerClaim(Owner);
            PC.OnItemPickedUp.UnbindObject(this);
        }

        PickupTargets.Remove(DestroyedActor);

        if (IsStoppedForPickup() && CurrentTurnState.ActiveBeams.Num() == 0 && CurrentTurnState.BeamQueue.Num() == 0)
        {
            ResumeFromPickup();
        }
    }

    // ==================================================================
    // Private helpers
    // ==================================================================

    private void TickPickup(float DeltaTime)
    {
        const FVector ShipLoc = Owner.ActorLocation;

        // 1. Initial configuration when a planned stop is hit and beams are clean
        if (CurrentTurnState.ActiveBeams.Num() == 0 && CurrentTurnState.BeamQueue.Num() == 0)
        {
            if (CurrentTurnState.RemainingPlan.Num() > 0)
            {
                ExecuteNextStop(); // Transfers the pre-sorted items to CurrentTurnState.BeamQueue
            }
            else
            {
                ResumeFromPickup();
                return;
            }
        }

        // 2. Dynamic Slot Maintenance: Fill available beam slots
        while (CurrentTurnState.ActiveBeams.Num() < MaxSimultaneousPickups && CurrentTurnState.BeamQueue.Num() > 0)
        {
            AActor CandidateItem = CurrentTurnState.BeamQueue[0];
            CurrentTurnState.BeamQueue.RemoveAt(0);

            if (CandidateItem == nullptr) continue;

            ULootComponent PickupComp = CandidateItem.GetComponentByClass(ULootComponent);
            if (PickupComp != nullptr && PickupComp.bCanBePickedUp && !PickupComp.IsCollected())
            {
                float Dist = GetItemLocation(CandidateItem).Distance(ShipLoc);
                float Score = (Dist > 0.1) ? (TractorBeamPullSpeed / (Dist * Dist)) : TractorBeamPullSpeed;

                if (PickupComp.TryClaimAsPuller(Owner, Score))
                {
                    int32 TargetSlotIndex = 0;
                    TArray<int32> TakenSlots;
                    for (const FBeamState& B : CurrentTurnState.ActiveBeams)
                        TakenSlots.Add(B.BeamIndex);

                    while (TakenSlots.Contains(TargetSlotIndex))
                    {
                        TargetSlotIndex++;
                    }

                    LaunchBeam(CandidateItem, TargetSlotIndex);
                }
                else
                {
                    PickupComp.ReleasePullerClaim(Owner);
                }
            }
        }

        // 3. Process Active Concurrently Claimed Beams
        for (int32 i = CurrentTurnState.ActiveBeams.Num() - 1; i >= 0; i--)
        {
            FBeamState& Beam = CurrentTurnState.ActiveBeams[i];

            if (Beam.Item == nullptr)
            {
                CurrentTurnState.ActiveBeams.RemoveAt(i);
                continue;
            }

            ULootComponent PickupComp = Beam.Item.GetComponentByClass(ULootComponent);
            if (PickupComp == nullptr || PickupComp.IsCollected() || !PickupComp.bCanBePickedUp)
            {
                if (PickupComp != nullptr)
                    PickupComp.ReleasePullerClaim(Owner);
                CurrentTurnState.ActiveBeams.RemoveAt(i);
                continue;
            }

            bool bCollected = PickupComp.UpdatePullMovement(Owner, ShipLoc, TractorBeamPullSpeed, DeltaTime);

            if (bCollected)
            {
                PickupComp.ReleasePullerClaim(Owner);
                CurrentTurnState.ActiveBeams.RemoveAt(i);
            }
        }

        // End stop criteria check
        if (CurrentTurnState.ActiveBeams.Num() == 0 && CurrentTurnState.BeamQueue.Num() == 0)
        {
            ResumeFromPickup();
        }
    }

    private void ExecuteNextStop()
    {
        if (CurrentTurnState.RemainingPlan.Num() == 0) return;

        FStopEvent NextStop = CurrentTurnState.RemainingPlan[0];
        CurrentTurnState.RemainingPlan.RemoveAt(0);

        // Stage all planned items for this stop into the tracking queue
        CurrentTurnState.BeamQueue = NextStop.PendingItems;
        CurrentTurnState.ActiveBeams.Empty();
    }

    private void UnregisterTarget(AActor ItemActor, const bool bReleaseClaim)
    {
        if (ItemActor == nullptr)
            return;

        ULootComponent PC = ItemActor.GetComponentByClass(ULootComponent);
        if (PC != nullptr)
        {
            if (bReleaseClaim)
                PC.ReleasePullerClaim(Owner);
            PC.OnItemPickedUp.UnbindObject(this);
        }

        ItemActor.OnDestroyed.UnbindObject(this);
        PickupTargets.Remove(ItemActor);
    }

    private void LaunchBeam(AActor Item, int32 BeamIndex)
    {
        if (Item == nullptr) return;

        FBeamState NewBeam;
        NewBeam.Item = Item;
        NewBeam.BeamIndex = BeamIndex;

        CurrentTurnState.ActiveBeams.Add(NewBeam);
    }

    private float GetShipSplineDist() const
    {
        if (Owner == nullptr || PathSpline == nullptr)
            return -1.0;

        const FVector Closest = PathSpline.FindLocationClosestToWorldLocation(
            Owner.ActorLocation, ESplineCoordinateSpace::World);
        return PathSpline.GetDistanceAlongSplineAtLocation(Closest, ESplineCoordinateSpace::World);
    }

    private float GetClosestSplineDist(const FVector& ItemLocation) const
    {
        if (PathSpline == nullptr)
            return -1.0;

        const FVector Closest = PathSpline.FindLocationClosestToWorldLocation(
            ItemLocation, ESplineCoordinateSpace::World);
        return PathSpline.GetDistanceAlongSplineAtLocation(Closest, ESplineCoordinateSpace::World);
    }

    //attempt to fix
    private void PadSplineToFormula(int&out AnchorIdx)
    {
        int CurrentCount = PathSpline.GetNumberOfSplinePoints();
        int DummyCount = (((1 - CurrentCount) % 3) + 3) % 3;
        if (DummyCount <= 0)
            return;

        FVector AnchorLoc    = PathSpline.GetLocationAtSplinePoint(AnchorIdx, ESplineCoordinateSpace::World);
        FVector AnchorArrive = PathSpline.GetArriveTangentAtSplinePoint(AnchorIdx, ESplineCoordinateSpace::World);

        PathSpline.RemoveSplinePoint(AnchorIdx, false);

        for (int32 i = 0; i < DummyCount; i++)
        {
            PathSpline.AddSplinePoint(AnchorLoc, ESplineCoordinateSpace::World, false);
            int32 NewIdx = PathSpline.GetNumberOfSplinePoints() - 1;
            PathSpline.SetSplinePointType(NewIdx, ESplinePointType::Linear, false);
            //PathSpline.SetTangentsAtSplinePoint(NewIdx, FVector::ZeroVector, FVector::ZeroVector, ESplineCoordinateSpace::World, false);
        }

        PathSpline.AddSplinePoint(AnchorLoc, ESplineCoordinateSpace::World, false);
        AnchorIdx = PathSpline.GetNumberOfSplinePoints() - 1;
        PathSpline.SetSplinePointType(AnchorIdx, ESplinePointType::Linear, false);
        //PathSpline.SetTangentsAtSplinePoint(AnchorIdx, AnchorArrive, FVector::ZeroVector, ESplineCoordinateSpace::World, false);

        PathSpline.UpdateSpline();
    }
}
