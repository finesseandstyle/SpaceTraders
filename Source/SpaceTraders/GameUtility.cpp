// Fill out your copyright notice in the Description page of Project Settings.

#include "GameUtility.h"
#include "GameFramework/PlayerController.h"
#include "Engine/LocalPlayer.h"
#include "Engine/World.h"
#include "SceneView.h"
#include "SceneViewExtension.h"
#include "Engine/Engine.h"
#include "Algo/Accumulate.h"
#include "Engine/GameViewportClient.h"
#include "Kismet/KismetMathLibrary.h"
#include "StructUtils/InstancedStruct.h"
#include "GameFramework/Pawn.h"
#include "Item.h"

//Implementation: https://forums.unrealengine.com/t/project-world-to-screen-location-stops-returning-a-value/57135/11
//Credit to Branden Marais
bool UGameUtility::ProjectWorldToScreenBidirectional(APlayerController const* Player, const FVector& WorldPosition, FVector2D& ScreenPosition, bool& bTargetBehindCamera, bool bPlayerViewportRelative)
{
	FVector Projected;
	bool bSuccess = false;

	ULocalPlayer* const LP = Player ? Player->GetLocalPlayer() : nullptr;
	if (LP && LP->ViewportClient)
	{
		// Get the projection data
		FSceneViewProjectionData ProjectionData;
		if (LP->GetProjectionData(LP->ViewportClient->Viewport, /*out*/ ProjectionData))
		{
			const FMatrix ViewProjectionMatrix = ProjectionData.ComputeViewProjectionMatrix();
			const FIntRect ViewRectangle = ProjectionData.GetConstrainedViewRect();

			FPlane Result = ViewProjectionMatrix.TransformFVector4(FVector4(WorldPosition, 1.f));
			if (Result.W < 0.f) { bTargetBehindCamera = true; }
			else { bTargetBehindCamera = false; }
			if (Result.W == 0.f) { Result.W = 1.f; } // Prevent Divide By Zero

			const float RHW = 1.f / FMath::Abs(Result.W);
			Projected = FVector(Result.X, Result.Y, Result.Z) * RHW;

			// Normalize to 0..1 UI Space
			const float NormX = (Projected.X / 2.f) + 0.5f;
			const float NormY = 1.f - (Projected.Y / 2.f) - 0.5f;

			Projected.X = (float)ViewRectangle.Min.X + (NormX * (float)ViewRectangle.Width());
			Projected.Y = (float)ViewRectangle.Min.Y + (NormY * (float)ViewRectangle.Height());

			bSuccess = true;
			ScreenPosition = FVector2D(Projected.X, Projected.Y);

			if (bPlayerViewportRelative)
			{
				ScreenPosition -= FVector2D(ProjectionData.GetConstrainedViewRect().Min);
			}
		}
		else
		{
			ScreenPosition = FVector2D(1234, 5678);
		}
	}

	return bSuccess;
}

bool UGameUtility::IsActorVisible(APlayerController const* Player, AActor const* Actor)
{
	if (!Player || !Actor)
	{
		return false;
	}

	FVector PlayerLocation;
	FRotator PlayerRotation;
	Player->GetPlayerViewPoint(PlayerLocation, PlayerRotation);

	FVector DirectionToActor = Actor->GetActorLocation() - PlayerLocation;
	DirectionToActor.Normalize();

	FVector PlayerFacingDirection = PlayerRotation.Vector();
	PlayerFacingDirection.Normalize();

	float DotProduct = FVector::DotProduct(PlayerFacingDirection, DirectionToActor);
	float FOV = Player->PlayerCameraManager->GetFOVAngle();
	float FOVRadians = FMath::DegreesToRadians(FOV / 2.0f);
	float CosFOV = FMath::Cos(FOVRadians);

	if (DotProduct > CosFOV)
	{
		// Actor is within FOV, now perform a line trace to check visibility
		FHitResult HitResult;
		FCollisionQueryParams Params;
		Params.AddIgnoredActor(Player->GetPawn());

		bool bHit = Player->GetWorld()->LineTraceSingleByChannel(HitResult, PlayerLocation, Actor->GetActorLocation(), ECC_Visibility, Params);
		if (!bHit || HitResult.GetActor() == Actor)
		{
			return true;
		}
	}

	return false;
}

