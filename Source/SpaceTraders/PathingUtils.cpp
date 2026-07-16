#include "PathingUtils.h"
#include "Curves/CurveFloat.h"
#include "Curves/RichCurve.h"

bool UPathingUtils::CreateNewPath(USplineComponent* PathSpline, const FVector& StartingLocation, const FVector& StartingDirection, const float ZLevel,
                                          const FVector& DestinationLocation, const float MinimumPathDistance, const FPathProperties& PathProperties, const float CurrentSpeed)
{
    PathSpline->ClearSplinePoints(false);
    PathSpline->SetDefaultUpVector(FVector(0.f, 0.f, 1.f), ESplineCoordinateSpace::World);        
    
    TArray<FPathPoint> Points = BuildDubinsArc(StartingLocation, StartingDirection, ZLevel, DestinationLocation, PathProperties, CurrentSpeed);
           
    for (int32 p = 0; p < Points.Num(); p++)
    {
        // Add point without updating yet
        PathSpline->AddSplinePoint(Points[p].Location, ESplineCoordinateSpace::World, false);
        PathSpline->SetSplinePointType(p, ESplinePointType::CurveCustomTangent, false);
    
        // Apply Arrive and Leave tangents separately
        PathSpline->SetTangentsAtSplinePoint(
            p, 
            Points[p].ArriveTangent, 
            Points[p].LeaveTangent, 
            ESplineCoordinateSpace::World, 
            false
        );
    }
    
    PathSpline->UpdateSpline();
        
    // Snap destination to below MinimumPathDistance - little QoL
    // Due to how splines work in UE, this still results in a very slight error in actual length of the path.
    // TODO: Implement how much error is acceptable probably something like 0.1
    const float TotalLength = PathSpline->GetSplineLength();
    const float Remainder   = FMath::Fmod(TotalLength, CurrentSpeed);
    if (MinimumPathDistance > 0.f && TotalLength > CurrentSpeed && Remainder <= MinimumPathDistance)
    {
        const int32 LastIdx = PathSpline->GetNumberOfSplinePoints() - 1;
        const int32 PrevIdx = LastIdx - 1;

        const FVector PreviousPos = PathSpline->GetLocationAtSplinePoint(PrevIdx, ESplineCoordinateSpace::World);
        const FVector CurrentPos  = PathSpline->GetLocationAtSplinePoint(LastIdx, ESplineCoordinateSpace::World);
        const FVector Dir         = (CurrentPos - PreviousPos).GetSafeNormal();

        // 1. Determine the exact position that hits the multiple of CurrentSpeed
        const FVector SnappedPos = CurrentPos - (Dir * Remainder);
        const float NewDist      = FVector::Dist(PreviousPos, SnappedPos);
        const FVector NewTangent = Dir * NewDist;

        // 2. Update Location
        PathSpline->SetLocationAtSplinePoint(LastIdx, SnappedPos, ESplineCoordinateSpace::World, false);

        // 3. Set tangents to match the physical distance (Force perfect linear segment)
        // Keep ArriveTangent of PrevIdx as it's the exit of your arc
        PathSpline->SetTangentsAtSplinePoint(PrevIdx, PathSpline->GetArriveTangentAtSplinePoint(PrevIdx, ESplineCoordinateSpace::World), NewTangent, ESplineCoordinateSpace::World, false);
        PathSpline->SetTangentsAtSplinePoint(LastIdx, NewTangent, FVector::ZeroVector, ESplineCoordinateSpace::World, false);
        PathSpline->UpdateSpline();
        return true;
    }

    PathSpline->UpdateSpline();
    return false;
}

bool UPathingUtils::AddPointsToPath(USplineComponent* PathSpline, const FVector& StartingLocation, const FVector& StartingDirection,
                                               const FVector& DestinationLocation, const float MinimumPathDistance, const float EndDistance, const float ZLevel, const float CurrentSpeed, const FPathProperties& PathProperties)
{
    TArray<FPathPoint> Points = BuildDubinsArc(StartingLocation, StartingDirection, ZLevel, DestinationLocation, PathProperties, CurrentSpeed);
    
    if (Points.Num() < 4) return false;

    // SharedIdx is Point 0
    const int32 SharedIdx = PathSpline->GetNumberOfSplinePoints() - 1;

    // 1. Update ONLY the Leave Tangent of the Shared Point (Sacred Arrive Tangent from Handover)
    PathSpline->SetSplinePointType(SharedIdx, ESplinePointType::CurveCustomTangent, false);
    PathSpline->SetTangentsAtSplinePoint(
        SharedIdx,
        PathSpline->GetArriveTangentAtSplinePoint(SharedIdx, ESplineCoordinateSpace::World),
        Points[0].LeaveTangent, // Dubins internal curve start
        ESplineCoordinateSpace::World, false
    );

    // 2. Append Points 1, 2, and 3
    for (int32 i = 1; i < Points.Num(); i++)
    {
        PathSpline->AddSplinePoint(Points[i].Location, ESplineCoordinateSpace::World, false);
        int32 NewIdx = PathSpline->GetNumberOfSplinePoints() - 1;
        PathSpline->SetSplinePointType(NewIdx, ESplinePointType::CurveCustomTangent, false);

        FVector Arrive = Points[i].ArriveTangent;
        FVector Leave  = Points[i].LeaveTangent;

        // FIXED: Scaling the straight segment (Exit point to Destination)
        if (i == 2) // Exit Point (End of Turn)
        {
            // Arrive is Sacred (part of the turn curvature)
            // Leave is the start of the straight path: scale to distance
            float StraightDist = FVector::Dist(Points[2].Location, Points[3].Location);
            Leave = (Points[3].Location - Points[2].Location).GetSafeNormal() * StraightDist;
        }
        else if (i == 3) // Destination Point
        {
            // Arrive is the end of the straight path: scale to distance
            float StraightDist = FVector::Dist(Points[2].Location, Points[3].Location);
            Arrive = (Points[3].Location - Points[2].Location).GetSafeNormal() * StraightDist;
            Leave = FVector::ZeroVector;
        }

        PathSpline->SetTangentsAtSplinePoint(NewIdx, Arrive, Leave, ESplineCoordinateSpace::World, false);
    }
    
    PathSpline->UpdateSpline();
    
    // Snapping Path Destination to the closest minimum distance
    const float TotalLength = PathSpline->GetSplineLength();
    const float Remainder   = FMath::Fmod(TotalLength - EndDistance, CurrentSpeed);
    
    if (MinimumPathDistance > 0.f && TotalLength > CurrentSpeed && Remainder <= MinimumPathDistance)
    {
        const int32 LastIdx = PathSpline->GetNumberOfSplinePoints() - 1;
        const int32 PrevIdx = LastIdx - 1;

        const FVector PreviousPos = PathSpline->GetLocationAtSplinePoint(PrevIdx, ESplineCoordinateSpace::World);
        const FVector CurrentPos  = PathSpline->GetLocationAtSplinePoint(LastIdx, ESplineCoordinateSpace::World);
        
        const float StraightSegLen = FVector::Dist(PreviousPos, CurrentPos);
        
        // ONLY SNAP if the straight segment is longer than the remainder.
        // Otherwise, we'd be moving the point into the curve.
        if (StraightSegLen > Remainder + 1.f)
        {
            const FVector Dir = (CurrentPos - PreviousPos).GetSafeNormal();
            const FVector SnappedPos = CurrentPos - (Dir * Remainder);
            const float NewDist      = FVector::Dist(PreviousPos, SnappedPos);
            const FVector NewTangent = Dir * NewDist;

            PathSpline->SetLocationAtSplinePoint(LastIdx, SnappedPos, ESplineCoordinateSpace::World, false);
            PathSpline->SetTangentsAtSplinePoint(PrevIdx, PathSpline->GetArriveTangentAtSplinePoint(PrevIdx, ESplineCoordinateSpace::World), NewTangent, ESplineCoordinateSpace::World, false);
            PathSpline->SetTangentsAtSplinePoint(LastIdx, NewTangent, FVector::ZeroVector, ESplineCoordinateSpace::World, false);
            
            PathSpline->UpdateSpline();
            return true;
        }
    }

    PathSpline->UpdateSpline();
    return false;
}

