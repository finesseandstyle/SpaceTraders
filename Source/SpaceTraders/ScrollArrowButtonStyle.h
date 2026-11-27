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
 * Size: across the scroll axis the button is always the list's Scroll Bar Style "Thickness" (so it
 * lines up with the scroll bar). Along the scroll axis it is ButtonLength. The built-in arrow is
 * scaled down to the smaller of the two sides.
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

	/**
	 * Size of the button along the scroll axis: its height in a vertical list, its width in a
	 * horizontal one. (The other side is the Scroll Bar Style "Thickness".)
	 */
	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Button Size", meta = (ClampMin = "1.0", UIMin = "1.0"))
	float ButtonLength = 16.0f;
};
