// ScrollArrowButtonStyle.h
#pragma once

#include "CoreMinimal.h"
#include "Styling/SlateBrush.h"
#include "ScrollArrowButtonStyle.generated.h"

/**
 * Appearance of one scroll arrow button: one brush per interaction state, exactly like the
 * scroll bar handle (Normal / Hovered / Dragged).
 *
 * Every brush that is left at its default (Draw As = Image, no texture) falls back to:
 *   1. the Normal image, if that one has a texture (tinted darker / lighter per state), or
 *   2. a built-in arrow texture pointing in the right direction.
 * So the buttons look right out of the box, and assigning a texture to Normal alone is enough.
 *
 * The button is square; its size is the list's Scroll Bar Style "Thickness".
 */
USTRUCT(BlueprintType)
struct FScrollArrowButtonStyle
{
	GENERATED_BODY()

	/** Arrow button while idle. */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Button Images")
	FSlateBrush NormalImage;

	/** Arrow button while the pointer is over it. */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Button Images")
	FSlateBrush HoveredImage;

	/** Arrow button while it is held down. */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Button Images")
	FSlateBrush PressedImage;

	/** Arrow button when it cannot scroll any further (or there is nothing to scroll). */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Button Images")
	FSlateBrush DisabledImage;
};