UCurveFloat* UPathingUtils::GetMovementCurve(UObject* WorldContextObject,
                                                const USplineComponent* PathSpline, 
                                                const float EaseInDistance,
                                                const float EaseOutDistance, 
                                                const float StartDistance,
                                                const float SegmentLength,
                                                const FPathProperties& PathProperties)
{
    // 1. Validate inputs and return nullptr instead of an empty struct
    if (!WorldContextObject || !PathSpline || SegmentLength <= KINDA_SMALL_NUMBER)
    {
        return nullptr;
    }

    const int32 N = FMath::Max(FMath::RoundToInt(SegmentLength / PathProperties.SampleInterval) + 1, 4);

    // ------------------------------------------------------------------
    // Step 1 – Curvature weights
    // ------------------------------------------------------------------
    TArray<float> SpeedWeight;
    SpeedWeight.SetNumUninitialized(N);

    for (int32 i = 0; i < N; i++)
    {
        const float Alpha     = static_cast<float>(i) / (N - 1);
        const float WorldDist = StartDistance + Alpha * SegmentLength;
        SpeedWeight[i]        = SampleCurvatureWeight(PathSpline, WorldDist, PathProperties);
    }

    // ------------------------------------------------------------------
    // Step 2 – Ease-in / ease-out over explicit world-unit distances
    // ------------------------------------------------------------------
    auto ApplyEaseZone = [&](const int32 StartSample, const int32 EndSample, const bool bRampUp)
    {
        const int32 Count = EndSample - StartSample;
        if (Count <= 0) return;

        for (int32 k = 0; k < Count; k++)
        {
            const float T     = static_cast<float>(k) / FMath::Max(Count - 1, 1);
            const float Ramp  = bRampUp ? T : (1.f - T);
            const float EaseW = FMath::Pow(Ramp, PathProperties.EaseExponent);
            SpeedWeight[StartSample + k] = FMath::Min(SpeedWeight[StartSample + k], EaseW);
        }
    };

    if (EaseInDistance > 0.f)
    {
        const float EffectiveDist = FMath::Max(EaseInDistance, PathProperties.EaseFraction * SegmentLength);
        const int32 EaseInSamples = FMath::Min(
            FMath::RoundToInt(EffectiveDist / PathProperties.SampleInterval) + 1, N);
        ApplyEaseZone(0, EaseInSamples, /*bRampUp=*/true);
    }

    if (EaseOutDistance > 0.f)
    {
        const float EffectiveDist  = FMath::Max(EaseOutDistance, PathProperties.EaseFraction * SegmentLength);
        const int32 EaseOutSamples = FMath::Min(
            FMath::RoundToInt(EffectiveDist / PathProperties.SampleInterval) + 1, N);
        ApplyEaseZone(N - EaseOutSamples, N, /*bRampUp=*/false);
    }

    // ------------------------------------------------------------------
    // Step 3 – Integrate: cumulative distance proportional to weights
    // ------------------------------------------------------------------
    TArray<float> CumulativeDistance;
    CumulativeDistance.SetNumUninitialized(N);
    CumulativeDistance[0] = 0.f;

    for (int32 i = 1; i < N; i++)
    {
        const float AvgW = (SpeedWeight[i - 1] + SpeedWeight[i]) * 0.5f;
        CumulativeDistance[i] = CumulativeDistance[i - 1] + FMath::Max(AvgW, 1e-4f);
    }
    
    const float TotalCumulativeDistance = CumulativeDistance[N - 1];

    // ------------------------------------------------------------------
    // Step 4 – Create the UCurveFloat Object and populate FloatCurve
    // ------------------------------------------------------------------
    UCurveFloat* MovementCurveInstance = NewObject<UCurveFloat>(WorldContextObject);
    if (!MovementCurveInstance)
    {
        return nullptr;
    }

    FRichCurve& RichCurve = MovementCurveInstance->FloatCurve;
    RichCurve.Reset();
    RichCurve.SetDefaultValue(0.f);

    for (int32 i = 0; i < N; i++)
    {
        const float NormTime = static_cast<float>(i) / (N - 1);
        const float NormDist = CumulativeDistance[i] / TotalCumulativeDistance;

        const FKeyHandle Handle = RichCurve.AddKey(NormTime, NormDist);
        RichCurve.SetKeyInterpMode(Handle, RCIM_Linear);
    }

    // Pin endpoints exactly to avoid floating-point drift at boundaries
    {
        TArray<FRichCurveKey>& Keys = RichCurve.Keys;
        if (Keys.Num() > 0)
        {
            Keys[0].Time     = 0.f;
            Keys[0].Value    = 0.f;
            Keys.Last().Time  = 1.f;
            Keys.Last().Value = 1.f;
        }
    }

    return MovementCurveInstance;
}

