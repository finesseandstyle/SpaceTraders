event void FOnMovementComplete2();
event void FOnPenaltyApplied2(float PenaltyDuration, float NewEndDistance);

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
    EasingForPickup,
    StoppedForPickup
}

UCLASS()
class UTurnBasedMovementComponent : UActorComponent
{
    UPROPERTY() FOnMovementComplete2 OnMovementComplete;
    UPROPERTY() FOnPenaltyApplied2 OnPenaltyApplied;

    UPROPERTY() TArray<float32> CheckpointDistances;
    UPROPERTY() float CurrentSpeed = 5000.0;
    UPROPERTY() float ZLevel = 810.0;

    UPROPERTY() USplineComponent PathSpline;
    UPROPERTY() float StartDistance = 0.0;
    UPROPERTY() float EndDistance = 1000.0;

    UPROPERTY() float PickupEaseDistance = 100.0;
    UPROPERTY() float TractorBeamRadius = 750.0;
    UPROPERTY() float TractorBeamPullSpeed = 1000.0;

    UPROPERTY() EShipMovementState MovementState; //TODO: this replaces bIsMoving, bCurveReady, bStopepdForPickup, bPickupEasingOut

    private UCurveFloat MovementCurve; // normTime [0,1] -> normDist [0,1]

    UPROPERTY() float OriginalNominalSpeed = 0.0; 
    private float SegmentLength = 0.0;
    private float RemainingTurnDuration;
    private bool  bIsMoving = false;
    private bool  bCurveReady = false;
    private float OriginalEndDistance  = 0.0; // EndDistance at the time of StopForPickup
    // SegmentLength / RemainingTurnDuration at StartMovement — never changes
    private float PreviousTurnSpeed    = 0.0; // We store the object's previous speed at every turn

    // Pickup related things
    private bool  bStoppedForPickup        = false;
    private bool  bPickupEasingOut         = false; // true while decelerating to the stop point
    private float PickupEaseStartWorldDist = 0.0;  // world dist where StopForPickup was called
    private float PickupEaseEndWorldDist   = 0.0;  // world dist where ship comes to full stop
    private float PickupEaseStartElapsed   = 0.0;  // ElapsedTime when StopForPickup was called
    private float PickupEaseOutDuration    = 0.0;  // seconds to complete the ease-out

    ATopDown_GameState CachedGameState;

