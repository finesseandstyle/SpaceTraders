event void FOnMovementComplete2();
event void FOnPenaltyApplied2(float PenaltyDuration, float NewEndDistance);
event void FOnShipRotated(FVector DestinationLocation);

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

struct FWaypointTriggerTime
{
    int32 SplinePointIndex;
    float NormalizedTime; // [0, 1] within this turn
    float ActualTimeSeconds; // Scaled to your turn's actual duration
}

UCLASS()
class UTurnBasedMovementComponent : UActorComponent
{
    UPROPERTY() FOnMovementComplete2 OnMovementComplete;
    UPROPERTY() FOnPenaltyApplied2 OnPenaltyApplied;
    UPROPERTY() FOnShipRotated OnShipRotated;

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
    private TArray<FWaypointTriggerTime> ActiveTurnTriggers;
    private int32 CurrentTriggerIndex = 0;

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

    UFUNCTION(BlueprintPure)
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

        if (bIsMoving)
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
            /*
            // 4. Compensate for the fact that we may delete some points in between the curve to maintain the 4 +3n point count
            if (ArcPhase == 0)
            {
                Print("Arc Phase 0", 2);
                // Insert a real point between the surviving arc-start and the anchor —
                // same tangent used for arrive/leave, matching how BuildDubinsArc treats
                // interior arc points — then a degenerate point coincident with the
                // anchor so the trailing straight-pair stays a zero-length "straight".
                PathSpline.AddSplinePointAtIndex(CurvaturePos, AnchorIdx, ESplineCoordinateSpace::World, false);
                PathSpline.SetSplinePointType(AnchorIdx, ESplinePointType::CurveCustomTangent, false);
                PathSpline.SetTangentsAtSplinePoint(AnchorIdx, CurvatureTangent, CurvatureTangent, ESplineCoordinateSpace::World, false);
                AnchorIdx++;

                PathSpline.AddSplinePointAtIndex(EndPoint, AnchorIdx, ESplineCoordinateSpace::World, false);
                PathSpline.SetSplinePointType(AnchorIdx, ESplinePointType::CurveCustomTangent, false);
                PathSpline.SetTangentsAtSplinePoint(AnchorIdx, FVector::ZeroVector, FVector::ZeroVector, ESplineCoordinateSpace::World, false);
                AnchorIdx++;

                PathSpline.UpdateSpline();
            }
            else if (ArcPhase == 1)
            {
                Print("Arc Phase 1", 2);
                // Both real arc points survived, so curvature is already represented —
                // just complete the pairing with one dummy at the anchor.
                PathSpline.AddSplinePointAtIndex(EndPoint, AnchorIdx, ESplineCoordinateSpace::World, false);
                PathSpline.SetSplinePointType(AnchorIdx, ESplinePointType::CurveCustomTangent, false);
                PathSpline.SetTangentsAtSplinePoint(AnchorIdx, FVector::ZeroVector, FVector::ZeroVector, ESplineCoordinateSpace::World, false);
                AnchorIdx++;

                PathSpline.UpdateSpline();
            }
            else {
                Print("Arc Phase 2", 2);
            }
            // ArcPhase == 2: cut landed in the straight run — already 4 + 3n, nothing to add.
            */
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