FVector UPathingUtils::PredictPlanetInterceptCS(const FTransform& ShipTransform, const float ZLevel, const FVector& OrbitCenter, 
                                                const float OrbitRadius, const float CurrentAngleDeg, const float OrbitTurns, const int32 MaxIterations, const float CurrentSpeed, const FPathProperties& PathProperties)
{    
    if (OrbitTurns <= 0.f || CurrentSpeed <= 0.f)
        return FVector::Zero();

    const float OmegaRad = 2.f * PI / OrbitTurns;
    const float StartRad = FMath::DegreesToRadians(CurrentAngleDeg);

    const FVector ShipPos = ShipTransform.GetLocation();
    const FVector ShipDir = FVector(
        ShipTransform.GetRotation().GetForwardVector().X,
        ShipTransform.GetRotation().GetForwardVector().Y,
        0.f).GetSafeNormal();

    const float MaxR = PathProperties.DubinsTurnRadius + CurrentSpeed / 50.f;
    const FVector2D S(ShipPos.X, ShipPos.Y);
    const FVector2D D = FVector2D(ShipDir.X, ShipDir.Y).GetSafeNormal();
    const FVector2D PerpL(-D.Y,  D.X);
    const FVector2D PerpR( D.Y, -D.X);

    auto ComputeDubinsDistance = [&](const FVector& EndPos) -> float
    {
        const FVector2D E(EndPos.X, EndPos.Y);
        const FVector2D V = E - S;

        auto AdaptiveRadius = [&](const FVector2D& Perp) -> float
        {
            const float Dot = FVector2D::DotProduct(V, Perp);
            if (Dot <= KINDA_SMALL_NUMBER) return MaxR;
            return FMath::Min(MaxR, (V.SizeSquared() / (2.f * Dot)) * 0.99f);
        };

        const float RL = AdaptiveRadius(PerpL);
        const float RR = AdaptiveRadius(PerpR);
        const FVector2D CL = S + PerpL * RL;
        const FVector2D CR = S + PerpR * RR;

        auto FindLength = [&](const FVector2D& C, const float R, const bool bCCW) -> float
        {
            const FVector2D CE = E - C;
            const float d = CE.Size();
            if (d <= R + KINDA_SMALL_NUMBER) return TNumericLimits<float>::Max();

            const float Alpha   = FMath::Acos(FMath::Clamp(R / d, 0.f, 1.f));
            const float AngleCE = FMath::Atan2(CE.Y, CE.X);
            const float Angles[2] = { AngleCE + Alpha, AngleCE - Alpha };

            for (const float TAngle : Angles)
            {
                const FVector2D T         = C + FVector2D(FMath::Cos(TAngle), FMath::Sin(TAngle)) * R;
                const FVector2D DepartDir = bCCW
                    ? FVector2D(-FMath::Sin(TAngle),  FMath::Cos(TAngle))
                    : FVector2D( FMath::Sin(TAngle), -FMath::Cos(TAngle));

                if (FVector2D::DotProduct(DepartDir, E - T) < KINDA_SMALL_NUMBER) continue;

                float StartAngle = FMath::Atan2(S.Y - C.Y, S.X - C.X);
                float ArcAngle   = TAngle - StartAngle;
                if (bCCW) { while (ArcAngle < 0.f) ArcAngle += 2.f * PI; }
                else      { while (ArcAngle > 0.f) ArcAngle -= 2.f * PI; }

                return (FMath::Abs(ArcAngle) * R) + (E - T).Size();
            }
            return TNumericLimits<float>::Max();
        };

        const float LenL = FindLength(CL, RL, true);
        const float LenR = FindLength(CR, RR, false);
        const float Best = FMath::Min(LenL, LenR);
        return (Best < TNumericLimits<float>::Max()) ? Best : FVector2D::Distance(S, E);
    };

    // Initial guess: time to reach planet's current position
    const FVector PlanetNow(
        OrbitCenter.X + OrbitRadius * FMath::Cos(StartRad),
        OrbitCenter.Y + OrbitRadius * FMath::Sin(StartRad),
        ZLevel);

    float T = ComputeDubinsDistance(PlanetNow) / CurrentSpeed;

    for (int32 i = 0; i < MaxIterations; i++)
    {
        const float   Angle     = StartRad + OmegaRad * T;
        const FVector PlanetAtT(
            OrbitCenter.X + OrbitRadius * FMath::Cos(Angle),
            OrbitCenter.Y + OrbitRadius * FMath::Sin(Angle),
            ZLevel);

        const float TNew       = ComputeDubinsDistance(PlanetAtT) / CurrentSpeed;
        const bool  bConverged = FMath::IsNearlyEqual(TNew, T, 0.01f);
        T = TNew;

        if (bConverged)
        {
            const float FinalAngle = StartRad + OmegaRad * T;
            return FVector(
                OrbitCenter.X + OrbitRadius * FMath::Cos(FinalAngle),
                OrbitCenter.Y + OrbitRadius * FMath::Sin(FinalAngle),
                ZLevel);
        }
    }

    // Did not converge — return best estimate
    const float FinalAngle = StartRad + OmegaRad * T;
    return FVector(
        OrbitCenter.X + OrbitRadius * FMath::Cos(FinalAngle),
        OrbitCenter.Y + OrbitRadius * FMath::Sin(FinalAngle),
        ZLevel);
}

