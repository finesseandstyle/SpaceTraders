// ScrollArrowDefaultTextures.h
#pragma once

#include "CoreMinimal.h"
#include "UObject/GCObject.h"
#include "UObject/ObjectPtr.h"

class UTexture2D;

enum class EScrollArrowDirection : uint8
{
	Up = 0,
	Down = 1,
	Left = 2,
	Right = 3
};

/**
 * Built-in white arrow textures (one per direction), generated on first use so the plugin needs
 * no content assets. Kept alive for the lifetime of the process.
 */
class FScrollArrowDefaultTextures : public FGCObject
{
public:
	static FScrollArrowDefaultTextures& Get();

	/** Returns nullptr when nothing can be rendered (e.g. dedicated server). Game thread only. */
	UTexture2D* GetTexture(EScrollArrowDirection Direction);

	//~ Begin FGCObject Interface
	virtual void AddReferencedObjects(FReferenceCollector& Collector) override;
	virtual FString GetReferencerName() const override { return TEXT("FScrollArrowDefaultTextures"); }
	//~ End FGCObject Interface

private:
	FScrollArrowDefaultTextures();
	UTexture2D* CreateTexture(EScrollArrowDirection Direction) const;

	TArray<TObjectPtr<UTexture2D>> Textures;
};