TArray<FVector2D> UGameUtility::DeprojectScreenCornersToPlane(
	APlayerController* PlayerController,
	FVector2D Offset,
	float MinimapScale,
	float ZPlane
)
{
	TArray<FVector2D> MinimapPoints;

	if (!PlayerController)
	{
		return MinimapPoints;
	}

	// Get viewport size
	FVector2D ViewportSize;
	GEngine->GameViewport->GetViewportSize(ViewportSize);
	if (ViewportSize.IsZero())
	{
		return MinimapPoints;
	}

	// Define 4 screen corners
	TArray<FVector2D> ScreenCorners = {
		FVector2D(0.f, 0.f),                // Top-left
		FVector2D(ViewportSize.X, 0.f),        // Top-right
		FVector2D(ViewportSize.X, ViewportSize.Y), // Bottom-right
		FVector2D(0.f, ViewportSize.Y),        // Bottom-left
	};

	for (const FVector2D& ScreenPos : ScreenCorners)
	{
		FVector WorldOrigin, WorldDirection;

		if (PlayerController->DeprojectScreenPositionToWorld(ScreenPos.X, ScreenPos.Y, WorldOrigin, WorldDirection))
		{
			if (!FMath::IsNearlyZero(WorldDirection.Z))
			{
				float t = (ZPlane - WorldOrigin.Z) / WorldDirection.Z;
				FVector WorldPoint = (WorldOrigin + t * WorldDirection);

				// Convert to minimap space
				float MinimapX = WorldPoint.Y * MinimapScale + Offset.X;
				float MinimapY = -WorldPoint.X * MinimapScale + Offset.Y;

				MinimapPoints.Add(FVector2D(MinimapX, MinimapY));
				//GEngine->AddOnScreenDebugMessage(-1, 0.0f, FColor::Yellow, FString::Printf(TEXT("World Point %s"), *WorldPoint.ToCompactString()));
			}
		}
	}

	return MinimapPoints;
}

template<typename T>
T EaseOutIn(const T& A, const T& B, float Alpha, float Exponent,
			T(*EaseOutFunc)(T, T, float, float),
			T(*EaseInFunc)(T, T, float, float))
{
	const T Mid = UKismetMathLibrary::VLerp(A, B, 0.5f);

	if (Alpha < 0.5f)
	{
		return EaseOutFunc(A, Mid, Alpha * 2.0f, Exponent);
	}
	else
	{
		return EaseInFunc(Mid, B, (Alpha - 0.5f) * 2.0f, Exponent);
	}
}

float UGameUtility::EaseOutInFloat(float A, float B, float Alpha, float Exponent)
{
	const float Mid = (A + B) * 0.5f;

	if (Alpha < 0.5f)
	{
		float AdjustedAlpha = Alpha * 2.0f;
		return UKismetMathLibrary::Ease(A, Mid, AdjustedAlpha, EEasingFunc::EaseOut, Exponent);
	}
	else
	{
		float AdjustedAlpha = (Alpha - 0.5f) * 2.0f;
		return UKismetMathLibrary::Ease(Mid, B, AdjustedAlpha, EEasingFunc::EaseIn, Exponent);
	}
}

// Implementation taken from https://github.com/python/cpython/blob/main/Lib/random.py#L511
float UGameUtility::RandomTriangular(float Low, float High, float Mode)
{
	// If High == Low, return Low directly
	if (Low == High)
	{
		return Low;
	}

	// Handle default Mode (when passed -1 or out of range)
	if (Mode < Low || Mode > High)
	{
		Mode = (Low + High) * 0.5f;
	}

	// Uniform random number in [0,1)
	float U = FMath::FRand();

	// Calculate c = (mode - low) / (high - low)
	float C = (Mode - Low) / (High - Low);

	// Mirror logic if U > C (to preserve distribution symmetry)
	if (U > C)
	{
		U = 1.0f - U;
		C = 1.0f - C;
		float Temp = Low;
		Low = High;
		High = Temp;
	}

	// Return value using sqrt(u * c)
	return Low + (High - Low) * FMath::Sqrt(U * C);
}