float UPathingUtils::SampleCurvatureWeight(const USplineComponent* PathSpline, const float WorldDistance, const FPathProperties& SplineProperties) 
{
    // Measure curvature from three positions straddling the sample point.
    // This is the Menger curvature of the osculating circle through P0, P1, P2:
    //   K = 2 * |cross(B-A, C-A)| / (|B-A| * |C-A| * |C-B|)
    // It depends only on where the path goes, not on spline tangent handles.
    //
    // Delta is half a SplineProperties.SampleInterval so the three points are one full interval
    // apart — consistent with the sample grid.
    const float Delta     = FMath::Max(SplineProperties.SampleInterval * 0.5f, 1.0f);

    const float DA = FMath::Max(WorldDistance - Delta, 0.0f);
    const float DB = WorldDistance;
    const float DC = FMath::Min(WorldDistance + Delta, PathSpline->GetSplineLength());

    const FVector A = PathSpline->GetLocationAtDistanceAlongSpline(DA, ESplineCoordinateSpace::World);
    const FVector B = PathSpline->GetLocationAtDistanceAlongSpline(DB, ESplineCoordinateSpace::World);
    const FVector C = PathSpline->GetLocationAtDistanceAlongSpline(DC, ESplineCoordinateSpace::World);

    const FVector AB = B - A;
    const FVector BC = C - B;
    const FVector AC = C - A;

    const float LenAB = AB.Size();
    const float LenBC = BC.Size();
    const float LenAC = AC.Size();

    if (LenAB < KINDA_SMALL_NUMBER || LenBC < KINDA_SMALL_NUMBER || LenAC < KINDA_SMALL_NUMBER)
        return 1.0f; // degenerate — treat as straight

    // Cross product magnitude = area of parallelogram spanned by AB and AC
    const float CrossMag = FVector::CrossProduct(AB, AC).Size();

    // Menger curvature K: high = tight curve, 0 = straight
    const float K = (2.0f * CrossMag) / (LenAB * LenBC * LenAC);

    // Normalise K to [0,1]. MaxCurvature corresponds to the tightest curve
    // we expect to ever see, which is a semicircle with radius = Delta:
    //   K_max = 1/Delta
    const float KNorm = FMath::Clamp(K * Delta, 0.0f, 1.0f);

    // KNorm = 0 → straight → weight 1. KNorm = 1 → max curve → weight 0.
    const float Deviation       = KNorm; // already 1 - LinearWeight
    const float ScaledDeviation = FMath::Pow(Deviation, 1.0f / FMath::Max(SplineProperties.CurveSlowdownExponent, 0.01f));
    const float CurvedWeight    = 1.0f - ScaledDeviation;

    return FMath::Lerp(1.0f, FMath::Max(CurvedWeight, 0.0f), SplineProperties.CurveSlowdownStrength);
}
 
