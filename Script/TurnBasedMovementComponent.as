/**
 * Drives an actor along a USplineComponent over a fixed duration, guaranteeing
 * checkpoint arrival regardless of speed variation along the path.
 *
 * HOW IT WORKS (Time Remapping):
 *   UPathingUtils::GetMovementCurve() samples curvature at evenly-spaced
 *   world-distance intervals along [StartDistance, EndDistance], builds a
 *   speed-weight profile, integrates it into a cumulative-distance array, and
 *   pairs it with uniform time samples to produce a normTime -> normDist
 *   UCurveFloat (RCIM_Linear internally).
 *
 *   Runtime tick:
 *       normDist = GameState.NormalizedTurnProgress
 *       position = PathSpline.GetLocationAtDistanceAlongSpline(StartDistance + normDist * SegmentLength)
 *
 *   The curve always ends at (1,1) so checkpoint arrival is guaranteed.
 *
 * PICKUP STOPS:
 *   StopForPickup() eases the ship to a halt and begins accumulating stopped
 *   time. ResumeFromPickup() eases it back up to speed and rebuilds the curve
 *   so the new EndDistance reflects the time lost while stopped. The ship
 *   never jumps — it resumes from exactly where it stopped.
 *   If the turn ends while stopped, OnMovementComplete does NOT fire; the
 *   ship simply remains at its current position until the next turn.
 *
 * NETWORKING:
 *   Fully deterministic — same spline data produces the same curve on every
 *   client. No per-frame replication required.
 */
UENUM()
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
};

struct FStopEvent
{
    float StopDistance = 0.0;
    FVector StopLocation = FVector::ZeroVector;
    TArray<AActor> PendingItems;
};

struct FTurnState
{
    TArray<FBeamState> ActiveBeams;
    TArray<AActor> BeamQueue;
    TArray<FStopEvent> RemainingPlan;
};

// Helper struct for internal calculation in PlanCollectionStops
struct FItemWindow
{
    AActor Item;
    float Entry;
    float Exit;
    float OptDist;
};

UCLASS()
class UTurnBasedMovementComponent : UActorComponent
{

    // MOVEMENT
    UPROPERTY() TArray<float32> CheckpointDistances;
    UPROPERTY() float CurrentSpeed = 5000.0;
    UPROPERTY() float ZLevel = 810.0;

    UPROPERTY() USplineComponent PathSpline;
    UPROPERTY() float StartDistance = 0.0;
    UPROPERTY() float EndDistance = 1000.0;

    UPROPERTY() EShipMovementState MovementState = EShipMovementState::NoPathDefined;
    private UCurveFloat MovementCurve; // normTime [0,1] -> normDist [0,1]

    UPROPERTY() float OriginalNominalSpeed = 0.0; 
    private float SegmentLength = 0.0;
    private float StoppedTimeStart, StoppedTimeEnd = 0;

    // Pickup related things
    private FVector OriginalDirection = FVector::ZeroVector;

    ATopDown_GameState CachedGameState; 

