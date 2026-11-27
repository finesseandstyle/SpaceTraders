// ScrollArrowButtonStyle.h
#pragma once

#include "CoreMinimal.h"
#include "Styling/SlateBrush.h"
#include "ScrollArrowButtonStyle.generated.h"

/**
 * Appearance of one scroll arrow button: one brush per interaction state, exactly like the
 * scroll bar handle (Normal / Hovered / Dragged).
 *
 * Defaults, so the buttons look right out of the box:
 *   - If Normal has no texture, the button is drawn as a solid square (which changes colour on
 *     hover / press / disabled) with a built-in arrow on top. Hovering highlights the whole square.
 *   - If Normal has a texture, that texture is used for every state you left empty, tinted
 *     lighter / darker per state. Assigning only a Normal texture is therefore enough.
 *   - Any state you set yourself is always used as-is.
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