TArray<FPathPoint> UPathingUtils::BuildDubinsArc(
    const FVector& StartPos, const FVector& StartDir, const float ZLevel,
    const FVector& EndPos, const FPathProperties& PathProperties, const float CurrentSpeed)
{
    const float MaxR = PathProperties.DubinsTurnRadius + CurrentSpeed / 50.f;

    const FVector2D S(StartPos.X, StartPos.Y);
    const FVector2D D = FVector2D{ StartDir.X, StartDir.Y }.GetSafeNormal();
    const FVector2D E(EndPos.X,   EndPos.Y);
    const FVector2D V = E - S;

    const FVector2D PerpL(-D.Y,  D.X);
    const FVector2D PerpR( D.Y, -D.X);

    //Adaptive radius is only to be used when performing a short 1 turn movement where the distance from the player to 
    //the destination is less than the MaxR's diameter.
    //It should not be used for a queued path with multiple checkpoints.
    auto AdaptiveRadius = [&](const FVector2D& Perp) -> float {
        const float Dot = FVector2D::DotProduct(V, Perp);
        if (Dot <= KINDA_SMALL_NUMBER) return MaxR;
        return FMath::Min(MaxR, (V.SizeSquared() / (2.f * Dot)) * 0.99f);
    };

    const float RL = AdaptiveRadius(PerpL);
    const float RR = AdaptiveRadius(PerpR);
    const FVector2D CL = S + PerpL * RL;
    const FVector2D CR = S + PerpR * RR;

    auto FindTangent = [&](const FVector2D& C, const float R, const bool bCCW) -> TTuple<FVector2D, float> {
        const FVector2D CE = E - C;
        const float d = CE.Size();
        if (d <= R + KINDA_SMALL_NUMBER) return MakeTuple(FVector2D::ZeroVector, TNumericLimits<float>::Max());

        float Alpha = FMath::Acos(FMath::Clamp(R / d, 0.f, 1.f));
        float AngleCE = FMath::Atan2(CE.Y, CE.X);
        float Angles[2] = { AngleCE + Alpha, AngleCE - Alpha };

        for (float TAngle : Angles) {
            FVector2D T = C + FVector2D(FMath::Cos(TAngle), FMath::Sin(TAngle)) * R;
            FVector2D DepartDir = bCCW ? FVector2D(-FMath::Sin(TAngle), FMath::Cos(TAngle)) : FVector2D(FMath::Sin(TAngle), -FMath::Cos(TAngle));
            if (FVector2D::DotProduct(DepartDir, E - T) < KINDA_SMALL_NUMBER) continue;

            float StartAngle = FMath::Atan2(S.Y - C.Y, S.X - C.X);
            float ArcAngle = TAngle - StartAngle;
            if (bCCW) { while (ArcAngle < 0.f) ArcAngle += 2.f * PI; }
            else      { while (ArcAngle > 0.f) ArcAngle -= 2.f * PI; }

            return MakeTuple(T, (FMath::Abs(ArcAngle) * R) + (E - T).Size());
        }
        return MakeTuple(FVector2D::ZeroVector, TNumericLimits<float>::Max());
    };

    auto [TL, LenL] = FindTangent(CL, RL, true);
    auto [TR, LenR] = FindTangent(CR, RR, false);

    const bool bCCW = (LenL <= LenR);
    const FVector2D C = bCCW ? CL : CR;
    const FVector2D T = bCCW ? TL : TR;
    const float R = bCCW ? RL : RR;

    // --- Spline Point Generation ---
    
    const float StartAngle = FMath::Atan2(S.Y - C.Y, S.X - C.X);
    const float EndAngle   = FMath::Atan2(T.Y - C.Y, T.X - C.X);
    float TotalArcAngle    = EndAngle - StartAngle;
    
    if (bCCW) { while (TotalArcAngle < 0.f) TotalArcAngle += 2.f * PI; }
    else      { while (TotalArcAngle > 0.f) TotalArcAngle -= 2.f * PI; }

    // We split the arc into 2 segments (3 points). 
    // The angle for each segment is TotalArcAngle / 2.
    const float SegmentAngle = TotalArcAngle / 2.f;
    
    // Magic formula for tangent length for a circular arc segment
    // I don't know why you need the multiply by 3 constant at the end but it makes the circles look perfect.
    // This should be played around to determine an exact value
    const float ArcTangentMag = (4.f / 3.f) * R * FMath::Tan(FMath::Abs(SegmentAngle) / 4.f) * 3.f;

    auto GetArcPoint = [&](const float Angle) -> FPathPoint {
        FVector2D Pos2D = C + FVector2D(FMath::Cos(Angle), FMath::Sin(Angle)) * R;
        FVector2D Dir2D = bCCW ? FVector2D(-FMath::Sin(Angle), FMath::Cos(Angle)) : FVector2D(FMath::Sin(Angle), -FMath::Cos(Angle));
        FVector Tangent = FVector(Dir2D.X, Dir2D.Y, 0.f) * ArcTangentMag;
        return { FVector(Pos2D.X, Pos2D.Y, ZLevel), Tangent, Tangent };
    };

    TArray<FPathPoint> OutPoints;
    // 1. Start Point
    OutPoints.Add(GetArcPoint(StartAngle));

    // 2. Mid Point
    OutPoints.Add(GetArcPoint(StartAngle + SegmentAngle));

    // 3. Exit Point (Transition from Arc to Straight)
    FPathPoint ExitPoint = GetArcPoint(EndAngle);
    
    // Calculate the straight line tangent
    FVector2D ToEndDir = (E - T).GetSafeNormal();
    float StraightDist = (E - T).Size();
    // For a perfectly straight spline segment, LeaveTangent at T and ArriveTangent at E 
    // should be the vector from T to E.
    FVector StraightTangent = FVector(ToEndDir.X, ToEndDir.Y, 0.f) * StraightDist;
    
    ExitPoint.LeaveTangent = StraightTangent; // Override LeaveTangent for the straight path
    OutPoints.Add(ExitPoint);

    // 4. Final Destination - Straight path
    OutPoints.Add({ FVector(E.X, E.Y, ZLevel), StraightTangent, FVector::ZeroVector });
    return OutPoints;
}

float UPathingUtils::EvalCurveDerivative(const UCurveFloat* MovementCurve, const float NormTime)
{
    constexpr float Eps = 0.005f;
    const float T0 = FMath::Max(NormTime - Eps, 0.0f);
    const float T1 = FMath::Min(NormTime + Eps, 1.0f);
    const float DT = T1 - T0;
    if (DT <= 0.0f) return 0.0f;
    return (MovementCurve->FloatCurve.Eval(T1) - MovementCurve->FloatCurve.Eval(T0)) / DT;
}

