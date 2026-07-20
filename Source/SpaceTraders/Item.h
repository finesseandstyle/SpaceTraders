#pragma once

#include "CoreMinimal.h"
#include "GameplayTagContainer.h"
#include "Engine/DataAsset.h"
#include "Engine/StaticMesh.h"
#include "Engine/Texture2D.h"
#include "Item.generated.h"

UCLASS(Abstract, EditInlineNew, CollapseCategories)
class SPACETRADERS_API UItemFragment : public UObject {GENERATED_BODY()};

UCLASS(BlueprintType)
class SPACETRADERS_API UItemDefinition : public UDataAsset
{
	GENERATED_BODY()

public:
	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, meta = (MultiLine="true"))
	FText Name;

	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, meta = (MultiLine="true"))
	FText Description;

	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly)
	FGameplayTag ItemType;

	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly)
	int32 BasePrice = 0; //A base price of -1 would signal that the item has no price to display

	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly)
	TSoftObjectPtr<UTexture2D> Icon;

	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly)
	TSoftClassPtr<UObject> Class;

	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly)
	TSoftObjectPtr<UStaticMesh> StaticMesh;

	//If true, items with the same ItemKey will stack
	//Container items should never stack, instead they work a bit differently
	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly)
	bool IsStackable = false;

	//Each WeightMultiplier contributes to 1 unit of an item.
	//If WeightMultiplier is 0.1 then if the Weight of the item is 1.0, the amount of stacks becomes 10.
	//Some very heavy stackable items can have a higher WeightMultiplier like 10, in the case of Heavy Machinery.
	//If used on a container, all sub items will be affected by the WeightMultiplier
	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly)
	float WeightMultiplier = 1.f;
	
	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Instanced, Category = "Fragments", Meta = (EditFixedOrder))
	TArray<UItemFragment*> Fragments;
	
	UFUNCTION(BlueprintCallable, meta = (DeterminesOutputType = "FragmentType"))
	const UItemFragment* GetFragment(const TSubclassOf<UItemFragment>& FragmentType) const
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
};
