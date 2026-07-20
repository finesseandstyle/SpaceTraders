// Fill out your copyright notice in the Description page of Project Settings.

#pragma once

#include "CoreMinimal.h"
#include "Kismet/BlueprintFunctionLibrary.h"
#include "GameUtility.generated.h"

/**
 * 
 */
UCLASS()
class SPACETRADERS_API UGameUtility : public UBlueprintFunctionLibrary
{
	GENERATED_BODY()
public:
	/**
	 * Projects a world position to screen coordinates, with an additional flag to check if the target is behind the camera.
	 * @param Player - The player controller.
	 * @param WorldPosition - The world position to project.
	 * @param ScreenPosition - The resulting screen position.
	 * @param bTargetBehindCamera - True if the target is behind the camera.
	 * @param bPlayerViewportRelative - Whether the screen position should be relative to the player's viewport.
	 * @return True if the projection was successful, false otherwise.
	 */
	UFUNCTION(BlueprintPure, Category = "Camera")
	static bool ProjectWorldToScreenBidirectional(APlayerController const* Player, const FVector& WorldPosition, FVector2D& ScreenPosition, bool& bTargetBehindCamera, bool bPlayerViewportRelative = false);

	/**
	 * Checks if an actor is within the player's field of view and there are no obstacles between the player and the actor.
	 * @param Player - The player controller.
	 * @param Actor - The actor to check.
	 * @return True if the actor is within the player's FOV and visible, false otherwise.
	 */
	UFUNCTION(BlueprintPure, Category = "Rendering")
	static bool IsActorVisible(APlayerController const* Player, AActor const* Actor);
	
	UFUNCTION(BlueprintCallable, Category = "Minimap|Projection")
	static TArray<FVector2D> DeprojectScreenCornersToPlane(
		APlayerController* PlayerController,
		FVector2D Offset, //156,0
		float MinimapScale = 0.0015f,
		float ZPlane = 810.0f		
	);

	/** Interpolates between A and B with an Ease Out-In curve: fast at start and end, slow in the middle */
	UFUNCTION(BlueprintPure, Category = "Interpolation")
	static float EaseOutInFloat(float A, float B, float Alpha, float Exponent);


	/**
	 * Generates a random floating-point number following a triangular distribution.
	 * @param Low - The lower limit of the range.
	 * @param High - The upper limit of the range.
	 * @param Mode - The mode (most likely value) of the distribution. If omitted or equal to Low/High, defaults to midpoint.
	 * @return A random number biased toward the mode.
	 */
	UFUNCTION(BlueprintPure, Category="Math|Random")
	static float RandomTriangular(float Low = 0.0f, float High = 1.0f, float Mode = -1.0f);

	/** Round a number to a 'nice' human-readable number, without inflating already clean values. */
	UFUNCTION(BlueprintPure, Category="Economy|Math")
	static float RoundToNiceNumber(float Value);

	/**
	 * Splits a total integer amount into proportional parts based on provided ratios.
	 * Each ratio determines how much of the total should go to a given slot.
	 * The function guarantees that all resulting parts are integers and sum exactly to the Total.
	 * Example:
	 *     SplitInteger(125, [0.1667f, 0.3333f, 0.5f]) → [21, 42, 62]
	 *
	 * @param Total   The total integer value to be distributed.
	 * @param Ratios  Array of ratios (should sum to 1.0) defining proportional shares.
	 *
	 * @return Array of integers representing the distributed portions of the total.
	 */
	UFUNCTION(BlueprintPure, Category="Math|Utility")
	static TArray<int32> SplitInteger(int32 Total, const TArray<float>& Ratios);

	/**
	 * Distributes a total number into a fixed number of slots using a descending weighted pattern
	 * and optional random variation for smooth, natural spread.
	 * Example:
	 *     DistributeValues(125, 3, 0.75) -> [60, 40, 25]
	 *     
	 * @param TotalValue          The total quantity to distribute.
	 * @param NumSlots            Number of slots/entities to divide the amount among.
	 * @param SpreadMultiplier    Controls distribution slope (0.5 = balanced, 1.0 = steep drop-off).
	 *
	 * @return An array of integer values representing the proportional share for each slot,
	 *         guaranteed to sum exactly to TotalAmount.
	 */
	UFUNCTION(BlueprintPure, Category = "Utility")
	static TArray<int32> DistributeValues(int32 TotalValue, int32 NumSlots, float SpreadMultiplier = 0.5f);

	/**
	 * Generates a random floating-point number approximating a normal (Gaussian-like) distribution.
	 * 
	 * This uses a simple approximation based on the Central Limit Theorem:
	 *     (Rand() + Rand() + Rand()) / 3
	 * which gives a bell-shaped distribution centered around 0.5.
	 * 
	 * The result is then scaled to the specified range [0, Ceiling].
	 * 
	 * @param Ceiling - The upper limit of the resulting range. The returned value is in [0, Ceiling].
	 * @return A random float approximating a normal distribution within [0, Ceiling].
	 */
	UFUNCTION(BlueprintPure, Category="Math|Random")
	static float RandomNormal(float Min = 0.f, float Max = 1.f);

	
	/**
	 * Checks if a string consists strictly of digits (0-9).
	 * Returns false for decimals, spaces, negative signs, or empty strings.
	 * * @param SourceString The string to check.
	 * @return True if the string is a valid sequence of digits.
	 */
	UFUNCTION(BlueprintPure, Category = "Utilies|String")
	static bool IsInteger(const FString& SourceString);

	/**
	 * Returns N unique random items from an array.
	 * @param TargetArray The source array to pull from
	 * @param NumberToGet How many unique items to retrieve
	 * @param OutArray The resulting array of random items
	 */
	
	UFUNCTION(BlueprintCallable, CustomThunk, Category = "Utilities|Array", meta = (ArrayParm = "TargetArray", ArrayTypeDependentParams = "OutArray", CompactNodeTitle = "RAND N"))
	static void GetNRandomItems(const TArray<int32>& TargetArray, int32 n, TArray<int32>& OutArray, TArray<int32>& OutIndices);
	
	UFUNCTION(BlueprintPure, Category = "Utilies")
	static FInstancedStruct MakeInstancedStructFromType(UScriptStruct* StructType);

	/**
	 * Wrap every line with LineStart and LineEnd
	 * @param InText 
	 * @param LineStart 
	 * @param LineEnd 
	 * @return 
	 */
	UFUNCTION(BlueprintPure, Category = "Utilies")
	static FText WrapLines(const FText& InText, const FString& LineStart, const FString& LineEnd);

	// This is the internal implementation that handles the generic logic
	DECLARE_FUNCTION(execGetNRandomItems);

	static void GenericGetNRandomItems(void* TargetArrayAddr, const FArrayProperty* TargetArrayProperty, int32 NumberToGet, void* OutArrayAddr, const FArrayProperty* OutArrayProperty);
	
	UFUNCTION(BlueprintCallable, meta = (DeterminesOutputType = "FragmentType"))
	static const UItemFragment* GetItemFragment(TArray<UItemFragment*> Fragments, const TSubclassOf<UItemFragment>& FragmentType);
};