float UGameUtility::RoundToNiceNumber(float Value)
{
	// Handle negatives gracefully
	const float Sign = FMath::Sign(Value);
	Value = FMath::Abs(Value);

	// Determine scale step based on magnitude
	float Step;
	if (Value < 50.f)
		Step = 5.f;
	else if (Value < 100.f)
		Step = 10.f;
	else if (Value < 250.f)
		Step = 25.f;
	else if (Value < 1000.f)
		Step = 50.f;
	else if (Value < 5000.f)
		Step = 100.f;
	else if (Value < 10000.f)
		Step = 250.f;
	else
		Step = 500.f;
	//More checks can be made for ever larger values but this is good enough

	// Round to the nearest step
	float Rounded = FMath::RoundToFloat(Value / Step) * Step;

	// Apply sign back
	return Rounded * Sign;
}

TArray<int32> UGameUtility::SplitInteger(const int32 Total, const TArray<float>& Ratios)
{
	TArray<int32> Result;
	Result.SetNum(Ratios.Num());

	if (Ratios.Num() == 0 || Total <= 0)
	{
		return Result;
	}

	// Step 1: Compute raw float allocations
	TArray<float> RawValues;
	RawValues.Reserve(Ratios.Num());

	for (float Ratio : Ratios)
	{
		RawValues.Add(Ratio * static_cast<float>(Total));
	}

	// Step 2: Take the floor of each
	int32 SumFloored = 0;
	for (int32 i = 0; i < RawValues.Num(); ++i)
	{
		Result[i] = FMath::FloorToInt(RawValues[i]);
		SumFloored += Result[i];
	}

	// Step 3: Compute remainder to distribute
	const int32 Remainder = Total - SumFloored;

	// Step 4: Calculate fractional remainders
	TArray<TPair<int32, float>> FractionalParts;
	FractionalParts.Reserve(Ratios.Num());
	for (int32 i = 0; i < RawValues.Num(); ++i)
	{
		FractionalParts.Add(TPair<int32, float>(i, RawValues[i] - static_cast<float>(Result[i])));
	}

	// Step 5: Sort by remainder descending
	FractionalParts.Sort([](const TPair<int32, float>& A, const TPair<int32, float>& B)
	{
		return A.Value > B.Value;
	});

	// Step 6: Distribute remaining units
	for (int32 i = 0; i < Remainder && i < FractionalParts.Num(); ++i)
	{
		Result[FractionalParts[i].Key] += 1;
	}

	return Result;
}

TArray<int32> UGameUtility::DistributeValues(const int32 TotalValue, const int32 NumSlots, const float SpreadMultiplier)
{
    TArray<int32> Output;
    Output.Init(0, NumSlots);

    if (TotalValue <= 0 || NumSlots <= 0)
        return Output;

	if (NumSlots == 1)
	{
		Output[0] = TotalValue;
		return Output;
	}

    // Step 1: Build a weighted base pattern
    TArray<float> BasePattern;
    BasePattern.Reserve(NumSlots);

    for (int32 i = 0; i < NumSlots; ++i)
    {
        BasePattern.Add(FMath::Max(0.1f, NumSlots - (i * SpreadMultiplier)));
    }

    // Compute pattern sum
    float PatternSum = 0.0f;
    for (const float Value : BasePattern)
        PatternSum += Value;

    // Normalized weights
    TArray<float> Distribution;
    Distribution.Reserve(NumSlots);
    for (const float Value : BasePattern)
        Distribution.Add(Value / PatternSum);

    // Case 1: If total smaller than slots → assign probabilistically
    if (TotalValue < NumSlots)
    {
        for (int32 n = 0; n < TotalValue; ++n)
        {
            const float RandomValue = FMath::FRand();
            float Cumulative = 0.0f;
            int32 ChosenIndex = 0;

            for (int32 i = 0; i < NumSlots; ++i)
            {
                Cumulative += Distribution[i];
                if (RandomValue <= Cumulative)
                {
                    ChosenIndex = i;
                    break;
                }
            }
            Output[ChosenIndex] += 1;
        }
        return Output;
    }

    // Case 2: Normal distribution
    Distribution.Empty();
    for (const float Value : BasePattern)
        Distribution.Add((Value / PatternSum) * TotalValue);

    const int32 MaxVariation = FMath::Max(1, TotalValue / NumSlots);

    // Random variations
    TArray<int32> RandomVariation;
    RandomVariation.Reserve(NumSlots);
    for (int32 i = 0; i < NumSlots; ++i)
        RandomVariation.Add(FMath::RandRange(-MaxVariation, MaxVariation));

    // Apply variations
    for (int32 i = 0; i < NumSlots; ++i)
    {
        if (i < NumSlots / 2)
        {
            Distribution[i] += FMath::Abs(RandomVariation[i]);
        }
        else
        {
            Distribution[i] -= FMath::Abs(RandomVariation[i]) * 0.25f;
        }
    }

    // Round and clamp
    for (int32 i = 0; i < NumSlots; ++i)
        Output[i] = FMath::Max(0, FMath::RoundToInt(Distribution[i]));

    // Correction step to ensure total matches
    const int32 Diff = TotalValue - Algo::Accumulate(Output, 0);

    for (int32 i = 0; i < FMath::Abs(Diff); ++i)
    {
        const int32 Index = i % NumSlots;
        if (Diff > 0)
        {
            Output[Index] += 1;
        }
        else if (Diff < 0 && Output[Index] > 0)
        {
            Output[Index] -= 1;
        }
    }

    // Sanity correction if off by a few units
    int32 FinalDiff = FMath::Abs(TotalValue - Algo::Accumulate(Output, 0));
    for (int32 i = NumSlots - 1; i >= 0 && FinalDiff > 0; --i)
    {
        int32 ReduceBy = FMath::Min(Output[i], FinalDiff);
        Output[i] -= ReduceBy;
        FinalDiff -= ReduceBy;
    }

    return Output;
}

