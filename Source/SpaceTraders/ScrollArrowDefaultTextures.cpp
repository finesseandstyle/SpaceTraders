// ScrollArrowDefaultTextures.cpp
#include "ScrollArrowDefaultTextures.h"

#include "Engine/Texture2D.h"
#include "Misc/App.h"
#include "TextureResource.h"

namespace
{
	bool PointInTriangle(const FVector2D& P, const FVector2D& A, const FVector2D& B, const FVector2D& C)
	{
		auto Sign = [](const FVector2D& P1, const FVector2D& P2, const FVector2D& P3)
		{
			return (P1.X - P3.X) * (P2.Y - P3.Y) - (P2.X - P3.X) * (P1.Y - P3.Y);
		};

		const double D1 = Sign(P, A, B);
		const double D2 = Sign(P, B, C);
		const double D3 = Sign(P, C, A);
		const bool bHasNeg = (D1 < 0.0) || (D2 < 0.0) || (D3 < 0.0);
		const bool bHasPos = (D1 > 0.0) || (D2 > 0.0) || (D3 > 0.0);
		return !(bHasNeg && bHasPos);
	}
}

FScrollArrowDefaultTextures& FScrollArrowDefaultTextures::Get()
{
	// Intentionally never destroyed: avoids static-destruction-order problems with the GC at shutdown.
	static FScrollArrowDefaultTextures* Instance = new FScrollArrowDefaultTextures();
	return *Instance;
}

FScrollArrowDefaultTextures::FScrollArrowDefaultTextures()
{
	Textures.SetNum(4);
}

void FScrollArrowDefaultTextures::AddReferencedObjects(FReferenceCollector& Collector)
{
	Collector.AddReferencedObjects(Textures);
}

UTexture2D* FScrollArrowDefaultTextures::GetTexture(EScrollArrowDirection Direction)
{
	if (!FApp::CanEverRender())
	{
		return nullptr;
	}

	const int32 Index = static_cast<int32>(Direction);
	if (!Textures.IsValidIndex(Index))
	{
		return nullptr;
	}

	if (!Textures[Index])
	{
		Textures[Index] = CreateTexture(Direction);
	}
	return Textures[Index];
}

UTexture2D* FScrollArrowDefaultTextures::CreateTexture(EScrollArrowDirection Direction) const
{
	constexpr int32 Size = 32;
	constexpr int32 SubSamples = 4; // 4x4 supersampling for smooth edges

	UTexture2D* Texture = UTexture2D::CreateTransient(Size, Size, PF_B8G8R8A8);
	if (!Texture || !Texture->GetPlatformData())
	{
		return nullptr;
	}

	// Filled triangle pointing up, in 0..1 texture space (y grows downwards).
	const FVector2D A(0.50, 0.25);
	const FVector2D B(0.22, 0.70);
	const FVector2D C(0.78, 0.70);

	TArray<FColor> Pixels;
	Pixels.SetNumUninitialized(Size * Size);

	for (int32 Y = 0; Y < Size; ++Y)
	{
		for (int32 X = 0; X < Size; ++X)
		{
			int32 Hits = 0;
			for (int32 SY = 0; SY < SubSamples; ++SY)
			{
				for (int32 SX = 0; SX < SubSamples; ++SX)
				{
					const FVector2D UV((X + (SX + 0.5) / SubSamples) / Size, (Y + (SY + 0.5) / SubSamples) / Size);

					// Map the sample back into the "pointing up" space.
					FVector2D UpSpace = UV;
					switch (Direction)
					{
					case EScrollArrowDirection::Up:    UpSpace = UV; break;
					case EScrollArrowDirection::Down:  UpSpace = FVector2D(UV.X, 1.0 - UV.Y); break;
					case EScrollArrowDirection::Left:  UpSpace = FVector2D(UV.Y, UV.X); break;
					case EScrollArrowDirection::Right: UpSpace = FVector2D(UV.Y, 1.0 - UV.X); break;
					}

					if (PointInTriangle(UpSpace, A, B, C))
					{
						++Hits;
					}
				}
			}

			const uint8 Alpha = static_cast<uint8>((Hits * 255) / (SubSamples * SubSamples));
			Pixels[Y * Size + X] = FColor(255, 255, 255, Alpha); // white, tinted by the brush
		}
	}

	Texture->SRGB = true;
	Texture->Filter = TF_Bilinear;
	Texture->AddressX = TA_Clamp;
	Texture->AddressY = TA_Clamp;
	Texture->NeverStream = true;
	Texture->LODGroup = TEXTUREGROUP_UI;

	FTexture2DMipMap& Mip = Texture->GetPlatformData()->Mips[0];
	void* Data = Mip.BulkData.Lock(LOCK_READ_WRITE);
	FMemory::Memcpy(Data, Pixels.GetData(), Pixels.Num() * sizeof(FColor));
	Mip.BulkData.Unlock();

	Texture->UpdateResource();
	return Texture;
}