TArray<FPathPoint> UPathingUtils::BuildRotatedDubinsPath(const FVector& StartLoc, const FVector& StartDir, const FVector& TargetLoc, 
    const FVector& TargetDir, const float CurrentSpeed, const float ZLevel, const FPathProperties& PathProperties)
{
    TArray<FPathPoint> OutPoints;
    const float R = PathProperties.DubinsTurnRadius + (CurrentSpeed / 50.f);

    // ── 2-D aliases ───────────────────────────────────────────────────────────
    const FVector2D S (StartLoc.X,  StartLoc.Y);
    const FVector2D E (TargetLoc.X, TargetLoc.Y);
    const FVector2D DS = FVector2D(StartDir.X,  StartDir.Y).GetSafeNormal();
    const FVector2D DE = FVector2D(TargetDir.X, TargetDir.Y).GetSafeNormal();

    // ── Pure geometry helpers ─────────────────────────────────────────────────

    auto LeftPerp  = [](const FVector2D& D) -> FVector2D { return FVector2D(-D.Y,  D.X); };
    auto RightPerp = [](const FVector2D& D) -> FVector2D { return FVector2D( D.Y, -D.X); };

    // Signed arc sweep from AngleA to AngleB given winding.
    // Result is always in [0, 2π] for CCW, [-2π, 0] for CW.
    auto ArcSweep = [](float AngleA, float AngleB, bool bCCW) -> float
    {
        float Delta = AngleB - AngleA;
        if (bCCW) { while (Delta <  0.f)       Delta += 2.f * PI; }
        else      { while (Delta >  0.f)       Delta -= 2.f * PI; }
        return Delta;
    };

    auto AngleTo = [](const FVector2D& C, const FVector2D& P) -> float
    {
        return FMath::Atan2(P.Y - C.Y, P.X - C.X);
    };

    // Tangent direction on a circle at angular position Angle
    auto ArcDir = [](float Angle, bool bCCW) -> FVector2D
    {
        return bCCW
            ? FVector2D(-FMath::Sin(Angle),  FMath::Cos(Angle))
            : FVector2D( FMath::Sin(Angle), -FMath::Cos(Angle));
    };

    // Cubic Bézier tangent magnitude for a half-arc segment (arc split in 2).
    // Multiplied by 3 to match BuildDubinsArc's visual calibration.
    auto ArcTangentMag = [&](float HalfArcAngle) -> float
    {
        return (4.f / 3.f) * R * FMath::Tan(FMath::Abs(HalfArcAngle) / 4.f) * 3.f;
    };

    // Four circle centres
    const FVector2D CLS = S + LeftPerp(DS)  * R;   // Start, Left  turn
    const FVector2D CRS = S + RightPerp(DS) * R;   // Start, Right turn
    const FVector2D CLE = E + LeftPerp(DE)  * R;   // End,   Left  turn
    const FVector2D CRE = E + RightPerp(DE) * R;   // End,   Right turn

    // ── Candidate storage ─────────────────────────────────────────────────────

    struct FCandidate
    {
        float      Cost = TNumericLimits<float>::Max();
        bool       bCSC = true;

        // CSC fields
        FVector2D  C1, C2;
        FVector2D  T1, T2;          // arc-exit / arc-entry on straight segment
        bool       bCCW1 = true, bCCW2 = true;

        // CCC fields
        FVector2D  Cm;              // middle circle centre
        bool       bCCWm = false;
        // arc angles for CCC
        float      A1s=0,A1e=0, Ams=0,Ame=0, A2s=0,A2e=0;
    };

    FCandidate Best;

    // ── CSC solver ────────────────────────────────────────────────────────────
    //
    // Strategy: enumerate all geometrically valid tangent lines for the
    // (C1,R)→(C2,R) pair, then accept only those where
    //   • the arc from S sweeps the correct winding to reach T1
    //   • the arc from T2 sweeps the correct winding to reach E
    //   • the straight segment points from T1 toward T2 (positive dot with arc exit dir)
    //
    auto TryCSC = [&](
        const FVector2D& C1, bool bCCW1,
        const FVector2D& C2, bool bCCW2,
        bool bExternal) -> void
    {
        FVector2D D  = C2 - C1;
        float     d  = D.Size();
        if (d < KINDA_SMALL_NUMBER) return;
        FVector2D Dn = D / d;

        // Collect candidate (T1,T2) pairs
        TArray<TPair<FVector2D,FVector2D>> Candidates;

        if (bExternal)
        {
            // External tangent: offset perp to inter-centre line by R on same side.
            // Two solutions: left-of-D and right-of-D.
            FVector2D PerpD(-Dn.Y, Dn.X);
            for (int32 s = -1; s <= 1; s += 2)
            {
                FVector2D t1 = C1 + PerpD * (R * s);
                FVector2D t2 = C2 + PerpD * (R * s);
                Candidates.Add({ t1, t2 });
            }
        }
        else
        {
            // Internal (cross) tangent: requires d >= 2R
            if (d < 2.f * R - KINDA_SMALL_NUMBER) return;

            float Alpha   = FMath::Acos(FMath::Clamp(2.f * R / d, 0.f, 1.f));
            float BaseAng = FMath::Atan2(D.Y, D.X);

            for (int32 s = -1; s <= 1; s += 2)
            {
                float  Ta = BaseAng + s * Alpha;
                FVector2D t1 = C1 + FVector2D(FMath::Cos(Ta), FMath::Sin(Ta)) * R;
                // Antipodal point on C2
                FVector2D t2 = C2 - FVector2D(FMath::Cos(Ta), FMath::Sin(Ta)) * R;
                Candidates.Add({ t1, t2 });
            }
        }

        for (auto& [t1, t2] : Candidates)
        {
            // --- Validate arc 1: S → T1 with winding bCCW1 ---
            float Ang1S = AngleTo(C1, S);
            float Ang1T = AngleTo(C1, t1);
            float Sweep1 = ArcSweep(Ang1S, Ang1T, bCCW1);

            // Arc exit direction at T1 must point toward T2 (positive dot product)
            FVector2D ExitDir1 = ArcDir(Ang1T, bCCW1);
            FVector2D ToT2     = (t2 - t1);
            float     SegLen   = ToT2.Size();
            if (SegLen < KINDA_SMALL_NUMBER) continue;               // degenerate straight
            if (FVector2D::DotProduct(ExitDir1, ToT2 / SegLen) < KINDA_SMALL_NUMBER) continue;

            // --- Validate arc 2: T2 → E with winding bCCW2 ---
            float Ang2T = AngleTo(C2, t2);
            float Ang2E = AngleTo(C2, E);
            float Sweep2 = ArcSweep(Ang2T, Ang2E, bCCW2);

            // Arc entry direction at T2 must align with the straight segment
            FVector2D EntryDir2 = ArcDir(Ang2T, bCCW2);
            if (FVector2D::DotProduct(EntryDir2, ToT2 / SegLen) < KINDA_SMALL_NUMBER) continue;

            // --- Cost ---
            float Cost = FMath::Abs(Sweep1) * R + SegLen + FMath::Abs(Sweep2) * R;

            if (Cost < Best.Cost)
            {
                Best.Cost  = Cost;
                Best.bCSC  = true;
                Best.C1    = C1;  Best.C2    = C2;
                Best.T1    = t1;  Best.T2    = t2;
                Best.bCCW1 = bCCW1; Best.bCCW2 = bCCW2;
            }
        }
    };

    // ── CCC solver ────────────────────────────────────────────────────────────

    auto TryCCC = [&](
        const FVector2D& C1, bool bCCW1,
        const FVector2D& C2, bool bCCW2,
        bool bCCWm) -> void
    {
        FVector2D D = C2 - C1;
        float     d = D.Size();
        if (d > 4.f * R + KINDA_SMALL_NUMBER || d < KINDA_SMALL_NUMBER) return;

        float CosA    = FMath::Clamp(d / (4.f * R), 0.f, 1.f);
        float Alpha   = FMath::Acos(CosA);
        float BaseAng = FMath::Atan2(D.Y, D.X);

        for (int32 s = -1; s <= 1; s += 2)
        {
            float     MidAng = BaseAng + s * Alpha;
            FVector2D Cm     = C1 + FVector2D(FMath::Cos(MidAng), FMath::Sin(MidAng)) * 2.f * R;

            FVector2D T1pt = (C1 + Cm) * 0.5f;
            FVector2D T2pt = (Cm + C2) * 0.5f;

            float A1s = AngleTo(C1, S);
            float A1e = AngleTo(C1, T1pt);
            float Ams = AngleTo(Cm, T1pt);
            float Ame = AngleTo(Cm, T2pt);
            float A2s = AngleTo(C2, T2pt);
            float A2e = AngleTo(C2, E);

            float Sw1 = ArcSweep(A1s, A1e, bCCW1);
            float Swm = ArcSweep(Ams, Ame, bCCWm);
            float Sw2 = ArcSweep(A2s, A2e, bCCW2);

            // Validate exit direction of arc1 aligns with arc-middle entry
            FVector2D ExitDir1   = ArcDir(A1e, bCCW1);
            FVector2D EntryDirM  = ArcDir(Ams, bCCWm);
            if (FVector2D::DotProduct(ExitDir1, EntryDirM) < -KINDA_SMALL_NUMBER) continue;

            // Validate exit of middle aligns with arc2 entry
            FVector2D ExitDirM  = ArcDir(Ame, bCCWm);
            FVector2D EntryDir2 = ArcDir(A2s, bCCW2);
            if (FVector2D::DotProduct(ExitDirM, EntryDir2) < -KINDA_SMALL_NUMBER) continue;

            float Cost = (FMath::Abs(Sw1) + FMath::Abs(Swm) + FMath::Abs(Sw2)) * R;

            if (Cost < Best.Cost)
            {
                Best.Cost  = Cost;
                Best.bCSC  = false;
                Best.C1    = C1;  Best.C2 = C2;  Best.Cm = Cm;
                Best.bCCW1 = bCCW1; Best.bCCW2 = bCCW2; Best.bCCWm = bCCWm;
                Best.A1s=A1s; Best.A1e=A1e;
                Best.Ams=Ams; Best.Ame=Ame;
                Best.A2s=A2s; Best.A2e=A2e;
            }
        }
    };

    // ── Evaluate all 6 Dubins words ───────────────────────────────────────────
    TryCSC(CLS, true,  CLE, true,  true);   // LSL
    TryCSC(CRS, false, CRE, false, true);   // RSR
    TryCSC(CLS, true,  CRE, false, false);  // LSR
    TryCSC(CRS, false, CLE, true,  false);  // RSL
    TryCCC(CLS, true,  CRE, false, false);  // LRL  (middle R = CW)
    TryCCC(CRS, false, CLE, true,  true);   // RLR  (middle L = CCW)

    if (Best.Cost >= TNumericLimits<float>::Max() - 1.f) return OutPoints;

    // ── Point emission helpers ────────────────────────────────────────────────

    // Emit 3 arc points (start, mid, exit) for one arc segment.
    // Returns the exit FPathPoint so the caller can patch tangents before pushing.
    auto EmitArcPoints = [&](
        const FVector2D& C,
        float AngleStart, float AngleEnd,
        bool  bCCW,
        TFunctionRef<void(FPathPoint& /*start*/, FPathPoint& /*mid*/, FPathPoint& /*exit*/)> PatchFn)
    {
        float TotalArc = ArcSweep(AngleStart, AngleEnd, bCCW);
        float HalfArc  = TotalArc / 2.f;
        float AngleMid = AngleStart + HalfArc;
        float TanMag   = ArcTangentMag(HalfArc);

        auto MakePt = [&](float A) -> FPathPoint {
            FVector2D P2  = C + FVector2D(FMath::Cos(A), FMath::Sin(A)) * R;
            FVector2D Dir = ArcDir(A, bCCW);
            FVector   T   = FVector(Dir.X, Dir.Y, 0.f) * TanMag;
            FPathPoint Pt;
            Pt.Location       = FVector(P2.X, P2.Y, ZLevel);
            Pt.ArriveTangent  = T;
            Pt.LeaveTangent   = T;
            return Pt;
        };

        FPathPoint P0 = MakePt(AngleStart);
        FPathPoint P1 = MakePt(AngleMid);
        FPathPoint P2 = MakePt(AngleEnd);
        PatchFn(P0, P1, P2);
        OutPoints.Add(P0);
        OutPoints.Add(P1);
        OutPoints.Add(P2);
    };

    // Append a junction point (coincides with previous exit, starts the next segment)
    auto PushJunction = [&](const FPathPoint& ExitPt, FVector OverrideLeave = FVector(0.f))
    {
        FPathPoint J  = ExitPt;
        J.ArriveTangent = ExitPt.ArriveTangent;
        if (!OverrideLeave.IsNearlyZero()) J.LeaveTangent = OverrideLeave;
        OutPoints.Add(J);
    };

    // ── Build output points ───────────────────────────────────────────────────

    if (Best.bCSC)
    {
        const FVector2D& C1 = Best.C1;
        const FVector2D& C2 = Best.C2;
        const FVector2D& T1 = Best.T1;
        const FVector2D& T2 = Best.T2;

        float A1S = AngleTo(C1, S);
        float A1E = AngleTo(C1, T1);
        float A2S = AngleTo(C2, T2);
        float A2E = AngleTo(C2, E);

        // Straight segment tangent: direction and magnitude T1 → T2
        float     SegLen    = (T2 - T1).Size();
        FVector2D SegDir2   = (T2 - T1).GetSafeNormal();
        FVector   StraightT = FVector(SegDir2.X, SegDir2.Y, 0.f) * SegLen;

        // --- Arc 1  (points 0, 1, 2) ---
        // Exit point (index 2): ArriveTangent = arc curvature (sacred), LeaveTangent = StraightT
        EmitArcPoints(C1, A1S, A1E, Best.bCCW1,
            [&](FPathPoint& P0, FPathPoint& P1, FPathPoint& P2)
            {
                P2.LeaveTangent = StraightT;
            });

        // --- Arc 2  (points 3, 4, 5) ---
        // Point 3 is the junction: it coincides with Arc1's exit (T1 location)
        // but lives on Arc2's circle at T2.  Per spec it IS Arc2's first point.
        // ArriveTangent = StraightT (end of straight), LeaveTangent = arc curvature.
        FPathPoint Arc2Exit;
        EmitArcPoints(C2, A2S, A2E, Best.bCCW2,
            [&](FPathPoint& P0, FPathPoint& P1, FPathPoint& P2)
            {
                P0.ArriveTangent = StraightT;   // junction: arrive via straight
                P2.LeaveTangent  = FVector::ZeroVector; // terminal leave = zero
                Arc2Exit = P2;
            });

        // --- Terminal junction (point 6) ---
        // Coincides with Arc2 exit; LeaveTangent = zero (end of path)
        FPathPoint Terminal;
        Terminal.Location      = Arc2Exit.Location;
        Terminal.ArriveTangent = Arc2Exit.ArriveTangent;
        Terminal.LeaveTangent  = FVector::ZeroVector;
        OutPoints.Add(Terminal);
    }
    else // CCC
    {
        const FVector2D& C1 = Best.C1;
        const FVector2D& C2 = Best.C2;
        const FVector2D& Cm = Best.Cm;

        // --- Arc 1 ---
        FPathPoint Arc1Exit;
        EmitArcPoints(C1, Best.A1s, Best.A1e, Best.bCCW1,
            [&](FPathPoint& P0, FPathPoint& P1, FPathPoint& P2)
            {
                Arc1Exit = P2;
            });
        PushJunction(Arc1Exit); // junction between arc1 and middle arc

        // --- Middle Arc ---
        FPathPoint ArcMExit;
        EmitArcPoints(Cm, Best.Ams, Best.Ame, Best.bCCWm,
            [&](FPathPoint& P0, FPathPoint& P1, FPathPoint& P2)
            {
                // Entry: arrive = arc1 exit tangent
                P0.ArriveTangent = Arc1Exit.LeaveTangent;
                ArcMExit = P2;
            });
        PushJunction(ArcMExit); // junction between middle arc and arc2

        // --- Arc 2 ---
        FPathPoint Arc2Exit;
        EmitArcPoints(C2, Best.A2s, Best.A2e, Best.bCCW2,
            [&](FPathPoint& P0, FPathPoint& P1, FPathPoint& P2)
            {
                // Entry: arrive = middle arc exit tangent
                P0.ArriveTangent = ArcMExit.LeaveTangent;
                // Exit: leave = zero (terminal)
                P2.LeaveTangent = FVector::ZeroVector;
                Arc2Exit = P2;
            });
        PushJunction(Arc2Exit); // terminal junction
    }
    return OutPoints;
}