    UFUNCTION(BlueprintOverride)
    void BeginPlay()
    {
        SetComponentTickEnabled(false);
        CachedGameState = Cast<ATopDown_GameState>(Gameplay::GetGameState());
        RemainingTurnDuration = CachedGameState.TurnDuration;
    }

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaSeconds)
    {
        if (!bIsMoving || PathSpline == nullptr || !bCurveReady)
            return;

        if (Owner == nullptr)
            return;

        if (bStoppedForPickup)
        {
            // Easing out should not be reset after every turn
            if (bPickupEasingOut)
            {
                // Phase 1: decelerate to a stop along the spline.
                // T goes 0->1 over PickupEaseOutDuration seconds.
                // Ease-out shape: position advances quickly then slows — mirrors
                // a power ramp where the derivative starts high and reaches zero.
                float T = Math::Clamp((CachedGameState.NormalizedTurnProgress - PickupEaseStartElapsed) / PickupEaseOutDuration, 0.0, 1.0);
                float EasedT = 1.0 - Math::Pow(1.0 - T, FPathProperties().EaseExponent);
                float WorldDist = Math::Lerp(PickupEaseStartWorldDist, PickupEaseEndWorldDist, EasedT);

                Owner.SetActorLocation(PathSpline.GetLocationAtDistanceAlongSpline(WorldDist, ESplineCoordinateSpace::World));

                if (T >= 1.0)
                    bPickupEasingOut = false;
            }

            // Logic for claiming Items

            return;
        }

        // Normal movement — evaluate the main curve
        float NormDist  = MovementCurve.GetFloatValue(CachedGameState.NormalizedTurnProgress);
        float WorldDist = StartDistance + NormDist * SegmentLength;

        Owner.SetActorLocation(PathSpline.GetLocationAtDistanceAlongSpline(WorldDist, ESplineCoordinateSpace::World));
        //Owner.SetActorLocation(Owner.GetActorLocation() + FVector(1, 1, 0));
    }

    void Update(float NormTime)
    {
        if (!bIsMoving || PathSpline == nullptr || !bCurveReady)
            return;

        if (Owner == nullptr)
            return;

        if (bStoppedForPickup)
        {
            // Easing out should not be reset after every turn
            if (bPickupEasingOut)
            {
                // Phase 1: decelerate to a stop along the spline.
                // T goes 0->1 over PickupEaseOutDuration seconds.
                // Ease-out shape: position advances quickly then slows — mirrors
                // a power ramp where the derivative starts high and reaches zero.
                float T = Math::Clamp((NormTime - PickupEaseStartElapsed) / PickupEaseOutDuration, 0.0, 1.0);
                float EasedT = 1.0 - Math::Pow(1.0 - T, FPathProperties().EaseExponent);
                float WorldDist = Math::Lerp(PickupEaseStartWorldDist, PickupEaseEndWorldDist, EasedT);

                Owner.SetActorLocation(PathSpline.GetLocationAtDistanceAlongSpline(WorldDist, ESplineCoordinateSpace::World));

                if (T >= 1.0)
                    bPickupEasingOut = false;
            }

            // Logic for claiming Items

            return;
        }

        // Normal movement — evaluate the main curve
        float NormDist  = MovementCurve.GetFloatValue(NormTime);
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
    void PrecomputeMovementCurve(float EaseInDistance, float EaseOutDistance)
    {
        bCurveReady = false;

        if (PathSpline == nullptr)
        {
            Warning("TurnBasedMovementComponent: PathSpline is null.");
            return;
        }

        SegmentLength = EndDistance - StartDistance;
        if (SegmentLength <= KINDA_SMALL_NUMBER)
        {
            Warning("TurnBasedMovementComponent: Segment length is zero or negative (" + SegmentLength + ").");
            return;
        }

        MovementCurve = UPathingUtils::GetMovementCurve(PathSpline, EaseInDistance, EaseOutDistance,
                                                         StartDistance, SegmentLength, FPathProperties());

        bCurveReady = (MovementCurve != nullptr);
    }

    UFUNCTION()
    void StartMovement()
    {
        if (!bCurveReady || !HasPathDefined())
            return;

        RemainingTurnDuration = CachedGameState.TurnDuration;
        bIsMoving  = true;
        SetComponentTickEnabled(true);
        OriginalEndDistance  = EndDistance;
        OriginalNominalSpeed = (RemainingTurnDuration > 0.0) ? (SegmentLength / RemainingTurnDuration) : 0.0;
        bPickupEasingOut = false; // prevent easing out when it's happening cross-turns.
    }

    UFUNCTION()
    void StopMovement()
    {
        bIsMoving = false;
        SetComponentTickEnabled(false);
        if (bCurveReady)
            Owner.SetActorLocation(PathSpline.GetLocationAtDistanceAlongSpline(EndDistance, ESplineCoordinateSpace::World));
    }

    // ==================================================================
    // Pickup stops
    //
    // Records the position and speed at the moment of stop — does NOT rebuild
    // the main MovementCurve or modify StartDistance / EndDistance /
    // RemainingTurnDuration. The turn clock (ElapsedTime) keeps advancing
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
        if (!bIsMoving || bStoppedForPickup || !bCurveReady)
            return;

        if (bImmediateStop)
        {
            bStoppedForPickup = true;
            bPickupEasingOut  = false;
            PickupEaseStartWorldDist = 0.0;
            PickupEaseEndWorldDist   = 0.0;
            PickupEaseStartElapsed   = 0.0;
            PickupEaseOutDuration    = 0.0;
            OriginalEndDistance      = EndDistance;
            return;
        }

        // Sample exact current position off the curve, not a fixed start point.
        // This handles being called mid-ease-in from a previous Resume.
        PickupEaseStartWorldDist = StartDistance + CachedGameState.NormalizedTurnProgress * SegmentLength;
        PickupEaseStartElapsed   = CachedGameState.NormalizedTurnProgress * CachedGameState.TurnDuration;
        OriginalEndDistance      = EndDistance;

        // Derive ease-out duration from actual current speed, not nominal speed.
        // If the ship is mid-ease-in it will be slower than full speed, so the
        // stop distance and time are proportionally shorter — no jerk.
        float ActualSpeed = GetCurrentSpeed();
        PickupEaseOutDuration = (ActualSpeed > KINDA_SMALL_NUMBER)
            ? (PickupEaseDistance * (ActualSpeed / Math::Max(OriginalNominalSpeed, 1.0))) / ActualSpeed
            : 0.0;

        // Ease travels proportionally less distance if ship is already slow.
        float SpeedRatio     = (OriginalNominalSpeed > 0.0) ? Math::Clamp(ActualSpeed / OriginalNominalSpeed, 0.0, 1.0) : 0.0;
        float ActualEaseDist = PickupEaseDistance * SpeedRatio;
        PickupEaseEndWorldDist = Math::Min(PickupEaseStartWorldDist + ActualEaseDist, OriginalEndDistance);

        bStoppedForPickup = true;
        bPickupEasingOut  = PickupEaseOutDuration > KINDA_SMALL_NUMBER;
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
        if (!bStoppedForPickup)
            return;

        bStoppedForPickup = false;
        bPickupEasingOut  = false;

        float ElapsedTime = CachedGameState.NormalizedTurnProgress * CachedGameState.TurnDuration;
        float RemainingTime  = RemainingTurnDuration - ElapsedTime;
        float PenaltyDuration = ElapsedTime - PickupEaseStartElapsed;

        if (RemainingTime <= KINDA_SMALL_NUMBER)
        {
            // Budget exhausted — end the turn at the stop position
            EndDistance = PickupEaseEndWorldDist;
            bIsMoving   = false;
            SetComponentTickEnabled(false);
            OnPenaltyApplied.Broadcast(PenaltyDuration, EndDistance);
            OnMovementComplete.Broadcast();
            return;
        }

        // Where would the ship be on the ORIGINAL curve if it had kept moving?
        // PickupEaseStartElapsed = when the stop was triggered.
        // RemainingTime          = budget left after the penalty.
        // Their sum is the point in the original turn timeline we'd have reached.
        // Evaluating the original MovementCurve (still intact at this point) gives
        // exactly the right endpoint — consistent with the original speed profile.
        float NewEndNormTime = Math::Clamp((PickupEaseStartElapsed + RemainingTime) / RemainingTurnDuration, 0.0, 1.0);
        float NewEndDistance = Math::Min(StartDistance + MovementCurve.GetFloatValue(NewEndNormTime) * SegmentLength, OriginalEndDistance);

        // Rebuild the curve: stop position -> new endpoint, with ease-in.
        // Reset elapsed time to 0 for the new curve — remaining budget becomes
        // the new RemainingTurnDuration.
        StartDistance = PickupEaseEndWorldDist;
        EndDistance   = NewEndDistance;
        RemainingTurnDuration = RemainingTime;
        ElapsedTime   = 0.0;

        PrecomputeMovementCurve(PickupEaseDistance, 0.0);

        SetComponentTickEnabled(true);
        OnPenaltyApplied.Broadcast(PenaltyDuration, NewEndDistance);
    }

    // ==================================================================
    // Queries
    // ==================================================================

    UFUNCTION()
    bool IsMoving() const
    {
        return bIsMoving;
    }

    UFUNCTION()
    int32 PathDurationInTurns() const
    {
        return CheckpointDistances.Num() - 1;
    }

    UFUNCTION()
    bool IsStoppedForPickup() const
    {
        return bStoppedForPickup;
    }

    float GetOriginalNominalSpeed() const
    {
        return OriginalNominalSpeed;
    }

    UFUNCTION()
    bool HasPathDefined() const
    {
        return CheckpointDistances.Num() >= 1 && CheckpointDistances.Last() - StartDistance > 1.0;
    }

    UFUNCTION()
    float GetCurrentSpeed() const
    {
        if (!bIsMoving || !bCurveReady || SegmentLength <= 0.0 || RemainingTurnDuration <= 0.0)
            return 0.0;

        return UPathingUtils::EvalCurveDerivative(MovementCurve, CachedGameState.NormalizedTurnProgress) * (SegmentLength / RemainingTurnDuration);
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
        FVector ForwardVector   = FVector(Owner.ActorForwardVector.X, Owner.ActorForwardVector.Y, 0.0).GetSafeNormal();

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

        return true;
    }

    UFUNCTION()
    void CancelPath()
    {
        StartDistance = 0.0;
        EndDistance   = 0.0;
        CheckpointDistances.Empty();
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
    bool QueuePathMidTurn(FVector DestinationLocation, FVector &out AdjustedLocation, int32&out Distance, int32&out Days)
    {
        AdjustedLocation = FVector::ZeroVector;
        Distance = 0;
        Days = 0;

        if (PathSpline == nullptr || Owner == nullptr)
            return false;

        if (bIsMoving)
        {
            float SampleDist = Math::Max(0.0, EndDistance - 0.1f);
            FVector EndPoint = PathSpline.GetLocationAtDistanceAlongSpline(EndDistance, ESplineCoordinateSpace::World);
            FVector ForwardVector = PathSpline.GetDirectionAtDistanceAlongSpline(SampleDist, ESplineCoordinateSpace::World);
            FVector Destination = FVector(DestinationLocation.X, DestinationLocation.Y, ZLevel);

            // 1. TRUNCATE FIRST
            for (int32 i = PathSpline.GetNumberOfSplinePoints() - 1; i >= 0; i--)
            {
                if (PathSpline.GetDistanceAlongSplineAtSplinePoint(i) > EndDistance + 0.5f)
                {
                    PathSpline.RemoveSplinePoint(i, false);
                }
            }
            PathSpline.UpdateSpline();

            // 2. ADD OR REUSE ANCHOR (Shared Point)
            int32 AnchorIdx = PathSpline.GetNumberOfSplinePoints() - 1;
            float TailDist = PathSpline.GetDistanceAlongSplineAtSplinePoint(AnchorIdx);

            if (Math::Abs(TailDist - EndDistance) > 0.1f)
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

            // 4. APPEND THE NEW PATH
            UPathingUtils::AddPointsToPath(PathSpline, EndPoint, ForwardVector, Destination,
                 400.0, EndDistance, ZLevel, CurrentSpeed, FPathProperties());

            float PathLength = PathSpline.GetSplineLength();

            // Rebuild CheckpointDistances logic...
            int32 DeletionIndex = -1;
            for (int32 i = 0; i < CheckpointDistances.Num(); i++)
            {
                // Use a slightly larger epsilon for the checkpoint search to avoid
                // double-adding the current turn
                if (CheckpointDistances[i] >= EndDistance - 1.0)
                {
                    DeletionIndex = i;
                    break;
                }
            }

            if (DeletionIndex != -1)
            {
                CheckpointDistances.RemoveAt(DeletionIndex);

                CheckpointDistances.Add(EndDistance);
                for (float d = EndDistance + CurrentSpeed; d < PathLength - 1.0; d += CurrentSpeed)
                {
                    CheckpointDistances.Add(d);
                }

                if (PathLength - CheckpointDistances.Last() > 1.0)
                {
                    CheckpointDistances.Add(PathLength);
                }
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
    bool SetRotatedPath(FVector DestinationLocation, FVector DestinationDirection, int32 &out Distance, int32 &out Days, FVector &out AdjustedLocation)
    {
        Distance = 0;
        Days = 0;
        AdjustedLocation = FVector::ZeroVector;

        if (PathSpline == nullptr || Owner == nullptr)
            return false;

        FVector StartPos = FVector(Owner.ActorLocation.X, Owner.ActorLocation.Y, ZLevel);
        FVector StartDir = FVector(Owner.ActorForwardVector.X, Owner.ActorForwardVector.Y, 0.0).GetSafeNormal();
        FVector EndPos = FVector(DestinationLocation.X, DestinationLocation.Y, ZLevel);
        FVector EndDir = (DestinationDirection - DestinationLocation).GetSafeNormal();

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
    FVector GetPathEndOfTurnLocation()
    {
        return PathSpline.GetLocationAtDistanceAlongSpline(EndDistance, ESplineCoordinateSpace::World);
    }
}