    // PICKUPS
    UPROPERTY() float TractorBeamRadius = 750.0;
    UPROPERTY() float TractorBeamPullSpeed = 1000.0;

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
            // Logic for claiming Items
            return;
        }

        // Normal movement — evaluate the main curve
        float NormDist  = MovementCurve.GetFloatValue(CachedGameState.NormalizedTurnProgress - StoppedTimeEnd);
        float WorldDist = StartDistance + NormDist * SegmentLength;

        Owner.SetActorLocation(PathSpline.GetLocationAtDistanceAlongSpline(WorldDist, ESplineCoordinateSpace::World));
    }

    UFUNCTION()
    bool SetNextPathSegment()
    {
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
        if (PathSpline == nullptr)
        {
            Warning("TurnBasedMovementComponent: PathSpline is null.");
            MovementState = EShipMovementState::NoPathDefined;
            return;
        }

        SegmentLength = EndDistance - StartDistance;
        if (SegmentLength <= KINDA_SMALL_NUMBER)
        {
            Warning("TurnBasedMovementComponent: Segment length is zero or negative (" + SegmentLength + ").");
            MovementState = EShipMovementState::NoPathDefined;
            return;
        }

        //Print(f"Current Nominal Speed: {SegmentLength / CachedGameState.TurnDuration} - Previous Nominal Speed: {OriginalNominalSpeed}", 2);
        FPathProperties Path;
        Path.EaseFraction = 0.1;
        Path.SampleInterval = 100;
        MovementCurve = UPathingUtils::GetMovementCurve2(PathSpline, StartDistance, SegmentLength, CachedGameState.TurnDuration, OriginalNominalSpeed, Path);
        //MovementCurve = UPathingUtils::GetMovementCurve(PathSpline, 0, 0, StartDistance, SegmentLength, FPathProperties());

        MovementState = (MovementCurve == nullptr) ? EShipMovementState::NoPathDefined : MovementState;
    }

    UFUNCTION()
    void StartMovement()
    {
        if (!HasPathDefined())
            return;

        MovementState = EShipMovementState::Moving; //watch out for frame 0 item pickup this could be set to stopped for pickup.
        SetComponentTickEnabled(true);
        OriginalNominalSpeed = (CachedGameState.TurnDuration > 0.0) ? (SegmentLength / CachedGameState.TurnDuration) : 0.0;
        OriginalDirection = PathSpline.GetDirectionAtDistanceAlongSpline(EndDistance, ESplineCoordinateSpace::World);
        StoppedTimeStart = 0.0;
        StoppedTimeEnd = 0.0;
    }

    UFUNCTION()
    void StopMovement()
    {
        MovementState = HasPathDefined() ? EShipMovementState::HasPathDefined : EShipMovementState::NoPathDefined;
        SetComponentTickEnabled(false);
    }

    // ==================================================================
    // Pickup stops
    //
    // Records the position and speed at the moment of stop — does NOT rebuild
    // the main MovementCurve or modify StartDistance / EndDistance /
    // CachedGameState.TurnDuration. The turn clock (ElapsedTime) keeps advancing
    // normally in tick, so time spent in the pickup state is naturally
    // deducted from the remaining budget. Tick overrides position logic while
    // bStoppedForPickup is true, performing the ease-out via direct position
    // interpolation and then holding the ship still.
    // ==================================================================

    /**
     * Eases the ship to a halt for a pickup. Call at any time during movement.
     * Time spent stopped is deducted from the turn budget when ResumeFromPickup()
     * is called, shortening the remaining path accordingly.
     * No-op if already stopped or not currently moving.
     */
    UFUNCTION()
    void StopForPickup(bool bImmediateStop = false)
    {
        if (!IsMoving())
            return;

        StoppedTimeStart = CachedGameState.NormalizedTurnProgress;

        MovementState = EShipMovementState::StoppedForPickup;
    }

    /**
     * Resumes movement after a StopForPickup(). Deducts the time spent stopped
     * from the remaining budget, recomputes the new EndDistance, rebuilds the
     * curve from the current position, and eases the ship back up to speed.
     * Fires OnPenaltyApplied with the new EndDistance.
     * No-op if not in a pickup stop.
     */
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

    UFUNCTION()
    int32 PathDurationInTurns() const
    {
        return CheckpointDistances.Num() - 1;
    }

    UFUNCTION(BlueprintPure)
    bool IsStoppedForPickup() const
    {
        return MovementState == EShipMovementState::StoppedForPickup;
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

    UFUNCTION()
    float GetCurrentSpeed() const
    {
        if (MovementState != EShipMovementState::Moving || SegmentLength <= 0.0 || CachedGameState.TurnDuration <= 0.0)
            return 0.0;

        return UPathingUtils::EvalCurveDerivative(MovementCurve, CachedGameState.NormalizedTurnProgress) * (SegmentLength / CachedGameState.TurnDuration);
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
        //Print(f"{CheckpointDistances.Num()}");

        return true;
    }

    UFUNCTION(BlueprintPure)
    int GetPathDistance()
    {
        float ScaledDistance = Math::Min(PathSpline.GetSplineLength() - StartDistance, CurrentSpeed * CheckpointDistances.Num()) / 10.0;
        return Math::RoundToInt(ScaledDistance);
    }

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
        //AdjustedLocation = FVector::ZeroVector;
        //Distance = 0;
        //Days = 0;

        if (PathSpline == nullptr || Owner == nullptr)
            return false;

        if (MovementState == EShipMovementState::Moving)
        {
            float SampleDist = Math::Max(0.0, EndDistance - 0.1);
            FVector EndPoint = PathSpline.GetLocationAtDistanceAlongSpline(EndDistance, ESplineCoordinateSpace::World);
            FVector ForwardVector = PathSpline.GetDirectionAtDistanceAlongSpline(SampleDist, ESplineCoordinateSpace::World);
            FVector Destination = FVector(DestinationLocation.X, DestinationLocation.Y, ZLevel);
            
            /*
            int32 LastSurvivingIdx = PathSpline.GetNumberOfSplinePoints() - 1;
            while (LastSurvivingIdx > 0 && PathSpline.GetDistanceAlongSplineAtSplinePoint(LastSurvivingIdx) > EndDistance + 0.5f)
            {
                LastSurvivingIdx--;
            }
            int32 ArcPhase = LastSurvivingIdx % 3; // 0: only ArcStart survives, 1: ArcStart+Mid survive, 2: in the straight run — nothing to fix

            FVector CurvaturePos = FVector::ZeroVector;
            FVector CurvatureTangent = FVector::ZeroVector;
            if (ArcPhase == 0)
            {
                // Only the arc's start point survives. Sample the TRUE curve shape at the
                // cut now — once we truncate, there's nothing left past ArcStart to
                // interpolate against, so this has to happen before that loop runs.
                FVector ArcStartLoc  = PathSpline.GetLocationAtSplinePoint(LastSurvivingIdx, ESplineCoordinateSpace::World);
                float   ArcStartDist = PathSpline.GetDistanceAlongSplineAtSplinePoint(LastSurvivingIdx);
                float   ArcSampleDist   = (ArcStartDist + EndDistance) * 0.5;

                CurvaturePos = PathSpline.GetLocationAtDistanceAlongSpline(ArcSampleDist, ESplineCoordinateSpace::World);
                CurvatureTangent = PathSpline.GetDirectionAtDistanceAlongSpline(ArcSampleDist, ESplineCoordinateSpace::World)
                                    * ArcStartLoc.Distance(EndPoint) * 0.5;
            }*/

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

        // --- FINALIZE ---
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

    //Returns the world location of the current path's location at the end of the turn
    UFUNCTION(BlueprintPure)
    FVector GetPathEndOfTurnLocation()
    {
        return PathSpline.GetLocationAtDistanceAlongSpline(EndDistance, ESplineCoordinateSpace::World);
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