void UPathingUtils::GetPathSamples(const USplineComponent* PathSpline, TArray<float>& CheckpointDistances, const float StartDistance, TArray<FVector>& OutCurrentPath, TArray<FVector>& OutRemainingPath, TArray<FVector>& OutTraversedPath, TArray<FVector>& OutCheckpoints, const float DistancePerStep, const int32 TurnsAhead)
{
    OutCurrentPath.Empty();
    OutRemainingPath.Empty();
    OutTraversedPath.Empty();
    OutCheckpoints.Empty();

    if (!PathSpline || PathSpline->GetNumberOfSplinePoints() < 2) return;

    const float TotalLength = PathSpline->GetSplineLength();
    
    // 1. Identify the Distance Range for this turn

    if (!(CheckpointDistances.IsValidIndex(TurnsAhead) && CheckpointDistances.IsValidIndex(TurnsAhead + 1)))
        return;

    const float NewStartDistance = CheckpointDistances[TurnsAhead];
    const float NewEndDistance = CheckpointDistances[TurnsAhead + 1];

    // Lambda to build a path by segments
    auto SampleRange = [&](const float MinDist, const float MaxDist, TArray<FVector>& OutArray)
    {
        for (int32 i = 0; i < PathSpline->GetNumberOfSplinePoints() - 1; ++i)
        {
            const float SegStart = PathSpline->GetDistanceAlongSplineAtSplinePoint(i);
            const float SegEnd   = PathSpline->GetDistanceAlongSplineAtSplinePoint(i + 1);

            // Skip segments completely outside the desired range
            if (SegEnd <= MinDist || SegStart >= MaxDist) continue;

            // Determine if this is an Arc (0,1) or Straight (2) segment
            const bool bIsStraight = (i % 3 == 2);
            
            // Apply the multiplier for straight segments
            const float CurrentStep = bIsStraight ? 750.f : DistancePerStep;

            const float StartPos = FMath::Max(SegStart, MinDist);
            const float EndPos   = FMath::Min(SegEnd, MaxDist);
            const float SegLen   = EndPos - StartPos;

            // Ensure we have at least 1 step to get from A to B
            const int32 Steps = FMath::Max(FMath::CeilToInt(SegLen / CurrentStep), 1);
            
            for (int32 j = 0; j < Steps; j++)
            {
                const float Alpha = j * 1.f / (Steps * 1.f);
                OutArray.Add(PathSpline->GetLocationAtDistanceAlongSpline(StartPos + (SegLen * Alpha), ESplineCoordinateSpace::World));
            }
        }
        // Always cap the very end of the requested range exactly
        OutArray.Add(PathSpline->GetLocationAtDistanceAlongSpline(MaxDist, ESplineCoordinateSpace::World));
    };

    SampleRange(NewStartDistance, NewEndDistance, OutCurrentPath);
    SampleRange(NewEndDistance, TotalLength, OutRemainingPath);
    SampleRange(0.f, NewStartDistance, OutTraversedPath);

    // 2. Checkpoints
    for (const float d : CheckpointDistances)
    {
        if (d > StartDistance)
        {
            const FVector CP = PathSpline->GetLocationAtDistanceAlongSpline(d, ESplineCoordinateSpace::World);
            OutCheckpoints.Add(FVector(CP.X, CP.Y, CP.Z + 5.f));
        }
    }
}