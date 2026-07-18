#pragma once
#include "Components/SplineComponent.h"
#include "Curves/RichCurve.h"
#include "Kismet/BlueprintFunctionLibrary.h"
#include "UObject/ObjectMacros.h"
#include "PathingUtils.generated.h"

USTRUCT(BlueprintType)
struct FPathPoint
{	
	GENERATED_BODY()

	UPROPERTY(BlueprintReadWrite) FVector Location;
	UPROPERTY(BlueprintReadWrite) FVector ArriveTangent = FVector::ZeroVector;
	UPROPERTY(BlueprintReadWrite) FVector LeaveTangent  = FVector::ZeroVector;
};

USTRUCT(BlueprintType)
struct FItemStopPlan
{
	GENERATED_BODY()

	UPROPERTY(BlueprintReadWrite) float StopDistance;			 // The spline distance where the ship will halt
	UPROPERTY(BlueprintReadWrite) TArray<AActor*> TargetItems; // Items to collect at this specific stop
	UPROPERTY(BlueprintReadWrite) float TotalRequiredPullTime; // Calculated based on Distance / PullSpeed
};

USTRUCT(BlueprintType)
struct FPathProperties
{
	GENERATED_BODY()
	
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category="Spline Movement|Curve Shape")
	float CurveSlowdownStrength = 0.70f;
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category="Spline Movement|Curve Shape")
	float CurveSlowdownExponent = 1.5f;
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category="Spline Movement|Curve Shape")
	float EaseFraction = 0.15f;
    UPROPERTY(EditAnywhere, BlueprintReadWrite, Category="Spline Movement|Curve Shape")
    float EaseExponent = 2.f;
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category="Spline Movement|Curve Shape")
	float SampleInterval = 100.f;
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category="Spline Movement|Path")
	float DubinsTurnRadius = 200.f;
};

UCLASS()
class SPACETRADERS_API UPathingUtils : public UBlueprintFunctionLibrary
{
	GENERATED_BODY()

public:	
	UFUNCTION(BlueprintCallable)
	static bool CreateNewPath(USplineComponent* PathSpline, const FVector& StartingLocation, const FVector& StartingDirection,
	                float ZLevel, const FVector& DestinationLocation, float MinimumPathDistance,
	                const FPathProperties& PathProperties, float CurrentSpeed);
	UFUNCTION(BlueprintCallable, Category = "Pathing")
	static bool AddPointsToPath(USplineComponent* PathSpline, const FVector& StartingLocation,
	                            const FVector& StartingDirection,
	                            const FVector& DestinationLocation, float MinimumPathDistance, float EndDistance, float ZLevel, float CurrentSpeed, const
	                            FPathProperties& PathProperties);


	// ---------------------------------------------------------------------------
	// GetMovementCurve
	//
	//  1. Sample curvature weight at N world-distance-spaced points.
	//  2. Apply ease-in / ease-out over explicit world-unit distances.
	//  3. Integrate weights → cumulative distance array.
	//  4. Pair uniform time indices with normalised CumulativeDistance → FRichCurve (LINEAR).
	//  5. Optional: draw debug spheres + on-screen table.
	//
	// Why RCIM_Linear?
	//   Cubic auto-tangent splines produce pre-ringing at local minima: they start
	//   descending before the minimum key to achieve a smooth fit. With curvature
	//   weights this means the ship slows down before the apex, not at it.
	//   RCIM_Linear has no look-ahead; each segment is a straight line between
	//   adjacent keys. With SampleInterval ≤ 100 UU the result is smooth enough
	//   visually while apex placement is exact.
	// ---------------------------------------------------------------------------
	UFUNCTION(BlueprintCallable, Category = "Pathing", meta = (WorldContext = "WorldContextObject"))
	static UCurveFloat* GetMovementCurve(UObject* WorldContextObject, const USplineComponent* PathSpline, const float EaseInDistance,
		const float EaseOutDistance, const float StartDistance, const float SegmentLength, const FPathProperties& PathProperties);
	
	UFUNCTION(BlueprintCallable, Category = "Pathing", meta = (WorldContext = "WorldContextObject"))
	static UCurveFloat* GetMovementCurve2(UObject* WorldContextObject, const USplineComponent* PathSpline, float StartDistance,
	                               float SegmentLength, float TurnDuration, float EntrySpeed,
	                               const FPathProperties& PathProperties);


	UFUNCTION(BlueprintCallable, Category = "Pathing")
	static FVector PredictPlanetInterceptCS(const FTransform& ShipTransform, float ZLevel, const FVector& OrbitCenter, float OrbitRadius,
	                                        float CurrentAngleDeg, float OrbitTurns, int32 MaxIterations, float CurrentSpeed, const FPathProperties& PathProperties);
	UFUNCTION(BlueprintCallable, Category = "Pathing")
	static TArray<FPathPoint> BuildRotatedDubinsPath(const FVector& StartLoc, const FVector& StartDir,
													 const FVector& TargetLoc,
													 const FVector& TargetDir, float CurrentSpeed, float ZLevel,
													 const FPathProperties& PathProperties);
	UFUNCTION(BlueprintCallable, Category = "Pathing")
	static void GetPathSamples(const USplineComponent* PathSpline, TArray<float>& CheckpointDistances, float StartDistance,
	                           TArray<FVector>& OutCurrentPath, TArray<FVector>& OutRemainingPath,
	                           TArray<FVector>& OutTraversedPath, TArray<FVector>& OutCheckpoints, float DistancePerStep,
	                           int32 TurnsAhead);
	UFUNCTION(BlueprintCallable, Category = "Pathing")
	static TArray<FPathPoint> BuildDubinsArc(const FVector& StartPos, const FVector& StartDir, float ZLevel,
									  const FVector& EndPos,
									  const FPathProperties& PathProperties, float CurrentSpeed);
	UFUNCTION(BlueprintPure, Category = "Pathing")
	static float EvalCurveDerivative(const UCurveFloat* MovementCurve, float NormTime);

private:
    static float SampleCurvatureWeight(const USplineComponent* PathSpline, float WorldDistance, const FPathProperties& SplineProperties);
};