float UGameUtility::RandomNormal(float Min, float Max)
{
	if (Min == Max)
	{
		return Min;
	}
	
	return FMath::Lerp(Min, Max, (FMath::FRand() + FMath::FRand() + FMath::FRand()) / 3);
}

void UGameUtility::SortActorsOnDistance(TArray<AActor*>& Actors, FVector Location)
{
	Actors.Sort([&](const AActor& A, const AActor& B) {
				float DistA = FVector::DistSquared(Location, A.GetActorLocation());
				float DistB = FVector::DistSquared(Location, B.GetActorLocation());
				return DistA > DistB;
	});
}

bool UGameUtility::IsInteger(const FString& SourceString)
{
	if (SourceString.IsEmpty())
	{
		return false;
	}
	
	//TODO first symbol can be a negative sign to account for negative numbers
	for (const TCHAR Char : SourceString)
	{
		// It returns false for '.', '-', ' ', etc.
		if (!FChar::IsDigit(Char))
		{
			return false;
		}
	}

	return true;
}
/**
 * Returns N random unique items from an array.
 * @param TargetArray The source array to pick from
 * @param n Number of items to retrieve
 * @param OutArray The resulting array of random items
 */
UFUNCTION(BlueprintCallable, CustomThunk, Category = "Utilities|Array", meta = (ArrayParm = "TargetArray", ArrayTypeDependentParams = "OutArray", CompactNodeTitle = "RAND N"))
static void GetNRandomItems(const TArray<int32>& TargetArray, int32 n, TArray<int32>& OutArray, TArray<int32>& OutIndices)
{
	
}


// This is the actual implementation that handles the generic logic
DECLARE_FUNCTION(execGetNRandomItems);

// C++ Template version for internal use
template<typename T>
static void GenericGetNRandomItems(const TArray<T>& TargetArray, int32 n, TArray<T>& OutArray)
{
    OutArray.Empty();
    int32 SourceSize = TargetArray.Num();

    if (n <= 0 || SourceSize == 0) return;

    if (n >= SourceSize)
    {
        OutArray = TargetArray;
        return;
    }

    // Create a copy to shuffle so we don't modify the original
    TArray<T> TempArray = TargetArray;
    
    // Fisher-Yates Shuffle
    const int32 LastIndex = TempArray.Num() - 1;
    for (int32 i = 0; i <= LastIndex; ++i)
    {
        int32 Index = FMath::RandRange(i, LastIndex);
        if (i != Index)
        {
            TempArray.Swap(i, Index);
        }
    }

    // Add the first n items to OutArray
    for (int32 i = 0; i < n; i++)
    {
        OutArray.Add(TempArray[i]);
    }
}

