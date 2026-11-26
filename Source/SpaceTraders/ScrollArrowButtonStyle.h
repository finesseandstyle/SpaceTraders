// ScrollArrowButtonStyle.h
#pragma once

#include "CoreMinimal.h"
#include "Styling/SlateBrush.h"
#include "ScrollArrowButtonStyle.generated.h"

/**
 * Appearance of one scroll arrow button.
 *
 * Works the same way as the scroll bar handle style: one brush per interaction state,
 * so every state can be driven by a texture, a box, a rounded box or a plain tint.
 * An optional arrow glyph is drawn on top; if no ArrowImage is set, a chevron is drawn
 * procedurally (so the buttons are usable without any art).
 */
USTRUCT(BlueprintType)
struct FScrollArrowButtonStyle
{
	GENERATED_BODY()

	FScrollArrowButtonStyle()
	{
		NormalImage.TintColor   = FLinearColor(0.10f, 0.10f, 0.10f, 1.0f);
		HoveredImage.TintColor  = FLinearColor(0.20f, 0.20f, 0.20f, 1.0f);
		PressedImage.TintColor  = FLinearColor(0.35f, 0.35f, 0.35f, 1.0f);
		DisabledImage.TintColor = FLinearColor(0.06f, 0.06f, 0.06f, 0.6f);
	}

	/** Button background while idle. */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Button Images")
	FSlateBrush NormalImage;

	/** Button background while the pointer is over it. */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Button Images")
	FSlateBrush HoveredImage;

	/** Button background while it is held down. */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Button Images")
	FSlateBrush PressedImage;

	/** Button background when the button cannot scroll any further (or there is nothing to scroll). */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Button Images")
	FSlateBrush DisabledImage;

	/** Size of the button across the scroll axis. Keep >= the scroll bar thickness (default scroll bar = 16). */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Button Size", meta = (ClampMin = "1.0", UIMin = "1.0"))
	float ButtonThickness = 16.0f;

	/** Size of the button along the scroll axis. */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Button Size", meta = (ClampMin = "1.0", UIMin = "1.0"))
	float ButtonLength = 16.0f;

	/**
	 * Optional arrow image, drawn as authored (it is NOT rotated, so use separate start/end styles
	 * if you use this). Leave empty to get the built-in chevron.
	 */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Arrow")
	FSlateBrush ArrowImage;

	/** Size of the arrow glyph. */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Arrow")
	FVector2D ArrowSize = FVector2D(8.0, 8.0);

	/** Line thickness of the built-in chevron (ignored when ArrowImage is set). */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Arrow", meta = (ClampMin = "0.5", UIMin = "0.5"))
	float ArrowLineThickness = 2.0f;

	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Arrow")
	FLinearColor ArrowNormalTint = FLinearColor(0.75f, 0.75f, 0.75f, 1.0f);

	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Arrow")
	FLinearColor ArrowHoveredTint = FLinearColor::White;

	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Arrow")
	FLinearColor ArrowPressedTint = FLinearColor(0.55f, 0.55f, 0.55f, 1.0f);

	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Arrow")
	FLinearColor ArrowDisabledTint = FLinearColor(0.30f, 0.30f, 0.30f, 0.6f);
};