    UFUNCTION()
    void SetupWaypointRotationTimers()
    {
        ActiveTurnTriggers.Empty();

        // 💡 Clean up old timer instances using the proper Name literal syntax
        System::ClearTimer(this, "TriggerNextWaypointRotation");
        CurrentTriggerIndex = 0;

        if (PathSpline == nullptr || MovementCurve == nullptr)
            return;

        float TotalTurnDist = EndDistance - StartDistance;
        int32 TotalPoints = PathSpline.GetNumberOfSplinePoints();
        
        if (TotalTurnDist <= 0.1)
            return;
        
        // Fallback for short/simple straight paths
        // BUG: The very first turn when we start the game, this fails to execute 
        if (TotalPoints <= 4)
        {
            OnShipRotated.Broadcast(GetPathEndOfTurnLocation());
            return;
        }

        FWaypointTriggerTime Trigger1;
        
        // 💡 FIX: Clamp the lookahead index to ensure we don't read past the end of the spline array
        Trigger1.SplinePointIndex = Math::CeilToInt(PathSpline.FindInputKeyClosestToWorldLocation(Owner.ActorLocation));
        Trigger1.SplinePointIndex = 4 + 3 * Math::IntegerDivisionTrunc(Math::Max(0, Trigger1.SplinePointIndex - 1), 3);
        Trigger1.NormalizedTime = 0;
        Trigger1.ActualTimeSeconds = 0;
        ActiveTurnTriggers.Add(Trigger1);
    
        // 💡 FIX: Removed the hardcoded InputKey(4) broadcast that was causing mid-path snaps.
        // The loop below will now dynamically handle all initial and mid-turn rotations.

        for (int32 i = 0; i < TotalPoints; i += 3)
        {
            float PointDist = PathSpline.GetDistanceAlongSplineAtSplinePoint(i);

            // Check if this waypoint falls within our current turn's active tracking segment
            if (PointDist >= StartDistance && PointDist <= EndDistance)
            {
                float TargetNormDist = (PointDist - StartDistance) / TotalTurnDist;
                float FoundNormTime = GetTimeFromNormalizedDistance(TargetNormDist);

                FWaypointTriggerTime Trigger;
                
                // 💡 FIX: Clamp the lookahead index to ensure we don't read past the end of the spline array
                Trigger.SplinePointIndex = Math::Min(i + 3, TotalPoints - 1);
                Trigger.NormalizedTime = FoundNormTime;
                Trigger.ActualTimeSeconds = FoundNormTime * CachedGameState.TurnDuration;

                ActiveTurnTriggers.Add(Trigger);
            }
        }

        // Kick off the sequential timer chain if an upcoming waypoint was caught in this turn window
        if (ActiveTurnTriggers.Num() > 0)
        {
            float FirstDelay = ActiveTurnTriggers[0].ActualTimeSeconds;

            if (FirstDelay == 0)
            {
                TriggerNextWaypointRotation();
            }
            else {
            
                // If a waypoint sits exactly at the start of the turn (ActualTimeSeconds == 0), 
                // this clamp ensures it triggers immediately on the next frame.
                FirstDelay = Math::Max(0.001f, FirstDelay); 
                
                System::SetTimer(this, n"TriggerNextWaypointRotation", FirstDelay, false);

            }
        }
    }

    // 💡 The Inverse Curve Solver via Binary Search
    float GetTimeFromNormalizedDistance(float TargetNormDist)
    {
        // Guard boundaries
        if (TargetNormDist <= 0.0) return 0.0;
        if (TargetNormDist >= 1.0) return 1.0;

        float LowTime = 0.0;
        float HighTime = 1.0;
        float EstimatedTime = 0.5;

        // 12 iterations gives an accuracy of 1/4096 (~0.0002 precision),
        // which takes less than a microsecond but matches frames flawlessly.
        for (int i = 0; i < 12; i++)
        {
            EstimatedTime = (LowTime + HighTime) * 0.5;
            float CurrentNormDist = MovementCurve.GetFloatValue(EstimatedTime);

            if (CurrentNormDist < TargetNormDist)
                LowTime = EstimatedTime; // Search upper half
            else
                HighTime = EstimatedTime; // Search lower half
        }

        return EstimatedTime;
    }

    UFUNCTION()
    void TriggerNextWaypointRotation()
    {
        // Safety check to ensure we haven't overrun the array boundaries
        if (!ActiveTurnTriggers.IsValidIndex(CurrentTriggerIndex))
            return;

        FWaypointTriggerTime TriggerData = ActiveTurnTriggers[CurrentTriggerIndex];

        // 💡 1. Execute your custom rotation handler here!
        // Pass the target waypoint index to your active rotation component/logic.
        FVector DestinationLocation = PathSpline.GetLocationAtSplineInputKey(Math::RoundToInt(TriggerData.SplinePointIndex), ESplineCoordinateSpace::World);
        //System::DrawDebugSphere(DestinationLocation, Radius=100, Duration=2);
        OnShipRotated.Broadcast(DestinationLocation); 

        // 2. Advance the tracker index to prime the next target
        CurrentTriggerIndex++;

        // 3. If there are remaining waypoints this turn, calculate the relative time difference
        if (CurrentTriggerIndex < ActiveTurnTriggers.Num())
        {
            float NextAbsoluteTime = ActiveTurnTriggers[CurrentTriggerIndex].ActualTimeSeconds;
            float CurrentAbsoluteTime = TriggerData.ActualTimeSeconds;
            
            // 💡 This is the precise delta time between the two events
            float TimeDifference = NextAbsoluteTime - CurrentAbsoluteTime;
            
            // Clamp to a tiny positive float value to keep execution ordered 
            // even if multiple waypoints share almost identical spacing metrics
            TimeDifference = Math::Max(0.001f, TimeDifference);

            // 4. Arm the next timer sequence using the relative difference
            System::SetTimer(this, n"TriggerNextWaypointRotation", TimeDifference, false);
        }
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