// The implementation of the Blueprint "CustomThunk"
DEFINE_FUNCTION(UGameUtility::execGetNRandomItems)
{
    // 1. Parse Input Array (Wildcard)
    Stack.StepCompiledIn<FArrayProperty>(NULL);
    void* TargetArrayAddr = Stack.MostRecentPropertyAddress;
    FArrayProperty* TargetArrayProperty = CastField<FArrayProperty>(Stack.MostRecentProperty);

    // 2. Parse Integer 'n'
    P_GET_PROPERTY(FIntProperty, n);

    // 3. Parse Output Array (Wildcard)
    Stack.StepCompiledIn<FArrayProperty>(NULL);
    void* OutArrayAddr = Stack.MostRecentPropertyAddress;
    FArrayProperty* OutArrayProperty = CastField<FArrayProperty>(Stack.MostRecentProperty);

    // 4. Parse Output Indices Array (Int32)
    Stack.StepCompiledIn<FArrayProperty>(NULL);
    void* OutIndicesAddr = Stack.MostRecentPropertyAddress;
    FArrayProperty* OutIndicesProperty = CastField<FArrayProperty>(Stack.MostRecentProperty);

    P_FINISH;

    if (!TargetArrayProperty || !OutArrayProperty || !OutIndicesProperty) return;

    FScriptArrayHelper TargetHelper(TargetArrayProperty, TargetArrayAddr);
    FScriptArrayHelper OutHelper(OutArrayProperty, OutArrayAddr);
    FScriptArrayHelper IndicesHelper(OutIndicesProperty, OutIndicesAddr);

    OutHelper.EmptyValues();
    IndicesHelper.EmptyValues();

    int32 SourceSize = TargetHelper.Num();
    if (n <= 0 || SourceSize == 0) return;

    // Handle n >= size: Return everything and all indices 0 to Size-1
    if (n >= SourceSize)
    {
        OutHelper.MoveAssign(TargetHelper.GetRawPtr());
        for (int32 i = 0; i < SourceSize; i++)
        {
            int32 NewIdx = IndicesHelper.AddValue();
            ((int32*)IndicesHelper.GetRawPtr())[NewIdx] = i;
        }
        return;
    }

    // --- Selection Logic ---
    TArray<int32> TempIndices;
    for (int32 i = 0; i < SourceSize; i++) TempIndices.Add(i);

    for (int32 i = 0; i < n; i++)
    {
        int32 SwapIndex = FMath::RandRange(i, SourceSize - 1);
        TempIndices.Swap(i, SwapIndex);
        
        // 1. Copy the value to the result array
        int32 NewValIdx = OutHelper.AddValue();
        TargetArrayProperty->Inner->CopySingleValueToScriptVM(
            OutHelper.GetRawPtr(NewValIdx), 
            TargetHelper.GetRawPtr(TempIndices[i])
        );

        // 2. Record the original index
        int32 NewIdxIdx = IndicesHelper.AddValue();
        // Since we know this is an int32 array, we can cast and assign
        *(int32*)(IndicesHelper.GetRawPtr(NewIdxIdx)) = TempIndices[i];
    }
}

const UItemFragment* UGameUtility::GetItemFragment(TArray<UItemFragment*> Fragments,
	const TSubclassOf<UItemFragment>& FragmentType)
{
	for (const auto Fragment : Fragments)
	{
		if (Fragment && Fragment->IsA(FragmentType))
		{
			return Fragment;
		}
	}

	return nullptr;
}

// Keep the stub empty since CustomThunk uses execGetNRandomItems
void UGameUtility::GetNRandomItems(const TArray<int32>& TargetArray, int32 n, TArray<int32>& OutArray, TArray<int32>& OutIndices)
{
    // Logic is handled by the exec function above.
}

FInstancedStruct UGameUtility::MakeInstancedStructFromType(UScriptStruct* StructType)
{
	if (!StructType)
	{
		return FInstancedStruct();
	}
    
	// This creates an empty instance of the specified struct type
	return FInstancedStruct(StructType);
}


FText UGameUtility::WrapLines(const FText& InText, const FString& LineStart, const FString& LineEnd)
{
	if (InText.IsEmpty())
	{
		return FText::GetEmpty();
	}

	// Convert to string for manipulation
	FString SourceString = InText.ToString();
    
	// Normalize line endings to just \n to handle various string sources safely
	SourceString.ReplaceInline(TEXT("\r\n"), TEXT("\n"));

	// Parse the string into an array of lines
	TArray<FString> Lines;
	SourceString.ParseIntoArray(Lines, TEXT("\n"), false);

	FString ResultString;
	for (int32 i = 0; i < Lines.Num(); ++i)
	{
		// Wrap the line in your tags
		ResultString += LineStart + Lines[i] + LineEnd;

		// Re-append the newline character if it's not the final line
		if (i < Lines.Num() - 1)
		{
			ResultString += TEXT("\n");
		}
	}

	return FText::FromString(ResultString);
}
